# Glance — Brand & Icon Guidelines

## Concept: Focal Frame
Two staggered architectural window planes framing a chamfered Steel Sapphire focus card in negative space. Built on a `256 × 256` geometric grid with a `20`-unit negative-space moat and `16 px` small-size cut.

## Master Files (`Assets/LogoKit/`)
- **Symbol (Light UI):** `glance-symbol-color.svg`
- **Symbol (Dark UI):** `glance-symbol-on-dark.svg`
- **Small Cut (`≤ 24 px` / Menu Bar):** `glance-symbol-small.svg`, `MenuBarTemplate.png`, `MenuBarTemplate@2x.png`
- **Lockups:** `glance-horizontal-color.svg`, `glance-horizontal-on-dark.svg`, `glance-stacked-color.svg`
- **macOS App Icon:** `glance-app-icon-tile.svg`, `AppIcon.icns`
- **One-Colour & Web Exports:** `exports/` (`black`, `white`, `mono-4b83db`, `square`, `favicon.ico`, `site.webmanifest`)

## Colour Palette
| Role | Light Surfaces | Dark Surfaces / HUD |
|---|---|---|
| Rear Plane (Titanium) | `#6E7788` | `#7B8598` |
| Active Frame | `#12151C` | `#DCE6F5` (Platinum Ice) |
| Focus Card (Accent) | `#4B83DB` | `#7DA8ED` (Steel Sapphire) |
| App Tile Surface | — | `#0E1015` (Obsidian) |

## Clear Space & Minimum Size
- **Clear space:** Maintain at least `24 px` (on the `256` grid, matching the frame wall width) around the mark on all sides.
- **Minimum size:** `16 px` digital (use `glance-symbol-small.svg` / `MenuBarTemplate`), `32 px` for horizontal lockups (`glance-horizontal-*`).

## Misuse to Avoid
- Do not add traffic-light dots or drop-shadows inside the negative-space moat.
- Do not place the light-mode `#12151C` frame directly on dark backgrounds; always switch to `glance-symbol-on-dark.svg` or `glance-white.svg`.
