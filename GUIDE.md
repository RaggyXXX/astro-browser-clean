# Astro Browser Guide

## Entry Points

- `main.lua` is the public Astro Browser runtime entry.
- `AstroUI.new(config)` creates an engine instance.
- `AstroUI.replace_global(config)` replaces `_G.AstroEngine` and returns the new engine for host bridge workflows.

## Runtime Layout

The runtime is under `core/`. It includes parsing, style resolution, layout, painting, events, components, SVG, fonts, routing, and platform adapters.

## Mounting A Browser Page

Create a window with `engine:create_window(...)`, then mount HTML and optional CSS with `engine:load_html(win_id, html, css, opts)`. Use `engine:load_file(...)` or `engine:load_url(...)` when the host adapter provides file or HTTP loading hooks.

## Minimal Shape

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine = AstroUI.new()
local win = engine:create_window({ id = "main", title = "Astro Browser", x = 80, y = 80, w = 520, h = 340 })

engine:load_html(win, "<h1>Astro Browser</h1><button>Ready</button>")
engine:start()
```
