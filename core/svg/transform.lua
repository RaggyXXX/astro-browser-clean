------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / transform.lua
-- 2D affine matrix operations for SVG transforms.
-- Matrix: {a, b, c, d, e, f} representing:
--   | a c e |
--   | b d f |
--   | 0 0 1 |
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgTransform = {}

local math_cos  = math.cos
local math_sin  = math.sin
local math_rad  = math.rad
local math_pi   = math.pi

------------------------------------------------------------
-- Matrix constructors
------------------------------------------------------------

function SvgTransform.identity()
    return { 1, 0, 0, 1, 0, 0 }
end

function SvgTransform.translate(tx, ty)
    return { 1, 0, 0, 1, tx or 0, ty or 0 }
end

function SvgTransform.scale(sx, sy)
    sy = sy or sx
    return { sx, 0, 0, sy, 0, 0 }
end

function SvgTransform.rotate(deg, cx, cy)
    cx = cx or 0
    cy = cy or 0
    local r = math_rad(deg)
    local c = math_cos(r)
    local s = math_sin(r)
    if cx == 0 and cy == 0 then
        return { c, s, -s, c, 0, 0 }
    end
    -- translate(cx,cy) * rotate(deg) * translate(-cx,-cy)
    return {
        c, s, -s, c,
        cx - c * cx + s * cy,
        cy - s * cx - c * cy,
    }
end

function SvgTransform.skewX(deg)
    local t = math.tan(math_rad(deg))
    return { 1, 0, t, 1, 0, 0 }
end

function SvgTransform.skewY(deg)
    local t = math.tan(math_rad(deg))
    return { 1, t, 0, 1, 0, 0 }
end

------------------------------------------------------------
-- Matrix operations
------------------------------------------------------------

--- Multiply two affine matrices: result = A * B
function SvgTransform.mul(a, b)
    return {
        a[1]*b[1] + a[3]*b[2],
        a[2]*b[1] + a[4]*b[2],
        a[1]*b[3] + a[3]*b[4],
        a[2]*b[3] + a[4]*b[4],
        a[1]*b[5] + a[3]*b[6] + a[5],
        a[2]*b[5] + a[4]*b[6] + a[6],
    }
end

--- Apply matrix to a point.
function SvgTransform.apply(m, x, y)
    return m[1]*x + m[3]*y + m[5],
           m[2]*x + m[4]*y + m[6]
end

--- Get the uniform scale factor (average of x/y scale).
function SvgTransform.get_scale(m)
    local sx = math.sqrt(m[1]*m[1] + m[2]*m[2])
    local sy = math.sqrt(m[3]*m[3] + m[4]*m[4])
    return (sx + sy) * 0.5
end

------------------------------------------------------------
-- Parse SVG transform attribute string
------------------------------------------------------------

--- Extract numbers from a string like "10, 20", ".5", or "1e-3".
function SvgTransform.extract_numbers(s)
    local nums = {}
    local i = 1
    local len = #(s or "")
    while i <= len do
        local _, e, n = s:find("^%s*([%+%-]?%d+%.?%d*[eE][%+%-]?%d+)", i)
        if not n then _, e, n = s:find("^%s*([%+%-]?%.%d+[eE][%+%-]?%d+)", i) end
        if not n then _, e, n = s:find("^%s*([%+%-]?%d+%.?%d*)", i) end
        if not n then _, e, n = s:find("^%s*([%+%-]?%.%d+)", i) end
        if n then
            nums[#nums + 1] = tonumber(n) or 0
            i = e + 1
        else
            i = i + 1
        end
    end
    return nums
end

--- Parse an SVG transform attribute string.
--- Supports: translate, scale, rotate, skewX, skewY, matrix.
--- Multiple transforms are concatenated left-to-right (per SVG spec).
---@param str string  SVG transform attribute value
---@return table  Affine matrix {a,b,c,d,e,f}
function SvgTransform.parse(str)
    if not str or str == "" then
        return SvgTransform.identity()
    end

    local result = SvgTransform.identity()

    for fn, args in str:gmatch("(%a+)%s*%(([^%)]+)%)") do
        local n = SvgTransform.extract_numbers(args)
        local m

        if fn == "translate" then
            if #n >= 1 then m = SvgTransform.translate(n[1], n[2] or 0) end
        elseif fn == "scale" then
            if #n >= 1 then m = SvgTransform.scale(n[1], n[2]) end
        elseif fn == "rotate" then
            if #n == 1 then
                m = SvgTransform.rotate(n[1])
            elseif #n >= 3 then
                m = SvgTransform.rotate(n[1], n[2], n[3])
            end
        elseif fn == "skewX" then
            if #n >= 1 then m = SvgTransform.skewX(n[1]) end
        elseif fn == "skewY" then
            if #n >= 1 then m = SvgTransform.skewY(n[1]) end
        elseif fn == "matrix" then
            if #n >= 6 then
                m = { n[1], n[2], n[3], n[4], n[5], n[6] }
            end
        end

        if m then
            result = SvgTransform.mul(result, m)
        end
    end

    return result
end

return SvgTransform



