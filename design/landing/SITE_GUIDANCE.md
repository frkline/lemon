# CLAUDE.md — lemon.living (marketing site)

Guidance for working in the **lemon.living** landing-page repo. This is the public
introduction site for Lemon, the macOS menu-bar app that orchestrates Claude Code against
your Linear/GitHub work, supervised by a local Gemma model and remote-controlled from the
Claude iOS app.

## What this site is
A single, meticulous, Apple-HIG-flavoured page. It follows the **Lemon Design System** and
is **dark-only** — warm-dark glass, locked to match the app (an unapologetically warm-dark
menu-bar tool). Warm, quiet, dense-but-breathing. Marketing copy is confident and
understated — never hypey.

## Visual rules (from the Lemon ethos — keep these)
1. **Material over stroke.** Depth = blur + fill opacity. Hairlines are 0.5px. Never heavier borders.
2. **Warm, not cold.** Every neutral is pulled toward amber. Dark mode is warm-dark, never gunmetal.
3. **Color is earned.** Lemon-yellow is spent on exactly one primary action per surface. Status
   lives in a single dot — never a filled pill, never a left accent bar.
4. **Machine truth in mono.** SF Mono for IDs, paths, specs, console output. SF Pro for everything human.
5. **Quiet by default, loud when it matters.** Only a live agent or a failure raises its voice.

## Theme system
- **Dark-only.** The site ships a single **Midnight** (warm-dark glass) palette as CSS custom
  properties on `:root`, locked unconditionally. There is **no** light/auto theme, no toggle,
  no `data-theme` attribute, and no `prefers-color-scheme` swap. `<meta name="color-scheme"
  content="dark">` + `color-scheme:dark` on `:root` so UA controls/scrollbars render dark.
- This is deliberate: brand coherence with the dark-glass app. A light marketing page would
  read as a different product than the warm-dark tool it's selling.
- The embedded **app UI** surfaces (popover, console, terminal, connection tiles) are warm-dark
  glass; the **phone** mock is **light** (it depicts the Claude iOS app, which is light). Those
  are fixed surface treatments, unrelated to any page theme.

## Tokens
Full token tables live in `design_handoff_lemon_living/README.md`. Quick reference:
- Brand: `--lemon #F7C842`, `--coral #FF6B46`, `--citrus #2D4A1E`, `--lemondrop #FEF4CC`.
- Accent (manifesto gold italic): `--accentText` = `#F7C842`.
- Canvas: `--pageSolid #15100a` (warm near-black) under a warm radial `--page` gradient.
- Neutrals are **one hue** stepped by opacity off `#ECE6D8`: ink / ink2 (.66) / ink3 (.42) / ink4 (.26).
- Console surface is opaque `#17110A` (not glass).
- Type: SF Pro Text (humans) + SF Mono (machines). Nothing below 10px; body ≥13px.

## Type & layout
- `max-width: 1180px`, centered. Page gutter 84px. Section padding 96px (`.band`).
- **No horizontal section dividers** — separation is by whitespace only.
- Display headings carry tight negative tracking (-.9 to -2px); the all-caps eyebrow is the one
  exception (+1.8px), as a quiet section marker.

## Do / Don't
- **Do** lift exact token values; keep status as dot+label; keep one lemon CTA per surface.
- **Do** keep entrance animations transform-only and reduced-motion-gated (content must never
  depend on JS/animation to become visible — matters for PDF/print/background tabs).
- **Don't** introduce new hues, a fifth radius, gradients-as-decoration, or emoji beyond 🍋.
- **Don't** add filler sections or stat-slop. Every element earns its place.

## Unverified content — confirm before launch
These are **placeholders** in the current page; replace with real values:
1. **Gemma checkpoint** — "Built on → MLX + Gemma" + hero/supervisor say "Gemma · 4-bit · MLX"
   with no version. Fill in the real checkpoint. Do not invent one.
2. **Setup commands** — the Setup terminal shows `brew install …` / `lemon setup …` as
   placeholders. Replace with the real install flow (`.dmg`, Homebrew cask, TestFlight…).

## Copy tone
Quiet, confident, concrete. Lead with the value, name the machinery plainly (Claude Code,
Gemma, MLX, Linear, GitHub, git worktrees, Claude iOS app, MCP). The page closes on the
manifesto — "That's it. That's the whole pitch." Keep that as the last word.
