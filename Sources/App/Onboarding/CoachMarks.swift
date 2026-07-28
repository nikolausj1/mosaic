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
    /// Fires on any tap anywhere on this overlay - EditorView's
    /// `skipGhostDemo` restores the original document and ends the demo
    /// immediately, exactly as if it had finished naturally.
    var onSkip: () -> Void

    var body: some View {
        ZStack {
            // Transparent (not a scrim - the whole point is watching the
            // REAL collage reshape, unobscured) full-screen catcher: blocks
            // every real touch to the canvas/header/bottom bar underneath
            // and doubles as "tap anywhere skips."
            Color.white.opacity(0.001)

            captionCapsule

            if let fingertipCenter {
                ghostFingertip
                    .position(fingertipCenter)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .contentShape(Rectangle())
        .onTapGesture { onSkip() }
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

    /// Fixed near the top of the screen, just below the header - reads as
    /// "top of the canvas" (which sits directly below the header with only
    /// small padding) without needing its own anchor plumbing. JUDGMENT
    /// CALL (Justin can retune the offset): 78pt clears the 60pt header +
    /// its hairline divider with a small margin.
    private var captionCapsule: some View {
        VStack {
            Text(captionText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.mosaicSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                // 132pt, not 78: the overlay ignores the safe area, so its
                // top is the physical screen edge - ~59pt status/safe area +
                // the 60pt header + margin (verified against a simulator
                // frame where 78pt sat the capsule on top of Save).
                .padding(.top, 132)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
