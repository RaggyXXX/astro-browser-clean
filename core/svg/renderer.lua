------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / renderer.lua
-- Paint SVG subtree: walks SVG children in document order,
-- resolves style inheritance, and renders shapes via
-- display list (fast path) or rasterizer masks (slow path).
--
-- Performance: 2-level cache
--   L1: polyline geometry cached by (d + tol_bucket)
--   L2: rasterized mask cached by (d + quantized_scale),
--       stores bbox offset so cache hits skip ALL tessellation.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local SvgPathParser    = require("core/icons/svg_path_parser")
local SvgElements      = require("core/icons/svg_elements")
local SvgTransform     = require("core/svg/transform")
local SvgStyle         = require("core/svg/style")
local StrokeTessellator = require("core/svg/stroke_tessellator")
local MaskCache        = require("core/svg/mask_cache")
local Constants        = require("core/svg/constants")
local Utf8             = require("core/util/utf8")

local SvgRenderer = {}

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local math_abs   = math.abs
local math_sqrt  = math.sqrt

--- Current visible rect (set during paint_svg_subtree)
SvgRenderer._visible_rect = nil
SvgRenderer._font_manager = nil
SvgRenderer._default_font = "inter"
SvgRenderer.strict_self_drawn_text = true

--- Interactive mode flag: when true, use span-based rendering
--- instead of crop textures for partially visible shapes.
--- Set by engine before paint when scrolling or resizing.
SvgRenderer._interactive = false

--- Shared mask cache (created once per Engine).
SvgRenderer._mask_cache = nil

--- L1 geometry cache: [d .. ":" .. tol_bucket] -> polylines
SvgRenderer._geom_cache = {}

--- L2 render cache: [key] -> { tex_id, w, h, min_x0, min_y0 }
--- Stores bbox offset relative to translation-free matrix so
--- cache hits only need to add tx,ty for final draw position.
SvgRenderer._render_cache = {}
SvgRenderer._render_failed = {}

--- Initialize the mask cache (called from Engine:start).
function SvgRenderer.init(platform)
    if SvgRenderer._mask_cache and SvgRenderer._mask_cache._platform ~= platform then
        SvgRenderer.reset_runtime_caches()
    end
    if not SvgRenderer._mask_cache then
        SvgRenderer._mask_cache = MaskCache:new(platform)
    end
end

--- Clear platform-owned SVG caches.
--- Geometry cache is platform-independent and remains reusable.
function SvgRenderer.reset_runtime_caches()
    SvgRenderer._mask_cache = nil
    SvgRenderer._render_cache = {}
    SvgRenderer._render_failed = {}
    SvgRenderer._visible_rect = nil
    SvgRenderer._interactive = false
    SvgRenderer._live_resize = false
end

------------------------------------------------------------
-- Cache helpers
------------------------------------------------------------

--- Quantize a float to nearest 1/100 for cache key stability.
local function q100(v)
    return math_floor(v * 100 + 0.5)
end

--- Build linear matrix key (rotation+scale only, no translation).
local function lin_key(m)
    return q100(m[1]) .. ":" .. q100(m[2]) .. ":" .. q100(m[3]) .. ":" .. q100(m[4])
end

--- Compute tolerance bucket: quantize to powers of sqrt(2)
--- so we get ~6 distinct tol levels across the useful range.
local function tol_bucket(scale)
    local tol = 0.25 / math_max(scale, 0.01)
    if tol < 0.05 then tol = 0.05 end
    if tol > 0.5 then tol = 0.5 end
    -- Quantize to one of: 0.05, 0.07, 0.10, 0.15, 0.20, 0.30, 0.50
    if tol <= 0.06 then return 0.05
    elseif tol <= 0.085 then return 0.07
    elseif tol <= 0.125 then return 0.10
    elseif tol <= 0.175 then return 0.15
    elseif tol <= 0.25 then return 0.20
    elseif tol <= 0.40 then return 0.30
    else return 0.50 end
end

--- Get or create polylines from L1 geometry cache.
local function get_polylines(d, tol)
    local key = d .. ":" .. tostring(tol)
    local cached = SvgRenderer._geom_cache[key]
    if cached then return cached end
    local polylines = SvgPathParser.parse(d, tol)
    if polylines and #polylines > 0 then
        SvgRenderer._geom_cache[key] = polylines
    end
    return polylines
end

--- Transform polylines by translation-free matrix, compute bbox, shift to origin.
--- Returns shifted polylines, pw, ph, min_x0, min_y0 (relative to tx=ty=0).
local function transform_and_prepare(polylines, matrix, extra_pad)
    -- Build translation-free matrix
    local m = { matrix[1], matrix[2], matrix[3], matrix[4], 0, 0 }

    local min_x, min_y = 1e9, 1e9
    local max_x, max_y = -1e9, -1e9

    local transformed = {}
    for pi = 1, #polylines do
        local poly = polylines[pi]
        local tp = {}
        for i = 1, #poly do
            local px = m[1] * poly[i].x + m[3] * poly[i].y
            local py = m[2] * poly[i].x + m[4] * poly[i].y
            tp[i] = { x = px, y = py }
            if px < min_x then min_x = px end
            if py < min_y then min_y = py end
            if px > max_x then max_x = px end
            if py > max_y then max_y = py end
        end
        transformed[pi] = tp
    end

    -- Add padding (for stroke width)
    min_x = min_x - extra_pad
    min_y = min_y - extra_pad
    max_x = max_x + extra_pad
    max_y = max_y + extra_pad

    local bbox_w = max_x - min_x
    local bbox_h = max_y - min_y
    if bbox_w < 1 or bbox_h < 1 then return nil end

    -- Shift to origin
    local shifted = {}
    for pi = 1, #transformed do
        local tp = transformed[pi]
        local sp = {}
        for i = 1, #tp do
            sp[i] = { x = tp[i].x - min_x, y = tp[i].y - min_y }
        end
        shifted[pi] = sp
    end

    local pw = math_max(1, math_floor(bbox_w + 0.5))
    local ph = math_max(1, math_floor(bbox_h + 0.5))

    return shifted, pw, ph, min_x, min_y
end

------------------------------------------------------------
-- Main entry point
------------------------------------------------------------

--- Paint the entire SVG subtree rooted at svg_nid.
--- Called from paint_tree when an <svg> node is encountered.
---@param ns           table  NodeStore
---@param svg_nid      number <svg> node id
---@param dl           table  DisplayList
---@param platform     table  Platform adapter
---@param visible_rect table|nil  {x,y,w,h} effective visible area (scroll clip)
function SvgRenderer.paint_svg_subtree(ns, svg_nid, dl, platform, visible_rect)
    local lay = ns.layout[svg_nid]
    if not lay or not lay._svg_ctx then return end

    local ctx = lay._svg_ctx
    local root_matrix = ctx.matrix

    -- Set per-frame live_resize flag for performance optimization
    SvgRenderer._live_resize = ctx.live_resize or false

    -- Compute effective visible rect: intersection of SVG box and scroll clip
    local svg_vr = { x = lay.content_x, y = lay.content_y,
                     w = lay.content_w, h = lay.content_h }
    if visible_rect then
        local vx1 = math_max(svg_vr.x, visible_rect.x)
        local vy1 = math_max(svg_vr.y, visible_rect.y)
        local vx2 = math_min(svg_vr.x + svg_vr.w, visible_rect.x + visible_rect.w)
        local vy2 = math_min(svg_vr.y + svg_vr.h, visible_rect.y + visible_rect.h)
        if vx2 > vx1 and vy2 > vy1 then
            svg_vr = { x = vx1, y = vy1, w = vx2 - vx1, h = vy2 - vy1 }
        else
            return  -- SVG entirely outside visible area
        end
    end
    SvgRenderer._visible_rect = svg_vr

    -- Push clip to SVG viewport
    local computed = ns.computed[svg_nid] or {}
    local bg = computed.background_color
    if bg then
        dl:clip_push(lay.content_x, lay.content_y,
                     lay.content_w, lay.content_h,
                     bg[1], bg[2], bg[3], bg[4] or 255)
    else
        dl:clip_push(lay.content_x, lay.content_y,
                     lay.content_w, lay.content_h)
    end

    -- Root SVG style defaults
    local root_style = SvgStyle.resolve(ns.attrs[svg_nid], nil)

    -- Walk children in document order
    local cid = ns.first_child[svg_nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        SvgRenderer._paint_node(ns, cid, dl, platform, root_matrix, root_style, 1.0)
        cid = ns.next_sibling[cid] or 0
    end

    dl:clip_pop()
    SvgRenderer._visible_rect = nil
end

------------------------------------------------------------
-- Clipped image draw helper
------------------------------------------------------------

--- Draw an image via display list.  GPU scissor handles
--- pixel-level clipping at overflow boundaries.  Software
--- cropping is kept as fallback for interactive SVG resize
--- where the alpha buffer is used for span-based rendering.
local math_ceil = math.ceil
local function draw_image_clipped(dl, hit, tx, ty, r, g, b, a)
    if a <= 0 then return end

    local ix = hit.min_x0 + tx
    local iy = hit.min_y0 + ty
    local iw = hit.w
    local ih = hit.h
    if iw < 1 or ih < 1 then return end

    local vr = SvgRenderer._visible_rect
    if not vr then
        -- No visible rect: draw full
        dl:image(hit.tex_id, ix, iy, iw, ih, r, g, b, a, true)
        return
    end

    -- Fully inside visible rect: draw original texture
    if ix >= vr.x and iy >= vr.y
       and ix + iw <= vr.x + vr.w and iy + ih <= vr.y + vr.h then
        dl:image(hit.tex_id, ix, iy, iw, ih, r, g, b, a, true)
        return
    end

    -- Fully outside visible rect: skip
    if ix + iw <= vr.x or iy + ih <= vr.y
       or ix >= vr.x + vr.w or iy >= vr.y + vr.h then
        return
    end

    -- Partially clipped: need to crop

    -- Determine which buffer to use for cropping.
    -- During live resize, the drawn image is stretched to a different size
    -- than the original buffer. Use scaled coordinates into the original buf.
    local crop_buf = hit.buf
    local crop_buf_w = iw
    local crop_buf_h = ih
    if not crop_buf and hit.src_buf then
        -- Live resize: use original (pre-resize) alpha buffer with scaling
        crop_buf = hit.src_buf
        crop_buf_w = hit.src_w
        crop_buf_h = hit.src_h
    end

    if not crop_buf then
        -- No buffer available at all: skip draw to prevent overflow.
        return
    end

    -- Compute crop in screen-pixel space
    local crop_x = math_max(0, math_ceil(vr.x - ix))
    local crop_y = math_max(0, math_ceil(vr.y - iy))
    local crop_r = math_min(iw, math_floor(vr.x + vr.w - ix))
    local crop_b = math_min(ih, math_floor(vr.y + vr.h - iy))
    local crop_w = crop_r - crop_x
    local crop_h = crop_b - crop_y

    if crop_w < 1 or crop_h < 1 then return end

    local cache = SvgRenderer._mask_cache
    if not cache then return end

    -- Map crop coordinates from screen space to buffer space
    local buf_crop_x, buf_crop_y, buf_crop_w, buf_crop_h
    if crop_buf_w == iw and crop_buf_h == ih then
        buf_crop_x = crop_x
        buf_crop_y = crop_y
        buf_crop_w = crop_w
        buf_crop_h = crop_h
    else
        -- Scale crop coordinates from screen space to buffer space
        local sx = crop_buf_w / iw
        local sy = crop_buf_h / ih
        buf_crop_x = math_floor(crop_x * sx)
        buf_crop_y = math_floor(crop_y * sy)
        if buf_crop_x >= crop_buf_w or buf_crop_y >= crop_buf_h then return end
        buf_crop_w = math_max(1, math_floor(crop_w * sx))
        buf_crop_h = math_max(1, math_floor(crop_h * sy))
        -- Clamp to buffer bounds
        if buf_crop_x + buf_crop_w > crop_buf_w then
            buf_crop_w = crop_buf_w - buf_crop_x
        end
        if buf_crop_y + buf_crop_h > crop_buf_h then
            buf_crop_h = crop_buf_h - buf_crop_y
        end
        if buf_crop_w < 1 or buf_crop_h < 1 then return end
    end

    -- Interactive mode (scroll/resize): use span-based rendering.
    -- Emits rect_fill calls from the alpha buffer directly -" no PNG
    -- encode or texture upload needed. rect_fill clips properly via
    -- rect_clip intersection in display_list replay.
    if SvgRenderer._interactive then
        -- Use the real cache entry so build_runs() caching works across frames.
        -- hit.buf points to the persistent mask entry buffer; find the matching
        -- entry to pass through (so entry.runs gets cached on it).
        local span_entry = hit._mask_entry
        if not span_entry then
            span_entry = { buf = crop_buf, w = crop_buf_w, h = crop_buf_h }
        end

        -- When buffer dimensions differ from screen dimensions (live resize),
        -- emit_spans works in buffer space. We need to scale the output
        -- coordinates so the spans cover the correct screen area.
        local scale_x, scale_y = 1, 1
        if crop_buf_w ~= iw or crop_buf_h ~= ih then
            scale_x = iw / crop_buf_w
            scale_y = ih / crop_buf_h
        end
        cache:emit_spans(dl, span_entry, buf_crop_x, buf_crop_y, buf_crop_w, buf_crop_h,
                         ix + crop_x, iy + crop_y, r, g, b, a, scale_x, scale_y)
        return
    end

    -- Idle mode: create exact cropped texture (cached by exact rect)
    local crop_entry = { buf = crop_buf, w = crop_buf_w, h = crop_buf_h, tex_id = hit.tex_id }
    local ok, crop_tex, cw, ch = pcall(cache.create_cropped, cache, crop_entry,
                                       buf_crop_x, buf_crop_y, buf_crop_w, buf_crop_h)
    if ok and crop_tex then
        dl:image(crop_tex, ix + crop_x, iy + crop_y, crop_w, crop_h, r, g, b, a, true)
    end
    -- If crop fails, skip draw entirely to prevent overflow
end

------------------------------------------------------------
-- Recursive node painting
------------------------------------------------------------

function SvgRenderer._paint_node(ns, nid, dl, platform, parent_matrix, parent_style, parent_opacity)
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)
    if not Constants.is_svg_child(tag_str) then return end

    local attrs = ns.attrs[nid] or {}

    -- Resolve local transform
    local local_matrix = SvgTransform.parse(attrs.transform)
    local world_matrix = SvgTransform.mul(parent_matrix, local_matrix)

    -- Resolve style with inheritance
    local style = SvgStyle.resolve(attrs, parent_style)

    -- Element opacity stacks multiplicatively
    local eff_opacity = parent_opacity * style.opacity

    if tag_str == "g" then
        -- Group: just recurse into children with accumulated transform/style
        local cid = ns.first_child[nid]
        if not cid then cid = 0 end
        while cid ~= 0 do
            SvgRenderer._paint_node(ns, cid, dl, platform, world_matrix, style, eff_opacity)
            cid = ns.next_sibling[cid] or 0
        end
        return
    end

    -- Shape rendering
    if tag_str == "rect" then
        SvgRenderer._paint_rect(attrs, world_matrix, style, eff_opacity, dl)
    elseif tag_str == "circle" then
        SvgRenderer._paint_circle(attrs, world_matrix, style, eff_opacity, dl)
    elseif tag_str == "ellipse" then
        SvgRenderer._paint_path("ellipse", attrs, world_matrix, style, eff_opacity, dl, platform)
    elseif tag_str == "line" then
        SvgRenderer._paint_line(attrs, world_matrix, style, eff_opacity, dl)
    elseif tag_str == "path" or tag_str == "polyline" or tag_str == "polygon" then
        SvgRenderer._paint_path(tag_str, attrs, world_matrix, style, eff_opacity, dl, platform)
    elseif tag_str == "svg-text" or tag_str == "text" then
        SvgRenderer._paint_text(attrs, world_matrix, style, eff_opacity, dl)
    end
end

------------------------------------------------------------
-- Fast path: rect (axis-aligned after transform)
------------------------------------------------------------

function SvgRenderer._paint_rect(attrs, matrix, style, opacity, dl)
    local rx = tonumber(attrs.x) or 0
    local ry = tonumber(attrs.y) or 0
    local rw = tonumber(attrs.width) or 0
    local rh = tonumber(attrs.height) or 0
    local rrx = tonumber(attrs.rx) or 0
    local rry = tonumber(attrs.ry) or 0
    if rrx > 0 and rry == 0 then rry = rrx end
    if rry > 0 and rrx == 0 then rrx = rry end

    if rw <= 0 or rh <= 0 then return end

    -- Check if transform is axis-aligned (no rotation/skew)
    local is_axis = (math_abs(matrix[2]) < 1e-6 and math_abs(matrix[3]) < 1e-6)

    if is_axis then
        -- Fast path: direct display list commands
        local sx, sy = matrix[1], matrix[4]
        local x1, y1 = SvgTransform.apply(matrix, rx, ry)
        local x2, y2 = SvgTransform.apply(matrix, rx + rw, ry + rh)
        local px = math_min(x1, x2)
        local py = math_min(y1, y2)
        local pw = math_abs(x2 - x1)
        local ph = math_abs(y2 - y1)
        local pr = math_min(rrx * math_abs(sx), pw * 0.5)

        -- Fill
        local fill = style.fill
        if fill and fill ~= "none" then
            local fa = math_floor((fill[4] or 255) * opacity * style.fill_opacity + 0.5)
            if fa > 0 then
                dl:rect_fill(px, py, pw, ph, fill[1], fill[2], fill[3], fa, pr)
            end
        end

        -- Stroke
        local stroke = style.stroke
        if stroke and stroke ~= "none" then
            local sa = math_floor((stroke[4] or 255) * opacity * style.stroke_opacity + 0.5)
            local sw = style.stroke_width * math_abs(sx)
            if sa > 0 and sw > 0 then
                dl:rect_stroke(px, py, pw, ph, stroke[1], stroke[2], stroke[3], sa, sw, pr)
            end
        end
    else
        -- Rotated rect: fall back to path rendering
        SvgRenderer._paint_path("rect", attrs, matrix, style, opacity, dl, nil)
    end
end

------------------------------------------------------------
-- Fast path: circle
------------------------------------------------------------

function SvgRenderer._paint_circle(attrs, matrix, style, opacity, dl)
    local cx = tonumber(attrs.cx) or 0
    local cy = tonumber(attrs.cy) or 0
    local r  = tonumber(attrs.r) or 0
    if r <= 0 then return end

    local is_uniform = (math_abs(matrix[2]) < 1e-6 and math_abs(matrix[3]) < 1e-6
                    and math_abs(math_abs(matrix[1]) - math_abs(matrix[4])) < 1e-6)

    if is_uniform then
        local s = math_abs(matrix[1])
        local px, py = SvgTransform.apply(matrix, cx, cy)
        local pr = r * s

        -- Check if circle bbox is partially outside visible rect
        -- If so, use slow path (texture + crop) for smooth clipping.
        -- Also applies during live resize: draw_image_clipped now
        -- supports scaled cropping from cached buffers.
        local vr = SvgRenderer._visible_rect
        if vr then
            local bx1, by1 = px - pr, py - pr
            local bx2, by2 = px + pr, py + pr
            local fully_inside = bx1 >= vr.x and by1 >= vr.y
                and bx2 <= vr.x + vr.w and by2 <= vr.y + vr.h
            if not fully_inside then
                -- Partially clipped: rasterize as texture for smooth crop
                SvgRenderer._paint_path("circle", attrs, matrix, style, opacity, dl, nil)
                return
            end
        end

        -- Fill
        local fill = style.fill
        if fill and fill ~= "none" then
            local fa = math_floor((fill[4] or 255) * opacity * style.fill_opacity + 0.5)
            if fa > 0 then
                dl:circle_fill(px, py, pr, fill[1], fill[2], fill[3], fa)
            end
        end

        -- Stroke (as circle outline via rect_stroke with full rounding)
        local stroke = style.stroke
        if stroke and stroke ~= "none" then
            local sa = math_floor((stroke[4] or 255) * opacity * style.stroke_opacity + 0.5)
            local sw = style.stroke_width * s
            if sa > 0 and sw > 0 then
                local d = pr * 2
                dl:rect_stroke(px - pr, py - pr, d, d, stroke[1], stroke[2], stroke[3], sa, sw, pr)
            end
        end
    else
        -- Non-uniform scale or rotation: rasterize
        SvgRenderer._paint_path("circle", attrs, matrix, style, opacity, dl, nil)
    end
end

------------------------------------------------------------
-- Fast path: line
------------------------------------------------------------

function SvgRenderer._paint_line(attrs, matrix, style, opacity, dl)
    local x1 = tonumber(attrs.x1) or 0
    local y1 = tonumber(attrs.y1) or 0
    local x2 = tonumber(attrs.x2) or 0
    local y2 = tonumber(attrs.y2) or 0

    local px1, py1 = SvgTransform.apply(matrix, x1, y1)
    local px2, py2 = SvgTransform.apply(matrix, x2, y2)

    local stroke = style.stroke
    if stroke and stroke ~= "none" then
        local sa = math_floor((stroke[4] or 255) * opacity * style.stroke_opacity + 0.5)
        local sw = style.stroke_width * SvgTransform.get_scale(matrix)
        if sa > 0 and sw > 0 then
            dl:line(px1, py1, px2, py2, stroke[1], stroke[2], stroke[3], sa, sw)
        end
    end
end

------------------------------------------------------------
-- Slow path: path, polyline, polygon (and fallback shapes)
-- Uses 2-level cache for maximum performance.
------------------------------------------------------------

function SvgRenderer._paint_path(tag, attrs, matrix, style, opacity, dl, platform)
    -- Convert shape to path d string
    local d = SvgElements.to_path_d(tag, attrs)
    if not d or d == "" then return end

    local scale = SvgTransform.get_scale(matrix)
    local sw_px = style.stroke_width * scale
    local tx, ty = matrix[5], matrix[6]

    local fill = style.fill
    local stroke = style.stroke
    local need_fill = fill and fill ~= "none"
    local need_stroke = stroke and stroke ~= "none" and sw_px > 0.5

    if not need_fill and not need_stroke then return end

    -- Build L2 cache keys (translation-free)
    local lk = lin_key(matrix)
    local fill_rule = style.fill_rule or "nonzero"
    local stroke_geom_key = (style.stroke_linecap or "butt") .. ":"
        .. (style.stroke_linejoin or "miter") .. ":"
        .. q100(style.stroke_miterlimit or 4)
    local fill_key = need_fill and ("f:" .. fill_rule .. ":" .. d .. ":" .. lk) or nil
    local stroke_key = need_stroke and ("s:" .. d .. ":" .. q100(sw_px) .. ":" .. stroke_geom_key .. ":" .. lk) or nil

    -- === FAST PATH: check L2 render cache first (no tessellation needed) ===
    local rc = SvgRenderer._render_cache
    local rf = SvgRenderer._render_failed

    local fill_hit = fill_key and rc[fill_key] or nil
    local stroke_hit = stroke_key and rc[stroke_key] or nil

    local all_cached = true
    if need_fill and not fill_hit and not (rf[fill_key]) then all_cached = false end
    if need_stroke and not stroke_hit and not (rf[stroke_key]) then all_cached = false end

    if all_cached then
        -- Pure cache hit: just draw with offset
        if fill_hit then
            local fa = math_floor((fill[4] or 255) * opacity * style.fill_opacity + 0.5)
            if fa > 0 then
                draw_image_clipped(dl, fill_hit, tx, ty, fill[1], fill[2], fill[3], fa)
            end
        end
        if stroke_hit then
            local sa = math_floor((stroke[4] or 255) * opacity * style.stroke_opacity + 0.5)
            if sa > 0 then
                draw_image_clipped(dl, stroke_hit, tx, ty, stroke[1], stroke[2], stroke[3], sa)
            end
        end
        return
    end

    local cache = SvgRenderer._mask_cache
    if not cache then return end
    local is_live_resize = SvgRenderer._live_resize

    -- === MISS PATH: tessellate, transform, compute bbox, then rasterize or stretch ===

    -- L1: get polylines from geometry cache
    local tol = tol_bucket(scale)
    local polylines = get_polylines(d, tol)
    if not polylines or #polylines == 0 then return end

    -- Compute bbox via transform (cheap: just iterate points, no rasterization)
    local shifted, pw, ph, min_x0, min_y0 = transform_and_prepare(polylines, matrix, need_stroke and sw_px or 0)
    if not shifted then return end

    local fill_family = "f:" .. fill_rule .. ":" .. d
    local stroke_family = "s:" .. stroke_geom_key .. ":" .. d

    -- Fill
    if need_fill and not fill_hit and not rf[fill_key] then
        -- Compute unpadded bbox for fill (stroke padding shifts min_x0/min_y0)
        local fill_shifted, fpw, fph, fmin_x0, fmin_y0
        if need_stroke then
            fill_shifted, fpw, fph, fmin_x0, fmin_y0 = transform_and_prepare(polylines, matrix, 0)
        else
            fill_shifted, fpw, fph, fmin_x0, fmin_y0 = shifted, pw, ph, min_x0, min_y0
        end

        if is_live_resize then
            -- Live resize: stretch nearest cached texture to correct bbox.
            -- Use unpadded fill bbox (fmin_x0/fmin_y0), not stroke-padded.
            local approx = cache:get_best_fit(fill_family)
            if approx then
                fill_hit = {
                    tex_id = approx.tex_id, w = fpw, h = fph,
                    min_x0 = fmin_x0, min_y0 = fmin_y0,
                    src_buf = approx.buf, src_w = approx.w, src_h = approx.h,
                    _mask_entry = approx,
                }
            elseif fill_shifted then
                -- Cache miss on first frame: force rasterization rather than
                -- showing nothing. One rasterization cost is acceptable.
                local entry = cache:get_or_create(fill_key, fill_shifted, fpw, fph, fill_family, fill_rule)
                if entry then
                    fill_hit = { tex_id = entry.tex_id, w = fpw, h = fph, min_x0 = fmin_x0, min_y0 = fmin_y0, buf = entry.buf, _mask_entry = entry }
                    rc[fill_key] = fill_hit
                else
                    rf[fill_key] = true
                end
            end
        else
            -- Normal: rasterize and cache
            if fill_shifted then
                local entry = cache:get_or_create(fill_key, fill_shifted, fpw, fph, fill_family, fill_rule)
                if entry then
                    fill_hit = { tex_id = entry.tex_id, w = fpw, h = fph, min_x0 = fmin_x0, min_y0 = fmin_y0, buf = entry.buf, _mask_entry = entry }
                    rc[fill_key] = fill_hit
                else
                    rf[fill_key] = true
                end
            end
        end
    end

    -- Stroke
    if need_stroke and not stroke_hit and not rf[stroke_key] then
        -- Helper: tessellate + rasterize stroke from scratch
        local function rasterize_stroke()
            local is_closed = (tag == "polygon") or (d and d:match("[Zz]%s*$"))
            local stroke_polys = {}
            for pi = 1, #shifted do
                local tess = StrokeTessellator.tessellate(
                    shifted[pi], sw_px,
                    style.stroke_linecap, style.stroke_linejoin,
                    style.stroke_miterlimit, is_closed
                )
                for ti = 1, #tess do
                    stroke_polys[#stroke_polys + 1] = tess[ti]
                end
            end

            if #stroke_polys > 0 then
                local s_min_x, s_min_y = 1e9, 1e9
                local s_max_x, s_max_y = -1e9, -1e9
                for pi = 1, #stroke_polys do
                    local sp = stroke_polys[pi]
                    for i = 1, #sp do
                        if sp[i].x < s_min_x then s_min_x = sp[i].x end
                        if sp[i].y < s_min_y then s_min_y = sp[i].y end
                        if sp[i].x > s_max_x then s_max_x = sp[i].x end
                        if sp[i].y > s_max_y then s_max_y = sp[i].y end
                    end
                end

                local spw = math_max(1, math_floor(s_max_x - s_min_x + 0.5))
                local sph = math_max(1, math_floor(s_max_y - s_min_y + 0.5))

                local shifted_stroke = {}
                for pi = 1, #stroke_polys do
                    local sp = stroke_polys[pi]
                    local ss = {}
                    for i = 1, #sp do
                        ss[i] = { x = sp[i].x - s_min_x, y = sp[i].y - s_min_y }
                    end
                    shifted_stroke[pi] = ss
                end

                local entry = cache:get_or_create(stroke_key, shifted_stroke, spw, sph, stroke_family)
                if entry then
                    stroke_hit = {
                        tex_id = entry.tex_id, w = spw, h = sph,
                        min_x0 = s_min_x + min_x0, min_y0 = s_min_y + min_y0,
                        buf = entry.buf, _mask_entry = entry,
                    }
                    rc[stroke_key] = stroke_hit
                else
                    rf[stroke_key] = true
                end
            else
                rf[stroke_key] = true
            end
        end

        if is_live_resize then
            -- Live resize: stretch nearest cached stroke texture.
            local approx = cache:get_best_fit(stroke_family)
            if approx then
                stroke_hit = {
                    tex_id = approx.tex_id, w = pw, h = ph,
                    min_x0 = min_x0, min_y0 = min_y0,
                    src_buf = approx.buf, src_w = approx.w, src_h = approx.h,
                    _mask_entry = approx,
                }
            else
                -- Cache miss on first frame: force rasterization
                rasterize_stroke()
            end
        else
            -- Normal: tessellate stroke, rasterize, cache
            rasterize_stroke()
        end
    end

    -- Draw whatever we have
    if fill_hit then
        local fa = math_floor((fill[4] or 255) * opacity * style.fill_opacity + 0.5)
        if fa > 0 then
            draw_image_clipped(dl, fill_hit, tx, ty, fill[1], fill[2], fill[3], fa)
        end
    end
    if stroke_hit then
        local sa = math_floor((stroke[4] or 255) * opacity * style.stroke_opacity + 0.5)
        if sa > 0 then
            draw_image_clipped(dl, stroke_hit, tx, ty, stroke[1], stroke[2], stroke[3], sa)
        end
    end
end

------------------------------------------------------------
-- SVG text (basic support)
------------------------------------------------------------

function SvgRenderer._paint_text(attrs, matrix, style, opacity, dl)
    local tx_attr = tonumber(attrs.x) or 0
    local ty_attr = tonumber(attrs.y) or 0
    local text = attrs.text or attrs.content or ""
    if text == "" then return end

    local px, py = SvgTransform.apply(matrix, tx_attr, ty_attr)
    local font_size = tonumber(attrs["font-size"] or attrs.font_size) or 16
    local scale_f = SvgTransform.get_scale(matrix)
    font_size = math_floor(font_size * scale_f + 0.5)

    local fill = style.fill
    if fill and fill ~= "none" then
        local fa = math_floor((fill[4] or 255) * opacity * style.fill_opacity + 0.5)
        if fa > 0 then
            local family = attrs["font-family"] or attrs.font_family or SvgRenderer._default_font
            local weight = tonumber(attrs["font-weight"] or attrs.font_weight) or 400
            local font_style = attrs["font-style"] or attrs.font_style or "normal"
            local cache = SvgRenderer._font_manager and SvgRenderer._font_manager:get_cache_for(family, weight, font_style)
            if cache then
                local pen_x = px
                local baseline_y = py - font_size
                local prev_cp = nil
                for cp in Utf8.codes(text) do
                    if cache.get_kerning then
                        pen_x = pen_x + cache:get_kerning(prev_cp, cp, font_size)
                    end
                    local glyph = cache:get_glyph(cp, font_size, 0)
                    if glyph then
                        dl:image(glyph.tex_id,
                            math_floor(pen_x + 0.5) + glyph.offset_x,
                            math_floor(baseline_y + 0.5) + glyph.offset_y,
                            glyph.tex_w, glyph.tex_h,
                            fill[1], fill[2], fill[3], fa)
                        pen_x = pen_x + glyph.advance
                    else
                        pen_x = pen_x + cache:get_advance(cp, font_size)
                    end
                    prev_cp = cp
                end
            elseif not SvgRenderer.strict_self_drawn_text then
                dl:text(text, px, py - font_size, font_size, fill[1], fill[2], fill[3], fa)
            end
        end
    end
end

return SvgRenderer



