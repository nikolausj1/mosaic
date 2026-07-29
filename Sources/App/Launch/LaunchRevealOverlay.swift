// Sources/App/Launch/LaunchRevealOverlay.swift
// "Scatter to order" - the launch reveal that replaces the old plain
// centre-screen logo (Justin, 2026-07-28, approved design). Three beats,
// staged by `LaunchRevealController` and drawn by `LaunchRevealView`, both
// hosted inline inside `PickerView.welcomeStage` (the shared first moment
// for both a returning launch and a first-run welcome - see that file):
//
//   1. LINES   - six empty rounded-square outlines draw themselves, in a
//                staircase, staggered, holding the shape of the mark.
//   2. TILES   - the six blue squares fall in (offset, rotated, scaled) and
//                seat into their outlines; each landing flares its outline,
//                which then fades, leaving the solid tile behind.
//   3. WORDMARK - the existing "Lockup" image (mark+wordmark together, at
//                the SAME frame/matchedGeometryEffect the compact masthead
//                lockup uses) fades up beneath the assembled mark.
//
// THE HARD RULE (Justin): this must ride the real photo-library fetch that
// already runs at launch (`PickerState.onAppear()`), never add fixed time on
// top of it. `PickerView` calls `markLibraryReady()` the instant that fetch
// finishes; every beat below checks it before animating its next step and,
// if it's already true, SNAPS everything remaining to its finished value
// with NO animation rather than playing the beat out - "cut short: tiles
// seat immediately, the wordmark beat drops." That is the only way a launch
// that happens on every single cold start (no opt-out, unlike the Magic
// Layout reveal) can honestly claim ~zero added wall clock in the common
// case where the fetch is already warm.
//
// Reduce Motion is NOT handled in here - `PickerView.init` already decides
// `launchPhase` synchronously and skips `.initial` (hence this whole file)
// entirely under Reduce Motion, exactly like it already did for the old
// splash. `run()` below still defends against being invoked directly with
// Reduce Motion on (belt and suspenders, cheap to check).
import SwiftUI
import UIKit

// MARK: - Mark geometry + palette

/// One filled cell of the 3x3 staircase - NOT a 2x2: one at top-right, two
/// in the middle row (centre + right), three across the bottom row. Colors
/// sampled from `_inbox/brand/lockup.png` (Justin's exact values), placed in
/// the ORDER the reveal builds them: anchor (bottom-left, deepest) first,
/// climbing the staircase to the lightest (top-right) last - both the line
/// draw and the tile fall use this same order.
struct LaunchMarkCell {
    let row: Int   // 0 top ... 2 bottom
    let col: Int   // 0 left ... 2 right
    let color: Color
    /// Where this tile starts before it flies in - an offset from its own
    /// seated center, plus a starting rotation/scale. Hand-picked (not
    /// randomized) so the "scatter" reads the same on every launch, which
    /// matters for screenshot verification.
    let startOffset: CGSize
    let startRotation: Angle
    let startScale: CGFloat
}

enum LaunchMark {
    /// Bottom-left is the anchor (deepest color); the walk climbs the
    /// staircase left-to-right, bottom-to-top within each column, ending at
    /// the lightest cell (top-right) - matching the "lockup's own staircase"
    /// shape and the spec's exact color-per-position table.
    static let cells: [LaunchMarkCell] = [
        LaunchMarkCell(row: 2, col: 0, color: hex(0x074BE8), startOffset: CGSize(width: -42, height: 34), startRotation: .degrees(-18), startScale: 0.55),
        LaunchMarkCell(row: 2, col: 1, color: hex(0x3081FC), startOffset: CGSize(width: 12, height: 48), startRotation: .degrees(14), startScale: 0.55),
        LaunchMarkCell(row: 1, col: 1, color: hex(0x3C93FD), startOffset: CGSize(width: -36, height: -32), startRotation: .degrees(-22), startScale: 0.5),
        LaunchMarkCell(row: 2, col: 2, color: hex(0x429AFE), startOffset: CGSize(width: 44, height: 32), startRotation: .degrees(20), startScale: 0.55),
        LaunchMarkCell(row: 1, col: 2, color: hex(0x4FAEFD), startOffset: CGSize(width: 40, height: -28), startRotation: .degrees(24), startScale: 0.5),
        LaunchMarkCell(row: 0, col: 2, color: hex(0x56BBFE), startOffset: CGSize(width: 12, height: -46), startRotation: .degrees(-16), startScale: 0.5)
    ]

    /// Construction-line / flare color - deliberately the same blue as the
    /// ring inside the wordmark's "o" (spec), so the outline language reads
    /// as coming from the mark itself.
    static let lineColor = hex(0x54B7FD)

    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Controller

/// The beat machine for the three-beat reveal above. Owned by `PickerView`
/// as a plain `@State` (one per fresh process appearance, same lifetime as
/// `launchPhase`) - there is no cross-view geometry export to arrange here
/// (unlike Magic Layout), so this is far simpler: no PreferenceKey, no
/// separate overlay host, just published animation state a sibling view
/// reads directly.
@MainActor
@Observable
final class LaunchRevealController {

    enum Beat: Equatable {
        case idle
        case lines
        case tiles
        case wordmark
        case done
    }

    /// `markLibraryReady()` is called from a SIBLING `.task` that races
    /// `run()`'s own start - on a warm library (already-authorized, cheap
    /// `reload()`) it routinely wins that race, arriving before `run()` has
    /// called `LaunchTiming.start()`. Seeding `revealStart` here (object
    /// creation, i.e. before either task exists) rather than leaving it at
    /// `LaunchTiming`'s own zero default is what keeps THAT mark's "+Nms"
    /// meaningful instead of a nonsense multi-decade delta.
    init() {
        LaunchTiming.revealStart = CFAbsoluteTimeGetCurrent()
    }

    private(set) var beat: Beat = .idle

    /// Per-cell state, indexed exactly like `LaunchMark.cells`.
    private(set) var outlineDrawn: [Double] = Array(repeating: 0, count: LaunchMark.cells.count)     // trim 0...1, "the line has drawn itself this far"
    private(set) var outlineOpacity: [Double] = Array(repeating: 1, count: LaunchMark.cells.count)    // 1 while holding, ->0 once its tile has flared
    private(set) var tileProgress: [Double] = Array(repeating: 0, count: LaunchMark.cells.count)      // 0 off-position -> 1 seated
    private(set) var flareStrength: [Double] = Array(repeating: 0, count: LaunchMark.cells.count)     // landing bloom envelope

    private(set) var wordmarkOpacity: Double = 0
    private(set) var wordmarkOffset: Double = 8   // "fades UP" - a small slide-up accompanies the fade-in

    /// Set by `PickerView` the instant `PickerState.onAppear()` (the real
    /// photo-library auth + fetch) returns. Checked at the top of every
    /// staggered step below - never polled on a timer, since a plain
    /// `@MainActor` bool flip is already visible at the next `await` in
    /// `run()`'s loop.
    private var libraryReady = false
    private var didSkip = false
    private var isRunning = false

    /// `-launchRevealOff` (DEBUG, same family as `-magicLayoutOff`):
    /// verification-only bypass so the "added wall clock" measurement has a
    /// same-build baseline to compare against (see STATUS/handoff notes for
    /// the measured numbers).
    static var isDisabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-launchRevealOff") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    /// `-launchRevealSlow N` (DEBUG, verification only - same family as
    /// Magic Layout's `-magicSlow`): stretches every beat's durations/
    /// staggers by N so a scripted screenshot pass can actually land INSIDE
    /// each beat. The whole reveal otherwise runs in ~1.6s, too fast for a
    /// simctl-driven screenshot to reliably catch mid-beat. Never anything
    /// but 1 outside DEBUG.
    private static let timeScale: Double = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-launchRevealSlow"), i + 1 < args.count, let n = Double(args[i + 1]), n > 0 {
            return n
        }
        #endif
        return 1
    }()

    private static func scaled(_ seconds: Double) -> Double { seconds * timeScale }

    func markLibraryReady() {
        libraryReady = true
        LaunchTiming.mark("library ready")
    }

    /// `PickerView.init`'s Reduce-Motion branch: pre-resolves every value to
    /// its finished target with no animation, BEFORE `run()` is ever called
    /// (it never will be - `runLaunchChoreographyIfNeeded` is gated on
    /// `launchPhase == .initial`, which a Reduce-Motion launch never
    /// reaches). Without this the mark would render as a blank hole - trims
    /// at 0, tiles invisible, wordmark opacity 0 - instead of "Reduce Motion
    /// skips the ANIMATION," which is the actual contract every other
    /// Reduce-Motion path in this app honors.
    func presentFinishedImmediately() {
        beat = .done
        for i in outlineDrawn.indices {
            outlineDrawn[i] = 1
            outlineOpacity[i] = 0
            tileProgress[i] = 1
            flareStrength[i] = 0
        }
        wordmarkOpacity = 1
        wordmarkOffset = 0
    }

    /// Dev Tools "Replay first-run experience" (`PickerView
    /// .replayFirstRunExperience`): re-arms every published value back to
    /// its pre-run default so `run()`'s `guard beat == .idle` doesn't just
    /// no-op the replay. `libraryReady` also resets to `false` - there is no
    /// second real fetch backing a replay, so every beat plays out at its
    /// full natural pace rather than being cut short, which is exactly what
    /// "replay it so I can see it" wants.
    func reset() {
        beat = .idle
        for i in outlineDrawn.indices {
            outlineDrawn[i] = 0
            outlineOpacity[i] = 1
            tileProgress[i] = 0
            flareStrength[i] = 0
        }
        wordmarkOpacity = 0
        wordmarkOffset = 8
        libraryReady = false
        didSkip = false
        isRunning = false
    }

    /// Any touch during the reveal (spec: "any touch skips straight to the
    /// picker"). Lands on exactly the state Reduce Motion would have started
    /// from - every value snapped to its finished target, no animation - so
    /// a mid-reveal tap and a Reduce-Motion launch are visually identical at
    /// rest.
    func skip() {
        guard isRunning, !didSkip else { return }
        didSkip = true
        LaunchTiming.mark("skipped by touch")
        snapAllRemaining(from: 0)
        wordmarkOpacity = 1
        wordmarkOffset = 0
        beat = .done
    }

    /// Runs the three beats in order, each one checking `libraryReady`
    /// before every staggered step and snapping the rest of ITS OWN beat
    /// instantly the moment the real fetch has landed. Returns once the
    /// mark (and, if there was time, the wordmark) has fully resolved.
    func run() async {
        guard beat == .idle, !Self.isDisabled else {
            beat = .done
            LaunchTiming.mark("reveal bypassed (-launchRevealOff / Reduce Motion)")
            return
        }
        isRunning = true
        LaunchTiming.start()
        beat = .lines
        await runLinesBeat()
        if !didSkip { await runTilesBeat() }
        if !didSkip { await runWordmarkBeat() }
        if !didSkip {
            beat = .done
            LaunchTiming.mark("reveal done")
        }
        isRunning = false
    }

    // MARK: Beat 1 - lines

    private static let lineStagger = 0.07
    private static let lineDrawDuration = 0.22
    /// Held after the last outline finishes drawing, so the completed
    /// staircase registers for a beat before the tiles start falling.
    private static let lineHoldAfter = 0.10

    private func runLinesBeat() async {
        for i in outlineDrawn.indices {
            guard !didSkip else { return }
            if libraryReady {
                for j in i..<outlineDrawn.count { outlineDrawn[j] = 1 }
                LaunchTiming.mark("lines cut short at \(i)/\(outlineDrawn.count)")
                return
            }
            withAnimation(.easeOut(duration: Self.scaled(Self.lineDrawDuration))) {
                outlineDrawn[i] = 1
            }
            await sleep(Self.scaled(Self.lineStagger))
        }
        await sleep(Self.scaled(Self.lineHoldAfter))
    }

    // MARK: Beat 2 - tiles fall + seat + flare

    private static let tileStagger = 0.07
    private static let tileFallDuration = 0.24
    private static let flareRiseDuration = 0.10
    private static let flareFallDuration = 0.14
    private static let outlineFadeDuration = 0.18
    /// Held after the last tile's chain (fall + flare + fade) so the
    /// assembled mark is visibly complete before the wordmark beat begins.
    private static let tileHoldAfter = 0.10

    private func runTilesBeat() async {
        beat = .tiles
        for i in tileProgress.indices {
            guard !didSkip else { return }
            if libraryReady {
                snapAllRemaining(from: i)
                LaunchTiming.mark("tiles cut short at \(i)/\(tileProgress.count)")
                return
            }
            fireTileSequence(i)
            await sleep(Self.scaled(Self.tileStagger))
        }
        // Let the LAST tile's own fall+flare+fade chain finish before moving
        // on - its `.delay(...)` chains above already account for the fall,
        // this is just the remaining flare/fade tail plus the settle hold.
        await sleep(Self.scaled(Self.flareRiseDuration + Self.flareFallDuration + Self.tileHoldAfter))
    }

    /// Fires tile `i`'s whole lifecycle in one synchronous burst using
    /// `Animation.delay(_:)` to stagger the sub-phases - fall, then flare
    /// rise, then flare fall + outline fade together - rather than a chain
    /// of awaited sleeps. That keeps this controller free of nested Tasks
    /// (and the cancellation bookkeeping they'd need): the state changes are
    /// all issued now, SwiftUI's animation system does the timing.
    private func fireTileSequence(_ i: Int) {
        let fall = Self.scaled(Self.tileFallDuration)
        let flareRise = Self.scaled(Self.flareRiseDuration)
        let flareFall = Self.scaled(Self.flareFallDuration)
        let outlineFade = Self.scaled(Self.outlineFadeDuration)
        withAnimation(.timingCurve(0.22, 0.9, 0.2, 1, duration: fall)) {
            tileProgress[i] = 1
        }
        withAnimation(.easeOut(duration: flareRise).delay(fall)) {
            flareStrength[i] = 1.3
        }
        withAnimation(.easeOut(duration: flareFall).delay(fall + flareRise)) {
            flareStrength[i] = 0
        }
        withAnimation(.easeOut(duration: outlineFade).delay(fall + flareRise)) {
            outlineOpacity[i] = 0
        }
    }

    /// Instant (unanimated) finish for every cell from `start` on - "cut
    /// short: the tiles seat immediately" and the touch-skip path. Every
    /// assignment here happens OUTSIDE `withAnimation`, so SwiftUI applies
    /// it as a plain step on the next frame rather than interpolating.
    private func snapAllRemaining(from start: Int) {
        for j in start..<outlineDrawn.count {
            outlineDrawn[j] = 1
            outlineOpacity[j] = 0
            tileProgress[j] = 1
            flareStrength[j] = 0
        }
    }

    // MARK: Beat 3 - wordmark

    private static let wordmarkFadeDuration = 0.30

    /// Only plays when the real fetch is STILL running once the mark has
    /// finished assembling - the beat this design explicitly sacrifices
    /// first (spec: "the wordmark beat is what gets dropped"). Dropped, the
    /// wordmark still ends up fully opaque and un-offset (so the
    /// `matchedGeometryEffect` handoff into the masthead has a real element
    /// to spring from) - it just gets there in one unanimated step instead
    /// of a fade, i.e. "the mark still completes; it just does not linger."
    private func runWordmarkBeat() async {
        guard !libraryReady else {
            wordmarkOpacity = 1
            wordmarkOffset = 0
            LaunchTiming.mark("wordmark beat dropped (library already ready)")
            return
        }
        beat = .wordmark
        withAnimation(.easeOut(duration: Self.scaled(Self.wordmarkFadeDuration))) {
            wordmarkOpacity = 1
            wordmarkOffset = 0
        }
        await sleep(Self.scaled(Self.wordmarkFadeDuration))
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

// MARK: - Timing (verification only)

/// Mirrors `MagicTiming` (MagicLayoutOverlay.swift) exactly - a separate
/// namespace because this measures a DIFFERENT window (process launch to
/// picker-interactive, not Next-tap to editor-mounted) and the two must
/// never be confused when reading a log.
enum LaunchTiming {
    nonisolated(unsafe) static var revealStart: CFAbsoluteTime = 0

    static func start() {
        revealStart = CFAbsoluteTimeGetCurrent()
        mark("reveal begin")
    }

    static func mark(_ label: String) {
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - revealStart) * 1000
        let line = String(format: "LAUNCH %@ +%.0fms", label, ms)
        fputs(line + "\n", stderr)
        NSLog("%@", line)
        #endif
    }
}

// MARK: - View

/// Draws the mark (outlines + tiles) and, beneath it, the wordmark. Sized to
/// sit exactly where `PickerView.welcomeStage` used to put the plain
/// oversized lockup image - see that file's call site for the
/// `matchedGeometryEffect` handoff into `masthead`'s compact lockup, which
/// this preserves unchanged (same id/namespace, attached to the same
/// wordmark image).
struct LaunchRevealView: View {
    var controller: LaunchRevealController
    var lockupNamespace: Namespace.ID
    var wordmarkHeight: CGFloat

    private let cellSize: CGFloat = 28
    private let cellGap: CGFloat = 7
    private var gridSize: CGFloat { cellSize * 3 + cellGap * 2 }
    private var step: CGFloat { cellSize + cellGap }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(Array(LaunchMark.cells.enumerated()), id: \.offset) { index, cell in
                    outline(for: cell, index: index)
                    tile(for: cell, index: index)
                }
            }
            .frame(width: gridSize, height: gridSize)
            .compositingGroup()

            Image("Lockup")
                .resizable()
                .scaledToFit()
                .frame(height: wordmarkHeight)
                .matchedGeometryEffect(id: "lockup", in: lockupNamespace)
                .opacity(controller.wordmarkOpacity)
                .offset(y: controller.wordmarkOffset)
                .accessibilityLabel("Mosaic")
        }
        .allowsHitTesting(false)
    }

    private func center(for cell: LaunchMarkCell) -> CGPoint {
        CGPoint(x: CGFloat(cell.col) * step + cellSize / 2, y: CGFloat(cell.row) * step + cellSize / 2)
    }

    /// The construction-line outline: a trimmed stroke (so it visibly draws
    /// itself rather than fading in as a whole), held at full opacity while
    /// the tile is still in flight, then fading away once that tile's flare
    /// has burned down (see `LaunchRevealController.fireTileSequence`).
    private func outline(for cell: LaunchMarkCell, index: Int) -> some View {
        let point = center(for: cell)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .trim(from: 0, to: controller.outlineDrawn[index])
            .stroke(LaunchMark.lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: cellSize, height: cellSize)
            .position(point)
            .opacity(controller.outlineOpacity[index])
    }

    /// The falling/seating tile, plus its landing flare - the same
    /// three-layer `plusLighter` bloom technique `MagicLayoutOverlay` uses
    /// for its face glows, tinted the construction-line blue instead of
    /// `mosaicAccent` so the flare reads as "this outline's own energy."
    private func tile(for cell: LaunchMarkCell, index: Int) -> some View {
        let point = center(for: cell)
        let t = controller.tileProgress[index]
        let offset = CGSize(
            width: cell.startOffset.width * (1 - t),
            height: cell.startOffset.height * (1 - t)
        )
        let rotation = cell.startRotation.degrees * (1 - t)
        let scale = cell.startScale + (1 - cell.startScale) * t

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cell.color)
                .frame(width: cellSize, height: cellSize)
            flareBloom(strength: controller.flareStrength[index])
        }
        .compositingGroup()
        .rotationEffect(.degrees(rotation))
        .scaleEffect(scale)
        .offset(offset)
        .position(point)
        .opacity(t == 0 ? 0 : 1)
    }

    private func flareBloom(strength: Double) -> some View {
        let bloom = min(1, max(0, strength))
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LaunchMark.lineColor, lineWidth: 6)
                .blur(radius: 8)
                .opacity(0.6 * bloom)
                .scaleEffect(1 + 0.15 * bloom)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                .blur(radius: 0.5)
                .opacity(0.7 * bloom)
        }
        .frame(width: cellSize, height: cellSize)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
