// Sources/App/Prototype/PhotoStore.swift
// Loads the four prototype photos (proto1...proto4), falling back to a
// programmatic gradient placeholder when the (gitignored) jpgs are absent -
// e.g. on a fresh clone that hasn't dropped the test photos in yet. Also
// builds the four fixed Documents the "Cycle" button walks through.
import UIKit
import CoreGraphics

struct PhotoStore {

    struct Entry {
        let id: PhotoID
        let ref: PhotoRef
        let image: UIImage
    }

    /// Always exactly 4 entries, in proto1...proto4 order.
    let entries: [Entry]

    init() {
        entries = (1...4).map { i in
            let name = "proto\(i)"
            let image = PhotoStore.loadImage(named: name) ?? PhotoStore.placeholder(index: i)
            let pixelSize = PhotoStore.pixelSize(of: image)
            let ref = PhotoRef(
                assetLocalIdentifier: name,
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height),
                zoom: 1.0,
                center: CGPoint(x: 0.5, y: 0.5),
                flipH: false,
                flipV: false,
                quarterTurns: 0,
                isAuto: true,
                roi: nil
            )
            return Entry(id: PhotoID(), ref: ref, image: image)
        }
    }

    var imagesByID: [PhotoID: UIImage] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.image) })
    }

    /// Number of fixed prototype layouts to cycle through.
    static let layoutCount = 4

    /// Border shared by every prototype document: a visible 1% seam, no
    /// outer margin - an invisible seam would make divider-grabbing
    /// untestable in this prototype (PRD note carried in the task brief).
    static let prototypeBorder = BorderStyle(inner: 0.01, outer: 0, linked: true, cornerRadius: 0, color: .white)

    /// Builds one of the 4 fixed prototype documents. `index` is taken mod
    /// layoutCount so callers can cycle freely without bounds-checking.
    func document(forLayout index: Int) -> Document {
        let i = ((index % PhotoStore.layoutCount) + PhotoStore.layoutCount) % PhotoStore.layoutCount
        let ids = entries.map(\.id)
        let root: Node
        let usedIDs: [PhotoID]

        switch i {
        case 0:
            // 2-up
            root = .split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])])
            usedIDs = [ids[0], ids[1]]

        case 1:
            // Big-left + 2 stacked right
            root = .split(
                axis: .horizontal,
                fractions: [0.6, 0.4],
                children: [
                    .leaf(ids[0]),
                    .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[1]), .leaf(ids[2])])
                ]
            )
            usedIDs = [ids[0], ids[1], ids[2]]

        case 2:
            // 2x2, columns-first
            root = .split(
                axis: .horizontal,
                fractions: [0.5, 0.5],
                children: [
                    .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])]),
                    .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[2]), .leaf(ids[3])])
                ]
            )
            usedIDs = ids

        default:
            // 4 columns
            root = .split(axis: .horizontal, fractions: [0.25, 0.25, 0.25, 0.25], children: ids.map { .leaf($0) })
            usedIDs = ids
        }

        var photos: [PhotoID: PhotoRef] = [:]
        for entry in entries where usedIDs.contains(entry.id) {
            photos[entry.id] = entry.ref
        }

        return Document(canvasRatio: .square, root: root, photos: photos, border: PhotoStore.prototypeBorder)
    }

    // MARK: - Loading

    private static func loadImage(named name: String) -> UIImage? {
        // Primary path per spec: asset-catalog-style lookup.
        if let img = UIImage(named: name) {
            return img
        }
        // Fallback: XcodeGen may add the Prototype folder as loose resources
        // rather than flattening them into the bundle root - try both.
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Prototype"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        return nil
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// Solid dark grey base with a diagonal gradient in a distinct hue per
    /// index, ~1500x2000. Used only when the real prototype jpgs aren't in
    /// the bundle (they're gitignored, so absent on a fresh clone).
    private static func placeholder(index: Int) -> UIImage {
        let size = CGSize(width: 1500, height: 2000)
        let hues: [CGFloat] = [0.58, 0.08, 0.33, 0.83] // blue, orange, green, magenta
        let hue = hues[(index - 1) % hues.count]

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let darkGrey = UIColor(white: 0.14, alpha: 1.0).cgColor
            let tint = UIColor(hue: hue, saturation: 0.55, brightness: 0.5, alpha: 1.0).cgColor

            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [darkGrey, tint] as CFArray,
                locations: [0, 1]
            ) else {
                UIColor(white: 0.14, alpha: 1.0).setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                return
            }

            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
    }
}
