// Sources/Engine/CanvasRatio.swift
// B32 Phase 5 - the canonical canvas-ratio preset list, plus the crude
// orientation-only rule that nominates a single "challenger" ratio for
// `MagicLayout.swift`'s `chooseCanvasAndLayout` to weigh against the square
// default. See `Magic Layout Spec.md`'s Phase 5 section for the why; this
// file is the how. Pure Foundation/CoreGraphics, same rules as the rest of
// `Sources/Engine`.
//
// TWO DISAGREEING LISTS EXISTED BEFORE THIS FILE (App layer, not Engine):
//   - `Sources/App/Prototype/BottomBar/RatioTrayView.swift` ships 6 chips
//     (1:1, 4:5, 3:4, 2:3, 9:16, 16:9) - the "un-flipped" orientation of
//     each preset; tapping the ACTIVE chip flips it in place (w:h -> h:w),
//     so all 9 shapes below are reachable through the tray, just not all
//     independently labeled.
//   - `Sources/App/Prototype/GestureController.swift`'s `ratioPresets`
//     (used for bracket-drag snapping) already lists the full 9, flips
//     included: (1,1), (4,5), (5,4), (3,4), (4,3), (2,3), (3,2), (9,16),
//     (16,9).
// `canonicalRatioPresets` below is the ONE list the Engine defines - it
// matches GestureController's fuller 9-entry set (the tray's 6 are exactly
// its unflipped half). This file does NOT edit either App file - the App
// layer still needs to be rewired to reference this list instead of
// maintaining its own; see the Phase 5 build-log entry for the exact call
// sites.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The full set of ratio shapes reachable through the app's own ratio tray
/// and bracket-drag snapping - see this file's header for where each entry
/// came from. Order matches `GestureController.ratioPresets` (square first,
/// then each destination pair un-flipped/flipped together, narrowest last).
/// This is the ONLY list `chooseCanvasAndLayout` is allowed to pick a
/// challenger from (see `Magic Layout Spec.md`: "Constrain the search to the
/// RATIO PRESETS, deliberately" - ratio encodes destination, not just
/// composition, so a continuous search would find shapes no destination
/// actually wants).
let canonicalRatioPresets: [Ratio] = [
    Ratio(width: 1, height: 1),
    Ratio(width: 4, height: 5),
    Ratio(width: 5, height: 4),
    Ratio(width: 3, height: 4),
    Ratio(width: 4, height: 3),
    Ratio(width: 2, height: 3),
    Ratio(width: 3, height: 2),
    Ratio(width: 9, height: 16),
    Ratio(width: 16, height: 9)
]

/// Phase 5's nominated portrait challenger - the tallest-Instagram-post
/// shape, a member of `canonicalRatioPresets`. The spec calls 4:5/5:4 "the
/// safe, destination-appropriate choices" and 9:16 "extreme...needs a
/// stronger signal (e.g. all photos being markedly tall, not merely
/// portrait)". Phase 5 is chartered to "start crude, on purpose" (Magic
/// Layout Spec.md's Phase 5 intro) - a single fixed preset per direction,
/// no escalation logic - so 9:16 is deliberately NOT reachable yet even
/// though it is a valid preset. Revisiting that escalation is a judgement
/// call flagged to Justin, not decided here (see the Phase 5 build-log
/// entry).
let portraitChallengerRatio = Ratio(width: 4, height: 5)

/// Phase 5's nominated landscape challenger - see `portraitChallengerRatio`
/// above for the same reasoning, mirrored. 16:9 is the extreme this phase
/// does not reach for.
let landscapeChallengerRatio = Ratio(width: 5, height: 4)

/// Crude, orientation-only nomination rule (Magic Layout Spec.md's Phase 5:
/// "Start crude, on purpose. A simple content rule captures most of the
/// value"). Looks at nothing but each photo's own PIXEL aspect - no
/// must-keep regions, no `framingCost` - and returns exactly one challenger
/// ratio, or none:
///   - every photo strictly portrait (width < height)  -> `portraitChallengerRatio`
///   - every photo strictly landscape (width > height) -> `landscapeChallengerRatio`
///   - anything else (a genuine mix, OR any exactly-square photo mixed in)
///     -> nil, meaning "no challenger" - square stays uncontested.
/// A square photo counts as NEITHER portrait nor landscape, so "3 portraits
/// + 1 square photo" is treated as mixed, not all-portrait. This is the
/// conservative reading the spec explicitly asks for ("keep it
/// conservative") - a mixed set gets no challenge at all rather than a
/// judgment call about which way a square photo leans.
/// Deterministic and order-independent: a plain loop over the caller's own
/// ordered `photos` list, no dictionary iteration drives the result.
func nominateChallengerRatio(photos: [PhotoID], photoSizes: [PhotoID: CGSize]) -> Ratio? {
    guard !photos.isEmpty else { return nil }

    var allPortrait = true
    var allLandscape = true
    for id in photos {
        let size = photoSizes[id] ?? CGSize(width: 1, height: 1)
        if !(size.width < size.height) { allPortrait = false }
        if !(size.width > size.height) { allLandscape = false }
    }

    if allPortrait { return portraitChallengerRatio }
    if allLandscape { return landscapeChallengerRatio }
    return nil
}

/// How much LOWER (better) the challenger ratio's total search cost must be
/// than the square default's, PER PHOTO, before `chooseCanvasAndLayout`
/// lets the challenger replace the default - Phase 5's "override threshold"
/// guardrail (Magic Layout Spec.md: "Only depart from the default when the
/// improvement is clearly significant"). The caller multiplies this by
/// `photos.count` before comparing, because `faceAwareAssignment`'s own
/// cost is a SUM over every photo in the set (see that function's doc
/// comment) - an un-scaled constant would make the bar easier to clear for
/// a 4-photo set than a 2-photo one purely because there are more terms to
/// accumulate a gap across, which has nothing to do with how clear the
/// improvement actually is.
///
/// Units: identical to `framingCost`'s own return value (see
/// `FramingCostWeight`) - a log-aspect-distance-shaped cost, NOT a
/// percentage. 0.35 is calibrated against `FramingCostWeight.aspect`
/// (1.0, the weight this same term already carries everywhere else in the
/// Engine): `log(1.4) ≈ 0.336`, i.e. roughly the aspect-term cost of moving
/// ONE photo from a near-square cell (aspect ~1.0) to a distinctly
/// non-square one (aspect ~1.4) - a difference that reads as a clear,
/// visible reshaping, not a rounding error. Requiring that much improvement
/// PER PHOTO, on average across the whole set, is the bar for "clearly
/// significant". Like every other weight in this file, this is a Phase 5
/// placeholder pending Phase 4's real-photo tuning, not a value derived
/// from real photos yet - flagged as a judgement call in the Phase 5
/// build-log entry.
let canvasRatioOverrideThreshold = 0.35

/// A canvas size for `ratio` that keeps `shortEdge` as the SHORT edge
/// regardless of orientation - the same convention the App layer's own
/// nominal search canvas already uses (`PickerView.buildDocument`'s
/// `nominalCanvas`, 1000x1000 for the square default), so a challenger
/// ratio's search runs at a canvas comparable in SCALE to the default's,
/// not only in shape. `ratio.value >= 1` (square or landscape) keeps
/// `shortEdge` as the height; `ratio.value < 1` (portrait) keeps it as the
/// width. Guards against a degenerate zero/negative ratio by falling back
/// to a square canvas rather than dividing by zero.
func nominalCanvasSize(for ratio: Ratio, shortEdge: Double) -> CGSize {
    guard ratio.value > 0 else { return CGSize(width: shortEdge, height: shortEdge) }
    if ratio.value >= 1 {
        return CGSize(width: shortEdge * ratio.value, height: shortEdge)
    } else {
        return CGSize(width: shortEdge, height: shortEdge / ratio.value)
    }
}
