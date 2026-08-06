---
title: "Photo Collage - Project Instructions"
created: 2026-07-24
modified: 2026-07-26
version: 1.3
author: Claude Sonnet 5 (claude-sonnet-5)
tags:
---

# Photo Collage

Parent standards and the Oracle system are defined in `_Projects/CLAUDE.md` (inherited; read it). Key project docs: `PRD.md` is the source of truth for scope and decisions.

## Oracle Reporting Contract

This project is tracked by Oracle, a portfolio agent at the `_Projects` root that rolls up all project statuses into `_Projects/_Oracle/PORTFOLIO.md`. Your obligations:

1. Keep `STATUS.md` at this project's root current. At the end of any session with meaningful progress, decisions, or new blockers, refresh it before finishing.
2. Follow the Oracle Status Format defined in `_Projects/CLAUDE.md` exactly. Update the front matter `modified` date and bump `version` on every edit.
3. Keep the Ideas Shelf stocked: 2 to 5 self-contained backlog items sized S / M / L that Justin could pick up for fun.
4. Never delete `STATUS.md`. If parking the project, set Stage to Paused and note why.
5. Oracle trusts `STATUS.md` completely. It does not inspect code or git. An inaccurate status means Justin gets a wrong portfolio picture.
6. Edits to `STATUS.md` marked "updated via Oracle at Justin's direction" are legitimate and authoritative: Justin dictated them at the portfolio level. Reconcile them with the backlog at session start; do not revert them.
7. Share what you learn. When this project discovers a reusable technique, fix, or better workflow that other projects could benefit from (environment-level, not project-specific design), record it briefly in an optional `## Lessons` section at the bottom of `STATUS.md`, below the divider. Oracle reviews these every run and promotes vetted ones into the shared Project Build Guide. The master guide at `_Projects/_Templates/Project Build Guide.md` is authoritative; if this folder contains its own older copy, prefer the master and its Changelog.


## Branches: what goes where

Two long-lived branches. They are not "current" and "future" - `next` is a
SUPERSET of `main`, and it should stay that way.

- **`main`** is what ships. It is always in a state you would be willing to
  submit.
- **`phase3-handover`** (the "Mosaic Next" build) is the proving ground. It
  carries everything in `main` plus whatever is being judged. Its bundle ID is
  `com.levelup.mosaic.next` and its display name is "Mosaic Next", so it
  installs ALONGSIDE the real app on Justin's phone rather than replacing it.

### The rule

> If you would need to see it running to know whether it is right, it goes to
> Next. If it is unambiguously correct, it goes to `main`.

Put another way: if I am wrong about this, do I want it on the App Store?

**To Next:** anything you have to feel (animation, pacing, timing); anything
that changes composition, especially the `framingCost` weights, since only
Justin's eye can say whether the output got better; dev tooling that must
never ship; and genuine experiments where "this turned out to be wrong" is an
acceptable result.

**To `main`:** submission work; crashes and correctness bugs where there is no
taste question; small polish with an obvious right answer; the name change.

### Merge direction is one-way

- **`main` -> Next: merge freely**, and do it often. That is what keeps Next a
  superset and stops the testbed drifting behind.
- **Next -> `main`: cherry-pick only, NEVER a straight merge.** Next carries
  three standing commits that must never reach the App Store: the bundle-ID
  and display-name change, the "Capture this collage" feedback tool, and the
  `LayoutPolicy` override that keeps the canvas ratio decision live (main
  ships square-only auto layout as of 2026-08-05; the eagerness question is
  being settled by eye on Next during the hero retune). A full merge would
  drag all of them into the shipping binary.

### After a commit graduates, REBUILD Next rather than merging

Cherry-picking a commit from Next to `main` and then merging `main` back into
Next produces a duplicate: Next has the original, `main` has the copy, and any
file touched by both conflicts messily. This has already happened once.

The fix is not to resolve that merge. It is to rebuild Next:

```
git branch -f next-backup phase3-handover     # safety net
git checkout -B phase3-handover main
git cherry-pick -x <bundle-id commit> <capture commit> <layout-policy commit>
```

Next is only ever `main` plus its standing never-ship commits, so re-deriving
it is cheap and leaves the invariant provably intact. Check it afterwards:
`git log --oneline main..phase3-handover` should show exactly those standing
commits, and `git log --oneline phase3-handover..main` should be empty. (Last
rebuilt this way 2026-08-05, when the animation-pacing experiment graduated
to `main` and the `LayoutPolicy` override joined the standing set.)

### The rule that stops `main` rotting

**A bug found while testing Next, in code both branches share, gets fixed on
`main` and merged down.** Never patched on Next alone.

Almost everything in Next is shared code. Justin will be looking at Next when
he finds things, so this is easy to get wrong, and the failure mode is quiet:
`main` keeps a bug that was already fixed, and ships with it.

### Other branches

- `fix/framing-cost-aspect-units` - the units bug in `framingCost`. Real, but
  it changes every collage containing a face and breaks four smoke assertions
  that encode the old numbers, so it lands as part of the weight retuning
  rather than on its own.
