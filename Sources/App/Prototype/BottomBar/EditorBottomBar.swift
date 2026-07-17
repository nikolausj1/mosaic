// Sources/App/Prototype/BottomBar/EditorBottomBar.swift
// The persistent DOCUMENT bar (design revision, Justin, 2026-07-17):
// Layout/Ratio/Border tabs + their trays are ALWAYS visible - document-
// level tools must never disappear behind a photo-level mode (the same
// argument the PRD used to pin Save to the top bar). The photo toolbar
// now lives in EditorView's floating strip between the canvas and this
// bar, so both can be on screen at once.
import SwiftUI

struct EditorBottomBar: View {
    let state: EditorState
    /// Bubbles up "Replace was tapped for this photo" so EditorView (which
    /// owns the picker-sheet presentation state) can present the picker.
    var onReplace: (PhotoID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            trayContent
            tabsBar
        }
    }

    @ViewBuilder
    private var trayContent: some View {
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
