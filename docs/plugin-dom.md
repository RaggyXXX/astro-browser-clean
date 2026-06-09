# Plugin DOM API

_Bridge-verified on Project Sylvanas live host 2026-05-22._

This is the DOM-style API available from **normal plugin Lua** - the code in your `main.lua`, not the code inside `<script lang="lua">`. After you call `engine:load_html(win_id, ...)`, the engine exposes document and element handles so you can query elements, attach event listeners, read form values, and update text or classes without round-tripping through `onClick="..."` attributes.

> **Two scripting surfaces.** Inside `<script lang="lua">` blocks you have the sandboxed `astro.*` API (see [scripting-api.md](scripting-api.md)). Outside scripts - in your plugin's own Lua files - you have the surface documented here: `engine:document(win_id)` and the element handles it returns. Pick by *where the code lives*, not by name.

## Get a document handle

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()
local win     = engine:create_window({ id="settings", title="Settings", x=120, y=120, w=420, h=260 })
engine:load_html(win, "<button id='save'>Save</button>")

local document = engine:document(win)   -- returns a handle, or nil
```

`win_id` is optional - when omitted, the engine uses the most recently loaded window. For multi-window plugins, always pass it explicitly.

## Find elements

| Call | Returns | Example |
| --- | --- | --- |
| `document:getElementById(id)` | one handle or `nil` | `document:getElementById("save")` |
| `document:querySelector(sel)` | first match or `nil` | `document:querySelector(".panel .primary")` |
| `document:querySelectorAll(sel)` | array of handles | `document:querySelectorAll("li")` |

## Supported selectors

The same shapes work in both `document:querySelector` and `:querySelectorAll`:

- `#id` - `document:querySelector("#save")`
- `.class` - `document:querySelector(".primary")`
- tag - `document:querySelector("button")`
- compound - `document:querySelector("section.panel.active button.primary")`
- attribute - `document:querySelector("[data-mode=edit]")`
- descendant - `document:querySelectorAll(".panel button")`
- comma list - `document:querySelectorAll("h1, h2, h3")`

## Element handle reference

Each match returns a handle. Handles are read **and** written through normal Lua property syntax (`element.textContent = "..."`) or method calls (`element:addEventListener(...)`).

### Content

| Member | Read | Write | Notes |
| --- | --- | --- | --- |
| `.textContent` | yes | yes | Reads the text inside the element; writing replaces it. |
| `.dataset` | yes | yes | Mirror of `data-*` attributes. `element.dataset.mode = "edit"` writes `data-mode="edit"`. Underscores in keys map to dashes. |

### Attributes

| Method | Purpose |
| --- | --- |
| `:getAttribute(name)` | Returns the attribute value or `nil`. |
| `:setAttribute(name, value)` | Sets the attribute and marks the element dirty for re-style. |
| `:removeAttribute(name)` | Deletes the attribute. |
| `:hasAttribute(name)` | Boolean check. |

### Classes

The `.classList` property exposes the canonical mutators:

| Call | Effect |
| --- | --- |
| `element.classList:add(cls)` | Adds the class if not already present. |
| `element.classList:remove(cls)` | Removes the class if present. |
| `element.classList:contains(cls)` | Boolean check. |
| `element.classList:toggle(cls)` | Adds when missing, removes when present. Returns the new presence state. |

### Form values

| Member | Applies to | Behavior |
| --- | --- | --- |
| `.value` (read) | `<input>`, `<textarea>`, `<select>` | Returns the current value as a string. **For `<select>` this is the underlying `<option value="...">` attribute, not the visible option text.** |
| `.value` (write) | `<input>`, `<textarea>`, `<select>` | Sets the current value. For `<select>`, pass the option `value` attribute. |
| `.checked` (read/write) | `<input type="checkbox">`, `<input type="radio">`, `<switch>` | Boolean. |
| `.disabled` (read/write) | form controls | Boolean. |

### Events

```lua
element:addEventListener("click", function(event)
  -- event.target / event.currentTarget are element handles
end)
```

Supported event names (canonical lowercase, mapped from the engine's event table):

`click`, `dblclick`, `change`, `input`, `submit`, `reset`, `focus`, `blur`, `keydown`, `keyup`, `keypress`, `mousedown`, `mouseup`, `mouseenter`, `mouseleave`, `mouseover`, `mouseout`, `mousemove`, `wheel`, `contextmenu`, `close`.

`:removeEventListener(event)` detaches the handler.

## Engine-level shortcuts

When you only have one mounted window, you can skip the `engine:document(win)` hop. These calls default `win_id` to the last loaded window:

| Call | Equivalent |
| --- | --- |
| `engine:getElementById(id)` | `engine:document():getElementById(id)` |
| `engine:querySelector(sel)` | `engine:document():querySelector(sel)` |
| `engine:querySelectorAll(sel)` | `engine:document():querySelectorAll(sel)` |
| `engine:onClick(sel, fn)` | `:addEventListener("click", fn)` on every match |
| `engine:onChange(sel, fn)` | `:addEventListener("change", fn)` on every match |
| `engine:onInput(sel, fn)` | `:addEventListener("input", fn)` on every match |

The "last loaded window" is the one mounted by your most recent `engine:load_html`, `engine:load_file`, or `engine:load_url` call. For a one-window plugin this is exactly what you want; for multi-window plugins, prefer the explicit-window aliases below.

## Aliases for multi-window plugins

The same shortcuts also exist in snake_case form, and these **require** an explicit `win_id` as the first argument:

| Call | Notes |
| --- | --- |
| `engine:query_selector(win_id, sel)` | First match. |
| `engine:query_selector_all(win_id, sel)` | All matches. |
| `engine:on_click(win_id, sel, fn)` | Click handler. |
| `engine:on_change(win_id, sel, fn)` | Change handler. |
| `engine:on_input(win_id, sel, fn)` | Input handler. |
| `engine:on(win_id, event, sel, fn)` | Generic - any event from the list above. |

These are not deprecated. Use them whenever your plugin manages more than one window, or when you want the `win_id` plumbing to be explicit at the call site.

## Complete example

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()

local win = engine:create_window({
  id = "plugin_dom", title = "Plugin DOM", x = 120, y = 120, w = 360, h = 220,
})

engine:load_html(win, [[
<style>
  body   { font: 14px sans-serif; padding: 16px; background: #0f172a; color: #e2e8f0; }
  input  { padding: 4px 8px; }
  button { padding: 6px 12px; border-radius: 6px; background: #2563eb; color: white; }
  .done  { color: #4ade80; }
</style>
<label>Name <input id="name" value="World"></label>
<button id="go">Greet</button>
<p id="out">Idle</p>
]])

local document = engine:document(win)
local name = document:querySelector("#name")
local out  = document:querySelector("#out")

document:querySelector("#go"):addEventListener("click", function()
  out.textContent = "Hello, " .. (name.value or "") .. "!"
  out.classList:add("done")
end)

engine:start()
```

---

Inside `<script lang="lua">`? See [scripting-api.md](scripting-api.md) for the sandboxed `astro.*` surface that ships with the same engine.



