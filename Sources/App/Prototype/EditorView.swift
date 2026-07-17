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
#if DEBUG
import os
#endif

#if DEBUG
private let debugExportLogger = Logger(subsystem: "com.levelup.mosaic", category: "export-debug")
#endif

struct EditorView: View {
    @State var state: EditorState
    var onNew: (() -> Void)?
    /// Phase 5: a real save handler is now wired in from ContentView (see
    /// its doc comment there) - non-nil enables the Save button's visual
    /// state, same gate Phase 4 used while this was always nil. The actual
    /// export+save mechanics live in `performSave()` below; `onSave` fires
    /// as an informational hook once a save completes successfully.
    var onSave: (() -> Void)? = nil
    /// Fires when the user taps Done on the save sheet (Screen C). Forwarded
    /// to ContentView, which dismisses back to the Picker (Phase 6 wires
    /// "last collage" archiving on top of this same hook).
    var onDone: (() -> Void)? = nil

    @AppStorage("hasSeenEditor") private var hasSeenEditor: Bool = false
    @State private var hasAppliedFirstLaunchSelection = false
    @State private var showDiscardConfirm = false
    @State private var replaceTarget: PhotoID?

    @State private var saveResult: SaveResult?
    @State private var showSaveSheet = false
    @State private var saveErrorMessage: String?
    @State private var showSaveError = false
    #if DEBUG
    @State private var didRunAutoSaveDebugHook = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                CanvasView(state: state, onReady: applyFirstLaunchSelectionIfNeeded)
                if state.isExporting {
                    // PRD: "Exporting: canvas locked." Rather than touching
                    // GestureController.swift/CanvasView.swift, an opaque-
                    // to-hit-testing (visually transparent) blocker sits on
                    // top of the whole canvas and swallows every touch for
                    // the duration of the export.
                    Color.white.opacity(0.0001)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .accessibilityHidden(true)
                }
            }
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
        .sheet(isPresented: $showSaveSheet) {
            if let saveResult {
                SaveSheetView(result: saveResult) {
                    showSaveSheet = false
                    onDone?()
                }
            }
        }
        .alert("Couldn't Save", isPresented: $showSaveError, presenting: saveErrorMessage) { _ in
            Button("Retry") { Task { await performSave() } }
            Button("Cancel", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onChange(of: state.selection) { _, newSelection in
            // Trays only ever show in the no-selection state; selecting a
            // photo swaps the whole bottom bar to the photo toolbar, so any
            // open tray is stale the instant a selection lands.
            if newSelection != nil { state.activeTray = .none }
        }
        .applyDebugUIStateLaunchArg(state: state)
    }

    // MARK: - Save (Phase 5)

    /// The whole export+save flow: locks the canvas, renders off the main
    /// thread via SaveCoordinator (CollageRenderer's CGContext pipeline),
    /// writes to Photos, then presents the save sheet (success) or an alert
    /// with the actual failure reason + Retry (failure). Re-entrant-safe:
    /// a second call while one is already in flight is a no-op.
    @MainActor
    private func performSave() async {
        guard !state.isExporting else { return }
        state.isExporting = true
        let canvasSize = state.canvasSize
        let document = state.document
        let images = state.images
        let outcome = await state.saveCoordinator.save(document: document, images: images, canvasSize: canvasSize)
        state.isExporting = false

        switch outcome {
        case .success(let result):
            saveResult = result
            showSaveSheet = true
            state.haptics.thump() // PRD's "save complete" haptic - the closest existing commit-style feedback in Haptics.swift
            onSave?()
        case .failure(let error):
            saveErrorMessage = error.userMessage
            showSaveError = true
        }
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
                Task { await performSave() }
            } label: {
                Group {
                    if state.isExporting {
                        ProgressView()
                            .tint(.black)
                            .frame(minWidth: 44, minHeight: 44)
                    } else {
                        barLabel("Save")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(onSave == nil ? Color.mosaicAccent.opacity(0.25) : Color.mosaicAccent)
                )
                .foregroundStyle(onSave == nil ? Color.white.opacity(0.4) : Color.black)
            }
            .disabled(onSave == nil || state.isExporting)
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
        defer {
            #if DEBUG
            triggerAutoSaveDebugHookIfNeeded()
            #endif
        }
        guard !hasSeenEditor else { return }

        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        state.selection = cells.first?.id
        hasSeenEditor = true
    }

    // MARK: - Debug verification hook (-autoSave launch arg, DEBUG only)

    #if DEBUG
    /// Mirrors the `-uiState` pattern: after the editor appears (canvas
    /// sized, CanvasView's onReady fired), automatically drive the same
    /// `performSave()` a real Save tap would - this exercises the whole
    /// pipeline (render -> encode -> Photos write) with no simctl taps
    /// needed. Regardless of whether the Photos-library write itself
    /// succeeds (it may be blocked by an unresolved add-only permission
    /// prompt on a fresh simulator), the rendered JPEG is always written to
    /// the app container's Documents/export-debug.jpg and logged, since
    /// `SaveError` carries the render artifact through permission/write
    /// failures (see SaveCoordinator.RenderedArtifact).
    private func triggerAutoSaveDebugHookIfNeeded() {
        guard !didRunAutoSaveDebugHook else { return }
        guard ProcessInfo.processInfo.arguments.contains("-autoSave") else { return }
        didRunAutoSaveDebugHook = true
        Task { await runAutoSaveDebugHook() }
    }

    private func runAutoSaveDebugHook() async {
        let before = DebugMemory.physFootprintBytes()
        await performSave()
        let after = DebugMemory.physFootprintBytes()

        let artifact: RenderedArtifact?
        if let saveResult {
            artifact = RenderedArtifact(image: saveResult.image, pixelSize: saveResult.pixelSize, jpegData: saveResult.jpegData, creationDate: saveResult.creationDate)
        } else {
            // Save-to-Photos failed (e.g. permission) - re-render+encode
            // directly so the debug artifact still exists. `performSave`
            // already tried once and lost the artifact behind the alert
            // path in that case (SaveError isn't threaded back to this
            // scope), so this is a deliberate second render purely for the
            // debug hook's own file/log output, never on the real Save path.
            let outcome = await state.saveCoordinator.renderAndEncode(document: state.document, images: state.images, canvasSize: state.canvasSize)
            artifact = try? outcome.get()
        }

        guard let artifact else {
            debugExportLogger.error("autoSave debug hook: render failed, nothing to write")
            return
        }

        if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let debugURL = docsURL.appendingPathComponent("export-debug.jpg")
            do {
                try artifact.jpegData.write(to: debugURL, options: .atomic)
            } catch {
                debugExportLogger.error("autoSave debug hook: failed to write export-debug.jpg: \(error.localizedDescription, privacy: .public)")
            }
        }

        let beforeMB = Double(before) / 1_048_576.0
        let afterMB = Double(after) / 1_048_576.0
        debugExportLogger.log("""
            autoSave debug: pixelSize=\(Int(artifact.pixelSize.width), privacy: .public)x\(Int(artifact.pixelSize.height), privacy: .public) \
            jpegBytes=\(artifact.jpegData.count, privacy: .public) \
            creationDate=\(String(describing: artifact.creationDate), privacy: .public) \
            memBeforeMB=\(beforeMB, privacy: .public) memAfterMB=\(afterMB, privacy: .public) peakDeltaMB=\(afterMB - beforeMB, privacy: .public)
            """)
    }
    #endif
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
