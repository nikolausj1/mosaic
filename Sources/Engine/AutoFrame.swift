// Sources/Engine/AutoFrame.swift
// Pure auto-framing math. Vision results come in as plain rects - this file
// never imports Vision/Photos/UIKit. All rects are NORMALIZED to photo space,
// origin top-left, y down (the App layer converts Vision's bottom-left
// coordinates before calling in). Pure Foundation, no SwiftUI/UIKit/Vision.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct AutoFrameInput {
    var faces: [CGRect]          // normalized to photo space, top-left origin, y down. NOT pre-thresholded.
    var faceConfidences: [Double]
    var salientRegion: CGRect?   // attention-based saliency box, normalized, top-left origin
    var photoPixelSize: CGSize   // effective (pre-rotation; prototype photos are qt 0)
    var cellSize: CGSize         // the cell this photo landed in, canvas points
}

/// Half the visible extent of the photo at a given zoom, normalized to the
/// photo's own 0...1 space (mirrors `clampedCenter`'s hx/hy derivation).
/// Not private: `MagicLayout.swift`'s `framingCost` reuses this directly
/// (passing a synthetic `cellSize` that carries only a target aspect - the
/// math here depends solely on cellSize's width/height RATIO, never its
/// absolute magnitude, so that's a legitimate reuse, not a coincidence).
func halfVisible(zoom: Double, photoPixelSize: CGSize, cellSize: CGSize) -> (hx: Double, hy: Double) {
    let photoW = Double(photoPixelSize.width)
    let photoH = Double(photoPixelSize.height)
    guard photoW > 0, photoH > 0, cellSize.width > 0, cellSize.height > 0 else { return (0.5, 0.5) }

    let s0 = max(Double(cellSize.width) / photoW, Double(cellSize.height) / photoH)
    let displayScale = s0 * zoom
    guard displayScale > 0 else { return (0.5, 0.5) }

    let hx = (Double(cellSize.width) / displayScale) / photoW / 2
    let hy = (Double(cellSize.height) / displayScale) / photoH / 2
    return (hx, hy)
}

/// Step 1: faces surviving both thresholds - height (in PIXEL terms, against
/// the photo's SHORT edge) and confidence. Factored out of `AutoFrameInput`
/// (not private) so `MagicLayout.swift`'s `mustKeepRegion` can reuse the
/// EXACT same thresholds (confidence 0.5, 8% of the short edge) rather than
/// inventing its own - see B32 Phase 1 in `Magic Layout Spec.md`.
func thresholdedFaces(faces: [CGRect], faceConfidences: [Double], photoPixelSize: CGSize) -> [CGRect] {
    let photoH = Double(photoPixelSize.height)
    let shortEdge = min(Double(photoPixelSize.width), Double(photoPixelSize.height))
    let minPixelHeight = 0.08 * shortEdge

    var kept: [CGRect] = []
    for (i, face) in faces.enumerated() {
        let confidence = i < faceConfidences.count ? faceConfidences[i] : 0
        guard confidence >= 0.5 else { continue }
        let facePixelHeight = Double(face.height) * photoH
        guard facePixelHeight >= minPixelHeight else { continue }
        kept.append(face)
    }
    return kept
}

/// Union of a (possibly empty) array of normalized rects; `.zero` for an
/// empty array. Not private: `MagicLayout.swift`'s `mustKeepRegion` reuses
/// this for the same union-of-surviving-faces math `autoFrame` does below.
func unionRect(_ rects: [CGRect]) -> CGRect {
    guard let first = rects.first else { return .zero }
    var result = first
    for r in rects.dropFirst() { result = result.union(r) }
    return result
}

/// The pure auto-framing math (PRD-locked algorithm). Returns nil when
/// neither a surviving face nor a saliency box exists - callers should fall
/// back to a center/fill crop in that case.
func autoFrame(_ input: AutoFrameInput) -> ROI? {
    let survivingFaces = thresholdedFaces(faces: input.faces, faceConfidences: input.faceConfidences, photoPixelSize: input.photoPixelSize)

    // Step 2: zoom from SALIENCY ONLY - never from faces.
    var zoomTarget = 1.0
    if let box = input.salientRegion, box.width > 0, box.height > 0 {
        let vis1 = halfVisible(zoom: 1.0, photoPixelSize: input.photoPixelSize, cellSize: input.cellSize)
        let visW1 = 2 * vis1.hx
        let visH1 = 2 * vis1.hy

        let coverage = max(Double(box.width) / visW1, Double(box.height) / visH1)
        // Epsilon guards the documented == 0.60 boundary (e.g. thirds like
        // 2/3 aren't exactly representable in binary floating point, so a
        // mathematically-exact 0.60 can otherwise land a hair on either
        // side of the comparison depending on rounding direction).
        if coverage > 0.60 + 1e-9 {
            zoomTarget = 1.0
        } else {
            let candidateX = 0.75 * visW1 / Double(box.width)
            let candidateY = 0.75 * visH1 / Double(box.height)
            zoomTarget = min(candidateX, candidateY)
            zoomTarget = min(max(zoomTarget, 1.0), 2.0)
        }
    }

    // Step 3: resolution guard - low-res sources refuse to zoom.
    let vis1ForGuard = halfVisible(zoom: 1.0, photoPixelSize: input.photoPixelSize, cellSize: input.cellSize)
    let visiblePxW = 2 * vis1ForGuard.hx * Double(input.photoPixelSize.width)
    let visiblePxH = 2 * vis1ForGuard.hy * Double(input.photoPixelSize.height)
    let minVisPx = min(visiblePxW, visiblePxH)
    let guardCap = max(1.0, minVisPx / 2048.0)
    var finalZoom = min(zoomTarget, guardCap)

    // Step 3.5: tighten toward the same must-keep AREA-coverage target
    // `framingCost`'s `minMustKeepAreaCoverage` (MagicLayout.swift) already
    // assumes the layout chooser can rely on - so the framer delivers on it
    // too, instead of only zooming when the photo's raw aspect happens to
    // force it (see this function's own header comment / the B32 set12
    // finding: a portrait photo in a portrait-ish cell needed no aspect-fill
    // zoom and stayed at 1.0 even with a tiny face). `mustKeepRegion` gives
    // the EXACT same subject region `framingCost` scores against: the
    // surviving-face union plus margin when a face survives, else the raw
    // saliency box untouched, else nil - so a photo with neither (a
    // landscape, or anything Vision found nothing in) takes this branch
    // never, and its behavior is unchanged, byte for byte.
    if let subject = mustKeepRegion(
        faces: input.faces,
        faceConfidences: input.faceConfidences,
        salientRegion: input.salientRegion,
        photoPixelSize: input.photoPixelSize
    ), subject.width > 0, subject.height > 0 {
        let visW1 = 2 * vis1ForGuard.hx
        let visH1 = 2 * vis1ForGuard.hy
        let subjectW = Double(subject.width)
        let subjectH = Double(subject.height)

        // The zoom at which the subject would exactly touch the crop's edge
        // on its tighter axis - beyond this, the crop starts clipping the
        // subject. This bound outranks everything else here: it is derived
        // the same way `framingCost`'s own `tightestSafeZoom` is (visible
        // extent shrinks as 1/zoom, so this is just solving each axis's
        // "visible extent == subject extent" for zoom and taking the
        // tighter, binding one).
        let noClipZoom = min(visW1 / subjectW, visH1 / subjectH)

        // The zoom at which the subject's AREA would fill exactly
        // `minMustKeepAreaCoverage` of the crop. Inverts `framingCost`'s own
        // areaCoverage formula (coverage = subjectArea / visibleArea, and
        // visibleArea shrinks as 1/zoom^2) to solve for zoom directly rather
        // than searching for it.
        let targetZoom = sqrt(minMustKeepAreaCoverage * visW1 * visH1 / (subjectW * subjectH))

        // Never exceed: the no-clip bound above (outranks everything), the
        // app's own 2.0x auto-zoom ceiling (Backlog B20, same one
        // `zoomTarget` already clamps to), or the resolution guard already
        // computed in Step 3 - and never zoom OUT from whatever
        // saliency/resolution already chose, only ever in, and only as far
        // as needed (conservative at the boundary: under-zooming is a far
        // better failure than clipping a face).
        let boundedTarget = min(targetZoom, noClipZoom, 2.0, guardCap)
        finalZoom = max(finalZoom, boundedTarget)
    }

    // Step 4: center.
    let rawCenter: CGPoint
    if !survivingFaces.isEmpty {
        let union = unionRect(survivingFaces)
        let hy = halfVisible(zoom: finalZoom, photoPixelSize: input.photoPixelSize, cellSize: input.cellSize).hy
        let centroidX = Double(union.midX)
        let centroidY = Double(union.midY)
        rawCenter = CGPoint(x: centroidX, y: centroidY + 0.1 * hy)
    } else if let box = input.salientRegion {
        rawCenter = CGPoint(x: box.midX, y: box.midY)
    } else {
        return nil
    }

    // Step 5: clamp at the final zoom and return.
    let clamped = clampedCenter(
        center: rawCenter,
        zoom: finalZoom,
        photoPixelSize: input.photoPixelSize,
        quarterTurns: 0,
        cellSize: input.cellSize
    )
    return ROI(center: clamped, zoom: finalZoom)
}
