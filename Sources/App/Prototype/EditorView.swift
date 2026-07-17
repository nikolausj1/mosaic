// Sources/App/Prototype/EditorView.swift
// Full-screen dark chrome: a top bar (New / Cycle / Auto / Undo / Redo) and
// the canvas centered in the remaining space. `state` is built by the caller
// (PickerView's confirm flow, or ContentView's -protoLayout/-autoPick launch-
// arg fallbacks) - this view owns no document-construction logic itself.
import SwiftUI

struct EditorView: View {
    @State var state: EditorState
    var onNew: (() -> Void)?

    @AppStorage("hasSeenEditor") private var hasSeenEditor: Bool = false
    @State private var hasAppliedFirstLaunchSelection = false
    @State private var showDiscardConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(state: state, onReady: applyFirstLaunchSelectionIfNeeded)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.043, green: 0.043, blue: 0.051).ignoresSafeArea())
        .overlay(alignment: .bottom) { debugHUD }
    }

    /// Prototype-only gesture event ticker. The last few classification
    /// events, newest at the bottom. Non-interactive - touches pass through.
    private var debugHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.debugEvents, id: \.self) { event in
                Text(event)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5))
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack {
            Button("New") { showDiscardConfirm = true }
                .frame(minWidth: 44, minHeight: 44)
                .confirmationDialog("Discard current collage?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { onNew?() }
                    Button("Cancel", role: .cancel) {}
                }

            Spacer()

            Button("Cycle") { state.cycleLayout() }
                .frame(minWidth: 44, minHeight: 44)

            Button {
                state.toggleAuto()
            } label: {
                Image(systemName: "wand.and.stars")
                    .frame(width: 44, height: 44)
            }
            .disabled(state.selection == nil)
            .foregroundStyle(autoButtonColor)

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

    /// Full accent when the selected photo's crop is the cached auto-frame
    /// ROI; a muted accent otherwise (including when nothing is selected,
    /// where the button is also disabled).
    private var autoButtonColor: Color {
        guard let sel = state.selection, let photo = state.document.photos[sel], photo.isAuto else {
            return Color.mosaicAccent.opacity(0.4)
        }
        return Color.mosaicAccent
    }

    private func applyFirstLaunchSelectionIfNeeded() {
        guard !hasAppliedFirstLaunchSelection else { return }
        hasAppliedFirstLaunchSelection = true
        guard !hasSeenEditor else { return }

        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        state.selection = cells.first?.id
        hasSeenEditor = true
    }
}
