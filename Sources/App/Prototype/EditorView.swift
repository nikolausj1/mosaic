// Sources/App/Prototype/EditorView.swift
// Full-screen dark chrome: a top bar (Cycle / Undo / Redo) and the canvas
// centered in the remaining space. No Save, no other chrome - out of scope
// for this gesture-prototype phase.
import SwiftUI

struct EditorView: View {
    @State private var state: EditorState
    @AppStorage("hasSeenEditor") private var hasSeenEditor: Bool = false
    @State private var hasAppliedFirstLaunchSelection = false

    init() {
        let store = PhotoStore()
        let layoutIndex = EditorView.launchLayoutIndex()
        var doc = store.document(forLayout: layoutIndex)
        // All 4 prototype documents start at canvasRatio 1:1, so a square
        // neutral canvas here is the *exact* real fit, not an approximation -
        // reclamp is scale-invariant for a fixed aspect ratio anyway.
        doc = reclampAll(doc, canvasSize: CGSize(width: 1000, height: 1000))
        _state = State(initialValue: EditorState(document: doc, images: store.imagesByID, photoStore: store, layoutIndex: layoutIndex))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(state: state, onReady: applyFirstLaunchSelectionIfNeeded)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.043, green: 0.043, blue: 0.051).ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Button("Cycle") { state.cycleLayout() }
                .frame(minWidth: 44, minHeight: 44)

            Spacer()

            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(state.undoStack.isEmpty)

            Button {
                state.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 44, height: 44)
            }
            .disabled(state.redoStack.isEmpty)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(Color.mosaicAccent)
        .frame(height: 52)
        .background(Color.white.opacity(0.06)) // grey-box chrome placeholder - not in scope this phase
    }

    private func applyFirstLaunchSelectionIfNeeded() {
        guard !hasAppliedFirstLaunchSelection else { return }
        hasAppliedFirstLaunchSelection = true
        guard !hasSeenEditor else { return }

        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        state.selection = cells.first?.id
        hasSeenEditor = true
    }

    /// "-protoLayout N" (0...3) picks the initial document, per the Build
    /// Guide's launch-arg convention for simctl screenshot automation.
    private static func launchLayoutIndex() -> Int {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-protoLayout"),
              flagIndex + 1 < args.count,
              let value = Int(args[flagIndex + 1]) else { return 0 }
        return value
    }
}
