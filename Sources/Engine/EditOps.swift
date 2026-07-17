// Sources/Engine/EditOps.swift
// Phase 4 photo-removal helper.
//
// NOTE ON WHY THIS FILE IS SMALL: `removeLeaf(id:from:)` (parent-drops-child,
// renormalize survivors, single-child splits collapse recursively, sole-leaf
// root removal returns nil) was already implemented in Operations.swift back
// in Phase 1, ahead of this phase's need, complete with smoke coverage for
// the 2-way/3-way/nested-collapse cases. Operations.swift is locked this
// phase, so rather than duplicate that logic here (which would also fail to
// compile as a redeclaration if the signature matched), this file adds the
// one piece Phase 4 actually needs on top of it: a variant that reports
// "nothing happened" (nil) when `id` isn't in the tree at all, which the
// existing function does not do (it returns the tree unchanged in that case,
// indistinguishable from "processed but nothing to remove"). Argument-label
// difference (`_ id:` here vs `id:` there) makes this a legal overload, not
// a collision, so both coexist.
import Foundation

/// True iff `id` appears as a leaf anywhere in `node`. Local re-statement of
/// Operations.swift's private `subtreeContains` - trivial, and duplicating a
/// pure membership test isn't the same as duplicating the removal logic
/// itself.
private func containsLeaf(_ node: Node, id: PhotoID) -> Bool {
    switch node {
    case .leaf(let leafID):
        return leafID == id
    case .split(_, _, let children):
        return children.contains { containsLeaf($0, id: id) }
    }
}

/// Removes leaf `id` from `root`, delegating the actual tree surgery to
/// Operations.swift's `removeLeaf(id:from:)`. Returns nil when `id` isn't
/// present anywhere in the tree (nothing to remove) OR when `root` was the
/// sole leaf being removed (the underlying function's own nil case).
/// Removing from a 2-leaf tree returns the surviving sibling subtree, not
/// nil - callers enforce the >= 2 photo floor themselves (EditorState.remove()
/// guards `photos.count > 2` before ever calling this).
///
/// INVARIANTS on any non-nil result (asserted below, exercised by the smoke
/// suite): fractions sum to 1, `fractions.count == children.count >= 2`,
/// every fraction >= Layout.minCellFraction. Renormalizing after dropping a
/// child only ever *grows* the survivors' shares (a removed fraction's mass
/// is redistributed proportionally), so it can never push a fraction below
/// the floor it already satisfied - the assertion exists as a tripwire, not
/// because a violation is expected.
func removeLeaf(_ id: PhotoID, from root: Node) -> Node? {
    guard containsLeaf(root, id: id) else { return nil }
    let result = removeLeaf(id: id, from: root)
    if let result {
        assertValidTree(result)
    }
    return result
}

/// Traps in debug builds (no-op under `-Ounchecked`, but this file is only
/// ever exercised via the debug smoke-test binary and the Xcode debug
/// build) if a split node violates the tree invariants documented in
/// Model.swift. Exposed (not `private`) so the smoke test can also call it
/// directly against `removeLeaf`'s result to make the "invariants hold on
/// every result" check explicit rather than implicit in a side-effecting
/// assert.
func assertValidTree(_ node: Node) {
    switch node {
    case .leaf:
        return
    case .split(_, let fractions, let children):
        assert(fractions.count == children.count, "fractions/children count mismatch")
        assert(fractions.count >= 2, "split must have >= 2 children")
        assert(abs(fractions.reduce(0, +) - 1.0) < 1e-9, "fractions must sum to 1")
        assert(fractions.allSatisfy { $0 >= Layout.minCellFraction - 1e-9 }, "fraction below the 0.10 floor")
        for child in children { assertValidTree(child) }
    }
}

/// Non-trapping mirror of `assertValidTree`, for smoke-test `check(...)`
/// call sites that want a Bool rather than a trap.
func isValidTree(_ node: Node) -> Bool {
    switch node {
    case .leaf:
        return true
    case .split(_, let fractions, let children):
        guard fractions.count == children.count, fractions.count >= 2 else { return false }
        guard abs(fractions.reduce(0, +) - 1.0) < 1e-9 else { return false }
        guard fractions.allSatisfy({ $0 >= Layout.minCellFraction - 1e-9 }) else { return false }
        return children.allSatisfy { isValidTree($0) }
    }
}
