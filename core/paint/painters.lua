------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / painters.lua
-- Tree painting with proper clip management, background/
-- border/text rendering, text truncation, custom font
-- glyph rendering, image painting, gradient backgrounds,
-- and transform stack.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local TextWrap     = require("core/layout/text_wrap")
local Utf8         = require("core/util/utf8")
local Gradient     = require("core/paint/gradient")
local Transform    = require("core/paint/transform")
local Filters      = require("core/paint/filters")
local ClipPath     = require("core/paint/clip_path")
local MultiColumn  = require("core/layout/multicolumn")
local SvgRenderer  = require("core/svg/renderer")
local SvgConstants = require("core/svg/constants")
local GlyphCache   = require("core/fonts/glyph_cache")

local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor
local math_ceil  = math.ceil
local math_abs   = math.abs

local Painters = {}
local normalize_opacity

local function shape_text(cache, text)
    if cache.shape_text then
        return cache:shape_text(text, Utf8)
    end
    local cps = {}
    for cp in Utf8.codes(text or "") do
        cps[#cps + 1] = cp
    end
    return cps
end

-- Reusable array pools to eliminate per-frame allocations
local _z_pool = {}      -- pool of stride-3 z-index arrays
local _z_pool_n = 0
local _np_pool = {}     -- pool of non-positioned arrays
local _np_pool_n = 0
local _matrix_pool = {} -- pool of {a,b,c,d,e,f} matrix tables
local _matrix_pool_n = 0

local function _acquire_z_buf()
    if _z_pool_n > 0 then
        local buf = _z_pool[_z_pool_n]
        _z_pool_n = _z_pool_n - 1
        return buf
    end
    return {}
end

local function _release_z_buf(buf)
    _z_pool_n = _z_pool_n + 1
    _z_pool[_z_pool_n] = buf
end

local function _acquire_np_buf()
    if _np_pool_n > 0 then
        local buf = _np_pool[_np_pool_n]
        _np_pool_n = _np_pool_n - 1
        return buf
    end
    return {}
end

local function _release_np_buf(buf)
    _np_pool_n = _np_pool_n + 1
    _np_pool[_np_pool_n] = buf
end

local function _acquire_matrix()
    if _matrix_pool_n > 0 then
        local m = _matrix_pool[_matrix_pool_n]
        _matrix_pool_n = _matrix_pool_n - 1
        return m
    end
    return { 1, 0, 0, 1, 0, 0 }
end

local function _release_matrix(m)
    _matrix_pool_n = _matrix_pool_n + 1
    _matrix_pool[_matrix_pool_n] = m
end

-- Cached defaults to avoid per-frame allocations
local _default_center = { 0.5, 0.5 }
local _empty_stops    = {}

--- Static reference to FontManager, set by Engine.
Painters._font_manager = nil

--- Default font name (e.g. "inter"), set by Engine.
Painters._default_font = nil

--- Final UI text should use the deterministic GlyphCache pipeline.  Native
--- platform text is kept only as an explicit legacy escape hatch.
Painters.strict_self_drawn_text = true

local TEXT_BASELINE_AUDIT_CASES = {
    ["text-indent-first-line"] = true,
    ["tw-nowrap-overflow"] = true,
    ["tw-break-all"] = true,
    ["tw-overflow-wrap-break"] = true,
    ["oos-soft-hyphen"] = true,
    ["tw-normal-long"] = true,
    ["inline-mixed-runs"] = true,
    ["font-line-height-mixed"] = true,
}

local function baseline_audit_enabled()
    local g = _G
    if type(g) ~= "table" then return false end
    return type(g.__astro_baseline_snapshot) == "table"
        or type(g.__astro_debug_paint_capture) == "table"
end

local function find_parity_case_id(ns, nid)
    local cur = nid
    while cur and cur ~= 0 do
        local attrs = ns.attrs and ns.attrs[cur]
        local pid = attrs and attrs["data-parity-id"]
        if pid and TEXT_BASELINE_AUDIT_CASES[pid] then
            return pid
        end
        cur = ns.parent and ns.parent[cur] or 0
    end
    return nil
end

local function text_metric_source(cache)
    local font = cache and cache._font
    local os2 = font and font.os2
    if os2 and os2.sTypoAscender and os2.sTypoDescender and os2.sTypoLineGap then
        local fs = os2.fsSelection or 0
        if (math_floor(fs / 128) % 2) == 1 then
            return "os2.sTypo"
        end
    end
    return "hhea"
end

local function push_text_baseline_audit(entry)
    local g = _G
    if type(g) ~= "table" then return end
    local snap = g.__astro_baseline_snapshot
    if type(snap) == "table" and type(entry) == "table" then
        snap[#snap + 1] = entry
    end
    local cap = g.__astro_debug_paint_capture
    if type(cap) ~= "table" or type(entry) ~= "table" then return end
    cap[#cap + 1] = entry
end

local function begin_text_baseline_audit(ns, nid, meta)
    if not baseline_audit_enabled() then return false end
    local case_id = find_parity_case_id(ns, nid)
    if not case_id then return false end
    meta = meta or {}
    meta.case_name = case_id
    meta.node_id = nid
    Painters._text_baseline_audit = meta
    return true
end

local function end_text_baseline_audit(active)
    if active then
        Painters._text_baseline_audit = nil
    end
end

--- Static reference to IconCache, set by Engine.
Painters._icon_cache = nil

--- Static reference to TextureCache, set by Engine.
Painters._texture_cache = nil

--- Current window clip rect {x, y, w, h}, set by Engine per window.
Painters._clip_rect = nil

--- Per-mount base URL for resolving relative <img src>, background url(),
--- and other resource references.  Set by Engine before each paint_tree.
Painters._base_url = nil

local Url = require("core/util/url")

local function estimate_text_width(text, font_size)
    local n = 0
    for _ in Utf8.codes(text or "") do n = n + 1 end
    return n * (font_size or 16) * 0.5
end

function Painters.get_text_cache(font_family, font_weight, font_style)
    local fm = Painters._font_manager
    local family = font_family or Painters._default_font
    if not fm or not family then return nil, nil end
    local weight = font_weight or 400
    local style = font_style or "normal"
    local cache = fm:get_cache_for(family, weight, style)
    local fallback = nil
    if weight ~= 400 then fallback = fm:get_cache_for(family, 400, style) end
    return cache, fallback
end

function Painters.measure_text(text, font_size, font_family, font_weight, font_style)
    if not text or text == "" then return 0 end
    local cache = Painters.get_text_cache(font_family, font_weight, font_style)
    if cache then return cache:measure_text(text, font_size or 16, Utf8) end
    return estimate_text_width(text, font_size or 16)
end

function Painters.paint_text(dl, text, x, y, font_size, r, g, b, a, centered,
                            font_family, font_weight, font_style, cw, cx,
                            fallback_cache, clip_rect, extra_shear, transform_matrix)
    if not text or text == "" then return false end
    local cache, auto_fallback = Painters.get_text_cache(font_family, font_weight, font_style)
    fallback_cache = fallback_cache or auto_fallback
    if cache then
        Painters._paint_text_custom(dl, text, x, y, font_size or 16,
            r or 255, g or 255, b or 255, a == nil and 255 or a,
            centered == true, cw or 0, cx or 0, cache, 0, 0,
            font_style or "normal", fallback_cache, clip_rect,
            extra_shear or 0, transform_matrix)
        return true
    end
    if not Painters.strict_self_drawn_text then
        dl:text(text, x, y, font_size or 16,
            r or 255, g or 255, b or 255, a == nil and 255 or a,
            centered == true, 0)
        return true
    end
    return false
end

--- Resolve a src URL against the current mount's base URL.
--- Returns the src unchanged if it is absolute or there is no base.
local function resolve_src(src)
    if not src or src == "" then return src end
    if Url.is_absolute(src) then return src end
    local base = Painters._base_url
    if not base or base == "" then return src end
    return Url.resolve(base, src)
end

--- Active resolved clip-path shape for the currently painting node.
--- Set before paint_node() is called when a clip-path is active.
--- nil means no clip-path shape masking (normal rectangular painting).
Painters._active_clip_shape = nil

--- Transform state: a complete layout→screen affine matrix.
--- nil = no transform active (identity).
--- The matrix maps absolute layout coordinates directly to screen coordinates,
--- with the translate-to-origin / translate-from-origin baked in.
Painters._transform_matrix = nil
Painters._transform_stack = {}

------------------------------------------------------------
-- Transform stack helpers
------------------------------------------------------------

--- Push a child transform.  Builds a full layout→screen matrix by
--- wrapping the child's raw matrix with translate(nx,ny) / translate(-nx,-ny),
--- then composing with the parent's accumulated matrix.
---@param child_matrix table  raw matrix from Transform.resolve (node-local space)
---@param nx number  absolute layout x of the node
---@param ny number  absolute layout y of the node
local function push_transform(child_matrix, nx, ny)
    local stack = Painters._transform_stack
    stack[#stack + 1] = Painters._transform_matrix

    -- Build full matrix: translate(nx,ny) * M * translate(-nx,-ny)
    local m = child_matrix
    local mt = _acquire_matrix()
    mt[1] = m[1]; mt[2] = m[2]; mt[3] = m[3]; mt[4] = m[4]
    mt[5] = m[1] * (-nx) + m[3] * (-ny) + m[5]
    mt[6] = m[2] * (-nx) + m[4] * (-ny) + m[6]

    local full = _acquire_matrix()
    full[1] = mt[1]; full[2] = mt[2]; full[3] = mt[3]; full[4] = mt[4]
    full[5] = mt[5] + nx; full[6] = mt[6] + ny

    _release_matrix(mt)  -- mt is temporary

    -- Compose with parent
    local parent_m = Painters._transform_matrix
    if parent_m then
        local result = _acquire_matrix()
        -- Transform.mul inlined to avoid allocation
        result[1] = parent_m[1]*full[1] + parent_m[3]*full[2]
        result[2] = parent_m[2]*full[1] + parent_m[4]*full[2]
        result[3] = parent_m[1]*full[3] + parent_m[3]*full[4]
        result[4] = parent_m[2]*full[3] + parent_m[4]*full[4]
        result[5] = parent_m[1]*full[5] + parent_m[3]*full[6] + parent_m[5]
        result[6] = parent_m[2]*full[5] + parent_m[4]*full[6] + parent_m[6]
        _release_matrix(full)
        Painters._transform_matrix = result
    else
        Painters._transform_matrix = full
    end
end

local function pop_transform()
    local stack = Painters._transform_stack
    local n = #stack
    local old = Painters._transform_matrix
    if old then _release_matrix(old) end
    Painters._transform_matrix = stack[n]
    stack[n] = nil
end

--- Extract horizontal shear (skewX component) from the current transform matrix.
--- Returns 0 when no transform is active or when transform has no skew.
--- The shear value is tan(angle) which is exactly what glyph_cache expects.
local function get_transform_shear()
    local m = Painters._transform_matrix
    if not m then return 0 end
    -- m[3] = c component of affine matrix = tan(skewX) for a skew transform
    -- For pure rotation, m[3] = -sin(angle) which would also cause shearing,
    -- but rotation is already handled by rotated_corners. We extract the
    -- skew component specifically: skew_x = atan2(m[3], m[4])
    -- For a pure skewX(a): m = {1, 0, tan(a), 1, tx, ty} → m[3] = tan(a), m[4] = 1
    -- For identity or translate: m[3] = 0
    local c = m[3]
    if math_abs(c) < 0.001 then return 0 end
    return c
end

--- Apply the accumulated transform to absolute layout coords.
--- The matrix is a complete layout→screen mapping, so we apply directly.
--- Returns x, y, w, h (AABB of transformed rect).
local function apply_transform(x, y, w, h)
    local m = Painters._transform_matrix
    if not m then return x, y, w, h end
    if not Transform.has_rotation(m) then
        -- Axis-aligned transforms may still have negative scale. Transform
        -- both opposite corners so the AABB lands on the correct side.
        local x1, y1 = Transform.apply_point(m, x, y)
        local x2, y2 = Transform.apply_point(m, x + w, y + h)
        return math_min(x1, x2), math_min(y1, y2), math_abs(x2 - x1), math_abs(y2 - y1)
    end
    -- Rotation: compute 4 transformed corners, return AABB
    local x1, y1 = Transform.apply_point(m, x, y)
    local x2, y2 = Transform.apply_point(m, x + w, y)
    local x3, y3 = Transform.apply_point(m, x + w, y + h)
    local x4, y4 = Transform.apply_point(m, x, y + h)
    return Transform.aabb(x1, y1, x2, y2, x3, y3, x4, y4)
end

------------------------------------------------------------
-- Tree painting (custom walk with clip push/pop)
------------------------------------------------------------

--- Paint the full DOM tree depth-first.
---@param node_store   table  NodeStore instance
---@param root_id      number root node id
---@param display_list table  DisplayList instance
---@param platform     table  Platform adapter instance
function Painters.paint_tree(node_store, root_id, display_list, platform)
    if root_id == 0 then return end

    local ns = node_store
    local dl = display_list

    -- Reset transform stack
    Painters._transform_stack = {}
    Painters._transform_matrix = nil
    Painters._opacity_stack = {}
    Painters._current_opacity = 255

    -- Viewport culling: skip nodes entirely outside the window clip rect
    local vp = Painters._clip_rect
    local vp_x, vp_y, vp_w, vp_h
    if vp then
        vp_x, vp_y, vp_w, vp_h = vp[1], vp[2], vp[3], vp[4]
    end

    -- Deferred fixed nodes (painted last, no clip)
    local fixed_defer = {}

    -- Parallel stacks to avoid per-entry table allocation
    local stack_nid = {}     -- node id
    local stack_leave = {}   -- false = enter, true = leave
    local stack_clip = {}    -- clip_path_pushed (for leave entries)
    local sp = 0
    local clipped = {}
    local transformed = {}  -- nid -> true if we pushed a transform
    local blended = {}      -- nid -> true if we pushed a blend mode

    sp = sp + 1
    stack_nid[sp] = root_id; stack_leave[sp] = false

    while sp > 0 do
        local nid    = stack_nid[sp]
        local action = stack_leave[sp]
        local clip_extra = stack_clip[sp]
        stack_clip[sp] = nil
        sp = sp - 1

        if action then  -- true = leave
            -- Pop clip if we pushed one for this node
            if clipped[nid] then
                dl:clip_pop()
                clipped[nid] = nil
            end
            -- Pop clip-path if we pushed one
            if clip_extra then
                dl:clip_pop()
                Painters._active_clip_shape = nil
            end
            -- Paint column rules after children for multi-column containers
            local mc_comp = ns.computed[nid]
            if mc_comp and (mc_comp.column_count or mc_comp.column_width) then
                MultiColumn.paint_rules(ns, nid, dl)
            end
            -- Pop transform if we pushed one
            if transformed[nid] then
                pop_transform()
                transformed[nid] = nil
            end
            -- Pop blend mode if we pushed one
            if blended[nid] then
                dl:blend_pop()
                blended[nid] = nil
            end
            local op_stack = Painters._opacity_stack
            if op_stack and op_stack[nid] ~= nil then
                Painters._current_opacity = op_stack[nid]
                op_stack[nid] = nil
            end
        else
            -- "enter": paint this node
            local computed = ns.computed[nid]
            local lay      = ns.layout[nid]

            if computed and lay then
                local vis = computed.visibility or "visible"
                local disp = computed.display or "block"
                local node_pos = computed.position or "static"

                -- Viewport culling: skip LEAF nodes entirely outside the viewport.
                -- Only cull leaf nodes (no children) without transforms to avoid
                -- hiding absolutely positioned descendants, fixed descendants
                -- (which are viewport-relative), or transformed elements.
                local culled = false
                if vp_x and not Painters._transform_matrix
                   and node_pos ~= "fixed" and node_pos ~= "absolute"
                   and not computed.transform
                then
                    local fc = ns.first_child[nid]
                    if not fc or fc == 0 then
                        -- Leaf node without transform: safe to cull
                        -- Expand bounds for box_shadow / outline overflow
                        local cull_m = 0
                        if computed.box_shadow then cull_m = 50 end
                        local _cow = computed.outline_width
                        if _cow and _cow > cull_m then cull_m = _cow + 2 end
                        local nx, ny = lay.x - cull_m, lay.y - cull_m
                        local nw, nh = lay.w + cull_m * 2, lay.h + cull_m * 2
                        if nx + nw < vp_x or nx > vp_x + vp_w
                           or ny + nh < vp_y or ny > vp_y + vp_h then
                            culled = true
                        end
                    end
                end

                if culled then
                    -- Entirely outside viewport -" skip node and all children

                -- Defer fixed nodes to paint last (on top, no clip)
                elseif node_pos == "fixed" and nid ~= root_id then
                    fixed_defer[#fixed_defer + 1] = nid
                    -- Skip normal painting - will be painted deferred
                elseif vis ~= "hidden" and disp ~= "none" and lay.w > 0 and lay.h > 0 then
                    local local_opacity = normalize_opacity(computed.opacity)
                    local prev_opacity = Painters._current_opacity or 255
                    local node_opacity = math_floor(prev_opacity * local_opacity / 255 + 0.5)
                    Painters._opacity_stack[nid] = prev_opacity
                    Painters._current_opacity = prev_opacity

                    -- Check for transform
                    local has_transform = false
                    if computed.transform then
                        local origin_x = lay.w / 2
                        local origin_y = lay.h / 2
                        if computed.transform_origin then
                            local to = computed.transform_origin
                            if type(to) == "table" then
                                origin_x = to[1] or origin_x
                                origin_y = to[2] or origin_y
                            end
                        end
                        local _, _, _, _, matrix = Transform.resolve(computed.transform, origin_x, origin_y)
                        if matrix then
                            push_transform(matrix, lay.x, lay.y)
                            has_transform = true
                            transformed[nid] = true
                        end
                    end

                    -- Apply clip-path if set
                    local clip_path_pushed = false
                    if computed.clip_path then
                        local parsed_cp = ClipPath.parse(computed.clip_path)
                        if parsed_cp then
                            clip_path_pushed = ClipPath.push_clip(dl, parsed_cp, lay)
                            -- Resolve shape for visual masking in paint_node
                            Painters._active_clip_shape = ClipPath.resolve(parsed_cp, lay)
                        end
                    end

                    -- Backdrop-filter approximation (frosted-glass overlay)
                    -- Real pixel blur is impossible without framebuffer access.
                    -- Instead: sample nearest ancestor bg color, then paint a
                    -- strong tinted overlay that hides content and adds a
                    -- lightened "frosted" layer on top.
                    if computed.backdrop_filter then
                        local parsed_bf = Filters.parse(computed.backdrop_filter)
                        if parsed_bf then
                            local br = computed.border_radius or 0
                            local bd_blur = Filters.get_blur_radius(parsed_bf)
                            if bd_blur and bd_blur > 0 then
                                -- Sample the visually "behind" color.
                                -- Check previous siblings first (they paint behind
                                -- this absolute element), then walk up parents.
                                local bg_r, bg_g, bg_b = 128, 128, 128
                                local found_bg = false
                                -- Check previous siblings
                                local pid = ns.parent[nid]
                                if pid and pid ~= 0 then
                                    local fc = ns.first_child[pid]
                                    if fc then
                                        local sib = fc
                                        while sib ~= 0 and sib ~= nid do
                                            local sc = ns.computed[sib]
                                            if sc then
                                                -- Check background_image gradient first (midpoint sample)
                                                -- For multi-background arrays, use the first (topmost) layer
                                                local _bi = sc.background_image
                                                if _bi and type(_bi) == "table" and not _bi.type and _bi[1] then _bi = _bi[1] end
                                                if _bi and type(_bi) == "table" and _bi.stops then
                                                    local stops = _bi.stops
                                                    if #stops > 0 then
                                                        local mid = stops[math.ceil(#stops / 2)]
                                                        if mid and mid[2] then
                                                            bg_r, bg_g, bg_b = mid[2][1], mid[2][2], mid[2][3]
                                                            found_bg = true
                                                        end
                                                    end
                                                end
                                                -- Check solid background_color
                                                if not found_bg and sc.background_color then
                                                    local c = sc.background_color
                                                    if type(c) == "table" and c[1] and c[4] and c[4] > 100 then
                                                        bg_r, bg_g, bg_b = c[1], c[2], c[3]
                                                        found_bg = true
                                                    end
                                                end
                                            end
                                            sib = ns.next_sibling[sib]
                                        end
                                    end
                                end
                                -- Fall back to ancestor bg color
                                if not found_bg then
                                    local anc = pid
                                    while anc and anc ~= 0 do
                                        local ac = ns.computed[anc]
                                        if ac and ac.background_color then
                                            local c = ac.background_color
                                            if type(c) == "table" and c[1] then
                                                bg_r, bg_g, bg_b = c[1], c[2], c[3]
                                                break
                                            end
                                        end
                                        anc = ns.parent[anc]
                                    end
                                end
                                -- Layer 1: solid ancestor-color fill to fully obscure
                                -- content behind (alpha 230 = nearly opaque)
                                dl:rect_fill(lay.x, lay.y, lay.w, lay.h,
                                    bg_r, bg_g, bg_b, 230, br)
                                -- Layer 2: lighter "frost" tint -" blend towards white
                                -- Strength scales with blur radius
                                local strength = math_min(bd_blur / 12, 1)
                                local frost_a = math_floor(40 + strength * 80)
                                dl:rect_fill(lay.x, lay.y, lay.w, lay.h,
                                    255, 255, 255, frost_a, br)
                            end
                            -- Color transforms: tinted overlay (respects border-radius)
                            for fi = 1, #parsed_bf do
                                local f = parsed_bf[fi]
                                if f.type == "grayscale" and f.value > 0 then
                                    dl:rect_fill(lay.x, lay.y, lay.w, lay.h,
                                        128, 128, 128, math_floor(f.value * 80), br)
                                elseif f.type == "brightness" and f.value < 1 then
                                    dl:rect_fill(lay.x, lay.y, lay.w, lay.h,
                                        0, 0, 0, math_floor((1 - f.value) * 180), br)
                                elseif f.type == "sepia" and f.value > 0 then
                                    dl:rect_fill(lay.x, lay.y, lay.w, lay.h,
                                        112, 66, 20, math_floor(f.value * 60), br)
                                end
                            end
                        end
                    end

                    -- Apply filter effects (painted behind/over element)
                    if computed.filter then
                        local parsed_f = Filters.parse(computed.filter)
                        -- Drop shadow (behind element)
                        local ds = Filters.get_drop_shadow(parsed_f)
                        if ds then
                            Filters.apply_drop_shadow(dl, lay.x, lay.y, lay.w, lay.h,
                                ds.x, ds.y, ds.blur, ds.color)
                        end
                        -- Blur approximation (translucent overlay)
                        local blur_r = Filters.get_blur_radius(parsed_f)
                        if blur_r and blur_r > 0 then
                            local bg = computed.background_color
                            local br, bg2, bb, ba = 128, 128, 128, 80
                            if bg and type(bg) == "table" and bg[1] then
                                br = bg[1]; bg2 = bg[2]; bb = bg[3]; ba = bg[4]
                            end
                            Filters.apply_blur_rects(dl, lay.x, lay.y, lay.w, lay.h,
                                blur_r, br, bg2, bb, ba)
                        end
                    end

                    -- Blend mode: push if non-normal (before any painting path)
                    local blend_mode = computed.mix_blend_mode
                    if blend_mode and blend_mode ~= "normal" then
                        dl:blend_push(blend_mode)
                        blended[nid] = true
                    end

                    -- Skip SVG child nodes (painted by SVG renderer)
                    local tag_id_p = ns.tag[nid]
                    local tag_str_p = ns._st:get(tag_id_p)
                    if SvgConstants.is_svg_child(tag_str_p) then
                        -- SVG children are painted by SvgRenderer, not here
                        if has_transform or clip_path_pushed or blended[nid] or Painters._opacity_stack[nid] ~= nil then
                            sp = sp + 1
                            stack_nid[sp] = nid; stack_leave[sp] = true; stack_clip[sp] = clip_path_pushed
                        end
                    else

                    -- Paint this node's background, border, text
                    Painters.paint_node(ns, nid, dl, platform)
                    Painters._current_opacity = node_opacity

                    -- SVG root: paint SVG subtree and skip normal child walk
                    if tag_str_p == "svg" then
                        -- Compute visible rect from ancestor overflow clips
                        local vr = nil
                        local anc = ns.parent[nid]
                        while anc and anc ~= 0 do
                            local ac = ns.computed[anc]
                            if ac then
                                local ox = ac.overflow_x or "visible"
                                local anc_is_root = (not ns.parent[anc]) or (ns.parent[anc] == 0)
                                local oy = ac.overflow_y or (anc_is_root and "auto" or "visible")
                                if ox ~= "visible" or oy ~= "visible" then
                                    local al = ns.layout[anc]
                                    if al then
                                        -- Use padding box for overflow clip (CSS spec)
                                        local ar = { x = al.pad_x or al.content_x,
                                                     y = al.pad_y or al.content_y,
                                                     w = al.pad_w or al.content_w,
                                                     h = al.pad_h or al.content_h }
                                        if not vr then
                                            vr = ar
                                        else
                                            local x1 = math_max(vr.x, ar.x)
                                            local y1 = math_max(vr.y, ar.y)
                                            local x2 = math_min(vr.x + vr.w, ar.x + ar.w)
                                            local y2 = math_min(vr.y + vr.h, ar.y + ar.h)
                                            if x2 > x1 and y2 > y1 then
                                                vr = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
                                            else
                                                vr = { x = 0, y = 0, w = 0, h = 0 }
                                            end
                                        end
                                    end
                                end
                            end
                            anc = ns.parent[anc]
                        end
                        -- Also intersect with window clip rect
                        local wcr = Painters._clip_rect
                        if wcr then
                            local wr = { x = wcr[1], y = wcr[2], w = wcr[3], h = wcr[4] }
                            if not vr then
                                vr = wr
                            else
                                local x1 = math_max(vr.x, wr.x)
                                local y1 = math_max(vr.y, wr.y)
                                local x2 = math_min(vr.x + vr.w, wr.x + wr.w)
                                local y2 = math_min(vr.y + vr.h, wr.y + wr.h)
                                if x2 > x1 and y2 > y1 then
                                    vr = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
                                else
                                    vr = { x = 0, y = 0, w = 0, h = 0 }
                                end
                            end
                        end
                        SvgRenderer.paint_svg_subtree(ns, nid, dl, platform, vr)
                        if has_transform or clip_path_pushed or blended[nid] or Painters._opacity_stack[nid] ~= nil then
                            sp = sp + 1
                            stack_nid[sp] = nid; stack_leave[sp] = true; stack_clip[sp] = clip_path_pushed
                        end
                    else

                    -- Check if we need to push a clip for overflow
                    -- Root node defaults to overflow_y:auto (like Chrome's <html>)
                    local paint_is_root = (not ns.parent[nid]) or (ns.parent[nid] == 0)
                    local ov_x = computed.overflow_x or "visible"
                    local ov_y_v = computed.overflow_y or (paint_is_root and "auto" or "visible")
                    local needs_clip = (ov_x == "hidden" or ov_x == "scroll" or ov_x == "auto")
                                    or (ov_y_v == "hidden" or ov_y_v == "scroll" or ov_y_v == "auto")

                    -- Collect children into CSS stacking order groups:
                    --   1. Positioned, negative z-index (ascending by z)
                    --   2. Non-positioned + positioned with z-index:auto (DOM order)
                    --   3. Positioned, z-index >= 0 (ascending by z, DOM order for ties)
                    -- CSS spec: z-index:auto does NOT create a stacking context,
                    -- so auto-positioned elements paint in DOM order with non-positioned.
                    -- Scroll-Virtualization: for scroll/auto containers, determine
                    -- the visible viewport so we can skip painting off-screen children.
                    -- Only in-flow children (static/relative) are culled; absolute/fixed
                    -- children are always painted.  A buffer of 1-- viewport height is
                    -- used to avoid popping artefacts during fast scrolling.
                    local sv_active = false
                    local sv_top, sv_bottom
                    if needs_clip and not Painters._transform_matrix then
                        local sv_ov = computed.overflow_y or "visible"
                        if sv_ov == "scroll" or sv_ov == "auto" then
                            local sv_y = lay.pad_y or lay.content_y
                            local sv_h = lay.pad_h or lay.content_h
                            if sv_h and sv_h > 0 then
                                sv_active = true
                                sv_top    = sv_y - sv_h       -- 1-- buffer above
                                sv_bottom = sv_y + sv_h + sv_h -- 1-- buffer below
                            end
                        end
                    end

                    -- Stacking context: collect children into paint-order groups.
                    -- neg_z/pos_z use stride-3 flat arrays {cid,zi,dom, cid,zi,dom,...}
                    -- to avoid per-child tuple allocation.
                    local neg_z   = _acquire_z_buf()
                    local non_pos = _acquire_np_buf()
                    local pos_z   = _acquire_z_buf()
                    local neg_n, np_n, pz_n = 0, 0, 0
                    local dom_idx = 0
                    local cid = ns.first_child[nid]
                    if not cid then cid = 0 end
                    while cid ~= 0 do
                        dom_idx = dom_idx + 1
                        local c_comp = ns.computed[cid]
                        local c_pos = c_comp and c_comp.position or "static"

                        -- Scroll-Virtualization: skip in-flow LEAF children outside viewport.
                        -- Only cull leaf nodes (no children) to avoid hiding absolutely
                        -- positioned descendants.  Never cull transformed children.
                        local sv_skip = false
                        if sv_active and c_pos ~= "absolute" and c_pos ~= "fixed"
                           and not (c_comp and c_comp.transform) then
                            local fc = ns.first_child[cid]
                            if not fc or fc == 0 then
                                -- Leaf node: safe to cull
                                local c_lay = ns.layout[cid]
                                if c_lay then
                                    local cy = c_lay.y
                                    local ch = c_lay.h
                                    if cy + ch < sv_top or cy > sv_bottom then
                                        sv_skip = true
                                    end
                                end
                            end
                        end

                        if sv_skip then
                            -- Off-screen: do not add to any paint group
                        elseif c_pos == "relative" or c_pos == "absolute" or c_pos == "sticky" then
                            local zi = c_comp and c_comp.z_index
                            if zi == "auto" or zi == nil then
                                np_n = np_n + 1
                                non_pos[np_n] = cid
                            elseif type(zi) == "number" and zi < 0 then
                                local base = neg_n * 3
                                neg_z[base + 1] = cid
                                neg_z[base + 2] = zi
                                neg_z[base + 3] = dom_idx
                                neg_n = neg_n + 1
                            else
                                local z_num = (type(zi) == "number") and zi or 0
                                local base = pz_n * 3
                                pos_z[base + 1] = cid
                                pos_z[base + 2] = z_num
                                pos_z[base + 3] = dom_idx
                                pz_n = pz_n + 1
                            end
                        else
                            np_n = np_n + 1
                            non_pos[np_n] = cid
                        end
                        cid = ns.next_sibling[cid] or 0
                    end

                    -- Sort positioned groups by z-index (stable: DOM order for ties)
                    -- Insertion sort on stride-3 flat arrays (typically very few entries)
                    if neg_n > 1 then
                        for i = 1, neg_n - 1 do
                            for j = i + 1, neg_n do
                                local ai, aj = (i-1)*3, (j-1)*3
                                local swap = false
                                if neg_z[aj+2] < neg_z[ai+2] then swap = true
                                elseif neg_z[aj+2] == neg_z[ai+2] and neg_z[aj+3] < neg_z[ai+3] then swap = true end
                                if swap then
                                    neg_z[ai+1], neg_z[aj+1] = neg_z[aj+1], neg_z[ai+1]
                                    neg_z[ai+2], neg_z[aj+2] = neg_z[aj+2], neg_z[ai+2]
                                    neg_z[ai+3], neg_z[aj+3] = neg_z[aj+3], neg_z[ai+3]
                                end
                            end
                        end
                    end
                    if pz_n > 1 then
                        for i = 1, pz_n - 1 do
                            for j = i + 1, pz_n do
                                local ai, aj = (i-1)*3, (j-1)*3
                                local swap = false
                                if pos_z[aj+2] < pos_z[ai+2] then swap = true
                                elseif pos_z[aj+2] == pos_z[ai+2] and pos_z[aj+3] < pos_z[ai+3] then swap = true end
                                if swap then
                                    pos_z[ai+1], pos_z[aj+1] = pos_z[aj+1], pos_z[ai+1]
                                    pos_z[ai+2], pos_z[aj+2] = pos_z[aj+2], pos_z[ai+2]
                                    pos_z[ai+3], pos_z[aj+3] = pos_z[aj+3], pos_z[ai+3]
                                end
                            end
                        end
                    end

                    local cn = neg_n + np_n + pz_n
                    if cn > 0 then
                        if needs_clip then
                            -- CSS spec: overflow clips to the padding box, not content box.
                            local clip_x = lay.pad_x or lay.content_x
                            local clip_y = lay.pad_y or lay.content_y
                            local clip_w = lay.pad_w or lay.content_w
                            local clip_h = lay.pad_h or lay.content_h
                            -- Pass background color for image masking
                            local bg = computed.background_color
                            if bg then
                                dl:clip_push(clip_x, clip_y, clip_w, clip_h,
                                             bg[1], bg[2], bg[3], bg[4] or 255)
                            else
                                dl:clip_push(clip_x, clip_y, clip_w, clip_h)
                            end
                            clipped[nid] = true
                        end

                        sp = sp + 1
                        stack_nid[sp] = nid; stack_leave[sp] = true; stack_clip[sp] = clip_path_pushed

                        -- Push in reverse paint order (stack is LIFO):
                        -- 3. Positioned z >= 0 (painted last = on top)
                        for i = pz_n, 1, -1 do
                            sp = sp + 1
                            stack_nid[sp] = pos_z[(i-1)*3 + 1]; stack_leave[sp] = false
                        end
                        -- 2. Non-positioned (DOM order)
                        for i = np_n, 1, -1 do
                            sp = sp + 1
                            stack_nid[sp] = non_pos[i]; stack_leave[sp] = false
                        end
                        -- 1. Positioned, negative z-index (painted first = underneath)
                        for i = neg_n, 1, -1 do
                            sp = sp + 1
                            stack_nid[sp] = neg_z[(i-1)*3 + 1]; stack_leave[sp] = false
                        end
                        -- Release pooled buffers (children are now on the stack)
                        _release_z_buf(neg_z)
                        _release_np_buf(non_pos)
                        _release_z_buf(pos_z)
                    elseif has_transform or clip_path_pushed or blended[nid] or Painters._opacity_stack[nid] ~= nil then
                        -- No children but has transform/clip-path/blend: push leave to pop it
                        sp = sp + 1
                        stack_nid[sp] = nid; stack_leave[sp] = true; stack_clip[sp] = clip_path_pushed
                        -- Release pooled buffers (no children to paint)
                        _release_z_buf(neg_z)
                        _release_np_buf(non_pos)
                        _release_z_buf(pos_z)
                    else
                        -- No children, no transform/clip: still need to release
                        _release_z_buf(neg_z)
                        _release_np_buf(non_pos)
                        _release_z_buf(pos_z)
                    end

                    end -- close SVG root check
                    end -- close SVG child check
                end
            end
        end
    end

    -- Stash deferred fixed nodes on the node store so the engine can paint
    -- them AFTER scrollbars / component paints -" fixed content (e.g. modal
    -- dialogs) must sit on top of everything else.
    ns._pending_fixed_paint = fixed_defer
end

--- Paint any deferred fixed nodes that were collected during the last
--- paint_tree call.  Called by the engine after scrollbars so fixed
--- content like modals doesn't get drawn over by scrollbars or overlays.
---@param ns       table
---@param dl       table
---@param platform table
function Painters.paint_fixed_deferred(ns, dl, platform)
    local list = ns._pending_fixed_paint
    if not list then return end
    ns._pending_fixed_paint = nil
    local i = 1
    while i <= #list do
        Painters.paint_tree(ns, list[i], dl, platform)
        local nested = ns._pending_fixed_paint
        ns._pending_fixed_paint = nil
        if nested then
            for j = 1, #nested do
                list[#list + 1] = nested[j]
            end
        end
        i = i + 1
    end
end

--- Paint a subtree (used for deferred fixed nodes).
---@param ns  table  NodeStore
---@param nid number root of subtree
---@param dl  table  DisplayList
---@param platform table
function Painters._paint_subtree(ns, nid, dl, platform)
    local computed = ns.computed[nid]
    local lay = ns.layout[nid]
    if not computed or not lay then return end
    if computed.visibility == "hidden" or computed.display == "none" then return end
    if lay.w <= 0 or lay.h <= 0 then return end

    -- Blend mode: push if non-normal
    local blend_mode = computed.mix_blend_mode
    local has_blend = blend_mode and blend_mode ~= "normal"
    if has_blend then
        dl:blend_push(blend_mode)
    end

    Painters.paint_node(ns, nid, dl, platform)

    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        Painters._paint_subtree(ns, cid, dl, platform)
        cid = ns.next_sibling[cid] or 0
    end

    if has_blend then
        dl:blend_pop()
    end
end

------------------------------------------------------------
-- Border edge painting (solid, dashed, dotted)
------------------------------------------------------------

--- Paint a single border edge with style support.
---@param dl    table  DisplayList
---@param x1    number start x
---@param y1    number start y
---@param x2    number end x
---@param y2    number end y
---@param thick number line thickness
---@param r     number red
---@param g     number green
---@param b     number blue
---@param a     number alpha
---@param style string "solid"|"dashed"|"dotted"
function Painters._paint_border_edge(dl, x1, y1, x2, y2, thick, r, g, b, a, style)
    local dx = x2 - x1
    local dy = y2 - y1
    local is_horiz = math.abs(dx) >= math.abs(dy)

    if style == "solid" then
        if is_horiz then
            local x = math.min(x1, x2)
            dl:rect_fill(x, y1 - thick / 2, math.abs(dx), thick, r, g, b, a, 0)
        else
            local y = math.min(y1, y2)
            dl:rect_fill(x1 - thick / 2, y, thick, math.abs(dy), r, g, b, a, 0)
        end
        return
    end

    local len = math.sqrt(dx * dx + dy * dy)
    if len <= 0 then return end

    local ux, uy = dx / len, dy / len

    if style == "dashed" then
        local dash = thick * 3
        local gap = thick * 2
        local cycle = dash + gap
        local pos = 0
        while pos < len do
            local seg_end = pos + dash
            if seg_end > len then seg_end = len end
            if is_horiz then
                local sx = x1 + ux * pos
                local ex = x1 + ux * seg_end
                local x = math.min(sx, ex)
                dl:rect_fill(x, y1 - thick / 2, math.abs(ex - sx), thick, r, g, b, a, 0)
            else
                local sy = y1 + uy * pos
                local ey = y1 + uy * seg_end
                local y = math.min(sy, ey)
                dl:rect_fill(x1 - thick / 2, y, thick, math.abs(ey - sy), r, g, b, a, 0)
            end
            pos = pos + cycle
        end
    elseif style == "dotted" then
        local dot_size = thick
        local gap = thick * 2
        local cycle = dot_size + gap
        local pos = 0
        while pos < len do
            local cx = x1 + ux * pos
            local cy = y1 + uy * pos
            if is_horiz then
                dl:rect_fill(cx, cy - thick / 2, dot_size, thick, r, g, b, a, 0)
            else
                dl:rect_fill(cx - thick / 2, cy, thick, dot_size, r, g, b, a, 0)
            end
            pos = pos + cycle
        end
    elseif style == "double" then
        -- Two parallel solid stripes, each ~1/3 of the thickness with a
        -- ~1/3-thick gap between them (CSS 2.1 §8.5.3).  Falls back to a
        -- single stripe if the thickness is too small to split.
        local t1 = math.floor(thick / 3)
        if t1 < 1 then t1 = 1 end
        local t2 = t1
        local gap = thick - t1 - t2
        if gap < 1 then
            -- not enough room -" paint solid
            if is_horiz then
                local x = math.min(x1, x2)
                dl:rect_fill(x, y1 - thick / 2, math.abs(dx), thick, r, g, b, a, 0)
            else
                local y = math.min(y1, y2)
                dl:rect_fill(x1 - thick / 2, y, thick, math.abs(dy), r, g, b, a, 0)
            end
        elseif is_horiz then
            local x = math.min(x1, x2)
            local top_y = y1 - thick / 2
            dl:rect_fill(x, top_y, math.abs(dx), t1, r, g, b, a, 0)
            dl:rect_fill(x, top_y + thick - t2, math.abs(dx), t2, r, g, b, a, 0)
        else
            local y = math.min(y1, y2)
            local left_x = x1 - thick / 2
            dl:rect_fill(left_x, y, t1, math.abs(dy), r, g, b, a, 0)
            dl:rect_fill(left_x + thick - t2, y, t2, math.abs(dy), r, g, b, a, 0)
        end
    elseif style == "groove" or style == "ridge" or style == "inset" or style == "outset" then
        -- Chrome's 3D border styles split the thickness into two stripes
        -- with contrasting shades of the declared color.  Without the
        -- side-of-box context (this function paints a single edge), we
        -- approximate by always rendering outer-then-inner with the
        -- darker shade where the style calls for it.  Pixel-perfect
        -- groove/ridge requires per-edge polarity, which is correct on
        -- ~99% of the visual outcome (the eye reads it as 3D anyway).
        local dark_r = math.floor(r * 0.55)
        local dark_g = math.floor(g * 0.55)
        local dark_b = math.floor(b * 0.55)
        local light_r = math.min(255, math.floor(r + (255 - r) * 0.45))
        local light_g = math.min(255, math.floor(g + (255 - g) * 0.45))
        local light_b = math.min(255, math.floor(b + (255 - b) * 0.45))
        local o_r, o_g, o_b, i_r, i_g, i_b
        if style == "groove" or style == "inset" then
            o_r, o_g, o_b = dark_r, dark_g, dark_b
            i_r, i_g, i_b = light_r, light_g, light_b
        else
            o_r, o_g, o_b = light_r, light_g, light_b
            i_r, i_g, i_b = dark_r, dark_g, dark_b
        end
        local t1 = math.floor(thick / 2)
        if t1 < 1 then t1 = 1 end
        local t2 = thick - t1
        if t2 < 1 then t2 = 1 end
        if is_horiz then
            local x = math.min(x1, x2)
            local top_y = y1 - thick / 2
            dl:rect_fill(x, top_y, math.abs(dx), t1, o_r, o_g, o_b, a, 0)
            dl:rect_fill(x, top_y + t1, math.abs(dx), t2, i_r, i_g, i_b, a, 0)
        else
            local y = math.min(y1, y2)
            local left_x = x1 - thick / 2
            dl:rect_fill(left_x, y, t1, math.abs(dy), o_r, o_g, o_b, a, 0)
            dl:rect_fill(left_x + t1, y, t2, math.abs(dy), i_r, i_g, i_b, a, 0)
        end
    else
        -- Unknown style: fall back to solid
        if is_horiz then
            local x = math.min(x1, x2)
            dl:rect_fill(x, y1 - thick / 2, math.abs(dx), thick, r, g, b, a, 0)
        else
            local y = math.min(y1, y2)
            dl:rect_fill(x1 - thick / 2, y, thick, math.abs(dy), r, g, b, a, 0)
        end
    end
end

------------------------------------------------------------
-- Box shadow painting
------------------------------------------------------------

--- Paint box shadows (before background).
---@param dl       table  DisplayList
---@param x        number element x
---@param y        number element y
---@param w        number element width
---@param h        number element height
---@param shadow   table  shadow value or array of shadows
---@param opacity  number 0-255
---@param radius   number border_radius
function Painters._paint_box_shadow(dl, x, y, w, h, shadow, opacity, radius)
    -- Detect single vs multiple shadows
    local shadows
    if shadow[1] and type(shadow[1]) == "table" then
        shadows = shadow  -- multiple
    else
        shadows = { shadow }  -- single
    end

    local opacity_factor = (opacity or 255) / 255

    -- Paint in reverse order (first shadow on top)
    for si = #shadows, 1, -1 do
        local s = shadows[si]
        local off_x = s[1] or 0
        local off_y = s[2] or 0
        local blur  = s[3] or 0
        local spread = s[4] or 0
        local clr   = s[5] or { 0, 0, 0, 128 }

        local sr = clr[1] or 0
        local sg = clr[2] or 0
        local sb = clr[3] or 0
        local sa = clr[4] or 128

        local sx = x + off_x - spread
        local sy = y + off_y - spread
        local sw = w + spread * 2
        local sh = h + spread * 2

        if blur <= 0 then
            -- No blur: single rect
            local a = math.floor(sa * opacity_factor)
            dl:rect_fill(sx, sy, sw, sh, sr, sg, sb, a, radius)
        else
            -- Approximate blur with concentric rings
            local steps = math.floor(blur)
            if steps < 4 then steps = 4 end
            if steps > 32 then steps = 32 end

            for i = steps, 0, -1 do
                local t = i / steps
                local expand = blur * t
                local ring_x = sx - expand
                local ring_y = sy - expand
                local ring_w = sw + expand * 2
                local ring_h = sh + expand * 2
                -- Alpha fades from 0 (outer) to full (inner)
                local ring_a = math.floor(sa * (1 - t) * opacity_factor / steps)
                if ring_a > 0 and ring_w > 0 and ring_h > 0 then
                    dl:rect_fill(ring_x, ring_y, ring_w, ring_h, sr, sg, sb, ring_a, radius)
                end
            end
        end
    end
end

------------------------------------------------------------
-- Single node painting
------------------------------------------------------------

--- Paint a single node's visual content (background, border, text, image).
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance
--- Paint a filled rectangle respecting current rotation matrix.
--- Uses triangle_fill when rotation is active, rect_fill otherwise.
--- IMPORTANT: ox, oy, ow, oh must be the ORIGINAL (pre-transform)
--- absolute layout coords.  The matrix is applied here.
local function rotated_rect_fill(dl, ox, oy, ow, oh, r, g, b, a, radius)
    local m = Painters._transform_matrix
    if m and Transform.has_rotation(m) then
        -- Scanline fill: rasterize rotated quad as 1px-high axis-aligned
        -- rect strips. Zero seam artifacts since each strip is a single
        -- rect_fill call. Cost: O(height) rect_fills per rotated element.
        local x1, y1 = Transform.apply_point(m, ox, oy)
        local x2, y2 = Transform.apply_point(m, ox + ow, oy)
        local x3, y3 = Transform.apply_point(m, ox + ow, oy + oh)
        local x4, y4 = Transform.apply_point(m, ox, oy + oh)

        local min_y = math.floor(math.min(y1, y2, y3, y4))
        local max_y = math.ceil(math.max(y1, y2, y3, y4))

        -- Quad edges: {x_start, y_start, x_end, y_end}
        local e1x, e1y, e1x2, e1y2 = x1, y1, x2, y2
        local e2x, e2y, e2x2, e2y2 = x2, y2, x3, y3
        local e3x, e3y, e3x2, e3y2 = x3, y3, x4, y4
        local e4x, e4y, e4x2, e4y2 = x4, y4, x1, y1

        for sy = min_y, max_y - 1 do
            local scan = sy + 0.5
            local lo, hi = 1e9, -1e9

            -- Intersect scanline with each of the 4 edges
            local function edge_isect(ax, ay, bx, by)
                if (ay <= scan and by > scan) or (by <= scan and ay > scan) then
                    local t = (scan - ay) / (by - ay)
                    local ix = ax + t * (bx - ax)
                    if ix < lo then lo = ix end
                    if ix > hi then hi = ix end
                end
            end
            edge_isect(e1x, e1y, e1x2, e1y2)
            edge_isect(e2x, e2y, e2x2, e2y2)
            edge_isect(e3x, e3y, e3x2, e3y2)
            edge_isect(e4x, e4y, e4x2, e4y2)

            if hi > lo then
                dl:rect_fill(lo, sy, hi - lo, 1, r, g, b, a, 0)
            end
        end
    else
        -- Apply axis-aligned transform
        local tx, ty, tw, th = apply_transform(ox, oy, ow, oh)
        dl:rect_fill(tx, ty, tw, th, r, g, b, a, radius or 0)
    end
end

local function split_ws(value)
    local out = {}
    if type(value) ~= "string" then return out end
    for tok in value:gmatch("%S+") do out[#out + 1] = tok end
    return out
end

local function parse_css_length(tok, axis_len)
    if type(tok) ~= "string" then return nil end
    local pct = tok:match("^([%d%.%-]+)%%$")
    if pct then return axis_len * (tonumber(pct) or 0) / 100, "percent" end
    local px = tok:match("^([%d%.%-]+)px$") or tok:match("^([%d%.%-]+)$")
    if px then return tonumber(px), "length" end
    return nil
end

local function bg_axis_from_tokens(tokens, is_x, area_len, image_len)
    local start_kw = is_x and "left" or "top"
    local end_kw = is_x and "right" or "bottom"
    local other_start = is_x and "top" or "left"
    local other_end = is_x and "bottom" or "right"
    local kw = nil
    local offset = nil
    local value = nil
    local mode = nil

    local function take_token(tok, next_tok)
        if tok == start_kw or tok == end_kw or tok == "center" then
            kw = tok
            local n, m = parse_css_length(next_tok, area_len)
            if n then offset = n end
            return true
        end
        if tok ~= other_start and tok ~= other_end then
            local n, m = parse_css_length(tok, area_len)
            if n then
                value = n
                mode = m
                return true
            end
        end
        return false
    end

    if #tokens >= 4 then
        local i = 1
        while i <= #tokens do
            if take_token(tokens[i], tokens[i + 1]) then
                if parse_css_length(tokens[i + 1] or "", area_len) then i = i + 2 else i = i + 1 end
            else
                i = i + 1
            end
        end
    elseif #tokens == 1 then
        local t = tokens[1]
        if is_x then
            if t == "top" or t == "bottom" then kw = "center" else take_token(t) end
        else
            if t == "left" or t == "right" then kw = "center" else take_token(t) end
        end
    else
        local t = is_x and tokens[1] or tokens[2]
        take_token(t)
    end

    if kw == "center" then
        return (area_len - image_len) * 0.5
    elseif kw == end_kw then
        return area_len - image_len - (offset or 0)
    elseif kw == start_kw then
        return offset or 0
    elseif value ~= nil then
        if mode == "percent" then
            local pct = area_len ~= 0 and value / area_len or 0
            return (area_len - image_len) * pct
        end
        return value
    end

    return 0
end

local function resolve_bg_image_rect(tex, bx, by, bw, bh, bg_size, bg_position)
    local iw = tex and tex.w or 0
    local ih = tex and tex.h or 0
    if iw <= 0 or ih <= 0 or bw <= 0 or bh <= 0 then
        return bx, by, bw, bh
    end

    local dw, dh = iw, ih
    local size = bg_size or "auto"
    if size == "cover" then
        local scale = math_max(bw / iw, bh / ih)
        dw = iw * scale
        dh = ih * scale
    elseif size == "contain" then
        local scale = math_min(bw / iw, bh / ih)
        dw = iw * scale
        dh = ih * scale
    elseif type(size) == "string" and size ~= "" and size ~= "auto" then
        local parts = split_ws(size)
        local function resolve_part(p, axis_len, intrinsic)
            if not p or p == "auto" then return nil end
            if p == "cover" or p == "contain" then return nil end
            local pct = p:match("^([%d%.%-]+)%%$")
            if pct then return axis_len * (tonumber(pct) or 0) / 100 end
            local px = p:match("^([%d%.%-]+)px$") or p:match("^([%d%.%-]+)$")
            if px then return tonumber(px) end
            return intrinsic
        end
        local rw = resolve_part(parts[1], bw, iw)
        local rh = resolve_part(parts[2], bh, ih)
        if rw and rh then
            dw, dh = rw, rh
        elseif rw then
            dw = rw
            dh = rw * ih / iw
        elseif rh then
            dh = rh
            dw = rh * iw / ih
        end
    end

    local pt = split_ws(bg_position or "0% 0%")
    local dx = bx + bg_axis_from_tokens(pt, true, bw, dw)
    local dy = by + bg_axis_from_tokens(pt, false, bh, dh)
    return dx, dy, dw, dh
end

local function resolve_bg_repeat(bg_repeat)
    local rep = bg_repeat or "repeat"
    if rep == "repeat-x" then return true, false end
    if rep == "repeat-y" then return false, true end
    local parts = split_ws(rep)
    local x = parts[1] or rep
    local y = parts[2] or x
    return x == "repeat", y == "repeat"
end

--- Paint a single background-image layer (gradient or url).
--- @param dl       display list
--- @param layer    table with .type field (single gradient/url descriptor)
--- @param bx       number background x
--- @param by       number background y
--- @param bw       number background width
--- @param bh       number background height
--- @param opacity  number element opacity (0-255)
--- @param layer_idx number|nil layer index for cache key disambiguation (nil for single)
function Painters._paint_bg_layer(dl, layer, bx, by, bw, bh, opacity, bg_size, bg_position, bg_repeat, clip_radius)
    if not layer or not layer.type then return end
    local ltype = layer.type
    if ltype == "linear-gradient" then
        Gradient.paint_linear(dl, bx, by, bw, bh,
            layer.angle or 180,
            layer.stops or _empty_stops,
            opacity, nil,
            layer.repeating)
    elseif ltype == "radial-gradient" then
        dl:clip_push(bx, by, bw, bh)
        Gradient.paint_radial(dl, bx, by, bw, bh,
            layer.center or _default_center,
            layer.stops or _empty_stops,
            opacity,
            layer.shape or "ellipse",
            layer.size or "farthest-corner",
            layer.repeating,
            clip_radius)
        dl:clip_pop()
    elseif ltype == "conic-gradient" then
        dl:clip_push(bx, by, bw, bh)
        Gradient.paint_conic(dl, bx, by, bw, bh,
            layer.stops or _empty_stops,
            layer.cx or 0.5,
            layer.cy or 0.5,
            layer.from_angle or 0,
            opacity,
            layer.repeating)
        dl:clip_pop()
    elseif ltype == "url" and Painters._texture_cache then
        local tex = Painters._texture_cache:get(resolve_src(layer.url))
        if tex then
            local ix, iy, iw, ih = resolve_bg_image_rect(tex, bx, by, bw, bh, bg_size, bg_position)
            dl:clip_push(bx, by, bw, bh)
            local repeat_x, repeat_y = resolve_bg_repeat(bg_repeat)
            if repeat_x or repeat_y then
                local step_x = iw > 0 and iw or bw
                local step_y = ih > 0 and ih or bh
                local start_x = ix
                local start_y = iy
                if repeat_x then while start_x > bx do start_x = start_x - step_x end end
                if repeat_y then while start_y > by do start_y = start_y - step_y end end
                local yy = start_y
                while yy < by + bh do
                    local xx = start_x
                    while xx < bx + bw do
                        dl:image(tex.tex_id, xx, yy, iw, ih, 255, 255, 255, opacity)
                        if not repeat_x then break end
                        xx = xx + step_x
                    end
                    if not repeat_y then break end
                    yy = yy + step_y
                end
            else
                dl:image(tex.tex_id, ix, iy, iw, ih, 255, 255, 255, opacity)
            end
            dl:clip_pop()
        end
    end
end

local function color_array(c, fallback)
    if type(c) == "table" and c.type == "color" then c = c.v end
    if type(c) == "table" and c.type == "light_dark" then
        c = c.dark or c.light
    end
    if type(c) ~= "table" then c = fallback end
    fallback = fallback or { 0, 0, 0, 255 }
    return {
        c[1] or fallback[1] or 0,
        c[2] or fallback[2] or 0,
        c[3] or fallback[3] or 0,
        c[4] or fallback[4] or 255,
    }
end

normalize_opacity = function(opacity)
    if opacity == nil then return 255 end
    if opacity <= 1 then
        opacity = opacity * 255
    end
    if opacity < 0 then return 0 end
    if opacity > 255 then return 255 end
    return opacity
end

function Painters.paint_node(ns, nid, dl, platform)
    local computed = ns.computed[nid]
    local lay      = ns.layout[nid]
    if not computed or not lay then return end
    if baseline_audit_enabled() then
        Painters._current_paint_ns = ns
        Painters._current_paint_nid = nid
    end

    local x, y, w, h = lay.x, lay.y, lay.w, lay.h

    -- Apply accumulated transform
    x, y, w, h = apply_transform(x, y, w, h)

    local opacity = normalize_opacity(computed.opacity)
    local tree_opacity = Painters._current_opacity
    if tree_opacity then
        opacity = math.floor(opacity * tree_opacity / 255 + 0.5)
    end

    -- Resolve per-corner border-radius.
    -- CSS spec: percentage radii resolve against the border-box dimension -"
    -- horizontal radius against width, vertical against height.  We
    -- intentionally collapse to a single uniform pixel value per corner
    -- here (the engine doesn't model elliptical corners separately), using
    -- min(w,h) as the scaling axis so `border-radius: 50%` produces a
    -- proper circle on square elements and a stadium on rectangular ones
    -- -" matching how Chrome / Firefox visually clamp the radius to
    -- min(w,h)/2.  Without this step the painter previously forwarded the
    -- raw `"50%"` string straight into `dl:rect_fill(..., rounding)`, and
    -- the platform draw_manager (which expects a numeric pixel value)
    -- treated it as 0, producing rectangular shapes and rectangular box
    -- shadows on circular elements (R8 / 2026-05-23 bridge probe).
    local function _resolve_radius(val, w_dim, h_dim)
        if type(val) == "number" then return val end
        if type(val) ~= "string" then return 0 end
        local pct = val:match("^(-?[%d%.]+)%%$")
        if pct then
            local n = tonumber(pct)
            if not n then return 0 end
            local base = math.min(w_dim or 0, h_dim or 0)
            if base <= 0 then return 0 end
            return base * n / 100
        end
        local px = val:match("^(-?[%d%.]+)px$") or val:match("^(-?[%d%.]+)$")
        return tonumber(px) or 0
    end

    local r_uniform_raw = computed.border_radius or 0
    local r_tl_raw = computed.border_top_left_radius     or r_uniform_raw
    local r_tr_raw = computed.border_top_right_radius    or r_uniform_raw
    local r_br_raw = computed.border_bottom_right_radius or r_uniform_raw
    local r_bl_raw = computed.border_bottom_left_radius  or r_uniform_raw

    local r_tl = _resolve_radius(r_tl_raw, w, h)
    local r_tr = _resolve_radius(r_tr_raw, w, h)
    local r_br = _resolve_radius(r_br_raw, w, h)
    local r_bl = _resolve_radius(r_bl_raw, w, h)
    local all_corners_equal = (r_tl == r_tr and r_tr == r_br and r_br == r_bl)

    -- Box shadow (painted BEFORE background so bg covers inner overlap).
    -- Shorthand border-radius is expanded to per-corner fields, so use the
    -- resolved radius instead of only computed.border_radius.
    local shadow = computed.box_shadow
    if shadow then
        local shadow_radius = all_corners_equal and r_tl or math.max(r_tl, r_tr, r_br, r_bl)
        Painters._paint_box_shadow(dl, x, y, w, h, shadow, opacity, shadow_radius)
    end

    -- Background
    local bg = color_array(computed.background_color, { 0, 0, 0, 0 })
    local is_rotated = Painters._transform_matrix and Transform.has_rotation(Painters._transform_matrix)
    -- Only use clip_shape for THIS node's own clip-path, not inherited from parent
    local clip_shape = computed.clip_path and Painters._active_clip_shape or nil
    local bg_clip = computed.background_clip or "border-box"
    local bg_origin = computed.background_origin or "padding-box"
    local bg_attachment = computed.background_attachment or "scroll"

    -- Compute background clip rect adjustments for padding-box / content-box
    local bg_x, bg_y, bg_w, bg_h = x, y, w, h
    if bg_clip == "padding-box" then
        local bt_adj = computed.border_top_width or computed.border_width or 0
        local br_adj = computed.border_right_width or computed.border_width or 0
        local bb_adj = computed.border_bottom_width or computed.border_width or 0
        local bl_adj = computed.border_left_width or computed.border_width or 0
        bg_x = x + bl_adj
        bg_y = y + bt_adj
        bg_w = w - bl_adj - br_adj
        bg_h = h - bt_adj - bb_adj
    elseif bg_clip == "content-box" then
        local bt_adj = computed.border_top_width or computed.border_width or 0
        local br_adj = computed.border_right_width or computed.border_width or 0
        local bb_adj = computed.border_bottom_width or computed.border_width or 0
        local bl_adj = computed.border_left_width or computed.border_width or 0
        local pt_adj = computed.padding_top or 0
        local pr_adj = computed.padding_right or 0
        local pb_adj = computed.padding_bottom or 0
        local pl_adj = computed.padding_left or 0
        bg_x = x + bl_adj + pl_adj
        bg_y = y + bt_adj + pt_adj
        bg_w = w - bl_adj - br_adj - pl_adj - pr_adj
        bg_h = h - bt_adj - bb_adj - pt_adj - pb_adj
    end

    -- background-attachment: fixed -" positions the background relative to the
    -- window clip rect, so it does not scroll with the element.  Only applies
    -- to background-image painting; solid background-color is unchanged.
    local bg_img_x, bg_img_y, bg_img_w, bg_img_h = bg_x, bg_y, bg_w, bg_h
    if bg_attachment == "fixed" and Painters._clip_rect then
        local vp = Painters._clip_rect
        bg_img_x, bg_img_y = vp[1], vp[2]
        bg_img_w, bg_img_h = vp[3], vp[4]
    end
    -- background-origin shifts the gradient/image origin (vs the bg clip box).
    -- If origin differs from clip and not fixed, inset the bg_img box accordingly.
    if bg_attachment ~= "fixed" and bg_origin ~= bg_clip then
        local bt_adj = computed.border_top_width or computed.border_width or 0
        local br_adj = computed.border_right_width or computed.border_width or 0
        local bb_adj = computed.border_bottom_width or computed.border_width or 0
        local bl_adj = computed.border_left_width or computed.border_width or 0
        if bg_origin == "padding-box" then
            bg_img_x = x + bl_adj
            bg_img_y = y + bt_adj
            bg_img_w = w - bl_adj - br_adj
            bg_img_h = h - bt_adj - bb_adj
        elseif bg_origin == "content-box" then
            local pt_adj = computed.padding_top or 0
            local pr_adj = computed.padding_right or 0
            local pb_adj = computed.padding_bottom or 0
            local pl_adj = computed.padding_left or 0
            bg_img_x = x + bl_adj + pl_adj
            bg_img_y = y + bt_adj + pt_adj
            bg_img_w = w - bl_adj - br_adj - pl_adj - pr_adj
            bg_img_h = h - bt_adj - bb_adj - pt_adj - pb_adj
        elseif bg_origin == "border-box" then
            bg_img_x = x; bg_img_y = y; bg_img_w = w; bg_img_h = h
        end
    end

    -- For background-clip: text, skip background painting entirely
    -- (gradient colors will be applied to text glyphs instead)
    if bg_clip ~= "text" and bg then
        local bg_a = bg[4] or 0
        if bg_a > 0 then
            local a = math.floor(bg_a * opacity / 255)
            if clip_shape and clip_shape.type == "circle" then
                -- Circle clip-path: draw background as filled circle
                dl:circle_fill(clip_shape.cx, clip_shape.cy, clip_shape.r,
                    bg[1] or 0, bg[2] or 0, bg[3] or 0, a)
            elseif clip_shape and clip_shape.type == "ellipse" then
                -- Ellipse clip-path: approximate with rounded rect
                -- The bounding rect of the ellipse with full rounding gives
                -- a good visual approximation of the elliptical shape.
                local erx = clip_shape.rx
                local ery = clip_shape.ry
                local ex = clip_shape.cx - erx
                local ey = clip_shape.cy - ery
                local ew = erx * 2
                local eh = ery * 2
                local e_round = math_min(erx, ery)
                dl:rect_fill(ex, ey, ew, eh, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, e_round)
            elseif clip_shape and clip_shape.type == "inset" then
                -- Inset clip-path: draw background clipped to inset rect
                local ir = clip_shape.round or 0
                dl:rect_fill(clip_shape.x, clip_shape.y, clip_shape.w, clip_shape.h,
                    bg[1] or 0, bg[2] or 0, bg[3] or 0, a, ir)
            elseif clip_shape and clip_shape.type == "polygon" and dl.polygon_fill then
                dl:polygon_fill(clip_shape.points, bg[1] or 0, bg[2] or 0, bg[3] or 0, a)
            elseif is_rotated then
                -- Rotation active: use ORIGINAL layout coords (rotated_rect_fill applies matrix)
                rotated_rect_fill(dl, lay.x, lay.y, lay.w, lay.h, bg[1] or 0, bg[2] or 0, bg[3] or 0, a)
            elseif all_corners_equal then
                dl:rect_fill(bg_x, bg_y, bg_w, bg_h, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, r_tl)
            else
                -- Draw with max radius, then overlay square corners
                local r_max = math.max(r_tl, r_tr, r_br, r_bl)
                dl:rect_fill(bg_x, bg_y, bg_w, bg_h, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, r_max)
                -- Square off corners that should have less rounding
                if r_tl < r_max then
                    dl:rect_fill(bg_x, bg_y, r_max, r_max, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, r_tl)
                end
                if r_tr < r_max then
                    dl:rect_fill(bg_x + bg_w - r_max, bg_y, r_max, r_max, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, r_tr)
                end
                if r_br < r_max then
                    dl:rect_fill(bg_x + bg_w - r_max, bg_y + bg_h - r_max, r_max, r_max, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, r_br)
                end
                if r_bl < r_max then
                    dl:rect_fill(bg_x, bg_y + bg_h - r_max, r_max, r_max, bg[1] or 0, bg[2] or 0, bg[3] or 0, a, r_bl)
                end
            end
        end
    end

    -- Background image (gradients + URL)
    -- When background-clip is "text", skip painting the gradient as a background;
    -- instead the gradient colors will be sampled and applied to text glyphs.
    local bg_image = computed.background_image
    if bg_image and type(bg_image) == "table" and bg_clip ~= "text" then
        local bg_image_clipped = false
        if bg_attachment == "fixed" then
            dl:clip_push(bg_x, bg_y, bg_w, bg_h)
            bg_image_clipped = true
        end
        if bg_image.type then
            -- Single background layer (has .type field)
            Painters._paint_bg_layer(dl, bg_image, bg_img_x, bg_img_y, bg_img_w, bg_img_h, opacity,
                computed.background_size, computed.background_position, computed.background_repeat,
                all_corners_equal and r_tl or nil)
        elseif bg_image[1] then
            -- Multiple background layers (array without .type, has numeric keys)
            -- Paint in reverse order: CSS spec says first listed = topmost,
            -- so paint last layer first (bottom) to first layer last (top).
            for i = #bg_image, 1, -1 do
                Painters._paint_bg_layer(dl, bg_image[i], bg_img_x, bg_img_y, bg_img_w, bg_img_h, opacity,
                    computed.background_size, computed.background_position, computed.background_repeat,
                    all_corners_equal and r_tl or nil)
            end
        end
        if bg_image_clipped then
            dl:clip_pop()
        end
    end

    -- Border (per-side aware)
    -- Resolve tag early for legend/border-collapse checks
    local tag_id_early = ns.tag[nid]
    local tag_str_early = ns._st:get(tag_id_early)

    local bw_uniform = computed.border_width or 0
    local bt_w = computed.border_top_width    or bw_uniform
    local br_w = computed.border_right_width  or bw_uniform
    local bb_w = computed.border_bottom_width or bw_uniform
    local bl_w = computed.border_left_width   or bw_uniform

    -- Legend border break: detect fieldset with legend child
    local legend_gap_start, legend_gap_end
    if tag_str_early == "fieldset" then
        local fc = ns.first_child[nid]
        if fc and fc ~= 0 then
            local fc_tag = ns._st:get(ns.tag[fc])
            if fc_tag == "legend" then
                local legend_lay = ns.layout[fc]
                if legend_lay then
                    -- Use layout-space (lay.x) for consistent coordinates
                    local gap_s = legend_lay.x - lay.x
                    local gap_e = gap_s + (legend_lay.w or 0)
                    -- Clamp to drawable border interval
                    local min_x = bl_w
                    local max_x = w - br_w
                    legend_gap_start = math.max(min_x, math.min(gap_s, max_x))
                    legend_gap_end   = math.max(min_x, math.min(gap_e, max_x))
                end
            end
        end
    end

    -- Border-collapse: suppress inner borders for td/th in collapsed tables
    local collapse_suppress  -- nil unless border-collapse is active (lazy alloc)
    if tag_str_early == "td" or tag_str_early == "th" then
        -- Climb ancestors to find table element (handles tbody/thead/tfoot)
        local ancestor = ns.parent[nid]
        local table_nid = nil
        local tr_nid = nil
        while ancestor and ancestor ~= 0 do
            local anc_tag = ns._st:get(ns.tag[ancestor])
            if anc_tag == "tr" and not tr_nid then tr_nid = ancestor end
            if anc_tag == "table" or anc_tag == "table_el" then
                table_nid = ancestor
                break
            end
            ancestor = ns.parent[ancestor]
        end
        if table_nid then
            local table_computed = ns.computed[table_nid]
            if table_computed and table_computed.border_collapse == "collapse" then
                collapse_suppress = {}
                -- Suppress right border if has next sibling td/th
                local next_sib = ns.next_sibling[nid]
                if next_sib and next_sib ~= 0 then
                    local sib_tag = ns._st:get(ns.tag[next_sib])
                    if sib_tag == "td" or sib_tag == "th" then
                        collapse_suppress.right = true
                    end
                end
                -- Suppress bottom border if parent tr has next sibling
                if tr_nid then
                    local next_tr = ns.next_sibling[tr_nid]
                    if next_tr and next_tr ~= 0 then
                        collapse_suppress.bottom = true
                    end
                end
            end
        end
    end

    local has_border = (bt_w > 0 or br_w > 0 or bb_w > 0 or bl_w > 0)
    if has_border then
        local bc_uniform = color_array(computed.border_color, { 60, 60, 70, 255 })
        local bc_t = color_array(computed.border_top_color, bc_uniform)
        local bc_r = color_array(computed.border_right_color, bc_uniform)
        local bc_b = color_array(computed.border_bottom_color, bc_uniform)
        local bc_l = color_array(computed.border_left_color, bc_uniform)

        local bs_uniform = computed.border_style     or "solid"
        local bs_t = computed.border_top_style    or bs_uniform
        local bs_r = computed.border_right_style  or bs_uniform
        local bs_b = computed.border_bottom_style or bs_uniform
        local bs_l = computed.border_left_style   or bs_uniform

        local rounding = all_corners_equal and r_tl or math.max(r_tl, r_tr, r_br, r_bl)

        -- Apply border-collapse suppression
        if collapse_suppress then
            if collapse_suppress.right then br_w = 0 end
            if collapse_suppress.bottom then bb_w = 0 end
        end

        -- Clip-path-aware border: reshape border to match clip shape
        local clip_border_handled = false
        if clip_shape then
            local a = math.floor((bc_t[4] or 255) * opacity / 255)
            if clip_shape.type == "circle" then
                -- Approximate circle border: stroke a rounded rect inscribed in circle
                -- Use the circle's bounding rect with full rounding
                local cr = clip_shape.r
                local bx = clip_shape.cx - cr
                local by = clip_shape.cy - cr
                dl:rect_stroke(bx, by, cr * 2, cr * 2, bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bt_w, cr)
                clip_border_handled = true
            elseif clip_shape.type == "ellipse" then
                -- Approximate ellipse border with rounded rect
                local erx = clip_shape.rx
                local ery = clip_shape.ry
                local bx = clip_shape.cx - erx
                local by = clip_shape.cy - ery
                local e_round = math_min(erx, ery)
                dl:rect_stroke(bx, by, erx * 2, ery * 2, bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bt_w, e_round)
                clip_border_handled = true
            elseif clip_shape.type == "inset" then
                -- Inset border: draw border on the inset rect
                local ir = clip_shape.round or 0
                dl:rect_stroke(clip_shape.x, clip_shape.y, clip_shape.w, clip_shape.h,
                    bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bt_w, ir)
                clip_border_handled = true
            end
        end

        if not clip_border_handled then
        -- Check if legend gap or collapse needs per-side painting
        local needs_slow_path = legend_gap_start
            or bt_w ~= br_w or br_w ~= bb_w or bb_w ~= bl_w
            or bc_t ~= bc_r or bc_r ~= bc_b or bc_b ~= bc_l
            or bs_t ~= "solid" or bs_r ~= "solid" or bs_b ~= "solid" or bs_l ~= "solid"

        -- Fast path: all 4 sides identical and solid, no legend gap
        if not needs_slow_path then
            local a = math.floor((bc_t[4] or 255) * opacity / 255)
            dl:rect_stroke(x, y, w, h, bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bt_w, rounding)
        else
            -- Slow path: paint each side individually
            -- Top edge: with legend gap break if applicable
            if bt_w > 0 and bs_t ~= "none" and bs_t ~= "hidden" then
                local a = math.floor((bc_t[4] or 255) * opacity / 255)
                if legend_gap_start then
                    -- Left segment of top border (before legend)
                    if legend_gap_start > bl_w then
                        Painters._paint_border_edge(dl, x + bl_w, y + bt_w / 2, x + legend_gap_start, y + bt_w / 2, bt_w, bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bs_t)
                    end
                    -- Right segment of top border (after legend)
                    if legend_gap_end < w - br_w then
                        Painters._paint_border_edge(dl, x + legend_gap_end, y + bt_w / 2, x + w - br_w, y + bt_w / 2, bt_w, bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bs_t)
                    end
                else
                    Painters._paint_border_edge(dl, x + bl_w, y + bt_w / 2, x + w - br_w, y + bt_w / 2, bt_w, bc_t[1] or 60, bc_t[2] or 60, bc_t[3] or 70, a, bs_t)
                end
            end
            -- Bottom edge
            if bb_w > 0 and bs_b ~= "none" and bs_b ~= "hidden" then
                local a = math.floor((bc_b[4] or 255) * opacity / 255)
                Painters._paint_border_edge(dl, x + bl_w, y + h - bb_w / 2, x + w - br_w, y + h - bb_w / 2, bb_w, bc_b[1] or 60, bc_b[2] or 60, bc_b[3] or 70, a, bs_b)
            end
            -- Left edge
            if bl_w > 0 and bs_l ~= "none" and bs_l ~= "hidden" then
                local a = math.floor((bc_l[4] or 255) * opacity / 255)
                Painters._paint_border_edge(dl, x + bl_w / 2, y, x + bl_w / 2, y + h, bl_w, bc_l[1] or 60, bc_l[2] or 60, bc_l[3] or 70, a, bs_l)
            end
            -- Right edge
            if br_w > 0 and bs_r ~= "none" and bs_r ~= "hidden" then
                local a = math.floor((bc_r[4] or 255) * opacity / 255)
                Painters._paint_border_edge(dl, x + w - br_w / 2, y, x + w - br_w / 2, y + h, br_w, bc_r[1] or 60, bc_r[2] or 60, bc_r[3] or 70, a, bs_r)
            end
        end
        end -- clip_border_handled
    end

    -- Outline (drawn outside element, no layout impact)
    local ow = computed.outline_width or 0
    if ow > 0 then
        local oc = color_array(computed.outline_color or computed.color, { 220, 220, 220, 255 })
        local oo = computed.outline_offset or 0
        local os_v = computed.outline_style or "solid"
        if os_v ~= "none" and os_v ~= "hidden" then
            local oa = math.floor((oc[4] or 255) * opacity / 255)
            local ox = x - ow - oo
            local oy = y - ow - oo
            local o_w = w + (ow + oo) * 2
            local o_h = h + (ow + oo) * 2
            if os_v == "solid" then
                dl:rect_stroke(ox, oy, o_w, o_h, oc[1] or 220, oc[2] or 220, oc[3] or 220, oa, ow, 0)
            else
                -- Dashed/dotted outline: 4 edges
                Painters._paint_border_edge(dl, ox, oy + ow / 2, ox + o_w, oy + ow / 2, ow, oc[1] or 220, oc[2] or 220, oc[3] or 220, oa, os_v)
                Painters._paint_border_edge(dl, ox, oy + o_h - ow / 2, ox + o_w, oy + o_h - ow / 2, ow, oc[1] or 220, oc[2] or 220, oc[3] or 220, oa, os_v)
                Painters._paint_border_edge(dl, ox + ow / 2, oy, ox + ow / 2, oy + o_h, ow, oc[1] or 220, oc[2] or 220, oc[3] or 220, oa, os_v)
                Painters._paint_border_edge(dl, ox + o_w - ow / 2, oy, ox + o_w - ow / 2, oy + o_h, ow, oc[1] or 220, oc[2] or 220, oc[3] or 220, oa, os_v)
            end
        end
    end

    -- Image element painting
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)
    if tag_str == "img" and Painters._texture_cache then
        local attrs = ns.attrs[nid]
        local src = attrs and attrs.src
        if src then
            local resolved_src = resolve_src(src)
            local tex

            -- mask-image: url(...) -" composite source image with mask at CPU
            local mi = computed.mask_image
            if type(mi) == "table" and mi.type == "mask_image" and mi.url then
                local resolved_mask = resolve_src(mi.url)
                tex = Painters._texture_cache:get_masked(resolved_src, resolved_mask)
            else
                tex = Painters._texture_cache:get(resolved_src)
            end

            if tex then
                local cx = lay.content_x
                local cy = lay.content_y
                local cw = lay.content_w
                local ch = lay.content_h
                cx, cy, cw, ch = apply_transform(cx, cy, cw, ch)

                local object_fit = computed.object_fit or "fill"
                local draw_x, draw_y, draw_w, draw_h = cx, cy, cw, ch

                if object_fit == "contain" and tex.w > 0 and tex.h > 0 then
                    local aspect = tex.w / tex.h
                    local box_aspect = cw / ch
                    if aspect > box_aspect then
                        draw_w = cw
                        draw_h = cw / aspect
                        draw_y = cy + (ch - draw_h) / 2
                    else
                        draw_h = ch
                        draw_w = ch * aspect
                        draw_x = cx + (cw - draw_w) / 2
                    end
                elseif object_fit == "cover" and tex.w > 0 and tex.h > 0 then
                    local aspect = tex.w / tex.h
                    local box_aspect = cw / ch
                    if aspect < box_aspect then
                        draw_w = cw
                        draw_h = cw / aspect
                        draw_y = cy + (ch - draw_h) / 2
                    else
                        draw_h = ch
                        draw_w = ch * aspect
                        draw_x = cx + (cw - draw_w) / 2
                    end
                end
                -- "fill" is default: stretch to fill

                -- GPU scissor (pushed by parent overflow clips) handles
                -- pixel-level clipping. object-fit: cover can intentionally
                -- draw larger than the content box, so it needs its own clip.
                local image_clip_pushed = false
                if object_fit == "cover" and (draw_w > cw or draw_h > ch) then
                    dl:clip_push(cx, cy, cw, ch)
                    image_clip_pushed = true
                end
                dl:image(tex.tex_id, draw_x, draw_y, draw_w, draw_h, 255, 255, 255, opacity)
                if image_clip_pushed then
                    dl:clip_pop()
                end
            end
        end
    end

    -- List markers for <li> elements
    if tag_str == "li" then
        -- Read list-style-type from computed style (inherits from ul/ol)
        local list_style = computed.list_style_type
        -- Fallback: check parent attrs for backward compat
        if not list_style then
            local parent_nid = ns.parent[nid]
            if parent_nid and parent_nid ~= 0 then
                local parent_tag = ns._st:get(ns.tag[parent_nid])
                local parent_attrs = ns.attrs[parent_nid] or {}
                list_style = parent_attrs.list_style_type
                    or parent_attrs["list-style-type"]
                    or ((parent_tag == "ol") and "decimal" or "disc")
            else
                list_style = "disc"
            end
        end

        if list_style ~= "none" then
            local clr = computed.color or { 220, 220, 220, 255 }
            local fs = computed.font_size or 16
            -- ::marker override: pseudo._marker_style wins for color/font-size
            local node_pseudo = ns.pseudo[nid]
            local m_style = node_pseudo and node_pseudo._marker_style
            if m_style then
                if m_style.color then clr = m_style.color end
                if m_style.font_size and type(m_style.font_size) == "number" then
                    fs = m_style.font_size
                end
            end
            local marker_a = math.floor((clr[4] or 255) * opacity / 255)

            -- list-style-image: url(...) -" draw image instead of bullet/number
            local used_image_marker = false
            local lsi = computed.list_style_image
            if type(lsi) == "table" and lsi.type == "list_style_image" and lsi.url
               and Painters._texture_cache then
                local tex = Painters._texture_cache:get(resolve_src(lsi.url))
                if tex then
                    local size = math.floor(fs * 0.8)
                    local ix = lay.content_x - size - 4
                    local iy = lay.content_y + math.floor((fs - size) / 2)
                    dl:image(tex.tex_id, ix, iy, size, size, 255, 255, 255, marker_a)
                    used_image_marker = true
                end
            end
            if used_image_marker then list_style = "none" end  -- skip bullet/decimal
            local marker_y = lay.content_y + fs * 0.35
            local marker_x = lay.content_x - 14
            local list_pos = computed.list_style_position or "outside"

            -- O(1) cached list-item index (maintained by NodeStore on insert/remove)
            local li_index = ns.li_index[nid] or 1

            -- Roman numeral lookup
            local LOWER_ROMAN = {"i","ii","iii","iv","v","vi","vii","viii","ix","x",
                                 "xi","xii","xiii","xiv","xv","xvi","xvii","xviii","xix","xx"}

            -- For "inside" position, content_x is already indented by block.lua,
            -- so marker goes at the original (pre-indent) position
            local inside_marker_x = lay.content_x - 16
            local marker_font_family = computed.font_family or Painters._default_font
            local marker_font_weight = computed.font_weight or 400
            local marker_font_style = computed.font_style or "normal"
            local marker_glyph_cache = nil
            local marker_glyph_fallback = nil
            if marker_font_family and Painters._font_manager then
                marker_glyph_cache = Painters._font_manager:get_cache_for(marker_font_family, marker_font_weight, marker_font_style)
                if marker_font_weight ~= 400 then
                    marker_glyph_fallback = Painters._font_manager:get_cache_for(marker_font_family, 400, marker_font_style)
                end
            end

            local function marker_text_width(text)
                if marker_glyph_cache then
                    return marker_glyph_cache:measure_text(text, fs, Utf8)
                end
                return Painters.measure_text(text, fs, marker_font_family, marker_font_weight, marker_font_style)
            end

            local function paint_marker_text(text, x)
                if marker_glyph_cache then
                    Painters._paint_text_custom(dl, text, x, lay.content_y, fs,
                        clr[1] or 220, clr[2] or 220, clr[3] or 220, marker_a,
                        false, 0, 0, marker_glyph_cache, 0, 0, marker_font_style,
                        marker_glyph_fallback, Painters._clip_rect, get_transform_shear(),
                        Painters._transform_matrix)
                else
                    Painters.paint_text(dl, text, x, lay.content_y, fs,
                        clr[1] or 220, clr[2] or 220, clr[3] or 220, marker_a,
                        false, marker_font_family, marker_font_weight, marker_font_style,
                        0, 0, nil, Painters._clip_rect, get_transform_shear(),
                        Painters._transform_matrix)
                end
            end

            if list_style == "decimal" then
                local num_text = tostring(li_index) .. "."
                local num_w = marker_text_width(num_text)
                local num_x = list_pos == "inside" and inside_marker_x or (lay.content_x - num_w - 4)
                paint_marker_text(num_text, num_x)
            elseif list_style == "lower-alpha" then
                local num_text = string.char(96 + ((li_index - 1) % 26) + 1) .. "."
                local num_w = marker_text_width(num_text)
                local num_x = list_pos == "inside" and inside_marker_x or (lay.content_x - num_w - 4)
                paint_marker_text(num_text, num_x)
            elseif list_style == "upper-alpha" then
                local num_text = string.char(64 + ((li_index - 1) % 26) + 1) .. "."
                local num_w = marker_text_width(num_text)
                local num_x = list_pos == "inside" and inside_marker_x or (lay.content_x - num_w - 4)
                paint_marker_text(num_text, num_x)
            elseif list_style == "lower-roman" then
                local num_text = (LOWER_ROMAN[li_index] or tostring(li_index)) .. "."
                local num_w = marker_text_width(num_text)
                local num_x = list_pos == "inside" and inside_marker_x or (lay.content_x - num_w - 4)
                paint_marker_text(num_text, num_x)
            elseif list_style == "upper-roman" then
                local raw = LOWER_ROMAN[li_index] or tostring(li_index)
                local num_text = string.upper(raw) .. "."
                local num_w = marker_text_width(num_text)
                local num_x = list_pos == "inside" and inside_marker_x or (lay.content_x - num_w - 4)
                paint_marker_text(num_text, num_x)
            elseif list_style and ns._style_engine and ns._style_engine._counter_styles
                   and ns._style_engine._counter_styles[list_style] then
                -- Custom @counter-style: pick symbol by index modulo list length
                local cs = ns._style_engine._counter_styles[list_style]
                local syms = cs.symbols or {}
                local sys = cs.system or "cyclic"
                local sym
                if #syms > 0 then
                    if sys == "fixed" or sys == "cyclic" then
                        sym = syms[((li_index - 1) % #syms) + 1]
                    elseif sys == "numeric" then
                        -- Positional numeric system: decode li_index in base=#syms
                        local n = li_index
                        local base = #syms
                        if base <= 1 then
                            sym = syms[1] or tostring(li_index)
                        else
                            local parts = {}
                            while n > 0 do
                                parts[#parts + 1] = syms[(n % base) + 1]
                                n = math.floor(n / base)
                            end
                            -- Reverse
                            local rev = {}
                            for k = #parts, 1, -1 do rev[#rev + 1] = parts[k] end
                            sym = table.concat(rev)
                        end
                    elseif sys == "alphabetic" then
                        -- a, b, c, ... z, aa, ab, ...
                        local base = #syms
                        if base <= 0 then
                            sym = tostring(li_index)
                        else
                            local n = li_index
                            local parts = {}
                            while n > 0 do
                                n = n - 1
                                parts[#parts + 1] = syms[(n % base) + 1]
                                n = math.floor(n / base)
                            end
                            local rev = {}
                            for k = #parts, 1, -1 do rev[#rev + 1] = parts[k] end
                            sym = table.concat(rev)
                        end
                    else
                        sym = syms[((li_index - 1) % #syms) + 1]
                    end
                else
                    sym = tostring(li_index)
                end
                local full = (cs.prefix or "") .. (sym or "") .. (cs.suffix or ". ")
                local num_w = marker_text_width(full)
                local num_x = list_pos == "inside" and inside_marker_x or (lay.content_x - num_w - 4)
                paint_marker_text(full, num_x)
            elseif list_style == "disc" then
                local mx = list_pos == "inside" and inside_marker_x or marker_x
                dl:rect_fill(mx, marker_y, 5, 5, clr[1] or 220, clr[2] or 220, clr[3] or 220, marker_a, 3)
            elseif list_style == "circle" then
                local mx = list_pos == "inside" and inside_marker_x or marker_x
                dl:rect_stroke(mx, marker_y, 5, 5, clr[1] or 220, clr[2] or 220, clr[3] or 220, marker_a, 1, 3)
            elseif list_style == "square" then
                local mx = list_pos == "inside" and inside_marker_x or marker_x
                dl:rect_fill(mx, marker_y, 5, 5, clr[1] or 220, clr[2] or 220, clr[3] or 220, marker_a, 0)
            end
        end
    end

    -- <hr> horizontal rule
    if tag_str == "hr" then
        local hr_y = lay.y + (lay.h * 0.5)
        local hr_color = computed.border_color or computed.background_color
        if hr_color then
            local a = hr_color[4] or 255
            a = math.floor(a * opacity / 255 + 0.5)
            dl:rect_fill(lay.x, hr_y, lay.w, 1, hr_color[1], hr_color[2], hr_color[3], a)
        else
            dl:rect_fill(lay.x, hr_y, lay.w, 1, 128, 128, 128, math.floor(opacity + 0.5))
        end
    end

    -- Replaced element placeholders (iframe, video, audio)
    if tag_str == "iframe" then
        -- Dark placeholder with centered label
        local a_if = math_floor(200 * opacity / 255)
        dl:rect_fill(x, y, w, h, 30, 30, 30, a_if, 0)
        dl:rect_stroke(x, y, w, h, 80, 80, 80, a_if, 1, 0)
        local label = "iframe"
        local attrs_if = ns.attrs[nid]
        if attrs_if and attrs_if.src then
            label = "iframe: " .. tostring(attrs_if.src)
        end
        local fs_if = math_min(computed.font_size or 12, 12)
        Painters.paint_text(dl, label, x + 8, y + h * 0.5 - fs_if * 0.5, fs_if,
            120, 120, 120, a_if, false,
            computed.font_family, computed.font_weight, computed.font_style)
    elseif tag_str == "video" then
        -- Black placeholder with play triangle
        local a_v = math_floor(220 * opacity / 255)
        dl:rect_fill(x, y, w, h, 10, 10, 10, a_v, 0)
        -- Play triangle
        local tri_sz = math_min(w * 0.15, h * 0.3, 30)
        local cx_v, cy_v = x + w * 0.5, y + h * 0.5
        dl:triangle_fill(cx_v - tri_sz * 0.4, cy_v - tri_sz * 0.5,
                         cx_v - tri_sz * 0.4, cy_v + tri_sz * 0.5,
                         cx_v + tri_sz * 0.5, cy_v,
                         200, 200, 200, a_v)
        local fs_v = math_min(computed.font_size or 11, 11)
        Painters.paint_text(dl, "Video", x + 6, y + h - fs_v - 4, fs_v,
            140, 140, 140, a_v, false,
            computed.font_family, computed.font_weight, computed.font_style)
    elseif tag_str == "audio" then
        -- Small rounded bar
        local a_au = math_floor(220 * opacity / 255)
        dl:rect_fill(x, y, w, h, 40, 40, 40, a_au, 4)
        dl:rect_stroke(x, y, w, h, 70, 70, 70, a_au, 1, 4)
        -- Play icon (small triangle)
        local tri_au = math_min(h * 0.4, 10)
        dl:triangle_fill(x + 10, y + h * 0.5 - tri_au * 0.5,
                         x + 10, y + h * 0.5 + tri_au * 0.5,
                         x + 10 + tri_au, y + h * 0.5,
                         180, 180, 180, a_au)
        -- Track bar
        local bar_x = x + 10 + tri_au + 8
        local bar_w = w - (10 + tri_au + 8) - 10
        if bar_w > 0 then
            local bar_h = 3
            local bar_y = y + h * 0.5 - bar_h * 0.5
            dl:rect_fill(bar_x, bar_y, bar_w, bar_h, 80, 80, 80, a_au, 2)
            dl:rect_fill(bar_x, bar_y, bar_w * 0.3, bar_h, 120, 120, 120, a_au, 2)
        end
    end

    -- Placeholder text for empty input/textarea elements
    local attrs_ph = ns.attrs[nid]
    local text_content_raw = ns.text_content[nid]
    if attrs_ph and attrs_ph.placeholder and (not text_content_raw or text_content_raw == "") then
        local ph_text = attrs_ph.placeholder
        if ph_text and ph_text ~= "" then
            local pseudo_ph = ns.pseudo[nid]
            local ph_style = pseudo_ph and pseudo_ph._placeholder_style
            local ph_color = (ph_style and ph_style.color) or { 150, 150, 160, 255 }
            local ph_font_size = (ph_style and ph_style.font_size) or computed.font_size or 16
            local ph_font_style = (ph_style and ph_style.font_style) or "normal"
            local ph_a = math_floor((ph_color[4] or 255) * opacity / 255)
            local ph_cx, ph_cy = lay.content_x, lay.content_y
            local ph_cw, ph_ch = lay.content_w, lay.content_h
            -- Per-glyph transform for placeholder text in skewed containers
            local ph_xform = nil
            do
                local m = Painters._transform_matrix
                if m and Transform.has_rotation(m) then
                    ph_xform = m
                end
            end
            if not ph_xform then
                ph_cx, ph_cy, ph_cw, ph_ch = apply_transform(ph_cx, ph_cy, ph_cw, ph_ch)
            end
            local ph_italic = (ph_font_style == "italic" or ph_font_style == "oblique")
            local ph_font_family = (ph_style and ph_style.font_family) or computed.font_family or Painters._default_font
            local ph_font_weight = (ph_style and ph_style.font_weight) or computed.font_weight or 400
            local ph_glyph_cache = nil
            local ph_glyph_fallback = nil
            if ph_font_family and Painters._font_manager then
                ph_glyph_cache = Painters._font_manager:get_cache_for(ph_font_family, ph_font_weight, ph_font_style)
                if ph_font_weight ~= 400 then
                    ph_glyph_fallback = Painters._font_manager:get_cache_for(ph_font_family, 400, ph_font_style)
                end
            end
            if ph_glyph_cache then
                Painters._paint_text_custom(dl, ph_text, ph_cx, ph_cy,
                    ph_font_size, ph_color[1], ph_color[2], ph_color[3], ph_a,
                    false, ph_cw, ph_cx, ph_glyph_cache, 0, 0,
                    ph_font_style, ph_glyph_fallback, Painters._clip_rect, get_transform_shear(), ph_xform)
            else
                Painters.paint_text(dl, ph_text, ph_cx, ph_cy, ph_font_size,
                    ph_color[1], ph_color[2], ph_color[3], ph_a,
                    false, ph_font_family, ph_font_weight, ph_font_style,
                    ph_cw, ph_cx, nil, Painters._clip_rect, get_transform_shear(), ph_xform)
            end
        end
    end

    -- Text content (multi-line wrapping)
    local text = ns.text_content[nid]
    -- Clip text for leaf nodes with overflow (e.g. textarea)
    local text_clip_pushed = false
    local ov_y_leaf = computed.overflow_y or "visible"
    local ov_x_leaf = computed.overflow_x or "visible"
    local leaf_needs_clip = (ov_y_leaf == "auto" or ov_y_leaf == "scroll" or ov_y_leaf == "hidden")
                         or (ov_x_leaf == "auto" or ov_x_leaf == "scroll" or ov_x_leaf == "hidden")
    if text and text ~= "" and leaf_needs_clip then
        local clip_x, clip_y, clip_w, clip_h = lay.content_x, lay.content_y, lay.content_w, lay.content_h
        if tag_str == "input" or tag_str == "select" then
            clip_x, clip_y, clip_w, clip_h = lay.x, lay.y, lay.w, lay.h
        end
        local bg = computed.background_color
        if bg then
            dl:clip_push(clip_x, clip_y, clip_w, clip_h,
                         bg[1], bg[2], bg[3], bg[4] or 255)
        else
            dl:clip_push(clip_x, clip_y, clip_w, clip_h)
        end
        text_clip_pushed = true
    end
    -- C-lite inline text fragment short-circuit. When inline.lua had to
    -- split a `<span>`'s single TEXT child across a line break to match
    -- browser word-wrap behavior, it wrote `lay.fragments = {{text,x,y,w,h},...}`
    -- on the TEXT child. Paint each fragment as a single-line text at its
    -- pre-computed position and skip the wrap-based path entirely -" that
    -- path expects every line to start at content_x, which is wrong for
    -- the first fragment (which continues at the end of an earlier line).
    if text and text ~= "" and lay.fragments and #lay.fragments > 0 then
        local font_size = computed.font_size or 16
        if type(font_size) ~= "number" then font_size = 16 end
        local clr = computed.color or { 220, 220, 220, 255 }
        local r_c, g_c, b_c = clr[1] or 220, clr[2] or 220, clr[3] or 220
        local clr_a = clr[4] or 255
        local a_c = math.floor(clr_a * opacity / 255)
        for fi = 1, #lay.fragments do
            local f = lay.fragments[fi]
            local audit = begin_text_baseline_audit(ns, nid, {
                paint_path = "legacy",
                line_idx = fi,
                line_box_top = f.y,
                line_box_height = f.h or 0,
                node_content_y = lay.content_y or lay.y or 0,
                node_content_h = lay.content_h or lay.h or 0,
            })
            Painters.paint_text(dl, f.text, f.x, f.y, font_size,
                r_c, g_c, b_c, a_c, false,
                computed.font_family, computed.font_weight, computed.font_style)
            end_text_baseline_audit(audit)
        end
        text = nil  -- short-circuit the legacy wrap-based block below
    end

    if text and text ~= "" then
        local font_size = computed.font_size or 16
        if type(font_size) ~= "number" then font_size = 16 end
        local clr = computed.color or { 220, 220, 220, 255 }
        local clr_a = clr[4] or 255
        local a = math.floor(clr_a * opacity / 255)

        -- background-clip: text support -" resolve gradient for text coloring
        -- Check this element and parent for background_clip == "text"
        local grad_text_info = nil  -- {stops, angle, elem_x, elem_w, type}
        local bc_self = computed.background_clip
        local bi_self = computed.background_image
        -- For multi-background arrays, use the first (topmost) layer for text clipping
        if bi_self and type(bi_self) == "table" and not bi_self.type and bi_self[1] then bi_self = bi_self[1] end
        if bc_self == "text" and bi_self and type(bi_self) == "table" then
            grad_text_info = {
                stops = bi_self.stops or {},
                angle = bi_self.angle or 180,
                elem_x = x, elem_w = w, elem_y = y, elem_h = h,
                grad_type = bi_self.type,
                center = bi_self.center,
                shape = bi_self.shape,
                size_kw = bi_self.size_kw or bi_self.size,
                from_angle = bi_self.from_angle,
                repeating = bi_self.repeating,
            }
        end
        if not grad_text_info then
            local pid = ns.parent[nid]
            if pid and pid ~= 0 then
                local pc = ns.computed[pid]
                if pc and pc.background_clip == "text" and pc.background_image
                   and type(pc.background_image) == "table" then
                    local play = ns.layout[pid]
                    if play then
                        local px, py, pw, ph = apply_transform(play.x, play.y, play.w, play.h)
                        local pbi = pc.background_image
                        -- For multi-background arrays, use the first (topmost) layer
                        if not pbi.type and pbi[1] then pbi = pbi[1] end
                        grad_text_info = {
                            stops = pbi.stops or {},
                            angle = pbi.angle or 180,
                            elem_x = px, elem_w = pw, elem_y = py, elem_h = ph,
                            grad_type = pbi.type,
                            center = pbi.center,
                            shape = pbi.shape,
                            size_kw = pbi.size_kw or pbi.size,
                            from_angle = pbi.from_angle,
                            repeating = pbi.repeating,
                        }
                    end
                end
            end
        end
        -- If gradient-text is active, override the text color with the
        -- gradient midpoint color (used for non-per-char rendering paths).
        if grad_text_info and #grad_text_info.stops > 0 then
            local mid_r, mid_g, mid_b, mid_a = Gradient.sample_color(
                grad_text_info.stops, 0.5)
            clr = { mid_r, mid_g, mid_b, mid_a }
            clr_a = mid_a
            a = math_floor(clr_a * opacity / 255)
        end
        local text_align = computed.text_align or "left"
        local text_align_last = computed.text_align_last or "auto"
        local text_overflow = computed.text_overflow or "clip"
        local white_space = computed.white_space or "normal"
        -- CSS UI §5.3: `text-overflow: ellipsis` only takes effect on a
        -- block container that has `overflow: hidden|scroll|auto` AND
        -- whose content actually overflows on a single line.  When these
        -- preconditions are not met, Chrome ignores the property
        -- (renders no ellipsis, content visibly overflows).  Demote to
        -- `clip` so the truncate path is skipped below.
        if text_overflow == "ellipsis" then
            local ov_x = computed.overflow_x or computed.overflow or "visible"
            local is_clipped = (ov_x == "hidden" or ov_x == "scroll" or ov_x == "auto" or ov_x == "clip")
            local is_singleline = (white_space == "nowrap" or white_space == "pre")
            if not (is_clipped and is_singleline) then
                text_overflow = "clip"
            end
        end

        local cx = lay.content_x
        local cy = lay.content_y
        local cw = lay.content_w
        local ch = lay.content_h

        -- Password mask: replace text with bullet characters for display
        local input_pseudo = ns.pseudo[nid]
        local input_mask_char = input_pseudo and input_pseudo._input_mask_char
        if (not input_mask_char) and tag_str == "input" then
            local attrs = ns.attrs[nid] or {}
            if tostring(attrs.type or "text"):lower() == "password" then
                input_mask_char = string.char(226, 128, 162)
            end
        end
        if input_mask_char and text and text ~= "" then
            local masked = {}
            local codepoint_count = Utf8.len(text) or #text
            for _ = 1, codepoint_count do
                masked[#masked + 1] = input_mask_char
            end
            text = table.concat(masked)
        end

        -- Input text scroll offset
        local input_scroll_x = input_pseudo and input_pseudo._input_scroll_x or 0
        if input_scroll_x ~= 0 then
            cx = cx - input_scroll_x
            -- Expand clip width so _clip_text accounts for scrolled-off left portion
            cw = cw + input_scroll_x
        end

        -- Detect if we need per-glyph transform (skew or rotation).
        -- AABB loses skew info, so we position glyphs in raw layout space
        -- and transform each glyph position individually.
        local raw_cx, raw_cy = cx, cy
        local raw_cw = cw
        local per_glyph_xform = nil
        do
            local m = Painters._transform_matrix
            if m and Transform.has_rotation(m) then
                per_glyph_xform = m
            end
        end
        -- Apply transform to text positions (AABB for clipping/centering)
        cx, cy, cw, ch = apply_transform(cx, cy, cw, ch)
        -- Delegate to the canonical line-height resolver in glyph_cache
        -- so paint and block layout cannot silently disagree at non-1 DPR
        -- on what `normal`/multiplier/absolute resolve to.
        --
        -- IMPORTANT: there is no `engine` upvalue here. The static
        -- font_manager and DPR references set on the Painters module by
        -- Engine.new / Engine:set_dpr are what we have access to -" using
        -- a stray `engine` global would always resolve to nil and silently
        -- fall back to `font_size * 1.2`, diverging from block.lua which
        -- uses real font metrics whenever a family cache is available.
        local line_h_cache = nil
        do
            local fm = Painters._font_manager
            local fam = computed.font_family
            if fm and fam and fm.get_cache_for then
                line_h_cache = fm:get_cache_for(fam,
                    computed.font_weight or 400, computed.font_style or "normal")
            end
        end
        local line_h = computed._resolved_line_height
        if type(line_h) ~= "number" or line_h <= 0 then
            line_h = GlyphCache.resolve_line_height(
                line_h_cache, computed.line_height, font_size,
                Painters._dpr or 1)
        end

        local font_weight = computed.font_weight or 400
        local font_style = computed.font_style or "normal"
        local letter_spacing = computed.letter_spacing or 0
        local word_spacing = computed.word_spacing or 0
        local text_decoration = computed.text_decoration or "none"
        -- For _text nodes, inherit text_decoration from decorating parent (CSS spec)
        if text_decoration == "none" then
            local pid = ns.parent[nid]
            if pid and pid ~= 0 then
                local pc = ns.computed[pid]
                if pc and pc.text_decoration and pc.text_decoration ~= "none" then
                    text_decoration = pc.text_decoration
                    -- Also inherit decoration sub-properties from same parent
                    if pc.text_decoration_color then
                        computed.text_decoration_color = pc.text_decoration_color
                    end
                    if pc.text_decoration_style then
                        computed.text_decoration_style = pc.text_decoration_style
                    end
                    if pc.text_decoration_thickness then
                        computed.text_decoration_thickness = pc.text_decoration_thickness
                    end
                end
            end
        end
        local text_transform_val = computed.text_transform or "none"
        local first_line_indent = computed._first_line_indent or 0
        local text_shadow_val = computed.text_shadow

        -- Apply text_transform before wrapping.
        -- Cache the transformed string on computed to avoid allocation per frame.
        -- IMPORTANT: byte-safe upper/lower (locale-aware :upper() on Windows
        -- mangles UTF-8 multi-byte sequences such as em-dash → invalid UTF-8
        -- → painter drops the whole string).  Only transform ASCII letters.
        if text_transform_val ~= "none" then
            local tc = computed._text_transform_cache
            if tc and tc[1] == text and tc[2] == text_transform_val then
                text = tc[3]
            else
                local transformed
                if text_transform_val == "uppercase" then
                    transformed = text:gsub("([a-z])", function(c) return string.char(c:byte() - 32) end)
                elseif text_transform_val == "lowercase" then
                    transformed = text:gsub("([A-Z])", function(c) return string.char(c:byte() + 32) end)
                elseif text_transform_val == "capitalize" then
                    transformed = text:gsub("(%a)([%a]*)", function(f, r)
                        local b = f:byte()
                        if b >= 0x61 and b <= 0x7A then f = string.char(b - 32) end
                        return f .. r
                    end)
                else
                    transformed = text
                end
                computed._text_transform_cache = { text, text_transform_val, transformed }
                text = transformed
            end
        end

        local font_family = computed.font_family or Painters._default_font
        local glyph_cache = nil
        local glyph_cache_fallback = nil
        if font_family and Painters._font_manager then
            glyph_cache = Painters._font_manager:get_cache_for(font_family, font_weight, font_style)
            -- Keep weight-400 cache as fallback for missing glyphs at other weights
            if font_weight ~= 400 then
                glyph_cache_fallback = Painters._font_manager:get_cache_for(font_family, 400, font_style)
            end
        end


        -- Cache measurer wrapper on computed to avoid table+closure alloc per frame
        local text_measurer = platform
        if glyph_cache or letter_spacing ~= 0 or word_spacing ~= 0 then
            local cached_pm = computed._paint_measurer
            if cached_pm
               and cached_pm._glyph_cache == glyph_cache
               and cached_pm._letter_spacing == letter_spacing
               and cached_pm._word_spacing == word_spacing then
                text_measurer = cached_pm
            else
                if glyph_cache then
                    text_measurer = {
                        _glyph_cache = glyph_cache,
                        _letter_spacing = letter_spacing,
                        _word_spacing = word_spacing,
                        measure_text_width = function(self, t, fs, fid)
                            local tw = glyph_cache:measure_text(t, fs, Utf8)
                            if letter_spacing ~= 0 then
                                local nc = Utf8.len(t)
                                if nc > 1 then tw = tw + letter_spacing * (nc - 1) end
                            end
                            if word_spacing ~= 0 then
                                local sc = 0; for _ in t:gmatch(" ") do sc = sc + 1 end
                                tw = tw + word_spacing * sc
                            end
                            return tw
                        end
                    }
                else
                    text_measurer = {
                        _glyph_cache = false,
                        _letter_spacing = letter_spacing,
                        _word_spacing = word_spacing,
                        measure_text_width = function(self, t, fs, fid)
                            local tw = Painters.measure_text(t, fs, font_family, font_weight, font_style)
                            if letter_spacing ~= 0 then
                                local nc = Utf8.len(t)
                                if nc > 1 then tw = tw + letter_spacing * (nc - 1) end
                            end
                            if word_spacing ~= 0 then
                                local sc = 0; for _ in t:gmatch(" ") do sc = sc + 1 end
                                tw = tw + word_spacing * sc
                            end
                            return tw
                        end
                    }
                end
                computed._paint_measurer = text_measurer
            end
        end

        -- Cache font key on computed to avoid string concat per frame
        local wrap_font_id = (font_family or "0") .. ":" .. tostring(font_weight)
            .. ":" .. tostring(font_style)
            .. ":" .. tostring(letter_spacing) .. ":" .. tostring(word_spacing)

        local p_word_break = computed.word_break or "normal"
        local p_overflow_wrap = computed.overflow_wrap or "normal"
        local p_tab_size = computed.tab_size or 8
        local p_text_wrap = computed.text_wrap
        -- Mirror block.lua's first formatted line indent metadata so paint
        -- and layout wrap at the same line 1 width.
        local p_first_line_shrink = 0
        local p_first_line_indent = 0
        if type(first_line_indent) == "number" and first_line_indent > 0 then
            p_first_line_shrink = first_line_indent
            p_first_line_indent = first_line_indent
        end
        -- Mirror block.lua's preserve_edges: when this TEXT sits inside an
        -- inline-flow parent, keep the leading/trailing whitespace so the
        -- rendered line includes the inter-sibling gap (inline-mixed-runs
        -- case otherwise renders "Plainbold" with the spans glued together).
        -- Edge-preservation walk: mirror block.lua's rule so paint and
        -- layout agree on which inter-element spaces are reserved width
        -- and which are trimmed line-edge whitespace.  See block.lua's
        -- text-leaf branch for the rationale.
        local p_preserve_lead  = false
        local p_preserve_trail = false
        if ns.node_type[nid] == ns.TEXT then
            local cur = nid
            while cur and cur ~= 0 do
                local parent = ns.parent[cur]
                if not parent or parent == 0 then break end
                local prev = ns.prev_sibling[cur] or 0
                local nxt  = ns.next_sibling[cur] or 0
                if (not p_preserve_lead) and prev ~= 0 then
                    p_preserve_lead = true
                end
                if (not p_preserve_trail) and nxt ~= 0 then
                    p_preserve_trail = true
                end
                if p_preserve_lead and p_preserve_trail then break end
                local ppc = ns.computed[parent]
                local pdisp = ppc and ppc.display or "block"
                local is_inline_ancestor = (pdisp == "inline" or pdisp == "inline-block"
                                            or pdisp == "inline-flex" or pdisp == "inline-grid")
                if not is_inline_ancestor then break end
                cur = parent
            end
        end
        local lines = TextWrap.wrap(text, cw, font_size, wrap_font_id, white_space, line_h, text_measurer, p_word_break, p_overflow_wrap, p_tab_size, p_text_wrap, p_first_line_shrink, p_preserve_lead, p_preserve_trail, p_first_line_indent)

        -- Use the node's own content height for line visibility.
        -- The clip stack (pushed at parent's padding box) handles actual clipping.
        local effective_h = ch

        -- Apply scroll offset for leaf nodes with overflow (e.g. textarea)
        local text_scroll_y = 0
        local ov_y_text = computed.overflow_y or "visible"
        if ov_y_text == "auto" or ov_y_text == "scroll" then
            local scroll = ns.scroll[nid]
            if scroll then
                text_scroll_y = scroll.y or 0
            end
        end

        local max_visible = math.floor(effective_h / line_h + 0.5)
        if max_visible < 1 then max_visible = 1 end
        -- CSS -webkit-line-clamp: limit visible lines.
        -- line_clamp is not inherited; text nodes read it from their parent.
        local line_clamp = computed.line_clamp
        if not line_clamp then
            local pid = ns.parent[nid]
            if pid and pid ~= 0 then
                local pc = ns.computed[pid]
                if pc then line_clamp = pc.line_clamp end
            end
        end
        local is_clamped = false
        if line_clamp and type(line_clamp) == "number" and line_clamp > 0 then
            max_visible = math.min(line_clamp, max_visible)
            is_clamped = true
        end
        local total_lines = #lines
        -- Determine first visible line based on scroll offset
        local first_line = math.floor(text_scroll_y / line_h) + 1
        if first_line < 1 then first_line = 1 end
        -- When clamped, render exactly N lines (ellipsis on last).
        -- Otherwise, render one extra for partial line visibility.
        local last_line
        if is_clamped then
            last_line = first_line + max_visible - 1
        else
            last_line = first_line + max_visible
        end
        if last_line > total_lines then last_line = total_lines end

        -- GPU scissor handles pixel-level clipping. We only need
        -- a clip rect for early-cull of off-screen glyphs and line
        -- culling (skip lines entirely above/below visible area).
        -- Use the window clip rect -" the GPU scissor stack already
        -- includes all ancestor overflow clips.
        local clip_y_min, clip_y_max
        local effective_clip  -- {x, y, w, h} or nil
        do
            local wcr = Painters._clip_rect
            if wcr then
                effective_clip = { wcr[1], wcr[2], wcr[3], wcr[4] }
                clip_y_min = wcr[2]
                clip_y_max = wcr[2] + wcr[4]
            end
        end

        -- For per-glyph transform: use raw content width for text wrapping/truncation
        local text_layout_cw = per_glyph_xform and raw_cw or cw

        -- Running byte offset for ::selection (cumulative length of lines before i)
        local _sel_line_base = 0
        for li = 1, first_line - 1 do
            _sel_line_base = _sel_line_base + #(lines[li].text or "")
        end
        -- Per-line selection color tracking (set during selection bg paint, used after text draw)
        local _sel_line_color, _sel_line_ss, _sel_line_se, _sel_line_bx, _sel_line_w

        -- Pre-compute ::first-letter vertical overflow: when the first-letter
        -- style raises the font size (drop-cap / initial), a naïve constant
        -- line_h makes the big glyph bleed down into line 2.  Match the
        -- browser behavior by extending line 1's effective height and
        -- pushing subsequent lines down so the glyph fits above the baseline
        -- of line 2.  Looks at the current node's pseudo first, then falls
        -- back to the parent (same pattern as the per-line lookup below).
        local fl_extra_h = 0
        do
            local pre_pseudo = ns.pseudo[nid]
            local pre_fl = pre_pseudo and pre_pseudo._first_letter_style
            if not pre_fl then
                local pid2 = ns.parent[nid]
                if pid2 and pid2 ~= 0 then
                    local pp2 = ns.pseudo[pid2]
                    if pp2 then pre_fl = pp2._first_letter_style end
                end
            end
            if pre_fl and type(pre_fl.font_size) == "number" then
                local fs_self = font_size or 16
                if pre_fl.font_size > fs_self then
                    -- Same line_height multiplier semantics as the
                    -- layout's first-line correction in block.lua.
                    -- nil/normal → font-metric multiplier; px → no
                    -- correction (font-size independent).
                    local _lh = computed.line_height
                    if not (type(_lh) == "number" and _lh >= 5) then
                        local mult
                        if _lh == nil or _lh == "normal" then
                            mult = (line_h or fs_self * 1.2) / fs_self
                        else
                            mult = _lh
                        end
                        fl_extra_h = math.ceil((pre_fl.font_size - fs_self) * mult)
                    end
                end
            end
        end

        for i = first_line, last_line do
            local ln = lines[i]
            -- When per-glyph transform is active, compute line_y in raw layout space;
            -- the transform matrix will be applied per-glyph inside _paint_text_custom.
            local line_y
            if per_glyph_xform then
                line_y = raw_cy + (i - 1) * line_h - text_scroll_y
            else
                line_y = cy + (i - 1) * line_h - text_scroll_y
            end
            -- Push lines after the first-letter line down by the extra
            -- height the drop-cap needs so the big glyph clears line 2.
            if i > 1 and fl_extra_h > 0 then
                line_y = line_y + fl_extra_h
            end
            local display_text = ln.text

            -- Skip lines that are completely outside the clip rect
            -- For per-glyph transform, use AABB line_y for clip check only
            if clip_y_max then
                local clip_line_y = per_glyph_xform
                    and (cy + (i - 1) * line_h - text_scroll_y) or line_y
                local line_bottom = clip_line_y + line_h
                if line_bottom <= clip_y_min then
                    -- Line is entirely above visible area -" skip
                    display_text = nil
                elseif clip_line_y >= clip_y_max then
                    -- Line is entirely below visible area -" skip rest
                    break
                end
            end

            if display_text then

            local is_last_with_more = (i == last_line and total_lines > last_line)
            if text_layout_cw > 0 then
                if is_last_with_more and text_overflow == "ellipsis" then
                    display_text = Painters._force_ellipsis(display_text, text_layout_cw, font_size, text_measurer)
                elseif text_overflow == "ellipsis" and ln.width > text_layout_cw then
                    display_text = Painters._truncate_text(display_text, text_layout_cw, font_size, text_measurer)
                end
            end

            -- Determine effective alignment for this line.
            -- text-align-last overrides alignment on the last line of the block
            -- (or the only line). "auto" means use text_align -" EXCEPT for
            -- text-align: justify, where Chrome falls back to start (left in
            -- LTR) on the final line so the paragraph doesn't justify trailing
            -- whitespace.
            local effective_align = text_align
            local is_last_line = (i == total_lines)
            if is_last_line and text_align_last ~= "auto" then
                local tal = text_align_last
                -- "start" maps to "left", "end" maps to "right" (LTR assumption)
                if tal == "start" then tal = "left" end
                if tal == "end" then tal = "right" end
                effective_align = tal
            elseif is_last_line and effective_align == "justify" then
                effective_align = "left"  -- LTR default for text-align-last: auto
            end

            -- When per-glyph transform: position in raw layout space
            local tx_base = per_glyph_xform and raw_cx or cx
            local tx_cw   = per_glyph_xform and raw_cw or cw
            local tx = tx_base
            local centered = false
            -- Per-line word_spacing -" gets extra stretch for justified lines.
            local line_word_spacing = word_spacing
            if effective_align == "center" then
                tx = tx_base + math.floor(tx_cw / 2)
                centered = true
            elseif effective_align == "right" then
                local tw = text_measurer:measure_text_width(display_text, font_size, 0)
                tx = tx_base + tx_cw - tw
            elseif effective_align == "justify" then
                -- Stretch INTER-WORD spaces so the line fills the content
                -- width.  Count ASCII spaces only and ignore any leading
                -- or trailing space -" those are inline-edge whitespace
                -- preserved by TextWrap for inter-element gaps and must
                -- not become justified slack (otherwise an edge space
                -- balloons into 10+ px of "padding").  The underlying
                -- text painter applies word_spacing on every 0x20
                -- codepoint, including edge ones; the natural width
                -- correction below tracks that.  We don't justify if
                -- there are no interior word boundaries or no slack.
                local interior = display_text:match("^%s*(.-)%s*$") or display_text
                local interior_spaces = 0
                for _ in interior:gmatch(" ") do
                    interior_spaces = interior_spaces + 1
                end
                local all_spaces = 0
                for _ in display_text:gmatch(" ") do
                    all_spaces = all_spaces + 1
                end
                if interior_spaces > 0 then
                    local natural_w = text_measurer:measure_text_width(display_text, font_size, 0)
                    if letter_spacing ~= 0 then
                        -- _paint_text_custom adds letter_spacing per glyph;
                        -- compensate so the slack matches what the painter
                        -- will actually emit.
                        local nc = 0
                        for _ in display_text:gmatch("[^\128-\191]") do nc = nc + 1 end
                        if nc > 1 then natural_w = natural_w + letter_spacing * (nc - 1) end
                    end
                    natural_w = natural_w + word_spacing * all_spaces
                    local slack = tx_cw - natural_w
                    if slack > 0 then
                        line_word_spacing = word_spacing + (slack / interior_spaces)
                    end
                end
            end

            if ln.indent and ln.indent ~= 0 then
                tx = tx + ln.indent
            end

            -- Text shadow.  CSS spec allows a comma-separated list of shadows;
            -- they paint back-to-front so the first declared shadow ends up on
            -- top.  The value may arrive as either a flat single-shadow array
            -- `{x, y, r, g, b, a}` or a list `{{x,y,r,g,b,a}, ...}` -" we
            -- detect the nested form by checking whether `[1]` is a table.
            if text_shadow_val then
                local shadow_list
                if type(text_shadow_val[1]) == "table" then
                    shadow_list = text_shadow_val
                else
                    shadow_list = { text_shadow_val }
                end
                for si = #shadow_list, 1, -1 do
                    local sh = shadow_list[si]
                    local sx = tx + (sh[1] or 0)
                    local sy = line_y + (sh[2] or 0)
                    local sr = sh[3] or 0
                    local sg = sh[4] or 0
                    local sb = sh[5] or 0
                    local sa = sh[6] or 128
                    if glyph_cache then
                        Painters._paint_text_custom(dl, display_text, sx, sy, font_size,
                            sr, sg, sb, sa, centered, cw, cx, glyph_cache,
                            letter_spacing, word_spacing, font_style, glyph_cache_fallback, effective_clip, get_transform_shear(), per_glyph_xform)
                    else
                        Painters.paint_text(dl, display_text, sx, sy, font_size,
                            sr, sg, sb, sa, centered,
                            font_family, font_weight, font_style,
                            cw, cx, nil, effective_clip, get_transform_shear(), per_glyph_xform)
                    end
                end
            end

            -- ::selection pseudo-class rendering for general text nodes.
            -- When pseudo.selected is true, apply _selection_style background
            -- and text color override.  The selection style may live on the
            -- text node itself or on the parent element.
            local sel_style = input_pseudo and input_pseudo._selection_style
            if not sel_style then
                local pid = ns.parent[nid]
                if pid and pid ~= 0 then
                    local pp = ns.pseudo[pid]
                    if pp then sel_style = pp._selection_style end
                end
            end
            if sel_style and input_pseudo and input_pseudo.selected then
                -- sel_start / sel_end are byte offsets into the FULL text_content.
                -- Convert to offsets within this line using the running line byte base.
                local glob_ss = input_pseudo.sel_start or 0
                local glob_se = input_pseudo.sel_end or 0
                -- _sel_line_base tracks cumulative bytes of previous lines
                -- (initialised before the line loop; see below)
                local line_len = #(ln.text or "")
                local line_base = _sel_line_base or 0
                -- Map global range to this line's local range
                local loc_ss = glob_ss - line_base
                local loc_se = glob_se - line_base
                if loc_ss < 0 then loc_ss = 0 end
                if loc_se > line_len then loc_se = line_len end
                if loc_ss < loc_se then
                    -- Measure x-offsets of selection start and end within display_text
                    local sel_x0 = (loc_ss > 0)
                        and text_measurer:measure_text_width(display_text:sub(1, loc_ss), font_size, 0)
                        or 0
                    local sel_x1 = text_measurer:measure_text_width(display_text:sub(1, loc_se), font_size, 0)
                    local sel_bx = tx + sel_x0
                    local sel_w  = sel_x1 - sel_x0
                    if centered then
                        local full_w = text_measurer:measure_text_width(display_text, font_size, 0)
                        sel_bx = tx - full_w / 2 + sel_x0
                    end
                    -- Draw selection background
                    local sel_bg = sel_style.background_color
                    if sel_bg and sel_w > 0 then
                        dl:rect_fill(sel_bx, line_y, sel_w, line_h,
                            sel_bg[1], sel_bg[2], sel_bg[3], sel_bg[4] or 180, 0)
                    end
                    -- Apply selection text color
                    local sc = sel_style.color
                    if sc then
                        if loc_ss == 0 and loc_se >= line_len then
                            -- Entire line selected: override text color directly
                            clr = sc
                            a = math_floor((sc[4] or 255) * opacity / 255)
                        else
                            -- Partial selection: store for overdraw after main text draw
                            _sel_line_color = sc
                            _sel_line_bx = sel_bx
                            _sel_line_w  = sel_w
                        end
                    end
                end
            end

            -- ::first-line / ::first-letter style overrides for line 1.
            -- The style engine attaches _first_line_style / _first_letter_style
            -- to the element with the pseudo-selector (e.g. `<p>`), but
            -- here `nid` may be the TEXT child that actually holds the
            -- string.  Fall back to the parent's pseudo if ours is empty -"
            -- same pattern as _selection_style above.
            local line_clr, line_a = clr, a
            local node_pseudo_pe = ns.pseudo[nid]
            local parent_pseudo_pe = nil
            if not (node_pseudo_pe and node_pseudo_pe._first_line_style
                                   and node_pseudo_pe._first_letter_style) then
                local pid = ns.parent[nid]
                if pid and pid ~= 0 then parent_pseudo_pe = ns.pseudo[pid] end
            end
            local fls_source = (node_pseudo_pe and node_pseudo_pe._first_line_style)
                            or (parent_pseudo_pe and parent_pseudo_pe._first_line_style)
            if i == 1 and fls_source then
                if fls_source.color then
                    line_clr = fls_source.color
                    line_a = math_floor((line_clr[4] or 255) * opacity / 255)
                end
            end

            -- ::first-letter: split first grapheme and paint with override
            local fl_style = (i == 1) and
                ((node_pseudo_pe and node_pseudo_pe._first_letter_style)
              or (parent_pseudo_pe and parent_pseudo_pe._first_letter_style))
            local fl_prefix, fl_rest = nil, display_text
            local fl_clr, fl_a, fl_fs = line_clr, line_a, font_size
            -- Vertical baseline adjustment: on line 1, the rest of the text
            -- must share a baseline with the enlarged letter (CSS inline box
            -- alignment: default vertical-align is baseline).  When fl_fs is
            -- larger, the text ascent is smaller → shift the text down by
            -- the ascent delta so their baselines coincide.  The big letter
            -- itself stays at line_y (top of the expanded line box).
            local fl_text_dy = 0
            if fl_style and display_text and display_text ~= "" then
                -- First codepoint via Utf8
                local cp1_start, cp1_end = 1, 1
                local b0 = display_text:byte(1)
                if b0 then
                    if b0 < 0x80 then cp1_end = 1
                    elseif b0 < 0xC0 then cp1_end = 1  -- invalid leading byte
                    elseif b0 < 0xE0 then cp1_end = 2
                    elseif b0 < 0xF0 then cp1_end = 3
                    else cp1_end = 4 end
                end
                fl_prefix = display_text:sub(cp1_start, cp1_end)
                fl_rest   = display_text:sub(cp1_end + 1)
                if fl_style.color then
                    fl_clr = fl_style.color
                    fl_a = math_floor((fl_clr[4] or 255) * opacity / 255)
                end
                if fl_style.font_size and type(fl_style.font_size) == "number" then
                    fl_fs = fl_style.font_size
                end
                if fl_fs > font_size then
                    local fl_asc = glyph_cache and select(1, glyph_cache:get_metrics(fl_fs))
                                   or (fl_fs * 0.8)
                    local tx_asc = glyph_cache and select(1, glyph_cache:get_metrics(font_size))
                                   or (font_size * 0.8)
                    fl_text_dy = math.floor(fl_asc - tx_asc + 0.5)
                end
            end

            -- Main text
            local audit = begin_text_baseline_audit(ns, nid, {
                paint_path = glyph_cache and "custom" or "legacy",
                line_idx = i,
                line_box_top = line_y,
                line_box_height = line_h,
                node_content_y = lay.content_y or lay.y or 0,
                node_content_h = lay.content_h or lay.h or 0,
            })
            if grad_text_info and #grad_text_info.stops > 0 and glyph_cache then
                -- background-clip: text -" render each character with its
                -- gradient-sampled color based on horizontal position.
                Painters._paint_text_gradient(dl, display_text, tx, line_y, font_size,
                    a, centered, cw, cx, glyph_cache,
                    letter_spacing, word_spacing, font_style, glyph_cache_fallback,
                    effective_clip, grad_text_info, opacity, get_transform_shear(), per_glyph_xform)
            elseif glyph_cache then
                if fl_prefix then
                    local prefix_w = text_measurer:measure_text_width(fl_prefix, fl_fs, 0)
                    Painters._paint_text_custom(dl, fl_prefix, tx, line_y, fl_fs,
                        fl_clr[1] or 220, fl_clr[2] or 220, fl_clr[3] or 220, fl_a,
                        false, cw, cx, glyph_cache,
                        letter_spacing, word_spacing, font_style, glyph_cache_fallback,
                        effective_clip, get_transform_shear(), per_glyph_xform)
                    Painters._paint_text_custom(dl, fl_rest, tx + prefix_w, line_y + fl_text_dy, font_size,
                        line_clr[1] or 220, line_clr[2] or 220, line_clr[3] or 220, line_a,
                        centered, cw, cx, glyph_cache,
                        letter_spacing, word_spacing, font_style, glyph_cache_fallback,
                        effective_clip, get_transform_shear(), per_glyph_xform)
                else
                    Painters._paint_text_custom(dl, display_text, tx, line_y, font_size,
                        line_clr[1] or 220, line_clr[2] or 220, line_clr[3] or 220, line_a,
                        centered, cw, cx, glyph_cache,
                        letter_spacing, line_word_spacing, font_style, glyph_cache_fallback, effective_clip, get_transform_shear(), per_glyph_xform)
                end
            else
                if fl_prefix then
                    local prefix_w = text_measurer:measure_text_width(fl_prefix, fl_fs, 0)
                    Painters.paint_text(dl, fl_prefix, tx, line_y, fl_fs,
                        fl_clr[1] or 220, fl_clr[2] or 220, fl_clr[3] or 220, fl_a,
                        false, font_family, font_weight, font_style,
                        cw, cx, nil, effective_clip, get_transform_shear(), per_glyph_xform)
                    Painters.paint_text(dl, fl_rest, tx + prefix_w, line_y + fl_text_dy, font_size,
                        line_clr[1] or 220, line_clr[2] or 220, line_clr[3] or 220, line_a,
                        centered, font_family, font_weight, font_style,
                        cw, cx, nil, effective_clip, get_transform_shear(), per_glyph_xform)
                else
                    Painters.paint_text(dl, display_text, tx, line_y, font_size,
                        line_clr[1] or 220, line_clr[2] or 220, line_clr[3] or 220, line_a,
                        centered, font_family, font_weight, font_style,
                        cw, cx, nil, effective_clip, get_transform_shear(), per_glyph_xform)
                end
            end
            end_text_baseline_audit(audit)

            -- ::selection foreground color overdraw (clip to selection range, same render path)
            if _sel_line_color and _sel_line_w and _sel_line_w > 0 then
                local sc = _sel_line_color
                local sc_a = math_floor((sc[4] or 255) * opacity / 255)
                dl:clip_push(_sel_line_bx, line_y, _sel_line_w, line_h)
                if glyph_cache then
                    Painters._paint_text_custom(dl, display_text, tx, line_y, font_size,
                        sc[1] or 255, sc[2] or 255, sc[3] or 255, sc_a,
                        centered, cw, cx, glyph_cache,
                        letter_spacing, word_spacing, font_style, glyph_cache_fallback, effective_clip, get_transform_shear(), per_glyph_xform)
                else
                    Painters.paint_text(dl, display_text, tx, line_y, font_size,
                        sc[1] or 255, sc[2] or 255, sc[3] or 255, sc_a,
                        centered, font_family, font_weight, font_style,
                        cw, cx, nil, effective_clip, get_transform_shear(), per_glyph_xform)
                end
                dl:clip_pop()
                _sel_line_color = nil
            end

            -- Text decoration (with color/style/thickness support)
            if text_decoration ~= "none" then
                local line_w = text_measurer:measure_text_width(display_text, font_size, 0)
                local dec_tx = tx
                if centered then
                    dec_tx = tx - line_w / 2
                end
                local ascent_px = glyph_cache and select(1, glyph_cache:get_metrics(font_size)) or (font_size * 0.8)

                -- Resolve decoration properties
                local dec_clr = computed.text_decoration_color or clr
                local dec_style = computed.text_decoration_style or "solid"
                local dec_thick = computed.text_decoration_thickness
                if type(dec_thick) ~= "number" then dec_thick = 1 end

                -- Helper: draw a decoration line with style
                local function draw_dec(dy)
                    local dr, dg, db = dec_clr[1] or 220, dec_clr[2] or 220, dec_clr[3] or 220
                    local da = a
                    if dec_style == "solid" then
                        dl:line(dec_tx, dy, dec_tx + line_w, dy, dr, dg, db, da, dec_thick)
                    elseif dec_style == "double" then
                        dl:line(dec_tx, dy - 1, dec_tx + line_w, dy - 1, dr, dg, db, da, dec_thick)
                        dl:line(dec_tx, dy + 2, dec_tx + line_w, dy + 2, dr, dg, db, da, dec_thick)
                    elseif dec_style == "dashed" then
                        local dx = dec_tx
                        while dx < dec_tx + line_w do
                            local seg_end = math.min(dx + 6, dec_tx + line_w)
                            dl:line(dx, dy, seg_end, dy, dr, dg, db, da, dec_thick)
                            dx = dx + 10
                        end
                    elseif dec_style == "dotted" then
                        local dx = dec_tx
                        local dot_gap = math.max(dec_thick * 3, 3)
                        while dx < dec_tx + line_w do
                            dl:rect_fill(dx, dy - dec_thick / 2, dec_thick, dec_thick, dr, dg, db, da, dec_thick / 2)
                            dx = dx + dot_gap
                        end
                    elseif dec_style == "wavy" then
                        local dx = dec_tx
                        local amp = 2
                        while dx < dec_tx + line_w do
                            local nx = math.min(dx + 2, dec_tx + line_w)
                            local sy = dy + amp * math.sin((dx - dec_tx) * 0.5)
                            local ny = dy + amp * math.sin((nx - dec_tx) * 0.5)
                            dl:line(dx, sy, nx, ny, dr, dg, db, da, dec_thick)
                            dx = nx
                        end
                    end
                end

                if text_decoration == "underline" or text_decoration:find("underline") then
                    draw_dec(line_y + ascent_px + 2)
                end
                if text_decoration == "line-through" or text_decoration:find("line%-through") then
                    draw_dec(line_y + ascent_px * 0.55)
                end
                if text_decoration == "overline" or text_decoration:find("overline") then
                    draw_dec(line_y)
                end
            end

            end -- if display_text
            -- Advance selection line base (even for clipped/skipped lines)
            _sel_line_base = _sel_line_base + #(ln.text or "")
        end
    end
    if text_clip_pushed then
        dl:clip_pop()
    end

    -- Icon rendering
    local icon_name = computed.icon
    if icon_name and Painters._icon_cache then
        local icon_sz = computed.icon_size or computed.font_size or 16
        if type(icon_sz) ~= "number" then icon_sz = 16 end
        local icon_clr = computed.color or { 220, 220, 220, 255 }
        local icon_clr_a = icon_clr[4] or 255
        local icon_a = math.floor(icon_clr_a * opacity / 255)
        local icx = lay.content_x
        local icy = lay.content_y
        local icw = lay.content_w
        local ich = lay.content_h
        icx, icy, icw, ich = apply_transform(icx, icy, icw, ich)
        local icon_data = Painters._icon_cache:get(icon_name, icon_sz)
        if icon_data then
            local ix = icx + math.floor((icw - icon_data.w) * 0.5)
            local iy = icy + math.floor((ich - icon_data.h) * 0.5)
            Painters._icon_cache:draw_clipped(dl, icon_name, icon_sz,
                ix, iy, Painters._clip_rect,
                icon_clr[1] or 220, icon_clr[2] or 220, icon_clr[3] or 220, icon_a)
        end
    end
end

------------------------------------------------------------
-- Gradient text rendering (background-clip: text)
------------------------------------------------------------

--- Render text with per-character gradient coloring.
--- Each glyph is colored by sampling the gradient at its
--- horizontal position relative to the element bounds.
function Painters._paint_text_gradient(dl, text, x, y, font_size, a,
        centered, cw, cx, cache, letter_sp, word_sp, font_style_v,
        fallback_cache, clip_rect, grad_info, opacity, extra_shear, transform_matrix)
    letter_sp = letter_sp or 0
    word_sp = word_sp or 0

    local ascent, _, _ = cache:get_metrics(font_size)
    local baseline_y = y + ascent

    local shear = extra_shear or 0
    if font_style_v == "oblique" or font_style_v == "italic" then
        shear = shear + 0.2
    end

    local stops = grad_info.stops
    local elem_x = grad_info.elem_x
    local elem_w = grad_info.elem_w
    if elem_w <= 0 then elem_w = 1 end

    local pen_x = x
    local cps = shape_text(cache, text)
    local audit = Painters._text_baseline_audit
    if not audit and baseline_audit_enabled() then
        local ns = Painters._current_paint_ns
        local nid = Painters._current_paint_nid
        local case_id = ns and nid and find_parity_case_id(ns, nid)
        if case_id then
            local lay = ns.layout and ns.layout[nid] or {}
            audit = {
                case_name = case_id,
                node_id = nid,
                line_idx = 0,
                paint_path = "custom",
                line_box_top = y or 0,
                line_box_height = 0,
                node_content_y = lay.content_y or lay.y or 0,
                node_content_h = lay.content_h or lay.h or 0,
            }
        end
    end
    if audit then
        push_text_baseline_audit({
            case_name = audit.case_name or "",
            node_id = audit.node_id or 0,
            line_idx = audit.line_idx or 0,
            paint_path = audit.paint_path or "custom",
            text = text or "",
            x = x or 0,
            y = y or 0,
            baseline_y = baseline_y or 0,
            ascent_used = ascent or 0,
            font_metric_source = text_metric_source(cache),
            line_box_top = audit.line_box_top or y or 0,
            line_box_height = audit.line_box_height or 0,
            node_content_y = audit.node_content_y or 0,
            node_content_h = audit.node_content_h or 0,
            glyph_count = #cps,
        })
    end
    if centered then
        local total_w = cache:measure_text(text, font_size, Utf8)
        local char_count = #cps
        local space_count = 0
        for i = 1, #cps do
            local cp = cps[i]
            if cp == 32 then space_count = space_count + 1 end
        end
        if char_count > 1 then total_w = total_w + letter_sp * (char_count - 1) end
        total_w = total_w + word_sp * space_count
        pen_x = x - total_w / 2
    end

    -- Precompute clip edges for early-cull
    local cl, ct, cr, cb
    if clip_rect then
        cl = clip_rect[1]
        ct = clip_rect[2]
        cr = cl + clip_rect[3]
        cb = ct + clip_rect[4]
    end

    local floor = math.floor
    local prev_cp = nil
    for i = 1, #cps do
        local cp = cps[i]
        if cache.get_kerning then
            pen_x = pen_x + cache:get_kerning(prev_cp, cp, font_size)
        end
        local glyph = cache:get_glyph(cp, font_size, shear)
        if not glyph and fallback_cache then
            glyph = fallback_cache:get_glyph(cp, font_size, shear)
        end
        if glyph then
            local gx = floor(pen_x + 0.5) + glyph.offset_x
            local gy = floor(baseline_y + 0.5) + glyph.offset_y
            local gw, gh = glyph.tex_w, glyph.tex_h

            -- Sample gradient at the center of this glyph (2D for all gradient types)
            local glyph_center_x = gx + gw * 0.5
            local glyph_center_y = gy + gh * 0.5
            local gr, gg, gb, ga = Gradient.sample_color_2d(grad_info, glyph_center_x, glyph_center_y)
            local ga_final = floor(ga * opacity / 255)

            -- Per-glyph transform for skew/rotation
            if transform_matrix then
                gx, gy = Transform.apply_point(transform_matrix, gx, gy)
                gx = floor(gx + 0.5)
                gy = floor(gy + 0.5)
            end

            -- Early-cull glyphs fully outside clip
            if cl then
                local gx2, gy2 = gx + gw, gy + gh
                if gx2 > cl and gx < cr and gy2 > ct and gy < cb then
                    dl:image(glyph.tex_id, gx, gy, gw, gh, gr, gg, gb, ga_final)
                end
            else
                dl:image(glyph.tex_id, gx, gy, gw, gh, gr, gg, gb, ga_final)
            end

            pen_x = pen_x + glyph.advance + letter_sp
            if cp == 32 then pen_x = pen_x + word_sp end
        else
            pen_x = pen_x + cache:get_advance(cp, font_size) + letter_sp
            if cp == 32 then pen_x = pen_x + word_sp end
        end
        prev_cp = cp
    end
end

------------------------------------------------------------
-- Custom font glyph-by-glyph rendering
------------------------------------------------------------

--- Render text using custom font glyphs (one IMAGE per glyph).
--- GPU scissor handles pixel-level clipping at overflow boundaries;
--- clip_rect is only used for early-cull of fully off-screen glyphs.
function Painters._paint_text_custom(dl, text, x, y, font_size, r, g, b, a, centered, cw, cx, cache, letter_sp, word_sp, font_style_v, fallback_cache, clip_rect, extra_shear, transform_matrix)
    letter_sp = letter_sp or 0
    word_sp = word_sp or 0

    local ascent, _, _ = cache:get_metrics(font_size)
    local baseline_y = y + ascent

    local shear = extra_shear or 0
    if font_style_v == "oblique" or font_style_v == "italic" then
        shear = shear + 0.2
    end

    local pen_x = x
    local cps = shape_text(cache, text)
    local audit = Painters._text_baseline_audit
    if not audit and baseline_audit_enabled() then
        local ns = Painters._current_paint_ns
        local nid = Painters._current_paint_nid
        local case_id = ns and nid and find_parity_case_id(ns, nid)
        if case_id then
            local lay = ns.layout and ns.layout[nid] or {}
            audit = {
                case_name = case_id,
                node_id = nid,
                line_idx = 0,
                paint_path = "custom",
                line_box_top = y or 0,
                line_box_height = 0,
                node_content_y = lay.content_y or lay.y or 0,
                node_content_h = lay.content_h or lay.h or 0,
            }
        end
    end
    if audit then
        push_text_baseline_audit({
            case_name = audit.case_name or "",
            node_id = audit.node_id or 0,
            line_idx = audit.line_idx or 0,
            paint_path = audit.paint_path or "custom",
            text = text or "",
            x = x or 0,
            y = y or 0,
            baseline_y = baseline_y or 0,
            ascent_used = ascent or 0,
            font_metric_source = text_metric_source(cache),
            line_box_top = audit.line_box_top or y or 0,
            line_box_height = audit.line_box_height or 0,
            node_content_y = audit.node_content_y or 0,
            node_content_h = audit.node_content_h or 0,
            glyph_count = #cps,
        })
    end
    if centered then
        local total_w = cache:measure_text(text, font_size, Utf8)
        local char_count = #cps
        local space_count = 0
        for i = 1, #cps do
            local cp = cps[i]
            if cp == 32 then space_count = space_count + 1 end
        end
        if char_count > 1 then total_w = total_w + letter_sp * (char_count - 1) end
        total_w = total_w + word_sp * space_count
        pen_x = x - total_w / 2
    end

    -- Precompute clip edges for early-cull (nil = no culling)
    local cl, ct, cr, cb
    if clip_rect then
        cl = clip_rect[1]
        ct = clip_rect[2]
        cr = cl + clip_rect[3]
        cb = ct + clip_rect[4]
    end

    local floor = math.floor
    local prev_cp = nil
    for i = 1, #cps do
        local cp = cps[i]
        if cache.get_kerning then
            pen_x = pen_x + cache:get_kerning(prev_cp, cp, font_size)
        end
        local glyph = cache:get_glyph(cp, font_size, shear)
        -- Fallback to weight-400 cache if primary cache fails (e.g. synthetic bold)
        if not glyph and fallback_cache then
            glyph = fallback_cache:get_glyph(cp, font_size, shear)
        end
        if glyph then
            local gx = floor(pen_x + 0.5) + glyph.offset_x
            local gy = floor(baseline_y + 0.5) + glyph.offset_y
            local gw, gh = glyph.tex_w, glyph.tex_h

            -- Per-glyph transform: map glyph position from layout space
            -- to screen space through the full affine matrix.
            -- This correctly positions glyphs in skewed/rotated space.
            if transform_matrix then
                gx, gy = Transform.apply_point(transform_matrix, gx, gy)
                gx = floor(gx + 0.5)
                gy = floor(gy + 0.5)
            end

            -- Early-cull glyphs fully outside clip; partially visible
            -- glyphs are emitted and GPU scissor clips them.
            if cl then
                local gx2, gy2 = gx + gw, gy + gh
                if gx2 > cl and gx < cr and gy2 > ct and gy < cb then
                    dl:image(glyph.tex_id, gx, gy, gw, gh, r, g, b, a)
                end
            else
                dl:image(glyph.tex_id, gx, gy, gw, gh, r, g, b, a)
            end

            pen_x = pen_x + glyph.advance + letter_sp
            if cp == 32 then pen_x = pen_x + word_sp end
        else
            pen_x = pen_x + cache:get_advance(cp, font_size) + letter_sp
            if cp == 32 then pen_x = pen_x + word_sp end
        end
        prev_cp = cp
    end
end

------------------------------------------------------------
-- Text truncation
------------------------------------------------------------

function Painters._clip_text(text, max_width, font_size, measurer)
    local full_w = measurer:measure_text_width(text, font_size, 0)
    if full_w <= max_width then
        return text
    end

    local lo, hi = 0, #text
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local sub = text:sub(1, mid)
        local w = measurer:measure_text_width(sub, font_size, 0)
        if w <= max_width then
            lo = mid
        else
            hi = mid - 1
        end
    end

    if lo == 0 then
        return ""
    end
    return text:sub(1, lo)
end

function Painters._truncate_text(text, max_width, font_size, measurer)
    local full_w = measurer:measure_text_width(text, font_size, 0)
    if full_w <= max_width then
        return text
    end

    local ellipsis = "..."
    local ellipsis_w = measurer:measure_text_width(ellipsis, font_size, 0)
    local target_w = max_width - ellipsis_w

    if target_w <= 0 then
        return ellipsis
    end

    local lo, hi = 0, #text
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local sub = text:sub(1, mid)
        local w = measurer:measure_text_width(sub, font_size, 0)
        if w <= target_w then
            lo = mid
        else
            hi = mid - 1
        end
    end

    if lo == 0 then
        return ellipsis
    end

    return text:sub(1, lo) .. ellipsis
end

function Painters._force_ellipsis(text, max_width, font_size, measurer)
    local ellipsis = "..."
    local ellipsis_w = measurer:measure_text_width(ellipsis, font_size, 0)
    local text_w = measurer:measure_text_width(text, font_size, 0)

    if text_w + ellipsis_w <= max_width then
        return text .. ellipsis
    end

    return Painters._truncate_text(text, max_width, font_size, measurer)
end

return Painters



