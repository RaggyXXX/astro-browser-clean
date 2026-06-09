# Advanced Engine API

`GUIDE.md` covers the everyday lifecycle: `Engine.new`, `create_window`, `load_html`, `start`, `stop`, `destroy`. This page documents the rest of the public engine surface: fonts, icons, animation, theming, navigation, frame control, and the profiler.

Everything here is called on the engine instance returned by `Engine.new()` or by the package-level constructor when you expose one.

## Fonts

### Register a custom font

```lua
engine:register_font(name, url, weight, style)
```

| Parameter | Description |
| --- | --- |
| `name` | Family identifier you reference from CSS (`font-family: "my-font"`). |
| `url` | Source URL the host platform can fetch. Pass `nil` to re-load an already-registered font. |
| `weight` | Optional CSS font-weight to bind this face to (e.g. `400`, `700`, `"bold"`). |
| `style` | Optional CSS font-style (`"normal"` or `"italic"`). |

Faces load asynchronously through the platform HTTP/file hook. Until ready, text falls back to the next family in the cascade.

### Control font hinting

```lua
engine:set_hinting(family, weight, enabled)
```

Returns `true` if applied. Enable hinting for small UI text (sub-16px) on low-DPI displays; disable for headlines where you want clean outline rendering. Passing `family = nil` and `weight = nil` applies the setting globally.

```lua
local stats = engine:get_hinting_stats()
```

Returns per-font hinting statistics (number of hinted glyphs, fallbacks, opcodes seen). Useful for diagnosing typography drift between environments.

## Icons

Astro ships a small icon cache so frequently-used SVG icons do not have to be parsed on every paint.

### Register a parsed icon tree

```lua
engine:register_icon("close", {
  tag  = "svg",
  attr = { viewBox = "0 0 24 24" },
  child = { ... },
})
```

The tree mirrors the react-icons shape (one `<svg>` root with nested children).

### Register a single-path icon

```lua
engine:register_icon_path("check", "M5 12l5 5L20 7", "0 0 24 24")
```

The third argument defaults to `"0 0 24 24"`. Use this for monochrome glyph icons.

Reference registered icons from HTML with the existing `<svg>` / `<use>` flow.

## Animation

### Register keyframes

```lua
engine:register_keyframes("spin", {
  { 0,   { transform = "rotate(0deg)"   } },
  { 100, { transform = "rotate(360deg)" } },
})
```

CSS rules can then reference the animation by name (`animation: spin 1s linear infinite`). Keyframes registered after a mount propagate to existing windows automatically.

## Theming and color scheme

```lua
engine:set_color_scheme("dark")  -- "light" | "dark"
```

Updates the value used to evaluate `prefers-color-scheme` media queries. All mounted windows re-cascade.

## Routing

```lua
engine:set_navigation_handler(function(href, target)
  if href:sub(1,1) == "#" then
    return true            -- swallow
  end
  return false             -- let engine handle it
end)
```

The handler runs for every `<a>` click. Return `true` to mark the click handled and prevent the engine's default navigation; return `false` (or `nil`) to let `load_url`/`load_file`/`load_html` run as usual.

## DPR

```lua
engine:set_dpr(1.5)
```

Sets the device pixel ratio used by layout and paint rounding. The engine reads platform DPR at construction; call this only when your host reports DPR through a non-default channel or when you want to force a specific value.

## Frame throttling

```lua
engine:set_fps_cap(active_fps, idle_fps)
```

| Parameter | Range | Default |
| --- | --- | --- |
| `active_fps` | 1..300 | 60 |
| `idle_fps` | 1..300 | 30 |

`idle_fps` kicks in when the window has no animations, no pending dirty state, and no recent user input. This keeps idle windows inexpensive when nothing is changing.

## Profiler

```lua
engine:enable_profiler()
engine:disable_profiler()

local stats = engine:get_profile_stats()
```

`get_profile_stats()` returns per-phase averages (avg / min / max / p95) for style, layout, paint, and replay. Use during development to find expensive frames; disable in shipped plugins.

## Lifecycle hooks

Already covered in `GUIDE.md`:

- `engine:create_window(opts)`
- `engine:load_html(win_id, html, css, opts)`
- `engine:start()`, `engine:stop()`, `engine:destroy()`

Recommended pattern: build everything once on plugin load, call `engine:start()` exactly once, call `engine:destroy()` on plugin unload.



