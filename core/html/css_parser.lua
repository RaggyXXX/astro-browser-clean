------------------------------------------------------------
-- ext_core_astro_ui_lib / core / html / css_parser.lua
-- CSS String Parser: tokenizes CSS text into bucketed rules
-- compatible with the engine's style system.
--
-- Input:  CSS string (e.g. "div { color: red; padding: 10px; }")
-- Output: rules table { by_id, by_class, by_tag, universal, complex, media }
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local SelectorParser = require("core/style/selector_parser")
local CalcParser     = require("core/style/calc_parser")

local CSSParser = {}

------------------------------------------------------------
-- Property name → ID mapping (CSS kebab-case → engine IDs)
-- Mirrors SE.PROP from style_engine.lua
------------------------------------------------------------
local PROP = {
    ["display"]             = 1,  ["position"]            = 2,
    ["width"]               = 3,  ["height"]              = 4,
    ["padding-top"]         = 5,  ["padding-right"]       = 6,
    ["padding-bottom"]      = 7,  ["padding-left"]        = 8,
    ["margin-top"]          = 9,  ["margin-right"]        = 10,
    ["margin-bottom"]       = 11, ["margin-left"]         = 12,
    ["border-width"]        = 13, ["border-color"]        = 14,
    ["border-radius"]       = 15, ["background-color"]    = 16,
    ["color"]               = 17, ["font-size"]           = 18,
    ["text-align"]          = 19, ["white-space"]         = 20,
    ["text-overflow"]       = 21, ["overflow-x"]          = 22,
    ["overflow-y"]          = 23, ["flex-direction"]      = 24,
    ["flex-wrap"]           = 25, ["flex-grow"]           = 26,
    ["flex-shrink"]         = 27, ["flex-basis"]          = 28,
    ["opacity"]             = 29, ["visibility"]          = 30,
    ["z-index"]             = 31, ["left"]                = 32,
    ["top"]                 = 33, ["right"]               = 34,
    ["bottom"]              = 35, ["align-items"]         = 36,
    ["align-self"]          = 37, ["align-content"]       = 38,
    ["justify-content"]     = 39, ["box-sizing"]          = 40,
    ["line-height"]         = 41, ["cursor"]              = 42,
    ["gap"]                 = 43, ["min-width"]           = 44,
    ["min-height"]          = 45, ["max-width"]           = 46,
    ["max-height"]          = 47, ["order"]               = 48,
    ["row-gap"]             = 49, ["column-gap"]          = 50,
    ["font-family"]         = 51, ["font-weight"]         = 52,
    ["font-style"]          = 53, ["letter-spacing"]      = 54,
    ["word-spacing"]        = 55, ["text-decoration"]     = 56,
    ["text-transform"]      = 57, ["text-indent"]         = 58,
    ["text-shadow"]         = 59,
    -- Grid
    ["grid-template-columns"] = 62, ["grid-template-rows"] = 63,
    ["grid-auto-rows"]      = 64, ["grid-auto-columns"]   = 65,
    ["grid-column"]         = 66, ["grid-row"]            = 67,
    ["grid-column-start"]   = 68, ["grid-column-end"]     = 69,
    ["grid-row-start"]      = 70, ["grid-row-end"]        = 71,
    ["justify-items"]       = 72,
    ["transform"]           = 73, ["transform-origin"]    = 74,
    ["object-fit"]          = 75,
    ["background-image"]    = 76, ["background-size"]     = 77,
    ["background-position"] = 78, ["background-repeat"]   = 79,
    ["transition-property"]          = 80, ["transition-duration"]          = 81,
    ["transition-timing-function"]   = 82, ["transition-delay"]             = 83,
    ["animation-name"]               = 84, ["animation-duration"]           = 85,
    ["animation-delay"]              = 86, ["animation-iteration-count"]    = 87,
    ["animation-direction"]          = 88, ["animation-timing-function"]    = 89,
    ["animation-fill-mode"]          = 90,
    ["border-top-width"]             = 91, ["border-right-width"]           = 92,
    ["border-bottom-width"]          = 93, ["border-left-width"]            = 94,
    ["border-top-color"]             = 95, ["border-right-color"]           = 96,
    ["border-bottom-color"]          = 97, ["border-left-color"]            = 98,
    ["border-style"]                 = 99, ["border-top-style"]             = 100,
    ["border-right-style"]           = 101, ["border-bottom-style"]         = 102,
    ["border-left-style"]            = 103,
    ["box-shadow"]                   = 104,
    ["outline-width"]                = 105, ["outline-color"]               = 106,
    ["outline-offset"]               = 107, ["outline-style"]               = 108,
    ["content"]                      = 109,
    ["pointer-events"]               = 110,
    ["aspect-ratio"]                 = 111,
    ["vertical-align"]               = 112,
    ["word-break"]                   = 113,
    ["overflow-wrap"]                = 114,
    ["border-top-left-radius"]       = 115,
    ["border-top-right-radius"]      = 116,
    ["border-bottom-right-radius"]   = 117,
    ["border-bottom-left-radius"]    = 118,
    ["float"]                        = 119,
    ["clear"]                        = 120,
    ["text-decoration-color"]        = 121,
    ["text-decoration-style"]        = 122,
    ["text-decoration-thickness"]    = 123,
    ["list-style-type"]              = 124,
    ["list-style-position"]          = 125,
    ["border-collapse"]              = 126,
    ["border-spacing"]               = 127,
    ["filter"]                       = 128,
    ["column-count"]                 = 129,
    ["column-width"]                 = 130,
    ["column-rule-width"]            = 131,
    ["column-rule-color"]            = 132,
    ["column-rule-style"]            = 133,
    ["counter-reset"]                = 134,
    ["counter-increment"]            = 135,
    ["clip-path"]                    = 136,
    -- Tier 6: critical missing features
    ["backdrop-filter"]              = 137,
    ["-webkit-line-clamp"]           = 138,
    ["line-clamp"]                   = 138,
    ["direction"]                    = 139,
    ["writing-mode"]                 = 140,
    ["unicode-bidi"]                 = 141,
    ["animation-play-state"]         = 142,
    ["user-select"]                  = 143,
    ["scroll-behavior"]              = 144,
    ["scroll-snap-type"]             = 145,
    ["scroll-snap-align"]            = 146,
    ["resize"]                       = 147,
    ["background-clip"]              = 148,
    ["-webkit-background-clip"]      = 148,
    ["caret-color"]                  = 149,
    ["accent-color"]                 = 150,
    ["tab-size"]                     = 151,
    ["text-align-last"]              = 152,
    ["overscroll-behavior-x"]        = 153,
    ["overscroll-behavior-y"]        = 154,
    ["scroll-padding-top"]           = 155,
    ["scroll-padding-right"]         = 156,
    ["scroll-padding-bottom"]        = 157,
    ["scroll-padding-left"]          = 158,
    ["scroll-margin-top"]            = 159,
    ["scroll-margin-right"]          = 160,
    ["scroll-margin-bottom"]         = 161,
    ["scroll-margin-left"]           = 162,
    ["mix-blend-mode"]               = 163,
    ["grid-template-areas"]          = 164,
    ["grid-area"]                    = 165,
    ["grid-auto-flow"]               = 166,
    ["mask-image"]                   = 167,
    ["mask-size"]                    = 168,
    ["mask-position"]                = 169,
    ["mask-repeat"]                  = 170,
    ["text-wrap"]                    = 171,
    ["hyphens"]                      = 172,
    ["font-variant"]                 = 173,
    ["font-stretch"]                 = 174,
    ["container-type"]               = 175,
    ["container-name"]               = 176,
    ["contain"]                      = 177,
    ["isolation"]                    = 178,
    ["background-attachment"]        = 179,
    ["background-origin"]            = 180,
    ["list-style-image"]             = 181,
    ["scrollbar-color"]              = 182,
    ["scrollbar-width"]              = 183,
    ["justify-self"]                 = 184,
    ["appearance"]                   = 185,
    ["-webkit-appearance"]           = 185,
    ["table-layout"]                 = 186,
    -- Shorthand aliases (not real IDs, handled by expansion)
    ["overflow"]            = -1,
    ["padding"]             = -2,
    ["margin"]              = -3,
    ["border"]              = -4,
    ["background"]          = -5,
    ["flex"]                = -6,
    ["font"]                = -7,
    ["outline"]             = -8,
    ["overscroll-behavior"] = -9,
    ["scroll-padding"]      = -10,
    ["scroll-margin"]       = -11,
    ["place-items"]         = -12,
    ["place-content"]       = -13,
    ["place-self"]          = -14,
    ["border-inline-width"] = -15,
    ["border-block-width"]  = -16,
    ["border-inline-color"] = -17,
    ["border-block-color"]  = -18,
    ["border-inline-style"] = -19,
    ["border-block-style"]  = -20,
    ["border-inline"]       = -21,
    ["border-block"]        = -22,
    ["border-inline-start"] = -23,
    ["border-inline-end"]   = -24,
    ["border-block-start"]  = -25,
    ["border-block-end"]    = -26,
    ["inline-size"]         = -27,
    ["block-size"]          = -28,
    ["min-inline-size"]     = -29,
    ["max-inline-size"]     = -30,
    ["min-block-size"]      = -31,
    ["max-block-size"]      = -32,
    ["margin-inline"]       = -33,
    ["margin-block"]        = -34,
    ["padding-inline"]      = -35,
    ["padding-block"]       = -36,
    ["inset"]               = -37,
    ["inset-inline"]        = -38,
    ["inset-block"]         = -39,
    ["border-start-start-radius"] = -40,
    ["border-start-end-radius"]   = -41,
    ["border-end-start-radius"]   = -42,
    ["border-end-end-radius"]     = -43,
    ["margin-inline-start"] = -44,
    ["margin-inline-end"]   = -45,
    ["margin-block-start"]  = -46,
    ["margin-block-end"]    = -47,
    ["padding-inline-start"] = -48,
    ["padding-inline-end"]   = -49,
    ["padding-block-start"]  = -50,
    ["padding-block-end"]    = -51,
    ["inset-inline-start"]   = -52,
    ["inset-inline-end"]     = -53,
    ["inset-block-start"]    = -54,
    ["inset-block-end"]      = -55,
    ["border-inline-start-width"] = -56,
    ["border-inline-end-width"]   = -57,
    ["border-block-start-width"]  = -58,
    ["border-block-end-width"]    = -59,
    ["border-inline-start-color"] = -60,
    ["border-inline-end-color"]   = -61,
    ["border-block-start-color"]  = -62,
    ["border-block-end-color"]    = -63,
    ["border-inline-start-style"] = -64,
    ["border-inline-end-style"]   = -65,
    ["border-block-start-style"]  = -66,
    ["border-block-end-style"]    = -67,
    ["overflow-inline"] = -68,
    ["overflow-block"]  = -69,
}

local math_floor = math.floor

local CSS_KEYWORD_VALUES = {
    inherit=1, initial=1, unset=1, revert=1, none=1, auto=1, normal=1,
    block=1, inline=1, flex=1, grid=1, table=1, ["inline-block"]=1,
    ["inline-flex"]=1, ["inline-grid"]=1, contents=1,
    hidden=1, visible=1, scroll=1, collapse=1, clip=1,
    absolute=1, relative=1, fixed=1, sticky=1, static=1,
    row=1, column=1, wrap=1, nowrap=1, ["row-reverse"]=1, ["column-reverse"]=1,
    ["wrap-reverse"]=1, center=1, start=1, ["end"]=1, stretch=1,
    ["flex-start"]=1, ["flex-end"]=1, ["space-between"]=1, ["space-around"]=1,
    ["space-evenly"]=1, baseline=1, bold=1, italic=1, underline=1,
    solid=1, dashed=1, dotted=1, double=1, groove=1, ridge=1, inset=1, outset=1,
    left=1, right=1, top=1, bottom=1, both=1,
    pointer=1, text=1, ["border-box"]=1, ["padding-box"]=1, ["content-box"]=1,
    cover=1, contain=1, ["no-repeat"]=1, ["repeat"]=1, ["repeat-x"]=1, ["repeat-y"]=1,
    space=1, round=1, ["local"]=1,
}

local function sorted_keys_by_kind(want_shorthand)
    local out = {}
    for name, id in pairs(PROP) do
        if (id < 0) == want_shorthand then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

--- Return a copy of the known CSS property map.
--- Positive IDs are runtime properties; negative IDs are parser-only shorthands.
function CSSParser.get_property_map()
    local copy = {}
    for name, id in pairs(PROP) do
        copy[name] = id
    end
    return copy
end

--- Return sorted runtime property names.
function CSSParser.get_known_properties()
    return sorted_keys_by_kind(false)
end

--- Return sorted parser shorthand names.
function CSSParser.get_known_shorthands()
    return sorted_keys_by_kind(true)
end

------------------------------------------------------------
-- Logical properties -> physical property mapping (horizontal-tb, LTR)
------------------------------------------------------------
local LOGICAL_MAP = {
    ["inline-size"]         = "width",
    ["block-size"]          = "height",
    ["min-inline-size"]     = "min-width",
    ["max-inline-size"]     = "max-width",
    ["min-block-size"]      = "min-height",
    ["max-block-size"]      = "max-height",
    ["overflow-inline"]     = "overflow-x",
    ["overflow-block"]      = "overflow-y",
    ["margin-inline-start"]  = "margin-left",
    ["margin-inline-end"]    = "margin-right",
    ["margin-block-start"]   = "margin-top",
    ["margin-block-end"]     = "margin-bottom",
    ["padding-inline-start"] = "padding-left",
    ["padding-inline-end"]   = "padding-right",
    ["padding-block-start"]  = "padding-top",
    ["padding-block-end"]    = "padding-bottom",
    ["border-start-start-radius"] = "border-top-left-radius",
    ["border-start-end-radius"]   = "border-top-right-radius",
    ["border-end-start-radius"]   = "border-bottom-left-radius",
    ["border-end-end-radius"]     = "border-bottom-right-radius",
    ["border-inline-start-width"] = "border-left-width",
    ["border-inline-end-width"]   = "border-right-width",
    ["border-block-start-width"]  = "border-top-width",
    ["border-block-end-width"]    = "border-bottom-width",
    ["border-inline-start-color"] = "border-left-color",
    ["border-inline-end-color"]   = "border-right-color",
    ["border-block-start-color"]  = "border-top-color",
    ["border-block-end-color"]    = "border-bottom-color",
    ["border-inline-start-style"] = "border-left-style",
    ["border-inline-end-style"]   = "border-right-style",
    ["border-block-start-style"]  = "border-top-style",
    ["border-block-end-style"]    = "border-bottom-style",
    ["inset-inline-start"] = "left",
    ["inset-inline-end"]   = "right",
    ["inset-block-start"]  = "top",
    ["inset-block-end"]    = "bottom",
}

local split_css_value_tokens

--- Split a value string into 1 or 2 whitespace-separated tokens.
local function split_two_values(str)
    local parts = split_css_value_tokens(str)
    return parts[1] or str, parts[2]
end

function split_css_value_tokens(str)
    local tokens = {}
    local depth = 0
    local quote = nil
    local start = 1
    local i = 1
    while i <= #str do
        local ch = str:sub(i, i)
        if quote then
            if ch == "\\" then
                i = i + 1
            elseif ch == quote then
                quote = nil
            end
        elseif ch == '"' or ch == "'" then
            quote = ch
        elseif ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            if depth > 0 then depth = depth - 1 end
        elseif ch:match("%s") and depth == 0 then
            local tok = str:sub(start, i - 1):match("^%s*(.-)%s*$")
            if tok ~= "" then tokens[#tokens + 1] = tok end
            start = i + 1
        end
        i = i + 1
    end
    local last = str:sub(start):match("^%s*(.-)%s*$")
    if last ~= "" then tokens[#tokens + 1] = last end
    return tokens
end

local function split_top_level_commas(str)
    local parts = {}
    local depth = 0
    local quote = nil
    local start = 1
    local i = 1
    while i <= #str do
        local ch = str:sub(i, i)
        if quote then
            if ch == "\\" then
                i = i + 1
            elseif ch == quote then
                quote = nil
            end
        elseif ch == '"' or ch == "'" then
            quote = ch
        elseif ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            if depth > 0 then depth = depth - 1 end
        elseif ch == "," and depth == 0 then
            local part = str:sub(start, i - 1):match("^%s*(.-)%s*$")
            if part ~= "" then parts[#parts + 1] = part end
            start = i + 1
        end
        i = i + 1
    end
    local last = str:sub(start):match("^%s*(.-)%s*$")
    if last ~= "" then parts[#parts + 1] = last end
    return parts
end

local function split_selector_list(selector)
    local parts = {}
    local depth_paren = 0
    local depth_bracket = 0
    local quote = nil
    local i = 1
    local start = 1
    while i <= #selector do
        local ch = selector:sub(i, i)
        if quote then
            if ch == "\\" then
                i = i + 1
            elseif ch == quote then
                quote = nil
            end
        elseif ch == '"' or ch == "'" then
            quote = ch
        elseif ch == "(" then
            depth_paren = depth_paren + 1
        elseif ch == ")" then
            if depth_paren > 0 then depth_paren = depth_paren - 1 end
        elseif ch == "[" then
            depth_bracket = depth_bracket + 1
        elseif ch == "]" then
            if depth_bracket > 0 then depth_bracket = depth_bracket - 1 end
        elseif ch == "," and depth_paren == 0 and depth_bracket == 0 then
            local part = selector:sub(start, i - 1):match("^%s*(.-)%s*$")
            if part ~= "" then parts[#parts + 1] = part end
            start = i + 1
        end
        i = i + 1
    end
    local last = selector:sub(start):match("^%s*(.-)%s*$")
    if last ~= "" then parts[#parts + 1] = last end
    return parts
end

------------------------------------------------------------
-- Color parsing (CSS color strings → {r,g,b,a})
------------------------------------------------------------
local NAMED_COLORS = {
    black       = {0,0,0,255},
    white       = {255,255,255,255},
    red         = {255,0,0,255},
    green       = {0,128,0,255},
    blue        = {0,0,255,255},
    yellow      = {255,255,0,255},
    cyan        = {0,255,255,255},
    magenta     = {255,0,255,255},
    orange      = {255,165,0,255},
    purple      = {128,0,128,255},
    gray        = {128,128,128,255},
    grey        = {128,128,128,255},
    pink        = {255,192,203,255},
    lime        = {0,255,0,255},
    navy        = {0,0,128,255},
    teal        = {0,128,128,255},
    silver      = {192,192,192,255},
    maroon      = {128,0,0,255},
    olive       = {128,128,0,255},
    aqua        = {0,255,255,255},
    fuchsia     = {255,0,255,255},
    transparent = {0,0,0,0},
    inherit     = nil,
    currentcolor = nil,
    -- Common web grays
    dimgray     = {105,105,105,255},
    darkgray    = {169,169,169,255},
    lightgray   = {211,211,211,255},
    whitesmoke  = {245,245,245,255},
    gainsboro   = {220,220,220,255},
    -- Common web colors
    tomato      = {255,99,71,255},
    coral       = {255,127,80,255},
    salmon      = {250,128,114,255},
    crimson     = {220,20,60,255},
    firebrick   = {178,34,34,255},
    darkred     = {139,0,0,255},
    gold        = {255,215,0,255},
    khaki       = {240,230,140,255},
    plum        = {221,160,221,255},
    violet      = {238,130,238,255},
    indigo      = {75,0,130,255},
    slateblue   = {106,90,205,255},
    dodgerblue  = {30,144,255,255},
    steelblue   = {70,130,180,255},
    skyblue     = {135,206,235,255},
    turquoise   = {64,224,208,255},
    seagreen    = {46,139,87,255},
    limegreen   = {50,205,50,255},
    darkgreen   = {0,100,0,255},
    sienna      = {160,82,45,255},
    chocolate   = {210,105,30,255},
    peru        = {205,133,63,255},
    tan         = {210,180,140,255},
    wheat       = {245,222,179,255},
    linen       = {250,240,230,255},
    beige       = {245,245,220,255},
    ivory       = {255,255,240,255},
    snow        = {255,250,250,255},
    honeydew    = {240,255,240,255},
    mintcream   = {245,255,250,255},
    azure       = {240,255,255,255},
    aliceblue   = {240,248,255,255},
    lavender    = {230,230,250,255},
    mistyrose   = {255,228,225,255},
    cornsilk    = {255,248,220,255},
}

local function parse_color(s)
    if not s or s == "" then return nil end
    s = s:match("^%s*(.-)%s*$") -- trim

    -- `currentcolor` (and the legacy `currentColor` spelling) is a token
    -- that resolves at computed-value time against the element's own
    -- `color` property.  Return a sentinel; the style engine resolves it
    -- after the regular cascade has produced `computed.color`.
    local lowered = s:lower()
    if lowered == "currentcolor" then
        return { type = "currentcolor" }
    end

    -- #hex
    if s:sub(1,1) == "#" then
        local hex = s:sub(2)
        if #hex == 3 then
            local r = tonumber(hex:sub(1,1), 16)
            local g = tonumber(hex:sub(2,2), 16)
            local b = tonumber(hex:sub(3,3), 16)
            if not (r and g and b) then return nil end
            r = r * 17; g = g * 17; b = b * 17
            return {r, g, b, 255}
        elseif #hex == 4 then
            local r = tonumber(hex:sub(1,1), 16)
            local g = tonumber(hex:sub(2,2), 16)
            local b = tonumber(hex:sub(3,3), 16)
            local a = tonumber(hex:sub(4,4), 16)
            if not (r and g and b and a) then return nil end
            r = r * 17; g = g * 17; b = b * 17; a = a * 17
            return {r, g, b, a}
        elseif #hex == 6 then
            local r = tonumber(hex:sub(1,2), 16)
            local g = tonumber(hex:sub(3,4), 16)
            local b = tonumber(hex:sub(5,6), 16)
            if not (r and g and b) then return nil end
            return {
                r,
                g,
                b,
                255,
            }
        elseif #hex == 8 then
            local r = tonumber(hex:sub(1,2), 16)
            local g = tonumber(hex:sub(3,4), 16)
            local b = tonumber(hex:sub(5,6), 16)
            local a = tonumber(hex:sub(7,8), 16)
            if not (r and g and b and a) then return nil end
            return {
                r,
                g,
                b,
                a,
            }
        end
    end

    -- rgb(r, g, b) / rgba(r, g, b, a) -" also handles modern space syntax
    local function clamp_byte(v)
        v = tonumber(v) or 0
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        return math_floor(v + 0.5)
    end
    local function parse_rgb_channel(tok)
        local n = tonumber((tok or ""):match("^[%+%-]?[%d%.]+"))
        if not n then return 0 end
        if tok:find("%%") then return clamp_byte(n / 100 * 255) end
        return clamp_byte(n)
    end
    local function parse_alpha(tok)
        local n = tonumber((tok or ""):match("^[%+%-]?[%d%.]+"))
        if not n then return 255 end
        if tok:find("%%") then return clamp_byte(n / 100 * 255) end
        if n <= 1 then return clamp_byte(n * 255) end
        return clamp_byte(n)
    end

    local fn = s:match("^rgba?%s*%((.+)%)$")
    if fn then
        -- Normalize: replace slashes with commas, commas with spaces
        fn = fn:gsub("/", ",")
        local parts = {}
        for tok in fn:gmatch("[^,%s]+") do
            parts[#parts + 1] = tok
        end
        if #parts >= 3 then
            local r = parse_rgb_channel(parts[1])
            local g = parse_rgb_channel(parts[2])
            local b = parse_rgb_channel(parts[3])
            local a = parts[4] and parse_alpha(parts[4]) or 255
            return {r, g, b, a}
        end
    end

    -- hsl(h, s%, l%) / hsla(h, s%, l%, a) -" basic support
    local hsl_fn = s:match("^hsla?%s*%((.+)%)$")
    if hsl_fn then
        hsl_fn = hsl_fn:gsub("/", ",")
        local parts = {}
        for tok in hsl_fn:gmatch("[^,%s]+") do
            parts[#parts + 1] = tok
        end
        if #parts >= 3 then
            local h = (tonumber(parts[1]:match("[%d%.]+")) or 0) / 360
            local sat = (tonumber(parts[2]:match("[%d%.]+")) or 0) / 100
            local l = (tonumber(parts[3]:match("[%d%.]+")) or 0) / 100
            local a = parts[4] and parse_alpha(parts[4]) or 255
            -- HSL to RGB
            local function hue2rgb(p, q, t)
                if t < 0 then t = t + 1 end
                if t > 1 then t = t - 1 end
                if t < 1/6 then return p + (q - p) * 6 * t end
                if t < 1/2 then return q end
                if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
                return p
            end
            local r, g, b
            if sat == 0 then
                r = l; g = l; b = l
            else
                local q = l < 0.5 and (l * (1 + sat)) or (l + sat - l * sat)
                local p = 2 * l - q
                r = hue2rgb(p, q, h + 1/3)
                g = hue2rgb(p, q, h)
                b = hue2rgb(p, q, h - 1/3)
            end
            return {math_floor(r*255+0.5), math_floor(g*255+0.5), math_floor(b*255+0.5), a}
        end
    end

    -- Named colors
    local named = NAMED_COLORS[s:lower()]
    if named then return {named[1], named[2], named[3], named[4]} end

    -- hwb(hue W% B% [/ alpha]) → HSL-like computation: white is added, black subtracted
    local hwb_fn = s:match("^hwb%s*%((.+)%)$")
    if hwb_fn then
        hwb_fn = hwb_fn:gsub("/", ",")
        local parts = {}
        for tok in hwb_fn:gmatch("[^,%s]+") do parts[#parts+1] = tok end
        if #parts >= 3 then
            local h = (tonumber(parts[1]:match("[%d%.%-]+")) or 0) % 360 / 360
            local w = (tonumber(parts[2]:match("[%d%.]+")) or 0) / 100
            local bk = (tonumber(parts[3]:match("[%d%.]+")) or 0) / 100
            local a = 255
            if parts[4] then
                local raw4 = parts[4]
                local av = tonumber(raw4:match("[%d%.]+"))
                if av then
                    if raw4:find("%%") then a = math_floor(av / 100 * 255 + 0.5)
                    elseif av <= 1 then a = math_floor(av * 255 + 0.5)
                    else a = math_floor(av + 0.5) end
                end
            end
            -- Clamp if white+black >= 1
            if w + bk >= 1 then
                local gray = w / (w + bk)
                local v = math_floor(gray * 255 + 0.5)
                return { v, v, v, a }
            end
            -- HSL with fully saturated colors, then scale by (1-w-bk) and add w
            local function h_to_rgb(hh)
                local k = (hh * 6) % 6
                if k < 1 then return 1, k, 0
                elseif k < 2 then return 2 - k, 1, 0
                elseif k < 3 then return 0, 1, k - 2
                elseif k < 4 then return 0, 4 - k, 1
                elseif k < 5 then return k - 4, 0, 1
                else return 1, 0, 6 - k end
            end
            local pr, pg, pb = h_to_rgb(h)
            local scale = 1 - w - bk
            local rr = pr * scale + w
            local gg = pg * scale + w
            local bb = pb * scale + w
            return { math_floor(rr*255+0.5), math_floor(gg*255+0.5), math_floor(bb*255+0.5), a }
        end
    end

    -- oklab(L a b [/ alpha])  0<=L<=1 (or 0..100%), a/b unbounded but typically -0.4..+0.4
    local oklab_fn = s:match("^oklab%s*%((.+)%)$")
    if oklab_fn then
        oklab_fn = oklab_fn:gsub("/", ",")
        local parts = {}
        for tok in oklab_fn:gmatch("[^,%s]+") do parts[#parts+1] = tok end
        if #parts >= 3 then
            local L = tonumber(parts[1]:match("[%d%.%-]+")) or 0
            if parts[1]:find("%%") then L = L / 100 end
            local a = tonumber(parts[2]:match("[%d%.%-]+")) or 0
            if parts[2]:find("%%") then a = a * 0.004 end  -- 100% → 0.4
            local b = tonumber(parts[3]:match("[%d%.%-]+")) or 0
            if parts[3]:find("%%") then b = b * 0.004 end
            local alpha = 255
            if parts[4] then
                local av = tonumber(parts[4]:match("[%d%.]+"))
                if av then
                    if parts[4]:find("%%") then alpha = math_floor(av/100*255+0.5)
                    elseif av <= 1 then alpha = math_floor(av*255+0.5)
                    else alpha = math_floor(av+0.5) end
                end
            end
            -- OKLab → linear sRGB (per CSS Color 4 spec matrix)
            local l_ = L + 0.3963377774 * a + 0.2158037573 * b
            local m_ = L - 0.1055613458 * a - 0.0638541728 * b
            local s_ = L - 0.0894841775 * a - 1.2914855480 * b
            local l = l_ ^ 3
            local m = m_ ^ 3
            local sm = s_ ^ 3
            local rl = (4.0767416621) * l + (-3.3077115913) * m + (0.2309699292) * sm
            local gl = (-1.2684380046) * l + (2.6097574011) * m + (-0.3413193965) * sm
            local bl = (-0.0041960863) * l + (-0.7034186147) * m + (1.7076147010) * sm
            local function lin_to_srgb(c)
                if c <= 0.0031308 then return 12.92 * c end
                return 1.055 * (c ^ (1/2.4)) - 0.055
            end
            local rr = math.max(0, math.min(1, lin_to_srgb(rl)))
            local gg = math.max(0, math.min(1, lin_to_srgb(gl)))
            local bb = math.max(0, math.min(1, lin_to_srgb(bl)))
            return { math_floor(rr*255+0.5), math_floor(gg*255+0.5), math_floor(bb*255+0.5), alpha }
        end
    end

    -- oklch(L C H [/ alpha]) -" polar form of oklab
    local oklch_fn = s:match("^oklch%s*%((.+)%)$")
    if oklch_fn then
        oklch_fn = oklch_fn:gsub("/", ",")
        local parts = {}
        for tok in oklch_fn:gmatch("[^,%s]+") do parts[#parts+1] = tok end
        if #parts >= 3 then
            local L = tonumber(parts[1]:match("[%d%.%-]+")) or 0
            if parts[1]:find("%%") then L = L / 100 end
            local C = tonumber(parts[2]:match("[%d%.%-]+")) or 0
            if parts[2]:find("%%") then C = C * 0.004 end
            local hue_deg = tonumber(parts[3]:match("[%d%.%-]+")) or 0
            local h_rad = hue_deg * math.pi / 180
            local a = C * math.cos(h_rad)
            local b = C * math.sin(h_rad)
            local alpha_str = parts[4] or "1"
            -- Delegate to oklab with the computed a,b
            local oklab_reconstructed = string.format("%f, %f, %f, %s", L, a, b, alpha_str)
            return parse_color("oklab(" .. oklab_reconstructed .. ")")
        end
    end

    -- lab(L a b [/alpha]) -" CIELAB. Approximate via OKLab approximation (close enough
    -- for typical UI colors; full CIELAB needs XYZ→D65→sRGB conversions).
    -- Map lab's L:0..100 → oklab ≈ L/100; a,b have different ranges but naive pass works.
    local lab_fn = s:match("^lab%s*%((.+)%)$")
    if lab_fn then
        lab_fn = lab_fn:gsub("/", ",")
        local parts = {}
        for tok in lab_fn:gmatch("[^,%s]+") do parts[#parts+1] = tok end
        if #parts >= 3 then
            local L_pct = (tonumber(parts[1]:match("[%d%.%-]+")) or 0)
            if parts[1]:find("%%") then L_pct = L_pct else L_pct = L_pct end
            local L = L_pct / 100
            local a = (tonumber(parts[2]:match("[%d%.%-]+")) or 0) / 125 * 0.4
            local b = (tonumber(parts[3]:match("[%d%.%-]+")) or 0) / 125 * 0.4
            local alpha_str = parts[4] or "1"
            return parse_color(string.format("oklab(%f, %f, %f, %s)", L, a, b, alpha_str))
        end
    end

    -- lch(L C H) -" polar lab, approximated via oklch
    local lch_fn = s:match("^lch%s*%((.+)%)$")
    if lch_fn then
        lch_fn = lch_fn:gsub("/", ",")
        local parts = {}
        for tok in lch_fn:gmatch("[^,%s]+") do parts[#parts+1] = tok end
        if #parts >= 3 then
            local L_raw = tonumber(parts[1]:match("[%d%.%-]+")) or 0
            local C_raw = tonumber(parts[2]:match("[%d%.%-]+")) or 0
            local alpha_str = parts[4] or "1"
            return parse_color(string.format("oklch(%f%%, %f%%, %s, %s)",
                L_raw, C_raw / 150 * 100, parts[3], alpha_str))
        end
    end

    -- color-mix(in <space>, colorA [pct], colorB [pct])
    -- We mix in sRGB regardless of the requested colorspace for simplicity.
    local mix_fn = s:match("^color%-mix%s*%((.+)%)$")
    if mix_fn then
        -- Split on top-level commas (balanced parens)
        local parts, depth, start = {}, 0, 1
        for i = 1, #mix_fn do
            local c = mix_fn:sub(i, i)
            if c == "(" then depth = depth + 1
            elseif c == ")" then depth = depth - 1
            elseif c == "," and depth == 0 then
                parts[#parts+1] = mix_fn:sub(start, i-1):match("^%s*(.-)%s*$")
                start = i + 1
            end
        end
        parts[#parts+1] = mix_fn:sub(start):match("^%s*(.-)%s*$")

        -- parts[1] is "in srgb" / "in oklab" -" ignore colorspace, mix in sRGB
        if #parts >= 3 then
            local function parse_color_with_pct(str)
                local pct = str:match("(%d+%.?%d*)%%%s*$")
                local color_part = str
                if pct then
                    color_part = str:gsub("%s*%d+%.?%d*%%%s*$", ""):match("^%s*(.-)%s*$")
                end
                local c = parse_color(color_part)
                return c, pct and tonumber(pct) or nil
            end
            local cA, pA = parse_color_with_pct(parts[2])
            local cB, pB = parse_color_with_pct(parts[3])
            if cA and cB then
                local tA = pA or (pB and (100 - pB)) or 50
                local t = tA / 100
                return {
                    math_floor(cA[1] * t + cB[1] * (1 - t) + 0.5),
                    math_floor(cA[2] * t + cB[2] * (1 - t) + 0.5),
                    math_floor(cA[3] * t + cB[3] * (1 - t) + 0.5),
                    math_floor((cA[4] or 255) * t + (cB[4] or 255) * (1 - t) + 0.5),
                }
            end
        end
    end

    -- light-dark(light, dark): static parse returns both; caller picks based on scheme
    local ld_fn = s:match("^light%-dark%s*%((.+)%)$")
    if ld_fn then
        -- Split on top-level comma
        local depth, comma = 0, nil
        for i = 1, #ld_fn do
            local c = ld_fn:sub(i, i)
            if c == "(" then depth = depth + 1
            elseif c == ")" then depth = depth - 1
            elseif c == "," and depth == 0 then comma = i; break end
        end
        if comma then
            local light = ld_fn:sub(1, comma-1):match("^%s*(.-)%s*$")
            local dark  = ld_fn:sub(comma+1):match("^%s*(.-)%s*$")
            return {
                type = "light_dark",
                light = parse_color(light),
                dark  = parse_color(dark),
            }
        end
    end

    return nil
end

------------------------------------------------------------
-- Gradient CSS string parsing
-- Parses linear-gradient(...) and radial-gradient(...) into
-- structured tables for the paint system.
------------------------------------------------------------

--- Split a gradient argument string by top-level commas (respects nested parens).
---@param s string  the inner content of gradient(...)
---@return table    list of trimmed argument strings
local function split_gradient_args(s)
    local args = {}
    local depth = 0
    local start = 1
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "(" then depth = depth + 1
        elseif ch == ")" then depth = depth - 1
        elseif ch == "," and depth == 0 then
            local arg = s:sub(start, i - 1):match("^%s*(.-)%s*$")
            args[#args + 1] = arg
            start = i + 1
        end
    end
    local last = s:sub(start):match("^%s*(.-)%s*$")
    if last and last ~= "" then args[#args + 1] = last end
    return args
end

--- Parse a single color-stop argument like "red 20%" or "#fff" or "rgb(1,2,3) 50%".
--- Returns {position_or_nil, {r,g,b,a}} or nil.
---@param s string
---@return table|nil
local function parse_color_stop(s)
    if not s or s == "" then return nil end
    s = s:match("^%s*(.-)%s*$")

    -- Try to extract a trailing percentage or length after the color.
    -- We match from the end: the position is the last whitespace-separated token
    -- that looks like a number with optional % or px suffix.
    local color_part, pos_str
    local last_pos = s:match("%s([%d%.]+%%?)$") or s:match("%s([%d%.]+px)$")
    if last_pos then
        -- Strip the position from the end to get the color part
        color_part = s:sub(1, #s - #last_pos):match("^%s*(.-)%s*$")
        pos_str = last_pos
    else
        color_part = s
        pos_str = nil
    end

    local color = parse_color(color_part)
    if not color then
        -- Maybe the whole string is a color (no position)
        if pos_str then
            color = parse_color(s)
            if color then return { nil, color } end
        end
        return nil
    end

    local position = nil
    if pos_str then
        local pct = pos_str:match("^([%d%.]+)%%$")
        if pct then
            position = tonumber(pct) / 100
        else
            local px = pos_str:match("^([%d%.]+)px$") or pos_str:match("^([%d%.]+)$")
            if px then position = tonumber(px) end
        end
    end

    return { position, color }
end

--- Auto-distribute positions for stops that have nil positions.
---@param stops table  array of {position_or_nil, {r,g,b,a}}
---@return table       array of {position, {r,g,b,a}} with all positions filled
local function distribute_stop_positions(stops)
    if #stops == 0 then return stops end
    -- First stop defaults to 0, last to 1
    if not stops[1][1] then stops[1][1] = 0 end
    if not stops[#stops][1] then stops[#stops][1] = 1 end

    -- Fill gaps: find runs of nil positions and interpolate
    local i = 1
    while i <= #stops do
        if stops[i][1] == nil then
            -- Find the start of the nil run (previous known) and end
            local prev_idx = i - 1
            local next_idx = i + 1
            while next_idx <= #stops and stops[next_idx][1] == nil do
                next_idx = next_idx + 1
            end
            -- Interpolate between prev_idx and next_idx
            local p0 = stops[prev_idx][1]
            local p1 = stops[next_idx][1]
            local count = next_idx - prev_idx
            for j = prev_idx + 1, next_idx - 1 do
                stops[j][1] = p0 + (p1 - p0) * (j - prev_idx) / count
            end
            i = next_idx + 1
        else
            i = i + 1
        end
    end
    return stops
end

--- Parse linear-gradient(...) or repeating-linear-gradient(...) CSS string.
---@param s string  e.g. "linear-gradient(to right, red, blue 50%, green)"
---@return table|nil  {type="linear-gradient", angle=180, stops={{pos,{r,g,b,a}},...}, repeating=bool}
local function parse_linear_gradient(s)
    local repeating = false
    local inner = s:match("^linear%-gradient%s*%((.+)%)%s*$")
    if not inner then
        inner = s:match("^repeating%-linear%-gradient%s*%((.+)%)%s*$")
        if not inner then return nil end
        repeating = true
    end

    local args = split_gradient_args(inner)
    if #args == 0 then return nil end

    local angle = 180  -- default: to bottom
    local first_is_dir = false

    local first = args[1]:match("^%s*(.-)%s*$")
    -- Check for "to <direction>"
    if first:match("^to%s+") then
        first_is_dir = true
        local dir = first:match("^to%s+(.+)$")
        dir = dir:match("^%s*(.-)%s*$")
        if dir == "bottom" then angle = 180
        elseif dir == "top" then angle = 0
        elseif dir == "right" then angle = 90
        elseif dir == "left" then angle = 270
        elseif dir == "bottom right" or dir == "right bottom" then angle = 135
        elseif dir == "bottom left" or dir == "left bottom" then angle = 225
        elseif dir == "top right" or dir == "right top" then angle = 45
        elseif dir == "top left" or dir == "left top" then angle = 315
        end
    else
        -- Check for angle like "45deg" or "180deg"
        local deg = first:match("^([%d%.%-]+)deg$")
        if deg then
            angle = tonumber(deg) or 180
            first_is_dir = true
        end
    end

    local stops = {}
    local start_idx = first_is_dir and 2 or 1
    for i = start_idx, #args do
        local stop = parse_color_stop(args[i])
        if stop then
            stops[#stops + 1] = stop
        end
    end

    if #stops < 2 then return nil end
    stops = distribute_stop_positions(stops)

    return { type = "linear-gradient", angle = angle, stops = stops, repeating = repeating }
end

--- Parse a position string like "center", "left top", "50% 50%", "at center".
---@param pos_str string
---@return number, number  cx, cy as fractions 0-1
local function parse_gradient_position(pos_str)
    if not pos_str or pos_str == "" then return 0.5, 0.5 end
    pos_str = pos_str:match("^%s*(.-)%s*$")

    -- Strip leading "at " if present
    local stripped = pos_str:match("^at%s+(.+)$")
    if stripped then pos_str = stripped end

    local kw = {
        left = 0, center = 0.5, right = 1,
        top = 0, bottom = 1,
    }

    local parts = {}
    for tok in pos_str:gmatch("[^%s]+") do parts[#parts + 1] = tok end

    if #parts == 1 then
        local p1 = parts[1]
        -- Single vertical keyword → center-x, keyword-y
        if p1 == "top" then return 0.5, 0 end
        if p1 == "bottom" then return 0.5, 1 end
        local k = kw[p1]
        if k ~= nil then return k, 0.5 end
        local pct = parts[1]:match("^([%d%.]+)%%$")
        if pct then local v = tonumber(pct) / 100; return v, v end
        return 0.5, 0.5
    elseif #parts >= 2 then
        local cx, cy
        -- x component
        local kx = kw[parts[1]]
        if kx ~= nil then cx = kx
        else
            local pct = parts[1]:match("^([%d%.]+)%%$")
            cx = pct and tonumber(pct) / 100 or 0.5
        end
        -- y component
        local ky = kw[parts[2]]
        if ky ~= nil then cy = ky
        else
            local pct = parts[2]:match("^([%d%.]+)%%$")
            cy = pct and tonumber(pct) / 100 or 0.5
        end
        return cx, cy
    end

    return 0.5, 0.5
end

--- Parse radial-gradient(...) or repeating-radial-gradient(...) CSS string.
---@param s string  e.g. "radial-gradient(circle at center, red, blue)"
---@return table|nil  {type="radial-gradient", shape="circle"|"ellipse", cx, cy, size, stops={{pos,{r,g,b,a}},...}, repeating=bool}
local function parse_radial_gradient(s)
    local repeating = false
    local inner = s:match("^radial%-gradient%s*%((.+)%)%s*$")
    if not inner then
        inner = s:match("^repeating%-radial%-gradient%s*%((.+)%)%s*$")
        if not inner then return nil end
        repeating = true
    end

    local args = split_gradient_args(inner)
    if #args == 0 then return nil end

    local shape = "ellipse"  -- default
    local cx, cy = 0.5, 0.5
    local size_keyword = "farthest-corner"
    local first_is_config = false

    local first = args[1]:match("^%s*(.-)%s*$")

    -- Check if first arg is shape/size/position config (not a color stop)
    -- Heuristic: contains "circle", "ellipse", "at", or size keywords
    local has_shape_kw = first:match("circle") or first:match("ellipse")
    local has_at = first:match("%s+at%s+") or first:match("^at%s+")
    local has_size_kw = first:match("closest%-side") or first:match("farthest%-side")
        or first:match("closest%-corner") or first:match("farthest%-corner")

    if has_shape_kw or has_at or has_size_kw then
        first_is_config = true

        -- Extract shape
        if first:match("circle") then shape = "circle"
        elseif first:match("ellipse") then shape = "ellipse" end

        -- Extract size keyword
        if first:match("closest%-side") then size_keyword = "closest-side"
        elseif first:match("farthest%-side") then size_keyword = "farthest-side"
        elseif first:match("closest%-corner") then size_keyword = "closest-corner"
        elseif first:match("farthest%-corner") then size_keyword = "farthest-corner" end

        -- Extract position after "at"
        local pos_part = first:match("at%s+(.+)$")
        if pos_part then
            cx, cy = parse_gradient_position(pos_part)
        end
    else
        -- Check if first arg is a color stop (try parsing it)
        local test_stop = parse_color_stop(first)
        if not test_stop then
            -- Not a color, might be just a position like "at 30% 50%"
            if first:match("^at%s+") then
                first_is_config = true
                cx, cy = parse_gradient_position(first)
            end
        end
    end

    local stops = {}
    local start_idx = first_is_config and 2 or 1
    for i = start_idx, #args do
        local stop = parse_color_stop(args[i])
        if stop then
            stops[#stops + 1] = stop
        end
    end

    if #stops < 2 then return nil end
    stops = distribute_stop_positions(stops)

    return {
        type = "radial-gradient",
        shape = shape,
        cx = cx,
        cy = cy,
        size = size_keyword,
        center = { cx, cy },
        stops = stops,
        repeating = repeating,
    }
end

--- Parse conic-gradient(...) or repeating-conic-gradient(...) CSS string.
---@param s string  e.g. "conic-gradient(from 45deg at center, red, blue)"
---@return table|nil  {type="conic-gradient", from_angle=0, cx=0.5, cy=0.5, stops={{pos,{r,g,b,a}},...}, repeating=bool}
local function parse_conic_gradient(s)
    local repeating = false
    local inner = s:match("^conic%-gradient%s*%((.+)%)%s*$")
    if not inner then
        inner = s:match("^repeating%-conic%-gradient%s*%((.+)%)%s*$")
        if not inner then return nil end
        repeating = true
    end

    local args = split_gradient_args(inner)
    if #args == 0 then return nil end

    local from_angle = 0
    local cx, cy = 0.5, 0.5
    local first_is_config = false

    local first = args[1]:match("^%s*(.-)%s*$")

    -- Check if first arg contains "from" or "at" keywords (configuration, not a color stop)
    local has_from = first:match("^from%s+") or first:match("^from$")
    local has_at = first:match("%s+at%s+") or first:match("^at%s+")

    if has_from or has_at then
        first_is_config = true

        -- Extract "from <angle>"
        local angle_str = first:match("from%s+([%d%.%-]+)deg")
        if angle_str then
            from_angle = tonumber(angle_str) or 0
        else
            local angle_turn = first:match("from%s+([%d%.%-]+)turn")
            if angle_turn then
                from_angle = (tonumber(angle_turn) or 0) * 360
            else
                local angle_rad = first:match("from%s+([%d%.%-]+)rad")
                if angle_rad then
                    from_angle = (tonumber(angle_rad) or 0) * 180 / math.pi
                else
                    local angle_grad = first:match("from%s+([%d%.%-]+)grad")
                    if angle_grad then
                        from_angle = (tonumber(angle_grad) or 0) * 0.9
                    end
                end
            end
        end

        -- Extract position after "at"
        local pos_part = first:match("at%s+(.+)$")
        if pos_part then
            cx, cy = parse_gradient_position(pos_part)
        end
    else
        -- Check if first arg is a color stop (try parsing it)
        local test_stop = parse_color_stop(first)
        if not test_stop then
            -- Not a color, might be just "at 30% 50%"
            if first:match("^at%s+") then
                first_is_config = true
                cx, cy = parse_gradient_position(first)
            end
        end
    end

    -- Parse color stops: positions can be in degrees or percentages
    local stops = {}
    local start_idx = first_is_config and 2 or 1
    for i = start_idx, #args do
        local arg = args[i]:match("^%s*(.-)%s*$")
        if arg ~= "" then
            -- Try to extract a trailing angle (deg) or percentage for the stop position
            local color_part, pos_val
            -- Check for trailing "Ndeg"
            local c_part, deg_str = arg:match("^(.-)%s+([%d%.%-]+)deg%s*$")
            if deg_str then
                color_part = c_part
                pos_val = (tonumber(deg_str) or 0) / 360
            else
                -- Check for trailing percentage
                local c_part2, pct_str = arg:match("^(.-)%s+([%d%.]+)%%%s*$")
                if pct_str then
                    color_part = c_part2
                    pos_val = (tonumber(pct_str) or 0) / 100
                else
                    -- Check for trailing turn value
                    local c_part3, turn_str = arg:match("^(.-)%s+([%d%.%-]+)turn%s*$")
                    if turn_str then
                        color_part = c_part3
                        pos_val = tonumber(turn_str) or 0
                    else
                        color_part = arg
                        pos_val = nil
                    end
                end
            end

            local color = parse_color(color_part)
            if color then
                stops[#stops + 1] = { pos_val, color }
            else
                -- Fallback: try the whole string as color (no position)
                local stop = parse_color_stop(arg)
                if stop then
                    stops[#stops + 1] = stop
                end
            end
        end
    end

    if #stops < 2 then return nil end
    stops = distribute_stop_positions(stops)

    return {
        type = "conic-gradient",
        from_angle = from_angle,
        cx = cx,
        cy = cy,
        center = { cx, cy },
        stops = stops,
        repeating = repeating,
    }
end

------------------------------------------------------------
-- CSS transform string parser
-- Parses "rotate(45deg) scale(1.5)" into operation arrays:
--   {{type="rotate", deg=45}, {type="scale", x=1.5, y=1.5}}
-- Supports: translate, translateX, translateY, scale, scaleX,
--   scaleY, rotate, skew, skewX, skewY.
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local function parse_css_transform(str)
    if not str or str == "" or str == "none" then return nil end

    local ops = {}

    for fn, args in str:gmatch("(%a+)%s*%(([^%)]+)%)") do
        -- Strip "deg" / "px" units and parse numbers from args
        local nums = {}
        for tok in args:gmatch("[^,%s]+") do
            local n = tok:match("^([%-%.%d]+)deg$")
            if n then
                nums[#nums + 1] = tonumber(n) or 0
            else
                n = tok:match("^([%-%.%d]+)px$")
                if n then
                    nums[#nums + 1] = tonumber(n) or 0
                else
                    n = tok:match("^([%-%.%deE]+)$")
                    if n then
                        nums[#nums + 1] = tonumber(n) or 0
                    end
                end
            end
        end

        local op
        if fn == "translate" then
            op = { type = "translate", x = nums[1] or 0, y = nums[2] or 0 }
        elseif fn == "translateX" then
            op = { type = "translate", x = nums[1] or 0, y = 0 }
        elseif fn == "translateY" then
            op = { type = "translate", x = 0, y = nums[1] or 0 }
        elseif fn == "scale" then
            local sx = nums[1] or 1
            local sy = nums[2] or sx
            op = { type = "scale", x = sx, y = sy }
        elseif fn == "scaleX" then
            op = { type = "scale", x = nums[1] or 1, y = 1 }
        elseif fn == "scaleY" then
            op = { type = "scale", x = 1, y = nums[1] or 1 }
        elseif fn == "rotate" then
            op = { type = "rotate", deg = nums[1] or 0 }
        elseif fn == "skew" then
            op = { type = "skew", x = nums[1] or 0, y = nums[2] or 0 }
        elseif fn == "skewX" then
            op = { type = "skewX", deg = nums[1] or 0 }
        elseif fn == "skewY" then
            op = { type = "skewY", deg = nums[1] or 0 }
        end

        if op then
            ops[#ops + 1] = op
        end
    end

    if #ops == 0 then return nil end
    return ops
end

------------------------------------------------------------
-- Value parsing: CSS value string → Lua value
-- Handles: numbers, px, %, em, rem, auto, colors, calc(),
-- var(), strings, etc.
------------------------------------------------------------
local FONT_SIZE_KEYWORDS = {
    ["xx-small"]  = 9,
    ["x-small"]   = 10,
    ["small"]     = 13,
    ["medium"]    = 16,
    ["large"]     = 18,
    ["x-large"]   = 24,
    ["xx-large"]  = 32,
    ["xxx-large"] = 48,
}

local function normalize_font_family_value(value)
    local families = {}
    local token = {}
    local quote = nil
    for i = 1, #value do
        local ch = value:sub(i, i)
        if quote then
            token[#token + 1] = ch
            if ch == quote then quote = nil end
        elseif ch == '"' or ch == "'" then
            quote = ch
            token[#token + 1] = ch
        elseif ch == "," then
            families[#families + 1] = table.concat(token)
            token = {}
        else
            token[#token + 1] = ch
        end
    end
    families[#families + 1] = table.concat(token)

    local cleaned = {}
    for i = 1, #families do
        local family = families[i]:match("^%s*(.-)%s*$")
        local unquoted = family:match('^"(.*)"$') or family:match("^'(.*)'$")
        if unquoted then
            family = unquoted:gsub('\\"', '"'):gsub("\\'", "'")
        end
        if family ~= "" then cleaned[#cleaned + 1] = family end
    end
    return table.concat(cleaned, ", ")
end

local function parse_value(val_str, prop_name)
    if not val_str or val_str == "" then return nil end
    val_str = val_str:match("^%s*(.-)%s*$") -- trim

    -- Check !important (strip it, caller handles flag)
    local is_important = false
    local trimmed = val_str:match("^(.-)%s*!important%s*$")
    if trimmed then
        val_str = trimmed
        is_important = true
    end
    local val_lower = val_str:lower()

    -- "inherit", "initial", "unset"
    if val_lower == "inherit" or val_lower == "initial" or val_lower == "unset" then
        return val_lower, is_important
    end

    if prop_name == "font-weight" then
        local lw = val_str:lower()
        if lw == "normal" then return 400, is_important end
        if lw == "bold" then return 700, is_important end
        if lw == "bolder" then return 700, is_important end
        if lw == "lighter" then return 300, is_important end
        local numeric_weight = tonumber(lw)
        if numeric_weight then return numeric_weight, is_important end
    elseif prop_name == "font-size" then
        local lw = val_str:lower()
        local keyword_size = FONT_SIZE_KEYWORDS[lw]
        if keyword_size then return keyword_size, is_important end
        if lw == "larger" or lw == "smaller" then return lw, is_important end
    elseif prop_name == "font-family" then
        return normalize_font_family_value(val_str), is_important
    end

    -- "auto", "none", keyword values
    if val_lower == "auto" or val_lower == "none" then
        return val_lower, is_important
    end

    -- content: "literal" -" CSS string delimiters are syntax, not content.
    -- Strip surrounding quotes for ::before/::after text and similar
    -- string-valued properties (quotes).  Handles \" and \' escapes.
    if prop_name == "content" or prop_name == "quotes" then
        local inner = val_str:match('^"(.*)"$') or val_str:match("^'(.*)'$")
        if inner then
            inner = inner:gsub('\\"', '"'):gsub("\\'", "'")
            return inner, is_important
        end
    end

    -- var() references
    if val_str:find("^var%(") then
        local var_name = val_str:match("^var%(([^,%)]+)")
        local fallback = val_str:match("^var%([^,]+,%s*(.+)%)")
        if var_name then
            var_name = var_name:match("^%s*(.-)%s*$")
            return { type = "var", name = var_name, fallback = fallback }, is_important
        end
    end

    -- CSS transform property: parse "rotate(45deg) scale(1.5)" etc.
    if prop_name == "transform" then
        local ops = parse_css_transform(val_str)
        if ops then return ops, is_important end
        -- Fall through for keyword values like strings
    end

    -- grid-template-areas: '"head head" "nav main"' or single-quoted
    -- '"'head head' 'nav main''' → 2D rows of names. CSS allows either
    -- quote style and the compiler currently emits single quotes; the
    -- previous double-quote-only match silently produced an empty `rows`
    -- table, so grid layout fell through to auto-flow and named-area
    -- references collapsed to single-cell placement.
    if prop_name == "grid-template-areas" then
        local rows = {}
        for row in val_str:gmatch('"([^"]*)"') do
            local cells = {}
            for cell in row:gmatch("%S+") do
                cells[#cells + 1] = cell
            end
            rows[#rows + 1] = cells
        end
        if #rows == 0 then
            for row in val_str:gmatch("'([^']*)'") do
                local cells = {}
                for cell in row:gmatch("%S+") do
                    cells[#cells + 1] = cell
                end
                rows[#rows + 1] = cells
            end
        end
        if #rows > 0 then
            return { type = "grid_template_areas", rows = rows }, is_important
        end
    end

    -- scrollbar-color: <thumb-color> <track-color>
    if prop_name == "scrollbar-color" then
        if val_str == "auto" then return "auto", is_important end
        -- Split into two top-level color tokens (balanced parens)
        local tokens = {}
        local depth = 0
        local start = 1
        for i = 1, #val_str do
            local c = val_str:sub(i, i)
            if c == "(" then depth = depth + 1
            elseif c == ")" then depth = depth - 1
            elseif c == " " and depth == 0 then
                local t = val_str:sub(start, i - 1):match("^%s*(.-)%s*$")
                if t ~= "" then tokens[#tokens + 1] = t end
                start = i + 1
            end
        end
        local last = val_str:sub(start):match("^%s*(.-)%s*$")
        if last ~= "" then tokens[#tokens + 1] = last end
        if #tokens >= 2 then
            local thumb = parse_color(tokens[1])
            local track = parse_color(tokens[2])
            if thumb and track then
                return { type = "scrollbar_color", thumb = thumb, track = track }, is_important
            end
        end
    end

    -- list-style-image: url(...) -" marker image for list items
    if prop_name == "list-style-image" then
        if val_str == "none" then
            return "none", is_important
        end
        local u = val_str:match('^url%(%s*"([^"]*)"%s*%)%s*$')
                or val_str:match("^url%(%s*'([^']*)'%s*%)%s*$")
                or val_str:match("^url%(%s*([^%)]-)%s*%)%s*$")
        if u then
            return { type = "list_style_image", url = u }, is_important
        end
    end

    -- mask-image: url(...) or gradient -" parse into structured value.
    -- Painters currently implement url() masks for <img> only; gradient
    -- masks fall back to normal paint with a warning.
    if prop_name == "mask-image" then
        if val_str == "none" then
            return "none", is_important
        end
        local u = val_str:match('^url%(%s*"([^"]*)"%s*%)%s*$')
                or val_str:match("^url%(%s*'([^']*)'%s*%)%s*$")
                or val_str:match("^url%(%s*([^%)]-)%s*%)%s*$")
        if u then
            return { type = "mask_image", url = u }, is_important
        end
        -- Fall through to gradient handling below (produces gradient obj)
    end

    -- background-image: url(...)
    if prop_name == "background-image" then
        if val_str == "none" then
            return "none", is_important
        end
        local u = val_str:match('^url%(%s*"([^"]*)"%s*%)%s*$')
                or val_str:match("^url%(%s*'([^']*)'%s*%)%s*$")
                or val_str:match("^url%(%s*([^%)]-)%s*%)%s*$")
        if u then
            return { type = "url", url = u }, is_important
        end
    end

    -- grid-area: "name" | "row-start / col-start / row-end / col-end"
    if prop_name == "grid-area" then
        local parts = {}
        for p in val_str:gmatch("[^/]+") do
            parts[#parts + 1] = p:match("^%s*(.-)%s*$")
        end
        if #parts == 1 and not parts[1]:find("^%d+$") then
            -- Named area reference: resolved at layout time via parent's template
            return { type = "grid_area", name = parts[1] }, is_important
        elseif #parts >= 2 then
            -- Numeric shorthand
            return {
                type = "grid_area",
                row_start = tonumber(parts[1]),
                col_start = tonumber(parts[2]),
                row_end   = tonumber(parts[3]),
                col_end   = tonumber(parts[4]),
            }, is_important
        end
    end

    -- calc() expressions
    if val_lower:find("^calc%(") or val_lower:find("^min%(") or val_lower:find("^max%(") or val_lower:find("^clamp%(") then
        local ok, ast = pcall(CalcParser.parse, val_str)
        if ok and ast then
            return ast, is_important
        end
    end

    -- Gradient functions (including repeating- variants)
    -- Gradient functions (including multiple comma-separated backgrounds)
    if val_str:find("gradient%(") then
        -- Single-pass: split at top-level commas to detect multi-background
        local layers
        local depth_g = 0
        local start_g = 1
        local len_g = #val_str
        for i = 1, len_g do
            local ch = val_str:sub(i, i)
            if ch == "(" then depth_g = depth_g + 1
            elseif ch == ")" then depth_g = depth_g - 1
            elseif ch == "," and depth_g == 0 then
                if not layers then layers = {} end
                local seg = val_str:sub(start_g, i - 1):match("^%s*(.-)%s*$")
                if seg and seg ~= "" then layers[#layers + 1] = seg end
                start_g = i + 1
            end
        end

        -- Fast path: no top-level comma → single background
        if not layers then
            local g
            if val_str:find("^linear%-gradient%(") or val_str:find("^repeating%-linear%-gradient%(") then
                g = parse_linear_gradient(val_str)
            elseif val_str:find("^radial%-gradient%(") or val_str:find("^repeating%-radial%-gradient%(") then
                g = parse_radial_gradient(val_str)
            elseif val_str:find("^conic%-gradient%(") or val_str:find("^repeating%-conic%-gradient%(") then
                g = parse_conic_gradient(val_str)
            end
            if g then return g, is_important end
        else
            -- Collect last segment
            local last = val_str:sub(start_g):match("^%s*(.-)%s*$")
            if last and last ~= "" then layers[#layers + 1] = last end

            -- Parse each layer
            local parsed = {}
            for li = 1, #layers do
                local seg = layers[li]
                local g
                local byte1 = seg:byte(1)
                if byte1 == 108 then  -- 'l'
                    if seg:find("^linear%-gradient%(") then
                        g = parse_linear_gradient(seg)
                    end
                elseif byte1 == 114 then  -- 'r' (radial, repeating-*)
                    if seg:find("^radial%-gradient%(") then
                        g = parse_radial_gradient(seg)
                    elseif seg:find("^repeating%-linear%-gradient%(") then
                        g = parse_linear_gradient(seg)
                    elseif seg:find("^repeating%-radial%-gradient%(") then
                        g = parse_radial_gradient(seg)
                    elseif seg:find("^repeating%-conic%-gradient%(") then
                        g = parse_conic_gradient(seg)
                    end
                elseif byte1 == 99 then  -- 'c'
                    if seg:find("^conic%-gradient%(") then
                        g = parse_conic_gradient(seg)
                    end
                elseif byte1 == 117 then  -- 'u'
                    if seg:find("^url%(") then
                        local url = seg:match("^url%(%s*[\"']?(.-)[\"']?%s*%)$")
                        if url then g = { type = "url", url = url } end
                    end
                end
                if g then parsed[#parsed + 1] = g end
            end
            if #parsed > 1 then
                return parsed, is_important
            elseif #parsed == 1 then
                return parsed[1], is_important
            end
        end
    end

    -- Color properties: try color parse first for color-like properties
    local is_color_prop = prop_name and (
        prop_name:find("color") or prop_name == "background-color" or
        prop_name == "background" or prop_name == "outline-color" or
        prop_name == "column-rule-color"
    )
    if is_color_prop then
        local c = parse_color(val_str)
        if c then return { type = "color", v = c }, is_important end
    end

    -- Numbers with units
    local num, unit = val_lower:match("^([%d%.%-]+)(px)$")
    if num then return tonumber(num), is_important end

    num, unit = val_lower:match("^([%d%.%-]+)(%%)")
    if num then return val_str, is_important end -- keep as string "50%"

    num, unit = val_lower:match("^([%d%.%-]+)(em)$")
    if num then return val_str, is_important end

    num, unit = val_lower:match("^([%d%.%-]+)(rem)$")
    if num then return val_str, is_important end

    num, unit = val_lower:match("^([%d%.%-]+)(vh)$")
    if num then return val_str, is_important end

    num, unit = val_lower:match("^([%d%.%-]+)(vw)$")
    if num then return val_str, is_important end

    -- Plain number
    local plain_num = tonumber(val_str)
    if plain_num then return plain_num, is_important end

    -- Try color for any value (might be hex/rgb/named)
    local c = parse_color(val_str)
    if c then return { type = "color", v = c }, is_important end

    if CSS_KEYWORD_VALUES[val_lower] then
        return val_lower, is_important
    end

    -- String keyword fallback
    return val_str, is_important
end

------------------------------------------------------------
-- Shorthand expansion
-- Expands CSS shorthands into individual longhand declarations
------------------------------------------------------------
local function expand_shorthands(prop_name, value_str)
    local results = {}
    local value_lower = value_str:lower()

    local function expand_logical_border_longhand(prefix, suffix, value)
        if prefix == "border-inline" then
            return {
                { "border-left-" .. suffix, value },
                { "border-right-" .. suffix, value },
            }
        elseif prefix == "border-block" then
            return {
                { "border-top-" .. suffix, value },
                { "border-bottom-" .. suffix, value },
            }
        elseif prefix == "border-inline-start" then
            return { { "border-left-" .. suffix, value } }
        elseif prefix == "border-inline-end" then
            return { { "border-right-" .. suffix, value } }
        elseif prefix == "border-block-start" then
            return { { "border-top-" .. suffix, value } }
        elseif prefix == "border-block-end" then
            return { { "border-bottom-" .. suffix, value } }
        end
        return {}
    end

    local function expand_logical_border(prefix, value)
        local out = {}
        local parts = {}
        for tok in value:gmatch("[^%s]+") do parts[#parts + 1] = tok end
        for i = 1, #parts do
            local p = parts[i]
            local pl = p:lower()
            local num = pl:match("^([%d%.]+)px$") or pl:match("^(%d[%d%.]*)$")
            local suffix
            if num then
                suffix = "width"
            elseif pl == "solid" or pl == "dashed" or pl == "dotted" or pl == "double"
                or pl == "groove" or pl == "ridge" or pl == "inset" or pl == "outset"
                or pl == "none" or pl == "hidden" then
                suffix = "style"
            else
                suffix = "color"
            end
            local expanded = expand_logical_border_longhand(prefix, suffix, suffix == "style" and pl or p)
            for j = 1, #expanded do out[#out + 1] = expanded[j] end
        end
        return out
    end

    -- Direct logical -> physical mapping (single-value properties)
    local phys = LOGICAL_MAP[prop_name]
    if phys then
        return { { phys, value_str } }
    end

    -- Logical shorthands (two-value)
    if prop_name == "margin-inline" then
        local a, b = split_two_values(value_str)
        return { { "margin-left", a }, { "margin-right", b or a } }
    elseif prop_name == "margin-block" then
        local a, b = split_two_values(value_str)
        return { { "margin-top", a }, { "margin-bottom", b or a } }
    elseif prop_name == "padding-inline" then
        local a, b = split_two_values(value_str)
        return { { "padding-left", a }, { "padding-right", b or a } }
    elseif prop_name == "padding-block" then
        local a, b = split_two_values(value_str)
        return { { "padding-top", a }, { "padding-bottom", b or a } }
    elseif prop_name == "inset-inline" then
        local a, b = split_two_values(value_str)
        return { { "left", a }, { "right", b or a } }
    elseif prop_name == "inset-block" then
        local a, b = split_two_values(value_str)
        return { { "top", a }, { "bottom", b or a } }
    elseif prop_name == "inset" then
        -- inset is shorthand for top/right/bottom/left (like margin)
        local parts = {}
        for tok in value_str:gmatch("[^%s]+") do parts[#parts+1] = tok end
        local t, r, b, l
        if #parts == 1 then
            t = parts[1]; r = parts[1]; b = parts[1]; l = parts[1]
        elseif #parts == 2 then
            t = parts[1]; r = parts[2]; b = parts[1]; l = parts[2]
        elseif #parts == 3 then
            t = parts[1]; r = parts[2]; b = parts[3]; l = parts[2]
        else
            t = parts[1]; r = parts[2]; b = parts[3]; l = parts[4]
        end
        return { { "top", t }, { "right", r }, { "bottom", b }, { "left", l } }
    elseif prop_name == "border-inline-width" then
        return expand_logical_border_longhand("border-inline", "width", value_str)
    elseif prop_name == "border-block-width" then
        return expand_logical_border_longhand("border-block", "width", value_str)
    elseif prop_name == "border-inline-color" then
        return expand_logical_border_longhand("border-inline", "color", value_str)
    elseif prop_name == "border-block-color" then
        return expand_logical_border_longhand("border-block", "color", value_str)
    elseif prop_name == "border-inline-style" then
        return expand_logical_border_longhand("border-inline", "style", value_str)
    elseif prop_name == "border-block-style" then
        return expand_logical_border_longhand("border-block", "style", value_str)
    elseif prop_name == "border-inline" then
        return expand_logical_border("border-inline", value_str)
    elseif prop_name == "border-block" then
        return expand_logical_border("border-block", value_str)
    elseif prop_name == "border-inline-start" then
        return expand_logical_border("border-inline-start", value_str)
    elseif prop_name == "border-inline-end" then
        return expand_logical_border("border-inline-end", value_str)
    elseif prop_name == "border-block-start" then
        return expand_logical_border("border-block-start", value_str)
    elseif prop_name == "border-block-end" then
        return expand_logical_border("border-block-end", value_str)
    end

    -- padding: <all> | <v> <h> | <t> <r> <b> <l>
    if prop_name == "padding" or prop_name == "margin" then
        local prefix = prop_name
        local parts = split_css_value_tokens(value_str)
        if #parts == 1 then
            results[#results+1] = {prefix.."-top", parts[1]}
            results[#results+1] = {prefix.."-right", parts[1]}
            results[#results+1] = {prefix.."-bottom", parts[1]}
            results[#results+1] = {prefix.."-left", parts[1]}
        elseif #parts == 2 then
            results[#results+1] = {prefix.."-top", parts[1]}
            results[#results+1] = {prefix.."-right", parts[2]}
            results[#results+1] = {prefix.."-bottom", parts[1]}
            results[#results+1] = {prefix.."-left", parts[2]}
        elseif #parts == 3 then
            results[#results+1] = {prefix.."-top", parts[1]}
            results[#results+1] = {prefix.."-right", parts[2]}
            results[#results+1] = {prefix.."-bottom", parts[3]}
            results[#results+1] = {prefix.."-left", parts[2]}
        elseif #parts >= 4 then
            results[#results+1] = {prefix.."-top", parts[1]}
            results[#results+1] = {prefix.."-right", parts[2]}
            results[#results+1] = {prefix.."-bottom", parts[3]}
            results[#results+1] = {prefix.."-left", parts[4]}
        end
        return results
    end

    -- border: <width> <style> <color>
    if prop_name == "border" then
        local parts = split_css_value_tokens(value_str)
        for i = 1, #parts do
            local p = parts[i]
            local pl = p:lower()
            local num = pl:match("^([%d%.]+)px$") or pl:match("^(%d[%d%.]*)$")
            if num then
                results[#results+1] = {"border-width", p}
            elseif pl == "solid" or pl == "dashed" or pl == "dotted" or pl == "double"
                or pl == "groove" or pl == "ridge" or pl == "inset" or pl == "outset"
                or pl == "none" or pl == "hidden" then
                results[#results+1] = {"border-style", pl}
            else
                results[#results+1] = {"border-color", p}
            end
        end
        return results
    end

    -- border-radius: <all> | <tl-br> <tr-bl> | <tl> <tr> <br> <bl>
    if prop_name == "border-radius" then
        local slash_at = nil
        local raw_parts = split_css_value_tokens(value_str)
        for i = 1, #raw_parts do
            if raw_parts[i] == "/" then slash_at = i; break end
        end
        local parts = {}
        local limit = slash_at and (slash_at - 1) or #raw_parts
        for i = 1, limit do parts[#parts + 1] = raw_parts[i] end
        if #parts == 1 then
            results[#results+1] = {"border-top-left-radius", parts[1]}
            results[#results+1] = {"border-top-right-radius", parts[1]}
            results[#results+1] = {"border-bottom-right-radius", parts[1]}
            results[#results+1] = {"border-bottom-left-radius", parts[1]}
        elseif #parts == 2 then
            results[#results+1] = {"border-top-left-radius", parts[1]}
            results[#results+1] = {"border-top-right-radius", parts[2]}
            results[#results+1] = {"border-bottom-right-radius", parts[1]}
            results[#results+1] = {"border-bottom-left-radius", parts[2]}
        elseif #parts == 3 then
            results[#results+1] = {"border-top-left-radius", parts[1]}
            results[#results+1] = {"border-top-right-radius", parts[2]}
            results[#results+1] = {"border-bottom-right-radius", parts[3]}
            results[#results+1] = {"border-bottom-left-radius", parts[2]}
        elseif #parts >= 4 then
            results[#results+1] = {"border-top-left-radius", parts[1]}
            results[#results+1] = {"border-top-right-radius", parts[2]}
            results[#results+1] = {"border-bottom-right-radius", parts[3]}
            results[#results+1] = {"border-bottom-left-radius", parts[4]}
        end
        return results
    end

    -- gap: <row> <col> or <both>
    if prop_name == "gap" then
        local parts = split_css_value_tokens(value_str)
        if #parts == 1 then
            results[#results+1] = {"row-gap", parts[1]}
            results[#results+1] = {"column-gap", parts[1]}
        elseif #parts >= 2 then
            results[#results+1] = {"row-gap", parts[1]}
            results[#results+1] = {"column-gap", parts[2]}
        end
        return results
    end

    -- overflow: <x> <y> or <both>
    if prop_name == "overflow" then
        local parts = split_css_value_tokens(value_str)
        if #parts == 1 then
            results[#results+1] = {"overflow-x", parts[1]}
            results[#results+1] = {"overflow-y", parts[1]}
        elseif #parts >= 2 then
            results[#results+1] = {"overflow-x", parts[1]}
            results[#results+1] = {"overflow-y", parts[2]}
        end
        return results
    end

    -- flex: <grow> [<shrink>] [<basis>]
    if prop_name == "flex" then
        if value_lower == "none" then
            results[#results+1] = {"flex-grow", "0"}
            results[#results+1] = {"flex-shrink", "0"}
            results[#results+1] = {"flex-basis", "auto"}
        elseif value_lower == "auto" then
            results[#results+1] = {"flex-grow", "1"}
            results[#results+1] = {"flex-shrink", "1"}
            results[#results+1] = {"flex-basis", "auto"}
        else
            local parts = split_css_value_tokens(value_str)
            if parts[1] then results[#results+1] = {"flex-grow", parts[1]} end
            if #parts == 2 and not tonumber(parts[2]) then
                results[#results+1] = {"flex-shrink", "1"}
                results[#results+1] = {"flex-basis", parts[2]}
            else
                if parts[2] then results[#results+1] = {"flex-shrink", parts[2]}
                else results[#results+1] = {"flex-shrink", "1"} end
                if parts[3] then results[#results+1] = {"flex-basis", parts[3]}
                else results[#results+1] = {"flex-basis", "0"} end
            end
        end
        return results
    end

    -- list-style: <type> | <position> | <image> | none (any order)
    if prop_name == "list-style" then
        if value_lower == "none" then
            results[#results+1] = {"list-style-type",     "none"}
            results[#results+1] = {"list-style-image",    "none"}
            return results
        end
        if value_lower == "inherit" or value_lower == "initial" or value_lower == "unset" then
            results[#results+1] = {"list-style-type",     value_lower}
            results[#results+1] = {"list-style-position", value_lower}
            results[#results+1] = {"list-style-image",    value_lower}
            return results
        end
        local positions = { inside = true, outside = true }
        local types = { disc=true, circle=true, square=true, decimal=true,
            ["decimal-leading-zero"]=true, ["lower-roman"]=true, ["upper-roman"]=true,
            ["lower-alpha"]=true, ["upper-alpha"]=true, ["lower-latin"]=true,
            ["upper-latin"]=true, ["lower-greek"]=true, armenian=true, georgian=true,
            hebrew=true, ["cjk-decimal"]=true, ["arabic-indic"]=true, none=true }
        local saw_type, saw_pos, saw_img = false, false, false
        for tok in value_str:gmatch("[^%s]+") do
            local tl = tok:lower()
            if positions[tl] and not saw_pos then
                results[#results+1] = {"list-style-position", tl}
                saw_pos = true
            elseif (tl:find("^url%(") or tl:find("^var%(") or tl == "none") and not saw_img then
                if tl ~= "none" or saw_type then
                    results[#results+1] = {"list-style-image", tok}
                    saw_img = true
                else
                    results[#results+1] = {"list-style-type", "none"}
                    saw_type = true
                end
            elseif types[tl] and not saw_type then
                results[#results+1] = {"list-style-type", tl}
                saw_type = true
            end
        end
        return results
    end

    -- background: color image position/size repeat attachment origin clip
    if prop_name == "background" then
        local layers = split_top_level_commas(value_str)
        if #layers > 1 then
            local images = {}
            local last = {}
            for li = 1, #layers do
                local expanded = expand_shorthands("background", layers[li])
                for ei = 1, #expanded do
                    local ep, ev = expanded[ei][1], expanded[ei][2]
                    if ep == "background-image" then
                        images[#images + 1] = ev
                    else
                        last[ep] = ev
                    end
                end
            end
            if #images > 0 then
                results[#results + 1] = { "background-image", table.concat(images, ", ") }
            end
            for k, v in pairs(last) do
                results[#results + 1] = { k, v }
            end
            return results
        end
        local tokens = split_css_value_tokens(value_str)
        local position = {}
        local size = {}
        local in_size = false
        local boxes = {}
        local repeats = {}

        for i = 1, #tokens do
            local p = tokens[i]
            local pl = p:lower()
            if p == "/" then
                in_size = true
            elseif p:find("/", 1, true) and not pl:find("^url%(") and not pl:find("gradient%(") then
                local before, after = p:match("^(.-)/(.*)$")
                if before and before ~= "" then position[#position + 1] = before end
                if after and after ~= "" then size[#size + 1] = after end
                in_size = true
            elseif pl:find("^url%(") or pl:find("gradient%(") then
                results[#results+1] = {"background-image", p}
            elseif pl:find("^var%(") or pl:find("^env%(") then
                -- var()/env() can resolve to either a color or an image
                -- (url, gradient). Emit the same reference to BOTH longhand
                -- slots; the style engine post-filters by type after the
                -- var() resolves, so only the correct slot survives. See
                -- SE:_resolve_var_declaration in core/style/style_engine.lua.
                results[#results+1] = {"background-color", p}
                results[#results+1] = {"background-image", p}
            elseif parse_color(p) then
                results[#results+1] = {"background-color", p}
            elseif pl == "fixed" or pl == "scroll" or pl == "local" then
                results[#results+1] = {"background-attachment", pl}
            elseif pl == "repeat-x" then
                repeats[#repeats + 1] = "repeat"
                repeats[#repeats + 1] = "no-repeat"
            elseif pl == "repeat-y" then
                repeats[#repeats + 1] = "no-repeat"
                repeats[#repeats + 1] = "repeat"
            elseif pl == "repeat" or pl == "no-repeat" or pl == "space" or pl == "round" then
                repeats[#repeats + 1] = pl
            elseif pl == "border-box" or pl == "padding-box" or pl == "content-box" then
                boxes[#boxes + 1] = pl
            elseif in_size then
                size[#size + 1] = p
            else
                position[#position + 1] = p
            end
        end

        if #position > 0 then
            results[#results+1] = {"background-position", table.concat(position, " ")}
        end
        if #size > 0 then
            results[#results+1] = {"background-size", table.concat(size, " ")}
        end
        if #repeats > 0 then
            results[#results+1] = {"background-repeat", table.concat(repeats, " ")}
        end
        if #boxes == 1 then
            results[#results+1] = {"background-origin", boxes[1]}
            results[#results+1] = {"background-clip", boxes[1]}
        elseif #boxes >= 2 then
            results[#results+1] = {"background-origin", boxes[1]}
            results[#results+1] = {"background-clip", boxes[2]}
        end
        return results
    end

    -- outline: <width> <style> <color>
    if prop_name == "outline" then
        local parts = {}
        for tok in value_str:gmatch("[^%s]+") do parts[#parts+1] = tok end
        for i = 1, #parts do
            local p = parts[i]
            local pl = p:lower()
            local num = pl:match("^([%d%.]+)px$") or pl:match("^(%d[%d%.]*)$")
            if num then
                results[#results+1] = {"outline-width", p}
            elseif pl == "solid" or pl == "dashed" or pl == "dotted" or pl == "double" or pl == "none" then
                results[#results+1] = {"outline-style", pl}
            else
                results[#results+1] = {"outline-color", p}
            end
        end
        return results
    end

    -- font: [style] [weight] size[/line-height] family[, family2, ...]
    if prop_name == "font" then
        -- Handle size/line-height: "16px/1.5" → split on "/"
        -- Handle quoted families: "Open Sans", serif → preserve quotes
        local rest = value_str
        -- Extract font-style
        local style_match = rest:match("^%s*(italic)%s") or rest:match("^%s*(oblique)%s")
        if style_match then
            results[#results+1] = {"font-style", style_match}
            rest = rest:gsub("^%s*" .. style_match .. "%s*", "", 1)
        end
        -- Extract font-weight
        local weight_match = rest:match("^%s*(bold)%s") or rest:match("^%s*(%d%d%d)%s")
        if weight_match then
            if weight_match == "bold" then weight_match = "700" end
            results[#results+1] = {"font-weight", weight_match}
            rest = rest:gsub("^%s*%S+%s*", "", 1)
        end
        -- Extract size (with optional /line-height)
        local size_lh = rest:match("^%s*([%d%.]+[%a%%]*/?[%d%.]*[%a%%]*)")
        if size_lh then
            local sz, lh = size_lh:match("^([^/]+)/?(.*)$")
            if sz and sz ~= "" then
                results[#results+1] = {"font-size", sz}
            end
            if lh and lh ~= "" then
                results[#results+1] = {"line-height", lh}
            end
            rest = rest:sub(#size_lh + 1):match("^%s*(.-)%s*$")
        end
        -- Rest is font-family (may include commas and quotes)
        if rest and rest ~= "" then
            -- Clean up quotes for family name
            rest = rest:gsub('^%s*', ''):gsub('%s*$', '')
            results[#results+1] = {"font-family", rest}
        end
        return results
    end

    -- overscroll-behavior: <x> [<y>]
    if prop_name == "overscroll-behavior" then
        local a, b = value_str:match("^(%S+)%s*(%S*)$")
        if not b or b == "" then b = a end
        return { { "overscroll-behavior-x", a }, { "overscroll-behavior-y", b } }
    end

    -- place-items: <align-items> [<justify-items>]
    if prop_name == "place-items" then
        local a, b = value_str:match("^(%S+)%s*(%S*)$")
        if not b or b == "" then b = a end
        return { { "align-items", a }, { "justify-items", b } }
    end

    -- place-content: <align-content> [<justify-content>]
    if prop_name == "place-content" then
        local a, b = value_str:match("^(%S+)%s*(%S*)$")
        if not b or b == "" then b = a end
        return { { "align-content", a }, { "justify-content", b } }
    end

    -- place-self: <align-self> [<justify-self>]
    if prop_name == "place-self" then
        local a, b = value_str:match("^(%S+)%s*(%S*)$")
        if not b or b == "" then b = a end
        return { { "align-self", a }, { "justify-self", b } }
    end

    -- scroll-padding: TRBL shorthand (like margin/padding)
    if prop_name == "scroll-padding" then
        local parts = {}
        for tok in value_str:gmatch("[^%s]+") do parts[#parts+1] = tok end
        local t, r, bo, l
        if #parts == 1 then
            t = parts[1]; r = parts[1]; bo = parts[1]; l = parts[1]
        elseif #parts == 2 then
            t = parts[1]; r = parts[2]; bo = parts[1]; l = parts[2]
        elseif #parts == 3 then
            t = parts[1]; r = parts[2]; bo = parts[3]; l = parts[2]
        else
            t = parts[1]; r = parts[2]; bo = parts[3]; l = parts[4]
        end
        return {
            { "scroll-padding-top", t }, { "scroll-padding-right", r },
            { "scroll-padding-bottom", bo }, { "scroll-padding-left", l },
        }
    end

    -- scroll-margin: TRBL shorthand (like margin/padding)
    if prop_name == "scroll-margin" then
        local parts = {}
        for tok in value_str:gmatch("[^%s]+") do parts[#parts+1] = tok end
        local t, r, bo, l
        if #parts == 1 then
            t = parts[1]; r = parts[1]; bo = parts[1]; l = parts[1]
        elseif #parts == 2 then
            t = parts[1]; r = parts[2]; bo = parts[1]; l = parts[2]
        elseif #parts == 3 then
            t = parts[1]; r = parts[2]; bo = parts[3]; l = parts[2]
        else
            t = parts[1]; r = parts[2]; bo = parts[3]; l = parts[4]
        end
        return {
            { "scroll-margin-top", t }, { "scroll-margin-right", r },
            { "scroll-margin-bottom", bo }, { "scroll-margin-left", l },
        }
    end

    return nil -- not a shorthand
end

------------------------------------------------------------
-- @supports condition evaluator
-- Checks if CSS properties are known to the engine.
------------------------------------------------------------

--- Known CSS keyword values for @supports validation (hoisted for reuse)
local SUPPORTS_KEYWORDS = {
    inherit=1, initial=1, unset=1, revert=1, none=1, auto=1, normal=1,
    block=1, inline=1, flex=1, grid=1, table=1, ["inline-block"]=1,
    ["inline-flex"]=1, ["inline-grid"]=1, contents=1,
    hidden=1, visible=1, scroll=1, collapse=1, clip=1,
    absolute=1, relative=1, fixed=1, sticky=1, static=1,
    row=1, column=1, wrap=1, nowrap=1, ["row-reverse"]=1, ["column-reverse"]=1,
    ["wrap-reverse"]=1, center=1, start=1, ["end"]=1, stretch=1,
    ["flex-start"]=1, ["flex-end"]=1, ["space-between"]=1, ["space-around"]=1,
    ["space-evenly"]=1, baseline=1, bold=1, italic=1, underline=1,
    solid=1, dashed=1, dotted=1, double=1, groove=1, ridge=1, inset=1, outset=1,
    left=1, right=1, top=1, bottom=1, both=1,
    pointer=1, text=1, ["border-box"]=1, ["padding-box"]=1, ["content-box"]=1,
    cover=1, contain=1, ["no-repeat"]=1, ["repeat"]=1,
}

--- Known CSS units for @supports numeric value validation
local SUPPORTS_UNITS = {
    px=1, em=1, rem=1, vh=1, vw=1, vmin=1, vmax=1,
    pt=1, pc=1, cm=1, mm=1, ["in"]=1, ch=1, ex=1,
    fr=1, deg=1, rad=1, grad=1, turn=1,
    s=1, ms=1, hz=1, khz=1, dpi=1, dpcm=1, dppx=1,
}

--- Evaluate a single @supports condition like "(property: value)"
--- Returns true if the property is recognized and the value looks valid.
local function eval_supports_single(cond)
    -- Extract property and value from "(property: value)"
    local prop, val = cond:match("^%s*%((.-):%s*(.-)%)%s*$")
    if not prop then return false end
    prop = prop:match("^%s*(.-)%s*$"):lower()
    if not PROP[prop] then return false end
    -- Value must be non-empty
    val = val and val:match("^%s*(.-)%s*$") or ""
    if val == "" then return false end
    local val_lower = val:lower()
    -- Color properties: validate with parse_color
    if prop:find("color") then
        return parse_color(val) ~= nil
    end
    -- Unitless number (e.g. "0", "1.5", "-2")
    if val:match("^%-?%d*%.?%d+$") then
        return true
    end
    -- Number + percent (e.g. "50%")
    if val:match("^%-?%d*%.?%d+%%$") then
        return true
    end
    -- Number + unit (e.g. "10px", ".5em", "-2rem") -" unit must be known
    local unit = val_lower:match("^%-?%d*%.?%d+([a-z]+)$")
    if unit and SUPPORTS_UNITS[unit] then
        return true
    end
    -- Known CSS keywords
    if SUPPORTS_KEYWORDS[val_lower] then return true end
    -- Function-like values (e.g. "rgb(...)", "calc(...)", "url(...)")
    if val_lower:match("^[a-z%-]+%(") then return true end
    -- Unknown value for known property -" not supported
    return false
end

--- Evaluate a @supports condition string.
--- Supports: (prop: val), not (prop: val), and/or combinations.
local function eval_supports_condition(cond_str)
    if not cond_str or cond_str == "" then return false end
    cond_str = cond_str:match("^%s*(.-)%s*$")

    -- Handle "not (...)"
    local not_inner = cond_str:match("^not%s+(.*)")
    if not_inner then
        return not eval_supports_condition(not_inner)
    end

    -- Split by " or " (lowest precedence)
    -- Find top-level " or " (not inside parentheses)
    local or_parts = {}
    local depth = 0
    local part_start = 1
    local i = 1
    local slen = #cond_str
    while i <= slen do
        local ch = cond_str:sub(i, i)
        if ch == "(" then depth = depth + 1
        elseif ch == ")" then depth = depth - 1
        elseif depth == 0 and cond_str:sub(i, i + 3) == " or " then
            or_parts[#or_parts + 1] = cond_str:sub(part_start, i - 1)
            i = i + 4
            part_start = i
        end
        i = i + 1
    end
    or_parts[#or_parts + 1] = cond_str:sub(part_start)

    if #or_parts > 1 then
        for oi = 1, #or_parts do
            if eval_supports_condition(or_parts[oi]) then return true end
        end
        return false
    end

    -- Split by " and "
    local and_parts = {}
    depth = 0
    part_start = 1
    i = 1
    while i <= slen do
        local ch = cond_str:sub(i, i)
        if ch == "(" then depth = depth + 1
        elseif ch == ")" then depth = depth - 1
        elseif depth == 0 and cond_str:sub(i, i + 4) == " and " then
            and_parts[#and_parts + 1] = cond_str:sub(part_start, i - 1)
            i = i + 5
            part_start = i
        end
        i = i + 1
    end
    and_parts[#and_parts + 1] = cond_str:sub(part_start)

    if #and_parts > 1 then
        for ai = 1, #and_parts do
            if not eval_supports_condition(and_parts[ai]) then return false end
        end
        return true
    end

    -- Strip balanced outer parentheses: ((display: grid) and ...) → (display: grid) and ...
    if cond_str:sub(1, 1) == "(" then
        local d = 0
        local closes_at_end = false
        for ci = 1, #cond_str do
            local cc = cond_str:sub(ci, ci)
            if cc == "(" then d = d + 1 elseif cc == ")" then d = d - 1 end
            if d == 0 and ci == #cond_str then closes_at_end = true end
            if d == 0 and ci < #cond_str then break end
        end
        if closes_at_end and #cond_str > 2 then
            local inner = cond_str:sub(2, #cond_str - 1):match("^%s*(.-)%s*$")
            -- Only unwrap if inner contains and/or (not a single property:value)
            if inner:find(" and ") or inner:find(" or ") then
                return eval_supports_condition(inner)
            end
        end
    end

    -- Single condition: "(property: value)"
    return eval_supports_single(cond_str)
end

------------------------------------------------------------
-- CSS tokenizer: split CSS text into rule blocks
-- Handles: comments, @media, nested braces
------------------------------------------------------------

--- Strip CSS comments (/* ... */)
local function strip_comments(css)
    local out = {}
    local i, n = 1, #css
    local quote = nil
    while i <= n do
        local ch = css:sub(i, i)
        local next_ch = css:sub(i + 1, i + 1)
        if quote then
            out[#out + 1] = ch
            if ch == "\\" and i < n then
                i = i + 1
                out[#out + 1] = css:sub(i, i)
            elseif ch == quote then
                quote = nil
            end
            i = i + 1
        elseif ch == '"' or ch == "'" then
            quote = ch
            out[#out + 1] = ch
            i = i + 1
        elseif ch == "/" and next_ch == "*" then
            i = i + 2
            while i <= n - 1 do
                if css:sub(i, i) == "*" and css:sub(i + 1, i + 1) == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Extract URL from @import value text (between @import and ;)
-- Supports: url("x"), url('x'), url(x), "x", 'x'
local function parse_import_url(value)
    -- url("...") or url('...') or url(...)
    local u = value:match('url%(%s*"([^"]*)"%s*%)')
           or value:match("url%(%s*'([^']*)'%s*%)")
           or value:match("url%(%s*([^)%s]*)%s*%)")
    if u then return u end
    -- bare string: "..." or '...'
    u = value:match('^%s*"([^"]*)"')
     or value:match("^%s*'([^']*)'")
    return u
end

------------------------------------------------------------
-- CSS Nesting (&) support
-- Separates a rule body into plain declarations and nested
-- rule blocks, then flattens nested selectors by resolving
-- the & placeholder against the parent selector.
------------------------------------------------------------

--- Check if a declarations string contains nested rule blocks.
--- Returns true if there is a '{' that is not inside a CSS function like url(), calc(), etc.
local function has_nested_rules(decls_str)
    local depth = 0
    local in_string = false
    local string_char = nil
    local i = 1
    local len = #decls_str
    while i <= len do
        local ch = decls_str:sub(i, i)
        if in_string then
            if ch == string_char and decls_str:sub(i - 1, i - 1) ~= "\\" then
                in_string = false
            end
        elseif ch == '"' or ch == "'" then
            in_string = true
            string_char = ch
        elseif ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
        elseif ch == "{" and depth == 0 then
            return true
        end
        i = i + 1
    end
    return false
end

--- Separate a block body into plain declarations and nested rule blocks.
--- Plain declarations are lines with "property: value;" that appear before
--- or between nested blocks (at brace depth 0 and without a '{' following).
---@param body string  the text between the outer { }
---@return string plain_decls  the non-nested declarations concatenated
---@return table  nested       array of {selector=string, decls_str=string}
local function split_nested_rules(body)
    local plain_parts = {}
    local nested = {}
    local pos = 1
    local len = #body

    while pos <= len do
        -- Skip whitespace
        local ws = body:find("[^%s]", pos)
        if not ws then break end
        pos = ws

        -- Look ahead for the next '{' at paren-depth 0 (skip quoted strings)
        local paren_depth = 0
        local brace_pos = nil
        local scan = pos
        local in_str = false
        local str_ch = nil
        while scan <= len do
            local ch = body:sub(scan, scan)
            if in_str then
                if ch == str_ch and body:sub(scan - 1, scan - 1) ~= "\\" then
                    in_str = false
                end
            elseif ch == '"' or ch == "'" then
                in_str = true
                str_ch = ch
            elseif ch == "(" then paren_depth = paren_depth + 1
            elseif ch == ")" then paren_depth = paren_depth - 1
            elseif paren_depth == 0 then
                if ch == "{" then
                    brace_pos = scan
                    break
                end
            end
            scan = scan + 1
        end

        if not brace_pos then
            -- No more nested blocks; rest is plain declarations
            local rest = body:sub(pos):match("^%s*(.-)%s*$")
            if rest ~= "" then
                plain_parts[#plain_parts + 1] = rest
            end
            break
        end

        -- Collect any plain declarations (semicolon-terminated) before the nested selector.
        -- Walk from pos to brace_pos-1, collecting complete "prop: value;" segments.
        local seg = body:sub(pos, brace_pos - 1)
        -- Find the last semicolon in this segment (not inside parens)
        local last_semi = nil
        paren_depth = 0
        for si = 1, #seg do
            local ch = seg:sub(si, si)
            if ch == "(" then paren_depth = paren_depth + 1
            elseif ch == ")" then paren_depth = paren_depth - 1
            elseif ch == ";" and paren_depth == 0 then
                last_semi = si
            end
        end

        if last_semi then
            -- Everything up to and including last_semi is plain declarations
            local plain_chunk = seg:sub(1, last_semi):match("^%s*(.-)%s*$")
            if plain_chunk ~= "" then
                plain_parts[#plain_parts + 1] = plain_chunk
            end
            -- The nested selector is what remains after last_semi
            local nested_sel = seg:sub(last_semi + 1):match("^%s*(.-)%s*$")

            -- Find matching closing brace for the nested block
            local depth = 1
            scan = brace_pos + 1
            while scan <= len and depth > 0 do
                local ch = body:sub(scan, scan)
                if ch == "{" then depth = depth + 1
                elseif ch == "}" then depth = depth - 1 end
                scan = scan + 1
            end
            local nested_body = body:sub(brace_pos + 1, scan - 2)

            if nested_sel ~= "" then
                nested[#nested + 1] = { selector = nested_sel, decls_str = nested_body }
            end
            pos = scan
        else
            -- No semicolon before brace: everything from pos to brace is the selector
            local nested_sel = seg:match("^%s*(.-)%s*$")

            -- Find matching closing brace
            local depth = 1
            scan = brace_pos + 1
            while scan <= len and depth > 0 do
                local ch = body:sub(scan, scan)
                if ch == "{" then depth = depth + 1
                elseif ch == "}" then depth = depth - 1 end
                scan = scan + 1
            end
            local nested_body = body:sub(brace_pos + 1, scan - 2)

            if nested_sel ~= "" then
                nested[#nested + 1] = { selector = nested_sel, decls_str = nested_body }
            end
            pos = scan
        end
    end

    local plain_decls = table.concat(plain_parts, " ")
    return plain_decls, nested
end

--- Resolve a nested selector against the parent selector.
--- - If '&' appears in the nested selector, replace it with the parent.
--- - Otherwise prepend the parent selector as a descendant combinator.
---@param parent_sel string  e.g. ".card"
---@param nested_sel string  e.g. "& .title" or "&:hover" or ".icon &"
---@return string  resolved selector, e.g. ".card .title"
local function resolve_nested_selector(parent_sel, nested_sel)
    if nested_sel:find("&", 1, true) then
        -- Replace all occurrences of & with the parent selector.
        -- Manual replacement to avoid gsub pattern/replacement escaping issues.
        local result = {}
        local pos = 1
        while true do
            local amp = nested_sel:find("&", pos, true)
            if not amp then
                result[#result + 1] = nested_sel:sub(pos)
                break
            end
            result[#result + 1] = nested_sel:sub(pos, amp - 1)
            result[#result + 1] = parent_sel
            pos = amp + 1
        end
        return table.concat(result)
    else
        -- No &: prepend parent as descendant
        return parent_sel .. " " .. nested_sel
    end
end

--- Flatten nested rules: given a parent selector and a list of nested rule
--- descriptors, resolve selectors and return flat {selector, decls_str} entries.
--- Handles recursive nesting (nested rules within nested rules).
---@param parent_sel string
---@param nested table  array of {selector, decls_str}
---@return table  flat array of {selector=string, decls_str=string}
local function flatten_nested_rules(parent_sel, nested)
    local flat = {}
    for i = 1, #nested do
        local n = nested[i]
        -- Handle comma-separated selectors in the nested rule
        local sel_parts = split_selector_list(n.selector)

        -- Resolve each nested selector against each parent selector part
        local parent_parts = split_selector_list(parent_sel)

        local resolved_sels = {}
        for pi = 1, #parent_parts do
            for si = 1, #sel_parts do
                resolved_sels[#resolved_sels + 1] = resolve_nested_selector(parent_parts[pi], sel_parts[si])
            end
        end

        local resolved_selector = table.concat(resolved_sels, ", ")

        -- Check if this nested block itself contains nested rules (recursive)
        if has_nested_rules(n.decls_str) then
            local inner_plain, inner_nested = split_nested_rules(n.decls_str)
            -- Add the plain declarations for this level
            if inner_plain ~= "" then
                flat[#flat + 1] = { selector = resolved_selector, decls_str = inner_plain }
            end
            -- Recurse for deeper nesting
            local deeper = flatten_nested_rules(resolved_selector, inner_nested)
            for di = 1, #deeper do
                flat[#flat + 1] = deeper[di]
            end
        else
            flat[#flat + 1] = { selector = resolved_selector, decls_str = n.decls_str }
        end
    end
    return flat
end

--- Tokenize CSS into an array of {selector, declarations_str}
--- or {type="media", condition=str, rules={...}}
--- Optional imports table collects @import tokens from the top of the stylesheet.
--- Optional layers table records declaration-order of @layer names (shared
--- between nested tokenize_rules calls via closure).
local function tokenize_rules(css, imports, layers_tbl, layer_name)
    local rules = {}
    local pos = 1
    local len = #css
    -- Per CSS spec, @import must precede all other rules (except @charset).
    -- Once we see a non-import/non-charset rule, stop collecting imports.
    local imports_allowed = (imports ~= nil)

    local function register_layer(name)
        if not layers_tbl or not name or name == "" then return end
        for i = 1, #layers_tbl do
            if layers_tbl[i] == name then return end
        end
        layers_tbl[#layers_tbl + 1] = name
    end

    local function find_matching_brace(brace_start)
        local depth = 1
        local scan = brace_start + 1
        local quote = nil
        while scan <= len and depth > 0 do
            local ch = css:sub(scan, scan)
            if quote then
                if ch == "\\" and scan < len then
                    scan = scan + 1
                elseif ch == quote then
                    quote = nil
                end
            elseif ch == '"' or ch == "'" then
                quote = ch
            elseif ch == "{" then
                depth = depth + 1
            elseif ch == "}" then
                depth = depth - 1
            end
            scan = scan + 1
        end
        return scan
    end

    while pos <= len do
        -- Skip whitespace
        local ws = css:find("[^%s]", pos)
        if not ws then break end
        pos = ws

        -- @media block
        if css:sub(pos, pos + 5) == "@media" then
            imports_allowed = false
            -- Find the condition (everything between @media and {)
            local brace_start = css:find("{", pos)
            if not brace_start then break end
            local condition = css:sub(pos + 6, brace_start - 1):match("^%s*(.-)%s*$")

            -- Find matching closing brace (balanced)
            local scan = find_matching_brace(brace_start)
            local inner_css = css:sub(brace_start + 1, scan - 2)
            local inner_rules = tokenize_rules(inner_css, nil, layers_tbl, layer_name)
            rules[#rules + 1] = { type = "media", condition = condition, rules = inner_rules }
            pos = scan

        -- @counter-style name { system: ...; symbols: ...; suffix: ... }
        elseif css:sub(pos, pos + 13) == "@counter-style" then
            imports_allowed = false
            local brace_start = css:find("{", pos)
            if brace_start then
                local name = css:sub(pos + 14, brace_start - 1):match("^%s*([%w_%-]+)%s*$")
                local depth = 1
                local scan = brace_start + 1
                while scan <= len and depth > 0 do
                    local ch = css:sub(scan, scan)
                    if ch == "{" then depth = depth + 1
                    elseif ch == "}" then depth = depth - 1 end
                    scan = scan + 1
                end
                local inner = css:sub(brace_start + 1, scan - 2)
                if name then
                    rules[#rules + 1] = { type = "counter_style", name = name, body = inner }
                end
                pos = scan
            else
                local semi = css:find(";", pos)
                pos = semi and semi + 1 or len + 1
            end

        -- @property --name { syntax: ...; inherits: ...; initial-value: ... }
        elseif css:sub(pos, pos + 8) == "@property" then
            imports_allowed = false
            local brace_start = css:find("{", pos)
            if brace_start then
                local name = css:sub(pos + 9, brace_start - 1):match("^%s*(%-%-[%w%-_]+)%s*$")
                local depth = 1
                local scan = brace_start + 1
                while scan <= len and depth > 0 do
                    local ch = css:sub(scan, scan)
                    if ch == "{" then depth = depth + 1
                    elseif ch == "}" then depth = depth - 1 end
                    scan = scan + 1
                end
                local inner = css:sub(brace_start + 1, scan - 2)
                if name then
                    rules[#rules + 1] = { type = "property", name = name, body = inner }
                end
                pos = scan
            else
                local semi = css:find(";", pos)
                pos = semi and semi + 1 or len + 1
            end

        -- @font-face: custom font declaration
        elseif css:sub(pos, pos + 9) == "@font-face" then
            imports_allowed = false
            local brace_start = css:find("{", pos)
            if brace_start then
                local depth = 1
                local scan = brace_start + 1
                while scan <= len and depth > 0 do
                    local ch = css:sub(scan, scan)
                    if ch == "{" then depth = depth + 1
                    elseif ch == "}" then depth = depth - 1 end
                    scan = scan + 1
                end
                local inner = css:sub(brace_start + 1, scan - 2)
                rules[#rules + 1] = { type = "font_face", body = inner }
                pos = scan
            else
                local semi = css:find(";", pos)
                pos = semi and semi + 1 or len + 1
            end

        -- @keyframes: parse into structured keyframe data
        elseif css:sub(pos, pos + 10) == "@keyframes" then
            imports_allowed = false
            local name_start = pos + 11
            local brace_start = css:find("{", name_start)
            if brace_start then
                local kf_name = css:sub(name_start, brace_start - 1):match("^%s*(.-)%s*$")
                local depth = 1
                local scan = brace_start + 1
                while scan <= len and depth > 0 do
                    local ch = css:sub(scan, scan)
                    if ch == "{" then depth = depth + 1
                    elseif ch == "}" then depth = depth - 1 end
                    scan = scan + 1
                end
                local inner = css:sub(brace_start + 1, scan - 2)
                rules[#rules + 1] = { type = "keyframes", name = kf_name, body = inner }
                pos = scan
            else
                local semi = css:find(";", pos)
                pos = semi and semi + 1 or len + 1
            end

        -- @supports: conditionally include rules based on property support
        elseif css:sub(pos, pos + 8) == "@supports" then
            imports_allowed = false
            local brace_start = css:find("{", pos)
            if not brace_start then break end
            local condition = css:sub(pos + 9, brace_start - 1):match("^%s*(.-)%s*$")

            -- Find matching closing brace (balanced)
            local scan = find_matching_brace(brace_start)

            -- Evaluate @supports condition
            local supported = eval_supports_condition(condition)
            if supported then
                local inner_css = css:sub(brace_start + 1, scan - 2)
                local inner_rules = tokenize_rules(inner_css, nil, layers_tbl, layer_name)
                -- Flatten inner rules into outer rules (like @media when active)
                for ri = 1, #inner_rules do
                    rules[#rules + 1] = inner_rules[ri]
                end
            end
            pos = scan

        -- @import: emit token for caller to resolve (no I/O here)
        elseif css:sub(pos, pos + 6) == "@import" then
            local semi = css:find(";", pos)
            if semi then
                if imports_allowed then
                    local value = css:sub(pos + 7, semi - 1)
                    local url = parse_import_url(value)
                    if url then
                        imports[#imports + 1] = { url = url }
                    end
                end
                pos = semi + 1
            else
                pos = len + 1
            end

        -- @starting-style { rules } -" rules applied on the first style
        -- resolution of a node; subsequent resolutions use normal rules,
        -- so transitions animate from the starting values.
        elseif css:sub(pos, pos + 14) == "@starting-style" then
            imports_allowed = false
            local brace_start = css:find("{", pos)
            if brace_start then
                local depth = 1
                local scan = brace_start + 1
                while scan <= len and depth > 0 do
                    local ch = css:sub(scan, scan)
                    if ch == "{" then depth = depth + 1
                    elseif ch == "}" then depth = depth - 1 end
                    scan = scan + 1
                end
                local inner_css = css:sub(brace_start + 1, scan - 2)
                local inner_rules = tokenize_rules(inner_css, nil, layers_tbl, layer_name)
                rules[#rules + 1] = { type = "starting_style", rules = inner_rules }
                pos = scan
            else
                pos = len + 1
            end

        -- @container [name] (condition) { rules }
        elseif css:sub(pos, pos + 9) == "@container" then
            imports_allowed = false
            local brace_start = css:find("{", pos)
            if brace_start then
                local header = css:sub(pos + 10, brace_start - 1):match("^%s*(.-)%s*$")
                -- Split into optional name and the parenthesized condition
                local cname, cond
                local paren_at = header:find("%(")
                if paren_at then
                    cname = header:sub(1, paren_at - 1):match("^%s*([%w_%-]*)%s*$")
                    cond  = header:sub(paren_at):match("^%s*(.-)%s*$")
                else
                    cname, cond = nil, header
                end
                local depth = 1
                local scan = brace_start + 1
                while scan <= len and depth > 0 do
                    local ch = css:sub(scan, scan)
                    if ch == "{" then depth = depth + 1
                    elseif ch == "}" then depth = depth - 1 end
                    scan = scan + 1
                end
                local inner_css = css:sub(brace_start + 1, scan - 2)
                local inner_rules = tokenize_rules(inner_css, nil, layers_tbl, layer_name)
                rules[#rules + 1] = {
                    type = "container",
                    name = (cname and cname ~= "") and cname or nil,
                    condition = cond,
                    rules = inner_rules,
                }
                pos = scan
            else
                pos = len + 1
            end

        -- @layer -" cascade layers.  Two forms:
        --   @layer foo, bar;           declaration-only; records names in order
        --   @layer foo { ... }         block; inner rules get layer_name stamped
        elseif css:sub(pos, pos + 5) == "@layer" then
            imports_allowed = false
            -- Find either brace or semicolon first
            local brace_start = css:find("{", pos)
            local semi = css:find(";", pos)
            if semi and (not brace_start or semi < brace_start) then
                -- Declaration form
                local names_str = css:sub(pos + 6, semi - 1)
                for name in names_str:gmatch("[%w_%-]+") do
                    register_layer(name)
                end
                pos = semi + 1
            elseif brace_start then
                -- Block form: @layer name { inner }
                local name = css:sub(pos + 6, brace_start - 1):match("^%s*([%w_%-]+)%s*$")
                if not name then name = "" end -- anonymous layer
                register_layer(name)
                local scan = find_matching_brace(brace_start)
                local inner_css = css:sub(brace_start + 1, scan - 2)
                local inner_rules = tokenize_rules(inner_css, nil, layers_tbl, name)
                for ri = 1, #inner_rules do
                    rules[#rules + 1] = inner_rules[ri]
                end
                pos = scan
            else
                pos = len + 1
            end

        -- @charset, @namespace (semicolon-terminated, skip entirely)
        elseif css:sub(pos, pos + 7) == "@charset" or css:sub(pos, pos + 9) == "@namespace" then
            -- @namespace is a real rule, so it ends the import preamble
            if css:sub(pos, pos + 9) == "@namespace" then
                imports_allowed = false
            end
            -- These are always semicolon-terminated (never braced)
            local semi = css:find(";", pos)
            pos = semi and semi + 1 or len + 1

        else
            imports_allowed = false
            -- Regular rule: selector { declarations }
            local brace_start = css:find("{", pos)
            if not brace_start then break end
            local selector = css:sub(pos, brace_start - 1):match("^%s*(.-)%s*$")

            -- Find matching closing brace
            local scan = find_matching_brace(brace_start)
            local decls_str = css:sub(brace_start + 1, scan - 2)

            -- CSS Nesting support: if the block body contains nested rule
            -- blocks (a '{' at paren-depth 0), split into plain declarations
            -- and nested rules, then flatten the nested selectors.
            if has_nested_rules(decls_str) then
                local plain_decls, nested = split_nested_rules(decls_str)
                -- Emit the parent rule with only its plain declarations
                if plain_decls ~= "" then
                    rules[#rules + 1] = { selector = selector, decls_str = plain_decls, layer = layer_name }
                end
                -- Flatten and emit nested rules
                local flat = flatten_nested_rules(selector, nested)
                for fi = 1, #flat do
                    rules[#rules + 1] = { selector = flat[fi].selector, decls_str = flat[fi].decls_str, layer = layer_name }
                end
            else
                rules[#rules + 1] = { selector = selector, decls_str = decls_str, layer = layer_name }
            end
            pos = scan
        end
    end

    return rules
end

--- Parse a declarations string into array of {prop_name, value_str}
--- Handles balanced parens in values (e.g. rgb(...), calc(...))
local function parse_declarations(decls_str)
    local decls = {}
    local pos = 1
    local len = #decls_str

    while pos <= len do
        -- Skip whitespace
        local ws = decls_str:find("[^%s]", pos)
        if not ws then break end
        pos = ws

        -- Find the colon separating property from value
        local colon = decls_str:find(":", pos)
        if not colon then break end

        local prop_name = decls_str:sub(pos, colon - 1):match("^%s*(.-)%s*$")
        if prop_name and prop_name:sub(1, 2) ~= "--" then
            prop_name = prop_name:lower()
        end

        -- Find the value (everything up to ; or end, respecting balanced parens)
        local val_start = colon + 1
        local depth = 0
        local quote = nil
        local scan = val_start
        while scan <= len do
            local ch = decls_str:sub(scan, scan)
            if quote then
                if ch == "\\" and scan < len then
                    scan = scan + 1
                elseif ch == quote then
                    quote = nil
                end
            elseif ch == '"' or ch == "'" then
                quote = ch
            elseif ch == "(" then depth = depth + 1
            elseif ch == ")" then depth = depth - 1
            elseif ch == ";" and depth == 0 then break
            end
            scan = scan + 1
        end
        local val_str = decls_str:sub(val_start, scan - 1):match("^%s*(.-)%s*$")
        decls[#decls + 1] = { prop_name, val_str }
        pos = scan + 1
    end

    return decls
end

--- Parse @media condition string into conditions table.
--- Supports: (min-width: Npx), (prefers-color-scheme: dark),
--- (orientation: landscape), (min-aspect-ratio: 16/9), etc.
local function parse_media_condition(cond_str)
    local conditions = {}
    -- Match all parenthesized conditions
    for term in cond_str:gmatch("%(([^%)]+)%)") do
        local name, val = term:match("^%s*([%w%-]+)%s*:%s*(.+)%s*$")
        if name and val then
            -- Try px value
            local px = val:match("^(%d+)px$")
            if px then
                conditions[name] = tonumber(px)
            else
                -- Try ratio (e.g. 16/9)
                local num, den = val:match("^(%d+)%s*/%s*(%d+)$")
                if num and den and tonumber(den) > 0 then
                    conditions[name] = tonumber(num) / tonumber(den)
                else
                    -- Keyword value (dark, light, landscape, portrait, etc.)
                    conditions[name] = val:match("^%s*(.-)%s*$")
                end
            end
        end
    end
    return conditions
end

------------------------------------------------------------
-- Compile a single CSS rule (selector + declarations) into
-- the bucketed format: {by_id, by_class, by_tag, universal, complex}
------------------------------------------------------------
local function compile_rule(selector, decls_str, order, target, layer_name)
    local raw_decls = parse_declarations(decls_str)
    local decls = {}
    local vars = nil
    local important_decls = {}

    for i = 1, #raw_decls do
        local prop_name = raw_decls[i][1]
        local val_str   = raw_decls[i][2]
        if not prop_name or prop_name == "" then
            -- skip empty
        elseif prop_name:sub(1, 2) == "--" then
            -- CSS custom property
            if not vars then vars = {} end
            local trimmed = val_str and val_str:match("^(.-)%s*!important%s*$") or val_str
            vars[prop_name] = trimmed or val_str
        else
            -- Check shorthand expansion
            local expanded = expand_shorthands(prop_name, val_str)
            if expanded then
                for ei = 1, #expanded do
                    local ep = expanded[ei][1]
                    local ev = expanded[ei][2]
                    local pid = PROP[ep]
                    if pid and pid > 0 then
                        local value, is_imp = parse_value(ev, ep)
                        if value ~= nil then
                            local arr = is_imp and important_decls or decls
                            arr[#arr + 1] = { pid, value }
                        end
                    end
                end
            else
                local pid = PROP[prop_name]
                if pid and pid > 0 then
                    local value, is_imp = parse_value(val_str, prop_name)
                    if value ~= nil then
                        local arr = is_imp and important_decls or decls
                        arr[#arr + 1] = { pid, value }
                    end
                end
            end
        end
    end

    local imp = (#important_decls > 0) and important_decls or nil

    -- Handle top-level comma-separated selectors: "h1, h2, h3"
    local selectors = split_selector_list(selector)

    for si = 1, #selectors do
        local sel = selectors[si]
        -- Bucket by selector type
        if SelectorParser.is_complex(sel) then
            local parsed = SelectorParser.parse(sel)
            local specificity = SelectorParser.specificity(parsed)
            local rule = { specificity = specificity, order = order, decls = decls, vars = vars, important_decls = imp, layer = layer_name }
            target.complex[#target.complex + 1] = { parsed = parsed, rule = rule }
        elseif sel == "*" then
            local rule = { specificity = 0, order = order, decls = decls, vars = vars, important_decls = imp, layer = layer_name }
            target.universal[#target.universal + 1] = rule
        elseif sel:sub(1, 1) == "#" and not sel:find("[%.%s%[>~%+:]") then
            local rule = { specificity = 10000, order = order, decls = decls, vars = vars, important_decls = imp, layer = layer_name }
            local id = sel:sub(2)
            if not target.by_id[id] then target.by_id[id] = {} end
            target.by_id[id][#target.by_id[id] + 1] = rule
        elseif sel:sub(1, 1) == "." and not sel:find("[#%s%[>~%+:]") and not sel:find("%.", 2) then
            -- Simple single-class selector like ".foo" (not ".foo.bar")
            local rule = { specificity = 100, order = order, decls = decls, vars = vars, important_decls = imp, layer = layer_name }
            local cls = sel:sub(2)
            if not target.by_class[cls] then target.by_class[cls] = {} end
            target.by_class[cls][#target.by_class[cls] + 1] = rule
        elseif sel:match("^[%w%-]+$") then
            local rule = { specificity = 1, order = order, decls = decls, vars = vars, important_decls = imp, layer = layer_name }
            local tag = sel:lower()
            if not target.by_tag[tag] then target.by_tag[tag] = {} end
            target.by_tag[tag][#target.by_tag[tag] + 1] = rule
        else
            -- Complex selector (combinators, pseudo-classes, etc.)
            local ok, parsed = pcall(SelectorParser.parse, sel)
            if ok and parsed then
                local specificity = SelectorParser.specificity(parsed)
                local rule = { specificity = specificity, order = order, decls = decls, vars = vars, important_decls = imp, layer = layer_name }
                target.complex[#target.complex + 1] = { parsed = parsed, rule = rule }
            end
        end
    end
end

------------------------------------------------------------
-- @keyframes body parser
------------------------------------------------------------

--- Resolve a structured CSS value to a plain value for animations.
--- Mirrors StyleEngine:_resolve_value() but without needing an instance.
local function resolve_anim_value(v)
    if not v or type(v) ~= "table" then return v end
    local vtype = v.type
    if vtype == "color" then
        local c = v.v
        if type(c) == "table" then
            return { c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 255 }
        end
        return { 0, 0, 0, 255 }
    elseif vtype == "px" then
        return v.v or 0
    elseif vtype == "keyword" then
        return v.v or ""
    elseif vtype == "none" then
        return "none"
    elseif vtype == "auto" then
        return "auto"
    end
    -- pct, vw, vh, rem, calc -" pass through as-is (layout resolves them)
    return v
end

--- Parse a @keyframes body into TransitionEngine format.
--- Input:  "0% { opacity: 0; } 50% { opacity: 128; } 100% { opacity: 255; }"
--- Output: { {0, {opacity=0}}, {50, {opacity=128}}, {100, {opacity=255}} }
---@param body string  inner text of @keyframes block
---@return table  keyframes array
local function parse_keyframes_body(body)
    local frames = {}
    local pos = 1
    local len = #body

    while pos <= len do
        -- Skip whitespace
        local ws = body:find("[^%s]", pos)
        if not ws then break end
        pos = ws

        -- Read percentage selector(s): "0%", "100%", "from", "to", "50%, 75%"
        local brace = body:find("{", pos)
        if not brace then break end
        local selector_str = body:sub(pos, brace - 1):match("^%s*(.-)%s*$")

        -- Find matching closing brace
        local depth = 1
        local scan = brace + 1
        while scan <= len and depth > 0 do
            local ch = body:sub(scan, scan)
            if ch == "{" then depth = depth + 1
            elseif ch == "}" then depth = depth - 1 end
            scan = scan + 1
        end
        local decls_str = body:sub(brace + 1, scan - 2)

        -- Parse declarations into prop=value map
        local raw_decls = parse_declarations(decls_str)
        local props = {}
        for di = 1, #raw_decls do
            local prop_name = raw_decls[di][1]
            local val_str   = raw_decls[di][2]
            if prop_name and val_str then
                -- Expand shorthands
                local expanded = expand_shorthands(prop_name, val_str)
                if expanded then
                    for ei = 1, #expanded do
                        local pid = PROP[expanded[ei][1]]
                        if pid and pid > 0 then
                            local pval = parse_value(expanded[ei][2], expanded[ei][1])
                            if pval ~= nil then
                                pval = resolve_anim_value(pval)
                                local pkey = expanded[ei][1]:gsub("%-", "_")
                                props[pkey] = pval
                            end
                        end
                    end
                else
                    -- Non-shorthand property: store directly
                    local pid = PROP[prop_name]
                    if pid and pid > 0 then
                        local pval = parse_value(val_str, prop_name)
                        if pval ~= nil then
                            pval = resolve_anim_value(pval)
                            local pkey = prop_name:gsub("%-", "_")
                            props[pkey] = pval
                        end
                    end
                end
            end
        end

        -- Parse percentage selectors (may be comma-separated)
        local first_pct = true
        for pct_str in selector_str:gmatch("[^,]+") do
            pct_str = pct_str:match("^%s*(.-)%s*$")
            local pct
            if pct_str == "from" then
                pct = 0
            elseif pct_str == "to" then
                pct = 100
            else
                pct = tonumber(pct_str:match("([%d%.]+)%%?"))
            end
            if pct then
                if first_pct then
                    frames[#frames + 1] = { pct, props }
                    first_pct = false
                else
                    -- Shallow copy to avoid shared mutation
                    local copy = {}
                    for k, v in pairs(props) do copy[k] = v end
                    frames[#frames + 1] = { pct, copy }
                end
            end
        end

        pos = scan
    end

    -- Sort by percentage
    table.sort(frames, function(a, b) return a[1] < b[1] end)
    return frames
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Parse a @font-face body into a structured table.
---@param body string  inner text of @font-face block
---@return table  { family, src, weight, style }
local function parse_font_face_body(body)
    local result = {}
    local decls = parse_declarations(body)
    for i = 1, #decls do
        local prop = decls[i][1]
        local val  = decls[i][2]
        if prop == "font-family" then
            -- Strip quotes: "MyFont" or 'MyFont' → MyFont
            local unquoted = val:match('^"(.-)"$') or val:match("^'(.-)'$") or val
            result.family = unquoted
        elseif prop == "src" then
            -- Extract URL from url("..."), url('...'), url(...)
            local url = val:match('url%(%s*"([^"]*)"%s*%)')
                     or val:match("url%(%s*'([^']*)'%s*%)")
                     or val:match("url%(%s*([^)%s]*)%s*%)")
            if url then
                result.src = url
            end
        elseif prop == "font-weight" then
            result.weight = val
        elseif prop == "font-style" then
            result.style = val
        end
    end
    return result
end

--- Parse a CSS string into bucketed rules.
---@param css_str string  raw CSS text
---@return table  rules { by_id, by_class, by_tag, universal, complex, media, keyframes, font_faces }
---@return table  imports  array of {url=string} for each @import found before rules
function CSSParser.parse(css_str)
    if not css_str or css_str == "" then
        return { by_id = {}, by_class = {}, by_tag = {}, universal = {}, complex = {} }, {}
    end

    -- Strip comments
    local clean = strip_comments(css_str)

    -- Tokenize into rule blocks; collect @import tokens and @layer declarations
    local imports = {}
    local layers_tbl = {}
    local raw_rules = tokenize_rules(clean, imports, layers_tbl, nil)

    -- Build layer → priority index.  Unlayered rules get index math.huge so
    -- they sort LAST (highest precedence) per CSS cascade spec.
    local layer_index = {}
    for i = 1, #layers_tbl do layer_index[layers_tbl[i]] = i end

    -- Compile into bucketed rules
    local rules = { by_id = {}, by_class = {}, by_tag = {}, universal = {}, complex = {}, layers = layers_tbl }
    local order = 0

    local function process_rules(raw_list, target)
        for i = 1, #raw_list do
            local r = raw_list[i]
            if r.type == "media" then
                local condition = parse_media_condition(r.condition)
                local inner_bucket = {
                    by_id = {}, by_class = {}, by_tag = {},
                    universal = {}, complex = {},
                }
                process_rules(r.rules, inner_bucket)
                rules.media = rules.media or {}
                rules.media[#rules.media + 1] = {
                    condition = condition,
                    rules = inner_bucket,
                }
            elseif r.type == "font_face" and r.body then
                local ff = parse_font_face_body(r.body)
                if ff.family then
                    ff.type = "font_face"
                    rules.font_faces = rules.font_faces or {}
                    rules.font_faces[#rules.font_faces + 1] = ff
                end
            elseif r.type == "starting_style" and r.rules then
                local inner_bucket = {
                    by_id = {}, by_class = {}, by_tag = {},
                    universal = {}, complex = {},
                }
                process_rules(r.rules, inner_bucket)
                rules.starting_styles = rules.starting_styles or {}
                rules.starting_styles[#rules.starting_styles + 1] = inner_bucket
            elseif r.type == "container" and r.rules then
                -- Parse "(min-width: 400px)" etc. into structured condition
                local parsed_cond = {}
                for k, v in r.condition:gmatch("%(%s*([%w%-]+)%s*:%s*([^%)]+)%s*%)") do
                    local num = v:match("([%d%.]+)")
                    if num then
                        parsed_cond[k] = tonumber(num)
                    end
                end
                local inner_bucket = {
                    by_id = {}, by_class = {}, by_tag = {},
                    universal = {}, complex = {},
                }
                process_rules(r.rules, inner_bucket)
                rules.containers = rules.containers or {}
                rules.containers[#rules.containers + 1] = {
                    name = r.name,
                    condition = parsed_cond,
                    rules = inner_bucket,
                }
            elseif r.type == "counter_style" and r.name and r.body then
                local raw_decls = parse_declarations(r.body)
                local entry = { name = r.name, system = "cyclic", symbols = {}, suffix = ". ", prefix = "" }
                for di = 1, #raw_decls do
                    local pn, pv = raw_decls[di][1], raw_decls[di][2]
                    if pn == "system" then
                        -- "cyclic", "numeric", "alphabetic", "additive", or "fixed N"
                        entry.system = pv:match("^%s*(%S+)")
                    elseif pn == "symbols" then
                        -- Collect quoted strings / bare words
                        for sym in pv:gmatch('"([^"]-)"') do
                            entry.symbols[#entry.symbols + 1] = sym
                        end
                        if #entry.symbols == 0 then
                            for sym in pv:gmatch("%S+") do
                                entry.symbols[#entry.symbols + 1] = sym
                            end
                        end
                    elseif pn == "suffix" then
                        entry.suffix = pv:match('"([^"]*)"') or pv:match("^%s*(.-)%s*$") or ". "
                    elseif pn == "prefix" then
                        entry.prefix = pv:match('"([^"]*)"') or pv:match("^%s*(.-)%s*$") or ""
                    end
                end
                rules.counter_styles = rules.counter_styles or {}
                rules.counter_styles[r.name] = entry
            elseif r.type == "property" and r.name and r.body then
                -- @property: parse body as simple decl list, store entry.
                -- Used by transitions/animations; not enforced at cascade time.
                local raw_decls = parse_declarations(r.body)
                local entry = { name = r.name }
                for di = 1, #raw_decls do
                    local pn, pv = raw_decls[di][1], raw_decls[di][2]
                    if pn == "syntax" then
                        entry.syntax = pv and pv:match('^"([^"]*)"$') or pv
                    elseif pn == "inherits" then
                        entry.inherits = (pv == "true")
                    elseif pn == "initial-value" then
                        entry.initial_value = pv
                    end
                end
                rules.properties = rules.properties or {}
                rules.properties[#rules.properties + 1] = entry
            elseif r.type == "keyframes" and r.name and r.body then
                rules.keyframes = rules.keyframes or {}
                rules.keyframes[r.name] = parse_keyframes_body(r.body)
            elseif r.selector and r.decls_str then
                order = order + 1
                compile_rule(r.selector, r.decls_str, order, target, r.layer)
            end
        end
    end

    process_rules(raw_rules, rules)

    -- Resolve each rule's layer_order now that we know the full layer list.
    local function set_layer_order(rule)
        if not rule then return end
        local li = rule.layer and layer_index[rule.layer] or nil
        rule.layer_order = li or math.huge  -- unlayered = highest priority
    end
    local function walk_bucket(bucket)
        if not bucket then return end
        for _, arr in pairs(bucket) do
            for i = 1, #arr do set_layer_order(arr[i]) end
        end
    end
    walk_bucket(rules.by_id)
    walk_bucket(rules.by_class)
    walk_bucket(rules.by_tag)
    for i = 1, #(rules.universal or {}) do set_layer_order(rules.universal[i]) end
    for i = 1, #(rules.complex or {}) do set_layer_order(rules.complex[i].rule) end
    if rules.media then
        for i = 1, #rules.media do
            local mr = rules.media[i].rules
            walk_bucket(mr.by_id); walk_bucket(mr.by_class); walk_bucket(mr.by_tag)
            for j = 1, #(mr.universal or {}) do set_layer_order(mr.universal[j]) end
            for j = 1, #(mr.complex or {}) do set_layer_order(mr.complex[j].rule) end
        end
    end

    return rules, imports
end

--- Parse a single inline style string (no selector, no braces).
---@param style_str string  e.g. "color: red; padding: 10px;"
---@return table  array of {prop_id, value}
function CSSParser.parse_inline(style_str)
    if not style_str or style_str == "" then return {} end

    local raw_decls = parse_declarations(style_str)
    local decls = {}

    for i = 1, #raw_decls do
        local prop_name = raw_decls[i][1]
        local val_str   = raw_decls[i][2]
        if prop_name and prop_name ~= "" and prop_name:sub(1, 2) ~= "--" then
            local expanded = expand_shorthands(prop_name, val_str)
            if expanded then
                for ei = 1, #expanded do
                    local pid = PROP[expanded[ei][1]]
                    if pid and pid > 0 then
                        local value = parse_value(expanded[ei][2], expanded[ei][1])
                        if value ~= nil then
                            decls[#decls + 1] = { pid, value }
                        end
                    end
                end
            else
                local pid = PROP[prop_name]
                if pid and pid > 0 then
                    local value = parse_value(val_str, prop_name)
                    if value ~= nil then
                        decls[#decls + 1] = { pid, value }
                    end
                end
            end
        end
    end

    return decls
end

--- Parse an inline style string and preserve CSS custom properties.
---@param style_str string
---@return table  { decls = array-of-{prop_id,value}, vars = map|nil }
function CSSParser.parse_inline_full(style_str)
    if not style_str or style_str == "" then return { decls = {} } end

    local raw_decls = parse_declarations(style_str)
    local decls = {}
    local important_decls = {}
    local vars = nil

    for i = 1, #raw_decls do
        local prop_name = raw_decls[i][1]
        local val_str   = raw_decls[i][2]
        if prop_name and prop_name ~= "" then
            if prop_name:sub(1, 2) == "--" then
                if not vars then vars = {} end
                local trimmed = val_str and val_str:match("^(.-)%s*!important%s*$") or val_str
                vars[prop_name] = trimmed or val_str
            else
                local expanded = expand_shorthands(prop_name, val_str)
                if expanded then
                    for ei = 1, #expanded do
                        local pid = PROP[expanded[ei][1]]
                        if pid and pid > 0 then
                            local value, is_imp = parse_value(expanded[ei][2], expanded[ei][1])
                            if value ~= nil then
                                local arr = is_imp and important_decls or decls
                                arr[#arr + 1] = { pid, value }
                            end
                        end
                    end
                else
                    local pid = PROP[prop_name]
                    if pid and pid > 0 then
                        local value, is_imp = parse_value(val_str, prop_name)
                        if value ~= nil then
                            local arr = is_imp and important_decls or decls
                            arr[#arr + 1] = { pid, value }
                        end
                    end
                end
            end
        end
    end

    local imp = (#important_decls > 0) and important_decls or nil
    return { decls = decls, important_decls = imp, vars = vars }
end

--- Parse a single CSS property value. Used after resolving var().
---@param val_str string
---@param prop_name string
---@return any
function CSSParser.parse_property_value(val_str, prop_name)
    local value = parse_value(val_str, prop_name)
    return value
end

--- Expose parse_color for external use
CSSParser.parse_color = parse_color

return CSSParser



