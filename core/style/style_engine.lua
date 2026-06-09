------------------------------------------------------------
-- ext_core_astro_ui_lib / core / style / style_engine.lua
-- CSS property resolution: constants, defaults, UA defaults,
-- rule matching, and computed style resolution.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local SelectorMatcher = require("core/style/selector_matcher")

local SE = {}
SE.__index = SE

------------------------------------------------------------
-- Property ID constants
------------------------------------------------------------
SE.PROP = {
    display           = 1,
    position          = 2,
    width             = 3,
    height            = 4,
    padding_top       = 5,
    padding_right     = 6,
    padding_bottom    = 7,
    padding_left      = 8,
    margin_top        = 9,
    margin_right      = 10,
    margin_bottom     = 11,
    margin_left       = 12,
    border_width      = 13,
    border_color      = 14,
    border_radius     = 15,
    background_color  = 16,
    color             = 17,
    font_size         = 18,
    text_align        = 19,
    white_space       = 20,
    text_overflow     = 21,
    overflow_x        = 22,
    overflow_y        = 23,
    flex_direction    = 24,
    flex_wrap         = 25,
    flex_grow         = 26,
    flex_shrink       = 27,
    flex_basis        = 28,
    opacity           = 29,
    visibility        = 30,
    z_index           = 31,
    left              = 32,
    top               = 33,
    right             = 34,
    bottom            = 35,
    align_items       = 36,
    align_self        = 37,
    align_content     = 38,
    justify_content   = 39,
    box_sizing        = 40,
    line_height       = 41,
    cursor            = 42,
    gap               = 43,
    min_width         = 44,
    min_height        = 45,
    max_width         = 46,
    max_height        = 47,
    order             = 48,
    row_gap           = 49,
    column_gap        = 50,
    font_family       = 51,
    font_weight       = 52,
    font_style        = 53,
    letter_spacing    = 54,
    word_spacing      = 55,
    text_decoration   = 56,
    text_transform    = 57,
    text_indent       = 58,
    text_shadow       = 59,
    icon              = 60,
    icon_size         = 61,
    -- Tier 1 new properties
    grid_template_columns = 62,
    grid_template_rows    = 63,
    grid_auto_rows        = 64,
    grid_auto_columns     = 65,
    grid_column           = 66,
    grid_row              = 67,
    grid_column_start     = 68,
    grid_column_end       = 69,
    grid_row_start        = 70,
    grid_row_end          = 71,
    justify_items         = 72,
    transform             = 73,
    transform_origin      = 74,
    object_fit            = 75,
    background_image      = 76,
    background_size       = 77,
    background_position   = 78,
    background_repeat     = 79,
    transition_property          = 80,
    transition_duration          = 81,
    transition_timing_function   = 82,
    transition_delay             = 83,
    animation_name               = 84,
    animation_duration           = 85,
    animation_delay              = 86,
    animation_iteration_count    = 87,
    animation_direction          = 88,
    animation_timing_function    = 89,
    animation_fill_mode          = 90,
    -- Tier 2 new properties
    border_top_width             = 91,
    border_right_width           = 92,
    border_bottom_width          = 93,
    border_left_width            = 94,
    border_top_color             = 95,
    border_right_color           = 96,
    border_bottom_color          = 97,
    border_left_color            = 98,
    border_style                 = 99,
    border_top_style             = 100,
    border_right_style           = 101,
    border_bottom_style          = 102,
    border_left_style            = 103,
    box_shadow                   = 104,
    outline_width                = 105,
    outline_color                = 106,
    outline_offset               = 107,
    outline_style                = 108,
    content                      = 109,
    -- Tier 3 new properties
    pointer_events               = 110,
    aspect_ratio                 = 111,
    vertical_align               = 112,
    word_break                   = 113,
    overflow_wrap                = 114,
    -- Per-corner border-radius
    border_top_left_radius       = 115,
    border_top_right_radius      = 116,
    border_bottom_right_radius   = 117,
    border_bottom_left_radius    = 118,
    -- Tier 4: new CSS properties
    float                        = 119,
    clear                        = 120,
    text_decoration_color        = 121,
    text_decoration_style        = 122,
    text_decoration_thickness    = 123,
    list_style_type              = 124,
    list_style_position          = 125,
    border_collapse              = 126,
    border_spacing               = 127,
    -- Tier 5: remaining CSS features
    filter                       = 128,
    column_count                 = 129,
    column_width                 = 130,
    column_rule_width            = 131,
    column_rule_color            = 132,
    column_rule_style            = 133,
    counter_reset                = 134,
    counter_increment            = 135,
    clip_path                    = 136,
    -- Tier 6: critical missing features
    backdrop_filter              = 137,
    line_clamp                   = 138,
    direction                    = 139,
    writing_mode                 = 140,
    unicode_bidi                 = 141,
    animation_play_state         = 142,
    user_select                  = 143,
    scroll_behavior              = 144,
    scroll_snap_type             = 145,
    scroll_snap_align            = 146,
    resize                       = 147,
    background_clip              = 148,
    caret_color                  = 149,
    accent_color                 = 150,
    tab_size                     = 151,
    text_align_last              = 152,
    overscroll_behavior_x        = 153,
    overscroll_behavior_y        = 154,
    scroll_padding_top           = 155,
    scroll_padding_right         = 156,
    scroll_padding_bottom        = 157,
    scroll_padding_left          = 158,
    scroll_margin_top            = 159,
    scroll_margin_right          = 160,
    scroll_margin_bottom         = 161,
    scroll_margin_left           = 162,
    mix_blend_mode               = 163,
    grid_template_areas          = 164,
    grid_area                    = 165,
    grid_auto_flow               = 166,
    mask_image                   = 167,
    mask_size                    = 168,
    mask_position                = 169,
    mask_repeat                  = 170,
    text_wrap                    = 171,
    hyphens                      = 172,
    font_variant                 = 173,
    font_stretch                 = 174,
    container_type               = 175,
    container_name               = 176,
    contain                      = 177,
    isolation                    = 178,
    background_attachment        = 179,
    background_origin            = 180,
    list_style_image             = 181,
    scrollbar_color              = 182,
    scrollbar_width              = 183,
    justify_self                 = 184,
    appearance                   = 185,
    table_layout                 = 186,
}

------------------------------------------------------------
-- PROP_TO_KEY: maps property ID -> computed style key name
------------------------------------------------------------
local PROP_TO_KEY = {}
for name, id in pairs(SE.PROP) do
    PROP_TO_KEY[id] = name
end

-- Properties that inherit by default (CSS spec)
local INHERITED = {
    color = true, font_size = true, font_family = true, font_weight = true,
    font_style = true, line_height = true, text_align = true, white_space = true,
    text_overflow = true, letter_spacing = true, word_spacing = true,
    text_transform = true, text_indent = true, visibility = true, cursor = true,
    pointer_events = true, word_break = true, overflow_wrap = true,
    list_style_type = true, list_style_position = true,
    direction = true, writing_mode = true,
    user_select = true,
    caret_color = true,
    accent_color = true,
    tab_size = true,
    text_align_last = true,
}

------------------------------------------------------------
-- Default computed style
------------------------------------------------------------
SE.DEFAULTS = {
    display           = "block",
    position          = "static",
    width             = "auto",
    height            = "auto",
    padding_top       = 0,
    padding_right     = 0,
    padding_bottom    = 0,
    padding_left      = 0,
    margin_top        = 0,
    margin_right      = 0,
    margin_bottom     = 0,
    margin_left       = 0,
    border_width      = 0,
    border_color      = { 60, 60, 70, 255 },
    border_radius     = 0,
    background_color  = { 0, 0, 0, 0 },  -- transparent until html/body UA defaults paint the page
    color             = { 0, 0, 0, 255 },
    font_size         = 16,
    text_align        = "left",
    white_space       = "normal",
    text_overflow     = "clip",
    overflow_x        = "visible",
    overflow_y        = "visible",
    flex_direction    = "row",
    flex_wrap         = "nowrap",
    flex_grow         = 0,
    flex_shrink       = 1,
    flex_basis        = "auto",
    opacity           = 255,
    visibility        = "visible",
    z_index           = "auto",
    left              = "auto",
    top               = "auto",
    right             = "auto",
    bottom            = "auto",
    align_items       = "stretch",
    align_self        = "auto",
    justify_self      = "auto",
    align_content     = "stretch",
    justify_content   = "flex-start",
    -- CSS spec initial value for box-sizing is `content-box`. We previously
    -- defaulted to `border-box` which broke Chrome parity for any project
    -- that set width+padding+border without an explicit box_sizing
    -- declaration (the browser-parity case surfaced this immediately: width:200 +
    -- padding 5+15 + border 1+3 should be a 200x60 content + 24 vertical
    -- padding/border = 84-tall outer box; border-box-default produced a
    -- 60-tall outer instead). Explicit box_sizing remains honored.
    box_sizing        = "content-box",
    -- CSS initial value for line-height is "normal". block.lua and
    -- painters.lua resolve "normal" via the active font's hhea metrics
    -- (ascent + |descent| + lineGap), matching Chrome's font-derived
    -- normal height rather than a hardcoded multiplier. Authors who
    -- want an explicit ratio set a numeric (e.g. 1.5) -" see Block
    -- _resolve_line_h for the full resolution rules.
    line_height       = "normal",
    cursor            = "default",
    gap               = 0,
    min_width         = 0,
    min_height        = 0,
    max_width         = "none",
    max_height        = "none",
    order             = 0,
    row_gap           = 0,
    column_gap        = 0,
    font_family       = nil,    -- nil = use built-in font
    font_weight       = 400,
    font_style        = "normal",
    letter_spacing    = 0,
    word_spacing      = 0,
    text_decoration   = "none",
    text_transform    = "none",
    text_indent       = 0,
    text_shadow       = nil,
    icon              = nil,
    icon_size         = nil,
    -- Tier 1 defaults
    grid_template_columns = nil,
    grid_template_rows    = nil,
    grid_auto_rows        = "auto",
    grid_auto_columns     = "auto",
    grid_column           = nil,
    grid_row              = nil,
    grid_column_start     = "auto",
    grid_column_end       = "auto",
    grid_row_start        = "auto",
    grid_row_end          = "auto",
    justify_items         = "stretch",
    transform             = nil,
    transform_origin      = nil,
    object_fit            = "fill",
    background_image      = nil,
    background_size       = "auto",
    background_position   = nil,
    background_repeat     = "repeat",
    background_clip       = "border-box",
    transition_property          = nil,
    transition_duration          = 0,
    transition_timing_function   = "ease",
    transition_delay             = 0,
    animation_name               = nil,
    animation_duration           = 0,
    animation_delay              = 0,
    animation_iteration_count    = 1,
    animation_direction          = "normal",
    animation_timing_function    = "ease",
    animation_fill_mode          = "none",
    -- Tier 2 defaults
    border_top_width             = nil,   -- nil = fallback to border_width
    border_right_width           = nil,
    border_bottom_width          = nil,
    border_left_width            = nil,
    border_top_color             = nil,   -- nil = fallback to border_color
    border_right_color           = nil,
    border_bottom_color          = nil,
    border_left_color            = nil,
    border_style                 = "solid",
    border_top_style             = nil,   -- nil = fallback to border_style
    border_right_style           = nil,
    border_bottom_style          = nil,
    border_left_style            = nil,
    box_shadow                   = nil,
    outline_width                = 0,
    outline_color                = nil,
    outline_offset               = 0,
    outline_style                = "solid",
    content                      = nil,
    -- Tier 3 defaults
    pointer_events               = "auto",
    aspect_ratio                 = nil,      -- nil = no constraint
    vertical_align               = "baseline",
    word_break                   = "normal",
    overflow_wrap                = "normal",
    -- Per-corner border-radius (nil = use uniform border_radius)
    border_top_left_radius       = nil,
    border_top_right_radius      = nil,
    border_bottom_right_radius   = nil,
    border_bottom_left_radius    = nil,
    -- Tier 4 defaults
    float                        = "none",
    clear                        = "none",
    text_decoration_color        = nil,   -- nil = use text color
    text_decoration_style        = "solid",
    text_decoration_thickness    = nil,   -- nil = 1px default
    list_style_type              = nil,   -- nil = inherit from parent / UA
    list_style_position          = "outside",
    border_collapse              = "separate",
    border_spacing               = 0,
    -- Tier 5 defaults
    filter                       = nil,       -- nil = no filter
    column_count                 = nil,       -- nil = auto (no multi-column)
    column_width                 = nil,       -- nil = auto
    column_rule_width            = 0,
    column_rule_color            = nil,       -- nil = use text color
    column_rule_style            = "none",
    counter_reset                = nil,       -- nil = no counters
    counter_increment            = nil,       -- nil = no increment
    clip_path                    = nil,       -- nil = no clipping
    -- Tier 6 defaults
    backdrop_filter              = nil,       -- nil = no backdrop filter
    line_clamp                   = nil,       -- nil = no line clamping
    direction                    = "ltr",     -- text direction
    writing_mode                 = "horizontal-tb",
    unicode_bidi                 = "normal",
    animation_play_state         = "running",
    user_select                  = "auto",
    scroll_behavior              = "auto",
    scroll_snap_type             = "none",
    scroll_snap_align            = "none",
    resize                       = "none",
    -- Tier 7: tab-size and text-align-last
    tab_size                     = 8,         -- default: 8 spaces
    text_align_last              = "auto",    -- default: use text-align
    -- Tier 8: overscroll-behavior, scroll-padding, scroll-margin
    overscroll_behavior_x        = "auto",
    overscroll_behavior_y        = "auto",
    scroll_padding_top           = 0,
    scroll_padding_right         = 0,
    scroll_padding_bottom        = 0,
    scroll_padding_left          = 0,
    scroll_margin_top            = 0,
    scroll_margin_right          = 0,
    scroll_margin_bottom         = 0,
    scroll_margin_left           = 0,
    -- Tier 9: compositing
    mix_blend_mode               = "normal",
    appearance                   = "auto",
    table_layout                 = "auto",
}

-- Shared metatable for computed styles -" provides defaults via __index.
-- Eliminates per-node DEFAULTS deep-copy (~20K allocs for 1000 nodes).
SE.DEFAULTS_MT = { __index = SE.DEFAULTS }

-- Properties whose value can be `currentcolor`.  After cascade, any of these
-- that still carry a `{type = "currentcolor"}` sentinel are resolved
-- against the element's computed `color`.
SE._CURRENT_COLOR_PROPS = {
    "background_color",
    "border_color",
    "border_top_color",
    "border_right_color",
    "border_bottom_color",
    "border_left_color",
    "outline_color",
    "text_decoration_color",
    "column_rule_color",
    "caret_color",
    "accent_color",
    "scrollbar_color",
}

------------------------------------------------------------
-- UA (User Agent) defaults by tag name
------------------------------------------------------------
SE.UA_DEFAULTS = {
    html = {
        display          = "block",
        background_color = { 255, 255, 255, 255 },
        color            = { 0, 0, 0, 255 },
        font_family      = "Times New Roman, serif",
    },
    body = {
        display          = "block",
        margin_top       = 8,
        margin_right     = 8,
        margin_bottom    = 8,
        margin_left      = 8,
        background_color = { 255, 255, 255, 255 },
        color            = { 0, 0, 0, 255 },
        font_family      = "Times New Roman, serif",
    },
    div = {
        display          = "block",
    },
    template = {
        display          = "none",
    },
    -- SVG elements: inline-block with overflow hidden (like Chrome)
    svg = {
        display         = "block",
        overflow_x      = "hidden",
        overflow_y      = "hidden",
        flex_shrink     = 0,
    },
    -- SVG child tags: display none in normal CSS context
    -- (they are rendered by the SVG renderer, not the HTML painter)
    g        = { display = "block" },
    path     = { display = "block" },
    circle   = { display = "block" },
    ellipse  = { display = "block" },
    line     = { display = "block" },
    polyline = { display = "block" },
    polygon  = { display = "block" },
    ["svg-text"] = { display = "block" },
    button = {
        display          = "inline-block",
        padding_top      = 2,
        padding_right    = 6,
        padding_bottom   = 2,
        padding_left     = 6,
        background_color = { 240, 240, 240, 255 },
        color            = { 0, 0, 0, 255 },
        border_width     = 1,
        border_color     = { 118, 118, 118, 255 },
        border_radius    = 2,
        text_align       = "center",
        cursor           = "pointer",
        font_family      = "Arial",
        font_size        = 13.333,
        line_height      = 1.2,
        appearance       = "auto",
    },
    input = {
        display          = "inline-block",
        padding_top      = 1,
        padding_right    = 2,
        padding_bottom   = 1,
        padding_left     = 2,
        width            = 160,
        height           = 22,
        box_sizing       = "border-box",
        background_color = { 255, 255, 255, 255 },
        color            = { 0, 0, 0, 255 },
        border_width     = 1,
        border_color     = { 118, 118, 118, 255 },
        white_space      = "nowrap",
        overflow_x       = "hidden",
        cursor           = "text",
        font_family      = "Arial",
        font_size        = 13.333,
        line_height      = 1.2,
        appearance       = "auto",
    },
    checkbox = {
        display         = "inline-block",
        width           = 13,
        height          = 13,
        border_width    = 1,
        border_color    = { 118, 118, 118, 255 },
        background_color = { 255, 255, 255, 255 },
        margin_top      = 3,
        margin_right    = 3,
        margin_bottom   = 3,
        margin_left     = 4,
        cursor          = "pointer",
        appearance      = "auto",
    },
    radio = {
        display          = "inline-block",
        width           = 13,
        height          = 13,
        background_color = { 255, 255, 255, 255 },
        margin_top       = 3,
        margin_right     = 3,
        margin_bottom    = 3,
        margin_left      = 4,
        cursor          = "pointer",
        appearance      = "auto",
    },
    select = {
        display          = "inline-block",
        padding_top      = 1,
        padding_right    = 20,
        padding_bottom   = 1,
        padding_left     = 4,
        width            = 80,
        height           = 22,
        min_width        = 80,
        background_color = { 255, 255, 255, 255 },
        color            = { 0, 0, 0, 255 },
        border_width     = 1,
        border_color     = { 118, 118, 118, 255 },
        cursor           = "default",
        font_family      = "Arial",
        font_size        = 13.333,
        line_height      = 1.2,
        appearance       = "auto",
    },
    option = {
        display          = "none",
        color            = { 0, 0, 0, 255 },
        background_color = { 255, 255, 255, 255 },
    },
    optgroup = {
        display          = "none",
        color            = { 0, 0, 0, 255 },
        background_color = { 255, 255, 255, 255 },
        font_weight      = 700,
    },
    slider = {
        display         = "inline-block",
        width           = 129,
        height          = 20,
        cursor          = "pointer",
        appearance      = "auto",
    },
    switch = {
        display          = "inline-block",
        width            = 38,
        height           = 20,
        box_sizing       = "border-box",
        background_color = { 0, 0, 0, 0 },
        border_width     = 0,
        accent_color     = { 0, 95, 184, 255 },
        cursor           = "pointer",
    },
    h1 = {
        display         = "block",
        font_size       = 32,
        font_weight     = 700,
        margin_top      = 21,
        margin_bottom   = 21,
    },
    h2 = {
        display         = "block",
        font_size       = 24,
        font_weight     = 700,
        margin_top      = 20,
        margin_bottom   = 20,
    },
    h3 = {
        display         = "block",
        font_size       = 18.72,
        font_weight     = 700,
        margin_top      = 18.72,
        margin_bottom   = 18.72,
    },
    h4 = {
        display         = "block",
        font_size       = 16,
        font_weight     = 700,
        margin_top      = 21,
        margin_bottom   = 21,
    },
    h5 = {
        display         = "block",
        font_size       = 13.28,
        font_weight     = 700,
        margin_top      = 22.18,
        margin_bottom   = 22.18,
    },
    h6 = {
        display         = "block",
        font_size       = 10.72,
        font_weight     = 700,
        margin_top      = 24.98,
        margin_bottom   = 24.98,
    },
    p = {
        display         = "block",
        -- CSS UA: `p { margin: 1em 0 }`. Chrome resolves 1em against the
        -- element's own font-size, not body's. Hardcoded 16 used to drift
        -- by 2px per side on any <p> with non-16 font_size (e.g. inherited
        -- 14 from main → Chrome 14, engine 16, +2 each side).
        margin_top      = { type = "em", v = 1 },
        margin_bottom   = { type = "em", v = 1 },
    },
    a = {
        display         = "inline",
        color           = { 0, 0, 238, 255 },
        text_decoration = "underline",
        cursor          = "pointer",
    },
    ul = {
        display         = "block",
        padding_left    = 40,
        margin_top      = 16,
        margin_bottom   = 16,
        list_style_type = "disc",
    },
    ol = {
        display         = "block",
        padding_left    = 40,
        margin_top      = 16,
        margin_bottom   = 16,
        list_style_type = "decimal",
    },
    li = {
        display         = "list-item",
    },
    strong = {
        display         = "inline",
        font_weight     = 700,
    },
    b = {
        display         = "inline",
        font_weight     = 700,
    },
    em = {
        display         = "inline",
        font_style      = "italic",
    },
    i = {
        display         = "inline",
        font_style      = "italic",
    },
    small = {
        display         = "inline",
        font_size       = 13,
    },
    mark = {
        display         = "inline",
        background_color = { 255, 255, 0, 255 },
        color           = { 0, 0, 0, 255 },
    },
    br = {
        display         = "block",
        height          = 0,
    },
    pre = {
        display         = "block",
        white_space     = "pre",
        font_family     = "monospace",
        font_size       = 13,
        margin_top      = 13,   -- 1em * 13px
        margin_bottom   = 13,
    },
    code = {
        display         = "inline",
        font_family     = "monospace",
        font_size       = 13,
    },
    hr = {
        display         = "block",
        height          = 2,
        margin_top      = 8,
        margin_bottom   = 8,
        border_width    = 1,
        border_color    = { 128, 128, 128, 255 },
    },
    textarea = {
        display          = "inline-block",
        padding_top      = 2,
        padding_right    = 2,
        padding_bottom   = 2,
        padding_left     = 2,
        width            = 200,
        height           = 44,
        background_color = { 255, 255, 255, 255 },
        color            = { 0, 0, 0, 255 },
        border_width     = 1,
        border_color     = { 118, 118, 118, 255 },
        white_space      = "pre-wrap",
        overflow_y       = "auto",
        min_height       = 0,
        cursor           = "text",
        font_family      = "Arial",
        font_size        = 13.333,
        line_height      = 1.2,
        resize           = "both",
        appearance       = "auto",
    },
    -- Semantic block elements
    blockquote = {
        display         = "block",
        margin_top      = 16,
        margin_bottom   = 16,
        margin_left     = 40,
        margin_right    = 40,
    },
    dl = {
        display         = "block",
        margin_top      = 16,
        margin_bottom   = 16,
    },
    dt = {
        display         = "block",
    },
    dd = {
        display         = "block",
        margin_left     = 40,
    },
    menu = {
        display         = "block",
        padding_left    = 40,
        margin_top      = 16,
        margin_bottom   = 16,
        list_style_type = "disc",
    },
    address = {
        display         = "block",
        font_style      = "italic",
    },
    center = {
        display         = "block",
        text_align      = "center",
    },
    abbr = {
        display         = "inline",
    },
    cite = {
        display         = "inline",
        font_style      = "italic",
    },
    q = {
        display         = "inline",
    },
    time = {
        display         = "inline",
    },
    var = {
        display         = "inline",
        font_style      = "italic",
    },
    samp = {
        display         = "inline",
        font_family     = "monospace",
        font_size       = 13,
    },
    sub = {
        display         = "inline",
        font_size       = 11,
        vertical_align  = "sub",
    },
    sup = {
        display         = "inline",
        font_size       = 11,
        vertical_align  = "super",
    },
    del = {
        display         = "inline",
        text_decoration = "line-through",
    },
    s = {
        display         = "inline",
        text_decoration = "line-through",
    },
    strike = {
        display         = "inline",
        text_decoration = "line-through",
    },
    ins = {
        display         = "inline",
        text_decoration = "underline",
    },
    u = {
        display         = "inline",
        text_decoration = "underline",
    },
    kbd = {
        display         = "inline",
        font_family     = "monospace",
        font_size       = 13,
    },
    section = { display = "block" },
    article = { display = "block" },
    nav     = { display = "block" },
    aside   = { display = "block" },
    header  = { display = "block" },
    footer  = { display = "block" },
    main    = { display = "block" },
    figure = {
        display         = "block",
        margin_top      = 16,
        margin_bottom   = 16,
        margin_left     = 40,
        margin_right    = 40,
    },
    figcaption = {
        display         = "block",
        text_align      = "center",
        font_size       = 13,
        color           = { 160, 160, 170, 255 },
    },
    span     = { display = "inline" },
    form     = { display = "block" },
    label    = { display = "inline", cursor = "pointer" },
    fieldset = {
        display         = "block",
        padding_top     = 8,
        padding_right   = 12,
        padding_bottom  = 8,
        padding_left    = 12,
        border_width    = 2,
        border_color    = { 192, 192, 192, 255 },
        border_radius   = 2,
        margin_left     = 2,
        margin_right    = 2,
    },
    legend = {
        display         = "block",
        padding_left    = 4,
        padding_right   = 4,
        color           = { 0, 0, 0, 255 },
    },
    -- <dialog>: hidden until `open` attribute is present. Dialog component
    -- flips display at runtime (same pattern as <details>).
    dialog = {
        display         = "none",
        position        = "fixed",
        top             = "10vh",
        left             = "10vw",
        width           = "80vw",
        padding_top     = 16,
        padding_right   = 16,
        padding_bottom  = 16,
        padding_left    = 16,
        background_color = { 255, 255, 255, 255 },
        color           = { 0, 0, 0, 255 },
        border_radius   = 0,
        border_width    = 1,
        border_color    = { 0, 0, 0, 255 },
        box_shadow      = "0px 8px 24px 0px rgba(0,0,0,0.25)",
        max_height      = "80vh",
        z_index         = 1000,
        box_sizing      = "border-box",
    },
    -- Table elements (proper CSS table display types)
    table = {
        display         = "table",
        border_collapse = "separate",
        border_spacing  = 2,
    },
    thead = {
        display         = "table-header-group",
    },
    tbody = {
        display         = "table-row-group",
    },
    tfoot = {
        display         = "table-footer-group",
    },
    tr = {
        display         = "table-row",
    },
    td = {
        display         = "table-cell",
        padding_top     = 4,
        padding_right   = 8,
        padding_bottom  = 4,
        padding_left    = 8,
        border_width    = 0,
        border_color    = { 128, 128, 128, 255 },
        vertical_align  = "middle",
    },
    th = {
        display         = "table-cell",
        padding_top     = 4,
        padding_right   = 8,
        padding_bottom  = 4,
        padding_left    = 8,
        border_width    = 0,
        border_color    = { 128, 128, 128, 255 },
        font_weight     = 700,
        text_align      = "center",
        vertical_align  = "middle",
    },
    caption = {
        display         = "table-caption",
        text_align      = "center",
        padding_top     = 4,
        padding_bottom  = 4,
    },
    -- Media / embed placeholders
    iframe = {
        display         = "block",
        width           = 300,
        height          = 150,
        border_width    = 2,
        border_color    = { 0, 0, 0, 255 },
        background_color = { 255, 255, 255, 255 },
    },
    video = {
        display         = "inline-block",
        width           = 300,
        height          = 150,
        background_color = { 0, 0, 0, 255 },
    },
    audio = {
        display         = "inline-block",
        width           = 300,
        height          = 32,
        background_color = { 240, 240, 240, 255 },
        border_radius   = 16,
    },
    img = {
        display         = "inline-block",
        color           = { 0, 0, 0, 255 },
    },
    progress = {
        display         = "inline-block",
        width           = 160,
        height          = 16,
    },
    meter = {
        display         = "inline-block",
        width           = 160,
        height          = 16,
    },
    details = {
        display         = "block",
    },
    summary = {
        display         = "block",
        cursor          = "pointer",
    },
}

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new StyleEngine.
---@param node_store table  NodeStore instance
---@return table  StyleEngine instance
function SE.new(node_store)
    local self = setmetatable({}, SE)
    self.ns              = node_store
    self.rules_by_id     = {}   -- interned_id -> array of rules
    self.rules_by_class  = {}   -- interned_class -> array of rules
    self.rules_by_tag    = {}   -- interned_tag -> array of rules
    self.rules_universal = {}   -- array of rules
    self.rules_complex   = {}   -- array of {parsed_selector, rule}
    self._variables      = {}   -- nid -> { ["--name"] = value, ... }
    self._media_groups   = {}   -- array of {condition, compiled_rules}
    self._container_groups = {} -- array of {name, condition, compiled_rules}
    self._container_sizes  = {} -- nid -> {w=, h=} snapshot for change detection
    self._starting_groups  = {} -- array of compiled rule buckets (@starting-style)
    self._seen_nodes       = {} -- nid -> true once the first resolution fires
    self._counter_styles   = {} -- name -> @counter-style descriptor
    self._viewport_w     = 0
    self._viewport_h     = 0
    self._color_scheme   = "light"  -- browser default: light, matching Chrome's normal page scheme
    -- Highest `order` seen across all loaded stylesheets.  append_rules() uses
    -- this so late-arriving <link> stylesheets cascade AFTER inline <style>.
    self._order_max      = 0
    return self
end

--- Bump every rule's `order` by `offset` and track the new max.
local function _bump_orders(rule_list, offset, order_tracker)
    for i = 1, #rule_list do
        local r = rule_list[i]
        if r and r.order then
            r.order = r.order + offset
            if r.order > order_tracker.max then order_tracker.max = r.order end
        end
    end
end

--- Bump orders recursively for bucket-style (by_id/by_class/by_tag) maps.
local function _bump_bucket(bucket, offset, order_tracker)
    if not bucket then return end
    for _, arr in pairs(bucket) do
        _bump_orders(arr, offset, order_tracker)
    end
end

--- Set color scheme for prefers-color-scheme media query.
---@param scheme string  "dark" or "light"
function SE:set_color_scheme(scheme)
    self._color_scheme = scheme or "dark"
end

--- After layout has run, check whether any container-type element changed
--- size since the last snapshot.  Returns true if a re-cascade is needed
--- so @container query rules can be re-evaluated against the new sizes.
---
--- Runs a shallow walk over the node store (no recursion) and looks only
--- at nodes whose `computed.container_type` is set.  Cost is O(k) where
--- k is the number of containment roots, not O(n) of the whole tree.
---@param root_id number
---@return boolean
function SE:check_container_changes(root_id)
    if #self._container_groups == 0 then return false end
    local ns = self.ns
    local sizes = self._container_sizes
    local changed = false
    local last_id = (ns._next_id or 1) - 1
    for nid = 1, last_id do
        local comp = ns.computed[nid]
        if comp and comp.container_type and comp.container_type ~= "normal" then
            local lay = ns.layout[nid]
            if lay then
                local w = lay.w or 0
                local h = lay.h or 0
                local prev = sizes[nid]
                if not prev or prev.w ~= w or prev.h ~= h then
                    sizes[nid] = { w = w, h = h }
                    changed = true
                end
            end
        end
    end
    return changed
end

------------------------------------------------------------
-- Rule loading
------------------------------------------------------------

--- Load pre-bucketed rules from a bundle. Replaces any existing rules.
---@param bundle_rules table
function SE:load_rules(bundle_rules)
    if not bundle_rules then return end

    self.rules_by_id     = {}
    self.rules_by_class  = {}
    self.rules_by_tag    = {}
    self.rules_universal = {}
    self.rules_complex   = {}
    self._media_groups   = {}
    self._container_groups = {}
    self._starting_groups  = {}
    self._counter_styles   = {}
    self._order_max      = 0

    local st = self.ns._st

    -- Index by interned string ids for fast lookup
    if bundle_rules.by_id then
        for id_str, rules in pairs(bundle_rules.by_id) do
            local sid = st:intern(id_str)
            self.rules_by_id[sid] = rules
            for i = 1, #rules do
                if rules[i].order and rules[i].order > self._order_max then
                    self._order_max = rules[i].order
                end
            end
        end
    end

    if bundle_rules.by_class then
        for cls_str, rules in pairs(bundle_rules.by_class) do
            local sid = st:intern(cls_str)
            self.rules_by_class[sid] = rules
            for i = 1, #rules do
                if rules[i].order and rules[i].order > self._order_max then
                    self._order_max = rules[i].order
                end
            end
        end
    end

    if bundle_rules.by_tag then
        for tag_str, rules in pairs(bundle_rules.by_tag) do
            local sid = st:intern(tag_str)
            self.rules_by_tag[sid] = rules
            for i = 1, #rules do
                if rules[i].order and rules[i].order > self._order_max then
                    self._order_max = rules[i].order
                end
            end
        end
    end

    if bundle_rules.universal then
        self.rules_universal = bundle_rules.universal
        for i = 1, #bundle_rules.universal do
            if bundle_rules.universal[i].order and bundle_rules.universal[i].order > self._order_max then
                self._order_max = bundle_rules.universal[i].order
            end
        end
    end

    if bundle_rules.complex then
        self.rules_complex = bundle_rules.complex
        for i = 1, #bundle_rules.complex do
            local r = bundle_rules.complex[i].rule
            if r and r.order and r.order > self._order_max then
                self._order_max = r.order
            end
        end
    end

    -- Store compiled media query groups for runtime evaluation
    if bundle_rules.media then
        for i = 1, #bundle_rules.media do
            local mg = bundle_rules.media[i]
            -- Intern the string keys in the compiled rules
            local interned = {
                by_id = {}, by_class = {}, by_tag = {},
                universal = mg.rules.universal or {},
                complex = mg.rules.complex or {},
            }
            if mg.rules.by_id then
                for id_str, r in pairs(mg.rules.by_id) do
                    interned.by_id[st:intern(id_str)] = r
                end
            end
            if mg.rules.by_class then
                for cls_str, r in pairs(mg.rules.by_class) do
                    interned.by_class[st:intern(cls_str)] = r
                end
            end
            if mg.rules.by_tag then
                for tag_str, r in pairs(mg.rules.by_tag) do
                    interned.by_tag[st:intern(tag_str)] = r
                end
            end
            self._media_groups[#self._media_groups + 1] = {
                condition = mg.condition,
                rules = interned,
            }
        end
    end

    -- @counter-style registry (consulted by li painter for custom list markers)
    if bundle_rules.counter_styles then
        for name, desc in pairs(bundle_rules.counter_styles) do
            self._counter_styles[name] = desc
        end
    end

    -- @starting-style groups (applied only on a node's first style resolution)
    if bundle_rules.starting_styles then
        for i = 1, #bundle_rules.starting_styles do
            local sg = bundle_rules.starting_styles[i]
            local interned = {
                by_id = {}, by_class = {}, by_tag = {},
                universal = sg.universal or {},
                complex = sg.complex or {},
            }
            if sg.by_id then
                for id_str, r in pairs(sg.by_id) do
                    interned.by_id[st:intern(id_str)] = r
                end
            end
            if sg.by_class then
                for cls_str, r in pairs(sg.by_class) do
                    interned.by_class[st:intern(cls_str)] = r
                end
            end
            if sg.by_tag then
                for tag_str, r in pairs(sg.by_tag) do
                    interned.by_tag[st:intern(tag_str)] = r
                end
            end
            self._starting_groups[#self._starting_groups + 1] = interned
        end
    end

    -- Container query groups (evaluated per-node at cascade time)
    if bundle_rules.containers then
        for i = 1, #bundle_rules.containers do
            local cg = bundle_rules.containers[i]
            local interned = {
                by_id = {}, by_class = {}, by_tag = {},
                universal = cg.rules.universal or {},
                complex = cg.rules.complex or {},
            }
            if cg.rules.by_id then
                for id_str, r in pairs(cg.rules.by_id) do
                    interned.by_id[st:intern(id_str)] = r
                end
            end
            if cg.rules.by_class then
                for cls_str, r in pairs(cg.rules.by_class) do
                    interned.by_class[st:intern(cls_str)] = r
                end
            end
            if cg.rules.by_tag then
                for tag_str, r in pairs(cg.rules.by_tag) do
                    interned.by_tag[st:intern(tag_str)] = r
                end
            end
            self._container_groups[#self._container_groups + 1] = {
                name = cg.name,
                condition = cg.condition,
                rules = interned,
            }
        end
    end
end

--- Append rules from a freshly-parsed bundle without clearing existing ones.
--- Incoming rule orders are offset past the current max so cascade precedence
--- matches the load order (later <link> beats earlier <style>).
---@param bundle_rules table
function SE:append_rules(bundle_rules)
    if not bundle_rules then return end

    local st = self.ns._st
    local offset = self._order_max + 1
    local tracker = { max = self._order_max }

    -- Offset orders everywhere before inserting
    _bump_bucket(bundle_rules.by_id, offset, tracker)
    _bump_bucket(bundle_rules.by_class, offset, tracker)
    _bump_bucket(bundle_rules.by_tag, offset, tracker)
    _bump_orders(bundle_rules.universal or {}, offset, tracker)
    if bundle_rules.complex then
        for i = 1, #bundle_rules.complex do
            local r = bundle_rules.complex[i].rule
            if r and r.order then
                r.order = r.order + offset
                if r.order > tracker.max then tracker.max = r.order end
            end
        end
    end
    if bundle_rules.media then
        for i = 1, #bundle_rules.media do
            local mr = bundle_rules.media[i].rules
            _bump_bucket(mr.by_id, offset, tracker)
            _bump_bucket(mr.by_class, offset, tracker)
            _bump_bucket(mr.by_tag, offset, tracker)
            _bump_orders(mr.universal or {}, offset, tracker)
            if mr.complex then
                for ci = 1, #mr.complex do
                    local r = mr.complex[ci].rule
                    if r and r.order then
                        r.order = r.order + offset
                        if r.order > tracker.max then tracker.max = r.order end
                    end
                end
            end
        end
    end

    -- Append (not replace) into existing buckets
    if bundle_rules.by_id then
        for id_str, rules in pairs(bundle_rules.by_id) do
            local sid = st:intern(id_str)
            local existing = self.rules_by_id[sid]
            if not existing then
                self.rules_by_id[sid] = rules
            else
                for i = 1, #rules do existing[#existing + 1] = rules[i] end
            end
        end
    end
    if bundle_rules.by_class then
        for cls_str, rules in pairs(bundle_rules.by_class) do
            local sid = st:intern(cls_str)
            local existing = self.rules_by_class[sid]
            if not existing then
                self.rules_by_class[sid] = rules
            else
                for i = 1, #rules do existing[#existing + 1] = rules[i] end
            end
        end
    end
    if bundle_rules.by_tag then
        for tag_str, rules in pairs(bundle_rules.by_tag) do
            local sid = st:intern(tag_str)
            local existing = self.rules_by_tag[sid]
            if not existing then
                self.rules_by_tag[sid] = rules
            else
                for i = 1, #rules do existing[#existing + 1] = rules[i] end
            end
        end
    end
    if bundle_rules.universal then
        for i = 1, #bundle_rules.universal do
            self.rules_universal[#self.rules_universal + 1] = bundle_rules.universal[i]
        end
    end
    if bundle_rules.complex then
        for i = 1, #bundle_rules.complex do
            self.rules_complex[#self.rules_complex + 1] = bundle_rules.complex[i]
        end
    end
    if bundle_rules.media then
        for i = 1, #bundle_rules.media do
            local mg = bundle_rules.media[i]
            local interned = {
                by_id = {}, by_class = {}, by_tag = {},
                universal = mg.rules.universal or {},
                complex = mg.rules.complex or {},
            }
            if mg.rules.by_id then
                for id_str, r in pairs(mg.rules.by_id) do
                    interned.by_id[st:intern(id_str)] = r
                end
            end
            if mg.rules.by_class then
                for cls_str, r in pairs(mg.rules.by_class) do
                    interned.by_class[st:intern(cls_str)] = r
                end
            end
            if mg.rules.by_tag then
                for tag_str, r in pairs(mg.rules.by_tag) do
                    interned.by_tag[st:intern(tag_str)] = r
                end
            end
            self._media_groups[#self._media_groups + 1] = {
                condition = mg.condition,
                rules = interned,
            }
        end
    end

    self._order_max = tracker.max
end

--- Set viewport dimensions for media query evaluation.
---@param w number  viewport width in pixels
---@param h number  viewport height in pixels
function SE:set_viewport(w, h)
    self._viewport_w = w or 0
    self._viewport_h = h or 0
end

--- Evaluate a media query condition against the current viewport.
---@param condition table  { ["min-width"]=N, ["max-width"]=N, ... }
---@param color_scheme string  "dark" or "light"
---@return boolean
local function eval_media_condition(condition, vw, vh, color_scheme)
    if condition["min-width"] and vw < condition["min-width"] then
        return false
    end
    if condition["max-width"] and vw > condition["max-width"] then
        return false
    end
    if condition["min-height"] and vh < condition["min-height"] then
        return false
    end
    if condition["max-height"] and vh > condition["max-height"] then
        return false
    end
    -- prefers-color-scheme: dark | light
    if condition["prefers-color-scheme"] then
        if condition["prefers-color-scheme"] ~= (color_scheme or "dark") then
            return false
        end
    end
    -- orientation: portrait | landscape
    if condition["orientation"] then
        local orient = (vw >= vh) and "landscape" or "portrait"
        if condition["orientation"] ~= orient then
            return false
        end
    end
    -- aspect-ratio / min-aspect-ratio / max-aspect-ratio (stored as decimal)
    if condition["min-aspect-ratio"] and vh > 0 then
        if (vw / vh) < condition["min-aspect-ratio"] then return false end
    end
    if condition["max-aspect-ratio"] and vh > 0 then
        if (vw / vh) > condition["max-aspect-ratio"] then return false end
    end
    return true
end

------------------------------------------------------------
-- Style resolution
------------------------------------------------------------

--- Walk the tree and compute styles for dirty nodes.
--- Uses walk_depth_first_dirty to skip entire clean subtrees (O(dirty) not O(n)).
---@param root_id number
function SE:resolve(root_id)
    if root_id == 0 then return end
    local ns = self.ns
    local _old_inh = self._old_inh_buf  -- reusable table for old inherited values
    if not _old_inh then _old_inh = {}; self._old_inh_buf = _old_inh end

    -- Element-wise table comparison (for color arrays)
    local function _tables_equal(a, b)
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" then return false end
        for k, v in pairs(a) do if b[k] ~= v then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end

    local variables = self._variables

    ns:walk_depth_first_dirty(root_id, ns.STYLE_DIRTY, function(nid)
        -- Save old inherited values + variables for comparison (reuse table)
        local old_computed = ns.computed[nid]
        for k in pairs(_old_inh) do _old_inh[k] = nil end
        if old_computed then
            for prop in pairs(INHERITED) do
                _old_inh[prop] = old_computed[prop]
            end
        end
        local old_vars = variables[nid]

        self:_compute_node(nid)
        -- Mark this node as "seen" so @starting-style rules apply only on
        -- the first resolution; subsequent resolves use the normal cascade.
        self._seen_nodes[nid] = true
        ns:clear_dirty(nid, ns.STYLE_DIRTY)
        ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)

        -- Check if inherited properties or CSS variables changed → mark children dirty
        local new_computed = ns.computed[nid]
        local first_child = ns.first_child[nid]
        if first_child and first_child ~= 0 then
            local children_need_dirty = false

            -- Check inherited properties (element-wise for table values like color)
            for prop in pairs(INHERITED) do
                if not _tables_equal(new_computed[prop], _old_inh[prop]) then
                    children_need_dirty = true
                    break
                end
            end

            -- Check CSS custom properties (var() inheritance)
            if not children_need_dirty then
                local new_vars = variables[nid]
                if old_vars ~= new_vars then
                    if old_vars and new_vars then
                        for k, v in pairs(old_vars) do
                            if new_vars[k] ~= v then children_need_dirty = true; break end
                        end
                        if not children_need_dirty then
                            for k in pairs(new_vars) do
                                if old_vars[k] == nil then children_need_dirty = true; break end
                            end
                        end
                    else
                        children_need_dirty = true
                    end
                end
            end

            if children_need_dirty then
                local cid = first_child
                while cid and cid ~= 0 do
                    ns:mark_dirty(cid, ns.STYLE_DIRTY)
                    cid = ns.next_sibling[cid] or 0
                end
            end
        end
    end)

    -- Clear subtree_dirty flags after resolve
    ns:clear_all_subtree_dirty()
end

--- Compute the style for a single node.
---@param nid number  node id
--- Recursively resolve var() references inside a calc/clamp/min/max AST.
---@param node table   AST node from CalcParser
---@param variables table  CSS variable map (e.g. { ["--spacing"] = "8px" })
---@return table  new AST node with var() nodes replaced
local function resolve_vars_in_ast(node, variables)
    if not node or type(node) ~= "table" then return node end

    if node.type == "var" then
        local resolved = variables[node.name]
        if resolved ~= nil then
            -- If resolved is a table (calc AST, var ref, etc.) - recurse
            if type(resolved) == "table" then
                return resolve_vars_in_ast(resolved, variables)
            end
            -- If resolved is a number, return as number node
            if type(resolved) == "number" then
                return { type = "number", value = resolved }
            elseif type(resolved) == "string" then
                -- Try to parse as number+unit (including %)
                local num, unit = resolved:match("^(%-?%d*%.?%d+)([a-zA-Z%%]+)$")
                if num then
                    return { type = "unit", value = tonumber(num), unit = unit }
                end
                local plain_num = tonumber(resolved)
                if plain_num then
                    return { type = "number", value = plain_num }
                end
            end
        end
        -- Use fallback
        if node.fallback then
            local fb = node.fallback
            if type(fb) == "string" then
                local num, unit = fb:match("^(%-?%d*%.?%d+)([a-zA-Z%%]+)$")
                if num then
                    return { type = "unit", value = tonumber(num), unit = unit }
                end
                local plain_num = tonumber(fb)
                if plain_num then
                    return { type = "number", value = plain_num }
                end
            end
        end
        return { type = "number", value = 0 }
    end

    -- Recurse into child nodes
    local copy = {}
    for k2, v2 in pairs(node) do
        if type(v2) == "table" and v2.type then
            copy[k2] = resolve_vars_in_ast(v2, variables)
        else
            copy[k2] = v2
        end
    end
    -- Handle arrays (min/max args)
    if node.args then
        copy.args = {}
        for i = 1, #node.args do
            copy.args[i] = resolve_vars_in_ast(node.args[i], variables)
        end
    end
    return copy
end

-- Reusable buffers for _compute_node to avoid per-call allocations.
-- Safe because _compute_node is only called from SE:resolve's iterative
-- walk_depth_first -" never re-entered.
local _matched_buf = {}
local _normal_buf  = {}
local _pe_before_buf = {}
local _pe_after_buf  = {}
local _pe_placeholder_buf = {}
local _pe_selection_buf   = {}
local _pe_marker_buf      = {}
local _pe_first_letter_buf = {}
local _pe_first_line_buf   = {}

local function decls_have_prop(decls, prop_id)
    if not decls then return false end
    for i = 1, #decls do
        local d = decls[i]
        if d and d[1] == prop_id then return true end
    end
    return false
end

function SE:_compute_node(nid)
    local ns = self.ns
    -- Reuse existing computed table to avoid GC of old one
    local computed = ns.computed[nid]
    if computed then
        -- Clear own keys -" metatable defaults remain accessible via __index
        for k in pairs(computed) do computed[k] = nil end
    else
        computed = {}
    end
    -- Metatable provides defaults via __index -" no copying needed
    if not getmetatable(computed) then
        setmetatable(computed, SE.DEFAULTS_MT)
    end

    -- 1.5. Inherit from parent (CSS inherited properties)
    -- Only write own-key if parent's value differs from default (metatable handles defaults)
    local parent_id = ns.parent[nid]
    if parent_id and parent_id ~= 0 then
        local pc = ns.computed[parent_id]
        if pc then
            local DEFS = SE.DEFAULTS
            -- color: table value, needs deep copy if non-default
            local pc_color = pc.color
            if pc_color ~= DEFS.color then
                computed.color = { pc_color[1], pc_color[2], pc_color[3], pc_color[4] }
            end
            -- Scalar inherited properties: skip if equal to default
            local pv
            pv = pc.font_size;        if pv ~= DEFS.font_size then computed.font_size = pv end
            pv = pc.line_height;      if pv ~= DEFS.line_height then computed.line_height = pv end
            pv = pc.text_align;       if pv ~= DEFS.text_align then computed.text_align = pv end
            pv = pc.white_space;      if pv ~= DEFS.white_space then computed.white_space = pv end
            pv = pc.text_overflow;    if pv ~= DEFS.text_overflow then computed.text_overflow = pv end
            pv = pc.font_family;      if pv ~= DEFS.font_family then computed.font_family = pv end
            pv = pc.font_weight;      if pv ~= DEFS.font_weight then computed.font_weight = pv end
            pv = pc.font_style;       if pv ~= DEFS.font_style then computed.font_style = pv end
            pv = pc.letter_spacing;   if pv ~= DEFS.letter_spacing then computed.letter_spacing = pv end
            pv = pc.word_spacing;     if pv ~= DEFS.word_spacing then computed.word_spacing = pv end
            pv = pc.text_transform;   if pv ~= DEFS.text_transform then computed.text_transform = pv end
            pv = pc.visibility;       if pv ~= DEFS.visibility then computed.visibility = pv end
            pv = pc.cursor;           if pv ~= DEFS.cursor then computed.cursor = pv end
            pv = pc.pointer_events;   if pv ~= DEFS.pointer_events then computed.pointer_events = pv end
            pv = pc.word_break;       if pv ~= DEFS.word_break then computed.word_break = pv end
            pv = pc.overflow_wrap;    if pv ~= DEFS.overflow_wrap then computed.overflow_wrap = pv end
            pv = pc.list_style_type;  if pv ~= DEFS.list_style_type then computed.list_style_type = pv end
            pv = pc.list_style_position; if pv ~= DEFS.list_style_position then computed.list_style_position = pv end
            pv = pc.direction;        if pv ~= DEFS.direction then computed.direction = pv end
            pv = pc.writing_mode;     if pv ~= DEFS.writing_mode then computed.writing_mode = pv end
            -- These have nil defaults -" only inherit if parent has them
            pv = pc.caret_color;      if pv then computed.caret_color = pv end
            pv = pc.accent_color;     if pv then computed.accent_color = pv end
            pv = pc.tab_size;         if pv ~= DEFS.tab_size then computed.tab_size = pv end
            pv = pc.text_align_last;  if pv ~= DEFS.text_align_last then computed.text_align_last = pv end
            -- user_select likewise lives on parent but is consulted on TEXT
            -- nodes by selection code; keep parity with the INHERITED set.
            pv = pc.user_select;      if pv ~= DEFS.user_select then computed.user_select = pv end
        end
    end

    -- 2. Apply UA defaults by tag
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)
    local ua_tag_str = tag_str
    if tag_str == "input" then
        local attrs = ns.attrs[nid]
        local input_type = tostring(attrs and attrs.type or "text"):lower()
        if input_type == "checkbox" then
            ua_tag_str = "checkbox"
        elseif input_type == "radio" then
            ua_tag_str = "radio"
        elseif input_type == "range" then
            ua_tag_str = "slider"
        elseif input_type == "button" or input_type == "submit" or input_type == "reset" then
            ua_tag_str = "button"
        end
    end
    if ua_tag_str and SE.UA_DEFAULTS[ua_tag_str] then
        local ua = SE.UA_DEFAULTS[ua_tag_str]
        for k, v in pairs(ua) do
            if type(v) == "table" then
                -- Shallow copy supporting both array tables (colors)
                -- and dict tables (structured values like {type="em", v=2})
                local copy = {}
                for tk, tv in pairs(v) do copy[tk] = tv end
                computed[k] = copy
            else
                computed[k] = v
            end
        end
    end

    -- HTML global `hidden` attribute → display:none (spec behavior). User
    -- CSS can still override but it's unusual to un-hide a hidden element.
    local attrs_boot = ns.attrs[nid]

    -- Textarea intrinsic sizing comes from HTML rows/cols attributes before
    -- author CSS. Chrome defaults to cols=20, rows=2.
    if tag_str == "textarea" then
        local rows = tonumber(attrs_boot and attrs_boot.rows) or 2
        local cols = tonumber(attrs_boot and attrs_boot.cols) or 20
        if rows < 1 then rows = 2 end
        if cols < 1 then cols = 20 end

        local fs = computed.font_size
        if type(fs) ~= "number" then fs = 13.333 end
        local lh = computed.line_height
        if type(lh) ~= "number" then lh = 1.2 end
        local line_px = (lh <= 4) and (lh * fs) or lh
        local pt = computed.padding_top or 0
        local pb = computed.padding_bottom or 0
        local bw = computed.border_width or 0
        computed.height = math.floor(rows * line_px + pt + pb + bw * 2 + 0.5)
        computed.width = math.floor(cols * fs * 0.75 + 0.5)
    end
    if attrs_boot and attrs_boot.hidden ~= nil and attrs_boot.hidden ~= "until-found" then
        computed.display = "none"
    end

    -- `disabled` attribute on inputs/buttons → reduce opacity by default
    -- and suppress pointer events.  User CSS can override via :disabled.
    if attrs_boot and attrs_boot.disabled ~= nil
       and (tag_str == "input" or tag_str == "button" or tag_str == "textarea"
            or tag_str == "select" or tag_str == "fieldset" or tag_str == "checkbox"
            or tag_str == "radio" or tag_str == "slider" or tag_str == "switch") then
        if computed.opacity == nil or computed.opacity == 1 then
            computed.opacity = 0.55
        end
        computed.pointer_events = computed.pointer_events or "none"
        -- Mirror into pseudo state so :disabled selectors match
        local p = ns.pseudo[nid]
        if p then p.disabled = true end
    end

    -- 3. Collect matching rules, sorted by specificity + order
    -- Reuse module-level buffers (clear first)
    local matched = _matched_buf;       for i = 1, #matched do matched[i] = nil end
    self:_collect_rules(nid, matched)

    -- Cascade sort: layer_order asc (unlayered = infinity → last), then
    -- specificity asc, then source order asc.  Later items override earlier.
    table.sort(matched, function(a, b)
        local la = a.layer_order or math.huge
        local lb = b.layer_order or math.huge
        if la ~= lb then return la < lb end
        if a.specificity ~= b.specificity then
            return a.specificity < b.specificity
        end
        return a.order < b.order
    end)

    -- Separate pseudo-element rules from normal rules (reuse buffers)
    local normal_rules        = _normal_buf;          for i = 1, #normal_rules do normal_rules[i] = nil end
    local pe_before_rules     = _pe_before_buf;       for i = 1, #pe_before_rules do pe_before_rules[i] = nil end
    local pe_after_rules      = _pe_after_buf;        for i = 1, #pe_after_rules do pe_after_rules[i] = nil end
    local pe_placeholder_rules = _pe_placeholder_buf; for i = 1, #pe_placeholder_rules do pe_placeholder_rules[i] = nil end
    local pe_selection_rules  = _pe_selection_buf;     for i = 1, #pe_selection_rules do pe_selection_rules[i] = nil end
    local pe_marker_rules     = _pe_marker_buf;        for i = 1, #pe_marker_rules do pe_marker_rules[i] = nil end
    local pe_first_letter_rules = _pe_first_letter_buf; for i = 1, #pe_first_letter_rules do pe_first_letter_rules[i] = nil end
    local pe_first_line_rules   = _pe_first_line_buf;   for i = 1, #pe_first_line_rules do pe_first_line_rules[i] = nil end
    for i = 1, #matched do
        local rule = matched[i]
        if rule.pseudo_element == "before" then
            pe_before_rules[#pe_before_rules + 1] = rule
        elseif rule.pseudo_element == "after" then
            pe_after_rules[#pe_after_rules + 1] = rule
        elseif rule.pseudo_element == "placeholder" then
            pe_placeholder_rules[#pe_placeholder_rules + 1] = rule
        elseif rule.pseudo_element == "selection" then
            pe_selection_rules[#pe_selection_rules + 1] = rule
        elseif rule.pseudo_element == "marker" then
            pe_marker_rules[#pe_marker_rules + 1] = rule
        elseif rule.pseudo_element == "first-letter" then
            pe_first_letter_rules[#pe_first_letter_rules + 1] = rule
        elseif rule.pseudo_element == "first-line" then
            pe_first_line_rules[#pe_first_line_rules + 1] = rule
        else
            normal_rules[#normal_rules + 1] = rule
        end
    end

    -- Parent computed style for unset keyword resolution
    local pc = nil
    local p_id = ns.parent[nid]
    if p_id and p_id ~= 0 then pc = ns.computed[p_id] end

    -- 4. Collect CSS variables first. var() is resolved at computed-value time
    -- against the final custom-property cascade, so later inline custom
    -- properties must be visible even to earlier normal declarations.
    local variables = nil
    local parent_id = ns.parent[nid]
    if parent_id and parent_id ~= 0 and self._variables[parent_id] then
        -- Inherit parent variables (shallow copy)
        variables = {}
        for k, v in pairs(self._variables[parent_id]) do
            variables[k] = v
        end
    end
    for i = 1, #normal_rules do
        local rule = normal_rules[i]
        if rule.vars then
            if not variables then variables = {} end
            for k, v in pairs(rule.vars) do
                variables[k] = v
            end
        end
    end

    local attrs = ns.attrs[nid]
    local inline_full = nil
    if attrs and attrs.style and type(attrs.style) == "string" then
        local st_val = attrs.style
        if not attrs._style_full_parsed or attrs._style_full_src ~= st_val then
            local CSSParser = require("core/html/css_parser")
            attrs._style_full_parsed = CSSParser.parse_inline_full(st_val)
            attrs._style_full_src    = st_val
            attrs._style_parsed      = attrs._style_full_parsed.decls
            attrs._style_src         = st_val
        end
        inline_full = attrs._style_full_parsed
        if inline_full and inline_full.vars then
            if not variables then variables = {} end
            for k, v in pairs(inline_full.vars) do variables[k] = v end
        end
    elseif attrs and attrs.style and type(attrs.style) == "table" then
        for k, v in pairs(attrs.style) do
            if type(k) == "string" and k:sub(1, 2) == "--" then
                if not variables then variables = {} end
                variables[k] = v
            end
        end
    end

    self._variables[nid] = variables

    local function author_declares(prop_id)
        for i = 1, #normal_rules do
            local rule = normal_rules[i]
            if decls_have_prop(rule.decls, prop_id) or decls_have_prop(rule.important_decls, prop_id) then
                return true
            end
        end
        if attrs and attrs.style then
            if type(attrs.style) == "string" then
                return decls_have_prop(inline_full and inline_full.decls, prop_id)
                    or decls_have_prop(inline_full and inline_full.important_decls, prop_id)
            elseif type(attrs.style) == "table" then
                local st = attrs.style
                if st[1] and type(st[1]) == "table" and st[1][1] then
                    return decls_have_prop(st, prop_id)
                end
                local key = PROP_TO_KEY[prop_id]
                return key ~= nil and st[key] ~= nil
            end
        end
        return false
    end

    local author_height = author_declares(SE.PROP.height)

    -- 4.5. Apply declarations from normal matched rules
    for i = 1, #normal_rules do
        local rule = normal_rules[i]
        if rule.decls then
            self:_apply_declarations(computed, rule.decls, pc, variables)
        end
    end

    -- 5. Apply inline style from attrs.style if present.
    -- attrs.style may be either:
    --   - a string from the HTML parser, e.g. "color: red; padding: 10px"
    --   - a table from the builder DSL, either as key/value map
    --     ({ color = {255,0,0,255} }) or as an array of {pid, value} pairs.
    if attrs and attrs.style then
        local st_val = attrs.style
        if type(st_val) == "string" then
            self:_apply_declarations(computed, (inline_full and inline_full.decls) or attrs._style_parsed or {}, pc, variables)
        elseif type(st_val) == "table" then
            -- Detect array-of-{pid,value} pairs vs key/value map.
            if st_val[1] and type(st_val[1]) == "table" and st_val[1][1] then
                self:_apply_declarations(computed, st_val, pc, variables)
            else
                for k, v in pairs(st_val) do
                    if type(k) == "string" and k:sub(1, 2) == "--" then
                        -- custom property already merged into variables above
                    elseif type(v) == "table" and v.type then
                        computed[k] = self:_resolve_value(v)
                    else
                        computed[k] = v
                    end
                end
            end
        end
    end

    -- 5a. Apply !important declarations.  CSS Cascade L5 §6.4.4 inverts the
    -- layer order for the !important origin: in normal origin, unlayered
    -- author has the highest priority; in !important origin, unlayered has
    -- the lowest priority.  Re-sort matched rules with reversed layer order
    -- before applying important declarations.
    local imp_sorted = nil
    for i = 1, #normal_rules do
        if normal_rules[i].important_decls then
            if not imp_sorted then imp_sorted = {} end
            imp_sorted[#imp_sorted + 1] = normal_rules[i]
        end
    end
    if imp_sorted then
        table.sort(imp_sorted, function(a, b)
            local la = a.layer_order or math.huge
            local lb = b.layer_order or math.huge
            if la ~= lb then return la > lb end  -- reversed for !important
            if a.specificity ~= b.specificity then
                return a.specificity < b.specificity
            end
            return a.order < b.order
        end)
        for i = 1, #imp_sorted do
            self:_apply_declarations(computed, imp_sorted[i].important_decls, pc, variables)
        end
    end
    -- Author-inline !important wins over selector-based !important in the
    -- common case where no selector has specificity ≥ inline (1,0,0,0).
    if inline_full and inline_full.important_decls then
        self:_apply_declarations(computed, inline_full.important_decls, pc, variables)
    end

    -- 5b. Resolve `currentcolor` sentinels.  Any color-valued property that
    -- was declared as `currentcolor` carries a `{type = "currentcolor"}`
    -- placeholder from the parser.  At computed-value time it resolves
    -- against this element's own `color`.  CSS Color §4.4.
    if type(computed.color) == "table" and computed.color.type == "currentcolor" then
        -- color: currentcolor → falls back to inherited color (parent),
        -- because currentcolor on `color` itself is defined to inherit.
        if pc and type(pc.color) == "table" then
            computed.color = { pc.color[1], pc.color[2], pc.color[3], pc.color[4] }
        else
            local d = SE.DEFAULTS.color
            computed.color = { d[1], d[2], d[3], d[4] }
        end
    end
    local cc = computed.color
    if type(cc) == "table" and #cc >= 3 then
        local CURRENT_COLOR_PROPS = SE._CURRENT_COLOR_PROPS
        for i = 1, #CURRENT_COLOR_PROPS do
            local key = CURRENT_COLOR_PROPS[i]
            local v = computed[key]
            if type(v) == "table" and v.type == "currentcolor" then
                computed[key] = { cc[1], cc[2], cc[3], cc[4] }
            end
        end
    end

    -- 5.5. Sync disabled attribute → pseudo state; apply fallback styles
    if attrs and (attrs._astro_resize_width or attrs._astro_resize_height) then
        if attrs._astro_resize_width then computed.width = attrs._astro_resize_width end
        if attrs._astro_resize_height then computed.height = attrs._astro_resize_height end
    end

    -- Chrome form controls do not keep a fixed UA content box when author
    -- padding changes. If the author did not explicitly set height, derive the
    -- used border-box height from font metrics, padding, and border.
    if not author_height and not (attrs and attrs._astro_resize_height) then
        local is_text_input = false
        local is_select = (tag_str == "select")
        local is_textarea = (tag_str == "textarea")
        if tag_str == "input" then
            local input_type = tostring(attrs and attrs.type or "text"):lower()
            is_text_input = not (input_type == "checkbox" or input_type == "radio"
                or input_type == "range" or input_type == "button"
                or input_type == "submit" or input_type == "reset")
        end
        if is_text_input or is_select or is_textarea then
            local fs = computed.font_size
            if type(fs) ~= "number" then fs = is_select and 13.333 or 13.333 end
            local lh = computed.line_height
            if type(lh) ~= "number" then lh = 1.2 end
            local line_px = (lh <= 4) and (lh * fs) or lh
            local pt = computed.padding_top or 0
            local pb = computed.padding_bottom or 0
            local bw = computed.border_width or 0
            local rows = 1
            if is_textarea then
                rows = tonumber(attrs and attrs.rows) or 2
                if rows < 1 then rows = 2 end
            end
            local min_h = is_textarea and 38 or 22
            computed.height = math.max(min_h, math.floor(rows * line_px + pt + pb + bw * 2 + 0.5))
        end
    end

    local pseudo = ns.pseudo[nid]
    if pseudo then
        local is_disabled = (attrs and attrs.disabled ~= nil and attrs.disabled ~= false) or false
        pseudo.disabled = is_disabled
        if is_disabled then
            local cur_opacity = computed.opacity or 255
            if cur_opacity > 128 then computed.opacity = 128 end
            computed.cursor = "not-allowed"
        end
    end

    -- 6. Handle pseudo state overrides (hover, focus, active)
    if pseudo then
        if pseudo.hover and attrs and attrs.onHoverStyle then
            for k, v in pairs(attrs.onHoverStyle) do
                if type(v) == "table" and v.type then
                    computed[k] = self:_resolve_value(v)
                else
                    computed[k] = v
                end
            end
        end
        if pseudo.focus and attrs and attrs.onFocusStyle then
            for k, v in pairs(attrs.onFocusStyle) do
                if type(v) == "table" and v.type then
                    computed[k] = self:_resolve_value(v)
                else
                    computed[k] = v
                end
            end
        end
        if pseudo.active and attrs and attrs.onActiveStyle then
            for k, v in pairs(attrs.onActiveStyle) do
                if type(v) == "table" and v.type then
                    computed[k] = self:_resolve_value(v)
                else
                    computed[k] = v
                end
            end
        end
    end

    -- 7. Substitute CSS variable references
    if variables then
        local var_cache -- lazily created per resolve pass

        local function resolve_var_value(val, depth)
            if depth > 10 then return val end
            if type(val) ~= "string" then return val end
            if not val:find("var(", 1, true) then return val end
            if var_cache and var_cache[val] then return var_cache[val] end
            -- If the entire value is a single var() reference, resolve directly
            -- (allows structured table values like colors to pass through)
            local sole_name = val:match("^var%(%-%-([%w_%-]+)%)$")
            if sole_name then
                local inner = variables["--" .. sole_name]
                if inner ~= nil then
                    local resolved = resolve_var_value(inner, depth + 1)
                    if not var_cache then var_cache = {} end
                    var_cache[val] = resolved
                    return resolved
                end
                return val
            end
            local result = val:gsub("var%(%-%-([%w_%-]+)%)", function(name)
                local inner = variables["--" .. name]
                if inner == nil then return "var(--" .. name .. ")" end
                local resolved = resolve_var_value(inner, depth + 1)
                if type(resolved) ~= "string" then return tostring(resolved) end
                return resolved
            end)
            if not var_cache then var_cache = {} end
            var_cache[val] = result
            return result
        end

        for k, v in pairs(computed) do
            if type(v) == "table" and v.type == "var" then
                local resolved = variables[v.name]
                if resolved ~= nil then
                    computed[k] = resolve_var_value(resolved, 0)
                elseif v.fallback ~= nil then
                    computed[k] = v.fallback
                else
                    computed[k] = nil
                end
            end
        end
    end

    -- 7b. Substitute var() references inside calc/clamp/min/max ASTs
    if variables then
        for k, v in pairs(computed) do
            if type(v) == "table" and (v.type == "calc" or v.type == "clamp" or v.type == "min" or v.type == "max") then
                computed[k] = resolve_vars_in_ast(v, variables)
            end
        end
    end

    -- 8. Apply CSS filter color transformations
    if computed.filter then
        local Filters = require("core/paint/filters")
        local parsed_f = Filters.parse(computed.filter)
        if parsed_f and #parsed_f > 0 then
            local color_keys = { "background_color", "color", "border_color",
                "border_top_color", "border_right_color", "border_bottom_color", "border_left_color",
                "outline_color" }
            for ki = 1, #color_keys do
                local ck = color_keys[ki]
                local cv = computed[ck]
                if cv and type(cv) == "table" and cv[1] then
                    local fr, fg, fb, fa = Filters.apply_color(
                        cv[1] or 0, cv[2] or 0, cv[3] or 0, cv[4] or 255, parsed_f)
                    computed[ck] = { fr, fg, fb, fa }
                end
            end
        end
    end

    -- 8b. RTL direction: default text_align to "right" if not explicitly set.
    -- Skip text nodes (node_type 2): they inherit text_align from their
    -- parent element which has already been resolved.  Re-flipping here
    -- would override a parent's explicit text_align:"left".
    local ntype = ns.node_type and ns.node_type[nid]
    if ntype ~= 2 and computed.direction == "rtl" and computed.text_align == "left" then
        local was_set = false
        -- Check normal rules + important rules for explicit text_align
        local all_rule_sets = { normal_rules }
        for ri = 1, #all_rule_sets do
            local rules = all_rule_sets[ri]
            for i = 1, #rules do
                local r = rules[i]
                local decl_lists = { r.decls, r.important_decls }
                for dli = 1, 2 do
                    local dl = decl_lists[dli]
                    if dl then
                        for di = 1, #dl do
                            if dl[di][1] == SE.PROP.text_align then was_set = true; break end
                        end
                    end
                    if was_set then break end
                end
                if was_set then break end
            end
            if was_set then break end
        end
        -- Check inline style
        if not was_set and attrs and attrs.style and attrs.style.text_align then
            was_set = true
        end
        if not was_set then
            computed.text_align = "right"
        end
    end

    ns.computed[nid] = computed
    ns.style_gen[nid] = (ns.style_gen[nid] or 0) + 1

    -- 9. Create/update ::before and ::after pseudo-element synthetic nodes.
    -- Skip this for nodes that are *themselves* pseudo-elements -" otherwise
    -- inheriting selectors like :lang() would match the pseudo-node too,
    -- spawning a nested pseudo-element and infinitely recursing.
    local attrs_self = ns.attrs[nid]
    if not (attrs_self and attrs_self._is_pseudo) then
        self:_ensure_pseudo_nodes(nid, pe_before_rules, pe_after_rules)
    end

    -- 10. Build ::placeholder computed style for input/textarea
    local tag_str_pe = ns._st:get(ns.tag[nid])
    if tag_str_pe == "input" or tag_str_pe == "textarea" then
        local ph_style = {
            -- Default placeholder styles (CSS spec-like)
            color = { 150, 150, 160, 255 },
        }
        -- Inherit base properties from this element's computed style
        if computed.font_size then ph_style.font_size = computed.font_size end
        if computed.font_family then ph_style.font_family = computed.font_family end
        if computed.font_weight then ph_style.font_weight = computed.font_weight end
        if computed.line_height then ph_style.line_height = computed.line_height end
        if computed.letter_spacing then ph_style.letter_spacing = computed.letter_spacing end
        -- Apply any ::placeholder rules (inherit resolves from originating element, not parent)
        for i = 1, #pe_placeholder_rules do
            if pe_placeholder_rules[i].decls then
                self:_apply_declarations(ph_style, pe_placeholder_rules[i].decls, computed, variables)
            end
        end
        for i = 1, #pe_placeholder_rules do
            if pe_placeholder_rules[i].important_decls then
                self:_apply_declarations(ph_style, pe_placeholder_rules[i].important_decls, computed, variables)
            end
        end
        -- Store on the node's pseudo table for painters to use
        local ph_pseudo = ns.pseudo[nid]
        if ph_pseudo then
            ph_pseudo._placeholder_style = ph_style
        end
    end

    -- 11. Build ::selection style (applies to any element with text)
    do
        local sel_style = {
            -- Default selection styles (blue highlight with white text)
            background_color = { 50, 100, 200, 180 },
            color            = { 255, 255, 255, 255 },
        }
        -- Apply any ::selection rules
        for i = 1, #pe_selection_rules do
            if pe_selection_rules[i].decls then
                self:_apply_declarations(sel_style, pe_selection_rules[i].decls, computed, variables)
            end
        end
        for i = 1, #pe_selection_rules do
            if pe_selection_rules[i].important_decls then
                self:_apply_declarations(sel_style, pe_selection_rules[i].important_decls, computed, variables)
            end
        end
        -- Store on the node's pseudo table for painters to use
        local sel_pseudo = ns.pseudo[nid]
        if sel_pseudo then
            sel_pseudo._selection_style = sel_style
        end
    end

    -- 12. Build ::marker style (applies to list items -" the li renderer
    -- checks pseudo._marker_style for color/font-size overrides)
    if #pe_marker_rules > 0 then
        local m_style = {}
        for i = 1, #pe_marker_rules do
            if pe_marker_rules[i].decls then
                self:_apply_declarations(m_style, pe_marker_rules[i].decls, computed, variables)
            end
        end
        for i = 1, #pe_marker_rules do
            if pe_marker_rules[i].important_decls then
                self:_apply_declarations(m_style, pe_marker_rules[i].important_decls, computed, variables)
            end
        end
        local m_pseudo = ns.pseudo[nid]
        if m_pseudo then
            m_pseudo._marker_style = m_style
        end
    end

    -- 13. Build ::first-letter style.  Painter applies these overrides when
    -- rendering the first grapheme of the first rendered line of text content.
    if #pe_first_letter_rules > 0 then
        local fl_style = {}
        for i = 1, #pe_first_letter_rules do
            if pe_first_letter_rules[i].decls then
                self:_apply_declarations(fl_style, pe_first_letter_rules[i].decls, computed, variables)
            end
        end
        for i = 1, #pe_first_letter_rules do
            if pe_first_letter_rules[i].important_decls then
                self:_apply_declarations(fl_style, pe_first_letter_rules[i].important_decls, computed, variables)
            end
        end
        local fl_pseudo = ns.pseudo[nid]
        if fl_pseudo then
            fl_pseudo._first_letter_style = fl_style
        end
    end

    -- 14. Build ::first-line style.  Painter applies to glyphs on the first
    -- wrapped line only.
    if #pe_first_line_rules > 0 then
        local fln_style = {}
        for i = 1, #pe_first_line_rules do
            if pe_first_line_rules[i].decls then
                self:_apply_declarations(fln_style, pe_first_line_rules[i].decls, computed, variables)
            end
        end
        for i = 1, #pe_first_line_rules do
            if pe_first_line_rules[i].important_decls then
                self:_apply_declarations(fln_style, pe_first_line_rules[i].important_decls, computed, variables)
            end
        end
        local fln_pseudo = ns.pseudo[nid]
        if fln_pseudo then
            fln_pseudo._first_line_style = fln_style
        end
    end
end

--- Create or update synthetic pseudo-element nodes (::before/::after).
---@param nid          number  parent node id
---@param before_rules table   array of matched rules for ::before
---@param after_rules  table   array of matched rules for ::after
function SE:_ensure_pseudo_nodes(nid, before_rules, after_rules)
    local ns = self.ns
    if not self._pseudo_nodes then self._pseudo_nodes = {} end

    local key_before = nid .. "::before"
    local key_after  = nid .. "::after"

    -- Helper: create or get pseudo-element node
    local function ensure_node(key, rules, position)
        if #rules == 0 then
            -- Remove existing pseudo node if no rules
            if self._pseudo_nodes[key] then
                local pnid = self._pseudo_nodes[key]
                ns:remove_node(pnid)
                self._pseudo_nodes[key] = nil
            end
            return
        end

        -- Build computed style for pseudo-element
        local pe_computed = {}
        -- Inherit from parent
        local pc = ns.computed[nid]
        if pc then
            if pc.color then
                pe_computed.color = { pc.color[1], pc.color[2], pc.color[3], pc.color[4] }
            end
            pe_computed.font_size     = pc.font_size
            pe_computed.font_family   = pc.font_family
            pe_computed.font_weight   = pc.font_weight
            pe_computed.font_style    = pc.font_style
            pe_computed.line_height   = pc.line_height
            pe_computed.letter_spacing = pc.letter_spacing
            pe_computed.word_spacing  = pc.word_spacing
            pe_computed.caret_color    = pc.caret_color
            pe_computed.accent_color   = pc.accent_color
            pe_computed.tab_size       = pc.tab_size
            pe_computed.text_align_last = pc.text_align_last
        end

        -- Apply declarations (parent_computed = pc, the originating element's
        -- computed style -" used by the `inherit` keyword).
        for i = 1, #rules do
            if rules[i].decls then
                self:_apply_declarations(pe_computed, rules[i].decls, pc, self._variables[nid])
            end
        end

        -- Resolve CSS variables (using parent's variables)
        local parent_vars = self._variables[nid]
        if parent_vars then
            for k, v in pairs(pe_computed) do
                if type(v) == "table" and v.type == "var" then
                    local resolved = parent_vars[v.name]
                    if resolved ~= nil then
                        pe_computed[k] = resolved
                    elseif v.fallback ~= nil then
                        pe_computed[k] = v.fallback
                    else
                        pe_computed[k] = nil
                    end
                end
            end
        end

        -- Pseudo-elements default to display: inline (CSS spec)
        if not pe_computed.display then
            pe_computed.display = "inline"
        end

        -- Extract content text. Pseudo elements without a content property are
        -- spec-undefined; we treat that the same as the empty string so that
        -- ::before { width: 10px; background: red } still produces a paintable
        -- box (CSS 2.1 §12.2: an empty `content` value still generates a box).
        local content_text = pe_computed.content or ""
        pe_computed.content = nil

        -- Create or reuse the synthetic ELEMENT node. ELEMENT (node_type=1) is
        -- required so width/height/background/border declarations apply; a
        -- TEXT-typed pseudo would ignore all box properties at paint time.
        local pnid = self._pseudo_nodes[key]
        if not pnid then
            pnid = ns:create_node("_pseudo", "", nil, ns.ELEMENT, "", { _is_pseudo = true })
            self._pseudo_nodes[key] = pnid
            -- Insert as first or last child of the originating element.
            if position == "before" then
                local old_first = ns.first_child[nid]
                ns.parent[pnid] = nid
                ns.first_child[nid] = pnid
                ns.next_sibling[pnid] = old_first or 0
                if old_first and old_first ~= 0 then
                    ns.prev_sibling[old_first] = pnid
                end
                ns.prev_sibling[pnid] = 0
                if not ns.last_child[nid] or ns.last_child[nid] == 0 then
                    ns.last_child[nid] = pnid
                end
            else
                local old_last = ns.last_child[nid]
                ns.parent[pnid] = nid
                ns.last_child[nid] = pnid
                ns.prev_sibling[pnid] = old_last or 0
                if old_last and old_last ~= 0 then
                    ns.next_sibling[old_last] = pnid
                end
                ns.next_sibling[pnid] = 0
                if not ns.first_child[nid] or ns.first_child[nid] == 0 then
                    ns.first_child[nid] = pnid
                end
            end
        end

        -- Reconcile a single TEXT child carrying the content string. This
        -- mirrors how authored markup expresses pseudo content: an inline
        -- element with a text node inside.
        local content_str = tostring(content_text)
        local existing_child = ns.first_child[pnid] or 0
        if content_str ~= "" then
            if existing_child == 0 then
                local tnid = ns:create_node("_text", "", nil, ns.TEXT, content_str, {})
                ns.parent[tnid]       = pnid
                ns.first_child[pnid]  = tnid
                ns.last_child[pnid]   = tnid
                ns.prev_sibling[tnid] = 0
                ns.next_sibling[tnid] = 0
            else
                ns.text_content[existing_child] = content_str
                ns:mark_dirty(existing_child, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
            end
        elseif existing_child ~= 0 then
            ns:remove_node(existing_child)
        end

        ns.computed[pnid] = pe_computed
        ns.style_gen[pnid] = (ns.style_gen[pnid] or 0) + 1
        ns:mark_dirty(pnid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
    end

    ensure_node(key_before, before_rules, "before")
    ensure_node(key_after, after_rules, "after")

    -- When pseudo-elements exist, make sibling _text nodes inline
    -- so ::before / text / ::after flow horizontally together.
    local has_pseudo = (#before_rules > 0) or (#after_rules > 0)
    if has_pseudo then
        local cid = ns.first_child[nid]
        if not cid then cid = 0 end
        while cid ~= 0 do
            if ns.node_type[cid] == ns.TEXT then
                local cc = ns.computed[cid]
                if cc then cc.display = "inline" end
            end
            cid = ns.next_sibling[cid] or 0
        end
    end
end

--- Collect all rules matching a node, appending to out[].
---@param nid number  node id
---@param out table   array to append matching rules to
function SE:_collect_rules(nid, out)
    local ns = self.ns

    -- Universal rules (specificity 0)
    for i = 1, #self.rules_universal do
        out[#out + 1] = self.rules_universal[i]
    end

    -- Tag rules (specificity 1)
    local tag_id = ns.tag[nid]
    if tag_id and self.rules_by_tag[tag_id] then
        local rules = self.rules_by_tag[tag_id]
        for i = 1, #rules do
            out[#out + 1] = rules[i]
        end
    end

    -- Class rules (specificity 10)
    local cls_list = ns.class_list[nid]
    if cls_list then
        for ci = 1, #cls_list do
            local cls_id = cls_list[ci]
            if cls_id and self.rules_by_class[cls_id] then
                local rules = self.rules_by_class[cls_id]
                for ri = 1, #rules do
                    out[#out + 1] = rules[ri]
                end
            end
        end
    end

    -- ID rules (specificity 100)
    local id_str_id = ns.id_str[nid]
    if id_str_id and id_str_id ~= 0 and self.rules_by_id[id_str_id] then
        local rules = self.rules_by_id[id_str_id]
        for i = 1, #rules do
            out[#out + 1] = rules[i]
        end
    end

    -- Complex selector rules (full matcher)
    for i = 1, #self.rules_complex do
        local entry = self.rules_complex[i]
        local parsed = entry.parsed
        local rule = entry.rule

        -- Check for ::before/::after pseudo-element in key selector (last segment)
        local segments = parsed.segments
        local pe_type = nil
        if segments and #segments > 0 then
            local key_sel = segments[#segments].selectors
            for si = 1, #key_sel do
                if key_sel[si].type == "pseudo-element" then
                    pe_type = key_sel[si].value
                    break
                end
            end
        end

        if pe_type then
            -- Strip pseudo-element from a copy, match base selector against node
            local base_parsed = { segments = {} }
            for si = 1, #segments do
                local seg = segments[si]
                if si == #segments then
                    -- Strip pseudo-element from last segment's selectors
                    local filtered = {}
                    for fi = 1, #seg.selectors do
                        if seg.selectors[fi].type ~= "pseudo-element" then
                            filtered[#filtered + 1] = seg.selectors[fi]
                        end
                    end
                    base_parsed.segments[si] = {
                        combinator = seg.combinator,
                        selectors = filtered,
                    }
                else
                    base_parsed.segments[si] = seg
                end
            end
            if SelectorMatcher.matches(ns, nid, base_parsed) then
                -- Store as pseudo-element rule (not applied to node directly)
                local pe_rule = {
                    specificity = rule.specificity,
                    order = rule.order,
                    decls = rule.decls,
                    vars = rule.vars,
                    important_decls = rule.important_decls,
                    pseudo_element = pe_type,
                }
                out[#out + 1] = pe_rule
            end
        else
            if SelectorMatcher.matches(ns, nid, parsed) then
                out[#out + 1] = rule
            end
        end
    end

    -- Media query rules (conditionally active based on viewport)
    local vw, vh = self._viewport_w, self._viewport_h
    for mi = 1, #self._media_groups do
        local mg = self._media_groups[mi]
        if eval_media_condition(mg.condition, vw, vh, self._color_scheme) then
            local mr = mg.rules
            -- Universal
            for i = 1, #mr.universal do
                out[#out + 1] = mr.universal[i]
            end
            -- Tag
            if tag_id and mr.by_tag[tag_id] then
                local rules = mr.by_tag[tag_id]
                for i = 1, #rules do out[#out + 1] = rules[i] end
            end
            -- Class
            if cls_list then
                for ci = 1, #cls_list do
                    local cls_id = cls_list[ci]
                    if cls_id and mr.by_class[cls_id] then
                        local rules = mr.by_class[cls_id]
                        for ri = 1, #rules do out[#out + 1] = rules[ri] end
                    end
                end
            end
            -- ID
            if id_str_id and id_str_id ~= 0 and mr.by_id[id_str_id] then
                local rules = mr.by_id[id_str_id]
                for i = 1, #rules do out[#out + 1] = rules[i] end
            end
            -- Complex (with pseudo-element handling, same as non-media path)
            for i = 1, #mr.complex do
                local entry = mr.complex[i]
                local parsed = entry.parsed
                local rule = entry.rule

                -- Check for ::before/::after pseudo-element in key selector
                local segments = parsed.segments
                local pe_type = nil
                if segments and #segments > 0 then
                    local key_sel = segments[#segments].selectors
                    for si = 1, #key_sel do
                        if key_sel[si].type == "pseudo-element" then
                            pe_type = key_sel[si].value
                            break
                        end
                    end
                end

                if pe_type then
                    -- Strip pseudo-element from a copy, match base selector
                    local base_parsed = { segments = {} }
                    for si = 1, #segments do
                        local seg = segments[si]
                        if si == #segments then
                            local filtered = {}
                            for fi = 1, #seg.selectors do
                                if seg.selectors[fi].type ~= "pseudo-element" then
                                    filtered[#filtered + 1] = seg.selectors[fi]
                                end
                            end
                            base_parsed.segments[si] = {
                                combinator = seg.combinator,
                                selectors = filtered,
                            }
                        else
                            base_parsed.segments[si] = seg
                        end
                    end
                    if SelectorMatcher.matches(ns, nid, base_parsed) then
                        local pe_rule = {
                            specificity = rule.specificity,
                            order = rule.order,
                            decls = rule.decls,
                            vars = rule.vars,
                            important_decls = rule.important_decls,
                            pseudo_element = pe_type,
                        }
                        out[#out + 1] = pe_rule
                    end
                else
                    if SelectorMatcher.matches(ns, nid, parsed) then
                        out[#out + 1] = rule
                    end
                end
            end
        end
    end

    -- @starting-style rules -" applied only on the node's FIRST style
    -- resolution.  On subsequent resolves, normal rules take over, and
    -- the TransitionEngine's snapshot-diff detection animates between them.
    if #self._starting_groups > 0 and not self._seen_nodes[nid] then
        for sgi = 1, #self._starting_groups do
            local sr = self._starting_groups[sgi]
            for i = 1, #sr.universal do out[#out + 1] = sr.universal[i] end
            if tag_id and sr.by_tag[tag_id] then
                local rr = sr.by_tag[tag_id]
                for i = 1, #rr do out[#out + 1] = rr[i] end
            end
            if cls_list then
                for ci = 1, #cls_list do
                    local cid2 = cls_list[ci]
                    if cid2 and sr.by_class[cid2] then
                        local rr = sr.by_class[cid2]
                        for i = 1, #rr do out[#out + 1] = rr[i] end
                    end
                end
            end
            if id_str_id and id_str_id ~= 0 and sr.by_id[id_str_id] then
                local rr = sr.by_id[id_str_id]
                for i = 1, #rr do out[#out + 1] = rr[i] end
            end
            for i = 1, #sr.complex do
                local entry = sr.complex[i]
                if SelectorMatcher.matches(ns, nid, entry.parsed) then
                    out[#out + 1] = entry.rule
                end
            end
        end
    end

    -- @container query groups -" match only when an ancestor container
    -- satisfies the size condition.  Early exit when no container rules
    -- exist makes this zero-cost for bundles without @container.
    if #self._container_groups > 0 then
        for cgi = 1, #self._container_groups do
            local cg = self._container_groups[cgi]
            local container_lay = nil
            -- Walk ancestors looking for a container-type element
            local cur = ns.parent[nid] or 0
            while cur ~= 0 do
                local cc = ns.computed[cur]
                if cc and cc.container_type and cc.container_type ~= "normal" then
                    -- If a name is required, it must match container-name
                    if not cg.name
                       or (cc.container_name and cc.container_name == cg.name) then
                        container_lay = ns.layout[cur]
                        break
                    end
                end
                cur = ns.parent[cur] or 0
            end
            if container_lay then
                local cw, ch = container_lay.w or 0, container_lay.h or 0
                local cond = cg.condition
                local matches = true
                if cond["min-width"] and cw < cond["min-width"] then matches = false end
                if cond["max-width"] and cw > cond["max-width"] then matches = false end
                if cond["min-height"] and ch < cond["min-height"] then matches = false end
                if cond["max-height"] and ch > cond["max-height"] then matches = false end
                if matches then
                    local cr = cg.rules
                    for i = 1, #cr.universal do out[#out + 1] = cr.universal[i] end
                    if tag_id and cr.by_tag[tag_id] then
                        local rr = cr.by_tag[tag_id]
                        for i = 1, #rr do out[#out + 1] = rr[i] end
                    end
                    if cls_list then
                        for ci = 1, #cls_list do
                            local cid = cls_list[ci]
                            if cid and cr.by_class[cid] then
                                local rr = cr.by_class[cid]
                                for i = 1, #rr do out[#out + 1] = rr[i] end
                            end
                        end
                    end
                    if id_str_id and id_str_id ~= 0 and cr.by_id[id_str_id] then
                        local rr = cr.by_id[id_str_id]
                        for i = 1, #rr do out[#out + 1] = rr[i] end
                    end
                    for i = 1, #cr.complex do
                        local entry = cr.complex[i]
                        if SelectorMatcher.matches(ns, nid, entry.parsed) then
                            out[#out + 1] = entry.rule
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Declaration application
------------------------------------------------------------

--- Resolve a structured value table to a plain value.
---@param v table  value descriptor {type=..., v=...}
---@return any
function SE:_resolve_value(v)
    if not v or type(v) ~= "table" then return v end
    local vtype = v.type
    if vtype == "color" then
        -- Return a copy of the color array
        local c = v.v
        if type(c) == "table" then
            -- Nested light-dark: is-color-prop wraps the parse_color
            -- result as {type="color", v=<light_dark>}, so the raw
            -- light_dark branch below never fires.  Resolve it here.
            if c.type == "light_dark" then
                local target = (self._color_scheme == "light") and c.light or c.dark
                if target then
                    return { target[1] or 0, target[2] or 0, target[3] or 0, target[4] or 255 }
                end
                return { 0, 0, 0, 255 }
            end
            return { c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 255 }
        end
        return { 0, 0, 0, 255 }
    elseif vtype == "light_dark" then
        -- light-dark() resolved against the current color scheme
        local target = (self._color_scheme == "light") and v.light or v.dark
        if target then
            return { target[1] or 0, target[2] or 0, target[3] or 0, target[4] or 255 }
        end
        return { 0, 0, 0, 255 }
    elseif vtype == "px" then
        return v.v or 0
    elseif vtype == "pct" then
        -- Percentage needs context; store as-is for now (resolved in layout)
        return v
    elseif vtype == "vw" or vtype == "vh" or vtype == "rem" then
        -- Viewport/rem units need context; store as-is (resolved in layout)
        return v
    elseif vtype == "auto" then
        return "auto"
    elseif vtype == "keyword" then
        return v.v or ""
    elseif vtype == "none" then
        return "none"
    elseif vtype == "calc" or vtype == "clamp" or vtype == "min" or vtype == "max" then
        -- Calc expressions: pass through for layout-time resolution
        return v
    elseif vtype == "linear-gradient" or vtype == "radial-gradient" or vtype == "conic-gradient" then
        -- Gradient: pass through
        return v
    elseif vtype == nil and type(v) == "table" and v[1] and type(v[1]) == "table" and v[1].type then
        -- Array of background images (multiple backgrounds): pass through
        return v
    elseif vtype == "var" then
        -- CSS variable reference: pass through for resolution in _compute_node
        return v
    elseif vtype == "url" then
        -- URL: pass through
        return v
    end
    return v
end

--- Apply an array of declarations to a computed style table.
---@param computed table  computed style table to modify
---@param decls    table  array of {prop_id, value} pairs
local function resolve_var_string(raw, variables, depth)
    if type(raw) ~= "string" then return raw end
    if not variables or not raw:find("var(", 1, true) then return raw end
    if (depth or 0) > 10 then return raw end

    local entire_name, entire_fallback = raw:match("^var%(%s*(%-%-[%w_%-]+)%s*,%s*(.-)%s*%)$")
    if not entire_name then
        entire_name = raw:match("^var%(%s*(%-%-[%w_%-]+)%s*%)$")
    end
    if entire_name then
        local v = variables[entire_name]
        if v == nil then v = entire_fallback end
        if v == nil then return raw end
        return resolve_var_string(v, variables, (depth or 0) + 1)
    end

    local out = raw:gsub("var%(%s*(%-%-[%w_%-]+)%s*,%s*([^%)]+)%)", function(name, fallback)
        local v = variables[name]
        if v == nil then v = fallback end
        v = resolve_var_string(v, variables, (depth or 0) + 1)
        return tostring(v)
    end)
    out = out:gsub("var%(%s*(%-%-[%w_%-]+)%s*%)", function(name)
        local v = variables[name]
        if v == nil then return "var(" .. name .. ")" end
        v = resolve_var_string(v, variables, (depth or 0) + 1)
        return tostring(v)
    end)
    return out
end

-- Image-typed value markers used to discriminate the two background slots
-- when a single `var()` is routed to both background-color and
-- background-image (see css_parser.expand_shorthands for the dual emit).
local _IMAGE_TYPES = {
    ["url"]                       = true,
    ["linear-gradient"]           = true,
    ["radial-gradient"]           = true,
    ["conic-gradient"]            = true,
    ["repeating-linear-gradient"] = true,
    ["repeating-radial-gradient"] = true,
    ["repeating-conic-gradient"]  = true,
}

function SE:_resolve_var_declaration(value, key, variables)
    local raw = nil
    if type(value) == "table" and value.type == "var" then
        raw = variables and variables[value.name] or nil
        if raw == nil then raw = value.fallback end
    elseif type(value) == "string" and value:find("var(", 1, true) then
        if not variables then return value end
        raw = value
    end
    if raw == nil then return value end

    raw = resolve_var_string(raw, variables, 0)
    if type(raw) ~= "string" then return raw end

    local CSSParser = require("core/html/css_parser")
    local parsed = CSSParser.parse_property_value(raw, key:gsub("_", "-"))

    -- Background-shorthand routing: a single var() is emitted to BOTH
    -- background-color and background-image because we cannot know its
    -- type at parse time. Skip the assignment when the resolved type
    -- doesn't match the slot -" returning nil here causes the caller
    -- (_apply_declarations) to leave the property at its previous value.
    local function looks_image_string(s)
        if type(s) ~= "string" then return false end
        return s:find("^url%(") ~= nil
            or s:find("^linear%-gradient%(") ~= nil
            or s:find("^radial%-gradient%(") ~= nil
            or s:find("^conic%-gradient%(") ~= nil
            or s:find("^repeating%-linear%-gradient%(") ~= nil
            or s:find("^repeating%-radial%-gradient%(") ~= nil
            or s:find("^repeating%-conic%-gradient%(") ~= nil
    end

    if key == "background_color" then
        if parsed == nil then return nil end
        if type(parsed) == "table" and parsed.type and _IMAGE_TYPES[parsed.type] then
            return nil
        end
        if looks_image_string(parsed) then return nil end
        if type(parsed) ~= "table" and parsed ~= "transparent" and parsed ~= "initial"
                and parsed ~= "inherit" and parsed ~= "unset" then
            -- Only string keywords above are valid for background-color;
            -- anything else as a string is an unrecognized value, drop it.
            -- (Color literals like "red"/"#fff" are returned as tables
            -- with type="color" by parse_value, so they take the first
            -- branch above and are unaffected.)
            return nil
        end
        return parsed
    elseif key == "background_image" then
        if parsed == nil then return nil end
        if type(parsed) == "table" and parsed.type == "color" then
            return nil
        end
        if type(parsed) ~= "table" and parsed ~= "none"
                and not looks_image_string(parsed) then
            return nil
        end
        return parsed
    end

    if parsed ~= nil then return parsed end
    return raw
end

function SE:_apply_declarations(computed, decls, parent_computed, variables)
    for i = 1, #decls do
        local decl = decls[i]
        local prop_id = decl[1]
        local value   = decl[2]

        local key = PROP_TO_KEY[prop_id]
        if key then
            value = self:_resolve_var_declaration(value, key, variables)
            -- CSS keywords: initial, inherit, unset
            if value == "initial" then
                local def = SE.DEFAULTS[key]
                computed[key] = def
            elseif value == "inherit" then
                if parent_computed then
                    computed[key] = parent_computed[key]
                else
                    computed[key] = SE.DEFAULTS[key]
                end
            elseif value == "unset" then
                if INHERITED[key] and parent_computed then
                    computed[key] = parent_computed[key]
                else
                    computed[key] = SE.DEFAULTS[key]
                end
            -- Resolve structured values
            elseif type(value) == "table" and value.type then
                computed[key] = self:_resolve_value(value)
            elseif type(value) == "table" then
                -- Plain table (e.g. color array) -- copy it
                local copy = {}
                for j = 1, #value do copy[j] = value[j] end
                if #copy == 0 then
                    for k, v in pairs(value) do copy[k] = v end
                end
                computed[key] = copy
            else
                computed[key] = value
            end
        end
    end
end

return SE



