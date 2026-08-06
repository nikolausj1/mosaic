---
title: "App Store Listing - Mosaic"
created: 2026-07-26
modified: 2026-08-06
version: 2.2
author: Claude Fable 5 (claude-fable-5)
tags:
---

# App Store Listing - Mosaic

Draft listing copy for review. Field limits respected (title 30, subtitle 30, keywords 100). ASO rationale: the App Name carries the most ranking weight, Subtitle second, Keywords third; no word is repeated across the three fields.

## App Name (30 char limit)

**Mosaic: Photo Collage & Layout** (exactly 30)

Carries the brand plus the two highest-intent search terms. Alternate if App Review ever objects to the ampersand: "Mosaic - Photo Collage Maker" (28).

## Subtitle (30 char limit)

**Auto layout that finds faces.** (29) - chosen by Justin 2026-08-06; also THE marketing headline from now on (screenshot panel 1, and anywhere a tagline is needed). Selling points it carries: auto layout + face finding; "fully adjustable" lives in the description.

Adds four new ranking words (grid, editor, faces, auto-framed) and states the differentiator. Alternates:
- "Clean, quick, nothing to learn" (30)
- "2-4 photos, perfectly framed" (28)

## Keywords field (100 char limit, not user-visible)

`picture,pic,combine,merge,stitch,joiner,montage,maker,frame,split,mix,square,two,three,four` (91)

Notes: never repeat title/subtitle words here (wasted characters); no competitor brand names (rejection risk); singular forms only, Apple matches plurals.

## Promotional text (170 char limit, editable without review)

The spiritual successor to Layout: pick 2-4 photos, drag the seams until it looks right, and save a full-resolution collage that lands right at the top of your library, carrying the original date and place inside the file.

## Description

Mosaic is a photo collage editor for people who want their photos, side by side, and nothing else.

Pick 2 to 4 photos. Mosaic arranges them instantly, framing faces and subjects automatically, entirely on your device. Drag any seam to resize. Drag the corner handle diagonally. Pinch to reframe, tap to swap. When it looks right, save.

WHAT MAKES IT DIFFERENT

- Auto-framing that actually works: on-device intelligence centers faces and subjects in every cell the moment your photos land, so the starting point already looks good.
- Ready to share the second it is saved: the collage lands at the top of your library, where Photos and Messages offer it first. The earliest source photo's date and location are written into the file's own EXIF, so the provenance travels with the image wherever you send it. Layout destroyed that metadata for nine years.
- Full resolution, always: exports use your photos' real pixels. No downscaling, no compression tricks.
- Nothing to learn: no templates to browse, no tutorial to skip. The layout is the interface.

WHAT IT LEAVES OUT, ON PURPOSE

No stickers. No filters. No text tools. No ads. No account. No tracking. Nothing ever leaves your device.

THE DETAILS

- Layouts for 2, 3, or 4 photos with draggable seams and a diagonal corner handle
- Square, portrait, story, and landscape canvas ratios, plus your photo's own ratio
- Border thickness, corner rounding, and color, including colors sampled from your photos
- Rotate, flip, replace, and swap photos in place
- Pinch the photo grid to size the thumbnails, the way Photos does

Mosaic is free with a small watermark on saved collages. One inexpensive one-time purchase removes it forever. No subscription.

## What's New (v1.0)

Initial release.

## Featuring nomination pitch (App Store Connect, submit ~3 months pre-launch)

**One-liner:** Mosaic revives the best-loved collage app Instagram abandoned, rebuilt for the Liquid Glass era with on-device Vision auto-framing.

**Narrative:** Instagram's Layout defined simple collages for nine years, then stopped. Mosaic is its spiritual successor, built by one developer who wanted the app back and better: every cell auto-frames faces and subjects using the Vision framework entirely on device, seams drag like they always should have, and the finished collage saves at full resolution into the photo library under the date the memory actually happened, the feature Layout famously never shipped. No accounts, no ads, no data leaving the phone.

**Maps to Apple's stated criteria:** innovation (on-device Vision auto-framing, EXIF-true saves), uniqueness (anti-feature philosophy in a category of sticker-filled editors), UI design (single-screen editor, self-teaching gesture grammar, native Liquid Glass icon), privacy (zero collection, documented in the nutrition label).

---

# App Store Connect fill sheet

Everything below is ready to paste into the record created 2026-07-28
(**Apple ID 6795437010**, bundle `com.levelup.mosaic`, SKU `mosaic-ios-001`).

## URLs (all live and verified)

| Field | Value |
|---|---|
| Privacy Policy URL (**required**) | `https://nikolausj1.github.io/mosaic-app-site/privacy.html` |
| Support URL (**required**) | `https://nikolausj1.github.io/mosaic-app-site/support.html` |
| Marketing URL (optional) | `https://nikolausj1.github.io/mosaic-app-site/` |

## Category and rating

- Primary category: **Photo & Video**. Secondary: none (or Graphics & Design if a second is wanted).
- Age rating: **4+**. Every questionnaire item is **None / No** - the app has no violence, no mature themes, no user-generated content sharing, no web access, no gambling, no contests, no ads, and no data collection. It does not have unrestricted web access and is not age-restricted.

## Privacy nutrition label

Answer: **"Data Not Collected."** Nothing else needs filling. The app has no analytics, no third-party SDKs, no accounts, and no servers of its own. Photos are read and written only on the device at the user's direction. The one required-reason API in use (UserDefaults, reason `CA92.1`) is already declared in `Sources/Resources/PrivacyInfo.xcprivacy`.

## App Review notes (paste into "Notes" on the version)

```
Mosaic is a photo-collage editor. No account, no sign-in, and no demo
credentials are needed - everything is reachable immediately on launch.

To try it: allow photo access when prompted, tap 2 to 4 photos, tap
"Next". In the editor, drag any seam between photos to resize, drag the
round handle where seams meet to reshape, and use the Layout / Ratio /
Border tabs at the bottom. Tap "Save" to write the collage to the photo
library. IMPORTANT: the test device or simulator needs at least two
photos in its library, otherwise the picker is legitimately empty.

In-app purchase: "Remove Watermark" (com.levelup.mosaic.removewatermark)
is a one-time non-consumable. The app is fully functional without it;
the only difference is a small Mosaic wordmark in the corner of saved
collages. The purchase surface is reachable from the "Remove" link on
the save sheet after saving, or from the gear icon in the top-right of
the photo picker -> "Save without the watermark". "Restore Purchase" is
in the same two places.

If you buy the unlock from the save sheet's "Remove" link while a
watermarked collage is still showing there, the app automatically saves
a second, clean copy of that same collage to Photos right after the
purchase completes - by design, so a purchase never leaves you with
only the watermarked file to notice and re-save yourself. Seeing two
Photos writes for one Save is expected in that flow, not a bug.

Privacy: the app makes no network requests of its own and has no
backend. Face and subject framing uses Apple's on-device Vision
framework. Nothing about the user or their photos is transmitted
anywhere.
```

## In-app purchase configuration

| Field | Value |
|---|---|
| Type | Non-Consumable |
| Reference Name | Remove Watermark |
| Product ID | `com.levelup.mosaic.removewatermark` |
| Display Name | Remove Watermark |
| Description | Removes the small Mosaic wordmark from the corner of every collage you save. One-time purchase, yours forever. |
| Price | **Justin's call** - `Mosaic.storekit` uses $2.99 as a placeholder only |
| Review screenshot | `_store/iap/paywall-review-screenshot.png` |

**Caveat on that review screenshot:** it was captured from a plain simulator install, where StoreKit has no product to load, so the button reads "Unlock" with no price. Recapture it from an Xcode run (the scheme has `Mosaic.storekit` attached) once the real price exists, so the button shows the actual amount.

The IAP must be submitted **with** the first version - a new app's in-app purchases are reviewed alongside the build, not separately.

## Screenshots

`_store/screenshots-v2/01-05.png`, five shots at 1320x2868 (6.9" display) - the spanning/panorama set built by `_store/build_banner.py`, which supersedes the older `_store/screenshots/` set (still on disk but not for upload). Upload in that order - the first two are what most people ever see. Apple scales these down for smaller devices, so no other size is required.

**Before uploading, panel 5 needs to be rebuilt:** its subhead currently reads "Saved under the date the photos were taken," which describes the OLD filing behavior. Saves now sort to the top of the library at export time, with the earliest source photo's date/location written into the file's own EXIF - the same claim the Description already makes correctly ("the collage lands at the top of your library... The earliest source photo's date and location are written into the file's own EXIF"). Fix in `_store/build_banner.py` line 323 (`sub="Saved under the date the photos were taken."`), e.g. `sub="Files at the top of your library, provenance kept in the EXIF."`, then re-run the script and re-export panel 5 - the raw device screenshot underneath (`sc-save.png`) is still accurate and does not need reshooting.

## Version information

- Version: **1.0**, Build: **1** (`project.yml` is the single source; `Info.plist` reads the macros)
- Copyright: `2026 Justin Nikolaus`
- Export compliance: `ITSAppUsesNonExemptEncryption` is already `false` in Info.plist, so the encryption question is answered automatically at upload.
- Release: recommend **manual release** after approval, so the launch moment is yours rather than whenever review finishes.

---

Once Justin approves: paste name/subtitle/keywords into App Store Connect verbatim; description supports minor formatting only (plain text, no markdown).
