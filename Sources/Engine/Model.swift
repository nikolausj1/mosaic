// The document model, verbatim from PRD §8. Pure Foundation - no SwiftUI, ever.
// The whole document is a tiny value type; undo is a snapshot stack of these.
import Foundation

typealias PhotoID = UUID

struct Ratio: Codable, Equatable {
    var width: Double
    var height: Double

    var value: Double { width / height }

    static let square = Ratio(width: 1, height: 1)
}

struct Document: Codable, Equatable {
    var canvasRatio: Ratio
    var root: Node
    var photos: [PhotoID: PhotoRef]
    var border: BorderStyle
}

enum Axis: String, Codable {
    case horizontal   // children side by side; dividers are vertical lines
    case vertical     // children stacked; dividers are horizontal lines
}

indirect enum Node: Codable, Equatable {
    case leaf(PhotoID)
    case split(axis: Axis, fractions: [Double], children: [Node])
}
// INVARIANTS (enforced by every mutating operation, checked by the smoke test):
//   fractions.count == children.count, and >= 2
//   fractions.sum() == 1.0 (renormalize after every mutation)
//   every fraction >= Layout.minCellFraction (0.10)
//   leaf count == photos.count, and is in 2...4
// n-way splits, not binary: "3 columns" is ONE node with 3 children and 2 dividers.
// Dragging divider i is zero-sum against fractions[i] and fractions[i+1] only.

struct PhotoRef: Codable, Equatable {
    var assetLocalIdentifier: String   // PHAsset local identifier
    var pixelWidth: Int                // source dimensions, pre-rotation
    var pixelHeight: Int
    var zoom: Double                   // 1.0 == aspect-fill. INVARIANT: 1.0...8.0
    var center: CGPoint                // normalized 0...1 in the photo's own space
    var flipH: Bool
    var flipV: Bool
    var quarterTurns: Int              // 0...3; odd values swap effective width/height
    var isAuto: Bool                   // true on arrival; any pan/pinch sets false
    var roi: ROI?                      // cached Vision result; nil if nothing detected
}
// INVARIANT: `center` is clamped after EVERY mutation (pan, zoom, ratio change,
// divider drag, topology change) such that the photo still fully covers its cell.
// This is the mechanism behind Principle 3 / success criterion S5. No exceptions.

struct ROI: Codable, Equatable {
    var center: CGPoint     // faces (biased upward) if any survive thresholds, else saliency centroid
    var zoom: Double        // from the SALIENCY box only, never faces. 1.0...2.0
}

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
}

struct BorderStyle: Codable, Equatable {
    var inner: Double        // FRACTION OF THE CANVAS SHORT EDGE, 0...0.15 - never points
    var outer: Double        // same units
    var linked: Bool         // default true
    var cornerRadius: Double // same units
    var color: RGBA

    static let none = BorderStyle(inner: 0, outer: 0, linked: true, cornerRadius: 0, color: .white)
}
// Border thickness is stored as a fraction of the canvas short edge so it scales
// automatically from the on-screen canvas to a 4096px export. The UI presents 0-100.
