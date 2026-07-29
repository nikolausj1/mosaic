// Sources/App/Store/WatermarkMockView.swift
// A mock of the exported corner (Justin, 2026-07-26) showing what the
// purchase removes. Mirrors `WatermarkDecorator`'s chip-plus-Lockup
// treatment exactly.
//
// Factored out of PaywallSheet (Justin, 2026-07-28) so SettingsSheet's
// watermark upsell card can show the IDENTICAL mock at a smaller size rather
// than a second, hand-drawn approximation that could quietly drift out of
// sync with this one. `size`/`chipHeight` default to PaywallSheet's original
// fixed 220/12 so this refactor is a pure extraction - zero visual change
// there.
//
// "Make the paywall preview look real" (Justin, 2026-07-28): the background
// used to be a flat gradient card - now it's a small render of the user's
// OWN photos (their in-progress/last collage, or failing that a quick
// composite of recent library photos) via `WatermarkPreviewProvider`, loaded
// asynchronously and falling back to the ORIGINAL gradient the instant
// nothing is available (denied access, no photos, a failed render) - see
// that file's header for the full priority order. The watermark chip itself
// - position, proportions, padding - is UNCHANGED: that's the product claim
// and has to stay accurate regardless of what's behind it.
import SwiftUI

struct WatermarkMockView: View {
    var size: CGFloat = 220
    var chipHeight: CGFloat = 12

    @State private var previewImage: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            background
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.0545, style: .continuous))
            // Same proportions as the original fixed-size mock (7/12 and
            // 5/12 padding fractions, a fully-rounded pill background, a
            // 10/220 outer inset) so shrinking `size`/`chipHeight` for the
            // Settings card scales the whole chip down uniformly instead of
            // just the logo inside it.
            Image("Lockup")
                .resizable()
                .scaledToFit()
                .frame(height: chipHeight)
                .padding(.horizontal, chipHeight * (7.0 / 12.0))
                .padding(.vertical, chipHeight * (5.0 / 12.0))
                .background(
                    RoundedRectangle(cornerRadius: chipHeight / 2, style: .continuous)
                        .fill(Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255).opacity(0.78))
                )
                .padding(size * (10.0 / 220.0))
        }
        .task {
            // Never blocks: `previewImage` simply stays nil (the gradient
            // keeps showing) until/unless this resolves - see
            // `WatermarkPreviewProvider`'s "falls back silently" contract.
            previewImage = await WatermarkPreviewProvider.image()
        }
    }

    @ViewBuilder
    private var background: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                // A real photo can be bright right where the chip sits;
                // this quiet corner-anchored scrim keeps the chip legible
                // over an arbitrary collage the same way the original flat
                // gradient always guaranteed a dark bottom-trailing corner.
                .overlay(
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.45)],
                        startPoint: .center,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            LinearGradient(
                colors: [Color.mosaicAccent.opacity(0.35), Color.mosaicSurface],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
