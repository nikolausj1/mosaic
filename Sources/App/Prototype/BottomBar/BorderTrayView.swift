// Sources/App/Prototype/BottomBar/BorderTrayView.swift
// Border tray (design revision, 2026-07-17): a single THICKNESS slider
// (writes both border.inner and border.outer together - the old linked
// Inner/Outer pair + link toggle is gone, `border.linked` stays true always)
// + a Radius slider + a fixed six-swatch row: White, Black, three colors
// sampled from the photos (EditorState.derivedSwatches), then a "+" that
// opens the system color picker and applies the pick directly.
import SwiftUI

private let borderFractionCeiling = 0.15

struct BorderTrayView: View {
    let state: EditorState

    @State private var showColorPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliders
            swatchRow
        }
        .padding(.vertical, 12)
        .background(Color.mosaicSurface)
        .sheet(isPresented: $showColorPicker) {
            SystemColorPickerRepresentable(
                initialColor: uiColor(from: state.document.border.color),
                onPicked: { state.setBorderColor($0) },
                onDismiss: { showColorPicker = false }
            )
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 6) {
            sliderRow(title: "Thickness", value: thicknessBinding)
            sliderRow(title: "Radius", value: radiusBinding)
        }
        .padding(.horizontal, 16)
    }

    private func sliderRow(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...100, onEditingChanged: { editing in
                withAnimation(.easeInOut(duration: 0.15)) { state.isAdjustingBorder = editing }
                if editing { state.beginGesture() } else { state.commitGesture() }
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

    private var swatchRow: some View {
        HStack(spacing: 10) {
            swatch(.white)
            swatch(RGBA(r: 0, g: 0, b: 0, a: 1))
            swatch(state.derivedSwatches.bright)
            swatch(state.derivedSwatches.mid)
            swatch(state.derivedSwatches.dark)
            addSwatchButton
        }
        .padding(.horizontal, 16)
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
                .frame(width: 36, height: 36)
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    private var addSwatchButton: some View {
        Button {
            showColorPicker = true
        } label: {
            Circle()
                .fill(Color.white.opacity(0.08))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                )
                .frame(width: 36, height: 36)
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    private func colorsMatch(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }

    private func uiColor(from rgba: RGBA) -> UIColor {
        UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}
