// Sources/App/Prototype/BottomBar/PhotoToolbarView.swift
// Photo toolbar (Phase 4): Auto | Flip H | Flip V | Rotate | Replace |
// Remove - single-tap actions, no trays, horizontally scrollable so touch
// targets never shrink (matches the Layout tray's four-tile precedent).
import SwiftUI

struct PhotoToolbarView: View {
    let state: EditorState
    var onReplace: (PhotoID) -> Void

    private var selectedPhoto: PhotoRef? {
        guard let sel = state.selection else { return nil }
        return state.document.photos[sel]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolButton(title: "Auto", systemImage: "wand.and.stars", tint: autoTint) {
                    state.toggleAuto()
                }
                toolButton(title: "Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    state.flipH()
                }
                toolButton(title: "Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    state.flipV()
                }
                toolButton(title: "Rotate", systemImage: "rotate.right") {
                    state.rotate()
                }
                toolButton(title: "Replace", systemImage: "photo.on.rectangle") {
                    if let sel = state.selection { onReplace(sel) }
                }
                toolButton(title: "Remove", systemImage: "trash", isDisabled: !state.canRemoveSelection) {
                    state.remove()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(height: 64)
        .background(Color.mosaicSurface)
    }

    private var autoTint: Color {
        guard let photo = selectedPhoto, photo.isAuto else { return Color.mosaicAccent.opacity(0.4) }
        return Color.mosaicAccent
    }

    private func toolButton(
        title: String, systemImage: String, tint: Color = .white,
        isDisabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
            }
            .frame(minWidth: 68, minHeight: 44)
            .foregroundStyle(isDisabled ? Color.white.opacity(0.25) : tint)
        }
        .disabled(isDisabled)
    }
}
