# HTML and CSS Input

Astro Browser ships local HTML and CSS parsers inside the engine. You feed HTML and CSS strings in and the runtime paints them. No external compiler, no preprocessor, no JavaScript runtime - the engine reads the strings directly.

This page documents the parser surface: how to feed it content, what entry points exist, and what the parsers do and do not accept. For exact tag/property coverage see the [compat reference](compat/).

## High-level: load HTML straight into a window

The normal path is `engine:load_html`:

```lua
local engine = AstroUI.new()
local win    = engine:create_window({ id = "main", title = "Hello", x = 100, y = 100, w = 480, h = 320 })

engine:load_html(win, [[
  <style>
    body { padding: 16px; font-family: sans-serif; background: #111; color: #eee; }
    button { padding: 8px 12px; border-radius: 6px; background: #2563eb; color: white; }
  </style>
  <h1>Hello</h1>
  <button onClick="say_hi">Click me</button>
]])

engine:start()
```

Signature:

```lua
engine:load_html(win_id, html, css, opts)
```

| Parameter | Purpose |
| --- | --- |
| `win_id` | Window id from `create_window`. |
| `html`   | Raw HTML string. Can contain `<style>` blocks. |
| `css`    | Optional external CSS string. Merged with any `<style>` blocks found in the HTML. |
| `opts`   | Optional table. Useful fields: `source_url`, `source_path`, `base_url` (used for resolving relative `<link rel="stylesheet">` and `@import` references). |

Variants that load from elsewhere:

```lua
engine:load_file(win_id, path, opts)   -- read sandbox-relative file
engine:load_url(win_id, url, opts)     -- fetch over the platform HTTP hook
engine:reload(win_id)                  -- re-parse the last source
```

`load_file` and `load_url` require the platform adapter to provide file or HTTP access - see `core/platform/platform_api.lua`.

## Programmatic: parse once, mount many

When the same content is mounted often (modal dialogs, repeated panels), parse once and mount the result:

```lua
local parsed = AstroUI.HTMLParser.parse(html, css)

engine:mount(win_a, parsed)
engine:mount(win_b, parsed)
```

The value returned by `HTMLParser.parse` is **opaque**: treat it as a token the engine understands, not as a data structure to inspect. Its internal shape is not part of the public contract and may change between versions.

## HTMLParser API

```lua
AstroUI.HTMLParser.parse(html, css)
```

Parses a full HTML document plus optional external CSS. Returns an opaque parsed value.

```lua
AstroUI.HTMLParser.get_parser_metadata()
```

Returns a small table with metadata about the parser (version, characteristics). Useful for tooling that wants to detect feature availability without running parses.

## CSSParser API

```lua
AstroUI.CSSParser.parse(css)
```

Parses a full stylesheet string. Returns an opaque parsed-rules value the engine can apply through internal channels.

```lua
AstroUI.CSSParser.parse_inline(style_attr_value)
```

Parses the right-hand side of a `style="..."` attribute (declarations only, no selectors). Returns a list of declarations the engine can apply to a single element.

```lua
AstroUI.CSSParser.parse_inline_full(style_attr_value)
```

Same as `parse_inline` but produces a fuller representation, including any value-level metadata. Use when tooling needs to validate or transform inline styles.

```lua
AstroUI.CSSParser.parse_property_value(value_str, property_name)
```

Parses one property value (e.g. `"1px solid red"` for `border`). Returns the resolved value, or a signal that the input is not supported. Useful for input fields that want to validate a single property before applying it.

```lua
AstroUI.CSSParser.get_known_properties()
AstroUI.CSSParser.get_known_shorthands()
```

Return lists of supported property names. Useful for editor autocomplete or for filtering CSS that originated from a less-restricted source.

## What the parsers accept

For the exhaustive coverage list, see:

- [compat/html_tags.md](compat/html_tags.md) - supported HTML tags
- [compat/css_properties.md](compat/css_properties.md) - supported CSS properties
- [compat/selectors.md](compat/selectors.md) - supported selectors
- [compat/svg.md](compat/svg.md) - supported SVG features
- [supported.md](supported.md) - high-level view of what V1 supports and what it does not

Practical notes:

- **Unknown tags** become generic block elements.
- **Unknown CSS properties or values** are ignored - the parser does not throw, but the property has no effect.
- **`<style>` blocks** in the HTML are extracted and merged with the optional `css` argument. Order of evaluation matches CSS source order.
- **Inline styles** (`style="..."` attributes) are parsed per-element and override stylesheet rules with normal CSS inline specificity.
- **`<link rel="stylesheet">` and `@import`** are resolved asynchronously through the platform's HTTP/file hook. They merge into the cascade as they arrive.
- **HTML entities** are decoded (`&amp;`, `&lt;`, `&#x2014;`, ...).
- **Comments** (`<!-- ... -->`) are stripped.
- **`<script lang="lua">`** blocks are extracted and run once at mount time in the sandboxed Lua environment - see [scripting-api.md](scripting-api.md).

## What the parsers do NOT do

- They do not run JavaScript. `<script>` without `lang="lua"` is ignored.
- They do not implement full HTML5 insertion-mode recovery. Severely malformed markup will not produce browser-identical results.
- They do not run a layout-affecting transform pass on CSS (transforms paint, layout does not respond to `transform`).
- They do not download fonts or images themselves; resource fetching is delegated to the platform adapter.
- They do not validate that referenced action ids (`onClick="save"`) actually have handlers - that is the script sandbox's concern.

## When to reach for the programmatic API

| Situation | Use |
| --- | --- |
| You have an HTML/CSS string and a window | `engine:load_html(win, html, css)` |
| You want to mount the same content in several windows | `HTMLParser.parse(...)` once, `engine:mount(...)` many times |
| You are building an editor and need to validate one CSS value | `CSSParser.parse_property_value(...)` |
| You want autocomplete for CSS property names | `CSSParser.get_known_properties()`, `get_known_shorthands()` |
| You want to apply a CSS rule list parsed elsewhere | `CSSParser.parse(...)` and let the engine merge it |
| You need to detect parser capabilities at runtime | `HTMLParser.get_parser_metadata()` |

## Recommended pattern

For a typical plugin: write HTML and CSS as Lua long strings, call `engine:load_html`, and forget the parser exists. Reach for `HTMLParser` / `CSSParser` only when you have a specific tooling or repetition need.



