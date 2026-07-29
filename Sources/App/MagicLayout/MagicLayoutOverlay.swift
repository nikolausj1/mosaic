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
        /// the photos and the real face glows light up as they are found.
        case scan
        /// ~260ms, and the point of the whole feature: the layout the faces
        /// chose SNAPS into place - as glowing empty slots on the canvas -
        /// while every face glow is still burning and flares in unison. The
        /// eye has to be able to connect "these faces" to "this arrangement",
        /// and that only happens if the arrangement resolves while they are
        /// lit, not afterwards.
        case decide
        /// ~500ms: the morph - frame AND crop - into those slots, glows
        /// still lit and still welded to their faces the whole way.
        case assemble
        /// ~460ms: the handoff. The photo layer crossfades onto the identical
        /// editor underneath, then the last of the theater (glows, slots,
        /// scrim) fades out as the editor's own always-on affordances - the
        /// divider capsules and corner handles - come in behind it.
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

    // Beat timings, in seconds. Phase 0 used the spec's Phase 3 numbers
    // verbatim and measured ~1.4s of added wall clock against the spinner.
    // The decision beat below is NEW time, so it is paid for out of the
    // beats either side of it rather than added on top: the scan floor comes
    // down (the glows now have the decide beat to breathe into, so they no
    // longer need a long scan to register), the assemble comes down to the
    // 450-500ms the Phase 0 build log already identified as a lever, and the
    // settle's own crossfade starts while the last few frames of the morph
    // are still running (see `assembleHold`).
    private static let arriveDuration = 0.25
    /// Floor on the scan beat: below this the glow reveal is a subliminal
    /// flicker rather than a beat. Only ever costs time when the document was
    /// ready almost instantly.
    private static let scanFloor = 0.30
    /// The spec's cap on the scan VISUALS. The beat itself can run longer
    /// than this when the work genuinely takes longer (the sweep just keeps
    /// going) - what's capped is how long we'd ever wait on our own account.
    private static let scanCap = 0.70
    /// Dead time held for the decision beat. The flare it starts resolves
    /// over ~220ms, i.e. into the first frames of the assemble - the beat
    /// hands off mid-gesture rather than coming to a full stop first.
    private static let decideDuration = 0.26
    private static let assembleDuration = 0.50
    /// How long the sequence actually WAITS on the morph before starting the
    /// settle. Deliberately shorter than the morph itself: at 88% of this
    /// timing curve the photos are within a pixel or two of the destination
    /// the editor underneath is already drawing them at, so beginning the
    /// crossfade there is invisible and buys back 60ms.
    private static let assembleHold = 0.44
    /// Settle sub-beats, all measured from the start of the settle:
    /// photo-layer crossfade (0 -> 0.24), glow/slot burn-down (0.08 -> 0.34),
    /// editor affordances arriving (0.22 -> 0.50). The stagger is the point:
    /// the theater is visibly LEAVING as the controls visibly ARRIVE, so the
    /// end of the sequence reads as a handoff rather than a cut.
    private static let settleDuration = 0.46
    private static let glowOutDelay = 0.08
    private static let glowOutDuration = 0.26
    private static let chromeInDelay = 0.22
    private static let chromeInDuration = 0.28

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
    /// Opacity of the PHOTO layer only (and, with `scrim`, the thing the
    /// settle crossfades). Split from the theater layers below so the glows
    /// and slots can outlive it: once the morph is complete the editor
    /// underneath is drawing pixel-identical photos, so fading these out
    /// leaves the energy burning over the LIVE editor for a beat. That is
    /// what makes the handoff legible instead of a cut to black chrome.
    private(set) var overlayOpacity: Double = 0
    /// 0...1 sweep position for the scan beat's travelling band.
    private(set) var sweep: Double = 0
    /// How many photos have had their glows lit so far (staggered reveal).
    private(set) var revealedGlows = 0
    /// False whenever detection is too weak to be worth advertising - see
    /// `shouldRevealGlows`. Never advertise a miss.
    private(set) var glowsEnabled = false
    /// How many genuinely-detected faces were withheld because the chosen
    /// framing cuts them (see `facesSurvivingFinalCrop`). Reported only -
    /// nothing renders from it - but it is the number that says whether the
    /// "never glow a face the layout clips" rule is doing any work on a real
    /// camera roll, which is Phase 4's question.
    private(set) var clippedFaceCount = 0

    /// Master strength of every face glow. 0 unlit, ~1 burning, ~2.1 at the
    /// decision flare. Multiplies both the bloom's opacity and its radius, so
    /// a pulse reads as the halo swelling rather than just brightening.
    private(set) var glowStrength: Double = 0
    /// 0...1: the chosen layout's empty slots snapping into place at the
    /// decision. Drives their opacity AND a slight scale overshoot.
    private(set) var slotReveal: Double = 0
    /// A single accent wash across the whole stage at the instant of the
    /// decision - the "click" of the layout landing.
    private(set) var decideFlash: Double = 0

    /// True from the moment the sequence starts until the handoff beat -
    /// read by `CanvasView` (via `EditorView`), which holds its always-on
    /// divider capsules, corner handles and brackets back while the theater
    /// is playing so they can ARRIVE at the end instead of having been there
    /// all along under the scrim. Flipped inside `withAnimation`, so the
    /// affordances fade and scale in for free.
    ///
    /// Every exit path (natural finish, skip, skip-before-ready) runs through
    /// `finish()`, which clears this - the editor must never be left without
    /// its controls.
    private(set) var suppressEditorChrome = false

    private(set) var photos: [MagicPhotoPlan] = []
    /// True once the user has touched the overlay: the sequence is abandoned
    /// and we land on the finished editor as fast as it exists.
    private(set) var didSkip = false
    /// The one case where the overlay still shows chrome of its own: the user
    /// skipped before the document was ready, so there is no editor to land
    /// on yet. Falls back to exactly today's spinner until there is.
    var showsFallbackSpinner: Bool { didSkip && completion == nil }

    /// True once every plan's `destRect` is a REAL cell rect (the document
    /// landed and the editor published its canvas). Until then a plan's
    /// destination is just its own source square, and anything that draws the
    /// "chosen layout" would be drawing the picker grid instead.
    var hasResolvedDestinations: Bool {
        completion != nil && canvasRect.width > 0 && canvasRect.height > 0 && !photos.isEmpty
    }

    /// The editor canvas rect, in the same global space as every plan rect -
    /// the frame the chosen layout's slots live in.
    var destinationBounds: CGRect? {
        guard hasResolvedDestinations else { return nil }
        return canvasRect
    }

    private var sources: [MagicSource] = []
    private var completion: PickCompletion?
    private var canvasRect: CGRect = .zero
    private var task: Task<Void, Never>?
    /// Prepared at `begin` so the decision beat's tap lands on the same frame
    /// as the flare rather than a warm-up later (same reason `Haptics` keeps
    /// its generators prepared).
    private let decisionHaptic = UIImpactFeedbackGenerator(style: .soft)

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
        // Nothing to fly (2026-07-28 review). The denied/limited-access
        // "Choose Photos" path builds its document from `fallbackPicks`,
        // which never populates `selectedAssetIDs` - so `magicSources()` is
        // legitimately empty there and the sequence would otherwise play out
        // in full over zero photos: a dark scrim, a sweep across nothing,
        // and about a second and a half of dead time before the crossfade.
        // Returning false hands that path back to the ordinary spinner.
        guard !sources.isEmpty else {
            MagicTiming.mark("sequence declined (no source thumbnails)")
            return false
        }

        self.sources = sources
        completion = nil
        canvasRect = .zero
        photos = []
        didSkip = false
        revealedGlows = 0
        glowsEnabled = false
        morphProgress = 0
        sweep = 0
        scrim = 0
        overlayOpacity = 0
        glowStrength = 0
        slotReveal = 0
        decideFlash = 0
        suppressEditorChrome = true
        beat = .arrive
        decisionHaptic.prepare()
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
        glowStrength = 0
        slotReveal = 0
        decideFlash = 0
        photos = []
        sources = []
        // Terminal handoff, non-negotiable: ALL theater is gone by here, and
        // the editor's own affordances are on their way in. On the natural
        // path this is a no-op (the settle beat already released them, on a
        // longer curve); on a skip it is the thing that guarantees the user
        // is never left looking at a canvas with no controls on it.
        revealEditorChrome(duration: 0.18)
        MagicTiming.mark("overlay done (editor visible)")
    }

    /// Idempotent - the settle beat calls it early and on its own timing;
    /// `finish()` calls it again as the backstop.
    private func revealEditorChrome(duration: Double) {
        guard suppressEditorChrome else { return }
        withAnimation(.easeOut(duration: Self.scaled(duration))) {
            suppressEditorChrome = false
        }
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

        // `documentReady` just ran `rebuildPlans()` synchronously, almost
        // certainly before the canvas rect existed (see the comment there) -
        // so `glowsEnabled` cannot yet reflect a real decision. Wait,
        // briefly and capped, for the resolved rebuild `canvasFrameChanged`
        // triggers before reading `glowsEnabled` below. A glow that starts
        // ~30ms later (the measured real-world gap) is far better than one
        // that has to retract.
        await waitForResolvedPlans(cap: 0.25)
        guard !Task.isCancelled else { return }

        // Real glows on real detections, staggered so they read as "found,
        // then found, then found" rather than appearing as one block. Skipped
        // wholesale when detection is weak (never advertise a miss) - or when
        // destinations never resolved at all, in which case `glowsEnabled`
        // is still sitting at its safe `begin()` default, `false`.
        if glowsEnabled {
            withAnimation(.easeOut(duration: Self.scaled(0.22))) { glowStrength = 1 }
            let stagger = min(0.09, Self.scanCap / Double(max(photos.count, 1)) / 2)
            for _ in photos.indices {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: Self.scaled(0.18))) { revealedGlows += 1 }
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

        // Almost always a no-op by now (the wait above already resolved it) -
        // kept as the backstop for the rare case where the canvas genuinely
        // took longer than that first cap: destRect must be correct before
        // ASSEMBLE needs it (capped - a still-missing rect falls back to the
        // source rect, i.e. no morph, rather than hanging).
        await waitForResolvedPlans(cap: 0.25)
        guard !Task.isCancelled else { return }

        // BEAT 3 - DECIDE. The whole reason the feature exists: this is the
        // moment the layout is SHOWN to be a consequence of the faces, and
        // the only way an eye can read cause and effect is if the effect
        // lands while the cause is still visibly lit. So, in one beat and
        // with nothing else moving: the sweep stops, every face glow flares
        // in unison, a wash crosses the stage, and the chosen layout snaps in
        // as a set of empty glowing slots on the canvas. Nothing flies yet -
        // the arrangement exists before the photos move into it, which is
        // exactly the order the algorithm did it in.
        beat = .decide
        withAnimation(.easeOut(duration: Self.scaled(0.10))) {
            sweep = 0                       // kill the repeatForever
            if glowsEnabled { glowStrength = 2.1 }
            decideFlash = 1
        }
        // A spring here, unlike everywhere else in this sequence: the slots
        // are the one element that should read as SNAPPING rather than
        // easing. Slight overshoot, quickly damped.
        withAnimation(.spring(response: 0.30, dampingFraction: 0.62)) {
            slotReveal = 1
        }
        // One soft tap on the same frame as the flare. The decision is the
        // only moment in the sequence the app is claiming to have DONE
        // something, and a single haptic is the cheapest way to make a
        // visual beat feel caused rather than scheduled.
        decisionHaptic.impactOccurred(intensity: 0.9)
        await sleep(0.10)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: Self.scaled(0.22))) {
            if glowsEnabled { glowStrength = 1.15 }
            decideFlash = 0
        }
        await sleep(Self.decideDuration - 0.10)
        guard !Task.isCancelled else { return }

        // BEAT 4 - ASSEMBLE. Frame AND crop, together (see `MagicPhotoPlan`),
        // into the slots the previous beat just laid down. A decelerating
        // curve with no overshoot: a spring's overshoot would push the
        // interpolated zoom past its clamped destination for a few frames,
        // which can briefly expose a cell edge.
        //
        // The glows stay lit for the entire flight (Phase 0 wiped them over
        // the first 40% of the morph). Keeping them welded to their faces all
        // the way into the cell is what carries the causal claim through the
        // motion instead of dropping it the moment the photos start moving.
        beat = .assemble
        withAnimation(.timingCurve(0.22, 0.68, 0.16, 1, duration: Self.scaled(Self.assembleDuration))) {
            morphProgress = 1
        }
        await sleep(Self.assembleHold)
        guard !Task.isCancelled else { return }

        // BEAT 5 - SETTLE / HANDOFF. Three staggered sub-beats, in this
        // order, because the order IS the message: the composition becomes
        // real (the overlay's photos dissolve into the editor's identical
        // ones), the energy burns down, and the controls arrive. By the last
        // frame there is no glow, no slot, no sweep, no scrim and no dimming
        // anywhere - if any of it lingered, the user would still be waiting
        // for permission to touch the thing.
        beat = .settle
        withAnimation(.easeInOut(duration: Self.scaled(0.24))) {
            overlayOpacity = 0
            scrim = 0
        }
        await sleep(Self.glowOutDelay)
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: Self.scaled(Self.glowOutDuration))) {
            glowStrength = 0
            slotReveal = 0
        }
        await sleep(Self.chromeInDelay - Self.glowOutDelay)
        guard !Task.isCancelled else { return }
        revealEditorChrome(duration: Self.chromeInDuration)
        await sleep(Self.settleDuration - Self.chromeInDelay)
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

    /// Waits, briefly and capped, for the editor's canvas rect to publish,
    /// then runs `rebuildPlans()` regardless of whether it did - so a plan
    /// build always reflects the best information available and this can
    /// never hang the sequence. Shared by the two points in `run()` that
    /// must not read `glowsEnabled` (or `destRect`) from a stale, unresolved
    /// build: right before the scan beat's glow decision, and again right
    /// before ASSEMBLE needs real destination geometry.
    private func waitForResolvedPlans(cap: Double) async {
        var waited = 0.0
        while !canvasRectResolved && waited < cap && !Task.isCancelled {
            await sleep(0.016)
            waited += 0.016
        }
        rebuildPlans()
    }

    /// The single predicate for "the editor has published a REAL canvas
    /// rect". `waitForResolvedPlans` and `rebuildPlans` must agree on it
    /// exactly. They did not at first: the wait exited on `canvasRect ==
    /// .zero` while the glow gate asked for a non-zero SIZE, so a rect that
    /// arrived with a real origin but no size yet - reachable mid-layout -
    /// would end the wait without satisfying the gate, and the glow beat
    /// would be skipped for the whole sequence rather than merely delayed.
    private var canvasRectResolved: Bool {
        canvasRect.width > 0 && canvasRect.height > 0
    }

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
        clippedFaceCount = 0
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
            let destZoom = dest == nil ? 1.0 : ref.zoom
            let destCenter = dest == nil ? CGPoint(x: 0.5, y: 0.5) : ref.center

            let detected = completion.faceRectsByPhotoID[id] ?? []
            let survivors = dest.map {
                Self.facesSurvivingFinalCrop(
                    faces: detected,
                    pixelSize: pixelSize,
                    cellSize: $0.size,
                    zoom: destZoom,
                    center: destCenter
                )
            } ?? detected
            clippedFaceCount += detected.count - survivors.count

            plans.append(MagicPhotoPlan(
                id: id,
                image: image,
                pixelSize: pixelSize,
                sourceRect: sourceRect,
                destRect: dest ?? sourceRect,
                destZoom: destZoom,
                destCenter: destCenter,
                faces: survivors
            ))
        }

        photos = plans

        // Glows may only be switched ON by a build whose destinations are
        // REAL (2026-07-28, closing the gap the verification sweep flagged
        // rather than just recording it): a build that runs before the
        // canvas rect has published skips the clip filter above (`??
        // detected`), so `shouldRevealGlows` would be judging faces that
        // were never checked against the real crop. Confirmed reachable on
        // a normal pick, not just theoretical: `documentReady` calls this
        // synchronously the instant the document lands, which is BEFORE
        // SwiftUI has had a render pass to let `CanvasView` publish
        // `canvasRect` - measured at ~30ms after on a real run. The very
        // next build, once `canvasFrameChanged` delivers the rect, is
        // authoritative and safe to read.
        //
        // Leaving `glowsEnabled` UNTOUCHED here (rather than assigning it
        // `false`) is deliberate, not an oversight: it is what keeps this
        // monotonic (false -> true, never back). A true -> false flip here
        // would be worse than it sounds, because `run()`'s scan beat reads
        // `glowsEnabled` once to decide whether to run the staggered reveal
        // AT ALL - if that read landed on `false` transiently, the reveal
        // would be skipped for the rest of the sequence (nothing re-triggers
        // it), silently killing the beat rather than just re-hiding a wrong
        // glow. `run()` pairs with this by waiting (briefly, capped, never
        // hanging) for a resolved build before it reads `glowsEnabled` -
        // see `waitForResolvedPlans`.
        let destinationsResolved = canvasRectResolved
        if destinationsResolved {
            glowsEnabled = Self.shouldRevealGlows(plans)
        }
        #if DEBUG
        NSLog("MAGIC plans: %d photos, glowedFaces=%@, clippedFacesDropped=%d, glows=%@, resolved=%@, canvas=%@",
              plans.count, plans.map { "\($0.faces.count)" }.joined(separator: ","),
              clippedFaceCount,
              glowsEnabled ? "on" : "off (degraded)",
              destinationsResolved ? "yes" : "no",
              NSCoder.string(for: canvasRect))
        #endif
    }

    /// Never glow a face the final framing cuts (2026-07-28). A halo drawn
    /// around something the very next beat crops out of the collage is the
    /// app pointing at its own miss - worse than saying nothing, because it
    /// proves the app SAW the face and dropped it anyway.
    ///
    /// The test is the crop the photo genuinely lands in, not an estimate:
    /// `halfVisible` is the same Engine function `autoFrame`'s own clamp uses,
    /// fed the destination cell's size and the `(zoom, center)` the document
    /// actually carries, which yields the visible window in normalized photo
    /// space. A face is kept only if at least 98% of its AREA falls inside
    /// that window. Area, not containment, because a strict "fully contained"
    /// test would drop a face over a sub-pixel sliver at a cell edge, and the
    /// 2% slack is far below what an eye reads as a cut face; anything more
    /// obviously clipped than that fails it comfortably.
    ///
    /// Fresh picks are always `quarterTurns == 0` (rotation is an editor
    /// action that cannot have happened yet), so photo space and the
    /// document's effective displayed space are the same space here.
    private static func facesSurvivingFinalCrop(
        faces: [CGRect],
        pixelSize: CGSize,
        cellSize: CGSize,
        zoom: Double,
        center: CGPoint
    ) -> [CGRect] {
        guard cellSize.width > 0, cellSize.height > 0, !faces.isEmpty else { return faces }
        let half = halfVisible(zoom: zoom, photoPixelSize: pixelSize, cellSize: cellSize)
        let visible = CGRect(
            x: center.x - half.hx,
            y: center.y - half.hy,
            width: 2 * half.hx,
            height: 2 * half.hy
        )
        return faces.filter { face in
            let faceArea = Double(face.width * face.height)
            guard faceArea > 0 else { return false }
            let overlap = face.intersection(visible)
            guard !overlap.isNull else { return false }
            return Double(overlap.width * overlap.height) >= 0.98 * faceArea
        }
    }

    /// Degradation rule (spec): "if detection is weak or finds fewer faces
    /// than expected, skip the reveal beat and just assemble." Weak here
    /// means fewer than half the photos produced a face that survived the
    /// framing thresholds AND the final crop - one lucky hit across four
    /// landscapes is not a face-detection story worth telling, and a set with
    /// no faces at all (the landscape case that must keep working) skips
    /// silently. Evaluated AFTER the clipped-face filter above deliberately:
    /// a set whose faces mostly got cropped away has no story either.
    private static func shouldRevealGlows(_ plans: [MagicPhotoPlan]) -> Bool {
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
                        .opacity(controller.overlayOpacity)
                } else {
                    // The layout, before the photos are in it. Drawn UNDER
                    // the flying photos so each one lands on top of its own
                    // slot, leaving only the slot's outer bloom showing round
                    // the edges - the composition stays lit until the handoff
                    // rather than going dead the instant it fills up.
                    layoutSlots(originFix: originFix)

                    ForEach(controller.photos) { plan in
                        MorphingPhotoView(
                            progress: controller.morphProgress,
                            plan: plan,
                            originFix: originFix,
                            photoOpacity: controller.overlayOpacity,
                            glowStrength: glowStrength(for: plan)
                        )
                    }
                    if controller.beat == .scan {
                        sweepBand(in: proxy.size)
                            .opacity(controller.overlayOpacity)
                    }
                    if controller.decideFlash > 0 {
                        Color.mosaicAccent
                            .opacity(0.13 * controller.decideFlash)
                            .blendMode(.plusLighter)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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

    /// A photo's glow strength: 0 until its turn in the staggered reveal
    /// arrives, then the controller's master `glowStrength` - which stays lit
    /// through the decision flare AND the entire flight, and only burns down
    /// at the handoff. (Phase 0 wiped the boxes over the first 40% of the
    /// morph, which dropped the causal claim exactly when the motion was
    /// making it.)
    private func glowStrength(for plan: MagicPhotoPlan) -> Double {
        guard controller.glowsEnabled, !plan.faces.isEmpty else { return 0 }
        guard let index = controller.photos.firstIndex(where: { $0.id == plan.id }) else { return 0 }
        guard index < controller.revealedGlows else { return 0 }
        return controller.glowStrength
    }

    /// The decision made visible: the chosen template's cells, drawn as empty
    /// glowing slots, snapping in while the face glows flare and BEFORE any
    /// photo moves. Only ever drawn once real destination geometry exists (a
    /// missing canvas rect degrades every destRect to its source rect, and
    /// slots on the picker's own thumbnail squares would assert a layout that
    /// isn't there).
    @ViewBuilder
    private func layoutSlots(originFix: CGPoint) -> some View {
        if controller.slotReveal > 0, controller.hasResolvedDestinations,
           let canvas = controller.destinationBounds {
            let t = controller.slotReveal
            ZStack {
                ForEach(controller.photos) { plan in
                    // Slot rects in CANVAS-local space, so the snap below
                    // scales the arrangement about the canvas's own center
                    // rather than the screen's.
                    let rect = plan.destRect.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
                    ZStack {
                        // Outer bloom - the part that still shows around the
                        // photo once it has landed on the slot.
                        Rectangle()
                            .strokeBorder(Color.mosaicAccent.opacity(0.55), lineWidth: 3)
                            .blur(radius: 7)
                        Rectangle()
                            .strokeBorder(Color.mosaicAccent.opacity(0.9), lineWidth: 1)
                            .blur(radius: 0.5)
                        // A faint fill so an EMPTY slot reads as a place a
                        // photo is about to go, not as a wireframe.
                        Rectangle()
                            .fill(Color.mosaicAccent.opacity(0.06 * (1 - controller.morphProgress)))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .compositingGroup()
            .blendMode(.plusLighter)
            // Snap: the whole arrangement lands as one object, scaling from
            // just under full size. `slotReveal` is spring-driven, so this
            // overshoots a touch and settles.
            .scaleEffect(0.965 + 0.035 * t)
            .opacity(min(1, t))
            .position(x: canvas.midX - originFix.x, y: canvas.midY - originFix.y)
            .allowsHitTesting(false)
        }
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
    /// The photo pixels' own opacity. Separate from the glow's so the settle
    /// can dissolve the photo into the editor's identical one underneath
    /// while the glow keeps burning over the live result for a beat.
    var photoOpacity: Double
    /// 0 unlit, ~1 burning, ~2.1 at the decision flare.
    var glowStrength: Double

    /// All THREE animated scalars ride in `animatableData`, not just the
    /// morph. A custom `Animatable` view interpolates only what it declares
    /// here; anything else a `withAnimation` touches is applied to this view
    /// as a step change on the next frame. Phase 0 got away with one scalar
    /// because the box opacity was derived from `progress` and the layer
    /// opacity was applied by a wrapper OUTSIDE this view - the glow burn-down
    /// and the photo-layer crossfade now happen INSIDE it, so leaving them
    /// out would make both of them pop instead of fade.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(progress, glowStrength), photoOpacity) }
        set {
            progress = newValue.first.first
            glowStrength = newValue.first.second
            photoOpacity = newValue.second
        }
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
                .opacity(photoOpacity)

            if glowStrength > 0 {
                faceGlows(
                    imageOrigin: CGPoint(x: blockCenterX - frameW / 2, y: blockCenterY - frameH / 2),
                    frameSize: CGSize(width: frameW, height: frameH)
                )
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    /// Real Vision rects, in the photo's own normalized top-left space,
    /// projected through the SAME display transform as the pixels they sit
    /// on - so a glow stays welded to its face while the photo pans, zooms
    /// and flies. (That projection is Phase 0's and is deliberately
    /// untouched; only what gets DRAWN at those rects changed.)
    ///
    /// Drawn as a bloom rather than a stroke (Justin, 2026-07-28: "a glowing
    /// square around each detected face to show the magic ... it should read
    /// as energy, not as a debug overlay"). Three coincident layers, all
    /// `plusLighter` so they add into light rather than paint over the photo:
    /// a wide soft halo, a tighter one, and a thin bright edge that keeps the
    /// SQUARE legible - lose that and the bloom stops reading as "the app
    /// drew a box around this face" and starts reading as lens flare.
    ///
    /// Both the opacity and the blur radius scale with `glowStrength`, which
    /// is what makes the decision beat's flare read as the halo SWELLING
    /// rather than merely brightening.
    private func faceGlows(imageOrigin: CGPoint, frameSize: CGSize) -> some View {
        let strength = min(glowStrength, 2.2)
        let bloom = min(1.0, strength)          // opacity ramp, saturates at 1
        let flare = max(0, strength - 1)        // extra energy above "lit"
        return ForEach(Array(plan.faces.enumerated()), id: \.offset) { _, face in
            let box = CGRect(
                x: imageOrigin.x + face.minX * frameSize.width,
                y: imageOrigin.y + face.minY * frameSize.height,
                width: face.width * frameSize.width,
                height: face.height * frameSize.height
            )
            let corner = min(box.width, box.height) * 0.16
            ZStack {
                RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                    .strokeBorder(Color.mosaicAccent, lineWidth: 6 + 5 * flare)
                    .blur(radius: 9 + 7 * flare)
                    .opacity(0.42 * bloom + 0.30 * flare)
                    .scaleEffect(1 + 0.06 * flare)
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .strokeBorder(Color.mosaicAccent, lineWidth: 3)
                    .blur(radius: 3.5)
                    .opacity(0.75 * bloom + 0.25 * flare)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                    .blur(radius: 0.4)
                    .opacity(0.55 * bloom + 0.45 * flare)
            }
            .compositingGroup()
            .blendMode(.plusLighter)
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
