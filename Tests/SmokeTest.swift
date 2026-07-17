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
// Summary
// =====================================================================
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
