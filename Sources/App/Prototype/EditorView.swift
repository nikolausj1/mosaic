// Sources/App/Prototype/EditorView.swift
// Full-screen dark chrome: a top bar (New / Undo / Redo / Save) and the
// canvas centered in the remaining space, with a contextual bottom bar
// below it (Phase 4: Layout/Ratio/Border tabs+trays when nothing is
// selected, single-tap photo tools when a photo is selected). `state` is
// built by the caller (PickerView's confirm flow, or ContentView's
// -protoLayout/-autoPick launch-arg fallbacks) - this view owns no
// document-construction logic itself.
import SwiftUI
import Photos

struct EditorView: View {
    @State var state: EditorState
    var onNew: (() -> Void)?
    /// Stub this phase - always nil, so Save renders in its disabled visual
    /// state. Phase 5 wires an actual export+save flow in here.
    var onSave: (() -> Void)? = nil

    @AppStorage("hasSeenEditor") private var hasSeenEditor: Bool = false
    @State private var hasAppliedFirstLaunchSelection = false
    @State private var showDiscardConfirm = false
    @State private var replaceTarget: PhotoID?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(state: state, onReady: applyFirstLaunchSelectionIfNeeded)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            EditorBottomBar(state: state, onReplace: { photoID in replaceTarget = photoID })
        }
        .background(Color.mosaicBackground.ignoresSafeArea())
        .overlay(alignment: .bottom) { debugHUD }
        .sheet(isPresented: Binding(
            get: { replaceTarget != nil },
            set: { if !$0 { replaceTarget = nil } }
        )) {
            replaceSheet
        }
        .onChange(of: state.selection) { _, newSelection in
            // Trays only ever show in the no-selection state; selecting a
            // photo swaps the whole bottom bar to the photo toolbar, so any
            // open tray is stale the instant a selection lands.
            if newSelection != nil { state.activeTray = .none }
        }
        .applyDebugUIStateLaunchArg(state: state)
    }

    @ViewBuilder
    private var replaceSheet: some View {
        if let photoID = replaceTarget {
            PickerView(state: PickerState(mode: .replace), onReplaceConfirmed: { image, pixelSize, asset in
                Task {
                    await state.replace(
                        photoID: photoID,
                        image: image,
                        pixelSize: pixelSize,
                        assetLocalIdentifier: asset?.localIdentifier
                    )
                    replaceTarget = nil
                }
            })
        }
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
        .offset(y: -84) // clear the bottom bar
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                showDiscardConfirm = true
            } label: {
                barLabel("New")
            }
            .confirmationDialog("Discard current collage?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { onNew?() }
                Button("Cancel", role: .cancel) {}
            }

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

            Button {
                onSave?()
            } label: {
                barLabel("Save")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(onSave == nil ? Color.mosaicAccent.opacity(0.25) : Color.mosaicAccent)
                    )
                    .foregroundStyle(onSave == nil ? Color.white.opacity(0.4) : Color.black)
            }
            .disabled(onSave == nil)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(Color.mosaicAccent)
        .frame(height: 52)
        .background(Color.mosaicSurface)
    }

    private func barLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
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

// MARK: - Dark chrome palette (PRD-locked)

extension Color {
    /// #0B0B0D
    static let mosaicBackground = Color(red: 0.043, green: 0.043, blue: 0.051)
    /// #1C1C1E
    static let mosaicSurface = Color(red: 0.110, green: 0.110, blue: 0.118)
}

// MARK: - Debug screenshot automation (-uiState launch arg)

private struct DebugUIStateModifier: ViewModifier {
    let state: EditorState
    @State private var applied = false

    func body(content: Content) -> some View {
        #if DEBUG
        content.task {
            guard !applied else { return }
            applied = true
            let args = ProcessInfo.processInfo.arguments
            guard let idx = args.firstIndex(of: "-uiState"), idx + 1 < args.count else { return }
            switch args[idx + 1] {
            case "layoutTray": state.activeTray = .layout
            case "ratioTray": state.activeTray = .ratio
            case "borderTray": state.activeTray = .border
            case "photoToolbar":
                let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
                state.selection = cells.first?.id
            case "rotated":
                // Rendering-math check: rotate the first photo 90 and pan it
                // off-center so the effective-space offset formula is
                // exercised with a non-0.5 center.
                let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
                state.selection = cells.first?.id
                state.rotate()
            default: break
            }
        }
        #else
        content
        #endif
    }
}

private extension View {
    func applyDebugUIStateLaunchArg(state: EditorState) -> some View {
        modifier(DebugUIStateModifier(state: state))
    }
}
