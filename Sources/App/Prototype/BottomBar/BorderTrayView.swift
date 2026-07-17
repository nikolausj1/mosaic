// Sources/App/Prototype/BottomBar/BorderTrayView.swift
// Border tray (Phase 4): Inner/Outer sliders (0-100 UI <-> 0...0.15 fraction,
// linked by default) + Radius slider + a swatch row (derived suggestions,
// then white/black/greys, then presets, then a "+" system color picker).
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
                onPicked: { state.addCustomSwatch($0) },
                onDismiss: { showColorPicker = false }
            )
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 6) {
            HStack {
                sliderRow(title: "Inner", value: innerBinding)
                linkToggle
            }
            sliderRow(title: "Outer", value: outerBinding)
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
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: 0...100, onEditingChanged: { editing in
                if editing { state.beginGesture() } else { state.commitGesture() }
            })
            .tint(Color.mosaicAccent)
        }
        .frame(minHeight: 44)
    }

    private var linkToggle: some View {
        Button {
            state.setBorderLinked(!state.document.border.linked)
        } label: {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(state.document.border.linked ? Color.mosaicAccent : Color.white.opacity(0.12))
                )
                .foregroundStyle(state.document.border.linked ? Color.black : Color.white.opacity(0.7))
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private var innerBinding: Binding<Double> {
        Binding(
            get: { state.document.border.inner / borderFractionCeiling * 100 },
            set: { state.setBorderInner(max(0, min($0, 100)) / 100 * borderFractionCeiling) }
        )
    }

    private var outerBinding: Binding<Double> {
        Binding(
            get: { state.document.border.outer / borderFractionCeiling * 100 },
            set: { state.setBorderOuter(max(0, min($0, 100)) / 100 * borderFractionCeiling) }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(state.derivedSwatches.enumerated()), id: \.offset) { _, rgba in
                    swatch(rgba)
                }
                swatch(.white)
                swatch(RGBA(r: 0, g: 0, b: 0, a: 1))
                swatch(RGBA(r: 0.110, g: 0.110, b: 0.118, a: 1)) // #1C1C1E
                swatch(RGBA(r: 0.282, g: 0.282, b: 0.290, a: 1)) // #48484A
                swatch(RGBA(r: 0.557, g: 0.557, b: 0.576, a: 1)) // #8E8E93
                swatch(RGBA(r: 0.961, g: 0.937, b: 0.902, a: 1)) // #F5EFE6 warm cream
                swatch(RGBA(r: 0.063, g: 0.094, b: 0.157, a: 1)) // #101828 deep navy
                ForEach(Array(state.customSwatches.enumerated()), id: \.offset) { _, rgba in
                    swatch(rgba)
                }
                addSwatchButton
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
    }

    private func swatch(_ rgba: RGBA) -> some View {
        let isActive = colorsMatch(rgba, state.document.border.color)
        return Button {
            state.setBorderColor(rgba)
        } label: {
            Circle()
                .fill(Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .overlay(Circle().stroke(Color.mosaicAccent, lineWidth: isActive ? 2.5 : 0))
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                )
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
        }
    }

    private func colorsMatch(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }

    private func uiColor(from rgba: RGBA) -> UIColor {
        UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}
