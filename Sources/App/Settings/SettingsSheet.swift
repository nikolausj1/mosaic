// Sources/App/Settings/SettingsSheet.swift
// B28's reserved settings ingress: a gear icon in the Picker header (Screen
// A) opens this. v1 has nothing to configure by design - this sheet exists
// only because B8's purchase (+ its restore) needed somewhere to live, so
// it stays deliberately tiny rather than growing into a general prefs
// screen.
//
// Dev Tools folded in here (Justin, 2026-07-27): the picker's gear used to
// open this AND a separate ellipsis-icon `DevSheet` side by side - now the
// gear alone opens both jobs, with the dev rows below in their own Section
// so they read as a distinct, lower-trust group rather than blending into
// the purchase rows above. `DevSheet.swift` is deleted; this file is now the
// only thing presenting these two actions. Ships in Release FOR NOW - Justin
// wants to replay the first-run experience and A/B test it on his own phone
// without a rebuild each time. The lead owns adding a pre-submission removal
// gate (`#if DEBUG`) before this ever reaches the App Store.
import SwiftUI

struct SettingsSheet: View {
    var storeService: StoreService
    /// Dev Tools "Replay first-run experience" (formerly `DevSheet`'s row):
    /// resets `hasSeenWelcome` (and the current process's launch-animation
    /// guard) and re-stages the welcome choreography from scratch - see
    /// `PickerView.replayFirstRunExperience()`, which still owns the actual
    /// mechanics since this sheet is presented FROM `PickerView` and has no
    /// reason to duplicate that state. That effect is visible immediately,
    /// no relaunch required, which is why this row's footer copy below is
    /// careful to only claim "next launch" for the pieces that actually need
    /// one.
    var onReplayFirstRun: () -> Void
    /// `DocumentStore.resetAll()` - wipes current.json, last.json, and any
    /// PHPicker-fallback proxy JPEGs.
    var onClearCollages: () -> Void
    var onDismiss: () -> Void

    @State private var showPaywall = false
    @State private var showClearConfirm = false
    /// B32 Phase 3 rationing: mirrors `MagicRevealPreference.current` in
    /// plain View `@State` so the Picker below re-renders on selection - the
    /// UserDefaults key it syncs to (via `onChange`) is the actual source of
    /// truth `MagicLayoutController.begin()` reads, exactly as `@AppStorage`
    /// would give a live-bound control, but without composing that property
    /// wrapper onto an `@Observable` class (see the reasoning on
    /// `MagicRevealPreference` itself).
    @State private var revealPreference: MagicRevealPreference = MagicRevealPreference.current

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if storeService.isUnlocked {
                        watermarkRemovedRow
                    } else {
                        watermarkUpsellCard
                    }
                }
                .listRowBackground(Color.mosaicSurface)

                // B32 Phase 3 (Justin, 2026-07-28): the reveal's one Settings
                // control, its own Section so it reads as a distinct
                // preference rather than blending into the purchase rows
                // above or the lower-trust Dev Tools group below.
                Section {
                    Picker(selection: $revealPreference) {
                        ForEach(MagicRevealPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    } label: {
                        Text("Reveal animation")
                            .foregroundStyle(.white)
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.6))
                } footer: {
                    Text("Plays when a new collage is created: photos fly in, face detection lights up, and the chosen layout assembles. \"First time only\" shows it once, ever. Off automatically when Reduce Motion is on, regardless of this setting.")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.mosaicSurface)
                .onChange(of: revealPreference) { _, newValue in
                    MagicRevealPreference.current = newValue
                }

                // Dev Tools group (Justin, 2026-07-27, moved from the deleted
                // `DevSheet.swift`) - a visually separate Section below the
                // purchase rows above, same reasoning `DevSheet` had for
                // keeping these apart from everything else.
                Section {
                    Button {
                        onReplayFirstRun()
                    } label: {
                        HStack {
                            Text("Replay first-run experience")
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }

                    Button {
                        showClearConfirm = true
                    } label: {
                        Text("Clear collages (current + last)")
                            .foregroundStyle(.red.opacity(0.85))
                    }
                } footer: {
                    // Coach marks (`hasSeenCoachMarks`) and the editor's
                    // auto-selected first cell (`hasSeenEditor`) live in
                    // EditorView.swift - this replay resets their
                    // UserDefaults keys but can't re-stage an Editor that
                    // isn't on screen, so those two genuinely need the next
                    // Editor entry.
                    Text("Replay takes effect immediately for the welcome screen above. Coach marks and the editor's first-cell hint replay the next time you open the editor.")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.mosaicSurface)

                Section {
                    HStack {
                        Text("Version")
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(appVersionString)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .listRowBackground(Color.mosaicSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.mosaicBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .confirmationDialog(
                "Clear current and last collage?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Collages", role: .destructive) {
                    onClearCollages()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallSheet(storeService: storeService)
        }
        // Loads the product ahead of the paywall sheet (Justin, 2026-07-28)
        // so `watermarkUpsellCard`'s button can show the real price - e.g.
        // "Unlock - $2.99" - the instant this sheet appears, not just after
        // the paywall itself has had a chance to load it. Harmless to call
        // again here even though `StoreService.start()` already loads it at
        // app launch: `loadProduct()` is a no-op once `product` is set.
        .task { await storeService.loadProduct() }
    }

    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    // MARK: - Watermark removal (Justin, 2026-07-28: upsell card replaces
    // the old plain "Remove Watermark" row)

    /// Already purchased: collapses to a quiet confirmation, never a sales
    /// pitch to someone who's already paid.
    private var watermarkRemovedRow: some View {
        Label("Watermark removed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.white.opacity(0.7))
    }

    /// Not yet purchased: a small marketing card - the shared watermark mock
    /// (see `WatermarkMockView`, the exact same visual PaywallSheet uses, so
    /// the two purchase surfaces agree) alongside a headline and one
    /// supporting line, then the price on the primary button and a quieter
    /// Restore Purchase below it. The primary button opens the full
    /// `PaywallSheet` - this card sells the idea, the sheet still owns the
    /// actual purchase flow and its error handling, so there's only one
    /// place that drives a StoreKit purchase. Restore Purchase calls
    /// `storeService.restore()` directly instead (unchanged from before this
    /// card existed) - it's a quick sync-and-check, not a sale, so it
    /// doesn't need the sheet's ceremony.
    private var watermarkUpsellCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                WatermarkMockView(size: 84, chipHeight: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save without the watermark")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Every collage you save carries a small Mosaic mark in the corner. Remove it once, keep it forever - no subscription.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Button {
                showPaywall = true
            } label: {
                Text(storeService.unlockButtonTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .background(Color.mosaicAccent)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .buttonStyle(.plain)

            Button {
                Task { await storeService.restore() }
            } label: {
                Text("Restore Purchase")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}
