# Lemon Design System

A faithful, self-contained HTML mirror of Lemon's visual language. Each file in
`ui_kits/lemon/` is one preview card — open any of them in a browser to see a
surface rendered with the real `LD.*` tokens over a warm-dark menubar-popover
backdrop. This is the human-readable companion to the source of truth,
`app/Lemon/LemonDesign.swift`.

It is also synced to a **Claude Design** project (claude.ai/design):
`projectId: dfaaaca4-3ca6-46e6-b4bd-f11312794011` ("Lemon Design System").

## The ethos (seven principles)

Captured in full in `ui_kits/lemon/ethos.html`. In short:

1. **Material over stroke** — depth comes from glass + blur, never a heavier border.
2. **Warm, not cold** — every neutral is pulled toward amber/citrus; dark that belongs beside a lemon.
3. **Color is earned** — lemon-yellow is reserved for the single primary action; state lives in one small dot.
4. **Machine truth in mono** — SF Mono = verbatim from Linear/GitHub/the agent; SF Pro = the human voice.
5. **Width-stable identity** — fixed-size source marks; a session list never reflows when a status flips.
6. **Quiet by default, loud when it matters** — a resting row whispers; only a live agent or failure raises its voice.
7. **Built for the corner** — assumes a ~340pt popover in the top-right; high density, ≥28pt hit targets.

## Layout

| Group | Cards |
|---|---|
| **Foundations** | `ethos`, `color`, `typography`, `spacing`, `materials`, `motion` |
| **Components** | `status-pill`, `source-glyph` |
| **Chrome** | `popover-root`, `session-row` |
| **Settings** | `settings-panels`, `pair-row` |
| **Editors** | `editor-panes` |

Each card's group/name/subtitle live in its first-line `<!-- @dsCard … -->`
marker, which the Claude Design pane indexes on.

## Viewing

```sh
open design/ui_kits/lemon/popover-root.html   # or any other card
```

No build step, no dependencies — every card is a standalone HTML file with
inline CSS.

## Syncing with Claude Design

Round-trips through the `DesignSync` tool / `/design-sync` skill. This directory
**is** the sync layout, so use it as the local dir:

- **Push** local → remote: `/design-sync` with `localDir: design/`, writes glob
  `ui_kits/lemon/*.html`, project `dfaaaca4-3ca6-46e6-b4bd-f11312794011`.
- **Pull** remote → local: export the project zip from claude.ai/design and
  unzip its `ui_kits/lemon/` over this directory.

Sync **one component at a time**; never wholesale-replace. Remote edits made in
the Design pane win — pull before you push so you don't clobber them.

## Landing page (`design/landing/`)

The revamped **lemon.living** marketing site, designed against this system.

- `lemon.living.html` — the high-fidelity HTML design reference (prototype; the
  shipped page is `docs/index.html`).
- `README.md` — the full handoff: tokens, theme system, section-by-section spec.
- `SITE_GUIDANCE.md` — visual rules / do's & don'ts for the site (the handoff's CLAUDE.md).
- `screenshots/01–06-lemon.png` — rendered references (hero light/dark, orchestrator,
  remote control, built-on, manifesto).

The live site is served from `docs/` (GitHub Pages, CNAME `lemon.living`). When
porting the reference to `docs/index.html`: move the `<template>` body into the
DOM so it renders without JS, drop the `data-screen-label` affordance, keep only
the theme-toggle script, and confirm the two flagged placeholders (Gemma
checkpoint, install commands) against real values before shipping.

## Notes

- **Fonts.** Lemon has no custom brand font — its type *is* the Apple system
  stack (SF Pro Text / SF Pro Rounded / SF Mono). Non-Apple renderers (incl. the
  Claude Design pane) can't load SF and substitute, which is cosmetic to the
  preview only; the real macOS app renders genuine SF. This is why the Design
  pane shows a "missing brand fonts" notice — it's expected, not a defect.
- **These cards mirror the Liquid Glass direction from PR #17** (`LemonGlass`
  modifier), which may still be unmerged. Regenerate from the branch that holds
  the current chrome if the app's design drifts from these previews.
