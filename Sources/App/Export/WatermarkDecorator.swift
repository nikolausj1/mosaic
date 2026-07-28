// Sources/App/Export/WatermarkDecorator.swift
// B8's watermark: the ExportDecorator CollageRenderer's compositing hook was
// built for (see its doc comment in CollageRenderer.swift). App-layer only -
// UIKit/CoreText, never imported by Sources/Engine. SaveCoordinator/EditorView
// decide WHETHER to use this (only when the user hasn't bought the
// remove-watermark unlock); this type only knows how to draw it.
import UIKit
import CoreGraphics

struct WatermarkDecorator: ExportDecorator {
    /// Lockup height as a fraction of the image's long edge - keeps the
    /// visual mass of B8's original "~4% cap height" text mark now that the
    /// mark is the brand lockup image (Justin, 2026-07-26).
    private static let lockupHeightFraction: CGFloat = 0.035
    /// Corner inset as a fraction of the lockup height (B8: "inset from the
    /// edges by about half the watermark height").
    private static let insetFraction: CGFloat = 0.5
    /// Chip padding around the lockup, as a fraction of lockup height. The
    /// dark backing chip is what keeps the white letters legible on light
    /// photos (replaces the old text stroke+shadow).
    private static let chipPaddingFraction: CGFloat = 0.45

    /// `document.border.outer` - same fraction-of-canvas-short-edge
    /// convention as `BorderStyle` (see Model.swift/Layout.swift). Computed
    /// against the actual export pixel size inside `decorate`, not
    /// pre-multiplied, since this decorator is built before CollageRenderer
    /// picks the final export size.
    let outerBorderFraction: Double

    func decorate(context: CGContext, size: CGSize) {
        // One lockup asset everywhere (Justin, 2026-07-27): the art supplied
        // as watermark.png - same mark, lighter blue "o", easier to read -
        // is now THE lockup, used by the picker masthead and the welcome
        // screen too, so there is no second variant to keep in sync.
        guard let lockup = UIImage(named: "Lockup"), lockup.size.height > 0 else { return }

        let shortEdge = min(size.width, size.height)
        let longEdge = max(size.width, size.height)
        let lockupHeight = longEdge * Self.lockupHeightFraction
        let lockupWidth = lockupHeight * (lockup.size.width / lockup.size.height)
        let padding = lockupHeight * Self.chipPaddingFraction
        let chipSize = CGSize(width: lockupWidth + padding * 2, height: lockupHeight + padding * 2)

        let outerMarginPixels = shortEdge * CGFloat(outerBorderFraction)
        // "inside the outer margin if one exists" (B8): the larger of the
        // two insets wins, so a thick border pushes the mark further in
        // rather than letting it sit on top of the border.
        let inset = max(lockupHeight * Self.insetFraction, outerMarginPixels)

        let chipRect = CGRect(
            x: size.width - inset - chipSize.width,
            y: size.height - inset - chipSize.height,
            width: chipSize.width,
            height: chipSize.height
        )

        UIGraphicsPushContext(context)
        context.saveGState()
        // The canvas-color chip (0B0B0D, mostly opaque) behind the lockup -
        // the same "dark background" treatment the brand uses everywhere
        // else, and what guarantees the white letters read on any photo.
        let chipPath = CGPath(
            roundedRect: chipRect,
            cornerWidth: chipRect.height * 0.28,
            cornerHeight: chipRect.height * 0.28,
            transform: nil
        )
        context.addPath(chipPath)
        context.setFillColor(UIColor(red: 11/255, green: 11/255, blue: 13/255, alpha: 0.78).cgColor)
        context.fillPath()

        lockup.draw(in: CGRect(
            x: chipRect.minX + padding,
            y: chipRect.minY + padding,
            width: lockupWidth,
            height: lockupHeight
        ))
        context.restoreGState()
        UIGraphicsPopContext()
    }
}
