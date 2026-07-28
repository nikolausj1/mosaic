---
title: "Ship Plan - Mosaic App Store Readiness"
created: 2026-07-26
modified: 2026-07-28
version: 1.2
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Ship Plan - Mosaic App Store Readiness

Diagnosis of everything standing between the current build and an App Store submission, split by who can do it. Sources: repo audit (2026-07-26), branding and featuring research (2026-07-26), STATUS.md, Backlog.md, PRD.md.

## Verdict in one paragraph

The app itself is nearly ready: no TODOs, no stray prints, debug HUD properly DEBUG-gated, privacy strings in place, modern single-size icon slot. What blocks submission is (1) four concrete code/config defects, all fixable by Claude in one session, (2) five decisions only Justin can make, none longer than 30 minutes except the pricing call, and (3) the entire marketing surface (icon, screenshots, listing copy, landing page), which Claude can draft end to end with Justin picking winners.

## Track 1 - Code and config fixes (Claude does, no decisions needed)

- [ ] **Prototype photos ship in Release.** `Sources/Resources/Prototype/proto1-4.jpg` are in the app target's Resources build phase. They are personal photos and dead weight. Fix: exclude from the target (or DEBUG-only copy phase) in `project.yml`.
- [ ] **`-protoLayout` / `-autoPick` launch args are live in Release.** Only `-resetPersistence` is `#if DEBUG`-gated in `MosaicApp.swift`. Fix: gate all debug launch args.
- [ ] **Signing config pins `CODE_SIGN_IDENTITY = "iPhone Developer"` in Release** and no `CODE_SIGN_STYLE` is declared. Fix: automatic signing in `project.yml`, no pinned identity.
- [ ] **Version source-of-truth mismatch.** `project.yml` says 0.1.0, `Sources/Info.plist` hardcodes 1.0/1. Fix: Info.plist uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, project.yml set to 1.0 / 1.
- [ ] **Add `PrivacyInfo.xcprivacy`.** Audit found no required-reason APIs except `@AppStorage` (UserDefaults, reason code CA92.1). Declare it deliberately plus the two Photos data-collection = none entries so the nutrition label review is trivial.
- [ ] Set `LSApplicationCategoryType` to Photography (cheap, explicit).
- [ ] Icon Composer build of the final icon: layered source, all six iOS 26 appearance variants (default, dark, clear light/dark, tinted light/dark). Without this Apple auto-converts flat icons for Liquid Glass with a crude heuristic.
- [ ] **Gate or remove the Developer sheet before submission.** Added 2026-07-26 at Justin's request so he can replay the first-run experience and A/B test on his phone; it currently ships in Release (picker header, hammer icon). Must be #if DEBUG-gated or deleted before any App Store build.

## Track 2 - Decisions only Justin can make

- [ ] **B26 device checklist** (~30 min). The only remaining unverified path to done. Nothing ships before this.
- [ ] **B27 onboarding** (~5 min). Claude's standing recommendation: hold the PRD no-tutorials line.
- [x] **Pricing at launch - DECIDED 2026-07-26 (Justin): freemium.** Free download, all features; exports carry a small corner Mosaic watermark; a one-time StoreKit 2 non-consumable purchase (com.levelup.mosaic.removewatermark, placeholder $2.99) removes it. B8 pulled into v1 scope; built per the B8 spec (watermark ~4% of long edge, bottom-right, white with dark stroke) with the B28 gear-in-picker settings ingress. Final price set in App Store Connect.
- [x] **The name question (B16) - DECIDED 2026-07-26 (Justin): option (a).** Keep Mosaic as the brand; submit under a compound App Store title such as "Mosaic: Photo Collage & Layout" (exact wording finalized with listing copy). Mitigates the ASO collision with the existing "Mosaic - Video & Photo Collage" (id 633846868) and the photomosaic search cluster. Known residual: trademark risk stays open (13 leading matches per B16); accepted for now.
- [ ] **Accent color** (~10 min) - mockups in `_review/phase7-accent-*.png`. The icon accent should follow this decision.
- [x] **Apple Developer Program + commercial setup - DONE (verified 2026-07-28).** Paid Apps Agreement Active (Jul 27 2026 - Apr 16 2027), Free Apps Agreement Active, Wells Fargo (5742) USD bank account Active, U.S. Form W-9 Active, EU Digital Services Act trader status Active. This was the long pole; the app can now sell the watermark unlock.
- [x] **App Store Connect record - CREATED 2026-07-28.** Apple ID **6795437010**, name **"Mosaic: Photo Collage & Layout"** (the name WAS available and is now reserved), bundle `com.levelup.mosaic`, SKU `mosaic-ios-001`, primary language English (U.S.), iOS only, Full Access. Prerequisite discovered and fixed en route: `com.levelup.mosaic` had never been registered as an explicit App ID (Xcode's automatic signing had not created it), so it was registered in Certificates, Identifiers & Profiles as "Mosaic Photo Collage" under team 6A4J2GTB6F first.
- [ ] **One TestFlight tester besides Justin** (per STATUS checklist).
- [ ] Final pass on reversible decisions B1, B3, B4, B5, B6 (audit lists them; all still look sound).

## Track 3 - Branding (Claude produces, Justin picks)

Direction, grounded in research: every collage competitor (PicCollage, Unfold, Canva, VSCO) is bright, saturated, gradient-heavy and social-coded. Mosaic's dark, quiet, hairline aesthetic is genuine home-screen whitespace, in the Halide/Darkroom lineage. The brand is the app's chrome extended outward.

- Icon: single focal glyph, the asymmetric split-tree layout (one large tile, two stacked), rounded geometry, dark canvas, must read in pure grayscale (iOS tinted mode), built as 2-3 depth layers for Icon Composer. Round 3 candidates generated 2026-07-26 in `_review/icon-gen/raw-r3/`.
- Landing page: DRAFTED 2026-07-26 with the final brand assets and real app screenshots, awaiting Justin's review at https://claude.ai/code/artifact/36f8ece3-f099-4507-881b-383fe363dde7 (Halide/Flighty pattern: hero device mockup, one-line promise, App Store badge, three-feature triptych, anti-feature section). Deploy target TBD (needs a domain decision).
- Featuring pitch (App Store Connect featuring nomination, submit ~3 months pre-launch, not 2 weeks): lead with on-device Vision auto-framing and the narrative "Layout, rebuilt for the Liquid Glass era", founder story, quotable copy. Maps to Apple's stated criteria 3 (innovation) and 4 (uniqueness).

## Track 4 - Store assets (Claude drafts, Justin approves)

- [x] App Store listing: drafted 2026-07-26 in `App Store Listing.md` (title, subtitle, keywords, description, promo text, featuring pitch) - awaiting Justin's review.
- [ ] Screenshots: none exist. Produce a designed set (device frames, captions, dark canvas) from simulator captures.
- [ ] Optional app preview video (later; screenshots first).
- [ ] Privacy nutrition label answers (trivial: no data collected, no tracking, no network) - enter in App Store Connect.
- [x] **Privacy policy + support pages - LIVE 2026-07-28** (both URLs are mandatory listing fields): https://nikolausj1.github.io/mosaic-app-site/privacy.html and https://nikolausj1.github.io/mosaic-app-site/support.html . Repo `nikolausj1/mosaic-app-site` (public, site files only); source of truth also kept in `_site/`. The policy deliberately avoids the absolute "no network calls" claim and discloses that StoreKit and iCloud Photos talk to Apple under Apple's own policy.

## Sequencing

1. Justin: B26 checklist, B27, pricing, name, accent (one sitting, under an hour of active time).
2. Claude: Track 1 fixes in one session; icon round converges in parallel.
3. Claude: listing copy, screenshots, landing page once name + accent are locked.
4. Justin: Developer Program + App Store Connect record; Claude preps all fields.
5. TestFlight build, outside tester, featuring nomination, submit.

## Research digest (for reference)

- Apple HIG app icons: single focal point, no text, must survive 29x29. https://developer.apple.com/design/human-interface-guidelines/app-icons
- Icon Composer / Liquid Glass six variants, layered construction, rounded geometry favored. https://developer.apple.com/videos/play/wwdc2025/361/
- Featuring criteria and self-serve nomination form. https://developer.apple.com/app-store/getting-featured/
- ADA pattern (Denim: Vision cropping; Kino/Halide: first/best at a new platform capability): minimalist UI + one signature interaction + a recent Apple framework used visibly.
- Name collision: https://apps.apple.com/us/app/mosaic-video-photo-collage/id633846868
