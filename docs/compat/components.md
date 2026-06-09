# Component Compatibility

All V1 components are drawn by Astro Browser and CSS-overridable within the V1 CSS surface.

Subparts (range track/thumb, select popup, checkbox box, radio dot, etc.) are handled internally so rendering stays consistent across hosts without exposing extra DOM.

| Component / Tag | Status | Notes |
| --- | --- | --- |
| Button / `button` | supported | Click, hover/active/focus styling path. |
| Text input / `input type=text`, `input type=password` | supported | Text editing, placeholder, caret, selection path. |
| Number input / `input type=number` | supported | Custom number component path. |
| Color input / `input type=color` | supported | Custom color component path. |
| Range / `input type=range`, `slider` | supported | Slider component path. |
| Textarea / `textarea` | supported | Multiline text input. |
| Select / `select`, `option`, `optgroup` | supported | Custom select component; option and optgroup children are normalized into select options. |
| Checkbox / `input type=checkbox`, `checkbox` | supported | Checked/disabled/change state. |
| Radio / `input type=radio`, `radio` | supported | Grouped selection/change behavior. |
| Progress / `progress` | supported | Self-drawn progress bar. |
| Meter / `meter` | supported | Self-drawn meter. |
| Details/Summary / `details`, `summary` | supported | Toggle behavior. |
| Dialog / `dialog` | supported | Open state and backdrop paint path. |
| Context menu | supported | Runtime context menu system. |
| Form submission | blocked | No native browser form submit/navigation in V1. |
| IME/composition input | planned | Important future text-input hardening. |
| Drag/drop | planned | Not part of current V1 component events. |
| Accessibility tree export | planned | Needed later, not V1 runtime blocker. |



