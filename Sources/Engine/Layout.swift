// Sources/Engine/Layout.swift
// Pure Foundation layout solver. Turns a Node tree + canvas size + border into
// concrete cell rects and divider gutter rects, all in canvas-coordinate points.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum Layout {
    static let minCellFraction = 0.10
}

struct CellFrame: Equatable {
    let id: PhotoID
    let rect: CGRect
}

// path = child indices from root to the SPLIT node owning this divider.
// index i = the divider between child i and child i+1 of that split node.
// line = the gutter strip rect in canvas coordinates (zero-thickness when
// the inner gutter is 0 - it collapses to the boundary line itself).
struct DividerFrame: Equatable {
    let path: [Int]
    let index: Int
    let axis: Axis
    let line: CGRect
}

private struct LayoutResult {
    var cells: [CellFrame] = []
    var dividers: [DividerFrame] = []
    var nodeRects: [[Int]: CGRect] = [:]
}

// Single shared traversal used by both `solve` and `nodeRect`, so the two
// never drift apart.
private func computeLayout(root: Node, canvasSize: CGSize, border: BorderStyle) -> LayoutResult {
    let shortEdge = min(canvasSize.width, canvasSize.height)
    let outerPts = border.outer * shortEdge
    let gutterPts = border.inner * shortEdge

    let contentRect = CGRect(
        x: outerPts,
        y: outerPts,
        width: canvasSize.width - 2 * outerPts,
        height: canvasSize.height - 2 * outerPts
    )

    var result = LayoutResult()

    func recurse(_ node: Node, rect: CGRect, path: [Int]) {
        result.nodeRects[path] = rect
        switch node {
        case .leaf(let id):
            result.cells.append(CellFrame(id: id, rect: rect))

        case .split(let axis, let fractions, let children):
            let n = children.count
            let isH = (axis == .horizontal)
            let totalExtent = isH ? rect.width : rect.height
            let usable = totalExtent - gutterPts * Double(n - 1)

            var childRects: [CGRect] = []
            childRects.reserveCapacity(n)
            var cursor = isH ? rect.minX : rect.minY
            for i in 0..<n {
                let extent = usable * fractions[i]
                let childRect: CGRect
                if isH {
                    childRect = CGRect(x: cursor, y: rect.minY, width: extent, height: rect.height)
                } else {
                    childRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: extent)
                }
                childRects.append(childRect)
                cursor += extent + gutterPts
            }

            for i in 0..<(n - 1) {
                let a = childRects[i]
                let b = childRects[i + 1]
                let line: CGRect
                if isH {
                    line = CGRect(x: a.maxX, y: rect.minY, width: b.minX - a.maxX, height: rect.height)
                } else {
                    line = CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: b.minY - a.maxY)
                }
                result.dividers.append(DividerFrame(path: path, index: i, axis: axis, line: line))
            }

            for i in 0..<n {
                recurse(children[i], rect: childRects[i], path: path + [i])
            }
        }
    }

    recurse(root, rect: contentRect, path: [])
    return result
}

func solve(root: Node, canvasSize: CGSize, border: BorderStyle) -> (cells: [CellFrame], dividers: [DividerFrame]) {
    let r = computeLayout(root: root, canvasSize: canvasSize, border: border)
    return (r.cells, r.dividers)
}

// The rect a given node (leaf OR split) occupies in canvas coordinates,
// BEFORE that node's own children partition it. path == [] means the whole
// content rect (root). Returns nil if the path doesn't resolve in this tree.
func nodeRect(at path: [Int], in root: Node, canvasSize: CGSize, border: BorderStyle) -> CGRect? {
    let r = computeLayout(root: root, canvasSize: canvasSize, border: border)
    return r.nodeRects[path]
}
