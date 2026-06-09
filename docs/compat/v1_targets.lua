------------------------------------------------------------
-- Machine-readable V1 compatibility target.
--
-- This file is intentionally narrower than "all browser features".
-- Builder/compiler export without warnings must stay inside these lists
-- until a feature is promoted with tests or live visual verification.
------------------------------------------------------------

return {
    html_tags = {
        "html", "body", "div", "span",
        "section", "header", "footer", "main", "nav", "article", "aside",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "p", "a", "strong", "b", "em", "i", "small", "code", "pre",
        "blockquote", "address", "center", "abbr", "cite", "q", "time",
        "var", "samp", "sub", "sup", "del", "s", "strike", "ins", "u", "kbd",
        "br", "hr",
        "ul", "ol", "menu", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "button", "input", "textarea", "select", "option", "optgroup",
        "label", "fieldset", "legend",
        "progress", "meter", "details", "summary", "dialog",
        "img",
    },

    svg_tags = {
        "svg", "g", "path", "circle", "rect", "ellipse", "line",
        "polyline", "polygon", "svg-text",
    },

    css_properties = {
        "accent-color",
        "align-content", "align-items", "align-self",
        "appearance",
        "aspect-ratio",
        "background-color", "background-image",
        "border-bottom-color", "border-bottom-left-radius", "border-bottom-right-radius",
        "border-bottom-style", "border-bottom-width",
        "border-color", "border-left-color", "border-left-style", "border-left-width",
        "border-radius", "border-right-color", "border-right-style", "border-right-width",
        "border-style", "border-top-color", "border-top-left-radius", "border-top-right-radius",
        "border-top-style", "border-top-width", "border-width",
        "box-sizing",
        "caret-color", "clear", "color", "column-gap", "content", "cursor",
        "display",
        "flex-basis", "flex-direction", "flex-grow", "flex-shrink", "flex-wrap",
        "float", "font-family", "font-size", "font-style", "font-weight",
        "gap", "height", "justify-content", "justify-items", "justify-self",
        "left", "letter-spacing", "line-height",
        "list-style-position", "list-style-type",
        "margin-bottom", "margin-left", "margin-right", "margin-top",
        "max-height", "max-width", "min-height", "min-width",
        "object-fit", "opacity", "order",
        "outline-color", "outline-offset", "outline-style", "outline-width",
        "overflow-x", "overflow-y",
        "padding-bottom", "padding-left", "padding-right", "padding-top",
        "pointer-events", "position",
        "right", "row-gap",
        "scrollbar-color", "scrollbar-width",
        "text-decoration", "text-decoration-color", "text-decoration-style",
        "text-decoration-thickness", "text-indent", "text-overflow", "text-shadow",
        "text-transform", "top",
        "user-select", "vertical-align", "visibility", "white-space",
        "width", "word-break", "word-spacing", "z-index",
    },

    css_shorthands = {
        "background", "block-size", "border", "border-block", "border-block-color",
        "border-block-end", "border-block-end-color", "border-block-end-style",
        "border-block-end-width", "border-block-start", "border-block-start-color",
        "border-block-start-style", "border-block-start-width", "border-block-style",
        "border-block-width", "border-end-end-radius", "border-end-start-radius",
        "border-inline", "border-inline-color", "border-inline-end",
        "border-inline-end-color", "border-inline-end-style", "border-inline-end-width",
        "border-inline-start", "border-inline-start-color", "border-inline-start-style",
        "border-inline-start-width", "border-inline-style", "border-inline-width",
        "border-start-end-radius", "border-start-start-radius",
        "flex", "font", "inline-size", "inset", "inset-block", "inset-block-end",
        "inset-block-start", "inset-inline", "inset-inline-end", "inset-inline-start",
        "margin", "margin-block", "margin-block-end",
        "margin-block-start", "margin-inline", "margin-inline-end", "margin-inline-start",
        "max-block-size", "max-inline-size", "min-block-size", "min-inline-size",
        "outline", "overflow", "overflow-block", "overflow-inline",
        "overscroll-behavior", "padding", "padding-block", "padding-block-end",
        "padding-block-start", "padding-inline", "padding-inline-end",
        "padding-inline-start", "place-content", "place-items", "place-self",
        "scroll-margin", "scroll-padding",
    },

    pseudo_classes = {
        "active", "checked", "dir", "disabled", "empty", "enabled",
        "first-child", "first-of-type", "focus", "focus-visible", "focus-within",
        "has", "hover", "invalid", "is", "lang", "last-child", "last-of-type",
        "link", "not",
        "nth-child", "nth-last-child", "nth-last-of-type", "nth-of-type",
        "only-child", "only-of-type", "optional", "placeholder-shown",
        "read-only", "read-write", "required", "root", "valid", "visited",
        "where",
    },

    pseudo_elements = {
        "after", "before", "first-letter", "first-line", "marker",
    },

    live_gates = {
        "browser_shell",
        "ua_defaults_text",
        "ua_defaults_forms",
        "ua_defaults_tables",
        "ua_defaults_controls_states",
        "ua_defaults_responsive",
        "final_app",
    },
}



