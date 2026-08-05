// Sources/App/Export/SaveCoordinator.swift
// Orchestrates the Save flow (PRD Screen C / "Export rule"): full-resolution
// source loading AT EXPORT TIME (the in-memory 2000px proxies EditorState
// carries are for the canvas only), the CollageRenderer CGContext pipeline,
// JPEG+EXIF encoding, and the PHAssetCreationRequest write (S7). One image,
// two dates: the PHAsset's own `creationDate` is EXPORT TIME (so the collage
// sorts to the top of the library / Share Sheet), while the earliest SOURCE
// photo's date and the agreeing location are embedded IN the JPEG's own
// EXIF/TIFF/GPS blocks (so provenance survives AirDrop/export/upload) and
// ALSO set as the asset's `location` (so it files under the right Place in
// Photos). Never imported by Sources/Engine.
import Foundation
import UIKit
import Photos
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

/// Artifacts from a successful render+encode, kept around even when the
/// LATER Photos-library write step fails (e.g. permission denied) - so a
/// caller (the debug `-autoSave` hook) can still inspect exactly what got
/// minted without depending on write-permission being granted on device/sim.
struct RenderedArtifact {
    let image: UIImage
    let pixelSize: CGSize
    let jpegData: Data
    /// The earliest SOURCE photo's creation date - embedded into `jpegData`'s
    /// own EXIF (DateTimeOriginal/TIFF DateTime), NOT set as the PHAsset's
    /// `creationDate` (which is export time instead, see `writeToPhotos`).
    /// Computed alongside the render so the debug hook can log/verify it
    /// regardless of the Photos-library write outcome.
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
        // Both computed up front (not just creationDate) because the
        // earliest-source-date and agreeing-location now need to be baked
        // into the JPEG's EXIF at ENCODE time, not just applied to the
        // PHAsset after the fact - see renderAndEncode below.
        let creationDate = await earliestCreationDate(for: document)
        let location = await agreeingLocation(for: document)

        guard case .success(let rendered) = await renderAndEncode(document: document, images: images, canvasSize: canvasSize, creationDate: creationDate, location: location) else {
            return .failure(.renderFailed)
        }

        let status = await requestAddOnlyAuthorizationIfNeeded()
        guard status == .authorized || status == .limited else {
            return .failure(.permissionDenied(rendered: rendered))
        }

        do {
            // `request.location` still gets the agreeing source location (so
            // the asset files under the right Place in Photos), but
            // `request.creationDate` is deliberately NOT the source date
            // anymore - see writeToPhotos.
            let assetID = try await writeToPhotos(jpegData: rendered.jpegData, location: location)
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
        creationDate: Date? = nil,
        location: CLLocation? = nil
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
            // EXIF DateTimeOriginal/TIFF DateTime = earliest SOURCE photo
            // date, GPS = agreeing source location - embedded IN the JPEG
            // bytes so the provenance survives AirDrop/export/upload, not
            // just the PHAsset's own attributes (which Messages/Share Sheet
            // recipients never see). Same 0.95 quality the old
            // `image.jpegData(compressionQuality:)` call used.
            guard let jpegData = encodeJPEG(image: image, sourceDate: creationDate, location: location, quality: 0.95) else {
                return .failure(.jpegEncodingFailed)
            }
            return .success(RenderedArtifact(image: image, pixelSize: pixelSize, jpegData: jpegData, creationDate: creationDate))
        }
    }

    // MARK: - JPEG + EXIF encoding

    /// Re-encodes `image` as JPEG via `CGImageDestination` (rather than
    /// `UIImage.jpegData(compressionQuality:)`, which writes no metadata at
    /// all) so `sourceDate`/`location` land in the file's own EXIF/TIFF/GPS
    /// blocks. `image.cgImage` is safe to use directly with no orientation
    /// correction: CollageRenderer always produces `UIImage(cgImage:)` with
    /// no explicit orientation, i.e. `.up` (see CollageRenderer.attemptRender).
    private func encodeJPEG(image: UIImage, sourceDate: Date?, location: CLLocation?, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]

        if let sourceDate {
            // EXIF/TIFF date strings are "yyyy:MM:dd HH:mm:ss" (colons, not
            // hyphens, in the date part) - a POSIX locale keeps the
            // formatter from picking up the device's calendar/number
            // conventions. Formatted in the device's current time zone:
            // PHAsset.creationDate is an absolute instant with no separately
            // recoverable "photo's own" time zone via this API, so local-now
            // is the closest available proxy to "local time where the photo
            // was taken" - flagged as a judgment call.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let dateString = formatter.string(from: sourceDate)

            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateString,
                kCGImagePropertyExifDateTimeDigitized: dateString
            ]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFDateTime: dateString
            ]
        }

        if let location {
            let coordinate = location.coordinate
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(coordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: coordinate.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(coordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: coordinate.longitude >= 0 ? "E" : "W"
            ]
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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

    private func writeToPhotos(jpegData: Data, location: CLLocation?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpegData, options: nil)
                // Export time, NOT the source photos' earliest date - so the
                // new collage sorts to the TOP of the library and Photos /
                // the Share Sheet offer it as the most recent item. The
                // source date lives in the JPEG's own EXIF DateTimeOriginal
                // instead (see encodeJPEG above), which is what the
                // App Store description's provenance claim is actually
                // about.
                request.creationDate = Date()
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
