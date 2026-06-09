# Astro Browser (Astro UI Library)

Astro Browser is a lightweight Lua 5.1 UI runtime for Project Sylvanas plugins that lets you build browser-like interfaces with HTML, CSS, and Lua scripting.

You write structure in familiar HTML, style it with CSS, and handle interactions with Lua. No browser engine is required, there is no JavaScript runtime to ship, and plugin code stays focused on behavior.

## What Astro Browser Gives You

- Compact Lua runtime entry through `main.lua`
- HTML and CSS parsing that runs locally in-process
- Common form controls: buttons, inputs, selects, textareas, checkboxes, sliders, dialogs, progress bars, details/summary, and more
- DOM-like plugin API for querying and updating mounted pages from your own `main.lua`
- Sandboxed in-document Lua scripting (`<script lang="lua">`) for declarative behavior
- Style engine with practical CSS coverage for day-to-day plugin UI
- Event model for click/change/input/key workflows and basic pointer + keyboard behavior
- Font, icon, keyframe, and theme extension points
- Deterministic bundle parsing and validation for stable reload behavior

## Quick start

1. Keep the module dependencies in `header.lua`.
2. Load the runtime with `local AstroUI = require("root/ext_core_astro_ui_lib/main")`.
3. Create an engine with `local engine = AstroUI.new()`.
4. Create a window, mount content with `engine:load_html(...)`, then call `engine:start()`.

## Who this is for

Astro Browser is intended for Sylvanas plugins that need fast, styled runtime UI without custom rendering code for every control.

Start with the documentation index, then move to:

- [docs/README.md](docs/README.md) for the full docs index
- [docs/cookbook.md](docs/cookbook.md) for ready-to-paste recipes
- [docs/supported.md](docs/supported.md) for feature coverage and limits

---

Astro Browser is intentionally pragmatic: it gives you the browser-like primitives you actually use, and leaves the heavy lifting of full web parity for later. That keeps plugins small, predictable, and easy to maintain.



