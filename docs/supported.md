# What is Supported in V1

This is the single source of truth for what Astro Browser V1 accepts and what it does not.

For per-feature detail (each tag, each property, each selector), follow the links to [compat/](compat/) under each section.

## Goal

Astro Browser V1 is a pure Lua 5.1 UI runtime for Project Sylvanas. You should be able to author UI with a comfortable HTML/CSS-like model and bind Lua actions without writing low-level draw, layout, input, focus, or scroll code.

V1 is not a full web browser.

## Non-negotiables

- Runtime code is Lua 5.1 compatible.
- All drawing goes through the Project Sylvanas platform adapter.
- Core modules do not call Project Sylvanas APIs directly; only `core/platform/*` may do that.
- V1 behavior has local verification coverage where host APIs are not required.
- V1 behavior that depends on Project Sylvanas has a manual/live verification checklist.

## Runtime layers

1. **Platform adapter** - `core/platform/platform_api.lua` defines the contract; `sylvanas_platform.lua` implements it.
2. **Core runtime** - DOM, style, layout, paint, events, input, scroll, animation, components, script sandbox.
3. **Parsed HTML/CSS input** - `engine:load_html`, `engine:load_file`, and `engine:load_url` feed documents into the runtime. Parsed bundles are opaque to plugin authors.

## Supported HTML tags

Full reference: [compat/html_tags.md](compat/html_tags.md).

- Structure: `html`, `body`, `div`, `span`, `section`, `header`, `footer`, `main`, `nav`, `article`
- Text: `_text`, `p`, `h1`, `h2`, `h3`, `strong`, `b`, `em`, `i`, `small`, `br`
- Lists: `ul`, `ol`, `li`
- Media/vector: `img`, `svg`
- Forms/components: `button`, `input`, `textarea`, `select`, `option`, `checkbox`, `radio`, `label`, `progress`, `meter`, `details`, `summary`, `dialog`
- Tables: `table`, `thead`, `tbody`, `tr`, `th`, `td`
- Navigation/script/style: `a`, `style`, `script`

Unknown tags are accepted as generic block elements.

## Supported CSS

Full property reference: [compat/css_properties.md](compat/css_properties.md). Selector reference: [compat/selectors.md](compat/selectors.md).

**Layout**

- Box model: `display`, `box-sizing`, width/height, min/max, margin, padding, border (width/color/style/radius)
- Flow: block, inline, inline-block, absolute, fixed, sticky, z-index
- Flex: direction, wrap, grow, shrink, basis, justify/align, gap
- Grid: V1-safe templates, rows/columns, gaps, placement, areas, basic auto-flow
- Overflow/scroll: `overflow`, `overflow-x`, `overflow-y`, scrollbars, clipping
- Lists: `list-style-type`, `list-style-position`, `list-style-image`, `@counter-style`

**Visual styling**

- Colors: hex, rgb/rgba, hsl/hsla, named basics, `transparent`
- Backgrounds: color, image/gradient, size, position, repeat, attachment, origin, clip
- Typography: family, size, weight, style, line-height, letter/word spacing, alignment, white-space, text-overflow, text-transform
- Text decoration: line, color, style, thickness
- Effects: opacity, box-shadow, outline, filter subset, transforms (paint path)
- Pseudo-elements: `::first-letter`, `::first-line`, `::marker`, `::selection`
- Pseudo-classes: hover, focus, active, disabled, enabled, checked, first/last/nth-child subset
- Responsive: viewport units, percent, `calc()`, `clamp()`, media queries, container query units
- Animation: transitions and keyframes for supported numeric, color, and transform properties

## Supported components

Full reference: [compat/components.md](compat/components.md). All drawn by Astro, CSS-overridable:

- Button
- Text / number / color input
- Textarea
- Select
- Checkbox
- Radio
- Slider / range
- Progress, meter
- Details / summary
- Dialog (modal)
- Context menu

Each component has UA default style, focus/disabled/hover/active states, keyboard handling where applicable, and consistent action callback behavior.

## Supported events

- Hit testing respects visibility, pointer-events, z-order, clipping, and windows.
- Mouse: click, context menu, hover, active state, wheel scrolling.
- Keyboard: focus routing, tab order, enter/space activation, text input mapping.
- Actions: `onclick`/`onClick`, `onchange`/`onChange`, links, script-registered actions.
- Components fire actions consistently and update their own state.

## What V1 does not do

- **No JavaScript runtime.** Scripts are sandboxed Lua actions, not arbitrary browser JS. See [scripting-api.md](scripting-api.md) for the full surface.
- **No full HTML5 parser recovery.** CSS/HTML parsing is pragmatic and deterministic; unsupported declarations are ignored rather than emulated.
- **Limited text shaping.** Complex international scripts may render approximately. Latin, Cyrillic, basic CJK glyphs work.
- **Transforms are paint-time only.** Layout does not respond to `transform`.
- **Floats and tables** are supported for practical plugin UI, not full browser spec parity.
- **CSS Grid is V1-safe, not Grid Level 2.** Deferred: `subgrid`, named lines, dense auto-placement, advanced track sizing (`minmax`, `fit-content`, `min-content`, `max-content`), full intrinsic spanning.
- **No 3D transforms, no IME composition, no drag-and-drop, no `:target`/`hashchange`.**
- **Border styles** `double`, `groove`, `ridge`, `inset`, `outset` fall back to `solid`.
- **Polygon `clip-path`** clips to the bounding box for paint.
- **`text-align: justify`** and full baseline alignment are deferred.
- **No accessibility tree export.**
- **No browser network APIs** beyond the existing stylesheet/font/resource loading hooks.

## Host runtime requirements

Project Sylvanas must provide the platform adapter capabilities documented in `core/platform/platform_api.lua`:

- rectangle, line, triangle, circle, texture, and text draw primitives
- clip/scissor push/pop
- texture loading and region drawing where available
- text measurement
- mouse position/buttons, wheel delta, keyboard state
- monotonic time
- data-file read/write hooks for bundled assets and cache

## Verification Notes

Keep verification evidence with the release package or project-level changelog when one is present. The runtime package itself stays focused on the Astro Browser core and documentation.

**Live Project Sylvanas gates**:

- `browser_shell`
- `ua_defaults_text`
- `ua_defaults_forms`
- `ua_defaults_tables`
- `ua_defaults_controls_states`
- `ua_defaults_responsive`
- `final_app`

The live checklist covers host rendering, UA defaults, form controls, tables, responsive behavior, and final app mounting.



