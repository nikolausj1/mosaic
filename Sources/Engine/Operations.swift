// Sources/Engine/Operations.swift
// All mutations are pure functions returning new values - Node/Document are
// value types, so "editing" always means "build a new tree/document".
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Renormalization

// Divide by sum. Sum 0 or non-finite -> equal shares.
func renormalized(_ fractions: [Double]) -> [Double] {
    guard !fractions.isEmpty else { return fractions }
    let sum = fractions.reduce(0, +)
    if !sum.isFinite || sum == 0 {
        return Array(repeating: 1.0 / Double(fractions.count), count: fractions.count)
    }
    let normalized = fractions.map { $0 / sum }
    if normalized.contains(where: { !$0.isFinite }) {
        return Array(repeating: 1.0 / Double(fractions.count), count: fractions.count)
    }
    return normalized
}

// MARK: - Tree navigation

func node(at path: [Int], in root: Node) -> Node? {
    if path.isEmpty { return root }
    guard case .split(_, _, let children) = root else { return nil }
    let idx = path[0]
    guard idx >= 0 && idx < children.count else { return nil }
    return node(at: Array(path.dropFirst()), in: children[idx])
}

func replacingNode(at path: [Int], in root: Node, with new: Node) -> Node {
    if path.isEmpty { return new }
    guard case .split(let axis, let fractions, var children) = root else { return root }
    let idx = path[0]
    guard idx >= 0 && idx < children.count else { return root }
    children[idx] = replacingNode(at: Array(path.dropFirst()), in: children[idx], with: new)
    return .split(axis: axis, fractions: fractions, children: children)
}

// MARK: - Divider dragging

struct DragResult: Equatable {
    var fractions: [Double]
    var snapped: Bool
}

// Zero-sum between fractions[index] and fractions[index+1] only. Hard floor:
// neither may go below Layout.minCellFraction - delta is clamped so both stay
// legal (rubber-banding is the UI's job). After clamping, if the divider's
// position (sum of fractions[0...index]) lands within toleranceFraction of a
// supplied candidate, snap the pair so the divider sits exactly there -
// unless that would breach the floor, in which case the snap is skipped.
func dragDivider(
    fractions: [Double],
    index: Int,
    deltaFraction: Double,
    snapCandidates: [Double],
    toleranceFraction: Double
) -> DragResult {
    precondition(index >= 0 && index + 1 < fractions.count, "index out of range for a zero-sum pair")

    let floor = Layout.minCellFraction
    var result = fractions
    let f0 = fractions[index]
    let f1 = fractions[index + 1]

    // delta >= floor - f0 keeps f0 >= floor; delta <= f1 - floor keeps f1 >= floor.
    let minDelta = floor - f0
    let maxDelta = f1 - floor
    let delta = min(max(deltaFraction, minDelta), maxDelta)

    var newF0 = f0 + delta
    var newF1 = f1 - delta
    result[index] = newF0
    result[index + 1] = newF1

    let precedingSum = index > 0 ? result[0..<index].reduce(0, +) : 0
    let position = precedingSum + newF0
    let pairSum = newF0 + newF1

    var snapped = false
    var bestCandidate: Double?
    var bestDist = Double.infinity

    for c in snapCandidates {
        let dist = abs(position - c)
        guard dist <= toleranceFraction, dist < bestDist else { continue }
        let candF0 = c - precedingSum
        let candF1 = pairSum - candF0
        guard candF0 >= floor && candF1 >= floor else { continue }
        bestCandidate = c
        bestDist = dist
    }

    if let c = bestCandidate {
        newF0 = c - precedingSum
        newF1 = pairSum - newF0
        result[index] = newF0
        result[index + 1] = newF1
        snapped = true
    }

    return DragResult(fractions: result, snapped: snapped)
}

// Computes real snap candidates for a divider being dragged: 0.5 (center) plus
// every OTHER same-axis divider's position, expressed in the dragged
// divider's own parent-fraction space. The divider being dragged is skipped.
func snapCandidates(
    forDividerAt path: [Int],
    index: Int,
    root: Node,
    canvasSize: CGSize,
    border: BorderStyle
) -> [Double] {
    let (_, dividers) = solve(root: root, canvasSize: canvasSize, border: border)

    guard let target = dividers.first(where: { $0.path == path && $0.index == index }) else {
        return [0.5]
    }
    guard let parentNode = node(at: path, in: root),
          case .split(let axis, _, let children) = parentNode,
          let parentRect = nodeRect(at: path, in: root, canvasSize: canvasSize, border: border)
    else {
        return [0.5]
    }

    let shortEdge = min(canvasSize.width, canvasSize.height)
    let gutterPts = border.inner * shortEdge
    let isH = (axis == .horizontal)
    let start = isH ? parentRect.minX : parentRect.minY
    let totalExtent = isH ? parentRect.width : parentRect.height
    let usable = totalExtent - gutterPts * Double(children.count - 1)

    var candidates: [Double] = [0.5]
    guard usable > 0 else { return candidates }

    for d in dividers {
        if d.path == path && d.index == index { continue } // skip self
        if d.axis != axis { continue } // same axis only
        let x = isH ? d.line.minX : d.line.minY
        let position = (x - start - gutterPts * Double(index)) / usable
        candidates.append(position)
    }
    _ = target // target only needed to confirm the divider exists
    return candidates
}

// MARK: - S5 invariant: photo must always fully cover its cell.

func clampedCenter(
    center: CGPoint,
    zoom: Double,
    photoPixelSize: CGSize,
    quarterTurns: Int,
    cellSize: CGSize
) -> CGPoint {
    let odd = (((quarterTurns % 4) + 4) % 4) % 2 == 1
    let photoW = odd ? photoPixelSize.height : photoPixelSize.width
    let photoH = odd ? photoPixelSize.width : photoPixelSize.height

    let s0 = max(cellSize.width / photoW, cellSize.height / photoH)
    let displayScale = s0 * zoom

    let hx = (cellSize.width / displayScale) / photoW / 2
    let hy = (cellSize.height / displayScale) / photoH / 2

    let cx: Double = hx >= 0.5 ? 0.5 : min(max(center.x, hx), 1 - hx)
    let cy: Double = hy >= 0.5 ? 0.5 : min(max(center.y, hy), 1 - hy)

    return CGPoint(x: cx, y: cy)
}

func clampedZoom(_ z: Double) -> Double {
    min(max(z, 1.0), 8.0)
}

func reclampAll(_ doc: Document, canvasSize: CGSize) -> Document {
    var newDoc = doc
    let (cells, _) = solve(root: doc.root, canvasSize: canvasSize, border: doc.border)
    for cell in cells {
        guard var photo = newDoc.photos[cell.id] else { continue }
        let newCenter = clampedCenter(
            center: photo.center,
            zoom: photo.zoom,
            photoPixelSize: CGSize(width: Double(photo.pixelWidth), height: Double(photo.pixelHeight)),
            quarterTurns: photo.quarterTurns,
            cellSize: cell.rect.size
        )
        photo.center = newCenter
        newDoc.photos[cell.id] = photo
    }
    return newDoc
}

// MARK: - Topology mutations

func splitLeaf(id: PhotoID, newPhoto: PhotoID, axis: Axis, in root: Node) -> Node {
    switch root {
    case .leaf(let leafId):
        guard leafId == id else { return root }
        return .split(axis: axis, fractions: [0.5, 0.5], children: [.leaf(id), .leaf(newPhoto)])
    case .split(let a, let f, let children):
        return .split(axis: a, fractions: f, children: children.map { splitLeaf(id: id, newPhoto: newPhoto, axis: axis, in: $0) })
    }
}

private func subtreeContains(_ node: Node, id: PhotoID) -> Bool {
    switch node {
    case .leaf(let leafId): return leafId == id
    case .split(_, _, let children): return children.contains { subtreeContains($0, id: id) }
    }
}

// Removes the leaf `id` anywhere in the tree. A split left with one surviving
// child collapses to that child (recursively, via the return of the deeper
// call). Removing from a 2-child split leaves the sibling in the parent's
// slot. Surviving fractions at the level a child was dropped are
// renormalized. Returns nil only if root itself was the sole leaf being removed.
func removeLeaf(id: PhotoID, from root: Node) -> Node? {
    switch root {
    case .leaf(let leafId):
        return leafId == id ? nil : root

    case .split(let axis, let fractions, let children):
        var newChildren: [Node] = []
        var newFractions: [Double] = []
        var changed = false

        for (i, child) in children.enumerated() {
            if subtreeContains(child, id: id) {
                changed = true
                if let reduced = removeLeaf(id: id, from: child) {
                    newChildren.append(reduced)
                    newFractions.append(fractions[i])
                }
                // else: child was a leaf equal to id - dropped entirely.
            } else {
                newChildren.append(child)
                newFractions.append(fractions[i])
            }
        }

        guard changed else { return root }

        if newChildren.isEmpty {
            return nil
        }
        if newChildren.count == 1 {
            return newChildren[0]
        }
        return .split(axis: axis, fractions: renormalized(newFractions), children: newChildren)
    }
}
