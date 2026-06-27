# Handoff: lemon.living landing page

## Overview
A single-page marketing/introduction site for **Lemon** — a macOS menu-bar app that runs
Claude Code agents against your Linear and GitHub issues, supervised by a local Gemma model,
and remote-controllable from the Claude iOS app. This handoff covers the full restyled
landing page: a warm, meticulous, Apple-HIG-flavoured page that follows the Lemon design
system and adapts to system light/dark.

## About the Design Files
`lemon.living.html` in this bundle is a **design reference created in HTML** — a working
prototype that shows the intended look, copy, and behavior. It is **not** meant to be shipped
verbatim. Recreate it in the target codebase using that project's established environment and
patterns. If the marketing site has no framework yet, a static site is the right call here:
plain HTML/CSS (or Astro / 11ty / a single React route) all fit. The page is intentionally
dependency-free (one small inline `<script>` for the theme toggle + template clone) so it
ports cleanly to almost anything.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, radii, shadows, and interactions are all
specified below and present in the HTML. Recreate pixel-faithfully, lifting the exact token
values. The only deliberately-unfinished pieces are two copy placeholders flagged under
**Open items** — do not treat those as final.

## Open items (must confirm before launch)
1. **Gemma checkpoint.** The "Built on → MLX + Gemma" card and the hero/supervisor copy say
   "Gemma · 4-bit · MLX" without a version. Replace with the real checkpoint (e.g. the exact
   Gemma 3 variant) once known. Do not invent a version.
2. **Install / setup flow.** The "Setup" section's terminal block shows `brew install …` and
   `lemon setup …` as **placeholders**. Confirm the real distribution (notarized `.dmg`,
   Homebrew cask, TestFlight, etc.) and replace the commands. Don't ship the fabricated CLI.

## Structure & build
- One document, `max-width: 1180px`, centered on a full-viewport themed background.
- The page body lives once inside `<template id="page">` and is cloned into
  `<main id="pageRoot">` by the inline script. If you move to a component framework, just
  author the sections normally — the template indirection exists only to keep the prototype DRY.
- `data-screen-label="lemon.living"` is on the page root (a prototype affordance; drop it).

## Theme system (light / dark)
Two themes driven by CSS custom properties on `:root`. **Daylight** (warm paper) is the
default and the light-system look; **Midnight** (warm-dark glass) applies when the OS is in
dark mode **or** the user forces it. A manual choice always wins.

```css
:root { /* Daylight — default */ }
@media (prefers-color-scheme: dark){ :root:not([data-theme="light"]){ /* Midnight */ } }
:root[data-theme="dark"]  { /* Midnight (forced) */ }
:root[data-theme="light"] { /* Daylight (forced) */ }
```

The nav toggle cycles **Auto → Light → Dark**, persisted in `localStorage["lemon-theme"]`
(values: `auto` | `light` | `dark`; `auto` removes the `data-theme` attribute). Icon is an
inline SVG (half-circle / sun / moon) with a `title` tooltip.

> Note: the rebuilt **app UI** (menu-bar popover, supervisor console, install terminal,
> connection tiles) is **always the warm-dark glass surface** regardless of page theme — it
> depicts the real app over a desktop. The **phone** mock is **always light** because it depicts
> the real Claude iOS app. Only the surrounding marketing page swaps light/dark.

## Design tokens

### Brand & semantic (theme-independent)
| Token | Hex | Use |
|---|---|---|
| `--lemon` | `#F7C842` | Primary action / brand. One per surface. |
| `--lemondrop` | `#FEF4CC` | Soft highlight. |
| `--coral` | `#FF6B46` | Stop / waiting. |
| `--citrus` | `#2D4A1E` | Ink on top of lemon (the only dark-on-yellow). |
| `--linearMark` | `#9DA4F5` | Linear favicon glyph. |
| `--githubMark` | `#F2EFE9` | GitHub favicon glyph (app UI only). |
| status planning | `#6197FA` | dot only |
| status executing | `#F7C842` | dot only |
| status waiting | `#FF6B46` | dot only |
| status reviewing | `#66C78F` | dot only |
| status done | `#45C27A` | dot only |
| status failed | `#F24545` | dot only |
| `--console` | `#17110A` | Opaque terminal/console surface. |
| `--consoleText` | `#E8E0CC` | Console text. |

### Daylight (light, default)
```
--pageSolid:#EFE7D6;
--page: radial-gradient(125% 80% at 12% -8%, #FCF8F0 0%, #F4EEE0 46%, #ECE3D0 100%);
--ink:#241D12;  --ink2:rgba(40,32,18,.64);  --ink3:rgba(40,32,18,.44);  --ink4:rgba(40,32,18,.26);
--hair:rgba(40,32,18,.13);
--panel:rgba(255,255,255,.56);  --panelRing:rgba(40,32,18,.09);
--chipBg:rgba(40,32,18,.05);     --chipRing:rgba(40,32,18,.10);
--appShadow:0 34px 80px rgba(40,28,8,.30);
--accentText:#B07E1A;   /* the gold italic in the closing manifesto */
```

### Midnight (dark, system or forced)
```
--pageSolid:#15100a;
--page: radial-gradient(125% 80% at 12% -8%, #2f2740 0%, #201a13 42%, #15100a 100%);
--ink:#ECE6D8;  --ink2:rgba(236,230,216,.66);  --ink3:rgba(236,230,216,.42);  --ink4:rgba(236,230,216,.26);
--hair:rgba(236,230,216,.12);
--panel:rgba(255,255,255,.028);  --panelRing:rgba(255,255,255,.08);
--chipBg:rgba(236,230,216,.06);   --chipRing:rgba(236,230,216,.12);
--appShadow:0 30px 70px rgba(0,0,0,.55);
--accentText:#F7C842;
```

### Typography
- **SF Pro Text** for humans: `-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif`
- **SF Mono** for machine truth (IDs, paths, console, specs): `"SF Mono", ui-monospace, Menlo, monospace`
- Scale (display sizes carry tight tracking):
  - Hero `h1` — 58px / 700 / -2px / line-height .96
  - Hero kicker (`.herokick`) — 25px / 600 / -.6px
  - Section `h2` — 36px / 700 / -.9px
  - Closing manifesto (`.pitch-q h2`) — 60px / 700 / -1.6px; the quoted clause is italic in `--accentText`
  - `.lead` — 18.5px / 400 / ink2
  - `.sub` — 15.5px / ink2
  - `.eyebrow` — 11px / 700 / +1.8px tracking / UPPERCASE / ink3, with a 6px `--lemon` dot
  - Body in cards — 13–14px; spec/meta mono — 10.5–11px
- Minimum shipped size 10px (machine IDs only); body text ≥13px.

### Spacing / shape
- Page gutter: `84px` left/right. Section vertical padding: `96px` (`.band`).
- **No horizontal section dividers** — sections are separated by padding alone (a `.rule`
  class exists but is `display:none`; remove the empty divs when you re-author).
- Radii in use: 9 / 11 / 12 / 13 / 14 / 16–18px. Buttons: 11px, height 46px.
- Hairlines are 0.5px (`inset 0 0 0 .5px …`), never heavier borders — depth comes from material
  (blur + fill opacity), per the Lemon ethos.

## Sections / views (in order)
1. **Nav** — brand (🍋 + "Lemon"), 3 links (The loop / How it works / Setup), theme toggle (icon), "GitHub ↗" ghost button.
2. **Hero** — eyebrow; `h1` "Claude Code, no cruft."; kicker "Built for the Mac mini on your desk."; lead; two CTAs (primary lemon "Download for Apple silicon" + ghost "View source"); mono fineprint. Right: a **macOS desktop product shot** (`.macscene`) — warm wallpaper, a translucent menu bar (Apple logo only on the left; status icons + active 🍋 status item + clock on the right), the Lemon **popover dropping from the lemon status item** (notch + ~10px wallpaper gap below the bar), and a dock. The shot bleeds off the right page edge.
3. **The Loop** — band-head + 4 numbered steps (01 tag with 🍋 / 02 watch live / 03 step in / 04 ship). Human-in-the-loop framing; step 01 notes each agent runs in its own **git worktree**.
4. **Orchestrator** — copy + featlist left; rebuilt **menu-bar popover** right.
5. **Connect everything** — band-head + a wrap of **connection tiles** (Linear teams + GitHub repos + "Add a source"), proving multi-tracker/multi-repo.
6. **Remote control** — copy + featlist left; **Claude iOS app** phone mock right (light; floating pill top bar "Review Lemon PR…" / "lemon"; assistant message with mono spans; "Diff +1227" / "View PR" chips; "Add feedback…" composer with "</> Accept edits", attach, mic, peach send button).
7. **Supervisor** — copy + on-device strip left (Gemma on MLX); **console card** right (Gemma reviewing a diff, pausing for a human).
8. **Recursive mode** — "Let Claude monitor Lemon." band-head; a 2-up grid: a console (Claude querying Lemon over MCP) + a "What Claude can do" capability card.
9. **Built on** — "None of this is from scratch." 2×2 technical cards (Claude Code / MLX + Gemma / SwiftUI + AppKit / Linear + GitHub), each with a mono `.spec` line.
10. **Setup** — copy + **terminal card** (PLACEHOLDER commands — see Open items).
11. **Is / Isn't** — two cards ("Personal workflow tooling" vs "An AI service") with check / × markers.
12. **The Point (closing)** — the manifesto: big "The point isn't *“Claude, but in a menu bar.”*" with the quote italic in `--accentText`, plus the editorial body ending "That's it. That's the whole pitch."
13. **Footer** — brand, `lemon.living` mono, links.

## Interactions & behavior
- **Theme toggle:** Auto → Light → Dark, persisted (see Theme system).
- **Hero entrance:** one staggered rise on load (`transform: translateY` only — *no opacity fade*, so content is never hidden in print/PDF/background tabs/reduced-motion). Gated on `@media (prefers-reduced-motion: no-preference)`.
- **Live status dot:** the one allowed continuous loop — a soft pulse on an executing agent's dot, reduced-motion-gated.
- **Hover/selection** in the app UI swaps *material* (blur + fill), not color.
- Anchors/links are non-functional placeholders (`href="#"`); wire to real routes/downloads.

## Component recipes (lift from the HTML)
- **Status** = colored dot + neutral label. Never a filled pill, never a left accent bar.
- **Source mark** = favicon tile (Linear = light-purple diagonal glyph on purple tile; GitHub = cat silhouette). Never a text badge. In the page light tiles, the GitHub glyph uses `var(--ink)` for contrast.
- **Materials:** thin (resting) → regular (hover/selected) → thick (popover root, casts the only shadow) → opaque (console `#17110A`). Recipes are in the Lemon design system / `CLAUDE.md`.

## Assets
- **Lemon mark:** the 🍋 emoji (per the design system). No custom logo file.
- **Apple logo / macOS status glyphs / phone status & composer icons:** inline SVGs in the HTML (generic, not branded assets). Replace with the host platform's real icon set if available.
- **Linear / GitHub glyphs:** inline SVGs (from the Lemon design system `source-glyph` card).
- No raster images or fonts are bundled; everything is system fonts + CSS + inline SVG.

## Files
- `lemon.living.html` — the full design reference (this bundle).
- `CLAUDE.md` — repo guidance for the marketing site (drop at the site repo root).
- `screenshots/` — rendered reference images:
  - `01-lemon.png` — hero (Daylight / light)
  - `02-lemon.png` — Orchestrator section + menu-bar popover
  - `03-lemon.png` — Remote control + Claude iOS phone
  - `04-lemon.png` — Built on (2×2 technical cards)
  - `05-lemon.png` — closing manifesto
  - `06-lemon.png` — hero (Midnight / dark)
- Source design system (for deeper component/material specs): the Lemon Design System project,
  `ui_kits/lemon/*.html` (color, typography, materials, motion, popover-root, session-row, etc.).
