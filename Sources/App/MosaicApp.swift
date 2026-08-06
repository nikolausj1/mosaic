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
///   - no current.json      -> Picker.
/// Confirming a selection in the Picker hands a built Document to EditorView
/// ("New collage committed" - archives any current.json to last.json first,
/// then starts autosaving the new document as current). Done on the save
/// sheet archives current.json -> last.json before returning here.
///
/// Nothing-is-destructive navigation (Justin, 2026-07-26): the editor's back
/// button (`onNew:`) no longer discards anything - it just returns to the
/// Picker, leaving current.json exactly as autosave last wrote it. The only
/// way current.json is ever replaced is by confirming a NEW pick, which
/// archives the old current to last first (see `commitNewCollage`) - so
/// nothing is ever silently lost, only ever superseded. The Picker itself no
/// longer offers an in-flow "Continue current collage" / "Edit last collage"
/// entry point (Justin, 2026-07-27 - Justin: "easy to recreate, not a big
/// deal"), but the persistence contract those rows used to expose is
/// unchanged: current.json still restores automatically on cold launch
/// (`applyLaunchArgsIfNeeded` below) and Done on the save sheet still
/// archives current -> last (`onDone` below) - only the picker's manual
/// re-entry points to files that already exist are gone.
struct ContentView: View {
    @State private var pickerState = PickerState()
    @State private var editorState: EditorState?
    @State private var didHandleLaunchArgs = false
    /// B8: one instance for the app's lifetime, threaded into the Picker
    /// (gear icon -> Settings) and Editor (save-sheet notice + the
    /// entitlement check `performSave()` reads) - see `StoreService.start()`.
    @State private var storeService = StoreService()

    /// B32 Phase 0 "Magic Layout" (see `Magic Layout Spec.md` and
    /// `Sources/App/MagicLayout/MagicLayout.swift`). Owned HERE, deliberately:
    /// the sequence spans the picker-to-editor handoff, and this view is the
    /// only one that outlives both sides of it. The picker has the source
    /// thumbnail frames but is torn down at handoff; the editor has the
    /// destination cell rects but does not exist until `commitNewCollage`
    /// runs. The overlay sits above both in the ZStack below and crossfades
    /// out onto the editor's first frame.
    @State private var magicLayout = MagicLayoutController()

    var body: some View {
        ZStack {
            content
            if magicLayout.isActive {
                MagicLayoutOverlay(controller: magicLayout)
            }
        }
        // The editor's canvas rect (global coords) - the morph's destination.
        // Read at this level rather than inside EditorView so it reaches the
        // overlay, which is EditorView's sibling, not its child.
        .onPreferenceChange(EditorCanvasFrameKey.self) { rect in
            magicLayout.canvasFrameChanged(rect)
        }
        .preferredColorScheme(.dark)
        .task {
            guard !didHandleLaunchArgs else { return }
            didHandleLaunchArgs = true
            // Before any document is built: clear the ratio "preference"
            // that old builds' corner-bracket drags stored by accident -
            // see this function's own comment for the story. Must run
            // ahead of `applyLaunchArgsIfNeeded` so even a restored-
            // current.json launch's NEXT pick sees clean state.
            EditorState.clearBracketRatioResidueOnce()
            await applyLaunchArgsIfNeeded()
        }
        // Independent of launch-arg handling above: entitlement should start
        // resolving immediately regardless of which routing branch wins, and
        // this task's own `updatesTask == nil` guard makes a second `.task`
        // firing (e.g. a scenePhase-driven re-render) a no-op.
        .task {
            await storeService.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let editorState {
                EditorView(
                    state: editorState,
                    storeService: storeService,
                    // Nothing-is-destructive navigation (Justin, 2026-07-26):
                    // this is just "back to photos" now, not a discard.
                    // current.json stays exactly as autosave last wrote it,
                    // even though the Picker no longer has an in-flow entry
                    // point back to it (Justin, 2026-07-27). Picking a NEW
                    // set is what actually replaces this collage (it archives
                    // current -> last first, see `commitNewCollage`); backing
                    // out here never throws anything away.
                    onNew: {
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
                    // to the Picker.
                    //
                    // Clear the picker's selection here too (Justin,
                    // 2026-08-05): Done means "that collage is finished,"
                    // so the Picker should come back empty rather than
                    // showing the just-saved photos still checked. This is
                    // deliberately NOT done in `onNew` above (the "Photos"
                    // back button) - backing out to tweak the selection is
                    // documented to retain it (see PickerView's
                    // return-to-task scroll comment). `clearSelection()`
                    // only touches `selectedAssetIDs`/thumb caches, not
                    // `loadedLibraryVersion`, so it does not force
                    // `PickerState.onAppear` to re-scan the library.
                    onDone: {
                        DocumentStore.archiveCurrentAsLast()
                        pickerState.clearSelection()
                        pickerState.clearFallbackPicks()
                        self.editorState = nil
                    },
                    // B32 Phase 0: the editor's first-entry ghost demo must
                    // not start while the arrival sequence is still playing
                    // over the top of it.
                    magicLayout: magicLayout
                )
            } else {
                PickerView(
                    state: pickerState,
                    storeService: storeService,
                    onConfirmed: { completion in
                        adoptPickCompletion(completion)
                    },
                    onPickBegan: { sources in
                        magicLayout.begin(sources: sources)
                    }
                )
            }
        }
    }

    /// The pick landed. Order matters and is the spec's: mount the editor
    /// FIRST (so its canvas publishes the destination geometry the assemble
    /// beat is about to need), THEN hand the result to the overlay, which is
    /// already on screen covering the swap.
    private func adoptPickCompletion(_ completion: PickCompletion) {
        commitNewCollage(completion: completion)
        // On the bypassed path (Reduce Motion / `-magicLayoutOff`) this mark
        // IS the whole user-visible wait - i.e. today's spinner baseline that
        // the sequence's own "overlay done" is measured against.
        magicLayout.documentReady(completion)
        // Covers the one race the sequence can't animate through: the user
        // touched to skip while the work was still running, so the overlay
        // has been showing today's plain spinner and is waiting for exactly
        // this moment to get out of the way.
        magicLayout.finishIfSkipped()
        pickerState.isMagicSequenceRunning = false
    }

    /// "New collage committed" (PRD: "Next from the picker"): both the real
    /// picker confirm flow and the `-autoPick` debug path funnel through
    /// here, so the archive-then-adopt contract is exactly one code path.
    /// Nothing-is-destructive navigation (Justin, 2026-07-26): the previous
    /// current.json (if any) is archived to last.json - not deleted - before
    /// the new document is adopted, so confirming a new pick supersedes the
    /// in-flight collage rather than discarding it.
    private func commitNewCollage(completion: PickCompletion) {
        DocumentStore.archiveCurrentAsLast()
        // Feedback capture (see Sources/App/Feedback/FeedbackCapture.swift):
        // this is the ONE moment the as-built Document exists before any
        // edit can touch it - `completion.document`/`completion.images` are
        // stashed into EditorState alongside the live copy it's about to
        // start mutating, mirroring the undo stack's own "snapshot before
        // mutation" pattern. Every other EditorState construction site
        // (restore, -protoLayout) leaves these nil - honestly, there is no
        // as-chosen moment to snapshot there.
        let state = EditorState(
            document: completion.document, images: completion.images, photoStore: PhotoStore(), layoutIndex: 0,
            beforeDocument: completion.document, beforeImages: completion.images,
            capturedTemplateIndex: completion.templateIndex, capturedDecisionCost: completion.cost
        )
        // Fresh-pick arrivals open with the Layout tray up (Justin,
        // 2026-07-17): choosing the topology is the natural first move
        // after choosing photos. Cold-launch restore (`restoreEditor` below)
        // arrives quiet - this is only for the pick flow.
        state.activeTray = .layout
        editorState = state
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
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments

        if args.contains("-resetPersistence") {
            DocumentStore.resetAll()
            // Onboarding (Justin, 2026-07-26, B27 option c): both flags ride
            // along with the same reset so automation/screenshots can
            // exercise the welcome card and coach marks from a clean slate,
            // not just a clean document store.
            UserDefaults.standard.removeObject(forKey: "hasSeenWelcome")
            UserDefaults.standard.removeObject(forKey: "hasSeenCoachMarks")
        }

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
            if await pickerState.autoPickSelect(count: n) {
                // Give the grid one beat to lay out the freshly-selected
                // cells and publish their global frames (B32's source
                // geometry). A real tap on Next never needs this - the
                // thumbnails have been on screen for as long as the user
                // spent choosing them - it exists only because this debug
                // path sets the selection and confirms in the same breath.
                // Deliberately OUTSIDE the timing window: `begin` below is
                // what starts the clock.
                try? await Task.sleep(nanoseconds: 500_000_000)
                MagicTiming.startPick()
                if pickerState.mode == .pick, magicLayout.begin(sources: pickerState.magicSources()) {
                    pickerState.isMagicSequenceRunning = true
                }
                if let completion = await pickerState.confirmSelection() {
                    adoptPickCompletion(completion)
                }
            }
            return
        }
        #endif

        if let document = DocumentStore.loadCurrent() {
            await restoreEditor(from: document)
        }
    }
}
