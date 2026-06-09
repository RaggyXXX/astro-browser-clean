# Astro Compatibility Matrix

This folder is the per-feature reference for what HTML, CSS, components, and selectors the Astro Browser runtime accepts.

For the **input path** (how to feed HTML and CSS into the engine, what the parsers do and do not accept), see [../html-css.md](../html-css.md).

`v1_targets.lua` is the machine-readable V1 gate. The Markdown files explain the product surface.

## Status Values

| Status | Meaning |
| --- | --- |
| `supported` | Parser and runtime semantics are available for V1 use. |
| `partial` | Usable for common UI work, but not full Chrome parity. Builder should constrain values. |
| `planned` | Desired for V1/V1.x, but not safe for unrestricted builder export yet. |
| `blocked` | Not part of V1, or impossible without a larger subsystem/API. |

## Rule

Nothing should be called `supported` in product copy unless it is listed as `supported` here and has runtime coverage or live visual verification.

The reduced Astro Browser package keeps this matrix as documentation only.



