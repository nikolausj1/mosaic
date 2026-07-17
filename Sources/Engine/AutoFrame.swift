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
private func halfVisible(zoom: Double, photoPixelSize: CGSize, cellSize: CGSize) -> (hx: Double, hy: Double) {
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
/// the photo's SHORT edge) and confidence.
private func thresholdedFaces(_ input: AutoFrameInput) -> [CGRect] {
    let photoH = Double(input.photoPixelSize.height)
    let shortEdge = min(Double(input.photoPixelSize.width), Double(input.photoPixelSize.height))
    let minPixelHeight = 0.08 * shortEdge

    var kept: [CGRect] = []
    for (i, face) in input.faces.enumerated() {
        let confidence = i < input.faceConfidences.count ? input.faceConfidences[i] : 0
        guard confidence >= 0.5 else { continue }
        let facePixelHeight = Double(face.height) * photoH
        guard facePixelHeight >= minPixelHeight else { continue }
        kept.append(face)
    }
    return kept
}

/// Union of a non-empty array of normalized rects.
private func unionRect(_ rects: [CGRect]) -> CGRect {
    var result = rects[0]
    for r in rects.dropFirst() { result = result.union(r) }
    return result
}

/// The pure auto-framing math (PRD-locked algorithm). Returns nil when
/// neither a surviving face nor a saliency box exists - callers should fall
/// back to a center/fill crop in that case.
func autoFrame(_ input: AutoFrameInput) -> ROI? {
    let survivingFaces = thresholdedFaces(input)

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
    let finalZoom = min(zoomTarget, guardCap)

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
