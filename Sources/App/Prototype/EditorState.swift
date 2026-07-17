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
import CoreImage
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

    // MARK: - Border swatches (Phase 4)

    /// Per-photo average colors (deduped, capped at 4), computed once here
    /// at editor-open time - not recomputed on Replace/Remove, matching
    /// "computed once when the editor opens" in the task brief.
    private(set) var derivedSwatches: [RGBA] = []
    /// User-picked custom colors (from the system color picker), persisted
    /// across editor sessions.
    private(set) var customSwatches: [RGBA] = []
    private static let customSwatchesDefaultsKey = "mosaic.customBorderSwatches.v1"

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
        self.derivedSwatches = Self.computeDerivedSwatches(document: document, images: images)
        self.customSwatches = Self.loadCustomSwatches()
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
        derivedSwatches = Self.computeDerivedSwatches(document: document, images: images)
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

    // MARK: - Border tray (Phase 4)

    /// Slider drags call `beginGesture()`/`commitGesture()` around a whole
    /// interaction (see BorderTrayView) so a multi-step drag collapses to
    /// ONE undo snapshot; these setters just mutate `document` live in
    /// between, mirroring GestureController's divider-drag pattern.
    func setBorderInner(_ fraction: Double) {
        var doc = document
        doc.border.inner = fraction
        if doc.border.linked { doc.border.outer = fraction }
        doc = reclampAll(doc, canvasSize: canvasSize)
        document = doc
    }

    func setBorderOuter(_ fraction: Double) {
        var doc = document
        doc.border.outer = fraction
        if doc.border.linked { doc.border.inner = fraction }
        doc = reclampAll(doc, canvasSize: canvasSize)
        document = doc
    }

    /// Corner radius is a pure paint-time property (Layout.swift's solver
    /// never reads it), so no reclamp is needed here.
    func setBorderRadius(_ fraction: Double) {
        var doc = document
        doc.border.cornerRadius = fraction
        document = doc
    }

    /// The link toggle is a discrete tap, not a drag - one undo snapshot of
    /// its own, matching the toggle-style actions elsewhere (toggleAuto).
    func setBorderLinked(_ linked: Bool) {
        let old = document
        var doc = document
        doc.border.linked = linked
        if linked { doc.border.outer = doc.border.inner }
        doc = reclampAll(doc, canvasSize: canvasSize)
        document = doc
        pushUndo(old)
    }

    /// Swatch tap: one undo snapshot, no reclamp needed (color is paint-only).
    func setBorderColor(_ color: RGBA) {
        let old = document
        var doc = document
        doc.border.color = color
        document = doc
        pushUndo(old)
    }

    /// Appends a custom color from the system color picker to the swatch
    /// row and persists it (RGBA JSON array) in UserDefaults so it survives
    /// future editor sessions. Also applies it as the current border color
    /// (one undo snapshot, same as any other swatch tap).
    func addCustomSwatch(_ color: RGBA) {
        customSwatches.append(color)
        Self.saveCustomSwatches(customSwatches)
        setBorderColor(color)
    }

    private static func loadCustomSwatches() -> [RGBA] {
        guard let data = UserDefaults.standard.data(forKey: customSwatchesDefaultsKey),
              let decoded = try? JSONDecoder().decode([RGBA].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveCustomSwatches(_ swatches: [RGBA]) {
        guard let data = try? JSONEncoder().encode(swatches) else { return }
        UserDefaults.standard.set(data, forKey: customSwatchesDefaultsKey)
    }

    /// Per-photo average color (CIAreaAverage on each proxy UIImage),
    /// deduped by simple RGB distance, capped at 4 - "derived suggestions"
    /// shown first in the swatch row. Computed once at init; never
    /// recomputed on Replace/Remove (those change which photos exist, but
    /// re-deriving suggestions mid-session would make the swatch row
    /// reshuffle under the user while they're picking a border color).
    private static func computeDerivedSwatches(document: Document, images: [PhotoID: UIImage]) -> [RGBA] {
        let ids = photoIDs(in: document.root)
        var result: [RGBA] = []
        for id in ids {
            guard let image = images[id], let color = averageColor(of: image) else { continue }
            let isDuplicate = result.contains { existing in
                let dr = existing.r - color.r
                let dg = existing.g - color.g
                let db = existing.b - color.b
                return (dr * dr + dg * dg + db * db).squareRoot() < 0.08
            }
            guard !isDuplicate else { continue }
            result.append(color)
            if result.count == 4 { break }
        }
        return result
    }

    private static func averageColor(of image: UIImage) -> RGBA? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let extentVector = CIVector(
            x: ciImage.extent.origin.x, y: ciImage.extent.origin.y,
            z: ciImage.extent.size.width, w: ciImage.extent.size.height
        )
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: extentVector
        ]), let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        guard bitmap[3] > 0 else { return nil }
        return RGBA(
            r: Double(bitmap[0]) / 255.0,
            g: Double(bitmap[1]) / 255.0,
            b: Double(bitmap[2]) / 255.0,
            a: 1.0
        )
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
