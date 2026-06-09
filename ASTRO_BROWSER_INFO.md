# Astro Browser - Info Text

## Section 01 - Overview

Astro Browser is a lightweight Lua 5.1 UI runtime for Project Sylvanas plugins. It lets developers build browser-like plugin interfaces with HTML, CSS, and Lua scripting, without shipping a full browser engine or JavaScript runtime. The goal is practical plugin UI: windows, layout, controls, styling, events, scrolling, rendering, and controlled scripting in one compact runtime.

## Section 02 - Short Product Text

Astro Browser brings browser-style UI development to Project Sylvanas plugins. Build styled plugin windows with HTML, CSS, Lua actions, form controls, events, custom styling, SVG, fonts, animations, and DOM-style updates. It gives plugin authors a familiar workflow while staying small, deterministic, and suitable for in-game plugin environments.

## Section 03 - What It Is

Astro Browser is not a traditional web browser. It is a browser-inspired UI engine for Lua 5.1. It parses HTML and CSS, builds an internal document tree, resolves styles, computes layout, and paints through a host platform adapter. Plugin authors can describe UI declaratively instead of manually drawing every button, input, panel, list, popup, and window.

## Section 04 - Main Purpose

The runtime is designed to separate UI structure, styling, and behavior. HTML describes the interface, CSS controls appearance and layout, and Lua handles logic. This keeps plugin code focused on behavior while Astro Browser handles parsing, style resolution, layout, painting, input state, events, and UI updates.

## Section 05 - Core Runtime Features

- Lua 5.1 compatible runtime
- Local HTML and CSS parsing
- DOM-like document model
- Style engine with cascading rules
- Layout engine for common UI patterns
- Paint pipeline based on display lists
- Event system for mouse and keyboard input
- Platform adapter for host integration
- Bundle validation for stable reload behavior

## Section 06 - HTML Support

Astro Browser supports common HTML needed for plugin UI: `html`, `body`, `div`, `span`, `section`, `header`, `footer`, `main`, `nav`, `article`, text nodes, paragraphs, headings, inline text tags, lists, tables, links, styles, scripts, images, SVG, forms, and UI components. Unknown tags are accepted as generic elements.

## Section 07 - CSS Layout Features

The CSS layer supports practical layout features: box model, display modes, sizing, min/max sizes, margin, padding, border, border radius, block layout, inline layout, inline-block, absolute positioning, fixed positioning, sticky positioning, z-index, overflow, scroll containers, flexbox, grid, tables, and multicolumn layout.

## Section 08 - CSS Styling Features

Styling support includes colors, backgrounds, gradients, images, background size and position, typography, font weight, font style, line height, text alignment, white-space, text overflow, text transform, text decoration, opacity, outlines, box shadows, filters, transforms, pseudo-classes, pseudo-elements, media queries, and responsive units.

## Section 09 - Supported Components

Astro Browser includes self-drawn UI components: buttons, text inputs, password inputs, number inputs, color inputs, textareas, selects, options, checkboxes, radios, sliders, progress bars, meters, details/summary controls, dialogs, and context menus. Components support relevant states such as hover, focus, active, disabled, checked, selected, open, and changed.

## Section 10 - Events And Input

The event system handles hit testing, hover chains, focus routing, pointer events, mouse clicks, context menus, wheel scrolling, keyboard navigation, text input, tab order, enter/space activation, form changes, and script-registered actions. Components fire events consistently and keep their own state synchronized.

## Section 11 - Plugin DOM API

Plugin Lua can interact with mounted UI through document and element handles. Supported APIs include `engine:document`, `getElementById`, `querySelector`, `querySelectorAll`, `textContent`, `dataset`, attributes, classList, form values, checked state, disabled state, `addEventListener`, and `removeEventListener`. Shortcut methods exist for one-window plugins.

## Section 12 - Sandboxed Lua Scripts

HTML can include `<script lang="lua">` blocks. These scripts run once at mount time in a sandbox and can register callbacks that stay live for the window. The sandbox exposes `astro.*` helpers, state storage, timers, animation frame callbacks, logging, DOM-like handles, and safe Lua standard functions.

## Section 13 - Script API Highlights

The script API includes `astro.find`, `astro.find_all`, `astro.on_action`, `astro.on_click`, `astro.on_change`, `astro.set_state`, `astro.get_state`, `astro.set_text`, `astro.create_element`, `astro.create_text`, `astro.load_html`, `astro.load_file`, `astro.load_url`, `astro.reload`, `astro.mark_dirty`, `astro.time`, and `astro.delta_time`.

## Section 14 - Script Sandbox Limits

Sandboxed scripts do not receive unrestricted Lua access. Globals such as `_G`, `io`, `os`, `debug`, `require`, `dofile`, `loadfile`, `package`, internal core modules, and direct Project Sylvanas host APIs are intentionally unavailable. This keeps document scripts focused on UI behavior rather than host-level control.

## Section 15 - Rendering Pipeline

The rendering pipeline is deterministic. HTML and CSS are parsed, nodes are stored in a compact document store, styles are matched and resolved, layout boxes are calculated, paint commands are emitted to a display list, and the platform adapter draws primitives such as rectangles, text, textures, lines, clipping, paths, gradients, and scrollbars.

## Section 16 - Fonts And Icons

Astro Browser includes font and icon systems. It supports custom font registration, TTF and WOFF parsing, glyph caching, rasterization, hinting controls, font metric diagnostics, SVG path parsing, parsed icon trees, single-path icon registration, and icon caching so common UI symbols do not need to be reparsed every frame.

## Section 17 - Images And SVG

The runtime includes PNG and JPEG decoding, texture caching, data URI support, resource path handling, masks, and basic image workflows. SVG support covers common vector UI needs, including root SVG layout, groups, paths, shapes, transforms, viewBox mapping, presentation attributes, and useful subsets of SVG styling.

## Section 18 - Advanced Engine API

Advanced APIs include custom font registration, font hinting controls, icon registration, keyframe registration, color scheme switching, navigation handlers, device pixel ratio control, active and idle FPS caps, profiler enable/disable methods, profile statistics, lifecycle methods, window creation, content loading, start, stop, and destroy.

## Section 19 - Loading Content

The main content API is `engine:load_html(win_id, html, css, opts)`. Additional paths include `engine:load_file`, `engine:load_url`, and `engine:reload`. HTML can contain inline `<style>` blocks. External CSS can be merged. Parsed content can also be mounted multiple times for repeated panels, dialogs, or reusable UI.

## Section 20 - Runtime Entry

The public entry is `main.lua`. It exports `AstroUI.new(config)` for creating an engine, `AstroUI.replace_global(config)` for host bridge workflows, and direct references to the Engine, HTMLParser, and CSSParser modules. This keeps plugin boot code small while still exposing the core runtime APIs.

## Section 21 - Packaging

The repository is trimmed to the Astro Browser runtime and documentation. It contains the `core/` engine modules, the public loader, the Sylvanas dependency header, and docs for supported HTML, CSS, scripting, DOM access, engine APIs, compatibility, and cookbook-style implementation patterns.

## Section 22 - Host Requirements

The host platform adapter must provide drawing and runtime primitives: rectangles, lines, triangles, circles, textures, text drawing, clipping, texture loading, region drawing, text measurement, mouse state, keyboard state, wheel input, monotonic time, data-file read/write hooks, and optional HTTP or file resource loading.

## Section 23 - Project Structure

The runtime lives under `core/`. Important areas include `html`, `style`, `layout`, `paint`, `events`, `components`, `fonts`, `icons`, `svg`, `assets`, `scroll`, `script`, `platform`, `window`, `debug`, and `util`. Documentation lives under `docs/`, with compatibility references in `docs/compat/`.

## Section 24 - What It Does Not Do

Astro Browser does not aim to be a full Chrome or WebKit replacement. It has no JavaScript runtime, no arbitrary browser DOM, no full HTML5 parser recovery, no full CSS parity, no 3D transforms, no drag-and-drop, no IME composition, no accessibility tree export, no Canvas/WebGL API, and no embedded media playback.

## Section 25 - Who It Is For

Astro Browser is for Project Sylvanas plugin authors who want styled runtime UI without hand-drawing every control. It is useful when a plugin needs reusable windows, forms, settings panels, dashboards, interactive controls, styled text, responsive layout, local scripting, and a clear split between markup, style, and behavior.

## Section 26 - Summary

Astro Browser is a compact browser-style UI runtime for Lua 5.1 plugin environments. It combines HTML/CSS parsing, layout, rendering, events, components, DOM-style APIs, Lua scripting, fonts, SVG, images, windows, routing, profiling, and host integration into a practical UI layer for Project Sylvanas plugins.
