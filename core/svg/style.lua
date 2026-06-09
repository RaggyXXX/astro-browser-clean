------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / style.lua
-- SVG presentation attribute parsing (fill, stroke, etc.).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgStyle = {}

local math_floor = math.floor

local function clamp_unit(v, fallback)
    local n = tonumber(v)
    if n == nil then n = fallback end
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

local function clamp_byte(v)
    v = math_floor((tonumber(v) or 0) + 0.5)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return v
end

------------------------------------------------------------
-- Named SVG colors (subset matching Chrome)
------------------------------------------------------------
local NAMED_COLORS = {
    black   = {0,0,0,255},       white   = {255,255,255,255},
    red     = {255,0,0,255},     green   = {0,128,0,255},
    blue    = {0,0,255,255},     yellow  = {255,255,0,255},
    cyan    = {0,255,255,255},   magenta = {255,0,255,255},
    gray    = {128,128,128,255}, grey    = {128,128,128,255},
    orange  = {255,165,0,255},   purple  = {128,0,128,255},
    pink    = {255,192,203,255}, brown   = {165,42,42,255},
    lime    = {0,255,0,255},     navy    = {0,0,128,255},
    teal    = {0,128,128,255},   maroon  = {128,0,0,255},
    olive   = {128,128,0,255},   aqua    = {0,255,255,255},
    silver  = {192,192,192,255}, fuchsia = {255,0,255,255},
    coral   = {255,127,80,255},  gold    = {255,215,0,255},
    indigo  = {75,0,130,255},    violet  = {238,130,238,255},
    salmon  = {250,128,114,255}, tomato  = {255,99,71,255},
    crimson = {220,20,60,255},   khaki   = {240,230,140,255},
    wheat   = {245,222,179,255}, tan     = {210,180,140,255},
    plum    = {221,160,221,255}, peru    = {205,133,63,255},
    sienna  = {160,82,45,255},   orchid  = {218,112,214,255},
    steelblue     = {70,130,180,255},
    dodgerblue    = {30,144,255,255},
    deepskyblue   = {0,191,255,255},
    royalblue     = {65,105,225,255},
    cornflowerblue = {100,149,237,255},
    darkblue      = {0,0,139,255},
    darkgreen     = {0,100,0,255},
    darkred       = {139,0,0,255},
    darkorange    = {255,140,0,255},
    darkviolet    = {148,0,211,255},
    lightgray     = {211,211,211,255},
    lightgrey     = {211,211,211,255},
    darkgray      = {169,169,169,255},
    darkgrey      = {169,169,169,255},
    whitesmoke    = {245,245,245,255},
    transparent   = {0,0,0,0},
    none          = nil,  -- sentinel
}

------------------------------------------------------------
-- Color parsing
------------------------------------------------------------

--- Parse a hex color string (#RGB, #RRGGBB, #RRGGBBAA).
local function parse_hex(s)
    local hex = s:match("^#(%x+)$")
    if not hex then return nil end
    local len = #hex
    if len == 3 then
        local r = tonumber(hex:sub(1,1), 16) * 17
        local g = tonumber(hex:sub(2,2), 16) * 17
        local b = tonumber(hex:sub(3,3), 16) * 17
        return {r, g, b, 255}
    elseif len == 6 then
        local r = tonumber(hex:sub(1,2), 16)
        local g = tonumber(hex:sub(3,4), 16)
        local b = tonumber(hex:sub(5,6), 16)
        return {r, g, b, 255}
    elseif len == 8 then
        local r = tonumber(hex:sub(1,2), 16)
        local g = tonumber(hex:sub(3,4), 16)
        local b = tonumber(hex:sub(5,6), 16)
        local a = tonumber(hex:sub(7,8), 16)
        return {r, g, b, a}
    end
    return nil
end

--- Parse rgb(r,g,b) or rgba(r,g,b,a).
local function parse_rgb(s)
    local r, g, b = s:match("rgb%s*%(([%d%.]+)%s*[,/]%s*([%d%.]+)%s*[,/]%s*([%d%.]+)%s*%)")
    if r then
        return {
            clamp_byte(r),
            clamp_byte(g),
            clamp_byte(b),
            255,
        }
    end
    local r2, g2, b2, a2 = s:match("rgba%s*%(([%d%.]+)%s*[,/]%s*([%d%.]+)%s*[,/]%s*([%d%.]+)%s*[,/]%s*([%d%.]+)%s*%)")
    if r2 then
        local alpha = math_floor(clamp_unit(a2, 1) * 255 + 0.5)
        return {
            clamp_byte(r2),
            clamp_byte(g2),
            clamp_byte(b2),
            alpha,
        }
    end
    return nil
end

--- Parse any SVG color value.
--- Returns {r,g,b,a} table, "none" string, or nil.
---@param v string|table|nil
---@return table|string|nil
function SvgStyle.parse_color(v)
    if not v then return nil end
    if type(v) == "table" then return v end
    if type(v) ~= "string" then return nil end

    local s = v:lower():match("^%s*(.-)%s*$")
    if s == "none" or s == "" then return "none" end
    if s == "currentcolor" or s == "currentColor" then return "currentcolor" end

    -- Named color
    if NAMED_COLORS[s] ~= nil then
        local c = NAMED_COLORS[s]
        if c then return { c[1], c[2], c[3], c[4] } end
        return "none"
    end

    -- Hex
    local hex = parse_hex(s)
    if hex then return hex end

    -- rgb/rgba
    local rgb = parse_rgb(s)
    if rgb then return rgb end

    return nil
end

------------------------------------------------------------
-- SVG style resolution with inheritance
------------------------------------------------------------

--- Resolve SVG presentation attributes for a node.
--- Inherits fill/stroke/stroke-width etc. from parent per SVG spec.
---@param attrs    table|nil  Node attributes
---@param parent   table|nil  Parent resolved style (or nil for root)
---@return table  Resolved style { fill, stroke, stroke_width, opacity, fill_opacity, stroke_opacity, stroke_linecap, stroke_linejoin, stroke_miterlimit, stroke_dasharray, stroke_dashoffset }
function SvgStyle.resolve(attrs, parent)
    attrs = attrs or {}
    parent = parent or {}

    -- Parse inline style="" attribute (per SVG spec: inline style overrides presentation attrs)
    local inline_style = attrs.style
    if inline_style and type(inline_style) == "string" then
        for prop, val in inline_style:gmatch("([%w%-]+)%s*:%s*([^;]+)") do
            local key = prop:gsub("%-", "_"):match("^%s*(.-)%s*$")
            val = val:match("^%s*(.-)%s*$")
            attrs[key] = val  -- inline style takes precedence over presentation attrs
        end
    end

    local style = {}

    -- color: inherited, default black. fill/stroke may reference it through
    -- currentColor.
    local raw_color = attrs.color
    if raw_color then
        style.color = SvgStyle.parse_color(raw_color)
    else
        style.color = parent.color or { 0, 0, 0, 255 }
    end
    if style.color == "currentcolor" or style.color == "none" or style.color == nil then
        style.color = parent.color or { 0, 0, 0, 255 }
    end

    -- fill: inherited, default black
    local raw_fill = attrs.fill
    if raw_fill then
        style.fill = SvgStyle.parse_color(raw_fill)
    else
        style.fill = parent.fill or { 0, 0, 0, 255 }
    end

    -- stroke: inherited, default none
    local raw_stroke = attrs.stroke
    if raw_stroke then
        style.stroke = SvgStyle.parse_color(raw_stroke)
    else
        style.stroke = parent.stroke or "none"
    end

    if style.fill == "currentcolor" then
        style.fill = { style.color[1], style.color[2], style.color[3], style.color[4] }
    end
    if style.stroke == "currentcolor" then
        style.stroke = { style.color[1], style.color[2], style.color[3], style.color[4] }
    end

    -- stroke-width: inherited, default 1
    local raw_sw = attrs["stroke-width"] or attrs.stroke_width
    if raw_sw then
        style.stroke_width = tonumber(raw_sw) or 1
    else
        style.stroke_width = parent.stroke_width or 1
    end

    -- opacity (element-level)
    local raw_op = attrs.opacity
    if raw_op then
        style.opacity = clamp_unit(raw_op, 1)
    else
        style.opacity = 1
    end

    -- fill-opacity
    local raw_fo = attrs["fill-opacity"] or attrs.fill_opacity
    if raw_fo then
        style.fill_opacity = clamp_unit(raw_fo, 1)
    else
        style.fill_opacity = parent.fill_opacity or 1
    end

    -- stroke-opacity
    local raw_so = attrs["stroke-opacity"] or attrs.stroke_opacity
    if raw_so then
        style.stroke_opacity = clamp_unit(raw_so, 1)
    else
        style.stroke_opacity = parent.stroke_opacity or 1
    end

    -- stroke-linecap: inherited, default butt
    style.stroke_linecap = attrs["stroke-linecap"] or attrs.stroke_linecap
        or parent.stroke_linecap or "butt"

    -- stroke-linejoin: inherited, default miter
    style.stroke_linejoin = attrs["stroke-linejoin"] or attrs.stroke_linejoin
        or parent.stroke_linejoin or "miter"

    -- stroke-miterlimit: inherited, default 4
    local raw_ml = attrs["stroke-miterlimit"] or attrs.stroke_miterlimit
    if raw_ml then
        style.stroke_miterlimit = tonumber(raw_ml) or 4
    else
        style.stroke_miterlimit = parent.stroke_miterlimit or 4
    end

    -- stroke-dasharray (string, inherited)
    style.stroke_dasharray = attrs["stroke-dasharray"] or attrs.stroke_dasharray
        or parent.stroke_dasharray

    -- stroke-dashoffset
    local raw_do = attrs["stroke-dashoffset"] or attrs.stroke_dashoffset
    if raw_do then
        style.stroke_dashoffset = tonumber(raw_do) or 0
    else
        style.stroke_dashoffset = parent.stroke_dashoffset or 0
    end

    -- fill-rule: inherited, default nonzero
    style.fill_rule = attrs["fill-rule"] or attrs.fill_rule
        or parent.fill_rule or "nonzero"

    return style
end

return SvgStyle



