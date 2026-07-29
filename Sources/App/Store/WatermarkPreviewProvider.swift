// Sources/App/Store/WatermarkPreviewProvider.swift
// "Make the paywall preview look real" (Justin, 2026-07-28): renders
// `WatermarkMockView`'s background from the USER'S OWN photos rather than a
// stock/gradient placeholder - "here is what YOUR collage looks like with
// the watermark" is more persuasive than any sample and sidesteps the
// licensing question a bundled stock image would raise outright. Priority
// order (spec):
//   1. The user's in-progress collage (current.json), if one exists.
//   2. Otherwise last.json (the most recently archived one).
//   3. Otherwise a small collage composed from the most recent library
//      photos - the app already has library access by the time the paywall
//      is reachable (PaywallSheet/SettingsSheet, both well past the picker).
//   4. Otherwise nil - `WatermarkMockView` keeps its existing gradient.
//
// FALLS BACK SILENTLY, NEVER BLOCKS (spec): every step below is a plain
// optional-returning function; a missing/denied/failed step just falls
// through to the next one rather than throwing or prompting. This file
// never REQUESTS Photos permission - it only reads whatever status already
// exists (Settings/the picker are what actually prompt).
//
// Never imported by Sources/Engine.
import Foundation
import UIKit
import Photos

@MainActor
enum WatermarkPreviewProvider {

    /// Memoized so the paywall AND the Settings upsell card (two independent
    /// `WatermarkMockView` instances, possibly both alive at once) share one
    /// render rather than each re-running the Photos fetch + `CollageRenderer`
    /// pass independently. Cleared only by process restart - the source
    /// material (current/last collage, recent library photos) is not
    /// expected to change meaningfully within one app session.
    private static var cachedTask: Task<UIImage?, Never>?

    static func image() async -> UIImage? {
        if let cachedTask { return await cachedTask.value }
        let task = Task<UIImage?, Never> { await Self.load() }
        cachedTask = task
        return await task.value
    }

    // MARK: - Priority chain

    private static func load() async -> UIImage? {
        if let doc = DocumentStore.loadCurrent(), let image = await render(doc) {
            return image
        }
        if let doc = DocumentStore.loadLast(), let image = await render(doc) {
            return image
        }
        if let image = await renderFromRecentLibraryPhotos() {
            return image
        }
        return nil
    }

    // MARK: - Priority 1/2: an existing document

    /// Small (not export-quality) render via the same `CollageRenderer` the
    /// real export uses - `renderForSampling` (already used by the Border
    /// tray's eyedropper) so this is pixel-faithful to what Save would
    /// actually produce, just at preview resolution. A photo whose PHAsset
    /// has since vanished from the library fails this render outright
    /// (`CollageRenderer.attemptRender` treats any missing source as a
    /// render failure); that's fine - the caller just falls through to the
    /// next priority rather than showing a hole where that photo was.
    private static func render(_ document: Document) async -> UIImage? {
        guard isPhotosAccessGranted else { return nil }
        let canvasSize = nominalCanvasSize(for: document.canvasRatio, shortEdge: previewRenderShortEdge)
        let renderer = CollageRenderer()
        let image = await renderer.renderForSampling(document: document, exportSize: canvasSize) { photoID, maxPixelSize in
            await loadCGImage(photoID: photoID, document: document, maxPixelSize: maxPixelSize)
        }
        return image
    }

    /// Mirrors `SaveCoordinator`'s full-resolution loader, but through
    /// `PHImageManager.requestImage(targetSize:)` at the small preview size
    /// instead of a full-resolution `requestImageDataAndOrientation` decode -
    /// this is illustrative chrome, not an export, so it should stay cheap.
    private static func loadCGImage(photoID: PhotoID, document: Document, maxPixelSize: Int) async -> CGImage? {
        guard let photo = document.photos[photoID] else { return nil }
        guard !photo.assetLocalIdentifier.isEmpty else {
            // PHPicker-fallback photo (no PHAsset) - the proxy sidecar
            // autosave already wrote for exactly this restore case.
            return DocumentStore.loadProxyImage(for: photoID)?.cgImage
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [photo.assetLocalIdentifier], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        return await requestImage(asset: asset, maxPixelSize: maxPixelSize)
    }

    // MARK: - Priority 3: recent library photos, composed into a throwaway document

    /// No saved collage to show - falls back to the most recent 2-4 photos
    /// in the library, run through the SAME (aspect-only, no Vision) default-
    /// template pipeline `PickerView.buildDocument` uses for its own
    /// before/after instrumentation, then rendered exactly like a real
    /// document above. Everything here (the synthesized `PhotoID`s, the
    /// `Document`) is thrown away after the one render - never persisted,
    /// never confused with a real collage.
    private static func renderFromRecentLibraryPhotos() async -> UIImage? {
        guard isPhotosAccessGranted else { return nil }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 4
        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard result.count >= 2 else { return nil }
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        var idsInOrder: [PhotoID] = []
        var pixelSizes: [PhotoID: CGSize] = [:]
        var cgImages: [PhotoID: CGImage] = [:]
        for asset in assets {
            guard let cgImage = await requestImage(asset: asset, maxPixelSize: Int(previewRenderShortEdge)) else { continue }
            let id = PhotoID()
            idsInOrder.append(id)
            pixelSizes[id] = CGSize(width: cgImage.width, height: cgImage.height)
            cgImages[id] = cgImage
        }
        guard idsInOrder.count >= 2 else { return nil }

        let orientations = idsInOrder.map { pixelSizes[$0] ?? CGSize(width: 1, height: 1) }
        let candidates = templates(for: idsInOrder)
        let templateIndex = min(defaultTemplateIndex(orientations: orientations), candidates.count - 1)
        let nominalCanvas = CGSize(width: 1000, height: 1000)
        let assigned = contentFitAssignment(
            photoSizes: pixelSizes,
            template: candidates[templateIndex],
            canvasSize: nominalCanvas,
            border: .none
        )

        var photos: [PhotoID: PhotoRef] = [:]
        for id in idsInOrder {
            guard let pixelSize = pixelSizes[id] else { continue }
            photos[id] = PhotoRef(
                assetLocalIdentifier: "",
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height),
                zoom: 1.0,
                center: CGPoint(x: 0.5, y: 0.5),
                flipH: false,
                flipV: false,
                quarterTurns: 0,
                isAuto: false,
                roi: nil
            )
        }
        var doc = Document(canvasRatio: .square, root: assigned, photos: photos, border: .none)
        doc = reclampAll(doc, canvasSize: nominalCanvas)

        let renderer = CollageRenderer()
        return await renderer.renderForSampling(
            document: doc,
            exportSize: CGSize(width: previewRenderShortEdge, height: previewRenderShortEdge)
        ) { photoID, _ in cgImages[photoID] }
    }

    // MARK: - Shared helpers

    private static var previewRenderShortEdge: CGFloat { 480 }

    /// Read-only status check - NEVER requests access. The picker (or
    /// Settings) is what actually prompts; by the time a paywall is
    /// reachable the app has either already asked, or the user has never
    /// been through the picker at all (in which case this silently declines
    /// to priority 4, the gradient).
    private static var isPhotosAccessGranted: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    private static func requestImage(asset: PHAsset, maxPixelSize: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let target = CGSize(width: max(maxPixelSize, 1), height: max(maxPixelSize, 1))
            // `.highQualityFormat` normally calls back exactly once, but
            // PhotoKit's contract doesn't strictly promise that (and the
            // callback can land off the main thread) - guard against ever
            // resuming a `CheckedContinuation` twice, and against a stray
            // degraded-only delivery leaving it unresumed forever.
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}
