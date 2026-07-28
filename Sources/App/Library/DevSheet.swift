// Sources/App/Library/DevSheet.swift
// Dev Tools entry (Justin, 2026-07-26): a small hammer icon at the trailing
// end of the picker header opens this. Ships in Release FOR NOW - Justin
// wants to replay the first-run experience and A/B test it on his own phone
// without a rebuild each time. The lead owns adding a pre-submission removal
// gate before this ever reaches the App Store; this file makes no attempt to
// hide itself. Styled to match `SettingsSheet` (List rows on
// `Color.mosaicSurface`, `Color.mosaicBackground` behind) without editing
// that file.
import SwiftUI

struct DevSheet: View {
    /// Resets hasSeenWelcome (and the current process's launch-animation
    /// guard) and re-stages the welcome choreography from scratch - see
    /// `PickerView.replayFirstRunExperience()`. That effect is visible
    /// immediately, no relaunch required, which is why this row's footer
    /// copy below is careful to only claim "next launch" for the pieces that
    /// actually need one.
    var onReplayFirstRun: () -> Void
    /// `DocumentStore.resetAll()` - wipes current.json, last.json, and any
    /// PHPicker-fallback proxy JPEGs.
    var onClearCollages: () -> Void
    var onDismiss: () -> Void

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
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
                    // EditorView.swift - this tool clears their UserDefaults
                    // keys but can't re-stage an Editor that isn't on screen,
                    // so those two genuinely need the next Editor entry.
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
            .navigationTitle("Developer")
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
    }

    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}
