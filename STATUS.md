---
title: "STATUS - Photo Collage"
created: 2026-07-24
modified: 2026-07-28
version: 3.1
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Photo Collage - Status

## Project

Mosaic, an iOS collage app (the spiritual successor to Instagram's discontinued Layout). Pick 2-4 photos, arrange them in a draggable split-tree layout with a signature diagonal corner-resize handle Layout never had, auto-frame faces/subjects on-device via Vision, adjust ratio/border, and export a full-resolution JPEG to Photos with correct EXIF (earliest source date/location), something Layout famously never did.

## Stage

Active Development, in App Store preparation. Feature-complete for v1 including the freemium unlock; the App Store Connect record exists and most listing metadata is entered.

## Health

🟡 At-risk - a great deal has been built and verified in the simulator, but **almost none of it has been used on a real phone**, and one finding makes that gap worse than it looked: Vision fails silently in the iOS Simulator, so every simulator judgement of auto-framing was of the fallback, not the feature. The device pass is now the single highest-value hour available.

## Waiting on Me

- [ ] **Run the device pass** - one guided checklist covering the original eight B26 checks plus everything built since: https://claude.ai/code/artifact/305b73b7-df5c-4e5b-8c15-4ed499e89625 (~45 min). Judge auto-framing and Magic Layout hardest; they have had the least honest evaluation.
      - unblocks: B26, Phase 7 sign-off, and the Magic Layout pacing decision
- [ ] **Drop ~40 real photos in a folder for layout tuning** - messy everyday ones, not your best. Then `Tools/LayoutLab/run.sh <folder>` renders judgement sheets. This is the whole of Phase 4, and it is the gate on whether the face-aware layout and the new canvas ratio are actually any good (~10 min for you, then a conversation over the sheets)
      - unblocks: B32 Phase 4, and the canvas-ratio finding below
- [ ] **Decide Magic Layout pacing** - the reveal adds roughly 1.5s+ per collage. Recommendation on record: ration it (full show on the first collage, short after) rather than trimming the choreography. Needs your gut after four collages in a row (~5 min, during the device pass)
      - unblocks: B32 Phase 3
- [ ] **Set the real IAP price and create the in-app purchase in App Store Connect** - $2.99 is a placeholder in `Mosaic.storekit`. The IAP must be submitted WITH the first version (~10 min)
      - unblocks: submission
- [ ] **Test a real purchase from an Xcode run** - StoreKit only attaches to the scheme in Xcode, not a plain install, so this cannot be verified any other way (~10 min)
      - unblocks: B8 sign-off
- [ ] **Finish the App Store Connect listing** - everything is drafted and most fields are entered; the save was blocked on the App Review contact phone number. All values are in `App Store Listing.md` (~10 min)
      - unblocks: submission
- [ ] **Build the layered app icon in Icon Composer** - GUI-only, no CLI exists, so this is the one asset that needs your hands (~20 min). Dark and tinted asset-catalog variants already ship, so this is an improvement rather than a blocker
- [ ] **One TestFlight tester besides you** (~15 min)
      - unblocks: submission
- [ ] **Sign off the accent color** - mockups in `_review/phase7-accent-*.png`; the brand blues are locked in code, so this is a confirmation rather than an open choice (~5 min)

## Next Up

1. The device pass, top to bottom. It gates B26, the pacing decision, and any honest read on auto-framing quality.
2. Report what the pass turns up; flags become the punch list.
3. Then either B32 Phase 5 (canvas ratio joins the decision, see `Magic Layout Spec.md`) or the remaining App Store fields, depending on whether the goal is a better app or a submitted one.

## Recently done (2026-07-28, evening)

- **B32 Phase 5 - the canvas ratio joins the decision.** Every collage used to be born square by a hardcoded literal; the photos now get a say in the outermost variable in the whole layout system. Wired in end to end, with a sticky preference so that once you set a ratio by hand the app stops guessing. **But see Biggest Risk: with the current cost function it almost never actually changes anything.**
- **LayoutLab, the Phase 4 tuning harness** (`Tools/LayoutLab/`). Point it at a folder of photos and it renders one sheet per set: today's layout beside the face-aware one, faces outlined, clipped faces in red. This is what turns "tune the weights against a real camera roll" from hours of hand-building collages into a flip-through.
- **The reveal's unverified list is closed.** Skip-on-touch at three beats, Reduce Motion, the clipped-face rule and the edge paths all verified. The added wall clock is now measured rather than guessed: **+1.66s**, four times the budget - which makes the pacing call the feature's biggest open question.
- **A glow-gating race found and fixed** - glows could be enabled from a plan build that skipped the clipped-face filter. Narrow (~30ms) and never observed visibly, but it is the one artifact this beat must never produce.

## Recently done (2026-07-28)

- **B32 Magic Layout Phases 0, 1 and 2** - the picker-to-editor cut is now a sequence: chosen photos fly in, each detected face glows, the layout resolves while the glows burn, then all theater clears as the drag handles return. Faces genuinely choose the template and assignment, and dividers now move so a cell can grow to fit a group shot. On your phone (Phases 0-1); Phase 2 lands with the next deploy.
- **B33 / Phase 5 specced** - canvas ratio joining the decision, which also gives the corner brackets something true to perform in the reveal.
- **Repo pushed to GitHub** (`nikolausj1/mosaic`) - the week's work now exists in three places rather than only on this machine, after a Dropbox/disk failure made that risk concrete.
- Earlier the same day: eyedropper sampling fix, bolder ghost-demo reshape, the Settings watermark upsell card, spanning App Store screenshots, icon appearance variants, privacy/support pages live.

## Ideas Shelf

- **Eyedropper border color** (S) - tap an eyedropper, tap anywhere in the collage, that exact color becomes the border; makes the frame feel like it belongs to the photos (Backlog B11)
- **Free rotation** (S) - arbitrary-angle rotation within a cell, snapping at 0; fixes the rare crooked-horizon photo Photos.app didn't already straighten (Backlog B15)
- **Auto color as a real feature** (S-M) - v1 ships derived border-color suggestions prepended to the swatch row; the fun version is a dedicated mode with several generated palettes to flip through (Backlog B12)
- **5-9 photos** (M) - the split tree is entirely count-agnostic, so this is a config change plus new template art; Instagram Layout supported up to 9 and people used it (Backlog B9)
- **iPad support** (L) - Layout never shipped an iPad app in nine years, an open gap in the category; real work since the editor's proportions and tray layouts don't transpose for free (Backlog B10)

## Biggest Risk

Layout quality has never been judged against real photos, and there is now hard evidence that matters. The new canvas-ratio decision (Phase 5) is wired in and verified correct, yet it clears its own override threshold in only 3 of 30 probe cases and did not fire once in six real simulator picks. Worse, every all-portrait four-photo set scored WORSE at 4:5 than at square - which is the exact example that motivated building it. So either the cost function is missing something real or the intuition was wrong, and the same cost function drives auto-framing (B20), the feature most able to silently embarrass the app on a stranger's photos. All of it has only ever been judged against ~4 curated photos and simulator runs. LayoutLab now makes the real test cheap; it just needs your camera roll.

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

Done
- [x] Apple Developer Program, Paid Apps Agreement, banking, W-9, EU trader status - all Active
- [x] App Store Connect record: "Mosaic: Photo Collage & Layout", Apple ID 6795437010, bundle com.levelup.mosaic
- [x] Privacy policy + support pages live (GitHub Pages), both URLs verified
- [x] Listing copy, App Review notes, age rating and nutrition-label answers drafted in `App Store Listing.md`
- [x] Screenshots: five 6.9" panels, spanning-banner design, in `_store/screenshots-v2/`
- [x] App icon dark + tinted appearance variants (verified compiled via assetutil)
- [x] Submission config: no personal photos or debug launch args in Release, automatic signing, one version source, PrivacyInfo.xcprivacy, Photography category
- [x] Source pushed to GitHub

Still to do
- [ ] Everything in "Waiting on Me" above
- [ ] **Gate the Settings dev rows behind #if DEBUG** - "Replay first-run experience" and "Clear collages" currently ship in Release at Justin's request; must be gated or removed before submission
- [ ] Recapture the IAP review screenshot from an Xcode run so the button shows the real price
- [ ] Archive + upload a build, then TestFlight
- [ ] Featuring nomination (~3 months lead time recommended; pitch drafted)

Open risk: the "Mosaic" trademark question stays accepted-but-unresolved (13 leading matches, plus an existing App Store app in the category). The compound title helps discovery, not legal exposure.

Structural risk: the project lives inside Dropbox, which caused a multi-hour outage on 2026-07-28 (file provider failing to serve repo files under disk pressure). Moving it to `~/Developer` is the real fix; Xcode projects in cloud-synced folders are a known-bad combination.
