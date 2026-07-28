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

