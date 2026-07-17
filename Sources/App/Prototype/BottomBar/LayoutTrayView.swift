// Sources/App/Prototype/BottomBar/LayoutTrayView.swift
// Layout tray (design revision, 2026-07-17: fixed-size, aligned glyph
// tiles). One 56x56 tile per `templates(for:)` entry for the CURRENT photo
// count, each containing a 44x44 glyph centered on both axes: the
// template's cells solved at exactly 44x44 with a ~3pt gutter, drawn as
// filled rounded rects (no strokes). Tapping applies that template
// (EditorState.applyTemplate(index:)) - photos keep identity and crop by
// leaf order, fractions reset to even, one undo snapshot.
import SwiftUI

struct LayoutTrayView: View {
    let state: EditorState

    private let tileSize: CGFloat = 56
    private let glyphSize: CGFloat = 44

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
                            tileSize: tileSize,
                            glyphSize: glyphSize,
                            isActive: sameTopology(template, state.document.root)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 72)
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

/// A `tileSize`x`tileSize` tile containing `template`'s cells solved at
/// exactly `glyphSize`x`glyphSize` (centered on both axes within the
/// tile), each cell a filled rounded rect with no stroke: dim grey when
/// inactive, accent when this template matches the document's current
/// topology.
private struct TopologyGlyph: View {
    let template: Node
    let tileSize: CGFloat
    let glyphSize: CGFloat
    let isActive: Bool

    var body: some View {
        // ~3pt gutter at glyphSize: computeLayout derives gutter points as
        // border.inner * shortEdge, so inner = 3/glyphSize solves back to
        // exactly 3pt here (see Layout.swift's computeLayout).
        let canvasSize = CGSize(width: glyphSize, height: glyphSize)
        let border = BorderStyle(inner: 3.0 / Double(glyphSize), outer: 0, linked: true, cornerRadius: 0, color: .white)
        let (cells, _) = solve(root: template, canvasSize: canvasSize, border: border)

        ZStack(alignment: .topLeading) {
            // Fixed-size base layer so the ZStack is EXACTLY glyphSize^2:
            // without it the stack sizes to its largest cell (e.g. 8x44 for
            // a columns template), and centering that in the tile shifted
            // every offset cell sideways/downward - the old tray's
            // misalignment bug.
            Color.clear
                .frame(width: glyphSize, height: glyphSize)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isActive ? Color.mosaicAccent : Color.white.opacity(0.14))
                    .frame(width: cell.rect.width, height: cell.rect.height)
                    .offset(x: cell.rect.minX, y: cell.rect.minY)
            }
        }
        .frame(width: tileSize, height: tileSize)
    }
}
