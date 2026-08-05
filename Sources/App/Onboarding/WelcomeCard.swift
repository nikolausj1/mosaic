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
// Grand-entrance rework (Justin, 2026-07-26): the three teaching rows now
// stagger in one at a time rather than fading as a single block, and a
// fourth, quieter line about the on-device AI framing joins them - see
// `isRevealed` below.
import SwiftUI

/// The teaching rows: three unchanged lines from the original modal card,
/// plus a fourth, quieter one about on-device intelligence (Justin,
/// 2026-07-26). Rows no longer fade in as a single block - each stages in on
/// its own delay once `isRevealed` flips true, so a single state change
/// reads as a real staggered sequence rather than one crossfade.
struct WelcomeInstructionRows: View {
    private struct Row: Identifiable {
        let id: Int
        let systemImage: String
        let text: String
        /// The fourth (on-device-AI) row is deliberately quieter - smaller
        /// type, muted color, no accent tint on its icon - so it reads as a
        /// footnote to the three teaching rows above it, not a fourth equal
        /// instruction.
        let isQuiet: Bool
    }

    /// Exactly the three lines from the PRD-revision brief, plus the new
    /// quiet fourth line, in order.
    private let rows: [Row] = [
        Row(id: 0, systemImage: "photo.on.rectangle", text: "Choose 2-4 photos", isQuiet: false),
        Row(id: 1, systemImage: "rectangle.split.2x1", text: "Drag the seams and corner to shape your collage", isQuiet: false),
        // Was "filed under the day the photos were taken" - that described
        // the OLD S7 behavior (PRD.md still says this; flagged for Justin to
        // reconcile). SaveCoordinator now files the asset at EXPORT time so
        // it sorts to the top of Photos/Messages, and keeps the source
        // date/location only in the JPEG's own EXIF (see SaveCoordinator.swift).
        Row(id: 2, systemImage: "square.and.arrow.down", text: "Save full resolution, right at the top of your library", isQuiet: false),
        Row(id: 3, systemImage: "sparkles", text: "On-device intelligence frames your photos and suggests colors. Nothing leaves your iPhone.", isQuiet: true)
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
                // ~0.6s stagger per row (Justin, 2026-07-26 grand-entrance
                // rework, was one single 0.35s block fade) - each row's delay
                // is keyed off its own index, so they land one after another
                // rather than together.
                .animation(.easeOut(duration: 0.5).delay(Double(row.id) * 0.6), value: isRevealed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
