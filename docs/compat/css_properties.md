# CSS Property Compatibility

The parser currently maps roughly 184 property IDs plus many shorthands. This
matrix is grouped by product surface. `supported` means safe for the builder to
emit within the documented value subset.

## Layout And Box Model

| Property group | Status | Notes |
| --- | --- | --- |
| `display` | partial | Block, inline, inline-block, flex, inline-flex, grid, inline-grid, table types, list-item. Not every CSS display pair. |
| `box-sizing` | supported | `content-box`, `border-box`. |
| `width`, `height`, `min-*`, `max-*` | supported | Includes px, %, viewport/rem/calc paths used by layout. |
| logical size shorthands | supported | `inline-size`, `block-size`, min/max variants for horizontal-tb/LTR V1 subset. |
| `margin`, `padding`, logical spacing | supported | Physical and horizontal-tb/LTR logical mappings. |
| `position`, `left/top/right/bottom`, `inset*` | partial | Static/relative/absolute/fixed/sticky paths exist; nested sticky edge cases need visual gates. |
| `z-index` | supported | Practical stacking behavior. |
| `float`, `clear` | partial | Useful float behavior; not full CSS exclusions spec. |
| `aspect-ratio` | supported | UI-safe behavior. |
| `vertical-align` | partial | Basic inline/table use; full baseline parity incomplete. |

## Flex, Grid, Tables, Columns

| Property group | Status | Notes |
| --- | --- | --- |
| Flexbox core | supported | `flex`, direction, wrap, grow, shrink, basis, order, gap, justify/align. |
| Grid core | partial | Templates, gaps, placement, areas, auto-flow, alignment. Advanced intrinsic parity still incomplete. |
| Grid advanced | planned | `auto-fill/auto-fit`, named lines, full min/max-content, subgrid. |
| Table properties | partial | `border-collapse`, `border-spacing`, table display types. UI/data-table safe. |
| Multi-column | partial | `column-count`, `column-width`, `column-rule-*`; browser fragmentation parity incomplete. |
| `container-type`, `container-name`, CQ units | partial | Useful subset; more visual parity needed. |

## Backgrounds, Borders, Effects

| Property group | Status | Notes |
| --- | --- | --- |
| `background-color` | supported | Standard color paths. |
| `background-image` gradients | supported | Linear/radial/conic and repeating variants. |
| `background-image: url(...)` | supported | PNG/JPEG/data URI/resource path via texture cache. |
| `background-size`, `position`, `repeat`, `attachment`, `origin`, `clip` | partial | Core Chrome-like behavior covered; multi-layer per-layer longhands are still constrained. |
| Borders physical/logical | supported | Width/style/color/radius and horizontal-tb logical mappings. |
| `outline-*` | supported | Practical outline paint. |
| `box-shadow`, `text-shadow` | partial | Useful visual approximation. |
| `opacity`, `visibility` | supported | Runtime paint/hit-test paths. |
| `filter`, `backdrop-filter` | partial | Approximation through available draw primitives, not shader-grade browser parity. |
| `clip-path`, `mask-*` | partial | Useful subset; advanced shape/mask parity incomplete. |
| `mix-blend-mode`, `isolation` | partial | Hooks exist; full compositing parity needs tests. |

## Typography And Text

| Property group | Status | Notes |
| --- | --- | --- |
| `font-family`, `font-size`, `font-weight`, `font-style`, `line-height` | supported | TTF/WOFF/OTF-CFF custom font path exists. |
| `font-variant`, `font-stretch` | partial | Parsed/represented; full OpenType shaping/stretch parity incomplete. |
| `color`, `caret-color`, `accent-color`, `appearance` | supported | Accent and appearance feed Astro-drawn controls where implemented. |
| `text-align`, `text-align-last`, `text-indent` | partial | Common UI use supported. |
| `white-space`, `text-overflow`, `text-transform` | supported | Common UI text behavior. |
| `letter-spacing`, `word-spacing` | supported | Custom text paint path. |
| `text-decoration*` | supported | Line/color/style/thickness subset. |
| `word-break`, `overflow-wrap`, `text-wrap`, `line-clamp` | partial | Useful wrapping/clamping subset. |
| `direction`, `writing-mode`, `unicode-bidi`, `hyphens` | partial | Parsed/represented; full bidi/vertical text/hyphenation is not complete. |

## Overflow, Scroll, Interaction

| Property group | Status | Notes |
| --- | --- | --- |
| `overflow`, `overflow-x`, `overflow-y` | supported | Scroll containers/clipping/scroll extents. |
| `scrollbar-color`, `scrollbar-width` | supported | Self-drawn scrollbar styling. |
| `scroll-behavior` | partial | Smooth behavior depends on runtime paths. |
| scroll snap/padding/margin | partial | Parsed and represented; full browser scroll-snap parity needs gates. |
| `overscroll-behavior*` | partial | Runtime constraint subset. |
| `cursor`, `pointer-events`, `user-select` | supported | UI-safe behavior. |
| `resize` | partial | Textarea resize UX is implemented; general element resize semantics remain constrained. |

## Animation And Transform

| Property group | Status | Notes |
| --- | --- | --- |
| `transform`, `transform-origin` | partial | Paint-time transform stack; layout-affecting transform behavior is not browser-complete. |
| transitions | partial | Numeric/color/transform subset. |
| keyframes/animation properties | partial | Supported subset; not all animatable properties. |
| `@starting-style` | partial | Useful subset. |

## Shorthands

| Shorthand | Status | Notes |
| --- | --- | --- |
| `margin`, `padding`, `border`, `outline`, `overflow`, `flex`, `font` | supported | V1-safe expansion subset. |
| `background` | partial | Strong single-layer support; constrained multi-layer/per-layer behavior. |
| `place-items`, `place-content`, `place-self` | supported | Grid alignment subset. |
| logical border/spacing/inset shorthands | supported | Horizontal-tb/LTR subset. |
| `scroll-padding`, `scroll-margin`, `overscroll-behavior` | partial | Expansion exists; runtime semantics constrained. |

## Blocked CSS Platform Areas

| Area | Status | Notes |
| --- | --- | --- |
| CSSOM / live browser style mutation API | blocked | Builder/compiler emits IR; runtime is not a JS CSSOM browser. |
| Houdini / paint worklets | blocked | Outside V1 runtime model. |
| Full color management / wide gamut | blocked | UI-safe sRGB approximations only. |
| Full cascade layer/import edge-case parity | planned | Parser support exists, but exhaustive browser recovery parity is not V1. |



