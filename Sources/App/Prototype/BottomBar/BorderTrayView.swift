// Sources/App/Prototype/BottomBar/BorderTrayView.swift
// Border tray (design revision, 2026-07-17): a single THICKNESS slider
// (writes both border.inner and border.outer together - the old linked
// Inner/Outer pair + link toggle is gone, `border.linked` stays true always)
// + a Radius slider + a fixed swatch row: White, Black, three vibrant colors
// sampled from the photos, and the brightest sampled color (Justin,
// 2026-07-26 - EditorState.derivedSwatches, most-to-least vibrant then
// brightest), then a "+" that opens the system color picker and applies the
// pick directly. That's 6 fixed swatches + "+" = 7 tappable elements in one
// row - see `swatchRow`'s doc comment for the sizing math that keeps them
// all on-screen at once.
import SwiftUI

private let borderFractionCeiling = 0.15

struct BorderTrayView: View {
    let state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliders
            swatchRow
        }
        .padding(.vertical, 12)
        .background(Color.mosaicSurface)
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 6) {
            // Sticky thickness (Justin, 2026-07-27): only the Thickness
            // slider commits to EditorState's remembered-thickness
            // preference on release - Radius has no such memory feature.
            sliderRow(title: "Thickness", value: thicknessBinding, isThickness: true)
            sliderRow(title: "Radius", value: radiusBinding)
        }
        .padding(.horizontal, 16)
    }

    private func sliderRow(title: String, value: Binding<Double>, isThickness: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...100, onEditingChanged: { editing in
                withAnimation(.easeInOut(duration: 0.15)) { state.isAdjustingBorder = editing }
                if editing {
                    state.beginGesture()
                } else {
                    state.commitGesture()
                    // Sticky thickness (Justin, 2026-07-27): remember
                    // whatever the user just landed on - including a
                    // deliberate 0 - and retire the Border tray's
                    // auto-starter for this document permanently.
                    if isThickness { state.commitBorderThicknessChoice() }
                }
            })
            .tint(Color.mosaicAccent)
        }
        .frame(minHeight: 44)
    }

    private var thicknessBinding: Binding<Double> {
        Binding(
            get: { state.document.border.inner / borderFractionCeiling * 100 },
            set: { state.setBorderThickness(max(0, min($0, 100)) / 100 * borderFractionCeiling) }
        )
    }

    private var radiusBinding: Binding<Double> {
        Binding(
            get: { state.document.border.cornerRadius / borderFractionCeiling * 100 },
            set: { state.setBorderRadius(max(0, min($0, 100)) / 100 * borderFractionCeiling) }
        )
    }

    // MARK: Swatches

    /// Seventh swatch + eyedropper (Justin, 2026-07-26): the row was 9
    /// elements - white, black, vibrant1-3, brightest, luminous, the B11
    /// eyedropper, and "+" - fixed at 9*38 + 8*3 + 2*10 = 386pt, which just
    /// fits a 393pt screen.
    ///
    /// Remembered eyedropper picks (Justin, 2026-07-27, cap raised 2 -> 4 on
    /// 2026-07-28 - "build a small palette"): up to 4 more swatches
    /// (`state.recentSampledSwatches`, newest first) now insert immediately
    /// before the eyedropper button, so the row can hold up to 13 elements -
    /// which no longer fits at any reasonable tap-target size. Rather than
    /// shrink targets further or truncate the row, `swatchRow` is now a
    /// horizontally scrollable `ScrollView` - the fixed 7 swatches + up to 4
    /// recent picks + eyedropper + "+" all keep their existing 38pt tap
    /// targets (still >= the 36pt floor) and are simply reachable by a short
    /// swipe when the recent picks push the row past the screen edge; with
    /// 0-1 recent picks (the common case) everything still fits with no
    /// scrolling needed at all.
    private let swatchSpacing: CGFloat = 3
    private let swatchTapTarget: CGFloat = 38
    private let swatchDiameter: CGFloat = 30

    private var swatchRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: swatchSpacing) {
                swatch(.white)
                swatch(RGBA(r: 0, g: 0, b: 0, a: 1))
                swatch(state.derivedSwatches.vibrant1)
                swatch(state.derivedSwatches.vibrant2)
                swatch(state.derivedSwatches.vibrant3)
                swatch(state.derivedSwatches.brightest)
                swatch(state.derivedSwatches.luminous)
                ForEach(Array(state.recentSampledSwatches.enumerated()), id: \.offset) { _, rgba in
                    swatch(rgba)
                }
                eyedropperButton
                addSwatchButton
            }
            .padding(.horizontal, 10)
        }
    }

    /// B11 loupe eyedropper (Justin, 2026-07-26): arms the canvas eyedropper
    /// AND kicks off the cached composite render the loupe magnifies from -
    /// see EditorState.beginColorSampling and CanvasView's samplingOverlay.
    private var eyedropperButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { state.beginColorSampling() }
        } label: {
            Circle()
                .fill(state.isSamplingColor ? Color.mosaicAccentDeep : Color.white.opacity(0.08))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .overlay(
                    Image(systemName: "eyedropper")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                )
                .frame(width: swatchDiameter, height: swatchDiameter)
                .frame(minWidth: swatchTapTarget, minHeight: swatchTapTarget)
        }
    }

    private func swatch(_ rgba: RGBA) -> some View {
        let isActive = colorsMatch(rgba, state.document.border.color)
        return Button {
            state.setBorderColor(rgba)
        } label: {
            Circle()
                .fill(Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .overlay(Circle().stroke(Color.mosaicAccent, lineWidth: isActive ? 2 : 0))
                .frame(width: swatchDiameter, height: swatchDiameter)
                .frame(minWidth: swatchTapTarget, minHeight: swatchTapTarget)
        }
    }

    private var addSwatchButton: some View {
        Button {
            // Presented straight from UIKit, not a SwiftUI sheet - the
            // system eyedropper crashes when its presenting sheet tears
            // down mid-sample. See SystemColorPicker's doc comment.
            SystemColorPicker.present(
                initialColor: uiColor(from: state.document.border.color),
                onPicked: { state.setBorderColor($0) }
            )
        } label: {
            Circle()
                .fill(Color.white.opacity(0.08))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                )
                .frame(width: swatchDiameter, height: swatchDiameter)
                .frame(minWidth: swatchTapTarget, minHeight: swatchTapTarget)
        }
    }

    private func colorsMatch(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }

    private func uiColor(from rgba: RGBA) -> UIColor {
        UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}
