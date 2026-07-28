// Sources/App/Store/PaywallSheet.swift
// B8's purchase surface: reached from the save sheet's watermark notice and
// from Settings' Remove Watermark row. Matches SaveSheetView's chrome
// (capsule handle, mosaicBackground, mosaicAccent primary button) so it
// reads as part of the app, not a bolted-on commerce screen.
import SwiftUI
import StoreKit

struct PaywallSheet: View {
    var storeService: StoreService

    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Spacer(minLength: 0)

            watermarkMock

            VStack(spacing: 8) {
                Text("Remove the watermark")
                    .font(.title2.weight(.semibold))
                Text("One-time purchase. No subscription. Everything else is already free.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    Task { await storeService.purchase() }
                } label: {
                    Group {
                        if storeService.isPurchasing {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text(purchaseButtonTitle)
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Color.mosaicAccent)
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(storeService.product == nil || storeService.isPurchasing)

                Button {
                    Task { await storeService.restore() }
                } label: {
                    Text("Restore Purchase")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .disabled(storeService.isPurchasing)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mosaicBackground.ignoresSafeArea())
        .foregroundStyle(.white)
        .task { await storeService.loadProduct() }
        .onChange(of: storeService.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
        .onChange(of: storeService.purchaseError) { _, error in
            showError = error != nil
        }
        .alert("Couldn't Complete Purchase", isPresented: $showError, presenting: storeService.purchaseError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var purchaseButtonTitle: String { storeService.unlockButtonTitle }

    /// The shared chip-plus-Lockup mock (Justin, 2026-07-28: factored into
    /// `WatermarkMockView` so SettingsSheet's upsell card shows the exact
    /// same visual, just smaller) at this sheet's original fixed 220pt size
    /// - unchanged from before the extraction.
    private var watermarkMock: some View {
        WatermarkMockView()
    }
}
