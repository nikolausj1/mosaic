// Tools/LayoutLab/Sources/Render.swift
// Composites one contact-sheet PNG per photo set: the WITHOUT-face-awareness
// layout side by side with the face-aware layout, each cell showing the
// actual cropped photo with detected-face outlines overlaid (clipped faces
// in red - the single failure this tool exists to make visible at a glance).
//
// Coordinate note (the exact trap the Build Guide warns about, one level up
// the stack from Vision's own bottom-left/top-left flip): every rect this
// file computes - cell rects from `solve()`, crop rects, face-overlay rects -
// is in TOP-LEFT, y-down space, matching the Engine's own convention. A raw
// `CGContext(data: nil, ...)` is NOT top-left/y-down by default (y grows
// upward from the bottom), and unlike `CGContextDrawImage` (which
// auto-orients its image), rect-based drawing (`stroke`, `fill`) does not -
// so an early version of this file applied a single global flip transform
// to the whole context and got a WHOLE-IMAGE flip instead of a
// per-drawing-call fix (confirmed by the face overlay boxes tracking the
// faces correctly even though the entire photo rendered upside down - both
// the image draw and the rect draw were consistently wrong together).
// Fixed here by leaving the context in its native orientation and flipping
// each rect individually via `flipY` right before it is used - verified by
// eye against a real face (see the tool's own report).
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import CoreText
import ImageIO
// AppKit only for the NSAttributedString.Key.font/.foregroundColor constants
// used by `drawText` below - no windows/views, this stays a plain CLI tool.
import AppKit

struct PanelResult {
    var clippedFaceCount: Int
    var totalFaceCount: Int
}

struct PhotoData {
    let id: PhotoID
    let cgImage: CGImage
    let pixelSize: CGSize
    let vision: (faces: [(CGRect, Double)], salient: CGRect?)
    let survivingFaces: [CGRect]
}

struct RenderVariant {
    let label: String
    let template: Node
    let templateIndex: Int
    let extra: String
}

private let panelCanvas: CGFloat = 900
private let headerHeight: CGFloat = 44
private let titleHeight: CGFloat = 64
private let panelGap: CGFloat = 28
private let margin: CGFloat = 24

/// Renders one comparison sheet and returns one `PanelResult` per input
/// variant, in the same order. `photosByID`/`order` cover every photo in
/// this set; `border` and each variant's `template` are solved fresh at
/// `panelCanvas` size here - proportions match the app's own decision (made
/// at its own nominal canvas) exactly, since every fraction in the tree is
/// scale-invariant.
func renderComparisonSheet(
    setLabel: String,
    fileNames: [String],
    photosByID: [PhotoID: PhotoData],
    variants: [RenderVariant],
    border: BorderStyle,
    outputURL: URL
) -> [PanelResult] {

    let panelCount = variants.count
    let totalWidth = margin * 2 + panelCanvas * CGFloat(panelCount) + panelGap * CGFloat(max(0, panelCount - 1))
    let totalHeight = margin + titleHeight + headerHeight + panelCanvas + margin

    // TOP-LEFT, y-down rect -> the native (y-up-from-bottom) rect this raw
    // CGContext actually expects. Applied individually to every rect drawn
    // below - see this file's header comment for why a single whole-context
    // flip is the wrong fix.
    func flipY(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: totalHeight - r.maxY, width: r.width, height: r.height)
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: Int(totalWidth.rounded()),
        height: Int(totalHeight.rounded()),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return [] }

    context.setFillColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

    drawText(setLabel + "  —  " + fileNames.joined(separator: ", "),
             x: margin, yTop: 14, fontSize: 15, bold: true,
             color: (1, 1, 1), context: context, canvasHeight: totalHeight, maxWidth: totalWidth - margin * 2)

    var results: [PanelResult] = []

    for (index, variant) in variants.enumerated() {
        let panelX = margin + CGFloat(index) * (panelCanvas + panelGap)
        let headerY: CGFloat = titleHeight
        let panelY: CGFloat = titleHeight + headerHeight

        drawText("\(variant.label) — template \(variant.templateIndex)\(variant.extra)",
                 x: panelX, yTop: headerY + 10, fontSize: 14, bold: false,
                 color: (0.85, 0.85, 0.92), context: context, canvasHeight: totalHeight, maxWidth: panelCanvas)

        let canvasSize = CGSize(width: panelCanvas, height: panelCanvas)
        let (cells, _) = solve(root: variant.template, canvasSize: canvasSize, border: border)

        var clipped = 0
        var total = 0

        for cell in cells {
            guard let photo = photosByID[cell.id] else { continue }
            let cellRectLocal = cell.rect // top-left, y-down, panel-local
            let cellRectImage = CGRect(
                x: panelX + cellRectLocal.minX,
                y: panelY + cellRectLocal.minY,
                width: cellRectLocal.width,
                height: cellRectLocal.height
            )

            let roi = autoFrame(AutoFrameInput(
                faces: photo.vision.faces.map(\.0),
                faceConfidences: photo.vision.faces.map(\.1),
                salientRegion: photo.vision.salient,
                photoPixelSize: photo.pixelSize,
                cellSize: cellRectLocal.size
            ))
            let zoom = roi?.zoom ?? 1.0
            let center = roi?.center ?? CGPoint(x: 0.5, y: 0.5)

            // Same halfVisible math autoFrame/framingCost use internally -
            // turns (zoom, center) back into the actual crop window, in the
            // photo's own normalized (top-left) space.
            let vis = halfVisible(zoom: zoom, photoPixelSize: photo.pixelSize, cellSize: cellRectLocal.size)
            let cropWNorm = 2 * vis.hx
            let cropHNorm = 2 * vis.hy
            let cropXNorm = Double(center.x) - vis.hx
            let cropYNorm = Double(center.y) - vis.hy

            let photoW = Double(photo.pixelSize.width)
            let photoH = Double(photo.pixelSize.height)
            var cropPixelRect = CGRect(
                x: cropXNorm * photoW,
                y: cropYNorm * photoH,
                width: cropWNorm * photoW,
                height: cropHNorm * photoH
            )
            // Defensive clamp only - clampedCenter (inside autoFrame) already
            // guarantees this crop sits inside the image; this just protects
            // `cropping(to:)` from a stray floating-point sliver.
            cropPixelRect = cropPixelRect.intersection(CGRect(x: 0, y: 0, width: photoW, height: photoH))

            if cropPixelRect.width > 0, cropPixelRect.height > 0,
               let cropped = photo.cgImage.cropping(to: cropPixelRect) {
                context.draw(cropped, in: flipY(cellRectImage))
            }

            // Face overlays: map each surviving face (normalized, top-left,
            // PHOTO space) into the crop window's own normalized space, then
            // into this cell's on-canvas pixel rect. A face only partially
            // (or not at all) inside the crop window is CLIPPED.
            for face in photo.survivingFaces {
                total += 1
                let relX = (Double(face.minX) - cropXNorm) / cropWNorm
                let relY = (Double(face.minY) - cropYNorm) / cropHNorm
                let relW = Double(face.width) / cropWNorm
                let relH = Double(face.height) / cropHNorm

                let isClipped = relX < 0 || relY < 0 || (relX + relW) > 1 || (relY + relH) > 1
                if isClipped { clipped += 1 }

                let faceRectImage = CGRect(
                    x: cellRectImage.minX + relX * cellRectImage.width,
                    y: cellRectImage.minY + relY * cellRectImage.height,
                    width: relW * cellRectImage.width,
                    height: relH * cellRectImage.height
                ).intersection(cellRectImage)

                guard faceRectImage.width > 0, faceRectImage.height > 0 else { continue }
                context.setLineWidth(isClipped ? 3 : 1.5)
                context.setStrokeColor(isClipped
                    ? CGColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)
                    : CGColor(red: 0.2, green: 1, blue: 0.9, alpha: 1))
                context.stroke(flipY(faceRectImage))
            }
        }

        // Faint cell borders so the template's own divisions read even where
        // no face overlay happens to draw a line.
        context.setLineWidth(1)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
        for cell in cells {
            let r = CGRect(x: panelX + cell.rect.minX, y: panelY + cell.rect.minY, width: cell.rect.width, height: cell.rect.height)
            context.stroke(flipY(r))
        }

        results.append(PanelResult(clippedFaceCount: clipped, totalFaceCount: total))
    }

    guard let image = context.makeImage() else { return results }
    writePNG(image: image, to: outputURL)
    return results
}

func writePNG(image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// Draws left-aligned text so its TOP sits `yTop` points below the image's
/// top edge - the context is in its native (y-up-from-bottom) orientation
/// (see this file's header comment), so the baseline is placed at
/// `canvasHeight - yTop - ascent`, not at `yTop` directly.
func drawText(_ string: String, x: CGFloat, yTop: CGFloat, fontSize: CGFloat, bold: Bool,
              color: (CGFloat, CGFloat, CGFloat), context: CGContext, canvasHeight: CGFloat, maxWidth: CGFloat) {
    let approxCharsPerLine = max(4, Int(maxWidth / (fontSize * 0.55)))
    let clipped = string.count > approxCharsPerLine
        ? String(string.prefix(approxCharsPerLine - 1)) + "…"
        : string

    let fontName = bold ? "Helvetica-Bold" : "Helvetica"
    let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
    let cgColor = CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
    let attributed = NSAttributedString(string: clipped, attributes: [
        .font: font,
        .foregroundColor: cgColor
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let ascent = CTFontGetAscent(font)

    context.saveGState()
    context.textPosition = CGPoint(x: x, y: canvasHeight - yTop - ascent)
    CTLineDraw(line, context)
    context.restoreGState()
}
