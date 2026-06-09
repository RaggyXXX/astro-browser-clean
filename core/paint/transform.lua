------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / transform.lua
-- Software transform resolution: translate, scale, rotate, skew.
--
-- Uses a 2D affine matrix [a, b, c, d, tx, ty] where:
--   | a  c  tx |     x' = a*x + c*y + tx
--   | b  d  ty |     y' = b*x + d*y + ty
--   | 0  0  1  |
--
-- Always returns a matrix (nil when no transform).
-- Backward compat: dx, dy, sx, sy still returned.
--
-- Transform values: array of operations
--   {{type="translate", x=10, y=20},
--    {type="scale", x=1.5, y=1.5},
--    {type="rotate", deg=45}}
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Transform = {}

local math_cos  = math.cos
local math_sin  = math.sin
local math_pi   = math.pi
local math_tan  = math.tan
local math_abs  = math.abs
local math_sqrt = math.sqrt
local math_min  = math.min
local math_max  = math.max

------------------------------------------------------------
-- 2D affine matrix helpers
------------------------------------------------------------

local IDENTITY = { 1, 0, 0, 1, 0, 0 }

--- Identity matrix.
function Transform.identity()
    return { 1, 0, 0, 1, 0, 0 }
end

--- Multiply two 2D affine matrices: result = A * B.
---@param a table  [a, b, c, d, tx, ty]
---@param b table  [a, b, c, d, tx, ty]
---@return table
function Transform.mul(a, b)
    return {
        a[1]*b[1] + a[3]*b[2],          -- a
        a[2]*b[1] + a[4]*b[2],          -- b
        a[1]*b[3] + a[3]*b[4],          -- c
        a[2]*b[3] + a[4]*b[4],          -- d
        a[1]*b[5] + a[3]*b[6] + a[5],  -- tx
        a[2]*b[5] + a[4]*b[6] + a[6],  -- ty
    }
end

local mat_mul = Transform.mul

--- Translation matrix.
local function mat_translate(tx, ty)
    return { 1, 0, 0, 1, tx, ty }
end

--- Scale matrix.
local function mat_scale(sx, sy)
    return { sx, 0, 0, sy, 0, 0 }
end

--- Rotation matrix (degrees).
local function mat_rotate(deg)
    local rad = deg * math_pi / 180
    local c = math_cos(rad)
    local s = math_sin(rad)
    return { c, s, -s, c, 0, 0 }
end

--- SkewX matrix (degrees).
local function mat_skew_x(deg)
    local rad = deg * math_pi / 180
    return { 1, 0, math_tan(rad), 1, 0, 0 }
end

--- SkewY matrix (degrees).
local function mat_skew_y(deg)
    local rad = deg * math_pi / 180
    return { 1, math_tan(rad), 0, 1, 0, 0 }
end

--- Apply matrix to a point.
---@param m  table   affine matrix
---@param px number  x coordinate
---@param py number  y coordinate
---@return number, number
function Transform.apply_point(m, px, py)
    return m[1]*px + m[3]*py + m[5],
           m[2]*px + m[4]*py + m[6]
end

--- Check if matrix has rotation (non-axis-aligned).
---@param m table  affine matrix
---@return boolean
function Transform.has_rotation(m)
    return math_abs(m[2]) > 0.0001 or math_abs(m[3]) > 0.0001
end

--- Check if matrix is (near-)identity.
function Transform.is_identity(m)
    return math_abs(m[1] - 1) < 0.0001
       and math_abs(m[2]) < 0.0001
       and math_abs(m[3]) < 0.0001
       and math_abs(m[4] - 1) < 0.0001
       and math_abs(m[5]) < 0.0001
       and math_abs(m[6]) < 0.0001
end

--- Check if matrix is singular (non-invertible).
function Transform.is_singular(m)
    local det = m[1] * m[4] - m[2] * m[3]
    return math_abs(det) < 0.0001
end

------------------------------------------------------------
-- Transform resolution
------------------------------------------------------------

--- Resolve a transform value into a 2D affine matrix.
--- Also returns dx, dy, sx, sy for backward compat.
---@param value     any     transform value (array of ops, single op, or nil)
---@param origin_x  number  transform-origin X relative to element
---@param origin_y  number  transform-origin Y relative to element
---@return number dx, number dy, number sx, number sy, table|nil matrix
function Transform.resolve(value, origin_x, origin_y)
    origin_x = origin_x or 0
    origin_y = origin_y or 0

    if not value then
        return 0, 0, 1, 1, nil
    end

    -- Single operation table with type field
    if type(value) == "table" and value.type then
        value = { value }
    end

    if type(value) ~= "table" then
        return 0, 0, 1, 1, nil
    end

    local m = Transform.identity()

    for i = 1, #value do
        local op = value[i]
        if type(op) == "table" then
            if op.type == "translate" then
                m = mat_mul(m, mat_translate(op.x or 0, op.y or 0))
            elseif op.type == "scale" then
                local new_sx = op.x or op.v or 1
                local new_sy = op.y or op.v or new_sx
                m = mat_mul(m, mat_translate(origin_x, origin_y))
                m = mat_mul(m, mat_scale(new_sx, new_sy))
                m = mat_mul(m, mat_translate(-origin_x, -origin_y))
            elseif op.type == "rotate" then
                local deg = op.deg or op.v or 0
                m = mat_mul(m, mat_translate(origin_x, origin_y))
                m = mat_mul(m, mat_rotate(deg))
                m = mat_mul(m, mat_translate(-origin_x, -origin_y))
            elseif op.type == "skewX" or op.type == "skew_x" then
                local deg = op.deg or op.v or 0
                m = mat_mul(m, mat_translate(origin_x, origin_y))
                m = mat_mul(m, mat_skew_x(deg))
                m = mat_mul(m, mat_translate(-origin_x, -origin_y))
            elseif op.type == "skewY" or op.type == "skew_y" then
                local deg = op.deg or op.v or 0
                m = mat_mul(m, mat_translate(origin_x, origin_y))
                m = mat_mul(m, mat_skew_y(deg))
                m = mat_mul(m, mat_translate(-origin_x, -origin_y))
            elseif op.type == "skew" then
                local dx = op.x or op.v or 0
                local dy = op.y or 0
                m = mat_mul(m, mat_translate(origin_x, origin_y))
                m = mat_mul(m, mat_skew_x(dx))
                if dy ~= 0 then
                    m = mat_mul(m, mat_skew_y(dy))
                end
                m = mat_mul(m, mat_translate(-origin_x, -origin_y))
            end
        end
    end

    -- If identity, return nil matrix (no transform)
    if Transform.is_identity(m) then
        return 0, 0, 1, 1, nil
    end

    -- Extract dx, dy, sx, sy for backward compat
    local dx = m[5]
    local dy = m[6]
    local sx = math_sqrt(m[1]*m[1] + m[2]*m[2])
    local sy = math_sqrt(m[3]*m[3] + m[4]*m[4])

    return dx, dy, sx, sy, m
end

--- Invert an affine matrix.  Returns nil if singular.
---@param m table  affine matrix
---@return table|nil
function Transform.invert(m)
    local a, b, c, d, tx, ty = m[1], m[2], m[3], m[4], m[5], m[6]
    local det = a * d - b * c
    if math_abs(det) < 0.0001 then return nil end
    local inv_det = 1 / det
    return {
         d * inv_det,
        -b * inv_det,
        -c * inv_det,
         a * inv_det,
        -(d * inv_det * tx + (-c * inv_det) * ty),
        -((-b * inv_det) * tx + a * inv_det * ty),
    }
end

--- Apply inverse transform to mouse coordinates for hit testing.
--- Supports full affine matrix (rotate + scale + translate).
---@param mx       number  mouse X
---@param my       number  mouse Y
---@param elem_x   number  element X
---@param elem_y   number  element Y
---@param dx       number  transform dx (unused if matrix provided)
---@param dy       number  transform dy (unused if matrix provided)
---@param sx       number  transform sx (unused if matrix provided)
---@param sy       number  transform sy (unused if matrix provided)
---@param matrix   table|nil  optional affine matrix
---@return number, number  transformed mouse coords
function Transform.inverse(mx, my, elem_x, elem_y, dx, dy, sx, sy, matrix)
    if matrix then
        local inv = Transform.invert(matrix)
        if not inv then
            -- Singular: can't hit-test, return far offscreen
            return -99999, -99999
        end
        local lx = mx - elem_x
        local ly = my - elem_y
        return elem_x + inv[1] * lx + inv[3] * ly + inv[5],
               elem_y + inv[2] * lx + inv[4] * ly + inv[6]
    end

    -- Legacy path: simple translate + scale
    if sx == 0 then sx = 0.001 end
    if sy == 0 then sy = 0.001 end

    local inv_x = elem_x + (mx - elem_x - dx) / sx
    local inv_y = elem_y + (my - elem_y - dy) / sy

    return inv_x, inv_y
end

--- Compute the 4 rotated corners of a rectangle.
--- Matrix transforms local-space (0,0)-(w,h), then offset by (x,y).
---@param m  table   affine matrix
---@param x  number  element x
---@param y  number  element y
---@param w  number  width
---@param h  number  height
---@return number, number, number, number, number, number, number, number
function Transform.rotated_corners(m, x, y, w, h)
    local x1, y1 = Transform.apply_point(m, 0, 0)
    local x2, y2 = Transform.apply_point(m, w, 0)
    local x3, y3 = Transform.apply_point(m, w, h)
    local x4, y4 = Transform.apply_point(m, 0, h)
    return x + x1, y + y1, x + x2, y + y2,
           x + x3, y + y3, x + x4, y + y4
end

--- Get axis-aligned bounding box of 4 points.
---@return number, number, number, number  (x, y, w, h)
function Transform.aabb(x1, y1, x2, y2, x3, y3, x4, y4)
    local mn_x = math_min(x1, x2, x3, x4)
    local mn_y = math_min(y1, y2, y3, y4)
    local mx_x = math_max(x1, x2, x3, x4)
    local mx_y = math_max(y1, y2, y3, y4)
    return mn_x, mn_y, mx_x - mn_x, mx_y - mn_y
end

return Transform



