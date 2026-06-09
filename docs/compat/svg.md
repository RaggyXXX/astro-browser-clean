# SVG Compatibility

Astro Browser renders SVG itself; it does not delegate to a browser SVG engine.

## Elements

| Element | Status | Notes |
| --- | --- | --- |
| `svg` | partial | Root layout, viewBox, viewport clipping. |
| `g` | supported | Group transform/style inheritance. |
| `path` | supported | M/L/H/V/C/S/Q/T/A/Z absolute and relative paths via parser/tessellation. |
| `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon` | supported | Shape conversion/fast paths. |
| `svg-text` | partial | Basic text paint; not full SVG text layout. |
| `defs`, `use`, `symbol` | planned | Needed for richer icon systems; not full DOM support yet. |
| `clipPath`, `mask` | planned | CSS clip/mask has subset support; SVG DOM clipPath/mask is not complete. |
| SVG gradients/patterns | planned | Browser SVG paint servers not complete. |
| SVG filters, markers | planned | Deferred advanced vector effects. |

## Attributes And Styling

| Area | Status | Notes |
| --- | --- | --- |
| `fill`, `stroke`, `stroke-width`, opacity attrs | supported | Presentation attribute and inline style resolution. |
| `stroke-linecap`, `stroke-linejoin`, dash attrs | partial | Stroke tessellation path exists; visual parity still needs gates. |
| `transform` | supported | translate/scale/rotate/skew/matrix. |
| `viewBox` | supported | Viewbox mapping. |
| CSS inheritance inside SVG | partial | Useful subset, not full SVG/CSS cascade parity. |



