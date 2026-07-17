import SwiftUI
import Photos

@main
struct MosaicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Phase 6 launch routing (PRD persistence table):
///   - current.json exists  -> restore straight into the Editor.
///   - no current.json      -> Picker (with "Edit last collage" if last.json exists).
/// Confirming a selection in the Picker hands a built Document to EditorView
/// ("New collage committed" - deletes last.json, starts autosaving as
/// current). "New" in the editor discards current.json and returns here.
/// Done on the save sheet archives current.json -> last.json before
/// returning here.
struct ContentView: View {
    @State private var pickerState = PickerState()
    @State private var editorState: EditorState?
    @State private var didHandleLaunchArgs = false

    var body: some View {
        Group {
            if let editorState {
                EditorView(
                    state: editorState,
                    // New (discard confirm): delete current.json, back to Picker.
                    onNew: {
                        DocumentStore.deleteCurrent()
                        self.editorState = nil
                    },
                    // Phase 5: non-nil enables the Save button (EditorView's
                    // own performSave() owns the actual export+save
                    // mechanics); this hook is just an informational
                    // completion signal for future bookkeeping.
                    onSave: {},
                    // Screen C's Done button: archive current -> last (PRD:
                    // "Save (Done on the save sheet): current.json ->
                    // last.json; current.json deleted"), then dismiss back
                    // to the Picker, which will now offer "Edit last collage".
                    onDone: {
                        DocumentStore.archiveCurrentAsLast()
                        self.editorState = nil
                    }
                )
            } else {
                PickerView(
                    state: pickerState,
                    onConfirmed: { doc, images in
                        commitNewCollage(document: doc, images: images)
                    },
                    hasLastCollage: DocumentStore.hasLastCollage,
                    onEditLastCollage: {
                        Task { await editLastCollage() }
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard !didHandleLaunchArgs else { return }
            didHandleLaunchArgs = true
            await applyLaunchArgsIfNeeded()
        }
    }

    /// "New collage committed" (PRD: "Next from the picker"): both the real
    /// picker confirm flow and the `-autoPick` debug path funnel through
    /// here, so the deleteLast()-then-edit contract is exactly one code path.
    private func commitNewCollage(document: Document, images: [PhotoID: UIImage]) {
        DocumentStore.deleteLast()
        let state = EditorState(document: document, images: images, photoStore: PhotoStore(), layoutIndex: 0)
        // Fresh-pick arrivals open with the Layout tray up (Justin,
        // 2026-07-17): choosing the topology is the natural first move
        // after choosing photos. Restore/edit-last arrive quiet - this is
        // only for the pick flow.
        state.activeTray = .layout
        editorState = state
    }

    /// "Edit last collage" (PRD): last.json -> current.json, restored into
    /// the Editor.
    private func editLastCollage() async {
        guard let document = DocumentStore.promoteLastToCurrent() else { return }
        await restoreEditor(from: document)
    }

    /// Launch-time restore (PRD: "Launch, current.json exists -> Editor,
    /// restored exactly"). The EditorState is created immediately (with an
    /// empty `images` dict, so CanvasView shows shimmer placeholders right
    /// away - see its Phase 6 doc comment) and each photo's proxy/asset loads
    /// in afterward, filling in `images` progressively. No Vision re-run:
    /// crops/zooms/border/ratio/topology/ROIs are all already in the JSON.
    @MainActor
    private func restoreEditor(from document: Document) async {
        let state = EditorState(document: document, images: [:], photoStore: PhotoStore(), layoutIndex: 0)
        editorState = state
        await loadPhotosForRestore(into: state, document: document)
    }

    private func loadPhotosForRestore(into state: EditorState, document: Document) async {
        let library = PhotoLibraryService()
        for (id, photo) in document.photos {
            // PHPicker-fallback photo (no PHAsset was ever produced) -
            // restore its proxy JPEG sidecar written by autosave.
            guard !photo.assetLocalIdentifier.isEmpty else {
                if let image = DocumentStore.loadProxyImage(for: id) {
                    state.updateImage(id, image: image)
                } else {
                    state.unavailablePhotoIDs.insert(id)
                }
                continue
            }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [photo.assetLocalIdentifier], options: nil)
            guard let asset = fetch.firstObject else {
                // Deleted from the library since autosave (PRD: "Photo
                // unavailable").
                state.unavailablePhotoIDs.insert(id)
                continue
            }
            guard let (image, _) = await library.loadForEditing(asset: asset) else {
                state.unavailablePhotoIDs.insert(id)
                continue
            }
            state.updateImage(id, image: image)
        }
        state.refreshDerivedSwatches()
    }

    /// "-protoLayout N" bypasses the picker with a fixed bundled-photo
    /// document (screenshot automation with no photo-library dependency -
    /// PhotoStore's bundled-photo path is kept ONLY for this). "-autoPick N"
    /// auto-selects the N newest grid photos from the REAL photo library and
    /// runs the actual pick-completion flow (screenshot automation that
    /// exercises template selection + content-fit + auto-framing on real
    /// assets). "-resetPersistence" (Phase 6) clears current.json/last.json/
    /// proxies before any of the above, for clean-slate verification runs.
    /// Absent every debug arg, this is where the real launch routing lives:
    /// restore current.json if present, else fall through to the Picker
    /// (already the `else` branch above).
    private func applyLaunchArgsIfNeeded() async {
        let args = ProcessInfo.processInfo.arguments

        #if DEBUG
        if args.contains("-resetPersistence") {
            DocumentStore.resetAll()
        }
        #endif

        if let idx = args.firstIndex(of: "-protoLayout"), idx + 1 < args.count, let n = Int(args[idx + 1]) {
            let store = PhotoStore()
            var doc = store.document(forLayout: n)
            // All prototype documents start at canvasRatio 1:1, so a square
            // neutral canvas here is the exact real fit, not an approximation.
            doc = reclampAll(doc, canvasSize: CGSize(width: 1000, height: 1000))
            editorState = EditorState(document: doc, images: store.imagesByID, photoStore: store, layoutIndex: n)
            return
        }

        if let idx = args.firstIndex(of: "-autoPick"), idx + 1 < args.count, let n = Int(args[idx + 1]) {
            if let (doc, images) = await pickerState.autoPickAndConfirm(count: n) {
                commitNewCollage(document: doc, images: images)
            }
            return
        }

        if let document = DocumentStore.loadCurrent() {
            await restoreEditor(from: document)
        }
    }
}
