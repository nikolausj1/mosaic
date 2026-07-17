// Sources/App/Prototype/BottomBar/LayoutTrayView.swift
// Layout tray (Phase 4): one 54x54 miniature-diagram glyph per
// `templates(for:)` entry for the CURRENT photo count. Tapping applies that
// template (EditorState.applyTemplate(index:)) - photos keep identity and
// crop by leaf order, fractions reset to even, one undo snapshot.
import SwiftUI

struct LayoutTrayView: View {
    let state: EditorState

    private let glyphSize: CGFloat = 54

    private var currentIDs: [PhotoID] { photoIDs(in: state.document.root) }
    private var candidates: [Node] { templates(for: currentIDs) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, template in
                    Button {
                        state.applyTemplate(index: index)
                    } label: {
                        TopologyGlyph(
                            template: template,
                            size: glyphSize,
                            isActive: sameTopology(template, state.document.root)
                        )
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 54 + 24)
        .background(Color.mosaicSurface)
    }
}

/// Structural topology match: same axis + same nesting shape, ignoring leaf
/// PhotoIDs (obviously - templates are re-populated with the CURRENT
/// photos' ids) AND ignoring fractions (a template stays "active" even
/// after the user drags its dividers away from even, since it's still
/// fundamentally the same topology - only a fresh `applyTemplate` call
/// resets to even).
func sameTopology(_ a: Node, _ b: Node) -> Bool {
    switch (a, b) {
    case (.leaf, .leaf):
        return true
    case (.split(let axisA, let fracA, let childrenA), .split(let axisB, let fracB, let childrenB)):
        guard axisA == axisB, childrenA.count == childrenB.count, fracA.count == fracB.count else { return false }
        return zip(childrenA, childrenB).allSatisfy { sameTopology($0, $1) }
    default:
        return false
    }
}

/// A miniature rendering of `template`, solved at `size`x`size` with a 2pt
/// gutter: each cell as a rounded rect, accent-stroked when `isActive`,
/// dim-grey-filled otherwise.
private struct TopologyGlyph: View {
    let template: Node
    let size: CGFloat
    let isActive: Bool

    var body: some View {
        let canvasSize = CGSize(width: size, height: size)
        let border = BorderStyle(inner: 2.0 / Double(size), outer: 0, linked: true, cornerRadius: 0, color: .white)
        let (cells, _) = solve(root: template, canvasSize: canvasSize, border: border)

        ZStack(alignment: .topLeading) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isActive ? Color.mosaicAccent.opacity(0.25) : Color.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(isActive ? Color.mosaicAccent : Color.white.opacity(0.25), lineWidth: isActive ? 1.5 : 1)
                    )
                    .frame(width: cell.rect.width, height: cell.rect.height)
                    .offset(x: cell.rect.minX, y: cell.rect.minY)
            }
        }
        .frame(width: size, height: size)
    }
}
