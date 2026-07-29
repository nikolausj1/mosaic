// Sources/App/Library/PickerView.swift
// Full-screen dark photo picker: album menu, pinch-to-resize square grid
// (3-column default), 2-4 unordered selection, and the pick-completion flow
// that builds a Document (template + content-fit assignment + per-photo
// auto-framing) ready to hand to EditorState.
import SwiftUI
import Photos
import PhotosUI
import UIKit

// MARK: - PickerState

/// `.pick`: the normal 2-4 multi-select flow that builds a whole new
/// Document. `.replace` (Phase 4): exactly one selection, used by the
/// editor's photo toolbar "Replace" action to swap a single existing
/// photo's asset - see `PickerState.confirmReplace()` and
/// `EditorState.replace(photoID:image:pixelSize:assetLocalIdentifier:)`.
enum PickerMode {
    case pick
    case replace
}

@Observable
@MainActor
final class PickerState {

    let library = PhotoLibraryService()
    let mode: PickerMode

    private(set) var albums: [PhotoLibraryService.AlbumInfo] = []
    private(set) var selectedAlbum: PhotoLibraryService.AlbumInfo?
    private(set) var assets: PHFetchResult<PHAsset> = PHFetchResult() {
        didSet {
            // Materialized ONCE per fetch here, never in a view body
            // (2026-07-26 perf fix - see the grid's doc comment): the array
            // is what ForEach iterates, keyed by each asset's stable
            // localIdentifier.
            var result: [PHAsset] = []
            result.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in result.append(asset) }
            gridAssets = result
        }
    }
    /// Plain-array mirror of `assets` for `ForEach` - kept in lockstep by
    /// `assets`'s `didSet`.
    private(set) var gridAssets: [PHAsset] = []

    /// A Set would lose deterministic grid redraw order, so this stays an
    /// Array - and as of the grid's big centered pick-order number (Justin,
    /// 2026-07-26, see `selectionOrder(_:)`), insertion order IS the number
    /// shown, not just an implementation detail.
    private(set) var selectedAssetIDs: [String] = []
    var pulseNextBadge = false

    /// Splash-to-picker launch animation (Justin, 2026-07-26): true once the
    /// arrival animation has played for this app process. `PickerState` for
    /// `.pick` mode is created once and lives for ContentView's whole
    /// lifetime (see MosaicApp.swift), so this flag survives the picker
    /// disappearing/reappearing as the editor opens and closes - exactly
    /// the "first appearance only" guard `PickerView.init` needs. A fresh
    /// `.replace`-mode PickerState is built per sheet presentation, but
    /// that mode never plays the animation regardless (gated in `init`).
    private(set) var hasPlayedLaunchAnimation = false

    var isLoading = false
    var loadingMessage = "Preparing…"

    /// B32 Phase 0: true from the moment the Magic Layout sequence takes over
    /// the picker-to-editor handoff. The old spinner (`loadingOverlay`) is the
    /// thing the sequence REPLACES, so it must not also show underneath it -
    /// but it is still the correct presentation for `.replace` mode, for
    /// Reduce Motion, and for a pick that bypasses the sequence, hence a flag
    /// rather than a deletion. Observable (unlike the two caches below) since
    /// a view body reads it.
    var isMagicSequenceRunning = false

    /// B32 Phase 0 - the overlay's source geometry. Live global frames of the
    /// SELECTED grid thumbnails, republished by `PickedThumbFramesKey` on
    /// every scroll/layout change and parked here by `PickerView` so they
    /// survive into the confirm handler (by which point the grid may be
    /// mid-teardown). `@ObservationIgnored` on purpose: nothing renders from
    /// these, so tracking them would only add spurious invalidations to a
    /// view that is re-rendered on every selection tap already.
    @ObservationIgnored private(set) var thumbFrames: [String: CGRect] = [:]

    /// B32 Phase 0 - the overlay's source PIXELS, so the sequence can start
    /// the instant Next is tapped rather than waiting for
    /// `loadForEditing`'s full-resolution proxies (which is the whole point:
    /// the arrive/scan beats run OVER that load, not after it). Capped at the
    /// current selection (<= 4 images) by `pruneThumbnailCache`, so this
    /// never becomes a library-sized bitmap cache.
    @ObservationIgnored private(set) var selectedThumbnails: [String: UIImage] = [:]

    /// Set only by the denied-state "Choose Photos" PHPickerViewController
    /// fallback - those results never have a backing PHAsset.
    private var fallbackPicks: [(image: UIImage, pixelSize: CGSize)] = []

    /// The overlay's inputs, in pick order: where each chosen thumbnail sits
    /// on screen right now and the bitmap already showing there. A selection
    /// whose frame never got published (scrolled far off screen in a lazy
    /// grid) is simply omitted - `MagicLayoutController` synthesizes a
    /// starting square for it rather than refusing to run.
    func magicSources() -> [MagicSource] {
        selectedAssetIDs.compactMap { id in
            guard let rect = thumbFrames[id] else { return nil }
            return MagicSource(assetID: id, rect: rect, image: selectedThumbnails[id])
        }
    }

    /// MERGES rather than replaces (2026-07-28 review). `PickedThumbFramesKey`
    /// only carries the grid cells `LazyVGrid` currently has realized, so a
    /// straight assignment dropped the frame of any selected photo the user
    /// had since scrolled past - and `magicSources()` then silently
    /// `compactMap`ed it away, so that photo took no part in the flight and
    /// simply appeared at the settle. Select near the top, scroll, select
    /// again, tap Next and you would see it. Keeping the last known frame is
    /// correct as well as sufficient: a photo can only be selected by being
    /// tapped, so it was on screen at least once while selected, and flying
    /// in from off the edge is exactly where it actually was.
    func recordThumbFrames(_ frames: [String: CGRect]) {
        thumbFrames.merge(frames) { _, new in new }
        thumbFrames = thumbFrames.filter { selectedAssetIDs.contains($0.key) }
    }

    /// Called by `GridThumbnail` whenever a SELECTED cell has a bitmap in
    /// hand (on load, and again if selection arrives after the load did).
    func recordSelectedThumbnail(_ assetID: String, image: UIImage) {
        guard selectedAssetIDs.contains(assetID) else { return }
        selectedThumbnails[assetID] = image
    }

    private func pruneThumbnailCache() {
        selectedThumbnails = selectedThumbnails.filter { selectedAssetIDs.contains($0.key) }
    }

    var authorizationStatus: PHAuthorizationStatus { library.authorizationStatus }
    var isLimited: Bool { authorizationStatus == .limited }
    var canConfirm: Bool {
        switch mode {
        case .pick: return selectedAssetIDs.count >= 2 || fallbackPicks.count >= 2
        case .replace: return selectedAssetIDs.count == 1 || fallbackPicks.count == 1
        }
    }
    var selectionCount: Int { max(selectedAssetIDs.count, fallbackPicks.count) }

    static let maxSelectionForPick = 4
    var effectiveSelectionLimit: Int { mode == .replace ? 1 : Self.maxSelectionForPick }

    init(mode: PickerMode = .pick) {
        self.mode = mode
    }

    // MARK: - Lifecycle

    func onAppear() async {
        library.refreshAuthorizationStatus()
        if library.authorizationStatus == .notDetermined {
            await library.requestAccess()
        }
        await reload()
    }

    func reload() async {
        guard library.authorizationStatus == .authorized || library.authorizationStatus == .limited else { return }
        let smart = library.smartAlbums()
        albums = smart
        let recents = smart.first(where: { $0.title == "Recents" })
        let target = selectedAlbum.flatMap { current in smart.first(where: { $0.id == current.id }) } ?? recents ?? smart.first
        selectedAlbum = target
        if let target {
            assets = library.assets(in: target)
        }
    }

    func selectAlbum(_ album: PhotoLibraryService.AlbumInfo) {
        selectedAlbum = album
        assets = library.assets(in: album)
    }

    // MARK: - Selection

    func isSelected(_ assetID: String) -> Bool { selectedAssetIDs.contains(assetID) }

    /// 1-based pick order, for the grid cell's big centered number - nil
    /// when unselected. Unordered per the note on `selectedAssetIDs` above,
    /// but the array's insertion order IS the pick order, so this is just
    /// its index.
    func selectionOrder(_ assetID: String) -> Int? {
        guard let idx = selectedAssetIDs.firstIndex(of: assetID) else { return nil }
        return idx + 1
    }

    /// Called once, synchronously, from `PickerView.init` on the picker's
    /// first appearance this process - see `hasPlayedLaunchAnimation`.
    func markLaunchAnimationPlayed() {
        hasPlayedLaunchAnimation = true
    }

    /// Dev Tools "Replay first-run experience" (Justin, 2026-07-26): re-arms
    /// the one-per-process guard above so `PickerView` can re-stage the
    /// welcome choreography in-place, without relaunching the app. See
    /// `PickerView.replayFirstRunExperience()`.
    func resetLaunchAnimationFlag() {
        hasPlayedLaunchAnimation = false
    }

    func toggleSelection(_ assetID: String) {
        // Every `return` below is followed by the same cache prune, so the
        // B32 thumbnail cache can never outlive the selection it mirrors.
        defer { pruneThumbnailCache() }
        if let idx = selectedAssetIDs.firstIndex(of: assetID) {
            selectedAssetIDs.remove(at: idx)
            return
        }
        if mode == .replace {
            // Single-select: tapping a different photo swaps the pick
            // rather than being blocked once one is already selected.
            selectedAssetIDs = [assetID]
            return
        }
        guard selectedAssetIDs.count < Self.maxSelectionForPick else {
            rejectSelection()
            return
        }
        selectedAssetIDs.append(assetID)
    }

    private func rejectSelection() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        pulseNextBadge = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            self?.pulseNextBadge = false
        }
    }

    // MARK: - PHPicker fallback (denied-state "Choose Photos")

    func addFallbackPick(image: UIImage, pixelSize: CGSize) {
        fallbackPicks.append((image, pixelSize))
    }

    func clearFallbackPicks() {
        fallbackPicks.removeAll()
    }

    // MARK: - Pick completion

    /// Builds a ready-to-edit Document from the current selection: choose an
    /// orientation-aware default template, brute-force content-fit assignment
    /// into it, solve for cell rects, then auto-frame each photo into its
    /// assigned cell. Template must be chosen BEFORE auto-framing since
    /// auto-framing needs the cell size.
    /// B32 Phase 0: returns a `PickCompletion` rather than the old
    /// `(Document, images)` pair - the Magic Layout overlay needs the raw
    /// per-photo face rects, which this flow used to distil into an `ROI` and
    /// then discard. Everything else about the pipeline is untouched.
    func confirmSelection() async -> PickCompletion? {
        isLoading = true
        loadingMessage = "Preparing…"
        defer { isLoading = false }

        if !fallbackPicks.isEmpty {
            return await buildDocument(from: fallbackPicks.map { (image: $0.image, pixelSize: $0.pixelSize, asset: nil) })
        }

        let chosen = selectedAssetIDs
        guard chosen.count >= 2 else { return nil }

        var loaded: [(image: UIImage, pixelSize: CGSize, asset: PHAsset?)] = []
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            guard chosen.contains(asset.localIdentifier) else { continue }
            guard let (proxy, pixelSize) = await library.loadForEditing(asset: asset) else { continue }
            loaded.append((proxy, pixelSize, asset))
            if loaded.count == chosen.count { break }
        }
        guard loaded.count >= 2 else { return nil }
        return await buildDocument(from: loaded)
    }

    /// Auto-selects the `count` newest grid photos - the `-autoPick N`
    /// launch-arg path for simctl screenshot automation.
    ///
    /// SPLIT from the old `autoPickAndConfirm` (B32 Phase 0): the caller now
    /// runs `confirmSelection()` itself, because the Magic Layout sequence
    /// has to START before the confirm is awaited (it plays OVER that work,
    /// not after it) - and because the grid needs a beat between the
    /// selection landing and the confirm to publish the selected thumbnails'
    /// frames, which is the overlay's source geometry. See
    /// `ContentView.applyLaunchArgsIfNeeded`.
    @discardableResult
    func autoPickSelect(count: Int) async -> Bool {
        await onAppear()
        guard assets.count > 0 else { return false }
        let n = min(count, assets.count)
        selectedAssetIDs = (0..<n).map { assets.object(at: $0).localIdentifier }
        return true
    }

    /// Phase 4 Replace flow: exactly one loaded (image, pixelSize, asset) -
    /// no Document is built here (that pipeline requires 2-4 photos for
    /// `templates(for:)`); the caller (EditorState.replace) auto-frames
    /// against the SPECIFIC cell the replaced photo already occupies.
    func confirmReplace() async -> (image: UIImage, pixelSize: CGSize, asset: PHAsset?)? {
        isLoading = true
        loadingMessage = "Preparing…"
        defer { isLoading = false }

        if let pick = fallbackPicks.first {
            return (pick.image, pick.pixelSize, nil)
        }

        guard let assetID = selectedAssetIDs.first else { return nil }
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            guard asset.localIdentifier == assetID else { continue }
            guard let (proxy, pixelSize) = await library.loadForEditing(asset: asset) else { return nil }
            return (proxy, pixelSize, asset)
        }
        return nil
    }

    /// The faces the framing decision actually used: the Engine's OWN
    /// threshold filter (confidence >= 0.5, height >= 8% of the photo's short
    /// edge), called directly rather than restated here.
    ///
    /// Phase 0 had a hand-copied duplicate of this, with a comment explaining
    /// that the Engine's filter was `private` at the time. Phase 1 made
    /// `thresholdedFaces` non-private precisely so `mustKeepRegion` could
    /// reuse it, so the copy is now both unnecessary and a hazard - the boxes
    /// the reveal lights up must be the same detections `autoFrame` and
    /// `mustKeepRegion` kept, and one shared function is the only way that
    /// stays true as the thresholds move in Phase 4.
    private static func survivingFaces(_ vision: (faces: [(CGRect, Double)], salient: CGRect?), pixelSize: CGSize) -> [CGRect] {
        thresholdedFaces(
            faces: vision.faces.map(\.0),
            faceConfidences: vision.faces.map(\.1),
            photoPixelSize: pixelSize
        )
    }

    /// See the call site in `buildDocument`. DEBUG-only, like every other
    /// launch arg in this app; always false in Release.
    private static let isFaceAwareLayoutDisabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-faceAwareLayoutOff")
        #else
        return false
        #endif
    }()

    private func buildDocument(from loaded: [(image: UIImage, pixelSize: CGSize, asset: PHAsset?)]) async -> PickCompletion? {
        loadingMessage = "Framing your photos…"

        var idsInOrder: [PhotoID] = []
        var pixelSizes: [PhotoID: CGSize] = [:]
        var images: [PhotoID: UIImage] = [:]
        var assetByID: [PhotoID: PHAsset] = [:]

        for entry in loaded {
            let id = PhotoID()
            idsInOrder.append(id)
            pixelSizes[id] = entry.pixelSize
            images[id] = entry.image
            if let asset = entry.asset { assetByID[id] = asset }
        }

        // A fresh collage starts with a genuinely zero border (Justin,
        // 2026-07-26): photos arrive touching, matching the Border tray's
        // slider at 0. Zero here (not stripped later) so content-fit and
        // auto-framing solve against the exact cell rects the editor shows.
        let border = BorderStyle(inner: 0, outer: 0, linked: true, cornerRadius: 0, color: .white)
        let nominalCanvas = CGSize(width: 1000, height: 1000)

        // ---- PASS 1: SEE. ------------------------------------------------
        // Vision first, for EVERY photo, before any template exists.
        //
        // B32 Phase 1 wiring (2026-07-28): this is the structural change.
        // Until now the order was template -> cell rects -> Vision, because
        // `autoFrame` needs the cell it is framing into; Vision's output was
        // therefore only ever available AFTER the layout had been decided, so
        // the layout could not possibly depend on it. Splitting the loop in
        // two - see, then decide, then frame - is what lets the faces choose
        // the template. It costs nothing: the same one Vision pass per photo,
        // just hoisted above the decision instead of below it.
        var visionByID: [PhotoID: (faces: [(CGRect, Double)], salient: CGRect?)] = [:]
        var mustKeepRegions: [PhotoID: CGRect] = [:]
        var faceRectsByPhotoID: [PhotoID: [CGRect]] = [:]
        for id in idsInOrder {
            guard let pixelSize = pixelSizes[id], let cgImage = images[id]?.cgImage else { continue }
            let vision = await library.visionInputs(cgImage: cgImage)
            visionByID[id] = vision
            // B32 Phase 0: keep the raw (thresholded) face rects, which this
            // flow used to drop on the floor the moment `autoFrame` had
            // turned them into an ROI. The reveal's glow beat needs the boxes
            // themselves.
            let kept = Self.survivingFaces(vision, pixelSize: pixelSize)
            faceRectsByPhotoID[id] = kept
            // The Engine owns what "must not be cropped away" means -
            // surviving faces plus margin, falling back to saliency, and to
            // nil when Vision found neither (the landscape case). Same
            // normalized top-left rects that feed `autoFrame` below.
            if let region = mustKeepRegion(
                faces: vision.faces.map(\.0),
                faceConfidences: vision.faces.map(\.1),
                salientRegion: vision.salient,
                photoPixelSize: pixelSize
            ) {
                mustKeepRegions[id] = region
            }
            #if DEBUG
            NSLog("MAGIC vision: %dx%d rawFaces=%d kept=%d salient=%@ mustKeep=%@",
                  Int(pixelSize.width), Int(pixelSize.height),
                  vision.faces.count, kept.count,
                  vision.salient == nil ? "no" : "yes",
                  mustKeepRegions[id].map { NSCoder.string(for: $0) } ?? "nil")
            #endif
        }

        // ---- PASS 2: DECIDE. ---------------------------------------------
        // The faces choose the layout. `faceAwareAssignment` searches EVERY
        // candidate template for this photo count and every assignment of
        // photos into its slots, scored by `framingCost` (clipped face
        // dominates; small face, crop loss and aspect mismatch are
        // tie-breakers) - replacing the old `defaultTemplateIndex` +
        // `contentFitAssignment` pair, which searched only permutations and
        // scored on ASPECT alone.
        //
        // No fallback is layered on top of it here, deliberately: the Engine
        // already guarantees that a photo set with no must-keep region
        // anywhere returns exactly today's `defaultTemplateIndex` +
        // `contentFitAssignment` answer (see the degrade guard in
        // `faceAwareAssignment`, and the "face-aware degrade" smoke-test
        // case). A second guard here could only ever disagree with it.
        // Phase 5: the canvas RATIO is part of the decision now, not a
        // hardcoded square. `chooseCanvasAndLayout` wraps the same
        // `faceAwareAssignment` search - it nominates at most ONE challenger
        // ratio from photo orientations, runs the search at both that and
        // square, and keeps the challenger only if it wins by a clear margin.
        // A user who has ever set a ratio by hand short-circuits all of it.
        let decision = chooseCanvasAndLayout(
            photos: idsInOrder,
            photoSizes: pixelSizes,
            // `-faceAwareLayoutOff` (DEBUG, same family as `-magicLayoutOff`):
            // starves the search of must-keep data, which by the Engine's own
            // degrade guarantee returns precisely today's `defaultTemplateIndex`
            // + `contentFitAssignment` answer. That makes the aspect-only
            // "before" reachable from the SAME build as the face-aware
            // "after" - the only honest way to screenshot the difference, and
            // the tool Phase 4 will want when a real-camera-roll layout looks
            // wrong and the question is whether the faces caused it.
            mustKeepRegions: Self.isFaceAwareLayoutDisabled ? [:] : mustKeepRegions,
            border: border,
            // Stated intent wins over the content rule. Nil until the user
            // has set a ratio by hand at least once.
            userRatio: EditorState.rememberedCanvasRatio
        )
        let assigned = decision.template
        // Everything downstream - solving for cells, auto-framing into them,
        // and the final reclamp - must use the canvas the decision actually
        // chose. Solving the chosen template against the old fixed square
        // would auto-frame every photo against cell shapes that never exist.
        let decidedCanvas = nominalCanvasSize(for: decision.canvasRatio, shortEdge: 1000)

        #if DEBUG
        // Before/after instrumentation (verification only): what today's
        // aspect-only path WOULD have chosen, so a real pick can be reported
        // as changed-or-not rather than assumed. Pure logging - nothing below
        // reads these.
        let orientations = idsInOrder.map { pixelSizes[$0] ?? CGSize(width: 1, height: 1) }
        let candidateTemplates = templates(for: idsInOrder)
        let previousIndex = min(defaultTemplateIndex(orientations: orientations), candidateTemplates.count - 1)
        let previousAssigned = contentFitAssignment(
            photoSizes: pixelSizes,
            template: candidateTemplates[previousIndex],
            canvasSize: nominalCanvas,
            border: border
        )
        let orderIndex = Dictionary(uniqueKeysWithValues: idsInOrder.enumerated().map { ($0.element, $0.offset) })
        let previousOrder = photoIDs(in: previousAssigned).map { orderIndex[$0].map(String.init) ?? "?" }.joined(separator: ",")
        let newOrder = photoIDs(in: assigned).map { orderIndex[$0].map(String.init) ?? "?" }.joined(separator: ",")
        NSLog("MAGIC decision: template %d->%d perm [%@]->[%@] ratio %.3f (%@) cost=%.3f mustKeep=%d/%d CHANGED=%@",
              previousIndex, decision.templateIndex, previousOrder, newOrder,
              decision.canvasRatio.value,
              EditorState.rememberedCanvasRatio != nil ? "sticky" :
                  (decision.canvasRatio == .square ? "square" : "chosen"),
              decision.cost, mustKeepRegions.count, idsInOrder.count,
              (previousIndex != decision.templateIndex || previousOrder != newOrder
                  || decision.canvasRatio != .square) ? "YES" : "no")
        #endif

        // ---- PASS 3: FRAME. ----------------------------------------------
        // Unchanged B20 auto-framing, now solving against the cells the
        // face-aware decision produced.
        let (cells, _) = solve(root: assigned, canvasSize: decidedCanvas, border: border)
        let cellRectByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })

        var photos: [PhotoID: PhotoRef] = [:]
        for id in idsInOrder {
            guard let pixelSize = pixelSizes[id] else { continue }
            let cellRect = cellRectByID[id] ?? CGRect(origin: .zero, size: decidedCanvas)

            var roi: ROI?
            if let vision = visionByID[id] {
                let input = AutoFrameInput(
                    faces: vision.faces.map(\.0),
                    faceConfidences: vision.faces.map(\.1),
                    salientRegion: vision.salient,
                    photoPixelSize: pixelSize,
                    cellSize: cellRect.size
                )
                roi = autoFrame(input)
            }

            photos[id] = PhotoRef(
                assetLocalIdentifier: assetByID[id]?.localIdentifier ?? "",
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height),
                zoom: roi?.zoom ?? 1.0,
                center: roi?.center ?? CGPoint(x: 0.5, y: 0.5),
                flipH: false,
                flipV: false,
                quarterTurns: 0,
                isAuto: roi != nil,
                roi: roi
            )
        }

        var doc = Document(canvasRatio: decision.canvasRatio, root: assigned, photos: photos, border: border)
        doc = reclampAll(doc, canvasSize: decidedCanvas)
        return PickCompletion(
            document: doc,
            images: images,
            orderedPhotoIDs: idsInOrder,
            assetIDByPhotoID: assetByID.mapValues(\.localIdentifier),
            faceRectsByPhotoID: faceRectsByPhotoID
        )
    }
}

// MARK: - PickerView

struct PickerView: View {
    @State var state: PickerState
    /// B28's settings ingress (gear icon, Screen A header) needs entitlement
    /// state for its Remove Watermark row - owned upstream (ContentView) and
    /// threaded through, same as every other state object in this app.
    var storeService: StoreService
    /// `.pick` mode's completion: the finished document, its images, and
    /// (B32 Phase 0) the per-photo face rects the Magic Layout reveal needs.
    var onConfirmed: (PickCompletion) -> Void = { _ in }
    /// B32 Phase 0: fired the instant Next is tapped, BEFORE the document
    /// work starts, handing the host the source geometry+pixels for the
    /// arrival sequence. Returns true if the host actually started the
    /// sequence (false under Reduce Motion / `-magicLayoutOff`), which is how
    /// this view knows whether to keep showing its own spinner.
    var onPickBegan: ([MagicSource]) -> Bool = { _ in false }
    /// `.replace` mode's completion (Phase 4): the single freshly-loaded
    /// asset, handed to `EditorState.replace(photoID:image:pixelSize:...)`.
    var onReplaceConfirmed: ((UIImage, CGSize, PHAsset?) -> Void)? = nil

    @State private var showAlbumMenu = false
    @State private var showFallbackPicker = false
    @State private var showSettings = false

    /// First-run welcome (Justin, 2026-07-26, full-screen revision): shown
    /// exactly once per install, gated by this flag - see `LaunchPhase` and
    /// `runLaunchChoreographyIfNeeded()` for the timing (it's now folded
    /// into the splash-to-picker choreography itself, not a modal shown
    /// after it settles).
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false

    /// Pinch-to-resize grid density (Justin, 2026-07-26 rework): 1-5 columns,
    /// default 3 (was a 3/4/5 tap control defaulting to 4 - see `pinchToResizeGesture`
    /// and `grid` below, replacing the old `ColumnCountControl`). Everything
    /// the grid draws per cell (`GridThumbnail`) is geometry-driven off its
    /// own `GeometryReader`, so changing this needs no other math to change
    /// anywhere.
    @AppStorage("pickerColumns") private var pickerColumns: Int = 3

    /// Pinch-gesture accumulator (Justin, 2026-07-26): `MagnificationGesture`
    /// reports its value cumulatively from the moment two fingers touch down,
    /// not as a per-frame delta - so to let one long pinch step through
    /// several column counts, this tracks the gesture value at the last step
    /// and measures each `onChanged` tick RELATIVE to it, resetting after
    /// every step (and back to 1.0 when the gesture ends). See
    /// `pinchToResizeGesture`.
    @State private var pinchStepAnchor: CGFloat = 1.0

    /// Collapsing hero header (Justin, 2026-07-26): raw vertical content

    /// Splash-to-picker launch, folded together with the first-run welcome
    /// (Justin, 2026-07-26). `.initial`: the oversized lockup, alone and
    /// centered on the empty background - the shared first moment for both
    /// a returning launch and a first-run welcome. From there:
    ///   - Returning (`hasSeenWelcome` already true): holds briefly, then
    ///     springs straight to `.arrived` (the real masthead/header/grid
    ///     layout) - exactly the original splash behavior, no text, no
    ///     button.
    ///   - First run (`hasSeenWelcome` false): `.welcomeText` fades in the
    ///     three teaching rows below the lockup, then `.welcomeReady` fades
    ///     in the "Get started" button below that. `.welcomeReady` HOLDS -
    ///     no timeout - until the button is tapped, which sets
    ///     `hasSeenWelcome` and springs to `.arrived` in the same motion
    ///     (see `getStarted()`).
    /// Reduce Motion skips straight to the settled state for either path:
    /// returning users land on `.arrived` immediately; first-run users land
    /// on `.welcomeReady` immediately (lockup + rows + button all present,
    /// no staged fades), and tapping "Get started" cuts straight to
    /// `.arrived` with no spring.
    /// Decided once, in `init`, from `hasPlayedLaunchAnimation`,
    /// `hasSeenWelcome`, and Reduce Motion - see there for why it must be
    /// decided synchronously rather than in `.task`.
    private enum LaunchPhase {
        case initial
        case welcomeText
        case welcomeReady
        case arrived
    }

    @State private var launchPhase: LaunchPhase
    /// Ties the oversized welcome-stage lockup to the real masthead lockup so
    /// the position/scale change reads as one element moving, not a
    /// crossfade between two - see `welcomeStage` and `masthead`.
    @Namespace private var lockupNamespace

    private let backgroundColor = Color(red: 0.043, green: 0.043, blue: 0.051)

    /// Disabled floating-CTA fill (Justin, 2026-07-26): a flat, fully OPAQUE
    /// dark grey - deliberately not `Color.mosaicSurface`, which sits too
    /// close to `backgroundColor` to read as a solid card over photos
    /// scrolling underneath it. No material, no alpha blend with what's
    /// behind - see `floatingNextButton`.
    private let ctaDisabledFill = Color(red: 0.176, green: 0.176, blue: 0.184)

    /// Hero header sizing (Justin, 2026-07-26 collapsing-header rework): the
    /// lockup sits at `mastheadHeroLockupHeight` at rest and shrinks to
    /// `mastheadCompactLockupHeight` (today's original masthead size) once
    /// the grid has scrolled `heroCollapseDistance` points - see
    /// `heroCollapseProgress` and `masthead`.
    private let mastheadCompactLockupHeight: CGFloat = 30
    private let mastheadHeroLockupHeight: CGFloat = 56
    private let heroCollapseDistance: CGFloat = 60

    /// Custom init (replaces the synthesized memberwise one) so the launch
    /// phase can be decided before the first frame renders. Parameter order
    /// mirrors the original property order exactly - both call sites
    /// (ContentView.swift, EditorView.swift) rely on skipping defaulted
    /// params out of position, which only works if this matches.
    init(
        state: PickerState,
        storeService: StoreService,
        onConfirmed: @escaping (PickCompletion) -> Void = { _ in },
        onReplaceConfirmed: ((UIImage, CGSize, PHAsset?) -> Void)? = nil,
        onPickBegan: @escaping ([MagicSource]) -> Bool = { _ in false }
    ) {
        _state = State(initialValue: state)
        self.storeService = storeService
        self.onConfirmed = onConfirmed
        self.onReplaceConfirmed = onReplaceConfirmed
        self.onPickBegan = onPickBegan

        // Read the "have we ever played this" flag BEFORE marking it -
        // that decides whether THIS appearance animates at all. Mark it
        // played synchronously right here (not after the animation
        // finishes) so a later PickerView init for the very same
        // PickerState (returning from the editor swaps EditorView back out,
        // same `.pick` PickerState instance persists on ContentView) can
        // never re-arm it, even if Reduce Motion is toggled mid-process.
        let isFreshProcessAppearance = state.mode == .pick && !state.hasPlayedLaunchAnimation
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // Read the UserDefaults value directly rather than through
        // `@AppStorage` - `self` isn't fully initialized yet at this point
        // in a custom init, but a plain UserDefaults read doesn't touch
        // `self` at all, so it's safe here (same key `hasSeenWelcome` reads/
        // writes through afterward).
        let neverSeenWelcome = state.mode == .pick && !UserDefaults.standard.bool(forKey: "hasSeenWelcome")
        if state.mode == .pick {
            state.markLaunchAnimationPlayed()
        }

        if !isFreshProcessAppearance {
            // Every appearance after the very first one this process (or
            // `.replace` mode, which never animates) - straight to settled.
            _launchPhase = State(initialValue: .arrived)
        } else if reduceMotion {
            // First appearance this process, but no animation: land
            // immediately on whichever HOLD state is correct for this
            // install - `.welcomeReady` (lockup+rows+button, all static) if
            // this is a first run, else straight past the welcome to
            // `.arrived`.
            _launchPhase = State(initialValue: neverSeenWelcome ? .welcomeReady : .arrived)
        } else {
            // The one case that actually animates: start at the shared
            // `.initial` moment: `runLaunchChoreographyIfNeeded()` stages
            // the rest, branching on `hasSeenWelcome`.
            _launchPhase = State(initialValue: .initial)
        }
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            // Splash-to-picker launch, folded with the first-run welcome
            // (Justin, 2026-07-26): the oversized lockup - and, on a first
            // run, the teaching rows and "Get started" button beneath it -
            // sit here, centered on the empty background, for every phase
            // except `.arrived` - see LaunchPhase.
            if launchPhase != .arrived {
                welcomeStage
            }

            VStack(spacing: 0) {
                if state.mode == .pick {
                    masthead
                }
                // Header/banner/grid group springs up + fades in together
                // with the masthead's lockup landing (one coordinated
                // transaction - see `runLaunchChoreographyIfNeeded` and
                // `getStarted`). Outside the launch window this offset/
                // opacity pair is just (0, 1) - a no-op.
                Group {
                    header
                    content
                }
                .offset(y: launchPhase == .arrived ? 0 : 80)
                .opacity(launchPhase == .arrived ? 1 : 0)
            }
        }
        .foregroundStyle(.white)
        .task { await state.onAppear() }
        // Independent of the `.task` above: photo-permission prompts and
        // library loading must never wait on this beat+spring+welcome-hold,
        // so it's its own child task rather than sequenced after
        // `onAppear()`.
        .task { await runLaunchChoreographyIfNeeded() }
        .sheet(isPresented: $showFallbackPicker) {
            SystemPhotoPicker(selectionLimit: state.effectiveSelectionLimit) { picks in
                for pick in picks { state.addFallbackPick(image: pick.0, pixelSize: pick.1) }
                Task { await confirmAndDeliver() }
            }
        }
        // B32 Phase 0: the source geometry export. Selected grid cells
        // publish their global frames up through the ScrollView; this parks
        // the live values on `PickerState` so they are in hand at confirm
        // time, when the grid itself is about to be torn down.
        .onPreferenceChange(PickedThumbFramesKey.self) { frames in
            state.recordThumbFrames(frames)
        }
        .overlay {
            // The Magic Layout sequence REPLACES this spinner for the `.pick`
            // handoff (it plays over exactly the work the spinner used to
            // hide). This overlay still serves `.replace` mode, Reduce
            // Motion, and any pick where the sequence declined to start.
            if state.isLoading && !state.isMagicSequenceRunning {
                loadingOverlay
            }
        }
        .overlay(alignment: .bottom) {
            // Hidden until the splash/welcome settles - the always-present
            // CTA otherwise peeks through the bottom of the first-run
            // welcome screen (caught in the 2026-07-26 review pass).
            if launchPhase == .arrived {
                floatingNextButton
            }
        }
        .sheet(isPresented: $showSettings) {
            // Dev Tools' "Replay first-run experience" / "Clear collages" rows
            // moved in here (Justin, 2026-07-27 - see `DevSheet.swift`'s
            // former header comment, now this one's): the gear that used to
            // just open purchase settings is now also the Dev Tools entry
            // point, so the callback plumbing that used to feed `DevSheet`
            // feeds `SettingsSheet` instead. Ships in Release FOR NOW - the
            // lead owns gating these behind `#if DEBUG` before submission.
            SettingsSheet(
                storeService: storeService,
                onReplayFirstRun: replayFirstRunExperience,
                onClearCollages: { DocumentStore.resetAll() },
                onDismiss: { showSettings = false }
            )
        }
    }

    // MARK: - Splash-to-picker + first-run welcome choreography (Justin, 2026-07-26)

    /// B32 Phase 0: the sequence starts HERE, on the tap - not when the
    /// document is finished. `onPickBegan` hands the host the picker's own
    /// geometry and pixels and puts the overlay on screen immediately, so the
    /// arrive and scan beats are spent covering the `loadForEditing` + Vision
    /// work that today sits behind a spinner. That overlap is what keeps the
    /// added wall clock small; starting the sequence after `confirmSelection`
    /// returned would make every millisecond of it pure addition.
    private func confirmAndDeliver() async {
        switch state.mode {
        case .pick:
            MagicTiming.startPick()
            if onPickBegan(state.magicSources()) {
                state.isMagicSequenceRunning = true
            }
            if let completion = await state.confirmSelection() {
                onConfirmed(completion)
            } else {
                state.isMagicSequenceRunning = false
            }
        case .replace:
            if let (image, pixelSize, asset) = await state.confirmReplace() {
                onReplaceConfirmed?(image, pixelSize, asset)
            }
        }
    }

    /// Holds the oversized centered lockup for a beat, then stages whichever
    /// path `init` decided this appearance should take. `guard launchPhase
    /// == .initial` makes this a no-op on every appearance after the first
    /// (or under Reduce Motion, or in `.replace` mode) - `init` already
    /// resolved those synchronously to their settled state.
    ///
    /// Grand-entrance rework (Justin, 2026-07-26): every hold roughly
    /// doubled from the original splash timing, and the lockup now gets a
    /// full 1.2s alone before anything else appears - a real title-sequence
    /// beat rather than a blink-and-you-miss-it pause. The rows themselves
    /// don't fade in as one block anymore: `WelcomeInstructionRows` stages
    /// each row on its own ~0.6s-staggered delay once `isRevealed` flips
    /// (see that view), so the second hold below is sized to let the LAST
    /// (fourth, on-device-AI) row finish landing before "Get started"
    /// appears underneath them.
    private func runLaunchChoreographyIfNeeded() async {
        guard launchPhase == .initial else { return }
        if hasSeenWelcome {
            // Returning user: the original splash - brief hold, then spring
            // straight to the settled picker.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard launchPhase == .initial else { return } // a dev-tools replay may have moved it
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                launchPhase = .arrived
            }
        } else {
            // First run: a full beat alone with the (now larger) lockup,
            // then the teaching rows stagger in beneath it, then (once
            // they've all landed) the CTA fades in at the BOTTOM of the
            // screen. `.welcomeReady` HOLDS from there - no further timer,
            // see `getStarted()`.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard launchPhase == .initial else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                launchPhase = .welcomeText
            }
            // ~0.6s stagger x 4 rows + each row's own fade duration - timed
            // to clear the last (AI) row before the CTA shows up.
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard launchPhase == .welcomeText else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                launchPhase = .welcomeReady
            }
        }
    }

    /// "Get started" - the button IS the welcome screen's dismissal. Sets
    /// `hasSeenWelcome` and triggers the EXISTING splash-to-picker spring in
    /// the same motion, so the welcome screen and the picker's arrival read
    /// as one continuous choreography rather than two separate animations.
    /// Spring slowed slightly (0.7 -> 0.9 response, Justin 2026-07-26) to
    /// match the rest of the grand-entrance rework's more deliberate pace,
    /// while staying the same one-motion spring it always was. Reduce
    /// Motion cuts straight to `.arrived` with no spring.
    private func getStarted() {
        hasSeenWelcome = true
        if UIAccessibility.isReduceMotionEnabled {
            launchPhase = .arrived
        } else {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) {
                launchPhase = .arrived
            }
        }
    }

    /// Dev Tools "Replay first-run experience" (Justin, 2026-07-26; moved into
    /// `SettingsSheet` 2026-07-27 - see the `.sheet(isPresented: $showSettings)`
    /// modifier above): clears `hasSeenWelcome` plus the other two onboarding
    /// flags EditorView owns (`hasSeenCoachMarks`, `hasSeenEditor` - reset
    /// here as plain UserDefaults keys since this file doesn't own
    /// EditorView.swift), then re-arms this process's launch-animation guard
    /// and rewinds `launchPhase` back to the welcome screen's start so the
    /// choreography re-runs immediately - no relaunch needed to see it. Coach
    /// marks and the editor's auto-selected first cell still need a fresh
    /// Editor entry to actually replay (their flags are read fresh there),
    /// which `SettingsSheet`'s footer copy is honest about.
    private func replayFirstRunExperience() {
        hasSeenWelcome = false
        UserDefaults.standard.removeObject(forKey: "hasSeenCoachMarks")
        UserDefaults.standard.removeObject(forKey: "hasSeenEditor")
        state.resetLaunchAnimationFlag()
        launchPhase = UIAccessibility.isReduceMotionEnabled ? .welcomeReady : .initial
        showSettings = false
        Task { await runLaunchChoreographyIfNeeded() }
    }

    // MARK: Masthead (branding + instruction, Justin 2026-07-17)

    /// Brand lockup (Justin, 2026-07-26) - replaces the tracked-out MOSAIC
    /// wordmark. Shared between the final masthead position and the
    /// oversized welcome-stage placement (`welcomeStage`) - the two `.frame`
    /// heights plus `matchedGeometryEffect` are what let one lockup read as
    /// sliding/scaling between them instead of crossfading.
    private var lockupImage: some View {
        Image("Lockup")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Mosaic")
    }

    /// Splash-to-picker launch + first-run welcome, one screen (Justin,
    /// 2026-07-26 grand-entrance rework): the lockup at ~2.2x the masthead's
    /// resting height (30pt -> 66pt, up from the original 1.6x/48pt), front
    /// and center, for every phase except `.arrived` - disappears the instant
    /// the real masthead lockup (tagged with the same namespace id) takes
    /// over, shrinking further from there as `masthead`'s own hero size
    /// settles in. On a first run the teaching rows stagger in below it as
    /// `launchPhase` advances to `.welcomeText`, then "Get started" appears
    /// pinned to the BOTTOM of the screen - same position/size class as the
    /// picker's persistent floating CTA (`floatingNextButton`), not a
    /// mid-screen button - once `launchPhase` reaches `.welcomeReady`. On a
    /// returning launch neither ever shows since `launchPhase` skips
    /// straight from `.initial` to `.arrived` (see
    /// `runLaunchChoreographyIfNeeded`). Hit-testing is on only for the
    /// button itself - the lockup and rows stay `allowsHitTesting(false)`
    /// like the old splash lockup did.
    private var welcomeStage: some View {
        ZStack {
            VStack(spacing: 28) {
                Spacer()
                lockupImage
                    .frame(height: mastheadCompactLockupHeight * 2.2)
                    .matchedGeometryEffect(id: "lockup", in: lockupNamespace)
                    .allowsHitTesting(false)
                    // Breathing room below the lockup (Justin, 2026-07-28 -
                    // "move the text down a bit to give some padding below
                    // the logo"): on top of the VStack's own 28pt spacing,
                    // so the rows land a deliberate ~48pt below the lockup
                    // instead of the old cramped 28pt.
                    .padding(.bottom, 20)

                // Present the whole time (not just at `.welcomeText`/
                // `.welcomeReady`) so each row's own staggered `.animation`
                // has a real false -> true transition to animate through -
                // see `WelcomeInstructionRows.isRevealed`. Invisible and
                // inert until then, so this is a no-op for returning users,
                // who never leave `.initial` before jumping to `.arrived`.
                WelcomeInstructionRows(isRevealed: launchPhase != .initial)
                    .allowsHitTesting(false)

                Spacer()
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // "Get started" now lives at the bottom of the screen, matching
            // the floating CTA's own position/size class exactly (80%-width
            // capsule, 16pt above the safe-area bottom) - see
            // `floatingNextButton`.
            if launchPhase == .welcomeReady {
                VStack {
                    Spacer()
                    WelcomeGetStartedButton(action: getStarted)
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Reserved brand space at the top of the picker: just the wordmark now
    /// (Justin, 2026-07-27 - the "Choose 2-4 photos below" instruction line
    /// that used to sit under it is gone; the floating CTA's own label
    /// ("Choose 2-4 photos" / "Choose 1 more" / "Next (N)", see `ctaLabel`)
    /// already carries that message, so the masthead had nothing left to say
    /// twice). Deliberately quiet otherwise - a brand moment, not a tutorial
    /// (the PRD's no-tutorials rule stands; the gesture grammar still teaches
    /// itself in the editor).
    ///
    /// The settings gear now lives in this hero area's top-right corner
    /// (Justin, 2026-07-27 - see `settingsButton`, replacing the old Dev
    /// Tools ellipsis that used to sit here; the header row below lost its
    /// own gear in the swap, see `header`), anchored via `.overlay` to the
    /// OUTER frame.
    ///
    /// While `launchPhase != .arrived` the real lockup isn't here yet -
    /// `welcomeStage` owns it - so a clear spacer holds the hero's height;
    /// the real lockup fades in and takes over via `matchedGeometryEffect`
    /// once the phase reaches `.arrived`.
    ///
    /// FIXED height, deliberately (Justin, 2026-07-27 - the tap-drift bug).
    /// This masthead sits in a VStack ABOVE the grid's ScrollView, so any
    /// change to its height moves the ScrollView's frame and slides every
    /// grid cell vertically on screen. The old scroll-driven collapse shrank
    /// it by ~72pt total (lockup 26 + paddings 30 + subtitle 16) DURING the
    /// first 60pt of scroll - i.e. exactly while a finger was down near the
    /// top of the grid - so a tap that started over one photo resolved over
    /// the next one down/along. That is the "wrong photo gets selected"
    /// report, and it was intermittent precisely because it only bit inside
    /// the collapse window. Nothing here may depend on scroll position
    /// again unless the hero moves INSIDE the ScrollView as scroll content.
    /// Padding tightened top/bottom (28/20 -> 26/26, Justin, 2026-07-27) now
    /// that the subtitle is gone - the lockup alone read bottom-heavy at the
    /// old asymmetric padding, so this centers it a bit more while still
    /// giving it real room to breathe as a confident brand moment.
    private var masthead: some View {
        VStack(spacing: 0) {
            if launchPhase == .arrived {
                lockupImage
                    .frame(height: mastheadHeroLockupHeight)
                    .matchedGeometryEffect(id: "lockup", in: lockupNamespace)
            } else {
                Color.clear.frame(height: mastheadHeroLockupHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 26)
        // No `.pick`-mode guard needed here - `masthead` itself is only ever
        // shown in `.pick` mode (see `body` above).
        .overlay(alignment: .topTrailing) {
            // Hidden until arrival (Justin, 2026-07-28 - "dont show the gear
            // icon on the loading/splash screen"): the gear has no business
            // being tappable over the welcome/splash lockup, and popping in
            // the instant `.arrived` lands read as an ugly snap next to the
            // rest of that transaction's spring, so it fades in on the same
            // ambient animation as the header/content `Group` below rather
            // than getting its own explicit `.animation` - matching that
            // Group's pattern exactly.
            settingsButton
                .opacity(launchPhase == .arrived ? 1 : 0)
                .allowsHitTesting(launchPhase == .arrived)
        }
    }

    // MARK: Header

    /// Next used to live here (trailing, "Next (N)"/"Replace"); it's now a
    /// floating CTA over the grid instead - see `floatingNextButton`
    /// (Justin, 2026-07-26). The thumbnail-size control that used to live at
    /// the trailing end moved off this row too (sizing is now a pinch
    /// gesture on the grid itself, see `pinchToResizeGesture`), and now the
    /// settings gear has moved off it as well (Justin, 2026-07-27 - it lives
    /// in the hero header's top-right corner now, see `masthead`/
    /// `settingsButton`) - so this row is just the album menu, the trailing
    /// `Spacer` kept purely to hold it left-weighted.
    private var header: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(state.albums) { album in
                    Button {
                        state.selectAlbum(album)
                    } label: {
                        Label("\(album.title) (\(album.count))", systemImage: state.selectedAlbum?.id == album.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(state.selectedAlbum?.title ?? "Recents")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(.white)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.white.opacity(0.06))
    }

    /// Settings ingress (B28), now doing double duty as the Dev Tools entry
    /// point too (Justin, 2026-07-27): moved here from the header row into
    /// the hero's top-right corner, taking over the exact spot and quiet
    /// styling the old Dev Tools "ellipsis.circle" glyph had (safe-area
    /// padded, `.pick`-only - the `.replace`-mode picker EditorView presents
    /// as a sheet has no chrome budget for it and nothing to settle
    /// mid-replace). `SettingsSheet` itself now carries the replay/clear rows
    /// the old (now-deleted) `DevSheet.swift` used to own - see
    /// `SettingsSheet.swift`.
    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 36, height: 36)
        }
        .padding(.top, 4)
        .padding(.trailing, 16)
    }

    // MARK: Pinch-to-resize grid (Justin, 2026-07-26)

    /// Replaces the old tap-driven `ColumnCountControl`: pinch the grid
    /// itself, Photos-app style - pinch IN (fingers together, magnification
    /// shrinking) shows MORE, smaller columns (4, then 5); pinch OUT
    /// (spreading, magnification growing) shows FEWER, bigger columns (2,
    /// then 1), clamped 1...5. `MagnificationGesture.onChanged` reports its
    /// value cumulatively from gesture start, not as a delta, so a single
    /// long pinch measures each tick relative to `pinchStepAnchor` (the
    /// value at the last step) rather than the gesture's true start -
    /// resetting that anchor after every step is what lets one continuous
    /// pinch walk through several sizes instead of firing once. Thresholds
    /// (1.3x / 0.77x, reciprocal of each other) are the same "does this feel
    /// like a deliberate step" balance the Photos app itself uses. Attached
    /// via `.simultaneousGesture` on the grid content (not the ScrollView)
    /// so it never steals the scroll drag or a cell's own tap gesture.
    private var pinchToResizeGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let relative = value / pinchStepAnchor
                if relative >= 1.3 {
                    stepColumns(by: -1)
                    pinchStepAnchor = value
                } else if relative <= 0.77 {
                    stepColumns(by: 1)
                    pinchStepAnchor = value
                }
            }
            .onEnded { _ in
                pinchStepAnchor = 1.0
            }
    }

    /// Steps `pickerColumns` by `delta`, clamped 1...5, with a quick
    /// re-layout animation and a light tap of haptic feedback per step
    /// (Justin, 2026-07-26) - every per-cell measurement (`GridThumbnail`'s
    /// selection overlay, its 40%-of-height number, the radial gradient
    /// radius) reads off its own `GeometryReader`, so nothing else needs to
    /// change when this does.
    private func stepColumns(by delta: Int) {
        let newValue = min(5, max(1, pickerColumns + delta))
        guard newValue != pickerColumns else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.25)) {
            pickerColumns = newValue
        }
    }

    // MARK: Persistent instructive CTA (Justin, 2026-07-26)

    /// Replaces the old header-row Next button AND the earlier
    /// appear/disappear floating capsule: this one is ALWAYS present while
    /// the picker is up, narrating the selection state instead of just
    /// gating on it - "clearly present but clearly inert" until the
    /// selection is valid. Existence is no longer the enablement signal;
    /// `state.canConfirm` now only toggles fill/border/text color and
    /// whether the button responds to taps. Same `confirmAndDeliver()`
    /// action either way, unreachable while disabled since `.disabled` on a
    /// `.plain`-styled button blocks the tap without adding its own dimming
    /// (this view already owns the muted-color look for the disabled state).
    /// Disabled fill is a flat, fully OPAQUE dark grey (Justin, 2026-07-26) -
    /// `ctaDisabledFill`, not a material or a border-plus-translucent-surface
    /// combo, so photos scrolling underneath the capsule never show through
    /// it. No border needed at that contrast, so the old hairline stroke is
    /// gone too.
    private var floatingNextButton: some View {
        Button {
            Task { await confirmAndDeliver() }
        } label: {
            Text(ctaLabel)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(state.canConfirm ? Color.white : Color.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                // Deep accent when enabled (real contrast for the white
                // label); flat opaque grey when disabled - both fully solid
                // fills, no material/border on either.
                .background(state.canConfirm ? Color.mosaicAccentDeep : ctaDisabledFill, in: Capsule())
                .shadow(color: .black.opacity(state.canConfirm ? 0.4 : 0), radius: 14, y: 6)
        }
        // NOT `.disabled()` (Justin, 2026-07-27): SwiftUI dims a disabled
        // button's ENTIRE rendering, including the opaque capsule fill, so
        // the inactive CTA still read as see-through with photos visible
        // through it - the exact thing the opaque `ctaDisabledFill` was
        // meant to fix. Blocking hit-testing instead keeps the fill fully
        // solid; the muted label color above is the only "disabled" cue.
        .allowsHitTesting(state.canConfirm)
        .buttonStyle(.plain)
        // 80% of screen width (Justin, 2026-07-26) - containerRelativeFrame
        // reads the ZStack root's width rather than needing a GeometryReader
        // of its own.
        .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.2), value: state.canConfirm)
        .animation(.easeInOut(duration: 0.2), value: ctaLabel)
    }

    /// Selection-count narration for the CTA above. `.pick`: 0 -> prompt to
    /// choose 2-4, 1 -> prompt for "1 more" (the common near-miss), 2-4 ->
    /// "Next (N)". `.replace`: 0 -> prompt, exactly 1 -> "Replace". The
    /// 5th-tap-rejected case never reaches here since the cap keeps
    /// `selectionCount` at 4.
    private var ctaLabel: String {
        switch state.mode {
        case .pick:
            switch state.selectionCount {
            case 0: return "Choose 2-4 photos"
            case 1: return "Choose 1 more"
            default: return "Next (\(state.selectionCount))"
            }
        case .replace:
            return state.canConfirm ? "Replace" : "Choose a photo"
        }
    }

    // MARK: Content per permission state

    @ViewBuilder
    private var content: some View {
        switch state.authorizationStatus {
        case .authorized, .limited:
            VStack(spacing: 0) {
                if state.isLimited {
                    limitedBanner
                }
                grid
            }
        case .denied, .restricted:
            deniedState
        case .notDetermined:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        @unknown default:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var limitedBanner: some View {
        Button {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: UIApplication.shared.topMostViewController ?? UIViewController())
        } label: {
            HStack {
                Image(systemName: "photo.badge.plus")
                Text("Allow access to more photos")
                Spacer()
            }
            .padding(10)
            .foregroundStyle(Color.mosaicAccent)
            .background(Color.white.opacity(0.08))
        }
    }

    /// Floating CTA capsule height (54) + its own bottom padding (16) + a
    /// little breathing room, so the last grid row can scroll clear of it
    /// instead of sitting underneath (Justin, 2026-07-26). Always applied
    /// now that the CTA is always present, not just once a selection is
    /// valid.
    private var gridBottomInset: CGFloat { 90 }

    /// Selection-identity bugfix (Justin, 2026-07-26): this grid used to
    /// `ForEach(0..<state.assets.count, id: \.self)`, keying every cell's
    /// SwiftUI identity to its plain integer INDEX rather than the asset
    /// itself. `PickerState.reload()` re-fetches a brand-new
    /// `PHFetchResult` (sorted newest-first) on every appearance, so if the
    /// library changed AT ALL between two appearances of the picker (a
    /// screenshot taken, a photo deleted, iCloud sync landing new assets),
    /// the SAME index pointed at a DIFFERENT `PHAsset` than before. SwiftUI,
    /// seeing an unchanged identity, reused the existing `GridThumbnail`
    /// view rather than tearing it down - so that cell's own `@State`
    /// (`image`/`isDegraded`/`requestID`) kept showing the OLD photo (since
    /// `.onAppear`, the only place a thumbnail fetch kicks off, never re-ran
    /// for a reused identity), while `isSelected`/`selectionOrder` and the
    /// tap gesture underneath had already moved on to the NEW asset at that
    /// index. The visible photo and the asset actually wired to the tap
    /// silently diverged - tapping the photo you SEE toggled selection on a
    /// different one. That's the "wrong photo selected, unpredictably"
    /// symptom: invisible when the library hadn't changed since last time,
    /// which is exactly why it read as random rather than reproducible.
    /// Fix: key each cell to the asset's own stable `localIdentifier`
    /// instead of its index. `PHFetchResult` only conforms to
    /// `NSFastEnumeration` (not `Sequence`/`RandomAccessCollection`, verified
    /// against the SDK - `ForEach` needs `RandomAccessCollection`), so
    /// `PickerState.gridAssets` materializes it into a plain `[PHAsset]`
    /// ONCE per fetch (reload/album change), not per render - enumerating a
    /// multi-thousand-photo library inside `body` made every re-render
    /// (each selection tap, every scroll frame of the collapsing hero, the
    /// back-from-editor transition) pay a full main-thread enumeration,
    /// which is exactly the "picker is almost unusable" / "2-3 second back
    /// lag" Justin reported (2026-07-26 perf fix). A changed asset at a
    /// given position is still a genuinely different `ForEach` identity, so
    /// the stale-cell selection fix is preserved.
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: pickerColumns), spacing: 2) {
                    ForEach(state.gridAssets, id: \.localIdentifier) { asset in
                        GridThumbnail(
                            asset: asset,
                            library: state.library,
                            isSelected: state.isSelected(asset.localIdentifier),
                            selectionOrder: state.selectionOrder(asset.localIdentifier),
                            pulse: state.pulseNextBadge,
                            onSelectedImage: { id, image in state.recordSelectedThumbnail(id, image: image) }
                        )
                        .onTapGesture {
                            state.toggleSelection(asset.localIdentifier)
                        }
                    }
                }
                // Pinch-to-resize (Justin, 2026-07-26): `.simultaneousGesture`
                // on the grid CONTENT (not the ScrollView itself) so it never
                // competes with the ScrollView's own drag gesture or a cell's
                // `.onTapGesture` - all three recognize side by side.
                .simultaneousGesture(pinchToResizeGesture)

                Color.clear.frame(height: gridBottomInset)
            }
            .scrollIndicators(.visible)
            // Deviation: a custom fast-scroll scrubber is Phase 4 polish; the
            // system scroll indicator is the accepted Phase 3 stand-in.
            //
            // Collapsing hero header (Justin, 2026-07-26): the iOS 18
            // `onScrollGeometryChange` is the cleanest current API for this -
            // no GeometryReader-on-scroll-content/PreferenceKey plumbing
            // needed, just the live content offset feeding `masthead`'s
            // continuous collapse interpolation (see `heroCollapseProgress`).
            // Scroll-offset tracking removed entirely (Justin, 2026-07-27):
            // its only consumer was the hero collapse, which is gone - see
            // `masthead`'s doc comment for why that had to go. Nothing now
            // re-renders the picker on scroll at all, which is also the
            // cheapest possible scrolling.
            // Return-to-task scroll (Justin, 2026-07-26): when the picker
            // reappears with an existing selection - the editor's "Photos"
            // back button, landing back on the same long-lived
            // `PickerState` - jump the grid so the FIRST selected photo is
            // visible, unanimated. Guarded on a non-empty selection, so a
            // genuine first launch (nothing selected yet) never scrolls.
            // `DispatchQueue.main.async` gives the grid one runloop turn to
            // lay out before `scrollTo` looks for the target cell's id.
            .onAppear {
                guard let firstSelectedID = state.selectedAssetIDs.first else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(firstSelectedID, anchor: .center)
                }
            }
        }
    }

    private var deniedState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.5))
            Text("Mosaic needs access to your photos")
                .font(.headline)
            Text("Grant photo access in Settings, or choose photos individually below.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.mosaicAccent)

            Button {
                showFallbackPicker = true
            } label: {
                Text("Choose Photos")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.bordered)
            .tint(Color.mosaicAccent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(state.loadingMessage)
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Grid thumbnail cell

private struct GridThumbnail: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    let isSelected: Bool
    /// 1-based pick order, nil when unselected - the big centered number
    /// (Justin, 2026-07-26). Always non-nil when `isSelected` is true.
    let selectionOrder: Int?
    let pulse: Bool
    /// B32 Phase 0: hands the loaded thumbnail bitmap up to `PickerState`
    /// while this cell is selected, so the arrival sequence has something to
    /// draw the instant Next is tapped (long before `loadForEditing`'s
    /// full-resolution proxy exists). Reported both when the image lands and
    /// when selection arrives after it - either order happens.
    var onSelectedImage: (String, UIImage) -> Void = { _, _ in }

    @State private var image: UIImage?
    @State private var isDegraded = true
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.05)
                // B32 Phase 0 - source geometry export. Zero-footprint marker
                // publishing this cell's GLOBAL frame while it is selected.
                // Note the ordering rule this project already paid for once
                // (see `CanvasView.coachMarkAnchorMarkers`): a geometry export
                // must describe the SIZED child, never a `.position`-wrapped
                // parent. There is no `.position` anywhere in this cell's
                // chain and `geo` is sized to exactly the square, so
                // `geo.frame(in: .global)` is precisely the thumbnail's
                // on-screen rect - and unlike an `Anchor` token it
                // re-resolves as the grid scrolls, which matters because
                // these frames are consumed at confirm time, arbitrarily
                // later than the tap that selected them.
                Color.clear
                    .preference(
                        key: PickedThumbFramesKey.self,
                        value: isSelected ? [asset.localIdentifier: geo.frame(in: .global)] : [:]
                    )
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                }
                if isDegraded && image != nil {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .overlay {
                // Kept as the lighter `mosaicAccent` (Justin, 2026-07-26):
                // against the now-deeper radial gradient below, this thin
                // rim reads as a highlight edge rather than clashing - a
                // second deep-blue layer here would just muddy into the
                // gradient instead of outlining it.
                if isSelected {
                    Rectangle()
                        .strokeBorder(Color.mosaicAccent, lineWidth: 2.5)
                }
            }
            // Selection vignette + big centered order number (Justin,
            // 2026-07-26) - replaces the small corner checkmark badge, which
            // wasn't unmistakable at a glance across a dense grid. Radial
            // gradient is heavier at the edges (0.55) and lighter dead
            // center (0.15) so the photo stays readable through the middle
            // while the accent color still reads clearly as "selected" from
            // the corners in. `endRadius` at 75% of the cell width pushes
            // full edge strength out past the corners (a unit square's
            // half-diagonal is ~70.7% of its side). Deep accent (Justin,
            // 2026-07-26) - same ramp, more saturated color, so the "selected"
            // read holds up at a glance next to the lighter accent stroke.
            .overlay {
                if isSelected, let selectionOrder {
                    ZStack {
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.mosaicAccentDeep.opacity(0.15), location: 0),
                                .init(color: Color.mosaicAccentDeep.opacity(0.55), location: 1)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: geo.size.width * 0.75
                        )
                        Text("\(selectionOrder)")
                            .font(.system(size: geo.size.height * 0.4, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    }
                    .scaleEffect(pulse ? 1.08 : 1.0)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isSelected)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: pulse)
            .onAppear {
                requestID = library.requestThumbnail(for: asset, targetSize: CGSize(width: geo.size.width * 3, height: geo.size.width * 3)) { img, degraded in
                    image = img
                    isDegraded = degraded
                    if let img, isSelected { onSelectedImage(asset.localIdentifier, img) }
                }
            }
            // Selection can land after the bitmap did (the common case: you
            // scroll, everything loads, then you tap) - report again here so
            // the B32 cache is populated either way.
            .onChange(of: isSelected) { _, selected in
                if selected, let image { onSelectedImage(asset.localIdentifier, image) }
            }
            .onDisappear {
                if let requestID { library.cancelThumbnailRequest(requestID) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // The tappable region is exactly the visible square - no reliance on
        // which sub-view happens to be opaque (Justin, 2026-07-27, hardening
        // alongside the masthead fix that actually caused the mis-taps).
        .contentShape(Rectangle())
    }
}

// MARK: - PHPickerViewController fallback (denied-state "Choose Photos")

private struct SystemPhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int = PickerState.maxSelectionForPick
    var onComplete: ([(UIImage, CGSize)]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([(UIImage, CGSize)]) -> Void
        init(onComplete: @escaping ([(UIImage, CGSize)]) -> Void) { self.onComplete = onComplete }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let providers = results.map(\.itemProvider)
            var loaded: [(UIImage, CGSize)] = []
            let group = DispatchGroup()
            for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage else { return }
                    let pixelSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? image.size
                    loaded.append((image, pixelSize))
                }
            }
            group.notify(queue: .main) { [onComplete] in
                onComplete(loaded)
            }
        }
    }
}

private extension UIApplication {
    var topMostViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
    }
}
