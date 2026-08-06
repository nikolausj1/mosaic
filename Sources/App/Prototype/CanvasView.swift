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
    /// #1F6BE8 (Justin, 2026-07-26) - a deeper, more saturated blue in the
    /// same lockup family, for spots that need real contrast against white
    /// text rather than the lighter `mosaicAccent`'s wash: the picker's
    /// enabled CTA fill and the selected-thumbnail radial gradient (see
    /// `PickerView.swift`). `mosaicAccent` itself is untouched - every
    /// existing use of it (brackets, strokes, links) keeps its original
    /// color.
    static let mosaicAccentDeep = Color(red: 0.12, green: 0.42, blue: 0.91)
}

// MARK: - Coach mark geometry preference (Justin, 2026-07-26)

/// Carries the real-geometry anchors the first-entry teach needs - the
/// canvas CENTER, the divider capsule, and a canvas composition bracket - up
/// the view tree from CanvasView (which computes them; see its "Coach mark
/// geometry export" section) to EditorView. Originally built for the
/// single-screen spotlight coach marks (which punched cutout holes over two
/// rects: the divider capsule and the interior corner handle); reused by the
/// ghost gesture demo that replaced them (Justin, 2026-07-26) - EditorView
/// resolves these into screen coordinates via a GeometryReader and uses them
/// to place the ghost fingertip instead. The `corner` field was swapped for
/// `bracket` (Justin, 2026-07-27): the demo's phase 1 now drags a canvas
/// BRACKET vertex, not the interior corner handle (which, in a 2x2 grid,
/// reads as "the middle point moving" - not what the demo should teach; see
/// `centralDivider`'s doc comment in GestureController.swift). `center` was
/// added the same day (Justin, 2026-07-27): the demo now fades the fingertip
/// in at the canvas's true center FIRST, before gliding to the bracket, so
/// the user has a beat to register what they're looking at - see
/// EditorView's `runGhostGestureDemo`. Chosen over publishing raw CGRects on
/// EditorState because an Anchor<CGRect>, unlike a plain rect, resolves
/// correctly regardless of the transforms/offsets/frames sitting between the
/// two views (CanvasView's own centering GeometryReader, EditorView's
/// VStack, etc.) - no manual coordinate-space bookkeeping needed on either
/// end.
struct CoachMarkAnchors {
    var center: Anchor<CGRect>?
    var divider: Anchor<CGRect>?
    var bracket: Anchor<CGRect>?
    /// The canvas's own full bounds (Justin, 2026-08-05: added for the ghost
    /// demo's focus scrim rework - see CoachMarks.swift's "Focus scrim"
    /// section). Unlike the three targets above, this isn't a 44pt hit-zone
    /// marker; it's the exact rect `canvasContent` occupies, published the
    /// same anchor-based way so the scrim's cutout tracks a live reshape
    /// (e.g. the bracket phase growing the canvas) exactly like the fingertip
    /// already tracks the bracket/divider targets - no separate measurement.
    var canvas: Anchor<CGRect>?
}

struct CoachMarkAnchorsKey: PreferenceKey {
    static var defaultValue = CoachMarkAnchors(center: nil, divider: nil, bracket: nil, canvas: nil)

    /// Each of the four marker views in `coachMarkAnchorMarkers` sets only
    /// one field and leaves the others nil, so a plain "keep whichever side
    /// is already non-nil, else take the incoming one" merge is enough -
    /// no risk of one marker's real value overwriting another's.
    static func reduce(value: inout CoachMarkAnchors, nextValue: () -> CoachMarkAnchors) {
        let next = nextValue()
        if value.center == nil { value.center = next.center }
        if value.divider == nil { value.divider = next.divider }
        if value.bracket == nil { value.bracket = next.bracket }
        if value.canvas == nil { value.canvas = next.canvas }
    }
}

struct CanvasView: View {
    let state: EditorState
    /// B32: true while the Magic Layout sequence is still playing over the
    /// top of this editor. Holds the always-on overlay chrome back so it can
    /// arrive as part of the sequence's handoff rather than being revealed
    /// mid-morph when the scrim lifts. Always false outside a fresh pick
    /// (restore, `-protoLayout`, Reduce Motion, any skip), so the normal
    /// editor is completely unaffected.
    var chromeHeldForMagicLayout: Bool = false
    var onReady: (() -> Void)?

    @State private var controller: GestureController?
    @State private var didFireReady = false
    /// Live touch-point + center-pixel color for the loupe eyedropper
    /// (Justin, 2026-07-26) - nil whenever no touch is down while sampling
    /// is armed. See `samplingOverlay`/`loupeDragGesture` below.
    @State private var loupeTouch: LoupeTouch?

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
                // B32 Phase 0 - destination geometry export (see
                // MagicLayout.swift). The canvas is centered in this reader,
                // so its global rect is derivable exactly, without an anchor:
                // the reader's own global frame plus the canvas's known size,
                // centered. Publishing the RECT rather than an
                // `Anchor<CGRect>` also sidesteps the ordering trap the coach
                // marks hit below - there is no way for this value to
                // accidentally describe the `.position` wrapper's full-bleed
                // frame instead of the canvas.
                .preference(key: EditorCanvasFrameKey.self, value: canvasGlobalRect(in: geo))
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

    /// The canvas rect in GLOBAL (window) coordinates - the same space
    /// `PickedThumbFramesKey` publishes the picker's thumbnails in, so the
    /// Magic Layout overlay can morph between the two without any coordinate
    /// bookkeeping of its own. Offsetting `solve()`'s cell rects by this
    /// origin lands them exactly on the cells `canvasContent` draws, which is
    /// what makes the sequence's final frame identical to the editor's first.
    private func canvasGlobalRect(in geo: GeometryProxy) -> CGRect {
        let container = geo.frame(in: .global)
        let size = state.canvasSize
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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

            // Always-on hairline canvas edge (Justin, 2026-07-17): 1px at
            // ~12% white so the canvas boundary - and especially a BLACK
            // border - stays legible against the #0B0B0D surround. UI
            // chrome only; the export renders nothing for this.
            Rectangle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: state.canvasSize.width, height: state.canvasSize.height)

            // Overlay chrome hides while the Border tray is active - not just
            // mid-slider-drag anymore (Justin, 2026-07-26: the old
            // isAdjustingBorder-only gate is now one case of the broader
            // hideOverlayChrome below) - so the border itself is what's
            // visible (accent capsules/outline sit exactly on the seams
            // being adjusted, and the brackets crowd the outer margin).
            if !hideOverlayChrome {
                // Divider/corner affordances (Justin, 2026-07-26: restored to
                // always-on): with the zero-border default the seams between
                // photos are invisible, so these render for EVERY cell, not
                // just a selected one, or nothing hints the layout is
                // draggable. The cell's own selection stroke stays
                // selection-gated below - only these drag affordances lost
                // their selection requirement.
                //
                // B32 handoff: `chromeHeldForMagicLayout` fades and scales
                // this whole group in at the END of the arrival sequence
                // (opacity + a small outward scale, animated by whatever
                // `withAnimation` the controller flips the flag inside), so
                // the controls visibly ARRIVE as the theater visibly leaves.
                // Deliberately opacity rather than an `if`: the affordances
                // keep their exact geometry and hit areas throughout, and a
                // touch during the sequence is already caught by the
                // overlay's own skip catcher above them.
                Group {
                    dividerAffordancesOverlay(cells: cells, gutterPts: gutterPts)

                    if let selection = state.selection,
                       let cell = cells.first(where: { $0.id == selection }) {
                        selectionStrokeOverlay(cell: cell)
                    }

                    bracketsOverlay
                }
                .opacity(chromeHeldForMagicLayout ? 0 : 1)
                .scaleEffect(chromeHeldForMagicLayout ? 1.035 : 1)
            }

            // Coach-mark geometry export (Justin, 2026-07-26): invisible,
            // always computed regardless of `hideOverlayChrome` so the
            // anchors stay live the moment the Border tray closes again.
            // See the "Coach mark geometry export" section below.
            coachMarkAnchorMarkers(cells: cells, gutterPts: gutterPts)

            if let swap = state.swapState {
                swapOverlay(swap: swap, cells: cells)
            }

            // B11 eyedropper (Justin, 2026-07-26): topmost while armed, so
            // it wins hit-testing over the drag/magnify gestures below - one
            // tap samples the composited pixel, the hint capsule cancels.
            if state.isSamplingColor {
                samplingOverlay
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
        // (Design revision 2026-07-17: the Phase 4 tap-closes-tray gesture
        // is gone - trays are document-level and now coexist with selection;
        // EditorView's dead-space catcher handles deselect + tray dismissal.)
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

    // MARK: - Chrome visibility (Justin, 2026-07-26)

    /// True while the Border tray is being judged - either it's simply open
    /// (`activeTray == .border`) or a Thickness/Radius slider inside it is
    /// mid-drag (`isAdjustingBorder`, the older and narrower signal this
    /// extends). Gates every piece of interactive overlay chrome (selection
    /// stroke, divider capsules, corner handles, composition brackets) so
    /// the canvas reads clean the whole time Border is the active tab, not
    /// just during a live slider drag. Both `isAdjustingBorder` and
    /// `activeTray` are @Observable properties, and every place that flips
    /// them (BorderTrayView's slider, EditorBottomBar's tab buttons) already
    /// wraps the mutation in `withAnimation`, so the conditional views below
    /// get their default opacity-fade transition for free - no explicit
    /// `.transition` needed here.
    private var hideOverlayChrome: Bool {
        state.isAdjustingBorder || state.activeTray == .border
    }

    // MARK: - Selection stroke (selection-gated, as before)

    private func selectionStrokeOverlay(cell: CellFrame) -> some View {
        Rectangle()
            .strokeBorder(Color.mosaicAccent, lineWidth: 2)
            .shadow(color: .black.opacity(0.35), radius: 0.5)
            .frame(width: cell.rect.width, height: cell.rect.height)
            .offset(x: cell.rect.minX, y: cell.rect.minY)
    }

    // MARK: - Divider/corner affordances (always-on, not selection-gated)

    /// Renders every cell's owned divider capsules and corner handles -
    /// NOT just the selected cell's (Justin, 2026-07-26: previously this was
    /// nested inside the `if let selection` branch of the old
    /// `selectionOverlay`, so the drag affordances vanished entirely with
    /// nothing selected). Each interior divider sits on the boundary between
    /// two sibling cells, so it is "owned" by exactly one of them per
    /// `edgeOwners`' deepest-ancestor rule - but since both siblings run the
    /// same math independently here, a divider each of them owns an edge of
    /// (e.g. a shared corner in a 2x2 grid) draws its capsule/handle from
    /// more than one cell, all landing on the exact same seam coordinates.
    /// That's harmless (identical opaque shapes stacked exactly on top of
    /// each other) and simpler than threading a global divider list through
    /// just to dedupe. `gutterPts` is 0 at the zero-border default - the
    /// specs already float exactly on the touching-photo seam in that case
    /// (unchanged math), so no adjustment was needed for hit areas.
    private func dividerAffordancesOverlay(cells: [CellFrame], gutterPts: Double) -> some View {
        ForEach(cells, id: \.id) { cell in
            if let path = leafPath(for: cell.id, in: state.document.root) {
                let owners = edgeOwners(forLeafPath: path, root: state.document.root)

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
        }
    }

    // MARK: - Coach mark geometry export (Justin, 2026-07-26)

    /// The rects the first-entry teach cares about - the canvas's true
    /// center point, the divider capsule closest to it ("most central/first
    /// divider" per the original coach-marks brief), and the TOP-RIGHT
    /// composition bracket vertex - in CANVAS-LOCAL coordinates (same space
    /// as `cell.rect`/`capsuleSpecs`/`bracketAnchor` above). Already sized to
    /// the same comfortable hit-zone conventions `classifyTouch` uses (44pt
    /// capsule band, 44x44 bracket square) rather than inventing new padding
    /// numbers. Originally these sized the old spotlight coach marks' cutout
    /// holes; now they're just where the anchor markers below sit, which is
    /// what the ghost gesture demo's fingertip tracks (Justin, 2026-07-26).
    /// `divider` is nil for a layout with no interior divider at all (a
    /// single-photo canvas); the demo skips its divider phase then (see
    /// EditorView's `centralDivider` usage). `bracket` is never nil - the
    /// composition brackets are always visible regardless of layout (see
    /// `bracketsOverlay` below), so the demo's phase always has somewhere to
    /// land. `bracket` moved from bottom-right to TOP-RIGHT (Justin,
    /// 2026-07-27 - "the upper right is more visible"); `center` is new the
    /// same day, a fixed 44x44 square straddling the canvas midpoint so the
    /// demo's opening beat has somewhere concrete to fade the fingertip in
    /// at before it glides anywhere.
    private func coachMarkTargetRects(cells: [CellFrame], gutterPts: Double) -> (center: CGRect, divider: CGRect?, bracket: CGRect) {
        let centerPoint = CGPoint(x: state.canvasSize.width / 2, y: state.canvasSize.height / 2)
        var bestDivider: (rect: CGRect, dist: CGFloat)?

        for cell in cells {
            guard let path = leafPath(for: cell.id, in: state.document.root) else { continue }
            let owners = edgeOwners(forLeafPath: path, root: state.document.root)

            for spec in capsuleSpecs(cellRect: cell.rect, owners: owners, gutterPts: gutterPts) {
                let hitZone = capsuleHitZone(spec)
                let d = hypot(hitZone.midX - centerPoint.x, hitZone.midY - centerPoint.y)
                if bestDivider == nil || d < bestDivider!.dist {
                    bestDivider = (hitZone, d)
                }
            }
        }

        let centerRect = CGRect(x: centerPoint.x - 22, y: centerPoint.y - 22, width: 44, height: 44)
        let bracketVertex = bracketAnchor(.topRight, canvasSize: state.canvasSize)
        let bracketRect = CGRect(x: bracketVertex.x - 22, y: bracketVertex.y - 22, width: 44, height: 44)
        return (centerRect, bestDivider?.rect, bracketRect)
    }

    /// Invisible markers (zero visual/hit-test footprint) placed exactly at
    /// `coachMarkTargetRects`' rects, each publishing its resolved
    /// `Anchor<CGRect>` via `CoachMarkAnchorsKey` - this is how EditorView
    /// gets real geometry instead of a screen-fraction guess. Anchors
    /// automatically re-resolve whenever layout changes (rotation, ratio
    /// change, bracket resize), so the overlay - if it happens to still be
    /// showing - would track a live layout change gracefully rather than
    /// freezing on stale coordinates.
    @ViewBuilder
    private func coachMarkAnchorMarkers(cells: [CellFrame], gutterPts: Double) -> some View {
        let targets = coachMarkTargetRects(cells: cells, gutterPts: gutterPts)
        ZStack {
            // anchorPreference must attach to the SIZED child, before
            // .position - .position wraps its child in a flexible frame that
            // fills the whole canvas, so attaching afterward publishes the
            // canvas bounds instead of the 44pt target (the giant-spotlight
            // bug caught in the 2026-07-26 review pass).
            Color.clear
                .frame(width: targets.center.width, height: targets.center.height)
                .anchorPreference(key: CoachMarkAnchorsKey.self, value: .bounds) { anchor in
                    CoachMarkAnchors(center: anchor, divider: nil, bracket: nil, canvas: nil)
                }
                .position(x: targets.center.midX, y: targets.center.midY)
            if let rect = targets.divider {
                Color.clear
                    .frame(width: rect.width, height: rect.height)
                    .anchorPreference(key: CoachMarkAnchorsKey.self, value: .bounds) { anchor in
                        CoachMarkAnchors(center: nil, divider: anchor, bracket: nil, canvas: nil)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
            Color.clear
                .frame(width: targets.bracket.width, height: targets.bracket.height)
                .anchorPreference(key: CoachMarkAnchorsKey.self, value: .bounds) { anchor in
                    CoachMarkAnchors(center: nil, divider: nil, bracket: anchor, canvas: nil)
                }
                .position(x: targets.bracket.midX, y: targets.bracket.midY)
            // Full canvas bounds (Justin, 2026-08-05, focus scrim rework):
            // sized and positioned to exactly cover `canvasContent`'s own
            // frame (state.canvasSize, centered on itself - matching the
            // border Rectangle/hairline edge drawn at the same size right
            // above in canvasContent's ZStack) rather than one of the small
            // 44pt hit-zones above.
            Color.clear
                .frame(width: state.canvasSize.width, height: state.canvasSize.height)
                .anchorPreference(key: CoachMarkAnchorsKey.self, value: .bounds) { anchor in
                    CoachMarkAnchors(center: nil, divider: nil, bracket: nil, canvas: anchor)
                }
                .position(x: state.canvasSize.width / 2, y: state.canvasSize.height / 2)
        }
    }

    // MARK: - B11 loupe eyedropper overlay (Justin, 2026-07-26 rework)

    /// Full-canvas drag catcher while `state.isSamplingColor`: touching and
    /// dragging floats a magnifying loupe over the fingertip (see
    /// `LoupeView` below) that tracks the live composited color under its
    /// center; releasing - whether after a drag or a plain tap, both land
    /// here since the gesture's `minimumDistance` is 0 - applies that pixel
    /// as the border color. The hint capsule at the top doubles as the
    /// cancel button, and sits LAST in this ZStack (drawn on top) so it
    /// keeps first claim on its own taps despite the drag gesture's
    /// full-canvas hit-testing shape underneath - unchanged hit-test order
    /// from the original one-tap sampler. Sits above every other layer in
    /// `canvasContent`'s ZStack so the editor's own drag/magnify gestures
    /// never fire while armed.
    private var samplingOverlay: some View {
        ZStack(alignment: .top) {
            Color.white.opacity(0.001)
                .frame(width: state.canvasSize.width, height: state.canvasSize.height)
                .contentShape(Rectangle())
                .gesture(loupeDragGesture)

            if let loupe = loupeTouch {
                LoupeView(composite: state.samplingComposite, canvasSize: state.canvasSize, touchPoint: loupe.location, centerColor: loupe.centerColor)
                    .position(loupeDisplayPosition(for: loupe.location))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { state.endColorSampling() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Drag to sample a color")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.mosaicAccentDeep, lineWidth: 1))
            }
            .padding(.top, 10)
        }
        .transition(.opacity)
    }

    /// `minimumDistance: 0` so a plain tap (no movement at all) still
    /// delivers both `onChanged` (loupe appears) and `onEnded` (sample +
    /// apply) - "a simple tap... should also work: show the loupe briefly
    /// at the tap point and apply on release" per the brief.
    private var loupeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in updateLoupe(at: value.location) }
            .onEnded { value in
                let p = normalizedSamplePoint(value.location)
                withAnimation(.easeInOut(duration: 0.12)) { loupeTouch = nil }
                // `applySampledColor` is `async` (Justin, 2026-07-27) so it
                // can wait out an in-flight composite render on a fast
                // release rather than silently failing - see its doc
                // comment in EditorState.swift.
                Task { await state.applySampledColor(atNormalized: p) }
            }
    }

    private func updateLoupe(at location: CGPoint) {
        let p = normalizedSamplePoint(location)
        let color: Color
        if let composite = state.samplingComposite, let rgba = EditorState.pixelColor(in: composite, atNormalized: p) {
            color = Color(red: rgba.r, green: rgba.g, blue: rgba.b)
        } else {
            // Composite hasn't resolved yet (arm-to-first-touch race, rare
            // given the render is near-instant off already-decoded
            // proxies) - a neutral placeholder ring rather than stale color.
            color = Color.white.opacity(0.4)
        }
        loupeTouch = LoupeTouch(location: location, centerColor: color)
    }

    /// Canvas-local touch point -> normalized (0...1) sample point, clamped
    /// so a drag that overshoots the canvas edge still samples the nearest
    /// valid pixel rather than nothing.
    private func normalizedSamplePoint(_ location: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(location.x / max(state.canvasSize.width, 1), 0), 1),
            y: min(max(location.y / max(state.canvasSize.height, 1), 0), 1)
        )
    }

    /// The loupe floats ~70pt off the fingertip, above it by default; near
    /// the top edge (where floating above would push it off-screen) it
    /// flips below instead - "Edge cases: touch near the top edge - keep
    /// the loupe on-screen" per the brief. 130 = the 70pt offset + half the
    /// loupe's ~96pt diameter + a small margin.
    private func loupeDisplayPosition(for location: CGPoint) -> CGPoint {
        let flipBelow = location.y < 130
        return CGPoint(x: location.x, y: location.y + (flipBelow ? 70 : -70))
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

// MARK: - Loupe eyedropper (Justin, 2026-07-26)

/// Live state for the loupe eyedropper's current touch - `location` is
/// canvas-local (same space as `cell.rect`), `centerColor` is the LIVE
/// composited color under the loupe's center, recomputed on every
/// touch-move (see CanvasView.updateLoupe).
private struct LoupeTouch {
    var location: CGPoint
    var centerColor: Color
}

/// The magnifier itself: a ~96pt circle showing a ~7-8x crop of the cached
/// sampling composite centered on `touchPoint`, a thin crosshair marking the
/// exact sample point, and a border ring painted with `centerColor` (the
/// live pixel that would apply if released right now). Purely a rendering
/// view - `centerColor` and the eventual applied color both come from
/// `EditorState.pixelColor`, never computed here.
private struct LoupeView: View {
    /// The one-time composite EditorState.beginColorSampling rendered when
    /// sampling armed - nil for the brief window before it resolves.
    let composite: UIImage?
    /// Canvas size, needed to map `touchPoint` (canvas-local points) into
    /// the composite's own pixel space (composite and canvas share the same
    /// aspect, just different absolute scale).
    let canvasSize: CGSize
    let touchPoint: CGPoint
    let centerColor: Color

    private let diameter: CGFloat = 96
    private let magnification: CGFloat = 7.5

    var body: some View {
        ZStack {
            magnifiedContent
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            crosshair
            Circle()
                .strokeBorder(centerColor, lineWidth: 4)
                .frame(width: diameter, height: diameter)
            Circle()
                .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                .frame(width: diameter + 4, height: diameter + 4)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
        .frame(width: diameter, height: diameter)
    }

    /// Position math: `touchPoint` normalized against the CANVAS gives the
    /// same normalized point in the composite (they share an aspect); that
    /// normalized point converted to the composite's own pixel size gives
    /// the center of the region to magnify. The composite `Image` is scaled
    /// up by `magnification` and offset so that exact point lands under the
    /// loupe's own center - clipped to the circle above, so only the small
    /// magnified disc around the touch point is ever visible. The sample
    /// region is clamped to the composite's bounds ("canvas edges - clamp
    /// the magnified sample region" per the brief) so a touch near an edge
    /// still shows real content, not a transparent gap - the CENTER pixel
    /// actually applied on release still reads the true (unclamped) point
    /// via `EditorState.pixelColor`, which does its own separate clamp, so
    /// accuracy at the edge is unaffected by this purely visual clamp.
    @ViewBuilder
    private var magnifiedContent: some View {
        if let composite, canvasSize.width > 0, canvasSize.height > 0 {
            let imgSize = composite.size
            let nx = touchPoint.x / canvasSize.width
            let ny = touchPoint.y / canvasSize.height
            let rawCX = nx * imgSize.width
            let rawCY = ny * imgSize.height
            let halfViewport = (diameter / 2) / magnification
            let cx = min(max(rawCX, halfViewport), max(imgSize.width - halfViewport, halfViewport))
            let cy = min(max(rawCY, halfViewport), max(imgSize.height - halfViewport, halfViewport))

            // `.position` places the (huge, magnified) image's own CENTER at
            // an absolute point within this diameter x diameter frame -
            // unambiguous, unlike stacking `.offset` on top of a default
            // centered `.frame` alignment. The image's center sits (cx,cy) -
            // (imgW/2, imgH/2) [scaled by `magnification`] away from the
            // sample point, so placing the image's center at the loupe's own
            // center MINUS that same vector cancels it out, landing the
            // sample point exactly at (diameter/2, diameter/2).
            let targetX = diameter / 2 - (cx - imgSize.width / 2) * magnification
            let targetY = diameter / 2 - (cy - imgSize.height / 2) * magnification

            ZStack {
                Image(uiImage: composite)
                    .resizable()
                    .frame(width: imgSize.width * magnification, height: imgSize.height * magnification)
                    .position(x: targetX, y: targetY)
            }
            .frame(width: diameter, height: diameter)
            .clipped()
        } else {
            Color.mosaicSurface
        }
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 16, height: 1.25)
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.25, height: 16)
            Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5).frame(width: 16, height: 16)
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
