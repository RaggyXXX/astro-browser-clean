------------------------------------------------------------
-- ext_core_astro_ui_lib / core / icons / svg_path_parser.lua
-- Parse SVG path `d` attribute into polylines.
--
-- Converts SVG path commands (M, L, H, V, C, S, Q, T, A, Z)
-- into arrays of {x=, y=} points, the same format used by
-- the scanline rasterizer. Curves are adaptively flattened
-- via De Casteljau subdivision.
--
-- Supports: all absolute and relative path commands.
-- Fill rule: nonzero winding (matches rasterizer).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgPathParser = {}

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local math_ceil  = math.ceil
local math_abs   = math.abs
local math_sqrt  = math.sqrt
local math_cos   = math.cos
local math_sin   = math.sin
local math_acos  = math.acos
local math_atan2 = math.atan2 or math.atan
local math_pi    = math.pi
local math_min   = math.min
local math_max   = math.max
local str_byte   = string.byte
local str_sub    = string.sub

------------------------------------------------------------
-- Curve flattening (copied from ttf_parser.lua)
------------------------------------------------------------

--- Flatten a quadratic Bezier curve into line segments.
---@param p0x number  Start X
---@param p0y number  Start Y
---@param cpx number  Control point X
---@param cpy number  Control point Y
---@param p1x number  End X
---@param p1y number  End Y
---@param out table   Output array; points appended as {x=, y=}
---@param tol number  Flatness tolerance
---@param depth number? Max recursion depth
local function flatten_quad(p0x, p0y, cpx, cpy, p1x, p1y, out, tol, depth)
    if not depth then depth = 16 end
    if depth <= 0 then
        out[#out + 1] = { x = p1x, y = p1y }
        return
    end

    local mx = (p0x + p1x) * 0.5
    local my = (p0y + p1y) * 0.5
    local dx = cpx - mx
    local dy = cpy - my
    if dx * dx + dy * dy <= tol * tol then
        out[#out + 1] = { x = p1x, y = p1y }
        return
    end

    local q0x = (p0x + cpx) * 0.5
    local q0y = (p0y + cpy) * 0.5
    local q1x = (cpx + p1x) * 0.5
    local q1y = (cpy + p1y) * 0.5
    local rx  = (q0x + q1x) * 0.5
    local ry  = (q0y + q1y) * 0.5

    flatten_quad(p0x, p0y, q0x, q0y, rx, ry, out, tol, depth - 1)
    flatten_quad(rx, ry, q1x, q1y, p1x, p1y, out, tol, depth - 1)
end

--- Flatten a cubic Bezier curve into line segments.
---@param p0x number  Start X
---@param p0y number  Start Y
---@param c1x number  First control X
---@param c1y number  First control Y
---@param c2x number  Second control X
---@param c2y number  Second control Y
---@param p1x number  End X
---@param p1y number  End Y
---@param out table   Output array; points appended as {x=, y=}
---@param tol number  Flatness tolerance
---@param depth number? Max recursion depth
local function flatten_cubic(p0x, p0y, c1x, c1y, c2x, c2y, p1x, p1y, out, tol, depth)
    if not depth then depth = 16 end
    if depth <= 0 then
        out[#out + 1] = { x = p1x, y = p1y }
        return
    end

    local dx = p1x - p0x
    local dy = p1y - p0y
    local d2 = dx * dx + dy * dy
    local tol2 = tol * tol

    if d2 < 1e-10 then
        local e1 = (c1x - p0x) * (c1x - p0x) + (c1y - p0y) * (c1y - p0y)
        local e2 = (c2x - p0x) * (c2x - p0x) + (c2y - p0y) * (c2y - p0y)
        if e1 <= tol2 and e2 <= tol2 then
            out[#out + 1] = { x = p1x, y = p1y }
            return
        end
    else
        local cross1 = (c1x - p0x) * dy - (c1y - p0y) * dx
        local cross2 = (c2x - p0x) * dy - (c2y - p0y) * dx
        if (cross1 * cross1 + cross2 * cross2) / d2 <= tol2 then
            out[#out + 1] = { x = p1x, y = p1y }
            return
        end
    end

    local m01x = (p0x + c1x) * 0.5;  local m01y = (p0y + c1y) * 0.5
    local m12x = (c1x + c2x) * 0.5;  local m12y = (c1y + c2y) * 0.5
    local m23x = (c2x + p1x) * 0.5;  local m23y = (c2y + p1y) * 0.5
    local m012x = (m01x + m12x) * 0.5; local m012y = (m01y + m12y) * 0.5
    local m123x = (m12x + m23x) * 0.5; local m123y = (m12y + m23y) * 0.5
    local mx = (m012x + m123x) * 0.5;  local my = (m012y + m123y) * 0.5

    flatten_cubic(p0x, p0y, m01x, m01y, m012x, m012y, mx, my, out, tol, depth - 1)
    flatten_cubic(mx, my, m123x, m123y, m23x, m23y, p1x, p1y, out, tol, depth - 1)
end

------------------------------------------------------------
-- Arc conversion (endpoint → center parameterization)
-- Per W3C SVG spec F.6.5-6.6
------------------------------------------------------------

--- Convert an SVG arc to line segments.
---@param x1 number  Start X
---@param y1 number  Start Y
---@param rx number  X radius
---@param ry number  Y radius
---@param phi number  X-axis rotation in radians
---@param fa number  Large-arc flag (0 or 1)
---@param fs number  Sweep flag (0 or 1)
---@param x2 number  End X
---@param y2 number  End Y
---@param out table  Output array
---@param tol number Flatness tolerance
local function flatten_arc(x1, y1, rx, ry, phi, fa, fs, x2, y2, out, tol)
    -- Degenerate: zero radius → line
    if rx == 0 or ry == 0 then
        out[#out + 1] = { x = x2, y = y2 }
        return
    end

    -- Degenerate: same start and end
    local ddx = x2 - x1
    local ddy = y2 - y1
    if ddx * ddx + ddy * ddy < 1e-10 then
        return
    end

    rx = math_abs(rx)
    ry = math_abs(ry)

    local cos_phi = math_cos(phi)
    local sin_phi = math_sin(phi)

    -- F.6.5.1: compute (x1', y1')
    local dx2 = (x1 - x2) * 0.5
    local dy2 = (y1 - y2) * 0.5
    local x1p =  cos_phi * dx2 + sin_phi * dy2
    local y1p = -sin_phi * dx2 + cos_phi * dy2

    -- F.6.6.2: ensure radii are large enough
    local x1p2 = x1p * x1p
    local y1p2 = y1p * y1p
    local rx2 = rx * rx
    local ry2 = ry * ry
    local lambda = x1p2 / rx2 + y1p2 / ry2
    if lambda > 1 then
        local sl = math_sqrt(lambda)
        rx = rx * sl
        ry = ry * sl
        rx2 = rx * rx
        ry2 = ry * ry
    end

    -- F.6.5.2: compute (cx', cy')
    local num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2
    local den = rx2 * y1p2 + ry2 * x1p2
    local sq = 0
    if den > 0 then
        sq = num / den
        if sq < 0 then sq = 0 end
        sq = math_sqrt(sq)
    end
    if fa == fs then sq = -sq end
    local cxp =  sq * rx * y1p / ry
    local cyp = -sq * ry * x1p / rx

    -- F.6.5.3: compute (cx, cy) from (cx', cy')
    local cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) * 0.5
    local cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) * 0.5

    -- F.6.5.5-6: compute theta1 and dtheta
    local ux = (x1p - cxp) / rx
    local uy = (y1p - cyp) / ry
    local vx = (-x1p - cxp) / rx
    local vy = (-y1p - cyp) / ry

    -- Angle of vector (1,0) to (ux, uy)
    local theta1 = math_atan2(uy, ux)

    -- Angle between (ux,uy) and (vx,vy)
    local n2 = math_sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
    local dp = ux * vx + uy * vy
    local cos_dt = dp / (n2 > 0 and n2 or 1)
    if cos_dt < -1 then cos_dt = -1 end
    if cos_dt >  1 then cos_dt =  1 end
    local dtheta = math_acos(cos_dt)
    if ux * vy - uy * vx < 0 then dtheta = -dtheta end

    -- Adjust dtheta for sweep direction
    if fs == 1 and dtheta < 0 then
        dtheta = dtheta + 2 * math_pi
    elseif fs == 0 and dtheta > 0 then
        dtheta = dtheta - 2 * math_pi
    end

    -- Discretize arc to line segments
    -- Use proper arc tessellation: max deviation = r*(1 - cos(step/2)) < tol
    local r_max = math_max(rx, ry)
    local n_segs
    if r_max > 1e-6 and tol < r_max then
        local max_step = 2 * math_acos(1 - math_min(tol, r_max) / r_max)
        n_segs = math_max(math_ceil(math_abs(dtheta) / max_step), 4)
    else
        n_segs = math_max(math_ceil(math_abs(dtheta) / (math_pi * 0.25)), 4)
    end
    local step = dtheta / n_segs

    for i = 1, n_segs do
        local theta = theta1 + step * i
        local cos_t = math_cos(theta)
        local sin_t = math_sin(theta)
        local px = cos_phi * rx * cos_t - sin_phi * ry * sin_t + cx
        local py = sin_phi * rx * cos_t + cos_phi * ry * sin_t + cy
        out[#out + 1] = { x = px, y = py }
    end
end

------------------------------------------------------------
-- Tokenizer
------------------------------------------------------------

-- Character classification
local function is_cmd(c)
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
end

local function is_digit(c)
    return c >= 48 and c <= 57
end

local function is_ws(c)
    return c == 32 or c == 9 or c == 10 or c == 13 or c == 44 -- space/tab/nl/cr/comma
end

--- Tokenize an SVG path `d` string.
--- Returns array of tokens: each is either a string (command letter)
--- or a number (coordinate/parameter value).
---@param d string  SVG path data
---@return table tokens
local function tokenize(d)
    local tokens = {}
    local tn = 0
    local len = #d
    local i = 1

    while i <= len do
        local c = str_byte(d, i)

        -- Skip whitespace and commas
        if is_ws(c) then
            i = i + 1

        -- Command letter
        elseif is_cmd(c) then
            tn = tn + 1
            tokens[tn] = str_sub(d, i, i)
            i = i + 1

        -- Number (sign, digits, dot, exponent)
        elseif is_digit(c) or c == 45 or c == 43 or c == 46 then
            local start = i
            -- Optional sign
            if c == 45 or c == 43 then
                i = i + 1
                if i > len then break end
                c = str_byte(d, i)
            end
            -- Integer part
            while i <= len and is_digit(str_byte(d, i)) do
                i = i + 1
            end
            -- Fractional part
            if i <= len and str_byte(d, i) == 46 then
                i = i + 1
                while i <= len and is_digit(str_byte(d, i)) do
                    i = i + 1
                end
            end
            -- Exponent
            if i <= len then
                local ec = str_byte(d, i)
                if ec == 101 or ec == 69 then -- 'e' or 'E'
                    i = i + 1
                    if i <= len then
                        ec = str_byte(d, i)
                        if ec == 45 or ec == 43 then i = i + 1 end
                    end
                    while i <= len and is_digit(str_byte(d, i)) do
                        i = i + 1
                    end
                end
            end
            local num = tonumber(str_sub(d, start, i - 1))
            if num then
                tn = tn + 1
                tokens[tn] = num
            end

            -- Handle implicit separator: if next char starts a new number
            -- (digit after no separator, or dot-dot, or sign-as-separator)
            -- The while loop naturally handles this since we re-enter.

        else
            -- Skip unknown characters
            i = i + 1
        end
    end

    return tokens
end

------------------------------------------------------------
-- Command processor
------------------------------------------------------------

--- Parse SVG path `d` string into polylines.
---
--- Returns an array of polylines in the same format used by
--- the scanline rasterizer: { { {x=,y=}, ... }, ... }
---
---@param d string   SVG path data string
---@param tol number? Flatness tolerance for curve flattening (default 0.5)
---@return table polylines
function SvgPathParser.parse(d, tol)
    tol = tol or 0.5

    local tokens = tokenize(d)
    local nt = #tokens
    if nt == 0 then return {} end

    local polylines = {}
    local cur_poly = nil  -- current polyline being built
    local cur_x, cur_y = 0, 0
    local start_x, start_y = 0, 0  -- subpath start (for Z)
    local last_cmd = nil  -- for S/T reflected control points
    local last_cx, last_cy = 0, 0  -- last control point

    local ti = 1  -- token index

    local function next_num()
        if ti > nt then return nil end
        local v = tokens[ti]
        if type(v) ~= "number" then return nil end
        ti = ti + 1
        return v
    end

    -- Arc flags (0 or 1) can be concatenated with subsequent numbers
    -- in compressed SVG paths, e.g. "0125" = flag 0, flag 1, number 25.
    -- This helper reads a single flag, splitting if needed.
    local _split_num = nil  -- pending number from flag split
    local function next_flag()
        if _split_num then
            -- We already split off a flag; consume the remainder
            local v = _split_num
            _split_num = nil
            -- v itself might be "1xx" -" extract flag, push rest back
            if v == 0 or v == 1 then return v end
            -- Multi-digit: first digit is the flag
            local s = tostring(v)
            local flag = tonumber(s:sub(1, 1))
            local rest = tonumber(s:sub(2))
            if rest then _split_num = rest end
            return flag
        end
        if ti > nt then return nil end
        local v = tokens[ti]
        if type(v) ~= "number" then return nil end
        ti = ti + 1
        -- Check if this number is just 0 or 1
        if v == 0 or v == 1 then return v end
        -- Multi-digit number starting with 0 or 1: split off the flag
        local s = tostring(v)
        local first = s:sub(1, 1)
        if first == "0" or first == "1" then
            local flag = tonumber(first)
            local rest = tonumber(s:sub(2))
            if rest then _split_num = rest end
            return flag
        end
        -- Not a valid flag, return as-is (will be treated as flag value)
        return v
    end

    -- Read next number, but check _split_num first (from flag splitting)
    local function next_arc_num()
        if _split_num then
            local v = _split_num
            _split_num = nil
            return v
        end
        return next_num()
    end

    local function ensure_poly()
        if not cur_poly then
            cur_poly = { { x = cur_x, y = cur_y } }
            polylines[#polylines + 1] = cur_poly
        end
    end

    local function close_poly()
        if cur_poly and #cur_poly >= 2 then
            -- Explicitly append start point so stroke expansion can detect closure
            local p1 = cur_poly[1]
            local pn = cur_poly[#cur_poly]
            if p1.x ~= pn.x or p1.y ~= pn.y then
                cur_poly[#cur_poly + 1] = { x = p1.x, y = p1.y }
            end
        end
        cur_poly = nil
        cur_x = start_x
        cur_y = start_y
    end

    while ti <= nt do
        local tok = tokens[ti]

        if type(tok) == "string" then
            ti = ti + 1
            local cmd = tok
            local rel = (cmd >= "a" and cmd <= "z")
            local CMD = cmd:upper()

            if CMD == "M" then
                -- MoveTo
                local x = next_num()
                local y = next_num()
                if not x or not y then break end

                if rel then x = x + cur_x; y = y + cur_y end
                cur_x = x; cur_y = y
                start_x = x; start_y = y
                cur_poly = { { x = cur_x, y = cur_y } }
                polylines[#polylines + 1] = cur_poly

                -- Subsequent coordinate pairs are implicit LineTo
                while true do
                    x = next_num()
                    y = next_num()
                    if not x or not y then break end
                    if rel then x = x + cur_x; y = y + cur_y end
                    cur_x = x; cur_y = y
                    cur_poly[#cur_poly + 1] = { x = cur_x, y = cur_y }
                end
                last_cmd = "M"

            elseif CMD == "L" then
                -- LineTo
                while true do
                    local x = next_num()
                    local y = next_num()
                    if not x or not y then break end
                    if rel then x = x + cur_x; y = y + cur_y end
                    cur_x = x; cur_y = y
                    ensure_poly()
                    cur_poly[#cur_poly + 1] = { x = cur_x, y = cur_y }
                end
                last_cmd = "L"

            elseif CMD == "H" then
                -- Horizontal LineTo
                while true do
                    local x = next_num()
                    if not x then break end
                    if rel then x = x + cur_x end
                    cur_x = x
                    ensure_poly()
                    cur_poly[#cur_poly + 1] = { x = cur_x, y = cur_y }
                end
                last_cmd = "H"

            elseif CMD == "V" then
                -- Vertical LineTo
                while true do
                    local y = next_num()
                    if not y then break end
                    if rel then y = y + cur_y end
                    cur_y = y
                    ensure_poly()
                    cur_poly[#cur_poly + 1] = { x = cur_x, y = cur_y }
                end
                last_cmd = "V"

            elseif CMD == "C" then
                -- Cubic Bezier
                while true do
                    local c1x = next_num(); local c1y = next_num()
                    local c2x = next_num(); local c2y = next_num()
                    local ex  = next_num(); local ey  = next_num()
                    if not c1x or not c1y or not c2x or not c2y or not ex or not ey then break end
                    if rel then
                        c1x = c1x + cur_x; c1y = c1y + cur_y
                        c2x = c2x + cur_x; c2y = c2y + cur_y
                        ex  = ex  + cur_x; ey  = ey  + cur_y
                    end
                    ensure_poly()
                    flatten_cubic(cur_x, cur_y, c1x, c1y, c2x, c2y, ex, ey, cur_poly, tol)
                    last_cx = c2x; last_cy = c2y
                    cur_x = ex; cur_y = ey
                end
                last_cmd = "C"

            elseif CMD == "S" then
                -- Smooth cubic Bezier (reflected control point)
                while true do
                    local c2x = next_num(); local c2y = next_num()
                    local ex  = next_num(); local ey  = next_num()
                    if not c2x or not c2y or not ex or not ey then break end
                    if rel then
                        c2x = c2x + cur_x; c2y = c2y + cur_y
                        ex  = ex  + cur_x; ey  = ey  + cur_y
                    end
                    -- Reflect last control point
                    local c1x, c1y
                    if last_cmd == "C" or last_cmd == "S" then
                        c1x = 2 * cur_x - last_cx
                        c1y = 2 * cur_y - last_cy
                    else
                        c1x = cur_x
                        c1y = cur_y
                    end
                    ensure_poly()
                    flatten_cubic(cur_x, cur_y, c1x, c1y, c2x, c2y, ex, ey, cur_poly, tol)
                    last_cx = c2x; last_cy = c2y
                    cur_x = ex; cur_y = ey
                    last_cmd = "S"
                end

            elseif CMD == "Q" then
                -- Quadratic Bezier
                while true do
                    local cpx = next_num(); local cpy = next_num()
                    local ex  = next_num(); local ey  = next_num()
                    if not cpx or not cpy or not ex or not ey then break end
                    if rel then
                        cpx = cpx + cur_x; cpy = cpy + cur_y
                        ex  = ex  + cur_x; ey  = ey  + cur_y
                    end
                    ensure_poly()
                    flatten_quad(cur_x, cur_y, cpx, cpy, ex, ey, cur_poly, tol)
                    last_cx = cpx; last_cy = cpy
                    cur_x = ex; cur_y = ey
                end
                last_cmd = "Q"

            elseif CMD == "T" then
                -- Smooth quadratic Bezier (reflected control point)
                while true do
                    local ex = next_num(); local ey = next_num()
                    if not ex or not ey then break end
                    if rel then
                        ex = ex + cur_x; ey = ey + cur_y
                    end
                    local cpx, cpy
                    if last_cmd == "Q" or last_cmd == "T" then
                        cpx = 2 * cur_x - last_cx
                        cpy = 2 * cur_y - last_cy
                    else
                        cpx = cur_x
                        cpy = cur_y
                    end
                    ensure_poly()
                    flatten_quad(cur_x, cur_y, cpx, cpy, ex, ey, cur_poly, tol)
                    last_cx = cpx; last_cy = cpy
                    cur_x = ex; cur_y = ey
                    last_cmd = "T"
                end

            elseif CMD == "A" then
                -- Arc (uses flag-aware readers for large-arc and sweep flags)
                while true do
                    local arx = next_arc_num()
                    local ary = next_arc_num()
                    local rotation = next_arc_num()
                    local large_arc = next_flag()
                    local sweep = next_flag()
                    local ex = next_arc_num()
                    local ey = next_arc_num()
                    if not arx or not ary or not rotation or not large_arc or not sweep or not ex or not ey then break end
                    if rel then
                        ex = ex + cur_x; ey = ey + cur_y
                    end
                    ensure_poly()
                    local phi = rotation * math_pi / 180
                    local fa = (large_arc ~= 0) and 1 or 0
                    local fs = (sweep ~= 0) and 1 or 0
                    flatten_arc(cur_x, cur_y, arx, ary, phi, fa, fs, ex, ey, cur_poly, tol)
                    cur_x = ex; cur_y = ey
                end
                last_cmd = "A"

            elseif CMD == "Z" then
                close_poly()
                last_cmd = "Z"
            end
        else
            -- Bare number without preceding command -" skip
            ti = ti + 1
        end
    end

    return polylines
end

return SvgPathParser



