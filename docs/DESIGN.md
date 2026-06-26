# DESIGN.md — Orchard Console Tactical UI Contract

**Status:** Active (v2)
**Last Updated:** 2026-05-11
**Audience:** AI coding agents and contributors generating or modifying Console UI.

This document is the tactical, component-level design contract for the Orchard
Console v2 LiveView UI. It covers visual rules an agent must follow before
emitting Tailwind classes, HEEx markup, or component changes.

**It is downstream of [`docs/brand-identity.md`](brand-identity.md).** The brand document is the
authority for palette, typography, dark/light mapping, wordmark, and brand-bar.
Anything in this document that appears to conflict with `docs/brand-identity.md`
is wrong and must be revised — brand identity wins.

---

## 1. Authority Ladder

When generating or reviewing Console UI, follow this order. Higher-numbered
documents may not contradict lower-numbered ones.

1. **`SPEC.md`** — normative product/build contract. Architecture, milestones,
   API surface, persistence, runtime adapters. Governs *what* exists.
2. **`AGENTS.md`** — agent contribution rules: single-repo source-of-truth,
   LiveView conventions, mise-backed quality workflow (`mix format` /
   `compile` / `credo` / `dialyzer` / `test` / `test --cover`), commit style,
   secret handling.
   Governs *how* changes are introduced.
3. **`docs/brand-identity.md`** — palette (Navy / Forest / Sage / Gold + slate
   structural scale + semantic red/amber/sky/violet), dark/light luminosity
   mapping, typography (mono for data, sans for UI), wordmark, brand bar,
   logo lockup, accessibility contrast targets. Governs *brand semantics*.
4. **`docs/DESIGN.md` (this file)** — tactical UI execution: surfaces,
   elevation, input states, sidebar rail, density, motion, focus, the
   `@class` merge rule. Governs *visual mechanics* only inside the limits
   set by the docs above.

If a tactical decision is not specified here, default to the closest analog
already in `core_components.ex` and `app.html.heex`. Do not invent new
structural tokens, color shades, or font families — see *§9 The `@class`
Merge Rule* and *§11 Out of Scope*.

---

## 2. Surfaces & Elevation

The Console has a small, fixed surface vocabulary. Every element must map
to one of these surfaces. Do not introduce intermediate shades.

| Surface          | Light                  | Dark                              | Where it appears |
|------------------|------------------------|-----------------------------------|------------------|
| Page canvas      | `bg-slate-50`          | `bg-slate-900`                    | `<main>` content area. |
| Control rail     | `bg-slate-100`         | `bg-slate-800`                    | Sidebar (`<aside id="console-sidebar">`). Distinct panel against the canvas. |
| Card / panel     | `bg-white`             | `bg-slate-800`                    | Page header, content cards, dialogs. |
| Elevated card    | `bg-white shadow-sm`   | `bg-slate-700`                    | Modals, popovers, hover-elevated rows. (v2 has no popover system; this row reserves the slot.) |
| Recessed well    | `bg-slate-50` + inner shadow | `bg-slate-900/60` + inner shadow | Form inputs, code/log embeds. See *§4 Form Inputs*. |

**Hierarchy (light):** canvas (slate-50) **→** card (white) is one step *up*;
canvas (slate-50) **→** rail (slate-100) is one step *down* (recessed panel);
card (white) **→** input well (slate-50) is one step *down within the card*.

**Hierarchy (dark):** canvas (slate-900) **→** card (slate-800) is one step
*up*; canvas (slate-900) **→** rail (slate-800) is also one step *up*; card
(slate-800) **→** input well (slate-900/60) is one step *down within the card*.

**Borders:** all surface boundaries use `border-slate-200` (light) /
`border-slate-700` (dark). Do not introduce alternative border shades.

**Shadows:** surface elevation never uses Tailwind's `shadow-md` or larger in
v2. `shadow-sm` is the only outward elevation token. `shadow-inner` is
reserved for the recessed well surface (inputs).

---

## 3. Color Roles (Quick Reference)

This section is a derived quick-reference. **Authoritative values live in
`docs/brand-identity.md`**.

| Role            | Light         | Dark          | Allowed uses |
|-----------------|---------------|---------------|--------------|
| Primary brand   | `navy`        | `sky-400`     | Active nav text/icon, primary buttons, primary focus rings, links. |
| Success         | `forest`      | `emerald-400` | Healthy/success badges and copy. Never as a focus ring. |
| Highlight       | `sage` (low opacity only) | `slate-800` (elevated surface) | Subtle success highlights only. Never as text on white. |
| CTA accent      | `gold`        | `yellow-300`  | Reserved for explicit brand CTAs. Never for warnings, focus, or hover states. |
| Error           | `red-600` text / `red-500` input border | `red-400` | Field error message text + input border/ring state. Overrides hover/focus styling. |
| Warning         | `amber-500`   | `amber-400`   | Warning badges. Never confused with Gold CTA. |
| Info / focus-dark | `sky-500`   | `sky-400`     | Informational badges; dark-mode focus ring, dark-mode link/active brand color. |
| Processing      | `violet-500`  | `violet-400`  | AI generation / in-progress indicators only. |

**Hard rules (from `docs/brand-identity.md`):**

- Structural surfaces are slate-tonal. Brand colors are accents.
- Monospace is for data (token counts, request IDs, latency, FSM states).
  Sans-serif for UI labels and prose. Do not mix in one element.
- Critical state is never conveyed by color alone; pair with icon, label, or
  shape.

---

## 4. Form Inputs (the Tactile Well)

The Console's shared text-like inputs, selects, and textareas
(`apps/orchard_controller/lib/orchard/console/core_components.ex`, `input/1`
clauses for `text | email | password | number | search | url | tel | date |
time | month | week | color | range | select | textarea`) render as
**tactile editable wells**. They share one surface treatment and one state
model. The checkbox and hidden variants are out of scope here.

### 4.1 State Model

Every well has these states. Each state has an exact set of class tokens.

| State                   | Trigger |
|-------------------------|---------|
| Rest                    | Default visual. |
| Hover                   | Pointer over the field, no focus, no error. |
| Focus-visible           | Keyboard or programmatic focus that meets `:focus-visible`. |
| Error                   | `@errors != []` from the `<.input>` component. Wins over hover and focus border colors. |
| Disabled                | `disabled` attribute is set. Non-interactive, dimmed. |
| Read-only               | `readonly` attribute is set. Looks dimmed but copy-selectable. |
| Placeholder             | Empty value with `placeholder` text. |

### 4.2 Authoritative Class Strings — Text-like / Select / Textarea

The default `input/1` clause, the `select` clause, and the `textarea` clause
compose the well from three class groups: a size-aware always-on base, a
neutral visual state used only when `@errors == []`, and the error state used
only when `@errors != []`. Tactility comes from border/surface/shadow/ring.

Do **not** emit the neutral visual state group when `@errors != []`.
Tailwind v4 CSS ordering is not guaranteed to follow HTML class order, so
appending red classes after neutral classes is insufficient: generated neutral
border or ring color rules can still win. The component must avoid conflicting
neutral border, hover, focus-border, and focus-ring color utilities in the
error state.

**Always-on well base (`size={:md}`, default):**

```
mt-1 block w-full rounded-md text-sm
border bg-slate-50 text-slate-900 shadow-inner
placeholder:text-slate-400
focus-visible:outline-none
focus-visible:ring-2
focus-visible:ring-offset-2 focus-visible:ring-offset-white
disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-400
read-only:bg-slate-100 read-only:text-slate-500
dark:bg-slate-900/60 dark:text-slate-100
dark:placeholder:text-slate-500
dark:focus-visible:ring-offset-slate-900
dark:disabled:bg-slate-800/40 dark:disabled:text-slate-500
dark:read-only:bg-slate-800/40 dark:read-only:text-slate-400
```

**Always-on well base (`size={:lg}`):**

```
mt-1 block w-full rounded-md text-base px-3 py-2
border bg-slate-50 text-slate-900 shadow-inner
placeholder:text-slate-400
focus-visible:outline-none
focus-visible:ring-2
focus-visible:ring-offset-2 focus-visible:ring-offset-white
disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-400
read-only:bg-slate-100 read-only:text-slate-500
dark:bg-slate-900/60 dark:text-slate-100
dark:placeholder:text-slate-500
dark:focus-visible:ring-offset-slate-900
dark:disabled:bg-slate-800/40 dark:disabled:text-slate-500
dark:read-only:bg-slate-800/40 dark:read-only:text-slate-400
```

**Neutral visual state group (`@errors == []` only):**

```
border-slate-300 hover:border-slate-400 focus-visible:border-navy focus-visible:ring-navy/40
dark:border-slate-700 dark:hover:border-slate-600 dark:focus-visible:border-sky-400 dark:focus-visible:ring-sky-400/40
```

### 4.3 Authoritative Class String — Error State

The error class is emitted when `@errors != []`. It is paired with the
always-on well base above and must be mutually exclusive with the neutral
border group. This keeps the invalid field red regardless of rest, hover, or
focus state and avoids Tailwind v4 ordering conflicts.

```
border-red-500 ring-1 ring-red-500/30
focus-visible:border-red-500 focus-visible:ring-red-500/40
dark:border-red-400 dark:ring-red-400/30
dark:focus-visible:border-red-400 dark:focus-visible:ring-red-400/40
```

### 4.4 Label and Error Message

`label/1` (in `core_components.ex`) renders as:

```
block text-sm font-medium text-slate-700 dark:text-slate-300
```

`field_errors/1` renders error rows as:

```
mt-1 space-y-1
```

…with each error `<p>` styled:

```
text-xs text-red-600 dark:text-red-400
```

These match the existing `core_components.ex` definitions and stay unchanged
in v2 unless a parity adjustment is required to remain legible against the
new well surface. Any such change must keep error text at `red-600`/`red-400`.

### 4.5 Checkbox (Reference Only — Visuals Not Refreshed in v2)

The checkbox variant uses its own visual class set (`h-4 w-4 rounded …`). v2 does not modify its visual styling. Shared form accessibility behavior still applies: errored checkbox inputs should expose `aria-invalid`, associate visible errors through `aria-describedby`, and render the same field-error text treatment. If a future revision adds tactile visual parity, it must be added here as a new subsection.

### 4.6 Input Sizing and Density

`<.input>` accepts `size={:md | :lg}` for text-like inputs, selects, and
textareas. Checkbox and hidden inputs do not use this visual sizing contract.

- `:md` is the default and preserves the prior baseline: `mt-1 block w-full
  rounded-md text-sm` plus the shared well surface/state tokens above. It does
  not add explicit `px-*` or `py-*` utilities.
- `:lg` is for high-signal composer/search controls and emits
  `text-base px-3 py-2` instead of `text-sm`. It must not emit both `text-sm`
  and `text-base`.
- Native HTML `size` is intentionally shadowed by the component-level atom
  attribute and is not passed through by `<.input>`. If a future callsite needs
  the native HTML width/count behavior, introduce an explicit `native_size`
  attribute rather than reusing `size`.
- `<input type="search">` keeps the same well treatment as text inputs.
  Do not use the bare `appearance-none` Tailwind reset unless explicitly
  required by a UA glitch — `core_components.ex` does not currently use it.

### 4.7 Optional CSS Escape Hatch

A single Tailwind-utility-equivalent class name is reserved for a future escape hatch *only* if the combination above cannot be expressed cleanly in pure utilities for some input variant: `.console-input-well`. v2 does not define or use this class in `apps/orchard_controller/assets/css/app.css`; it remains a reserved name, not an implemented selector. Any custom CSS for input wells beyond this reserved escape hatch is out of scope.

---

## 5. Sidebar / Control Rail

The sidebar (`<aside id="console-sidebar">` in
`apps/orchard_controller/lib/orchard/console/layouts/app.html.heex`) reads
as a **distinct slate control panel** against the page canvas. The collapse
mechanism (`JS.toggle_class("sidebar-collapsed", to: "#console-shell")`,
widths `16rem` ↔ `4.5rem`, transitions in `app.css`) is unchanged in v2.

### 5.1 Authoritative Class String — Rail Container

Apply to the `<aside id="console-sidebar">` element in `app.html.heex`:

```
flex flex-col overflow-hidden
bg-slate-100 border-r border-slate-200
dark:bg-slate-800 dark:border-slate-700
```

Notes:

- Rail is `slate-100` in light (one step *down* from `slate-50` canvas) and
  `slate-800` in dark (one step *up* from `slate-900` canvas). This delivers
  the tactile-panel reading in both modes.
- `<main>` retains `bg-slate-50 dark:bg-slate-900` in v2 — do not change it.
- The `border-r border-slate-200 dark:border-slate-700` divider remains the
  single source of the rail/canvas boundary. Do not add a second
  `shadow-*` or `ring-*` divider in v2.
- Footer chrome inside the rail (license badge, version, collapse button)
  keeps its existing classes, including the badge wrapper's `bg-slate-50
  dark:bg-slate-900/60`. The badge now reads as a tinted chip *inside* the
  recessed rail; this is intended.

### 5.2 Sidebar Nav Items (`sidebar_nav/1`)

Defined in `core_components.ex`. The base classes apply to both the link
and the disabled span variants:

**Base (always applied):**

```
flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium
transition-colors
focus-visible:outline-none
focus-visible:ring-2 focus-visible:ring-navy/40
focus-visible:ring-offset-2 focus-visible:ring-offset-slate-100
dark:focus-visible:ring-sky-400/40
dark:focus-visible:ring-offset-slate-800
```

**Active (`item.key == @active`) — contained, brand-tinted:**

```
bg-navy/10 text-navy ring-1 ring-inset ring-navy/15
dark:bg-sky-400/10 dark:text-sky-400 dark:ring-sky-400/20
```

`ring-inset` keeps the active highlight contained inside the
`rounded-md` so it never bleeds into adjacent items.

**Inactive enabled (link):**

```
text-slate-600 hover:bg-white hover:text-slate-900
dark:text-slate-400 dark:hover:bg-slate-700/60 dark:hover:text-slate-100
```

The hover surface is `bg-white` in light and `bg-slate-700/60` in dark,
producing a clear "lifted tile" against the recessed rail.

**Disabled (non-interactive span):**

```
text-slate-400 cursor-default
dark:text-slate-600
```

Disabled items keep their `aria-disabled="true"` (when not active) and
`title="<label> — coming soon"` from the existing `sidebar_nav/1`
implementation. Do not add hover styling to the disabled span.

### 5.3 Collapse Behavior (Unchanged)

- The `sidebar-label`, `console-sidebar-version`, and `sidebar-toggle-icon`
  rules in `app.css` (`#console-sidebar { width / min-width }`,
  `.sidebar-collapsed` overrides, reduced-motion media query) are not
  modified in v2.
- The icon column at `h-5 w-5 flex-shrink-0` is kept on every nav item so
  collapsed-state alignment continues to work.
- Active `aria-current="page"` is set by `sidebar_nav/1` and must remain.

---

## 6. Density & Spacing

- Vertical rhythm between a label and its field is `mt-1`.
- Vertical rhythm between fields in a form is the form-level `space-y-*`
  on the parent (existing `<.simple_form>` defaults). Inputs do not add
  margin-bottom themselves.
- Form group radius is `rounded-md` (6px). Cards/panels keep their
  existing radii (`rounded-lg` where already set). Do not introduce
  `rounded-xl` or `rounded-2xl` in v2.
- Sidebar nav row padding is `px-3 py-2`. Do not change in v2.

### 6.1 Page Width Modes

Console pages may opt into one of these layout width modes by assigning
`page_mode` in their LiveView mount, for example
`assign(socket, :page_mode, :workspace)`. If no mode is assigned, the app shell
uses `:standard` and keeps the default wrapper token-equivalent to the
pre-v2 layout.

| Mode | Width/alignment contract | Intended use |
|------|--------------------------|--------------|
| `:standard` | Centered, `mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6`. Default. | Most Console pages. |
| `:wide` | Centered, `mx-auto max-w-[96rem] px-4 sm:px-6 lg:px-8 py-6`. | Pages that need more horizontal room but still read as documents. |
| `:workspace` | Full canvas after the sidebar, `max-w-none px-6 sm:px-8 lg:px-10 py-6`, left-aligned. | IDE-like operational workspaces. |
| `:detail` | Reserved. Currently falls back to `:standard` in `OrchardConsole.Layouts.page_content_class/1` until a detail-page rollout updates this contract. | Future dense detail pages when narrower line length improves scanning. |

Page title typography is mode-aware through
`OrchardConsole.Layouts.page_title_class/1`:

| Mode | Title class contract |
|------|----------------------|
| `:standard` | `text-lg font-semibold text-slate-900 dark:text-slate-100`. Default; token-equivalent to the pre-v2 title. |
| `:wide` | `text-xl font-semibold text-slate-900 dark:text-slate-100`. |
| `:workspace` | `text-xl font-semibold text-slate-900 dark:text-slate-100`. |
| `:detail` | Reserved. Currently falls back to `:standard`. |

### 6.2 Card Variants

`<.card>` accepts `variant={:default | :primary | :secondary | :rail}`.
The default variant is token-equivalent to the pre-v2 card root, title, and
subtitle classes. Variants compose root/title/subtitle classes inside
`OrchardConsole.CoreComponents.card/1`; callers must not recreate these tokens
with ad-hoc `@class` overrides.

| Variant | Root class contract | Title class contract | Subtitle class contract | Intended use |
|---------|---------------------|----------------------|-------------------------|--------------|
| `:default` | `rounded-lg border border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800` | `text-base font-semibold text-slate-900 dark:text-slate-100` | `mt-1 text-sm text-slate-500 dark:text-slate-400` | Standard content cards and current default behavior. |
| `:primary` | `rounded-lg border border-slate-200 bg-white shadow-sm ring-1 ring-navy/10 dark:border-slate-700 dark:bg-slate-800 dark:ring-sky-400/20` | `text-base font-semibold text-navy dark:text-sky-400` | `mt-1 text-sm text-slate-500 dark:text-slate-400` | High-signal panels that need subtle brand emphasis without changing surface vocabulary. |
| `:secondary` | `rounded-lg border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-900/40` | `text-base font-semibold text-slate-900 dark:text-slate-100` | `mt-1 text-sm text-slate-500 dark:text-slate-400` | Softer full-width strips or supporting panels against the page canvas. |
| `:rail` | `rounded-lg border border-slate-200 bg-slate-100/70 dark:border-slate-700 dark:bg-slate-900/50` | `text-sm font-semibold text-slate-900 dark:text-slate-100` | `mt-1 text-xs text-slate-500 dark:text-slate-400` | Cards embedded in a control/diagnostic rail where denser hierarchy is needed. |

### 6.3 Shared Metric and Detail Primitives

Console pages use four shared primitives from
`OrchardConsole.CoreComponents` for summary metrics and labeled detail values.
Callers own the surrounding layout and any product-specific composition; these
primitives own the visual contract below.

#### `metric_tile/1`

`<.metric_tile>` accepts `label`, `value`, `tone`, `density`, optional `id`,
and additive `class`. Callers must pass a display-ready value string or value
that renders as display-ready text (for example, already run through
`format_integer/1` or `format_duration/1`).

| Density | Wrapper contract | Label contract | Value contract | Intended use |
|---------|------------------|----------------|----------------|--------------|
| `:comfortable` (default) | `rounded-lg px-4 py-3` + tone surface | `text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400` | `mt-1 text-2xl font-mono text-slate-900 dark:text-slate-100` | Dashboard/detail-page metric cards such as Overview and Request Detail. |
| `:compact` | `rounded-lg border px-3 py-2 text-center` + tone border | `text-xs text-slate-500 dark:text-slate-400` | `text-lg font-semibold font-mono text-slate-900 dark:text-slate-100` | Dense table-summary strips such as Models and Requests. |

Comfortable tone contracts:

| Tone | Class contract |
|------|----------------|
| `:neutral` | `bg-slate-50 dark:bg-slate-900/60` |
| `:info` | `bg-sky-50/50 ring-1 ring-sky-200/60 dark:bg-sky-900/20 dark:ring-sky-700/30` |
| `:success` | `bg-forest-50/50 ring-1 ring-forest-300/60 dark:bg-emerald-900/20 dark:ring-emerald-700/30` |
| `:warning` | `bg-amber-50/50 ring-1 ring-amber-200/60 dark:bg-amber-900/20 dark:ring-amber-700/30` |
| `:error` | `bg-red-50/50 ring-1 ring-red-200/60 dark:bg-red-900/20 dark:ring-red-700/30` |

Compact tone contracts:

| Tone | Class contract |
|------|----------------|
| `:neutral` | `border-slate-200 dark:border-slate-700` |
| `:info` | `border-sky-200 dark:border-sky-800` |
| `:success` | `border-forest-300 dark:border-emerald-800` |
| `:warning` | `border-amber-200 dark:border-amber-800` |
| `:error` | `border-red-200 dark:border-red-800` |

Nodes intentionally retains its local `summary_tile/1` after PR3 because its
rail-aware surface carries `ring-1` on every tone, including neutral. The shared
comfortable `:neutral` metric tile deliberately has no ring to preserve Overview
and Request Detail parity; adding a third metric surface variant would be an
over-extraction for v2.

#### `metric_grid/1`

`<.metric_grid>` is only a thin grid wrapper:

```
grid + gap_class
```

Its default `gap_class` is `gap-3`. Callers that need a local gap override pass
it through `gap_class` (for example `gap_class="gap-4"`). Callers pass non-gap
layout tokens such as columns, margins, or density-specific placement through
`class` (for example `sm:grid-cols-2 xl:grid-cols-3`). The component must not
bake in column counts, and callers must not pass gap utilities through `class`.

#### `detail_field/1`

`<.detail_field>` renders a wrapper `<div id={...}>` containing a `<dt>` and
`<dd>`. It accepts `id`, `label`, optional `mono`, optional `break_all`, additive
wrapper `class`, and additive value `value_class` for the `<dd>`.

- Label / `<dt>`: `text-xs font-medium uppercase tracking-wide text-slate-500
  dark:text-slate-400`.
- Value / `<dd>`: `mt-1 text-sm text-slate-900 dark:text-slate-100`.
- `mono={true}` adds `font-mono` to the value only.
- `break_all={true}` adds `break-all` to the value only for long IDs or hashes.
- `value_class` adds caller-provided tokens to the value only.

The canonical value typography is intentionally `text-sm`. Some planned copy
mentioned bumping Model Hub detail values to `text-base`, but PR3 keeps the
Request Detail parity contract so migrating ~30 fields does not silently change
information density. Model Hub long IDs stay legible through `font-mono` plus
`break-all` rather than a larger detail value size.

#### `detail_grid/1`

`<.detail_grid>` renders the semantic wrapper for fields:

```
<dl class="grid ...">
```

Its default `gap_class` is `gap-x-6 gap-y-4`. Callers that need local gap
overrides pass them through `gap_class` (for example `gap_class="gap-4"` or
`gap_class="gap-x-6 gap-y-3"`). Callers pass non-gap layout tokens such as
columns or margins through `class`. The component must not bake in page-specific
column counts. Use it only with children that render `<dt>` / `<dd>` pairs,
normally `<.detail_field>`.

### 6.4 Table Density Policy

`<.table>` remains the standard Console table density in v2. PR3 does **not**
introduce a `density` attribute, does not bump table-cell typography, and does
not add a parallel comfortable table variant. A future PR may add table density
only after a browser walk demonstrates a concrete table-crush regression caused
by other typography or layout changes.

---

## 7. Motion

- New or changed tactile-refresh surfaces use `transition-colors` (or scoped `transition` rules in `app.css` for the sidebar collapse). Do not add new `duration-*` or `ease-*` overrides for the v2 input/rail refresh; existing transitions elsewhere, such as flash hide/show helpers, are grandfathered.
- The reduced-motion media query in `app.css` (`@media
  (prefers-reduced-motion: reduce)`) is the floor: any new transition must
  either inherit it or add an entry there. Do not add a Tailwind motion
  utility that bypasses reduced-motion.
- No fade-in/scale-in entrance animations in v2 (no `motion-safe:animate-*`
  introductions).

---

## 8. Accessibility

- **Focus visibility**: every interactive surface — input, nav link, button,
  collapse toggle — must show a `:focus-visible` ring that is *not*
  color-only. The class strings above use `ring-2` plus a `ring-offset-2`
  offset color matching the surrounding surface, so the ring is visible
  even for users with reduced color perception.
- **Color is never the sole signal.** Error state combines `red` border
  *and* error message text. Active nav state combines `bg-navy/10`,
  `text-navy`, *and* `aria-current="page"`. Disabled state combines a
  dimmer slate text *and* `aria-disabled="true"` + `cursor-default`.
- **Contrast targets** (from `docs/brand-identity.md`): body text on
  white ≥ AA (slate-900 on white = 15.4:1; slate-500 on white = 4.6:1).
  Any new text/background combination introduced by an agent must clear
  AA at minimum and be cross-checked against the brand-identity contrast
  table.
- **Keyboard navigation**: do not introduce `tabindex` overrides on the
  sidebar or form inputs. The `<.link>` and `<input>` defaults are correct.
- **Reduced motion**: see §7. Honor the existing media query.

---

## 9. The `@class` Merge Rule

`core_components.ex` input/`<.link>`/sidebar callsites use the pattern
`class={[ "<base tokens>", "<state token>", @class ]}`. The convention is:

- **The component owns *structural* tokens.** Surface, border, shadow,
  focus ring, hover, error, disabled, read-only. Pasted from this
  document.
- **The caller owns *additive* tokens.** Examples: `font-mono` for a
  monospace data field, `max-w-xs` for a narrow input, `text-right` for
  numeric alignment.
- **Callers must not pass conflicting structural tokens** via `@class`.
  Examples of disallowed caller overrides on inputs: `bg-*`,
  `border-*-{50..900}`, `shadow-*`, `ring-*`, `focus-visible:ring-*`,
  `text-slate-*` (text color), `placeholder:*`. If a caller needs a
  structurally distinct field, the right path is a new component variant
  here, not a class-string override at the callsite.
- **No Tailwind-merge utility is introduced.** The append-last pattern is
  the source of truth. Spec compliance is enforced socially via this
  document and via the render-class smoke tests in
  `apps/orchard_controller/test/orchard/console/core_components_test.exs`.

When auditing a callsite, search for inline `class={...}` on `<.input>`
or `<.link>` inside `sidebar_nav/1`. If the override conflicts with this
spec, remove it.

---

## 10. v2 Validation Checklist

Use this checklist for Console UI changes governed by this document. UI tactility is observable, not unit-testable; v2 verification combines class-token render smoke and a structured browser walk.

### 10.1 Component Smoke (must pass before browser walk)

From the umbrella root:

```sh
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test apps/orchard_controller/test/orchard/console/core_components_test.exs
```

Render-class assertions check *required token presence*, not full
class-string equality and not class order.

### 10.2 Final Validation (before commit)

```sh
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix dialyzer
mise exec -- mix test apps/orchard_controller/test/orchard/console/core_components_test.exs
mise exec -- mix test
mise exec -- mix test --cover
git diff --check
```

Repo-wide gates that fail outside the touched scope must be recorded as
explicit baseline blockers, not silently accepted.

### 10.3 Browser Walk

For each pair of `{light, dark} × {sidebar-expanded, sidebar-collapsed}`:

**Sidebar / rail**

- [ ] Sidebar reads as a distinct panel against the page canvas.
- [ ] Divider between sidebar and main is unambiguous.
- [ ] Active nav item is contained, not bleeding into adjacent items.
- [ ] Hover affordance is visible without being loud.
- [ ] `:focus-visible` state is clear in expanded *and* collapsed modes
  and is not color-only.
- [ ] Disabled nav item is visibly inactive.
- [ ] Collapse animation and toggle icon rotation still work; reduced
  motion is respected.
- [ ] License badge and version label still render correctly when expanded;
  they collapse cleanly when collapsed.

**Form input wells (Model Hub search)**

- [ ] `<.input type="search">` reads as an editable well at rest.
- [ ] Hover state is visible.
- [ ] Focus state is unambiguous (border + ring + ring-offset visible on
  dark).
- [ ] Placeholder contrast is readable.

**Form input wells (Tenants + Tenant Detail)**

- [ ] Tenant create `<.input>` renders as a tactile well.
- [ ] API key create `<.input>` renders as a tactile well.

**Form input wells (Playground)**

- [ ] `<.input type="select">` model selector - well + caret visually
  consistent.
- [ ] `<.input type="textarea">` system prompt - well treatment scales to
  multi-line.
- [ ] `<.input type="textarea">` main message - well treatment scales to
  large height; the `SubmitOnModEnter` hook still fires.
- [ ] Send remains a submit control for `#playground-form`; click submission
  routes through `PlaygroundSubmitClick` and respects disabled state.
- [ ] Cmd/Ctrl + Enter uses the same browser submit path as Send and respects
  disabled state.
- [ ] Disabled state legible. Verify via existing component paths or
  short-lived local-only attribute toggles in devtools; do not commit
  fixture-only UI states.
- [ ] Read-only state legible. Same constraint as Disabled.
- [ ] Error state legible. Force via existing validation paths where
  available, or via temporary local-only invalid form state; do not
  commit verification-only code.

**Console health**

- [ ] Overview, Model Hub, Playground render without console errors after
  the refresh.
- [ ] No layout regression in the page header or content wrapper.

### 10.4 Stop Conditions

- Any compile warning, format failure, or render-test failure → stop, fix.
- Any browser checklist regression in a state not explicitly covered by v2
  → stop and scope the regression into a follow-up rather than silently
  expanding v2.

---

## 11. Out of Scope (v2)

The following are intentionally *not* defined here or not implemented in PR1. An
agent must not generate code that depends on them unless a later PR updates this
contract first.

- New Tailwind color tokens, font extensions, or `app.css` `@theme` changes
  outside a narrowly scoped token/documentation correction.
- A second design escape hatch beyond `.console-input-well` (and that one
  is reserved, not yet used).
- Page-header, breadcrumb, status pill, modal, toast/flash, badge, or button
  restyling beyond what already exists.
- Mobile sidebar / responsive collapse below `lg`. The rail is desktop-only
  in v2.
- Animated entrance/exit transitions for inputs, nav items, or rail.
- Component library swap (Headless UI, Radix, etc.).
- A LiveView component split (`Orchard.Console.UI.Input` etc.).

If a future revision needs any of these, it must update this document
*before* the implementation lands and must keep the change consistent with
`docs/brand-identity.md`.

---

## 12. Change Discipline

- This document is the **active tactical spec** for the v2 refresh. The
  render-class smoke tests in
  `apps/orchard_controller/test/orchard/console/core_components_test.exs`
  read tokens from §4 and §5.
- Adding a new state, surface, size, page mode, or token requires editing this
  document first, then updating the component, then updating the render smoke.
- Drift between `core_components.ex`, `app.html.heex`, `app.css` `@theme` /
  `@source`, and this document is a defect. Either the code is wrong or this
  document is wrong; resolve before commit.
- This document never references planning artifacts, agent harnesses, or
  external context tools. It is a self-contained product document.

---

## 13. Theme Mode Control

Theme mode is an explicit Console state with three valid preferences: `system`,
`light`, and `dark`. `system` is the default and preserves the operator's OS
appearance preference until the operator chooses a fixed mode.

### 13.1 Cookie Contract

- Preference is stored in the `orchard_console_theme` cookie.
- Valid cookie values are exactly `system`, `light`, and `dark`; any missing or
  invalid value falls back to `system`.
- The Console reads the cookie during the browser pipeline after cookies are
  explicitly fetched. The value is validation-only input, never trusted as a
  broader preference object.
- Client writes use the Console cookie convention: `Path=/console`,
  `SameSite=Lax`, and a one-year max age.

### 13.2 Root Attributes

The root document carries two related attributes:

- `data-theme` drives CSS. Server render emits the validated preference value;
  a synchronous pre-paint script resolves `system` to concrete `light` or `dark`
  before the stylesheet loads.
- `data-theme-mode` records the operator preference for controls. It remains
  `system` when the UI is following OS appearance.

When `system` is selected, OS appearance is resolved before first paint and on
subsequent page loads. Live OS-appearance changes require the client theme
control to register a `matchMedia` change listener; without JavaScript,
`system` cannot resolve and the Console uses the light selector state.

Tailwind's `dark:` utilities and Console dark custom rules are keyed from
`<html data-theme="dark">`. Do not mix media-query driven app CSS with this
selector contract.

### 13.3 Control Contract

The theme control is a three-segment radiogroup mounted in the sidebar footer
above the collapse button. Segments expose `data-theme-mode="system"`,
`data-theme-mode="light"`, and `data-theme-mode="dark"`; active state updates
`aria-checked`, focus, the cookie, `data-theme-mode`, and resolved
`data-theme` without a server round trip.

Collapsed-sidebar mode hides segment text through the existing `.sidebar-label`
pattern while keeping the three icon targets visible and clickable. In the
4.5rem collapsed rail, the icon-only segments stack vertically so each target
fits inside the clipped sidebar without adding a second control style.

### 13.4 Design Boundaries

This state-model addition satisfies §12 Change Discipline. It does not relax
§11: no new Tailwind color tokens, font extensions, palette values, or `@theme`
changes are part of theme mode control.
