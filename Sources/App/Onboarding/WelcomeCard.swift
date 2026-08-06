// Sources/App/Onboarding/WelcomeCard.swift
// First-run welcome (Justin, 2026-07-26, full-screen revision): this used to
// be a dismissible modal card (WelcomeCard/WelcomeCardOverlay) shown AFTER
// the splash-to-picker animation settled. It's now folded directly into that
// animation instead - one continuous choreography (lockup alone -> teaching
// rows fade in -> "Get started" fades in -> tap springs into the settled
// picker) owned entirely by `PickerView` (see `welcomeStage`,
// `runLaunchChoreographyIfNeeded`, `getStarted`). This file keeps just the
// two purely-presentational pieces that choreography needs, so PickerView
// alone owns timing/gating and these stay pure look. PRD section 4 (revised
// 2026-07-26) allows this full-screen-then-picker shape in place of any
// multi-screen intro.
//
// Grand-entrance rework (Justin, 2026-07-26): the teaching rows now stagger
// in one at a time rather than fading as a single block - see `isRevealed`
// below.
//
// Row swap (Justin, 2026-08-05): the "save full resolution" row is gone; the
// on-device-intelligence row takes its place as a full teaching row instead
// of a quieter fourth line, so there are exactly three rows again.
import SwiftUI

/// The teaching rows: three full-weight lines, each staging in on its own
/// delay once `isRevealed` flips true, so a single state change reads as a
/// real staggered sequence rather than one crossfade.
struct WelcomeInstructionRows: View {
    private struct Row: Identifiable {
        let id: Int
        let systemImage: String
        let text: String
        /// No row is quiet as of the 2026-08-05 row swap (was used for a
        /// fourth, footnote-weight row - smaller type, muted color, no
        /// accent tint on its icon - that no longer exists). Left in place,
        /// unused at full weight, in case a future row needs to be
        /// de-emphasized again rather than removed.
        let isQuiet: Bool
    }

    /// Exactly three lines (Justin, 2026-08-05): the old "save full
    /// resolution" row is gone, and the on-device-intelligence row - a
    /// quieter fourth line until now - takes its place at full weight.
    private let rows: [Row] = [
        Row(id: 0, systemImage: "photo.on.rectangle", text: "Choose 2-4 photos", isQuiet: false),
        Row(id: 1, systemImage: "rectangle.split.2x1", text: "Drag the seams and corner to shape your collage", isQuiet: false),
        // Shortened (Justin, 2026-08-05, on-device review: "too much text
        // for the third list item") - "suggests colors" was the trim; the
        // privacy half is the part that has to survive.
        Row(id: 2, systemImage: "sparkles", text: "On-device intelligence frames your photos. Nothing leaves your iPhone.", isQuiet: false)
    ]

    /// Drives the staggered reveal - false while the welcome stage is still
    /// holding on the lockup alone (`.initial`), true from `.welcomeText`
    /// onward. Present-but-invisible before that (rather than being
    /// conditionally inserted) is what lets each row's own `.animation(value:
    /// isRevealed)` below have a real false -> true transition to animate,
    /// instead of just appearing at full opacity with no transition to run.
    var isRevealed: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.systemImage)
                        .font(.system(size: row.isQuiet ? 13 : 16, weight: .medium))
                        .foregroundStyle(row.isQuiet ? .white.opacity(0.4) : Color.mosaicAccent)
                        .frame(width: 22)
                    Text(row.text)
                        .font(.system(size: row.isQuiet ? 12 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(row.isQuiet ? 0.45 : 0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(isRevealed ? 1 : 0)
                .offset(y: isRevealed ? 0 : 8)
                // One block again (Justin, 2026-08-05, on-device review:
                // "display the list below all at the same time" - reversing
                // the 2026-07-26 per-row stagger). The beat he asked for
                // between the wordmark and this list lives in
                // `PickerView.runLaunchChoreographyIfNeeded`, not here.
                .animation(.easeOut(duration: 0.5), value: isRevealed)
            }
        }
        // Capped and centerable rather than edge-to-edge (Justin, 2026-08-05:
        // the left-aligned list read odd against a center-aligned screen, but
        // centering the text itself would be odd too). The rows stay
        // left-aligned WITHIN the block - the icon rail needs a straight
        // left edge to read as a list - while the capped width lets the
        // parent VStack center the whole block under the wordmark, so the
        // group reads as centered without any row being center-set.
        .frame(maxWidth: 300, alignment: .leading)
    }
}

/// "Get started" - deep-accent capsule per the 2026-07-26 contrast pass (see
/// `Color.mosaicAccentDeep`), white bold text. This button IS the welcome
/// screen's dismissal, no separate skip control - tapping it both marks
/// `hasSeenWelcome` and triggers the existing splash-to-picker spring in one
/// motion (see `PickerView.getStarted`).
struct WelcomeGetStartedButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Get started")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.mosaicAccentDeep, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
