// Sources/App/Store/WatermarkMockView.swift
// A cheap pure-SwiftUI mock of the exported corner (Justin, 2026-07-26) -
// skips a real image asset; a gradient card is enough to show what the
// purchase removes rather than just describing it. Mirrors
// `WatermarkDecorator`'s chip-plus-Lockup treatment exactly.
//
// Factored out of PaywallSheet (Justin, 2026-07-28) so SettingsSheet's
// watermark upsell card can show the IDENTICAL mock at a smaller size rather
// than a second, hand-drawn approximation that could quietly drift out of
// sync with this one. `size`/`chipHeight` default to PaywallSheet's original
// fixed 220/12 so this refactor is a pure extraction - zero visual change
// there.
import SwiftUI

struct WatermarkMockView: View {
    var size: CGFloat = 220
    var chipHeight: CGFloat = 12

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.0545, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.mosaicAccent.opacity(0.35), Color.mosaicSurface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: size, height: size)
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
    }
}
