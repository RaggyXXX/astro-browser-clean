# Scripting API

> **Two scripting surfaces.** This page documents the sandboxed `astro.*` API available **inside `<script lang="lua">` blocks**. For the JavaScript-flavored DOM API used from **normal plugin Lua** (your `main.lua`) - `engine:document(win)`, `querySelector`, `addEventListener`, element handle properties - see [plugin-dom.md](plugin-dom.md). Pick by where the code lives.

Astro Browser does not run JavaScript. Inline scripts are sandboxed Lua:

```html
<script lang="lua">
  astro.on_action("save", function()
    astro.log("saved")
  end)
</script>
```

The script runs once at mount time. Callbacks registered from it stay live for the mounted window.

## Sandbox environment

These globals are available inside `<script lang="lua">`:

- `string`, `table`, `math`, `pairs`, `ipairs`, `next`, `type`, `tostring`, `tonumber`, `select`, `unpack`, `pcall`, `xpcall`, `error`
- `print` - writes to the engine log with a `[script]` prefix
- `astro` - the API documented below
- `state` - direct access to the per-window state table (`astro.get_state` / `astro.set_state` are the sugar)
- `document`, `window`, `console`, `FormData`, `customElements` - DOM-like convenience handles
- `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, `requestAnimationFrame`, `cancelAnimationFrame`

These are intentionally **not** available: `_G`, `io`, `os`, `debug`, `require`, `dofile`, `loadfile`, `package`, `core`, any Project Sylvanas host API.

## Logging

```lua
astro.log(msg)    -- info
astro.warn(msg)   -- warning
astro.error(msg)  -- error
```

## Finding elements

```lua
local h     = astro.find("#save")      -- first match (handle or nil)
local all   = astro.find_all(".item")  -- list of handles
```

Selectors accept the same syntax as CSS (tag, `.class`, `#id`, descendant, combinators).

## Actions

Bind action ids referenced from `onClick="..."` / `onChange="..."`:

```lua
astro.on_action("save", function(event) astro.log("save") end)
astro.register_action("save", fn)  -- alias of on_action
astro.action("save", fn)           -- alias of on_action
```

## Direct event binding

When you do not want an `onClick` attribute, bind by selector:

```lua
astro.on_click("#save", function(event) ... end)
astro.on_change("#name", function(event) ... end)
astro.on_submit("form", function(event) ... end)
astro.on_reset("form",  function(event) ... end)
```

## State

`state` is a per-window key/value store. Use it for view state that should survive a re-render.

```lua
astro.set_state("count", 0)
local n = astro.get_state("count") or 0
astro.set_state("count", n + 1)
```

Re-renders triggered by state changes are scheduled automatically.

## Mutating content

Quick text update on a matched element:

```lua
astro.set_text("#status", "Ready")
```

Create new nodes (not yet attached to the tree):

```lua
local el = astro.create_element("div", {
  id    = "row",
  class = "item highlighted",
  text  = "Hello",
  attrs = { ["data-id"] = "42" },
})

local t = astro.create_text("plain text")
```

The returned handle is the same handle type returned by `astro.find`, so you can attach event listeners, set text, or inspect it. Use the handle's standard methods to append it into the tree.

## Timers and animation frames

```lua
local id = setTimeout(fn, 250)         -- run once after 250ms
clearTimeout(id)

local iv = setInterval(fn, 1000)       -- run every 1000ms
clearInterval(iv)

local raf = requestAnimationFrame(function(timestamp_ms) ... end)
cancelAnimationFrame(raf)
```

All timer ids are simple numbers. Timers are bound to the current window's lifecycle and are cancelled automatically when the window is destroyed.

## Navigation

```lua
astro.reload()                              -- reload current content
astro.load_url(url, opts)                   -- load external URL (host must support HTTP)
astro.load_file(path, opts)                 -- load from sandboxed file
astro.load_html(html, css, opts)            -- swap to inline HTML/CSS
```

Use these for in-app page switches. To handle plain `<a href="...">` clicks instead of replacing content, register a navigation handler on the engine - see [engine-api-advanced.md](engine-api-advanced.md).

## Re-rendering

```lua
astro.mark_dirty()         -- mark everything dirty
astro.mark_dirty("style")  -- only style
astro.mark_dirty("layout") -- only layout
astro.mark_dirty("paint")  -- only paint
```

You rarely need this - engine state changes, `astro.set_state`, and event handlers already trigger the right reflow.

## Time

```lua
local t  = astro.time()         -- seconds (monotonic, from platform)
local dt = astro.delta_time()   -- seconds since last frame
```

## URL resolution

```lua
local abs = astro.resolve_url("./icon.svg")
```

Resolves a reference against the current document's base URL (useful when paths arrived via `load_url` or `load_file`).



