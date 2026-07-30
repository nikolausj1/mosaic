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
    /// B32 Phase 3 (handover): `MagicLayoutDecision.templateIndex` -
    /// `chooseCanvasAndLayout`'s index into `templates(for:)`'s fixed-order
    /// candidate list. The handover beat reconstructs that candidate's
    /// AUTHORED fractions (`templates(for: orderedPhotoIDs)[templateIndex]`)
    /// to compare against the fractions actually landed in `document.root` -
    /// which is what lets the divider capsules animate the REAL delta Phase
    /// 2's search produced, rather than a demonstration. Divider search never
    /// changes a template's topology (only its fractions and which photo
    /// permutation fills its leaves - see `searchDividerFractions`'s own doc
    /// comment in `Sources/Engine/MagicLayout.swift`), so the authored
    /// candidate and `document.root` are always the same tree SHAPE, just
    /// with (possibly) different fraction values at the same paths - exactly
    /// what the handover needs to compare.
    var templateIndex: Int
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

// MARK: - Handover (Phase 3 revision) - divider geometry

/// One interior divider the handover beat can show migrating from the
/// template's AUTHORED position (what the app would have shown WITHOUT
/// face-awareness - the honest "before" the spec's honesty line permits,
/// since it is literally what today's aspect-only path would have produced,
/// not a fabricated contrast) to the position the document ACTUALLY carries
/// (Phase 2's real divider search output). Built once, alongside the photo
/// plans, the moment real destination geometry exists - see
/// `MagicLayoutController.rebuildPlans()`.
///
/// Deliberately keyed and positioned independently of `CanvasView`'s own
/// `capsuleSpecs` (which walks per-LEAF edge ownership, so a divider shared
/// by cells of different extents along it - e.g. a big leaf beside a
/// 3-row stack - draws more than one capsule instance at different
/// sub-positions). This type instead reads the divider's FULL boundary
/// (`DividerFrame.line`, from `solve()`) and centers a capsule-shaped rect
/// on it at 50% length / 5pt thick - the same proportions `capsuleSpecs`
/// uses, just measured against the whole shared edge rather than one
/// leaf's own slice of it. That is enough for a ghost that fades OUT as the
/// real capsule fades IN nearby (see `MagicLayoutOverlay.handoverAffordances`)
/// - it does not need to register pixel-for-pixel against every nested
/// case, only land in the right neighborhood at the right moment.
struct HandoverDividerPlan: Identifiable, Equatable {
    let id: String
    let axis: Axis
    /// Canvas-local capsule rect at the template's AUTHORED fractions.
    let authoredRect: CGRect
    /// Canvas-local capsule rect at the fractions `document.root` actually
    /// carries - pixel-identical to where `CanvasView`'s own (currently
    /// held-back) capsule sits.
    let chosenRect: CGRect
    /// |chosen - authored| in FRACTION units (the same space `Node.fractions`
    /// uses - NOT a rect-space distance), because the spec's own example
    /// ("0.50 to 0.55") is stated in fraction terms and
    /// `MagicLayoutController.minVisibleDividerFractionDelta` is tuned
    /// against that same unit.
    let fractionDelta: Double
    /// Logged (spec acceptance: "before and after fractions logged") -
    /// never rendered from directly.
    let authoredFraction: Double
    let chosenFraction: Double

    /// See `MagicLayoutController.minVisibleDividerFractionDelta`'s doc
    /// comment for the reasoning behind this specific cutoff.
    var crossesVisibilityThreshold: Bool {
        fractionDelta >= MagicLayoutController.minVisibleDividerFractionDelta
    }
}

// MARK: - Rationing (Phase 3) - Settings

/// The Settings screen's three-state control for the reveal (spec:
/// "Rationing - the design, settled 2026-07-28"; REVISED by Justin,
/// 2026-07-28 evening - see `MagicLayoutController`'s "Rationing" section
/// below for the full reasoning). `.always` and `.firstTimeOnly` only differ
/// in what happens AFTER the very first reveal has played: `.always` keeps
/// showing the SAME full reveal every time (the first-collage-vs-later
/// split that used to shorten it is gone), `.firstTimeOnly` stops showing it
/// at all, same as `.off`. Reduce Motion forces the bypass regardless of
/// this setting (`MagicLayoutController.isDisabled` is checked first in
/// `begin()`).
///
/// Persisted the way this codebase already persists a preference that an
/// `@Observable` class also needs to read - plain `UserDefaults`, not
/// `@AppStorage` (see `EditorState.lastBorderThicknessDefaultsKey`'s comment
/// for why: composing `@AppStorage` with `@Observable`'s own storage isn't
/// supported, and `MagicLayoutController` is `@Observable` and is exactly
/// what needs to read this at `begin()`).
enum MagicRevealPreference: String, CaseIterable, Identifiable {
    case always
    case firstTimeOnly
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .firstTimeOnly: return "First time only"
        case .off: return "Off"
        }
    }

    static let defaultsKey = "magicLayoutRevealPreference"

    /// Defaults to `.always` - the feature ships on, matching every other
    /// path through this file, which plays unless something opts it out.
    static var current: MagicRevealPreference {
        get {
            guard
                let raw = UserDefaults.standard.string(forKey: defaultsKey),
                let value = MagicRevealPreference(rawValue: raw)
            else { return .always }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
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
        /// B32 Phase 3 revision (Justin, 2026-07-28 - "the affordances
        /// perform the work; there is no ghost fingertip"): the SECOND of
        /// the sequence's three movements ("Assemble" / "Handover" /
        /// "Invitation"). The energy that was burning on the faces migrates
        /// OUTWARD to the controls that are about to be handed to the user -
        /// the divider capsules (which genuinely move, from the template's
        /// AUTHORED fractions to the ones Phase 2's search actually chose -
        /// see `HandoverDividerPlan`) and the canvas corner brackets (which
        /// only RECEIVE the glow and never move - Phase 5's ratio decision
        /// almost never fires, so there is no true delta for them to
        /// perform yet; see `Magic Layout Spec.md`'s Phase 3 revision).
        /// Skipped ENTIRELY (not just visually suppressed) whenever
        /// `glowsEnabled` is false - a faceless set has no glow to migrate,
        /// and "nothing moves" IS the honest answer for that case, at zero
        /// added wall clock.
        case handover
        /// ~460ms: the handoff. The photo layer crossfades onto the identical
        /// editor underneath, then the last of the theater (glows, slots,
        /// scrim, and the handover's migrating capsules/brackets) fades out
        /// as the editor's own always-on affordances - the divider capsules
        /// and corner handles - come in behind it, landing exactly where the
        /// handover's ghosts left off.
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
    // verbatim and measured ~1.4s of added wall clock against the spinner;
    // Phase 3's own decide beat grew that to ~1.66s (build log,
    // 2026-07-28). The beats below are split into two groups because the
    // measurement was: arrive and scan sit ON TOP of `loadForEditing` +
    // Vision + the decision (they are free, and are NOT rationed - see
    // `arriveDuration`/`scanFloor`/`scanCap` immediately below), while
    // everything from the decision onward runs AFTER the result already
    // exists and is pure addition - that's what `PostResultTiming` below
    // exists to ration.
    //
    // REVISED (Justin, 2026-07-28 evening, verbal direction): "everyone
    // should get the longer show... this is our difference, let's celebrate
    // it" - the first-collage-vs-later split that used to shrink these
    // post-result beats on every later collage is GONE. Every reveal (that
    // plays at all - Settings and Reduce Motion still gate that) now gets
    // what was previously the first-collage-only "generous" timing. See
    // `PostResultTiming` below, now a single tuned set rather than two.
    // Separately, the scan beat's face-glow reveal - the one beat the owner
    // asked to make deliberately SLOWER, not merely un-shrunk - lives in
    // `GlowReveal` further down, split out specifically so it is NOT subject
    // to this struct's covered-work scaling either (see that type's doc).
    private static let arriveDuration = 0.25
    /// Floor on the scan beat: below this the glow reveal is a subliminal
    /// flicker rather than a beat. Only ever costs time when the document was
    /// ready almost instantly.
    private static let scanFloor = 0.30
    /// The spec's cap on the scan VISUALS. The beat itself can run longer
    /// than this when the work genuinely takes longer (the sweep just keeps
    /// going) - what's capped is how long we'd ever wait on our own account.
    private static let scanCap = 0.70

    /// The post-result beats' timings (decide, assemble, settle) -
    /// everything from the moment the layout decision is shown onward,
    /// which the spec's wall-clock measurement identified as the part of
    /// the sequence that is pure addition (arrive/scan cover real work and
    /// are untouched, aside from the glow reveal - see `GlowReveal`).
    ///
    /// REVISED (Justin, 2026-07-28 evening): this used to be TWO tuned sets
    /// - `.generous` for the first-ever collage, `.rationed` (shorter) for
    /// every later one. That split is gone: "everyone should get the longer
    /// show... this is our difference, let's celebrate it." Every reveal
    /// that plays at all now uses the single set below, unconditionally.
    /// One dial still applies on top of it: `MagicLayoutController
    /// .postResultTiming` scales every field here by how long the covered
    /// work (`loadForEditing` + Vision + the decision) actually took, so a
    /// fast Vision pass still gets a shorter show than a slow one - never
    /// hold purely for show when the result is ready. That dial is
    /// deliberately NOT applied to `GlowReveal`'s fields (see its doc): the
    /// owner is knowingly overriding that rule for the scan/glow beat
    /// specifically, so a fast Vision pass must not silently shrink the
    /// beat he asked to make slower.
    private struct PostResultTiming {
        /// Cap on `waitForResolvedPlans` - a ceiling, not a typical wait (the
        /// canvas rect usually resolves in ~30ms), but a smaller ceiling
        /// keeps a later collage's worst case bounded too.
        var resolveWaitCap: Double
        /// The decide beat's first half: the flare-up. Also how long `run()`
        /// sleeps before starting the fade-back (the two are equal by
        /// design - the flare holds exactly as long as it takes to read).
        var decideFlareDuration: Double
        /// The decide beat's fade-back ANIMATION duration - deliberately
        /// longer than `decideFadeSleepDuration` below so the ease bleeds
        /// into the first frames of assemble rather than coming to a full
        /// stop first (spec/build-log: "the beat hands off mid-gesture").
        var decideFadeAnimDuration: Double
        /// How long `run()` actually WAITS during the fade-back before
        /// moving on to assemble.
        var decideFadeSleepDuration: Double
        /// The morph's animation duration.
        var assembleDuration: Double
        /// How long the sequence actually WAITS on the morph before
        /// starting the settle. Deliberately shorter than the morph itself:
        /// near the end of this timing curve the photos are within a pixel
        /// or two of the destination the editor underneath is already
        /// drawing them at, so beginning the crossfade there is invisible.
        var assembleHold: Double
        /// The handover beat's glow crossfade - the face glow dimming as the
        /// control glow (divider capsules + corner brackets) brightens.
        /// (The divider capsules' own POSITION migration runs on a fixed,
        /// unscaled spring - see `run()` - matching how the decide beat's
        /// `slotReveal` spring is also left out of this scaling: a spring's
        /// feel is tuned once, not stretched by dial 1.)
        var handoverGlowDuration: Double
        /// How long `run()` actually holds on the handover beat before
        /// moving to settle - long enough for the capsule migration's
        /// overshoot-and-settle spring to fully land, not just start.
        var handoverHoldDuration: Double
        /// Settle's photo-layer crossfade animation duration (the overlay's
        /// photos dissolving onto the editor's identical ones underneath).
        var photoCrossfadeDuration: Double
        /// Settle's total held time. Sub-beats below are measured from the
        /// start of settle; the stagger is the point - the theater is
        /// visibly LEAVING as the controls visibly ARRIVE.
        var settleDuration: Double
        var glowOutDelay: Double
        var glowOutDuration: Double
        var chromeInDelay: Double
        var chromeInDuration: Double

        /// The ONLY set now (spec originally: "the wow is worth 1.6s exactly
        /// once" - reversed 2026-07-28, "everyone should get the longer
        /// show"). These are Phase 3's original first-collage numbers,
        /// verbatim - every reveal that plays now gets what used to be
        /// reserved for the very first one. The old `.rationed` set (the
        /// shrunk-down later-collage timing) is deleted outright rather than
        /// left dead in the file, per instruction: this is a reversal, not a
        /// fallback to quietly preserve.
        static let generous = PostResultTiming(
            resolveWaitCap: 0.25,
            decideFlareDuration: 0.10,
            decideFadeAnimDuration: 0.22,
            decideFadeSleepDuration: 0.16,
            assembleDuration: 0.50,
            assembleHold: 0.44,
            handoverGlowDuration: 0.30,
            handoverHoldDuration: 0.48,
            photoCrossfadeDuration: 0.24,
            settleDuration: 0.46,
            glowOutDelay: 0.08,
            glowOutDuration: 0.26,
            chromeInDelay: 0.22,
            chromeInDuration: 0.28
        )

        /// Dial 1: every field scaled by the same factor, so the beats'
        /// internal proportions (e.g. the fade-anim/fade-sleep bleed) hold
        /// regardless of how much the covered work compressed them.
        func scaled(by factor: Double) -> PostResultTiming {
            PostResultTiming(
                resolveWaitCap: resolveWaitCap * factor,
                decideFlareDuration: decideFlareDuration * factor,
                decideFadeAnimDuration: decideFadeAnimDuration * factor,
                decideFadeSleepDuration: decideFadeSleepDuration * factor,
                assembleDuration: assembleDuration * factor,
                assembleHold: assembleHold * factor,
                handoverGlowDuration: handoverGlowDuration * factor,
                handoverHoldDuration: handoverHoldDuration * factor,
                photoCrossfadeDuration: photoCrossfadeDuration * factor,
                settleDuration: settleDuration * factor,
                glowOutDelay: glowOutDelay * factor,
                glowOutDuration: glowOutDuration * factor,
                chromeInDelay: chromeInDelay * factor,
                chromeInDuration: chromeInDuration * factor
            )
        }
    }

    /// Fixed timing for the scan beat's per-FACE glow reveal (Justin,
    /// 2026-07-28: "we need to slow this down and make it more obvious.
    /// Really celebrate it" / "spend the extra time showing MORE, not
    /// waiting longer"). Deliberately its own type, separate from
    /// `PostResultTiming`, for two reasons:
    ///
    /// 1. It is NOT subject to dial 1 (`PostResultTiming.scaled(by:)`). The
    ///    owner is knowingly overriding "never hold purely for show when the
    ///    result is ready" for exactly this beat - he is willing to pay a
    ///    full extra second so the face-detection beat reads as causally
    ///    connected to the layout that follows. Scaling it down whenever
    ///    Vision comes back quickly (which is the common case on-device,
    ///    unlike the simulator's CPU fallback) would silently undo the
    ///    override the moment it mattered most.
    /// 2. It only ever runs when `glowsEnabled` - a faceless/landscape set
    ///    takes the degrade path before this code is reached at all, so it
    ///    never pays for a beat with nothing to show (spec's "never
    ///    advertise a miss", now doubly true: nothing to advertise, nothing
    ///    to wait for either).
    ///
    /// The reveal is keyed to individual FACES, not photos: `run()` flattens
    /// every surviving face across all photos into one ordered sequence
    /// (photo order, then face order within a photo) and lights them one at
    /// a time, so a photo with several faces reads as "found... found...
    /// found" exactly like four single-face photos would, rather than
    /// popping in as one block per photo (Phase 3's original behavior).
    private enum GlowReveal {
        /// Gap between consecutive faces lighting, before the span cap below
        /// compresses it.
        static let stagger = 0.22
        /// Each face's own fade-in, once its turn arrives - long enough to
        /// register as a discrete "found", not a flicker.
        static let stepDuration = 0.22
        /// The shared brightness envelope's very first rise (see
        /// `MagicLayoutOverlay.glowStrength(for:)` - gates on a PLAN's first
        /// face lighting), kept close to `stepDuration` so the first face
        /// doesn't look slower to arrive than the rest.
        static let inDuration = 0.24
        /// Ceiling on the total stagger WALK (first face lighting to last),
        /// regardless of how many faces were detected - a busy group shot
        /// compresses the per-face gap rather than ballooning past this.
        static let maxStaggerSpan = 1.15
        /// Held AFTER the last face lights, before the decide flare - the
        /// beat the owner asked for explicitly: a moment to register "found
        /// N faces" as a settled fact, not just the last flicker of a loop.
        static let postHoldDuration = 0.35
    }

    /// What `PostResultTiming.generous`'s numbers were tuned against:
    /// roughly what `loadForEditing` + Vision + the decision take on the
    /// covered-work path they're meant to hide behind. A run whose covered
    /// work finished faster than this scales every post-result beat down
    /// proportionally (dial 1); a run that took longer never gets MORE than
    /// the tuned numbers (scale is capped at 1) - "never hold purely for
    /// show when the result is ready" cuts both ways. Does NOT apply to
    /// `GlowReveal` - see its doc for why that beat is deliberately exempt.
    private static let referenceCoveredWork = 1.0
    /// Floor on dial 1's scale: a beat that shrank below half its designed
    /// length stops reading as motion at all, so the covered-work cap never
    /// pushes a run past this regardless of how fast the work was.
    private static let minPostResultScale = 0.5

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
    /// How many individual FACES have had their glows lit so far, out of
    /// the flattened per-face reveal order `run()` walks (photo order, then
    /// face order within a photo - see `GlowReveal`). Revised 2026-07-28
    /// from a per-PHOTO counter: a photo with several faces used to light
    /// them all as one block, which undersold a group shot exactly where
    /// the "found... found... found" story is most worth telling.
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

    /// Handover beat (Phase 3 revision): brightness of the CONTROL glow - the
    /// divider capsules and corner brackets lighting up - independent of
    /// `glowStrength` (the FACE glow) so the two can crossfade against each
    /// other (faces dim as controls brighten) rather than being forced to
    /// share one envelope. 0 before/after the handover; ramps to 1 during it.
    private(set) var controlGlowStrength: Double = 0
    /// 0...1: how far the migrating divider capsules have travelled from
    /// their AUTHORED position to the CHOSEN one (see `HandoverDividerPlan`).
    /// Driven by a spring (overshoot-and-settle, per the spec's own guidance
    /// on imperceptible deltas) so a real-but-small move still reads as
    /// motion without overselling it.
    private(set) var handoverProgress: Double = 0
    /// Built once, when destinations resolve, alongside `photos` - see
    /// `rebuildPlans()`. Empty on the faceless degrade path (no `glowsEnabled`
    /// means the handover beat never runs at all, so this is simply never
    /// consulted there) and whenever `completion`/`canvasRect` aren't ready.
    private(set) var handoverDividers: [HandoverDividerPlan] = []

    /// Below this, even an overshoot-eased migration would be manufacturing
    /// drama the actual move doesn't support (spec: "a divider moving 0.50
    /// to 0.55 may not read at all... below some threshold it is better to
    /// skip the emphasis entirely than to manufacture drama - pick a
    /// threshold"). CHOSEN VALUE, reported rather than decided: 0.03 (3
    /// percentage points of fraction space). Reasoning: Phase 2's own search
    /// grid (`dividerSearchGrid = [0.3, 0.4, 0.5, 0.6, 0.7]`, a 0.1 step in
    /// the LOCAL pair's own split point) can only ever produce a non-zero
    /// GLOBAL fraction delta of roughly 0.05 or more on the smallest real
    /// pair (a 4-way split's adjacent pair sums to 0.5 of that node's own
    /// 1.0, so 0.1 x 0.5 = 0.05) - so 0.03 sits comfortably below every real
    /// non-zero move this codebase can actually produce, while still
    /// excluding a hypothetical near-zero artifact (e.g. coordinate descent
    /// nudging an authored 1/3 to the nearest grid point 0.3, a ~0.02 global
    /// delta) from being dramatized. On a typical ~350pt canvas short edge,
    /// 0.03 of it is roughly 10pt of capsule travel - this is a judgment
    /// call about where "real but not worth animating" begins, and it wants
    /// a phone in hand to confirm, same as the rest of this beat's pacing.
    static let minVisibleDividerFractionDelta = 0.03

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
    /// A second, softer tap at the moment the handover beat starts - the
    /// physical cue that "the controls just became yours," parallel to
    /// `decisionHaptic`'s tap at "the layout was just chosen." Deliberately
    /// gentler (0.6 vs `decisionHaptic`'s 0.9 intensity): the decide beat is
    /// the loud moment, handover is a quieter one.
    private let handoverHaptic = UIImpactFeedbackGenerator(style: .soft)

    // MARK: - Rationing (Phase 3)

    /// `CFAbsoluteTimeGetCurrent()` at `begin()` - the "sequence start" half
    /// of the covered-work measurement the spec asks for.
    private var beginTime: CFAbsoluteTime = 0
    /// `documentReady()`'s timestamp minus `beginTime` - the "document
    /// landing" half. 0 until the document lands, which is also the safe
    /// "don't scale" default `postResultTiming` reads.
    private(set) var coveredWorkDuration: Double = 0

    /// The actual timing this run's decide/assemble/settle beats use:
    /// `PostResultTiming.generous` - the only set there is now - scaled by
    /// how long the covered work actually took (dial 1, still live).
    /// Computed fresh rather than cached because `coveredWorkDuration` is
    /// still 0 the instant `documentReady` fires (set in the same call) and
    /// only becomes final once the scan beat's wait loop has observed it -
    /// by the time `run()` reaches the decide beat this is stable.
    private var postResultTiming: PostResultTiming {
        let base = PostResultTiming.generous
        guard coveredWorkDuration > 0 else { return base }
        let scale = min(1, max(Self.minPostResultScale, coveredWorkDuration / Self.referenceCoveredWork))
        return base.scaled(by: scale)
    }

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

    /// True once the reveal has ever played to completion, UNSKIPPED, on
    /// this device - set exactly once, at the bottom of `run()`'s natural
    /// (non-cancelled) path. Every reveal is now the same (formerly
    /// "generous") show, so this flag's only remaining job is
    /// `MagicRevealPreference.firstTimeOnly`: whether a reveal plays again AT
    /// ALL. (It used to also pick a run's tier; that dial is gone - see the
    /// "Rationing" revision above `PostResultTiming`.) Plain `UserDefaults`
    /// for the same reason as `MagicRevealPreference` above.
    private static let hasPlayedFullRevealDefaultsKey = "magicLayoutHasPlayedFullReveal"
    static var hasPlayedFullReveal: Bool {
        get { UserDefaults.standard.bool(forKey: hasPlayedFullRevealDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasPlayedFullRevealDefaultsKey) }
    }

    /// Starts the sequence. Returns false when the sequence is bypassed
    /// (Reduce Motion / `-magicLayoutOff` / the Settings preference), in
    /// which case the caller must keep its old spinner-and-commit behavior.
    @discardableResult
    func begin(sources: [MagicSource]) -> Bool {
        guard !isActive else { return true }
        guard !Self.isDisabled else {
            MagicTiming.mark("sequence bypassed (Reduce Motion / -magicLayoutOff)")
            return false
        }
        // Settings' three-state control (spec: "Rationing"). Checked AFTER
        // Reduce Motion so that one always wins regardless of this setting,
        // and BEFORE the empty-sources guard so `-magicSlow`/timing marks
        // stay meaningful for whichever reason a run didn't happen.
        let preference = MagicRevealPreference.current
        if preference == .off {
            MagicTiming.mark("sequence bypassed (Settings: Off)")
            return false
        }
        if preference == .firstTimeOnly, Self.hasPlayedFullReveal {
            MagicTiming.mark("sequence bypassed (Settings: First Time Only, already played)")
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
        beginTime = CFAbsoluteTimeGetCurrent()
        coveredWorkDuration = 0
        scrim = 0
        overlayOpacity = 0
        glowStrength = 0
        slotReveal = 0
        decideFlash = 0
        controlGlowStrength = 0
        handoverProgress = 0
        handoverDividers = []
        suppressEditorChrome = true
        beat = .arrive
        decisionHaptic.prepare()
        handoverHaptic.prepare()
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
        // Dial 1's measurement: "from sequence start to the document
        // landing" (spec), taken exactly once per run - `beginTime > 0`
        // guards against a stray second call (there isn't one today, but
        // this must never double-count).
        if beginTime > 0, coveredWorkDuration == 0 {
            coveredWorkDuration = CFAbsoluteTimeGetCurrent() - beginTime
        }
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
        controlGlowStrength = 0
        handoverProgress = 0
        handoverDividers = []
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

        // Everything from here on structurally runs AFTER the document
        // exists - the "after the result already exists" half of the spec's
        // measurement. Resolved once, now, rather than read live off
        // `postResultTiming` at each step: `coveredWorkDuration` is stable
        // the instant the wait loop above exits (`documentReady` set it
        // synchronously before `completion` itself), and a single snapshot
        // keeps this run's pacing internally consistent even if something
        // odd raced the computed property. (The glow-reveal stagger just
        // below is deliberately NOT part of `timing` - it reads `GlowReveal`
        // instead, fixed and unscaled - see that type's doc for why.)
        let timing = postResultTiming

        // `documentReady` just ran `rebuildPlans()` synchronously, almost
        // certainly before the canvas rect existed (see the comment there) -
        // so `glowsEnabled` cannot yet reflect a real decision. Wait,
        // briefly and capped, for the resolved rebuild `canvasFrameChanged`
        // triggers before reading `glowsEnabled` below. A glow that starts
        // ~30ms later (the measured real-world gap) is far better than one
        // that has to retract.
        await waitForResolvedPlans(cap: timing.resolveWaitCap)
        guard !Task.isCancelled else { return }

        // Real glows on real detections, staggered PER FACE (2026-07-28
        // revision - see `GlowReveal`) so they read as "found, then found,
        // then found" rather than appearing as one block per photo. Skipped
        // wholesale when detection is weak (never advertise a miss) - or when
        // destinations never resolved at all, in which case `glowsEnabled`
        // is still sitting at its safe `begin()` default, `false`. This is
        // also, deliberately, the one beat the owner asked to make slower
        // rather than merely un-rationed - "spend the extra time showing
        // MORE, not waiting longer" - so the span below is a real walk
        // across individual faces plus a hold, not a sleep for its own sake.
        let totalGlowFaces = photos.reduce(0) { $0 + $1.faces.count }
        if glowsEnabled, totalGlowFaces > 0 {
            MagicTiming.mark("glow reveal begin (\(totalGlowFaces) faces)")
            withAnimation(.easeOut(duration: Self.scaled(GlowReveal.inDuration))) { glowStrength = 1 }
            let span = min(GlowReveal.stagger * Double(max(totalGlowFaces - 1, 0)), GlowReveal.maxStaggerSpan)
            let perFaceGap = totalGlowFaces > 1 ? span / Double(totalGlowFaces - 1) : 0
            for _ in 0..<totalGlowFaces {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: Self.scaled(GlowReveal.stepDuration))) { revealedGlows += 1 }
                await sleep(perFaceGap)
            }
            // The consolidation beat: hold on "found N faces" before the
            // decide flare erases the count by turning every glow into one
            // undifferentiated flare.
            await sleep(GlowReveal.postHoldDuration)
            MagicTiming.mark("glow reveal end")
            guard !Task.isCancelled else { return }
        }
        // The floor, measured from the START of the scan beat, so slow work
        // pays nothing for it. Unrationed (arrive/scan's own floor, not a
        // `PostResultTiming` field) - only engages when the document arrived
        // faster than the floor itself; irrelevant whenever the glow walk
        // above already ran longer, which it now usually does.
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
        await waitForResolvedPlans(cap: timing.resolveWaitCap)
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
        withAnimation(.easeOut(duration: Self.scaled(timing.decideFlareDuration))) {
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
        await sleep(timing.decideFlareDuration)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: Self.scaled(timing.decideFadeAnimDuration))) {
            if glowsEnabled { glowStrength = 1.15 }
            decideFlash = 0
        }
        await sleep(timing.decideFadeSleepDuration)
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
        withAnimation(.timingCurve(0.22, 0.68, 0.16, 1, duration: Self.scaled(timing.assembleDuration))) {
            morphProgress = 1
        }
        await sleep(timing.assembleHold)
        guard !Task.isCancelled else { return }

        // BEAT "HANDOVER" (Phase 3 revision, Justin 2026-07-28 evening -
        // "the affordances perform the work; there is no ghost fingertip").
        // The energy that has been burning on the faces migrates OUTWARD to
        // the controls the user is about to be handed: the divider capsules
        // (which genuinely move, from `HandoverDividerPlan.authoredRect` to
        // `.chosenRect` - Phase 2's real search output, never a
        // demonstration) and the corner brackets (which only RECEIVE the
        // glow and never move - Phase 5's ratio decision almost never fires
        // today, so there is no true delta for them to perform yet).
        //
        // Gated on `glowsEnabled`, and nothing else: with no face glow
        // burning in the first place (the faceless degrade path) there is
        // nothing to migrate, and skipping the WHOLE beat - not merely its
        // visuals - is what keeps that case genuinely free (spec: "NOTHING
        // SHOULD MOVE... stillness signals it did not [find something]").
        if glowsEnabled {
            beat = .handover
            let migratingCount = handoverDividers.filter(\.crossesVisibilityThreshold).count
            MagicTiming.mark("handover begin (\(migratingCount)/\(handoverDividers.count) dividers migrating)")
            #if DEBUG
            for d in handoverDividers {
                NSLog("MAGIC handover divider %@: authored=%.4f chosen=%.4f delta=%.4f %@",
                      d.id, d.authoredFraction, d.chosenFraction, d.fractionDelta,
                      d.crossesVisibilityThreshold ? "MIGRATES" : "below threshold (static)")
            }
            #endif
            handoverHaptic.impactOccurred(intensity: 0.6)
            // The crossfade of LIGHT: faces dim as the controls brighten -
            // same accent, same bloom language, just changing where it
            // burns. Not wrapped in `Self.scaled` for the spring below
            // (see the decide beat's `slotReveal` spring, same reasoning:
            // a spring's feel is tuned once, not stretched by `-magicSlow`
            // or dial 1 - only the SLEEP that gates the next beat is).
            withAnimation(.easeInOut(duration: Self.scaled(timing.handoverGlowDuration))) {
                controlGlowStrength = 1
                glowStrength = 0.55
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                handoverProgress = 1
            }
            await sleep(timing.handoverHoldDuration)
            guard !Task.isCancelled else { return }
            MagicTiming.mark("handover end")
        }

        // BEAT 5 - SETTLE / HANDOFF. Three staggered sub-beats, in this
        // order, because the order IS the message: the composition becomes
        // real (the overlay's photos dissolve into the editor's identical
        // ones), the energy burns down, and the controls arrive. By the last
        // frame there is no glow, no slot, no sweep, no scrim and no dimming
        // anywhere - if any of it lingered, the user would still be waiting
        // for permission to touch the thing.
        beat = .settle
        withAnimation(.easeInOut(duration: Self.scaled(timing.photoCrossfadeDuration))) {
            overlayOpacity = 0
            scrim = 0
        }
        await sleep(timing.glowOutDelay)
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: Self.scaled(timing.glowOutDuration))) {
            glowStrength = 0
            slotReveal = 0
            // The handover's ghost capsules/brackets finish fading out on
            // the SAME curve the face glow burns down on - one continuous
            // dimming of every piece of theater, matched against
            // `revealEditorChrome` (below) fading the REAL chrome in.
            controlGlowStrength = 0
        }
        await sleep(timing.chromeInDelay - timing.glowOutDelay)
        guard !Task.isCancelled else { return }
        revealEditorChrome(duration: timing.chromeInDuration)
        await sleep(timing.settleDuration - timing.chromeInDelay)
        guard !Task.isCancelled else { return }
        // Reached only on the UNSKIPPED natural path (a skip cancels the
        // task, which returns out of every `guard !Task.isCancelled` above
        // before ever reaching here) - so this is exactly "the full reveal
        // played, to completion, and the user actually saw it", which is
        // what `MagicRevealPreference.firstTimeOnly` keys off of to decide
        // whether a later reveal plays at all.
        Self.hasPlayedFullReveal = true
        finish()
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * Self.timeScale * 1_000_000_000))
    }

    /// Every `withAnimation` duration goes through here so `-magicSlow`
    /// stretches the visible motion and the beat sleeps by the same factor.
    private static func scaled(_ seconds: Double) -> Double { seconds * timeScale }

    /// `GlowReveal.stepDuration`, pre-scaled by `-magicSlow` - exposed
    /// (rather than `timeScale` itself, which is private) so
    /// `MagicLayoutOverlay`'s renderer can give each individual face's own
    /// `.animation(value:)` the SAME duration the stagger loop in `run()`
    /// paces by, without duplicating the debug time-scale logic on the view
    /// side.
    var faceGlowStepDuration: Double { Self.scaled(GlowReveal.stepDuration) }

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

        // Handover geometry (Phase 3 revision): built alongside the photo
        // plans above, once real destination geometry exists, so the
        // divider capsules can migrate from the template's AUTHORED
        // fractions to the ones `doc.root` actually carries. See
        // `HandoverDividerPlan`'s own doc comment for why this is a
        // separate, simpler geometry pass rather than reusing the photo
        // cells' own `cellRectByID` above.
        if canvasRect.width > 0, canvasRect.height > 0 {
            handoverDividers = Self.buildHandoverDividers(completion: completion, canvasSize: canvasRect.size)
        } else {
            handoverDividers = []
        }

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

    // MARK: - Handover geometry (Phase 3 revision)

    /// Identifies one interior divider the same way `Layout.swift`'s own
    /// `DividerFrame` does: the path to the owning `.split` node, plus which
    /// of its dividers (`index` separates child `index` from `index + 1`).
    private struct DividerKey: Hashable {
        let path: [Int]
        let index: Int
    }

    /// Every interior divider's OWN fraction (`fractions[index]`, from the
    /// `.split` node at `path`) - the raw number the spec's acceptance
    /// criterion wants logged, and the value `crossesVisibilityThreshold`
    /// compares across the authored/chosen pair. Reading `fractions[index +
    /// 1]` instead would give the mirror-image delta (their sum is
    /// preserved by every divider mutation - see `Node`'s own invariant
    /// comment in Model.swift), so either side is equally valid; `index` is
    /// arbitrary but must be used consistently, which this single walk
    /// guarantees.
    private static func dividerFractions(in root: Node) -> [DividerKey: Double] {
        var result: [DividerKey: Double] = [:]
        func walk(_ node: Node, path: [Int]) {
            guard case .split(_, let fractions, let children) = node else { return }
            for i in 0..<(fractions.count - 1) {
                result[DividerKey(path: path, index: i)] = fractions[i]
            }
            for (i, child) in children.enumerated() {
                walk(child, path: path + [i])
            }
        }
        walk(root, path: [])
        return result
    }

    /// Converts a `DividerFrame.line` (the FULL boundary strip `Layout.swift`
    /// returns - zero-thickness at the zero-border default a fresh pick
    /// always starts with, collapsing exactly to the boundary line) into a
    /// capsule-shaped rect: 50% of the edge's length, centered, 5pt thick -
    /// the same proportions `GestureController.capsuleSpecs` draws the real
    /// interactive capsule at. See `HandoverDividerPlan`'s doc comment for
    /// why this is a deliberately SIMPLER derivation than that function's
    /// (which is per-leaf-edge and can therefore differ at a T-junction).
    private static func capsuleRect(fromLine line: CGRect, axis: Axis) -> CGRect {
        let thickness: CGFloat = 5
        switch axis {
        case .horizontal:
            // Children side by side -> dividers are VERTICAL lines: `line`
            // is a tall, gutter-width-wide strip (see Layout.swift).
            let h = line.height * 0.5
            return CGRect(x: line.midX - thickness / 2, y: line.midY - h / 2, width: thickness, height: h)
        case .vertical:
            // Children stacked -> dividers are HORIZONTAL lines: `line` is
            // a wide, gutter-height-tall strip.
            let w = line.width * 0.5
            return CGRect(x: line.midX - w / 2, y: line.midY - thickness / 2, width: w, height: thickness)
        }
    }

    /// Builds one `HandoverDividerPlan` per interior divider in the document
    /// - see that type's own doc comment for the full reasoning. Returns
    /// empty (rather than guessing) whenever the authored/chosen trees don't
    /// correspond divider-for-divider, which per `PickCompletion
    /// .templateIndex`'s contract should never actually happen (Phase 2
    /// never restructures a template's topology) - this is a defensive
    /// bail-out, not an expected path.
    private static func buildHandoverDividers(completion: PickCompletion, canvasSize: CGSize) -> [HandoverDividerPlan] {
        let doc = completion.document
        let orderedIDs = completion.orderedPhotoIDs
        guard (2...4).contains(orderedIDs.count) else { return [] }
        let candidates = templates(for: orderedIDs)
        guard !candidates.isEmpty else { return [] }
        let index = min(max(completion.templateIndex, 0), candidates.count - 1)
        let authoredTemplate = candidates[index]

        let (_, chosenDividers) = solve(root: doc.root, canvasSize: canvasSize, border: doc.border)
        let (_, authoredDividers) = solve(root: authoredTemplate, canvasSize: canvasSize, border: doc.border)
        guard chosenDividers.count == authoredDividers.count else { return [] }

        let authoredByKey = Dictionary(uniqueKeysWithValues: authoredDividers.map {
            (DividerKey(path: $0.path, index: $0.index), $0)
        })
        let chosenFractionsByKey = dividerFractions(in: doc.root)
        let authoredFractionsByKey = dividerFractions(in: authoredTemplate)

        var plans: [HandoverDividerPlan] = []
        for chosen in chosenDividers {
            let key = DividerKey(path: chosen.path, index: chosen.index)
            guard let authored = authoredByKey[key],
                  let chosenFrac = chosenFractionsByKey[key],
                  let authoredFrac = authoredFractionsByKey[key] else { continue }
            plans.append(HandoverDividerPlan(
                id: "\(key.path)-\(key.index)",
                axis: chosen.axis,
                authoredRect: capsuleRect(fromLine: authored.line, axis: authored.axis),
                chosenRect: capsuleRect(fromLine: chosen.line, axis: chosen.axis),
                fractionDelta: abs(chosenFrac - authoredFrac),
                authoredFraction: authoredFrac,
                chosenFraction: chosenFrac
            ))
        }
        return plans
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
                            glowStrength: glowStrength(for: plan),
                            revealedFaceMask: revealedFaceMask(for: plan),
                            faceRevealStepDuration: controller.faceGlowStepDuration
                        )
                    }
                    if controller.beat == .scan {
                        sweepBand(in: proxy.size)
                            .opacity(controller.overlayOpacity)
                    }
                    // Handover (Phase 3 revision): drawn ON TOP of the
                    // photos, same as the real divider capsules/corner
                    // brackets are drawn on top of the cells in CanvasView -
                    // so the migrating glow reads as sitting on the seam,
                    // not behind the photo.
                    if controller.controlGlowStrength > 0 {
                        handoverAffordances(originFix: originFix)
                    }
                    if controller.decideFlash > 0 {
                        // 0.13 -> 0.17 (2026-07-28, "really celebrate it"):
                        // a touch more wash at the moment the layout lands.
                        Color.mosaicAccent
                            .opacity(0.17 * controller.decideFlash)
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

    /// A photo's shared brightness ENVELOPE: 0 until the FIRST of its faces
    /// lights, then the controller's master `glowStrength` - which stays lit
    /// through the decision flare AND the entire flight, and only burns down
    /// at the handoff. (Phase 0 wiped the boxes over the first 40% of the
    /// morph, which dropped the causal claim exactly when the motion was
    /// making it.) This is the SWELL/FLARE/BURN-DOWN curve shared by every
    /// already-revealed face in the plan; which INDIVIDUAL faces have
    /// started revealing at all is a separate, per-face question - see
    /// `revealedFaceMask(for:)`.
    private func glowStrength(for plan: MagicPhotoPlan) -> Double {
        guard controller.glowsEnabled, !plan.faces.isEmpty else { return 0 }
        guard flatFaceIndex(planID: plan.id, faceIndex: 0) < controller.revealedGlows else { return 0 }
        return controller.glowStrength
    }

    /// Per-face reveal gate, parallel to `plan.faces`: true once THIS face's
    /// slot in the flattened per-face stagger order (`run()`'s loop, photo
    /// order then face order within a photo) has been reached. Consumed by
    /// `MorphingPhotoView.faceGlows`, which fades each face in independently
    /// via its own `.animation(value:)` rather than through the shared
    /// `glowStrength` envelope above - that's what produces "found... found
    /// ... found" for faces sharing one photo, not just faces across
    /// different photos.
    private func revealedFaceMask(for plan: MagicPhotoPlan) -> [Bool] {
        guard controller.glowsEnabled else { return Array(repeating: false, count: plan.faces.count) }
        let base = flatFaceIndex(planID: plan.id, faceIndex: 0)
        return plan.faces.indices.map { base + $0 < controller.revealedGlows }
    }

    /// A face's position in the flattened (photo order, then face order
    /// within a photo) reveal sequence `run()`'s stagger loop counts
    /// against - the two must agree exactly on ordering, or a face's mask
    /// bit would flip out of step with the loop that's supposedly lighting
    /// it. Bounded by the 2-4 photo cap and a handful of faces each, so a
    /// linear scan per call (called per rendered face, every frame the
    /// reveal is progressing) is cheap.
    private func flatFaceIndex(planID: PhotoID, faceIndex: Int) -> Int {
        var count = 0
        for p in controller.photos {
            if p.id == planID { return count + faceIndex }
            count += p.faces.count
        }
        return count + faceIndex
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

    // MARK: - Handover (Phase 3 revision)

    /// The energy migrating outward: a glowing ghost capsule per divider
    /// (traveling from its AUTHORED position to its CHOSEN one when the move
    /// clears `MagicLayoutController.minVisibleDividerFractionDelta`, static
    /// otherwise - see `HandoverDividerPlan`), plus a glow at each of the
    /// four canvas corners for the brackets. The brackets NEVER move here -
    /// only capsules that genuinely moved do (spec: "nothing moves for
    /// show"; brackets specifically "may RECEIVE the glow... but must NOT
    /// move or reshape the canvas" until Phase 5's ratio decision genuinely
    /// fires). These ghosts fade out in `settle` on the same curve the real
    /// `CanvasView` chrome fades IN on (`controlGlowStrength` and
    /// `revealEditorChrome` are driven together in `run()`), so the ghost
    /// hands off to the real, static affordance rather than the two ever
    /// being seen at full strength simultaneously.
    @ViewBuilder
    private func handoverAffordances(originFix: CGPoint) -> some View {
        if let canvas = controller.destinationBounds {
            ZStack {
                ForEach(controller.handoverDividers) { divider in
                    let rect = divider.crossesVisibilityThreshold
                        ? Self.lerp(divider.authoredRect, divider.chosenRect, controller.handoverProgress)
                        : divider.chosenRect
                    capsuleGlow(rect: rect)
                }
                ForEach(BracketCorner.allCases, id: \.self) { corner in
                    bracketGlow(corner: corner, canvasSize: canvas.size)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .compositingGroup()
            .blendMode(.plusLighter)
            .opacity(controller.controlGlowStrength)
            .position(x: canvas.midX - originFix.x, y: canvas.midY - originFix.y)
            .allowsHitTesting(false)
        }
    }

    /// One migrating (or, below threshold, static) divider capsule's glow -
    /// same three-layer bloom language `MorphingPhotoView.faceGlows` uses
    /// for a face (wide soft halo, tighter halo, thin bright edge), so the
    /// "same energy, new home" claim reads visually, not just conceptually.
    private func capsuleGlow(rect: CGRect) -> some View {
        ZStack {
            Capsule()
                .fill(Color.mosaicAccent)
                .blur(radius: 10)
                .opacity(0.55)
            Capsule()
                .fill(Color.mosaicAccent)
                .blur(radius: 3.5)
                .opacity(0.85)
            Capsule()
                .fill(Color.white.opacity(0.9))
                .blur(radius: 0.5)
                .opacity(0.5)
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .position(x: rect.midX, y: rect.midY)
    }

    /// A corner bracket's glow - a small blurred "L" at exactly
    /// `bracketAnchor`'s vertex (the same fixed point `CanvasView.
    /// bracketsOverlay` draws the real, always-visible bracket at). Reuses
    /// `bracketAnchor` for POSITION parity with the real bracket but draws
    /// its own simplified glyph rather than reusing `CanvasView`'s private
    /// `BracketShape` - this is transient theater that fades out the moment
    /// the real bracket fades in, so it only needs to read as "the same
    /// corner, lighting up," not register stroke-for-stroke.
    private func bracketGlow(corner: BracketCorner, canvasSize: CGSize) -> some View {
        let anchor = bracketAnchor(corner, canvasSize: canvasSize)
        return ZStack {
            HandoverBracketGlyph(corner: corner)
                .stroke(Color.mosaicAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .blur(radius: 8)
                .opacity(0.6)
            HandoverBracketGlyph(corner: corner)
                .stroke(Color.mosaicAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .blur(radius: 2)
                .opacity(0.85)
        }
        .frame(width: 22, height: 22)
        .position(x: anchor.x, y: anchor.y)
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

/// A simplified glow glyph for one corner bracket, matching `CanvasView.
/// BracketShape`'s "L" geometry (two strokes meeting at the canvas vertex)
/// closely enough to read as the same affordance, without depending on that
/// private type. See `MagicLayoutOverlay.bracketGlow`'s doc comment for why
/// this doesn't need to be pixel-identical.
private struct HandoverBracketGlyph: Shape {
    let corner: BracketCorner

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height)
        switch corner {
        case .topLeft:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        case .topRight:
            p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        case .bottomLeft:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY - len))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        case .bottomRight:
            p.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        }
        return p
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
    /// 0 unlit, ~1 burning, ~2.1 at the decision flare. Shared by every
    /// ALREADY-REVEALED face in this plan - the swell/flare/burn-down
    /// envelope, not the individual reveal-in (see `revealedFaceMask`).
    var glowStrength: Double
    /// Parallel to `plan.faces`: which individual faces have reached their
    /// turn in the flattened per-face stagger (`MagicLayoutController.run()`
    /// / `MagicLayoutOverlay.revealedFaceMask(for:)`). Deliberately NOT part
    /// of `animatableData` below - each face fades itself in independently
    /// via its own `.animation(value:)` inside `faceGlows`, which works
    /// correctly whether or not this view's outer Animatable interpolation
    /// happens to be mid-frame for `progress`/`glowStrength` at the same
    /// moment, because that per-face animation is keyed off its own value
    /// transition, not off this struct's frame-by-frame data.
    let revealedFaceMask: [Bool]
    /// `GlowReveal.stepDuration`, already `-magicSlow`-scaled - handed down
    /// from the controller (see its doc) so each face's own fade-in below
    /// runs at the same pace the stagger loop paces by.
    let faceRevealStepDuration: Double

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
    ///
    /// REVISED (Justin, 2026-07-28: "we need to slow this down and make it
    /// more obvious. Really celebrate it"): every layer's width/opacity/blur
    /// was turned up from Phase 0's numbers, and each face now fades in and
    /// pops to its full size INDEPENDENTLY - gated by `revealedFaceMask`,
    /// not by the plan-wide `glowStrength` envelope alone - so a photo with
    /// several faces still reads as a sequence of individual "founds" rather
    /// than one block lighting at once.
    private func faceGlows(imageOrigin: CGPoint, frameSize: CGSize) -> some View {
        let strength = min(glowStrength, 2.2)
        let bloom = min(1.0, strength)          // opacity ramp, saturates at 1
        let flare = max(0, strength - 1)        // extra energy above "lit"
        return ForEach(Array(plan.faces.enumerated()), id: \.offset) { index, face in
            let box = CGRect(
                x: imageOrigin.x + face.minX * frameSize.width,
                y: imageOrigin.y + face.minY * frameSize.height,
                width: face.width * frameSize.width,
                height: face.height * frameSize.height
            )
            let corner = min(box.width, box.height) * 0.16
            let revealed = index < revealedFaceMask.count && revealedFaceMask[index]
            ZStack {
                RoundedRectangle(cornerRadius: corner + 5, style: .continuous)
                    .strokeBorder(Color.mosaicAccent, lineWidth: 8 + 6 * flare)
                    .blur(radius: 11 + 8 * flare)
                    .opacity(0.55 * bloom + 0.35 * flare)
                    .scaleEffect(1 + 0.08 * flare)
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .strokeBorder(Color.mosaicAccent, lineWidth: 4)
                    .blur(radius: 4)
                    .opacity(0.85 * bloom + 0.30 * flare)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .blur(radius: 0.4)
                    .opacity(0.65 * bloom + 0.5 * flare)
            }
            .compositingGroup()
            .blendMode(.plusLighter)
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
            // The individual "found" pop: each face arrives on its own,
            // scaling up from just under full size as it fades in, rather
            // than every face in a photo snapping to full brightness at
            // once the instant the plan's shared envelope turns on.
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.8)
            .animation(.easeOut(duration: faceRevealStepDuration), value: revealed)
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
