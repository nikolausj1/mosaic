---
title: "HANDOFF - Mosaic session state"
created: 2026-07-28
modified: 2026-07-28
version: 1.0
author: Claude Fable 5 (claude-fable-5)
tags:
---

# HANDOFF

Written deliberately before compacting a long session. Everything here is what would otherwise be lost with the conversation; anything already durable is pointed at rather than repeated.

**Read these first, in order:** `STATUS.md` (what Justin owes, what is done), `Magic Layout Spec.md` (the active feature, all phases, architecture decisions already made), `Backlog.md` (B29-B33 carry the reasoning behind recent decisions), `Ship Plan.md` (App Store diagnosis), `App Store Listing.md` (every submission field, ready to paste).

## In flight right now

- **A verification sweep agent is running** against B32 Magic Layout. It owns `Sources/App/**` and simulator `44EE92E3-46CF-4ADD-9FB7-515C1A3BD7EC`. It was asked to produce a PASS/FAIL/CANNOT-TRIGGER verdict on five things, with evidence: (1) skip-on-touch at three different beats, (2) Reduce Motion bypass, (3) the "never glow a face the final layout clips" rule, (4) added wall clock measured against the bypass path, (5) the 2-photo / 4-photo / no-faces edge paths. It may make small clearly-correct fixes; anything that is a judgement call it was told to REPORT, not decide.
- **When it reports:** review it, fold in any fix, commit, then **deploy to Justin's phone** - that was promised and is outstanding. His device carries Phases 0 and 1 only; Phase 2 has not shipped to it.

## The immediate next actions

1. Review the verification sweep, commit, deploy to device (`DA1CF583-BC81-54E3-AFA8-11C8388367A6`).
2. Justin runs the device pass: https://claude.ai/code/artifact/305b73b7-df5c-4e5b-8c15-4ed499e89625
3. Two decisions are waiting on him and should NOT be made for him: the Magic Layout **pacing** (ration vs trim - recommendation on record is ration), and the **layout scoring weights**, which are placeholders that need tuning against his real camera roll (Phase 4).

## Things that will bite you, learned the hard way

- **Vision does not work in the iOS Simulator.** Requests throw "Failed to create espresso context". A CPU-only retry in `PhotoLibraryService` (runs only after the default path throws, never on device) makes it work. Consequence worth remembering: every simulator judgement of auto-framing BEFORE 2026-07-28 was judging the center-fill fallback, not the feature.
- **`anchorPreference` must attach to the SIZED child BEFORE `.position(...)`, never after.** Attaching after publishes the whole container's bounds. This caused a canvas-sized "spotlight hole" once already.
- **A symmetric test can hide an asymmetric bug.** The Phase 1 degrade guarantee "passed" with two identical photos and diverged on three of six asymmetric sets. There is a standing probe pattern: run `faceAwareAssignment` with empty `mustKeepRegions` across mixed-orientation sets and assert it matches `defaultTemplateIndex`.
- **Determinism must be tested across PROCESSES, not within one.** Swift reseeds hashing per process, so a same-process repeat cannot catch dictionary-order dependence. Build a small probe binary and run it twice.
- **`-autoPick N` picks the newest photos, which on a used simulator are previously SAVED COLLAGES**, not source photos. Drive the UI with real taps when the content matters.
- **`timeout` is not installed on macOS.** `timeout 20 cmd` fails and can look like the command itself timed out.
- **The smoke test needs the `main.swift` trick**: top-level statements only compile in a file with that name. `D=$(mktemp -d) && cp Tests/SmokeTest.swift $D/main.swift && swiftc -O Sources/Engine/*.swift $D/main.swift -o $D/smoke && $D/smoke`
- **`Sources/Engine/**` is platform-pure** and compiled standalone by that test. Never import UIKit/SwiftUI/Photos/Vision there.

## Environment

- Device: `DA1CF583-BC81-54E3-AFA8-11C8388367A6` ("JustinN", iPhone 16 Pro Max). Often unreachable; a poll-and-install loop is the reliable way to catch it.
- Simulators: `44EE92E3...` (iPhone 16 Pro, editor/prototype testing) and `37BF44EB...` (iPhone 16 Pro Max, 6.9" screenshot size; its library has AI-generated landscapes plus two portraits WITH FACES, which is what makes the glow beat testable).
- Build products: `~/Library/Developer/Xcode/DerivedData/Mosaic-gshdtqiuajpkdjeibqmwpsphrwiy/Build/Products/`
- XcodeGen project; `project.yml` is the source of truth and `Mosaic.xcodeproj` is gitignored. Run `xcodegen generate` after adding files.
- Git history is backed up as a bundle at the session scratchpad `backup/mosaic-history.bundle`, and pushed to `github.com/nikolausj1/mosaic` (PUBLIC - keep personal photos and PII out).

## Known structural risk

The project lives inside Dropbox. On 2026-07-28 the boot volume filled to 99% and Dropbox's file provider stopped serving repo files; reads and `git` timed out for hours and all agent work had to be halted. Freeing 5.8GB plus a reboot fixed it. **Moving the project to `~/Developer` is the real fix** - Xcode projects in cloud-synced folders are a known-bad combination. Not done, because it is Justin's call.

## What I need from Justin (nothing else is blocking me)

1. **The App Review contact phone number**, to finish the App Store Connect listing. He supplied it in chat; it is deliberately NOT recorded here or anywhere in this repo, because the repo is public. Ask him again.
2. The device pass results.
3. The two decisions above (pacing, and eventually tuning).
