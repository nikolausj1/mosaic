// Sources/Engine/ExportPlan.swift
// Per-cell downsampling plan for the export pipeline. Export.swift's
// exportPixelSize picks the OVERALL canvas scale (a maximization across
// cells); this file answers a different question per cell, once that
// overall size is fixed: how many NATIVE source pixels does THIS cell
// actually need decoded to render at ~1:1 detail - no more (so a 48MP photo
// filling an 800px cell never gets decoded past ~800px), no less. Pure
// Foundation, mirrors the same fillScale/effectivePhotoSize math the
// renderer (Sources/App/Export/CollageRenderer.swift) and the canvas
// (GestureController.swift) both use, so all three stay in lockstep.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct ExportCellPlan: Equatable {
    let id: PhotoID
    let rect: CGRect                  // cell rect in EXPORT-pixel space (from solve() run at export size)
    let thumbnailMaxPixelSize: Int     // arg for kCGImageSourceThumbnailMaxPixelSize
}

// Solves the document directly AT the export pixel size - border/gutter
// fractions are canvas-short-edge relative (see BorderStyle's doc comment in
// Model.swift), so they scale automatically and this is exactly the same
// geometry the export renderer draws into. For each cell with a photo,
// pairs the solved rect with its minimal decode target.
func exportCellPlans(doc: Document, exportSize: CGSize) -> [ExportCellPlan] {
    let (cells, _) = solve(root: doc.root, canvasSize: exportSize, border: doc.border)
    return cells.compactMap { cell in
        guard let photo = doc.photos[cell.id] else { return nil }
        let size = requiredThumbnailMaxPixelSize(
            cellSize: cell.rect.size,
            photoPixelWidth: photo.pixelWidth,
            photoPixelHeight: photo.pixelHeight,
            quarterTurns: photo.quarterTurns,
            zoom: photo.zoom
        )
        return ExportCellPlan(id: cell.id, rect: cell.rect, thumbnailMaxPixelSize: size)
    }
}

// The number of NATIVE source pixels (the photo's own pixelWidth/pixelHeight
// space - post EXIF-orientation-correction, pre the document's own
// quarterTurns rotation) needed so the cell renders at ~1:1 detail.
//
// Derivation: the renderer scales the native image by displayScale = s0 *
// zoom (s0 = the aspect-fill scale against the EFFECTIVE, rotation-aware
// size - same as fillScale in GestureController.swift). A native pixel grid
// downsampled/decoded at a fraction `r` of its full resolution occupies (nativeDim
// * r) decoded pixels; drawing that decoded image into the cell stretches it
// by (approximately) 1/r relative to a full-res decode, so setting r =
// displayScale makes decoded-pixel density land at ~1:1 in the cell - MORE
// than that wastes memory decoding detail that gets thrown away scaling
// down; LESS than that decodes fewer pixels than the cell will show,
// softening the result. Clamped so we never ask a thumbnail decoder to
// upsample past the source's own resolution (any further upsampling, e.g.
// zoom > 1 against a small source, happens for free in the CGContext draw
// step, same as it already does on the live canvas).
func requiredThumbnailMaxPixelSize(
    cellSize: CGSize,
    photoPixelWidth: Int,
    photoPixelHeight: Int,
    quarterTurns: Int,
    zoom: Double
) -> Int {
    let nativeW = Double(photoPixelWidth)
    let nativeH = Double(photoPixelHeight)
    guard nativeW > 0, nativeH > 0, cellSize.width > 0, cellSize.height > 0 else { return 1 }

    let odd = (((quarterTurns % 4) + 4) % 4) % 2 == 1
    let effW = odd ? nativeH : nativeW
    let effH = odd ? nativeW : nativeH
    guard effW > 0, effH > 0 else { return 1 }

    let s0 = max(cellSize.width / effW, cellSize.height / effH)
    let displayScale = s0 * zoom
    let nativeMax = max(nativeW, nativeH)
    guard displayScale.isFinite, displayScale > 0 else { return Int(nativeMax.rounded()) }

    let needed = (nativeMax * displayScale).rounded(.up)
    let clamped = min(max(needed, 1), nativeMax)
    return Int(clamped)
}
