// Sources/App/Feedback/FeedbackCapture.swift
// On-device feedback capture: the owner is tuning the face-aware layout
// algorithm by making a collage, correcting it by hand, and sending both to
// the developer - today that means screenshotting before/after and hunting
// the source photos down in the camera roll separately. This file bundles
// everything the app already holds (source photos by assetLocalIdentifier,
// the as-chosen Document, the corrected Document, and whatever Vision data
// can still be recovered or cheaply recomputed) into one folder and hands it
// to the system share sheet, so it's one AirDrop gesture.
//
// This build (Mosaic Next, see project.yml's bundle id) never ships to the
// App Store, so nothing here is gated behind `#if DEBUG` - but it is
// entirely additive: it reads EditorState/Document, it never mutates them,
// and it touches no existing persistence/save/render code path.
import SwiftUI
import UIKit
import Photos
import CoreGraphics

// MARK: - Manifest + vision snapshot models (Codable, written as pretty JSON)

struct FeedbackManifest: Codable {
    struct PhotoEntry: Codable {
        var photoID: String
        var assetLocalIdentifier: String
        var sourceFileName: String?
        /// TRUE original dimensions read directly off `PHAsset.pixelWidth`/
        /// `pixelHeight` - NOT the 2000px-capped proxy `PhotoRef.pixelWidth`/
        /// `pixelHeight` actually store (see EditorState/PickerView - those
        /// fields are the editing-proxy size, capped by `loadForEditing`).
        /// The desktop harness's resolution guard needs the true source
        /// size, per the task brief - this is the one place in the whole
        /// bundle that carries it.
        var originalPixelWidth: Int?
        var originalPixelHeight: Int?
        /// False for the PHPicker-fallback path (no PHAsset ever existed -
        /// `originalPixelWidth/Height` above are the best-available proxy
        /// dimensions in that case, not a true original) and for any asset
        /// this capture couldn't fetch.
        var originalDimensionsAvailable: Bool
        /// "ok" - fetched fresh from Photos at capture time.
        /// "proxyOnly" - Photos fetch failed (deleted/iCloud-restricted) or
        ///   this photo never had a PHAsset; fell back to the in-memory
        ///   editing proxy still held by EditorState.
        /// "unavailable" - no source image could be found at all; this
        ///   photo has no file under sources/.
        var availability: String
        var unavailableReason: String?
    }
    struct Decision: Codable {
        var templateIndex: Int?
        var cost: Double?
    }
    var appVersion: String
    var appBuild: String
    var captureDate: String // ISO 8601
    /// False whenever `before.json` was NOT written from a genuine
    /// as-chosen snapshot (a restored/cold-launch session, or a debug
    /// bundled-photo path) - see `EditorState.capturedBeforeDocument`'s doc
    /// comment. This is the field that keeps this bundle honest: writing the
    /// current document into `before.json` in that case would silently read
    /// as "the algorithm agreed with the user," which the task brief calls
    /// out as worse than useless.
    var beforeAvailable: Bool
    var decision: Decision
    var photos: [PhotoEntry]
}

/// Per-photo Vision data, either carried forward or cheaply recomputed at
/// capture time (see `FeedbackCaptureService.capture`'s doc comment for
/// exactly which is which).
struct FeedbackVisionEntry: Codable {
    var photoID: String
    var assetLocalIdentifier: String
    /// Every face Vision detected, before any threshold - normalized,
    /// top-left origin (the Engine's convention, same as everywhere else in
    /// this codebase). Nil when this photo's Vision pass couldn't be run at
    /// all (no source image available in any form).
    var detectedFaceRects: [CGRect]?
    var detectedFaceConfidences: [Double]?
    /// Faces surviving `AutoFrame.swift`'s thresholds (confidence >= 0.5,
    /// pixel height >= 8% of the photo's short edge) - the same faces the
    /// layout decision and the reveal's glow beat both used.
    var survivingFaceRects: [CGRect]?
    var salientRegion: CGRect?
    /// `MagicLayout.swift`'s `mustKeepRegion` - union of surviving faces plus
    /// margin, falling back to saliency.
    var mustKeepRegion: CGRect?
    /// `MagicLayout.swift`'s `smallestSurvivingFaceHeight` - the group-photo
    /// legibility signal.
    var smallestSurvivingFaceHeight: Double?
    /// "original" - recomputed against the freshly-fetched, capped source
    ///   image (the same one written to sources/).
    /// "proxy" - recomputed against the in-memory editing proxy (the
    ///   original asset couldn't be fetched).
    /// "unavailable" - no image at all; every field above is nil.
    var recomputedFrom: String
}

// MARK: - Capture context (what EditorView hands over)

/// Everything `FeedbackCaptureService` needs, gathered from the live
/// `EditorState` at the moment the owner taps Capture. Deliberately a plain
/// value snapshot, not a reference to `EditorState` itself - the capture
/// runs on a background `Task` while the user may keep editing, and this
/// struct is what freezes "the collage on screen right now" at tap time.
struct FeedbackCaptureContext {
    var afterDocument: Document
    var afterImages: [PhotoID: UIImage]
    var beforeDocument: Document?
    var beforeImages: [PhotoID: UIImage]?
    var templateIndex: Int?
    var decisionCost: Double?
}

enum FeedbackCaptureError: Error {
    case writeFailed
}

// MARK: - Capture service

struct FeedbackCaptureService {

    /// Builds one timestamped folder under Application Support/Mosaic/
    /// Captures/ containing sources/, before.json, after.json, vision.json,
    /// manifest.json, before.png/after.png, and an optional note.txt - and
    /// returns its URL for the caller to hand to `UIActivityViewController`.
    ///
    /// VISION DATA RECOVERY (task brief: "say what you could and could not
    /// recover"): the app throws away raw Vision output the instant
    /// `autoFrame`/`chooseCanvasAndLayout` have used it (see
    /// `PickerView.buildDocument` - `visionByID` etc. are locals that never
    /// escape that function). Rather than thread that ephemeral state
    /// through the whole app just for this feature, this method RECOMPUTES
    /// it here, per photo, against the same kind of image the app itself
    /// used (the freshly re-fetched, 2000px-capped source when available,
    /// else whatever in-memory proxy is still around) - the exact same
    /// `PhotoLibraryService.visionInputs`/`thresholdedFaces`/`mustKeepRegion`/
    /// `smallestSurvivingFaceHeight` calls `buildDocument` makes. Vision's
    /// face detector is deterministic against the same pixels, so this
    /// reproduces what the app saw rather than approximating it - the one
    /// thing it can NOT reproduce is the raw pre-recompute state for a photo
    /// whose source is gone entirely (deleted, iCloud-unreachable, AND no
    /// proxy left in memory), which is recorded honestly as
    /// `recomputedFrom: "unavailable"` rather than silently omitted.
    func capture(context: FeedbackCaptureContext, note: String) async -> Result<URL, FeedbackCaptureError> {
        let root = Self.capturesDirectory.appendingPathComponent(Self.timestamp(), isDirectory: true)
        let sourcesDir = root.appendingPathComponent("sources", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed)
        }

        let beforeAvailable = context.beforeDocument != nil

        // Union of every photo referenced by EITHER document (a photo the
        // user removed after commit only exists in `before`; one added by a
        // Replace keeps the same PhotoID but a new asset).
        var idsInOrder: [PhotoID] = []
        var seen = Set<PhotoID>()
        for id in Self.orderedPhotoIDs(in: context.beforeDocument) + Self.orderedPhotoIDs(in: context.afterDocument) {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            idsInOrder.append(id)
        }

        var manifestPhotos: [FeedbackManifest.PhotoEntry] = []
        var visionEntries: [FeedbackVisionEntry] = []

        for (index, id) in idsInOrder.enumerated() {
            guard let photoRef = context.afterDocument.photos[id] ?? context.beforeDocument?.photos[id] else { continue }
            let assetID = photoRef.assetLocalIdentifier
            let fileName = String(format: "%02d.jpg", index + 1)

            var entry = FeedbackManifest.PhotoEntry(
                photoID: id.uuidString,
                assetLocalIdentifier: assetID,
                sourceFileName: nil,
                originalPixelWidth: nil,
                originalPixelHeight: nil,
                originalDimensionsAvailable: false,
                availability: "unavailable",
                unavailableReason: nil
            )

            var visionImage: CGImage?
            var visionPixelSize: CGSize?
            var recomputedFrom = "unavailable"

            if !assetID.isEmpty {
                if let fetched = await Self.fetchCappedSource(assetLocalIdentifier: assetID, longestEdge: 2000) {
                    entry.originalPixelWidth = fetched.originalPixelWidth
                    entry.originalPixelHeight = fetched.originalPixelHeight
                    entry.originalDimensionsAvailable = true
                    if let data = fetched.image.jpegData(compressionQuality: 0.9) {
                        try? data.write(to: sourcesDir.appendingPathComponent(fileName), options: .atomic)
                        entry.sourceFileName = fileName
                        entry.availability = "ok"
                    } else {
                        entry.unavailableReason = "Fetched source image but could not JPEG-encode it"
                    }
                    visionImage = fetched.image.cgImage
                    visionPixelSize = fetched.image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
                    recomputedFrom = "original"
                } else {
                    entry.unavailableReason = "Asset unreachable (deleted from the library, or iCloud-only under limited-library access)"
                    // Best-effort fallback: whichever in-memory proxy this
                    // session still holds (before-snapshot proxy preferred -
                    // it matches what before.json describes).
                    if let proxy = context.beforeImages?[id] ?? context.afterImages[id] {
                        if let data = proxy.jpegData(compressionQuality: 0.9) {
                            try? data.write(to: sourcesDir.appendingPathComponent(fileName), options: .atomic)
                            entry.sourceFileName = fileName
                            entry.availability = "proxyOnly"
                        }
                        visionImage = proxy.cgImage
                        visionPixelSize = proxy.cgImage.map { CGSize(width: $0.width, height: $0.height) }
                        recomputedFrom = "proxy"
                    }
                }
            } else {
                // PHPicker-fallback photo (denied full-library access at pick
                // time): no PHAsset ever existed, so the in-memory proxy IS
                // the only source there has ever been.
                entry.unavailableReason = "PHPicker fallback photo - no PHAsset was ever produced for this photo"
                if let proxy = context.beforeImages?[id] ?? context.afterImages[id] {
                    entry.originalPixelWidth = photoRef.pixelWidth
                    entry.originalPixelHeight = photoRef.pixelHeight
                    entry.originalDimensionsAvailable = false
                    if let data = proxy.jpegData(compressionQuality: 0.9) {
                        try? data.write(to: sourcesDir.appendingPathComponent(fileName), options: .atomic)
                        entry.sourceFileName = fileName
                        entry.availability = "proxyOnly"
                        entry.unavailableReason = nil
                    }
                    visionImage = proxy.cgImage
                    visionPixelSize = proxy.cgImage.map { CGSize(width: $0.width, height: $0.height) }
                    recomputedFrom = "proxy"
                }
            }

            manifestPhotos.append(entry)

            if let cgImage = visionImage, let pixelSize = visionPixelSize {
                let vision = await PhotoLibraryService().visionInputs(cgImage: cgImage)
                let rawFaces = vision.faces.map(\.0)
                let rawConfidences = vision.faces.map(\.1)
                let surviving = thresholdedFaces(faces: rawFaces, faceConfidences: rawConfidences, photoPixelSize: pixelSize)
                let mustKeep = mustKeepRegion(faces: rawFaces, faceConfidences: rawConfidences, salientRegion: vision.salient, photoPixelSize: pixelSize)
                let smallest = smallestSurvivingFaceHeight(faces: rawFaces, faceConfidences: rawConfidences, photoPixelSize: pixelSize)
                visionEntries.append(FeedbackVisionEntry(
                    photoID: id.uuidString, assetLocalIdentifier: assetID,
                    detectedFaceRects: rawFaces, detectedFaceConfidences: rawConfidences,
                    survivingFaceRects: surviving, salientRegion: vision.salient,
                    mustKeepRegion: mustKeep, smallestSurvivingFaceHeight: smallest,
                    recomputedFrom: recomputedFrom
                ))
            } else {
                visionEntries.append(FeedbackVisionEntry(
                    photoID: id.uuidString, assetLocalIdentifier: assetID,
                    detectedFaceRects: nil, detectedFaceConfidences: nil,
                    survivingFaceRects: nil, salientRegion: nil, mustKeepRegion: nil,
                    smallestSurvivingFaceHeight: nil, recomputedFrom: "unavailable"
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let beforeDocument = context.beforeDocument, let data = try? encoder.encode(beforeDocument) {
            try? data.write(to: root.appendingPathComponent("before.json"), options: .atomic)
        }
        if let data = try? encoder.encode(context.afterDocument) {
            try? data.write(to: root.appendingPathComponent("after.json"), options: .atomic)
        }
        if let data = try? encoder.encode(visionEntries) {
            try? data.write(to: root.appendingPathComponent("vision.json"), options: .atomic)
        }

        let manifest = FeedbackManifest(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
            captureDate: ISO8601DateFormatter().string(from: Date()),
            beforeAvailable: beforeAvailable,
            decision: FeedbackManifest.Decision(templateIndex: context.templateIndex, cost: context.decisionCost),
            photos: manifestPhotos
        )
        guard let manifestData = try? encoder.encode(manifest) else { return .failure(.writeFailed) }
        try? manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            try? trimmedNote.write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        }

        // before.png / after.png - the exact CollageRenderer path Save/the
        // eyedropper already use (`renderForSampling`), not a new one.
        if let beforeDocument = context.beforeDocument, let beforeImages = context.beforeImages,
           let image = await Self.render(document: beforeDocument, images: beforeImages) {
            try? image.pngData()?.write(to: root.appendingPathComponent("before.png"), options: .atomic)
        }
        if let image = await Self.render(document: context.afterDocument, images: context.afterImages) {
            try? image.pngData()?.write(to: root.appendingPathComponent("after.png"), options: .atomic)
        }

        return .success(root)
    }

    // MARK: - Rendering (reuses CollageRenderer.renderForSampling)

    private static func render(document: Document, images: [PhotoID: UIImage]) async -> UIImage? {
        let box = CGSize(width: 1600, height: 1600)
        let exportSize = EditorState.fitSize(ratio: document.canvasRatio.value, in: box)
        guard exportSize.width > 0, exportSize.height > 0 else { return nil }
        let provider: CollageImageProvider = { id, _ in images[id]?.cgImage }
        return await CollageRenderer().renderForSampling(document: document, exportSize: exportSize, imageProvider: provider)
    }

    // MARK: - Source fetch (capped at 2000px longest edge, true original dims)

    private struct FetchedSource {
        let image: UIImage
        let originalPixelWidth: Int
        let originalPixelHeight: Int
    }

    /// Mirrors `PhotoLibraryService.loadForEditing`/`SaveCoordinator.loadFullResolutionCGImage`:
    /// `requestImageDataAndOrientation` (network allowed - full originals may
    /// be iCloud-only) -> `CGImageSourceCreateThumbnailAtIndex` capped at
    /// `longestEdge`, orientation-normalized. `PHAsset.pixelWidth`/
    /// `pixelHeight` are read directly off the fetched asset BEFORE any
    /// downsampling - that's the "true original dimensions" the manifest
    /// needs. Returns nil (asset not found, or image data unreachable) for
    /// the caller's unavailable/degrade path - never throws, never crashes
    /// the whole capture.
    private static func fetchCappedSource(assetLocalIdentifier: String, longestEdge: Int) async -> FetchedSource? {
        guard !assetLocalIdentifier.isEmpty else { return nil }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }
        let originalWidth = asset.pixelWidth
        let originalHeight = asset.pixelHeight

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: longestEdge,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: FetchedSource(
                    image: UIImage(cgImage: cgImage),
                    originalPixelWidth: originalWidth,
                    originalPixelHeight: originalHeight
                ))
            }
        }
    }

    // MARK: - Small helpers

    private static func orderedPhotoIDs(in document: Document?) -> [PhotoID] {
        guard let document else { return [] }
        return photoIDs(in: document.root)
    }

    /// Application Support/Mosaic/Captures/ - same container and creation
    /// convention `DocumentStore` already uses for current.json/last.json/
    /// proxies, kept local to this file since nothing else needs it.
    private static var capturesDirectory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mosaic", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}

// MARK: - UI: the editor's "Capture this collage" control

/// Lives in the editor's top bar (see `EditorView.topBar`), next to Save -
/// reachable without leaving the collage, and captures exactly what's on
/// screen at tap time (`state.document`/`state.images`, plus whatever
/// before-snapshot `state` was constructed with). One tap opens a skippable
/// one-line note prompt, then runs the capture and presents the system share
/// sheet - the whole point being one AirDrop gesture, no screenshot hunting.
struct FeedbackCaptureButton: View {
    var state: EditorState

    @State private var showNotePrompt = false
    @State private var noteText = ""
    @State private var isCapturing = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var captureErrorMessage: String?
    @State private var showCaptureError = false

    var body: some View {
        Button {
            noteText = ""
            showNotePrompt = true
        } label: {
            Group {
                if isCapturing {
                    ProgressView()
                        .tint(.white.opacity(0.5))
                } else {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 36, height: 44)
        }
        .disabled(isCapturing)
        .accessibilityLabel("Capture this collage")
        .accessibilityHint("Bundles the source photos and layout for sharing with the developer")
        .alert("Capture this collage", isPresented: $showNotePrompt) {
            TextField("Add a note (optional)", text: $noteText)
            Button("Cancel", role: .cancel) {}
            Button("Capture") { runCapture(note: noteText) }
        } message: {
            Text("Bundles the source photos, the layout the app chose, your edited version, and the available Vision data - ready to share.")
        }
        .alert("Couldn't Capture", isPresented: $showCaptureError, presenting: captureErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL {
                FeedbackShareActivityView(activityItems: [shareURL])
            }
        }
    }

    private func runCapture(note: String) {
        guard !isCapturing else { return }
        isCapturing = true
        let context = FeedbackCaptureContext(
            afterDocument: state.document,
            afterImages: state.images,
            beforeDocument: state.capturedBeforeDocument,
            beforeImages: state.capturedBeforeImages,
            templateIndex: state.capturedTemplateIndex,
            decisionCost: state.capturedDecisionCost
        )
        Task {
            let result = await FeedbackCaptureService().capture(context: context, note: note)
            await MainActor.run {
                isCapturing = false
                switch result {
                case .success(let url):
                    shareURL = url
                    showShareSheet = true
                case .failure:
                    captureErrorMessage = "Something went wrong writing the capture bundle. Try again."
                    showCaptureError = true
                }
            }
        }
    }
}

/// Same `UIActivityViewController` pattern `SaveSheetView.swift` already uses
/// for sharing an exported collage - a folder URL works exactly like a file
/// URL here (AirDrop and Files both accept a directory).
private struct FeedbackShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
