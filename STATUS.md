---
title: "STATUS - Photo Collage"
created: 2026-07-24
modified: 2026-07-28
version: 2.2
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Photo Collage - Status

## Project

Mosaic, an iOS collage app (the spiritual successor to Instagram's discontinued Layout). Pick 2-4 photos, arrange them in a draggable split-tree layout with a signature diagonal corner-resize handle Layout never had, auto-frame faces/subjects on-device via Vision, adjust ratio/border, and export a full-resolution JPEG to Photos with correct EXIF (earliest source date/location), something Layout famously never did.

## Stage

Active Development (Phase 6 of 7 complete; Phase 7, visual polish, in progress)

## Health

🟡 At-risk - feature-complete including the new freemium unlock, and submission-config clean, but nothing has been verified end-to-end with your own real photos yet (every phase's "happy path" was proven on the simulator or with bundled test photos), and B27 (onboarding) plus the accent/icon picks are still open.

## Waiting on Me

- [ ] **Run the B26 device checklist** - now a guided tap-through page you can open on your phone: https://claude.ai/code/artifact/305b73b7-df5c-4e5b-8c15-4ed499e89625 (~30 min)
      - unblocks: the only remaining unverified path to "done," and Phase 7 sign-off
- [ ] **Try the new freemium flow in an Xcode run** - Save with watermark, the paywall from the save sheet's Remove link, a test purchase (Mosaic.storekit is wired into the scheme so the $2.99 unlock works in Simulator/device runs from Xcode), then a Save without watermark (~10 min)
      - unblocks: B8 sign-off
- [ ] **Decide B27: onboarding.** You asked for splash + onboarding screens; the PRD locks a no-tutorials principle instead (first-launch auto-selected cell *is* the onboarding). Pick one: (a) hold the PRD line [Claude's recommendation], (b) one dismissible first-run hint, (c) full onboarding, which means formally rewriting the PRD principle (~5 min)
      - unblocks: building or formally closing the onboarding question; can't submit to the App Store with this open
- [ ] **Pick the accent color** - mockups in `_review/phase7-accent-*.png`; icon is now DECIDED (Justin supplied final brand assets 2026-07-26: tangram-M icon + mosaic lockup, integrated same day as app icon, picker masthead, and watermark chip) (~10 min)
      - unblocks: Phase 7 visual polish sign-off
- [ ] **Judge the full 2026-07-26 batch on your phone** (three deploys, latest has everything): deep-blue CTA and selection, full-screen first-run welcome flowing into the picker, single-screen spotlight coach marks with real cutout holes, thumbnail-size control (3/4/5 columns), Developer sheet (hammer icon: replay first-run, clear collages - MUST be gated before App Store submission, tracked in Ship Plan), plus everything from earlier: always-on divider handles, back-chevron header, nothing-is-destructive navigation, sixth brightest swatch, freemium watermark (~15 min)
      - unblocks: Icon Composer layered build and Phase 7 sign-off
- [ ] **Judge the picker rework (this session, 2026-07-26, second batch)**: welcome screen is now a slower, bigger title sequence (2.2x lockup, staggered teaching rows, a new quiet 4th line about on-device AI, "Get started" moved to the bottom as the same capsule as the floating CTA); the floating CTA's disabled state is now a flat opaque grey (no more see-through-looking fill); the thumbnail-size tap control is GONE, replaced by a pinch gesture directly on the grid (pinch in = more/smaller columns, out = fewer/bigger, like Photos); default grid is now 3 columns; the picker header got a real hero moment that collapses to a compact bar as you scroll and restores at the top; the Dev Tools icon moved from the header row into that hero's top-right corner and changed to the three-dot glyph; and the "wrong photo gets selected" bug you reported is fixed (root cause: the grid keyed cells by index instead of the photo's own stable ID, so a changed library between visits could show a stale photo under a live selection state) (~10 min)
      - unblocks: closing the selection-bug report and folding this into the next full-batch device pass above
- [ ] **Judge the editor batch (2026-07-26, final batch, deployed)**: spotlight coach marks now always teach the corner gesture (real cutout when the layout has a corner handle, a text tip when it doesn't); opening Border on a zero-border collage auto-bumps thickness to a visible starter; the export watermark uses your new watermark.png art; a 7th "luminous" derived swatch joins the row; and the color row gained a true canvas eyedropper (tap the eyedropper swatch, then tap any photo - that exact composited pixel becomes the border color) while the "+" system picker now presents from UIKit, fixing the eyedropper crash you reported (~10 min)
      - unblocks: closing the eyedropper crash report and B11
- [ ] **Judge the perf + polish pass (2026-07-26 night, deployed)**: picker lag and the 2-3s back-button delay fixed (root cause: the selection-bug fix was re-enumerating your whole photo library on every render; it now materializes once per fetch, and hero-collapse scroll updates are quantized); border starter reduced 0.045 to 0.02; coach marks now spotlight the CORNER handle (seam is a secondary text tip) (~5 min)
      - unblocks: closing the picker performance report
- [ ] **Judge the teach + eyedropper rework (2026-07-26 late night, deployed)**: first-run coach marks are GONE, replaced by a ghost gesture demo - a translucent fingertip drags the corner and then a seam on the user's own collage, live, then restores it exactly (tap skips; Dev sheet replay still works); the border eyedropper now has a proper magnifier loupe - touch and drag on the collage, a mag circle with crosshair and live color ring follows, release to apply (~5 min)
      - unblocks: closing the first-run teaching design and B11 for good
- [ ] **Judge the tap-bug fix + bracket demo (2026-07-27, deployed)**: the wrong-photo-selected bug is ROOT-CAUSED and fixed - the collapsing hero header sat above the grid's ScrollView, so collapsing it shrank the layout ~72pt and slid the grid under your finger mid-tap (intermittent because it only bit while the hero was collapsing near the top). The hero is now a fixed-height brand moment, no collapse; verified with a 48-photo numbered test library, four consecutive select/deselect operations all landing exactly, including immediately after a scroll. Also: the inactive CTA is now truly opaque (SwiftUI's .disabled() was dimming the whole button, including the opaque fill); and the ghost demo now drags a CANVAS CORNER BRACKET to reshape the aspect ratio freehand instead of the interior middle point (~10 min)
      - unblocks: closing the selection-bug report for good; if you still want the hero to shrink on scroll, it has to move INSIDE the scroll view as content - say the word
- [x] **DONE 2026-07-28: Apple developer/commercial setup verified and app record created.** Paid Apps Agreement, banking, W-9 and EU trader status all Active; App Store Connect record live as "Mosaic: Photo Collage & Layout" (Apple ID 6795437010, bundle com.levelup.mosaic). The name was available and is now reserved.
- [ ] **Judge the just-shipped layout-tray-on-arrival and border-visibility fixes** in hand - both are code-verified/sim-verified only, not device-confirmed by you yet (~10 min)
      - unblocks: closing those two fixes with confidence

## Next Up

1. Work the B26 checklist top to bottom on your phone with real photos (guided page linked above), the highest-value 30 minutes available; if it surfaces anything wrong with auto-framing, log real examples since B20 (auto-zoom) is flagged as the riskiest shipped feature and still collecting evidence.
2. Decide B27 (onboarding) and pick accent + icon (round-3 candidates in `_review/phase7-ai-icons-r3-sheet.png`); Claude then finishes the Icon Composer build and starts listing copy, screenshots, and the landing page.
3. Done 2026-07-26: Track 1 submission fixes (prototype photos out of Release, debug launch args gated, automatic signing, version alignment, privacy manifest, Photography category) and the full B8 freemium build (watermark + paywall + settings), sim-verified. Full diagnosis lives in `Ship Plan.md`.

## Ideas Shelf

- **Eyedropper border color** (S) - tap an eyedropper, tap anywhere in the collage, that exact color becomes the border; makes the frame feel like it belongs to the photos (Backlog B11)
- **Free rotation** (S) - arbitrary-angle rotation within a cell, snapping at 0; fixes the rare crooked-horizon photo Photos.app didn't already straighten (Backlog B15)
- **Auto color as a real feature** (S-M) - v1 ships derived border-color suggestions prepended to the swatch row; the fun version is a dedicated mode with several generated palettes to flip through (Backlog B12)
- **5-9 photos** (M) - the split tree is entirely count-agnostic, so this is a config change plus new template art; Instagram Layout supported up to 9 and people used it (Backlog B9)
- **iPad support** (L) - Layout never shipped an iPad app in nine years, an open gap in the category; real work since the editor's proportions and tray layouts don't transpose for free (Backlog B10)

## Biggest Risk

Auto-framing quality (B20) is the one feature that can silently embarrass the app on a stranger's random photo library, and it has only been judged against your ~4 curated test photos and simulator runs. It needs a real, harsh test against your actual camera roll before you'd want anyone else to hit Save.

---

## Deferred

- **B1** - bare-seam drag without selection (reversible; watching for accidental resizes in real use)
- **B7** - layout suggestion strip in the picker
- **B9** - 5-9 photos (v1 caps at 4)
- **B10** - iPad support
- **B11** - eyedropper border color
- **B13** - project library (multiple saved collages; v1 is single current+last)
- **B14** - picker search
- **B15** - free rotation (v1 is 90 degree steps only)
- **B21** - content-fit assignment vs. pick order (an alternative to aspect-based auto-placement)
- **B22** - cell-shape-aware ROI (auto-framing doesn't yet consider the destination cell's aspect)
- **B25** - picker fast-scroll scrubber, iCloud download progress ring, swatch recompute timing, all noted as polish, not correctness
- Debug HUD removal (gesture trace overlay) - stays until you formally sign off on gesture feel

## App Store Readiness

- [ ] Full B26 device pass (nothing has shipped to the Store without this)
- [ ] Resolve B27 (onboarding), can't submit with an open product-behavior question
- [ ] Finish Phase 7: final accent color + icon locked in from mockups
- [ ] Privacy nutrition label (Photos access, on-device-only processing, should be a short/clean one, no network calls exist)
- [ ] App Store screenshots (none generated yet)
- [ ] App Store listing copy (name, description, keywords), not started
- [ ] Decide in/out for v2 items currently excluded from v1: **StoreKit/paid unlock + watermark (B8)**, if this is meant to be a paid app or freemium at launch, that's a real chunk of unbuilt work, not polish
- [ ] TestFlight pass with at least one person besides you
- [ ] Final pass on Backlog "reversible decisions" (B1, B3, B4, B5, B6), confirm none need flipping before wide release
