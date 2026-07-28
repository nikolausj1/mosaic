// Sources/App/Settings/SettingsSheet.swift
// B28's reserved settings ingress: a gear icon in the Picker header (Screen
// A) opens this. v1 has nothing to configure by design - this sheet exists
// only because B8's purchase (+ its restore) needed somewhere to live, so
// it stays deliberately tiny rather than growing into a general prefs
// screen.
import SwiftUI

struct SettingsSheet: View {
    var storeService: StoreService
    var onDismiss: () -> Void

    @State private var showPaywall = false

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
