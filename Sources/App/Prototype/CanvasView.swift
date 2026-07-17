// Sources/App/Prototype/CanvasView.swift
// Renders the document (photos honoring zoom/center/flips/quarterTurns),
// the selection/capsule/corner overlay grammar, the always-on composition
// brackets, and the swap-mode proxy. Owns the single gesture pair (one
// DragGesture + a simultaneous MagnifyGesture) and routes every callback
// into GestureController - no per-view gestures anywhere else.
import SwiftUI

extension Color {
    /// #71BFFF - the one accent color for every overlay element.
    static let mosaicAccent = Color(red: 0.443, green: 0.749, blue: 1.0)
}

struct CanvasView: View {
    let state: EditorState
    var onReady: (() -> Void)?

    @State private var controller: GestureController?
    @State private var didFireReady = false

    /// How far outside the canvas rect the gesture's hit-testable shape
    /// extends, so the 44x44 bracket zones (which sit up to ~34pt outside
    /// the canvas corners) are reliably reachable. This only affects hit
    /// testing, not the 28pt visual clearance computed below.
    private let hitTestMargin: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(geo.size.width - 56, 0), height: max(geo.size.height - 56, 0))

            canvasContent
                .frame(width: state.canvasSize.width, height: state.canvasSize.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    state.containerSize = available
                    if controller == nil { controller = GestureController(state: state) }
                    if !didFireReady {
                        didFireReady = true
                        onReady?()
                    }
                }
                .onChange(of: geo.size) { _, newValue in
                    state.containerSize = CGSize(width: max(newValue.width - 56, 0), height: max(newValue.height - 56, 0))
                }
        }
    }

    // MARK: - Canvas content

    @ViewBuilder
    private var canvasContent: some View {
        let (cells, _) = solve(root: state.document.root, canvasSize: state.canvasSize, border: state.document.border)
        let gutterPts = state.document.border.inner * min(state.canvasSize.width, state.canvasSize.height)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color(from: state.document.border.color))
                .frame(width: state.canvasSize.width, height: state.canvasSize.height)

            ForEach(cells, id: \.id) { cell in
                photoCell(cell)
            }

            if let selection = state.selection,
               let cell = cells.first(where: { $0.id == selection }),
               let path = leafPath(for: selection, in: state.document.root) {
                selectionOverlay(cell: cell, path: path, gutterPts: gutterPts)
            }

            bracketsOverlay

            if let swap = state.swapState {
                swapOverlay(swap: swap, cells: cells)
            }
        }
        .frame(width: state.canvasSize.width, height: state.canvasSize.height)
        .contentShape(Rectangle().inset(by: -hitTestMargin))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { controller?.dragChanged($0) }
                .onEnded { controller?.dragEnded($0) }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { controller?.magnifyChanged($0) }
                .onEnded { controller?.magnifyEnded($0) }
        )
        .simultaneousGesture(
            // Phase 4: closes an open Layout/Ratio/Border tray on any tap
            // (dead space OR a photo) when nothing is selected. Selecting a
            // photo already closes the tray via EditorView's
            // `.onChange(of: state.selection)`; this covers the dead-space
            // case, where selection stays nil so that onChange never fires.
            // Purely additive/side-effect-only - doesn't touch
            // GestureController or the selection/pan/swap state machine.
            TapGesture().onEnded {
                if state.selection == nil { state.activeTray = .none }
            }
        )
    }

    // MARK: - Photo rendering

    /// Shared crop-rendering used both for a cell in place and for the swap
    /// proxy (which just re-renders the same crop at a smaller visual scale).
    @ViewBuilder
    private func cellContent(ref: PhotoRef, image: UIImage, cellSize: CGSize, cornerRadiusPts: Double = 0) -> some View {
        let pixelSize = CGSize(width: Double(ref.pixelWidth), height: Double(ref.pixelHeight))
        let s0 = fillScale(cellSize: cellSize, photoPixelSize: pixelSize, quarterTurns: ref.quarterTurns)
        let displayScale = s0 * ref.zoom
        let frameSize = CGSize(width: pixelSize.width * displayScale, height: pixelSize.height * displayScale)
        // `center` is in effective DISPLAYED space (post-rotation/flip,
        // screen-aligned - see panDelta's note in GestureController). The
        // rotated visual is re-framed to its own bounding box (effW x effH)
        // FIRST, so the offset formula below is the same one that has been
        // rendering correct crops since Phase 2 - just against effective
        // dimensions. At quarterTurns == 0 the re-frame is an exact no-op
        // (effW == frameW), which is what keeps the proven path unchanged.
        let effPx = effectivePhotoSize(pixelSize: pixelSize, quarterTurns: ref.quarterTurns)
        let effW = effPx.width * displayScale
        let effH = effPx.height * displayScale
        // Explicit center placement - no offset/alignment chains. SwiftUI's
        // placement of oversized children inside a smaller .frame proved
        // untrustworthy under algebra (the Phase 4 offset form rendered
        // zoomed off-center crops against the wrong side, with coverage
        // gaps - caught by the export-fidelity harness). `.position` pins
        // the image's layout-frame CENTER, rotation spins about that same
        // center, so the rotated/flipped block of effW x effH is centered
        // at exactly this point in cell space:
        let blockCenterX = cellSize.width / 2 + (0.5 - ref.center.x) * effW
        let blockCenterY = cellSize.height / 2 + (0.5 - ref.center.y) * effH

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: frameSize.width, height: frameSize.height)
                .rotationEffect(.degrees(90 * Double(ref.quarterTurns)))
                .scaleEffect(x: ref.flipH ? -1 : 1, y: ref.flipV ? -1 : 1)
                .position(x: blockCenterX, y: blockCenterY)
        }
        .frame(width: cellSize.width, height: cellSize.height)
        // Border tray's Radius: canvas must match what export mints
        // (CollageRenderer clips each cell with the same rounded rect).
        .clipShape(RoundedRectangle(cornerRadius: cornerRadiusPts, style: .continuous))
    }

    /// Phase 6 (additive only - no gesture/render math touched): a cell
    /// whose photo isn't loaded yet renders a shimmer while restore is still
    /// fetching it, or a "Photo unavailable" placeholder if restore
    /// determined the source asset is gone. Tapping either still resolves to
    /// `.photo(id, rect)` in `classifyTouch` (unaffected by whether `image`
    /// is loaded), so selection - and therefore Replace - keeps working.
    /// BorderStyle.cornerRadius is a fraction of the canvas short edge
    /// (same rule as inner/outer) - convert once per render.
    private var cellCornerRadiusPts: Double {
        state.document.border.cornerRadius * min(state.canvasSize.width, state.canvasSize.height)
    }

    @ViewBuilder
    private func photoCell(_ cell: CellFrame) -> some View {
        if let ref = state.document.photos[cell.id] {
            if let image = state.images[cell.id] {
                cellContent(ref: ref, image: image, cellSize: cell.rect.size, cornerRadiusPts: cellCornerRadiusPts)
                    .opacity(state.swapState?.sourceID == cell.id ? 0.85 : 1.0)
                    .offset(x: cell.rect.minX, y: cell.rect.minY)
            } else if state.unavailablePhotoIDs.contains(cell.id) {
                UnavailablePlaceholder()
                    .frame(width: cell.rect.width, height: cell.rect.height)
                    .clipped()
                    .offset(x: cell.rect.minX, y: cell.rect.minY)
            } else {
                ShimmerPlaceholder()
                    .frame(width: cell.rect.width, height: cell.rect.height)
                    .clipped()
                    .offset(x: cell.rect.minX, y: cell.rect.minY)
            }
        }
    }

    private func color(from rgba: RGBA) -> Color {
        Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    // MARK: - Selection overlay (outline, capsules, corner handles)

    @ViewBuilder
    private func selectionOverlay(cell: CellFrame, path: [Int], gutterPts: Double) -> some View {
        let owners = edgeOwners(forLeafPath: path, root: state.document.root)

        Rectangle()
            .strokeBorder(Color.mosaicAccent, lineWidth: 2)
            .shadow(color: .black.opacity(0.35), radius: 0.5)
            .frame(width: cell.rect.width, height: cell.rect.height)
            .offset(x: cell.rect.minX, y: cell.rect.minY)

        ForEach(Array(capsuleSpecs(cellRect: cell.rect, owners: owners, gutterPts: gutterPts).enumerated()), id: \.offset) { _, spec in
            Capsule()
                .fill(Color.mosaicAccent)
                .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 0.5)
                .frame(width: spec.rect.width, height: spec.rect.height)
                .position(x: spec.rect.midX, y: spec.rect.midY)
        }

        ForEach(Array(cornerHandleSpecs(cellRect: cell.rect, owners: owners, gutterPts: gutterPts).enumerated()), id: \.offset) { _, spec in
            Circle()
                .fill(Color.mosaicAccent)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 0.5)
                .frame(width: 16, height: 16)
                .position(x: spec.center.x, y: spec.center.y)
        }
    }

    // MARK: - Composition brackets (always visible)

    private struct BracketShape: Shape {
        let corner: BracketCorner

        func path(in rect: CGRect) -> Path {
            var p = Path()
            let len = min(rect.width, rect.height)
            switch corner {
            case .topLeft:
                p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
            case .topRight:
                p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
            case .bottomLeft:
                p.move(to: CGPoint(x: rect.minX, y: rect.maxY - len))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX + len, y: rect.maxY))
            case .bottomRight:
                p.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
            }
            return p
        }
    }

    /// Origin (top-left) to place a 22x22 bracket box so that its vertex
    /// corner lands exactly on `anchor`.
    private func bracketBoxOrigin(_ corner: BracketCorner, anchor: CGPoint, size: CGFloat) -> CGPoint {
        switch corner {
        case .topLeft: return anchor
        case .topRight: return CGPoint(x: anchor.x - size, y: anchor.y)
        case .bottomLeft: return CGPoint(x: anchor.x, y: anchor.y - size)
        case .bottomRight: return CGPoint(x: anchor.x - size, y: anchor.y - size)
        }
    }

    private var bracketsOverlay: some View {
        ForEach(BracketCorner.allCases, id: \.self) { corner in
            let anchor = bracketAnchor(corner, canvasSize: state.canvasSize)
            let origin = bracketBoxOrigin(corner, anchor: anchor, size: 22)
            BracketShape(corner: corner)
                .stroke(Color.mosaicAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .square))
                .shadow(color: .black.opacity(0.35), radius: 0.5)
                .frame(width: 22, height: 22)
                .offset(x: origin.x, y: origin.y)
        }
    }

    // MARK: - Swap overlay

    @ViewBuilder
    private func swapOverlay(swap: SwapState, cells: [CellFrame]) -> some View {
        if let targetID = swap.hoveredTargetID, let targetCell = cells.first(where: { $0.id == targetID }) {
            Rectangle()
                .stroke(Color.mosaicAccent, lineWidth: 2)
                .frame(width: targetCell.rect.width, height: targetCell.rect.height)
                .offset(x: targetCell.rect.minX, y: targetCell.rect.minY)
        }

        if let ref = state.document.photos[swap.sourceID], let image = state.images[swap.sourceID] {
            cellContent(ref: ref, image: image, cellSize: swap.sourceCellRect.size)
                .scaleEffect(0.9)
                .opacity(0.9)
                .shadow(radius: 12)
                .frame(width: swap.sourceCellRect.width, height: swap.sourceCellRect.height)
                .position(x: swap.fingerLocation.x, y: swap.fingerLocation.y)
        }
    }
}

// MARK: - Phase 6 edge-state placeholders (additive view code only)

/// Restore is still fetching this photo's proxy/asset - a subtle animated
/// gradient sweep on the surface color, standing in for the missing image.
private struct ShimmerPlaceholder: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.mosaicSurface
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.14), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(geo.size.width, geo.size.height) * 0.6)
                .offset(x: sweep ? geo.size.width : -geo.size.width)
            }
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

/// The source asset was deleted from the library since this document was
/// last autosaved (PRD: "Photo unavailable... tap to replace"). Selection
/// still works over this cell (see `photoCell`'s doc comment); EditorView
/// additionally opens the Replace sheet directly on selecting one of these.
private struct UnavailablePlaceholder: View {
    var body: some View {
        ZStack {
            Color.mosaicSurface
            VStack(spacing: 6) {
                Image(systemName: "photo.slash")
                    .font(.system(size: 22, weight: .medium))
                Text("Photo unavailable")
                    .font(.system(size: 12, weight: .semibold))
                Text("Tap to replace")
                    .font(.system(size: 11))
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
        }
    }
}
