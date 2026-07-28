// Sources/App/MagicLayout/MagicLayoutOverlay.swift
// B32 "Magic Layout", PHASE 0 (see `Magic Layout Spec.md` at the project
// root): the picker-to-editor cut, dramatized. Four chosen photos fly out of
// the picker grid as raw square thumbnails, the real Vision face boxes light
// up on them, and they morph into the cells of the layout the app ACTUALLY
// chose - which in Phase 0 is still the existing aspect-based decision
// (`defaultTemplateIndex` + `contentFitAssignment`), unchanged. No algorithm
// work here at all: this phase exists purely to test whether the theater
// lands before Phase 1's real face-aware decision gets built.
//
// ARCHITECTURE (decided in the spec, not re-litigated here): the sequence is
// hosted by a full-screen overlay owned by `ContentView`, above BOTH the
// picker and the editor. The picker owns the source geometry but is torn
// down at handoff; the editor owns the destination geometry but doesn't
// exist until `commitNewCollage` runs; only `ContentView` outlives both. So
// this file owns:
//
//   1. `PickedThumbFramesKey`   - the picker grid publishing each SELECTED
//                                 thumbnail's frame in global coordinates.
//   2. `EditorCanvasFrameKey`   - the editor's canvas rect, same space, so
//                                 destination cell rects are the REAL ones
//                                 (`solve()` against the live canvas size)
//                                 rather than a re-derived guess.
//   3. `MagicLayoutController`  - the beat machine (arrive / scan / assemble
//                                 / settle), the skip catcher, the Reduce
//                                 Motion bypass, and the degradation rule.
//   4. `MagicLayoutOverlay`     - the presentation.
//
// TIMING CONTRACT: the sequence starts the instant the user taps Next, NOT
// when the document is finished - it runs OVER the same `loadForEditing` +
// Vision work that today hides behind `PickerView.loadingOverlay`'s spinner.
// That overlap is the whole reason the added wall clock can stay small: the
// arrive and scan beats are spent on work that was always happening. The
// scan beat cuts short the moment the document is ready (never hold purely
// for show) and stretches, unbounded, when the work genuinely takes longer.
import SwiftUI
import UIKit

// MARK: - Geometry export: picker grid -> overlay

/// Each SELECTED grid thumbnail's frame in GLOBAL (window) coordinates, keyed
/// by the asset's `localIdentifier`. Published by `GridThumbnail` (see
/// PickerView.swift) and read by `PickerView`'s `.onPreferenceChange`, which
/// parks it on `PickerState` so the frames survive into the confirm handler.
///
/// The spec points at `CanvasView.coachMarkAnchorMarkers` as the precedent,
/// and its hard-won rule applies to any anchor-based export: `anchorPreference`
/// must attach to the SIZED child BEFORE `.position`, never after, or the
/// published rect is the parent's full bounds instead of the target's (the
/// giant-spotlight bug). This key sidesteps that class of bug entirely by
/// publishing a resolved global rect rather than an `Anchor<CGRect>`:
/// `GridThumbnail` already owns a `GeometryReader` sized to exactly the square
/// cell and there is no `.position`/transform anywhere in its chain, so
/// `geo.frame(in: .global)` IS the thumbnail's true on-screen rect. It also
/// re-resolves on every scroll frame (a `GeometryReader` re-evaluates when its
/// geometry changes, where an `Anchor` token would not force the reading
/// closure to re-run), which matters here because the frames are consumed at
/// confirm time - potentially long after selection - and must not be stale.
struct PickedThumbFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The editor canvas's rect in GLOBAL (window) coordinates - the destination
/// geometry half of the morph. Published by `CanvasView` from the same
/// `GeometryReader` that centers the canvas, so it is exactly the rect
/// `canvasContent` is drawn into: cell rects from `solve(root:canvasSize:
/// border:)` offset by this rect's origin land pixel-for-pixel on the cells
/// the editor itself renders, which is what makes the final crossfade
/// invisible.
struct EditorCanvasFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

// MARK: - Inputs

/// One selected thumbnail as the picker knew it: where it sat on screen and
/// the (already-decoded, already-on-screen) thumbnail bitmap. Available at
/// Next-tap time, which is what lets the sequence start before any
/// full-resolution proxy has loaded.
struct MagicSource: Equatable {
    let assetID: String
    let rect: CGRect
    let image: UIImage?
}

/// Everything `PickerView.buildDocument` learned, handed forward intact.
/// Today's pipeline discards the raw face rects the moment `autoFrame` has
/// distilled them into an `ROI`; the box-reveal beat needs the originals, so
/// they ride along here (normalized to photo space, TOP-LEFT origin, y down -
/// the Engine's convention, already converted from Vision's bottom-left by
/// `PhotoLibraryService.visionInputs`).
struct PickCompletion {
    var document: Document
    var images: [PhotoID: UIImage]
    /// Document leaf/creation order, used to pair photos with picker
    /// thumbnails when there is no asset identifier to match on (the
    /// PHPicker-fallback path produces no `PHAsset`).
    var orderedPhotoIDs: [PhotoID]
    var assetIDByPhotoID: [PhotoID: String]
    /// Only faces that SURVIVE the same thresholds `AutoFrame.swift` applies
    /// (confidence >= 0.5, height >= 8% of the photo's short edge) - the
    /// boxes must be genuinely what the framing decision used, not every
    /// speculative detection.
    var faceRectsByPhotoID: [PhotoID: [CGRect]]
}

// MARK: - Render model

/// One photo's whole journey, resolved once when the document lands: where it
/// started (the picker thumbnail's square), where it is going (its real cell),
/// and - critically - the CROP at each end.
///
/// Animating the crop, not just the frame, is the point (spec, Phase 3 beat
/// 3): a picker thumbnail is a square aspect-FILL center crop (zoom 1.0,
/// center 0.5/0.5 against a square cell) while the destination cell is some
/// other aspect with the zoom/center `autoFrame` chose. A frame-only morph
/// would slide the square into place and then visibly JUMP as the real crop
/// snapped in. Interpolating `(rect, zoom, center)` together and re-deriving
/// the fill scale every frame means the crop is continuously correct - the
/// photo pans and zooms into its framing as it flies.
struct MagicPhotoPlan: Identifiable {
    let id: PhotoID
    let image: UIImage
    let pixelSize: CGSize
    let sourceRect: CGRect
    var destRect: CGRect
    var destZoom: Double
    var destCenter: CGPoint
    /// Normalized to photo space, top-left origin.
    var faces: [CGRect]
}

// MARK: - Controller

/// The beat machine. Owned by `ContentView`, driven by three events:
/// `begin(sources:)` (Next tapped), `documentReady(_:)` (the real work
/// finished and the editor has been mounted underneath), and
/// `canvasFrameChanged(_:)` (the editor published its canvas rect).
@MainActor
@Observable
final class MagicLayoutController {

    enum Beat: Equatable {
        /// Nothing on screen - the overlay isn't mounted at all.
        case idle
        /// ~250ms: thumbnails appear at their picker positions, everything
        /// else dims.
        case arrive
        /// Tied to the real work, visuals capped at ~700ms: a sweep crosses
        /// the photos and the real face boxes light up as they are found.
        case scan
        /// ~700ms: the morph - frame AND crop - into the chosen cells.
        case assemble
        /// ~250ms: boxes fade, crossfade onto the editor underneath.
        case settle
    }

    /// `-magicSlow N` (DEBUG, verification only - same family as `-uiState`
    /// and `-autoSave`): stretches every beat by N so a simctl-driven touch
    /// can actually land INSIDE the sequence. The whole thing runs in ~1.5s,
    /// which is shorter than a scripted tap's round trip, so without this
    /// there is no way to verify the skip path with a genuine touch through
    /// the real gesture recognizer rather than by calling `skip()` directly.
    /// Never 1 outside DEBUG.
    private static let timeScale: Double = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-magicSlow"), i + 1 < args.count, let n = Double(args[i + 1]), n > 0 {
            return n
        }
        #endif
        return 1
    }()

    // Beat timings, in seconds - the spec's Phase 3 numbers, used verbatim
    // for Phase 0 so the judgment is about the same choreography that ships.
    private static let arriveDuration = 0.25
    /// Floor on the scan beat: below this the box reveal is a subliminal
    /// flicker rather than a beat. Only ever costs time when the document was
    /// ready almost instantly.
    private static let scanFloor = 0.38
    /// The spec's cap on the scan VISUALS. The beat itself can run longer
    /// than this when the work genuinely takes longer (the sweep just keeps
    /// going) - what's capped is how long we'd ever wait on our own account.
    private static let scanCap = 0.70
    private static let assembleDuration = 0.70
    private static let settleDuration = 0.25

    private(set) var beat: Beat = .idle
    var isActive: Bool { beat != .idle }

    /// Animated 0...1: how far the photos have travelled from their picker
    /// squares to their cells, crop and all. Driven by `withAnimation` and
    /// consumed by `MorphingPhotoView`'s `animatableData`.
    private(set) var morphProgress: Double = 0
    /// Backdrop dim. Deliberately near-opaque once arrived: the picker is
    /// swapped out for the editor UNDERNEATH this overlay partway through the
    /// scan beat, and a light scrim would show that swap happening.
    private(set) var scrim: Double = 0
    private(set) var overlayOpacity: Double = 0
    /// 0...1 sweep position for the scan beat's travelling band.
    private(set) var sweep: Double = 0
    /// How many photos have had their boxes lit so far (staggered reveal).
    private(set) var revealedBoxes = 0
    /// False whenever detection is too weak to be worth advertising - see
    /// `shouldRevealBoxes`. Never advertise a miss.
    private(set) var boxesEnabled = false

    private(set) var photos: [MagicPhotoPlan] = []
    /// True once the user has touched the overlay: the sequence is abandoned
    /// and we land on the finished editor as fast as it exists.
    private(set) var didSkip = false
    /// The one case where the overlay still shows chrome of its own: the user
    /// skipped before the document was ready, so there is no editor to land
    /// on yet. Falls back to exactly today's spinner until there is.
    var showsFallbackSpinner: Bool { didSkip && completion == nil }

    private var sources: [MagicSource] = []
    private var completion: PickCompletion?
    private var canvasRect: CGRect = .zero
    private var task: Task<Void, Never>?

    /// Reduce Motion cuts straight through (spec: "Reduce Motion cuts
    /// straight through", matching the ghost demo's own handling): the caller
    /// gets `false`, keeps its existing spinner, and commits the document the
    /// moment it exists, exactly as before this feature existed.
    ///
    /// `-magicLayoutOff` (DEBUG) forces the same bypass, which is how the
    /// baseline "today's spinner path" wall clock is measured against the
    /// identical build.
    static var isDisabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-magicLayoutOff") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    /// Starts the sequence. Returns false when the sequence is bypassed
    /// (Reduce Motion / `-magicLayoutOff`), in which case the caller must
    /// keep its old spinner-and-commit behavior.
    @discardableResult
    func begin(sources: [MagicSource]) -> Bool {
        guard !isActive else { return true }
        guard !Self.isDisabled else {
            MagicTiming.mark("sequence bypassed (Reduce Motion / -magicLayoutOff)")
            return false
        }

        self.sources = sources
        completion = nil
        canvasRect = .zero
        photos = []
        didSkip = false
        revealedBoxes = 0
        boxesEnabled = false
        morphProgress = 0
        sweep = 0
        scrim = 0
        overlayOpacity = 0
        beat = .arrive
        seedPlansFromSources()

        task = Task { await run() }
        return true
    }

    /// The arrive and scan beats happen BEFORE any document exists, so they
    /// have to be drawn from the picker's own thumbnails - the whole point of
    /// carrying `MagicSource.image` at all. Without this the overlay rendered
    /// nothing at all until `documentReady` landed, which on a slow pick is a
    /// black screen for the entire duration of the work (caught in the
    /// simulator capture, where CPU-path Vision made that gap 1.7s long).
    ///
    /// Destination == source here, so if anything ever tried to morph these
    /// they would simply hold still. `rebuildPlans` swaps them for the real
    /// plans the moment the document lands; because both draw the same photo
    /// at the same rect with the same square aspect-fill crop, the swap from
    /// thumbnail bitmap to full proxy is invisible.
    private func seedPlansFromSources() {
        photos = sources.compactMap { source in
            guard let image = source.image else { return nil }
            let pixelSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? image.size
            guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
            return MagicPhotoPlan(
                id: PhotoID(),
                image: image,
                pixelSize: pixelSize,
                sourceRect: source.rect,
                destRect: source.rect,
                destZoom: 1,
                destCenter: CGPoint(x: 0.5, y: 0.5),
                faces: []
            )
        }
    }

    /// The real work finished. The caller must have ALREADY mounted the
    /// editor (spec: "the overlay runs while `commitNewCollage` mounts the
    /// editor underneath it"), so that by the time the assemble beat needs
    /// destination geometry, `canvasFrameChanged` has delivered it.
    func documentReady(_ result: PickCompletion) {
        MagicTiming.mark("document ready + editor mounted")
        completion = result
        guard isActive else { return }
        rebuildPlans()
    }

    func canvasFrameChanged(_ rect: CGRect) {
        guard rect != canvasRect else { return }
        canvasRect = rect
        // Only re-solve while the destination is still ahead of us; a canvas
        // resize mid-settle (e.g. the layout tray finishing its layout pass)
        // must not yank the photos out from under a finished morph.
        if beat == .scan || beat == .arrive { rebuildPlans() }
    }

    /// Any touch jumps to the end state (spec, non-negotiable: "the final
    /// layout must be usable the instant it exists"). If the document is
    /// already in hand the editor is complete underneath us and we simply
    /// stop drawing; if it isn't, we degrade to today's spinner and vanish
    /// the moment it lands.
    func skip() {
        guard isActive, !didSkip else { return }
        didSkip = true
        task?.cancel()
        task = nil
        MagicTiming.mark("skipped by touch")
        if completion != nil {
            finish()
        } else {
            // Nothing to land on yet: hold the spinner, and `documentReady`'s
            // caller ends us by mounting the editor - see `finishIfSkipped`.
            beat = .scan
            scrim = 1
            overlayOpacity = 1
        }
    }

    /// Called by the host right after it mounts the editor, to close out a
    /// skip that happened while the work was still running.
    func finishIfSkipped() {
        guard didSkip else { return }
        finish()
    }

    private func finish() {
        task?.cancel()
        task = nil
        beat = .idle
        overlayOpacity = 0
        scrim = 0
        photos = []
        sources = []
        MagicTiming.mark("overlay done (editor visible)")
    }

    // MARK: - The sequence

    private func run() async {
        // BEAT 1 - ARRIVE. The thumbnails appear exactly where they already
        // are in the picker grid, and everything else dims AROUND them.
        //
        // `overlayOpacity` snaps to 1 with no animation while only the scrim
        // animates up: fading the two together made the chosen photos dim
        // along with everything else, which is the exact opposite of the
        // beat (caught in the first simulator capture). Snapping is invisible
        // because the overlay's photos are drawn at precisely the picker
        // thumbnails' own rects and crops - the only thing that changes on
        // that first frame is that the selection vignette and pick-order
        // number drop away, which reads as the chosen photos shedding their
        // picker chrome.
        overlayOpacity = 1
        withAnimation(.easeOut(duration: Self.scaled(Self.arriveDuration))) {
            scrim = 1
        }
        await sleep(Self.arriveDuration)
        guard !Task.isCancelled else { return }

        // BEAT 2 - SCAN. Tied to the real work: the sweep starts now and
        // keeps travelling for as long as `buildDocument` takes. The only
        // time WE add is the floor below, and only when the work beat us to
        // it.
        beat = .scan
        withAnimation(.linear(duration: Self.scaled(0.9)).repeatForever(autoreverses: false)) {
            sweep = 1
        }
        let scanStart = CFAbsoluteTimeGetCurrent()
        while completion == nil && !Task.isCancelled {
            await sleep(0.016)
        }
        guard !Task.isCancelled else { return }

        // Real boxes on real detections, staggered so they read as "found,
        // then found, then found" rather than appearing as one block. Skipped
        // wholesale when detection is weak (never advertise a miss).
        if boxesEnabled {
            let stagger = min(0.09, Self.scanCap / Double(max(photos.count, 1)) / 2)
            for _ in photos.indices {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: Self.scaled(0.18))) { revealedBoxes += 1 }
                await sleep(stagger)
            }
        }
        // The floor, measured from the START of the scan beat, so slow work
        // pays nothing for it.
        let elapsed = CFAbsoluteTimeGetCurrent() - scanStart
        if elapsed < Self.scanFloor {
            await sleep(Self.scanFloor - elapsed)
        }
        guard !Task.isCancelled else { return }

        // The editor mounted during the scan; give its canvas rect a couple
        // of frames to arrive if it somehow hasn't (capped - a missing rect
        // falls back to the source rect, i.e. no morph, rather than hanging).
        var waited = 0.0
        while canvasRect == .zero && waited < 0.25 && !Task.isCancelled {
            await sleep(0.016)
            waited += 0.016
        }
        rebuildPlans()
        guard !Task.isCancelled else { return }

        // BEAT 3 - ASSEMBLE. Frame AND crop, together (see `MagicPhotoPlan`).
        // A decelerating curve with no overshoot: a spring's overshoot would
        // push the interpolated zoom past its clamped destination for a few
        // frames, which can briefly expose a cell edge.
        beat = .assemble
        withAnimation(.timingCurve(0.22, 0.68, 0.16, 1, duration: Self.scaled(Self.assembleDuration))) {
            morphProgress = 1
        }
        await sleep(Self.assembleDuration)
        guard !Task.isCancelled else { return }

        // BEAT 4 - SETTLE. The photos are now sitting exactly on the editor's
        // own cells, so lifting the scrim and fading this layer out reveals
        // an identical composition with its chrome resolving in.
        beat = .settle
        withAnimation(.easeInOut(duration: Self.scaled(Self.settleDuration))) {
            overlayOpacity = 0
            scrim = 0
        }
        await sleep(Self.settleDuration)
        guard !Task.isCancelled else { return }
        finish()
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * Self.timeScale * 1_000_000_000))
    }

    /// Every `withAnimation` duration goes through here so `-magicSlow`
    /// stretches the visible motion and the beat sleeps by the same factor.
    private static func scaled(_ seconds: Double) -> Double { seconds * timeScale }

    // MARK: - Plan resolution

    /// Pairs each finished photo with the picker thumbnail it came from and
    /// resolves its destination cell. Idempotent - re-run whenever a new
    /// input (document, canvas rect) lands.
    private func rebuildPlans() {
        guard let completion else {
            // Pre-document: keep whatever `seedPlansFromSources` put up -
            // the picker's own thumbnails, held at their picker positions.
            return
        }

        let doc = completion.document
        let cellRectByID: [PhotoID: CGRect]
        if canvasRect.width > 0, canvasRect.height > 0 {
            let (cells, _) = solve(root: doc.root, canvasSize: canvasRect.size, border: doc.border)
            cellRectByID = Dictionary(uniqueKeysWithValues: cells.map {
                ($0.id, $0.rect.offsetBy(dx: canvasRect.minX, dy: canvasRect.minY))
            })
        } else {
            cellRectByID = [:]
        }

        // Source pairing: by asset identifier where there is one (the normal
        // library path), else positionally (the PHPicker-fallback path never
        // produces a PHAsset). Anything still unmatched gets a synthesized
        // starting square so the sequence degrades to "photos appear in the
        // middle and assemble" rather than not running at all - which is what
        // happens when the selected thumbnails were scrolled off screen and
        // the lazy grid never published their frames.
        var remainingSources = sources
        var plans: [MagicPhotoPlan] = []
        let ids = completion.orderedPhotoIDs
        for (index, id) in ids.enumerated() {
            guard let ref = doc.photos[id], let image = completion.images[id] else { continue }
            let assetID = completion.assetIDByPhotoID[id] ?? ""

            var source: MagicSource?
            if !assetID.isEmpty, let match = remainingSources.firstIndex(where: { $0.assetID == assetID }) {
                source = remainingSources.remove(at: match)
            } else if !remainingSources.isEmpty {
                source = remainingSources.removeFirst()
            }

            let pixelSize = CGSize(width: Double(ref.pixelWidth), height: Double(ref.pixelHeight))
            let dest = cellRectByID[id]
            let sourceRect = source?.rect ?? Self.syntheticSourceRect(index: index, count: ids.count, around: dest ?? canvasRect)

            plans.append(MagicPhotoPlan(
                id: id,
                image: image,
                pixelSize: pixelSize,
                sourceRect: sourceRect,
                destRect: dest ?? sourceRect,
                destZoom: dest == nil ? 1.0 : ref.zoom,
                destCenter: dest == nil ? CGPoint(x: 0.5, y: 0.5) : ref.center,
                faces: completion.faceRectsByPhotoID[id] ?? []
            ))
        }

        photos = plans
        boxesEnabled = Self.shouldRevealBoxes(plans)
        #if DEBUG
        NSLog("MAGIC plans: %d photos, faces=%@, boxes=%@, canvas=%@",
              plans.count, plans.map { "\($0.faces.count)" }.joined(separator: ","),
              boxesEnabled ? "on" : "off (degraded)", NSCoder.string(for: canvasRect))
        #endif
    }

    /// Degradation rule (spec): "if detection is weak or finds fewer faces
    /// than expected, skip the box-reveal beat and just assemble." Weak here
    /// means fewer than half the photos produced a face that survived the
    /// framing thresholds - one lucky hit across four landscapes is not a
    /// face-detection story worth telling, and a set with no faces at all
    /// (the landscape case that must keep working) skips silently.
    private static func shouldRevealBoxes(_ plans: [MagicPhotoPlan]) -> Bool {
        guard !plans.isEmpty else { return false }
        let withFaces = plans.filter { !$0.faces.isEmpty }.count
        return withFaces * 2 >= plans.count
    }

    /// Last-resort starting square for a photo whose picker thumbnail frame
    /// never arrived: a small tile near the canvas center, laid out in a
    /// rough grid so several of them don't stack.
    private static func syntheticSourceRect(index: Int, count: Int, around anchor: CGRect) -> CGRect {
        let side = max(min(anchor.width, anchor.height) * 0.28, 60)
        let columns = count <= 2 ? count : 2
        let rows = Int(ceil(Double(count) / Double(max(columns, 1))))
        let col = index % max(columns, 1)
        let row = index / max(columns, 1)
        let totalW = Double(columns) * side + Double(max(columns - 1, 0)) * 8
        let totalH = Double(rows) * side + Double(max(rows - 1, 0)) * 8
        let originX = anchor.midX - totalW / 2 + Double(col) * (side + 8)
        let originY = anchor.midY - totalH / 2 + Double(row) * (side + 8)
        return CGRect(x: originX, y: originY, width: side, height: side)
    }
}

// MARK: - Timing instrumentation (DEBUG)

/// Wall-clock marks for the one number the spec makes an acceptance
/// criterion: added time versus today's spinner path. Written to STDERR
/// (unbuffered, unlike `print`'s fully-buffered stdout when piped) so
/// `xcrun simctl launch --console-pipe` sees each mark as it happens rather
/// than in one flush at exit.
enum MagicTiming {
    /// Set once, at the tap, on BOTH paths - so the sequence's total and the
    /// bypassed ("today's spinner") total are measured from the same instant
    /// and are directly comparable. The baseline number is "editor mounted"
    /// with `-magicLayoutOff`; the sequence's number is "overlay done".
    nonisolated(unsafe) static var pickStart: CFAbsoluteTime = 0

    static func startPick() {
        pickStart = CFAbsoluteTimeGetCurrent()
        mark("Next tapped")
    }

    static func mark(_ label: String) {
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - pickStart) * 1000
        let line = String(format: "MAGIC %@ +%.0fms", label, ms)
        fputs(line + "\n", stderr)
        // Also the unified log, which `xcrun simctl spawn <udid> log show`
        // can read after the fact - a piped stdout/stderr from simctl launch
        // is not reliably flushed for a GUI app.
        NSLog("%@", line)
        #endif
    }
}

// MARK: - Overlay

struct MagicLayoutOverlay: View {
    let controller: MagicLayoutController

    var body: some View {
        GeometryReader { proxy in
            // Everything published into this overlay is in GLOBAL (window)
            // coordinates; this reader ignores the safe area so its own local
            // space is the window's, and the residual origin correction below
            // keeps that true even if it ever isn't.
            let originFix = proxy.frame(in: .global).origin

            ZStack {
                Color.mosaicBackground
                    .opacity(controller.scrim * 0.93)
                    .ignoresSafeArea()

                if controller.showsFallbackSpinner {
                    // Skipped before the result existed - exactly today's
                    // spinner, until there's an editor to land on.
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(controller.photos) { plan in
                        MorphingPhotoView(
                            progress: controller.morphProgress,
                            plan: plan,
                            originFix: originFix,
                            boxOpacity: boxOpacity(for: plan)
                        )
                    }
                    if controller.beat == .scan {
                        sweepBand(in: proxy.size)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .opacity(controller.overlayOpacity)
            // Any touch anywhere skips (spec: "any touch skips instantly to
            // the finished editor"). A zero-distance drag catches a touch
            // DOWN rather than waiting for a completed tap, so a press-and-
            // hold ends the sequence too.
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in controller.skip() })
            .onTapGesture { controller.skip() }
        }
        .ignoresSafeArea()
    }

    /// Boxes fade in on the staggered reveal, then wipe out over the first
    /// ~40% of the assemble morph - derived from `morphProgress` rather than
    /// animated separately so they never lag the photo they're drawn on.
    private func boxOpacity(for plan: MagicPhotoPlan) -> Double {
        guard controller.boxesEnabled, !plan.faces.isEmpty else { return 0 }
        guard let index = controller.photos.firstIndex(where: { $0.id == plan.id }) else { return 0 }
        guard index < controller.revealedBoxes else { return 0 }
        return max(0, 1 - controller.morphProgress * 2.5)
    }

    /// The scan beat's travelling band - a soft accent-tinted sweep crossing
    /// the whole stage. Deliberately cheap and non-literal: the honest
    /// content of this beat is the boxes, which are real; the sweep is just
    /// the motion that carries them.
    private func sweepBand(in size: CGSize) -> some View {
        let bandHeight = max(size.height * 0.18, 90)
        let travel = size.height + bandHeight
        return LinearGradient(
            colors: [.clear, Color.mosaicAccent.opacity(0.16), Color.mosaicAccent.opacity(0.30), Color.mosaicAccent.opacity(0.16), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: size.width, height: bandHeight)
        .blendMode(.plusLighter)
        .position(x: size.width / 2, y: -bandHeight / 2 + controller.sweep * travel)
        .allowsHitTesting(false)
    }
}

// MARK: - The morph

/// One photo, drawn at an arbitrary point along its journey.
///
/// `Animatable` on a `View` is what makes the CROP animate: SwiftUI
/// interpolates `animatableData` and re-evaluates `body` every frame, so the
/// rect, the zoom and the crop center are all re-derived per frame from one
/// eased scalar - rather than SwiftUI independently animating a `.frame` while
/// the crop math snapped at the end.
///
/// The per-frame math is deliberately the SAME formula `CanvasView.cellContent`
/// uses (fill scale from the effective photo size, then an explicit
/// `.position` of the image's own center, never an `.offset`/alignment chain),
/// so at `progress == 1` this view is drawing precisely what the editor
/// underneath it is drawing. That identity is what lets the settle beat
/// crossfade instead of cut.
private struct MorphingPhotoView: View, Animatable {
    var progress: Double
    let plan: MagicPhotoPlan
    let originFix: CGPoint
    let boxOpacity: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = min(max(progress, 0), 1)
        let rect = Self.lerp(plan.sourceRect, plan.destRect, t)
            .offsetBy(dx: -originFix.x, dy: -originFix.y)
        // Source crop is a square aspect-fill center crop - exactly what
        // `GridThumbnail` renders (`aspectRatio(contentMode: .fill)` in a
        // square frame) - so zoom starts at 1.0 and center at (0.5, 0.5).
        let zoom = 1 + (plan.destZoom - 1) * t
        let center = CGPoint(
            x: 0.5 + (plan.destCenter.x - 0.5) * t,
            y: 0.5 + (plan.destCenter.y - 0.5) * t
        )

        let s0 = fillScale(cellSize: rect.size, photoPixelSize: plan.pixelSize, quarterTurns: 0)
        let displayScale = s0 * zoom
        let frameW = plan.pixelSize.width * displayScale
        let frameH = plan.pixelSize.height * displayScale
        let blockCenterX = rect.width / 2 + (0.5 - center.x) * frameW
        let blockCenterY = rect.height / 2 + (0.5 - center.y) * frameH

        ZStack(alignment: .topLeading) {
            Image(uiImage: plan.image)
                .resizable()
                .frame(width: frameW, height: frameH)
                .position(x: blockCenterX, y: blockCenterY)

            if boxOpacity > 0 {
                faceBoxes(
                    imageOrigin: CGPoint(x: blockCenterX - frameW / 2, y: blockCenterY - frameH / 2),
                    frameSize: CGSize(width: frameW, height: frameH)
                )
                .opacity(boxOpacity)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    /// Real Vision rects, in the photo's own normalized top-left space,
    /// projected through the SAME display transform as the pixels they sit
    /// on - so a box stays welded to its face while the photo pans and zooms.
    private func faceBoxes(imageOrigin: CGPoint, frameSize: CGSize) -> some View {
        ForEach(Array(plan.faces.enumerated()), id: \.offset) { _, face in
            let box = CGRect(
                x: imageOrigin.x + face.minX * frameSize.width,
                y: imageOrigin.y + face.minY * frameSize.height,
                width: face.width * frameSize.width,
                height: face.height * frameSize.height
            )
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.mosaicAccent, lineWidth: 2)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
        }
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: max(a.width + (b.width - a.width) * t, 1),
            height: max(a.height + (b.height - a.height) * t, 1)
        )
    }
}
