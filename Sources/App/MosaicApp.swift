import SwiftUI

@main
struct MosaicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// App launches to PickerView (no persistence yet - Phase 6). Confirming a
/// selection there hands a built Document to EditorView. "New" in the editor
/// discards the in-memory document and returns here.
struct ContentView: View {
    @State private var pickerState = PickerState()
    @State private var editorState: EditorState?
    @State private var didHandleLaunchArgs = false

    var body: some View {
        Group {
            if let editorState {
                EditorView(
                    state: editorState,
                    onNew: { self.editorState = nil },
                    // Phase 5: non-nil enables the Save button (EditorView's
                    // own performSave() owns the actual export+save
                    // mechanics); this hook is just an informational
                    // completion signal for future bookkeeping.
                    onSave: {},
                    // Screen C's Done button: dismiss back to the Picker.
                    // Phase 6 wires "last collage" archiving on top of this
                    // same hook.
                    onDone: { self.editorState = nil }
                )
            } else {
                PickerView(state: pickerState) { doc, images in
                    editorState = EditorState(document: doc, images: images, photoStore: PhotoStore(), layoutIndex: 0)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard !didHandleLaunchArgs else { return }
            didHandleLaunchArgs = true
            await applyLaunchArgsIfNeeded()
        }
    }

    /// "-protoLayout N" bypasses the picker with a fixed bundled-photo
    /// document (screenshot automation with no photo-library dependency -
    /// PhotoStore's bundled-photo path is kept ONLY for this). "-autoPick N"
    /// auto-selects the N newest grid photos from the REAL photo library and
    /// runs the actual pick-completion flow (screenshot automation that
    /// exercises template selection + content-fit + auto-framing on real
    /// assets).
    private func applyLaunchArgsIfNeeded() async {
        let args = ProcessInfo.processInfo.arguments

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
                editorState = EditorState(document: doc, images: images, photoStore: PhotoStore(), layoutIndex: 0)
            }
        }
    }
}
