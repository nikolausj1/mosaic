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

    @Environment(\.scenePhase) private var scenePhase
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
    @State private var didRunSimulateUnavailableDebugHook = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                // Dead-space deselect (bug fix, Justin 2026-07-17): the
                // canvas's own gesture surface only extends 40pt beyond the
                // canvas rect, so taps in the large empty areas above/below
                // it never reached classifyTouch's .empty -> deselect path.
                // This catcher sits BEHIND CanvasView: SwiftUI hit-testing
                // gives the canvas's contentShape first claim, and anything
                // outside it lands here.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selection = nil
                        withAnimation(.easeInOut(duration: 0.2)) { state.activeTray = .none }
                    }
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
            .overlay(alignment: .bottom) {
                // Photo context strip (design revision, Justin 2026-07-17):
                // floats over the dead space between canvas and document
                // bar so selecting a photo never resizes the canvas. The
                // document bar below stays fully usable alongside it.
                if state.selection != nil {
                    HStack(spacing: 0) {
                        PhotoToolbarView(state: state, onReplace: { photoID in replaceTarget = photoID })
                        Button {
                            state.selection = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .frame(width: 40, height: 44)
                        }
                    }
                    .background(Color.mosaicSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state.selection != nil)
            EditorBottomBar(state: state, onReplace: { _ in })
        }
        .background(Color.mosaicBackground.ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .bottom) {
            if ProcessInfo.processInfo.arguments.contains("-hud") {
                debugHUD
            }
        }
        #endif
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
            // Design revision 2026-07-17: trays and the photo strip may
            // coexist (document-level trays no longer close on selection).
            // Phase 6: selecting an unavailable photo (placeholder cell tap)
            // opens the Replace sheet directly, via the same selection
            // mechanism a normal photo tap already uses - no gesture/hit-test
            // changes needed. Toolbar Replace still works as the fallback.
            if let newSelection, state.unavailablePhotoIDs.contains(newSelection) {
                replaceTarget = newSelection
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // PRD persistence contract: autosave is debounced ~0.5s, but a
            // backgrounded/inactive app must not lose that last half-second.
            if newPhase == .background || newPhase == .inactive {
                state.flushAutosaveNow()
            }
        }
        .applyDebugUIStateLaunchArg(state: state)
        .applyDebugAutoDoneLaunchArg(showSaveSheet: $showSaveSheet, onDone: onDone)
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
        // PRD: "Photo unavailable... Save is blocked" with an explanatory
        // alert. The Save button is also visually disabled in this state
        // (see `topBar`), but this guard covers the -autoSave debug hook and
        // the alert's own Retry button too.
        guard state.unavailablePhotoIDs.isEmpty else {
            saveErrorMessage = "Replace the unavailable photo before saving."
            showSaveError = true
            return
        }
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
        .offset(y: -170) // clear the bottom bar + floating photo strip
    }

    /// Header redesign, 2026-07-17: transparent bar (mosaicBackground shows
    /// through - no fill of its own) with a hairline bottom divider, replacing
    /// the old opaque mosaicSurface bar.
    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    showDiscardConfirm = true
                } label: {
                    capsText("New")
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .confirmationDialog("Discard current collage?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { onNew?() }
                    Button("Cancel", role: .cancel) {}
                }

                Spacer()

                HStack(spacing: 0) {
                    Button {
                        state.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white.opacity(state.undoStack.isEmpty ? 0.22 : 0.55))
                            .frame(width: 44, height: 44)
                    }
                    .disabled(state.undoStack.isEmpty)
                    .padding(.trailing, 4)

                    Button {
                        state.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white.opacity(state.redoStack.isEmpty ? 0.22 : 0.55))
                            .frame(width: 44, height: 44)
                    }
                    .disabled(state.redoStack.isEmpty)
                    .padding(.trailing, 12)

                    Button {
                        Task { await performSave() }
                    } label: {
                        Group {
                            if state.isExporting {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                capsText("Save")
                                    .foregroundStyle(saveEnabled ? Color.black : Color.white.opacity(0.35))
                            }
                        }
                        .frame(height: 34)
                        .padding(.horizontal, 16)
                        .background(
                            Capsule().fill(saveEnabled ? Color.mosaicAccent : Color.mosaicAccent.opacity(0.25))
                        )
                    }
                    .disabled(!saveEnabled || state.isExporting)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    /// PRD: Save is blocked while any photo is unavailable (deleted from the
    /// library since autosave) - both visually (this gates the button's
    /// tint/label color) and functionally (`performSave`'s own guard).
    private var saveEnabled: Bool {
        onSave != nil && state.unavailablePhotoIDs.isEmpty
    }

    /// The app's caps-tracked label token: `.system(size: 11, weight:
    /// .semibold)` + `.textCase(.uppercase)` + `.tracking(0.8)`, used
    /// throughout the bottom bar/trays and now the header too.
    private func capsText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private func applyFirstLaunchSelectionIfNeeded() {
        guard !hasAppliedFirstLaunchSelection else { return }
        hasAppliedFirstLaunchSelection = true
        defer {
            #if DEBUG
            triggerSimulateUnavailableDebugHookIfNeeded()
            triggerAutoSaveDebugHookIfNeeded()
            #endif
        }
        guard !hasSeenEditor else { return }

        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        state.selection = cells.first?.id
        hasSeenEditor = true
    }

    // MARK: - Debug verification hook (-simulateUnavailable launch arg, DEBUG only)

    #if DEBUG
    /// Forces the "photo unavailable" edge state for screenshots/testing
    /// without needing to actually delete an asset from the library mid-run:
    /// marks the first photo (in leaf order) unavailable after the editor
    /// appears, regardless of whether this run got here via restore, a fresh
    /// pick, or -protoLayout/-autoPick.
    private func triggerSimulateUnavailableDebugHookIfNeeded() {
        guard !didRunSimulateUnavailableDebugHook else { return }
        guard ProcessInfo.processInfo.arguments.contains("-simulateUnavailable") else { return }
        didRunSimulateUnavailableDebugHook = true
        guard let firstID = photoIDs(in: state.document.root).first else { return }
        state.unavailablePhotoIDs.insert(firstID)
    }
    #endif

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
            case "stressCrops":
                // Export-fidelity harness: non-default zoom/center/rotation/
                // flip on every photo, so a canvas screenshot and an -autoSave
                // export can be compared crop-for-crop (the default document
                // hides center/zoom bugs - everything sits at 0.5/1.0).
                var doc = state.document
                let ids = photoIDs(in: doc.root)
                let tweaks: [(zoom: Double, center: CGPoint, turns: Int, flipH: Bool)] = [
                    (1.8, CGPoint(x: 0.35, y: 0.60), 0, false),
                    (2.5, CGPoint(x: 0.70, y: 0.40), 0, false),
                    (1.0, CGPoint(x: 0.50, y: 0.50), 1, false),
                    (1.5, CGPoint(x: 0.30, y: 0.50), 0, true),
                ]
                for (i, id) in ids.enumerated() where i < tweaks.count {
                    guard var photo = doc.photos[id] else { continue }
                    photo.zoom = tweaks[i].zoom
                    photo.center = tweaks[i].center
                    photo.quarterTurns = tweaks[i].turns
                    photo.flipH = tweaks[i].flipH
                    photo.isAuto = false
                    doc.photos[id] = photo
                }
                state.document = reclampAll(doc, canvasSize: state.canvasSize)
            case "borderBlack":
                var doc = state.document
                doc.border.color = RGBA(r: 0, g: 0, b: 0, a: 1)
                doc.border.inner = 0.03
                doc.border.outer = 0.03
                state.document = reclampAll(doc, canvasSize: state.canvasSize)
                state.activeTray = .border
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

// MARK: - Debug verification hook (-autoDone launch arg)

#if DEBUG
/// The save sheet's Done button can't be automated by simctl taps (it's
/// inside a system sheet), so `-autoDone` drives it programmatically: 2s
/// after `showSaveSheet` becomes true (from either a real Save tap or the
/// `-autoSave` hook above), dismiss the sheet and fire `onDone` exactly like
/// a real Done tap - which is what runs the "current.json -> last.json"
/// archiving (see ContentView.onDone).
private struct DebugAutoDoneModifier: ViewModifier {
    @Binding var showSaveSheet: Bool
    var onDone: (() -> Void)?
    @State private var didRun = false

    func body(content: Content) -> some View {
        content.onChange(of: showSaveSheet) { _, isShown in
            guard isShown, !didRun, ProcessInfo.processInfo.arguments.contains("-autoDone") else { return }
            didRun = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showSaveSheet = false
                onDone?()
            }
        }
    }
}
#endif

private extension View {
    func applyDebugAutoDoneLaunchArg(showSaveSheet: Binding<Bool>, onDone: (() -> Void)?) -> some View {
        #if DEBUG
        modifier(DebugAutoDoneModifier(showSaveSheet: showSaveSheet, onDone: onDone))
        #else
        self
        #endif
    }
}
