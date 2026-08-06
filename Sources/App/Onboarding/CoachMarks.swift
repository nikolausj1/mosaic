// Sources/App/Onboarding/CoachMarks.swift
// Ghost gesture demo overlay (Justin, 2026-07-26): replaces the old
// single-screen spotlight coach marks (a dark scrim punched with two cutout
// holes + tip cards - deleted below, see git history for that version) with
// a quieter first-entry teach: the app itself demonstrates the corner-drag
// and divider-drag gestures on the user's OWN collage while they watch, via
// a translucent "ghost fingertip" that presses, drags, holds, and returns.
// This view is pure presentation - EditorView's `runGhostGestureDemo` (see
// its "Ghost gesture demo" section) owns the whole orchestration: the
// document snapshot/restore, the per-tick divider-drag math, and the
// press/travel/hold timing. This file keeps its old name/location
// (Onboarding/) since the trigger wiring (`hasSeenCoachMarks`, unchanged
// key) and the caption capsule's visual language (mosaicSurface capsule,
// white text, hairline stroke) both carry over from the coach marks it
// replaces.
//
// Focus scrim (Justin, 2026-08-05, on-device review): reverses the original
// "stay transparent" call below - watching the demo through a fully clear
// overlay let the header buttons and bottom nav compete for attention with
// the thing actually being taught. Justin's verbatim ask: "make sure the
// scrim covers all elements outside of the actual canvas... make the scrim
// darker to really emphasise the interaction we want them to see," plus
// moving the caption "closer to the action (not pinned on top)". Both are
// below - `scrim` (an even-odd cutout punched exactly over the live canvas
// rect) and `captionCapsule` (now anchored just under the canvas instead of
// pinned near the header).
import SwiftUI

struct GhostGestureOverlay: View {
    /// Full screen this overlay covers (EditorView's GeometryReader,
    /// ignoring safe area - mirrors the old CoachMarksOverlay's contract,
    /// so the tap-anywhere-skip catcher reaches the header and bottom bar
    /// too, not just the canvas).
    let screenSize: CGSize
    /// Where the ghost fingertip is right now, in the SAME coordinate space
    /// as `screenSize` - resolved by EditorView from CanvasView's live
    /// `CoachMarkAnchorsKey` preference (the corner handle while demoing
    /// the corner drag, the divider capsule while demoing the seam drag).
    /// Nil for the first beat before the very first anchor has resolved -
    /// the fingertip just doesn't render yet rather than guessing a
    /// position.
    let fingertipCenter: CGPoint?
    /// True for the brief "press" pulse at the start of each drag leg -
    /// scales the fingertip down slightly, like a real touch-down.
    let isPressed: Bool
    let captionText: String
    /// The live canvas rect, in the SAME coordinate space as `screenSize` -
    /// resolved by EditorView the same way as `fingertipCenter`, but from
    /// `CoachMarkAnchorsKey`'s new `canvas` anchor (see CanvasView.swift)
    /// rather than one of the three small hit-zone anchors. Drives both the
    /// scrim's cutout (`scrim` below) and the caption's position
    /// (`captionCapsule` below). Nil only for the same brief pre-resolve
    /// beat `fingertipCenter` allows for - the scrim just covers the full
    /// screen with no hole yet, rather than guessing one.
    let canvasRect: CGRect?
    /// Fires on any tap anywhere on this overlay - EditorView's
    /// `skipGhostDemo` restores the original document and ends the demo
    /// immediately, exactly as if it had finished naturally.
    var onSkip: () -> Void

    /// Justin, 2026-08-05: "make the scrim darker to really emphasise the
    /// interaction we want them to see." Named (not inlined) so a future
    /// retune is a one-line change - 0.62 sits inside the black-at-~0.55-0.65
    /// range Justin asked for, closer to the dark end since the whole point
    /// here is emphasis over subtlety.
    private let scrimOpacity: Double = 0.62

    var body: some View {
        ZStack {
            scrim

            captionCapsule

            if let fingertipCenter {
                ghostFingertip
                    .position(fingertipCenter)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        // Hit-testing is unchanged from the old transparent design: the
        // WHOLE frame (canvas hole included) is one tap-anywhere-skip
        // catcher, blocking every real touch to the canvas/header/bottom bar
        // underneath. `scrim` itself opts out of hit-testing (see its own
        // comment) so this contentShape - not the fill underneath it - is
        // what SwiftUI actually dispatches the tap to.
        .contentShape(Rectangle())
        .onTapGesture { onSkip() }
    }

    // MARK: - Focus scrim

    /// Dark scrim over everything on screen EXCEPT the live canvas rect,
    /// which is punched out via an even-odd fill (full-screen rect + the
    /// canvas rect, `eoFill: true` cancels their overlap) so the canvas stays
    /// fully visible - that's where the demo happens - while the header
    /// buttons, bottom nav/trays, and any dead space around the canvas all
    /// go dark. `canvasRect` comes from CanvasView's live `CoachMarkAnchorsKey`
    /// export the same way `fingertipCenter` does, so the hole tracks a real
    /// reshape (e.g. the bracket phase growing the canvas) instead of
    /// freezing on a stale size. `allowsHitTesting(false)` because tap-to-
    /// skip is owned by the outer ZStack's `contentShape`/`onTapGesture`
    /// above, not by this decorative fill - it should never get first claim
    /// on a tap over the canvas hole.
    private var scrim: some View {
        ScrimCutoutShape(cutout: canvasRect ?? .zero)
            .fill(Color.black.opacity(scrimOpacity), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
    }

    // MARK: - Ghost fingertip

    /// A soft translucent white circle with a light glow, standing in for a
    /// fingertip - deliberately faint (this demonstrates a gesture, it
    /// isn't chrome) with a small scale-down pulse on "press" via
    /// `isPressed`, matching a real touch-down's visual weight.
    private var ghostFingertip: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 54, height: 54)
                .blur(radius: 8)
            Circle()
                .fill(Color.white.opacity(0.55))
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .scaleEffect(isPressed ? 0.82 : 1.0)
        .allowsHitTesting(false)
    }

    // MARK: - Caption

    /// Anchored just below the live canvas rect (Justin, 2026-08-05: "closer
    /// to the action (not pinned on top)", replacing the old fixed 132pt-
    /// from-top placement). Below, not above, because that's where the dead
    /// space between the canvas and the bottom bar already lives - now part
    /// of the same darkened scrim, so the capsule reads clearly against it
    /// exactly as Justin asked ("make it look easier to read"). Tracks
    /// `canvasRect` live the same way the fingertip tracks its own anchor,
    /// which matters during the bracket phase: the canvas can grow to nearly
    /// the full screen height (see EditorView's `animateBracketDrag` doc
    /// comment - peak bbox measured ~820pt on an ~874pt screen), so the
    /// preferred "just below the canvas" spot is clamped to a fixed floor
    /// near the bottom of the screen (see `captionTopInset` below) rather
    /// than being allowed to drift past it. Type is larger and heavier than the old
    /// caption (15pt semibold -> here bumped to bold) with a stronger shadow,
    /// both purely for legibility against the new darker background - the
    /// text itself is unchanged.
    private var captionCapsule: some View {
        Group {
            if let canvasRect {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(height: captionTopInset(for: canvasRect))
                    Text(captionText)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Color.mosaicSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                        .padding(.horizontal, 24)
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// `canvasGap` is the breathing room between the canvas's bottom edge and
    /// the capsule (JUDGMENT CALL, Justin can retune). `captionBudget` is a
    /// rough height reservation for the capsule itself (one line at this
    /// font/padding is ~44pt tall) plus a small safety margin, used only to
    /// compute the clamp floor below - not an exact measurement, since the
    /// capsule's real size depends on the caption text SwiftUI hasn't laid
    /// out yet at this point.
    private let canvasGap: CGFloat = 14
    private let captionBudget: CGFloat = 64

    /// Where the top of the VStack's spacer should end - i.e. how far down
    /// the screen the capsule starts - clamped so an extreme bracket-phase
    /// canvas (which can grow to within ~27pt of the physical screen edge)
    /// never pushes the capsule off-screen: the ceiling guarantees
    /// `captionBudget` worth of room stays below it no matter how large the
    /// live canvas rect gets. At that peak the capsule briefly overlaps the
    /// canvas's bottom edge instead - the deliberate trade (legibility was
    /// the whole ask): a transiently overlapped edge beats text sliding off
    /// the screen mid-teach.
    private func captionTopInset(for canvasRect: CGRect) -> CGFloat {
        let preferred = canvasRect.maxY + canvasGap
        return min(preferred, screenSize.height - captionBudget)
    }
}

/// Full-screen rect with a `cutout` rect punched out via even-odd fill -
/// the scrim's shape. `.zero` as the cutout degenerates to a rect with no
/// area, i.e. no hole at all (used for the one frame before `canvasRect`
/// first resolves - see `scrim`'s doc comment above).
private struct ScrimCutoutShape: Shape {
    var cutout: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(cutout)
        return path
    }
}
