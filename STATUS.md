---
title: "STATUS - Photo Collage"
created: 2026-07-24
modified: 2026-07-29
version: 3.7
author: Claude Opus 5 (claude-opus-5)
tags:
---

# Photo Collage - Status

## Project

Mosaic, an iOS collage app (the spiritual successor to Instagram's discontinued Layout). Pick 2-4 photos, arrange them in a draggable split-tree layout with a signature diagonal corner-resize handle Layout never had, auto-frame faces/subjects on-device via Vision, adjust ratio/border, and export a full-resolution JPEG to Photos with correct EXIF (earliest source date/location), something Layout famously never did.

## Stage

Active Development, in App Store preparation. Feature-complete for v1 including the freemium unlock; the App Store Connect record exists and most listing metadata is entered.

**Two builds now run side by side on Justin's phone.** `main` is the shippable 1.0 candidate. A second branch installs as "Mosaic Next" under its own bundle ID, carrying everything in `main` plus whatever is being judged by eye, so a taste call never has to be made against the build that ships. The full rule, including why the merge direction is one-way, is in `CLAUDE.md`.

## Health

🟡 At-risk, but for a better reason than yesterday. The layout intelligence has now been judged against 61 real photos rather than 4 curated ones, and it holds up: clipped faces drop from 22 to 2 across fifteen 4-photo sets, and 29 to 2 across twenty 3-photo sets. Two features that were written but never actually ran (auto-zoom, and the group-photo term) now run. What keeps this amber is that **a full build has still never been driven by hand on a phone**, and one open question is a naming decision that gets much more expensive after submission.

## Waiting on Me

Sorted by what unblocks the most. Items 1-3 are the ones that matter this week.

- [ ] **Drive the new build on your phone, top to bottom** - everything from the 29th is installed: the launch reveal, the Clear button, the full theater with faces lighting one at a time, the real-collage paywall, and auto-zoom finally working. Guided checklist: https://claude.ai/code/artifact/305b73b7-df5c-4e5b-8c15-4ed499e89625 (~45 min)
      - unblocks: B26, and any honest read on whether the theater still delights on the fourth collage
- [ ] **Decide the name** - see `Naming Study.md`. This is time-sensitive in a way the rest is not: renaming before first submission is cheap, after is expensive. The study found that "mosaic" already means *pixelate a face* in this category, which is the opposite of what the app does (~20 min to read, then a decision)
      - unblocks: the App Store listing, the icon, and every screenshot that carries the wordmark
- [ ] **Judge the layout sheets** - `~/Desktop/mosaic-layout-sheets/` (4-photo) and `mosaic-layout-sheets-3up/` (3-photo). Tell me which layouts look WRONG to your eye. That is the one input I cannot generate, and it is what turns Phase 4 from mechanism into quality (~20 min)
      - unblocks: B32 Phase 4, and the group-area weighting decision below
- [ ] **Decide the group-area trade** - the photo with the most people should get the most area, and it does not. Three search approaches were tried and all made it worse; the cause is that `framingCost` caps the legibility term while clip-avoidance is uncapped. Fixing it means reweighting, which risks clipped faces. **Your call on how much clipping risk is worth better composition** (~10 min, over the sheets)
      - unblocks: B32 Phase 4 completion
- [ ] **Test a real purchase from an Xcode run** - StoreKit only attaches to the scheme in Xcode, not a plain install, so this cannot be verified any other way (~10 min)
      - unblocks: B8 sign-off
- [ ] **One TestFlight tester besides you** (~15 min)
      - unblocks: submission
- [ ] **Sign off the accent color** - mockups in `_review/phase7-accent-*.png`; the brand blues are locked in code, so this is a confirmation rather than an open choice (~5 min)
- [ ] **Optional: rebuild the app icon in Icon Composer** - GUI-only, so it needs your hands. Dark and tinted variants already ship, so this is polish, not a blocker (~20 min). Recommend skipping for v1, and skipping entirely if the name changes

### Done, no longer yours

The in-app purchase is fully configured in App Store Connect (Apple ID 6795797662, $2.99, 175 regions, copy, review notes, screenshot). The listing is complete. The 40 photos are in and have been run through LayoutLab twice. The pacing decision is made and shipped: everyone gets the full theater.

## Next Up

1. The device pass on the build installed 2026-07-29 00:35. Everything since the 28th is in it and none of it has been touched by hand.
2. The naming decision, because it is the only open item that gets materially more expensive after submission.
3. Judge the layout sheets, then settle the group-area weighting trade. That closes Phase 4 and with it the last quality unknown.
4. Then gate the Settings dev rows behind `#if DEBUG`, archive, and TestFlight.

## Recently done (2026-07-29)

- **A launch reveal, a Clear button, and a paywall that shows YOUR collage.** The launch animation builds the mark out of construction lines and falling tiles, and rides the photo-library fetch so it costs nothing on a warm start. The picker gained "Clear (N)" opposite Recents, built opacity-only so it cannot reintroduce the tap-drift bug. The paywall preview now renders the user's own collage through the real export path instead of a grey placeholder.
- **The theater is no longer rationed.** Justin's call: every collage gets the full show, and faces now light one at a time across the whole set rather than per photo, with a hold after the last so "it found N faces" registers. Roughly +2.6s, deliberately.
- **`Naming Study.md`** - ten agents across four phases. The headline finding is in Biggest Risk.
- **Two "written but never wired" bugs fixed.** (1) Auto-zoom (B20)'s resolution guard was being judged against the 2000px `loadForEditing` proxy instead of the original asset, so `guardCap` could never exceed 1.0 and auto-zoom has never actually zoomed in production - fixed via a new optional `AutoFrameInput.sourcePixelSize`, populated in `PickerView.buildDocument` from `PHAsset.pixelWidth/pixelHeight`, with an orientation-mismatch correction inside `autoFrame` itself (covered by two new smoke-test anchors, hand-verified against the underlying math). (2) The group-photo legibility term (`smallestSurvivingFaceHeight` / `mustKeepFaceHeights`) existed end-to-end in the Engine and in `Tools/LayoutLab` but `PickerView.buildDocument` never computed or passed it, so it did nothing in the shipping app - now wired into the same Vision pass that already builds `mustKeepRegions`, and into `-faceAwareLayoutOff`'s degrade path.
- **`Tools/LayoutLab` updated to read real source-file pixel dimensions** (`readSourcePixelSize`, via `CGImageSourceCopyPropertiesAtIndex` - no full decode) so the resolution-guard fix is actually exercised, not just theoretically present.
- **Verified against all 61 of your real camera-roll photos** (`_inbox/40_photo_dump`, git-stash before/after so both binaries built from the literal pre/post-fix source): clipped-face totals unchanged - setSize 4: 15 sets, 22 clipped (default path), 2 clipped (face-aware), before AND after; setSize 3: 20 sets, 29 clipped (default path), 2 clipped (face-aware), before AND after. No regression. Crops noticeably tighter in ~30 of 35 sheets (pixel-diffed), including the set12 (setSize 3) case the fix was written for - eyeballed a half-dozen sheets across both sizes, nothing looked over-cropped. Smoke test 294 -> 297 (3 new anchors), decision time ~7.5ms avg / ~9ms worst case for a 4-photo challenger search (60ms budget).

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

The name. Everything else on this page is recoverable; a name is not, once the app ships under it. `Naming Study.md` found - and the finding was independently re-verified - that "mosaic" in the App Store's photo vocabulary already means *pixelate a face into blocks*. The category is full of blur and censorship tools using it, one called literally "Mosaic: Blur & Censor Photo", another using facial recognition to automatically obscure the faces it detects. This app detects faces in order to keep them whole. The name currently asserts the opposite of the differentiator, on the same shelf, and no modifier repairs that.

Second, and now better understood than feared: `framingCost` drives both the layout choice and auto-framing, and its balance is off - the legibility term is capped at 2.4 per photo while clip-avoidance and aspect-mismatch are uncapped, so searching harder chases the wrong terms and gives group photos LESS area. On real photos the function still performs well where it matters (22 clipped faces down to 2), so this is a composition-quality ceiling rather than a correctness bug. A separate units bug in the same function sits fixed but unmerged on `fix/framing-cost-aspect-units`, because it changes every collage with a face and breaks 4 assertions that encode the old numbers.

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

## Lessons

- **A real camera-roll photo dump cannot test an orientation-swap hazard by itself.** All 61 photos in `_inbox/40_photo_dump` read EXIF orientation `1` (already upright/baked-in) via `sips -g orientation` - so a bug-fix branch that corrects a mismatch between an orientation-corrected decode and a raw/rotated size (e.g. `PHAsset.pixelWidth/height` vs. a `kCGImageSourceCreateThumbnailWithTransform`-corrected proxy) can look fully verified against "real photos" while that code path never actually executes. Caught by writing a tiny standalone Swift driver (`swiftc` against the Engine sources + a throwaway `main.swift`) with synthetic mismatched-orientation inputs and hand/script-verified expected numbers, then hardening it into a permanent smoke-test anchor. Worth checking `sips -g orientation` (or equivalent) on any "real data" test corpus before trusting it to cover an orientation-dependent code path. (promoted to Build Guide v2.9, 2026-07-29)
- **`git stash push -u -m "<label>" -- <files>` / `git stash pop` is a clean way to get an honest "before" build for A/B verification** when a fix's actual effect must be measured against a real-data harness (not just unit-tested): stash the fix, build+run the harness for "before," pop the stash, build+run again for "after," same binary-build recipe both times. Cheaper and less error-prone than maintaining two branches or manually reverting/re-applying edits. (promoted to Build Guide v2.9, 2026-07-29)
- **A separate side-by-side build beats a feature flag when the thing being judged is taste.** Give the experimental branch its own `PRODUCT_BUNDLE_IDENTIFIER` and `CFBundleDisplayName` (here `com.levelup.mosaic.next` / "Mosaic Next") and both apps install on the same phone at once, so the owner can flip between them in seconds instead of reinstalling to compare. It also gets a genuinely clean first-run every time, since the second bundle ID has its own permissions, UserDefaults and saved documents. Two rules make it safe: the shippable branch merges INTO the testbed freely so the testbed never drifts behind, and the testbed only ever cherry-picks back, because it carries commits that must never reach the App Store (the bundle-ID change itself, and any dev-only tooling). The trap worth naming: a bug found while testing the testbed, in code both branches share, must be fixed on the SHIPPABLE branch and merged down - patching it on the testbed alone leaves the shipping build quietly carrying a bug that was already fixed, and the owner is always looking at the testbed when he finds things.
- **Ask the app for the feedback data instead of asking the user to assemble it.** Tuning an algorithm against real use stalled because the owner had to screenshot before and after, then hunt the source photos down in a different app and transfer them separately. The app already held all of it - asset identifiers, detection output, the layout it chose, the layout the user changed it to - so a single in-app "capture" control now writes one shareable bundle with the sources, both documents, both renders and a manifest. The design rule that makes it trustworthy: snapshot the as-built state at the ONE moment it exists (before any edit can touch it), and when that snapshot is genuinely unavailable, record `beforeAvailable: false` rather than substituting the current state. A fabricated "before" would read as the algorithm agreeing with the user when it did not, which silently poisons the very dataset the feature exists to build.
