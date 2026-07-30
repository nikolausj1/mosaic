// Sources/Engine/MagicLayout.swift
// B32 Phase 1 + Phase 2 + Phase 5 ("Magic Layout" - the face-aware layout
// DECISION). Pure Foundation, no SwiftUI/UIKit/Photos/Vision - same rules
// as the rest of Sources/Engine. See `Magic Layout Spec.md` (project root)
// and Backlog.md B30/B32 for the why; this file is the how.
//
// Five pieces, in the order the spec lists them:
//   1. `mustKeepRegion(...)`       - what a crop must not cut into.
//   2. `framingCost(...)`         - how bad a given cell shape is for that
//      region.
//   3. `faceAwareAssignment(...)` - search templates + permutations by that
//      cost, using each candidate's AUTHORED fractions.
//   4. Phase 2's divider-fraction search - `searchDividerFractions(...)`,
//      nested inside #3's per-template loop (see that function's own
//      comment for the search shape, the pruning, and why it stays
//      bounded).
//   5. Phase 5's `chooseCanvasAndLayout(...)` - the outermost decision.
//      Runs #3 (which already contains #4) at the square default canvas,
//      and again at a single content-nominated challenger ratio
//      (`CanvasRatio.swift`'s `nominateChallengerRatio`), returning
//      whichever wins as ONE coherent (ratio, template, assignment)
//      result. See that function's own comment for the guardrails.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Instrumentation only - counts every (template, fraction-candidate,
/// permutation) triple `faceAwareAssignment` has actually scored since
/// process start. Exists purely so the smoke test (and the Phase 2 build
/// log) can report REAL evaluation counts against the spec's "low
/// thousands" / under-60ms budget instead of an estimate. Reading or
/// resetting it never affects search behavior or its result - it is
/// incremented alongside a cost computation that already happens, never
/// used to decide anything.
var magicLayoutEvaluationCount = 0

// MARK: - 1. Must-keep region

/// Fractional padding added around the union of surviving faces, as a
/// fraction of the union rect's own width/height (applied evenly on every
/// side via `insetBy`). Enough breathing room that a crop landing exactly
/// on the literal face boxes doesn't itself read as clipped, without
/// ballooning the must-keep region into content the faces don't need.
/// Unlike the confidence/size thresholds (reused verbatim from
/// `AutoFrame.swift`), this number has no existing precedent - it is a
/// Phase 1 placeholder, expected to move during Phase 4's real-photo tuning.
let mustKeepFaceMargin = 0.25

/// The union of surviving face rects (SAME confidence-0.5 / 8%-of-short-edge
/// thresholds as `autoFrame`'s `thresholdedFaces`, reused rather than
/// reinvented) plus `mustKeepFaceMargin`, normalized to photo space,
/// top-left origin, clamped back to the photo's own 0...1 bounds. Falls back
/// to `salientRegion` when no face survives the thresholds, and to nil when
/// neither exists - the same nil contract `autoFrame` already has, which is
/// what keeps landscape photos (and any photo Vision found nothing in)
/// working exactly as they do today.
func mustKeepRegion(
    faces: [CGRect],
    faceConfidences: [Double],
    salientRegion: CGRect?,
    photoPixelSize: CGSize
) -> CGRect? {
    let survivors = thresholdedFaces(faces: faces, faceConfidences: faceConfidences, photoPixelSize: photoPixelSize)
    guard !survivors.isEmpty else { return salientRegion }

    let union = unionRect(survivors)
    let marginX = union.width * mustKeepFaceMargin
    let marginY = union.height * mustKeepFaceMargin
    let expanded = union.insetBy(dx: -marginX, dy: -marginY)
    return expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
}

/// The smallest surviving face's own normalized height - a fraction of the
/// PHOTO's own height, same units `thresholdedFaces`' pixel-height check
/// already uses (`face.height * photoPixelSize.height` == that face's pixel
/// height). Nil when no face survives the thresholds (saliency-only or
/// nothing at all), same nil contract `mustKeepRegion` has.
///
/// This is the signal `mustKeepRegion`'s UNION cannot give you: the union
/// only says how much of the frame the faces TOGETHER occupy, which a
/// five-person group spread across a wide photo and a single centered
/// selfie can both satisfy identically, even though one has tiny faces and
/// the other has one big one. `framingCost`'s legibility term (below) scores
/// against this - not the union - which is what actually lets a group photo
/// earn a bigger cell than a selfie: see "THE PRINCIPLED FORM OF THAT RULE"
/// in the B32 group-photo-cell-size request for the reasoning.
///
/// Deliberately its own function rather than a byproduct of
/// `mustKeepRegion`: callers that only need the crop-safety region (e.g. a
/// future caller that never wants the legibility term) can keep calling
/// `mustKeepRegion` alone, and this stays cheap to compute (one more
/// `thresholdedFaces` call, already O(faces) and already reused twice above).
func smallestSurvivingFaceHeight(
    faces: [CGRect],
    faceConfidences: [Double],
    photoPixelSize: CGSize
) -> Double? {
    let survivors = thresholdedFaces(faces: faces, faceConfidences: faceConfidences, photoPixelSize: photoPixelSize)
    guard !survivors.isEmpty else { return nil }
    return survivors.map { Double($0.height) }.min()
}

// MARK: - 2. Framing cost

/// Relative weights within `framingCost`'s single sum. Tuned only so the
/// ORDERING the spec requires holds (clip always dominates; the rest are
/// minor tie-breakers) - not calibrated against real photos yet, which is
/// explicitly Phase 4's job, not this one's.
enum FramingCostWeight {
    /// Heaviest by a wide margin: a template that clips a face must always
    /// score worse than one that does not, no matter how well the loser
    /// otherwise fits. `smallFace + cropLoss + aspect`'s combined plausible
    /// range sits well under this even in a bad-but-unclipped case, so
    /// "clipped" always wins the comparison against "not clipped".
    static let clip = 40.0
    /// A face that survives uncut but ends up rendering small (a lot of
    /// dead cell around the must-keep region) is a lesser, but real, defect.
    static let smallFace = 3.0
    /// Zooming in past the app's OWN existing auto-zoom ceiling (2.0x - see
    /// `AutoFrame.swift` / Backlog.md B20) to keep a must-keep region safe
    /// discards a lot of the original photo. Reuses that ceiling as the
    /// "reasonable" boundary here rather than inventing a new number.
    static let cropLoss = 1.0
    /// Same weight `contentFitAssignment` already uses for its aspect term.
    /// Keeping it at 1.0 here (not just the same FORMULA) is what makes a
    /// mustKeep-less photo's contribution in `faceAwareAssignment` an exact
    /// match for that function's cost, not merely a similar one.
    static let aspect = 1.0
    /// The group-photo-cell-size term: a photo whose SMALLEST surviving face
    /// would render below `minLegibleFaceHeightFraction` in a candidate cell.
    /// A related but distinct defect from `smallFace` (that term scores the
    /// must-keep UNION's coverage of the crop; this one scores one specific
    /// face's absolute rendered size against the whole canvas, the only way
    /// a bigger cell can ever earn a lower cost - see `framingCost`'s doc
    /// comment). Both real, both meant to stay secondary to an outright clip.
    ///
    /// 20.0, not 3.0 (`smallFace`'s weight) - EMPIRICALLY chosen, not just
    /// guessed, against `Tools/LayoutLab` run over 61 real camera-roll
    /// photos (15 sets) on 2026-07-28: this is the highest weight in a
    /// sweep {3, 6, 10, 20, 30, 50, 80, 120, 200, 400} that changed zero
    /// per-set clipped-face counts anywhere in that corpus (120 was the
    /// first value that regressed one set's clip count, 1 -> 5 - see the
    /// B32 group-photo-cell-size build-log entry for the full sweep table).
    /// Deliberately NOT pushed higher just because it was available: per
    /// `FramingCostWeight.clip`'s own contract, clip must stay dominant, and
    /// a per-photo legibility contribution is capped at
    /// `weight * minLegibleFaceHeightFraction` (2.4 at this weight) - small
    /// next to even a mild single clip event, by design.
    static let legibility = 20.0
}

/// An injectable bundle of `framingCost`'s tunable numbers - the five
/// `FramingCostWeight` weights plus the two related thresholds
/// (`minMustKeepAreaCoverage`, `minLegibleFaceHeightFraction`) that shape the
/// same terms. `FramingCostWeight` itself stays a static enum (existing
/// callers, existing doc comments, existing tests all reference it directly)
/// - this struct exists ALONGSIDE it purely so a caller that wants to vary
/// the weights (Phase 4 tuning, `Tools/LayoutLab`'s sweep harness) can pass a
/// different set through the decision path without recompiling.
///
/// `.current` reproduces today's values exactly, and every function in this
/// file's decision path (`framingCost`, `faceAwareAssignment`,
/// `searchDividerFractions`, `chooseCanvasAndLayout`) defaults its new
/// `weights:` parameter to `.current` - so this is a PURE ADDITION: no
/// existing caller (App layer included) that doesn't pass `weights:`
/// explicitly sees any change in behavior or output.
struct FramingWeights: Equatable {
    var clip: Double
    var smallFace: Double
    var cropLoss: Double
    var aspect: Double
    var legibility: Double
    /// Same number `minMustKeepAreaCoverage` (below) holds today; kept as a
    /// separate stored value here (rather than reading the global directly)
    /// so a sweep config can vary it independently of `AutoFrame.swift`'s own
    /// direct use of that same global, which this struct does NOT touch.
    var minMustKeepAreaCoverage: Double
    /// Same number `minLegibleFaceHeightFraction` (below) holds today. Also
    /// the "cap" the B32 diagnosis refers to: the legibility term's maximum
    /// possible per-photo contribution is `legibility * minLegibleFaceHeightFraction`
    /// (2.4 at today's values) - raising THIS, not `legibility`, raises that
    /// cap without moving the weight the diagnosis already showed causes new
    /// clips.
    var minLegibleFaceHeightFraction: Double

    /// Today's values, unchanged - see this struct's own doc comment. Reads
    /// the two global thresholds via `framingCostDefaultAreaCoverage`/
    /// `framingCostDefaultLegibleFaceHeightFraction` (declared below, aliased
    /// under a different name) rather than the bare global names directly:
    /// inside this type's own body, an unqualified `minMustKeepAreaCoverage`
    /// resolves to THIS struct's own stored property of the same name (a
    /// static-initializer-time compile error: "instance member... property
    /// initializers run before 'self' is available"), not the file-scope
    /// `let` - the alias sidesteps that name collision without renaming
    /// either global (which `AutoFrame.swift` also reads directly).
    static let current = FramingWeights(
        clip: FramingCostWeight.clip,
        smallFace: FramingCostWeight.smallFace,
        cropLoss: FramingCostWeight.cropLoss,
        aspect: FramingCostWeight.aspect,
        legibility: FramingCostWeight.legibility,
        minMustKeepAreaCoverage: framingCostDefaultAreaCoverage,
        minLegibleFaceHeightFraction: framingCostDefaultLegibleFaceHeightFraction
    )
}

/// Aliases for `minMustKeepAreaCoverage`/`minLegibleFaceHeightFraction`
/// (declared below) used only by `FramingWeights.current` above - see that
/// property's own comment for why a direct reference does not compile.
private let framingCostDefaultAreaCoverage = minMustKeepAreaCoverage
private let framingCostDefaultLegibleFaceHeightFraction = minLegibleFaceHeightFraction

/// Minimum rendered face height, expressed as a fraction of the CANVAS's own
/// short edge (not the cell's - a fraction of the cell would cancel out
/// exactly the effect this term exists to produce, since a bigger cell would
/// then need a proportionally bigger face too; see `framingCost`'s doc
/// comment for the full argument). Below this a face reads as a smudge
/// rather than a face. Deliberately loose, a Phase 1 placeholder like
/// `minMustKeepAreaCoverage` above - expected to move once Phase 4 tunes
/// against real photos.
let minLegibleFaceHeightFraction = 0.12

/// Minimum acceptable fraction of the resulting crop's AREA that the
/// must-keep region should occupy once framed as tightly as it safely can
/// be; below this, faces read as small even though nothing was clipped.
/// mustKeep already carries `mustKeepFaceMargin` of padding, so demanding
/// near-100% coverage here would penalize ordinary, well-framed group
/// shots - this is deliberately a loose floor, a Phase 1 placeholder like
/// `mustKeepFaceMargin` above.
let minMustKeepAreaCoverage = 0.40

/// Given a must-keep region (normalized to photo space, top-left origin),
/// the photo's own pixel size, and a candidate cell's REAL size (canvas
/// points, same convention `solve(...)`'s `CellFrame.rect.size` already
/// uses), scores how good a fit that cell is. Lower is better; 0 is a
/// perfect match. Fully deterministic - pure arithmetic on the inputs, no
/// randomness, no iteration over any unordered collection.
///
/// Method: find the TIGHTEST zoom (in the app's own "1.0 == aspect-fill,
/// larger == cropped in tighter" convention - see `PhotoRef.zoom` in
/// `Model.swift`) whose crop, at `cellSize`'s aspect, still fully contains
/// `mustKeep`. Because a crop's visible photo-space extent shrinks
/// monotonically as zoom increases (see `halfVisible` below), and the real
/// zoom floor is 1.0 (aspect-fill - you cannot zoom OUT further), that
/// tightest safe zoom is well-defined: if even the floor (zoom 1.0) cuts
/// into `mustKeep`, no zoom can save it - a clip is unavoidable for this
/// cell shape, and that is the heaviest penalty below. Otherwise, the
/// tightest safe zoom is exactly the boundary where relaxing zoom any
/// further would just start clipping, and everything else is scored
/// relative to that.
///
/// `cellSize`'s ABSOLUTE magnitude, not just its aspect, is why this
/// function can now tell a small cell from a big one at all: every OTHER
/// term below (clip severity, area coverage, aspect mismatch) is a ratio
/// against the photo's own or the must-keep region's own extent, which is
/// PROVABLY invariant to scaling `cellSize` by any positive constant (see
/// `halfVisible`'s own doc comment - it depends only on `cellSize`'s
/// width/height RATIO). A cost built only from those terms is therefore
/// structurally incapable of preferring a bigger cell over a smaller one at
/// the same aspect, no matter how the weights are tuned - this was measured
/// directly (a 4x canvas-area change moved the old aspect-only cost by
/// 0.000000000000) before this parameter existed. The legibility term below
/// is the one exception: it multiplies a normalized-to-photo quantity
/// (`smallestFaceHeightFraction`) by `cellSize.height` itself, which is what
/// finally produces an ABSOLUTE rendered size in canvas points - see that
/// term's own comment for the derivation.
///
/// `canvasShortEdge` (canvas points, `min` of the full canvas's own
/// width/height - NOT the cell's) is the legibility term's other half: the
/// floor a rendered face must clear is stated as a fraction of the CANVAS,
/// so it has to be compared against something that does not itself shrink
/// or grow with the cell being scored. Defaults to `defaultReferenceShortEdge`
/// (1000), the one scale every current caller already solves against, so a
/// caller with no interest in the legibility term (`smallestFaceHeightFraction`
/// nil, the default) never needs to think about it.
func framingCost(
    mustKeep: CGRect,
    photoPixelSize: CGSize,
    cellSize: CGSize,
    canvasShortEdge: Double = defaultReferenceShortEdge,
    smallestFaceHeightFraction: Double? = nil,
    // See `FramingWeights`'s own doc comment: defaults to today's values
    // exactly, so every existing caller is unaffected.
    weights: FramingWeights = .current
) -> Double {
    guard mustKeep.width > 0, mustKeep.height > 0,
          cellSize.width > 0, cellSize.height > 0,
          photoPixelSize.width > 0, photoPixelSize.height > 0 else { return 0 }

    let cellAspect = aspect(cellSize)
    guard cellAspect > 0 else { return 0 }

    let vis1 = halfVisible(zoom: 1.0, photoPixelSize: photoPixelSize, cellSize: cellSize)
    let visW1 = 2 * vis1.hx
    let visH1 = 2 * vis1.hy

    let mustKeepW = Double(mustKeep.width)
    let mustKeepH = Double(mustKeep.height)

    // zoomFor{Width,Height}: the zoom at which that axis's visible extent
    // would shrink to EXACTLY mustKeep's own extent. The smaller of the two
    // is the binding constraint - the tightest zoom safe on BOTH axes.
    let zoomForWidth = visW1 / mustKeepW
    let zoomForHeight = visH1 / mustKeepH
    let tightestSafeZoom = min(zoomForWidth, zoomForHeight)

    var cost = 0.0

    if tightestSafeZoom < 1.0 {
        // Even the loosest possible crop (the aspect-fill floor - real zoom
        // never goes below 1.0) cuts into the must-keep region on at least
        // one axis. Severity: how far under 1.0 the boundary zoom falls,
        // clamped to keep the penalty bounded and comparable across cases.
        let severity = min(1.0, 1.0 - tightestSafeZoom)
        cost += weights.clip * severity
    } else {
        // Safe to frame this tightly. Area-coverage proxy for "does the
        // must-keep region fill the frame or get lost in a lot of empty
        // cell": at the tightest safe zoom, exactly one axis touches
        // mustKeep's own extent by construction, so a single-axis ratio is
        // always trivially 1 and tells us nothing - the AREA ratio is what
        // actually varies with how well `cellAspect` suits `mustKeep`'s own
        // aspect (e.g. a square mustKeep inside a very wide, short cell:
        // width fits exactly, but the region still occupies only a sliver
        // of the letterboxed frame's area).
        let resultingVisW = visW1 / tightestSafeZoom
        let resultingVisH = visH1 / tightestSafeZoom
        let areaCoverage = (mustKeepW * mustKeepH) / (resultingVisW * resultingVisH)
        if areaCoverage < weights.minMustKeepAreaCoverage {
            cost += weights.smallFace * (weights.minMustKeepAreaCoverage - areaCoverage)
        }

        // Excess zoom past the app's own established auto-zoom ceiling
        // (2.0x) - the crop is safe, but reaching it required cropping in
        // further than the app itself otherwise considers reasonable.
        let excessZoom = max(0.0, tightestSafeZoom - 2.0)
        cost += weights.cropLoss * excessZoom
    }

    // Aspect mismatch between the must-keep region's own shape and the
    // cell's, independent of zoom - same log-distance shape
    // `contentFitAssignment` already uses for photo-vs-cell aspect.
    let mustKeepAspect = mustKeepW / mustKeepH
    cost += weights.aspect * abs(log(mustKeepAspect) - log(cellAspect))

    // The group-photo-cell-size term (see this function's own doc comment
    // for the derivation of why THIS term, alone among the others, can
    // depend on cellSize's absolute magnitude). Computed at whatever zoom the
    // crop would ACTUALLY use - `tightestSafeZoom` when safe, but never below
    // the real zoom floor of 1.0 even when clipping (a clipping cell still
    // renders the photo at zoom 1.0; it just also eats the heavy clip
    // penalty above), so this term is meaningful in both branches rather
    // than only the safe one.
    if let smallestFaceHeightFraction {
        let appliedZoom = max(tightestSafeZoom, 1.0)
        let resultingVisHForFace = visH1 / appliedZoom
        if resultingVisHForFace > 0 {
            // resultingVisHForFace is the fraction of the PHOTO's height
            // visible at appliedZoom; by aspect-fill construction that
            // visible fraction maps exactly onto cellSize.height (canvas
            // points). So cellSize.height / resultingVisHForFace is
            // "canvas points per unit of normalized-photo-height", and
            // multiplying by smallestFaceHeightFraction (itself a fraction
            // of the photo's height, same units `thresholdedFaces` already
            // uses) converts it straight to the face's RENDERED height in
            // canvas points - the one absolute, comparable-across-cell-sizes
            // quantity this whole function has been missing.
            let renderedFaceHeightPoints = smallestFaceHeightFraction * cellSize.height / resultingVisHForFace
            let renderedFaceHeightFraction = renderedFaceHeightPoints / canvasShortEdge
            let deficit = max(0.0, weights.minLegibleFaceHeightFraction - renderedFaceHeightFraction)
            cost += weights.legibility * deficit
        }
    }

    return cost
}

// MARK: - 3. Template + assignment search

/// The winning (template, assignment) pair `faceAwareAssignment` found,
/// plus its total cost (lower is better; 0 only when every slot is a
/// perfect, unclipped, aspect-matched fit).
struct FaceAwareAssignment: Equatable {
    /// Index into `templates(for:)`'s fixed-order candidate list.
    var templateIndex: Int
    /// `templates(for:)[templateIndex]`, with its leaves reassigned to the
    /// winning permutation - ready to hand straight to `solve(...)`, same as
    /// `contentFitAssignment`'s return value.
    var template: Node
    var cost: Double
}

/// Face-aware sibling of `contentFitAssignment`. Where that function trusts
/// one already-chosen template and scores permutations by aspect distance
/// alone, this searches EVERY candidate `templates(for:)` offers for
/// `photos.count` photos, solves each at `canvasSize`/`border`, and scores
/// every permutation of `photos` into that template's slots by
/// `framingCost` - falling back, for any photo with no entry in
/// `mustKeepRegions`, to the exact aspect-distance term
/// `contentFitAssignment` already uses (same formula, same weight). A photo
/// set with no must-keep data anywhere therefore degrades byte-for-byte to
/// today's aspect-only cost - see the "face-aware degrade" case in
/// `Tests/SmokeTest.swift`, which is what makes this a strict improvement
/// rather than a replacement.
///
/// Determinism / tie-breaking, same rules as `contentFitAssignment`: within
/// one template, `permutations(_:)`'s enumeration order means the first
/// permutation to reach the strictly lowest cost wins (ties favor whichever
/// permutation sits closest to that template's own original leaf order).
/// Across templates, the same strict-`<` rule means ties favor the earlier
/// candidate in `templates(for:)`'s fixed order. No dictionary iteration
/// drives any decision - every dictionary here is a lookup table, keyed by
/// values already fixed by `photos`'s own (caller-supplied, ordered) list.
///
/// PHASE 2: for each candidate, after finding the best permutation at that
/// template's AUTHORED fractions (below), `searchDividerFractions` gets a
/// chance to move that template's own dividers and re-score before this
/// template competes with the others - see that function's doc comment for
/// the search shape and its pruning. The chosen fractions live directly in
/// the returned `FaceAwareAssignment.template` (no new field): the App
/// layer already only ever reads `result.template` and feeds it straight to
/// `solve(...)`, so a template whose fractions were adjusted is, from that
/// call site's point of view, just another template.
func faceAwareAssignment(
    photos: [PhotoID],
    photoSizes: [PhotoID: CGSize],
    mustKeepRegions: [PhotoID: CGRect],
    // Group-photo-cell-size signal (the smallest surviving face's normalized
    // height per photo - see `smallestSurvivingFaceHeight`'s own comment).
    // Defaults to empty so every caller written before this parameter
    // existed still compiles unchanged and still gets exactly today's
    // `framingCost` behavior (that term contributes 0 whenever a photo has
    // no entry here, same as it does when the photo has no face at all).
    mustKeepFaceHeights: [PhotoID: Double] = [:],
    canvasSize: CGSize,
    border: BorderStyle,
    // See `FramingWeights`'s own doc comment: defaults to today's values, so
    // every existing caller (App layer included) is unaffected.
    weights: FramingWeights = .current
) -> FaceAwareAssignment {
    precondition((2...4).contains(photos.count), "faceAwareAssignment supports 2...4 photos")

    let candidates = templates(for: photos)

    // Degrade guarantee (see this function's doc comment). With no
    // must-keep data anywhere there is nothing face-aware to decide, so
    // hand straight back to today's exact path rather than re-deriving a
    // template from aspect cost alone. This is NOT redundant with the
    // aspect fallback inside the search: today's template comes from
    // `defaultTemplateIndex`'s ORIENTATION heuristic, which is a different
    // function from "lowest total aspect distance" and genuinely disagrees
    // with it - measured on 2026-07-28 across a spread of no-face sets,
    // they picked different templates in half of them (wide+square, and
    // both the 3- and 4-photo mixed sets). Without this guard, adding
    // face-awareness would silently relayout every faceless collage
    // (landscapes, screenshots, food) - the exact "replacement, not
    // improvement" outcome the spec rules out. THIS GUARD RETURNS BEFORE
    // Phase 2's divider search ever runs, so a faceless set never enters it
    // either - the degrade stays byte-identical to Phase 1, and to today.
    let hasAnyMustKeep = photos.contains { mustKeepRegions[$0] != nil }
    guard hasAnyMustKeep else {
        let index = defaultTemplateIndex(orientations: photos.map { photoSizes[$0] ?? CGSize(width: 1, height: 1) })
        let safeIndex = min(index, candidates.count - 1)
        let assigned = contentFitAssignment(
            photoSizes: photoSizes,
            template: candidates[safeIndex],
            canvasSize: canvasSize,
            border: border
        )
        return FaceAwareAssignment(templateIndex: safeIndex, template: assigned, cost: 0)
    }

    var bestTemplateIndex = 0
    var bestTemplate = candidates[0]
    var bestCost = Double.infinity

    for (templateIndex, template) in candidates.enumerated() {
        // `templates(for:)` places `photos` into each candidate's leaves in
        // list order (its own documented contract), so this always equals
        // `photos` - re-deriving it here mirrors `contentFitAssignment`'s
        // own style rather than assuming the contract from a distance.
        let originalOrder = photoIDs(in: template)

        let (authoredPermutation, authoredCost) = bestPermutationAndCost(
            for: template,
            originalOrder: originalOrder,
            photoSizes: photoSizes,
            mustKeepRegions: mustKeepRegions,
            mustKeepFaceHeights: mustKeepFaceHeights,
            canvasSize: canvasSize,
            border: border,
            weights: weights
        )

        // PHASE 2 (see `searchDividerFractions`'s own comment): let this
        // template's own dividers move and see if any coarse position beats
        // what the authored fractions just scored above. Never worse than
        // `authoredCost` - a candidate only replaces the running best on a
        // strict improvement.
        let (finalTemplate, finalPermutation, finalCost) = searchDividerFractions(
            template: template,
            originalOrder: originalOrder,
            authoredPermutation: authoredPermutation,
            authoredCost: authoredCost,
            photoSizes: photoSizes,
            mustKeepRegions: mustKeepRegions,
            mustKeepFaceHeights: mustKeepFaceHeights,
            canvasSize: canvasSize,
            border: border,
            weights: weights
        )

        if finalCost < bestCost {
            bestCost = finalCost
            bestTemplateIndex = templateIndex
            var cursor = 0
            bestTemplate = replacingLeavesInOrder(finalTemplate, with: finalPermutation, cursor: &cursor)
        }
    }

    return FaceAwareAssignment(templateIndex: bestTemplateIndex, template: bestTemplate, cost: bestCost)
}

/// Solves `template` once at `canvasSize`/`border` and brute-forces every
/// permutation of `originalOrder` into its slots, scored exactly the way
/// `faceAwareAssignment`'s own loop body always has (must-keep photos via
/// `framingCost`, everyone else via the aspect-distance fallback). Factored
/// out so Phase 2's `searchDividerFractions` can score a fraction-adjusted
/// tree with the EXACT same cost function `faceAwareAssignment` uses for a
/// template's authored fractions - not a similar one.
private func bestPermutationAndCost(
    for template: Node,
    originalOrder: [PhotoID],
    photoSizes: [PhotoID: CGSize],
    mustKeepRegions: [PhotoID: CGRect],
    mustKeepFaceHeights: [PhotoID: Double],
    canvasSize: CGSize,
    border: BorderStyle,
    weights: FramingWeights = .current
) -> (permutation: [PhotoID], cost: Double) {
    let (cells, _) = solve(root: template, canvasSize: canvasSize, border: border)
    let cellByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })
    // The cell's REAL size (canvas points), not just its aspect - this is
    // the architectural change the group-photo-cell-size rule needed.
    // `framingCost`'s own doc comment has the full "why aspect alone can
    // never work" argument.
    let slotSizes: [CGSize] = originalOrder.map { id in
        cellByID[id]?.size ?? CGSize(width: 1, height: 1)
    }
    let canvasShortEdge = min(canvasSize.width, canvasSize.height)

    var bestPermCost = Double.infinity
    var bestPermutation = originalOrder

    for perm in permutations(originalOrder) {
        var cost = 0.0
        for slot in 0..<perm.count {
            let photoID = perm[slot]
            let cellSize = slotSizes[slot]
            guard cellSize.width > 0, cellSize.height > 0 else { continue }

            if let mustKeep = mustKeepRegions[photoID] {
                let pixelSize = photoSizes[photoID] ?? CGSize(width: 1, height: 1)
                cost += framingCost(
                    mustKeep: mustKeep,
                    photoPixelSize: pixelSize,
                    cellSize: cellSize,
                    canvasShortEdge: canvasShortEdge,
                    smallestFaceHeightFraction: mustKeepFaceHeights[photoID],
                    weights: weights
                )
            } else {
                let cellAspect = aspect(cellSize)
                let photoAspect = aspect(photoSizes[photoID] ?? CGSize(width: 1, height: 1))
                guard photoAspect > 0, cellAspect > 0 else { continue }
                cost += weights.aspect * abs(log(photoAspect) - log(cellAspect))
            }
        }
        magicLayoutEvaluationCount += 1
        if cost < bestPermCost {
            bestPermCost = cost
            bestPermutation = perm
        }
    }

    return (bestPermutation, bestPermCost)
}

// MARK: - 4. Phase 2: divider-fraction search

/// The coarse grid Phase 2 searches each hot divider over - `Magic Layout
/// Spec.md`'s own "roughly 0.3...0.7 in about 5 steps". `t` is the
/// divider's position WITHIN the pair of fractions it separates (see
/// `applyingDividerFraction`'s comment) - for a plain 2-child split this IS
/// the new fraction directly, which is what makes 0.3...0.7 read the same
/// way here as it does in the spec's own framing.
///
/// TASK 2 INVESTIGATION (2026-07-29), NOT ADOPTED - recorded so it is not
/// re-litigated blind: widening this to 0.2...0.8 DOES let the search reach
/// set18's true `framingCost` minimum (measured at a divider fraction of
/// ~0.26 via a 0.01-step brute-force sweep against set18's real photos -
/// strictly lower cost, confirmed). But the resulting split moves the
/// MOST-populated photo's cell SMALLER, not larger (measured on real
/// `Tools/LayoutLab` output: set18's two 4-face group photos dropped from
/// 15% each to 10% each while the 2-face selfie grew from 70% to 80%; the
/// same direction showed up on set13 with plain iterated coordinate descent
/// inside the ORIGINAL grid, no widening needed - the 7-face photo's cell
/// shrank further, not grew). Root cause: `framingCost`'s legibility term
/// (`FramingCostWeight.legibility`, `smallestFaceHeightFraction`) is capped
/// at a maximum per-photo contribution of `20 * 0.12 = 2.4`, while the
/// clip-avoidance term (weight 40, uncapped severity) and the aspect-
/// mismatch term (weight 1, an unbounded log-distance) can swing far more
/// with divider position - so whenever a photo's must-keep region is tight
/// against a candidate cell's aspect (set18's group photos have faces
/// spanning their full source width; set13's crowd photo similarly), a more
/// thorough search chases THOSE terms, which can require SHRINKING a
/// neighboring cell rather than growing it - directly against the
/// legibility term's much weaker pull the other way. A smarter or wider
/// SEARCH cannot fix this: it only finds MORE of the cost function's own
/// preference, and that preference does not reliably match "give the
/// most-populated photo the most area" once actually pursued to its true
/// optimum. See the Task 2 hand-off notes for the full trail (iterated
/// coordinate descent, a widened grid, and a full joint combinatorial cross
/// were all built and measured - none delivered the acceptance goal, and
/// two of the three actively worsened it) - fixing this for real needs
/// `framingCost`'s own weights/caps revisited, which is out of scope here
/// ("do not simply raise the weight" - and this investigation suggests the
/// fix isn't a weight bump anyway, but the cap/uncapped-ness imbalance
/// itself). Reverted to the original single-pass search over this original
/// grid rather than ship a change that measurably moves the reported bug
/// in the wrong direction.
private let dividerSearchGrid: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7]

/// One divider inside a template's tree, located the same way
/// `Layout.swift`'s `DividerFrame` locates one (`path` to the owning
/// `.split` node, `index` of the divider within it - divider `index`
/// separates that node's child `index` from child `index + 1`), plus the
/// two SLOT-INDEX ranges (into `originalOrder`, i.e. `photoIDs(in:)`'s own
/// flattened traversal order) that sit on either side of it. A "slot" is a
/// leaf POSITION in that traversal, not a photo identity - stable for a
/// given template regardless of which permutation ends up assigned there.
private struct DividerSearchSite {
    let path: [Int]
    let index: Int
    let leftRange: Range<Int>
    let rightRange: Range<Int>
}

/// Depth-first, parent-before-children walk collecting every `.split`
/// node's dividers as `DividerSearchSite`s. Fixed and fully deterministic
/// for a given tree SHAPE - it depends only on the template's topology
/// (never on which photo occupies which leaf), so the same template always
/// yields sites in the same order. Mirrors `Layout.swift`'s own
/// divider-collection order (a node's own dividers before its children's).
private func dividerSearchSites(in node: Node) -> [DividerSearchSite] {
    func walk(_ node: Node, path: [Int], slotOffset: Int) -> (slotCount: Int, sites: [DividerSearchSite]) {
        switch node {
        case .leaf:
            return (1, [])
        case .split(_, _, let children):
            var childCounts: [Int] = []
            var childSites: [DividerSearchSite] = []
            var cursor = slotOffset
            for (i, child) in children.enumerated() {
                let (count, sites) = walk(child, path: path + [i], slotOffset: cursor)
                childCounts.append(count)
                childSites.append(contentsOf: sites)
                cursor += count
            }

            var starts: [Int] = []
            var runningStart = slotOffset
            for count in childCounts {
                starts.append(runningStart)
                runningStart += count
            }

            var ownSites: [DividerSearchSite] = []
            for i in 0..<(children.count - 1) {
                let leftRange = starts[i]..<(starts[i] + childCounts[i])
                let rightRange = starts[i + 1]..<(starts[i + 1] + childCounts[i + 1])
                ownSites.append(DividerSearchSite(path: path, index: i, leftRange: leftRange, rightRange: rightRange))
            }
            return (cursor - slotOffset, ownSites + childSites)
        }
    }
    return walk(node, path: [], slotOffset: 0).sites
}

/// Returns `node` with divider (`path`, `index`) moved to `t`: the two
/// fractions that divider separates (`fractions[index]` and
/// `fractions[index + 1]`) are redistributed so their OWN sum is preserved
/// (a zero-sum move against just that pair, same as a real divider drag -
/// see the invariant comment on `Node` in `Model.swift`) with `t` as the new
/// split point WITHIN that pair - `fractions[index] = t * pairSum`. Every
/// other fraction in the tree, including every other divider's own pair
/// sum, is untouched. Clamps to `Layout.minCellFraction` on either side of
/// the pair if the coarse grid would otherwise push a fraction below it
/// (requirement: a searched fraction must never violate Layout's own
/// minimum-cell rule) - the clamp itself preserves the pair's sum, so the
/// whole array still sums to 1.0 afterward.
private func applyingDividerFraction(_ node: Node, path: [Int], index: Int, t: Double) -> Node {
    guard let head = path.first else {
        guard case .split(let axis, var fractions, let children) = node,
              fractions.indices.contains(index), fractions.indices.contains(index + 1) else { return node }
        let pairSum = fractions[index] + fractions[index + 1]
        var left = t * pairSum
        var right = pairSum - left
        if left < Layout.minCellFraction {
            left = Layout.minCellFraction
            right = pairSum - left
        }
        if right < Layout.minCellFraction {
            right = Layout.minCellFraction
            left = pairSum - right
        }
        fractions[index] = left
        fractions[index + 1] = right
        return .split(axis: axis, fractions: fractions, children: children)
    }
    guard case .split(let axis, let fractions, let children) = node, children.indices.contains(head) else { return node }
    var newChildren = children
    newChildren[head] = applyingDividerFraction(children[head], path: Array(path.dropFirst()), index: index, t: t)
    return .split(axis: axis, fractions: fractions, children: newChildren)
}

/// Phase 2's divider-fraction search for ONE template candidate, nested
/// inside `faceAwareAssignment`'s per-template loop exactly where that
/// function's doc comment says it would be. Lets a cell GROW to fit a
/// group shot instead of only ever cropping it, by trying coarser positions
/// for the template's own dividers (`dividerSearchGrid`, ~0.3...0.7 in 5
/// steps, per `Magic Layout Spec.md`'s Phase 2) and re-solving before each
/// one is scored - never touching `framingCost` or `mustKeepRegion`
/// themselves, only widening the search space they get evaluated over.
///
/// PRUNING (bounding the cost): a divider whose cells hold no must-keep
/// region can only ever move the APPEARANCE of aspect-fallback photos,
/// which Phase 2 isn't chartered to chase - so this only searches "hot"
/// dividers, those with a must-keep photo on at least one side, determined
/// ONCE from `authoredPermutation` (the winning assignment at the
/// template's own authored fractions, already computed by the caller).
/// That keeps the grid tiny even for the biggest candidates (8 templates x
/// up to 3 dividers each, for 4 photos) - see the Phase 2 build-log entry
/// for measured evaluation counts and wall-clock.
///
/// SEARCH SHAPE: single-pass coordinate descent over the hot dividers, in
/// `dividerSearchSites`' fixed traversal order - not a full combinatorial
/// cross of every hot divider's 5 positions. A full cross is what actually
/// blows the budget: several of this app's OWN templates place 2 or 3
/// dividers on ONE split node (`threeColumns`, `fourColumns`, `fourRows`,
/// and the inner 3-way split inside every `bigX...` / `sandwich` template),
/// so a same-node combinatorial cross is `5^(dividers in that node)` before
/// even multiplying across templates. Coordinate descent instead fixes
/// every OTHER hot divider at its current-best value while sweeping one,
/// keeps the value if a candidate strictly beats the running cost (ties
/// therefore keep the earlier, wider-canvas-fraction candidate - the same
/// strict-`<` rule `faceAwareAssignment` itself uses), and moves on -
/// O(hot dividers x 5) fraction-candidates per template rather than
/// O(5 ^ hot dividers). At each candidate this reruns
/// `bestPermutationAndCost` (a fresh full permutation search, not the
/// fixed `authoredPermutation`), so the assignment is free to follow the
/// fractions if a different one now fits better - this is what keeps the
/// result a true (template, fractions, assignment) triple rather than
/// fractions searched against a permutation that's gone stale.
///
/// TASK 2 INVESTIGATION (2026-07-29), NOT ADOPTED: an ITERATED version of
/// this same coordinate descent (repeat the full sweep until a pass
/// improves nothing) was built and measured against set13/set18's real
/// photos. It genuinely finds a lower `framingCost` in several real sets
/// (confirmed via `Tools/LayoutLab`) - but the resulting split gives the
/// MOST-populated photo LESS area, not more, moving further from what B32's
/// group-photo-cell-size request actually wants. See `dividerSearchGrid`'s
/// own comment for the full root-cause explanation (a capped legibility
/// term losing out to uncapped clip/aspect terms once the search explores
/// more of the space) - this is a `framingCost` weighting issue, not
/// something a more thorough SEARCH can fix, so single-pass ships unchanged.
///
/// Never worse than the authored fractions: `currentCost` starts at
/// `authoredCost` and only updates on a strict improvement, so a template
/// with no hot dividers (or none that help) returns `(template,
/// authoredPermutation, authoredCost)` unchanged.
private func searchDividerFractions(
    template: Node,
    originalOrder: [PhotoID],
    authoredPermutation: [PhotoID],
    authoredCost: Double,
    photoSizes: [PhotoID: CGSize],
    mustKeepRegions: [PhotoID: CGRect],
    mustKeepFaceHeights: [PhotoID: Double],
    canvasSize: CGSize,
    border: BorderStyle,
    weights: FramingWeights = .current
) -> (template: Node, permutation: [PhotoID], cost: Double) {
    let sites = dividerSearchSites(in: template)
    guard !sites.isEmpty else { return (template, authoredPermutation, authoredCost) }

    func isHot(_ site: DividerSearchSite) -> Bool {
        let leftHot = site.leftRange.contains { slot in mustKeepRegions[authoredPermutation[slot]] != nil }
        let rightHot = site.rightRange.contains { slot in mustKeepRegions[authoredPermutation[slot]] != nil }
        return leftHot || rightHot
    }
    let hotSites = sites.filter(isHot)
    guard !hotSites.isEmpty else { return (template, authoredPermutation, authoredCost) }

    var currentTemplate = template
    var currentPermutation = authoredPermutation
    var currentCost = authoredCost

    for site in hotSites {
        var bestTemplateForSite = currentTemplate
        var bestPermutationForSite = currentPermutation
        var bestCostForSite = currentCost

        for t in dividerSearchGrid {
            let candidate = applyingDividerFraction(currentTemplate, path: site.path, index: site.index, t: t)
            let (perm, cost) = bestPermutationAndCost(
                for: candidate,
                originalOrder: originalOrder,
                photoSizes: photoSizes,
                mustKeepRegions: mustKeepRegions,
                mustKeepFaceHeights: mustKeepFaceHeights,
                canvasSize: canvasSize,
                border: border,
                weights: weights
            )
            if cost < bestCostForSite {
                bestCostForSite = cost
                bestTemplateForSite = candidate
                bestPermutationForSite = perm
            }
        }

        currentTemplate = bestTemplateForSite
        currentPermutation = bestPermutationForSite
        currentCost = bestCostForSite
    }

    return (currentTemplate, currentPermutation, currentCost)
}

// MARK: - 5. Phase 5: canvas ratio joins the decision

/// The reference short edge Phase 5's searches solve against - the same
/// units the App layer's own nominal search canvas already uses (1000; see
/// `PickerView.buildDocument`'s `nominalCanvas`). A default parameter on
/// `chooseCanvasAndLayout` rather than hardcoded inline so a caller (or a
/// test) can override the scale, but every existing call site already
/// assumes 1000.
let defaultReferenceShortEdge = 1000.0

/// Phase 5's ONE coherent decision: which canvas ratio AND which
/// (template, assignment) pair to use with it, returned together rather
/// than as two calls a caller could combine inconsistently (e.g. picking a
/// ratio, then separately re-solving a DIFFERENT template's search against
/// it). See this file's header comment and `Magic Layout Spec.md`'s Phase 5
/// section for the why.
struct MagicLayoutDecision: Equatable {
    /// The chosen canvas ratio - either the caller's own sticky preference
    /// (returned unchanged), the square default, or the one challenger the
    /// content rule nominated and the override threshold cleared.
    var canvasRatio: Ratio
    /// Index into `templates(for:)`'s fixed-order candidate list, solved AT
    /// `canvasRatio`.
    var templateIndex: Int
    /// `templates(for:)[templateIndex]`, with its leaves and fractions
    /// resolved by `faceAwareAssignment` (Phase 1 + 2) at `canvasRatio` -
    /// ready to hand straight to `solve(...)`.
    var template: Node
    /// The winning `faceAwareAssignment` cost AT `canvasRatio` - NOT
    /// comparable across two different `MagicLayoutDecision`s computed at
    /// different ratios (a portrait canvas's cell aspects differ from a
    /// square canvas's, so their costs live on different scales); only
    /// meaningful as "how good this particular decision is internally".
    var cost: Double
}

/// Phase 5's top-level entry point - the outermost variable (canvas ratio)
/// joining the decision Phase 1 + 2 already make (template + assignment +
/// dividers). See `Magic Layout Spec.md`'s Phase 5 section for the full
/// reasoning; summarized here as the four things this function does, in
/// order:
///
/// 1. **Sticky preference.** If `userRatio` is non-nil, that is stated
///    intent (same contract border thickness already has) - return it
///    UNCHANGED and run no challenger search at all. The face-aware
///    (template, assignment) search still runs, once, at that ratio, so the
///    caller still gets one coherent decision.
/// 2. **Degrade guarantee.** With no must-keep region anywhere (the
///    faceless path), there is no face evidence to justify reshaping the
///    canvas either - `nominateChallengerRatio` is deliberately blind to
///    faces (orientation only), so without this guard a faceless
///    all-portrait set (screenshots, portrait-shot panoramas, etc) would
///    still get a canvas challenge on looks alone, which is exactly the
///    "replacement, not improvement" outcome the spec rules out for the
///    WHOLE Magic Layout system, not just Phase 1. Bailing out here, before
///    a challenger is even nominated, keeps the faceless path both
///    byte-identical to today (square canvas, `defaultTemplateIndex` +
///    `contentFitAssignment`, via `faceAwareAssignment`'s own guard one
///    level down) AND cheap - a single search, not two.
/// 3. **Crude nomination.** Otherwise, `nominateChallengerRatio` looks at
///    photo orientations only and nominates at most one challenger ratio.
///    "Mixed" (its `nil` case) means no challenge - the square default wins
///    by default, without a second search.
/// 4. **Override threshold.** With a challenger nominated, run the SAME
///    Phase 1 + 2 search again at the challenger's canvas, and let it win
///    only if its cost beats the default's by more than
///    `canvasRatioOverrideThreshold` per photo - see that constant's own
///    comment for the units and the reasoning. A marginal win keeps the
///    square default; churn requires a clear improvement.
///
/// Determinism: every branch is a fixed sequence of calls into
/// deterministic functions (`nominateChallengerRatio`, `faceAwareAssignment`
/// - itself already proven deterministic) - no randomness, no dictionary
/// iteration drives any decision here either.
func chooseCanvasAndLayout(
    photos: [PhotoID],
    photoSizes: [PhotoID: CGSize],
    mustKeepRegions: [PhotoID: CGRect],
    // See `faceAwareAssignment`'s own doc comment on this same parameter -
    // same default, same degrade contract.
    mustKeepFaceHeights: [PhotoID: Double] = [:],
    border: BorderStyle,
    userRatio: Ratio? = nil,
    referenceShortEdge: Double = defaultReferenceShortEdge,
    // See `FramingWeights`'s own doc comment: defaults to today's values, so
    // every existing caller (App layer included) is unaffected.
    weights: FramingWeights = .current
) -> MagicLayoutDecision {
    precondition((2...4).contains(photos.count), "chooseCanvasAndLayout supports 2...4 photos")

    func decide(at ratio: Ratio) -> FaceAwareAssignment {
        let canvasSize = nominalCanvasSize(for: ratio, shortEdge: referenceShortEdge)
        return faceAwareAssignment(
            photos: photos,
            photoSizes: photoSizes,
            mustKeepRegions: mustKeepRegions,
            mustKeepFaceHeights: mustKeepFaceHeights,
            canvasSize: canvasSize,
            border: border,
            weights: weights
        )
    }

    // 1. Sticky preference - see doc comment above. Returns before ANY
    // challenger nomination happens, so a hand-set ratio is never even
    // compared against one.
    if let userRatio {
        let decision = decide(at: userRatio)
        return MagicLayoutDecision(
            canvasRatio: userRatio,
            templateIndex: decision.templateIndex,
            template: decision.template,
            cost: decision.cost
        )
    }

    let defaultDecision = decide(at: .square)

    // 2. Degrade guarantee - see doc comment above. Same predicate
    // `faceAwareAssignment` itself uses one level down, checked again here
    // because a challenger being nominated is a DIFFERENT decision (canvas
    // shape) than the template/assignment guard that predicate already
    // protects, and needs its own bail-out.
    let hasAnyMustKeep = photos.contains { mustKeepRegions[$0] != nil }
    guard hasAnyMustKeep else {
        return MagicLayoutDecision(
            canvasRatio: .square,
            templateIndex: defaultDecision.templateIndex,
            template: defaultDecision.template,
            cost: defaultDecision.cost
        )
    }

    // 3. Crude nomination - orientation only, at most one challenger.
    guard let challengerRatio = nominateChallengerRatio(photos: photos, photoSizes: photoSizes) else {
        return MagicLayoutDecision(
            canvasRatio: .square,
            templateIndex: defaultDecision.templateIndex,
            template: defaultDecision.template,
            cost: defaultDecision.cost
        )
    }

    let challengerDecision = decide(at: challengerRatio)

    // 4. Override threshold - see `canvasRatioOverrideThreshold`'s own
    // comment. Strict `>`, matching every other tie-break rule in this
    // file: an exact tie (or anything short of a clear win) keeps the
    // square default rather than churning the canvas shape.
    let improvement = defaultDecision.cost - challengerDecision.cost
    let requiredImprovement = canvasRatioOverrideThreshold * Double(photos.count)
    if improvement > requiredImprovement {
        return MagicLayoutDecision(
            canvasRatio: challengerRatio,
            templateIndex: challengerDecision.templateIndex,
            template: challengerDecision.template,
            cost: challengerDecision.cost
        )
    } else {
        return MagicLayoutDecision(
            canvasRatio: .square,
            templateIndex: defaultDecision.templateIndex,
            template: defaultDecision.template,
            cost: defaultDecision.cost
        )
    }
}
