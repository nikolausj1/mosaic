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

    private var purchaseButtonTitle: String {
        guard let product = storeService.product else { return "Unlock" }
        return "Unlock - \(product.displayPrice)"
    }

    /// A cheap pure-SwiftUI mock of the exported corner (skips a real image
    /// asset per the brief - a gradient card is enough to show what the
    /// purchase removes rather than just describing it).
    private var watermarkMock: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.mosaicAccent.opacity(0.35), Color.mosaicSurface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 220, height: 220)
            // Mirrors WatermarkDecorator's chip-plus-lockup treatment so the
            // paywall shows exactly what a purchase removes.
            Image("Lockup")
                .resizable()
                .scaledToFit()
                .frame(height: 12)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 11/255, green: 11/255, blue: 13/255).opacity(0.78))
                )
                .padding(10)
        }
    }
}
