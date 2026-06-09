------------------------------------------------------------
-- ext_core_astro_ui_lib / core / icons / svg_elements.lua
-- Convert SVG primitive elements (circle, rect, line, etc.)
-- into equivalent path `d` strings.
--
-- This allows the SVG path parser to handle all SVG shape
-- elements uniformly by converting them to path data first.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgElements = {}
local SvgTransform = require("core/svg/transform")

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local math_min = math.min
local fmt = string.format

------------------------------------------------------------
-- Element converters
------------------------------------------------------------

--- Convert a circle to a path d string (two arc semicircles).
---@param cx number  Center X
---@param cy number  Center Y
---@param r  number  Radius
---@return string  Path data
local function circle_to_path(cx, cy, r)
    if r <= 0 then return "" end
    -- Two semicircular arcs forming a full circle
    return fmt("M %g %g A %g %g 0 1 1 %g %g A %g %g 0 1 1 %g %g Z",
        cx - r, cy,
        r, r, cx + r, cy,
        r, r, cx - r, cy)
end

--- Convert an ellipse to a path d string.
---@param cx number  Center X
---@param cy number  Center Y
---@param rx number  X radius
---@param ry number  Y radius
---@return string  Path data
local function ellipse_to_path(cx, cy, rx, ry)
    if rx <= 0 or ry <= 0 then return "" end
    return fmt("M %g %g A %g %g 0 1 1 %g %g A %g %g 0 1 1 %g %g Z",
        cx - rx, cy,
        rx, ry, cx + rx, cy,
        rx, ry, cx - rx, cy)
end

--- Convert a rect to a path d string (with optional rounded corners).
---@param x  number  Top-left X
---@param y  number  Top-left Y
---@param w  number  Width
---@param h  number  Height
---@param rx number? Corner radius X
---@param ry number? Corner radius Y
---@return string  Path data
local function rect_to_path(x, y, w, h, rx, ry)
    if w <= 0 or h <= 0 then return "" end
    rx = rx or 0
    ry = ry or 0
    -- If only one radius specified, use it for both
    if rx > 0 and ry == 0 then ry = rx end
    if ry > 0 and rx == 0 then rx = ry end
    -- Clamp to half dimensions
    rx = math_min(rx, w * 0.5)
    ry = math_min(ry, h * 0.5)

    if rx <= 0 or ry <= 0 then
        -- Sharp corners
        return fmt("M %g %g L %g %g L %g %g L %g %g Z",
            x, y, x + w, y, x + w, y + h, x, y + h)
    else
        -- Rounded corners
        return fmt(
            "M %g %g L %g %g A %g %g 0 0 1 %g %g " ..
            "L %g %g A %g %g 0 0 1 %g %g " ..
            "L %g %g A %g %g 0 0 1 %g %g " ..
            "L %g %g A %g %g 0 0 1 %g %g Z",
            x + rx, y,                          -- start after top-left corner
            x + w - rx, y,                      -- top edge
            rx, ry, x + w, y + ry,              -- top-right corner arc
            x + w, y + h - ry,                  -- right edge
            rx, ry, x + w - rx, y + h,          -- bottom-right corner arc
            x + rx, y + h,                      -- bottom edge
            rx, ry, x, y + h - ry,              -- bottom-left corner arc
            x, y + ry,                          -- left edge
            rx, ry, x + rx, y)                  -- top-left corner arc
    end
end

--- Convert a line to a path d string.
---@param x1 number  Start X
---@param y1 number  Start Y
---@param x2 number  End X
---@param y2 number  End Y
---@return string  Path data
local function line_to_path(x1, y1, x2, y2)
    return fmt("M %g %g L %g %g", x1, y1, x2, y2)
end

--- Parse a points string "x1,y1 x2,y2 ..." into coordinate pairs.
---@param points string
---@return table  Array of {x, y} pairs
local function parse_points(points)
    local result = SvgTransform.extract_numbers(points or "")
    local pairs_out = {}
    for i = 1, #result - 1, 2 do
        pairs_out[#pairs_out + 1] = { result[i], result[i + 1] }
    end
    return pairs_out
end

--- Convert a polyline to a path d string.
---@param points string  SVG points attribute "x1,y1 x2,y2 ..."
---@return string  Path data
local function polyline_to_path(points)
    local pts = parse_points(points)
    if #pts < 2 then return "" end
    local parts = { fmt("M %g %g", pts[1][1], pts[1][2]) }
    for i = 2, #pts do
        parts[#parts + 1] = fmt("L %g %g", pts[i][1], pts[i][2])
    end
    return table.concat(parts, " ")
end

--- Convert a polygon to a path d string (same as polyline + Z).
---@param points string  SVG points attribute
---@return string  Path data
local function polygon_to_path(points)
    local d = polyline_to_path(points)
    if d == "" then return "" end
    return d .. " Z"
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Convert an SVG element to a path d string.
---@param tag  string  Element tag name (circle, rect, line, etc.)
---@param attr table   Attributes table
---@return string|nil  Path data string, or nil if unsupported
function SvgElements.to_path_d(tag, attr)
    if tag == "circle" then
        return circle_to_path(
            tonumber(attr.cx) or 0,
            tonumber(attr.cy) or 0,
            tonumber(attr.r) or 0)

    elseif tag == "ellipse" then
        return ellipse_to_path(
            tonumber(attr.cx) or 0,
            tonumber(attr.cy) or 0,
            tonumber(attr.rx) or 0,
            tonumber(attr.ry) or 0)

    elseif tag == "rect" then
        return rect_to_path(
            tonumber(attr.x) or 0,
            tonumber(attr.y) or 0,
            tonumber(attr.width) or 0,
            tonumber(attr.height) or 0,
            tonumber(attr.rx),
            tonumber(attr.ry))

    elseif tag == "line" then
        return line_to_path(
            tonumber(attr.x1) or 0,
            tonumber(attr.y1) or 0,
            tonumber(attr.x2) or 0,
            tonumber(attr.y2) or 0)

    elseif tag == "polyline" then
        if attr.points then
            return polyline_to_path(attr.points)
        end

    elseif tag == "polygon" then
        if attr.points then
            return polygon_to_path(attr.points)
        end

    elseif tag == "path" then
        -- Path already has a d attribute
        return attr.d
    end

    return nil
end

return SvgElements



