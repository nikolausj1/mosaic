// Sources/App/Prototype/BottomBar/RatioTrayView.swift
// Ratio tray (design revision, 2026-07-17: chips gained an aspect glyph):
// 1:1, 4:5, 3:4, 2:3, 9:16, 16:9, Original. Tapping a non-active chip sets
// that ratio (its "un-flipped" w:h orientation); tapping the ACTIVE chip
// flips it (w:h -> h:w) - so a chip showing "4:5" stays the active one
// whether the canvas is actually 4:5 or 5:4. Each chip's glyph is a small
// stroked rect whose own w:h matches the ratio it represents (the active
// chip's glyph tracks the canvas's CURRENT effective ratio, so a flip
// visibly rotates it too).
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

/// Extreme photo aspects (e.g. panoramas) are clamped into this range so
/// the "Original" chip's glyph always draws sanely.
private let originalGlyphRatioRange = 0.4...2.5

struct RatioTrayView: View {
    let state: EditorState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(ratioPresets) { preset in
                    chip(label: preset.label, w: preset.w, h: preset.h)
                }
                originalChip
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 76)
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
        let glyphRatio = active ? state.document.canvasRatio.value : w / h
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
            chipContent(label: label, glyphRatio: glyphRatio, active: active)
        }
    }

    @ViewBuilder
    private var originalChip: some View {
        if let original = state.originalAspectRatio {
            let active = isActive(w: original.width, h: original.height)
            let rawRatio = active ? state.document.canvasRatio.value : original.width / original.height
            let glyphRatio = min(max(rawRatio, originalGlyphRatioRange.lowerBound), originalGlyphRatioRange.upperBound)
            Button {
                if active {
                    let current = state.document.canvasRatio
                    state.setCanvasRatio(width: current.height, height: current.width)
                } else {
                    state.setCanvasRatio(width: original.width, height: original.height)
                }
            } label: {
                chipContent(label: "Original", glyphRatio: glyphRatio, active: active)
            }
        }
    }

    private func chipContent(label: String, glyphRatio: Double, active: Bool) -> some View {
        VStack(spacing: 5) {
            aspectGlyph(ratio: glyphRatio, active: active)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(active ? Color.mosaicAccent : Color.white.opacity(0.5))
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    /// A stroked rect whose w:h equals `ratio`, scaled to fit a 24x17 box
    /// (centered within it).
    private func aspectGlyph(ratio: Double, active: Bool) -> some View {
        let box = CGSize(width: 24, height: 17)
        let r = max(ratio, 0.001)
        let fitted: CGSize
        if r > box.width / box.height {
            fitted = CGSize(width: box.width, height: box.width / r)
        } else {
            fitted = CGSize(width: box.height * r, height: box.height)
        }
        return RoundedRectangle(cornerRadius: 2)
            .stroke(active ? Color.mosaicAccent : Color.white.opacity(0.5), lineWidth: 1.5)
            .frame(width: fitted.width, height: fitted.height)
            .frame(width: box.width, height: box.height)
    }
}
