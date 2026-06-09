------------------------------------------------------------
-- ext_core_astro_ui_lib / core / icons / icon_cache.lua
-- On-demand icon rasterization and texture caching.
--
-- Follows the GlyphCache pattern: icons are registered once,
-- then rasterized at requested pixel sizes on first use.
-- Each (name, size) pair produces a white-on-transparent PNG
-- that is loaded as a GPU texture for color-tinted rendering.
--
-- Icons are registered as react-icons-style trees:
--   { tag="svg", attr={viewBox="0 0 24 24"}, child={
--       { tag="path", attr={d="M..."} },
--       ...
--   }}
--
-- Per-element stroke/fill detection, transform stacking,
-- and proper stroke tessellation (round caps/joins) via
-- the existing core/svg modules.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgPathParser     = require("core/icons/svg_path_parser")
local SvgElements       = require("core/icons/svg_elements")
local Rasterizer        = require("core/fonts/rasterizer")
local SvgStyle          = require("core/svg/style")
local SvgTransform      = require("core/svg/transform")
local StrokeTessellator = require("core/svg/stroke_tessellator")

local IconCache = {}
IconCache.__index = IconCache

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new IconCache.
---@param platform table  Platform adapter (must have :load_texture)
---@return table IconCache instance
function IconCache:new(platform)
    local o = {
        _platform  = platform,
        _icons     = {},    -- [name] -> { polylines, fill_rules, viewBox }
        _raw_trees = {},    -- [name] -> { tree, viewBox } (lazy, parsed on first get)
        _textures  = {},    -- ["name:size"] -> { tex_id, w, h }
        _failed    = {},    -- ["name:size"] -> true (prevent re-attempts)
    }
    return setmetatable(o, self)
end

------------------------------------------------------------
-- Internal: viewBox parsing
------------------------------------------------------------

--- Parse a viewBox string "x y w h" into a table.
---@param vb string
---@return table {x, y, w, h}
local function parse_viewbox(vb)
    if not vb then return { x = 0, y = 0, w = 24, h = 24 } end
    local parts = SvgTransform.extract_numbers(vb)
    return {
        x = parts[1] or 0,
        y = parts[2] or 0,
        w = parts[3] or 24,
        h = parts[4] or 24,
    }
end

------------------------------------------------------------
-- Internal: per-element polyline collection with style
-- resolution, transform stacking, and tagged output.
------------------------------------------------------------

--- Detect if a polyline is closed (last point ≈ first).
---@param poly table  Array of {x,y}
---@return boolean
local function is_poly_closed(poly)
    local n = #poly
    if n < 3 then return false end
    local p1, pn = poly[1], poly[n]
    local dx, dy = p1.x - pn.x, p1.y - pn.y
    return (dx * dx + dy * dy) < 0.5
end

--- Recursively walk an icon tree node and collect tagged polylines.
--- Each tagged entry has: polys, mode, stroke_width, linecap, linejoin,
--- miterlimit, fill_rule, closed.
---
---@param node         table   { tag, attr, child }
---@param tagged_polys table   Output array of tagged entries
---@param tol          number  Curve flattening tolerance
---@param parent_style table   Parent resolved style (from SvgStyle.resolve)
---@param transform    table   Current affine transform {a,b,c,d,e,f}
local function collect_polylines(node, tagged_polys, tol, parent_style, transform)
    if not node or not node.tag then return end

    local tag = node.tag
    local attr = node.attr or {}

    -- Skip invisible / metadata elements
    if tag == "title" or tag == "desc" or tag == "defs" or tag == "clipPath"
        or tag == "mask" or tag == "style" or tag == "metadata" then
        return
    end

    -- Resolve style for this node
    local style = SvgStyle.resolve(attr, parent_style)

    -- Skip zero-opacity elements
    if style.opacity == 0 then return end

    -- Compose transform
    local xform = transform
    local raw_xform = attr.transform
    if raw_xform then
        local local_xform = SvgTransform.parse(raw_xform)
        xform = SvgTransform.mul(transform, local_xform)
    end

    -- Container elements: recurse children with inherited style + transform
    if tag == "svg" or tag == "g" then
        if node.child then
            for i = 1, #node.child do
                collect_polylines(node.child[i], tagged_polys, tol, style, xform)
            end
        end
        return
    end

    -- Leaf element: extract path data
    local d = nil
    if tag == "path" then
        d = attr.d
    elseif tag == "text" or tag == "tspan" then
        return  -- text not supported in icon pipeline
    else
        d = SvgElements.to_path_d(tag, attr)
    end

    if not d or d == "" then return end

    -- Parse path into polylines
    local parsed = SvgPathParser.parse(d, tol)
    if not parsed or #parsed == 0 then return end

    -- Apply accumulated transform to all points
    local is_identity = (xform[1] == 1 and xform[2] == 0 and xform[3] == 0
                         and xform[4] == 1 and xform[5] == 0 and xform[6] == 0)
    if not is_identity then
        for i = 1, #parsed do
            local poly = parsed[i]
            for j = 1, #poly do
                local pt = poly[j]
                pt.x, pt.y = SvgTransform.apply(xform, pt.x, pt.y)
            end
        end
    end

    -- Determine fill and stroke rendering modes
    local has_fill = (style.fill ~= "none" and style.fill ~= nil)
    -- Treat "currentcolor" as filled (monochrome pipeline)
    if style.fill == "currentcolor" then has_fill = true end

    local has_stroke = (style.stroke ~= "none" and style.stroke ~= nil
                        and style.stroke_width > 0)
    if style.stroke == "currentcolor" then has_stroke = true end

    -- Scale stroke_width by transform scale factor
    local sw = style.stroke_width
    if has_stroke and not is_identity then
        sw = sw * SvgTransform.get_scale(xform)
    end

    local fill_rule = style.fill_rule or "nonzero"

    -- Emit fill-mode entries
    if has_fill then
        local fill_opacity = style.fill_opacity * style.opacity
        if fill_opacity > 0 then
            for i = 1, #parsed do
                tagged_polys[#tagged_polys + 1] = {
                    polys      = parsed[i],
                    mode       = "fill",
                    fill_rule  = fill_rule,
                    closed     = is_poly_closed(parsed[i]),
                }
            end
        end
    end

    -- Emit stroke-mode entries
    if has_stroke then
        local stroke_opacity = style.stroke_opacity * style.opacity
        if stroke_opacity > 0 then
            for i = 1, #parsed do
                tagged_polys[#tagged_polys + 1] = {
                    polys        = parsed[i],
                    mode         = "stroke",
                    stroke_width = sw,
                    linecap      = style.stroke_linecap or "butt",
                    linejoin     = style.stroke_linejoin or "miter",
                    miterlimit   = style.stroke_miterlimit or 4,
                    closed       = is_poly_closed(parsed[i]),
                }
            end
        end
    end
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Register an icon from a react-icons-style tree.
--- Parsing is deferred until first get() to avoid startup stalls.
---
--- The tree format is:
---   { tag="svg", attr={viewBox="0 0 24 24"}, child={
---       { tag="path", attr={d="M..."} },
---       { tag="circle", attr={cx=12, cy=12, r=3} },
---       ...
---   }}
---
---@param name string     Icon identifier (e.g. "MdHome")
---@param icon_tree table  Icon tree structure
function IconCache:register(name, icon_tree)
    if not icon_tree or not icon_tree.tag then return end

    local root_attr = icon_tree.attr or {}
    -- Construct viewBox from width/height if viewBox is absent
    local vb = root_attr.viewBox
    if not vb then
        local w = tonumber(root_attr.width) or 24
        local h = tonumber(root_attr.height) or 24
        vb = "0 0 " .. w .. " " .. h
    end

    self._raw_trees[name] = {
        tree    = icon_tree,
        viewBox = parse_viewbox(vb),
    }
end

--- Register a single-path icon (shorthand for common react-icons).
---
---@param name string     Icon identifier
---@param d string        SVG path data
---@param viewBox string? ViewBox string (default "0 0 24 24")
function IconCache:register_path(name, d, viewBox)
    self:register(name, {
        tag = "svg",
        attr = { viewBox = viewBox or "0 0 24 24" },
        child = {
            { tag = "path", attr = { d = d } },
        },
    })
end

--- Internal: ensure polylines are parsed for a given icon.
--- Called lazily on first get() to spread work across frames.
--- Uses per-element style resolution and StrokeTessellator.
---@param name string
---@return table|nil  { polylines, fill_rules, viewBox } or nil
function IconCache:_ensure_parsed(name)
    -- Already parsed
    local existing = self._icons[name]
    if existing then return existing end

    -- Check for raw tree
    local raw = self._raw_trees[name]
    if not raw then return nil end

    -- Collect tagged polylines with per-element style + transform
    local tol = 0.25
    local tagged_polys = {}
    local identity = SvgTransform.identity()
    collect_polylines(raw.tree, tagged_polys, tol, {}, identity)

    -- Process tagged entries: tessellate strokes, pass through fills
    local final_polys = {}
    local fill_rules = {}
    local has_evenodd = false

    for i = 1, #tagged_polys do
        local tp = tagged_polys[i]
        if tp.mode == "stroke" then
            -- Use StrokeTessellator for proper caps/joins
            local tess = StrokeTessellator.tessellate(
                tp.polys, tp.stroke_width,
                tp.linecap, tp.linejoin,
                tp.miterlimit, tp.closed)
            -- Flatten: tessellate returns array of polylines (outline + caps)
            for j = 1, #tess do
                final_polys[#final_polys + 1] = tess[j]
                fill_rules[#fill_rules + 1] = "nonzero"  -- stroked outlines always nonzero
            end
        else
            -- Fill-mode: pass polyline through directly
            final_polys[#final_polys + 1] = tp.polys
            local rule = tp.fill_rule or "nonzero"
            fill_rules[#fill_rules + 1] = rule
            if rule == "evenodd" then has_evenodd = true end
        end
    end

    -- Simplify fill_rules: if all nonzero, no need to pass table
    local fill_rules_param = nil
    if has_evenodd then
        fill_rules_param = fill_rules
    end

    local entry = {
        polylines   = final_polys,
        fill_rules  = fill_rules_param,
        viewBox     = raw.viewBox,
    }
    self._icons[name] = entry
    -- Free raw tree to save memory
    self._raw_trees[name] = nil
    return entry
end

--- Get (or rasterize) an icon at the given pixel size.
---
--- Returns a table with texture info for rendering, or nil if
--- the icon is not registered or rasterization failed.
---
---@param name string       Icon identifier
---@param pixel_size number  Desired size in pixels
---@return table|nil  { tex_id, w, h }
function IconCache:get(name, pixel_size)
    local size_key = math_floor(pixel_size)
    if size_key < 1 then size_key = 1 end
    local cache_key = name .. ":" .. tostring(size_key)

    -- Check texture cache
    local cached = self._textures[cache_key]
    if cached then return cached end

    -- Check failure cache
    if self._failed[cache_key] then return nil end

    -- Look up registered icon (lazy-parse if needed)
    local icon_data = self:_ensure_parsed(name)
    if not icon_data then
        self._failed[cache_key] = true
        return nil
    end

    local polylines = icon_data.polylines
    local viewBox = icon_data.viewBox

    if not polylines or #polylines == 0 then
        self._failed[cache_key] = true
        return nil
    end

    -- Rasterize at requested size (uniform scaling, square output)
    -- out_h = nil triggers uniform/icon mode in rasterizer
    -- 5th param: fill_rules (nil = all nonzero, backward compatible)
    local png, out_w, out_h, alpha_buf = Rasterizer.rasterize(
        polylines, viewBox, size_key, nil, icon_data.fill_rules)
    if not png then
        self._failed[cache_key] = true
        return nil
    end

    -- Load as GPU texture
    local ok, tex_id = pcall(self._platform.load_texture, self._platform, png, out_w, out_h)
    if not ok or not tex_id or tex_id == 0 then
        self._failed[cache_key] = true
        return nil
    end

    local entry = {
        tex_id    = tex_id,
        w         = out_w,
        h         = out_h,
        alpha_buf = alpha_buf,  -- for software scissor clipping
    }
    self._textures[cache_key] = entry
    return entry
end

--- Draw an icon with software scissor clipping.
--- If the icon is fully inside the clip rect, draws as a normal
--- texture (fast path). If partially overlapping, draws visible
--- pixels as rect_fill spans (slow path, pixel-perfect clipping).
---
---@param dl table         DisplayList instance
---@param name string      Icon identifier
---@param pixel_size number Desired size in pixels
---@param ix number        Draw x position
---@param iy number        Draw y position
---@param clip table|nil   {x, y, w, h} clip rect, or nil for no clip
---@param r number         Tint red 0-255
---@param g number         Tint green 0-255
---@param b number         Tint blue 0-255
---@param a number         Tint alpha 0-255
---@return boolean         true if drawn
function IconCache:draw_clipped(dl, name, pixel_size, ix, iy, clip, r, g, b, a)
    local entry = self:get(name, pixel_size)
    if not entry then return false end

    local iw, ih = entry.w, entry.h

    -- No clip at all → texture fast path
    if not clip then
        dl:image(entry.tex_id, ix, iy, iw, ih, r, g, b, a)
        return true
    end

    -- Fully outside → skip
    if ix + iw <= clip[1] or ix >= clip[1] + clip[3]
       or iy + ih <= clip[2] or iy >= clip[2] + clip[4] then
        return false
    end

    -- When a clip is active, ALWAYS use rect_fill spans.
    local alpha_buf = entry.alpha_buf
    if not alpha_buf then
        return false
    end

    -- Compute visible row/col range (clamp to clip rect)
    local row_start = math_max(math_floor(clip[2] - iy), 0)
    local row_end   = math_min(math_floor(clip[2] + clip[4] - iy), ih) - 1
    local col_start = math_max(math_floor(clip[1] - ix), 0)
    local col_end   = math_min(math_floor(clip[1] + clip[3] - ix), iw) - 1

    if row_start > row_end or col_start > col_end then return false end

    -- Emit rect_fill spans for each visible row.
    local math_floor_l = math_floor
    for row = row_start, row_end do
        local base = row * iw
        local span_start = nil
        local span_alpha = 0

        for col = col_start, col_end do
            local px_alpha = alpha_buf[base + col + 1]
            if px_alpha > 0 then
                local blended = math_floor_l(px_alpha * a / 255)
                if blended > 0 then
                    if span_start and blended == span_alpha then
                        -- Continue current span
                    else
                        -- Flush previous span
                        if span_start then
                            dl:rect_fill(ix + span_start, iy + row,
                                col - span_start, 1,
                                r, g, b, span_alpha, 0)
                        end
                        span_start = col
                        span_alpha = blended
                    end
                else
                    if span_start then
                        dl:rect_fill(ix + span_start, iy + row,
                            col - span_start, 1,
                            r, g, b, span_alpha, 0)
                        span_start = nil
                    end
                end
            else
                if span_start then
                    dl:rect_fill(ix + span_start, iy + row,
                        col - span_start, 1,
                        r, g, b, span_alpha, 0)
                    span_start = nil
                end
            end
        end

        -- Flush last span in row
        if span_start then
            dl:rect_fill(ix + span_start, iy + row,
                col_end - span_start + 1, 1,
                r, g, b, span_alpha, 0)
        end
    end

    return true
end

--- Check if an icon is registered.
---@param name string
---@return boolean
function IconCache:has(name)
    return self._icons[name] ~= nil or self._raw_trees[name] ~= nil
end

return IconCache



