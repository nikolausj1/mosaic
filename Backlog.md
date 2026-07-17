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

### B8 - IAP + watermark (v2, the plan of record)
StoreKit 2 non-consumable, one-time unlock. Watermark: ~4% of the long edge, bottom-right, inside the outer margin if one exists, white with a subtle dark stroke. **The v1 export pipeline already ends in a single compositing hook** - this is a small, contained addition, not a refactor.
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
**Blocking for App Store, non-blocking for the build.** v1 builds as "Collage" / `com.levelup.collage` / repo `photo-collage`.
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

### B23 - First pan attempt sometimes not recognized (OPEN BUG, Phase 2)
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
