# Brand Identity

**Status:** Active  
**Last Updated:** 2026-05-20
**Adapted from:** `kapitan-orchard/docs/designs/brand-identity.md` (v1 Jinja2/Tauri app)  
**Product name:** Orchard Console

This document defines the Orchard brand identity for the v2 Phoenix LiveView console,
including logo, color palette, dark mode guidance, and visual guidelines.

---

## Overview

Orchard uses a **4-color brand system** (Navy, Forest, Sage, Gold) designed to communicate
both authority ("Kapitan" heritage — command, control plane) and growth ("Orchard" — cultivation,
LLM orchestration, governance, and future fine-tuning).

In the v2 console, brand colors serve **semantic and accent roles** rather than structural ones.
Structural elements (backgrounds, cards, borders) use a neutral gray/slate scale for data-dense
readability. Brand colors draw the eye to meaningful state: active navigation, success/warning
states, and primary actions.

---

## The Palette

### Brand Colors (Semantic / Accent)

| Role | Name | Hex | Usage |
|------|------|-----|-------|
| **Primary** | Navy | `#1565C0` | Active nav, primary buttons, headers, links |
| **Secondary** | Forest | `#1B5E20` | Success/healthy states, positive badges |
| **Tertiary** | Sage | `#81C784` | Success backgrounds (low opacity), subtle highlights |
| **Accent** | Gold | `#FDD835` | CTAs, important badges, attention draws |

### Structural Colors (Backgrounds, Cards, Borders)

Use Tailwind's `slate` scale for all structural elements:

| Element | Light Mode | Dark Mode |
|---------|------------|----------|
| Page background | `slate-50` (#F8FAFC) | `slate-900` (#0F172A) |
| Card/surface | `white` | `slate-800` (#1E293B) |
| Elevated surface | `white` + shadow | `slate-700` (#334155) |
| Border | `slate-200` (#E2E8F0) | `slate-700` (#334155) |
| Primary text | `slate-900` (#0F172A) | `slate-50` (#F8FAFC) |
| Secondary text | `slate-500` (#64748B) | `slate-400` (#94A3B8) |
| Disabled text | `slate-300` (#CBD5E1) | `slate-600` (#475569) |

### Utility / Semantic Colors

| Role | Light | Dark | Usage |
|------|-------|------|-------|
| Error | `red-600` (#DC2626) | `red-400` (#F87171) | Errors, destructive actions |
| Warning | `amber-500` (#F59E0B) | `amber-400` (#FBBF24) | Warnings, degraded states |
| Info | `sky-500` (#0EA5E9) | `sky-400` (#38BDF8) | Informational badges, links |
| Processing | `violet-500` (#8B5CF6) | `violet-400` (#A78BFA) | AI generation, in-progress states |

> **Note:** Gold (`#FDD835`) is reserved for brand CTAs. Use Amber for warnings to avoid
> semantic confusion between "pay attention" (warning) and "take action" (CTA).

### Dark Mode Mapping

Brand colors shift luminosity for dark backgrounds while preserving hue identity:

| Brand Color | Light Mode | Dark Mode | Rationale |
|-------------|-----------|-----------|----------|
| Navy | `#1565C0` | `#38BDF8` (sky-400) | Navy vanishes on dark bg; shift to bright readable blue |
| Forest | `#1B5E20` | `#4ADE80` (emerald-400) | Dark green invisible; shift to vivid luminous green |
| Sage | `#81C784` | `#1E293B` (slate-800) | Sage becomes elevated surface color, not accent |
| Gold | `#FDD835` | `#FDE047` (yellow-300) | Brighten slightly to pop on dark |

### Brand Bar

The 4-color brand bar is a **standalone decorative element**, not part of the logo lockup:

```
┌────────┬────────┬────────┬────────┐
│  Navy  │ Forest │  Sage  │  Gold  │
└────────┴────────┴────────┴────────┘
```

**Recommended usage:**
- 2-3px gradient line at the top edge of the browser viewport
- Active-state bottom border on main navigation tabs
- Login page accent below the logo lockup
- **Not** as part of the logo/wordmark itself

---

## Logo & Lockup

### Product Name

The product is **Orchard Console**. The parent brand "Kapitan" is not surfaced in the UI.

- Full name: "Orchard Console" (documentation, about pages)
- Short name: "Orchard" (logo, nav, casual reference)
- Console suffix: used in page titles (e.g., `<title>Orchard Console — Overview</title>`)

### Wordmark

"Orchard" in monospace bold, Navy color:
- Font: `ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace`
- Weight: 700 (bold)
- Color: Navy (`#1565C0` light / `#38BDF8` dark)
- Letter-spacing: tight (`-0.02em`)

### Logo Mark (Grove Focal)

**Style:** foreground-only geometric SVG mark, no plate or background.

The canonical Orchard mark is a 3×3 grove/grid of circular nodes:
- Eight small Forest nodes (`#1B5E20` light / `#4ADE80` dark) arranged at x/y positions 12, 32, and 52 in a 64×64 viewBox
- One larger Gold focal node (`#FDD835` light / `#FDE047` dark) centered in the top row at `cx=32`, `cy=12`, `r=6`
- No navy squircle, glass plate, drop shadow, or raster-only background
- Designed to read as a clean foreground glyph on both light and dark UI surfaces, closer to the surface-independent behavior of the Claude and ChatGPT marks

Represents: a cultivated model/governance/orchestration matrix with one ripe focal output. The warm orchard metaphor leads; orchestration and governance are reinforced by surrounding copy, UI context, and optional motion states rather than extra lines inside the mark.

Per-circle SVG fills are written as direct `fill=` presentation attributes for portability across embeds and tooling that may strip style blocks. CSS in the Console stylesheet and inside the standalone SVG continues to drive theme and animation behavior; CSS `fill` rules win over presentation attributes by specificity. The standalone SVG intentionally retains its internal `<style>` and `@media (prefers-color-scheme: dark)` block so favicon and `<img>` usages can adapt to OS dark mode, even though app-level forced theme cannot control an external SVG document.

**Design source:** Claude Design handoff, `Kapitan Orchard Logo Design`, final user-selected direction: original Grove Focal. The user explicitly preferred it over the later Grove Lanes sharpening.

### Combined Lockup

**Expanded sidebar / login page:**
Foreground Grove mark on the left, wordmark on the right, vertically center-aligned.

```
  ● ● ●  Orchard
  ● ● ●
  ● ● ●
```

The top-center node is Gold and larger than the Forest nodes.

**Collapsed sidebar:**
Mark only (no text).

```
  ● ● ●
  ● ● ●
  ● ● ●
```

**Login page (centered):**
Mark above, wordmark below (exception to sidebar rule — login is a centered composition).

```
     ● ● ●
     ● ● ●
     ● ● ●
     Orchard
  ████████████   ← brand bar (decorative, below lockup)
```

#### Login / marketing voltage variant

`:voltage` enlarges the Gold focal dot to `r=7` for centered Login compositions, marketing hero blocks, and release-page surfaces. The canonical product mark (sidebar, favicon, lockups) stays at `r=6`.

### Favicon

Use the foreground Grove Focal SVG as the primary favicon:

```html
<link rel="icon" type="image/svg+xml" href="/images/orchard-mark.svg">
```

The SVG includes light/dark color declarations for browsers that honor `prefers-color-scheme` inside SVG documents. PNG fallbacks remain available for legacy browser and platform surfaces:

| Asset | Purpose | Notes |
|-------|---------|-------|
| `/images/orchard-mark.svg` | Primary favicon / reusable foreground mark | Canonical Grove Focal SVG; no background plate |
| `/images/favicon-32x32.png` | Alternate 32px favicon fallback | Legacy raster fallback |
| `/images/apple-touch-icon.png` | Apple touch icon | Legacy raster platform asset |
| `/images/icon-192.png` | 192px PWA/manifest-style fallback | Legacy raster platform asset |

Do not regenerate the canonical mark from a raster master. Update `orchard-mark.svg` and the Phoenix component SVG together when changing the mark geometry.

### Phoenix LiveView Component

The logo will be implemented as a Phoenix function component (replacing the v1 Jinja2 macro):

```elixir
defmodule OrchardWeb.Components.Logo do
  use Phoenix.Component

  @doc """
  Renders the Orchard logo lockup.

  ## Attributes
  - `size` - :sm (24px icon), :md (32px icon), :lg (48px icon). Default :md.
  - `variant` - :lockup (icon + text), :icon (icon only), :login (centered, stacked). Default :lockup.
  - `class` - additional CSS classes.
  """
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :variant, :atom, default: :lockup, values: [:lockup, :icon, :login]
  attr :class, :string, default: ""

  def logo(assigns) do
    ~H"""
    <%# Implementation: inline foreground Grove Focal SVG mark; no image plate. %>
    """
  end
end
```

---

## Typography

| Role | Font | Weight | Usage |
|------|------|--------|-------|
| UI labels, body | System sans-serif (`Inter` or `system-ui`) | 400/500 | Navigation, descriptions, table cells |
| Headings | System sans-serif | 600/700 | Page titles, section headers |
| Brand/logo | Monospace (`SF Mono`, `JetBrains Mono`) | 700 | "Orchard" wordmark only |
| Data/metrics | Monospace | 400/500 | Token counts, latency, request IDs, FSM states |
| Code/logs | Monospace | 400 | Log streams, JSON payloads, error details |

**Key rule:** Monospace for data, sans-serif for UI. Never mix in the same element.

---

## Design Principles (v2 Console)

1. **Neutral structure, brand accents** — Gray/slate for layout, brand colors for meaning
2. **Data density over decoration** — Operators want information, not illustration
3. **High contrast states** — Active/healthy/error states must be instantly distinguishable
4. **Monospace for machine data** — Token counts, request IDs, latency always monospace
5. **Restraint over variety** — Fewer colors, sharper hierarchy, cleaner borders
6. **LiveView-native interactions** — No page reloads; use transitions for state changes

### Theme Mode Preference

Console users may choose System (default), Light, or Dark from the sidebar theme control. System follows the operating-system color scheme, while Light and Dark pin the Console independently. The brand-color luminosity mapping is unchanged: Navy, Forest, Sage, Gold, and structural slate tokens keep the same light/dark roles defined below.

---

## Tailwind Integration

Tailwind v4 is bound in `apps/orchard_controller/assets/css/app.css` via
`@import "tailwindcss"`, the `@theme` block, and `@source` declarations for
Console `.ex` / `.heex` files. The `@theme` block is the implementation source
of truth for custom Orchard brand tokens.

| Token | Hex | Source | Usage |
|-------|-----|--------|-------|
| `navy` / `navy-600` | `#1565C0` | `@theme` | Primary brand, active nav, primary buttons, links |
| `navy-50` | `#E3F2FD` | `@theme` | Low-emphasis primary tint |
| `navy-100` | `#BBDEFB` | `@theme` | Primary tint |
| `navy-400` | `#42A5F5` | `@theme` | Light primary accent |
| `navy-700` | `#0D47A1` | `@theme` | Darker primary emphasis |
| `navy-800` | `#0A3A8A` | `@theme` | Deep primary emphasis |
| `forest` / `forest-600` | `#1B5E20` | `@theme` | Secondary brand, success/healthy states |
| `forest-50` | `#E8F5E9` | `@theme` | Success tint |
| `forest-100` | `#C8E6C9` | `@theme` | Success tint |
| `forest-300` | `#81C784` | `@theme` | Mid success accent |
| `forest-400` | `#66BB6A` | `@theme` | Success accent |
| `forest-700` | `#145A19` | `@theme` | Dark success emphasis |
| `forest-900` | `#0A290B` | `@theme` | Deep success emphasis |
| `sage` / `sage-300` | `#81C784` | `@theme` | Tertiary brand, subtle highlights |
| `sage-50` | `#F1F8E9` | `@theme` | Highlight tint |
| `sage-100` | `#DCEDC8` | `@theme` | Highlight tint |
| `sage-200` | `#A5D6A7` | `@theme` | Highlight tint |
| `sage-400` | `#66BB6A` | `@theme` | Highlight accent |
| `gold` / `gold-400` | `#FDD835` | `@theme` | CTA accent, important badges |
| `gold-50` | `#FFFDE7` | `@theme` | Accent tint |
| `gold-100` | `#FFF9C4` | `@theme` | Accent tint |
| `gold-300` | `#FDE047` | `@theme` | Light accent |
| `gold-500` | `#FBC02D` | `@theme` | Strong accent |
| `slate-50` | `#F8FAFC` | Tailwind built-in | Page background, primary dark text inverse |
| `slate-100` | `#F1F5F9` | Tailwind built-in | Control rail and disabled light surfaces |
| `slate-200` | `#E2E8F0` | Tailwind built-in | Light borders |
| `slate-300` | `#CBD5E1` | Tailwind built-in | Disabled light text |
| `slate-400` | `#94A3B8` | Tailwind built-in | Secondary dark text |
| `slate-500` | `#64748B` | Tailwind built-in | Secondary light text |
| `slate-600` | `#475569` | Tailwind built-in | Disabled dark text |
| `slate-700` | `#334155` | Tailwind built-in | Dark borders, elevated dark surfaces |
| `slate-800` | `#1E293B` | Tailwind built-in | Dark card/surface |
| `slate-900` | `#0F172A` | Tailwind built-in | Dark page background, primary light text |

> **Note:** Structural slate colors and semantic colors (red, amber, sky, violet) are
> built into Tailwind and don't need to be extended. The mono font stack is also
> declared in `app.css` under `--font-mono`.

---

## Accessibility

### Contrast Ratios

| Combination | Ratio | WCAG | Use For |
|-------------|-------|------|---------|
| Navy on white | 4.9:1 | AA | Body text, buttons |
| Forest on white | 7.2:1 | AAA | Body text, badges |
| White on Navy | 4.9:1 | AA | Button text |
| White on Forest | 7.2:1 | AAA | Button text |
| slate-900 on white | 15.4:1 | AAA | Primary body text |
| slate-500 on white | 4.6:1 | AA | Secondary text |
| Gold on Navy-700 | 8.1:1 | AAA | Highlighted text |

### Color Blindness

- Navy and Forest are distinguishable in deuteranopia (green-blind)
- Gold provides high contrast for all color vision types
- Critical information is never conveyed by color alone (use icons/labels)
- Error red and Forest green are differentiated by iconography, not just hue

---

## Asset Files

### Source Files (in repo)

The canonical web mark is stored with the served Console assets so Phoenix can serve it directly and tests can assert the exact browser path:

```
apps/orchard_controller/priv/static/images/
└── orchard-mark.svg        # Canonical foreground Grove Focal SVG
```

Legacy raster/vector assets may remain in the repository for historical reference and platform fallbacks, but they are not the canonical logo contract.

### Web-Served Assets

```
apps/orchard_controller/priv/static/images/
├── orchard-mark.svg        # Primary SVG favicon and reusable foreground mark
├── favicon.png             # Legacy 32×32 PNG fallback
├── favicon-32x32.png       # Legacy 32×32 PNG fallback
├── apple-touch-icon.png    # Legacy 180×180 platform fallback
├── icon-192.png            # Legacy 192×192 platform fallback
└── logo-transparent.png    # Legacy raster wordmark asset
```

### Updating Web Assets

Update `orchard-mark.svg` directly for SVG/favicon changes. Keep the inline SVG in `OrchardConsole.CoreComponents.logo/1` geometrically identical to `orchard-mark.svg`. Regenerate PNG fallbacks only when a platform surface specifically requires updated raster assets.

---

## Decision History

### v1 → v2 Changes

| Aspect | v1 (kapitan-orchard) | v2 (Orchard Console) | Rationale |
|--------|---------------------|---------------------|----------|
| Product name | Kapitan Orchard | Orchard Console | Standalone product identity |
| Brand bar | Part of logo lockup | Standalone decorative element | Cleaner lockup, more product-grade |
| Sage role | Card backgrounds, borders | Success highlight (low opacity) | Sage overwhelms data-dense UIs |
| Structure colors | Brand colors for structure | Neutral slate scale | Data readability in operator console |
| Dark mode | Not defined | Full dark mode mapping | Console may be used in dim environments |
| Template engine | Jinja2 macros | Phoenix function components | LiveView architecture |
| Icon generation | `cargo tauri icon` | Foreground inline SVG + SVG favicon | Surface-independent mark; no raster master required |
| Lockup layout | Text above, bar below | Mark left + text right (sidebar) | Vertical space efficiency |

### v1 Palette Decision (Preserved)

The 4-color palette was selected through a multi-agent review evaluating:
1. Pure Orchard (rejected: brown dated for tech)
2. Tech-Forward (rejected: too generic, no accent)
3. Kapitan (rejected: too many colors)
4. **Tech Kapitan (selected):** Navy → greens → gold (best balance)

Refined from 5 to 4 colors by removing mid-green (#43A047) overlap.

### v2 Adaptations (Gemini Design Review, 2026-03-14)

- Demoted brand colors from structural to semantic/accent roles
- Added neutral slate scale for data-dense UI readability
- Added dark mode luminosity-shift mapping
- Added Amber for warnings (distinct from Gold CTA)
- Added Violet for AI processing/generation states
- Changed lockup to icon-left + text-right for sidebar efficiency
- Moved brand bar to standalone decorative element
- Added typography rules: monospace for data, sans-serif for UI

### v3 Icon Refresh — Liquid Glass (2026-03-25)

- Historical icon refresh that replaced the flat vector neural tree icon with a self-contained Liquid Glass squircle
- Retained only as legacy design history after the 2026-05-20 foreground-mark refresh

### v4 Logo Refresh — Grove Focal (2026-05-20)

- Replaced the self-contained dark/glass icon plate with a foreground-only SVG mark
- Selected the original Grove Focal direction from the Claude Design handoff after comparing Grove, Bloom, and Grove Lanes variants
- Preserves the Orchard cultivation metaphor while broadening beyond inference into LLM orchestration, governance, and future fine-tuning
- Uses a 3×3 dot grid: Forest nodes plus a single larger Gold focal node in the top center
- Designed to work on light and dark UI surfaces without a background plate
- Implemented as inline SVG in `OrchardConsole.CoreComponents.logo/1` plus primary SVG favicon at `/images/orchard-mark.svg`
- Optional motion states (`heartbeat`, `cascade`, `harvest`) are CSS-only and disabled under reduced-motion preferences
