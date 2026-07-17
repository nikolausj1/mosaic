// Sources/App/Library/PickerView.swift
// Full-screen dark photo picker: album menu, 4-column square grid, 2-4
// unordered selection, and the pick-completion flow that builds a Document
// (template + content-fit assignment + per-photo auto-framing) ready to hand
// to EditorState.
import SwiftUI
import Photos
import PhotosUI
import UIKit

// MARK: - PickerState

/// `.pick`: the normal 2-4 multi-select flow that builds a whole new
/// Document. `.replace` (Phase 4): exactly one selection, used by the
/// editor's photo toolbar "Replace" action to swap a single existing
/// photo's asset - see `PickerState.confirmReplace()` and
/// `EditorState.replace(photoID:image:pixelSize:assetLocalIdentifier:)`.
enum PickerMode {
    case pick
    case replace
}

@Observable
@MainActor
final class PickerState {

    let library = PhotoLibraryService()
    let mode: PickerMode

    private(set) var albums: [PhotoLibraryService.AlbumInfo] = []
    private(set) var selectedAlbum: PhotoLibraryService.AlbumInfo?
    private(set) var assets: PHFetchResult<PHAsset> = PHFetchResult()

    /// Unordered - a Set would lose deterministic grid redraw order, so this
    /// stays an Array, but nothing in the UI numbers the selections.
    private(set) var selectedAssetIDs: [String] = []
    var pulseNextBadge = false

    var isLoading = false
    var loadingMessage = "Preparing…"

    /// Set only by the denied-state "Choose Photos" PHPickerViewController
    /// fallback - those results never have a backing PHAsset.
    private var fallbackPicks: [(image: UIImage, pixelSize: CGSize)] = []

    var authorizationStatus: PHAuthorizationStatus { library.authorizationStatus }
    var isLimited: Bool { authorizationStatus == .limited }
    var canConfirm: Bool {
        switch mode {
        case .pick: return selectedAssetIDs.count >= 2 || fallbackPicks.count >= 2
        case .replace: return selectedAssetIDs.count == 1 || fallbackPicks.count == 1
        }
    }
    var selectionCount: Int { max(selectedAssetIDs.count, fallbackPicks.count) }

    static let maxSelectionForPick = 4
    var effectiveSelectionLimit: Int { mode == .replace ? 1 : Self.maxSelectionForPick }

    init(mode: PickerMode = .pick) {
        self.mode = mode
    }

    // MARK: - Lifecycle

    func onAppear() async {
        library.refreshAuthorizationStatus()
        if library.authorizationStatus == .notDetermined {
            await library.requestAccess()
        }
        await reload()
    }

    func reload() async {
        guard library.authorizationStatus == .authorized || library.authorizationStatus == .limited else { return }
        let smart = library.smartAlbums()
        albums = smart
        let recents = smart.first(where: { $0.title == "Recents" })
        let target = selectedAlbum.flatMap { current in smart.first(where: { $0.id == current.id }) } ?? recents ?? smart.first
        selectedAlbum = target
        if let target {
            assets = library.assets(in: target)
        }
    }

    func selectAlbum(_ album: PhotoLibraryService.AlbumInfo) {
        selectedAlbum = album
        assets = library.assets(in: album)
    }

    // MARK: - Selection

    func isSelected(_ assetID: String) -> Bool { selectedAssetIDs.contains(assetID) }

    func toggleSelection(_ assetID: String) {
        if let idx = selectedAssetIDs.firstIndex(of: assetID) {
            selectedAssetIDs.remove(at: idx)
            return
        }
        if mode == .replace {
            // Single-select: tapping a different photo swaps the pick
            // rather than being blocked once one is already selected.
            selectedAssetIDs = [assetID]
            return
        }
        guard selectedAssetIDs.count < Self.maxSelectionForPick else {
            rejectSelection()
            return
        }
        selectedAssetIDs.append(assetID)
    }

    private func rejectSelection() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        pulseNextBadge = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            self?.pulseNextBadge = false
        }
    }

    // MARK: - PHPicker fallback (denied-state "Choose Photos")

    func addFallbackPick(image: UIImage, pixelSize: CGSize) {
        fallbackPicks.append((image, pixelSize))
    }

    func clearFallbackPicks() {
        fallbackPicks.removeAll()
    }

    // MARK: - Pick completion

    /// Builds a ready-to-edit Document from the current selection: choose an
    /// orientation-aware default template, brute-force content-fit assignment
    /// into it, solve for cell rects, then auto-frame each photo into its
    /// assigned cell. Template must be chosen BEFORE auto-framing since
    /// auto-framing needs the cell size.
    func confirmSelection() async -> (Document, [PhotoID: UIImage])? {
        isLoading = true
        loadingMessage = "Preparing…"
        defer { isLoading = false }

        if !fallbackPicks.isEmpty {
            return await buildDocument(from: fallbackPicks.map { (image: $0.image, pixelSize: $0.pixelSize, asset: nil) })
        }

        let chosen = selectedAssetIDs
        guard chosen.count >= 2 else { return nil }

        var loaded: [(image: UIImage, pixelSize: CGSize, asset: PHAsset?)] = []
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            guard chosen.contains(asset.localIdentifier) else { continue }
            guard let (proxy, pixelSize) = await library.loadForEditing(asset: asset) else { continue }
            loaded.append((proxy, pixelSize, asset))
            if loaded.count == chosen.count { break }
        }
        guard loaded.count >= 2 else { return nil }
        return await buildDocument(from: loaded)
    }

    /// Auto-selects the `count` newest grid photos and runs the same
    /// completion flow - the `-autoPick N` launch-arg path for simctl
    /// screenshot automation.
    func autoPickAndConfirm(count: Int) async -> (Document, [PhotoID: UIImage])? {
        await onAppear()
        guard assets.count > 0 else { return nil }
        let n = min(count, assets.count)
        selectedAssetIDs = (0..<n).map { assets.object(at: $0).localIdentifier }
        return await confirmSelection()
    }

    /// Phase 4 Replace flow: exactly one loaded (image, pixelSize, asset) -
    /// no Document is built here (that pipeline requires 2-4 photos for
    /// `templates(for:)`); the caller (EditorState.replace) auto-frames
    /// against the SPECIFIC cell the replaced photo already occupies.
    func confirmReplace() async -> (image: UIImage, pixelSize: CGSize, asset: PHAsset?)? {
        isLoading = true
        loadingMessage = "Preparing…"
        defer { isLoading = false }

        if let pick = fallbackPicks.first {
            return (pick.image, pick.pixelSize, nil)
        }

        guard let assetID = selectedAssetIDs.first else { return nil }
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            guard asset.localIdentifier == assetID else { continue }
            guard let (proxy, pixelSize) = await library.loadForEditing(asset: asset) else { return nil }
            return (proxy, pixelSize, asset)
        }
        return nil
    }

    private func buildDocument(from loaded: [(image: UIImage, pixelSize: CGSize, asset: PHAsset?)]) async -> (Document, [PhotoID: UIImage])? {
        loadingMessage = "Framing your photos…"

        var idsInOrder: [PhotoID] = []
        var pixelSizes: [PhotoID: CGSize] = [:]
        var images: [PhotoID: UIImage] = [:]
        var assetByID: [PhotoID: PHAsset] = [:]

        for entry in loaded {
            let id = PhotoID()
            idsInOrder.append(id)
            pixelSizes[id] = entry.pixelSize
            images[id] = entry.image
            if let asset = entry.asset { assetByID[id] = asset }
        }

        let orientations = idsInOrder.map { pixelSizes[$0] ?? CGSize(width: 1, height: 1) }
        let defaultIndex = defaultTemplateIndex(orientations: orientations)
        let candidateTemplates = templates(for: idsInOrder)
        let chosenTemplate = candidateTemplates[min(defaultIndex, candidateTemplates.count - 1)]

        let border = BorderStyle(inner: 0.01, outer: 0, linked: true, cornerRadius: 0, color: .white)
        let nominalCanvas = CGSize(width: 1000, height: 1000)

        let assigned = contentFitAssignment(photoSizes: pixelSizes, template: chosenTemplate, canvasSize: nominalCanvas, border: border)
        let (cells, _) = solve(root: assigned, canvasSize: nominalCanvas, border: border)
        let cellRectByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })

        var photos: [PhotoID: PhotoRef] = [:]
        for id in idsInOrder {
            guard let pixelSize = pixelSizes[id] else { continue }
            let cellRect = cellRectByID[id] ?? CGRect(origin: .zero, size: nominalCanvas)

            var roi: ROI?
            if let cgImage = images[id]?.cgImage {
                let vision = await library.visionInputs(cgImage: cgImage)
                let input = AutoFrameInput(
                    faces: vision.faces.map(\.0),
                    faceConfidences: vision.faces.map(\.1),
                    salientRegion: vision.salient,
                    photoPixelSize: pixelSize,
                    cellSize: cellRect.size
                )
                roi = autoFrame(input)
            }

            photos[id] = PhotoRef(
                assetLocalIdentifier: assetByID[id]?.localIdentifier ?? "",
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height),
                zoom: roi?.zoom ?? 1.0,
                center: roi?.center ?? CGPoint(x: 0.5, y: 0.5),
                flipH: false,
                flipV: false,
                quarterTurns: 0,
                isAuto: roi != nil,
                roi: roi
            )
        }

        var doc = Document(canvasRatio: .square, root: assigned, photos: photos, border: border)
        doc = reclampAll(doc, canvasSize: nominalCanvas)
        return (doc, images)
    }
}

// MARK: - PickerView

struct PickerView: View {
    @State var state: PickerState
    /// `.pick` mode's completion: a whole new Document + its images.
    var onConfirmed: (Document, [PhotoID: UIImage]) -> Void = { _, _ in }
    /// `.replace` mode's completion (Phase 4): the single freshly-loaded
    /// asset, handed to `EditorState.replace(photoID:image:pixelSize:...)`.
    var onReplaceConfirmed: ((UIImage, CGSize, PHAsset?) -> Void)? = nil
    /// Phase 6 persistence: whether `last.json` exists - shows the "Edit
    /// last collage" entry point below the header when true. Left `false`
    /// (the default) for the `.replace`-mode picker EditorView presents as a
    /// sheet, which never wants this.
    var hasLastCollage: Bool = false
    /// Tapping "Edit last collage" - the caller (ContentView) promotes
    /// last.json to current.json and restores it into the editor.
    var onEditLastCollage: (() -> Void)? = nil

    @State private var showAlbumMenu = false
    @State private var showFallbackPicker = false

    private let backgroundColor = Color(red: 0.043, green: 0.043, blue: 0.051)

    var body: some View {
        VStack(spacing: 0) {
            if state.mode == .pick {
                masthead
            }
            header
            // Shown regardless of photo-library authorization state (unlike
            // the grid/denied/loading `content` below): resuming a
            // previously-saved document never needs a NEW pick, so this
            // shouldn't be gated behind permission resolution - a user who
            // hasn't granted (or has denied) photo access can still get back
            // into their last collage.
            if hasLastCollage, state.mode == .pick {
                editLastCollageBanner
            }
            content
        }
        .background(backgroundColor.ignoresSafeArea())
        .foregroundStyle(.white)
        .task { await state.onAppear() }
        .sheet(isPresented: $showFallbackPicker) {
            SystemPhotoPicker(selectionLimit: state.effectiveSelectionLimit) { picks in
                for pick in picks { state.addFallbackPick(image: pick.0, pixelSize: pick.1) }
                Task { await confirmAndDeliver() }
            }
        }
        .overlay {
            if state.isLoading {
                loadingOverlay
            }
        }
    }

    private func confirmAndDeliver() async {
        switch state.mode {
        case .pick:
            if let (doc, images) = await state.confirmSelection() {
                onConfirmed(doc, images)
            }
        case .replace:
            if let (image, pixelSize, asset) = await state.confirmReplace() {
                onReplaceConfirmed?(image, pixelSize, asset)
            }
        }
    }

    // MARK: Masthead (branding + instruction, Justin 2026-07-17)

    /// Reserved brand space on Screen A's fresh/new state: the wordmark and
    /// a single instruction line. Deliberately quiet - copy, not a tutorial
    /// (the PRD's no-tutorials rule stands; the gesture grammar still
    /// teaches itself in the editor).
    private var masthead: some View {
        VStack(spacing: 6) {
            Text("MOSAIC")
                .font(.system(size: 22, weight: .bold))
                .tracking(6)
                .foregroundStyle(Color.mosaicAccent)
            Text("Choose 2-4 photos below")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Menu {
                ForEach(state.albums) { album in
                    Button {
                        state.selectAlbum(album)
                    } label: {
                        Label("\(album.title) (\(album.count))", systemImage: state.selectedAlbum?.id == album.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(state.selectedAlbum?.title ?? "Recents")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(.white)
            }

            Spacer()

            Button {
                Task { await confirmAndDeliver() }
            } label: {
                Text(state.mode == .replace ? "Replace" : "Next (\(state.selectionCount))")
                    .font(.headline)
            }
            .disabled(!state.canConfirm)
            .foregroundStyle(state.canConfirm ? Color.mosaicAccent : Color.white.opacity(0.3))
            .scaleEffect(state.pulseNextBadge ? 1.15 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: state.pulseNextBadge)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.white.opacity(0.06))
    }

    // MARK: Content per permission state

    @ViewBuilder
    private var content: some View {
        switch state.authorizationStatus {
        case .authorized, .limited:
            VStack(spacing: 0) {
                if state.isLimited {
                    limitedBanner
                }
                grid
            }
        case .denied, .restricted:
            deniedState
        case .notDetermined:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        @unknown default:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Phase 6 persistence contract: shown whenever `last.json` exists
    /// (Launch-with-no-current.json and New-collage-discard both route here
    /// with it available). Tapping it promotes last -> current and restores
    /// straight into the editor - the picker never re-shows the old photos.
    private var editLastCollageBanner: some View {
        Button {
            onEditLastCollage?()
        } label: {
            HStack {
                Image(systemName: "arrow.uturn.backward.circle")
                Text("Edit last collage")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .padding(12)
            .foregroundStyle(Color.mosaicAccent)
            .background(Color.white.opacity(0.06))
        }
    }

    private var limitedBanner: some View {
        Button {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: UIApplication.shared.topMostViewController ?? UIViewController())
        } label: {
            HStack {
                Image(systemName: "photo.badge.plus")
                Text("Allow access to more photos")
                Spacer()
            }
            .padding(10)
            .foregroundStyle(Color.mosaicAccent)
            .background(Color.white.opacity(0.08))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                ForEach(0..<state.assets.count, id: \.self) { index in
                    let asset = state.assets.object(at: index)
                    GridThumbnail(
                        asset: asset,
                        library: state.library,
                        isSelected: state.isSelected(asset.localIdentifier),
                        pulse: state.pulseNextBadge
                    )
                    .onTapGesture {
                        state.toggleSelection(asset.localIdentifier)
                    }
                }
            }
        }
        .scrollIndicators(.visible)
        // Deviation: a custom fast-scroll scrubber is Phase 4 polish; the
        // system scroll indicator is the accepted Phase 3 stand-in.
    }

    private var deniedState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.5))
            Text("Mosaic needs access to your photos")
                .font(.headline)
            Text("Grant photo access in Settings, or choose photos individually below.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.mosaicAccent)

            Button {
                showFallbackPicker = true
            } label: {
                Text("Choose Photos")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.bordered)
            .tint(Color.mosaicAccent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(state.loadingMessage)
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Grid thumbnail cell

private struct GridThumbnail: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    let isSelected: Bool
    let pulse: Bool

    @State private var image: UIImage?
    @State private var isDegraded = true
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.05)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                }
                if isDegraded && image != nil {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .overlay {
                if isSelected {
                    Rectangle()
                        .strokeBorder(Color.mosaicAccent, lineWidth: 2.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    ZStack {
                        Circle().fill(Color.mosaicAccent)
                        Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                    .padding(4)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                }
            }
            .onAppear {
                requestID = library.requestThumbnail(for: asset, targetSize: CGSize(width: geo.size.width * 3, height: geo.size.width * 3)) { img, degraded in
                    image = img
                    isDegraded = degraded
                }
            }
            .onDisappear {
                if let requestID { library.cancelThumbnailRequest(requestID) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - PHPickerViewController fallback (denied-state "Choose Photos")

private struct SystemPhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int = PickerState.maxSelectionForPick
    var onComplete: ([(UIImage, CGSize)]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([(UIImage, CGSize)]) -> Void
        init(onComplete: @escaping ([(UIImage, CGSize)]) -> Void) { self.onComplete = onComplete }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let providers = results.map(\.itemProvider)
            var loaded: [(UIImage, CGSize)] = []
            let group = DispatchGroup()
            for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage else { return }
                    let pixelSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? image.size
                    loaded.append((image, pixelSize))
                }
            }
            group.notify(queue: .main) { [onComplete] in
                onComplete(loaded)
            }
        }
    }
}

private extension UIApplication {
    var topMostViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
    }
}
