---
title: "STATUS - Photo Collage"
created: 2026-07-24
modified: 2026-08-06
version: 4.2
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Photo Collage - Status

## Project

Mosaic, an iOS collage app (the spiritual successor to Instagram's discontinued Layout). Pick 2-4 photos, arrange them in a draggable split-tree layout with a signature diagonal corner-resize handle Layout never had, auto-frame faces/subjects on-device via Vision, adjust ratio/border, and export a full-resolution JPEG to Photos with correct EXIF (earliest source date/location), something Layout famously never did.

## Stage

Active Development - **v1.0 (1) submitted to App Review 2026-08-06** (Waiting for Review), the Remove Watermark IAP in the same submission. Subtitle and marketing headline: "Auto layout that finds faces."

**Two builds now run side by side on Justin's phone.** `main` is the shippable 1.0 candidate. A second branch installs as "Mosaic Next" under its own bundle ID, carrying everything in `main` plus whatever is being judged by eye, so a taste call never has to be made against the build that ships. The full rule, including why the merge direction is one-way, is in `CLAUDE.md`.

## Health

🟢 Submitted. Build 1.0 (1) uploaded, attached, and submitted for review together with the IAP on 2026-08-06. All five last-mile ASC gaps (privacy label published as Data Not Collected, privacy policy URL, age rating 4+, content rights, Photo & Video category) were filled from the listing doc's drafted answers the same morning. Waiting on Apple now.

## Waiting on Me

The submission is in. What remains while Apple reviews:

- [ ] **Decide: swap screenshot panel 1 now or after approval** - the re-rendered panel (new "Auto layout that finds faces." headline plus light-blue-o lockup) is committed at `_store/screenshots-v2/01.png`, but ASC still holds the old render and screenshots are locked while Waiting for Review. Swapping now means remove-from-review, replace, resubmit (~1 day queue cost); after approval, screenshot swaps need no review (~2 min either way)
- [ ] **TestFlight restore test, still worth doing during review** - buy, restore, watermark gone, clean copy at the top of the library. If anything fails, pull the submission before Apple finds it (~10 min)
- [ ] **Sign off the accent color** - mockups in `_review/phase7-accent-*.png` (~5 min)
- [ ] **Optional: rebuild the app icon in Icon Composer** - polish, not a blocker (~20 min)

### Done, no longer yours

The weight sweep is judged: all 35 sets, with reasons (`~/Desktop/mosaic-sweep/FEEDBACK.txt`). The direction is decided - hero plus legibility floor. A real purchase went through in local StoreKit from an Xcode run; the "restore didn't work" scare was the environment (nothing to restore after a delete in local testing), not the code. The Settings dev rows are gated behind #if DEBUG (verified against the Release binary). The in-app purchase is fully configured in App Store Connect. The listing is complete.

## Next Up

1. Build hero plus legibility floor on Next - approved direction from the sweep feedback; its dependency (the relative face-size gate) is committed. Includes Justin's open clipping trade (face-aware clips rose 2 to 6 / 2 to 4 after the detection fix found more faces to protect) and the how-eagerly-may-the-canvas-leave-square question, both judged by eye on Next.
2. TestFlight restore test during the review window (see Waiting on Me).
3. Respond to the review outcome; if approved, decide manual vs automatic release.

## Recently done (2026-08-06, overnight)

- **Ship-prep while Justin slept.** Pre-submission audit: all eight checks PASS, zero rejection risks (Info.plist, ITSAppUsesNonExemptEncryption false, PrivacyInfo.xcprivacy correct and bundled, zero debug strings in the Release binary, Next-only capture tool confirmed absent, dark/tinted icons compiled, no personal photos in the bundle). Listing truth-audited: reviewer note added explaining the auto-resave (two Photos writes for one Save is by design, not a bug), save-sheet label corrected, screenshots pointer moved to the v2 set, and panel 5's stale caption re-rendered in place by regenerating the deterministic background. Archive + export: distribution-signed Mosaic.ipa v1.0(1) at build/export/, codesign verified; upload stopped only at the missing API-key Issuer ID - exact remaining steps in build/UPLOAD-NEXT-STEPS.txt.
- **Sticky-ratio bug found and fixed after Justin's "main picked non-square" report.** Corner-bracket drags were committing a permanent ratio preference (the ghost demo teaches that very gesture), bypassing the square default. Drags no longer commit - only tray-chip taps do - and a one-time migration clears the residue.

## Recently done (2026-08-05)

- **Second on-device round, same day.** Splash: a beat after the wordmark, the list lands as one block (stagger removed), third row trimmed, block width capped so it centers as a group. The face-reveal pacing fix (the detection fix's 8+ faces had compressed the per-face gap into a flicker) was judged on Next and graduated to main the same day: span cap 1.15 to 2.4, assemble morph 0.50 to 0.72. And square is the auto-layout default on main again - the ratio challenge lives on only in Next (a third standing never-ship commit, documented in CLAUDE.md) until the hero retune settles how eagerly the canvas may leave square. Next was rebuilt per the CLAUDE.md recipe; smoke test 299/299.
- **All five of Justin's on-device feedback items, shipped and installed.** Wordmark-only splash (the lockup under the animated icon repeated the icon); welcome rows down to three with the on-device-intelligence line promoted; Done clears the picker selection while back-to-tweak still retains it; the ghost demo got a real focus scrim (black 0.62, cutout tracking the live canvas, caption moved under the canvas at 15pt bold); and a purchase from the save sheet now automatically resaves a clean copy so nobody is stranded with only the watermarked JPEG.
- **The lighter blue o, everywhere.** Both brand assets carried their blue as saturated-ink-at-partial-alpha (a white-knockout artifact) that read dark over the near-black splash; the light blue from the brand art (84,184,252) is now baked in as opaque ink in both the Lockup and the new Wordmark asset.
- **The group-photo detection fix is committed** - a face now survives thresholding if it is within 60% of the largest confidence-passing face in the same photo (minimum two candidates, so lone background bystanders stay rejected). This is the fix that took the eight-person group from 0 faces to 8 and earned it the hero slot without the hero rule existing yet. 297/297 smoke assertions.
- **Weight sweep judged, direction decided.** Justin scored all 35 sheets with reasons; the through-line is hero-for-the-group-photo plus a legibility floor, approved as the next Engine build.

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

Done since
- [x] Settings dev rows: "Play intro again" ships (not destructive); "Clear collages" gated behind #if DEBUG (verified absent from the Release binary via strings)
- [x] Purchase flow verified end to end in local StoreKit (Xcode run, real prompt, unlock persisted)

Still to do
- [ ] Everything in "Waiting on Me" above
- [ ] Recapture the IAP review screenshot from an Xcode run so the button shows the real price
- [ ] Archive + upload a build, then TestFlight (also the only faithful restore-purchases test)
- [ ] Featuring nomination (~3 months lead time recommended; pitch drafted)

Open risk: the "Mosaic" trademark question stays accepted-but-unresolved (13 leading matches, plus an existing App Store app in the category). The compound title helps discovery, not legal exposure.

Structural risk: the project lives inside Dropbox, which caused a multi-hour outage on 2026-07-28 (file provider failing to serve repo files under disk pressure). Moving it to `~/Developer` is the real fix; Xcode projects in cloud-synced folders are a known-bad combination.

## Lessons

- **A real camera-roll photo dump cannot test an orientation-swap hazard by itself.** All 61 photos in `_inbox/40_photo_dump` read EXIF orientation `1` (already upright/baked-in) via `sips -g orientation` - so a bug-fix branch that corrects a mismatch between an orientation-corrected decode and a raw/rotated size (e.g. `PHAsset.pixelWidth/height` vs. a `kCGImageSourceCreateThumbnailWithTransform`-corrected proxy) can look fully verified against "real photos" while that code path never actually executes. Caught by writing a tiny standalone Swift driver (`swiftc` against the Engine sources + a throwaway `main.swift`) with synthetic mismatched-orientation inputs and hand/script-verified expected numbers, then hardening it into a permanent smoke-test anchor. Worth checking `sips -g orientation` (or equivalent) on any "real data" test corpus before trusting it to cover an orientation-dependent code path. (promoted to Build Guide v2.9, 2026-07-29)
- **`git stash push -u -m "<label>" -- <files>` / `git stash pop` is a clean way to get an honest "before" build for A/B verification** when a fix's actual effect must be measured against a real-data harness (not just unit-tested): stash the fix, build+run the harness for "before," pop the stash, build+run again for "after," same binary-build recipe both times. Cheaper and less error-prone than maintaining two branches or manually reverting/re-applying edits. (promoted to Build Guide v2.9, 2026-07-29)
- **A separate side-by-side build beats a feature flag when the thing being judged is taste.** Give the experimental branch its own `PRODUCT_BUNDLE_IDENTIFIER` and `CFBundleDisplayName` (here `com.levelup.mosaic.next` / "Mosaic Next") and both apps install on the same phone at once, so the owner can flip between them in seconds instead of reinstalling to compare. It also gets a genuinely clean first-run every time, since the second bundle ID has its own permissions, UserDefaults and saved documents. Two rules make it safe: the shippable branch merges INTO the testbed freely so the testbed never drifts behind, and the testbed only ever cherry-picks back, because it carries commits that must never reach the App Store (the bundle-ID change itself, and any dev-only tooling). The trap worth naming: a bug found while testing the testbed, in code both branches share, must be fixed on the SHIPPABLE branch and merged down - patching it on the testbed alone leaves the shipping build quietly carrying a bug that was already fixed, and the owner is always looking at the testbed when he finds things.
- **Ask the app for the feedback data instead of asking the user to assemble it.** Tuning an algorithm against real use stalled because the owner had to screenshot before and after, then hunt the source photos down in a different app and transfer them separately. The app already held all of it - asset identifiers, detection output, the layout it chose, the layout the user changed it to - so a single in-app "capture" control now writes one shareable bundle with the sources, both documents, both renders and a manifest. The design rule that makes it trustworthy: snapshot the as-built state at the ONE moment it exists (before any edit can touch it), and when that snapshot is genuinely unavailable, record `beforeAvailable: false` rather than substituting the current state. A fabricated "before" would read as the algorithm agreeing with the user when it did not, which silently poisons the very dataset the feature exists to build.
