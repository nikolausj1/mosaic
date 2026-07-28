---
title: "Photo Collage - Backlog"
created: 2026-07-16
modified: 2026-07-16
version: 1.0
author: Justin Nikolaus + Claude Opus 4.8
tags:
---

# Backlog

Companion to `PRD.md`. Everything deliberately deferred, every decision made with a known tradeoff, and **the specific signal that should make us revisit it**. A decision with no revisit signal is just a decision - it belongs in the PRD, not here.

Claude Code: do not act on anything in this file. If you hit one of these while building, flag it.

---

## Reversible decisions (shipped one way, watching for a reason to flip)

### B1 - Bare-seam drag without selection
**Shipped:** you can drag a seam directly, no selection required. Live zone is the seam +/-11pt (or half the border thickness, whichever is larger); a selected photo's explicit handles get the full 44pt and win ties; corners always require selection.
**Why it's risky:** it reintroduces the pan-vs-resize ambiguity we'd otherwise have eliminated. Instagram Layout required tap-then-pull to resize, for nine years, and had no complaint of this class. Justin chose the fluid version deliberately, to feel it before doing the "safe" thing.
**Revisit signal:** accidental resizes while panning near a seam happen more than rarely in real use.
**Fallback (fully specified, ready to implement):** require selection for seam drags. Handles become the only resize affordance. No other part of the design changes.

### B2 - Canvas-edge handles on a selected photo
**Superseded, not rejected.** Justin originally overruled the recommendation and asked for handles on all four edges of a selected photo, with canvas-boundary ones changing the composite's ratio. The Layout research then surfaced a third option that delivers the same goal better: **permanent composition brackets**, always visible, so the ratio is always one drag away without ever putting a ratio control on a photo's edge. Adopted in the PRD.
**Revisit signal:** reaching for a photo's outer edge to change the ratio, and finding nothing there.

### B3 - Corners where a divider meets a canvas edge
**Shipped:** no handle drawn. One axis wants to move a divider, the other wants to change the ratio; there is no non-arbitrary answer, so v1 declines to invent one.
**Revisit signal:** repeatedly grabbing that corner expecting something.

### B4 - Reset crop
**Rejected**, and the reasoning is worth preserving because it was a real argument. It looked necessary, but it can't be - minimum zoom is aspect-fill, so pinching all the way out hits a floor and self-corrects. The only residual is pan slack along a photo's overflow axis, which is visible on screen and one drag away. Undo covers the rest.
**Revisit signal:** getting back to "centered" turns out to be fiddly in practice, particularly for wide photos in tall cells.

### B5 - Linked 2x2 grid (a draggable center cross)
**Rejected.** Would need a second node type in the data model whose only effect is to *remove* expressiveness. Sibling-alignment snapping gets a clean 2x2 effortlessly while leaving staggered ("Mondrian") 2x2s reachable.
**Revisit signal:** staggered 2x2s are never used, and dragging both dividers separately to keep a grid tidy is annoying.

### B6 - Thirds snapping on dividers
**Rejected.** Center is the only proportional detent. Multiple detents in a short drag make a divider feel notchy and magnetic rather than analog, and fighting a snap you didn't want is worse than missing one you did.
**Revisit signal:** hitting 1/3 by eye is a recurring annoyance.

### B7 - Layout suggestion strip in the picker
**Rejected in favor of:** an orientation-aware default on arrival + the Layout tray in the editor. Instagram Layout put a live-updating strip in the picker and people liked it, but ours gives better feedback - you judge a layout against your actual photos at full canvas size, not a 60pt thumbnail.
**Revisit signal:** landing on a default and then immediately opening the Layout tray, every single time.

---

## Deferred features (wanted, not now)

### B8 - IAP + watermark (PULLED INTO v1 - decided 2026-07-26 by Justin, BUILT same day)
Launch model is freemium: free download, every feature included, exports watermarked until a one-time unlock. Shipped implementation: StoreKit 2 non-consumable `com.levelup.mosaic.removewatermark` (placeholder $2.99, final price set in App Store Connect), `StoreService` + `PaywallSheet` + save-sheet notice + B28's gear-in-picker Settings sheet, watermark drawn by `WatermarkDecorator` through CollageRenderer's ExportDecorator hook exactly per the spec below. Sim-verified end to end 2026-07-26 (watermark renders correctly on a real export; purchase flow still needs an Xcode run with Mosaic.storekit or a sandbox account).
Original spec: StoreKit 2 non-consumable, one-time unlock. Watermark: ~4% of the long edge, bottom-right, inside the outer margin if one exists, white with a subtle dark stroke. **The v1 export pipeline already ends in a single compositing hook** - this is a small, contained addition, not a refactor.
**Trigger:** Justin has used the app for several weeks and still wants it. Also requires: the rename (B16), an App Store Connect record, screenshots, and a privacy nutrition label for the photo-library permission.
**Strategic note:** every ranked competitor is a subscription. One-time purchase is the wedge, not just a price.

### B9 - 5-9 photos
The split tree is entirely count-agnostic. This is a config change plus new template art - the cost is that topologies explode combinatorially and the layout row needs its own organization.
**Trigger:** Justin wants more than 4 twice. (Instagram Layout supported 9 and people used it.)

### B10 - iPad
Layout never shipped an iPad app in nine years; it's an open gap in the category. Real work: the editor's proportions and the tray layouts don't transpose for free.
**Trigger:** App Store traction, or Justin wants it on the iPad Pro.

### B11 - Eyedropper border color
Tap an eyedropper, tap anywhere in the collage, that exact color becomes the border. Makes the frame feel like it belongs to the photos.
**Trigger:** the swatch row plus derived suggestions don't cover a color Justin wants.

### B12 - Auto color as a real feature
v1 ships derived colors as *suggestions prepended to the swatch row*. The bigger version is a dedicated mode with several generated palettes to flip through.
**Trigger:** the suggestions get used often. If they're ignored, this is dead and the suggestions should be cut too.

### B13 - Project library
Multiple saved documents with thumbnails. v1 has one autosaved document plus one level of "edit last collage."
**Trigger:** wanting two collages in flight at once.

### B14 - Picker search
v1 has an album/Favorites filter and a fast-scroll scrubber.
**Trigger:** the album filter isn't enough at 40,000 photos. (Layout's picker at scale was a recurring complaint.)

### B15 - Free rotation
Arbitrary-angle rotation within a cell, snapping at 0. Rejected for v1: Photos.app straightens horizons before import, and the gesture rides along with pinch and needs its own zoom-clamping math so corners never expose a gap.
**Trigger:** crooked horizons that Photos didn't already fix.

### B16 - The rename
**DECIDED 2026-07-26 (Justin): keep Mosaic as the brand; submit under a compound App Store title, working wording "Mosaic: Photo Collage & Layout" (final wording locked with the listing copy).** Mitigates the discovered exact-category App Store collision ("Mosaic - Video & Photo Collage", id 633846868) and photomosaic search dilution. Residual trademark risk (13 leading matches) acknowledged and accepted; revisit only if App Review or a rights holder objects.
**Original framing, kept for the record:** Blocking for App Store, non-blocking for the build. v1 builds as "Collage" / `com.levelup.collage` / repo `photo-collage`.
Shortlist so far, all availability-verified against Apple's live index:
- **Plain-language pass:** Spreads (exact=0, leading=0 - the cleanest plain-English result found; `spreads.photos` open), Mosaic (best comprehension, but 13 leading matches and *a mosaic is thousands of tiny tiles, not 2-4 big photos*), Gridly (coined, owns its namespace, but "grid" names the rigidity this app removes)
- **Craft-vocabulary pass (rejected as too obscure, kept for the record):** Muntin (the strip dividing a window into panes - the app named after its own core interaction; verified clear, `muntin.photo` open), Reglet, Casement, Transom, Kerf
- **Verified taken:** Joiner (painful - Hockney's "joiners" are literally this artform), Quire, Quarto, Passepartout, Stack, Gather, Cluster, Grid, Tile (trademark), Facet (trademark)
- **Do not use:** Mullion (homophone of "million"), Quilty (homophone of "guilty"), Quilt (the sewing hobby owns it; two Quilt collage apps already ship)

---

## Open research

### B17 - Verify Layout's remaining unknowns
Layout's interaction model was reconstructed twice, independently: once from pixel-measuring Meta's own App Store screenshots plus archived Help Center articles, and once from frame-level analysis of tutorial video. The two agree everywhere they overlap. Between them they settled the toolbar question (**fixed, 4 buttons by 2017, contextually greyed - not contextual as first inferred**) and the 2x2 question (**independent dividers, columns-first nesting**).

Three things remain genuinely unverifiable from any surviving source:
- **Snapping, haptics, and minimum cell size.** Nothing observable on video, nothing documented. **Our values for these have no precedent - they are inventions. Do not let anyone fill this gap by assumption or claim Layout as authority for them.**
- The final export resolution (750x750 at launch; **the widely-circulated "1080x1080" is SEO synthesis, not a measurement - do not trust it**)
- The deselect mechanism (a deselected state exists; the trigger was never observed. Layout had no Done control - its header was only `back | EDIT | SAVE`)

These could be settled by dumping strings/resources from an Android APK, **which needs Justin's explicit say-so**.
**Value:** low. Each is a decision we've already made deliberately; Layout's answer would be a data point, not a verdict. Curiosity only.

### B20 - Auto-zoom (the riskiest thing shipped in v1)
**Shipped:** saliency-driven zoom on arrival, hard-capped at 2.0x, skipped when the salient subject already fills >60% of the frame, never past usable source resolution. Faces drive the center only.
**Why it's risky:** centering has a right answer; zooming is a taste call the app makes on the user's behalf. The recommendation was centering-only. Justin took the zoom *and* paired it with the per-photo Auto toggle - which is what makes it defensible: auto-zoom justifies the toggle's existence, and the toggle caps auto-zoom's downside to one tap.
**Kill trigger (explicit):** if Auto gets switched off on **more than roughly 1 photo in 4** in real use, auto-zoom is wrong. Cut back to ROI centering only, keep zoom at aspect-fill. The toggle then becomes redundant and should be cut too - the two stand or fall together.
**Opposite trigger:** if Auto is essentially never switched off, consider whether the toggle is dead weight and the whole thing should go invisible (the original recommendation).

### B21 - Content-fit assignment vs. pick order
**Shipped:** photos are assigned to cells by aspect match on arrival, so the picker uses **unordered checkmarks** rather than numbered badges. The two are a package - numbering would promise a control the picker doesn't have.
**Revisit signal:** wanting to control which photo lands where *from the picker*, rather than swapping in the editor. Fallback: numbered badges, pick order = placement, no content-fit.
**Note:** this needs no Vision - it's `|log(photoAspect) - log(cellAspect)|` brute-forced over at most 24 permutations.

### B22 - Cell-shape-aware ROI
**Not shipped.** ROI is computed **once** per photo at pick time and never re-run. The theoretically better version recomputes the ideal center per cell shape - e.g. two faces that can't both fit in a narrow column could pick the better one *for that column*.
**Why not:** re-running on topology or ratio changes makes photos move by themselves, and re-running during a divider drag makes them swim under your finger. The one-shot version slots into the existing `center` field with zero new rules.
**Revisit signal:** photos that hold multiple subjects are consistently badly framed after a topology change.

### B27 - Onboarding screens (CLOSED 2026-07-26: Justin chose option (c), welcome card + contextual coach marks; PRD section 4 principle formally revised same day; built 2026-07-26)
**Justin asked (2026-07-17)** for splash + onboarding screens for first launch. The launch screen (dark, native) shipped. Onboarding screens directly contradict the PRD's locked no-tutorials principle ("the handle grammar has to teach itself or the app has failed") and its designed alternative (first-ever-launch auto-selection as the entire onboarding). Options on the table: (a) keep the PRD's position - no onboarding; (b) a single dismissible one-time hint line, not a carousel; (c) full onboarding screens, formally revising the PRD principle. Claude recommends (a), accepts (b); (c) needs the PRD principle rewritten, not just screens added.
**Revisit signal:** anyone Justin hands the app to fails to discover pan/resize/swap within the first minute.

### B28 - Settings area (decided: none in v1; ingress reserved)
v1 has nothing to configure by design (dark always, no resolution picker, zero-config auto-framing). Candidates that would eventually justify one: watermark toggle (v2 StoreKit), restore purchases (v2), haptics toggle, about/licenses. When one materializes, the ingress is a gear icon in the PICKER header (Screen A) - the editor's chrome budget is spent.
**Revisit signal:** the first real setting arrives (likely v2's purchase restore).

### B31 - "Magic layout" reveal: show the work so the app gets credit for it
**Idea (Justin, 2026-07-28):** photos land in a deliberately plain template, then a sweep of "magic energy" crosses the composition, real face bounding boxes light up, and the layout morphs - ghost-demo style - into the chosen one. All on device. "This animation and these steps are Theater, but it is to get the wow from our users."
**Why it is right:** the app already does the impressive thing (on-device Vision framing) and the user perceives nothing, because it is instant and invisible. Invisible work earns no credit. This is also the single best 15 seconds of an App Store preview video and the clearest demonstration of the "innovation" criterion in the featuring pitch.
**The line that keeps it honest:** the plain starting template must be the template the app would genuinely have used without face-awareness, and the boxes must be the real detections. Then it is a visualization of real work, not a fake. Faked boxes or a staged "before" would be indefensible the moment a reviewer looks closely - and it would undercut the very claim it exists to make. This is an argument for building B30 properly rather than around it.
**Design constraints this has to respect:**
- **Never a gate.** The final layout must be usable the instant it exists; the reveal is an overlay over an already-finished result, and ANY touch jumps straight to the end state.
- **Frequency is the whole design.** Delightful three times, infuriating thirty. Full show on the first-ever collage, a much shorter version afterwards, and a Settings toggle. A 2s ceremony on every arrival makes a fast app feel slow.
- **Degrade quietly.** If detection is weak or finds fewer faces than expected, skip the box-reveal and just morph - never advertise a miss.
- **Reduce Motion** cuts straight to the final layout, as the ghost demo already does.
**On the proposed toggle:** a button that reverts to the boring template is odd - nobody wants "make it worse." Better as a **re-run / shuffle**: tap it and the magic replays, landing on the next-best scoring layout. Same affordance, same theater on demand, but it moves forward instead of backward. Manual escape already exists in the Layout tab, and Undo covers regret.
**Sequencing:** the reveal is worth little without B30 underneath, since today there is no layout DECISION to dramatize - only per-cell framing. Cheap phase 0: dramatize the framing that already happens (boxes appear, each cell pans/zooms to its chosen crop) with no B30 at all, to test whether the theater lands before investing in the real thing.
**Related:** B30 (the decision this dramatizes), B20 (auto-zoom, already the riskiest shipped feature - this puts a spotlight on it).

### B30 - Face-aware auto-layout (choose the TEMPLATE from the faces, not just the crop)
**Idea (Justin, 2026-07-28):** "auto create a layout by finding the bounding faces of a photo and making sure they are all visible and appropriate for that layout and zoom level and crop."
**What exists already:** Vision runs per photo at arrival and yields an ROI that drives auto-framing (pan/zoom) INSIDE an already-chosen cell (B20). Template choice is orientation-based; photo-to-cell assignment is brute-forced over <=24 permutations by ASPECT match only (`contentFitAssignment`, cost = |log(photoAspect) - log(cellAspect)|). Nothing today scores whether a face survives the crop.
**What it would take, in order of value per effort:**
1. **A must-keep region per photo.** Union of all detected face rects plus margin (not the single ROI we keep now), with face count and spread recorded. Falls back to the existing saliency rect when no face is found - landscapes must keep working.
2. **A framing cost function** `framingCost(photo, cellAspect)`: compute the minimum zoom whose crop still contains the must-keep region, then penalise any face clipped, faces below a minimum relative size, and excessive crop loss; reward must-keep aspect matching the cell. This is the whole idea in one function, and it is pure arithmetic on rects - no second Vision pass.
3. **Search templates, not just assignments.** Enumerate the candidate templates for N photos, solve assignment against `framingCost` for each, take the best (template, assignment) pair. Roughly 10 templates x 24 permutations = ~240 rect evaluations for 4 photos; negligible next to the Vision pass already running.
4. **Then search the split fractions** (the real unlock): let each divider move within ~0.3-0.7 in coarse steps so a cell can grow to fit a group shot. A 5-step grid over 2-3 dividers keeps it in the hundreds of evaluations.
**Why it is tractable here:** all of this belongs in `Sources/Engine`, which is platform-pure and already covered by the 174-assertion standalone smoke test - it is unusually testable for a visual feature.
**Risks:** Vision misses profiles/sunglasses/small faces, so low-confidence results must degrade to today's aspect-only path; a strict optimum can look mechanical where the current default looks natural; and it changes ARRIVAL, the app's first impression, on top of B20 which is already the riskiest shipped feature. Budget most of the effort for tuning against a real camera roll, not for the code.
**Rough shape:** step 2+3 together are S-M and capture most of the win; step 4 is a further M; tuning is the long pole and is judgment, not engineering.
**Related:** B20 (auto-zoom), B21 (content-fit vs pick order), B22 (cell-shape-aware ROI - this supersedes it).

### B29 - Do users need "Continue current collage" / "Edit last collage"? (removed 2026-07-27, watching)
Both picker entry rows were built and then **removed at Justin's direction** ("Its easy to recreate, not a big deal. If I hear different from our users I will add it back."). The PERSISTENCE behind them is untouched and still runs: current.json is autosaved, a cold launch with current.json still restores straight into the editor, and the save sheet's Done still archives current -> last. Only the two in-picker entry points are gone, so a warm relaunch is the only way back into an in-progress collage now.
**Revisit signal:** a tester (or Justin) backs out of the editor, can't get the collage back, and is annoyed - or App Store reviews ask for it. Restoring is a small job: re-add the two banner rows plus the `hasCurrentCollage`/`onContinueCurrent`/`hasLastCollage`/`onEditLastCollage` plumbing (see git history around 2026-07-27), since DocumentStore still exposes everything they need.

### B24 - "Original" ratio chip semantics (Phase 4 judgment call)
**Shipped:** Original := the FIRST photo's native pixel aspect (document leaf order). The PRD lists the chip without defining it for a multi-photo canvas.
**Revisit signal:** Justin taps Original expecting something else (e.g. the arrival ratio, or the currently selected photo's aspect).

### B25 - Deferred Phase 4/6 polish (all noted in code)
- Picker fast-scroll scrubber: system scroll indicators for now; custom scrubber was explicitly allowed to slip to polish.
- iCloud download progress ring in editor cells: shimmer placeholder covers the visual gap; per-photo progress plumbing deferred.
- Derived border swatches compute at editor-open and after restore, not on Replace/Remove.
**Revisit signal:** any of these feels missing in daily use.

### B26 - Device-verification checklist (autonomous run, 2026-07-17)
Everything below is BUILT and sim-verified where the sim allows; these specific flows need the phone because sim permission dialogs / real assets can't be automated:
1. Happy-path restore: pick real photos, force-quit mid-edit, relaunch -> exact restore with photos (sim only proved the document/JSON side + unavailable path).
2. Real save-to-Photos: asset lands in the library, filed under the EARLIEST source capture date (S7) - check in Photos' library (date-sorted), not just Recents.
3. Share sheet from the save sheet.
4. Edit last collage round-trip after a real save.
5. Delete a source photo from Photos, relaunch -> unavailable placeholder + blocked Save + Replace clears it.
6. Gesture feel on rotated/flipped photos (pan/pinch should feel identical; the coordinate-space semantics changed in Phase 4).
7. Auto-framing quality on fresh picks (B20 evidence collection continues).
8. Export wall-clock < 3s and no dropped frames during gestures (S2/S4) - Instruments if it feels off.

### B23 - RESOLVED 2026-07-17: first pan eaten by a stuck post-pinch latch
**Root cause (proven by the on-device HUD trace Justin captured):** when both pinch fingers lift simultaneously, SwiftUI skips the accompanying DragGesture's onEnded, so `dragConsumedByPinch` stayed armed and silently ate the ENTIRE next one-finger pan ("drag suppressed (post-pinch)" x N ticks). One dead pan after most pinches; second attempt always worked - exactly the two-pass symptom reported at the S1 gate.
**Fix:** the latch now remembers WHICH touch sequence the pinch consumed (its startLocation); a drag arriving from any other touch clears the latch and proceeds. Same commit also hard-locks the canvas during export at the GestureController entry points - the visual blocker overlay only claimed taps, so pans during the multi-second save could edit the document after the export snapshot was taken (Justin's canvas-vs-minted-image mismatch).
**Residual watch:** if a first-pan miss EVER recurs with the HUD showing `down->photo` (not "suppressed"), that's a different bug - reopen with the HUD fingerprint table from the original entry (git history has it).
**Cleanup still owed:** debug HUD removal once Justin confirms feel on device.

### B23-archive - original hypothesis table (superseded by the resolution above)
**Symptom (Justin, on device, 2026-07-16):** the first finger-drag to pan a photo does nothing; the second attempt pans. "Feels ok for now" - deferred, not resolved.
**Instrumentation is already in place:** the prototype renders a gesture-event HUD at the bottom of the screen (EditorState.debugEvents / debugLog). When it recurs, the last lines identify the cause directly:
- `down->photo … hold->swap … up: swap no-target` -> the 0.35s long-press is stealing deliberate pans (natural grab-settle-move rhythm). Fix space: longer hold, bigger slop, or require selection for swap.
- `down->divider …` / `down->corner …` -> the seam (±11pt) or capsule (44pt) hit zones are too greedy near edges - this would also be evidence against B1's bare-seam decision.
- `down->photo` then `up: tracking died …` -> drag ticks never crossed the 8pt slop; delivery/threshold problem.
- `drag suppressed (post-pinch)` -> the dragConsumedByPinch latch over-suppresses.
- Nothing logged -> hit-testing hole above the gesture layer.
**Resolution also includes:** removing the debug HUD and debugLog calls at Phase 2 sign-off.

### B19 - First-launch auto-selection
**Shipped:** cell one arrives selected on the first-ever entry to the editor, then never again. One persisted boolean.
**Why:** onboarding is a hard non-goal (Layout's unskippable intro was a nine-year complaint), so the handle grammar must teach itself. A silent self-explaining first state is the only teacher we've allowed. Layout auto-selected on *every* entry and its grammar taught itself for nine years; we take the lesson and skip the permanent cost.
**Revisit signal:** it reads as a glitch rather than a hint, or the grammar turns out to need no teaching at all (in which case cut it). Conversely, if new users are lost, the fallback is Layout's version - select on every entry.

### B18 - EXIF beyond date and location
v1 preserves the earliest source capture date and the location if the sources agree. Camera, lens, and exposure data are dropped - a composite of several photos has no honest answer for them.
**Trigger:** someone actually wants it. Probably nobody does.

---

## Dead (recorded so they don't get relitigated)

| Idea | Why it's dead |
|---|---|
| Filters / brightness / contrast / B&W | Photos.app is better and one tap away. Anything you'd do here you'd do there first |
| Text / stickers / emoji / drawing | The exact feature set that makes every competitor unusable to our customer. Reviewers named the *absence* of these as why they deleted rivals |
| Template-only layouts | Layout's #1 complaint for nine years |
| Freeform floating-rect canvas | No shared edges, so no dividers - which is the entire product |
| Onboarding / intro screens | Layout's unskippable ~60s intro was a nine-year complaint. The handle grammar teaches the app or the app has failed |
| Landscape orientation | A 16:9 canvas renders short and wide in portrait; there's no reason to rotate the device |
| Backend / accounts / analytics / runtime AI | Per the Build Guide. Nothing leaves the device |
| HEIC export | Breaks the moment a collage leaves the Apple ecosystem |
| Appended watermark footer strip | Changes the exported aspect ratio, breaking the one thing the app promises |
| Resolution picker on export | You'd choose Max every time. The automatic rule is strictly better |
