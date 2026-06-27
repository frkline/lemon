# Handoff: lemon.living landing page

## Overview
A single-page marketing/introduction site for **Lemon** — a macOS menu-bar app that runs
Claude Code agents against your Linear and GitHub issues, supervised by a local Gemma model,
and remote-controllable from the Claude iOS app. This handoff covers the full restyled
landing page: a warm, meticulous, Apple-HIG-flavoured page that follows the Lemon design
system. The site is **dark-only** (warm-dark glass), locked to match the app — no light/auto
theme, no toggle.

## About the Design Files
`lemon.living.html` in this bundle is a **design reference created in HTML** — a working
prototype that shows the intended look, copy, and behavior. It is **not** meant to be shipped
verbatim. Recreate it in the target codebase using that project's established environment and
patterns. If the marketing site has no framework yet, a static site is the right call here:
plain HTML/CSS (or Astro / 11ty / a single React route) all fit. The page is intentionally
dependency-free — system fonts + CSS + inline SVG. The reference keeps one tiny inline
`<script>` solely to clone the `<template>` body (a prototype DRY affordance); there is **no**
theme script. The shipped port (`docs/index.html`) inlines the sections directly and ships
**zero** JavaScript.

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
- One document, `max-width: 1180px`, centered on a full-viewport warm-dark background.
- In the reference, the page body lives once inside `<template id="page">` and is cloned into
  `<main id="pageRoot">` by a tiny inline script. If you move to a component framework, just
  author the sections normally — the template indirection exists only to keep the prototype DRY.
  (The shipped `docs/index.html` already inlines the sections directly, no template, no script.)
- `data-screen-label="lemon.living"` is on the page root (a prototype affordance; drop it).

## Theme (dark-only)
A single **Midnight** (warm-dark glass) palette, driven by CSS custom properties on `:root`
and locked unconditionally. The site is **dark-only** to stay coherent with the dark-glass
app — a light marketing page would read as a different product than the warm-dark tool it
sells. There is **no** light/auto theme, no nav toggle, no `data-theme` attribute, and no
`prefers-color-scheme` swap.

```css
:root { color-scheme:dark; /* Midnight — the only palette */ }
```

`<meta name="color-scheme" content="dark">` in `<head>` plus `color-scheme:dark` on `:root`
ensure UA form controls and scrollbars render dark.

> Note: the rebuilt **app UI** (menu-bar popover, supervisor console, install terminal,
> connection tiles) is the warm-dark glass surface — it depicts the real app over a desktop.
> The **phone** mock is **light** because it depicts the real Claude iOS app. Those are fixed
> surface treatments, independent of (and unaffected by) the page being dark-only.

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

### Midnight (the only palette — dark-only)
```
--pageSolid:#15100a;
--page: radial-gradient(125% 80% at 12% -8%, #2f2740 0%, #201a13 42%, #15100a 100%);
--ink:#ECE6D8;  --ink2:rgba(236,230,216,.66);  --ink3:rgba(236,230,216,.42);  --ink4:rgba(236,230,216,.26);
--hair:rgba(236,230,216,.12);  --hair2:rgba(236,230,216,.07);
--panel:rgba(255,255,255,.028);  --panelRing:rgba(255,255,255,.08);  --panelHi:rgba(255,255,255,.05);
--chipBg:rgba(236,230,216,.06);   --chipRing:rgba(236,230,216,.12);
--appShadow:0 30px 70px rgba(0,0,0,.55);
--accentText:#F7C842;   /* the gold italic in the closing manifesto */
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
1. **Nav** — brand (🍋 + "Lemon"), 3 links (The loop / How it works / Setup), "GitHub ↗" ghost button. (No theme toggle — the site is dark-only.)
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
- **Theme:** dark-only, no toggle (see Theme above).
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
- `screenshots/` — rendered reference images. **Note:** `01`–`05` were captured in the
  retired light theme and are now stale; `06` (dark hero) reflects the shipped dark-only look.
  Re-capture `01`–`05` in dark when convenient.
  - `01-lemon.png` — hero (stale light capture; site now ships the dark hero, see `06`)
  - `02-lemon.png` — Orchestrator section + menu-bar popover
  - `03-lemon.png` — Remote control + Claude iOS phone
  - `04-lemon.png` — Built on (2×2 technical cards)
  - `05-lemon.png` — closing manifesto
  - `06-lemon.png` — hero (Midnight / dark — the shipped look)
- Source design system (for deeper component/material specs): the Lemon Design System project,
  `ui_kits/lemon/*.html` (color, typography, materials, motion, popover-root, session-row, etc.).
