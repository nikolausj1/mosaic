---
title: "HANDOFF - Mosaic session state"
created: 2026-07-28
modified: 2026-07-28
version: 2.0
author: Claude Opus 5 (claude-opus-5)
tags:
---

# HANDOFF

Everything here is what would otherwise be lost with the conversation; anything already durable is pointed at rather than repeated.

**Read these first, in order:** `STATUS.md` (what Justin owes, what is done), `Magic Layout Spec.md` (the active feature - all phases, every decision, and the build log with measured numbers), `Backlog.md` (B29-B33 carry the reasoning), `Ship Plan.md`, `App Store Listing.md`.

## The one thing that matters most right now

**The layout intelligence has never been judged against real photos, and there is now evidence it does not behave as assumed.** The Phase 5 canvas-ratio decision is wired in and verified correct, yet:

- it cleared its own override threshold in **3 of 30** probe sets, and in **none of six** real simulator picks including an adversarial one;
- the challenger scored **worse than square in 17 of 30** cases, so the orientation-only nomination rule proposes losers about half the time;
- **every all-portrait 4-photo set scored worse at 4:5 than at square** - which is precisely the example that motivated building the phase.

So either the cost function is missing something real about canvas shape, the motivating intuition was wrong, or comparing costs across canvases of different total area is not apples-to-apples. The same cost function drives auto-framing (B20), the feature most able to embarrass the app on a stranger's library.

**Do not tune this against synthetic inputs.** The probe above used invented must-keep regions; tuning a cost function against invented data is how you get confidently wrong. `Tools/LayoutLab/` was built to answer it properly against a real camera roll. That is Phase 4, and it is now the gate on the whole feature.

## In flight

- **A device install poll is running.** Justin's phone (`DA1CF583-BC81-54E3-AFA8-11C8388367A6`) was unreachable all evening except a single minute at 18:32. A Release build containing Phases 0, 1, 2, 5 and the Phase 3 rationing is built and waiting at `~/Library/Developer/Xcode/DerivedData/Mosaic-gshdtqiuajpkdjeibqmwpsphrwiy/Build/Products/Release-iphoneos/Mosaic.app`. **What is currently ON his phone is the 16:55 build: Phases 0, 1, 2 only.** If the poll has expired, re-run the install; a USB connection or unlocking the phone on the same network is the usual unblock.

## What landed this session

- **Phase 5** - canvas ratio joins the decision, Engine and App. Sticky preference persists from a tray tap or bracket drag, never from the app's own choice.
- **Phase 3 (rationing half)** - post-result beats scale by how long the covered work took, and the generous timing is spent once. Later collages 1388ms vs a 1062ms bypass baseline, i.e. **+326ms**, inside the original 400ms budget. Settings gains Always / First time only / Off.
- **LayoutLab** (`Tools/LayoutLab/run.sh <folder>`) - the Phase 4 harness.
- **The reveal's unverified list closed** - skip-on-touch, Reduce Motion, the clipped-face rule, edge paths. Added wall clock measured at +1.66s before rationing.
- **A glow-gating race fixed** - glows could be enabled from a plan build that skipped the clipped-face filter. ~30ms exposure, never observed visibly, fixed defensively.

## Deliberately NOT built, and why

**The Phase 3 "handover" movement** (glow migrating outward into the divider capsules and corner brackets) waits on the ratio finding above. Until the ratio decision genuinely fires, the brackets have nothing true to perform, and animating them anyway would stage exactly the comparative claim the spec's honesty line rules out. The re-run affordance is also unbuilt.

## Things that will bite you, learned the hard way

- **Vision does not work in the iOS Simulator.** Requests throw "Failed to create espresso context"; a CPU-only retry in `PhotoLibraryService` (runs only after the default path throws, never on device) fixes it. **Consequence: every simulator timing and framing judgement runs the CPU fallback and is not device-representative.**
- **`xcodegen generate` after adding ANY file.** `project.yml` is the source of truth and `Mosaic.xcodeproj` is generated and gitignored. This broke the build once today in a confusing way: the Engine smoke test globs `Sources/Engine/*.swift` so it passed, while the app target had a stale file list and failed on the same symbol.
- **`anchorPreference` must attach to the SIZED child BEFORE `.position(...)`, never after.**
- **A symmetric test hides an asymmetric bug.** The Phase 1 degrade guarantee once "passed" using two identical photos and diverged on 3 of 6 asymmetric sets. The standing probe pattern: run the decision with empty `mustKeepRegions` across mixed-orientation, differing-size sets and assert it matches `defaultTemplateIndex` + `contentFitAssignment`. A lead-written version of this probe (3276 sets) is what proved Phase 5's degrade guarantee.
- **Determinism must be tested across PROCESSES**, not within one - Swift reseeds hashing per process.
- **`-autoPick N` grabs the NEWEST photos, which on a used simulator are previously SAVED COLLAGES.** Drive with real taps whenever content matters.
- **`timeout` is NOT installed on macOS.**
- **Simulator UserDefaults cannot be reset by editing the container plist** - `cfprefsd` caches independently of the file. Only a full uninstall/reinstall reliably clears it. Also, `defaults read <bundle-id>` via `simctl spawn` never works for a sandboxed app.
- **Screenshot scales differ**: the MCP screenshot preview renders at ~2x device points while raw `xcrun simctl io screenshot` is 3x. Mixing them causes mis-taps; use the raw 3x and divide by 3 for hit-testing.
- The smoke test needs the `main.swift` trick (top-level statements only compile in a file with that name):
  `D=$(mktemp -d) && cp Tests/SmokeTest.swift $D/main.swift && swiftc -O Sources/Engine/*.swift $D/main.swift -o $D/smoke && $D/smoke`
- **`Sources/Engine/**` is platform-pure.** Never import UIKit/SwiftUI/Photos/Vision there.

## Environment

- Device: `DA1CF583-BC81-54E3-AFA8-11C8388367A6` ("JustinN", iPhone 16 Pro Max). Frequently unreachable; poll-and-install is the reliable pattern.
- Simulators: `44EE92E3...` (iPhone 16 Pro, editor testing) and `37BF44EB...` (iPhone 16 Pro Max, 6.9" screenshot size). **Note:** the "portrait photos with faces" in `37BF44EB`'s library are actually 1024x1024 SQUARE, which silently defeats orientation-based tests - crop real portrait versions before relying on them.
- Build products: `~/Library/Developer/Xcode/DerivedData/Mosaic-gshdtqiuajpkdjeibqmwpsphrwiy/Build/Products/`
- Pushed to `github.com/nikolausj1/mosaic` (**PUBLIC** - keep personal photos and PII out).

## Known structural risk

The project lives inside Dropbox. On 2026-07-28 the boot volume filled and Dropbox's file provider stopped serving repo files; reads and `git` timed out for hours. **Moving the project to `~/Developer` is the real fix** - Xcode projects in cloud-synced folders are a known-bad combination. Not done, because it is Justin's call.

## What I need from Justin

1. **A folder of ~40 real photos** for LayoutLab. This is the gate on everything above.
2. **The device pass**, and his gut on pacing after four collages in a row.
3. **The App Review contact phone number**, to finish the App Store Connect listing. He supplied it in chat; it is deliberately NOT recorded here or anywhere in this repo, because the repo is public. Ask him again.
