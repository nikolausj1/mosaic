// Sources/App/Prototype/BottomBar/EditorBottomBar.swift
// The persistent, contextual bottom bar (Phase 4). Nothing selected: three
// tabs (Layout/Ratio/Border) that each raise a tray above the bar. A photo
// selected: the single-tap photo toolbar (Auto/Flip H/Flip V/Rotate/
// Replace/Remove), no trays. Only one tray is ever open at a time, and
// selection changes are handled by EditorView's `.onChange(of: state.selection)`
// (closing the tray without touching GestureController).
import SwiftUI

struct EditorBottomBar: View {
    let state: EditorState
    /// Bubbles up "Replace was tapped for this photo" so EditorView (which
    /// owns the picker-sheet presentation state) can present the picker.
    var onReplace: (PhotoID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            trayContent
            bar
        }
        // A tap anywhere on the canvas (photo or dead space) closes a tray -
        // GestureController itself is off-limits this phase, so this rides
        // alongside it rather than through it.
    }

    @ViewBuilder
    private var trayContent: some View {
        if state.selection == nil {
            switch state.activeTray {
            case .none:
                EmptyView()
            case .layout:
                LayoutTrayView(state: state)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .ratio:
                RatioTrayView(state: state)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .border:
                BorderTrayView(state: state)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        if state.selection != nil {
            PhotoToolbarView(state: state, onReplace: onReplace)
                .transition(.opacity)
        } else {
            tabsBar
                .transition(.opacity)
        }
    }

    private var tabsBar: some View {
        HStack(spacing: 0) {
            tabButton(.layout, title: "Layout", systemImage: "square.grid.2x2")
            tabButton(.ratio, title: "Ratio", systemImage: "aspectratio")
            tabButton(.border, title: "Border", systemImage: "square.dashed")
        }
        .frame(height: 64)
        .background(Color.mosaicSurface)
    }

    private func tabButton(_ tray: EditorState.ActiveTray, title: String, systemImage: String) -> some View {
        let isActive = state.activeTray == tray
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                state.activeTray = (state.activeTray == tray) ? .none : tray
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isActive ? Color.mosaicAccent : Color.white.opacity(0.55))
        }
    }
}
