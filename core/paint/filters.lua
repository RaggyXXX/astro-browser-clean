------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / filters.lua
-- CSS filter effects: parse, color transform, blur/shadow
-- approximation via layered display list primitives.
--
-- Supports: blur, grayscale, brightness, contrast, saturate,
-- sepia, invert, opacity, hue-rotate, drop-shadow.
--
-- No GPU shaders available -" all effects are software
-- approximations using the display list rect_fill primitive.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local math_floor = math.floor
local math_min   = math.min
local math_max   = math.max
local math_sin   = math.sin
local math_cos   = math.cos
local math_sqrt  = math.sqrt
local math_abs   = math.abs
local math_pi    = math.pi

local Filters = {}

------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------

--- Clamp a value between lo and hi.
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Clamp a color channel to 0-255 integer.
local function clamp_byte(v)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return math_floor(v + 0.5)
end

--- Convert RGB (0-255) to HSL (h: 0-360, s: 0-1, l: 0-1).
local function rgb_to_hsl(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max_c = math_max(r, g, b)
    local min_c = math_min(r, g, b)
    local l = (max_c + min_c) / 2
    if max_c == min_c then
        return 0, 0, l
    end
    local d = max_c - min_c
    local s
    if l > 0.5 then
        s = d / (2 - max_c - min_c)
    else
        s = d / (max_c + min_c)
    end
    local h
    if max_c == r then
        h = (g - b) / d
        if g < b then h = h + 6 end
    elseif max_c == g then
        h = (b - r) / d + 2
    else
        h = (r - g) / d + 4
    end
    h = h * 60
    return h, s, l
end

--- Convert HSL (h: 0-360, s: 0-1, l: 0-1) to RGB (0-255).
local function hsl_to_rgb(h, s, l)
    if s == 0 then
        local v = clamp_byte(l * 255)
        return v, v, v
    end
    h = h / 360
    local q
    if l < 0.5 then
        q = l * (1 + s)
    else
        q = l + s - l * s
    end
    local p = 2 * l - q
    local function hue2rgb(t)
        if t < 0 then t = t + 1 end
        if t > 1 then t = t - 1 end
        if t < 1/6 then return p + (q - p) * 6 * t end
        if t < 1/2 then return q end
        if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
        return p
    end
    return clamp_byte(hue2rgb(h + 1/3) * 255),
           clamp_byte(hue2rgb(h) * 255),
           clamp_byte(hue2rgb(h - 1/3) * 255)
end

------------------------------------------------------------
-- Parse
------------------------------------------------------------

--- Parse a single CSS color value from drop-shadow.
--- Accepts #RRGGBB, #RRGGBBAA, #RGB, rgba(r,g,b,a), rgb(r,g,b)
--- or common named colors. Returns r, g, b, a (0-255).
local function parse_color(s)
    if not s or s == "" then return 0, 0, 0, 128 end
    s = s:match("^%s*(.-)%s*$")  -- trim

    -- Hex colors
    if s:sub(1, 1) == "#" then
        local hex = s:sub(2)
        if #hex == 3 then
            local r = tonumber(hex:sub(1,1), 16) * 17
            local g = tonumber(hex:sub(2,2), 16) * 17
            local b = tonumber(hex:sub(3,3), 16) * 17
            return r or 0, g or 0, b or 0, 255
        elseif #hex == 6 then
            local r = tonumber(hex:sub(1,2), 16)
            local g = tonumber(hex:sub(3,4), 16)
            local b = tonumber(hex:sub(5,6), 16)
            return r or 0, g or 0, b or 0, 255
        elseif #hex == 8 then
            local r = tonumber(hex:sub(1,2), 16)
            local g = tonumber(hex:sub(3,4), 16)
            local b = tonumber(hex:sub(5,6), 16)
            local a = tonumber(hex:sub(7,8), 16)
            return r or 0, g or 0, b or 0, a or 255
        end
    end

    -- rgba(r, g, b, a) or rgb(r, g, b)
    local fr, fg, fb, fa = s:match("rgba?%s*%(([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,?%s*([%d%.]*)%)")
    if fr then
        local a = tonumber(fa)
        if a and a <= 1 then a = math_floor(a * 255 + 0.5) end
        return tonumber(fr) or 0, tonumber(fg) or 0, tonumber(fb) or 0, a or 255
    end

    -- Named colors (common subset)
    local named = {
        black   = {0, 0, 0, 255},
        white   = {255, 255, 255, 255},
        red     = {255, 0, 0, 255},
        green   = {0, 128, 0, 255},
        blue    = {0, 0, 255, 255},
        gray    = {128, 128, 128, 255},
        grey    = {128, 128, 128, 255},
        transparent = {0, 0, 0, 0},
    }
    local n = named[s:lower()]
    if n then return n[1], n[2], n[3], n[4] end

    return 0, 0, 0, 128
end

--- Parse a filter value (string or table) into a normalized
--- array of {type=string, value=number, [extra fields]}.
---
--- String format: "blur(4px) grayscale(100%) brightness(1.5)"
--- Table format:  {{type="blur", value=4}, ...}
---
---@param filter_val string|table
---@return table  array of {type, value, ...}
function Filters.parse(filter_val)
    if not filter_val then return {} end

    -- Already a table of filter ops
    if type(filter_val) == "table" then
        -- Validate and normalize
        local out = {}
        for i = 1, #filter_val do
            local f = filter_val[i]
            if type(f) == "table" and f.type then
                out[#out + 1] = f
            end
        end
        return out
    end

    if type(filter_val) ~= "string" then return {} end

    local result = {}
    local s = filter_val

    -- Tokenize with balanced parentheses to handle nested functions
    -- like drop-shadow(2px 2px 4px rgba(0,0,0,0.5))
    local tokens = {}
    local pos = 1
    local len = #s
    while pos <= len do
        -- skip whitespace
        local ws_end = s:find("[^%s]", pos)
        if not ws_end then break end
        pos = ws_end
        -- match function name
        local name_s, name_e, fname = s:find("([%w%-]+)%s*%(", pos)
        if not name_s or name_s ~= pos then break end
        -- find matching closing paren with nesting
        local depth = 1
        local scan = name_e + 1
        while scan <= len and depth > 0 do
            local ch = s:sub(scan, scan)
            if ch == "(" then depth = depth + 1
            elseif ch == ")" then depth = depth - 1 end
            scan = scan + 1
        end
        local args_str = s:sub(name_e + 1, scan - 2)
        tokens[#tokens + 1] = { fname, args_str }
        pos = scan
    end

    for ti = 1, #tokens do
    local name, args = tokens[ti][1], tokens[ti][2]
        local entry = nil

        if name == "blur" then
            local px = tonumber(args:match("([%d%.]+)"))
            if px then
                entry = { type = "blur", value = px }
            end

        elseif name == "grayscale" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "grayscale", value = clamp(v, 0, 1) }
            end

        elseif name == "brightness" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "brightness", value = math_max(0, v) }
            end

        elseif name == "contrast" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "contrast", value = math_max(0, v) }
            end

        elseif name == "saturate" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "saturate", value = math_max(0, v) }
            end

        elseif name == "sepia" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "sepia", value = clamp(v, 0, 1) }
            end

        elseif name == "invert" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "invert", value = clamp(v, 0, 1) }
            end

        elseif name == "opacity" then
            local v, unit = args:match("([%d%.]+)(%%?)")
            v = tonumber(v)
            if v then
                if unit == "%" then v = v / 100 end
                entry = { type = "opacity", value = clamp(v, 0, 1) }
            end

        elseif name == "hue-rotate" then
            local v = tonumber(args:match("([%d%.%-]+)"))
            if v then
                entry = { type = "hue-rotate", value = v }
            end

        elseif name == "drop-shadow" then
            -- drop-shadow(x y blur color)
            -- color is everything after the third number
            local rest = args
            local nums = {}
            local pos = 1
            for _ = 1, 3 do
                local ns, ne, nv = rest:find("([%d%.%-]+)%s*px?%s*", pos)
                if ns then
                    nums[#nums + 1] = tonumber(nv) or 0
                    pos = ne + 1
                else
                    -- Try without px suffix
                    ns, ne, nv = rest:find("([%d%.%-]+)%s*", pos)
                    if ns then
                        nums[#nums + 1] = tonumber(nv) or 0
                        pos = ne + 1
                    end
                end
            end
            local color_str = rest:sub(pos):match("^%s*(.-)%s*$")
            local cr, cg, cb, ca = parse_color(color_str)
            entry = {
                type = "drop-shadow",
                value = 0,
                x = nums[1] or 0,
                y = nums[2] or 0,
                blur = nums[3] or 0,
                color = { cr, cg, cb, ca },
            }
        end

        if entry then
            result[#result + 1] = entry
        end
    end -- for ti

    return result
end

------------------------------------------------------------
-- Color transformation
------------------------------------------------------------

--- Apply a chain of filter operations to a single RGBA color.
--- blur and drop-shadow are skipped (handled at paint level).
---
---@param r number  red   0-255
---@param g number  green 0-255
---@param b number  blue  0-255
---@param a number  alpha 0-255
---@param filters table  array from Filters.parse()
---@return number, number, number, number  modified r, g, b, a
function Filters.apply_color(r, g, b, a, filters)
    if not filters or #filters == 0 then return r, g, b, a end

    for i = 1, #filters do
        local f = filters[i]
        local ft = f.type
        local fv = f.value

        if ft == "grayscale" then
            -- Luminance: 0.2126R + 0.7152G + 0.0722B
            local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = r + (lum - r) * fv
            g = g + (lum - g) * fv
            b = b + (lum - b) * fv

        elseif ft == "brightness" then
            r = r * fv
            g = g * fv
            b = b * fv

        elseif ft == "contrast" then
            -- Adjust around 128 midpoint
            r = (r - 128) * fv + 128
            g = (g - 128) * fv + 128
            b = (b - 128) * fv + 128

        elseif ft == "saturate" then
            local h, s, l = rgb_to_hsl(
                clamp_byte(r), clamp_byte(g), clamp_byte(b))
            s = clamp(s * fv, 0, 1)
            r, g, b = hsl_to_rgb(h, s, l)

        elseif ft == "sepia" then
            -- Sepia matrix (CSS spec)
            local sr = 0.393 * r + 0.769 * g + 0.189 * b
            local sg = 0.349 * r + 0.686 * g + 0.168 * b
            local sb = 0.272 * r + 0.534 * g + 0.131 * b
            -- Blend original → sepia by amount
            r = r + (sr - r) * fv
            g = g + (sg - g) * fv
            b = b + (sb - b) * fv

        elseif ft == "invert" then
            r = r + (255 - 2 * r) * fv
            g = g + (255 - 2 * g) * fv
            b = b + (255 - 2 * b) * fv

        elseif ft == "opacity" then
            a = a * fv

        elseif ft == "hue-rotate" then
            local h, s, l = rgb_to_hsl(
                clamp_byte(r), clamp_byte(g), clamp_byte(b))
            h = (h + fv) % 360
            if h < 0 then h = h + 360 end
            r, g, b = hsl_to_rgb(h, s, l)

        -- blur, drop-shadow: skip (not applicable to single color)
        end
    end

    return clamp_byte(r), clamp_byte(g), clamp_byte(b), clamp_byte(a)
end

------------------------------------------------------------
-- Blur approximation (layered rects)
------------------------------------------------------------

--- Approximate a Gaussian blur by drawing multiple
--- semi-transparent rects at offsets around the element.
--- This is a visual hack -" not a real convolution.
---
--- The approach draws concentric expanding rects with
--- decreasing opacity, simulating light bleeding outward.
---
---@param dl      table   DisplayList instance
---@param x       number  element x
---@param y       number  element y
---@param w       number  element width
---@param h       number  element height
---@param radius  number  blur radius in pixels
---@param r       number  fill color red   0-255
---@param g       number  fill color green 0-255
---@param b       number  fill color blue  0-255
---@param a       number  fill color alpha 0-255
function Filters.apply_blur_rects(dl, x, y, w, h, radius, r, g, b, a)
    if radius <= 0 or a <= 0 then return end

    -- Number of layers scales with radius, capped for performance
    local layers = math_min(math_floor(radius), 12)
    if layers < 1 then layers = 1 end

    -- Each layer expands outward by a step and fades
    local step = radius / layers
    -- Total alpha budget distributed across layers (Gaussian-ish falloff)
    local base_alpha = a / (layers * 1.5)

    for i = layers, 1, -1 do
        local expand = step * i
        local t = i / layers  -- 1.0 at outermost, decreasing inward
        -- Gaussian-like falloff: exp(-2 * t^2) approximated
        local falloff = 1 - t * t
        local layer_a = math_floor(base_alpha * falloff + 0.5)
        if layer_a > 0 then
            dl:rect_fill(
                x - expand,
                y - expand,
                w + expand * 2,
                h + expand * 2,
                r, g, b, layer_a, 0
            )
        end
    end

    -- Center fill at reduced alpha (the "core" of the blur)
    local core_a = math_floor(a * 0.6 + 0.5)
    if core_a > 0 then
        dl:rect_fill(x, y, w, h, r, g, b, core_a, 0)
    end
end

------------------------------------------------------------
-- Drop shadow
------------------------------------------------------------

--- Draw a drop shadow behind an element using layered rects.
--- The shadow is offset by (shadow_x, shadow_y) and blurred.
---
---@param dl       table   DisplayList instance
---@param x        number  element x
---@param y        number  element y
---@param w        number  element width
---@param h        number  element height
---@param shadow_x number  horizontal offset
---@param shadow_y number  vertical offset
---@param blur     number  blur radius
---@param color    table   {r, g, b, a} shadow color (0-255 each)
function Filters.apply_drop_shadow(dl, x, y, w, h, shadow_x, shadow_y, blur, color)
    local sr = (color and color[1]) or 0
    local sg = (color and color[2]) or 0
    local sb = (color and color[3]) or 0
    local sa = (color and color[4]) or 128

    local sx = x + shadow_x
    local sy = y + shadow_y

    if blur <= 0 then
        -- Sharp shadow: single rect
        if sa > 0 then
            dl:rect_fill(sx, sy, w, h, sr, sg, sb, sa, 0)
        end
        return
    end

    -- Blurred shadow: layered expanding rects
    local layers = math_min(math_floor(blur), 10)
    if layers < 1 then layers = 1 end

    local step = blur / layers
    local base_alpha = sa / (layers * 1.8)

    for i = layers, 1, -1 do
        local expand = step * i
        local t = i / layers
        local falloff = 1 - t * t
        local layer_a = math_floor(base_alpha * falloff + 0.5)
        if layer_a > 0 then
            dl:rect_fill(
                sx - expand,
                sy - expand,
                w + expand * 2,
                h + expand * 2,
                sr, sg, sb, layer_a, 0
            )
        end
    end

    -- Core shadow rect
    local core_a = math_floor(sa * 0.5 + 0.5)
    if core_a > 0 then
        dl:rect_fill(sx, sy, w, h, sr, sg, sb, core_a, 0)
    end
end

------------------------------------------------------------
-- Convenience: check if a filter list has paint-level effects
------------------------------------------------------------

--- Returns true if the filter chain contains blur or
--- drop-shadow (effects that need paint-level handling).
---@param filters table  array from Filters.parse()
---@return boolean has_blur, boolean has_shadow
function Filters.has_paint_effects(filters)
    if not filters then return false, false end
    local has_blur = false
    local has_shadow = false
    for i = 1, #filters do
        local ft = filters[i].type
        if ft == "blur" then has_blur = true end
        if ft == "drop-shadow" then has_shadow = true end
    end
    return has_blur, has_shadow
end

--- Extract the first blur radius from a filter chain.
---@param filters table
---@return number  radius (0 if none)
function Filters.get_blur_radius(filters)
    if not filters then return 0 end
    for i = 1, #filters do
        if filters[i].type == "blur" then
            return filters[i].value or 0
        end
    end
    return 0
end

--- Extract the first drop-shadow from a filter chain.
---@param filters table
---@return table|nil  {x, y, blur, color} or nil
function Filters.get_drop_shadow(filters)
    if not filters then return nil end
    for i = 1, #filters do
        local f = filters[i]
        if f.type == "drop-shadow" then
            return {
                x     = f.x or 0,
                y     = f.y or 0,
                blur  = f.blur or 0,
                color = f.color or {0, 0, 0, 128},
            }
        end
    end
    return nil
end

return Filters



