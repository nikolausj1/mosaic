// Tools/LayoutLab/Sources/PhotoLoading.swift
// Listing input photos and loading the same 2000px-capped, orientation-
// corrected proxy `PhotoLibraryService.loadForEditing` produces - Vision and
// the framing decision both need to see EXACTLY this image, not the original
// full-resolution file, or the harness would judge a different input than
// the app ever does.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import ImageIO

let supportedPhotoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]

/// Sequential-by-filename grouping (v1 - see README): sorted with
/// `localizedStandardCompare` (Finder-style, numeric-aware: "proto2" sorts
/// before "proto10"), then chunked into groups of `setSize`. A trailing
/// remainder of fewer than 2 photos is dropped (the Engine's own
/// `templates(for:)`/`faceAwareAssignment` precondition is 2...4) - the
/// caller is told how many photos were dropped, if any.
func listPhotoSets(in folderPath: String, setSize: Int) -> (sets: [[URL]], droppedCount: Int) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folderPath), includingPropertiesForKeys: nil) else {
        return ([], 0)
    }
    let photos = entries
        .filter { supportedPhotoExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    var sets: [[URL]] = []
    var i = 0
    while i < photos.count {
        let end = min(i + setSize, photos.count)
        let chunk = Array(photos[i..<end])
        if chunk.count >= 2 {
            sets.append(chunk)
        }
        i = end
    }
    let used = sets.reduce(0) { $0 + $1.count }
    return (sets, photos.count - used)
}

/// Mirrors `PhotoLibraryService.loadForEditing` exactly: thumbnail at max
/// pixel size 2000, `kCGImageSourceCreateThumbnailWithTransform: true` so
/// EXIF orientation is baked in (the resulting CGImage is already upright -
/// same reason `buildDocument` always uses `quarterTurns: 0`).
func loadPhotoProxy(url: URL) -> (image: CGImage, pixelSize: CGSize)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 2000,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
    return (cgImage, CGSize(width: cgImage.width, height: cgImage.height))
}
