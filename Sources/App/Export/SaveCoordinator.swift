// Sources/App/Export/SaveCoordinator.swift
// Orchestrates the Save flow (PRD Screen C / "Export rule"): full-resolution
// source loading AT EXPORT TIME (the in-memory 2000px proxies EditorState
// carries are for the canvas only), the CollageRenderer CGContext pipeline,
// JPEG encoding, and the PHAssetCreationRequest write with earliest-date /
// agreeing-location metadata (S7). Never imported by Sources/Engine.
import Foundation
import UIKit
import Photos
import CoreLocation

/// Artifacts from a successful render+encode, kept around even when the
/// LATER Photos-library write step fails (e.g. permission denied) - so a
/// caller (the debug `-autoSave` hook) can still inspect exactly what got
/// minted without depending on write-permission being granted on device/sim.
struct RenderedArtifact {
    let image: UIImage
    let pixelSize: CGSize
    let jpegData: Data
    /// The metadata that WOULD be / WAS set on the asset (earliest source
    /// creation date) - computed alongside the render so the debug hook can
    /// log it regardless of the write outcome.
    let creationDate: Date?
}

struct SaveResult {
    let image: UIImage
    let pixelSize: CGSize
    let assetLocalIdentifier: String
    let jpegData: Data
    let creationDate: Date?
}

enum SaveError: Error {
    case renderFailed
    case jpegEncodingFailed
    case permissionDenied(rendered: RenderedArtifact)
    case libraryWriteFailed(reason: String, rendered: RenderedArtifact)

    /// The rendered artifact, if the failure happened AFTER a successful
    /// render (i.e. everything but the actual save to Photos happened) -
    /// nil for `.renderFailed`/`.jpegEncodingFailed`, where there is nothing
    /// to show.
    var rendered: RenderedArtifact? {
        switch self {
        case .renderFailed, .jpegEncodingFailed: return nil
        case .permissionDenied(let r): return r
        case .libraryWriteFailed(_, let r): return r
        }
    }

    /// User-facing reason text for the failure alert (PRD: "Alert with the
    /// actual reason + Retry").
    var userMessage: String {
        switch self {
        case .renderFailed:
            return "The collage couldn't be rendered. Please try again."
        case .jpegEncodingFailed:
            return "The collage couldn't be encoded for saving."
        case .permissionDenied:
            return "Mosaic needs permission to add photos to your library. Enable it in Settings, then retry."
        case .libraryWriteFailed(let reason, _):
            return "Saving to Photos failed: \(reason)"
        }
    }
}

final class SaveCoordinator {
    private let imageManager = PHImageManager.default()
    var decorator: ExportDecorator = NoOpDecorator()

    // MARK: - Full save flow

    /// Renders, encodes, and writes to Photos. `images` is EditorState's
    /// in-memory proxy dictionary - used ONLY as the fallback source for
    /// photos with an empty `assetLocalIdentifier` (the PHPicker
    /// denied-state fallback, which never produced a PHAsset).
    func save(document: Document, images: [PhotoID: UIImage], canvasSize: CGSize) async -> Result<SaveResult, SaveError> {
        let creationDate = await earliestCreationDate(for: document)

        guard case .success(let rendered) = await renderAndEncode(document: document, images: images, canvasSize: canvasSize, creationDate: creationDate) else {
            return .failure(.renderFailed)
        }

        let status = await requestAddOnlyAuthorizationIfNeeded()
        guard status == .authorized || status == .limited else {
            return .failure(.permissionDenied(rendered: rendered))
        }

        let location = await agreeingLocation(for: document)

        do {
            let assetID = try await writeToPhotos(jpegData: rendered.jpegData, creationDate: creationDate, location: location)
            return .success(SaveResult(
                image: rendered.image,
                pixelSize: rendered.pixelSize,
                assetLocalIdentifier: assetID,
                jpegData: rendered.jpegData,
                creationDate: creationDate
            ))
        } catch {
            return .failure(.libraryWriteFailed(reason: error.localizedDescription, rendered: rendered))
        }
    }

    /// Render + JPEG-encode only, with no Photos-library interaction at all.
    /// Used internally by `save`, and directly by the `-autoSave` debug hook
    /// so it can capture the export artifact even when the Photos add
    /// permission is unresolved/blocked on a simulator.
    func renderAndEncode(
        document: Document,
        images: [PhotoID: UIImage],
        canvasSize: CGSize,
        creationDate: Date? = nil
    ) async -> Result<RenderedArtifact, SaveError> {
        var renderer = CollageRenderer()
        renderer.decorator = decorator

        let outcome = await renderer.renderCollage(document: document, canvasSize: canvasSize) { [weak self] photoID, maxPixelSize in
            await self?.loadFullResolutionCGImage(photoID: photoID, document: document, images: images, maxPixelSize: maxPixelSize)
        }

        switch outcome {
        case .failure:
            return .failure(.renderFailed)
        case .success(let (image, pixelSize)):
            guard let jpegData = image.jpegData(compressionQuality: 0.95) else {
                return .failure(.jpegEncodingFailed)
            }
            return .success(RenderedArtifact(image: image, pixelSize: pixelSize, jpegData: jpegData, creationDate: creationDate))
        }
    }

    // MARK: - Full-resolution source loading (export time only)

    /// requestImageDataAndOrientation (network allowed - full originals may
    /// be iCloud-only) -> CGImageSourceCreateThumbnailAtIndex at the caller-
    /// computed `maxPixelSize` (never the full native resolution unless the
    /// cell genuinely needs it), orientation-normalized via
    /// kCGImageSourceCreateThumbnailWithTransform. For photos with an empty
    /// `assetLocalIdentifier` (PHPicker fallback - no PHAsset was ever
    /// produced), falls back to the in-memory proxy UIImage already held by
    /// EditorState.
    private func loadFullResolutionCGImage(
        photoID: PhotoID,
        document: Document,
        images: [PhotoID: UIImage],
        maxPixelSize: Int
    ) async -> CGImage? {
        guard let photo = document.photos[photoID] else { return nil }

        guard !photo.assetLocalIdentifier.isEmpty else {
            return images[photoID]?.cgImage
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photo.assetLocalIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            // Asset vanished from the library since autosave - fall back to
            // the in-memory proxy rather than failing the whole export.
            return images[photoID]?.cgImage
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
                continuation.resume(returning: cgImage)
            }
        }
    }

    // MARK: - Metadata (S7)

    /// The earliest `creationDate` among the document's source PHAssets
    /// (photos with an empty `assetLocalIdentifier` - the PHPicker fallback
    /// - are skipped, they have no PHAsset to ask).
    func earliestCreationDate(for document: Document) async -> Date? {
        let assets = fetchSourceAssets(for: document)
        return assets.compactMap(\.creationDate).min()
    }

    /// The sources' shared location, IF every non-nil location among them
    /// lies within 1km of every other - otherwise nil (PRD S7: "their
    /// location if they agree").
    func agreeingLocation(for document: Document) async -> CLLocation? {
        let assets = fetchSourceAssets(for: document)
        let locations = assets.compactMap(\.location)
        guard !locations.isEmpty else { return nil }
        guard allWithinOneKilometer(locations) else { return nil }
        return locations.first
    }

    private func fetchSourceAssets(for document: Document) -> [PHAsset] {
        let ids = document.photos.values.map(\.assetLocalIdentifier).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func allWithinOneKilometer(_ locations: [CLLocation]) -> Bool {
        guard locations.count > 1 else { return true }
        for i in 0..<locations.count {
            for j in (i + 1)..<locations.count {
                if locations[i].distance(from: locations[j]) > 1000 { return false }
            }
        }
        return true
    }

    // MARK: - Photos permission + write

    private func requestAddOnlyAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    private func writeToPhotos(jpegData: Data, creationDate: Date?, location: CLLocation?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpegData, options: nil)
                if let creationDate { request.creationDate = creationDate }
                if let location { request.location = location }
                placeholderID = request.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: placeholderID ?? "")
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "com.levelup.mosaic.save", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown Photos library error"]))
                }
            })
        }
    }
}
