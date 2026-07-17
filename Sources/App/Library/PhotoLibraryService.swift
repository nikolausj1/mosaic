// Sources/App/Library/PhotoLibraryService.swift
// Thin @Observable wrapper around PHPhotoLibrary/PHImageManager plus the
// Vision calls the picker's pick-completion flow needs. App-layer only -
// never imported by Sources/Engine.
import Foundation
import Photos
import UIKit
import Vision
import CoreGraphics

@Observable
final class PhotoLibraryService {

    struct AlbumInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let count: Int
        let collection: PHAssetCollection

        static func == (lhs: AlbumInfo, rhs: AlbumInfo) -> Bool { lhs.id == rhs.id }
    }

    private(set) var authorizationStatus: PHAuthorizationStatus
    private let imageManager = PHCachingImageManager()

    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        return status
    }

    // MARK: - Albums

    /// Recents (smartAlbumUserLibrary) + Favorites (smartAlbumFavorites) + every
    /// non-empty user album (albumRegular), in that order.
    func smartAlbums() -> [AlbumInfo] {
        var result: [AlbumInfo] = []

        func appendSmartAlbum(_ subtype: PHAssetCollectionSubtype, titleOverride: String?) {
            let fetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            fetch.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                result.append(AlbumInfo(id: collection.localIdentifier, title: titleOverride ?? collection.localizedTitle ?? "Album", count: count, collection: collection))
            }
        }

        appendSmartAlbum(.smartAlbumUserLibrary, titleOverride: "Recents")
        appendSmartAlbum(.smartAlbumFavorites, titleOverride: "Favorites")

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            result.append(AlbumInfo(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album", count: count, collection: collection))
        }

        return result
    }

    /// Assets in `album`, creationDate DESCENDING (reverse-chronological).
    func assets(in album: AlbumInfo) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(in: album.collection, options: options)
    }

    // MARK: - Thumbnails (opportunistic delivery via one shared caching manager)

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        imageManager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
    }

    func stopCaching(_ assets: [PHAsset], targetSize: CGSize) {
        imageManager.stopCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
    }

    /// `resultHandler` may be called twice: once with a degraded (fast, maybe
    /// blurry) image, then again with the final full-quality thumbnail -
    /// callers should key off `PHImageResultIsDegradedKey` to show/hide a
    /// progress overlay in between.
    @discardableResult
    func requestThumbnail(for asset: PHAsset, targetSize: CGSize, resultHandler: @escaping (UIImage?, Bool) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            resultHandler(image, degraded)
        }
    }

    func cancelThumbnailRequest(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }

    // MARK: - Loading a full-quality proxy for editing

    /// requestImageDataAndOrientation (network allowed, for iCloud-only
    /// originals) -> CGImageSourceCreateThumbnailAtIndex at max pixel size
    /// 2000, respecting EXIF orientation. Returns nil on failure (corrupt
    /// data, cancelled request, etc).
    func loadForEditing(asset: PHAsset) async -> (proxy: UIImage, pixelSize: CGSize)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2000,
                    kCGImageSourceCreateThumbnailWithTransform: true // respects orientation
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = UIImage(cgImage: cgImage)
                let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                continuation.resume(returning: (image, pixelSize))
            }
        }
    }

    // MARK: - Vision (faces + saliency), downsampled input, top-left-origin output

    /// Runs VNDetectFaceRectanglesRequest + VNGenerateAttentionBasedSaliencyImageRequest
    /// on `cgImage` (the 2000px `loadForEditing` proxy is fine as-is - already
    /// downsampled). Vision returns normalized rects with BOTTOM-LEFT origin;
    /// this converts every rect to TOP-LEFT origin (y' = 1 - y - h) before
    /// returning, per the Engine's coordinate convention.
    func visionInputs(cgImage: CGImage) async -> (faces: [(CGRect, Double)], salient: CGRect?) {
        await withCheckedContinuation { continuation in
            let faceRequest = VNDetectFaceRectanglesRequest()
            let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([faceRequest, saliencyRequest])
            } catch {
                continuation.resume(returning: ([], nil))
                return
            }

            let faces: [(CGRect, Double)] = (faceRequest.results ?? []).map { obs in
                (Self.flipToTopLeft(obs.boundingBox), Double(obs.confidence))
            }

            var salient: CGRect?
            if let observation = saliencyRequest.results?.first,
               let object = observation.salientObjects?.first {
                salient = Self.flipToTopLeft(object.boundingBox)
            }

            continuation.resume(returning: (faces, salient))
        }
    }

    /// Same as above but takes raw image data (e.g. the PHPickerViewController
    /// fallback path, which never produces a PHAsset/CGImage directly).
    func visionInputs(data: Data) async -> (faces: [(CGRect, Double)], salient: CGRect?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ([], nil)
        }
        return await visionInputs(cgImage: cgImage)
    }

    private static func flipToTopLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.minY - r.height, width: r.width, height: r.height)
    }
}
