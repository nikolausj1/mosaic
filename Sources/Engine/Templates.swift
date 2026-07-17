// Sources/Engine/Templates.swift
// The PRD's locked topology set. Pure Foundation - builders taking the
// caller's [PhotoID] and returning ready-to-solve Node trees. Order within
// each count's list is part of the contract (Cycle walks it, tests pin it).
import Foundation

enum Templates {

    // MARK: - 2 photos (2 templates)

    /// index 0: side-by-side, two equal columns.
    static func sideBySide(_ ids: [PhotoID]) -> Node {
        .split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])])
    }

    /// index 1: stacked, two equal rows.
    static func stacked(_ ids: [PhotoID]) -> Node {
        .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])])
    }

    // MARK: - 3 photos (6 templates)

    /// index 0: 3 equal columns.
    static func threeColumns(_ ids: [PhotoID]) -> Node {
        let third = 1.0 / 3.0
        return .split(axis: .horizontal, fractions: [third, third, third], children: ids.map { .leaf($0) })
    }

    /// index 1: 3 equal rows.
    static func threeRows(_ ids: [PhotoID]) -> Node {
        let third = 1.0 / 3.0
        return .split(axis: .vertical, fractions: [third, third, third], children: ids.map { .leaf($0) })
    }

    /// index 2: big photo on the left, 2 stacked on the right.
    static func bigLeftTwoRight(_ ids: [PhotoID]) -> Node {
        .split(axis: .horizontal, fractions: [0.6, 0.4], children: [
            .leaf(ids[0]),
            .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[1]), .leaf(ids[2])])
        ])
    }

    /// index 3: mirror of bigLeftTwoRight - 2 stacked on the left, big photo on the right.
    static func bigRightTwoLeft(_ ids: [PhotoID]) -> Node {
        .split(axis: .horizontal, fractions: [0.4, 0.6], children: [
            .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])]),
            .leaf(ids[2])
        ])
    }

    /// index 4: big photo on top, 2 side-by-side on the bottom.
    static func bigTopTwoBottom(_ ids: [PhotoID]) -> Node {
        .split(axis: .vertical, fractions: [0.6, 0.4], children: [
            .leaf(ids[0]),
            .split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(ids[1]), .leaf(ids[2])])
        ])
    }

    /// index 5: mirror of bigTopTwoBottom - 2 side-by-side on top, big photo on the bottom.
    static func bigBottomTwoTop(_ ids: [PhotoID]) -> Node {
        .split(axis: .vertical, fractions: [0.4, 0.6], children: [
            .split(axis: .horizontal, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])]),
            .leaf(ids[2])
        ])
    }

    // MARK: - 4 photos (8 templates)

    /// index 0: 2x2, columns-first (each column is its own vertical split).
    static func twoByTwoColumnsFirst(_ ids: [PhotoID]) -> Node {
        .split(axis: .horizontal, fractions: [0.5, 0.5], children: [
            .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[0]), .leaf(ids[1])]),
            .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[2]), .leaf(ids[3])])
        ])
    }

    /// index 1: 4 equal columns.
    static func fourColumns(_ ids: [PhotoID]) -> Node {
        .split(axis: .horizontal, fractions: [0.25, 0.25, 0.25, 0.25], children: ids.map { .leaf($0) })
    }

    /// index 2: 4 equal rows.
    static func fourRows(_ ids: [PhotoID]) -> Node {
        .split(axis: .vertical, fractions: [0.25, 0.25, 0.25, 0.25], children: ids.map { .leaf($0) })
    }

    /// index 3: big photo on the left, 3 stacked on the right.
    static func bigLeftThreeRight(_ ids: [PhotoID]) -> Node {
        let third = 1.0 / 3.0
        return .split(axis: .horizontal, fractions: [0.62, 0.38], children: [
            .leaf(ids[0]),
            .split(axis: .vertical, fractions: [third, third, third], children: [.leaf(ids[1]), .leaf(ids[2]), .leaf(ids[3])])
        ])
    }

    /// index 4: mirror of bigLeftThreeRight - 3 stacked on the left, big photo on the right.
    static func bigRightThreeLeft(_ ids: [PhotoID]) -> Node {
        let third = 1.0 / 3.0
        return .split(axis: .horizontal, fractions: [0.38, 0.62], children: [
            .split(axis: .vertical, fractions: [third, third, third], children: [.leaf(ids[0]), .leaf(ids[1]), .leaf(ids[2])]),
            .leaf(ids[3])
        ])
    }

    /// index 5: big photo on top, 3 side-by-side on the bottom.
    static func bigTopThreeBottom(_ ids: [PhotoID]) -> Node {
        let third = 1.0 / 3.0
        return .split(axis: .vertical, fractions: [0.62, 0.38], children: [
            .leaf(ids[0]),
            .split(axis: .horizontal, fractions: [third, third, third], children: [.leaf(ids[1]), .leaf(ids[2]), .leaf(ids[3])])
        ])
    }

    /// index 6: mirror of bigTopThreeBottom - 3 side-by-side on top, big photo on the bottom.
    static func bigBottomThreeTop(_ ids: [PhotoID]) -> Node {
        let third = 1.0 / 3.0
        return .split(axis: .vertical, fractions: [0.38, 0.62], children: [
            .split(axis: .horizontal, fractions: [third, third, third], children: [.leaf(ids[0]), .leaf(ids[1]), .leaf(ids[2])]),
            .leaf(ids[3])
        ])
    }

    /// index 7: 1/2/1 sandwich - a tall leaf, a 2-up vertical split, a tall leaf.
    static func sandwich(_ ids: [PhotoID]) -> Node {
        .split(axis: .horizontal, fractions: [0.3, 0.4, 0.3], children: [
            .leaf(ids[0]),
            .split(axis: .vertical, fractions: [0.5, 0.5], children: [.leaf(ids[1]), .leaf(ids[2])]),
            .leaf(ids[3])
        ])
    }
}

/// All locked templates for `photos.count` photos, in PRD-fixed order.
/// The leaves are populated with `photos` in list order (photos[0] first, etc).
/// - 2 photos (2 templates): side-by-side, stacked.
/// - 3 photos (6 templates): 3 columns, 3 rows, big-left+2-right, big-right+2-left,
///   big-top+2-bottom, big-bottom+2-top.
/// - 4 photos (8 templates): 2x2 columns-first, 4 columns, 4 rows,
///   big-left+3-right, big-right+3-left, big-top+3-bottom, big-bottom+3-top, sandwich.
/// Leaf PhotoIDs of `node` in traversal order (left-to-right / top-to-bottom
/// through each split's children) - the same order `templates(for:)` uses to
/// place photos into a fresh template's slots. Shared by `contentFitAssignment`
/// and by the App layer's "Cycle" (which re-templates the CURRENT tree's
/// photos without re-running content-fit assignment).
func photoIDs(in node: Node) -> [PhotoID] {
    switch node {
    case .leaf(let id):
        return [id]
    case .split(_, _, let children):
        return children.flatMap { photoIDs(in: $0) }
    }
}

func templates(for photos: [PhotoID]) -> [Node] {
    precondition((2...4).contains(photos.count), "templates(for:) supports 2...4 photos")

    switch photos.count {
    case 2:
        return [
            Templates.sideBySide(photos),
            Templates.stacked(photos)
        ]
    case 3:
        return [
            Templates.threeColumns(photos),
            Templates.threeRows(photos),
            Templates.bigLeftTwoRight(photos),
            Templates.bigRightTwoLeft(photos),
            Templates.bigTopTwoBottom(photos),
            Templates.bigBottomTwoTop(photos)
        ]
    default: // 4
        return [
            Templates.twoByTwoColumnsFirst(photos),
            Templates.fourColumns(photos),
            Templates.fourRows(photos),
            Templates.bigLeftThreeRight(photos),
            Templates.bigRightThreeLeft(photos),
            Templates.bigTopThreeBottom(photos),
            Templates.bigBottomThreeTop(photos),
            Templates.sandwich(photos)
        ]
    }
}
