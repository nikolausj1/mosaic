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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Text("Remove Watermark")
                                .foregroundStyle(.white)
                            Spacer()
                            if storeService.isUnlocked {
                                Label("Removed", systemImage: "checkmark")
                                    .labelStyle(.trailingIcon)
                                    .foregroundStyle(.white.opacity(0.5))
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                        }
                    }
                    .disabled(storeService.isUnlocked)

                    Button {
                        Task { await storeService.restore() }
                    } label: {
                        Text("Restore Purchase")
                            .foregroundStyle(Color.mosaicAccent)
                    }
                }
                .listRowBackground(Color.mosaicSurface)

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
    }

    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}

/// "Removed" + a checkmark, icon trailing the title - the reverse of
/// SwiftUI's default Label layout, matching the row's leading-title/
/// trailing-status convention used elsewhere (e.g. PickerView's album menu).
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

private extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}
