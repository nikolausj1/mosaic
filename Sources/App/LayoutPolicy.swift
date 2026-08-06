// Sources/App/LayoutPolicy.swift
// The one switch that differs between the shipping app and Mosaic Next.
// Deliberately its own tiny file (rather than a literal at the call site in
// PickerView) so Next's standing override commit - which flips exactly this
// value - can never conflict when Next is rebuilt from main.
enum LayoutPolicy {
    /// Whether the auto layout decision may leave the square canvas
    /// (`chooseCanvasAndLayout`'s steps 3-4). False on main (Justin,
    /// 2026-08-05: "make square the default on main" - the non-square auto
    /// canvas surprised him on device, and the eagerness question belongs
    /// to the hero retune, judged by eye on Next). True on Next, where the
    /// ratio decision stays live as a testbed experiment. A hand-set ratio
    /// is honored regardless of this value.
    // NEXT OVERRIDE (standing testbed commit, like the bundle-id and
    // capture commits - never ships): the ratio decision stays live here so
    // the hero retune can settle how eagerly the canvas may leave square.
    static let allowCanvasRatioChallenge = true
}
