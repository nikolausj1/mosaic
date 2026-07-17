// Sources/App/Prototype/EditorState.swift
// The single source of truth for the prototype editor. Owns the document,
// undo/redo, selection, and the transient overlay state GestureController /
// CanvasView read and write. Snapshot rule (PRD): push undo ON GESTURE END
// ONLY - one snapshot per completed pan/pinch/divider/corner/bracket
// drag/swap/layout-cycle - never mid-gesture. Selection changes never
// snapshot. Any new mutation clears the redo stack.
import Observation
import UIKit
import CoreGraphics

@Observable
final class EditorState {

    // MARK: - Persistent state

    var document: Document
    private(set) var undoStack: [Document] = []
    private(set) var redoStack: [Document] = []
    var selection: PhotoID?
    let images: [PhotoID: UIImage]
    let haptics = Haptics()

    let photoStore: PhotoStore
    private(set) var layoutIndex: Int

    static let undoCap = 50

    // MARK: - Canvas sizing

    /// Space available to fit the canvas ratio into. CanvasView writes this
    /// after subtracting the 28pt bracket-clearance padding on every side.
    var containerSize: CGSize = .zero

    /// Non-nil only while a bracket drag is live: overrides the normal
    /// fit-to-container size so the canvas can grow/shrink directly under
    /// the finger. Cleared (animated back to the fitted size) on release.
    var liveCanvasSize: CGSize?

    var canvasSize: CGSize {
        liveCanvasSize ?? Self.fitSize(ratio: document.canvasRatio.value, in: containerSize)
    }

    var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    static func fitSize(ratio: Double, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0, ratio > 0, ratio.isFinite else { return .zero }
        let boxRatio = box.width / box.height
        if ratio > boxRatio {
            return CGSize(width: box.width, height: box.width / ratio)
        } else {
            return CGSize(width: box.height * ratio, height: box.height)
        }
    }

    // MARK: - Transient gesture overlay state

    /// Non-nil only while a swap drag is in flight; read by CanvasView to
    /// render the dimmed source cell, the proxy thumbnail, and the hovered
    /// target outline.
    var swapState: SwapState?

    // MARK: - Debug event ticker (prototype only)

    /// Rolling log of gesture-classification events, rendered as an on-screen
    /// HUD so gesture bugs can be diagnosed from the device itself. Remove
    /// with the rest of the prototype scaffolding after Phase 2 sign-off.
    private(set) var debugEvents: [String] = []
    private var debugCounter = 0

    func debugLog(_ message: String) {
        debugCounter += 1
        debugEvents.append("\(debugCounter) \(message)")
        if debugEvents.count > 7 { debugEvents.removeFirst() }
    }

    // MARK: - Gesture snapshot lifecycle

    private var gestureStartDocument: Document?

    init(document: Document, images: [PhotoID: UIImage], photoStore: PhotoStore, layoutIndex: Int) {
        self.document = document
        self.images = images
        self.photoStore = photoStore
        self.layoutIndex = layoutIndex
    }

    /// Call once at the very start of any gesture that might mutate
    /// `document` (pan/pinch/divider/corner/bracket/swap). Idempotent: a
    /// second call while one is already in flight (e.g. drag + magnify
    /// both firing for a two-finger gesture) is a no-op.
    func beginGesture() {
        guard gestureStartDocument == nil else { return }
        gestureStartDocument = document
    }

    /// Call at gesture end. Pushes the pre-gesture snapshot iff the
    /// document actually changed; always clears the in-flight marker.
    /// Safe to call even when nothing happened (e.g. a plain tap, or a
    /// swap released over empty space) - it simply won't push anything.
    func commitGesture() {
        defer { gestureStartDocument = nil }
        guard let start = gestureStartDocument, start != document else { return }
        pushUndo(start)
    }

    /// Abandons an in-flight gesture, restoring `document` to whatever it
    /// was before the gesture began. Used when a pinch pre-empts a
    /// still-undecided tracking/pan.
    func cancelGesture() {
        defer { gestureStartDocument = nil }
        guard let start = gestureStartDocument else { return }
        document = start
    }

    private func pushUndo(_ doc: Document) {
        undoStack.append(doc)
        if undoStack.count > Self.undoCap { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: - Undo / redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        if redoStack.count > Self.undoCap { redoStack.removeFirst() }
        document = previous
        sanitizeSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        if undoStack.count > Self.undoCap { undoStack.removeFirst() }
        document = next
        sanitizeSelection()
    }

    private func sanitizeSelection() {
        if let sel = selection, document.photos[sel] == nil {
            selection = nil
        }
    }

    // MARK: - Cycle

    /// Cycles `templates(for:)` for the CURRENT photo count, using the
    /// CURRENT document's own leaf order (not re-run through
    /// contentFitAssignment/autoFrame - per the PRD's topology-change rule,
    /// photos keep their existing zoom/center on a plain layout cycle; only
    /// reclampAll runs). One undo snapshot per cycle.
    func cycleLayout() {
        let currentIDs = photoIDs(in: document.root)
        let candidates = templates(for: currentIDs)
        guard !candidates.isEmpty else { return }
        let nextIndex = (layoutIndex + 1) % candidates.count

        var doc = document
        doc.root = candidates[nextIndex]
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        layoutIndex = nextIndex
        document = doc
        pushUndo(old)
    }

    // MARK: - Auto-frame toggle

    /// Toggles the selected photo between its cached auto-frame ROI and a
    /// plain center/fill crop. One undo snapshot per toggle.
    func toggleAuto() {
        guard let sel = selection, let photo = document.photos[sel] else { return }

        var updated = photo
        if photo.isAuto {
            updated.center = CGPoint(x: 0.5, y: 0.5)
            updated.zoom = 1.0
            updated.isAuto = false
        } else if let roi = photo.roi {
            updated.center = roi.center
            updated.zoom = roi.zoom
            updated.isAuto = true
        } else {
            updated.center = CGPoint(x: 0.5, y: 0.5)
            updated.zoom = 1.0
            updated.isAuto = false
        }

        var doc = document
        doc.photos[sel] = updated
        doc = reclampAll(doc, canvasSize: canvasSize)

        let old = document
        document = doc
        pushUndo(old)
    }
}

/// Live swap-drag overlay state. `sourceID`/`sourceCellRect` are fixed for
/// the duration of the drag; `fingerLocation` and `hoveredTargetID` update
/// on every move.
struct SwapState {
    let sourceID: PhotoID
    let sourceCellRect: CGRect
    var fingerLocation: CGPoint
    var hoveredTargetID: PhotoID?
}
