------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / viewbox.lua
-- SVG viewBox parsing and viewport mapping.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgTransform = require("core/svg/transform")

local Viewbox = {}

local math_min = math.min
local math_max = math.max

--- Parse a viewBox string "minX minY width height".
---@param str string|nil
---@return table|nil  {x, y, w, h}
function Viewbox.parse(str)
    if not str then return nil end
    local nums = SvgTransform.extract_numbers(str)
    if #nums < 4 then return nil end
    return { x = nums[1], y = nums[2], w = nums[3], h = nums[4] }
end

--- Compute the affine matrix that maps viewBox coordinates
--- into the viewport (layout content rect).
--- Default: preserveAspectRatio = "xMidYMid meet" (Chrome default).
---@param vp_x number  Viewport X (content_x)
---@param vp_y number  Viewport Y (content_y)
---@param vp_w number  Viewport width (content_w)
---@param vp_h number  Viewport height (content_h)
---@param vb  table    {x, y, w, h} from parse()
---@param par string|nil  preserveAspectRatio value (optional)
---@return table  Affine matrix {a,b,c,d,e,f}
function Viewbox.compute_matrix(vp_x, vp_y, vp_w, vp_h, vb, par)
    if not vb or vb.w <= 0 or vb.h <= 0 then
        -- No viewBox: identity + viewport offset
        return { 1, 0, 0, 1, vp_x, vp_y }
    end

    par = par or "xMidYMid meet"

    -- Check for "none"
    if par == "none" then
        local sx = vp_w / vb.w
        local sy = vp_h / vb.h
        local tx = vp_x - vb.x * sx
        local ty = vp_y - vb.y * sy
        return { sx, 0, 0, sy, tx, ty }
    end

    -- Parse alignment and meet/slice
    local align = par:match("^(%a+)")
    local meet_slice = par:match("(%a+)$")
    if meet_slice ~= "slice" then meet_slice = "meet" end

    local sx = vp_w / vb.w
    local sy = vp_h / vb.h

    local s
    if meet_slice == "meet" then
        s = math_min(sx, sy)
    else
        s = math_max(sx, sy)
    end

    -- Scaled viewBox size
    local scaled_w = vb.w * s
    local scaled_h = vb.h * s

    -- Alignment offsets
    local tx, ty = 0, 0

    -- X alignment
    if align == "xMidYMid" or align == "xMidYMin" or align == "xMidYMax" then
        tx = (vp_w - scaled_w) * 0.5
    elseif align == "xMaxYMid" or align == "xMaxYMin" or align == "xMaxYMax" then
        tx = vp_w - scaled_w
    end
    -- else xMin: tx = 0

    -- Y alignment
    if align == "xMidYMid" or align == "xMinYMid" or align == "xMaxYMid" then
        ty = (vp_h - scaled_h) * 0.5
    elseif align == "xMidYMax" or align == "xMinYMax" or align == "xMaxYMax" then
        ty = vp_h - scaled_h
    end
    -- else yMin: ty = 0

    local final_tx = vp_x + tx - vb.x * s
    local final_ty = vp_y + ty - vb.y * s

    return { s, 0, 0, s, final_tx, final_ty }
end

return Viewbox



