---
title: "Photo Collage - Product Requirements Document"
created: 2026-07-16
modified: 2026-07-16
version: 1.0
author: Justin Nikolaus + Claude Opus 4.8
tags:
---

# Mosaic - Product Requirements Document

| | |
|---|---|
| **Product** | Mosaic - a collage tool for 2-4 photos where every proportion is set by dragging the thing itself |
| **Platform** | iOS - iPhone only, portrait only, iOS 18+ |
| **Status** | v1.0 PRD - agreed 2026-07-16 |
| **Companion docs** | `Project Build Guide.md` (accounts, stack, signing, deployment - follow it, do not restate it)<br>`Backlog.md` (deferred ideas, reversible decisions, and the signal that should make us revisit each) |

---

## 1. Overview and Vision

**The problem.** In May 2024, Meta killed Instagram Layout. On the day it was removed it was **#53 in Photo & Video with 103.8K ratings at 4.4 stars and 100M+ Android installs**. It was abandoned, not out-competed - its last user-facing feature shipped in April 2015 and it ran on autopilot for nine years. Its stated replacement is a format inside the Stories camera, capped at 6 photos, that does not produce a saved collage. The job Layout actually did was never migrated.

Meanwhile **Diptic** - the only one-time-purchase, no-subscription, minimal collage app, and the pick every "I hate subscriptions" listicle still routes readers to - **has not shipped a build since February 2021**. It is abandonware with a decaying 4.5 stars.

Every one of the top ~12 collage apps on the App Store today is free-with-subscription. Not one paid app ranks anywhere. The category has bifurcated into maximalist (Canva, Picsart, PicCollage: AI, stickers, text, memes, template walls, $10-15/month) and abandoned-minimal (Diptic, Layout). **There is no Halide of collage apps.** The customer who wants direct manipulation, craft, restraint, and a one-time price is being served by two products that no longer meaningfully exist.

**The one-liner.** Pick 2-4 photos. Drag the seams between them until it looks right. Save it at full resolution. Nothing else.

**Why this wins.**

1. **Direct manipulation is the product, not a feature.** Layout's single best-evidenced complaint across nine years and both platforms was *rigid layouts* - you could flip the images but not the arrangement. Every proportion here is set by dragging the thing itself, and a corner handle resizes a photo in both dimensions at once, which Layout never had at all (verified by measuring Meta's own screenshots: no corner handles exist, anywhere).
2. **Borders done properly.** Layout shipped with no borders by deliberate choice, capitulated within four months to a **white on/off toggle**, and never touched it again. Users asked for color for a decade. We ship inner and outer thickness, color, and corner radius on day one.
3. **One-time purchase.** Every ranked competitor is a subscription. They cannot copy this without torching their revenue model. It is the one part of the strategy that is structurally defensible.

---

## 2. Users

**Justin (v1's only user).** UX designer. iPhone 16 Pro Max. Does not use Instagram; saves to the camera roll and shares over iMessage. He is building this for one reason, in his words: *to make manipulating the layout fluid, easy, natural, and feel like he has control of the layout, the photos, and the frames.* He is a demanding judge of gesture feel and an indifferent one of feature count. **Every tie in this document breaks toward feel.**

**The App Store user (v2's audience).** Searches "collage," finds a wall of subscriptions and sticker apps, and bounces. Remembers Layout and is annoyed it's gone, or found Diptic and noticed it's from 2021. Wants a clean 2-4 photo collage at real resolution, no account, no monthly fee. Values what the app *refuses* to do. Willing to pay once.

---

## 3. Goals and Success Criteria

**Goals**

- Make the manipulation of layout, photos, and frames feel fluid, natural, and completely under the user's control.
- Reach a saved, good-looking collage faster than the mental overhead of opening any competitor.
- Do a small number of things without compromise, and refuse the rest visibly.
- Prove the app is good before spending a day on monetization.

**Success criteria** (each is checkable against the running product)

| # | Criterion |
|---|---|
| S1 | Justin, holding the Phase 2 prototype, says the corner handle does what his hand expected - without being coached on how it works. **This is the gate; nothing proceeds until it passes.** |
| S2 | Every gesture tracks the finger at the display's full refresh rate with 4 photos loaded - no dropped frames during a divider drag, a pinch, or a swap. |
| S3 | Launch to a saved 3-photo collage in under 45 seconds, unhurried. |
| S4 | Export of a 4-photo collage completes in under 3 seconds and peaks under 400MB. |
| S5 | Zero states in which a photo does not completely fill its cell. Not reachable by any gesture or sequence. |
| S6 | Force-quit mid-edit; relaunch restores the document exactly - same crops, same fractions, same borders. |
| S7 | An exported collage carries the earliest capture date of its sources and files itself next to them in Photos. |
| S8 | Export resolution beats Layout's (750x750) by at least 4x on the long edge for any collage of modern iPhone photos. |

**The one-sentence test**

> **Justin grabs a corner handle and both photos resize exactly the way his hand expected - first try, no thought.**

This is the tiebreaker for every micro-decision in the gesture layer. If a feature costs fluidity here, the feature loses.

---

## 4. Scope

**In scope (v1)**

- Custom photo picker: album/Favorites filter, reverse-chronological grid, fast-scroll, multi-select 2-4 with checkmark badges (unordered)
- **Auto-framing** - on-device Vision computes each photo's initial crop (faces drive the center, saliency drives the zoom); a per-photo Auto toggle
- **Content-fit assignment** - photos are placed into cells by aspect match, not pick order
- Recursive split-tree layout, n-way splits, arbitrary nesting
- Layout row: every topology worth having for 2, 3, and 4 photos (2 / 6 / 8 respectively)
- Orientation-aware default layout on arrival
- Draggable seams; selection outline + capsule handles on movable edges; **corner handles for diagonal resize**; permanent composition brackets for canvas ratio
- Pinch-zoom and pan to crop each photo in place, always filling its cell
- Long-press to lift, drag to swap
- Per-photo: flip horizontal, flip vertical, rotate 90 degrees, replace, remove
- Aspect ratio: preset chips + portrait/landscape flip + drag the composition brackets for arbitrary ratios
- Borders: inner and outer thickness (linked by default, unlinkable), color (swatch row + system picker + **derived suggestions from the photos**), corner radius
- Full undo/redo, ~50 steps
- Automatic high-resolution export (rule in section 6), JPEG q0.95, capped at 4096px long edge
- Save to Photos with **earliest source capture date and location preserved**; confirmation sheet showing the minted image and its dimensions; system share sheet
- Autosave of the in-progress document; one level of "edit last collage" after a save
- Dark chrome, light blue accent

**Out of scope (non-goals - these are decisions, not oversights)**

- **Filters, brightness, contrast, B&W, any per-photo image adjustment.** Photos.app is better at this and is one tap away. Anything you'd do here you'd do there first.
- **Text, stickers, emoji, memes, drawing.** This is the exact feature set that made every competitor unusable to the customer we're building for. Reviewers named the *absence* of these as why they deleted the rivals.
- **Free rotation of photos.** Photos.app straightens horizons before import. Costs gesture surface and zoom-clamping math for a case that's already solved upstream.
- **Non-rectangular cells, shapes, masks.** Different product.
- **Video.** Different product.
- **A project library / multiple saved documents.** That's naming, thumbnails, deletion, and storage management for a tool where you make a collage and export it thirty seconds later. One autosaved document plus one level of "edit last" covers the real cases.
- **Onboarding, tutorial, or intro screens.** Layout's unskippable ~60-second intro was a recurring complaint for nine years. The app teaches itself through its handle grammar (section 7) or it has failed.
- **iPad and landscape orientation.** A 16:9 canvas simply renders short and wide in portrait; there is no reason to rotate the device. Removes an entire category of layout work.
- **Backend, accounts, cloud sync, analytics.** Per the Build Guide's no-backend default. Nothing leaves the device.
- **Runtime AI calls of any kind.** Per the Build Guide.

**Deferred (v2+ candidates - see `Backlog.md` for the full list and the trigger for each)**

- IAP + watermark (architected for in v1; see section 6)
- 5-9 photos (the split tree is count-agnostic; this is a config change plus template art)
- iPad
- Eyedropper border color
- Corner handles where a divider meets a canvas edge (currently undefined by design)
- Project library

---

## 5. Product Principles

These win every argument. Three to five, and here they are:

1. **Nothing is committed until Save.** Everything before it is live, fluid, and reversible. No modal crop screen, no Apply button on any tray, no confirm step on a layout change, no separate preview mode. Every control mutates the canvas under your finger, in place, immediately. Save is the only moment anything is minted.
2. **Dragging changes proportions. Templates change topology.** A drag can make the left column wider; it can never turn "3 side-by-side" into "1 big + 2 stacked." Structural changes need a button; proportional ones never do.
3. **Photos always fill their cell.** A gap is a bug, not a style. Minimum zoom is aspect-fill and it is not reachable past.
4. **Chrome never covers the photos.** The canvas shows the truth of what will export. Handles live on seams and outside the composition, never on top of an image.
5. **Feel beats features.** If a feature costs gesture fluidity, the feature loses. This is the only reason the app exists.
6. **Intelligence proposes; the hand disposes.** Every automatic decision must be reversible by one gesture or one tap, and must **visibly stand down the moment you touch it**. Auto-framing is a proposal rendered in pixels, never a commitment - which is the only reason it's allowed to be on by default. An indicator that claims the app framed a photo you framed yourself is a lie, and lies are how automation loses trust.

---

## 6. Functional Requirements

### Screen A - Picker

Full screen, dark. This is the first screen on first launch and after every Save.

**Layout, top to bottom:**
- Header: album selector (a chevron button, default "Recents") on the left; **Next** on the right, disabled below 2 selections, showing the count as a badge (`Next (3)`).
- If an archived last-saved document exists: a single row at the top, **"Edit last collage"**, with a thumbnail. Tapping it restores that document and goes to the Editor.
- Grid: 4 across, square thumbnails, reverse-chronological. Fast-scroll scrubber down the right edge with floating date labels.
- Selection: an accent-colored border plus a **checkmark badge** - deliberately **unordered**. Placement is decided by content fit (below), so a numbered badge would promise a control the picker doesn't have. Do not "restore" numbering without also removing content-fit assignment; the two are a package.

**Album selector** opens a list: Recents, Favorites, then all user albums. No search in v1.

**States:**

| State | Behavior |
|---|---|
| Loading | Shimmer placeholders in the grid; scrubber disabled |
| Empty library | "No photos yet." Next stays disabled |
| Permission **denied** | Explanation copy + "Open Settings" button + a **"Choose Photos" button that falls back to `PHPickerViewController`**, which needs no permission. The app must remain fully usable without library access |
| Permission **limited** | Grid shows only the permitted subset, plus a persistent top row: **"Allow access to more photos"** -> `presentLimitedLibraryPicker`. Never show an empty-looking grid and call it done |
| iCloud-only photo | Thumbnail loads from the cloud with a small progress ring; `isNetworkAccessAllowed = true` |
| 5th tap | Rejected. Haptic bump; the Next badge pulses. No auto-replacement of an earlier pick |

### Screen B - Editor

The whole app. Dark chrome.

**Layout:**
- Top bar: **New** (left) | **Undo**, **Redo** | **Save** (right, accent-colored). New confirms ("Discard current collage?") - it is the one action undo cannot save you from.
  - **Save lives in the top bar, not the bottom one, and this is load-bearing:** the bottom bar is contextual, so a Save button down there would disappear whenever a photo was selected, forcing a deselect just to find it. Layout put SAVE in its header for the same reason. Save must be reachable from every state.
- Canvas: centered in the available space, scaled to fit, generous dead space around it. **Composition brackets sit just outside the canvas corners, permanently visible** whether or not a photo is selected.
- Bottom bar (contextual):
  - **Nothing selected:** `Layout` | `Ratio` | `Border`. Each raises a tray above the bar.
  - **A photo selected:** `Auto` | `Flip H` | `Flip V` | `Rotate` | `Replace` | `Remove`. All single-tap actions, no trays. `Auto` renders in the accent color when lit and dim when not (Layout used exactly this active-state convention). Six tiles is tight on the narrowest supported devices - **let the bar scroll horizontally rather than shrinking the touch targets**; Layout's did the same at four.
  - Deselect by tapping the dead space around the canvas.

**Trays:**
- **Layout** - a horizontally scrolling row of glyphs showing every topology for the current photo count. Tapping one changes the topology; photos keep their identity and crops where the cells map, and split fractions reset to even.
- **Ratio** - a scrolling chip row: `1:1`, `4:5`, `3:4`, `2:3`, `9:16`, `16:9`, `Original`. Tapping the *active* chip flips portrait/landscape.
- **Border** - `Inner` and `Outer` sliders with a **link toggle defaulting to ON**; a `Radius` slider; a swatch row (derived suggestions first, then white/black/greys/presets, then `+` for the system color picker). Custom colors persist in the row.

**The layout row's contents (locked):**

| Photos | Topologies |
|---|---|
| 2 | side-by-side, stacked |
| 3 | 3 columns, 3 rows, one-big-plus-two-stacked in each of the 4 directions |
| 4 | 2x2, 4 columns, 4 rows, one-big-plus-three in each of the 4 directions, the 1/2/1 sandwich |

That is every topology worth having. Together with draggable everything, it fully answers Layout's most-complained-about limitation.

**Default topology on arrival (orientation-aware):** canvas 1:1. Count the sources' orientations - mostly portrait -> columns; mostly landscape -> rows; 4 photos -> always 2x2.

**Content-fit assignment (which photo lands in which cell).** Not pick order. Once the topology is chosen, assign photos to cells by **aspect match**: cost = `|log(photoAspect) - log(cellAspect)|`, minimized across the assignment. **This needs no Vision and no cleverness** - with 4 photos maximum there are at most 24 permutations, so brute-force them and take the lowest total cost. A tight portrait lands in the squarer cell; the wide landscape gets the wide one. Ties broken by picker order.

Applies **on arrival only.** Once you're in the editor, placement is yours - swap is a first-class gesture and it never re-runs.

**Default selection on arrival:** **on the first-ever entry to the editor, and only then, cell one arrives selected** - outline and capsules visible, doing nothing. Every entry afterwards arrives with nothing selected. One persisted boolean.

This is deliberate and it is the app's entire onboarding. Section 4 rules out tutorials and intro screens, which means **the handle grammar has to teach itself or the app has failed** - and a silent, self-explaining first state is the only teacher we've allowed ourselves. Layout auto-selected the first cell on every entry (verified across two independent recordings) and its grammar demonstrably taught itself for nine years; we take the teaching moment and decline the permanent tax. **Do not "clean this up" - it looks like a bug and it is the plan.**

### Auto-framing (on-device Vision)

**Read this first: the Build Guide's rule "never make runtime AI calls from shipped apps" does not apply here and must not be cited against this feature.** That rule exists to prevent per-user cost, embedded keys, and App Review questions - all of which come from *network* calls to Gemini/OpenAI. `Vision` is on-device, free, offline, keyless, needs no privacy declaration beyond the photo permission we already hold, and adds nothing to the binary. It is a system framework, like Core Graphics.

**Why this exists.** Without it, a photo drops into its cell center-cropped, which is the naive default and which decapitates people. This is not a feature; it is the correct default. Its worst case (below) is exactly the behavior we'd have shipped anyway.

**The algorithm.** Runs once per photo at pick time (and on Replace), alongside proxy generation. ~20ms per photo.

1. `VNDetectFaceRectanglesRequest`. **Discard faces below a size threshold (height < ~8% of the photo's short edge) or below a confidence threshold.** This is what kills false positives from posters, banners, and background crowds.
2. **Faces drive the CENTER.** If any survive: ROI center = the centroid of the union of kept face rects, **biased slightly upward** so the subject sits above the cell's midline (standard portrait headroom).
3. **Saliency drives the ZOOM. Faces never drive zoom - this is load-bearing.** `VNGenerateAttentionBasedSaliencyImageRequest` -> the salient region's bounding box. Zoom so that box occupies ~70-80% of the cell, **hard-capped at 2.0x**, and **skipped entirely (zoom stays 1.0) when the salient box already exceeds ~60% of the frame.**
4. No faces -> ROI center = the salient region's centroid. No salient region either -> plain center, zoom 1.0 (today's behavior).
5. **Never zoom past the point where the photo's source pixels drop below the cell's export resolution.** Auto must not be able to zoom you into mush.
6. The result is written to the photo's existing `center` and `zoom`. **No new machinery downstream** - the clamp, ratio changes, divider drags, and undo all work unchanged.

> **Why faces must not drive zoom - the case that proves it.** In `_inbox/20260606_0135 BVH.JPG`, a kid running, the face is **~6% of the frame height**. A rule targeting "face at 30% of the cell" zooms ~4x and returns a headshot of a child mid-stride - throwing away the arms, the airborne orange shoes, and the dad grinning behind him. The photo is *about the running*. Saliency bounds the whole kid, which is the actual subject. Any implementation that reaches for face rects to compute zoom is wrong, no matter how good the numbers look.

**The Auto state model.** `Auto` is a **per-photo** toggle in the photo toolbar. It is **never global** - a global toggle would reset photos you'd hand-cropped, which is a destructive button wearing a mode's clothing.

| State | Meaning | How you get there |
|---|---|---|
| **Auto ON** | The crop is the app's proposal (ROI center + ROI zoom) | Every photo on arrival; or tap Auto while OFF |
| **Manual** (Auto dim) | The crop is yours | **Any pinch or pan silently drops that photo out of Auto.** Not a prompt, not a confirmation - it just stands down |
| **Neutral** (Auto dim) | Plain center, zoom 1.0 | Tap Auto while ON - this is "undo the auto" |

The auto-stand-down on touch is **mandatory, not polish**: an indicator that claims the app framed a photo you framed yourself is a lie (Principle 6). It also means a single tap can never silently destroy hand-crop work - after a hand-crop Auto is already dim, so tapping it moves *toward* the app's proposal, never away from yours.

**Graceful degradation is the safety property.** Verified against Justin's own `_inbox/` photos: the start-line shot has ~60 faces, so their union is the whole frame and it collapses to plain centering (correct); the finish-line shot has two faces spanning ~25% of the width, so in a narrow column it physically cannot hold both and picks one (acceptable). **Both failure modes land on "today's spec," not on "wrong."**

### The gesture model (the heart of the app - specify nothing here loosely)

**Handle grammar.** This is adapted from Layout's, whose grammar was verified by pixel-measuring Meta's App Store screenshots, and extended where Layout had gaps:

- **Thin outline (~2pt, accent) on all four edges** = "this photo is selected."
- **A fat capsule on an edge** = "this edge can move." Capsules appear **only on movable edges** - i.e. internal dividers, never canvas boundaries. A glance at the capsules tells you the layout's structure with zero copy. (In Layout this is why nobody ever tried to drag the canvas boundary.)
- **Capsule geometry:** ~**50% of the cell edge's length**, ~5pt thick, centered on the edge midpoint, **straddling the divider line**, with a subtle darker stroke and a soft drop shadow so it reads as a physical grab-bar. This is Layout's measured sizing. It is a huge, confident target - **not a 44pt dot**. Do not shrink it.
- **Corner handle** where two movable edges meet -> **diagonal resize, moving both dividers at once.** This is the feature that answers the original requirement ("one image smaller in height *and* width"), and **Layout provably never had it** - two independent research passes confirmed it, the second by selecting the center cell of a 3x3 (the only state where all four edges are internal dividers, i.e. the only state where a corner handle could exist) and finding four edge-midpoint capsules and zero handle-colored pixels in any corner. **This is the differentiator. Do not cut it, do not defer it, and do not let it degrade into two sequential edge drags.**
- **Composition brackets**, drawn differently (brackets, outside the canvas, not capsules on a seam), always visible -> canvas ratio.
- A corner where a divider meets a canvas edge is **undefined by design; draw no handle.** One axis wants a divider, the other wants a ratio; there is no non-arbitrary answer. Backlogged.

**Gestures:**

| Gesture | Result |
|---|---|
| Tap a photo | Select it. Outline + capsules + corner handles appear; bottom bar becomes photo tools |
| Tap the dead space | Deselect |
| One-finger drag on a photo body | **Pan the crop.** Works selected or not - direct manipulation is never gated behind selection |
| Pinch on a photo | **Zoom the crop.** Works selected or not. Min zoom = aspect-fill; max 8x |
| One-finger drag on a capsule / corner handle | Resize (requires the photo to be selected) |
| One-finger drag on a **bare seam** | Resize, no selection required. Live zone = the seam +/-11pt, or half the border thickness if larger. A selected photo's explicit handles get the full 44pt and win any tie. **Corners always require selection** - two overlapping seam zones cannot be resolved from a touch-down alone. Everything outside that band is a pan, always. *(Reversible decision - see `Backlog.md`. Layout required selection to resize and it worked; we're trying the more fluid version first. Fallback is fully specified.)* |
| **Long-press (~0.35s) then drag** | **Swap.** Haptic thump on lift; a **small floating proxy of the photo follows the finger** (the source cell keeps showing its photo - do not leave a hole); the **hovered target cell outlines in the accent color**; release trades them with an animation. Layout used exactly this disambiguation for nine years and its feedback was verified frame-by-frame - **the long-press is load-bearing. Do not "improve" it into a bare drag or panning breaks.** |
| Drag a composition bracket | Canvas ratio. **The canvas physically grows under the finger** during the drag with a live ratio readout, then springs back to fit-on-screen at the new ratio on release. (It must grow, or the handle visibly lags the finger - the split fractions are percentages, so a photo at 60% width moves only 60% as far as the canvas does.) |

**Constraints, snapping, haptics:**

**None of the values below have precedent** - two research passes established that Layout's snapping, minimum cell size, and haptics are genuinely unverifiable from any surviving source. These are our own inventions. Tune them on device in Phase 2; do not treat them as received wisdom.

| Rule | Value |
|---|---|
| Minimum cell | 10% of the parent's extent along the split axis, with rubber-band resistance. Never crosses. Haptic at the floor |
| Snap: center | Within 8pt of 50% -> snap, haptic tick. **The only proportional detent** - thirds were considered and rejected; multiple detents make a short drag feel notchy rather than analog |
| Snap: sibling alignment | Two sibling dividers within 8pt of each other -> snap flush, haptic tick. This is what makes a clean 2x2 effortless while leaving staggered ("Mondrian") 2x2s reachable. **Dividers are independent; there is no linked grid node.** Verified as Layout's model too: in a real Layout 2x2, the left column's divider sat at ~48% height while the right column's sat at ~80% - columns-first nesting, never coupled |
| Zoom floor / pan clamp | Rubber-bands past the limit, springs back on release. A gap is never reachable |
| Haptics | Divider grab, center snap, sibling snap, min-cell floor, photo lift, photo drop, save complete |

**Aspect ratio changes preserve work (locked).** Split fractions are stored as percentages, so 60/40 stays 60/40 across any ratio change. Each photo keeps its zoom and normalized center and re-crops around that same focal point as its cell changes shape - **zooming in automatically if the new shape would otherwise expose an edge.** Changing the ratio never costs crop work.

**Editor states:**

| State | Behavior |
|---|---|
| Loading proxies | Cells shimmer until their downsampled copies are ready |
| iCloud download | Progress ring in the cell |
| **Photo unavailable** (deleted from the library since autosave) | Cell shows a placeholder with "Photo unavailable - tap to replace." **Save is blocked** with an explanatory alert |
| Exporting | Save shows a spinner; canvas locked |
| Export failed | Alert with the actual reason + Retry |

### Screen C - Save sheet

Tapping **Save** renders, writes to Photos, then presents a modal sheet:

- **The actual exported image** - not a re-render of the canvas. You see exactly what got minted.
- "Saved to Photos"
- The real pixel dimensions ("3072 x 3840")
- **Share** (system share sheet) | **Done**

**Done** dismisses to the **Picker**. The document is archived as the "last collage" and the canvas clears. Tapping Save twice produces two identical assets in Photos - expected, no dedup.

### Export rule (locked)

**Sizing.** For each cell, compute the source pixels currently mapped into it. Scale the canvas so that the **most detail-rich cell renders at roughly 1:1 with its source**, then **clamp the long edge to 4096px**. A collage of modern iPhone photos comes out genuinely sharp; a collage of screenshots doesn't get artificially bloated. No resolution picker - the export sheet reports the result. (For reference: Layout shipped 750x750 and was square-only forever.)

**Format.** JPEG at 0.95. HEIC is half the size but stumbles the moment a collage leaves the Apple ecosystem.

**Rendering.** Full-resolution export goes through **Core Graphics (`CGContext`), never SwiftUI's `ImageRenderer`**, which is unreliable at large scales. Photos are composited **one at a time and released** to bound peak memory. If the render still fails, retry once at half scale and tell the user.

**Metadata.** The saved asset carries the **earliest capture date among the sources**, and their location if they agree. The collage then files itself next to the photos it's made from; Photos' "Recents" sorts by date-added, so you still find it immediately today. Layout destroyed this metadata for nine years and broke people's photo-print subscriptions.

**The watermark seam (v1 architecture, v2 feature).** The export pipeline ends with a single compositing hook. v2 draws a small wordmark there - ~4% of the long edge, bottom-right, inside the outer margin if one exists, white with a subtle dark stroke. v1 passes through untouched. **No StoreKit in v1.**

### Persistence

Two files. `current.json` is the in-progress document, autosaved continuously. `last.json` is the archived just-saved document.

| Event | Result |
|---|---|
| Launch, `current.json` exists | Editor, restored exactly |
| Launch, no `current.json` | Picker (with "Edit last collage" if `last.json` exists) |
| Save | `current.json` -> `last.json`; `current.json` deleted |
| "Edit last collage" | `last.json` -> `current.json`; Editor |
| New collage committed (Next from the picker) | `last.json` deleted |

Both survive termination. Photos are referenced by `PHAsset` local identifier.

---

## 7. Visual and Design Spec

**Tone:** a tool, not a toy. Halide and Darkroom, not PicCollage. Quiet, dark, confident. The photos are the only color on screen.

**Appearance: dark, always.** Ignores the system light/dark setting, deliberately. A light surround measurably biases how you judge an image's exposure and color - every serious photo tool is permanently dark for this reason, including Apple's own Photos editor. Following the system would mean your collage looks different at 9am than at 9pm.

**Palette (placeholder rule - see open questions):**

| Token | Value | Use |
|---|---|---|
| Background | `#0B0B0D` | The surround behind the canvas |
| Surface | `#1C1C1E` | Bars, trays, sheets |
| Accent | **`#71BFFF`** | Selection outline, capsules, brackets, active controls, Save, picker badges |
| Accent stroke | `#000000` at ~30% | A subtle dark outer stroke behind every accent element |

`#71BFFF` is the exact token Instagram Layout used app-wide, sampled from Meta's screenshots. Justin independently specified "light blue," so it stands as the placeholder until he picks from the `_review/` mockups. **The accent stroke is not optional** - light blue disappears against sky, and sky is in a great many photos. The stroke is what makes the accent readable against anything without changing the color.

**Handles:** see the handle grammar in section 6. It is a design spec as much as a functional one.

**Icon direction:** a light blue grid on a dark background. Generate candidates into `_review/` per the Build Guide's design-time asset workflow; Justin picks. Placeholder-first: the app must feel finished with a programmatic placeholder icon.

**Typography:** SF Pro throughout. Toolbar labels in caps, small, tracked - the register Layout used and one of the few things it got right on the first try.

---

## 8. Data Model

Plain `Codable` value types. The whole document is small - a tree of fractions and a handful of transforms - which is precisely why full undo is cheap (section 9).

```swift
struct Document: Codable, Equatable {
    var canvasRatio: Ratio          // width:height. Only the ratio matters, never absolute size
    var root: Node
    var photos: [PhotoID: PhotoRef]
    var border: BorderStyle
}

indirect enum Node: Codable, Equatable {
    case leaf(PhotoID)
    case split(axis: Axis, fractions: [Double], children: [Node])
}
// INVARIANTS:
//   fractions.count == children.count, and >= 2
//   fractions.sum() == 1.0 (renormalize after every mutation)
//   every fraction >= 0.10
//   leaf count == photos.count, and is in 2...4
// n-way splits, not binary: "3 columns" is ONE node with 3 children and 2 dividers.
// Dragging divider i is zero-sum against fractions[i] and fractions[i+1] only.

struct PhotoRef: Codable, Equatable {
    var assetLocalIdentifier: String   // PHAsset
    var zoom: Double                   // 1.0 == aspect-fill. INVARIANT: 1.0...8.0, never below 1.0
    var center: CGPoint                // normalized 0...1 in the photo's own space; the point at the cell's center
    var flipH: Bool
    var flipV: Bool
    var quarterTurns: Int              // 0...3
    var isAuto: Bool                   // true on arrival. Auto-framing owns `zoom`+`center` while true.
    var roi: ROI?                      // cached Vision result; nil if detection found nothing.
                                       // Computed ONCE at pick time (and on Replace) - never re-run on
                                       // topology/ratio/divider changes, or the photo would swim under
                                       // the user's finger.
}

struct ROI: Codable, Equatable {
    var center: CGPoint     // faces (biased upward) if any survive thresholds, else saliency centroid
    var zoom: Double        // from the SALIENCY box only, never faces. 1.0...2.0
}
// INVARIANT: any pan or pinch on a photo sets isAuto = false. No exceptions, no prompt.
// `roi` is retained while isAuto is false so tapping Auto can restore the proposal without re-running Vision.
// INVARIANT: `center` is clamped after EVERY mutation (pan, zoom, ratio change, divider drag,
// topology change) such that the photo still fully covers its cell. This invariant is the
// mechanism behind Principle 3 and success criterion S5. It has no exceptions.

struct BorderStyle: Codable, Equatable {
    var inner: Double        // FRACTION OF THE CANVAS SHORT EDGE, 0...0.15 - never points
    var outer: Double        // same units
    var linked: Bool         // default true
    var cornerRadius: Double // same units
    var color: RGBA
}
// Border thickness is stored as a fraction of the canvas short edge so it scales
// automatically from the on-screen canvas to a 4096px export. The UI presents it as 0-100.
```

**Undo:** `[Document]`, snapshotted on **gesture end** (not continuously), capped at 50. A redo stack cleared on any new mutation.

**Engine/UI split:** everything above, plus layout solving, clamping, snapping, and export sizing math, lives in `Sources/Engine/` as **plain Foundation with no SwiftUI import**, so it is testable via the Build Guide's `swiftc` smoke-test recipe without an Xcode build.

---

## 9. Tech Stack and Architecture

Follow the Build Guide's iOS section for signing, XcodeGen, the Dropbox `xattr -cr` gotcha, and deployment. Project-specific only:

| | |
|---|---|
| **Repo** | `nikolausj1/mosaic` |
| **Bundle ID** | `com.levelup.mosaic` |
| **Min iOS** | 18.0. Two years old and near-universal; gives modern SwiftUI and StoreKit 2 for v2 |
| **Devices** | iPhone only, portrait only |
| **UI** | SwiftUI |
| **Photos** | `PHPhotoLibrary` full access for the custom grid, **with `PHPickerViewController` as the mandatory fallback** on denied/limited |
| **Vision** | `VNDetectFaceRectanglesRequest` + `VNGenerateAttentionBasedSaliencyImageRequest` for auto-framing. **On-device, free, offline, keyless.** The Build Guide's "no runtime AI calls" rule targets *network* calls to Gemini/OpenAI and does not apply - do not cite it against this |
| **Export** | Core Graphics `CGContext`. **Not `ImageRenderer`** - unreliable at large scale |
| **Backend** | None. Nothing leaves the device |

**Performance architecture (locked).** Four 48MP photos live on a canvas will kill the app if handled naively. On pick, generate a **downsampled proxy** per photo (~2x the largest on-screen cell, so ~2000px long edge maximum) via `CGImageSourceCreateThumbnailAtIndex`, and cache it. **The editor only ever touches proxies.** Only the export path touches full-size pixels, one photo at a time, released immediately. This is what buys S2 and S4.

**Rejected alternatives** (do not relitigate):

| Considered | Rejected because |
|---|---|
| Template-only layouts (Diptic/Layout model) | Layout's #1 complaint for nine years was exactly this |
| Freeform floating-rect canvas | No shared edges, so no dividers to drag - which is the entire product |
| A linked "grid" node type for 2x2 | A second node type in the data model to *remove* expressiveness. Sibling-alignment snapping gets the clean grid for free and keeps staggered layouts reachable |
| `PHPickerViewController` as the primary picker | An in-app grid is faster and matches "one interface." PHPicker remains the fallback |
| HEIC export | Breaks outside the Apple ecosystem |
| `ImageRenderer` for export | Unreliable at high scale |
| A web/HTML gesture prototype | Browser touch handling isn't UIKit's; it would answer a question we aren't asking |

---

## 10. Build Phases

Each phase ends in something verifiable. **Phase 2 is a hard gate.**

**Phase 0 - Scaffold.** Repo, XcodeGen `project.yml`, bundle ID, `.gitignore` / `.dropboxignore` / `_inbox/` / `_review/` per the Build Guide.
*Exit:* `xcodebuild` succeeds; an empty app launches on the sim.

**Phase 1 - Layout engine.** `Sources/Engine/`, pure Foundation: the tree, n-way splits, fraction renormalization, the 10% floor, center and sibling snapping, the cell-covering clamp, ratio-change preservation, export sizing math.
*Exit:* **50+ engine checks green** via the Build Guide's `swiftc` recipe. No UI.

**Phase 2 - The gesture prototype, on Justin's iPhone. HARD GATE.** Hardcoded bundled photos, grey boxes for everything else, no picker, no borders, no export, no color beyond the placeholder accent. Ships: the split tree rendered, bare-seam drags, selection outline + capsules, **corner diagonal resize**, composition brackets + ratio drag, pinch/pan crop with clamping, long-press swap, undo/redo, all haptics.
*Exit:* **Installed on Justin's iPhone (Build Guide Recipe A). He holds it and approves the feel - or we redesign the gesture layer having spent days instead of weeks. Nothing proceeds until this passes.** This inverts the Build Guide's screenshot-approval loop at exactly the one place a screenshot is useless: a screenshot cannot tell you whether a corner handle feels right.

**Phase 3 - Picker and auto-framing.** Grid, album/Favorites filter, fast-scroll, checkmark multi-select, all four permission states, the PHPicker fallback, proxy generation, orientation-aware default topology, content-fit assignment, **Vision auto-framing + the per-photo Auto toggle and its stand-down-on-touch behavior**.
*Exit:* Sim-verify + screenshots. Pick 2-4 real photos and land in the editor correctly framed. **Verify auto-framing against the four photos in `_inbox/`**, which cover the cases deliberately: a ~60-face crowd (must collapse to plain centering), a small off-center face with a large salient body (must center on the face and NOT zoom to a headshot), two faces spanning the frame, and a low-resolution source (must not zoom into mush).

**Phase 4 - Chrome.** Contextual bottom bar; Layout / Ratio / Border trays; the full layout row (2/6/8); ratio chips + flip; inner/outer/radius sliders with the link toggle; swatch row + system picker + **derived color suggestions**; the photo toolbar (flip H, flip V, rotate, replace, remove).
*Exit:* Sim-verify + screenshots of every tray and both bar states.

**Phase 5 - Export and Save.** The CGContext pipeline, the sizing rule, the watermark seam (pass-through), JPEG encoding, save to Photos, **EXIF date + location**, the save sheet, the share sheet.
*Exit:* Export a 4-photo collage; verify the pixel dimensions, that it beats 4x Layout's 750px, and that **Photos shows it filed on the earliest source's capture date**. Verify peak memory under 400MB.

**Phase 6 - Persistence and edges.** Autosave, `current`/`last`, restore-on-launch, New + confirm, and every row of the edge-case table.
*Exit:* Force-quit mid-edit and restore exactly (S6). Delete a source photo from the library and confirm the unavailable state and the blocked save.

**Phase 7 - Visual polish.** Color selection from the `_review/` mockups over Justin's real photos; icon candidates; the accent stroke verified against sky, skin, foliage, and night.
*Exit:* Justin picks; values land in the PRD; deployed to his iPhone.

**v2 (not now):** StoreKit 2 non-consumable, watermark at the seam, restore purchases, App Store record, screenshots, privacy nutrition label, the rename.

---

## 11. Acceptance Criteria

Each line is verifiable by testing the running product.

- [ ] Picking 2-4 photos lands in an editor with a sensible default layout matching the photos' orientation
- [ ] On a fresh install, the first-ever entry to the editor arrives with cell one selected; the second entry and every one after arrives with nothing selected
- [ ] Save is reachable from the top bar in every state, including with a photo selected
- [ ] Every internal seam can be dragged; no seam can collapse a cell below 10%; center and sibling-alignment both snap with a haptic
- [ ] Selecting a photo shows a thin outline on all four edges and a capsule **only** on movable edges
- [ ] A corner handle exists wherever two movable edges meet, and dragging it moves both dividers
- [ ] Composition brackets are visible at all times and drag to any ratio, with the canvas growing under the finger and springing back on release
- [ ] Every ratio chip works; tapping the active chip flips orientation; **no ratio change ever loses a crop**
- [ ] Pinch and pan work on any photo whether or not it is selected
- [ ] Photos arrive auto-framed: a face is never cropped out of a cell it could have fitted in
- [ ] A photo whose face is a small fraction of the frame is **not** zoomed to a headshot - the salient subject, not the face, drives zoom, capped at 2.0x
- [ ] A crowd photo (many faces) collapses to plain centering rather than a nonsense crop
- [ ] Auto never zooms past the source's usable resolution for that cell
- [ ] Pinching or panning any photo **immediately dims its Auto indicator**, with no prompt
- [ ] Tapping a dim Auto re-applies the app's framing; tapping a lit Auto resets to plain center + aspect-fill
- [ ] Auto is per-photo: toggling it on one photo leaves every other photo's crop untouched
- [ ] Photos are assigned to cells by aspect fit on arrival, and never re-assigned afterwards
- [ ] **No gesture or sequence of gestures can produce a photo that doesn't fill its cell** (S5)
- [ ] Long-press lifts a photo with a haptic; dragging it onto another swaps them; a bare drag never swaps
- [ ] Flip H, flip V, rotate 90, replace, and remove all work; remove is disabled at 2 photos
- [ ] The layout row offers 2 / 6 / 8 topologies for 2 / 3 / 4 photos and every one applies correctly
- [ ] Inner and outer sliders move together when linked and independently when not; radius, swatches, the system picker, and derived suggestions all work
- [ ] Undo and redo cover every action, ~50 deep; both grey out at their limits
- [ ] Save writes a JPEG to Photos whose long edge is >= 3000px for a 2-photo collage of iPhone photos, and never exceeds 4096
- [ ] **The saved asset carries the earliest source capture date** and files next to it in Photos (S7)
- [ ] The save sheet shows the real exported image and its true dimensions; Share opens the system sheet; Done returns to the picker with "Edit last collage" present
- [ ] Force-quit mid-edit restores the document exactly (S6)
- [ ] Denied and limited permission both leave the app fully usable via the PHPicker fallback
- [ ] A deleted source photo shows the unavailable state and blocks Save with an explanation
- [ ] No dropped frames during any gesture with 4 photos loaded (S2)
- [ ] Export completes in under 3 seconds, peak memory under 400MB (S4)

---

## 12. Risks and Open Questions

**Risks**

| Risk | Mitigation |
|---|---|
| **Gesture feel is the entire product and cannot be validated by screenshot.** The normal review loop structurally cannot evaluate the one thing that decides success | Phase 2 hard gate: on-device prototype in Justin's hand before any chrome exists. If the handles are wrong we find out in days, not weeks |
| **Bare-seam drags misfire into accidental resizes** while panning near a seam. Layout required selection to resize and had no such class of complaint | Tight live zone (+/-11pt); selection handles win ties; corners require selection. **Fallback fully specified in `Backlog.md`**: require selection for seam drags. Revisit signal: accidental resizes in real use |
| **Memory during export.** Four 48MP sources into a 4096px canvas | Proxies for the editor; composite one photo at a time into the CGContext and release; 4096 cap; retry once at half scale on failure; peak-memory acceptance test |
| **iCloud photos aren't local.** Export needs full-res originals that may require a download | `isNetworkAccessAllowed = true` with progress UI in the cell and on export; explicit failure alert with retry |
| **Auto-zoom is the riskiest thing in the app.** Centering has a right answer; zooming is a taste call the app is making on the user's behalf, and when it's wrong you're pinching back out of a state you never chose | Saliency-driven (never face-driven), hard-capped at 2.0x, skipped when the subject already fills the frame, and refuses to exceed usable source resolution. **The per-photo Auto toggle is its safety net** - one tap to neutral. Backlogged with an explicit kill trigger (B20): if Auto gets switched off on more than ~1 in 4 photos, auto-zoom is wrong and should be cut back to centering-only |
| **Vision false positives** - a face on a background poster or banner hijacks the crop | Size threshold (face height > ~8% of the short edge) plus a confidence threshold; below that, fall through to saliency. Verified against the four real photos in `_inbox/` |
| **Auto-derived border colors look muddy.** The dominant color of a photo is often dirt, skin, or sky mud | **Derive, never use raw dominants**: extract the palette, then desaturate and push light/dark. Ship as *suggestions prepended to the swatch row*, never automatic - they can be ignored, which caps the downside |
| **A source photo is deleted from the library** after autosave | Unavailable placeholder; tap to replace; Save blocked with an explanation |
| **Dropbox breaks code signing** | `xattr -cr Sources` before every build, per the Build Guide |
| **"Mosaic" trademark.** The name is registrable on the App Store (verified: zero exact matches on Apple's live index) but several live companies use the word, and 13 apps hold it as a leading token | **Trademark clearance is a real pre-submission step, not a formality.** It blocks nothing in the build. Two verified-clear alternates are on file in `Backlog.md` (Spreads, Gridly) and the rename is cheap while Justin is the only user |

**Open questions (non-blocking - Claude Code must flag these, not decide them)**

1. **The exact accent hex and handle treatment.** Justin will pick from mockups composited over his own photos in `_review/` (Phase 7). **Placeholder rule: `#71BFFF` with the dark accent stroke.** Do not block; do not silently substitute another color.
2. **Whether bare-seam drag survives real use.** See risks. The fallback is specified; the decision is Justin's after Phase 2.
3. **"Mosaic" trademark clearance.** Needed before submission only. Do not let it delay any build phase.

---

# Quality Checklist

**Completeness**
- [x] A stranger reading only this PRD and the Project Build Guide could build it
- [x] Every screen has its empty, loading, and error states specified
- [x] Every user-facing flow is traceable start to finish
- [x] Data model covers every entity the functional spec mentions
- [x] Content strategy: n/a - all content is the user's own photos; no editable content files

**Decisions**
- [x] Non-goals contains real decisions with reasons, not obvious exclusions
- [x] Every TBD is resolved or moved to a non-blocking open question with a placeholder rule
- [x] Locked decisions are marked as locked
- [x] Rejected alternatives are noted (section 9)

**Testability**
- [x] Every success criterion is a checkable assertion
- [x] Acceptance criteria are testable against the running product
- [x] The one-sentence test exists

**Claude Code fit**
- [x] References the Build Guide rather than restating it
- [x] Build phases are small, ordered, each ending in verification; the riskiest thing (gesture feel) is Phase 2 and gates everything
- [x] Edge cases are enumerated as tables
- [x] Open questions flagged non-blocking with placeholder rules and instructions to ask, not decide

**Brevity**
- [x] Core sections within range; the backlog lives in its own file
