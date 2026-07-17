// Sources/App/Export/CollageRenderer.swift
// The full-resolution export pipeline (PRD "Export rule", locked): a raw
// CGContext - never SwiftUI's ImageRenderer, which is unreliable at large
// scales - reproducing exactly what CanvasView shows, at the Engine's
// chosen export pixel size. Photos are composited ONE AT A TIME so peak
// memory stays bounded (S4 target < 400MB): each source CGImage is fetched,
// drawn, and released before the next is requested.
//
// RENDERING CONTRACT (locked in Phase 4 - see panDelta's note in
// GestureController.swift): PhotoRef.center is in EFFECTIVE DISPLAYED
// space - the photo as displayed after rotation/flips, normalized 0...1,
// screen-aligned axes. This file reproduces CanvasView's cellContent(...)
// pixel-for-pixel: same fillScale/effectivePhotoSize helpers (reused
// directly, not reimplemented), same offset formula, same
// translate/rotate/flip/draw order.
import UIKit
import CoreGraphics

enum ExportError: Error, Equatable {
    /// The render pipeline failed (context allocation, or a photo failed to
    /// decode) even after the half-scale retry.
    case renderFailed
    case jpegEncodingFailed
}

/// v1 pass-through, architecture mandatory for v2: the export pipeline ends
/// with a single compositing hook. v2 draws a small wordmark here (~4% of
/// the long edge, bottom-right, inside the outer margin if one exists,
/// white with a subtle dark stroke). v1 does nothing - this is the PRD's
/// "watermark seam."
protocol ExportDecorator {
    func decorate(context: CGContext, size: CGSize)
}

struct NoOpDecorator: ExportDecorator {
    func decorate(context: CGContext, size: CGSize) {}
}

/// Fetches (and downsamples) the source pixels for one photo, given the
/// minimal native pixel size (`ExportPlan.requiredThumbnailMaxPixelSize`)
/// the renderer has determined that cell needs. Implemented by
/// SaveCoordinator (which owns PHImageManager / the in-memory proxy
/// fallback) - kept as a plain closure here so this file stays testable
/// without Photos.
typealias CollageImageProvider = (_ photoID: PhotoID, _ maxPixelSize: Int) async -> CGImage?

struct CollageRenderer {
    var decorator: ExportDecorator = NoOpDecorator()

    /// Renders `document` at the Engine's chosen export pixel size
    /// (`exportPixelSize`, computed from `canvasSize` - the on-screen canvas
    /// at export time). That function's math is scale-invariant to
    /// `canvasSize`'s absolute magnitude as long as its aspect ratio matches
    /// `document.canvasRatio` (uniform scaling of the input cancels out of
    /// the k factor), so passing the live on-screen `state.canvasSize`
    /// directly is exact, not an approximation.
    ///
    /// On a hard render failure (context allocation failure, or any photo
    /// failing to decode), retries ONCE at half the pixel size before
    /// surfacing `.renderFailed`.
    func renderCollage(
        document: Document,
        canvasSize: CGSize,
        imageProvider: @escaping CollageImageProvider
    ) async -> Result<(image: UIImage, pixelSize: CGSize), ExportError> {
        let fullSize = exportPixelSize(doc: document, canvasUnits: canvasSize)
        if let image = await attemptRender(document: document, exportSize: fullSize, imageProvider: imageProvider) {
            return .success((image, fullSize))
        }

        let halfSize = CGSize(
            width: max((fullSize.width / 2).rounded(), 1),
            height: max((fullSize.height / 2).rounded(), 1)
        )
        if let image = await attemptRender(document: document, exportSize: halfSize, imageProvider: imageProvider) {
            return .success((image, halfSize))
        }

        return .failure(.renderFailed)
    }

    // MARK: - One render attempt

    private func attemptRender(
        document: Document,
        exportSize: CGSize,
        imageProvider: CollageImageProvider
    ) async -> UIImage? {
        guard let context = makeTopLeftContext(size: exportSize) else { return nil }

        let plans = exportCellPlans(doc: document, exportSize: exportSize)
        let cornerRadiusFraction = document.border.cornerRadius

        // Background: fills the outer margin and every gutter with the
        // border color, exactly like CanvasView's base Rectangle fill.
        context.setFillColor(cgColor(from: document.border.color))
        context.fill(CGRect(origin: .zero, size: exportSize))

        for plan in plans {
            guard let photo = document.photos[plan.id] else { continue }

            // Fetched and drawn one photo at a time; `cgImage` is a local
            // that goes out of scope (and is released) before the next
            // iteration's `await` fetches the following photo - this is
            // what bounds peak memory (S4).
            guard let cgImage = await imageProvider(plan.id, plan.thumbnailMaxPixelSize) else {
                // Missing/undecodable source - treated as a render failure
                // so the caller retries at half scale (matches the PRD's
                // "retry once at half scale" contract; a smaller decode
                // target can succeed where a larger one failed to load).
                return nil
            }

            autoreleasepool {
                draw(photo: photo, cgImage: cgImage, cellRect: plan.rect, cornerRadiusFraction: cornerRadiusFraction, context: context)
            }
        }

        decorator.decorate(context: context, size: exportSize)

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Per-cell compositing

    /// Reproduces CanvasView.cellContent(...) exactly, against a CGContext
    /// instead of SwiftUI modifiers. See this file's header for the
    /// contract; fillScale/effectivePhotoSize are the SAME functions
    /// CanvasView/GestureController use (imported from GestureController.swift,
    /// not reimplemented), so the two renderers cannot drift apart.
    private func draw(photo: PhotoRef, cgImage: CGImage, cellRect: CGRect, cornerRadiusFraction: Double, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        // Clip to the cell, honoring the border's corner radius (a fraction
        // of the canvas short edge - same convention as border.inner/outer).
        let shortEdge = min(context.width, context.height)
        let radius = cornerRadiusFraction * Double(shortEdge)
        let clipPath = CGPath(roundedRect: cellRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(clipPath)
        context.clip()

        let pixelSize = CGSize(width: Double(photo.pixelWidth), height: Double(photo.pixelHeight))
        let s0 = fillScale(cellSize: cellRect.size, photoPixelSize: pixelSize, quarterTurns: photo.quarterTurns)
        let displayScale = s0 * photo.zoom
        let frameSize = CGSize(width: pixelSize.width * displayScale, height: pixelSize.height * displayScale)

        let effPx = effectivePhotoSize(pixelSize: pixelSize, quarterTurns: photo.quarterTurns)
        let effW = effPx.width * displayScale
        let effH = effPx.height * displayScale
        let innerOffsetX = cellRect.width / 2 - photo.center.x * effW
        let innerOffsetY = cellRect.height / 2 - photo.center.y * effH

        // Block's top-left = cellOrigin + (cellW/2 - cx*effW, cellH/2 - cy*effH).
        let blockOriginX = cellRect.minX + innerOffsetX
        let blockOriginY = cellRect.minY + innerOffsetY

        // Translate to the block's CENTER, then rotate/flip/draw the
        // UNROTATED frame rect centered on the origin - matching
        // CanvasView's rotationEffect -> scaleEffect(flip) -> frame(eff) ->
        // offset chain exactly.
        context.translateBy(x: blockOriginX + effW / 2, y: blockOriginY + effH / 2)
        // NOTE (y-flip caveat, verified against _review/phase4-rotated.png):
        // `makeTopLeftContext` flips the raw CGContext to a top-left,
        // Y-DOWN coordinate system matching UIKit/SwiftUI. In that space,
        // `CGContext.rotate(by:)` for a POSITIVE angle turns content
        // CLOCKWISE on screen - the same direction as SwiftUI's
        // `.rotationEffect(.degrees(90 * quarterTurns))`. No extra sign flip
        // is needed here as a result.
        context.rotate(by: CGFloat.pi / 2 * CGFloat(photo.quarterTurns))
        context.scaleBy(x: photo.flipH ? -1 : 1, y: photo.flipV ? -1 : 1)

        let drawRect = CGRect(
            x: -frameSize.width / 2, y: -frameSize.height / 2,
            width: frameSize.width, height: frameSize.height
        )
        // CGContext.draw(_:in:) draws CGImage pixel rows pre-flipped
        // relative to the (already Y-down-flipped) context set up by
        // makeTopLeftContext - confirmed empirically: without this,
        // every cell's PLACEMENT was correct but its CONTENT rendered
        // upside-down. `drawRect` is symmetric about the local origin, so
        // this extra flip only corrects pixel content, not position.
        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }

    private func cgColor(from rgba: RGBA) -> CGColor {
        CGColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    // MARK: - Context setup

    /// A plain (non-UIKit-thread-affine) CGBitmapContext, flipped once at
    /// creation to a top-left, Y-DOWN coordinate system - i.e. the same
    /// coordinate space `solve()`'s cell rects and CanvasView's SwiftUI
    /// layout both already use, so every downstream formula in `draw(...)`
    /// carries over unchanged. Deliberately NOT UIGraphicsImageRenderer:
    /// that API is documented main-thread-only, and export must run off the
    /// main thread (SaveCoordinator/EditorView) without blocking the UI.
    private func makeTopLeftContext(size: CGSize) -> CGContext? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }
}
