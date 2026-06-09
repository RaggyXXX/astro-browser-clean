------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / layout.lua
-- SVG layout: viewBox mapping for <svg> root, and absolute
-- coordinate placement for SVG children (no flow layout).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local Viewbox     = require("core/svg/viewbox")
local SvgTransform = require("core/svg/transform")
local Constants    = require("core/svg/constants")

local SvgLayout = {}

local math_min = math.min
local math_max = math.max

------------------------------------------------------------
-- SVG root layout
------------------------------------------------------------

--- After Block.layout has computed the <svg> element's CSS box,
--- compute the viewBox matrix and lay out all SVG children.
---@param engine table  LayoutEngine instance
---@param nid    number <svg> node id
function SvgLayout.layout_svg_root(engine, nid, live_resize)
    local ns = engine.ns
    local lay = ns.layout[nid]
    if not lay then return end

    local attrs = ns.attrs[nid] or {}

    -- Parse viewBox
    local vb = Viewbox.parse(attrs.viewBox or attrs.viewbox)

    -- Compute viewport -> viewBox matrix
    local matrix = Viewbox.compute_matrix(
        lay.content_x, lay.content_y,
        lay.content_w, lay.content_h,
        vb,
        attrs.preserveAspectRatio or attrs.preserveaspectratio
    )

    -- Store SVG context on the layout node for renderer access
    lay._svg_ctx = {
        matrix = matrix,
        viewBox = vb,
        live_resize = live_resize or false,
    }

    -- Recursively lay out SVG children
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        SvgLayout._layout_svg_child(engine, cid, matrix)
        cid = ns.next_sibling[cid] or 0
    end
end

------------------------------------------------------------
-- SVG child layout (recursive for <g>)
------------------------------------------------------------

--- Lay out a single SVG child node.
--- SVG children don't participate in flow layout; their position
--- comes from geometry attributes + parent transform matrix.
---@param engine table  LayoutEngine instance
---@param nid    number Child node id
---@param parent_matrix table  Accumulated affine matrix
function SvgLayout._layout_svg_child(engine, nid, parent_matrix)
    local ns = engine.ns
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)

    if not Constants.is_svg_child(tag_str) then return end

    local attrs = ns.attrs[nid] or {}
    local lay = ns.layout[nid]
    if not lay then
        -- Initialize layout entry
        ns.layout[nid] = {
            x = 0, y = 0, w = 0, h = 0,
            content_x = 0, content_y = 0, content_w = 0, content_h = 0,
        }
        lay = ns.layout[nid]
    end

    -- Compute local transform (from transform attribute)
    local local_matrix = SvgTransform.parse(attrs.transform)
    local world_matrix = SvgTransform.mul(parent_matrix, local_matrix)

    -- Compute bounding box in screen coords based on shape type
    local bbox = SvgLayout._compute_bbox(tag_str, attrs, world_matrix)

    -- Store layout
    lay.x = bbox.x
    lay.y = bbox.y
    lay.w = bbox.w
    lay.h = bbox.h
    lay.content_x = bbox.x
    lay.content_y = bbox.y
    lay.content_w = bbox.w
    lay.content_h = bbox.h

    -- Store SVG context for renderer
    lay._svg_ctx = {
        matrix = world_matrix,
        tag = tag_str,
    }

    -- Recurse into <g> children
    if tag_str == "g" then
        local cid = ns.first_child[nid]
        if not cid then cid = 0 end
        while cid ~= 0 do
            SvgLayout._layout_svg_child(engine, cid, world_matrix)
            cid = ns.next_sibling[cid] or 0
        end
    end
end

------------------------------------------------------------
-- Bounding box computation
------------------------------------------------------------

--- Compute the screen-space bounding box for an SVG shape.
---@param tag    string  Tag name
---@param attrs  table   Node attributes
---@param matrix table   World affine matrix
---@return table  {x, y, w, h}
function SvgLayout._compute_bbox(tag, attrs, matrix)
    local pts = {}

    if tag == "rect" then
        local rx = tonumber(attrs.x) or 0
        local ry = tonumber(attrs.y) or 0
        local rw = tonumber(attrs.width) or 0
        local rh = tonumber(attrs.height) or 0
        pts[1] = { SvgTransform.apply(matrix, rx, ry) }
        pts[2] = { SvgTransform.apply(matrix, rx + rw, ry) }
        pts[3] = { SvgTransform.apply(matrix, rx + rw, ry + rh) }
        pts[4] = { SvgTransform.apply(matrix, rx, ry + rh) }

    elseif tag == "circle" then
        local cx = tonumber(attrs.cx) or 0
        local cy = tonumber(attrs.cy) or 0
        local r  = tonumber(attrs.r) or 0
        -- Approximate: transform 4 cardinal points
        pts[1] = { SvgTransform.apply(matrix, cx - r, cy - r) }
        pts[2] = { SvgTransform.apply(matrix, cx + r, cy - r) }
        pts[3] = { SvgTransform.apply(matrix, cx + r, cy + r) }
        pts[4] = { SvgTransform.apply(matrix, cx - r, cy + r) }

    elseif tag == "ellipse" then
        local cx = tonumber(attrs.cx) or 0
        local cy = tonumber(attrs.cy) or 0
        local rx = tonumber(attrs.rx) or 0
        local ry = tonumber(attrs.ry) or 0
        pts[1] = { SvgTransform.apply(matrix, cx - rx, cy - ry) }
        pts[2] = { SvgTransform.apply(matrix, cx + rx, cy - ry) }
        pts[3] = { SvgTransform.apply(matrix, cx + rx, cy + ry) }
        pts[4] = { SvgTransform.apply(matrix, cx - rx, cy + ry) }

    elseif tag == "line" then
        local x1 = tonumber(attrs.x1) or 0
        local y1 = tonumber(attrs.y1) or 0
        local x2 = tonumber(attrs.x2) or 0
        local y2 = tonumber(attrs.y2) or 0
        pts[1] = { SvgTransform.apply(matrix, x1, y1) }
        pts[2] = { SvgTransform.apply(matrix, x2, y2) }

    elseif tag == "g" then
        -- Group: zero-size bbox (children have their own)
        return { x = 0, y = 0, w = 0, h = 0 }

    else
        -- path, polyline, polygon, text: use a rough estimate
        -- Full bbox would require parsing d/points, but layout only
        -- needs approximate bounds for clipping.
        -- The renderer uses the world matrix directly.
        return { x = 0, y = 0, w = 0, h = 0 }
    end

    -- Find min/max from transformed points
    if #pts == 0 then
        return { x = 0, y = 0, w = 0, h = 0 }
    end

    local min_x, min_y = pts[1][1], pts[1][2]
    local max_x, max_y = min_x, min_y
    for i = 2, #pts do
        local px, py = pts[i][1], pts[i][2]
        if px < min_x then min_x = px end
        if py < min_y then min_y = py end
        if px > max_x then max_x = px end
        if py > max_y then max_y = py end
    end

    return {
        x = min_x,
        y = min_y,
        w = max_x - min_x,
        h = max_y - min_y,
    }
end

return SvgLayout



