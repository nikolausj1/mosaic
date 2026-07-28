// Sources/App/Prototype/EditorState.swift
// The single source of truth for the prototype editor. Owns the document,
// undo/redo, selection, and the transient overlay state GestureController /
// CanvasView read and write. Snapshot rule (PRD): push undo ON GESTURE END
// ONLY - one snapshot per completed pan/pinch/divider/corner/bracket
// drag/swap/layout-cycle - never mid-gesture. Selection changes never
// snapshot. Any new mutation clears the redo stack.
import Observation
import UIKit
import CoreGraphics
import Photos
import Vision

@Observable
final class EditorState {

    // MARK: - Persistent state

    /// Every mutation autosaves (debounced ~0.5s) via `scheduleAutosave()` -
    /// see the Autosave section below. `didSet` fires on every assignment
    /// EXCEPT the one made in `init` (Swift property-observer semantics), so
    /// `init` schedules the initial autosave itself.
    var document: Document {
        didSet { scheduleAutosave() }
    }
    private(set) var undoStack: [Document] = []
    private(set) var redoStack: [Document] = []
    var selection: PhotoID?

    /// PhotoIDs whose source asset could not be found on restore (deleted
    /// from the library since the document was last autosaved). Populated by
    /// the restore flow (ContentView), cleared by `replace(...)` once the
    /// user picks a new asset for that id. Non-empty blocks Save (PRD:
    /// "Photo unavailable... Save is blocked").
    var unavailablePhotoIDs: Set<PhotoID> = []
    /// Was `let` through Phase 3. Phase 4's Replace action swaps in a new
    /// UIImage for an existing PhotoID (the document keeps the same id, so
    /// undo restoring an older Document still renders fine against
    /// whichever image is currently in this dict - see `replace(...)`'s
    /// doc comment) - hence mutable now, via `updateImage`.
    private(set) var images: [PhotoID: UIImage]
    let haptics = Haptics()

    let photoStore: PhotoStore
    private(set) var layoutIndex: Int

    // MARK: - Export / Save (Phase 5)

    /// True for the duration of a Save: gates the canvas (EditorView overlays
    /// a full-screen touch blocker while this is true - see its doc comment
    /// - rather than reaching into GestureController.swift/CanvasView.swift)
    /// and shows a spinner in place of the Save button's label.
    var isExporting = false
    let saveCoordinator = SaveCoordinator()

    static let undoCap = 50

    // MARK: - Bottom bar / tray state (Phase 4)

    /// Which tray (if any) is raised above the contextual bottom bar when
    /// nothing is selected. Selecting a photo swaps the bar to the photo
    /// toolbar entirely, so this is only ever consulted in the no-selection
    /// state - EditorView resets it to `.none` whenever `selection` becomes
    /// non-nil (see its `.onChange(of: state.selection)`).
    enum ActiveTray: Equatable {
        case none, layout, ratio, border
    }
    var activeTray: ActiveTray = .none

    /// True only while a border-tray slider drag is live. CanvasView hides
    /// the selection overlay chrome and composition brackets for the
    /// duration so the border being adjusted is actually visible under the
    /// finger (Justin, 2026-07-17).
    var isAdjustingBorder = false

    // MARK: - Border swatches (design revision, 2026-07-17)

    /// Four colors sampled from every photo's downsampled pixels (see
    /// `computeSampledSwatches`), computed once here at editor-open time -
    /// not recomputed on Replace/Remove, matching "computed once when the
    /// editor opens" in the task brief. Restore is the exception: `images`
    /// starts empty there, so `refreshDerivedSwatches()` recomputes once
    /// every photo has finished loading (see its doc comment).
    private(set) var derivedSwatches: SampledBorderColors = .fallback

    // MARK: - Canvas sizing

    /// Space available to fit the canvas ratio into. CanvasView writes this
    /// after subtracting the 28pt bracket-clearance padding on every side.
    var containerSize: CGSize = .zero

    /// Non-nil only while a bracket drag is live: overrides the normal
    /// fit-to-container size so the canvas can grow/shrink directly under
    /// the finger. Cleared (animated back to the fitted size) on release.
    var liveCanvasSize: CGSize?

    var canvasSize: CGSize {
        liveCanvasSize ?? Self.fitSize(ratio: document.canvasRatio.value, in: containerSize)
    }

    var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    static func fitSize(ratio: Double, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0, ratio > 0, ratio.isFinite else { return .zero }
        let boxRatio = box.width / box.height
        if ratio > boxRatio {
            return CGSize(width: box.width, height: box.width / ratio)
        } else {
            return CGSize(width: box.height * ratio, height: box.height)
        }
    }

    // MARK: - Transient gesture overlay state

    /// Non-nil only while a swap drag is in flight; read by CanvasView to
    /// render the dimmed source cell, the proxy thumbnail, and the hovered
    /// target outline.
    var swapState: SwapState?

    // MARK: - Debug event ticker (prototype only)

    /// Rolling log of gesture-classification events, rendered as an on-screen
    /// HUD so gesture bugs can be diagnosed from the device itself. Remove
    /// with the rest of the prototype scaffolding after Phase 2 sign-off.
    private(set) var debugEvents: [String] = []
    private var debugCounter = 0

    func debugLog(_ message: String) {
        debugCounter += 1
        debugEvents.append("\(debugCounter) \(message)")
        if debugEvents.count > 7 { debugEvents.removeFirst() }
    }

    // MARK: - Gesture snapshot lifecycle

    private var gestureStartDocument: Document?

    init(document: Document, images: [PhotoID: UIImage], photoStore: PhotoStore, layoutIndex: Int) {
        self.document = document
        self.images = images
        self.photoStore = photoStore
        self.layoutIndex = layoutIndex
        self.derivedSwatches = Self.computeSampledSwatches(document: document, images: images)
        // `didSet` doesn't fire for this initializer's own assignment above
        // (Swift property-observer semantics) - schedule the first autosave
        // explicitly so current.json exists as soon as the editor opens.
        scheduleAutosave()
    }

    // MARK: - Autosave (Phase 6)

    /// Debounced ~0.5s after any document/image mutation. `.common` run-loop
    /// mode so the timer still fires while a gesture's tracking loop is live.
    private var autosaveTimer: Timer?

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.performAutosave()
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    /// Cancels any pending debounce and writes immediately - called on
    /// scenePhase .background/.inactive (see EditorView) so a backgrounded
    /// app never loses the last ~0.5s of edits.
    func flushAutosaveNow() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        performAutosave()
    }

    private func performAutosave() {
        DocumentStore.saveCurrent(document)
        for (id, photo) in document.photos where photo.assetLocalIdentifier.isEmpty {
            if let image = images[id] {
                DocumentStore.saveProxyIfNeeded(photoID: id, image: image)
            }
        }
        let referenced = [document] + (DocumentStore.loadLast().map { [$0] } ?? [])
        DocumentStore.garbageCollectProxies(referencedDocuments: referenced)
    }

    /// Recomputes the border tray's derived swatches against whatever images
    /// are currently loaded. Normally swatches are computed once at init
    /// (see `derivedSwatches`'s doc comment) against a fully-loaded `images`
    /// dict; restore is the one path where `images` starts empty and fills in
    /// asynchronously, so the caller (ContentView's restore flow) calls this
    /// once every photo has finished loading.
    func refreshDerivedSwatches() {
        derivedSwatches = Self.computeSampledSwatches(document: document, images: images)
    }

    /// Call once at the very start of any gesture that might mutate
    /// `document` (pan/pinch/divider/corner/bracket/swap). Idempotent: a
    /// second call while one is already in flight (e.g. drag + magnify
    /// both firing for a two-finger gesture) is a no-op.
    func beginGesture() {
        guard gestureStartDocument == nil else { return }
        gestureStartDocument = document
    }

    /// Call at gesture end. Pushes the pre-gesture snapshot iff the
    /// document actually changed; always clears the in-flight marker.
    /// Safe to call even when nothing happened (e.g. a plain tap, or a
    /// swap released over empty space) - it simply won't push anything.
    func commitGesture() {
        defer { gestureStartDocument = nil }
        guard let start = gestureStartDocument, start != document else { return }
        pushUndo(start)
    }

    /// Abandons an in-flight gesture, restoring `document` to whatever it
    /// was before the gesture began. Used when a pinch pre-empts a
    /// still-undecided tracking/pan.
    func cancelGesture() {
        defer { gestureStartDocument = nil }
        guard let start = gestureStartDocument else { return }
        document = start
    }

    private func pushUndo(_ doc: Document) {
        undoStack.append(doc)
        if undoStack.count > Self.undoCap { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: - Undo / redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        if redoStack.count > Self.undoCap { redoStack.removeFirst() }
        document = previous
        sanitizeSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        if undoStack.count > Self.undoCap { undoStack.removeFirst() }
        document = next
        sanitizeSelection()
    }

    private func sanitizeSelection() {
        if let sel = selection, document.photos[sel] == nil {
            selection = nil
        }
    }

    // MARK: - Layout tray: apply a template by index (Phase 4)

    /// Replaces `document.root` with `templates(for:)[index]` for the
    /// CURRENT photo count, keeping each photo's identity and cropping by
    /// leaf order (exactly what the old "Cycle" button did) - fractions
    /// reset to even because every template starts even. One undo snapshot.
    /// Supersedes `cycleLayout()` (deleted): the layout tray lets you pick
    /// any topology directly instead of only walking forward one at a time.
    func applyTemplate(index: Int) {
        let currentIDs = photoIDs(in: document.root)
        let candidates = templates(for: currentIDs)
        guard candidates.indices.contains(index) else { return }

        var doc = document
        doc.root = candidates[index]
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        layoutIndex = index
        document = doc
        pushUndo(old)
    }

    // MARK: - Ratio tray (Phase 4)

    /// Sets the canvas ratio directly (used by the ratio tray's chips,
    /// including the active-chip-flips-orientation case - the caller
    /// decides whether to pass (w,h) or the flipped (h,w)). Fractions are
    /// percentages so they're untouched; `reclampAll` re-crops every photo
    /// around its existing zoom/center, zooming in only if the new shape
    /// would otherwise expose an edge (existing `reclampAll` behavior,
    /// unchanged here - verified by reading Operations.swift, not
    /// reimplemented). One undo snapshot per tap.
    func setCanvasRatio(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let old = document
        var doc = document
        doc.canvasRatio = Ratio(width: width, height: height)
        let fitted = Self.fitSize(ratio: width / height, in: containerSize)
        doc = reclampAll(doc, canvasSize: fitted)
        document = doc
        pushUndo(old)
    }

    /// JUDGMENT CALL: "Original" (the ratio tray's 7th chip) is defined as
    /// the FIRST photo's native pixel aspect, in the document's current
    /// leaf order - Justin may redefine this (e.g. "the largest photo", or
    /// "average aspect across all photos") if it doesn't feel right on
    /// device.
    var originalAspectRatio: (width: Double, height: Double)? {
        guard let firstID = photoIDs(in: document.root).first,
              let photo = document.photos[firstID],
              photo.pixelWidth > 0, photo.pixelHeight > 0
        else { return nil }
        return (Double(photo.pixelWidth), Double(photo.pixelHeight))
    }

    // MARK: - Border tray (design revision, 2026-07-17: one THICKNESS slider
    // replaces the old linked Inner/Outer pair)

    /// Slider drags call `beginGesture()`/`commitGesture()` around a whole
    /// interaction (see BorderTrayView) so a multi-step drag collapses to
    /// ONE undo snapshot; this setter just mutates `document` live in
    /// between, mirroring GestureController's divider-drag pattern.
    /// `border.linked` stays `true` unconditionally now - the model field is
    /// kept only for persistence compatibility with documents saved before
    /// this revision (no UI ever reads it anymore).
    func setBorderThickness(_ fraction: Double) {
        var doc = document
        doc.border.inner = fraction
        doc.border.outer = fraction
        doc.border.linked = true
        doc = reclampAll(doc, canvasSize: canvasSize)
        document = doc
    }

    /// Border tab assumes intent (Justin, 2026-07-26): opening the Border
    /// tray on a zero-border document animates the thickness up to a modest
    /// visible starter so the sliders demonstrably control something. One
    /// undo snapshot via the same begin/commit pair the slider itself uses;
    /// re-opening the tray with any nonzero border is a no-op.
    ///
    /// Sticky thickness (Justin, 2026-07-27): "A user might really like a
    /// certain border thickness so lets not auto change it after they set
    /// it." Two changes from the original: (1) the starter value is now
    /// whatever the user last DELIBERATELY chose (see
    /// `commitBorderThicknessChoice`/`rememberedBorderThickness` below),
    /// falling back to the old 0.02 only before any preference has ever been
    /// saved; (2) `hasCustomizedBorderThickness` makes this permanently a
    /// no-op for the CURRENT document once the user has touched the
    /// Thickness slider - even if they drag it back down to exactly zero,
    /// which the old zero-check alone couldn't distinguish from "never
    /// touched." A restored/edit-last document that already carries a
    /// nonzero border still short-circuits on the zero-check below exactly
    /// as before, independent of this flag.
    func applyBorderStarterIfZero() {
        guard !hasCustomizedBorderThickness else { return }
        guard document.border.inner == 0, document.border.outer == 0 else { return }
        beginGesture()
        setBorderThickness(Self.rememberedBorderThickness)
        commitGesture()
    }

    /// True once the user has ended a Thickness slider drag for the CURRENT
    /// document (any resulting value, including a deliberate 0) - see
    /// BorderTrayView's Thickness `sliderRow`, which calls
    /// `commitBorderThicknessChoice()` on release. Per-EditorState-instance
    /// (not persisted): a fresh EditorState - a new document, or the same
    /// document reopened in a later session - starts false again, so
    /// `applyBorderStarterIfZero` gets exactly one more chance to apply the
    /// remembered starter on a document whose border happens to still be
    /// zero, matching "untouched" rather than "the user chose zero just
    /// now."
    private(set) var hasCustomizedBorderThickness = false

    /// UserDefaults key for the cross-document/cross-session "last
    /// deliberately-chosen thickness" (Justin, 2026-07-27). Read/written via
    /// plain UserDefaults rather than the `@AppStorage` property wrapper:
    /// `@Observable`'s macro already manages this class's stored-property
    /// storage, and composing it with a second property wrapper on the same
    /// property isn't supported - reading/writing UserDefaults directly here
    /// gets the identical persistence (same suite, same key) without that
    /// conflict. `BorderTrayView` (a plain SwiftUI View) is where the write
    /// actually happens, via this same key.
    static let lastBorderThicknessDefaultsKey = "lastBorderThickness"

    /// The remembered starter value: whatever the user last deliberately
    /// committed, or 0.02 (the original hardcoded starter) the very first
    /// time this key has never been written. `object(forKey:)` (not
    /// `double(forKey:)`) is what makes that distinction possible -
    /// `double(forKey:)` returns 0 for an absent key, indistinguishable from
    /// a genuinely-saved 0.
    private static var rememberedBorderThickness: Double {
        (UserDefaults.standard.object(forKey: lastBorderThicknessDefaultsKey) as? Double) ?? 0.02
    }

    /// Called by BorderTrayView's Thickness slider on release (`editing ==
    /// false`, right after `commitGesture()`) - persists whatever thickness
    /// the user just landed on (including 0) as the new cross-session
    /// default, and permanently retires `applyBorderStarterIfZero` for this
    /// document/session. NOT called for the Radius slider - only Thickness
    /// is "the border" in the sense this feature is about.
    func commitBorderThicknessChoice() {
        hasCustomizedBorderThickness = true
        UserDefaults.standard.set(document.border.inner, forKey: Self.lastBorderThicknessDefaultsKey)
    }

    /// B11 canvas eyedropper (Justin, 2026-07-26): true while the Border
    /// tray's eyedropper is armed - CanvasView overlays a loupe magnifier
    /// (see `samplingComposite` and `applySampledColor` below) that samples
    /// the collage on release.
    var isSamplingColor = false

    /// LOUPE EYEDROPPER (Justin, 2026-07-26 rework of the original one-tap
    /// sampler - "I expect a mag glass / pixel selection UI... not what
    /// shipped"): the composited collage, rendered ONCE via the same
    /// `CollageRenderer.renderForSampling` path the old one-tap sampler
    /// used, held here for the duration of sampling so CanvasView's loupe
    /// can magnify live off this cached bitmap on every touch-move instead
    /// of re-rendering per frame. Sized bigger than the old one-shot's
    /// 480pt (900pt - see `beginColorSampling`) so a ~7-8x magnified crop
    /// still looks sharp. Nil before the render resolves and whenever
    /// sampling isn't armed.
    private(set) var samplingComposite: UIImage?

    /// The in-flight composite render kicked off by `beginColorSampling`
    /// (Justin, 2026-07-27 - see its doc comment for the bug this closes).
    /// Tracked so a second `beginColorSampling()` can CANCEL a still-running
    /// prior render (rather than leaving two renders racing to write
    /// `samplingComposite`, where the OLDER one could theoretically resolve
    /// last and clobber the newer result with stale pixels), and so
    /// `applySampledColor` can `await` it when the user releases before the
    /// render has resolved, instead of silently failing.
    private var samplingRenderTask: Task<Void, Never>?

    /// Arms the eyedropper AND kicks off the one-time composite render the
    /// loupe magnifies from - called instead of setting `isSamplingColor`
    /// directly (see BorderTrayView's eyedropper button) so the render
    /// starts the instant the user commits to sampling, not on their first
    /// touch. The render itself reuses already-decoded in-memory proxies
    /// (no Photos re-decode), so in practice it resolves within a frame or
    /// two of arming.
    ///
    /// BUG FIX (Justin, 2026-07-27): "the eyedropper broke after one
    /// selection - it appears to work only once per editor session."
    /// Reproducing this on-device pointed at a race, not a state-reset bug:
    /// `applySampledColor` (below) read `samplingComposite` and, if it was
    /// still nil (the async render from THIS arm hadn't resolved yet -
    /// e.g. a quick tap-release, which naturally becomes more likely the
    /// SECOND time a user reaches for the eyedropper, once they already
    /// know the gesture and move faster than their first, exploratory
    /// drag), it silently gave up via `defer { endColorSampling() }`
    /// disarming with no color applied and no error of any kind - which
    /// reads exactly as "stopped working," and once it happens once, every
    /// later attempt that also beats the render is silently eaten the same
    /// way. `samplingComposite`/`isSamplingColor` themselves WERE being
    /// reset/rebuilt correctly on every arm, as this method's body already
    /// shows - the actual gap was that NOTHING waited for the rebuild before
    /// the release handler gave up on it. Fixed two ways: (1)
    /// `applySampledColor` now awaits the in-flight render (via
    /// `samplingRenderTask`) if the composite isn't ready the instant the
    /// user releases, instead of failing silently; (2) this method now
    /// cancels any still-running PRIOR render before starting a new one, so
    /// two renders can never race to write `samplingComposite` and a stale
    /// one can never clobber a fresh arm's result.
    func beginColorSampling() {
        samplingRenderTask?.cancel()
        isSamplingColor = true
        samplingComposite = nil
        let width = 900.0
        let aspect = canvasSize.height / max(canvasSize.width, 1)
        let exportSize = CGSize(width: width, height: (width * aspect).rounded())
        let proxies = images
        let doc = document
        samplingRenderTask = Task { [weak self] in
            let provider: CollageImageProvider = { id, _ in proxies[id]?.cgImage }
            let rendered = await CollageRenderer().renderForSampling(document: doc, exportSize: exportSize, imageProvider: provider)
            guard !Task.isCancelled else { return }
            self?.samplingComposite = rendered
        }
    }

    /// Disarms the eyedropper and releases the cached composite - called
    /// both by the hint capsule's explicit cancel and by
    /// `applySampledColor` once a color has been applied.
    func endColorSampling() {
        isSamplingColor = false
        samplingComposite = nil
        samplingRenderTask?.cancel()
        samplingRenderTask = nil
    }

    /// Reads the composited pixel at a normalized canvas point (0...1 in
    /// both axes) from the cached `samplingComposite` and applies it as the
    /// border color - the loupe's release action (and a plain tap, which is
    /// just a drag that never moved - see CanvasView's `loupeDragGesture`).
    /// A no-op (still disarms) if the composite hasn't resolved yet.
    /// `async` (Justin, 2026-07-27, was synchronous) so the release handler
    /// can wait out an in-flight composite render instead of racing it - see
    /// `beginColorSampling`'s bug-fix doc comment for the failure this
    /// closes. `samplingRenderTask` is read (not consumed) here since
    /// `endColorSampling()` in the `defer` below is what tears it down.
    func applySampledColor(atNormalized point: CGPoint) async {
        defer { endColorSampling() }
        if samplingComposite == nil {
            await samplingRenderTask?.value
        }
        guard let composite = samplingComposite, let rgba = Self.pixelColor(in: composite, atNormalized: point) else { return }
        setBorderColor(rgba)
        rememberSampledSwatch(rgba)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Recently-sampled swatches (Justin, 2026-07-27)

    /// The eyedropper's own picks, newest first, capped at 2 - shown in the
    /// swatch row alongside the fixed derived swatches so the user can
    /// toggle back and forth (e.g. between a fresh pick and white) without
    /// re-sampling. Session-only per the brief ("They live for the editor
    /// session ... no persistence needed") - a plain instance property, not
    /// backed by UserDefaults/DocumentStore, so it resets with a fresh
    /// EditorState same as `recentSampledSwatches`'s sibling session state
    /// elsewhere in this file.
    private(set) var recentSampledSwatches: [RGBA] = []

    /// Fuzzy equality for swatch dedupe - mirrors BorderTrayView's own
    /// `colorsMatch` (alpha isn't compared; every border swatch is fully
    /// opaque).
    private static func swatchesMatch(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }

    /// Inserts a freshly-sampled color at the front of `recentSampledSwatches`.
    /// Dedupes against the seven FIXED swatches (white/black/vibrant1-3/
    /// brightest/luminous) - those are already reachable elsewhere in the
    /// row, so a pick that lands on one of them contributes nothing new. A
    /// pick that matches something ALREADY in the recent list is bumped to
    /// the front (removed, then reinserted) rather than duplicated, so the
    /// row never shows two identical circles. Caps at 2 - the oldest falls
    /// off the end.
    private func rememberSampledSwatch(_ rgba: RGBA) {
        let fixed = [
            RGBA.white, RGBA(r: 0, g: 0, b: 0, a: 1),
            derivedSwatches.vibrant1, derivedSwatches.vibrant2, derivedSwatches.vibrant3,
            derivedSwatches.brightest, derivedSwatches.luminous,
        ]
        guard !fixed.contains(where: { Self.swatchesMatch($0, rgba) }) else { return }
        recentSampledSwatches.removeAll { Self.swatchesMatch($0, rgba) }
        recentSampledSwatches.insert(rgba, at: 0)
        if recentSampledSwatches.count > 2 { recentSampledSwatches.removeLast() }
    }

    /// Reads one pixel from `image` at a normalized position via a 1x1
    /// bitmap draw - no full-image byte buffer needed. Not `private`
    /// (Justin, 2026-07-26): CanvasView's loupe reuses this exact function
    /// on every touch-move to read the LIVE center-pixel color for the
    /// loupe's border ring, not just once on release.
    static func pixelColor(in image: UIImage, atNormalized p: CGPoint) -> RGBA? {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let x = min(max(Int(p.x * CGFloat(cg.width)), 0), cg.width - 1)
        let yTop = min(max(Int(p.y * CGFloat(cg.height)), 0), cg.height - 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        // The CGImage out of CollageRenderer's makeTopLeftContext already
        // carries that context's top-left flip, so the usual bottom-left
        // correction would double-flip (verified empirically in the
        // 2026-07-26 review pass: tree taps sampled the road). Translating
        // by the raw top-based y is what lands the tapped pixel on the
        // context's single pixel.
        ctx.draw(cg, in: CGRect(
            x: -CGFloat(x),
            y: -CGFloat(yTop),
            width: CGFloat(cg.width),
            height: CGFloat(cg.height)
        ))
        return RGBA(
            r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255,
            b: Double(pixel[2]) / 255, a: 1
        )
    }

    /// Corner radius is a pure paint-time property (Layout.swift's solver
    /// never reads it), so no reclamp is needed here.
    func setBorderRadius(_ fraction: Double) {
        var doc = document
        doc.border.cornerRadius = fraction
        document = doc
    }

    /// Swatch tap (including a color freshly picked from the system color
    /// picker): one undo snapshot, no reclamp needed (color is paint-only).
    /// Picked colors are applied directly and are NOT appended to the
    /// swatch row - there's no more persisted custom-swatch list.
    func setBorderColor(_ color: RGBA) {
        let old = document
        var doc = document
        doc.border.color = color
        document = doc
        pushUndo(old)
    }

    /// Three vibrant, hue-distinct colors sampled from every photo currently
    /// in the document, shown in the swatch row alongside plain white/black
    /// (Justin, 2026-07-26: "scan the photo and find the brightest, most
    /// vibrant colors"). Downsamples each proxy UIImage to ~64x64 and bins
    /// every qualifying pixel into one of `hueBucketCount` hue buckets
    /// (spanning ALL photos combined, not per-photo), where a pixel
    /// "qualifies" only if it's not near-black, near-white, or low-saturation
    /// - grays and shadows shouldn't be able to win a "vibrant" swatch just
    /// by being common. Each bucket's score is the sum of `saturation *
    /// brightness` across its qualifying pixels, so a hue wins both by being
    /// vivid and by covering real area in the photos. The top 3 scoring
    /// buckets that are at least ~30 degrees of hue apart become the
    /// swatches (most vibrant first); if the photos don't have 3 distinct
    /// vibrant hues, the remaining slots fall back to the next-best buckets
    /// even if their hues are close, so the row always has exactly 3
    /// swatches. Each winner's saturation/brightness is then clamped to a
    /// presentable border-color range (capped saturation, floored
    /// brightness) so the result never reads neon or muddy. Falls back to
    /// neutral grays if no photo has finished loading yet (`images` empty)
    /// or every pixel fails the vibrancy bar.
    ///
    /// A fourth, independently-scored "brightest" swatch is added on top of
    /// these three (Justin, 2026-07-26) - see `pickBrightestSwatch`'s doc
    /// comment for that pass in full.
    ///
    /// Per-hue-bucket accumulator for the "brightest" sixth swatch (Justin,
    /// 2026-07-26) - declared at class scope (rather than local to
    /// `computeSampledSwatches`) so `pickBrightestSwatch` below can take it
    /// as a parameter type.
    private struct BrightBucket {
        var sSum: Double = 0
        var vSum: Double = 0
        var count: Int = 0
    }

    private static func computeSampledSwatches(document: Document, images: [PhotoID: UIImage]) -> SampledBorderColors {
        let ids = photoIDs(in: document.root)

        let hueBucketCount = 30
        let hueBucketWidth = 360.0 / Double(hueBucketCount)

        // Vibrant-candidacy thresholds: a pixel below the saturation floor,
        // below the brightness floor, or above the brightness ceiling while
        // desaturated never contributes to any bucket's score.
        let minVibrantSaturation = 0.20
        let minVibrantBrightness = 0.15
        let nearWhiteBrightness = 0.95
        let nearWhiteSaturation = 0.10

        // Sixth swatch (Justin, 2026-07-26): "brightest" is scored on an
        // entirely separate pass over the same pixels - a lower, standalone
        // saturation floor (0.15 vs. vibrant's 0.20) so it can pick up
        // brighter-but-less-punchy content the vibrancy pass would reject,
        // while still keeping true near-white/gray pixels (saturation ~0)
        // from winning. See `pickBrightestSwatch` for the scoring/fallback.
        let minBrightSaturation = 0.15
        // Seventh swatch (Justin, 2026-07-26): "luminous" runs a third pass
        // with an even lower floor - pale-but-glowing content (bright sky,
        // sunlit haze) qualifies here that both passes above reject.
        let minLuminousSaturation = 0.08

        struct HueBucket {
            var sSum: Double = 0
            var vSum: Double = 0
            var count: Int = 0
            var score: Double = 0   // sum of saturation * brightness
        }

        var buckets = [HueBucket](repeating: HueBucket(), count: hueBucketCount)
        var brightBuckets = [BrightBucket](repeating: BrightBucket(), count: hueBucketCount)
        var lumBuckets = [BrightBucket](repeating: BrightBucket(), count: hueBucketCount)
        var qualifyingCount = 0

        for id in ids {
            guard let image = images[id] else { continue }
            for pixel in downsampledPixels(of: image, dimension: 64) {
                guard pixel.a > 0 else { continue }
                let (h, s, v) = rgbToHSV(r: pixel.r, g: pixel.g, b: pixel.b)
                let index = min(hueBucketCount - 1, Int(h / hueBucketWidth))

                if s >= minBrightSaturation {
                    brightBuckets[index].sSum += s
                    brightBuckets[index].vSum += v
                    brightBuckets[index].count += 1
                }

                if s >= minLuminousSaturation, !(v >= nearWhiteBrightness && s < nearWhiteSaturation) {
                    lumBuckets[index].sSum += s
                    lumBuckets[index].vSum += v
                    lumBuckets[index].count += 1
                }

                guard v >= minVibrantBrightness,
                      s >= minVibrantSaturation,
                      !(v >= nearWhiteBrightness && s < nearWhiteSaturation)
                else { continue }

                buckets[index].sSum += s
                buckets[index].vSum += v
                buckets[index].count += 1
                buckets[index].score += s * v
                qualifyingCount += 1
            }
        }

        // Border colors should be presentable, never neon or muddy: cap
        // saturation and floor brightness before converting back to RGB.
        // Shared by both the vibrant candidates below and the brightest
        // swatch (`pickBrightestSwatch`) per the task brief's "same clamps".
        let saturationCeiling = 0.85
        let brightnessFloor = 0.35

        guard qualifyingCount > 0 else {
            // No photo cleared the vibrancy bar at all - vibrant1-3 fall
            // back to neutral grays, but the brightest pass ran independently
            // above and may still have a real answer (e.g. photos that are
            // bright and mildly saturated throughout, never hitting
            // vibrant's stricter 0.20 floor).
            var fallback = SampledBorderColors.fallback
            fallback.brightest = pickBrightestSwatch(
                brightBuckets: brightBuckets,
                hueBucketWidth: hueBucketWidth,
                excludingHues: [],
                saturationCeiling: saturationCeiling,
                brightnessFloor: brightnessFloor
            )
            fallback.luminous = pickBrightestSwatch(
                brightBuckets: lumBuckets,
                hueBucketWidth: hueBucketWidth,
                excludingHues: hueOf(fallback.brightest).map { [$0] } ?? [],
                saturationCeiling: 1.0,
                brightnessFloor: brightnessFloor
            )
            return fallback
        }

        func hueDistance(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }

        struct Candidate {
            let hue: Double
            let rgba: RGBA
        }

        let candidates: [Candidate] = buckets.enumerated()
            .compactMap { index, bucket -> (Candidate, Double)? in
                guard bucket.count > 0 else { return nil }
                let hue = (Double(index) + 0.5) * hueBucketWidth
                let s = min(bucket.sSum / Double(bucket.count), saturationCeiling)
                let v = max(bucket.vSum / Double(bucket.count), brightnessFloor)
                return (Candidate(hue: hue, rgba: hsvToRGB(h: hue, s: s, v: v)), bucket.score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        guard !candidates.isEmpty else {
            var fallback = SampledBorderColors.fallback
            fallback.brightest = pickBrightestSwatch(
                brightBuckets: brightBuckets,
                hueBucketWidth: hueBucketWidth,
                excludingHues: [],
                saturationCeiling: saturationCeiling,
                brightnessFloor: brightnessFloor
            )
            fallback.luminous = pickBrightestSwatch(
                brightBuckets: lumBuckets,
                hueBucketWidth: hueBucketWidth,
                excludingHues: hueOf(fallback.brightest).map { [$0] } ?? [],
                saturationCeiling: 1.0,
                brightnessFloor: brightnessFloor
            )
            return fallback
        }

        // Greedily take the 3 best hue-distinct winners (>= 30 degrees
        // apart); pad any remaining slots with the next-best candidates
        // regardless of hue proximity so the row is always exactly 3.
        var chosen: [Candidate] = []
        for candidate in candidates where chosen.count < 3 {
            if chosen.allSatisfy({ hueDistance($0.hue, candidate.hue) >= 30 }) {
                chosen.append(candidate)
            }
        }
        for candidate in candidates where chosen.count < 3 {
            if !chosen.contains(where: { $0.hue == candidate.hue }) {
                chosen.append(candidate)
            }
        }
        while chosen.count < 3, let best = candidates.first {
            chosen.append(best)
        }

        let brightest = pickBrightestSwatch(
            brightBuckets: brightBuckets,
            hueBucketWidth: hueBucketWidth,
            excludingHues: chosen.map(\.hue),
            saturationCeiling: saturationCeiling,
            brightnessFloor: brightnessFloor
        )

        // Seventh swatch: peak brightness, no saturation cap (ceiling 1.0),
        // hue-distinct from all four derived slots above when possible - the
        // shared relaxation ladder in pickBrightestSwatch handles convergent
        // photo sets.
        let luminous = pickBrightestSwatch(
            brightBuckets: lumBuckets,
            hueBucketWidth: hueBucketWidth,
            excludingHues: chosen.map(\.hue) + (hueOf(brightest).map { [$0] } ?? []),
            saturationCeiling: 1.0,
            brightnessFloor: brightnessFloor
        )

        return SampledBorderColors(vibrant1: chosen[0].rgba, vibrant2: chosen[1].rgba, vibrant3: chosen[2].rgba, brightest: brightest, luminous: luminous)
    }

    /// Sixth swatch (Justin, 2026-07-26): "brightest" - the brightest sampled
    /// color across all photos combined, hue-bucketed the same way as the
    /// vibrancy pass above but scored purely by brightness: `meanBrightness *
    /// log(count + 1)`, so a bucket needs real photo coverage (not just one
    /// stray bright pixel) to win - a single hot highlight pixel scores
    /// `v * log(2) ≈ 0.69v`, while a bucket covering 50 pixels at the same
    /// mean brightness scores `v * log(51) ≈ 3.93v`, roughly 5.7x higher.
    /// REQUIRED to read as visually distinct from the three vibrant
    /// swatches: >= 30 degrees of hue from EACH of them. If nothing clears
    /// that bar, the constraint relaxes in steps (20, then 10, then any
    /// distance) rather than silently hand back a near-duplicate of an
    /// existing swatch - the final (any-distance) rung can still land on the
    /// same hue as a vibrant swatch in a genuinely single-hue photo set, but
    /// even then the two differ in saturation/brightness (this pass floors
    /// brightness higher in practice, since it's scored on brightness), so
    /// they read as different swatches rather than exact duplicates.
    /// Hue of an already-picked swatch, for hue-distinctness excludes in
    /// later passes. Nil for effectively-neutral colors (their hue is
    /// numerically arbitrary and shouldn't veto anything).
    private static func hueOf(_ rgba: RGBA) -> Double? {
        let (h, s, _) = rgbToHSV(r: rgba.r, g: rgba.g, b: rgba.b)
        return s < 0.05 ? nil : h
    }

    private static func pickBrightestSwatch(
        brightBuckets: [BrightBucket],
        hueBucketWidth: Double,
        excludingHues: [Double],
        saturationCeiling: Double,
        brightnessFloor: Double
    ) -> RGBA {
        struct BrightCandidate {
            let hue: Double
            let score: Double
            let rgba: RGBA
        }

        func hueDistance(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }

        let candidates: [BrightCandidate] = brightBuckets.enumerated()
            .compactMap { index, bucket -> BrightCandidate? in
                guard bucket.count > 0 else { return nil }
                let hue = (Double(index) + 0.5) * hueBucketWidth
                let meanS = bucket.sSum / Double(bucket.count)
                let meanV = bucket.vSum / Double(bucket.count)
                let score = meanV * log(Double(bucket.count) + 1)
                let s = min(meanS, saturationCeiling)
                let v = max(meanV, brightnessFloor)
                return BrightCandidate(hue: hue, score: score, rgba: hsvToRGB(h: hue, s: s, v: v))
            }
            .sorted { $0.score > $1.score }

        // No photo had a single pixel above the brightest pass's saturation
        // floor (e.g. a fully grayscale set) - fall back to a light neutral
        // rather than collapse the swatch row down to 5 entries.
        guard !candidates.isEmpty else {
            return RGBA(r: 0.92, g: 0.92, b: 0.92, a: 1)
        }

        for threshold in [30.0, 20.0, 10.0, 0.0] {
            if let match = candidates.first(where: { candidate in
                excludingHues.allSatisfy { hueDistance($0, candidate.hue) >= threshold }
            }) {
                return match.rgba
            }
        }

        // Unreachable - the 0-degree rung above always matches the
        // top-scoring candidate - kept only for exhaustiveness.
        return candidates[0].rgba
    }

    /// Draws `image` into a `dimension`x`dimension` RGBA bitmap (ignoring
    /// aspect - this is a color histogram sample, not a faithful crop) and
    /// returns its opaque-or-translucent pixels as normalized 0...1 floats.
    private static func downsampledPixels(of image: UIImage, dimension: Int) -> [(r: Double, g: Double, b: Double, a: Double)] {
        guard let cgImage = image.cgImage else { return [] }
        var pixelData = [UInt8](repeating: 0, count: dimension * dimension * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        var result: [(r: Double, g: Double, b: Double, a: Double)] = []
        result.reserveCapacity(dimension * dimension)
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let a = Double(pixelData[i + 3]) / 255.0
            guard a > 0 else { continue }
            result.append((
                r: Double(pixelData[i]) / 255.0,
                g: Double(pixelData[i + 1]) / 255.0,
                b: Double(pixelData[i + 2]) / 255.0,
                a: a
            ))
        }
        return result
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let v = maxV
        let s = maxV == 0 ? 0 : delta / maxV
        guard delta > 0 else { return (0, s, v) }
        var h: Double
        if maxV == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, v)
    }

    /// Inverse of `rgbToHSV`, used to turn a hue bucket's winning
    /// (hue, saturation, brightness) back into a displayable RGBA swatch.
    /// `h` is expected in 0..<360.
    private static func hsvToRGB(h: Double, s: Double, v: Double) -> RGBA {
        let c = v * s
        let hPrime = h / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        let base: (r: Double, g: Double, b: Double)
        switch hPrime {
        case 0..<1: base = (c, x, 0)
        case 1..<2: base = (x, c, 0)
        case 2..<3: base = (0, c, x)
        case 3..<4: base = (0, x, c)
        case 4..<5: base = (x, 0, c)
        default:    base = (c, 0, x)
        }

        return RGBA(r: base.r + m, g: base.g + m, b: base.b + m, a: 1)
    }

    // MARK: - Photo toolbar actions (Phase 4)

    /// Mirrors the visible crop IN PLACE: `center` is stored in effective
    /// displayed space, so mirroring the content must mirror the crop point
    /// with it (cx -> 1-cx) or the cell would jump to showing the
    /// mirror-image region of the photo. Symmetric, so the clamp invariant
    /// is preserved without a reclamp.
    func flipH() {
        guard let sel = selection, var photo = document.photos[sel] else { return }
        photo.flipH.toggle()
        photo.center.x = 1 - photo.center.x
        let old = document
        var doc = document
        doc.photos[sel] = photo
        document = doc
        pushUndo(old)
    }

    func flipV() {
        guard let sel = selection, var photo = document.photos[sel] else { return }
        photo.flipV.toggle()
        photo.center.y = 1 - photo.center.y
        let old = document
        var doc = document
        doc.photos[sel] = photo
        document = doc
        pushUndo(old)
    }

    /// `clampedCenter` handles odd turns via the effective (rotated) size,
    /// so a reclamp after rotating is what keeps the crop legal.
    func rotate() {
        guard let sel = selection, var photo = document.photos[sel] else { return }
        photo.quarterTurns = (photo.quarterTurns + 1) % 4
        // Rotate the crop point with the content (90 CW in displayed
        // space: (x, y) -> (1-y, x)) so the same visible region stays
        // centered, just turned. reclampAll below re-covers the cell.
        photo.center = CGPoint(x: 1 - photo.center.y, y: photo.center.x)
        var doc = document
        doc.photos[sel] = photo
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        document = doc
        pushUndo(old)
    }

    /// Guarded by the caller-visible `canRemoveSelection` (>= 2 photo floor
    /// -  the button renders disabled at exactly 2, per the PRD). Uses the
    /// EditOps.swift `removeLeaf(_:from:)` overload (not
    /// Operations.swift's labeled one) so an unexpected "id not in the
    /// tree" case is nil rather than a silent no-op.
    var canRemoveSelection: Bool {
        selection != nil && document.photos.count > 2
    }

    func remove() {
        guard let sel = selection, document.photos.count > 2 else { return }
        guard let newRoot = removeLeaf(sel, from: document.root) else { return }

        var doc = document
        doc.root = newRoot
        doc.photos.removeValue(forKey: sel)
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        document = doc
        selection = nil
        pushUndo(old)
        // The Layout tray reads `photoIDs(in: document.root)` /
        // `templates(for:)` live each render, so it automatically reflects
        // the new (smaller) photo count's template list - no extra
        // bookkeeping needed here.
    }

    /// Replace: swaps in a freshly-picked asset for an EXISTING PhotoID (the
    /// tree is untouched - same leaf, same cell). Auto-frames against that
    /// photo's CURRENT cell size (solved from the live document), reuses the
    /// same PhotoID so undo/redo and the tree stay simple, resets flips/
    /// rotation, and sets `isAuto` per whether a ROI was found (mirroring
    /// the picker's own pick-completion flow in PickerView.swift).
    ///
    /// NOTE: undo restores the `Document`, which is the source of truth for
    /// which asset/pixel-size/crop is current; `images[photoID]` also keeps
    /// the OLD UIImage around after a redo-away-from / undo-back-to this
    /// point would want it, but since we never delete entries from
    /// `images`, the old bitmap is simply never looked at again once the
    /// document stops referencing it as "the newer content" - harmless,
    /// matches the brief's own note.
    @MainActor
    func replace(photoID: PhotoID, image: UIImage, pixelSize: CGSize, assetLocalIdentifier: String?) async {
        guard var photo = document.photos[photoID] else { return }

        let (cells, _) = solve(root: document.root, canvasSize: canvasSize, border: document.border)
        let cellSize = cells.first(where: { $0.id == photoID })?.rect.size ?? canvasSize

        var roi: ROI?
        if let cgImage = image.cgImage {
            let vision = await PhotoLibraryService().visionInputs(cgImage: cgImage)
            let input = AutoFrameInput(
                faces: vision.faces.map(\.0),
                faceConfidences: vision.faces.map(\.1),
                salientRegion: vision.salient,
                photoPixelSize: pixelSize,
                cellSize: cellSize
            )
            roi = autoFrame(input)
        }

        photo.assetLocalIdentifier = assetLocalIdentifier ?? photo.assetLocalIdentifier
        photo.pixelWidth = Int(pixelSize.width)
        photo.pixelHeight = Int(pixelSize.height)
        photo.zoom = roi?.zoom ?? 1.0
        photo.center = roi?.center ?? CGPoint(x: 0.5, y: 0.5)
        photo.flipH = false
        photo.flipV = false
        photo.quarterTurns = 0
        photo.isAuto = roi != nil
        photo.roi = roi

        updateImage(photoID, image: image)
        // The replaced asset is a fresh pick, so this id is no longer
        // "unavailable" even if it was before (PRD: "Replace on that photo
        // clears it from the set").
        unavailablePhotoIDs.remove(photoID)

        var doc = document
        doc.photos[photoID] = photo
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        document = doc
        pushUndo(old)
    }

    /// Also used by the restore flow (ContentView) to fill in `images`
    /// progressively as each photo's proxy/asset finishes loading - not just
    /// by `replace(...)`. Schedules an autosave so a freshly-loaded
    /// PHPicker-fallback proxy gets written to its sidecar file promptly.
    func updateImage(_ id: PhotoID, image: UIImage) {
        images[id] = image
        scheduleAutosave()
    }

    // MARK: - Auto-frame toggle

    /// Toggles the selected photo between its cached auto-frame ROI and a
    /// plain center/fill crop. One undo snapshot per toggle.
    func toggleAuto() {
        guard let sel = selection, let photo = document.photos[sel] else { return }

        var updated = photo
        if photo.isAuto {
            updated.center = CGPoint(x: 0.5, y: 0.5)
            updated.zoom = 1.0
            updated.isAuto = false
        } else if let roi = photo.roi {
            updated.center = roi.center
            updated.zoom = roi.zoom
            updated.isAuto = true
        } else {
            updated.center = CGPoint(x: 0.5, y: 0.5)
            updated.zoom = 1.0
            updated.isAuto = false
        }

        var doc = document
        doc.photos[sel] = updated
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        document = doc
        pushUndo(old)
    }
}

/// Live swap-drag overlay state. `sourceID`/`sourceCellRect` are fixed for
/// the duration of the drag; `fingerLocation` and `hoveredTargetID` update
/// on every move.
struct SwapState {
    let sourceID: PhotoID
    let sourceCellRect: CGRect
    var fingerLocation: CGPoint
    var hoveredTargetID: PhotoID?
}

/// The Border tray's three sampled swatches (see
/// `EditorState.computeSampledSwatches`), ranked most to least vibrant.
/// `.fallback` is neutral grays, used before any photo has finished loading
/// (e.g. mid-restore) so the swatch row always renders exactly 3 sampled
/// circles.
struct SampledBorderColors: Equatable {
    var vibrant1: RGBA
    var vibrant2: RGBA
    var vibrant3: RGBA
    /// Sixth swatch (Justin, 2026-07-26): the brightest sampled color,
    /// distinct in hue from the three vibrant swatches above whenever a
    /// qualifying bucket allows it - see `EditorState.pickBrightestSwatch`'s
    /// doc comment for the exact scoring and the fallback ladder used when
    /// no such candidate exists.
    var brightest: RGBA
    /// Seventh swatch (Justin, 2026-07-26): "luminous" - the peak-brightness
    /// color. Same scoring machinery as `brightest` but with a much lower
    /// saturation floor (0.08) and NO saturation cap on output, so a blazing
    /// sky blue or bright yellow can win here even when the stricter
    /// `brightest` pass settled on something punchier. Distinct in hue from
    /// all four derived slots above when the photos allow it.
    var luminous: RGBA

    static let fallback = SampledBorderColors(
        vibrant1: RGBA(r: 0.85, g: 0.85, b: 0.85, a: 1),
        vibrant2: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1),
        vibrant3: RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1),
        brightest: RGBA(r: 0.95, g: 0.95, b: 0.95, a: 1),
        luminous: RGBA(r: 0.75, g: 0.78, b: 0.85, a: 1)
    )
}
