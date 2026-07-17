// Sources/App/Prototype/GestureController.swift
// The gesture state machine. ONE DragGesture(minimumDistance: 0) plus a
// simultaneous MagnifyGesture on the whole canvas container; this file does
// the manual routing to bracket/corner/divider/pan/swap/tap. All coordinates
// handled here are CANVAS-LOCAL (0,0 = canvas top-left, same space `solve`
// returns rects in) - CanvasView attaches the gesture directly to a view
// framed at `state.canvasSize` with an enlarged .contentShape so touches in
// the bracket zones (which sit outside the canvas rect) still land here with
// negative / out-of-bounds coordinates, which is exactly what the bracket
// math below expects.
//
// Scope notes (see final report for the full list):
//  - Rotation/flip are intentionally ignored in the pinch anchor math below;
//    no gesture in this phase mutates quarterTurns/flipH/flipV, so every
//    live photo has quarterTurns == 0 and flips == false. The static render
//    in CanvasView still honors those fields.
//  - The swap "proxy thumbnail" is a live re-render of the same crop rather
//    than a rasterized UIImage snapshot - pixel-identical, simpler.
import SwiftUI

// MARK: - Pure geometry helpers (shared with CanvasView's rendering)

/// True width/height after quarterTurns rotation (odd turns swap them) -
/// mirrors the Engine's own internal convention in clampedCenter/exportPixelSize.
func effectivePhotoSize(pixelSize: CGSize, quarterTurns: Int) -> CGSize {
    let odd = (((quarterTurns % 4) + 4) % 4) % 2 == 1
    return odd ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
}

/// s0 = max(cellW/photoW, cellH/photoH) using the *effective* (rotation-aware) dims.
func fillScale(cellSize: CGSize, photoPixelSize: CGSize, quarterTurns: Int) -> Double {
    let eff = effectivePhotoSize(pixelSize: photoPixelSize, quarterTurns: quarterTurns)
    guard eff.width > 0, eff.height > 0 else { return 1 }
    return max(cellSize.width / eff.width, cellSize.height / eff.height)
}

/// PAN's delta-center formula. Dragging right moves the photo CONTENT right
/// on screen, which means the normalized `center` (the point of the photo
/// that sits at the cell's center) must move LEFT - hence the negation.
func panDelta(translation: CGSize, s0: Double, zoom: Double, photoEffectiveSize: CGSize) -> CGPoint {
    let displayScale = s0 * zoom
    guard displayScale > 0, photoEffectiveSize.width > 0, photoEffectiveSize.height > 0 else { return .zero }
    let dx = -(translation.width / displayScale) / photoEffectiveSize.width
    let dy = -(translation.height / displayScale) / photoEffectiveSize.height
    return CGPoint(x: dx, y: dy)
}

/// A divider identified by its owning split's path + index, per Layout.swift's convention.
struct DividerRef {
    let path: [Int]
    let index: Int
    let axis: Axis
}

enum EdgeSide { case top, bottom, left, right }
enum CellCorner { case topLeft, topRight, bottomLeft, bottomRight }

/// Which of a leaf's 4 edges are movable (own a divider), and which divider
/// owns each. See the task brief's worked example for the exact algorithm:
/// walk ancestors deepest -> root; a horizontal-axis ancestor can claim
/// left/right, a vertical-axis ancestor can claim top/bottom; the first
/// (deepest) ancestor able to claim a given edge owns it.
struct EdgeOwners {
    var left: DividerRef?
    var right: DividerRef?
    var top: DividerRef?
    var bottom: DividerRef?
}

func leafPath(for id: PhotoID, in root: Node, path: [Int] = []) -> [Int]? {
    switch root {
    case .leaf(let leafID):
        return leafID == id ? path : nil
    case .split(_, _, let children):
        for (i, child) in children.enumerated() {
            if let found = leafPath(for: id, in: child, path: path + [i]) { return found }
        }
        return nil
    }
}

func edgeOwners(forLeafPath leafPath: [Int], root: Node) -> EdgeOwners {
    var owners = EdgeOwners()
    var d = leafPath.count - 1
    while d >= 0 {
        let ancestorPath = Array(leafPath[0..<d])
        guard case .split(let axis, _, let children)? = node(at: ancestorPath, in: root) else {
            d -= 1
            continue
        }
        let i = leafPath[d]
        let n = children.count
        switch axis {
        case .horizontal:
            if owners.left == nil && i > 0 {
                owners.left = DividerRef(path: ancestorPath, index: i - 1, axis: axis)
            }
            if owners.right == nil && i < n - 1 {
                owners.right = DividerRef(path: ancestorPath, index: i, axis: axis)
            }
        case .vertical:
            if owners.top == nil && i > 0 {
                owners.top = DividerRef(path: ancestorPath, index: i - 1, axis: axis)
            }
            if owners.bottom == nil && i < n - 1 {
                owners.bottom = DividerRef(path: ancestorPath, index: i, axis: axis)
            }
        }
        d -= 1
    }
    return owners
}

private func ownerRef(_ side: EdgeSide, owners: EdgeOwners) -> DividerRef? {
    switch side {
    case .left: return owners.left
    case .right: return owners.right
    case .top: return owners.top
    case .bottom: return owners.bottom
    }
}

private func cornerDividerRefs(_ corner: CellCorner, owners: EdgeOwners) -> (x: DividerRef?, y: DividerRef?) {
    switch corner {
    case .topLeft: return (owners.left, owners.top)
    case .topRight: return (owners.right, owners.top)
    case .bottomLeft: return (owners.left, owners.bottom)
    case .bottomRight: return (owners.right, owners.bottom)
    }
}

/// The visual capsule rect for one owned edge: 50% of edge length, 5pt
/// thick, straddling the seam (centered half a gutter outside the cell edge).
struct CapsuleSpec {
    let side: EdgeSide
    let rect: CGRect
}

func capsuleSpecs(cellRect: CGRect, owners: EdgeOwners, gutterPts: Double) -> [CapsuleSpec] {
    let thickness: CGFloat = 5
    var specs: [CapsuleSpec] = []
    if owners.left != nil {
        let x = cellRect.minX - gutterPts / 2
        let h = cellRect.height * 0.5
        specs.append(CapsuleSpec(side: .left, rect: CGRect(x: x - thickness / 2, y: cellRect.midY - h / 2, width: thickness, height: h)))
    }
    if owners.right != nil {
        let x = cellRect.maxX + gutterPts / 2
        let h = cellRect.height * 0.5
        specs.append(CapsuleSpec(side: .right, rect: CGRect(x: x - thickness / 2, y: cellRect.midY - h / 2, width: thickness, height: h)))
    }
    if owners.top != nil {
        let y = cellRect.minY - gutterPts / 2
        let w = cellRect.width * 0.5
        specs.append(CapsuleSpec(side: .top, rect: CGRect(x: cellRect.midX - w / 2, y: y - thickness / 2, width: w, height: thickness)))
    }
    if owners.bottom != nil {
        let y = cellRect.maxY + gutterPts / 2
        let w = cellRect.width * 0.5
        specs.append(CapsuleSpec(side: .bottom, rect: CGRect(x: cellRect.midX - w / 2, y: y - thickness / 2, width: w, height: thickness)))
    }
    return specs
}

/// Hit zone for a capsule: a 44pt-wide band along its length (centered on
/// the same axis-line, widened perpendicular to it).
private func capsuleHitZone(_ spec: CapsuleSpec) -> CGRect {
    switch spec.side {
    case .left, .right:
        return CGRect(x: spec.rect.midX - 22, y: spec.rect.minY, width: 44, height: spec.rect.height)
    case .top, .bottom:
        return CGRect(x: spec.rect.minX, y: spec.rect.midY - 22, width: spec.rect.width, height: 44)
    }
}

struct CornerHandleSpec {
    let corner: CellCorner
    let center: CGPoint
}

/// A corner handle exists only when BOTH edges meeting there are movable.
func cornerHandleSpecs(cellRect: CGRect, owners: EdgeOwners, gutterPts: Double) -> [CornerHandleSpec] {
    let g = gutterPts / 2
    var specs: [CornerHandleSpec] = []
    if owners.top != nil, owners.left != nil {
        specs.append(CornerHandleSpec(corner: .topLeft, center: CGPoint(x: cellRect.minX - g, y: cellRect.minY - g)))
    }
    if owners.top != nil, owners.right != nil {
        specs.append(CornerHandleSpec(corner: .topRight, center: CGPoint(x: cellRect.maxX + g, y: cellRect.minY - g)))
    }
    if owners.bottom != nil, owners.left != nil {
        specs.append(CornerHandleSpec(corner: .bottomLeft, center: CGPoint(x: cellRect.minX - g, y: cellRect.maxY + g)))
    }
    if owners.bottom != nil, owners.right != nil {
        specs.append(CornerHandleSpec(corner: .bottomRight, center: CGPoint(x: cellRect.maxX + g, y: cellRect.maxY + g)))
    }
    return specs
}

enum BracketCorner: CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// The bracket's vertex point: 12pt outside the corresponding canvas corner.
func bracketAnchor(_ corner: BracketCorner, canvasSize: CGSize) -> CGPoint {
    let d: CGFloat = 12
    switch corner {
    case .topLeft: return CGPoint(x: -d, y: -d)
    case .topRight: return CGPoint(x: canvasSize.width + d, y: -d)
    case .bottomLeft: return CGPoint(x: -d, y: canvasSize.height + d)
    case .bottomRight: return CGPoint(x: canvasSize.width + d, y: canvasSize.height + d)
    }
}

// MARK: - Hit-test classification

enum HitTarget {
    case bracket(BracketCorner)
    case corner(x: DividerRef, y: DividerRef)
    case divider(DividerRef)
    case photo(PhotoID, CGRect)
    case empty
}

/// Priority order (first hit wins), per the task brief:
/// 1. Composition bracket zones (44x44 centered on each bracket vertex).
/// 2. If a cell is selected: its corner handles (44x44), then its capsules
///    (44pt-wide band).
/// 3. Bare seam: any divider's gutter rect expanded 11pt perpendicular to
///    its axis; a crossing (both axes match) picks the nearer seam.
/// 4. Photo body, else empty (dead space).
func classifyTouch(at point: CGPoint, document: Document, canvasSize: CGSize, selection: PhotoID?) -> HitTarget {
    for corner in BracketCorner.allCases {
        let anchor = bracketAnchor(corner, canvasSize: canvasSize)
        if abs(point.x - anchor.x) <= 22 && abs(point.y - anchor.y) <= 22 {
            return .bracket(corner)
        }
    }

    let (cells, dividers) = solve(root: document.root, canvasSize: canvasSize, border: document.border)
    let shortEdge = min(canvasSize.width, canvasSize.height)
    let gutterPts = document.border.inner * shortEdge

    if let selection, let cell = cells.first(where: { $0.id == selection }),
       let path = leafPath(for: selection, in: document.root) {
        let owners = edgeOwners(forLeafPath: path, root: document.root)

        for spec in cornerHandleSpecs(cellRect: cell.rect, owners: owners, gutterPts: gutterPts) {
            if abs(point.x - spec.center.x) <= 22 && abs(point.y - spec.center.y) <= 22 {
                let refs = cornerDividerRefs(spec.corner, owners: owners)
                if let x = refs.x, let y = refs.y {
                    return .corner(x: x, y: y)
                }
            }
        }

        for spec in capsuleSpecs(cellRect: cell.rect, owners: owners, gutterPts: gutterPts) {
            if capsuleHitZone(spec).contains(point), let ref = ownerRef(spec.side, owners: owners) {
                return .divider(ref)
            }
        }
    }

    var bestSeam: (ref: DividerRef, dist: CGFloat)?
    for d in dividers {
        let expanded = d.axis == .horizontal ? d.line.insetBy(dx: -11, dy: 0) : d.line.insetBy(dx: 0, dy: -11)
        guard expanded.contains(point) else { continue }
        let dist = d.axis == .horizontal ? abs(point.x - d.line.midX) : abs(point.y - d.line.midY)
        if bestSeam == nil || dist < bestSeam!.dist {
            bestSeam = (DividerRef(path: d.path, index: d.index, axis: d.axis), dist)
        }
    }
    if let best = bestSeam { return .divider(best.ref) }

    if let cell = cells.first(where: { $0.rect.contains(point) }) {
        return .photo(cell.id, cell.rect)
    }
    return .empty
}

/// Swaps the two leaves' PhotoIDs anywhere in the tree. A local helper since
/// Operations.swift has no swap primitive and Engine files are off-limits.
func swappingLeaves(_ a: PhotoID, _ b: PhotoID, in root: Node) -> Node {
    switch root {
    case .leaf(let id):
        if id == a { return .leaf(b) }
        if id == b { return .leaf(a) }
        return root
    case .split(let axis, let fractions, let children):
        return .split(axis: axis, fractions: fractions, children: children.map { swappingLeaves(a, b, in: $0) })
    }
}

// MARK: - Ratio detents (bracket drag)

private let ratioPresets: [(w: Double, h: Double)] = [
    (1, 1), (4, 5), (5, 4), (3, 4), (4, 3), (2, 3), (3, 2), (9, 16), (16, 9)
]

// MARK: - The state machine

@MainActor
final class GestureController {

    private let state: EditorState

    private let slop: CGFloat = 8
    private let holdDuration: TimeInterval = 0.35
    /// Rubber-band excursion cap for zoom past [1, 8], mirrored both ends
    /// (spec gives the below-1.0 floor as 0.85; "same treatment mirrored"
    /// above 8.0 is read here as a symmetric +0.15 ceiling).
    private let zoomOvershoot = 0.15

    private enum Phase {
        case idle
        case tracking(TrackingInfo)
        case pan(PanInfo)
        case swap(sourceID: PhotoID, sourceCellRect: CGRect)
        case divider(DividerInfo)
        case corner(x: DividerInfo, y: DividerInfo)
        case bracket(BracketInfo)
        case pinch(PinchInfo)
    }

    private struct TrackingInfo {
        let cellID: PhotoID?
        let cellRect: CGRect?
        let startLocation: CGPoint
        let startTime: Date
    }

    private struct PanInfo {
        let photoID: PhotoID
        let cellRect: CGRect
        let originalRef: PhotoRef
        let s0: Double
        let effectiveSize: CGSize
    }

    private struct DividerInfo {
        let ref: DividerRef
        let parentPath: [Int]
        let originalFractions: [Double]
        let children: [Node]
        let usableExtent: Double
        let candidates: [Double]
        let tolerance: Double
        var wasSnapped = false
        var floorExceeded = false
    }

    private struct BracketInfo {
        let corner: BracketCorner
        let originalSize: CGSize
        var snappedPresetIndex: Int?
    }

    private struct PinchInfo {
        let photoID: PhotoID
        let cellRect: CGRect
        let originalCenter: CGPoint
        let originalZoom: Double
        let pixelSize: CGSize
        let quarterTurns: Int
        let s0: Double
        let effectiveSize: CGSize
        /// Screen-space offset of the pinch's start point from the cell
        /// center, captured once at pinch start.
        let localAnchor: CGPoint
        /// The normalized photo point that sat under the pinch centroid at
        /// start - kept stationary as zoom changes.
        let anchorU: Double
        let anchorV: Double
        let dragTranslationAtStart: CGSize
    }

    private var phase: Phase = .idle
    /// Updated at the top of every dragChanged call regardless of phase, so
    /// magnifyChanged can read "how far the simultaneous single-touch drag
    /// has moved" for the two-finger-pan-during-pinch case (MagnifyGesture
    /// itself reports no translation).
    private var currentDragTranslation: CGSize = .zero
    private var holdToken: UUID?
    /// Set when a pinch takes ownership of the current touch sequence. The
    /// still-live DragGesture must not be re-classified after the pinch ends
    /// (pinch -> lift one finger -> keep dragging would otherwise re-enter
    /// beginTouch with a stale startLocation and a translation that includes
    /// the whole pinch era - a visible jump). Cleared when the drag ends.
    private var dragConsumedByPinch = false

    init(state: EditorState) {
        self.state = state
    }

    // MARK: - Drag

    func dragChanged(_ value: DragGesture.Value) {
        currentDragTranslation = value.translation

        switch phase {
        case .idle:
            if dragConsumedByPinch { return } // stale post-pinch drag; ignore until it ends
            state.beginGesture()
            beginTouch(at: value.startLocation)
        case .tracking(let info):
            handleTracking(info, value: value)
        case .pan(let info):
            handlePan(info, value: value)
        case .divider(var info):
            handleDivider(&info, value: value)
            phase = .divider(info)
        case .corner(var x, var y):
            handleCorner(&x, &y, value: value)
            phase = .corner(x: x, y: y)
        case .bracket(var info):
            handleBracket(&info, value: value)
            phase = .bracket(info)
        case .swap:
            handleSwap(value: value)
        case .pinch:
            break // driven by magnifyChanged; translation already captured above
        }
    }

    func dragEnded(_ value: DragGesture.Value) {
        currentDragTranslation = value.translation
        defer {
            holdToken = nil
            dragConsumedByPinch = false
        }

        switch phase {
        case .pinch:
            return // owned by magnifyEnded
        case .idle:
            return
        case .tracking(let info):
            endTracking(info, value: value)
        case .pan:
            endPan(value: value)
        case .divider:
            phase = .idle
            state.commitGesture()
        case .corner:
            phase = .idle
            state.commitGesture()
        case .bracket(let info):
            endBracket(info)
        case .swap:
            endSwap()
        }
    }

    // MARK: - Touch-down classification

    private func beginTouch(at point: CGPoint) {
        let target = classifyTouch(at: point, document: state.document, canvasSize: state.canvasSize, selection: state.selection)
        switch target {
        case .bracket(let corner):
            phase = .bracket(BracketInfo(corner: corner, originalSize: state.canvasSize, snappedPresetIndex: nil))
        case .corner(let x, let y):
            phase = .corner(x: makeDividerInfo(x), y: makeDividerInfo(y))
        case .divider(let ref):
            phase = .divider(makeDividerInfo(ref))
        case .photo(let id, let rect):
            phase = .tracking(TrackingInfo(cellID: id, cellRect: rect, startLocation: point, startTime: Date()))
            scheduleHoldTimer()
        case .empty:
            phase = .tracking(TrackingInfo(cellID: nil, cellRect: nil, startLocation: point, startTime: Date()))
        }
    }

    private func makeDividerInfo(_ ref: DividerRef) -> DividerInfo {
        let root = state.document.root
        let canvasSize = state.canvasSize
        let border = state.document.border

        guard case .split(_, let fractions, let children)? = node(at: ref.path, in: root),
              let parentRect = nodeRect(at: ref.path, in: root, canvasSize: canvasSize, border: border) else {
            return DividerInfo(ref: ref, parentPath: ref.path, originalFractions: [], children: [], usableExtent: 0, candidates: [], tolerance: 0)
        }

        let shortEdge = min(canvasSize.width, canvasSize.height)
        let gutterPts = border.inner * shortEdge
        let isH = ref.axis == .horizontal
        let totalExtent = isH ? parentRect.width : parentRect.height
        let usable = totalExtent - gutterPts * Double(children.count - 1)
        let candidates = snapCandidates(forDividerAt: ref.path, index: ref.index, root: root, canvasSize: canvasSize, border: border)
        let tolerance = usable > 0 ? 8.0 / usable : 0

        return DividerInfo(ref: ref, parentPath: ref.path, originalFractions: fractions, children: children, usableExtent: usable, candidates: candidates, tolerance: tolerance)
    }

    // MARK: - Tracking -> tap / pan / swap

    private func handleTracking(_ info: TrackingInfo, value: DragGesture.Value) {
        let point = value.location
        let dist = hypot(point.x - info.startLocation.x, point.y - info.startLocation.y)
        guard dist > slop else { return }

        guard let cellID = info.cellID, let cellRect = info.cellRect else {
            phase = .idle // dead-space drag: nothing to pan/swap
            return
        }
        beginPan(photoID: cellID, cellRect: cellRect)
    }

    private func endTracking(_ info: TrackingInfo, value: DragGesture.Value) {
        phase = .idle
        defer { state.commitGesture() }

        let point = value.location
        let dist = hypot(point.x - info.startLocation.x, point.y - info.startLocation.y)
        let elapsed = Date().timeIntervalSince(info.startTime)
        guard dist <= slop, elapsed < holdDuration else { return }
        state.selection = info.cellID // nil deselects (tap resolved on dead space)
    }

    private func scheduleHoldTimer() {
        let token = UUID()
        holdToken = token
        let duration = holdDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.fireHoldTimer(token: token)
        }
    }

    private func fireHoldTimer(token: UUID) {
        guard holdToken == token else { return }
        guard case .tracking(let info) = phase, let cellID = info.cellID, let cellRect = info.cellRect else { return }
        let dist = hypot(currentDragTranslation.width, currentDragTranslation.height)
        guard dist <= slop else { return }
        beginSwap(photoID: cellID, cellRect: cellRect)
    }

    // MARK: - Pan

    private func beginPan(photoID: PhotoID, cellRect: CGRect) {
        guard let ref = state.document.photos[photoID] else { phase = .idle; return }
        let pixelSize = CGSize(width: Double(ref.pixelWidth), height: Double(ref.pixelHeight))
        let effSize = effectivePhotoSize(pixelSize: pixelSize, quarterTurns: ref.quarterTurns)
        let s0 = fillScale(cellSize: cellRect.size, photoPixelSize: pixelSize, quarterTurns: ref.quarterTurns)
        phase = .pan(PanInfo(photoID: photoID, cellRect: cellRect, originalRef: ref, s0: s0, effectiveSize: effSize))
    }

    private func handlePan(_ info: PanInfo, value: DragGesture.Value) {
        let (unclamped, clamped) = panCenters(info, translation: value.translation)
        let display = CGPoint(
            x: clamped.x + (unclamped.x - clamped.x) * 0.35,
            y: clamped.y + (unclamped.y - clamped.y) * 0.35
        )
        var doc = state.document
        guard var photo = doc.photos[info.photoID] else { return }
        photo.center = display
        photo.isAuto = false
        doc.photos[info.photoID] = photo
        state.document = doc
    }

    private func endPan(value: DragGesture.Value) {
        guard case .pan(let info) = phase else { phase = .idle; return }
        let (_, clamped) = panCenters(info, translation: value.translation)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            var doc = state.document
            if var photo = doc.photos[info.photoID] {
                photo.center = clamped
                photo.isAuto = false
                doc.photos[info.photoID] = photo
                state.document = doc
            }
        }
        phase = .idle
        state.commitGesture()
    }

    private func panCenters(_ info: PanInfo, translation: CGSize) -> (unclamped: CGPoint, clamped: CGPoint) {
        let delta = panDelta(translation: translation, s0: info.s0, zoom: info.originalRef.zoom, photoEffectiveSize: info.effectiveSize)
        let unclamped = CGPoint(x: info.originalRef.center.x + delta.x, y: info.originalRef.center.y + delta.y)
        let clamped = clampedCenter(
            center: unclamped,
            zoom: info.originalRef.zoom,
            photoPixelSize: CGSize(width: Double(info.originalRef.pixelWidth), height: Double(info.originalRef.pixelHeight)),
            quarterTurns: info.originalRef.quarterTurns,
            cellSize: info.cellRect.size
        )
        return (unclamped, clamped)
    }

    // MARK: - Pinch (Magnify + simultaneous drag translation)

    func magnifyChanged(_ value: MagnifyGesture.Value) {
        state.beginGesture()
        switch phase {
        case .pinch(let info):
            applyPinch(info, value: value)
        case .tracking, .pan:
            phase = .idle
            beginPinch(value: value)
        default:
            break // don't steal a divider/corner/bracket/swap drag
        }
    }

    func magnifyEnded(_ value: MagnifyGesture.Value) {
        guard case .pinch(let info) = phase else { return }
        let raw = info.originalZoom * value.magnification
        let finalZoom = clampedZoom(raw)
        let finalCenter = pinchCenter(info, zoom: finalZoom, clamp: true)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            var doc = state.document
            if var photo = doc.photos[info.photoID] {
                photo.zoom = finalZoom
                photo.center = finalCenter
                photo.isAuto = false
                doc.photos[info.photoID] = photo
                state.document = doc
            }
        }
        phase = .idle
        state.commitGesture()
    }

    private func beginPinch(value: MagnifyGesture.Value) {
        dragConsumedByPinch = true
        let point = value.startLocation
        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        guard let cell = cells.first(where: { $0.rect.contains(point) }), let ref = state.document.photos[cell.id] else {
            phase = .idle
            return
        }
        let pixelSize = CGSize(width: Double(ref.pixelWidth), height: Double(ref.pixelHeight))
        let effSize = effectivePhotoSize(pixelSize: pixelSize, quarterTurns: ref.quarterTurns)
        let s0 = fillScale(cellSize: cell.rect.size, photoPixelSize: pixelSize, quarterTurns: ref.quarterTurns)
        let displayScale0 = s0 * ref.zoom
        let local = CGPoint(x: point.x - cell.rect.midX, y: point.y - cell.rect.midY)
        let u = ref.center.x + Double(local.x) / (displayScale0 * effSize.width)
        let v = ref.center.y + Double(local.y) / (displayScale0 * effSize.height)

        phase = .pinch(PinchInfo(
            photoID: cell.id,
            cellRect: cell.rect,
            originalCenter: ref.center,
            originalZoom: ref.zoom,
            pixelSize: pixelSize,
            quarterTurns: ref.quarterTurns,
            s0: s0,
            effectiveSize: effSize,
            localAnchor: local,
            anchorU: u,
            anchorV: v,
            dragTranslationAtStart: currentDragTranslation
        ))
    }

    private func applyPinch(_ info: PinchInfo, value: MagnifyGesture.Value) {
        let raw = info.originalZoom * value.magnification
        let displayZoom = rubberBandZoom(raw)
        let clamped = pinchCenter(info, zoom: displayZoom, clamp: false)
        let unclamped = pinchCenter(info, zoom: displayZoom, clamp: false, rawOnly: true)
        let display = CGPoint(
            x: clamped.x + (unclamped.x - clamped.x) * 0.35,
            y: clamped.y + (unclamped.y - clamped.y) * 0.35
        )

        var doc = state.document
        guard var photo = doc.photos[info.photoID] else { return }
        photo.zoom = displayZoom
        photo.center = display
        photo.isAuto = false
        doc.photos[info.photoID] = photo
        state.document = doc
    }

    private func rubberBandZoom(_ raw: Double) -> Double {
        if raw < 1.0 {
            return max(1 - (1 - raw) * 0.35, 1 - zoomOvershoot)
        } else if raw > 8.0 {
            return min(8 + (raw - 8) * 0.35, 8 + zoomOvershoot)
        }
        return raw
    }

    /// Anchor-preserving center at a given zoom, plus the simultaneous
    /// drag gesture's translation-since-pinch-start (the "two-finger pan
    /// during pinch" case - MagnifyGesture reports no translation of its
    /// own, per the task brief). `rawOnly` skips the engine clamp so the
    /// caller can rubber-band between raw and clamped itself.
    private func pinchCenter(_ info: PinchInfo, zoom: Double, clamp: Bool, rawOnly: Bool = false) -> CGPoint {
        let displayScale = info.s0 * zoom
        let zoomOnly = CGPoint(
            x: info.anchorU - Double(info.localAnchor.x) / (displayScale * info.effectiveSize.width),
            y: info.anchorV - Double(info.localAnchor.y) / (displayScale * info.effectiveSize.height)
        )
        let panTranslation = CGSize(
            width: currentDragTranslation.width - info.dragTranslationAtStart.width,
            height: currentDragTranslation.height - info.dragTranslationAtStart.height
        )
        let panShift = panDelta(translation: panTranslation, s0: info.s0, zoom: zoom, photoEffectiveSize: info.effectiveSize)
        let unclamped = CGPoint(x: zoomOnly.x + panShift.x, y: zoomOnly.y + panShift.y)

        guard !rawOnly else { return unclamped }
        return clampedCenter(center: unclamped, zoom: zoom, photoPixelSize: info.pixelSize, quarterTurns: info.quarterTurns, cellSize: info.cellRect.size)
    }

    // MARK: - Divider / corner

    private func handleDivider(_ info: inout DividerInfo, value: DragGesture.Value) {
        guard info.usableExtent > 0 else { return }
        let isH = info.ref.axis == .horizontal
        let deltaPoints = isH ? value.translation.width : value.translation.height
        var doc = state.document
        applyDividerDelta(&info, deltaPoints: deltaPoints, doc: &doc)
        doc = reclampAll(doc, canvasSize: state.canvasSize)
        state.document = doc
    }

    private func handleCorner(_ x: inout DividerInfo, _ y: inout DividerInfo, value: DragGesture.Value) {
        var doc = state.document
        if x.usableExtent > 0 { applyDividerDelta(&x, deltaPoints: value.translation.width, doc: &doc) }
        if y.usableExtent > 0 { applyDividerDelta(&y, deltaPoints: value.translation.height, doc: &doc) }
        doc = reclampAll(doc, canvasSize: state.canvasSize)
        state.document = doc
    }

    private func applyDividerDelta(_ info: inout DividerInfo, deltaPoints: CGFloat, doc: inout Document) {
        let deltaFraction = Double(deltaPoints) / info.usableExtent

        let floor = Layout.minCellFraction
        let f0 = info.originalFractions[info.ref.index]
        let f1 = info.originalFractions[info.ref.index + 1]
        let minDelta = floor - f0
        let maxDelta = f1 - floor
        let exceeds = deltaFraction < minDelta || deltaFraction > maxDelta
        if exceeds && !info.floorExceeded { state.haptics.floorBump() }
        info.floorExceeded = exceeds

        let result = dragDivider(fractions: info.originalFractions, index: info.ref.index, deltaFraction: deltaFraction, snapCandidates: info.candidates, toleranceFraction: info.tolerance)
        if result.snapped && !info.wasSnapped { state.haptics.tick() }
        info.wasSnapped = result.snapped

        let newNode = Node.split(axis: info.ref.axis, fractions: result.fractions, children: info.children)
        doc.root = replacingNode(at: info.parentPath, in: doc.root, with: newNode)
    }

    // MARK: - Bracket (canvas ratio resize)

    private func handleBracket(_ info: inout BracketInfo, value: DragGesture.Value) {
        let dx = value.translation.width
        let dy = value.translation.height
        var newWidth = info.originalSize.width
        var newHeight = info.originalSize.height

        switch info.corner {
        case .topLeft: newWidth -= dx; newHeight -= dy
        case .topRight: newWidth += dx; newHeight -= dy
        case .bottomLeft: newWidth -= dx; newHeight += dy
        case .bottomRight: newWidth += dx; newHeight += dy
        }
        newWidth = max(newWidth, 120)
        newHeight = max(newHeight, 120)

        var ratioValue = newWidth / newHeight
        var snappedIndex: Int?
        for (i, preset) in ratioPresets.enumerated() {
            let presetValue = preset.w / preset.h
            if abs(log(ratioValue) - log(presetValue)) < 0.035 {
                snappedIndex = i
                ratioValue = presetValue
                break
            }
        }
        if info.snappedPresetIndex == nil, snappedIndex != nil {
            state.haptics.tick()
        }
        info.snappedPresetIndex = snappedIndex

        let finalRatio: Ratio
        if let idx = snappedIndex {
            finalRatio = Ratio(width: ratioPresets[idx].w, height: ratioPresets[idx].h)
        } else {
            finalRatio = Ratio(width: newWidth, height: newHeight)
        }

        state.document.canvasRatio = finalRatio
        state.liveCanvasSize = CGSize(width: newWidth, height: newHeight)
    }

    private func endBracket(_ info: BracketInfo) {
        phase = .idle
        let finalRatioValue = state.document.canvasRatio.value
        let fitted = EditorState.fitSize(ratio: finalRatioValue, in: state.containerSize)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            state.liveCanvasSize = nil
        }
        state.document = reclampAll(state.document, canvasSize: fitted)
        state.commitGesture()
    }

    // MARK: - Swap

    private func beginSwap(photoID: PhotoID, cellRect: CGRect) {
        state.haptics.thump()
        phase = .swap(sourceID: photoID, sourceCellRect: cellRect)
        state.swapState = SwapState(sourceID: photoID, sourceCellRect: cellRect, fingerLocation: CGPoint(x: cellRect.midX, y: cellRect.midY), hoveredTargetID: nil)
    }

    private func handleSwap(value: DragGesture.Value) {
        guard case .swap(let sourceID, _) = phase else { return }
        let point = value.location
        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        let target = cells.first { $0.id != sourceID && $0.rect.contains(point) }
        state.swapState?.fingerLocation = point
        state.swapState?.hoveredTargetID = target?.id
    }

    private func endSwap() {
        guard case .swap(let sourceID, let sourceCellRect) = phase else { phase = .idle; return }
        phase = .idle

        guard let targetID = state.swapState?.hoveredTargetID else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                state.swapState?.fingerLocation = CGPoint(x: sourceCellRect.midX, y: sourceCellRect.midY)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.state.swapState = nil
            }
            state.commitGesture() // no-op: document unchanged
            return
        }

        var doc = state.document
        doc.root = swappingLeaves(sourceID, targetID, in: doc.root)
        doc = reclampAll(doc, canvasSize: state.canvasSize)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            state.document = doc
        }
        state.haptics.thump()
        state.swapState = nil
        state.commitGesture()
    }
}
