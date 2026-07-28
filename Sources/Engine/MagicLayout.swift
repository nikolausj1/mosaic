// Sources/Engine/MagicLayout.swift
// B32 Phase 1 ("Magic Layout" - the face-aware layout DECISION). Pure
// Foundation, no SwiftUI/UIKit/Photos/Vision - same rules as the rest of
// Sources/Engine. See `Magic Layout Spec.md` (project root) and Backlog.md
// B30/B32 for the why; this file is the how.
//
// Three pieces, in the order the spec lists them:
//   1. `mustKeepRegion(...)`  - what a crop must not cut into.
//   2. `framingCost(...)`     - how bad a given cell shape is for that region.
//   3. `faceAwareAssignment(...)` - search templates + permutations by that cost.
//
// PHASE 2 IS NOT HERE. Divider-position search (letting a cell's fractions
// move, not just which template/permutation wins) is explicitly deferred -
// see the seam comment on `faceAwareAssignment` below.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

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
}

/// Minimum acceptable fraction of the resulting crop's AREA that the
/// must-keep region should occupy once framed as tightly as it safely can
/// be; below this, faces read as small even though nothing was clipped.
/// mustKeep already carries `mustKeepFaceMargin` of padding, so demanding
/// near-100% coverage here would penalize ordinary, well-framed group
/// shots - this is deliberately a loose floor, a Phase 1 placeholder like
/// `mustKeepFaceMargin` above.
let minMustKeepAreaCoverage = 0.40

/// Given a must-keep region (normalized to photo space, top-left origin),
/// the photo's own pixel size, and a candidate cell's aspect ratio
/// (width/height), scores how good a fit that cell shape is. Lower is
/// better; 0 is a perfect match. Fully deterministic - pure arithmetic on
/// the inputs, no randomness, no iteration over any unordered collection.
///
/// Method: find the TIGHTEST zoom (in the app's own "1.0 == aspect-fill,
/// larger == cropped in tighter" convention - see `PhotoRef.zoom` in
/// `Model.swift`) whose crop, at `cellAspect`, still fully contains
/// `mustKeep`. Because a crop's visible photo-space extent shrinks
/// monotonically as zoom increases (see `halfVisible` below), and the real
/// zoom floor is 1.0 (aspect-fill - you cannot zoom OUT further), that
/// tightest safe zoom is well-defined: if even the floor (zoom 1.0) cuts
/// into `mustKeep`, no zoom can save it - a clip is unavoidable for this
/// cell shape, and that is the heaviest penalty below. Otherwise, the
/// tightest safe zoom is exactly the boundary where relaxing zoom any
/// further would just start clipping, and everything else is scored
/// relative to that.
func framingCost(mustKeep: CGRect, photoPixelSize: CGSize, cellAspect: Double) -> Double {
    guard mustKeep.width > 0, mustKeep.height > 0, cellAspect > 0,
          photoPixelSize.width > 0, photoPixelSize.height > 0 else { return 0 }

    // `halfVisible` depends only on cellSize's ASPECT (see its own comment
    // in AutoFrame.swift), so a synthetic (cellAspect, 1.0) size is a
    // faithful stand-in for the real cell without needing its actual point
    // dimensions - `framingCost` only ever gets a ratio from its caller.
    let syntheticCell = CGSize(width: cellAspect, height: 1.0)
    let vis1 = halfVisible(zoom: 1.0, photoPixelSize: photoPixelSize, cellSize: syntheticCell)
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
        cost += FramingCostWeight.clip * severity
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
        if areaCoverage < minMustKeepAreaCoverage {
            cost += FramingCostWeight.smallFace * (minMustKeepAreaCoverage - areaCoverage)
        }

        // Excess zoom past the app's own established auto-zoom ceiling
        // (2.0x) - the crop is safe, but reaching it required cropping in
        // further than the app itself otherwise considers reasonable.
        let excessZoom = max(0.0, tightestSafeZoom - 2.0)
        cost += FramingCostWeight.cropLoss * excessZoom
    }

    // Aspect mismatch between the must-keep region's own shape and the
    // cell's, independent of zoom - same log-distance shape
    // `contentFitAssignment` already uses for photo-vs-cell aspect.
    let mustKeepAspect = mustKeepW / mustKeepH
    cost += FramingCostWeight.aspect * abs(log(mustKeepAspect) - log(cellAspect))

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
/// PHASE 2 SEAM (do not implement here): this only tries each template's
/// AUTHORED fractions. A follow-up phase can nest a coarse divider-fraction
/// search (~0.3...0.7 in 5 steps, see `Magic Layout Spec.md`'s Phase 2)
/// inside the `for (templateIndex, template) in candidates.enumerated()`
/// loop below - re-solving at each candidate fraction set before scoring -
/// without changing this function's signature or its callers.
func faceAwareAssignment(
    photos: [PhotoID],
    photoSizes: [PhotoID: CGSize],
    mustKeepRegions: [PhotoID: CGRect],
    canvasSize: CGSize,
    border: BorderStyle
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
    // improvement" outcome the spec rules out.
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

        let (cells, _) = solve(root: template, canvasSize: canvasSize, border: border)
        let cellByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })
        let slotAspects: [Double] = originalOrder.map { id in
            cellByID[id].map { aspect($0) } ?? 1
        }

        var bestPermCost = Double.infinity
        var bestPermutation = originalOrder

        for perm in permutations(originalOrder) {
            var cost = 0.0
            for slot in 0..<perm.count {
                let photoID = perm[slot]
                let cellAspect = slotAspects[slot]
                guard cellAspect > 0 else { continue }

                if let mustKeep = mustKeepRegions[photoID] {
                    let pixelSize = photoSizes[photoID] ?? CGSize(width: 1, height: 1)
                    cost += framingCost(mustKeep: mustKeep, photoPixelSize: pixelSize, cellAspect: cellAspect)
                } else {
                    let photoAspect = aspect(photoSizes[photoID] ?? CGSize(width: 1, height: 1))
                    guard photoAspect > 0 else { continue }
                    cost += FramingCostWeight.aspect * abs(log(photoAspect) - log(cellAspect))
                }
            }
            if cost < bestPermCost {
                bestPermCost = cost
                bestPermutation = perm
            }
        }

        if bestPermCost < bestCost {
            bestCost = bestPermCost
            bestTemplateIndex = templateIndex
            var cursor = 0
            bestTemplate = replacingLeavesInOrder(template, with: bestPermutation, cursor: &cursor)
        }
    }

    return FaceAwareAssignment(templateIndex: bestTemplateIndex, template: bestTemplate, cost: bestCost)
}
