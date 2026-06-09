# HTML Tag Compatibility

Astro Browser parses unknown tags as generic elements. That does not mean they have browser
semantics. This table marks runtime behavior for the supported Astro HTML surface.

## Structure

| Tag(s) | Status | Notes |
| --- | --- | --- |
| `html`, `body` | partial | Parsed as document wrappers; not visual nodes with full browser document semantics. |
| `head`, `meta`, `title` | partial | Captured/skipped for document metadata; not visual nodes. |
| `style`, `link rel=stylesheet` | supported | Inline CSS and stylesheet references are captured; production should compile CSS into IR. |
| `script lang=lua` | partial | Lua action sandbox only; no browser JavaScript DOM. |
| `div`, `span` | supported | Core block/inline elements. |
| `section`, `article`, `nav`, `aside`, `header`, `footer`, `main` | supported | Semantic block elements with block UA defaults. |
| `figure`, `figcaption` | supported | Basic block UA behavior. |
| unknown custom tags | partial | Accepted as generic nodes; no custom element lifecycle. |

## Text

| Tag(s) | Status | Notes |
| --- | --- | --- |
| text nodes, `p`, `br` | supported | Text flow, wrapping, line breaks. |
| `h1`-`h6` | supported | UA font/margin defaults. |
| `strong`, `b`, `em`, `i`, `small`, `mark` | supported | Inline UA styling. |
| `pre`, `code`, `kbd` | supported | Basic whitespace/mono-like styling path. |
| `blockquote`, `address`, `center`, `sub`, `sup`, `del`, `s`, `strike`, `ins`, `u` | supported | Basic UA styling; advanced inline baseline parity is partial. |
| `abbr`, `cite`, `q`, `time`, `var`, `samp` | supported | Chrome-UA inline defaults for V1; `q` does not yet synthesize quote glyphs. |

## Lists And Tables

| Tag(s) | Status | Notes |
| --- | --- | --- |
| `ul`, `ol`, `menu`, `li`, `dl`, `dt`, `dd` | supported | Markers, counters, list-style, custom counter styles, and definition-list UA spacing. |
| `table`, `thead`, `tbody`, `tfoot`, `tr`, `td`, `th`, `caption` | partial | Suitable for UI/data tables; not full browser table edge-case parity. |
| `colgroup`, `col` | planned | Void parsing exists for `col`; full column styling semantics are not complete. |

## Forms And Components

| Tag(s) | Status | Notes |
| --- | --- | --- |
| `button` | supported | Self-drawn button behavior and events. |
| `input type=text/password` | supported | Text input component path. |
| `input type=number` | supported | Number input component path. |
| `input type=color` | supported | Color input component path. |
| `input type=range`, `slider` | supported | Range/slider component path. |
| `textarea` | supported | Textarea component path. |
| `select`, `option`, `optgroup` | supported | Custom select component path; option/optgroup are normalized into select options, not standalone visual UI. |
| `input type=checkbox`, `checkbox` | supported | Checkbox component path. |
| `input type=radio`, `radio` | supported | Radio component path. |
| `label`, `fieldset`, `legend` | partial | Basic UA and interaction behavior; full browser form association is partial. |
| `progress`, `meter`, `details`, `summary`, `dialog` | supported | Self-drawn component paths. |
| `form` | partial | Container semantics only; no full native form submission. |
| validation-only tags/attrs | partial | Pseudo-class support exists; full browser validation model is incomplete. |

## Media And Embeds

| Tag(s) | Status | Notes |
| --- | --- | --- |
| `img` | supported | PNG/JPEG/data URI and object-fit style paths. |
| `svg` | partial | Strong shape/path support; advanced SVG features are partial. |
| `iframe`, `video`, `audio`, `embed`, `object`, `source`, `track` | blocked | Parsed/placeholder-level only; no embedded browsing or media playback in V1. |
| `canvas` | blocked | No Canvas 2D/WebGL API in V1. |
| `picture` | planned | Not useful until source selection is specified for Astro assets. |

## Modern HTML Platform

| Feature | Status | Notes |
| --- | --- | --- |
| `template` | blocked | Requires inert document fragments/content model. |
| `slot`, Shadow DOM | blocked | Requires shadow tree/lifecycle system. |
| Custom elements lifecycle | blocked | Unknown tags parse, but no lifecycle/callbacks. |
| `contenteditable` | blocked | Text editing model beyond input/textarea is not V1. |



