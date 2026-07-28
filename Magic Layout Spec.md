---
title: "Magic Layout - Build Spec"
created: 2026-07-28
modified: 2026-07-28
version: 1.3
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Magic Layout - Build Spec

Kick-off-ready spec for Backlog **B32**, which consolidates **B30** (face-aware auto-layout) and **B31** (the reveal). Read this top to bottom before writing code. It is written so a competent worker with simulator access can start immediately without re-deriving decisions.

## The pitch, in one paragraph

The four chosen photos fly in from the picker grid as raw thumbnails, get scanned on device (real face boxes light up on the real detections), and morph into a layout the app actually chose for those faces. Today all of that work happens invisibly behind a spinner, so the user credits the app with nothing. This makes the work visible, turns the picker-to-editor cut into a transition worth watching, and hands us the single best fifteen seconds of an App Store preview video.

## Scope

In scope: the picker-to-canvas transition, the face-aware layout decision, and the reveal animation, as one coherent feature.

Explicit non-goals: no server, no model training, no change to the 2-4 photo cap, no template browser, no change to the export pipeline.

## What already exists (do not rebuild these)

| Piece | Where | Notes |
|---|---|---|
| Face + saliency detection | `Sources/App/Library/PhotoLibraryService.swift:142+` | `VNDetectFaceRectanglesRequest` + `VNGenerateAttentionBasedSaliencyImageRequest`, already running per photo at pick time |
| Pure framing math | `Sources/Engine/AutoFrame.swift` | Takes `faces: [CGRect]`, `faceConfidences`, `salientRegion`, all normalized top-left. Already thresholds faces at confidence 0.5 and 8 percent of the short edge |
| Template list | `Sources/Engine/Templates.swift` `templates(for:)` | The candidate set to search over |
| Assignment search | `Sources/Engine/Assignment.swift` `contentFitAssignment` | Brute force over <= 24 permutations, currently scored by ASPECT match only |
| Layout solve | `Sources/Engine/Layout.swift` `solve(root:canvasSize:border:)` | Gives cell rects for a template |
| Document build | `Sources/App/Library/PickerView.swift:245` `buildDocument` | Async, shows "Framing your photos..." |
| The seam we replace | `PickerView.loadingOverlay` (~line 1127) | A black 0.6 scrim plus a spinner, shown during exactly the work we want to dramatize |
| Choreography precedent | `EditorView.runGhostGestureDemo` + `Sources/App/Onboarding/CoachMarks.swift` | Async keyframe loop, snapshot/restore, skip catcher, Reduce Motion handling. Copy these patterns |
| Geometry export precedent | `CanvasView.coachMarkAnchorMarkers` | How live rects reach an overlay. NOTE the rule: `anchorPreference` attaches to the SIZED child BEFORE `.position`, never after |

## Architecture decision (the crux - already made)

**Host the animation in a full-screen `MagicLayoutOverlay` owned by `ContentView`, above both the picker and the editor.**

Why this and not the alternatives:

- The **picker** owns the source geometry (thumbnail frames) but is torn down at handoff.
- The **editor** owns the destination geometry but does not exist until `commitNewCollage` runs.
- Neither view can own an animation that spans both. `ContentView` outlives both, so an overlay there can hold the source frames, run the whole sequence, and fade out onto an already-mounted editor.

Rejected: running it inside `PickerView` and relying on an invisible cut into the editor (fragile - the two canvas rects must match to the pixel or the handoff pops). Rejected: hoisting a `matchedGeometryEffect` namespace into `ContentView` (couples all three views and fights the existing `if let editorState` swap).

The overlay needs exactly three inputs:

1. **Source frames + images** - each selected thumbnail's frame in global coordinates, published from `PickerView` via a `PreferenceKey` at confirm time.
2. **The finished document** - `Document` + `[PhotoID: UIImage]` from `buildDocument`, plus the destination cell rects from `solve()` against the editor's canvas size.
3. **The face rects** - per photo, normalized, already available from `PhotoLibraryService`. These must be plumbed out of `buildDocument` rather than discarded (today only the derived `ROI` survives).

Handoff: the overlay runs while `commitNewCollage` mounts the editor underneath it, then crossfades out onto the editor's first frame.

## Phases

Each phase is independently shippable and independently verifiable. Do them in order.

### Phase 0 - Dramatize what already happens (no algorithm work)

The cheap test of whether the theater lands. No `B30` needed.

- Replace `loadingOverlay` with the overlay above.
- Thumbnails fly from their picker positions into the cell rects of the CURRENT (aspect-chosen) template.
- Real face boxes appear on the photos where Vision found them.
- Each cell settles into the crop `autoFrame` already chose.
- Crossfade to the editor.

Acceptance: the sequence plays end to end on a real pick, any touch skips instantly to the finished editor, Reduce Motion cuts straight through, and total added wall-clock over today's spinner is under 400ms.

**Stop here and judge.** If the theater does not delight at this stage, the algorithm work will not save it.

### Phase 1 - The real decision (Engine, pure, testable)

This is `B30`'s core. All of it lives in `Sources/Engine`, which is platform-pure and covered by the standalone smoke test.

1. **Must-keep region.** Union of surviving face rects (reuse `AutoFrame.swift`'s existing confidence and size thresholds) plus a margin. Fall back to `salientRegion` when no face survives, and to nil when neither exists (landscapes must keep working).
2. **`framingCost(mustKeep:photoPixelSize:cellAspect:) -> Double`.** Find the minimum zoom whose crop still contains the must-keep region, then penalize: any face clipped (heaviest), face height below a minimum fraction of cell height, excessive crop loss, and must-keep aspect far from cell aspect. Reward the opposite. Deterministic, no randomness.
3. **Search templates and assignments together.** For each candidate from `templates(for:)`, solve for cell rects, run the existing permutation search but scored by `framingCost` instead of aspect distance, and keep the best pair. Roughly 10 templates times 24 permutations for four photos, all rect arithmetic, no second Vision pass.
4. **Degrade to today's behavior** when no photo yields a must-keep region, so the change is a strict improvement rather than a replacement.

Acceptance: new smoke-test assertions covering a clipped-face case, a group-shot-wants-a-wider-cell case, a no-faces landscape case, and determinism (same input, same output, twice). Existing 174 assertions still pass. Measured decision time under 20ms for four photos on device.

### Phase 2 - Divider search (the real unlock)

Let each divider move within roughly 0.3 to 0.7 in coarse steps (5 positions is plenty) nested inside the Phase 1 search, so a cell can GROW to fit a group shot rather than cropping it. Keep the total evaluation count in the low thousands and measure it.

Acceptance: a group photo that Phase 1 still clips now gets a taller or wider cell instead. Decision time still under 60ms.

### Phase 3 - The full theater

Rebuild the Phase 0 sequence against the real decision, and add the re-run affordance.

Beats, with the constraint that the whole thing is an overlay on an already-finished result:

1. **Arrive** (~250ms) - thumbnails appear at their picker positions, everything else dims.
2. **Scan** (tie to real work, cap at ~700ms) - a sweep passes over the photos and the real face boxes light up as they are found. If Vision finished earlier, this is a re-enactment, which is fine. Never hold purely for show when the result is ready.
3. **Assemble** (~700ms) - thumbnails fly and morph into their chosen cells. **Animate the crop, not just the frame**: picker thumbnails are square crops and final cells are varied aspects with their own crops, so a frame-only morph will visibly jump at the end.
4. **Settle** (~250ms) - boxes fade, border and chrome resolve, crossfade to the editor.

**Re-run affordance** (this replaces B31's original revert-toggle, which meant "make it worse"): a control that replays the sequence and lands on the NEXT-best scoring layout. Forward, not backward. Manual escape already exists in the Layout tab; Undo covers regret.

Rationing: full sequence on the first-ever collage, a shortened version afterwards, plus a Settings toggle. Any touch jumps to the end state. Reduce Motion skips entirely.

Degradation: if detection is weak or finds fewer faces than expected, skip the box-reveal beat and just assemble. Never advertise a miss.

**REVISION (Justin, 2026-07-28) - the affordances perform the work; there is no ghost fingertip.**

The original Phase 3 assumed a separate teaching animation. Two problems surfaced: a first-time user today gets the reveal AND the existing ghost gesture demo back to back, roughly seven seconds of watching before they can touch anything; and a demo that distorts the layout and restores it sits badly right after the app has argued that this layout was chosen carefully.

The better shape is one continuous sequence in three movements:
1. **Assemble** - photos fly, faces glow, the layout resolves. *We did this.*
2. **Handover** - the glow does not simply fade; it migrates outward into the divider capsules and corner brackets, which light up as it arrives. Same visual language carrying from "our work" to "your controls". *These are yours.*
3. **Invitation** (first run only) - if anything is still needed after 1 and 2.

Movements 1 and 2 always play; anything in 3 is conditional, which resolves the lifetime mismatch (the reveal is per-pick, teaching is once-ever) without two separate systems.

**The key idea: nothing moves for show.** The affordances perform the REAL adjustment rather than demonstrating a gesture. Phase 2 made this possible - dividers now genuinely move from the template's authored fractions to the chosen ones, so animating that journey is not decoration, it is the delta the intelligence produced. It costs almost nothing, because the layout has to reach those fractions anyway. And it needs no restore, because the motion is productive.

This also redeems the "start from a boring template" instinct honestly: the authored template IS the real before - what you would have got without face-awareness - so no staging is required to show the contrast.

Watch for: **imperceptible deltas** (a divider moving 0.50 -> 0.55 may not read; an overshoot-and-settle easing keeps small moves legible without claiming anything false, below which it is better to skip the emphasis than manufacture drama), and the **no-adjustment case** (faceless sets take the degrade path and nothing moves - correct, and it makes motion mean something: movement signals the app found something, stillness signals it did not).

**Open, pending the device pass:** whether the existing ghost gesture demo is still needed at all. The divider capsules and corner brackets are now always visible, and the reveal already puts the eye on the layout, so the grammar may teach itself - which was the PRD's original position. Until Phase 5 lands the brackets can only glow (no decision sits behind them, so moving them would be faking); after it, they can perform.

### Phase 5 - Canvas ratio joins the decision (and gives the brackets something true to perform)

**Run this BEFORE Phase 4.** Tuning should tune the whole decision at once, and this changes the outermost variable.

**Why it belongs (Justin, 2026-07-28).** The app already commits to a canvas ratio the moment a collage arrives - that choice simply is not informed by the photos. So this is not "should the app decide"; it already decides, badly. Ratio is also plausibly the highest-leverage variable in the system, because every cell aspect is a product of canvas ratio x template x divider fractions: Phases 1 and 2 optimise the inner two while the outer one is pinned. Four portraits in a square canvas crops every face harder than necessary no matter how well the dividers move, and that is probably the worst common arrival case in the app today.

**Start crude, on purpose.** A simple content rule captures most of the value and is a few lines in the Engine:
- all photos portrait -> prefer a portrait preset
- all landscape -> prefer a landscape preset
- mixed -> square
A later refinement can score the combined must-keep regions' aspect through `framingCost` the same way cells are scored, but do NOT start there.

**Constrain the search to the RATIO PRESETS, deliberately.** Ratio encodes destination, not only composition - 9:16 means a Story, 4:5 means the tallest Instagram feed post. A continuous search would always find some perfect-fitting 2.37:1 canvas that is beautiful and unpostable. The presets carry destination-appropriateness the cost function cannot see. The algorithm picks among presets; the user drags the brackets to anything they like. Each does what it is good at.

**Two guardrails, both judgement calls that want real photos:**
1. **Sticky preference.** Once the user sets a ratio by hand, that is stated intent - remember it and stop guessing, exactly as border thickness now works. Auto-choose only where no preference exists.
2. **Override threshold.** Only depart from the default when the improvement is clearly significant. Churning the canvas shape for a marginal gain is worse than a mediocre default.

**The animation payoff.** Today the brackets can only glow, because no decision sits behind them - see the Phase 3 revision. Once ratio is genuinely chosen, the brackets have something true to perform: the canvas visibly reshaping to suit the photos, through the same control the user will later grab. That teaches the corner gesture - the app's least obvious, highest-value affordance - without a ghost fingertip and without staging.

**Explicitly ruled out: starting from a deliberately wrong ratio to dramatise the fix.** It reads as a comparative claim ("we improved this for you") that no decision backs. The practical objection is stronger than the principled one: if the canvas always starts wrong and always resolves the same way regardless of content, the users who make five or ten collages notice the fix never varies, and at that point the whole sequence reads as canned - which puts the genuinely real beats (detection, template choice, divider moves) under suspicion too. The real work is impressive enough to carry the theater; faking one beat devalues the rest.

Acceptance: Engine-only decision with smoke-test coverage (all-portrait, all-landscape, mixed, single-photo-dominant, and a sticky-preference case that must NOT be overridden); the faceless degrade path unchanged; and a measured decision time that keeps the whole search inside budget (Phase 2 alone is ~7ms worst case, so a preset sweep needs pruning or an early-out).


### Phase 4 - Tune against a real camera roll

The long pole, and it is judgment rather than engineering. Budget most of the calendar time here. Pair it with the `B26` device pass.

## Verification plan

- **Engine**: extend `Tests/SmokeTest.swift` (`swiftc -O Sources/Engine/*.swift Tests/SmokeTest.swift` per the Build Guide). This is the main safety net and it is cheap.
- **Animation**: simulator screenshot sequences, the pattern used throughout this project. Launch with `-resetPersistence -autoPick 4`, capture at ~0.3s intervals in a background loop, and assert on measured geometry rather than eyeballing.
- **Timing**: measure and report added wall-clock against today's spinner. It is a regression if the app feels slower.
- **On device**: the animation must be judged on a phone, not the simulator.

## Build log

- **Phase 1 - DONE 2026-07-28.** `Sources/Engine/MagicLayout.swift`: `mustKeepRegion`, `framingCost`, `faceAwareAssignment`. Smoke test 174 -> 219. Review caught that the degrade guarantee did not actually hold: the search re-derived the template from aspect cost while today's flow uses `defaultTemplateIndex`'s orientation heuristic, and the two disagreed on half of a spread of faceless sets. Fixed with an explicit fallback guard plus asymmetric test cases (the original test used two identical photos, which agree by symmetry and could never have caught it). NOT yet wired into the App layer.
- **Phase 0 - DONE 2026-07-28.** `Sources/App/MagicLayout/MagicLayoutOverlay.swift` plus plumbing. Verified on simulator with real taps.
  - **Timing missed the budget: ~1.4s added, not 400ms.** The arrive and scan beats are free (they cover `loadForEditing` + Vision), but box reveal + assemble + settle can only run after the result exists. The spec's own beat budget (1900ms) only fits inside 400ms if the covered work takes >= 1.5s, and it does not. Levers: overlap the settle with the assemble tail (-250ms), shorten assemble to ~450ms (-250ms), stream Vision per photo so boxes light DURING the scan (-350ms). **Recommendation: ration instead of trimming - keep the full show for the first collage, cut hard for later ones - which is Phase 3's rationing brought forward.**
  - **Finding: Vision is dead in the iOS Simulator** ("Failed to create espresso context"), and the error was previously swallowed and returned as "no faces". Every simulator run has been exercising the center-fill fallback, so all prior simulator-based judgement of B20 auto-framing was of the fallback, not the feature. A CPU-only retry (after the default throws only, never on device) fixes it. **This retroactively weakens any auto-framing conclusion drawn from a simulator before 2026-07-28.**

## Current state (2026-07-28, end of day)

- **Phase 0 - DONE and committed.** Overlay, transition, scan, assemble.
- **Phase 1 - DONE, committed, and WIRED IN.** `buildDocument` now runs two passes: gather each photo's `mustKeepRegion`, then call `faceAwareAssignment` in place of `defaultTemplateIndex` + `contentFitAssignment`. Faces choose the layout.
- **The reveal now shows causality.** Each detected face gets a glowing square and the destination cells resolve WHILE the glows are lit, so the arrangement visibly follows from the faces. At the end all theater clears and the editor's drag handles arrive, handing control back.
- **Verified 2026-07-28** on simulator with two portraits: five faces detected and glowed, resolved to a stacked layout keeping every face whole, clean handoff. Debug + Release build; smoke test 219/219. **Installed on Justin's device.**
- **Phase 2 - IN PROGRESS** (divider search). Seam is marked in `MagicLayout.swift`.
- **Phase 3/4 - not started.** Rationing, the re-run affordance, and tuning against a real camera roll.

### Unverified, and worth checking first on device
Skip-on-touch and Reduce Motion after the glow rework; the "never glow a face the final layout clips" rule; and the added wall clock (last measured at ~1.4s BEFORE the glow beat, so likely longer now). Justin's call on pacing is the open decision - recommendation on record is to ration (full show on the first collage, short after) rather than trim uniformly.

## Risks

- **This is arrival, the app's first impression**, layered on top of `B20` (auto-zoom), already flagged as the riskiest shipped feature. A bad frame here is the first thing every new user sees.
- **Perceived slowness.** The mitigation is that the animation covers work that genuinely takes time. If it ever waits on nothing, cut it.
- **Async photo loading**: full-resolution images arrive after the proxies. The overlay must animate proxies and never pop.
- **Vision misses** on profiles, sunglasses, and small faces. Handled by the degradation rule, but it needs real-library evidence.
- **Over-optimization looks mechanical.** A "good enough" threshold that keeps the current aesthetic default may beat a strict optimum. Watch for layouts that are technically optimal and visually cold.

## Honesty line (settled 2026-07-28)

The starting state asserts nothing, so it does not need to be a "real" alternative layout - raw thumbnails assembling make no comparative claim. What must stay true: **the final layout is genuinely the one the algorithm chose, and the boxes are genuinely what Vision found.** Separately, do not build a before/after comparison in marketing framed as "what you would get without the AI" - that is where a real claim would start. See `Backlog.md` B31 for the full reasoning.
