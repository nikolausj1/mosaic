// Tests/SmokeTest.swift
// Top-level executable Swift - copied to /tmp/main.swift by the Build Guide
// recipe and compiled together with Sources/Engine/*.swift via swiftc.
// NOT part of the Xcode target. No @main - just top-level statements.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Tiny harness

var passed = 0
var failed = 0

func check(_ cond: Bool, _ name: String) {
    if cond {
        passed += 1
    } else {
        failed += 1
        print("✗ \(name)")
    }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    abs(a - b) <= tol
}

func makePhoto(
    w: Int, h: Int, zoom: Double = 1.0,
    center: CGPoint = CGPoint(x: 0.5, y: 0.5),
    quarterTurns: Int = 0, roi: ROI? = nil
) -> PhotoRef {
    PhotoRef(
        assetLocalIdentifier: "test-\(w)x\(h)",
        pixelWidth: w, pixelHeight: h,
        zoom: zoom, center: center,
        flipH: false, flipV: false,
        quarterTurns: quarterTurns,
        isAuto: true, roi: roi
    )
}

// =====================================================================
// ANCHOR A - Solver
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    let root = Node.split(axis: .horizontal, fractions: [0.58, 0.42], children: [.leaf(a), .leaf(b)])
    let border = BorderStyle(inner: 0.02, outer: 0.02, linked: true, cornerRadius: 0, color: .white)
    let (cells, dividers) = solve(root: root, canvasSize: CGSize(width: 380, height: 380), border: border)

    let cellA = cells.first { $0.id == a }!
    let cellB = cells.first { $0.id == b }!

    check(near(cellA.rect.origin.x, 7.6, 0.001), "A: cellA.x")
    check(near(cellA.rect.origin.y, 7.6, 0.001), "A: cellA.y")
    check(near(cellA.rect.width, 207.176, 0.001), "A: cellA.width")
    check(near(cellA.rect.height, 364.8, 0.001), "A: cellA.height")
    check(near(cellB.rect.origin.x, 222.376, 0.001), "A: cellB.x")
    check(near(cellB.rect.origin.y, 7.6, 0.001), "A: cellB.y")
    check(near(cellB.rect.width, 150.024, 0.001), "A: cellB.width")
    check(near(cellB.rect.height, 364.8, 0.001), "A: cellB.height")
    check(dividers.count == 1 && near(dividers[0].line.minX, cellA.rect.maxX, 0.001), "A: divider aligns with cellA.maxX")
}

// =====================================================================
// ANCHOR B - Clamp
// =====================================================================
do {
    let c = clampedCenter(
        center: CGPoint(x: 0, y: 0), zoom: 1,
        photoPixelSize: CGSize(width: 2400, height: 1600),
        quarterTurns: 0, cellSize: CGSize(width: 200, height: 200)
    )
    check(near(c.x, 1.0 / 3.0, 1e-9), "B: clamp x == 1/3")
    check(near(c.y, 0.5, 1e-9), "B: clamp y == 0.5")
}

// =====================================================================
// ANCHOR C - Drag floor
// =====================================================================
do {
    let r = dragDivider(fractions: [0.5, 0.5], index: 0, deltaFraction: -0.45, snapCandidates: [], toleranceFraction: 0.01)
    check(near(r.fractions[0], 0.10, 1e-9), "C: floor f0 == 0.10")
    check(near(r.fractions[1], 0.90, 1e-9), "C: floor f1 == 0.90")
    check(r.snapped == false, "C: floor snapped == false")
}

// =====================================================================
// ANCHOR D - Center snap
// =====================================================================
do {
    let r1 = dragDivider(fractions: [0.52, 0.48], index: 0, deltaFraction: 0, snapCandidates: [0.5], toleranceFraction: 0.03)
    check(near(r1.fractions[0], 0.5, 1e-9), "D1: f0 snapped to 0.5")
    check(near(r1.fractions[1], 0.5, 1e-9), "D1: f1 snapped to 0.5")
    check(r1.snapped == true, "D1: snapped == true")

    let r2 = dragDivider(fractions: [0.55, 0.45], index: 0, deltaFraction: 0, snapCandidates: [0.5], toleranceFraction: 0.03)
    check(near(r2.fractions[0], 0.55, 1e-9), "D2: f0 unchanged")
    check(near(r2.fractions[1], 0.45, 1e-9), "D2: f1 unchanged")
    check(r2.snapped == false, "D2: snapped == false")
}

// =====================================================================
// ANCHOR E - Export sizing
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    let root = Node.split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(a), .leaf(b)])
    var photos: [PhotoID: PhotoRef] = [:]
    photos[a] = makePhoto(w: 2400, h: 1600, zoom: 1)
    photos[b] = makePhoto(w: 1284, h: 1926, zoom: 1)
    let doc = Document(canvasRatio: .square, root: root, photos: photos, border: .none)
    let size = exportPixelSize(doc: doc, canvasUnits: CGSize(width: 100, height: 100))
    check(near(size.width, 1926, 1), "E: export width ~1926")
    check(near(size.height, 1926, 1), "E: export height ~1926")
}

// =====================================================================
// Renormalization
// =====================================================================
do {
    let r = renormalized([2, 3, 5])
    check(near(r[0], 0.2, 1e-9), "renorm [2,3,5] -> 0.2")
    check(near(r[1], 0.3, 1e-9), "renorm [2,3,5] -> 0.3")
    check(near(r[2], 0.5, 1e-9), "renorm [2,3,5] -> 0.5")

    let z = renormalized([0, 0, 0])
    check(near(z[0], 1.0 / 3.0, 1e-9), "renorm zero-sum -> 1/3 (a)")
    check(near(z[1], 1.0 / 3.0, 1e-9), "renorm zero-sum -> 1/3 (b)")
    check(near(z[2], 1.0 / 3.0, 1e-9), "renorm zero-sum -> 1/3 (c)")

    let inf = renormalized([Double.infinity, 1, 1])
    check(near(inf[0], 1.0 / 3.0, 1e-9), "renorm non-finite (inf) -> 1/3 (a)")
    check(near(inf[1], 1.0 / 3.0, 1e-9), "renorm non-finite (inf) -> 1/3 (b)")
    check(near(inf[2], 1.0 / 3.0, 1e-9), "renorm non-finite (inf) -> 1/3 (c)")

    let nanCase = renormalized([Double.nan, 1, 1])
    check(near(nanCase[0], 1.0 / 3.0, 1e-9), "renorm non-finite (nan) -> 1/3 (a)")
    check(near(nanCase[1], 1.0 / 3.0, 1e-9), "renorm non-finite (nan) -> 1/3 (b)")
    check(near(nanCase[2], 1.0 / 3.0, 1e-9), "renorm non-finite (nan) -> 1/3 (c)")
}

// =====================================================================
// node(at:) / replacingNode(at:) round trip
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    let c = PhotoID()
    let d = PhotoID()
    let root = Node.split(
        axis: .horizontal, fractions: [0.4, 0.6],
        children: [.leaf(a), .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(b), .leaf(c)])]
    )

    check(node(at: [1, 0], in: root) == .leaf(b), "node(at:) finds nested leaf b")
    check(node(at: [1, 1], in: root) == .leaf(c), "node(at:) finds nested leaf c")
    check(node(at: [5], in: root) == nil, "node(at:) out-of-range top index -> nil")
    check(node(at: [1, 5], in: root) == nil, "node(at:) out-of-range nested index -> nil")

    let replaced = replacingNode(at: [1, 0], in: root, with: .leaf(d))
    check(node(at: [1, 0], in: replaced) == .leaf(d), "replacingNode: slot replaced")
    check(node(at: [1, 1], in: replaced) == .leaf(c), "replacingNode: sibling untouched")
}

// =====================================================================
// dragDivider on a 3-way node only touches the adjacent pair
// =====================================================================
do {
    let r = dragDivider(fractions: [0.3, 0.3, 0.4], index: 0, deltaFraction: 0.05, snapCandidates: [], toleranceFraction: 0)
    check(near(r.fractions[0], 0.35, 1e-9), "3-way: f0 adjusted")
    check(near(r.fractions[1], 0.25, 1e-9), "3-way: f1 adjusted")
    check(near(r.fractions[2], 0.4, 1e-9), "3-way: f2 untouched")
    check(near(r.fractions.reduce(0, +), 1.0, 1e-9), "3-way: fractions still sum to 1")
    check(r.snapped == false, "3-way: no snap requested")
}

// =====================================================================
// Snap refused when it would breach the 0.10 floor
// =====================================================================
do {
    let r = dragDivider(fractions: [0.11, 0.89], index: 0, deltaFraction: 0, snapCandidates: [0.02], toleranceFraction: 0.15)
    check(near(r.fractions[0], 0.11, 1e-9), "floor-refuse: f0 unchanged")
    check(near(r.fractions[1], 0.89, 1e-9), "floor-refuse: f1 unchanged")
    check(r.snapped == false, "floor-refuse: snapped == false")
}

// =====================================================================
// snapCandidates for a 2x2 grid
// =====================================================================
do {
    let w = PhotoID(), x = PhotoID(), y = PhotoID(), z = PhotoID()
    let col0 = Node.split(axis: .vertical, fractions: [0.48, 0.52], children: [.leaf(w), .leaf(x)])
    let col1 = Node.split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(y), .leaf(z)])
    let root = Node.split(axis: .horizontal, fractions: [0.5, 0.5], children: [col0, col1])
    let canvasSize = CGSize(width: 400, height: 400)

    let cands = snapCandidates(forDividerAt: [0], index: 0, root: root, canvasSize: canvasSize, border: .none)
    check(cands.count == 2, "2x2 snapCandidates: center + col1 divider (count == 2)")
    check(cands.allSatisfy { near($0, 0.5, 1e-9) }, "2x2 snapCandidates: both candidates == 0.5")

    let dragResult = dragDivider(fractions: [0.48, 0.52], index: 0, deltaFraction: 0, snapCandidates: cands, toleranceFraction: 0.03)
    check(dragResult.snapped == true, "2x2: col0 divider snaps flush")
    check(near(dragResult.fractions[0], 0.5, 1e-9), "2x2: col0 f0 == 0.5 after snap")
    check(near(dragResult.fractions[1], 0.5, 1e-9), "2x2: col0 f1 == 0.5 after snap")
}

// =====================================================================
// clampedCenter with zoom 2 (hx == 1/6)
// =====================================================================
do {
    let cellSize = CGSize(width: 200, height: 200)
    let photoSize = CGSize(width: 2400, height: 1600)

    let lo = clampedCenter(center: CGPoint(x: 0, y: 0), zoom: 2, photoPixelSize: photoSize, quarterTurns: 0, cellSize: cellSize)
    check(near(lo.x, 1.0 / 6.0, 1e-9), "zoom2: lo.x == 1/6")
    check(near(lo.y, 0.25, 1e-9), "zoom2: lo.y == 0.25")

    let hi = clampedCenter(center: CGPoint(x: 1, y: 1), zoom: 2, photoPixelSize: photoSize, quarterTurns: 0, cellSize: cellSize)
    check(near(hi.x, 5.0 / 6.0, 1e-9), "zoom2: hi.x == 5/6")
    check(near(hi.y, 0.75, 1e-9), "zoom2: hi.y == 0.75")

    let mid = clampedCenter(center: CGPoint(x: 0.5, y: 0.5), zoom: 2, photoPixelSize: photoSize, quarterTurns: 0, cellSize: cellSize)
    check(near(mid.x, 0.5, 1e-9), "zoom2: mid.x unchanged")
    check(near(mid.y, 0.5, 1e-9), "zoom2: mid.y unchanged")
}

// =====================================================================
// quarterTurns swapping effective dimensions
// =====================================================================
do {
    let cellSize = CGSize(width: 200, height: 200)
    let photoSize = CGSize(width: 2400, height: 1600) // odd turn -> effective 1600x2400

    let lo = clampedCenter(center: CGPoint(x: 0, y: 0), zoom: 1, photoPixelSize: photoSize, quarterTurns: 1, cellSize: cellSize)
    check(near(lo.x, 0.5, 1e-9), "quarterTurns=1: hx >= 0.5 forces x == 0.5")
    check(near(lo.y, 1.0 / 3.0, 1e-9), "quarterTurns=1: lo.y == 1/3")

    let hi = clampedCenter(center: CGPoint(x: 1, y: 1), zoom: 1, photoPixelSize: photoSize, quarterTurns: 1, cellSize: cellSize)
    check(near(hi.x, 0.5, 1e-9), "quarterTurns=1: hi.x still forced 0.5")
    check(near(hi.y, 2.0 / 3.0, 1e-9), "quarterTurns=1: hi.y == 2/3")
}

// =====================================================================
// clampedZoom bounds
// =====================================================================
do {
    check(near(clampedZoom(0.5), 1.0, 1e-9), "clampedZoom: below floor -> 1.0")
    check(near(clampedZoom(10.0), 8.0, 1e-9), "clampedZoom: above ceiling -> 8.0")
    check(near(clampedZoom(3.0), 3.0, 1e-9), "clampedZoom: in range unchanged")
    check(near(clampedZoom(1.0), 1.0, 1e-9), "clampedZoom: floor boundary unchanged")
    check(near(clampedZoom(8.0), 8.0, 1e-9), "clampedZoom: ceiling boundary unchanged")
}

// =====================================================================
// reclampAll idempotence + correctness
// =====================================================================
do {
    let p1 = PhotoID()
    let p2 = PhotoID()
    let root = Node.split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(p1), .leaf(p2)])
    var photos: [PhotoID: PhotoRef] = [:]
    photos[p1] = makePhoto(w: 2400, h: 1600, zoom: 1, center: CGPoint(x: 0, y: 0))
    photos[p2] = makePhoto(w: 1000, h: 1000, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
    let doc = Document(canvasRatio: .square, root: root, photos: photos, border: .none)
    let canvasSize = CGSize(width: 300, height: 300)

    let once = reclampAll(doc, canvasSize: canvasSize)
    let twice = reclampAll(once, canvasSize: canvasSize)
    check(once == twice, "reclampAll: idempotent (once == twice)")

    // cellA (p1's cell): width 150, height 300 (border zero, horizontal 2-way split of 300x300).
    // s0 = max(150/2400, 300/1600) = 0.1875; hx = 1/6; hy >= 0.5 -> forced 0.5.
    let clampedP1 = once.photos[p1]!
    check(near(clampedP1.center.x, 1.0 / 6.0, 1e-9), "reclampAll: p1.center.x correctly clamped")
    check(near(clampedP1.center.y, 0.5, 1e-9), "reclampAll: p1.center.y forced to 0.5")
}

// =====================================================================
// splitLeaf
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    let split1 = splitLeaf(id: a, newPhoto: b, axis: .vertical, in: .leaf(a))
    check(node(at: [0], in: split1) == .leaf(a), "splitLeaf: slot 0 == original leaf")
    check(node(at: [1], in: split1) == .leaf(b), "splitLeaf: slot 1 == new leaf")
    if case .split(_, let fractions, _) = split1 {
        check(near(fractions.reduce(0, +), 1.0, 1e-9), "splitLeaf: fractions sum to 1")
    } else {
        check(false, "splitLeaf: result is a split")
    }

    // Nested: split leaf b inside a 2-leaf tree, leaf a must be untouched.
    let c = PhotoID()
    let tree = Node.split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(a), .leaf(b)])
    let split2 = splitLeaf(id: b, newPhoto: c, axis: .vertical, in: tree)
    check(node(at: [0], in: split2) == .leaf(a), "splitLeaf nested: leaf a untouched")
    check(node(at: [1, 0], in: split2) == .leaf(b), "splitLeaf nested: leaf b relocated to [1,0]")
    check(node(at: [1, 1], in: split2) == .leaf(c), "splitLeaf nested: new leaf c at [1,1]")
}

// =====================================================================
// removeLeaf
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    let c = PhotoID()

    // 2-child split collapses to the sibling directly.
    let twoLeaf = Node.split(axis: .horizontal, fractions: [0.4, 0.6], children: [.leaf(a), .leaf(b)])
    check(removeLeaf(id: a, from: twoLeaf) == .leaf(b), "removeLeaf: 2-child collapses to sibling leaf")

    // 3-way split: remove middle, renormalize survivors.
    let threeWay = Node.split(axis: .horizontal, fractions: [0.2, 0.3, 0.5], children: [.leaf(a), .leaf(b), .leaf(c)])
    if let reduced = removeLeaf(id: b, from: threeWay), case .split(_, let fr, let children) = reduced {
        check(children.count == 2, "removeLeaf 3-way: two children remain")
        check(children[0] == .leaf(a) && children[1] == .leaf(c), "removeLeaf 3-way: correct surviving children")
        check(near(fr[0], 0.2 / 0.7, 1e-9), "removeLeaf 3-way: renormalized f0")
        check(near(fr[1], 0.5 / 0.7, 1e-9), "removeLeaf 3-way: renormalized f1")
    } else {
        check(false, "removeLeaf 3-way: expected a split result")
    }

    // Nested collapse: removing the last-but-one leaf collapses the inner
    // split down to its sole surviving child, leaving the outer split's
    // own fractions untouched.
    let nested = Node.split(
        axis: .horizontal, fractions: [0.5, 0.5],
        children: [.leaf(a), .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(b), .leaf(c)])]
    )
    if let reducedNested = removeLeaf(id: b, from: nested) {
        check(node(at: [0], in: reducedNested) == .leaf(a), "removeLeaf nested: leaf a untouched")
        check(node(at: [1], in: reducedNested) == .leaf(c), "removeLeaf nested: inner split collapsed to leaf c")
        if case .split(_, let fr, _) = reducedNested {
            check(near(fr[0], 0.5, 1e-9) && near(fr[1], 0.5, 1e-9), "removeLeaf nested: outer fractions untouched")
        }
    } else {
        check(false, "removeLeaf nested: expected non-nil result")
    }

    // Removing the sole remaining leaf at the root returns nil.
    check(removeLeaf(id: a, from: .leaf(a)) == nil, "removeLeaf: sole root leaf -> nil")
}

// =====================================================================
// Phase 4 - removeLeaf(_:from:) (EditOps.swift) - the "id not found -> nil"
// wrapper over Operations.swift's removeLeaf(id:from:), plus invariant
// checks on every non-nil result.
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    let c = PhotoID()
    let ghost = PhotoID() // never inserted into any tree below

    // Remove middle child of a 3-way: fractions renormalize proportionally.
    let threeWay = Node.split(axis: .horizontal, fractions: [0.2, 0.3, 0.5], children: [.leaf(a), .leaf(b), .leaf(c)])
    if let reduced = removeLeaf(b, from: threeWay), case .split(_, let fr, let children) = reduced {
        check(children.count == 2, "EditOps removeLeaf 3-way: two children remain")
        check(children[0] == .leaf(a) && children[1] == .leaf(c), "EditOps removeLeaf 3-way: correct survivors")
        check(near(fr[0], 0.2 / 0.7, 1e-9), "EditOps removeLeaf 3-way: renormalized f0")
        check(near(fr[1], 0.5 / 0.7, 1e-9), "EditOps removeLeaf 3-way: renormalized f1")
        check(isValidTree(reduced), "EditOps removeLeaf 3-way: result satisfies tree invariants")
    } else {
        check(false, "EditOps removeLeaf 3-way: expected a split result")
    }

    // Remove from a 2-way: returns the sibling subtree directly.
    let twoWay = Node.split(axis: .horizontal, fractions: [0.4, 0.6], children: [.leaf(a), .leaf(b)])
    let removedTwoWay = removeLeaf(a, from: twoWay)
    check(removedTwoWay == .leaf(b), "EditOps removeLeaf 2-way: returns sibling leaf")
    if let removedTwoWay { check(isValidTree(removedTwoWay), "EditOps removeLeaf 2-way: result satisfies invariants") }

    // Remove a leaf nested 2 deep: single-child collapse cascades up.
    let nested = Node.split(
        axis: .horizontal, fractions: [0.5, 0.5],
        children: [.leaf(a), .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(b), .leaf(c)])]
    )
    if let reducedNested = removeLeaf(b, from: nested) {
        check(node(at: [0], in: reducedNested) == .leaf(a), "EditOps removeLeaf nested: leaf a untouched")
        check(node(at: [1], in: reducedNested) == .leaf(c), "EditOps removeLeaf nested: inner split collapsed to leaf c")
        check(isValidTree(reducedNested), "EditOps removeLeaf nested: result satisfies invariants")
    } else {
        check(false, "EditOps removeLeaf nested: expected non-nil result")
    }

    // Remove a nonexistent id -> nil (the behavior Operations.swift's own
    // removeLeaf(id:from:) does NOT provide - it returns the tree unchanged).
    check(removeLeaf(ghost, from: threeWay) == nil, "EditOps removeLeaf: nonexistent id -> nil")
    check(removeLeaf(ghost, from: .leaf(a)) == nil, "EditOps removeLeaf: nonexistent id on a lone leaf -> nil")

    // Sole-root-leaf removal still returns nil, matching the wrapped function.
    check(removeLeaf(a, from: .leaf(a)) == nil, "EditOps removeLeaf: sole root leaf -> nil")

    // Invariants hold on every non-nil result produced above (belt-and-braces
    // re-check via the standalone helper, not just inline above).
    check(isValidTree(threeWay), "EditOps removeLeaf: original 3-way tree itself is valid (sanity)")

    // isValidTree actually catches violations too, not just a rubber stamp.
    let belowFloor = Node.split(axis: .horizontal, fractions: [0.05, 0.95], children: [.leaf(a), .leaf(b)])
    check(isValidTree(belowFloor) == false, "isValidTree: catches a fraction below the 0.10 floor")
    let badSum = Node.split(axis: .horizontal, fractions: [0.3, 0.3], children: [.leaf(a), .leaf(b)])
    check(isValidTree(badSum) == false, "isValidTree: catches fractions not summing to 1")
    check(isValidTree(.leaf(a)) == true, "isValidTree: a lone leaf is trivially valid")
}

// =====================================================================
// Codable round trip of a full Document
// =====================================================================
do {
    let a = PhotoID()
    let b = PhotoID()
    var photos: [PhotoID: PhotoRef] = [:]
    photos[a] = makePhoto(w: 3000, h: 2000, zoom: 1.5, center: CGPoint(x: 0.4, y: 0.6), roi: ROI(center: CGPoint(x: 0.5, y: 0.4), zoom: 1.2))
    photos[b] = makePhoto(w: 1200, h: 1800, zoom: 2.0, quarterTurns: 3)
    let root = Node.split(axis: .horizontal, fractions: [0.45, 0.55], children: [.leaf(a), .leaf(b)])
    let border = BorderStyle(inner: 0.01, outer: 0.03, linked: false, cornerRadius: 0.02, color: RGBA(r: 0.1, g: 0.2, b: 0.3, a: 1))
    let doc = Document(canvasRatio: Ratio(width: 4, height: 5), root: root, photos: photos, border: border)

    do {
        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(Document.self, from: encoded)
        check(decoded == doc, "Codable: decoded Document == original")
        check(decoded.photos.count == doc.photos.count, "Codable: photos count preserved")
        check(decoded.root == doc.root, "Codable: root tree preserved")
    } catch {
        check(false, "Codable: round trip threw \(error)")
    }
}

// =====================================================================
// Export cap at 4096
// =====================================================================
do {
    let id = PhotoID()
    let doc = Document(
        canvasRatio: .square,
        root: .leaf(id),
        photos: [id: makePhoto(w: 20000, h: 20000, zoom: 1)],
        border: .none
    )
    let size = exportPixelSize(doc: doc, canvasUnits: CGSize(width: 100, height: 100))
    check(near(size.width, 4096, 0.5), "export cap: width == 4096")
    check(near(size.height, 4096, 0.5), "export cap: height == 4096")
}

// =====================================================================
// Phase 3 - Templates: counts and leaf orders
// =====================================================================
func leafList(_ node: Node) -> [PhotoID] {
    switch node {
    case .leaf(let id): return [id]
    case .split(_, _, let children): return children.flatMap { leafList($0) }
    }
}

do {
    let ids2 = (0..<2).map { _ in PhotoID() }
    let ids3 = (0..<3).map { _ in PhotoID() }
    let ids4 = (0..<4).map { _ in PhotoID() }

    let t2 = templates(for: ids2)
    check(t2.count == 2, "templates: 2-photo count == 2")
    check(leafList(t2[0]) == ids2, "templates: 2-photo[0] (side-by-side) leaf order")
    check(leafList(t2[1]) == ids2, "templates: 2-photo[1] (stacked) leaf order")
    if case .split(let axis0, let f0, _) = t2[0] {
        check(axis0 == .horizontal, "templates: 2-photo[0] axis horizontal")
        check(f0 == [0.5, 0.5], "templates: 2-photo[0] fractions 50/50")
    } else { check(false, "templates: 2-photo[0] is a split") }
    if case .split(let axis1, _, _) = t2[1] {
        check(axis1 == .vertical, "templates: 2-photo[1] axis vertical")
    } else { check(false, "templates: 2-photo[1] is a split") }

    let t3 = templates(for: ids3)
    check(t3.count == 6, "templates: 3-photo count == 6")
    for (i, t) in t3.enumerated() {
        check(leafList(t) == ids3, "templates: 3-photo[\(i)] leaf order preserved")
    }
    if case .split(let axis, let f, let children) = t3[2] {
        check(axis == .horizontal, "templates: 3-photo[2] big-left axis horizontal")
        check(f == [0.6, 0.4], "templates: 3-photo[2] big-left fractions")
        check(children[0] == .leaf(ids3[0]), "templates: 3-photo[2] big-left slot0 is leaf")
        if case .split(let innerAxis, let innerF, _) = children[1] {
            check(innerAxis == .vertical, "templates: 3-photo[2] right column vertical")
            check(innerF == [0.5, 0.5], "templates: 3-photo[2] right column 50/50")
        } else { check(false, "templates: 3-photo[2] right side is a split") }
    } else { check(false, "templates: 3-photo[2] is a split") }
    // Mirror check: index 3 swaps the big cell to the right.
    if case .split(_, let f3, let children3) = t3[3] {
        check(f3 == [0.4, 0.6], "templates: 3-photo[3] mirror fractions")
        check(children3[1] == .leaf(ids3[2]), "templates: 3-photo[3] big cell on the right")
    } else { check(false, "templates: 3-photo[3] is a split") }

    let t4 = templates(for: ids4)
    check(t4.count == 8, "templates: 4-photo count == 8")
    for (i, t) in t4.enumerated() {
        check(leafList(t) == ids4, "templates: 4-photo[\(i)] leaf order preserved")
    }
    if case .split(let axis, let f, let children) = t4[0] {
        check(axis == .horizontal, "templates: 4-photo[0] 2x2 outer axis horizontal")
        check(f == [0.5, 0.5], "templates: 4-photo[0] 2x2 outer fractions")
        check(children.count == 2, "templates: 4-photo[0] 2x2 has 2 columns")
    } else { check(false, "templates: 4-photo[0] is a split") }
    if case .split(let axis, let f, let children) = t4[7] {
        check(axis == .horizontal, "templates: 4-photo[7] sandwich axis horizontal")
        check(f == [0.3, 0.4, 0.3], "templates: 4-photo[7] sandwich fractions")
        check(children[0] == .leaf(ids4[0]), "templates: 4-photo[7] sandwich left leaf")
        check(children[2] == .leaf(ids4[3]), "templates: 4-photo[7] sandwich right leaf")
        if case .split(_, let innerF, _) = children[1] {
            check(innerF == [0.5, 0.5], "templates: 4-photo[7] sandwich middle 50/50")
        } else { check(false, "templates: 4-photo[7] sandwich middle is a split") }
    } else { check(false, "templates: 4-photo[7] is a split") }
}

// =====================================================================
// Phase 3 - defaultTemplateIndex: orientation-aware default
// =====================================================================
do {
    check(defaultTemplateIndex(orientations: [
        CGSize(width: 1, height: 1), CGSize(width: 2, height: 3),
        CGSize(width: 3, height: 4), CGSize(width: 1, height: 2)
    ]) == 0, "defaultTemplateIndex: 4 photos always -> 2x2 (index 0)")

    check(defaultTemplateIndex(orientations: [
        CGSize(width: 3, height: 4), CGSize(width: 2, height: 3)
    ]) == 0, "defaultTemplateIndex: 2 portrait -> columns (0)")

    check(defaultTemplateIndex(orientations: [
        CGSize(width: 4, height: 3), CGSize(width: 16, height: 9)
    ]) == 1, "defaultTemplateIndex: 2 landscape -> rows (1)")

    check(defaultTemplateIndex(orientations: [
        CGSize(width: 3, height: 4), CGSize(width: 4, height: 3)
    ]) == 0, "defaultTemplateIndex: 2-way tie -> columns (0)")

    check(defaultTemplateIndex(orientations: [
        CGSize(width: 3, height: 4), CGSize(width: 1, height: 1), CGSize(width: 16, height: 9)
    ]) == 0, "defaultTemplateIndex: 3 majority portrait/square -> columns (0)")

    check(defaultTemplateIndex(orientations: [
        CGSize(width: 16, height: 9), CGSize(width: 4, height: 3), CGSize(width: 3, height: 4)
    ]) == 1, "defaultTemplateIndex: 3 majority landscape -> rows (1)")
}

// =====================================================================
// Phase 3 - contentFitAssignment: brute-force cost minimization
// =====================================================================
do {
    let portrait = PhotoID()
    let landscape = PhotoID()
    let fourFive = PhotoID()
    // Deliberately NOT already optimal: the template's original order puts
    // fourFive at big-left, landscape at top-right, portrait at bottom-right.
    let ids = [fourFive, landscape, portrait]
    let template = templates(for: ids)[2] // big-left+2-stacked-right
    let canvasSize = CGSize(width: 1000, height: 1000)
    let sizes: [PhotoID: CGSize] = [
        portrait: CGSize(width: 900, height: 1600),   // aspect 0.5625 (9:16)
        landscape: CGSize(width: 1600, height: 900),  // aspect 1.778 (16:9)
        fourFive: CGSize(width: 800, height: 1000)     // aspect 0.8 (4:5) - exact match for the right-column cells
    ]

    let result = contentFitAssignment(photoSizes: sizes, template: template, canvasSize: canvasSize, border: .none)
    let resultLeaves = leafList(result)
    check(resultLeaves[0] == portrait, "contentFitAssignment: 9:16 portrait lands in the tall big-left slot")
    check(Set(resultLeaves[1...2]) == Set([landscape, fourFive]), "contentFitAssignment: remaining photos fill the equal-aspect right slots")

    // Manual cost check (cost = sum |log(photoAspect) - log(cellAspect)|) for
    // a handful of permutations, derived from the template's own solved rects
    // rather than hardcoded numbers.
    let (cellsForCost, _) = solve(root: template, canvasSize: canvasSize, border: .none)
    let cellAspectByID = Dictionary(uniqueKeysWithValues: cellsForCost.map { ($0.id, Double($0.rect.width) / Double($0.rect.height)) })
    func manualCost(_ order: [PhotoID]) -> Double {
        zip(order, ids).reduce(0) { acc, pair in
            let (photoID, slotOriginalID) = pair
            let photoAspect = Double(sizes[photoID]!.width) / Double(sizes[photoID]!.height)
            let cellAspect = cellAspectByID[slotOriginalID]!
            return acc + abs(log(photoAspect) - log(cellAspect))
        }
    }
    let identityCost = manualCost([fourFive, landscape, portrait])
    let winningCost = manualCost([portrait, fourFive, landscape])
    let worstCost = manualCost([landscape, fourFive, portrait])
    check(winningCost < identityCost, "contentFitAssignment: winning permutation beats identity")
    check(winningCost < worstCost, "contentFitAssignment: winning permutation beats landscape-at-big-left")
    check(near(winningCost, abs(log(0.5625) - log(0.6)) + abs(log(1600.0 / 900.0) - log(0.8)), 1e-3), "contentFitAssignment: winning cost matches hand-computed value")
}

// =====================================================================
// Phase 3 - autoFrame: PRD-locked auto-framing anchors
// =====================================================================
do {
    // Anchor A: no faces, no saliency -> nil.
    let inputA = AutoFrameInput(
        faces: [], faceConfidences: [],
        salientRegion: nil,
        photoPixelSize: CGSize(width: 2400, height: 1600),
        cellSize: CGSize(width: 200, height: 200)
    )
    check(autoFrame(inputA) == nil, "autoFrame A: no faces/no saliency -> nil")
}

do {
    // Anchor B: saliency-only zoom. Low-res source (2400x1600) caps zoom at 1.0.
    let box = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6)
    let inputB1 = AutoFrameInput(
        faces: [], faceConfidences: [],
        salientRegion: box,
        photoPixelSize: CGSize(width: 2400, height: 1600),
        cellSize: CGSize(width: 200, height: 200)
    )
    let roiB1 = autoFrame(inputB1)
    check(roiB1 != nil, "autoFrame B1: saliency present -> non-nil")
    if let roi = roiB1 {
        check(near(roi.zoom, 1.0, 1e-9), "autoFrame B1: 2400x1600 source caps zoom at 1.0")
    }

    // Same saliency box at 2x resolution (4800x3200) -> reaches the 1.25 target.
    let inputB2 = AutoFrameInput(
        faces: [], faceConfidences: [],
        salientRegion: box,
        photoPixelSize: CGSize(width: 4800, height: 3200),
        cellSize: CGSize(width: 200, height: 200)
    )
    let roiB2 = autoFrame(inputB2)
    check(roiB2 != nil, "autoFrame B2: saliency present -> non-nil")
    if let roi = roiB2 {
        check(near(roi.zoom, 1.25, 1e-9), "autoFrame B2: 4800x3200 source reaches zoom 1.25")
    }
}

do {
    // Anchor C: a surviving face, no saliency. The face union (+ margin)
    // occupies only ~3.4% of the frame at zoom 1.0, well under
    // `minMustKeepAreaCoverage` (0.40) - Step 3.5's new tightening zooms in
    // to close that gap, bounded here by the resolution guard (guardCap ==
    // 1.5625 for this 4800x3200 source at this cellSize, which is tighter
    // than both the no-clip bound (40/9) and the 2.0x ceiling). This
    // replaces the old "zoom stays 1.0" anchor - that was exactly the B32
    // set12 bug (a face-only photo with no saliency box never zoomed past
    // 1.0 no matter how tiny the face was); center.y no longer hits the
    // hy>=0.5 forced-0.5 branch either, since hy shrinks below 0.5 once
    // zoom exceeds 1.0, and instead is a genuine clamp up from 0.307 to 0.32.
    let inputC = AutoFrameInput(
        faces: [CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.15)],
        faceConfidences: [0.9],
        salientRegion: nil,
        photoPixelSize: CGSize(width: 4800, height: 3200),
        cellSize: CGSize(width: 200, height: 200)
    )
    let roiC = autoFrame(inputC)
    check(roiC != nil, "autoFrame C: surviving face -> non-nil")
    if let roi = roiC {
        check(near(roi.zoom, 1.5625, 1e-9), "autoFrame C: zoom tightens to 1.5625 (resolution-guard-capped) toward the 40% must-keep-area target")
        check(near(roi.center.x, 0.45, 1e-9), "autoFrame C: center.x == 0.45")
        check(near(roi.center.y, 0.32, 1e-9), "autoFrame C: center.y clamps up to 0.32 at the new tighter zoom")
    }
}

do {
    // Anchor D: tiny face (pixel height below the 0.08 * short-edge floor) is
    // discarded; with no saliency either, autoFrame falls through to nil.
    let inputD = AutoFrameInput(
        faces: [CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.05)],
        faceConfidences: [0.9],
        salientRegion: nil,
        photoPixelSize: CGSize(width: 2400, height: 1600),
        cellSize: CGSize(width: 200, height: 200)
    )
    check(autoFrame(inputD) == nil, "autoFrame D: tiny face discarded -> nil")
}

do {
    // Anchor E (2026-07-29 fix): the resolution guard must be judged against
    // the ORIGINAL source's pixel dimensions, not the (possibly-capped)
    // decoding proxy - `AutoFrameInput.sourcePixelSize`. A small saliency box
    // (near-instant coverage -> zoomTarget clamps to the 2.0 ceiling well
    // above any guardCap this test can produce) isolates the guard itself:
    // whatever `finalZoom` comes out to IS the guard's cap.
    let box = CGRect(x: 0.495, y: 0.495, width: 0.01, height: 0.01)
    let photoPixelSize = CGSize(width: 1000, height: 1200) // portrait proxy
    let cellSize = CGSize(width: 100, height: 140)

    // No sourcePixelSize supplied (nil default): the guard falls back to the
    // small proxy alone, exactly today's (pre-fix) behavior - a 1000x1200
    // proxy caps zoom at 1.0 regardless of what the real photo could support.
    let inputE0 = AutoFrameInput(
        faces: [], faceConfidences: [],
        salientRegion: box,
        photoPixelSize: photoPixelSize,
        cellSize: cellSize
    )
    if let roi = autoFrame(inputE0) {
        check(near(roi.zoom, 1.0, 1e-9), "autoFrame E0: no sourcePixelSize -> guard still judged against the small proxy (zoom 1.0)")
    } else {
        check(false, "autoFrame E0: expected non-nil ROI")
    }

    // A 3x-larger ORIGINAL (3000x3600, same portrait orientation as the
    // proxy) raises the guard's cap well past 1.0 - this is the actual bug
    // fix: a photo that measured as low-res via the proxy alone can now
    // zoom, because export renders from this original, not the proxy.
    let inputE1 = AutoFrameInput(
        faces: [], faceConfidences: [],
        salientRegion: box,
        photoPixelSize: photoPixelSize,
        sourcePixelSize: CGSize(width: 3000, height: 3600),
        cellSize: cellSize
    )
    if let roi = autoFrame(inputE1) {
        check(near(roi.zoom, 1.255580357142857, 1e-6), "autoFrame E1: correctly-oriented sourcePixelSize raises the guard cap to ~1.2556")
    } else {
        check(false, "autoFrame E1: expected non-nil ROI")
    }

    // ORIENTATION HAZARD: the SAME original asset, but its dimensions arrive
    // swapped (3600x3000, reading as LANDSCAPE) against the proxy's portrait
    // orientation - exactly what `PHAsset.pixelWidth`/`pixelHeight` can do
    // for a rotated photo. Un-swapped, this pairs the guard's width fraction
    // against the wrong (bigger) axis and produces a HIGHER, unsafe cap
    // (~1.4648 - hand-verified against this same math) - i.e. a portrait
    // photo would be allowed to zoom in further than its real short edge
    // supports. `autoFrame` must detect the mismatched orientation and
    // correct it, landing on the EXACT SAME ~1.2556 as the correctly-
    // oriented E1 case above, not the higher unswapped value.
    let inputF = AutoFrameInput(
        faces: [], faceConfidences: [],
        salientRegion: box,
        photoPixelSize: photoPixelSize,
        sourcePixelSize: CGSize(width: 3600, height: 3000),
        cellSize: cellSize
    )
    if let roi = autoFrame(inputF) {
        check(near(roi.zoom, 1.255580357142857, 1e-6), "autoFrame F: orientation-mismatched sourcePixelSize is corrected before use (matches E1, not the ~1.4648 unswapped value)")
    } else {
        check(false, "autoFrame F: expected non-nil ROI")
    }
}

// =====================================================================
// Phase 5 - ExportPlan: requiredThumbnailMaxPixelSize / exportCellPlans
// =====================================================================
do {
    // Cell exactly matches image aspect, zoom 1: needs decode == cell's own
    // pixel span (no more, no less) - the "never decode 48MP for an 800px
    // cell" case.
    let size1 = requiredThumbnailMaxPixelSize(
        cellSize: CGSize(width: 800, height: 600),
        photoPixelWidth: 4000, photoPixelHeight: 3000,
        quarterTurns: 0, zoom: 1.0
    )
    check(size1 == 800, "ExportPlan: matching-aspect zoom-1 needs decode == 800 (cell span, not 4000 native)")

    // Doubling the cell size doubles the required decode.
    let size2 = requiredThumbnailMaxPixelSize(
        cellSize: CGSize(width: 1600, height: 1200),
        photoPixelWidth: 4000, photoPixelHeight: 3000,
        quarterTurns: 0, zoom: 1.0
    )
    check(size2 == 1600, "ExportPlan: doubled cell doubles required decode size")

    // Clamped: never exceeds the source's own native max dimension, even if
    // the math would ask for more (e.g. a huge cell against a tiny photo).
    let size3 = requiredThumbnailMaxPixelSize(
        cellSize: CGSize(width: 5000, height: 5000),
        photoPixelWidth: 400, photoPixelHeight: 400,
        quarterTurns: 0, zoom: 1.0
    )
    check(size3 == 400, "ExportPlan: decode target clamped to the source's own native max dimension")

    // Odd quarterTurns swap the effective axes used for the fill-scale
    // computation (mirrors clampedCenter/fillScale's own odd-turn handling).
    let size4 = requiredThumbnailMaxPixelSize(
        cellSize: CGSize(width: 600, height: 800),
        photoPixelWidth: 4000, photoPixelHeight: 3000,
        quarterTurns: 1, zoom: 1.0
    )
    check(size4 == 800, "ExportPlan: quarterTurns=1 uses the rotated (effective) aspect for fill-scale")

    // Zooming in (tighter crop) lowers the required decode - the visible
    // native region is smaller than at zoom 1.
    let size5 = requiredThumbnailMaxPixelSize(
        cellSize: CGSize(width: 800, height: 600),
        photoPixelWidth: 4000, photoPixelHeight: 3000,
        quarterTurns: 0, zoom: 2.0
    )
    check(size5 == 1600, "ExportPlan: zoom 2 doubles the decode target relative to zoom 1 (still well under native)")
}

do {
    // exportCellPlans: solves directly at export size and pairs each cell
    // with its decode target - a 2-up document at a concrete export size.
    let a = PhotoID()
    let b = PhotoID()
    let root = Node.split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(a), .leaf(b)])
    var photos: [PhotoID: PhotoRef] = [:]
    photos[a] = makePhoto(w: 4000, h: 4000, zoom: 1)
    photos[b] = makePhoto(w: 4000, h: 4000, zoom: 1)
    let doc = Document(canvasRatio: .square, root: root, photos: photos, border: .none)
    let exportSize = CGSize(width: 2000, height: 1000)

    let plans = exportCellPlans(doc: doc, exportSize: exportSize)
    check(plans.count == 2, "exportCellPlans: one plan per photo cell")
    if let planA = plans.first(where: { $0.id == a }) {
        check(near(Double(planA.rect.width), 1000, 0.5), "exportCellPlans: cellA rect matches solve() at export size")
        check(planA.thumbnailMaxPixelSize == 1000, "exportCellPlans: cellA decode target matches its own cell span")
    } else {
        check(false, "exportCellPlans: expected a plan for photo a")
    }
}

// =====================================================================
// Phase 1 (B32 "Magic Layout") - mustKeepRegion: nil/empty edge cases,
// mirroring autoFrame's own nil contract and thresholds exactly.
// =====================================================================
do {
    check(mustKeepRegion(faces: [], faceConfidences: [], salientRegion: nil, photoPixelSize: CGSize(width: 2400, height: 1600)) == nil,
          "mustKeepRegion: no faces/no saliency -> nil")

    let salientBox = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)
    let salientOnly = mustKeepRegion(faces: [], faceConfidences: [], salientRegion: salientBox, photoPixelSize: CGSize(width: 2400, height: 1600))
    check(salientOnly == salientBox, "mustKeepRegion: no surviving faces -> falls back to salientRegion untouched")

    // Tiny face (pixel height below the 8%-of-short-edge floor, same as
    // autoFrame's Anchor D) is discarded; no saliency either -> nil.
    let tinyFaceOnly = mustKeepRegion(
        faces: [CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.05)],
        faceConfidences: [0.9],
        salientRegion: nil,
        photoPixelSize: CGSize(width: 2400, height: 1600)
    )
    check(tinyFaceOnly == nil, "mustKeepRegion: tiny face discarded, no saliency -> nil")

    // Low-confidence face (below 0.5) discarded even though it is otherwise
    // large enough.
    let lowConfidenceOnly = mustKeepRegion(
        faces: [CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.15)],
        faceConfidences: [0.3],
        salientRegion: nil,
        photoPixelSize: CGSize(width: 2400, height: 1600)
    )
    check(lowConfidenceOnly == nil, "mustKeepRegion: low-confidence face discarded, no saliency -> nil")
}

// =====================================================================
// Phase 1 - mustKeepRegion: margin math (interior, then clamped at the
// photo's own 0...1 edge).
// =====================================================================
do {
    // Interior face: margin (25% of the face's own extent, 0.2*0.25=0.05
    // each side) applies with no clamping.
    let interiorFace = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
    let region = mustKeepRegion(faces: [interiorFace], faceConfidences: [0.9], salientRegion: nil, photoPixelSize: CGSize(width: 2000, height: 2000))
    check(region != nil, "mustKeepRegion: one surviving face -> non-nil")
    if let region {
        check(near(region.minX, 0.25, 1e-9), "mustKeepRegion: interior face - left edge = face.minX - margin")
        check(near(region.minY, 0.25, 1e-9), "mustKeepRegion: interior face - top edge = face.minY - margin")
        check(near(region.maxX, 0.55, 1e-9), "mustKeepRegion: interior face - right edge = face.maxX + margin")
        check(near(region.maxY, 0.55, 1e-9), "mustKeepRegion: interior face - bottom edge = face.maxY + margin")
    }

    // Corner face: the same margin would push past the photo's 0...1
    // bounds on two sides - those sides clamp at the edge instead.
    let cornerFace = CGRect(x: 0.02, y: 0.02, width: 0.2, height: 0.2)
    let cornerRegion = mustKeepRegion(faces: [cornerFace], faceConfidences: [0.9], salientRegion: nil, photoPixelSize: CGSize(width: 2000, height: 2000))
    check(cornerRegion != nil, "mustKeepRegion: corner face -> non-nil")
    if let cornerRegion {
        check(near(cornerRegion.minX, 0.0, 1e-9), "mustKeepRegion: corner face - left margin clamped at the photo edge")
        check(near(cornerRegion.minY, 0.0, 1e-9), "mustKeepRegion: corner face - top margin clamped at the photo edge")
        check(near(cornerRegion.maxX, 0.27, 1e-9), "mustKeepRegion: corner face - right edge unaffected by clamping")
        check(near(cornerRegion.maxY, 0.27, 1e-9), "mustKeepRegion: corner face - bottom edge unaffected by clamping")
    }

    // Two faces union first, THEN margin - not margin-then-union.
    let faceA = CGRect(x: 0.1, y: 0.4, width: 0.1, height: 0.1)
    let faceB = CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.1)
    let twoFaceRegion = mustKeepRegion(faces: [faceA, faceB], faceConfidences: [0.9, 0.9], salientRegion: nil, photoPixelSize: CGSize(width: 2000, height: 2000))
    check(twoFaceRegion != nil, "mustKeepRegion: two surviving faces -> non-nil")
    if let twoFaceRegion {
        // Union of [0.1,0.4,0.1,0.1] and [0.6,0.4,0.1,0.1] is x:0.1...0.7, y:0.4...0.5
        // (width 0.6, height 0.1) - margin is 25% of THAT union's own extent
        // (0.15 in x, 0.025 in y), not of either face individually. The left
        // edge (0.1 - 0.15 = -0.05) falls outside the photo and clamps to 0.
        check(near(twoFaceRegion.minX, 0.0, 1e-9), "mustKeepRegion: two faces - union-then-margin left edge clamped")
        check(near(twoFaceRegion.maxX, 0.7 + 0.15, 1e-9), "mustKeepRegion: two faces - union-then-margin right edge")
        check(near(twoFaceRegion.minY, 0.4 - 0.025, 1e-9), "mustKeepRegion: two faces - union-then-margin top edge")
        check(near(twoFaceRegion.maxY, 0.5 + 0.025, 1e-9), "mustKeepRegion: two faces - union-then-margin bottom edge")
    }
}

// =====================================================================
// Phase 1 - framingCost: degenerate-input guards, ordering (a clipped
// cell must always cost more than a safe one), and determinism.
// =====================================================================
do {
    // Degenerate inputs return 0 rather than dividing by zero / crashing.
    check(near(framingCost(mustKeep: .zero, photoPixelSize: CGSize(width: 2000, height: 2000), cellSize: CGSize(width: 500, height: 500)), 0, 1e-9),
          "framingCost: zero-size mustKeep -> 0")
    check(near(framingCost(mustKeep: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), photoPixelSize: CGSize(width: 2000, height: 2000), cellSize: .zero), 0, 1e-9),
          "framingCost: zero cellSize -> 0")
    check(near(framingCost(mustKeep: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), photoPixelSize: .zero, cellSize: CGSize(width: 500, height: 500)), 0, 1e-9),
          "framingCost: zero photoPixelSize -> 0")

    // A tall, narrow must-keep region (a single portrait-oriented subject)
    // fits safely in a narrow cell but gets clipped by a wide one. Real
    // (canvas-point) cell sizes now, not bare aspect ratios - cellSize's
    // absolute magnitude matters as of the group-photo-cell-size rule (see
    // `framingCost`'s own doc comment), even though these two cells
    // happen to share a scale (500x1000 vs 1000x500) so this particular
    // pair of checks is unaffected by it.
    let tallNarrow = CGRect(x: 0.4, y: 0.2, width: 0.15, height: 0.6)
    let portraitPhoto = CGSize(width: 2000, height: 3000)
    let safeCost = framingCost(mustKeep: tallNarrow, photoPixelSize: portraitPhoto, cellSize: CGSize(width: 500, height: 1000))
    let clippedCost = framingCost(mustKeep: tallNarrow, photoPixelSize: portraitPhoto, cellSize: CGSize(width: 1000, height: 500))
    check(safeCost < 3, "framingCost: tall/narrow subject in a narrow cell scores low (no clip)")
    check(clippedCost > 10, "framingCost: tall/narrow subject in a wide cell scores high (clipped)")
    check(safeCost < clippedCost, "framingCost: the safe cell beats the clipping one")

    // Determinism: identical inputs, identical output, called twice.
    let repeat1 = framingCost(mustKeep: tallNarrow, photoPixelSize: portraitPhoto, cellSize: CGSize(width: 1000, height: 500))
    let repeat2 = framingCost(mustKeep: tallNarrow, photoPixelSize: portraitPhoto, cellSize: CGSize(width: 1000, height: 500))
    check(repeat1 == repeat2, "framingCost: identical inputs -> identical output (determinism)")
}

// =====================================================================
// Phase 1.5 (group-photo-cell-size rule) - `framingCost`'s new legibility
// term in isolation: the architectural fix (real cellSize, not just
// aspect) actually moving the cost with cell AREA, the term contributing
// exactly 0 when no face-height signal is given (degrade at the
// framingCost level, not just the higher-level guards), and a small face
// in a small cell costing strictly more than the SAME small face in a
// bigger cell of the SAME aspect.
// =====================================================================
do {
    // Same mustKeep/photo/aspect in every call - only cellSize's ABSOLUTE
    // magnitude changes (aspect held fixed at 1.0, a square cell). Before
    // this change this was PROVABLY impossible: a 4x canvas-AREA change
    // (500x500 -> 1000x1000, aspect held at 1.0) moved the old aspect-only
    // cost by 0.000000000000 - measured directly against the pre-change
    // `framingCost` while scoping this work.
    let smallGroupFace = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.15) // wide union, faces individually small
    let photoSize = CGSize(width: 3000, height: 2000)
    let smallestFace = 0.05 // 5% of the photo's own height - a small face in a 5-person group

    let costSmallCell = framingCost(
        mustKeep: smallGroupFace, photoPixelSize: photoSize,
        cellSize: CGSize(width: 500, height: 500), canvasShortEdge: 1000,
        smallestFaceHeightFraction: smallestFace
    )
    let costBigCell = framingCost(
        mustKeep: smallGroupFace, photoPixelSize: photoSize,
        cellSize: CGSize(width: 1000, height: 1000), canvasShortEdge: 1000,
        smallestFaceHeightFraction: smallestFace
    )
    check(costBigCell < costSmallCell, "framingCost: same face, same aspect, BIGGER cell costs strictly less (the group-photo rule's core claim)")

    // No face-height signal at all (the default, and what every caller
    // written before this parameter existed still passes) -> the
    // legibility term contributes exactly 0, so cost is identical to
    // whatever the pre-existing terms alone produce, regardless of
    // cellSize's magnitude. This is the degrade guarantee AT THE
    // framingCost LEVEL, one layer below `faceAwareAssignment`'s own guard.
    let noSignalSmall = framingCost(mustKeep: smallGroupFace, photoPixelSize: photoSize, cellSize: CGSize(width: 500, height: 500), canvasShortEdge: 1000)
    let noSignalBig = framingCost(mustKeep: smallGroupFace, photoPixelSize: photoSize, cellSize: CGSize(width: 1000, height: 1000), canvasShortEdge: 1000)
    check(near(noSignalSmall, noSignalBig, 1e-9), "framingCost: with no smallestFaceHeightFraction, cost is scale-invariant exactly as before (legibility term contributes 0)")

    // A selfie's one big face (60% of its own photo's height) clears the
    // legibility floor even in the smaller cell above - no legibility
    // penalty either size, so the two costs there must ALSO agree (the
    // "selfie not penalized in a small cell" acceptance case, at the
    // framingCost level).
    let selfieMustKeep = CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.6)
    let bigFace = 0.60
    let selfieCostSmallCell = framingCost(
        mustKeep: selfieMustKeep, photoPixelSize: CGSize(width: 2000, height: 2000),
        cellSize: CGSize(width: 500, height: 500), canvasShortEdge: 1000,
        smallestFaceHeightFraction: bigFace
    )
    let selfieCostNoSignalSmallCell = framingCost(
        mustKeep: selfieMustKeep, photoPixelSize: CGSize(width: 2000, height: 2000),
        cellSize: CGSize(width: 500, height: 500), canvasShortEdge: 1000
    )
    check(near(selfieCostSmallCell, selfieCostNoSignalSmallCell, 1e-9), "framingCost: a selfie's already-legible face adds ZERO legibility penalty even in a small cell")
}

// =====================================================================
// Phase 1 - faceAwareAssignment: the search entry point. Covers a
// clipped-vs-safe template pair, a group shot wanting a wider cell, a
// no-faces landscape set matching today's choice, determinism, and the
// degrade-to-today guarantee.
// =====================================================================
do {
    // A single tall/narrow subject: sideBySide's narrow columns (cell
    // aspect 0.5) keep it safe; stacked's wide rows (cell aspect 2.0) clip
    // it. The better template (sideBySide, index 0) must win.
    let subject = PhotoID()
    let neutral = PhotoID()
    let photos = [subject, neutral]
    let photoSizes: [PhotoID: CGSize] = [
        subject: CGSize(width: 2000, height: 3000),
        neutral: CGSize(width: 2000, height: 2000)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        subject: CGRect(x: 0.4, y: 0.2, width: 0.15, height: 0.6)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(result.templateIndex == 0, "faceAwareAssignment: clipped-vs-safe - the non-clipping template (sideBySide) wins")
    check(leafList(result.template) == photos, "faceAwareAssignment: clipped-vs-safe - single valid 2-way permutation preserved")
}

do {
    // A wide group shot (faces spread horizontally): stacked's wide rows
    // (cell aspect 2.0) keep it safe; sideBySide's narrow columns (cell
    // aspect 0.5) clip it. The better template (stacked, index 1) must win.
    let group = PhotoID()
    let neutral = PhotoID()
    let photos = [group, neutral]
    let photoSizes: [PhotoID: CGSize] = [
        group: CGSize(width: 3000, height: 2000),
        neutral: CGSize(width: 2000, height: 2000)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        group: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let result1 = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(result1.templateIndex == 1, "faceAwareAssignment: group shot - the wider template (stacked) wins")

    // Determinism: same inputs, called again, identical (template index,
    // resulting tree, AND cost) result.
    let result2 = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(result1.templateIndex == result2.templateIndex, "faceAwareAssignment: determinism - templateIndex repeats")
    check(result1.template == result2.template, "faceAwareAssignment: determinism - resulting tree repeats")
    check(near(result1.cost, result2.cost, 1e-12), "faceAwareAssignment: determinism - cost repeats")
}

do {
    // No must-keep region anywhere (a landscape set with no faces/saliency
    // survivors) must match EXACTLY what today's app flow already produces:
    // defaultTemplateIndex's orientation-based template, then
    // contentFitAssignment's permutation on it. This is the "strict
    // improvement, not a replacement" guarantee.
    let p1 = PhotoID()
    let p2 = PhotoID()
    let photos = [p1, p2]
    let photoSizes: [PhotoID: CGSize] = [
        p1: CGSize(width: 1920, height: 1080), // 16:9 landscape
        p2: CGSize(width: 1920, height: 1080)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let expectedTemplateIndex = defaultTemplateIndex(orientations: photos.map { photoSizes[$0]! })
    let expectedTemplate = contentFitAssignment(
        photoSizes: photoSizes,
        template: templates(for: photos)[expectedTemplateIndex],
        canvasSize: canvasSize,
        border: .none
    )

    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: [:], canvasSize: canvasSize, border: .none)
    check(result.templateIndex == expectedTemplateIndex, "faceAwareAssignment degrade: no-mustKeep landscape set picks the SAME template as today")
    check(result.template == expectedTemplate, "faceAwareAssignment degrade: no-mustKeep landscape set picks the SAME assignment as today")
}

do {
    // The degrade guarantee has to hold for ASYMMETRIC sets too, not just
    // the symmetric one above - two identical photos agree by coincidence,
    // because a symmetric set makes the orientation heuristic and the
    // aspect-cost argmin land on the same template anyway. Measured
    // 2026-07-28: before the explicit fallback guard in
    // `faceAwareAssignment`, THESE cases silently disagreed (wide+square,
    // 3-mixed and 4-mixed), which would have relaid out every faceless
    // collage in the app. Each case below is a no-mustKeep set that must
    // reproduce today's `defaultTemplateIndex` + `contentFitAssignment`
    // result exactly.
    let sets: [(String, [CGSize])] = [
        ("wide + square", [CGSize(width: 1920, height: 1080), CGSize(width: 1500, height: 1500)]),
        ("tall + wide", [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)]),
        ("3 mixed", [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 1500, height: 1500)]),
        ("4 mixed", [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 1500, height: 1500), CGSize(width: 1920, height: 1080)])
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)
    for (label, sizes) in sets {
        let ids = sizes.map { _ in PhotoID() }
        var photoSizes: [PhotoID: CGSize] = [:]
        for (i, id) in ids.enumerated() { photoSizes[id] = sizes[i] }

        let expectedIndex = defaultTemplateIndex(orientations: ids.map { photoSizes[$0]! })
        let expectedTemplate = contentFitAssignment(
            photoSizes: photoSizes,
            template: templates(for: ids)[expectedIndex],
            canvasSize: canvasSize,
            border: .none
        )
        let result = faceAwareAssignment(photos: ids, photoSizes: photoSizes, mustKeepRegions: [:], canvasSize: canvasSize, border: .none)
        check(result.templateIndex == expectedIndex, "faceAwareAssignment degrade (asymmetric): \(label) picks the SAME template as today")
        check(result.template == expectedTemplate, "faceAwareAssignment degrade (asymmetric): \(label) picks the SAME assignment as today")
    }
}

do {
    // Edge case: a 4-photo set where only ONE photo has a must-keep region
    // and the rest degrade to the aspect-only term, all in one search -
    // exercises the mixed mustKeep/no-mustKeep path through a bigger
    // template set (8 candidates instead of 2).
    let faced = PhotoID()
    let a = PhotoID()
    let b = PhotoID()
    let c = PhotoID()
    let photos = [faced, a, b, c]
    let photoSizes: [PhotoID: CGSize] = [
        faced: CGSize(width: 2000, height: 2000),
        a: CGSize(width: 2000, height: 2000),
        b: CGSize(width: 2000, height: 2000),
        c: CGSize(width: 2000, height: 2000)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        faced: CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.8) // tall subject
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)
    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(templates(for: photos).indices.contains(result.templateIndex), "faceAwareAssignment: 4-photo mixed set - templateIndex is a valid candidate index")
    check(Set(leafList(result.template)) == Set(photos), "faceAwareAssignment: 4-photo mixed set - every photo still placed exactly once")
    check(result.cost.isFinite, "faceAwareAssignment: 4-photo mixed set - cost is finite")
}

// =====================================================================
// Phase 2 - divider-fraction search: lets a template's own split fractions
// move coarsely (~0.3...0.7, per `Magic Layout Spec.md`'s Phase 2) so a
// cell can GROW to rescue a group shot Phase 1 could only crop. Covers: a
// clip Phase 1 alone cannot escape that Phase 2 rescues by resizing, the
// resulting fractions genuinely differing from the authored ones,
// determinism, bounds (every searched fraction stays >= minCellFraction
// and each split's fractions still sum to 1.0), the (unchanged) faceless
// degrade, and a bigger mixed-mustKeep case.
// =====================================================================

/// Reproduces `MagicLayout.swift`'s own (private, same-cost) per-template
/// permutation search using only PUBLIC engine pieces (`solve`,
/// `photoIDs(in:)`, `permutations`, `framingCost`, `aspect`,
/// `FramingCostWeight.aspect`) - same technique the existing degrade tests
/// already use to reconstruct "what today's flow produces" for comparison.
/// Gives the cost `template`'s AUTHORED fractions alone would have scored,
/// i.e. the Phase-1-only answer, to compare against Phase 2's result.
func referenceAuthoredCost(
    template: Node,
    photoSizes: [PhotoID: CGSize],
    mustKeepRegions: [PhotoID: CGRect],
    mustKeepFaceHeights: [PhotoID: Double] = [:],
    canvasSize: CGSize,
    border: BorderStyle
) -> Double {
    let originalOrder = photoIDs(in: template)
    let (cells, _) = solve(root: template, canvasSize: canvasSize, border: border)
    let cellByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })
    // Real cellSize, not just aspect - mirrors `MagicLayout.swift`'s own
    // (private) `bestPermutationAndCost` exactly, post-group-photo-cell-size
    // change, so this reference stays a faithful stand-in for "what the
    // AUTHORED fractions alone would score" rather than a stale one.
    let slotSizes: [CGSize] = originalOrder.map { id in cellByID[id]?.size ?? CGSize(width: 1, height: 1) }
    let canvasShortEdge = min(canvasSize.width, canvasSize.height)

    var bestCost = Double.infinity
    for perm in permutations(originalOrder) {
        var cost = 0.0
        for slot in 0..<perm.count {
            let photoID = perm[slot]
            let cellSize = slotSizes[slot]
            guard cellSize.width > 0, cellSize.height > 0 else { continue }
            if let mustKeep = mustKeepRegions[photoID] {
                let pixelSize = photoSizes[photoID] ?? CGSize(width: 1, height: 1)
                cost += framingCost(
                    mustKeep: mustKeep, photoPixelSize: pixelSize,
                    cellSize: cellSize, canvasShortEdge: canvasShortEdge,
                    smallestFaceHeightFraction: mustKeepFaceHeights[photoID]
                )
            } else {
                let cellAspect = aspect(cellSize)
                let photoAspect = aspect(photoSizes[photoID] ?? CGSize(width: 1, height: 1))
                guard photoAspect > 0, cellAspect > 0 else { continue }
                cost += FramingCostWeight.aspect * abs(log(photoAspect) - log(cellAspect))
            }
        }
        if cost < bestCost { bestCost = cost }
    }
    return bestCost
}

/// The fractions of `node` if it's a `.split`, else nil - lets a check fail
/// gracefully (via the `else` branch below) instead of crashing the whole
/// harness if a template ever turned out not to be a split (never expected
/// for 2...4 photos, but this keeps the test itself honest either way).
func splitFractions(_ node: Node) -> [Double]? {
    if case .split(_, let fractions, _) = node { return fractions }
    return nil
}

/// Every split node's fractions sum to 1.0 and no individual fraction is
/// below `Layout.minCellFraction` - the same invariant every OTHER
/// mutating operation on `Node` already has to uphold (see `Model.swift`).
/// Phase 2 is a new source of fraction values, so it needs its own check
/// that it never violates this.
func allFractionsValid(_ node: Node) -> Bool {
    switch node {
    case .leaf:
        return true
    case .split(_, let fractions, let children):
        guard near(fractions.reduce(0, +), 1.0, 1e-6) else { return false }
        guard fractions.allSatisfy({ $0 >= Layout.minCellFraction - 1e-9 }) else { return false }
        return children.allSatisfy(allFractionsValid)
    }
}

do {
    // Wide group shot (mustKeep aspect 3.0) alongside a neutral square
    // photo. At `stacked`'s AUTHORED 0.5/0.5 split the cell aspect is 2.0,
    // which the reference cost below confirms still clips this subject -
    // Phase 1 alone cannot escape this without switching templates, and
    // `sideBySide` clips far worse regardless (its columns can only reach
    // aspect ~0.7 at best, nowhere near what this subject needs). Phase 2
    // must find a NARROWER row for the neutral photo - growing the group's
    // own row instead - and remove the clip.
    let group = PhotoID()
    let neutral = PhotoID()
    let photos = [group, neutral]
    let photoSizes: [PhotoID: CGSize] = [
        group: CGSize(width: 3500, height: 1500),
        neutral: CGSize(width: 2000, height: 2000)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        group: CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.3)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let authoredStackedCost = referenceAuthoredCost(
        template: templates(for: photos)[1], // stacked
        photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none
    )
    check(authoredStackedCost > 2.0, "Phase 2 rescue: stacked's OWN authored fractions (cell aspect 2.0) still clip the group shot")

    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(result.templateIndex == 1, "Phase 2 rescue: stacked (already the better template) still wins")
    check(result.cost < authoredStackedCost, "Phase 2 rescue: the resized cell scores strictly better than the authored split")
    check(result.cost < 1.0, "Phase 2 rescue: the resized cell is no longer clipping (cost has dropped out of clip range)")

    if let fractions = splitFractions(result.template) {
        check(!near(fractions[0], 0.5, 0.01), "Phase 2 rescue: chosen fractions genuinely differ from the authored 0.5/0.5 split")
        check(fractions.allSatisfy { $0 >= Layout.minCellFraction - 1e-9 }, "Phase 2 rescue: searched fractions respect Layout.minCellFraction")
        check(near(fractions.reduce(0, +), 1.0), "Phase 2 rescue: searched fractions still sum to 1.0")
    } else {
        check(false, "Phase 2 rescue: winning template is a split node")
    }

    // Determinism: same inputs, called again, identical (template index,
    // resulting tree - fractions AND assignment - and cost).
    let result2 = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(result.templateIndex == result2.templateIndex, "Phase 2: determinism - templateIndex repeats")
    check(result.template == result2.template, "Phase 2: determinism - resulting tree (fractions + assignment) repeats")
    check(near(result.cost, result2.cost, 1e-12), "Phase 2: determinism - cost repeats")
}

do {
    // Explicit Phase 2 regression on the degrade guarantee: the guard in
    // `faceAwareAssignment` returns BEFORE Phase 2's divider search ever
    // runs, so a faceless set must not even increment the evaluation
    // counter, let alone produce a different template or assignment. This
    // is the same guard Phase 1's build log notes was broken once before
    // and caught late - this check pins it against Phase 2 specifically.
    let p1 = PhotoID()
    let p2 = PhotoID()
    let photos = [p1, p2]
    let photoSizes: [PhotoID: CGSize] = [
        p1: CGSize(width: 1920, height: 1080),
        p2: CGSize(width: 1920, height: 1080)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let evaluationsBefore = magicLayoutEvaluationCount
    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: [:], canvasSize: canvasSize, border: .none)
    check(magicLayoutEvaluationCount == evaluationsBefore, "Phase 2 regression: faceless degrade never enters the divider search (0 new evaluations)")

    let expectedTemplateIndex = defaultTemplateIndex(orientations: photos.map { photoSizes[$0]! })
    let expectedTemplate = contentFitAssignment(
        photoSizes: photoSizes,
        template: templates(for: photos)[expectedTemplateIndex],
        canvasSize: canvasSize,
        border: .none
    )
    check(result.templateIndex == expectedTemplateIndex, "Phase 2 regression: faceless degrade picks the SAME template as today")
    check(result.template == expectedTemplate, "Phase 2 regression: faceless degrade result stays byte-identical (fractions included)")
}

do {
    // A bigger, messier case: 4 photos, every one carrying its own
    // must-keep region (the worst case for the search - every template's
    // dividers are "hot"). Exercises bounds and general validity rather
    // than a specific expected template, since with four competing wide
    // and tall subjects there's no single obviously-correct answer - what
    // must hold is that the search still terminates with a valid, fully
    // assigned, in-range result.
    let a = PhotoID()
    let b = PhotoID()
    let c = PhotoID()
    let d = PhotoID()
    let photos = [a, b, c, d]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 3500, height: 1500),
        b: CGSize(width: 1500, height: 3500),
        c: CGSize(width: 2000, height: 2000),
        d: CGSize(width: 2800, height: 2100)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.3),
        b: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8),
        c: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        d: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.4)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(templates(for: photos).indices.contains(result.templateIndex), "Phase 2 (4-photo, all mustKeep): templateIndex is a valid candidate index")
    check(Set(leafList(result.template)) == Set(photos), "Phase 2 (4-photo, all mustKeep): every photo still placed exactly once")
    check(result.cost.isFinite, "Phase 2 (4-photo, all mustKeep): cost is finite")
    check(allFractionsValid(result.template), "Phase 2 (4-photo, all mustKeep): every searched fraction is in-range and every split still sums to 1.0")

    // Determinism holds for the bigger case too.
    let result2 = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, canvasSize: canvasSize, border: .none)
    check(result.template == result2.template, "Phase 2 (4-photo, all mustKeep): determinism - resulting tree repeats")
    check(near(result.cost, result2.cost, 1e-12), "Phase 2 (4-photo, all mustKeep): determinism - cost repeats")
}

// =====================================================================
// Phase 5 - `chooseCanvasAndLayout`: the outermost decision (canvas ratio)
// joining the Phase 1+2 search. Covers: an all-portrait set winning the
// portrait challenger, an all-landscape set (mirrored) winning the
// landscape challenger, a mixed set staying square, the override threshold
// actually biting (a real-but-marginal improvement that must still lose),
// sticky user preference overriding what the content rule would have
// nominated, the faceless degrade path (including the specific trap of an
// ALL-PORTRAIT faceless set, where the orientation rule alone would
// nominate a challenger but the degrade guard must fire first), and
// determinism (in-process repeat, plus a pinned golden value standing in
// for the cross-process check - see the Phase 5 build-log entry for the
// actual two-separate-processes run this was verified against).
// =====================================================================

do {
    // All portrait, DIFFERING sizes (the trap: a symmetric pair - two
    // identical photos - agrees by coincidence and can't tell a genuine
    // orientation decision from a fluke; see Phase 1's own build-log entry
    // for how that bit this project once already). A tall, narrow subject
    // (mustKeep width 0.20 of the frame) that a 4:5 canvas frames
    // noticeably better than square - clears the override threshold with
    // room to spare (verified below, not merely asserted).
    let a = PhotoID()
    let b = PhotoID()
    let photos = [a, b]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 1000, height: 2200),
        b: CGSize(width: 1100, height: 2000)
    ]
    let w = 0.20
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: (1 - w) / 2, y: 0.05, width: w, height: 0.9),
        b: CGRect(x: (1 - w) / 2 - 0.02, y: 0.05, width: w, height: 0.9)
    ]

    let result = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none)
    check(result.canvasRatio == portraitChallengerRatio, "Phase 5: all-portrait (differing sizes) picks the portrait challenger (4:5)")
    check(Set(leafList(result.template)) == Set(photos), "Phase 5: all-portrait - every photo still placed exactly once")
}

do {
    // Mirror of the case above (landscape instead of portrait), same
    // differing-sizes discipline.
    let a = PhotoID()
    let b = PhotoID()
    let photos = [a, b]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 2200, height: 1000),
        b: CGSize(width: 2000, height: 1100)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.2),
        b: CGRect(x: 0.05, y: 0.38, width: 0.9, height: 0.2)
    ]

    let result = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none)
    check(result.canvasRatio == landscapeChallengerRatio, "Phase 5: all-landscape (differing sizes) picks the landscape challenger (5:4)")
    check(Set(leafList(result.template)) == Set(photos), "Phase 5: all-landscape - every photo still placed exactly once")
}

do {
    // Mixed orientation (one portrait, one landscape), both carrying real
    // must-keep regions - `nominateChallengerRatio` must return nil here,
    // so the square default wins WITHOUT a second search ever running.
    let a = PhotoID()
    let b = PhotoID()
    let photos = [a, b]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 1000, height: 2200),
        b: CGSize(width: 2200, height: 1000)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.9),
        b: CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.2)
    ]

    check(nominateChallengerRatio(photos: photos, photoSizes: photoSizes) == nil, "Phase 5: mixed orientation - nominateChallengerRatio itself returns nil")
    let result = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none)
    check(result.canvasRatio == .square, "Phase 5: mixed orientation set stays square")
}

do {
    // The override threshold actually biting: a wider mustKeep (w=0.30,
    // vs the clear-win case's 0.20) that a 4:5 canvas STILL frames better
    // than square - genuinely better, not worse - but only marginally so.
    // Verified directly against both canvases (not just asserted) that the
    // improvement is real (> 0) yet falls short of
    // `canvasRatioOverrideThreshold * photos.count`, so the challenger must
    // still lose and the canvas must not churn for a marginal gain.
    let a = PhotoID()
    let b = PhotoID()
    let photos = [a, b]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 1000, height: 2200),
        b: CGSize(width: 1100, height: 2000)
    ]
    let w = 0.30
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: (1 - w) / 2, y: 0.05, width: w, height: 0.9),
        b: CGRect(x: (1 - w) / 2 - 0.02, y: 0.05, width: w, height: 0.9)
    ]

    check(nominateChallengerRatio(photos: photos, photoSizes: photoSizes) == portraitChallengerRatio, "Phase 5 threshold: this set still nominates the portrait challenger")

    let squareDecision = faceAwareAssignment(
        photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions,
        canvasSize: nominalCanvasSize(for: .square, shortEdge: defaultReferenceShortEdge), border: .none
    )
    let challengerDecision = faceAwareAssignment(
        photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions,
        canvasSize: nominalCanvasSize(for: portraitChallengerRatio, shortEdge: defaultReferenceShortEdge), border: .none
    )
    let improvement = squareDecision.cost - challengerDecision.cost
    check(improvement > 0, "Phase 5 threshold: the challenger genuinely IS better here (improvement > 0), not a strawman")
    check(improvement <= canvasRatioOverrideThreshold * Double(photos.count), "Phase 5 threshold: but the improvement falls short of the override bar")

    let result = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none)
    check(result.canvasRatio == .square, "Phase 5 threshold: a marginal improvement must NOT churn the canvas - square wins")
}

do {
    // Sticky user preference: an all-LANDSCAPE set (which would nominate
    // `landscapeChallengerRatio`, 5:4, on its own) but the caller passes an
    // explicit `userRatio` of `portraitChallengerRatio` (4:5) - the
    // opposite direction from what the content rule would have picked.
    // The result must carry the user's ratio UNCHANGED, proving this isn't
    // merely "returns some sensible default" but genuinely skips
    // nomination and the override threshold entirely.
    let a = PhotoID()
    let b = PhotoID()
    let photos = [a, b]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 2200, height: 1000),
        b: CGSize(width: 2000, height: 1100)
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.2),
        b: CGRect(x: 0.05, y: 0.38, width: 0.9, height: 0.2)
    ]
    check(nominateChallengerRatio(photos: photos, photoSizes: photoSizes) == landscapeChallengerRatio, "Phase 5 sticky: content rule alone would nominate landscape here")

    let result = chooseCanvasAndLayout(
        photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none,
        userRatio: portraitChallengerRatio
    )
    check(result.canvasRatio == portraitChallengerRatio, "Phase 5 sticky: user's hand-set ratio (4:5) is returned UNCHANGED, opposite of what content would have nominated")
    check(Set(leafList(result.template)) == Set(photos), "Phase 5 sticky: the layout search still ran (at the user's ratio) - every photo placed exactly once")
}

do {
    // Faceless degrade, ASYMMETRIC mixed-orientation sets (same discipline,
    // and the same reused sets, as the Phase 1 degrade-guarantee tests
    // above): with no must-keep region anywhere, `chooseCanvasAndLayout`
    // must match EXACTLY what today's app flow produces - square canvas,
    // `defaultTemplateIndex` + `contentFitAssignment` - for every one of
    // these, not just the symmetric case that agrees by coincidence.
    let sets: [(String, [CGSize])] = [
        ("wide + square", [CGSize(width: 1920, height: 1080), CGSize(width: 1500, height: 1500)]),
        ("tall + wide", [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)]),
        ("3 mixed", [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 1500, height: 1500)]),
        ("4 mixed", [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 1500, height: 1500), CGSize(width: 1920, height: 1080)])
    ]
    for (label, sizes) in sets {
        let ids = sizes.map { _ in PhotoID() }
        var photoSizes: [PhotoID: CGSize] = [:]
        for (i, id) in ids.enumerated() { photoSizes[id] = sizes[i] }

        let expectedIndex = defaultTemplateIndex(orientations: ids.map { photoSizes[$0]! })
        let expectedTemplate = contentFitAssignment(
            photoSizes: photoSizes,
            template: templates(for: ids)[expectedIndex],
            canvasSize: nominalCanvasSize(for: .square, shortEdge: defaultReferenceShortEdge),
            border: .none
        )
        let result = chooseCanvasAndLayout(photos: ids, photoSizes: photoSizes, mustKeepRegions: [:], border: .none)
        check(result.canvasRatio == .square, "Phase 5 degrade (asymmetric): \(label) stays square")
        check(result.templateIndex == expectedIndex, "Phase 5 degrade (asymmetric): \(label) picks the SAME template as today")
        check(result.template == expectedTemplate, "Phase 5 degrade (asymmetric): \(label) picks the SAME assignment as today")
    }
}

do {
    // THE trap this guard exists for: a FACELESS set that is ALSO
    // all-portrait (asymmetric sizes). `nominateChallengerRatio` is blind
    // to faces - it would nominate the portrait challenger here purely on
    // orientation - so without an explicit degrade guard ABOVE the
    // nomination step, this exact case would silently reshape the canvas
    // for every faceless portrait pick (screenshots, portrait scans,
    // panorama crops shot tall). It must not: canvas stays square, and the
    // template/assignment match today's flow exactly, same as the
    // faceless landscape/mixed cases above.
    let a = PhotoID()
    let b = PhotoID()
    let c = PhotoID()
    let photos = [a, b, c]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 1000, height: 2200),
        b: CGSize(width: 1100, height: 1800),
        c: CGSize(width: 1300, height: 2000)
    ]
    check(nominateChallengerRatio(photos: photos, photoSizes: photoSizes) == portraitChallengerRatio, "Phase 5 degrade trap: orientation rule alone WOULD nominate portrait here")

    let expectedIndex = defaultTemplateIndex(orientations: photos.map { photoSizes[$0]! })
    let expectedTemplate = contentFitAssignment(
        photoSizes: photoSizes,
        template: templates(for: photos)[expectedIndex],
        canvasSize: nominalCanvasSize(for: .square, shortEdge: defaultReferenceShortEdge),
        border: .none
    )
    let result = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: [:], border: .none)
    check(result.canvasRatio == .square, "Phase 5 degrade trap: faceless all-portrait set stays square (guard fires before nomination is even acted on)")
    check(result.templateIndex == expectedIndex, "Phase 5 degrade trap: faceless all-portrait picks the SAME template as today")
    check(result.template == expectedTemplate, "Phase 5 degrade trap: faceless all-portrait picks the SAME assignment as today")
}

do {
    // Determinism. In-process repeat (same technique the Phase 1/2 tests
    // above already use) plus a PINNED golden value using fixed PhotoID
    // literals (not fresh UUIDs) standing in for the cross-process check:
    // this exact (photos, sizes, mustKeep) input, with these exact photo
    // identities, was independently verified byte-identical across THREE
    // separate OS processes (not just this one) while building Phase 5 -
    // see the build-log entry. Pinning the expected values here means a
    // future Dictionary-iteration-order regression that happened to still
    // agree with itself twice in a single process (the exact trap the
    // spec warns about) would still be caught the moment it disagreed
    // with these hardcoded expectations in any process.
    let a = PhotoID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = PhotoID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let photos = [a, b]
    let photoSizes: [PhotoID: CGSize] = [
        a: CGSize(width: 1000, height: 2200),
        b: CGSize(width: 1100, height: 2000)
    ]
    let w = 0.20
    let mustKeepRegions: [PhotoID: CGRect] = [
        a: CGRect(x: (1 - w) / 2, y: 0.05, width: w, height: 0.9),
        b: CGRect(x: (1 - w) / 2 - 0.02, y: 0.05, width: w, height: 0.9)
    ]

    let result1 = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none)
    let result2 = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, border: .none)
    check(result1 == result2, "Phase 5: determinism - identical inputs, called twice in-process, identical MagicLayoutDecision")

    // Golden values, verified across 3 separate process runs (2026-07-28).
    check(result1.canvasRatio == portraitChallengerRatio, "Phase 5: determinism (pinned) - canvasRatio matches the cross-process-verified golden value")
    check(result1.templateIndex == 0, "Phase 5: determinism (pinned) - templateIndex matches the cross-process-verified golden value")
    check(leafList(result1.template) == [a, b], "Phase 5: determinism (pinned) - leaf order matches the cross-process-verified golden value")
    check(near(result1.cost, 1.5464580378975552, 1e-9), "Phase 5: determinism (pinned) - cost matches the cross-process-verified golden value")
}

// =====================================================================
// B32 follow-up - the group-photo-cell-size rule ("equalize RENDERED face
// size"): `mustKeepFaceHeights` threaded through `faceAwareAssignment` /
// `chooseCanvasAndLayout`, scored by `framingCost`'s new legibility term.
// Covers the owner's literal acceptance list: a group photo winning a
// bigger cell than a selfie, a selfie NOT penalized in a small cell when
// its face still renders large, the faceless degrade with the new
// parameter EXPLICITLY exercised (not just omitted), and determinism
// (in-process repeat + a cross-process-verified pinned golden value, same
// technique as the Phase 5 case above).
//
// Every case here uses DIFFERENT photo sizes and MIXED orientations (the
// documented trap: a symmetric pair can pass by coincidence) - see
// `Tools/LayoutLab` real-photo evidence (2026-07-28, 61 photos / 15 sets)
// for why the scenario below is deliberately built ASPECT-NEUTRAL (both
// mustKeeps tuned to the same real aspect) rather than left to chance: an
// aspect-driven win would prove nothing about the legibility term
// specifically, and real photos showed the two effects can easily point in
// opposite directions.
// =====================================================================

do {
    // group: landscape, 5-person union, deliberately SMALL smallest face
    // (6% of its own photo height). selfie: PORTRAIT (mixed orientation
    // vs group and neutral), one big face (50% of its own photo height).
    // neutral: landscape, no mustKeep at all (aspect-fallback).
    //
    // Both mustKeeps are tuned to the SAME real aspect (1.4 - i.e.
    // `mustKeepW/mustKeepH * photoAspect`, not the raw normalized ratio;
    // see the "units bug" note in MagicLayout.swift's own history) so
    // WITHOUT the face-height signal, aspect fit alone is a wash between
    // group and selfie (verified below, not just asserted) - the ONLY
    // thing that can break that tie is `mustKeepFaceHeights`.
    let group = PhotoID()
    let selfie = PhotoID()
    let neutral = PhotoID()
    let photos = [group, selfie, neutral]
    let photoSizes: [PhotoID: CGSize] = [
        group: CGSize(width: 3000, height: 2000),  // landscape, 1.5
        selfie: CGSize(width: 1500, height: 2000), // portrait, 0.75
        neutral: CGSize(width: 1800, height: 1200) // landscape, 1.5
    ]
    let mustKeepRegions: [PhotoID: CGRect] = [
        group: CGRect(x: 0.15, y: 0.125, width: 0.7, height: 0.75),     // real aspect 1.4
        selfie: CGRect(x: 0.175, y: 0.326, width: 0.65, height: 0.348)  // real aspect 1.4
    ]
    let mustKeepFaceHeights: [PhotoID: Double] = [
        group: 0.06,
        selfie: 0.50
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    func cellArea(_ template: Node, _ id: PhotoID) -> Double {
        let (cells, _) = solve(root: template, canvasSize: canvasSize, border: .none)
        guard let rect = cells.first(where: { $0.id == id })?.rect else { return -1 }
        return Double(rect.width) * Double(rect.height)
    }

    // WITHOUT the signal: prove the aspect-neutral setup is genuine by
    // showing group does NOT already win on aspect alone - selfie (or a
    // tie) wins here, so any group win below cannot be aspect coincidence.
    let without = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, mustKeepFaceHeights: [:], canvasSize: canvasSize, border: .none)
    let groupAreaWithout = cellArea(without.template, group)
    let selfieAreaWithout = cellArea(without.template, selfie)
    check(groupAreaWithout <= selfieAreaWithout, "group-photo-cell-size: WITHOUT the face-height signal, group does NOT already win the bigger cell (confirms the setup is aspect-neutral, not stacked)")

    // WITH the signal: the literal acceptance case - group (smallest face
    // 6%) must win a LARGER cell than selfie (face already 50%, legible).
    let with1 = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, mustKeepFaceHeights: mustKeepFaceHeights, canvasSize: canvasSize, border: .none)
    let groupArea = cellArea(with1.template, group)
    let selfieArea = cellArea(with1.template, selfie)
    check(groupArea > selfieArea, "group-photo-cell-size: a small-faced group photo gets a LARGER cell than an already-legible selfie")
    check(groupArea > groupAreaWithout, "group-photo-cell-size: the signal strictly GREW the group's own cell versus the no-signal baseline")

    // Determinism: in-process repeat...
    let with2 = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, mustKeepFaceHeights: mustKeepFaceHeights, canvasSize: canvasSize, border: .none)
    check(with1.templateIndex == with2.templateIndex, "group-photo-cell-size: determinism - templateIndex repeats")
    check(with1.template == with2.template, "group-photo-cell-size: determinism - resulting tree repeats")
    check(near(with1.cost, with2.cost, 1e-12), "group-photo-cell-size: determinism - cost repeats")

    // ...plus a pinned golden value standing in for the cross-process
    // check (same convention as the Phase 5 pinned test above) - THIS
    // exact (photos, sizes, mustKeep, mustKeepFaceHeights) input, with
    // fixed PhotoID literals, was independently verified byte-identical
    // across 3 separate OS processes while scoping this work (2026-07-28).
    //
    // TASK 2 (2026-07-29): investigated an iterated coordinate descent, a
    // widened `dividerSearchGrid`, and a full joint combinatorial cross as
    // possible fixes for the "most-populated photo should get the most
    // area" request (set13/set18). All three were built and measured; none
    // were adopted - each one either found no improvement for the actual
    // reported cases, or (worse) found a lower `framingCost` that gives the
    // most-populated photo LESS area, not more, confirmed via
    // `Tools/LayoutLab` against the real photos. See `searchDividerFractions`
    // and `dividerSearchGrid`'s own doc comments in `MagicLayout.swift` for
    // the full root-cause finding (a capped legibility term losing out to
    // uncapped clip/aspect terms once the search explores more of the
    // space) and why fixing this needs `framingCost`'s own weights/caps
    // revisited, not a smarter search. Code reverted to the original
    // single-pass search over the original 0.3...0.7 grid - this pinned
    // anchor's values are therefore UNCHANGED from before Task 2, not a new
    // golden value.
    let pinnedA = PhotoID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let pinnedB = PhotoID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    let pinnedC = PhotoID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    let pinnedD = PhotoID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    let pinnedPhotos = [pinnedA, pinnedB, pinnedC, pinnedD]
    let pinnedSizes: [PhotoID: CGSize] = [
        pinnedA: CGSize(width: 3500, height: 1500),
        pinnedB: CGSize(width: 1500, height: 3500),
        pinnedC: CGSize(width: 2000, height: 2000),
        pinnedD: CGSize(width: 2800, height: 2100)
    ]
    let pinnedMustKeep: [PhotoID: CGRect] = [
        pinnedA: CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.3),
        pinnedB: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8),
        pinnedC: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        pinnedD: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.4)
    ]
    let pinnedFaceHeights: [PhotoID: Double] = [pinnedA: 0.08, pinnedB: 0.12, pinnedC: 0.20, pinnedD: 0.15]
    let pinnedDecision = chooseCanvasAndLayout(photos: pinnedPhotos, photoSizes: pinnedSizes, mustKeepRegions: pinnedMustKeep, mustKeepFaceHeights: pinnedFaceHeights, border: .none)
    check(pinnedDecision.canvasRatio == .square, "group-photo-cell-size: determinism (pinned) - canvasRatio matches the cross-process-verified golden value")
    check(pinnedDecision.templateIndex == 0, "group-photo-cell-size: determinism (pinned) - templateIndex matches the cross-process-verified golden value")
    check(photoIDs(in: pinnedDecision.template) == [pinnedC, pinnedB, pinnedA, pinnedD], "group-photo-cell-size: determinism (pinned) - leaf order matches the cross-process-verified golden value")
    check(near(pinnedDecision.cost, 3.177596882882995, 1e-9), "group-photo-cell-size: determinism (pinned) - cost matches the cross-process-verified golden value")
}

do {
    // "A selfie is not penalized for landing in a small cell when its face
    // still renders large": a 2-photo set where the selfie ends up in the
    // SMALLER of two cells, but its face (55% of its own photo height) still
    // clears the legibility floor there - adding the signal must NOT change
    // the decision at all versus leaving it out, proving the term is a
    // genuine THRESHOLD (zero cost once legible), not a blanket "bigger is
    // always better" pull that would fight a photo out of a cell it never
    // needed to leave. Different sizes, mixed orientations.
    let selfie = PhotoID()
    let wide = PhotoID()
    let photos = [selfie, wide]
    let photoSizes: [PhotoID: CGSize] = [
        selfie: CGSize(width: 1400, height: 1800), // portrait-ish
        wide: CGSize(width: 3200, height: 1400)    // landscape, wide
    ]
    // wide's mustKeep spans nearly the whole frame at a wide aspect - a
    // realistic panorama-style subject that legitimately wants the
    // wide/stacked template's row shape, independent of any face signal.
    let mustKeepRegions: [PhotoID: CGRect] = [
        selfie: CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.62),
        wide: CGRect(x: 0.04, y: 0.15, width: 0.92, height: 0.55)
    ]
    let mustKeepFaceHeights: [PhotoID: Double] = [selfie: 0.55]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let without = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, mustKeepFaceHeights: [:], canvasSize: canvasSize, border: .none)
    let with = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: mustKeepRegions, mustKeepFaceHeights: mustKeepFaceHeights, canvasSize: canvasSize, border: .none)

    check(without.templateIndex == with.templateIndex, "group-photo-cell-size: selfie-already-legible - adding the signal does not change which template wins")
    check(without.template == with.template, "group-photo-cell-size: selfie-already-legible - adding the signal does not change the resulting tree")
    check(near(without.cost, with.cost, 1e-9), "group-photo-cell-size: selfie-already-legible - adding the signal does not change the cost (zero contribution, already above floor)")
}

do {
    // Degrade guarantee, `mustKeepFaceHeights` EXPLICITLY exercised (not
    // just omitted) - passing an empty dict, or a dict with entries for
    // photos that have no mustKeepRegion at all, must be exactly as inert
    // as never mentioning the parameter. Asymmetric mixed set, same
    // discipline as every other degrade case in this file.
    let p1 = PhotoID()
    let p2 = PhotoID()
    let p3 = PhotoID()
    let photos = [p1, p2, p3]
    let photoSizes: [PhotoID: CGSize] = [
        p1: CGSize(width: 1000, height: 2200),
        p2: CGSize(width: 1100, height: 1800),
        p3: CGSize(width: 1300, height: 2000)
    ]
    let canvasSize = CGSize(width: 1000, height: 1000)

    let expectedIndex = defaultTemplateIndex(orientations: photos.map { photoSizes[$0]! })
    let expectedTemplate = contentFitAssignment(
        photoSizes: photoSizes,
        template: templates(for: photos)[expectedIndex],
        canvasSize: canvasSize,
        border: .none
    )

    // A dict with entries the Engine should never look at anyway (no
    // photo here has a mustKeepRegion, so mustKeepFaceHeights is inert
    // regardless of its own contents) - the strongest form of "this
    // parameter changes nothing without mustKeepRegions to pair it with".
    let noisyFaceHeights: [PhotoID: Double] = [p1: 0.5, p2: 0.02, p3: 0.9]
    let result = faceAwareAssignment(photos: photos, photoSizes: photoSizes, mustKeepRegions: [:], mustKeepFaceHeights: noisyFaceHeights, canvasSize: canvasSize, border: .none)
    check(result.templateIndex == expectedIndex, "group-photo-cell-size degrade: mustKeepFaceHeights present but mustKeepRegions empty - still matches today's template")
    check(result.template == expectedTemplate, "group-photo-cell-size degrade: mustKeepFaceHeights present but mustKeepRegions empty - still matches today's assignment exactly")
    check(result.cost == 0, "group-photo-cell-size degrade: cost is exactly 0, same as the plain no-mustKeep degrade")

    let decision = chooseCanvasAndLayout(photos: photos, photoSizes: photoSizes, mustKeepRegions: [:], mustKeepFaceHeights: noisyFaceHeights, border: .none)
    check(decision.canvasRatio == .square, "group-photo-cell-size degrade (chooseCanvasAndLayout): stays square with mustKeepFaceHeights present but mustKeepRegions empty")
    check(decision.templateIndex == expectedIndex, "group-photo-cell-size degrade (chooseCanvasAndLayout): still matches today's template")
    check(decision.template == expectedTemplate, "group-photo-cell-size degrade (chooseCanvasAndLayout): still matches today's assignment exactly")
}

// =====================================================================
// Summary
// =====================================================================
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
