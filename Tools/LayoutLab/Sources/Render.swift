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

// GRID LAYOUT (added for WeightSweep's 8-panel sweep, used unchanged by
// LayoutLab's own 2-panel sheets - see `renderComparisonSheet`'s own doc
// comment): a ribbon N panels wide is unusable once N gets past 3 or 4 - at
// "fit width" zoom on a laptop screen every panel shrinks to a sliver. This
// file now wraps panels into a `columns`-wide grid (default: one row, i.e.
// the original ribbon, so LayoutLab's 2-panel call site is pixel-layout-
// unchanged in spirit) and stamps a large, stable panel NUMBER (1-based,
// left to right then top to bottom - `index + 1` in `variants`, which is
// always in the same fixed order the tool's own `main.swift` builds it in,
// so panel N means the same config on every sheet) into each panel's header.
// That number, not the config name, is what a human is asked to type back.
struct PanelResult {
    var clippedFaceCount: Int
    var totalFaceCount: Int
}

struct PhotoData {
    let id: PhotoID
    let cgImage: CGImage
    let pixelSize: CGSize
    /// The original file's own pixel dimensions (`readSourcePixelSize`),
    /// mirroring `PHAsset.pixelWidth`/`pixelHeight` in the real app - fed to
    /// `autoFrame`'s resolution guard below so LayoutLab actually exercises
    /// the Fix 1 code path instead of always seeing the 2000px proxy. Nil
    /// only if reading the file's properties failed, in which case the
    /// guard falls back to `pixelSize` (unchanged old behavior).
    let sourcePixelSize: CGSize?
    let vision: (faces: [(CGRect, Double)], salient: CGRect?)
    let survivingFaces: [CGRect]
}

struct RenderVariant {
    let label: String
    let template: Node
    let templateIndex: Int
    let extra: String
    /// Marks the panel that reproduces TODAY's shipped `framingCost` weights
    /// (`FramingWeights.current`) - drawn with a small "SHIPS TODAY" tag so
    /// a human flipping through the grid always has the baseline anchored
    /// without having to count panels to find it. Defaults to false so
    /// LayoutLab's own two-variant call site (neither of which is a weight
    /// sweep) doesn't need to change.
    var isShipsToday: Bool = false
}

private let panelCanvas: CGFloat = 900
// Header holds THREE things stacked, all legible at a glance on a
// multi-panel grid sheet (the old 44pt header, sized for a 2-panel ribbon,
// was microscopic relative to an 8-panel sheet): the big panel-number badge,
// the config name (+ "SHIPS TODAY" tag), and the template-index/cost detail
// line.
private let headerHeight: CGFloat = 104
private let titleHeight: CGFloat = 60
private let panelGap: CGFloat = 32
private let margin: CGFloat = 28
// Square badge in the header's left edge holding the big panel number - see
// this file's grid-layout comment above `PanelResult`.
private let numberBadgeSize: CGFloat = 88

/// Renders one comparison sheet and returns one `PanelResult` per input
/// variant, in the same order. `photosByID`/`order` cover every photo in
/// this set; `border` and each variant's `template` are solved fresh at
/// `panelCanvas` size here - proportions match the app's own decision (made
/// at its own nominal canvas) exactly, since every fraction in the tree is
/// scale-invariant.
///
/// `columns` wraps panels into a grid `columns` wide (see this file's
/// grid-layout comment above `PanelResult`); `nil` (LayoutLab's default)
/// means "one row", i.e. every panel across, matching this function's
/// original ribbon layout exactly. Panels are numbered 1-based, left to
/// right then top to bottom, in `variants`' own order.
func renderComparisonSheet(
    setLabel: String,
    fileNames: [String],
    photosByID: [PhotoID: PhotoData],
    variants: [RenderVariant],
    border: BorderStyle,
    outputURL: URL,
    columns: Int? = nil
) -> [PanelResult] {

    let panelCount = variants.count
    guard panelCount > 0 else { return [] }
    let cols = max(1, min(columns ?? panelCount, panelCount))
    let rows = Int(ceil(Double(panelCount) / Double(cols)))

    let totalWidth = margin * 2 + panelCanvas * CGFloat(cols) + panelGap * CGFloat(max(0, cols - 1))
    let totalHeight = margin + titleHeight
        + (headerHeight + panelCanvas) * CGFloat(rows)
        + panelGap * CGFloat(max(0, rows - 1))
        + margin

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
             x: margin, yTop: 16, fontSize: 18, bold: true,
             color: (1, 1, 1), context: context, canvasHeight: totalHeight, maxWidth: totalWidth - margin * 2)

    var results: [PanelResult] = []

    for (index, variant) in variants.enumerated() {
        let col = index % cols
        let row = index / cols
        let panelX = margin + CGFloat(col) * (panelCanvas + panelGap)
        let headerY: CGFloat = titleHeight + CGFloat(row) * (headerHeight + panelCanvas + panelGap)
        let panelY: CGFloat = headerY + headerHeight
        let panelNumber = index + 1

        // Big, stable panel number - the primary label a human types back
        // (see this file's grid-layout comment). Left edge of the header.
        drawNumberBadge(panelNumber,
                        rect: CGRect(x: panelX, y: headerY + (headerHeight - numberBadgeSize) / 2,
                                     width: numberBadgeSize, height: numberBadgeSize),
                        context: context, canvasHeight: totalHeight)

        // Header text stacks in up to three lines beside the number badge:
        // config name, an optional "SHIPS TODAY" tag on its own line, then
        // the template-index/cost detail line - sequential so the tag never
        // collides with either.
        let textX = panelX + numberBadgeSize + 14
        let textMaxWidth = panelCanvas - numberBadgeSize - 14

        drawText(variant.label, x: textX, yTop: headerY + 6, fontSize: 22, bold: true,
                 color: (0.97, 0.97, 1.0), context: context, canvasHeight: totalHeight, maxWidth: textMaxWidth)

        var lineY = headerY + 38
        if variant.isShipsToday {
            _ = drawPill("SHIPS TODAY", x: textX, yTop: lineY, fontSize: 13,
                         context: context, canvasHeight: totalHeight)
            lineY += 28
        }
        drawText("template \(variant.templateIndex)\(variant.extra)",
                 x: textX, yTop: lineY, fontSize: 15, bold: false,
                 color: (0.8, 0.8, 0.88), context: context, canvasHeight: totalHeight,
                 maxWidth: textMaxWidth)

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
                sourcePixelSize: photo.sourcePixelSize,
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

/// Draws a panel's big, stable number: a dark rounded badge with a white
/// border and a large bold numeral, centered inside `rect` (top-left,
/// y-down, same convention as every other rect in this file). This is the
/// PRIMARY label a human reading a WeightSweep sheet is asked to type back
/// (see this file's grid-layout comment) - sized and colored to survive
/// being seen at a glance when the whole multi-panel sheet is on screen,
/// not read up close.
func drawNumberBadge(_ number: Int, rect: CGRect, context: CGContext, canvasHeight: CGFloat) {
    let flipped = CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    let corner = rect.width * 0.18
    let path = CGPath(roundedRect: flipped, cornerWidth: corner, cornerHeight: corner, transform: nil)

    context.saveGState()
    context.addPath(path)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    let fontSize = rect.height * 0.62
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributed = NSAttributedString(string: String(number), attributes: [
        .font: font,
        .foregroundColor: CGColor(red: 1, green: 0.86, blue: 0.2, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

    context.saveGState()
    context.textPosition = CGPoint(
        x: rect.midX - width / 2,
        y: canvasHeight - rect.midY - (ascent - descent) / 2
    )
    CTLineDraw(line, context)
    context.restoreGState()
}

/// Draws a small filled "pill" label (used for the "SHIPS TODAY" tag on
/// today's shipped-weights panel) with its top-left corner at `(x, yTop)`
/// in top-left/y-down space, and returns the pill's width so a caller can
/// lay out anything that follows it on the same line.
@discardableResult
func drawPill(_ text: String, x: CGFloat, yTop: CGFloat, fontSize: CGFloat,
              context: CGContext, canvasHeight: CGFloat) -> CGFloat {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

    let paddingX: CGFloat = 10
    let paddingY: CGFloat = 5
    let pillWidth = textWidth + paddingX * 2
    let pillHeight = ascent + descent + paddingY * 2
    let flipped = CGRect(x: x, y: canvasHeight - yTop - pillHeight, width: pillWidth, height: pillHeight)
    let path = CGPath(roundedRect: flipped, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil)

    context.saveGState()
    context.addPath(path)
    context.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.16, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.textPosition = CGPoint(x: x + paddingX, y: canvasHeight - yTop - paddingY - ascent)
    CTLineDraw(line, context)
    context.restoreGState()

    return pillWidth
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
