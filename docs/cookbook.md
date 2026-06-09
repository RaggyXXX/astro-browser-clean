# Cookbook

Copy-paste recipes. Each one is a complete, working `main.lua`: paste it into your plugin folder, declare the dependency in `header.lua`, and run.

---

## Recipe 0 - Plugin-Lua DOM (querySelector + addEventListener)

This is the recipe most plugin authors start with. You load a chunk of HTML/CSS, then attach behavior from your normal Lua file using the plugin DOM API - no `onClick="..."` attributes, no `<script lang="lua">` block needed.

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()

local win = engine:create_window({
  id = "intro", title = "Intro",
  x = 120, y = 120, w = 360, h = 220,
})

engine:load_html(win, [[
<style>
  body    { font: 14px sans-serif; padding: 18px; background: #0f172a; color: #e2e8f0; }
  input   { padding: 4px 8px; margin-left: 6px; }
  button  { margin-top: 10px; padding: 6px 12px; border-radius: 6px;
            background: #2563eb; color: white; }
  #out    { margin-top: 12px; }
  .done   { color: #4ade80; font-weight: 600; }
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

**What you learned:** four primitives carry most plugin UI work: `engine:document(win)` for a handle, `querySelector` to find elements, `addEventListener` to react to user input, and the element properties `.value` / `.textContent` / `.classList` to read inputs and update the UI. The full surface is in [plugin-dom.md](plugin-dom.md).

---

## Recipe 1 - A status panel that updates from Lua

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()

local win = engine:create_window({
  id = "status", title = "Status",
  x = 120, y = 120, w = 320, h = 160,
})

engine:load_html(win, [[
<style>
  body  { font: 14px sans-serif; padding: 14px; background: #0f172a; color: #e2e8f0; }
  .row  { display: flex; justify-content: space-between; margin: 6px 0; }
  .key  { color: #94a3b8; }
  .val  { font-weight: 600; }
</style>

<div class="row"><span class="key">HP</span>      <span class="val" id="hp">100</span></div>
<div class="row"><span class="key">Mana</span>    <span class="val" id="mana">50</span></div>
<div class="row"><span class="key">Targets</span> <span class="val" id="tgt">0</span></div>

<script lang="lua">
  -- Call astro.set_text from anywhere in your game loop:
  --   astro.set_text("#hp", tostring(current_hp))
  -- For periodic refresh, use setInterval:
  setInterval(function()
    astro.set_text("#hp",   tostring(math.random(50, 100)))
    astro.set_text("#mana", tostring(math.random(0,  50)))
    astro.set_text("#tgt",  tostring(math.random(0,   5)))
  end, 500)
</script>
]])

engine:start()
```

**What you learned:** `astro.set_text("#id", value)` writes into an element. `setInterval(fn, ms)` is built into the sandbox.

---

## Recipe 2 - A button that increments a counter

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()

local win = engine:create_window({
  id = "counter", title = "Counter",
  x = 140, y = 140, w = 280, h = 160,
})

engine:load_html(win, [[
<style>
  body   { font: 14px sans-serif; padding: 20px; text-align: center;
           background: #0f172a; color: #e2e8f0; }
  #n     { font-size: 32px; font-weight: 600; margin: 8px 0 16px; }
  button { padding: 8px 14px; border-radius: 6px;
           background: #2563eb; color: white; }
</style>

<div id="n">0</div>
<button onClick="inc">+1</button>

<script lang="lua">
  astro.set_state("count", 0)
  astro.on_action("inc", function()
    local n = astro.get_state("count") + 1
    astro.set_state("count", n)
    astro.set_text("#n", tostring(n))
  end)
</script>
]])

engine:start()
```

**What you learned:** `astro.set_state` / `get_state` persist a value across renders. `astro.on_action(name, fn)` binds the `onClick="name"` attribute to a Lua function. `astro.set_text` writes into a DOM element.

---

## Recipe 3 - A settings form with checkbox, slider, and Save

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()

local win = engine:create_window({
  id = "settings", title = "Settings",
  x = 160, y = 160, w = 360, h = 240,
})

engine:load_html(win, [[
<style>
  body   { font: 14px sans-serif; padding: 16px; background: #111827; color: #f9fafb; }
  label  { display: flex; align-items: center; gap: 8px; margin: 8px 0; }
  input[type=range] { flex: 1; }
  button { margin-top: 12px; padding: 8px 16px; border-radius: 6px;
           background: #2563eb; color: white; }
</style>

<label>
  <input type="checkbox" id="enabled" checked>
  Enable feature
</label>

<label>
  Opacity
  <input type="range" id="opacity" min="0" max="100" value="80">
  <span id="opacity-val">80</span>%
</label>

<button onClick="save_settings">Save</button>

<script lang="lua">
  astro.on_change("#opacity", function()
    -- input.value is always a string; convert with tonumber when you need a number
    astro.set_text("#opacity-val", astro.find("#opacity").value or "0")
  end)

  astro.on_action("save_settings", function()
    local enabled = astro.find("#enabled").checked            -- boolean
    local opacity = tonumber(astro.find("#opacity").value) or 0 -- string ->’ number
    astro.log("Saving: enabled=" .. tostring(enabled) .. " opacity=" .. opacity)
    -- Persist to wherever your plugin stores config.
  end)
</script>
]])

engine:start()
```

**What you learned:** form controls (`<input type=range>`, `<input type=checkbox>`) work out of the box. `astro.find(sel).value` is always a string; `.checked` is a boolean. `astro.on_change` fires while the user drags.

---

## Recipe 4 - A confirmation dialog

```lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")
local engine  = AstroUI.new()

local win = engine:create_window({
  id = "main", title = "Astro",
  x = 200, y = 200, w = 360, h = 200,
})

engine:load_html(win, [[
<style>
  body    { font: 14px sans-serif; padding: 16px; background: #0f172a; color: #e2e8f0; }
  button  { padding: 8px 14px; border-radius: 6px; background: #ef4444; color: white; }
  dialog  { padding: 16px; border-radius: 8px; background: #1e293b; color: #f1f5f9;
            border: 1px solid #334155; }
  .row    { display: flex; gap: 8px; margin-top: 12px; justify-content: flex-end; }
</style>

<button onClick="open_confirm">Delete account</button>

<dialog id="confirm">
  <strong>Are you sure?</strong>
  <p>This cannot be undone.</p>
  <div class="row">
    <button onClick="cancel">Cancel</button>
    <button onClick="confirm">Delete</button>
  </div>
</dialog>

<script lang="lua">
  astro.on_action("open_confirm", function() astro.find("#confirm"):show() end)
  astro.on_action("cancel",       function() astro.find("#confirm"):close() end)
  astro.on_action("confirm",      function()
    astro.find("#confirm"):close()
    astro.log("Confirmed deletion")
  end)
</script>
]])

engine:start()
```

**What you learned:** the engine ships a real `<dialog>` element with `:show()` / `:close()`. No native widget needed.

---

## Recipe 5 - A clean plugin shape

```lua
-- ext_my_plugin/main.lua
local AstroUI = require("root/ext_core_astro_ui_lib/main")

local engine = AstroUI.new()
local win    = engine:create_window({
  id = "my_plugin_main", title = "My Plugin",
  x = 100, y = 100, w = 640, h = 420,
})

engine:load_html(win, require("ui/main_page_html"), require("ui/main_page_css"))
engine:start()

return {
  unload = function() engine:destroy() end,
}
```

```lua
-- ext_my_plugin/ui/main_page_html.lua
return [[
  <h1>My Plugin</h1>
  <p>Page content here.</p>
]]
```

```lua
-- ext_my_plugin/ui/main_page_css.lua
return [[
  body { font-family: sans-serif; padding: 16px; }
]]
```

**What you learned:** keep one engine per plugin, mount once on load, call `engine:destroy()` on unload. Split content into small Lua modules that return strings.

---

## Where to go from here

- More API: [scripting-api.md](scripting-api.md)
- All HTML/CSS that works: [compat/](compat/)
- Custom fonts, icons, animations: [engine-api-advanced.md](engine-api-advanced.md)
- The full engine guide: [../GUIDE.md](../GUIDE.md)



