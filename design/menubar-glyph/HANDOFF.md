# Handoff: Lemon Menu Bar Glyph

## Overview
The menu bar status glyph for **Lemon**, a macOS menubar companion that runs Claude coding agents. This package specifies a single template icon with two primary states — **idle** (no agent running) and **in‑use** (an agent is working) — plus four secondary status states (waiting, done, error, disabled). The mark is a stylized lemon (body + leaf + vein), drawn from a real vector so it stays crisp at the 18px size macOS renders menu bar items.

## About the Design Files
The files in this bundle are **design references created in HTML/SVG** — prototypes showing the intended look and behavior, not production code to ship directly. The task is to **implement this glyph in Lemon's real codebase** using its established environment and patterns.

For a macOS menu bar app this almost certainly means:
- An **`NSStatusItem`** whose `button.image` is set to one of the provided SVG/PDF assets.
- Mark the image as a **template image** (`image.isTemplate = true`) so AppKit tints it automatically for light/dark menu bars and for the highlighted (clicked) state. **Do not** bake color into the asset.
- Swap the button's image when agent state changes (see *State Management*).

The provided **SVG files in `assets/` are the source of truth for the artwork.** If the build pipeline prefers PDF or multi‑resolution PNG (@1x/@2x) for template images, rasterize/convert from these SVGs at the sizes below — the geometry is resolution‑independent.

## Fidelity
**High‑fidelity.** Final geometry, proportions, stroke weights, and state treatments. Recreate the artwork exactly from the supplied SVG paths. The only thing that should change in implementation is *format* (SVG → PDF/PNG template asset as the toolchain requires) and *color* (left to the system via template tinting).

## The Glyph — Construction
The mark is built from three real vector paths in a **1024×1024** coordinate space (the source artwork is `assets/lemon-source.svg`):

- **Body** — the lemon silhouette (with two small sprig nubs).
- **Leaf** — a symmetric lens shape sitting over the top‑left shoulder.
- **Vein** — a short line down the leaf center.

Two render modes produce the two primary states from the *same* paths:
- **Idle = outline.** Stroke the body, leaf, and vein. The body stroke is masked where the leaf sits so the leaf reads as separate.
- **In‑use = solid.** Fill the union of body + leaf through a mask; the leaf is separated from the body by a **knockout moat** (a transparent stroked gap) and the vein is knocked out as a thin transparent line.

The **leaf gap ("moat")** is a single value — the stroke width of the knockout path (`44` in 1024‑space at default). Leaf separation, stroke weight, and tilt are all driven by numbers, never hand‑redrawn.

### Geometry constants (1024×1024 space)
- Body path `d`: see `assets/lemon-idle.svg` / `lemon-working.svg` (identical path string in both).
- Leaf transform: `translate(-40 -70) rotate(-18 448 185)`.
- Vein: `M448.43 185.61 h150`.
- Idle stroke width: `34` (1024‑space). General formula used in the prototype: `strokeWidthPx = strokeWeight(pt) × 20`, default `strokeWeight = 1.7pt` → `34`.
- Knockout moat width: `44` (1024‑space).
- Vein knockout width (solid state): `26` (1024‑space).

## States
The app toggles the status item image between these. The two the product requires are **Idle** and **In‑use**; the rest are optional status affordances.

| State | Asset | Treatment |
|---|---|---|
| **Idle** | `lemon-idle.svg` | Outline lemon. Nothing running. |
| **In‑use** | `lemon-working.svg` | Solid lemon. An agent is actively working. |
| **Waiting** | `lemon-waiting.svg` | Solid lemon + bottom‑right circular badge with a **?** (agent needs input). |
| **Done** | `lemon-done.svg` | Solid lemon + badge with a **✓** (run finished). |
| **Error** | `lemon-error.svg` | Solid lemon + badge with a **✗** (run failed). |
| **Disabled** | `lemon-disabled.svg` | Outline lemon at 40% opacity (paused/disabled). |

### Badge geometry (1024×1024 space)
- Badge center: `(792, 792)`, radius `188`.
- Transparent separator ring around the badge: width `76` (i.e. a knockout circle of radius `188 + 76`).
- Symbol stroke widths: check `62`, cross `58`, question mark `56` + a filled dot (r `34`).
- In a real template image the badge disc is opaque ink and the ring + symbol are **transparent** (they punch through to the bar behind). This is already how the SVGs are authored (`currentColor` fill + `mask` knockouts).

## Sizing
- macOS renders menu bar icons at roughly **18×18 pt**. Provide the template asset sized for that, plus @2x.
- The artwork is authored in a 1024 viewBox and scales down cleanly; it was verified legible at 18px, 36px, and large sizes.
- Recommended exports if PNGs are needed: 18×18 (@1x), 36×36 (@2x), 54×54 (@3x is unused on macOS but harmless).

## State Management
- One enum drives the icon, e.g. `enum LemonStatus { idle, working, waiting, done, error, disabled }`.
- On status change, set `statusItem.button?.image = NSImage(named: <asset for status>)` and keep `image.isTemplate = true`.
- Suggested transitions (wire to the agent runtime; not visual):
  - `idle → working` when a run starts.
  - `working → waiting` when the agent blocks on user input.
  - `working → done` on success; `working → error` on failure.
  - `done/error/waiting → idle` (or `→ working`) when acknowledged / next run starts.
  - `disabled` when the app is paused or no workspace is connected.
- **Optional polish (in‑use):** the prototype shows a subtle "breathing" opacity pulse on the solid lemon while working (`opacity 1 → 0.62 → 1`, ~2.4s ease‑in‑out). This is decorative; on macOS you'd animate the button's `alphaValue` or layer opacity if desired. Not required.

## Color
This is a **template image** — it carries no color. AppKit tints it (white/black) to match the menu bar and the clicked/highlighted state. The brand palette is only relevant if you ever render the lemon *outside* the menu bar (e.g. in a popover):

## Design Tokens (brand — Lemon design system)
Use only if rendering the mark in colored UI; the menu bar glyph itself stays template/monochrome.
- `--lemon` `#F7C842` — primary brand yellow (one element per surface)
- `--lemondrop` `#FEF4CC` — soft highlight
- `--coral` `#FF6B46` — stop / destructive / waiting
- `--citrus` `#2D4A1E` — ink on top of lemon
- `--primary` (ink) `#ECE6D8` — primary text/icon on dark surfaces
- Console surface `#17110A`; warm‑glass chrome `rgba(33,27,17,·)`
- Status dot colors: planning `#6197FA`, executing `#F7C842`, waiting `#FF6B46`, reviewing `#66C78F`, done `#45C27A`, failed `#F24545`
- Menu bar dark ink reference used in the spec preview: `#1C1610`

## Assets
All in `assets/`:
- `lemon-idle.svg`, `lemon-working.svg`, `lemon-waiting.svg`, `lemon-done.svg`, `lemon-error.svg`, `lemon-disabled.svg` — the six state template images (`viewBox 0 0 1024 1024`, `currentColor`).
- `lemon-source.svg` — the original multi‑layer lemon vector the geometry was lifted from (provided by the product team).

All state SVGs use `fill="currentColor"` and SVG `mask` for the knockouts, making them valid macOS template images as‑is.

## Files (design references)
- `Lemon Glyph - Final.dc.html` — the committed spec sheet for the glyph (hero states, true‑size menu bar previews, full state set, build notes). This is the canonical visual reference.
- `Menubar Glyph.dc.html` — the exploration canvas (the "before" plus 7 directions); included for context on why this direction was chosen. Direction 07 ("Leaf‑top") is the committed mark.

> Note: the `.dc.html` files are interactive design components. Open them in a browser to view. They are references — implement the glyph as native menu bar template assets, not by embedding HTML.
