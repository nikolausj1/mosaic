// Sources/App/Prototype/BottomBar/RatioTrayView.swift
// Ratio tray (Phase 4): 1:1, 4:5, 3:4, 2:3, 9:16, 16:9, Original. Tapping a
// non-active chip sets that ratio (its "un-flipped" w:h orientation);
// tapping the ACTIVE chip flips it (w:h -> h:w) - so a chip showing "4:5"
// stays the active one whether the canvas is actually 4:5 or 5:4.
import SwiftUI

private struct RatioPreset: Identifiable {
    let id: Int
    let label: String
    let w: Double
    let h: Double
}

private let ratioPresets: [RatioPreset] = [
    RatioPreset(id: 0, label: "1:1", w: 1, h: 1),
    RatioPreset(id: 1, label: "4:5", w: 4, h: 5),
    RatioPreset(id: 2, label: "3:4", w: 3, h: 4),
    RatioPreset(id: 3, label: "2:3", w: 2, h: 3),
    RatioPreset(id: 4, label: "9:16", w: 9, h: 16),
    RatioPreset(id: 5, label: "16:9", w: 16, h: 9),
]

struct RatioTrayView: View {
    let state: EditorState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ratioPresets) { preset in
                    chip(label: preset.label, w: preset.w, h: preset.h)
                }
                originalChip
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(height: 44 + 28)
        .background(Color.mosaicSurface)
    }

    private func isActive(w: Double, h: Double) -> Bool {
        let current = state.document.canvasRatio.value
        let target = w / h
        let flipped = h / w
        return abs(current - target) < 1e-6 || abs(current - flipped) < 1e-6
    }

    private func chip(label: String, w: Double, h: Double) -> some View {
        let active = isActive(w: w, h: h)
        return Button {
            if active {
                // Flip the CURRENT canvas ratio's orientation, not the
                // preset's nominal one - "4:5 active-flipped-to-5:4" must
                // still read as "4:5 active" per the brief.
                let current = state.document.canvasRatio
                state.setCanvasRatio(width: current.height, height: current.width)
            } else {
                state.setCanvasRatio(width: w, height: h)
            }
        } label: {
            chipLabel(label, active: active)
        }
    }

    @ViewBuilder
    private var originalChip: some View {
        if let original = state.originalAspectRatio {
            let active = isActive(w: original.width, h: original.height)
            Button {
                if active {
                    let current = state.document.canvasRatio
                    state.setCanvasRatio(width: current.height, height: current.width)
                } else {
                    state.setCanvasRatio(width: original.width, height: original.height)
                }
            } label: {
                chipLabel("Original", active: active)
            }
        }
    }

    private func chipLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .background(
                Capsule().fill(active ? Color.mosaicAccent : Color.white.opacity(0.10))
            )
            .overlay(
                Capsule().stroke(Color.black.opacity(0.35), lineWidth: active ? 1 : 0)
            )
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
    }
}
