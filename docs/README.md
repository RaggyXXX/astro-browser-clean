# Astro UI Documentation

Astro Browser is a UI runtime for Project Sylvanas plugins. You write HTML and CSS, the engine parses, lays out, and paints it.

## I just want to...

| Task | Read |
| --- | --- |
| Get my first window on screen | [../README.md](../README.md#quick-start) |
| Copy-paste working recipes | [cookbook.md](cookbook.md) |
| Learn the runtime layout | [../GUIDE.md](../GUIDE.md) |
| Pass HTML/CSS strings programmatically | [html-css.md](html-css.md) |
| `<script lang="lua">` inside the HTML | [scripting-api.md](scripting-api.md) |
| Your plugin Lua (`main.lua`) | [plugin-dom.md](plugin-dom.md) |
| Read the value of an input or checkbox | [scripting-api.md#finding-elements](scripting-api.md#finding-elements) |
| Load custom fonts or icons | [engine-api-advanced.md](engine-api-advanced.md) |
| Close or destroy a window when my plugin unloads | [../GUIDE.md#6-engine-lifecycle](../GUIDE.md#6-engine-lifecycle) |
| My window does not appear or text is wrong size | [../GUIDE.md#17-troubleshooting](../GUIDE.md#17-troubleshooting) |
| Check what HTML, CSS, components are supported | [supported.md](supported.md), [compat/](compat/) |

## Full reading path

If you prefer linear reading:

1. [../README.md](../README.md) - install and quickstart
2. [cookbook.md](cookbook.md) - copy-paste recipes
3. [../GUIDE.md](../GUIDE.md) - engine lifecycle, windows, content loading, components, performance, troubleshooting
4. [html-css.md](html-css.md) - HTML/CSS input, parser surface
5. [scripting-api.md](scripting-api.md) - `astro.*` sandbox API
6. [plugin-dom.md](plugin-dom.md) - plugin-side DOM API (`engine:document`, `querySelector`, `addEventListener`)
7. [engine-api-advanced.md](engine-api-advanced.md) - fonts, icons, keyframes, theming, navigation, FPS, profiler
8. [supported.md](supported.md) - what V1 supports and what it does not
9. [compat/](compat/) - per-feature reference
10. [../README.md](../README.md) - project overview and quick links

## Status

- Engine: `0.3.0-beta`
- Runtime entry: [../main.lua](../main.lua)

## What is not in these docs

The engine includes local HTML and CSS parsers - see [html-css.md](html-css.md). The internal shape of parsed bundles remains an implementation detail for plugin authors.



