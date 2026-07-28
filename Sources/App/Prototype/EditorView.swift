// Sources/App/Prototype/EditorView.swift
// Full-screen dark chrome: a top bar (a back control to Photos, and Save)
// and the canvas centered in the remaining space, with a contextual bottom
// bar below it (Phase 4: Layout/Ratio/Border tabs+trays when nothing is
// selected, single-tap photo tools when a photo is selected). `state` is
// built by the caller (PickerView's confirm flow, or ContentView's
// -protoLayout/-autoPick launch-arg fallbacks) - this view owns no
// document-construction logic itself.
import SwiftUI
import Photos
import UIKit
#if DEBUG
import os
#endif

#if DEBUG
private let debugExportLogger = Logger(subsystem: "com.levelup.mosaic", category: "export-debug")
#endif

struct EditorView: View {
    @State var state: EditorState
    var storeService: StoreService
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
    /// B32 Phase 0: the arrival sequence plays in a ContentView-owned overlay
    /// ABOVE this editor while the editor is quietly mounting underneath it.
    /// The only thing this view needs from it is "am I still hidden?" - see
    /// `triggerGhostDemoIfNeeded`, which must not start teaching gestures on
    /// a canvas nobody can see yet (and must not reshape that canvas while
    /// the sequence is morphing photos onto its cells). Nil on any path that
    /// never runs the sequence.
    var magicLayout: MagicLayoutController? = nil

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenEditor") private var hasSeenEditor: Bool = false
    @State private var hasAppliedFirstLaunchSelection = false
    @State private var replaceTarget: PhotoID?

    /// First-editor-entry teach (Justin, 2026-07-26, B27 option c; reworked
    /// from a single-screen spotlight to a live "ghost gesture demo" later
    /// the same day - see the "Ghost gesture demo" section below). Same
    /// `hasSeenCoachMarks` key as the coach marks it replaces - the Dev
    /// sheet's replay and `-resetPersistence` both key off this name, so it
    /// stays put even though nothing here is a "coach mark" anymore.
    @AppStorage("hasSeenCoachMarks") private var hasSeenCoachMarks: Bool = false
    @State private var didTriggerGhostDemo = false
    /// Overall visible/hidden for the ghost overlay (fingertip + caption) -
    /// fades in at demo start, fades out at demo end/skip.
    @State private var ghostDemoVisible = false
    /// Which live anchor (see CanvasView's CoachMarkAnchorsKey export) the
    /// ghost fingertip currently tracks. (Justin, 2026-07-27): a `.center`
    /// opening beat was added ahead of the bracket/divider phases that
    /// already existed - "having it start at the center gives the user a
    /// second to figure out whats going on" - and phase 1's bracket target
    /// moved from the bottom-right corner to the top-right one ("the upper
    /// right is more visible"); phase 1 used to track the interior corner
    /// handle before that - see `runGhostGestureDemo`'s doc comment for why
    /// that changed.
    private enum GhostDemoPhase { case center, bracket, divider }
    @State private var ghostDemoPhase: GhostDemoPhase = .center
    /// The brief scale-down "press" pulse at the start of each drag leg.
    @State private var ghostDemoPressed = false
    /// The pre-demo document, captured once at demo start so any exit path
    /// (natural finish, skip tap, or an early guard) can restore it exactly.
    /// Half the ghost fingertip's outer glow ring (54pt, see CoachMarks.swift)
    /// - the clamp margin that keeps it fully on screen at a bracket anchor.
    private let ghostFingertipRadius: CGFloat = 27
    @State private var ghostDemoSnapshot: Document?
    @State private var ghostDemoTask: Task<Void, Never>?

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
                .overlay(ghostDemoScrim)
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
                CanvasView(state: state, onReady: {
                    applyFirstLaunchSelectionIfNeeded()
                    triggerGhostDemoIfNeeded()
                })
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
                .overlay(ghostDemoScrim)
        }
        .background(Color.mosaicBackground.ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .bottom) {
            if ProcessInfo.processInfo.arguments.contains("-hud") {
                debugHUD
            }
        }
        #endif
        .overlayPreferenceValue(CoachMarkAnchorsKey.self) { anchors in
            // Ghost gesture demo (Justin, 2026-07-26, replaces the old
            // single-screen spotlight coach marks): reuses the exact same
            // CoachMarkAnchorsKey geometry CanvasView already exports for
            // the divider capsule and corner handle (see its "Coach mark
            // geometry export" section) - just to place a ghost fingertip
            // AT those live positions instead of punching scrim holes over
            // them. Because `runGhostGestureDemo` mutates `state.document`
            // directly on every animation tick, CanvasView's cells (and so
            // its anchor markers) re-render every tick too, republishing
            // this preference with the ACTUAL live corner/divider position -
            // reading `proxy[anchor]` fresh on every render of this closure
            // is what makes the fingertip track the reshaping layout with no
            // separate position state of its own to keep in sync.
            // `.ignoresSafeArea()` matches the old coach marks' contract:
            // this overlay (and its tap-anywhere-skip catcher) covers the
            // true full screen, header and bottom bar included.
            GeometryReader { proxy in
                if ghostDemoVisible {
                    let targetAnchor: Anchor<CGRect>? = {
                        switch ghostDemoPhase {
                        case .center: return anchors.center
                        case .bracket: return anchors.bracket
                        case .divider: return anchors.divider
                        }
                    }()
                    GhostGestureOverlay(
                        screenSize: proxy.size,
                        fingertipCenter: targetAnchor.map { anchor in
                            let rect = proxy[anchor]
                            // Clamped inside the screen (Justin, 2026-07-28):
                            // the canvas runs nearly edge to edge, so a
                            // bracket anchor - which sits 12pt OUTSIDE the
                            // canvas corner - puts the fingertip half off
                            // the display, which defeated the whole point of
                            // moving the demo to the more visible corner. A
                            // real finger would cover the bracket from just
                            // inside anyway.
                            let inset = ghostFingertipRadius + 6
                            return CGPoint(
                                x: min(max(rect.midX, inset), proxy.size.width - inset),
                                y: min(max(rect.midY, inset), proxy.size.height - inset)
                            )
                        },
                        isPressed: ghostDemoPressed,
                        captionText: "Watch: drag a corner to reshape, a seam to resize",
                        onSkip: skipGhostDemo
                    )
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(
            get: { replaceTarget != nil },
            set: { if !$0 { replaceTarget = nil } }
        )) {
            replaceSheet
        }
        .sheet(isPresented: $showSaveSheet) {
            if let saveResult {
                SaveSheetView(result: saveResult, onDone: {
                    showSaveSheet = false
                    onDone?()
                }, storeService: storeService)
            }
        }
        .alert("Couldn't Save", isPresented: $showSaveError, presenting: saveErrorMessage) { _ in
            Button("Retry") { Task { await performSave() } }
            Button("Cancel", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onChange(of: state.activeTray) { _, newTray in
            // Border tab assumes intent (Justin, 2026-07-26): arriving on a
            // zero-border document animates thickness up to a visible
            // starter so the sliders demonstrably control something.
            if newTray == .border {
                withAnimation(.easeInOut(duration: 0.35)) {
                    state.applyBorderStarterIfZero()
                }
            }
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
        // B8: the ONE place entitlement reaches the export pipeline - decide
        // per-save, right before rendering, so a purchase completed earlier
        // in this same session (paywall from the save sheet or Settings)
        // takes effect on the very next Save without any other plumbing.
        state.saveCoordinator.decorator = storeService.isUnlocked
            ? NoOpDecorator()
            : WatermarkDecorator(outerBorderFraction: document.border.outer)
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
            PickerView(state: PickerState(mode: .replace), storeService: storeService, onReplaceConfirmed: { image, pixelSize, asset in
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

    /// Header rework (Justin, 2026-07-26): the old New/Undo/Redo/Save row is
    /// gone. LEFT is now a plain back control - chevron + "Photos" - that
    /// calls `onNew` directly with no confirmation dialog of any kind (the
    /// other worker is changing `onNew`'s own semantics to a non-destructive
    /// "back to the picker"; this view just calls it, same as any other
    /// closure it's handed). Undo/Redo buttons are removed entirely - the
    /// undo/redo MACHINERY in EditorState is untouched, there's just no
    /// header affordance for it anymore. RIGHT is Save alone, made the
    /// header's one strong element: a full 44pt-tall accent capsule with a
    /// larger semibold label, instead of the old 34pt caps-tracked pill.
    /// Still transparent (mosaicBackground shows through) with the same
    /// hairline bottom divider from the 2026-07-17 pass.
    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    onNew?()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Photos")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(minHeight: 44, alignment: .leading)
                }

                Spacer()

                Button {
                    Task { await performSave() }
                } label: {
                    Group {
                        if state.isExporting {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text("Save")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(saveEnabled ? Color.black : Color.white.opacity(0.35))
                        }
                    }
                    .frame(height: 44)
                    .padding(.horizontal, 24)
                    .background(
                        Capsule().fill(saveEnabled ? Color.mosaicAccent : Color.mosaicAccent.opacity(0.25))
                    )
                }
                .disabled(!saveEnabled || state.isExporting)
            }
            .padding(.horizontal, 16)
            .frame(height: 60)

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

    // MARK: - Ghost gesture demo (Justin, 2026-07-26, B27 option c; reworked
    // same evening from the single-screen spotlight coach marks into a live
    // demonstration of the corner-drag and divider-drag gestures on the
    // user's own collage)

    /// Fired from the same `CanvasView.onReady` callback as B19's auto-select
    /// above, but entirely independent of it: its own `didTriggerGhostDemo`
    /// guard, the same `hasSeenCoachMarks` flag the old coach marks used,
    /// never touches `hasSeenEditor` or the cell-one selection.
    private func triggerGhostDemoIfNeeded() {
        guard !didTriggerGhostDemo else { return }
        didTriggerGhostDemo = true
        guard !hasSeenCoachMarks else { return }

        // Reduce Motion: skip the demo entirely and mark it seen - per
        // Justin's brief, "no animation is acceptable teaching cost" here;
        // there's deliberately no static fallback overlay standing in for
        // it.
        guard !UIAccessibility.isReduceMotionEnabled else {
            hasSeenCoachMarks = true
            return
        }

        // Fresh-pick arrivals land with the Layout tray already open
        // (`ContentView.commitNewCollage` sets `activeTray = .layout`
        // before this view even exists - EditorState is constructed with
        // it already set, so there's no async "tray slides up" transition
        // to wait out, just the tray's own settled presence eating extra
        // vertical space the canvas has to fit into). On top of the usual
        // ~800ms canvas-settle this gives that a little extra breathing
        // room before the demo starts manipulating the canvas right above
        // it. JUDGMENT CALL (Justin can retune): 800ms base, +400ms when
        // arriving with any tray open.
        let hasOpenTray = state.activeTray != .none
        let delayNs: UInt64 = hasOpenTray ? 1_200_000_000 : 800_000_000

        ghostDemoTask = Task {
            // B32 Phase 0: a fresh pick arrives UNDER the Magic Layout
            // overlay, which is still animating photos onto this canvas's
            // cells. Wait it out before the teach begins - otherwise the
            // demo's canvas reshape fights the morph landing on it, and the
            // caption/fingertip play out where nobody can see them.
            while magicLayout?.isActive == true {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, !hasSeenCoachMarks else { return }
            await runGhostGestureDemo()
        }
    }

    /// Focus scrim (Justin, 2026-07-27): while the demo plays, a dark scrim
    /// dims the header and bottom bar (each applies this as its own
    /// `.overlay` in `body`) so attention lands on the canvas, which stays
    /// unscrimmed - the whole point is watching the collage reshape. Purely
    /// a function of `ghostDemoVisible`, so it fades in/out for free under
    /// whatever `withAnimation` call is already flipping that flag (demo
    /// start, natural finish, or skip) - no separate animation wiring
    /// needed. `allowsHitTesting(false)` so it never competes with
    /// `GhostGestureOverlay`'s own full-screen tap-anywhere-skip catcher
    /// (published above via `.overlayPreferenceValue`, which layers on top
    /// of this entire VStack regardless of where this scrim sits in it).
    private var ghostDemoScrim: some View {
        Color.black.opacity(ghostDemoVisible ? 0.6 : 0)
            .allowsHitTesting(false)
    }

    /// Tap-anywhere-skip (GhostGestureOverlay's `onSkip`): cancels the
    /// in-flight demo task, restores the pre-demo document immediately, and
    /// marks the demo seen - exactly as final as letting it play out.
    private func skipGhostDemo() {
        ghostDemoTask?.cancel()
        ghostDemoTask = nil
        hasSeenCoachMarks = true
        withAnimation(.easeInOut(duration: 0.15)) { ghostDemoVisible = false }
        if let snapshot = ghostDemoSnapshot {
            state.document = snapshot
        }
        ghostDemoSnapshot = nil
    }

    /// The whole demo: snapshot -> center hold -> glide to the bracket ->
    /// (bracket press/drag-out/hold/drag-back) -> travel -> (divider
    /// press/drag-out/hold/drag-back) -> restore -> fade out. Bypasses
    /// `GestureController` and `EditorState.beginGesture`/`commitGesture`
    /// entirely - it mutates `state.document` (and, for the bracket phase,
    /// `state.liveCanvasSize`) directly, the same way a real gesture's
    /// PREVIEW does mid-drag (see GestureController's per-tick
    /// `state.document = doc` calls) - so there is NO undo-stack entry at
    /// any point, matching "gestures preview without pushing undo, only
    /// commit at gesture end" (this demo never calls the "commit" half at
    /// all, since it always ends by restoring the exact starting document
    /// rather than keeping a change).
    ///
    /// Opening beat (Justin, 2026-07-27): the fingertip now fades in at the
    /// canvas's dead center and holds there briefly BEFORE anything moves -
    /// "having it start at the center gives the user a second to figure out
    /// whats going on" - then glides to the bracket phase below. Previously
    /// the fingertip faded in already sitting on the bracket.
    ///
    /// Phase 1 change (Justin, 2026-07-27): this used to demo the interior
    /// CORNER handle (where two dividers cross) first. On-device, Justin
    /// reported that in his 2x2 layout that handle sits exactly at the
    /// middle intersection point - so the phase read as "the middle point
    /// moving," which he explicitly did not want, rather than the corner
    /// drag he wanted taught ("the big one - it lets the user know they can
    /// easily change the aspect ratio by freehand"). Phase 1 now instead
    /// drags a canvas composition BRACKET vertex (`HitTarget.bracket`,
    /// `bracketAnchor`) - the 44x44 zone 12pt outside each canvas corner -
    /// which reshapes the canvas's ASPECT RATIO, exactly matching what
    /// Justin asked to see. It drives the same `BracketInfo`/
    /// `applyBracketDelta` free functions GestureController's real
    /// `handleBracket` uses (see GestureController.swift's "Ratio detents
    /// (bracket drag)" / "Bracket-drag math" sections) - same
    /// shared-free-function pattern already established for the divider
    /// phase below. The TARGET CORNER moved from bottom-right to top-right
    /// the same day ("the upper right is more visible") - see `bracketDY`'s
    /// doc comment just below for the sign flip that move required. Phase 2
    /// (divider drag) is unchanged - Justin explicitly approved it ("a line
    /// divider (yes this is good)").
    ///
    /// Autosave note: `document`'s `didSet` schedules an autosave on EVERY
    /// assignment regardless of undo - that's pre-existing, unconditional
    /// behavor, true of a real drag too. During this demo's ~350ms "hold"
    /// beats (close to the 0.5s autosave debounce), it's possible for the
    /// debounce timer to fire and write the INTERMEDIATE (mid-reshape)
    /// document to disk before the drag-back leg starts. That's the one
    /// place this demo can touch disk with a non-original document - it's
    /// acceptable per Justin's brief ONLY because the final restore below
    /// always fires another autosave with the ORIGINAL document shortly
    /// after, so whatever's on disk once the app goes idle is correct.
    @MainActor
    private func runGhostGestureDemo() async {
        let snapshot = state.document
        ghostDemoSnapshot = snapshot
        defer { ghostDemoSnapshot = nil }

        let canvasSize = state.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            hasSeenCoachMarks = true
            return
        }
        let (cells, _) = solve(root: snapshot.root, canvasSize: canvasSize, border: snapshot.border)
        let gutterPts = snapshot.border.inner * min(canvasSize.width, canvasSize.height)
        // The bracket phase always has somewhere to land - the composition
        // brackets are always visible regardless of layout (even a single-
        // photo canvas has all 4) - so unlike the old corner search, there's
        // no "no draggable geometry at all" guard needed here. Only the
        // divider phase can be legitimately absent (a single-photo canvas
        // has no interior seam); it degrades gracefully by simply skipping
        // below.
        let divider = centralDivider(cells: cells, root: snapshot.root, canvasSize: canvasSize, gutterPts: gutterPts)

        let shortEdge = min(canvasSize.width, canvasSize.height)
        // Divider travel: ~18% of the canvas's short edge, within the
        // brief's "~15-20% of canvas" range (unchanged from before).
        let travel = shortEdge * 0.18
        // Bracket travel: deliberately ASYMMETRIC (not a plain diagonal at
        // 45 degrees) so the drag visibly changes the canvas's ASPECT RATIO
        // rather than just scaling it up uniformly - a real freehand
        // reshape. Magnitude is a JUDGMENT CALL (Justin can retune): the
        // dominant component (`bracketDY`) takes the canvas from its
        // starting ratio toward a taller/portrait shape (obvious against
        // the default square canvas), while `bracketDX` keeps the drag
        // genuinely diagonal rather than a pure vertical pull.
        //
        // MUCH MORE AGGRESSIVE (Justin, 2026-07-28: "really allow the user
        // to see that they can really change the entire shape of the
        // composition" - the old ~16%/~6% pair read as a subtle nudge, not a
        // reshape). Pushed the dominant axis to ~42% of the canvas short
        // edge (within the new "~35-45%" range). `bracketDX` is UNCHANGED at
        // 6%, not scaled up with it - verified empirically (not just
        // computed) with a debug build that measured the canvas's on-screen
        // bounds via the same blue bracket-corner pixel edge detection the
        // ratio-slider work used: an early pass that scaled both axes up
        // together (~14%/~42%) grew the canvas WIDER than the phone's own
        // screen at peak, clipping the bracket corners off both edges - a
        // glitchy overflow, not an impressive reshape. Keeping `bracketDX`
        // at its original, screen-safe magnitude while only pushing the
        // dominant `bracketDY` still reads as a genuinely diagonal drag (the
        // corner visibly moves up-and-right, not straight up) while the
        // canvas stays within the phone's own bounds throughout: measured
        // peak bracket bbox ~392x820pt against a 402x874pt screen. From a
        // starting ~1:1 square this peaks at a clearly recognizable tall-
        // portrait shape - `applyBracketDelta`'s preset snap (its
        // `abs(log ratio diff) < 0.035` tolerance) sits just outside this
        // delta's resulting ratio, so it settles as a crisp freehand shape
        // rather than locking to a named preset, which is fine - the point
        // is the VISIBLE change, not landing on a preset. The 120pt floor in
        // `applyBracketDelta` never engages here since this corner's "out"
        // leg only ever GROWS both dimensions.
        let bracketDX = shortEdge * 0.06
        let bracketDY = shortEdge * 0.42

        ghostDemoPhase = .center // fingertip fades in here, not on the bracket
        withAnimation(.easeInOut(duration: 0.25)) { ghostDemoVisible = true }
        // Hold at center ~0.6s total (0.25s fade-in + this) so the user has
        // a beat to register what they're looking at before anything moves.
        try? await Task.sleep(nanoseconds: 350_000_000)

        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.45)) { ghostDemoPhase = .bracket } // glide: center -> the upper-right bracket
        try? await Task.sleep(nanoseconds: 500_000_000) // let the glide read before the first press

        guard !Task.isCancelled else { return }
        await pressPulse()
        guard !Task.isCancelled else { return }
        await animateBracketDrag(corner: .topRight, canvasSize: canvasSize, dx: bracketDX, dy: -bracketDY, out: true)
        guard !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: 350_000_000) // brief hold
        guard !Task.isCancelled else { return }
        await animateBracketDrag(corner: .topRight, canvasSize: canvasSize, dx: bracketDX, dy: -bracketDY, out: false)
        // Hard safety-net snap to a bit-identical original before the next
        // phase - mirrors the old corner phase's same safety net. Also
        // clears the bracket's live-size override so `state.canvasSize`
        // falls back to `fitSize` computed from the just-restored ratio,
        // exactly like a real `endBracket`'s settle.
        state.document = snapshot
        state.liveCanvasSize = nil

        if let divider {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { ghostDemoPhase = .divider } // travel: bracket -> divider, document untouched so this is a plain position glide
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await pressPulse()
            guard !Task.isCancelled else { return }
            await animateDividerDrag(ref: divider, document: snapshot, canvasSize: canvasSize, delta: travel, out: true)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await animateDividerDrag(ref: divider, document: snapshot, canvasSize: canvasSize, delta: travel, out: false)
            state.document = snapshot
        }

        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { ghostDemoVisible = false }
        hasSeenCoachMarks = true
    }

    /// Ticks a canvas bracket drag from 0 to the full `(dx, dy)` target
    /// (`out == true`) or back from full to 0 (`out == false`) over ~1.1s at
    /// ~60fps - the SAME `BracketInfo`/`applyBracketDelta` free-function
    /// pair GestureController's real bracket drag uses (see
    /// GestureController.swift), just fed a synthetic eased time curve
    /// instead of live per-frame touch deltas, so the aspect-ratio reshape
    /// is mathematically identical to what a finger would produce. Mirrors
    /// the real `handleBracket`'s per-tick contract exactly: writes
    /// `state.document.canvasRatio` and `state.liveCanvasSize` directly, no
    /// `reclampAll` per frame (that only happens once, at a real
    /// `endBracket` - here the demo instead hard-restores the pristine
    /// snapshot once the drag-back leg finishes, see `runGhostGestureDemo`).
    /// No haptics (a silent demo), even on a preset snap -
    /// `applyBracketDelta`'s snap flag is simply discarded.
    @MainActor
    private func animateBracketDrag(corner: BracketCorner, canvasSize: CGSize, dx: CGFloat, dy: CGFloat, out: Bool) async {
        var info = BracketInfo(corner: corner, originalSize: canvasSize, snappedPresetIndex: nil)
        // Slowed slightly from the shared 1.1s (Justin, 2026-07-28): the
        // bigger reshape below needs a bit more time on screen to read as a
        // deliberate shape change rather than a snap.
        await tickAnimation(duration: 1.35) { eased in
            let t = out ? eased : (1 - eased)
            let result = applyBracketDelta(&info, translation: CGSize(width: dx * t, height: dy * t))
            state.document.canvasRatio = result.ratio
            state.liveCanvasSize = result.liveSize
        }
    }

    /// Same idea as `animateBracketDrag`, for a single divider along its own
    /// axis.
    @MainActor
    private func animateDividerDrag(ref: DividerRef, document: Document, canvasSize: CGSize, delta: CGFloat, out: Bool) async {
        var info = makeDividerInfo(ref, document: document, canvasSize: canvasSize)
        await tickAnimation(duration: 1.1) { eased in
            let t = out ? eased : (1 - eased)
            var doc = document
            if info.usableExtent > 0 { applyDividerDelta(&info, deltaPoints: delta * t, doc: &doc) }
            state.document = reclampAll(doc, canvasSize: canvasSize)
        }
    }

    /// Shared eased-time driver behind both animate* functions above: ~60
    /// steps over `duration` seconds, calling `step(easedT)` with `easedT`
    /// sweeping 0...1 through a smoothstep curve - a natural ease-in/ease-
    /// out glide, not a linear one, so the synthetic "drag" reads like a
    /// real finger's acceleration/deceleration rather than a robotic slide.
    private func tickAnimation(duration: TimeInterval, _ step: (Double) -> Void) async {
        let frameInterval = 1.0 / 60.0
        let steps = max(Int(duration / frameInterval), 1)
        for i in 0...steps {
            guard !Task.isCancelled else { return }
            let t = Double(i) / Double(steps)
            let eased = t * t * (3 - 2 * t) // smoothstep
            step(eased)
            try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
        }
    }

    /// The small scale-down-then-back pulse at the start of each drag leg,
    /// standing in for a real touch-down before the drag itself begins.
    private func pressPulse() async {
        withAnimation(.easeOut(duration: 0.12)) { ghostDemoPressed = true }
        try? await Task.sleep(nanoseconds: 160_000_000)
        withAnimation(.easeOut(duration: 0.12)) { ghostDemoPressed = false }
        try? await Task.sleep(nanoseconds: 100_000_000)
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
