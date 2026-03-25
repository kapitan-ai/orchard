# Brand Identity

**Status:** Active  
**Last Updated:** 2026-03-14  
**Adapted from:** `kapitan-orchard/docs/designs/brand-identity.md` (v1 Jinja2/Tauri app)  
**Product name:** Orchard Console

This document defines the Orchard brand identity for the v2 Phoenix LiveView console,
including logo, color palette, dark mode guidance, and visual guidelines.

---

## Overview

Orchard uses a **4-color brand system** (Navy, Forest, Sage, Gold) designed to communicate
both authority ("Kapitan" heritage — command, control plane) and growth ("Orchard" — cultivation,
inference orchestration).

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

### App Icon (Neural Tree)

**Style:** Apple Liquid Glass (updated 2026-03-25, previously flat vector)

A neural tree rendered in translucent glass materials on a navy glass background:
- Forest green (#1B5E20) glass trunk branching upward from a glowing root node
- Sage green (#81C784) frosted glass spherical nodes at branch junctions with soft inner glow
- Three gold (#FDD835) glass spheres at the crown as "fruit" (inference outputs) with specular highlights and warm halos
- Deep navy-to-dark-navy frosted glass background with subtle gradient depth
- Rounded superellipse (squircle) corners
- Bold simplified silhouette designed for legibility at small sizes (32px favicon)

Represents: neural network (AI/inference) + tree (orchard/growth/cultivation)

**Generation details:** FLUX Pro 1.1 via fal.ai, forest green variant, seed 42.
Source prompt and iteration history preserved in `orchard-workbench/notes/`.

### Combined Lockup

**Expanded sidebar / login page:**
Icon on the left, wordmark on the right, vertically center-aligned.

```
┌──────┐
│ 🌳   │  Orchard
└──────┘
```

**Collapsed sidebar:**
Icon only (no text).

```
┌──────┐
│ 🌳   │
└──────┘
```

**Login page (centered):**
Icon above, wordmark below (exception to sidebar rule — login is a centered composition).

```
     ┌──────┐
     │ 🌳   │
     └──────┘
     Orchard
  ████████████   ← brand bar (decorative, below lockup)
```

### Favicon

Use the Liquid Glass neural tree icon at generated sizes. The bold silhouette and
high-contrast gold-on-navy design remains legible at 32x32 and 16x16.

All favicon/PWA assets are regenerated from the 1024×1024 master using `sips`:

```bash
sips -z 32 32 assets/brand/orchard-app-icon-1024.png --out apps/orchard_controller/priv/static/images/favicon-32x32.png
sips -z 180 180 assets/brand/orchard-app-icon-1024.png --out apps/orchard_controller/priv/static/images/apple-touch-icon.png
sips -z 192 192 assets/brand/orchard-app-icon-1024.png --out apps/orchard_controller/priv/static/images/icon-192.png
```

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
    <%# Implementation: inline SVG or <img> referencing /images/... %>
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

---

## Tailwind Integration

Configure in `apps/orchard_controller/assets/tailwind.config.js`:

```javascript
module.exports = {
  theme: {
    extend: {
      colors: {
        // Brand colors (accent/semantic roles)
        navy: {
          DEFAULT: '#1565C0',
          50: '#E3F2FD',
          100: '#BBDEFB',
          400: '#42A5F5',
          600: '#1565C0',
          700: '#0D47A1',
          800: '#0A3A8A',
        },
        forest: {
          DEFAULT: '#1B5E20',
          50: '#E8F5E9',
          100: '#C8E6C9',
          400: '#66BB6A',
          600: '#1B5E20',
          700: '#145A19',
        },
        sage: {
          DEFAULT: '#81C784',
          50: '#F1F8E9',
          100: '#DCEDC8',
          200: '#A5D6A7',
          300: '#81C784',
          400: '#66BB6A',
        },
        gold: {
          DEFAULT: '#FDD835',
          50: '#FFFDE7',
          100: '#FFF9C4',
          300: '#FDE047',
          400: '#FDD835',
          500: '#FBC02D',
        },
      },
      fontFamily: {
        mono: ['"SF Mono"', '"JetBrains Mono"', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'Consolas', 'monospace'],
      },
    },
  },
}
```

> **Note:** Structural slate colors and semantic colors (red, amber, sky, violet) are
> built into Tailwind and don't need to be extended.

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

```
assets/brand/
├── orchard-icon-neural-v5e.svg         # Legacy flat vector icon (v2)
├── orchard-app-icon-1024.png           # Master PNG (1024×1024) — Liquid Glass
├── orchard-logo-medium-transparent.png # Wordmark 200×66
├── orchard-logo-large-transparent.png  # Wordmark 240×76
└── orchard-logo-xlarge-transparent.png # Wordmark 360×112
```

### Web-Served (generated)

```
apps/orchard_controller/priv/static/images/
├── logo-transparent.png    # Wordmark for login/header
├── favicon.png             # 32×32 icon
├── favicon-32x32.png       # 32×32 icon
├── apple-touch-icon.png    # 180×180 icon
└── icon-192.png            # 192×192 PWA icon
```

### Regenerating Web Assets

```bash
# From repo root
sips -z 32 32 assets/brand/orchard-app-icon-1024.png --out apps/orchard_controller/priv/static/images/favicon-32x32.png
sips -z 180 180 assets/brand/orchard-app-icon-1024.png --out apps/orchard_controller/priv/static/images/apple-touch-icon.png
sips -z 192 192 assets/brand/orchard-app-icon-1024.png --out apps/orchard_controller/priv/static/images/icon-192.png
```

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
| Icon generation | `cargo tauri icon` | `sips` (macOS native) | No Tauri dependency |
| Lockup layout | Text above, bar below | Icon left + text right (sidebar) | Vertical space efficiency |

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

- Replaced flat vector neural tree icon (v5e SVG) with Apple Liquid Glass style
- Generated via FLUX Pro 1.1 on fal.ai (forest green variant, seed 42)
- Preserves neural tree motif: trunk → branches → 3 gold fruit spheres
- Tree rendered in translucent forest green glass (brand-faithful #1B5E20)
- Gold spheres with specular highlights and warm halos
- Bold simplified silhouette optimized for favicon legibility at 32px
- Navy frosted glass background with subtle gradient depth
- Works on both light and dark dashboard backgrounds as self-contained squircle
- Evaluated against: Recraft V3 (digital/realistic/vector), FLUX Pro cyan variant,
  warm emerald variants, multiple seed explorations
- Legacy SVG retained as `orchard-icon-neural-v5e.svg` for reference
