// Sources/Engine/Export.swift
// Picks the export pixel size so the most detail-rich cell renders 1:1;
// never lets one low-resolution photo drag the whole export down.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

func exportPixelSize(doc: Document, canvasUnits: CGSize) -> CGSize {
    let (cells, _) = solve(root: doc.root, canvasSize: canvasUnits, border: doc.border)

    var k: Double = 1
    var haveK = false

    for cell in cells {
        guard let photo = doc.photos[cell.id] else { continue }

        let odd = (((photo.quarterTurns % 4) + 4) % 4) % 2 == 1
        let photoW = odd ? Double(photo.pixelHeight) : Double(photo.pixelWidth)
        let photoH = odd ? Double(photo.pixelWidth) : Double(photo.pixelHeight)

        let cellW = cell.rect.width
        let cellH = cell.rect.height
        guard cellW > 0, cellH > 0, photoW > 0, photoH > 0 else { continue }

        let s0 = max(cellW / photoW, cellH / photoH)
        let displayScale = s0 * photo.zoom
        guard displayScale > 0 else { continue }

        let visibleWidthPx = cellW / displayScale
        let k_c = visibleWidthPx / cellW // == 1 / displayScale

        if !haveK || k_c > k {
            k = k_c
            haveK = true
        }
    }

    var outW = canvasUnits.width * k
    var outH = canvasUnits.height * k

    let longEdge = max(outW, outH)
    if longEdge > 4096 {
        let capScale = 4096 / longEdge
        outW *= capScale
        outH *= capScale
    }

    return CGSize(width: outW.rounded(), height: outH.rounded())
}
