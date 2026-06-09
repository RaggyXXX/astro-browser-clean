------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / block.lua
-- Block layout algorithm: stack children vertically, resolve
-- box model (margins, padding, border), handle text content.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ValueVM  = require("core/style/value_vm")
local TextWrap = require("core/layout/text_wrap")
local Utf8     = require("core/util/utf8")
local Inline   = require("core/layout/inline")
local SvgTransform = require("core/svg/transform")
local GlyphCache   = require("core/fonts/glyph_cache")

local Block = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

--- Resolve `line-height` value to absolute pixels.
---
--- CSS line-height accepts:
---   nil / "normal" means font-metric-derived height per the active font's
---                    hhea (ascent + |descent| + lineGap). Chrome's
---                    "normal" line-height isn't a fixed multiplier -
---                    it depends on the font. For Inter at 14px this
---                    lands around 16.9px, vs the old hardcoded 1.2
---                    multiplier giving 16.8px. The difference accumulates
---                    over multi-line paragraphs and is the main remaining
---                    parity gap on text-heavy cases after Sprint A-fast.
---   number < 5 means unitless multiplier (e.g. 1.5 * font_size)
---   number >= 5 means absolute pixels (e.g. 24px)
---
--- When the font isn't ready (no font_manager, no cache, no get_metrics),
--- we fall back to 1.2 * font_size - a deterministic, self-drawn-safe
--- default close to Inter/Tinos/Fira normal.
---
--- Exposed on Block.* so painters.lua can reuse the same resolution.
--- DPR is read from `engine._dpr` (default 1) so `normal` line-height matches
--- Chrome's per-component device-pixel rounding at non-integer DPRs.
function Block._resolve_line_h(raw, font_size, engine, family, weight, style)
    local dpr = (engine and engine._dpr) or 1
    if (raw == nil or raw == "normal")
       and engine and engine.platform
       and type(engine.platform.get_normal_line_height) == "function" then
        local ok, h = pcall(engine.platform.get_normal_line_height,
            engine.platform, family, font_size, dpr, weight or 400, style or "normal")
        if ok and type(h) == "number" and h > 0 then
            return h
        end
    end
    if engine and engine.platform
       and type(engine.platform.resolve_line_height) == "function" then
        local ok, h = pcall(engine.platform.resolve_line_height,
            engine.platform, raw, family, font_size, dpr, weight or 400, style or "normal")
        if ok and type(h) == "number" and h > 0 then
            return h
        end
    end
    local cache = nil
    if engine and engine.font_manager and engine.font_manager.get_cache_for and family then
        cache = engine.font_manager:get_cache_for(family, weight or 400, style or "normal")
    end
    return GlyphCache.resolve_line_height(cache, raw, font_size, dpr)
end

--- Collapse adjacent sibling margins (CSS 2.1 §8.3.1).
--- Both positive → max; both negative → min; mixed → sum.
local function collapsed_margin(a, b)
    if a >= 0 and b >= 0 then return math.max(a, b) end
    if a <= 0 and b <= 0 then return math.min(a, b) end
    return a + b
end

--- Check whether an element establishes a new block formatting context (BFC).
--- Elements that establish a BFC do NOT collapse margins with their children
--- or with adjacent siblings.
local function establishes_bfc(comp)
    if not comp then return false end
    local d = comp.display or "block"
    if d == "flow-root" then return true end  -- CSS Display L3 §3 explicit BFC
    if d == "inline-block" or d == "inline-flex" or d == "inline-grid" then return true end
    if d == "flex" or d == "grid" then return true end
    if d == "table-cell" or d == "table-caption" then return true end
    local ov = comp.overflow or "visible"
    if ov ~= "visible" and ov ~= "clip" then return true end
    local ov_x = comp.overflow_x or ov
    local ov_y = comp.overflow_y or ov
    if (ov_x ~= "visible" and ov_x ~= "clip") or (ov_y ~= "visible" and ov_y ~= "clip") then return true end
    local p = comp.position or "static"
    if p == "absolute" or p == "fixed" then return true end
    if comp.float and comp.float ~= "none" then return true end
    if comp.contain then
        local c = comp.contain
        if c == "layout" or c == "content" or c == "strict" or c:find("layout", 1, true) then
            return true
        end
    end
    return false
end

--- Check whether a parent can collapse its top margin with its first child's
--- top margin. Collapsing is blocked by border-top, padding-top, or if the
--- parent establishes a new BFC.
local function can_collapse_parent_top(comp, border_t_val, padding_t_val)
    if establishes_bfc(comp) then return false end
    if border_t_val > 0 then return false end
    if padding_t_val > 0 then return false end
    return true
end

--- Same for bottom margin with last child.
local function can_collapse_parent_bottom(comp, border_b_val, padding_b_val)
    if establishes_bfc(comp) then return false end
    if border_b_val > 0 then return false end
    if padding_b_val > 0 then return false end
    return true
end

--- Resolve font_size to a plain number (it may be a calc/clamp/rem/em table).
--- For em-based font_size (e.g. h1 { font-size: 2em }), the parent's
--- resolved font_size is needed as the reference.
local function resolve_font_size(raw, engine, avail_w, avail_h, parent_font_size)
    if raw == nil then return parent_font_size or 16 end
    if type(raw) == "number" then return raw end
    if raw == "larger" then return (parent_font_size or 16) * 1.2 end
    if raw == "smaller" then return (parent_font_size or 16) / 1.2 end
    -- Bootstrap context: font_size = parent's resolved font_size
    -- (em-based font-size means "relative to parent", not self)
    local boot = {
        parent_width   = avail_w,
        parent_height  = avail_h,
        percent_base   = parent_font_size or 16,
        font_size      = parent_font_size or 16,
        viewport_w     = engine.viewport_w or 0,
        viewport_h     = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
    }
    local resolved = ValueVM.resolve(raw, boot)
    if type(resolved) == "number" then return resolved end
    return parent_font_size or 16
end

--- Build a ValueVM context from engine + computed style.
--- parent_font_size: the parent element's resolved font_size (for em in font-size)
local function make_context(engine, computed, avail_w, avail_h, parent_font_size, container_w, container_h)
    local resolved_fs = resolve_font_size(computed.font_size, engine, avail_w, avail_h, parent_font_size)
    return {
        parent_width   = avail_w,
        parent_height  = avail_h,
        font_size      = resolved_fs,
        viewport_w     = engine.viewport_w or 0,
        viewport_h     = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
        -- Container Query units (cqw/cqh/cqi/cqb/cqmin/cqmax).  If caller
        -- hasn't resolved the nearest container yet, fall back to the
        -- immediate parent's box.
        container_w    = container_w or avail_w,
        container_h    = container_h or avail_h,
    }
end

--- Walk up ancestors looking for an element with `container-type: size` or
--- `inline-size` and return its layout box.  Used to supply container query
--- units (cqw/cqh/...) with the right dimensions.  Returns nil if no
--- ancestor declares a container-type.
local function resolve_container_size(engine, nid, default_w, default_h)
    local ns = engine.ns
    local cur = ns.parent[nid] or 0
    while cur ~= 0 do
        local cc = ns.computed[cur]
        if cc and cc.container_type and cc.container_type ~= "normal" then
            local clay = ns.layout[cur]
            if clay then return clay.w or default_w, clay.h or default_h end
            return default_w, default_h
        end
        cur = ns.parent[cur] or 0
    end
    return default_w, default_h
end

--- Resolve a dimension value, returning a number or "auto".
---@param val     any     raw value from computed style
---@param context table   ValueVM context
---@return any  number or "auto"
local function resolve_dim(val, context)
    if val == nil then return "auto" end
    return ValueVM.resolve(val, context)
end

local function resolve_dim_percent_base(val, context, percent_base)
    if val == nil then return "auto" end
    local old = context.percent_base
    context.percent_base = percent_base
    local resolved = ValueVM.resolve(val, context)
    context.percent_base = old
    return resolved
end

--- Resolve a numeric value (margin, padding, etc.), defaulting to 0.
---@param val     any
---@param context table
---@return number
local function resolve_num(val, context)
    if val == nil then return 0 end
    local r = ValueVM.resolve(val, context)
    if type(r) == "number" then return r end
    return 0
end

local function resolve_num_percent_base(val, context, percent_base)
    if val == nil then return 0 end
    local old = context.percent_base
    context.percent_base = percent_base
    local resolved = ValueVM.resolve(val, context)
    context.percent_base = old
    if type(resolved) == "number" then return resolved end
    return 0
end

local function snap_device_px(v, engine)
    local dpr = (engine and engine._dpr) or 1
    if dpr <= 0 then dpr = 1 end
    return math.floor(v * dpr + 0.5) / dpr
end

local function is_inline_display(d)
    return d == "inline" or d == "inline-block" or d == "inline-flex" or d == "inline-grid"
end

local function first_formatted_line_owner(ns, nid)
    if ns.node_type[nid] ~= ns.TEXT then return nid end
    local cur = nid
    while cur and cur ~= 0 do
        local parent = ns.parent[cur]
        if not parent or parent == 0 then return nil end
        if (ns.prev_sibling[cur] or 0) ~= 0 then return nil end
        local pc = ns.computed[parent]
        local pd = pc and pc.display or "block"
        if not is_inline_display(pd) then return parent end
        cur = parent
    end
    return nil
end

local function resolve_text_indent(raw, content_w, avail_h, font_size, engine)
    if raw == nil or raw == 0 then return 0 end
    local ctx = {
        parent_width = content_w, parent_height = avail_h,
        percent_base = content_w,
        font_size = font_size,
        viewport_w = engine.viewport_w or 0,
        viewport_h = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
    }
    local ti = resolve_num(raw, ctx)
    if ti <= 0 then return 0 end
    return snap_device_px(ti, engine)
end

------------------------------------------------------------
-- Block layout
------------------------------------------------------------

--- Perform block layout for a node.
---@param engine    table   LayoutEngine instance
---@param nid       number  node id
---@param avail_x   number  available x position
---@param avail_y   number  available y position
---@param avail_w   number  available width
---@param avail_h   number  available height
---@param measuring boolean|table|nil  when truthy, layout is a measurement pass.
---  - true / { mode = "intrinsic", ... } → shrink-wrap auto-width to content (legacy).
---  - { mode = "available-width" }       → keep supplied avail_w as inline-size
---    (used by grid auto-row sizing so block-size reflects wrap at the resolved
---    column width, not the intrinsic preferred width).
function Block.layout(engine, nid, avail_x, avail_y, avail_w, avail_h, measuring)
    local ns = engine.ns
    local computed = ns.computed[nid]
    if not computed then return end

    -- Decode measurement mode early so all later branches can read the flags
    -- without re-checking the shape of `measuring`.
    local measuring_mode = measuring ~= nil and measuring ~= false
    local shrinkwrap_measure = measuring == true
    if type(measuring) == "table" then
        measuring_mode = true
        if measuring.mode == "intrinsic" or measuring.shrink_width == true then
            shrinkwrap_measure = true
        end
    end

    -- Get parent's resolved font_size for em-based font-size resolution
    local parent_nid = ns.parent[nid]
    local parent_fs = 16
    if parent_nid and parent_nid ~= 0 then
        local pc = ns.computed[parent_nid]
        if pc and type(pc.font_size) == "number" then
            parent_fs = pc.font_size
        end
    end

    local cq_w, cq_h = resolve_container_size(engine, nid, avail_w, avail_h)
    local context = make_context(engine, computed, avail_w, avail_h, parent_fs, cq_w, cq_h)

    -- Write resolved font_size back so painters can use it as a plain number
    computed.font_size = context.font_size

    -- 1. Resolve box model values (preserve "auto" for horizontal centering)
    local margin_t  = resolve_num(computed.margin_top, context)
    local margin_b  = resolve_num(computed.margin_bottom, context)
    local raw_ml    = computed.margin_left
    local raw_mr    = computed.margin_right
    local ml_auto   = (raw_ml == "auto")
    local mr_auto   = (raw_mr == "auto")
    local margin_l  = ml_auto and 0 or resolve_num(raw_ml, context)
    local margin_r  = mr_auto and 0 or resolve_num(raw_mr, context)

    local padding_t = resolve_num(computed.padding_top, context)
    local padding_r = resolve_num(computed.padding_right, context)
    local padding_b = resolve_num(computed.padding_bottom, context)
    local padding_l = resolve_num(computed.padding_left, context)

    local border_w  = resolve_num(computed.border_width, context)
    local border_t  = resolve_num(computed.border_top_width, context)
    local border_r  = resolve_num(computed.border_right_width, context)
    local border_b  = resolve_num(computed.border_bottom_width, context)
    local border_l  = resolve_num(computed.border_left_width, context)
    -- Per-side fallback: nil → uniform border_width
    if computed.border_top_width == nil    then border_t = border_w end
    if computed.border_right_width == nil  then border_r = border_w end
    if computed.border_bottom_width == nil then border_b = border_w end
    if computed.border_left_width == nil   then border_l = border_w end
    -- CSS spec: border-style "none"/"hidden" → computed border-width = 0
    local bs_uniform = computed.border_style or "solid"
    if (computed.border_top_style    or bs_uniform) == "none" then border_t = 0 end
    if (computed.border_right_style  or bs_uniform) == "none" then border_r = 0 end
    if (computed.border_bottom_style or bs_uniform) == "none" then border_b = 0 end
    if (computed.border_left_style   or bs_uniform) == "none" then border_l = 0 end
    if (computed.border_top_style    or bs_uniform) == "hidden" then border_t = 0 end
    if (computed.border_right_style  or bs_uniform) == "hidden" then border_r = 0 end
    if (computed.border_bottom_style or bs_uniform) == "hidden" then border_b = 0 end
    if (computed.border_left_style   or bs_uniform) == "hidden" then border_l = 0 end

    -- 2. Compute width
    local width_val = resolve_dim(computed.width, context)
    local outer_w
    if type(width_val) == "number" then
        -- Explicit width
        if computed.box_sizing == "border-box" then
            outer_w = width_val
        else
            outer_w = width_val + padding_l + padding_r + border_l + border_r
        end
    else
        -- "auto": fill available width minus margins
        outer_w = avail_w - margin_l - margin_r
        if outer_w < 0 then outer_w = 0 end
    end
    local auto_width = (type(width_val) ~= "number")
    local display = computed.display or "block"
    local is_inline = (display == "inline" or display == "inline-block"
                       or display == "inline-flex" or display == "inline-grid")
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)

    -- margin:auto horizontal centering (CSS 2.1 §10.3.3)
    -- Only for block-level, in-flow elements (not inline/inline-block/absolute/fixed)
    local pos = computed.position or "static"
    local is_in_flow_block = (display == "block" or display == "flex" or display == "grid" or display == "list-item")
        and pos ~= "absolute" and pos ~= "fixed"
    if is_in_flow_block and type(width_val) == "number" and (ml_auto or mr_auto) then
        local remaining = avail_w - outer_w
        if remaining > 0 then
            if ml_auto and mr_auto then
                margin_l = remaining / 2
                margin_r = remaining / 2
            elseif ml_auto then
                margin_l = remaining - margin_r
            else
                margin_r = remaining - margin_l
            end
        end
    end

    -- Content area dimensions.
    -- Non-root `overflow: auto/scroll` containers reserve the platform's
    -- classic scrollbar gutter so children laid out inside report the
    -- same content-width as the host browser/DOM.  The gutter width is
    -- platform-dependent:
    --   * Windows classic scrollbar (default test stub): 15 CSS px.
    --   * Sylvanas in-game (paints its own thin scrollbar at
    --     SB_WIDTH=6 + SB_MARGIN=1 from the right edge, see
    --     core/scroll/scroll_engine.lua): 7 CSS px.
    --   * Overlay scrollbars (headless Chrome, macOS modern, etc.): 0,
    --     so no gutter reservation -" content extends to the box edge
    --     and the scrollbar paints OVER content.
    -- The platform exposes the value via get_scrollbar_gutter_width(); we
    -- cache it on the LayoutEngine (engine._scrollbar_gutter_w) for the
    -- frame so the protocol call only fires once per layout pass.
    -- When the platform doesn't implement the method we default to 15
    -- (Windows classic) which preserves the existing layout behavior
    -- without modifying older platform stubs.
    --
    -- Root scrollports keep no gutter reservation -" html/body never
    -- shrink the layout viewport even with overflow:auto (matches the
    -- "root overflow auto does not reserve a phantom scrollbar gutter"
    -- layout rule).
    local scrollbar_gutter_w = engine._scrollbar_gutter_w
    if scrollbar_gutter_w == nil then
        scrollbar_gutter_w = 15
        local pl = engine.platform
        if pl and type(pl.get_scrollbar_gutter_width) == "function" then
            local ok, v = pcall(pl.get_scrollbar_gutter_width, pl)
            if ok and type(v) == "number" and v >= 0 then
                scrollbar_gutter_w = v
            end
        end
        engine._scrollbar_gutter_w = scrollbar_gutter_w
    end
    local scrollbar_w = 0
    local ov_y = computed.overflow_y or "visible"
    local is_root_scrollport = (tag_str == "html" or tag_str == "body" or (ns.parent[nid] or 0) == 0)
    if ov_y == "scroll" or (ov_y == "auto" and not is_root_scrollport) then
        scrollbar_w = scrollbar_gutter_w
    end
    local content_w = outer_w - padding_l - padding_r - border_l - border_r - scrollbar_w
    if content_w < 0 then content_w = 0 end

    -- 3. Determine position (pos already resolved above for margin:auto guard)
    local box_x, box_y
    local abs_bottom_fixup = nil  -- for post-layout bottom repositioning
    local abs_stretch_h = nil

    if pos == "fixed" then
        -- Fixed positioning: relative to viewport
        -- Initial placement at avail_x/avail_y, adjusted in post-layout
        box_x = avail_x + margin_l
        box_y = avail_y + margin_t
        -- Register for post-layout adjustment
        if engine._fixed_nodes then
            engine._fixed_nodes[#engine._fixed_nodes + 1] = nid
        end
    elseif pos == "absolute" then
        -- Absolute positioning relative to parent content area
        local abs_left   = resolve_dim(computed.left, context)
        local abs_top    = resolve_dim_percent_base(computed.top, context, avail_h)
        local abs_right  = resolve_dim(computed.right, context)
        local abs_bottom = resolve_dim_percent_base(computed.bottom, context, avail_h)

        if auto_width and type(abs_left) == "number" and type(abs_right) == "number" then
            outer_w = avail_w - abs_left - abs_right - margin_l - margin_r
            if outer_w < 0 then outer_w = 0 end
            content_w = outer_w - padding_l - padding_r - border_l - border_r - scrollbar_w
            if content_w < 0 then content_w = 0 end
        end

        local height_probe = resolve_dim_percent_base(computed.height, context, avail_h)
        if type(height_probe) ~= "number" and type(abs_top) == "number" and type(abs_bottom) == "number" then
            abs_stretch_h = avail_h - abs_top - abs_bottom - margin_t - margin_b
            if abs_stretch_h < 0 then abs_stretch_h = 0 end
        end

        if type(abs_left) == "number" then
            box_x = avail_x + abs_left
        elseif type(abs_right) == "number" then
            box_x = avail_x + avail_w - outer_w - abs_right
        else
            box_x = avail_x + margin_l
        end

        if type(abs_top) == "number" then
            box_y = avail_y + abs_top
        elseif type(abs_bottom) == "number" then
            -- Temporary placement; corrected after layout when final height is known
            box_y = avail_y + margin_t
            abs_bottom_fixup = { avail_y = avail_y, avail_h = avail_h, offset = abs_bottom }
        else
            box_y = avail_y + margin_t
        end
    else
        box_x = avail_x + margin_l
        box_y = avail_y + margin_t
    end

    -- Position: relative -" offset from normal flow without affecting siblings
    if pos == "relative" then
        local rel_l = resolve_dim(computed.left, context)
        local rel_t = resolve_dim_percent_base(computed.top, context, avail_h)
        if type(rel_l) == "number" then
            box_x = box_x + rel_l
        else
            local rel_r = resolve_dim(computed.right, context)
            if type(rel_r) == "number" then box_x = box_x - rel_r end
        end
        if type(rel_t) == "number" then
            box_y = box_y + rel_t
        else
            local rel_b = resolve_dim_percent_base(computed.bottom, context, avail_h)
            if type(rel_b) == "number" then box_y = box_y - rel_b end
        end
    end

    -- Sticky: participates in normal flow, but register for post-layout
    if pos == "sticky" then
        local sticky_top = resolve_num_percent_base(computed.top, context, avail_h)
        if engine._sticky_nodes then
            engine._sticky_nodes[#engine._sticky_nodes + 1] = {
                nid = nid,
                top = type(sticky_top) == "number" and sticky_top or 0,
            }
        end
    end

    -- Content area start
    local content_x = box_x + border_l + padding_l
    local content_y = box_y + border_t + padding_t

    -- 4. Layout children or text content
    local content_h = 0
    local max_child_w = 0
    -- Absolute/fixed children are collected during the normal-flow pass and
    -- dispatched only after this element's content height is resolved
    -- (declared here so it stays in scope past the children-branch `end`).
    local abs_children = nil

    -- Check for <img> tag with texture cache
    -- list-style-position: inside -" add extra indent for marker
    if tag_str == "li" and computed.list_style_position == "inside" then
        local marker_indent = 16
        content_x = content_x + marker_indent
        content_w = content_w - marker_indent
        if content_w < 0 then content_w = 0 end
    end

    if tag_str == "svg" then
        -- SVG replaced element sizing (per CSS/SVG spec):
        -- 1. Explicit attrs width/height → intrinsic size
        -- 2. viewBox → intrinsic aspect ratio only (NOT pixel size)
        -- 3. Default: 300x150 (CSS replaced element fallback)
        local attrs = ns.attrs[nid] or {}
        local svg_w = tonumber(attrs.width)
        local svg_h = tonumber(attrs.height)

        -- Parse viewBox for aspect ratio
        local vb_ratio = nil
        local vb_str = attrs.viewBox
        if vb_str then
            local nums = SvgTransform.extract_numbers(vb_str)
            if #nums >= 4 and nums[3] > 0 and nums[4] > 0 then
                vb_ratio = nums[3] / nums[4]
            end
        end

        -- Browser default for SVG without explicit dimensions: 300x150
        local intrinsic_w = svg_w or 300
        local intrinsic_h = svg_h or 150
        local intrinsic_ratio = vb_ratio or (intrinsic_w / intrinsic_h)

        -- CSS width/height override intrinsic
        local img_w = type(width_val) == "number" and
            (computed.box_sizing == "border-box" and (width_val - padding_l - padding_r - border_l - border_r) or width_val)
            or intrinsic_w
        local explicit_h = resolve_dim_percent_base(computed.height, context, avail_h)
        local img_h = type(explicit_h) == "number" and
            (computed.box_sizing == "border-box" and (explicit_h - padding_t - padding_b - border_t - border_b) or explicit_h)
            or intrinsic_h

        -- Maintain aspect ratio from viewBox when only one dimension specified
        if type(width_val) == "number" and type(explicit_h) ~= "number" and intrinsic_ratio > 0 then
            img_h = img_w / intrinsic_ratio
        elseif type(explicit_h) == "number" and type(width_val) ~= "number" and intrinsic_ratio > 0 then
            img_w = img_h * intrinsic_ratio
        end

        content_h = img_h
        if auto_width then
            outer_w = img_w + padding_l + padding_r + border_l + border_r
            content_w = img_w
        end

    elseif tag_str == "img" then
        -- Image element: use intrinsic dimensions from texture
        local attrs = ns.attrs[nid]
        local src = attrs and attrs.src
        local tex_info = engine.texture_cache and src and engine.texture_cache:get(src)

        if tex_info then
            -- Use texture dimensions as intrinsic size
            local intrinsic_w = tex_info.w
            local intrinsic_h = tex_info.h

            -- Explicit width/height from CSS override intrinsic
            local img_w = type(width_val) == "number" and
                (computed.box_sizing == "border-box" and (width_val - padding_l - padding_r - border_l - border_r) or width_val)
                or intrinsic_w
            local explicit_h = resolve_dim_percent_base(computed.height, context, avail_h)
            local img_h = type(explicit_h) == "number" and
                (computed.box_sizing == "border-box" and (explicit_h - padding_t - padding_b - border_t - border_b) or explicit_h)
                or intrinsic_h

            -- Maintain aspect ratio if only one dimension specified
            if type(width_val) == "number" and type(explicit_h) ~= "number" and intrinsic_w > 0 then
                img_h = img_w * intrinsic_h / intrinsic_w
            elseif type(explicit_h) == "number" and type(width_val) ~= "number" and intrinsic_h > 0 then
                img_w = img_h * intrinsic_w / intrinsic_h
            end

            content_h = img_h
            if auto_width then
                outer_w = img_w + padding_l + padding_r + border_l + border_r
                content_w = img_w
            end
        else
            -- Texture not loaded yet: use explicit CSS dimensions as placeholder
            local explicit_h = resolve_dim_percent_base(computed.height, context, avail_h)
            if type(explicit_h) == "number" then
                content_h = computed.box_sizing == "border-box"
                    and (explicit_h - padding_t - padding_b - border_t - border_b)
                    or explicit_h
            else
                content_h = 0
            end
        end

    elseif ns.node_type[nid] == ns.TEXT or
       (not ns:has_children(nid) and ns.text_content[nid] and ns.text_content[nid] ~= "") then
        -- TEXT node or leaf element with text: measure text
        local text = ns.text_content[nid] or ""
        local font_size = resolve_font_size(computed.font_size, engine, avail_w, avail_h)
        computed.font_size = font_size  -- Write back for painters
        local line_h = Block._resolve_line_h(
            computed.line_height, font_size, engine,
            computed.font_family, computed.font_weight, computed.font_style
        )
        computed._resolved_line_height = line_h
        local white_space = computed.white_space or "normal"
        local font_family = computed.font_family
        local font_weight = computed.font_weight or 400
        local font_style = computed.font_style or "normal"
        local letter_spacing = computed.letter_spacing or 0
        local word_spacing = computed.word_spacing or 0
        local text_transform = computed.text_transform or "none"

        -- Apply text_transform before measuring/wrapping.
        -- IMPORTANT: Lua's string.upper / string.lower are locale-sensitive
        -- on Windows (MBCS locales) and can corrupt UTF-8 multi-byte
        -- sequences (e.g. the em-dash's 0xE2 0x80 0x94 bytes get
        -- individually uppercased and the codepoint is destroyed, making
        -- the whole string invalid UTF-8 → painter silently drops it).
        -- Only touch ASCII letters with pattern-based substitution.
        if text_transform == "uppercase" then
            text = text:gsub("([a-z])", function(c) return string.char(c:byte() - 32) end)
        elseif text_transform == "lowercase" then
            text = text:gsub("([A-Z])", function(c) return string.char(c:byte() + 32) end)
        elseif text_transform == "capitalize" then
            text = text:gsub("(%a)([%a]*)", function(f, r)
                local b = f:byte()
                if b >= 0x61 and b <= 0x7A then f = string.char(b - 32) end
                return f .. r
            end)
        end

        -- In measuring mode, shrink-wrap to full text width.
        -- Inline TEXT nodes only shrink-wrap during measurement, not
        -- during final layout -" during layout they wrap to avail_w
        -- just like text in block elements (CSS inline formatting).
        local is_text_node = (ns.node_type[nid] == ns.TEXT)
        -- Measure that matches the per-word wrap measurer: include
        -- letter-spacing and word-spacing so the intrinsic width we
        -- expose to the caller equals what TextWrap will actually
        -- compute. Without this, a TEXT child inside a block with
        -- letter-spacing (e.g. uppercased h2) measures narrower than
        -- its real laid-out width, so the container allocates exactly
        -- the measured width and TextWrap then wraps at the first space.
        -- Pre-compute edge preservation so measure_with_spacing can drop
        -- any leading/trailing whitespace that TextWrap will trim during
        -- the actual layout pass -" keeps the reserved width in sync with
        -- the rendered glyphs.  See the inline-flow rule documented on
        -- the TextWrap.wrap call below.
        local mws_lead, mws_trail = false, false
        if is_text_node then
            local cur = nid
            while cur and cur ~= 0 do
                local parent = ns.parent[cur]
                if not parent or parent == 0 then break end
                local prev = ns.prev_sibling[cur] or 0
                local nxt  = ns.next_sibling[cur] or 0
                if (not mws_lead) and prev ~= 0 then mws_lead = true end
                if (not mws_trail) and nxt ~= 0 then mws_trail = true end
                if mws_lead and mws_trail then break end
                local ppc = ns.computed[parent]
                local pdisp = ppc and ppc.display or "block"
                local is_inline_ancestor = (pdisp == "inline" or pdisp == "inline-block"
                                            or pdisp == "inline-flex" or pdisp == "inline-grid")
                if not is_inline_ancestor then break end
                cur = parent
            end
        end
        local function measure_with_spacing()
            local effective_text = text
            if is_text_node and (white_space == "normal" or white_space == "nowrap"
                                 or white_space == "pre-line") then
                if not mws_lead  then effective_text = effective_text:gsub("^%s+", "") end
                if not mws_trail then effective_text = effective_text:gsub("%s+$", "") end
                effective_text = effective_text:gsub("%s+", " ")
            end
            local w = engine:measure_text_width(effective_text, font_size, 0, font_family, font_weight, font_style)
            if letter_spacing ~= 0 then
                local nc = Utf8.len(effective_text)
                if nc > 1 then w = w + letter_spacing * (nc - 1) end
            end
            if word_spacing ~= 0 then
                local sc = 0
                for _ in effective_text:gmatch(" ") do sc = sc + 1 end
                w = w + word_spacing * sc
            end
            return math.ceil(w)
        end
        if shrinkwrap_measure and auto_width then
            local text_w = measure_with_spacing()
            outer_w = text_w + padding_l + padding_r + border_l + border_r
            content_w = text_w
        elseif is_inline and auto_width and not is_text_node then
            local text_w = measure_with_spacing()
            outer_w = text_w + padding_l + padding_r + border_l + border_r
            content_w = text_w
        end

        -- Create a measurer wrapper when custom font, spacing, or weight is active.
        -- Cache on computed to avoid table+closure alloc per text node per frame.
        local measurer = engine
        local Utf8_mod = Utf8
        if font_family or letter_spacing ~= 0 or word_spacing ~= 0 then
            local cached_m = computed._measurer
            if cached_m and cached_m._eng == engine
               and cached_m._font_family == font_family
               and cached_m._font_weight == font_weight
               and cached_m._font_style == font_style
               and cached_m._letter_spacing == letter_spacing
               and cached_m._word_spacing == word_spacing then
                measurer = cached_m
            else
                measurer = {
                    _eng = engine,
                    _font_family = font_family,
                    _font_weight = font_weight,
                    _font_style = font_style,
                    _letter_spacing = letter_spacing,
                    _word_spacing = word_spacing,
                    measure_text_width = function(self, t, fs, fid)
                        local w = engine:measure_text_width(t, fs, fid, font_family, font_weight, font_style)
                        if letter_spacing ~= 0 then
                            local nc = Utf8_mod.len(t)
                            if nc > 1 then w = w + letter_spacing * (nc - 1) end
                        end
                        if word_spacing ~= 0 then
                            local sc = 0; for _ in t:gmatch(" ") do sc = sc + 1 end
                            w = w + word_spacing * sc
                        end
                        return w
                    end
                }
                computed._measurer = measurer
            end
        end

        -- Cache font key on computed to avoid string concat per layout pass
        local wrap_font_id = (font_family or "0") .. ":" .. tostring(font_weight)
            .. ":" .. tostring(font_style)
            .. ":" .. tostring(letter_spacing) .. ":" .. tostring(word_spacing)

        -- ::first-letter drop-cap lookup (parent-first, then self).  The
        -- style lives on the element that carries the pseudo-selector,
        -- which is the parent <p> when `nid` is the actual TEXT child.
        local fl_pseudo = ns.pseudo[nid]
        local fl_style = fl_pseudo and fl_pseudo._first_letter_style
        if not fl_style then
            local pid = ns.parent[nid]
            if pid and pid ~= 0 then
                local pp = ns.pseudo[pid]
                if pp then fl_style = pp._first_letter_style end
            end
        end

        -- First-line effects reduce line 1's available width. Text-indent
        -- belongs to the block's first formatted line, not every TEXT leaf.
        local first_line_shrink = 0
        local first_line_indent = 0
        local indent_owner = first_formatted_line_owner(ns, nid)
        if indent_owner then
            local owner_comp = ns.computed[indent_owner]
            if owner_comp then
                first_line_indent = resolve_text_indent(
                    owner_comp.text_indent, content_w, avail_h, font_size, engine)
                if first_line_indent > 0 then
                    first_line_shrink = first_line_shrink + first_line_indent
                end
            end
        end
        computed._first_line_indent = first_line_indent
        if fl_style and type(fl_style.font_size) == "number"
           and fl_style.font_size > font_size and text ~= "" then
            local cp1_end = 1
            local b0 = text:byte(1)
            if b0 then
                if b0 < 0x80 then cp1_end = 1
                elseif b0 < 0xC0 then cp1_end = 1
                elseif b0 < 0xE0 then cp1_end = 2
                elseif b0 < 0xF0 then cp1_end = 3
                else cp1_end = 4 end
            end
            local first_char = text:sub(1, cp1_end)
            local w_fl = measurer:measure_text_width(first_char, fl_style.font_size, 0)
            local w_nm = measurer:measure_text_width(first_char, font_size, 0)
            local fl_shrink = math.ceil(w_fl - w_nm)
            if fl_shrink > 0 then first_line_shrink = first_line_shrink + fl_shrink end
        end

        -- Wrap text to get line count and total height
        local wb = computed.word_break or "normal"
        local ow = computed.overflow_wrap or "normal"
        local p_tab_size = computed.tab_size or 8
        local p_text_wrap = computed.text_wrap
        -- Edge whitespace preservation for inline-flow TEXT (CSS line-box
        -- rule): keep inter-element whitespace as a single space but trim
        -- whitespace that sits at the line-box edge.  The ancestor walk
        -- happened above for `mws_lead`/`mws_trail`; reuse it so all
        -- three stages (measure_with_spacing, TextWrap.wrap, painter)
        -- agree on which edges are interior.
        local _, total_h = TextWrap.wrap(
            text, content_w, font_size, wrap_font_id, white_space, line_h,
            measurer, wb, ow, p_tab_size, p_text_wrap, first_line_shrink,
            mws_lead, mws_trail, first_line_indent)

        -- Mirror the painter's line-2+ shift into content_h so the
        -- paragraph box contains the shifted lines (else the tail bleeds
        -- into the next sibling).
        if fl_style and type(fl_style.font_size) == "number"
           and fl_style.font_size > font_size then
            -- First-line extra-height correction: when the first-letter
            -- enlarges the line, total_h must include the larger glyph's
            -- vertical extent above the normal-size line.
            -- For px (absolute) line_height the height is font-size-independent
            -- so no additive correction is needed.
            local lh_raw = computed.line_height
            if not (type(lh_raw) == "number" and lh_raw >= 5) then
                -- For numeric multiplier OR font-metric "normal", compute
                -- the per-font-size multiplier ratio and apply the delta.
                local norm_h = Block._resolve_line_h(
                    lh_raw, font_size, engine,
                    computed.font_family, computed.font_weight, computed.font_style
                )
                local mult = norm_h / font_size
                total_h = total_h + math.ceil((fl_style.font_size - font_size) * mult)
            end
        end

        content_h = total_h
    else
        -- Layout children vertically (block stacking)
        local scroll = ns.scroll[nid]
        local scroll_y = (scroll and scroll.y) or 0
        local scroll_x = (scroll and scroll.x) or 0
        local child_y = content_y - scroll_y
        local child_x_base = content_x - scroll_x
        local children_total_h = 0
        local child_context = make_context(engine, computed, content_w, avail_h)

        -- Legend support: if fieldset, check if first child is <legend>
        local is_fieldset_with_legend = false
        local legend_nid = nil
        if tag_str == "fieldset" then
            local fc = ns.first_child[nid]
            if fc and fc ~= 0 then
                local fc_tag = ns._st:get(ns.tag[fc])
                if fc_tag == "legend" then
                    is_fieldset_with_legend = true
                    legend_nid = fc
                end
            end
        end

        -- Track state for margin collapsing (block siblings only)
        local prev_margin_b = nil
        local seen_first_block = false  -- for parent-first-child collapsing
        local parent_collapses_top = can_collapse_parent_top(computed, border_t, padding_t)
        local parent_collapses_bottom = can_collapse_parent_bottom(computed, border_b, padding_b)

        -- Buffer for consecutive inline / inline-block children
        local inline_run = {}

        -- Pre-compute container content height for vertical-align
        local inline_container_h = 0
        local peek_h = resolve_dim_percent_base(computed.height, context, avail_h)
        if type(peek_h) == "number" then
            if computed.box_sizing == "border-box" then
                inline_container_h = peek_h - padding_t - padding_b - border_t - border_b
            else
                inline_container_h = peek_h
            end
            if inline_container_h < 0 then inline_container_h = 0 end
        end

        -- Float context for this container
        local float_left = {}   -- array of {x, y, w, h}
        local float_right = {}
        local max_float_bottom = 0  -- track max float bottom for container height

        -- Helper: compute available width at a given Y, accounting for floats.
        -- Returns: left_edge_x, available_width
        -- Multiple left floats at the same Y level stack horizontally;
        -- the left edge is the rightmost right-edge among all overlapping
        -- left floats.  Similarly, right floats eat from the right.
        local function avail_at_y(ay, ah)
            local left_intrusion = 0   -- px eaten from the left
            local right_intrusion = 0  -- px eaten from the right
            for fi = 1, #float_left do
                local f = float_left[fi]
                if ay < f.y + f.h and ay + ah > f.y then
                    local fe = (f.x + f.w) - content_x  -- right edge relative to content area
                    if fe > left_intrusion then
                        left_intrusion = fe
                    end
                end
            end
            for fi = 1, #float_right do
                local f = float_right[fi]
                if ay < f.y + f.h and ay + ah > f.y then
                    local fe = (content_x + content_w) - f.x  -- px from right edge
                    if fe > right_intrusion then
                        right_intrusion = fe
                    end
                end
            end
            local lx = content_x + left_intrusion
            local rw = content_w - left_intrusion - right_intrusion
            if rw < 0 then rw = 0 end
            return lx, rw
        end

        -- Flush pending inline run
        local function flush_inline_run()
            if #inline_run == 0 then return end
            -- Adjust inline run for float exclusions.
            -- Use a reasonable line-height estimate; after layout we accept
            -- the result (full per-line wrapping around floats is deferred).
            local line_est = context.font_size or 16
            local run_x, run_w = avail_at_y(child_y, line_est)
            local run_h, max_rw = Inline.layout_run(
                engine, ns, inline_run,
                run_x, child_y, run_w, avail_h, inline_container_h, context.font_size,
                -- Pass parent font info + line-height so the strut uses
                -- the same font-metric line-height resolution as the
                -- block text branch (instead of hardcoded font_size * 1.2).
                computed.font_family, computed.font_weight, computed.font_style,
                computed.line_height)
            child_y = child_y + run_h
            children_total_h = children_total_h + run_h
            if max_rw > max_child_w then max_child_w = max_rw end
            prev_margin_b = nil
            seen_first_block = true  -- inline content prevents parent-child collapsing
            inline_run = {}
        end

        local cid = ns.first_child[nid]
        if not cid then cid = 0 end
        while cid ~= 0 do
            local child_computed = ns.computed[cid]
            local child_display = "block"
            if child_computed then
                child_display = child_computed.display or "block"
            end
            -- TEXT nodes are inline by default. `display` is not inherited
            -- (CSS spec) and there's no UA rule for the synthetic `_text`
            -- tag, so without this an inline-interleaved parent such as
            --   <p>Hello <span>world</span>!</p>
            -- would flush the leading and trailing TEXT as separate block
            -- boxes, breaking the line between every inline child.
            if ns.node_type[cid] == ns.TEXT and child_display == "block" then
                child_display = "inline"
            end

            if child_display ~= "none" then
                local child_pos = "static"
                if child_computed then
                    child_pos = child_computed.position or "static"
                end

                if child_pos == "absolute" or child_pos == "fixed" then
                    -- Absolute/fixed children don't affect normal flow.  Defer
                    -- the layout call until after we know the parent's
                    -- resolved content height; otherwise `top:0; bottom:0`
                    -- expands to the viewport because every auto-height
                    -- ancestor propagates its own avail_h.
                    if not abs_children then abs_children = {} end
                    abs_children[#abs_children + 1] = cid

                elseif child_display == "inline" or child_display == "inline-block"
                    or child_display == "inline-flex" or child_display == "inline-grid" then
                    -- Buffer inline children for horizontal flow
                    inline_run[#inline_run + 1] = cid

                elseif child_computed and (child_computed.float == "left" or child_computed.float == "right") then
                    -- Floated child: measure, place at container edge, avoid overlap
                    flush_inline_run()

                    -- Honour clear on the float itself before placement
                    local float_clear = child_computed.clear
                    if float_clear and float_clear ~= "none" then
                        local clear_y = child_y
                        if float_clear == "left" or float_clear == "both" then
                            for fi = 1, #float_left do
                                local fb = float_left[fi].y + float_left[fi].h
                                if fb > clear_y then clear_y = fb end
                            end
                        end
                        if float_clear == "right" or float_clear == "both" then
                            for fi = 1, #float_right do
                                local fb = float_right[fi].y + float_right[fi].h
                                if fb > clear_y then clear_y = fb end
                            end
                        end
                        if clear_y > child_y then
                            child_y = clear_y
                        end
                    end

                    local fw, fh = engine:measure(cid, content_w, avail_h)
                    local float_side = child_computed.float
                    local float_list = (float_side == "right") and float_right or float_left
                    local other_list = (float_side == "right") and float_left or float_right

                    -- Place the float, resolving both same-side stacking and
                    -- cross-side collision.  At each candidate Y we compute
                    -- where the float would go (left floats stack rightward,
                    -- right floats stack leftward) and verify it fits.
                    local fy = child_y
                    local max_iter = 200   -- safety guard
                    local placed = false
                    while not placed and max_iter > 0 do
                        max_iter = max_iter - 1

                        -- Compute horizontal position by stacking past same-side floats.
                        local fx
                        if float_side == "left" then
                            fx = content_x
                            -- Push right of any overlapping left floats
                            for fi = 1, #float_list do
                                local ef = float_list[fi]
                                if fy < ef.y + ef.h and fy + fh > ef.y then
                                    local re = ef.x + ef.w
                                    if re > fx then fx = re end
                                end
                            end
                        else -- "right"
                            fx = content_x + content_w - fw
                            -- Push left of any overlapping right floats
                            for fi = 1, #float_list do
                                local ef = float_list[fi]
                                if fy < ef.y + ef.h and fy + fh > ef.y then
                                    if ef.x < fx + fw then
                                        fx = ef.x - fw
                                    end
                                end
                            end
                        end

                        -- Check cross-side collision: ensure float doesn't
                        -- overlap floats on the opposite side.
                        local cross_ok = true
                        for fi = 1, #other_list do
                            local ef = other_list[fi]
                            if fy < ef.y + ef.h and fy + fh > ef.y then
                                if float_side == "left" then
                                    if fx + fw > ef.x then cross_ok = false end
                                else
                                    if fx < ef.x + ef.w then cross_ok = false end
                                end
                            end
                        end

                        -- Also ensure float stays within the container
                        if fx < content_x then cross_ok = false end
                        if fx + fw > content_x + content_w then cross_ok = false end

                        if not cross_ok then
                            -- Drop below the lowest float that overlaps at fy
                            local lowest = fy + 1  -- at least advance 1
                            for fi = 1, #float_list do
                                local ef = float_list[fi]
                                if fy < ef.y + ef.h and fy + fh > ef.y then
                                    if ef.y + ef.h > lowest then lowest = ef.y + ef.h end
                                end
                            end
                            for fi = 1, #other_list do
                                local ef = other_list[fi]
                                if fy < ef.y + ef.h and fy + fh > ef.y then
                                    if ef.y + ef.h > lowest then lowest = ef.y + ef.h end
                                end
                            end
                            fy = lowest
                        else
                            placed = true
                            engine:_layout_node(cid, fx, fy, fw, avail_h)
                            local flay = ns.layout[cid]
                            local rect = { x = fx, y = fy, w = flay.w or fw, h = flay.h or fh }
                            float_list[#float_list + 1] = rect
                            local fb = fy + (flay.h or fh)
                            if fb - content_y > max_float_bottom then
                                max_float_bottom = fb - content_y
                            end
                        end
                    end
                    -- Floats don't advance cursor_y

                else
                    -- Check clear property
                    if child_computed and child_computed.clear and child_computed.clear ~= "none" then
                        local clear_val = child_computed.clear
                        local clear_y = child_y
                        if clear_val == "left" or clear_val == "both" then
                            for fi = 1, #float_left do
                                local fb = float_left[fi].y + float_left[fi].h
                                if fb > clear_y then clear_y = fb end
                            end
                        end
                        if clear_val == "right" or clear_val == "both" then
                            for fi = 1, #float_right do
                                local fb = float_right[fi].y + float_right[fi].h
                                if fb > clear_y then clear_y = fb end
                            end
                        end
                        if clear_y > child_y then
                            local delta = clear_y - child_y
                            child_y = clear_y
                            children_total_h = children_total_h + delta
                        end
                    end
                    -- Block-level child: flush any pending inline run first
                    flush_inline_run()

                    -- Margin collapsing
                    local child_cm = ns.computed[cid] or {}
                    -- Resolve child's font_size first (em margins use the element's own font_size)
                    local child_fs = resolve_font_size(child_cm.font_size, engine, content_w, avail_h, context.font_size)
                    local child_margin_ctx = {
                        parent_width = content_w, parent_height = avail_h,
                        font_size = child_fs,
                        viewport_w = engine.viewport_w or 0, viewport_h = engine.viewport_h or 0,
                        root_font_size = engine.root_font_size or 16,
                    }
                    local cm_t = resolve_num(child_cm.margin_top, child_margin_ctx)
                    -- Preserve the authored margin_top
                    -- so we can neutralise it on the child's _layout_node
                    -- call when Rule 2 absorbs the margin into the parent.
                    -- Block.layout's box-positioning math (box_y = avail_y
                    -- + margin_t) re-applies the child's computed margin_top
                    -- inside its own layout call regardless of the parent
                    -- loop's local cm_t. Without compensation the margin
                    -- stays VISUALLY inside the parent but is excluded
                    -- from the parent's content_h -" descendants extend past
                    -- wrapper.bottom and the next sibling starts too early.
                    local cm_t_for_child_layout = cm_t
                    local cm_t_collapsed_through_parent = false

                    -- Rule 2: Parent-first-child margin collapsing.
                    -- Per CSS 2.1 §8.3.1, when a parent has no border-top
                    -- and no padding-top, the first block child's margin-
                    -- top collapses with the parent's margin-top. The
                    -- collapsed margin appears OUTSIDE the parent (between
                    -- the parent's previous sibling and the parent itself).
                    --
                    -- Engine compromise: zero out the child's top margin so
                    -- it doesn't create space INSIDE the parent (matches
                    -- Chrome's "the child's margin doesn't add space inside
                    -- the parent box"). Surface the absorbed margin via
                    -- `first_child_absorbed_t` on the layout record so the
                    -- parent's parent loop can apply a retroactive +shift
                    -- to land the wrapper at the right outer y.
                    --
                    -- Prior implementation shifted box_y/content_y/child_y
                    -- DOWN by `extra` (== `box_y -= extra`), which moved the
                    -- wrapper into geometric overlap with the previous
                    -- sibling. CSS shifts the wrapper DOWN to accommodate
                    -- the larger child margin, never up. The shift+cm_t=0
                    -- behavior produced visible text overlap on every
                    -- section/h2-first-child arrangement in the browser
                    -- parity case (visible as overlapping headers + paragraphs).
                    local child_is_bfc = establishes_bfc(child_cm)
                    if not seen_first_block and parent_collapses_top and not child_is_bfc then
                        seen_first_block = true
                        local parent_child_collapsed = collapsed_margin(margin_t, cm_t)
                        local extra = parent_child_collapsed - margin_t
                        if extra > 0 then
                            -- Stash on the in-progress layout so the parent
                            -- loop (lay.first_child_absorbed_t) can apply
                            -- the +shift retroactively when placing this
                            -- box's siblings.
                            ns.layout[nid] = ns.layout[nid] or {}
                            ns.layout[nid].first_child_absorbed_t = extra
                        end
                        -- Remove child's top margin from inside the parent
                        -- (matches Chrome -" first child's margin "escapes"
                        -- the parent rather than creating internal space).
                        cm_t_collapsed_through_parent = true
                        cm_t = 0
                    else
                        seen_first_block = true
                    end

                    -- Rule 1: Adjacent sibling margin collapsing.
                    -- Only collapse if the child does not establish a new BFC.
                    if prev_margin_b ~= nil and not child_is_bfc then
                        local overlap = (prev_margin_b + cm_t)
                            - collapsed_margin(prev_margin_b, cm_t)
                        child_y = child_y - overlap
                        children_total_h = children_total_h - overlap
                    end

                    -- Adjust for float exclusion zones.
                    -- Use an estimated height for the initial query; after layout
                    -- we will verify and re-layout if the real height changed the
                    -- available width (rare but possible).
                    local est_h = 16
                    -- When Rule 2 zeroed cm_t in the
                    -- parent loop, the child's internal Block.layout still
                    -- adds margin_t via `box_y = avail_y + margin_t`. To
                    -- keep the child rect anchored at child_y (and not
                    -- child_y + margin_t), shift the avail_y we pass to
                    -- _layout_node by -cm_t_for_child_layout. The child's
                    -- internal +margin_t then cancels out and box_y lands
                    -- exactly at child_y.
                    local child_layout_y = child_y
                    if cm_t_collapsed_through_parent and cm_t_for_child_layout ~= 0 then
                        child_layout_y = child_y - cm_t_for_child_layout
                    end
                    local block_x, block_avail_w = avail_at_y(child_y, est_h)
                    local child_avail_w = block_avail_w
                    if (shrinkwrap_measure or is_inline) and auto_width then
                        local mw, _ = engine:measure(cid, content_w, avail_h)
                        local cm_l = resolve_num(child_cm.margin_left, child_margin_ctx)
                        local cm_r = resolve_num(child_cm.margin_right, child_margin_ctx)
                        child_avail_w = mw + cm_l + cm_r
                    end

                    -- Legend shrink-to-fit: measure intrinsic width so border gap is tight
                    local child_tag_str = ns._st:get(ns.tag[cid])
                    if child_tag_str == "legend" then
                        local mw, _ = engine:measure(cid, content_w, avail_h)
                        if mw < child_avail_w then
                            child_avail_w = mw
                        end
                    end

                    engine:_layout_node(cid, block_x, child_layout_y, child_avail_w, avail_h)

                    local child_lay = ns.layout[cid]

                    -- Re-check: if the child's actual height differs from the
                    -- estimate and the available width would change, re-layout.
                    local real_h = child_lay.h or 0
                    if real_h ~= est_h and (#float_left > 0 or #float_right > 0) then
                        local bx2, bw2 = avail_at_y(child_y, real_h)
                        if bx2 ~= block_x or bw2 ~= child_avail_w then
                            block_x = bx2
                            child_avail_w = bw2
                            engine:_layout_node(cid, block_x, child_layout_y, child_avail_w, avail_h)
                            child_lay = ns.layout[cid]
                        end
                    end

                    local cm_b = resolve_num(child_cm.margin_bottom, child_margin_ctx)
                    -- Retroactive parent-first-child collapse: if the child
                    -- absorbed a first-grandchild margin (Rule 2 above
                    -- stashed extra on child_lay.first_child_absorbed_t),
                    -- treat that extra as part of the child's EFFECTIVE
                    -- top margin and collapse with prev_margin_b (CSS 2.1
                    -- §8.3.1 adjacent-sibling collapse). The net shift is
                    -- collapsed(prev_margin_b, absorbed_t) - already-applied
                    -- gap, where the already-applied gap is the margin_t
                    -- + prev_margin_b that Rule 1 already collapsed above.
                    local absorbed_t = child_lay.first_child_absorbed_t or 0
                    if absorbed_t > 0 then
                        -- The effective sibling-gap with absorption:
                        local pmb = prev_margin_b or 0
                        local new_collapsed = collapsed_margin(pmb, absorbed_t)
                        local already_applied = collapsed_margin(pmb, cm_t)
                        local shift_dy = new_collapsed - already_applied
                        if shift_dy < 0 then shift_dy = 0 end
                        if shift_dy > 0 then
                            ns:walk_depth_first(cid, function(descendant_nid)
                                local dl = ns.layout[descendant_nid]
                                if dl then
                                    dl.y = (dl.y or 0) + shift_dy
                                    if dl.content_y ~= nil then
                                        dl.content_y = dl.content_y + shift_dy
                                    end
                                    if dl.pad_y ~= nil then
                                        dl.pad_y = dl.pad_y + shift_dy
                                    end
                                end
                            end)
                            cm_t = cm_t + shift_dy
                        end
                        -- Update prev_margin_b so the WRAPPER's effective
                        -- top-margin (now including absorbed grandchild)
                        -- is what the NEXT sibling collapses against via
                        -- Rule 1. Actually Rule 1 uses prev_margin_b which
                        -- is the previous sibling's margin_bottom, not
                        -- top -" so no update needed here.
                        child_lay.first_child_absorbed_t = nil
                    end
                    local child_outer_h = (child_lay.h or 0) + cm_t + cm_b

                    -- Rule 4: Empty block self-collapsing.
                    -- If a block has no height, padding, border, or content,
                    -- its top and bottom margins collapse with each other.
                    local child_inner_h = child_lay.h or 0
                    local child_pt = resolve_num(child_cm.padding_top, child_margin_ctx)
                    local child_pb = resolve_num(child_cm.padding_bottom, child_margin_ctx)
                    local child_bt = resolve_num(child_cm.border_top_width, child_margin_ctx)
                    local child_bb = resolve_num(child_cm.border_bottom_width, child_margin_ctx)
                    local is_empty_block = (child_inner_h == 0
                        and child_pt == 0 and child_pb == 0
                        and child_bt == 0 and child_bb == 0
                        and not child_is_bfc)
                    if is_empty_block then
                        -- Self-collapse: top and bottom margins become one
                        local self_collapsed = collapsed_margin(cm_t, cm_b)
                        local self_overlap = (cm_t + cm_b) - math.abs(self_collapsed)
                        if self_overlap > 0 then
                            child_outer_h = child_outer_h - self_overlap
                        end
                        -- The resulting margin participates in further collapsing
                        cm_b = self_collapsed
                    end

                    child_y = child_y + child_outer_h
                    children_total_h = children_total_h + child_outer_h

                    local child_cm_l = resolve_num(child_cm.margin_left, child_margin_ctx)
                    local child_cm_r = resolve_num(child_cm.margin_right, child_margin_ctx)
                    local child_outer_w = (child_lay.w or 0) + child_cm_l + child_cm_r
                    if child_outer_w > max_child_w then max_child_w = child_outer_w end
                    -- Propagate child's scrollable width for overflow containers
                    local child_sw = child_lay.scroll_w or 0
                    if child_sw > max_child_w then max_child_w = child_sw end

                    -- For BFC children, margins don't collapse with siblings
                    if child_is_bfc then
                        prev_margin_b = nil
                    else
                        prev_margin_b = cm_b
                    end
                end
            end

            cid = ns.next_sibling[cid] or 0
        end

        -- Flush final inline run
        flush_inline_run()

        -- Include float bottoms in content height (prevents float-only collapse)
        if max_float_bottom > children_total_h then
            children_total_h = max_float_bottom
        end

        -- Rule 3: Parent-last-child margin collapsing.
        -- If the parent has no border-bottom/padding-bottom and does not
        -- establish a BFC, the last block child's bottom margin collapses
        -- with the parent's margin-bottom. Remove the child's bottom margin
        -- from the content height (it merges into the parent's external
        -- bottom margin).
        if parent_collapses_bottom and prev_margin_b ~= nil and prev_margin_b > 0 then
            -- The last block child's bottom margin is absorbed into the
            -- parent's margin_bottom (the larger of the two wins).
            local collapsed_bot = collapsed_margin(margin_b, prev_margin_b)
            -- Remove the last child's margin_bottom from content height
            children_total_h = children_total_h - prev_margin_b
            if children_total_h < 0 then children_total_h = 0 end
            -- Increase the parent's effective bottom margin
            margin_b = collapsed_bot
        end

        -- Legend: emulate browser fieldset behavior.
        -- 1) Legend is centered on the top border line (out of normal flow).
        -- 2) Non-legend children start at content_y (padding-top origin).
        -- 3) Content height is reduced only by the legend's normal-flow space.
        if is_fieldset_with_legend and legend_nid then
            local legend_lay = ns.layout[legend_nid]
            if legend_lay then
                local legend_h = legend_lay.h or 0

                local function shift_subtree(sid, dy)
                    if dy == 0 then return end
                    local sl = ns.layout[sid]
                    if sl then
                        sl.y = sl.y - dy
                        sl.content_y = (sl.content_y or sl.y) - dy
                    end
                    local ch = ns.first_child[sid] or 0
                    while ch ~= 0 do
                        shift_subtree(ch, dy)
                        ch = ns.next_sibling[ch] or 0
                    end
                end

                -- 1) Move legend to border center line
                local target_y = box_y + math.floor(border_t / 2) - math.floor(legend_h / 2)
                local legend_shift = legend_lay.y - target_y
                if legend_shift > 0 then
                    shift_subtree(legend_nid, legend_shift)
                end

                -- 2) Shift non-legend children back to content_y.
                -- After normal layout, first non-legend child is at
                -- content_y + legend_outer_h. We want it at content_y.
                local legend_cm = ns.computed[legend_nid] or {}
                local legend_mt = resolve_num(legend_cm.margin_top or 0, context)
                local legend_mb = resolve_num(legend_cm.margin_bottom or 0, context)
                local legend_flow_h = legend_h + legend_mt + legend_mb
                if legend_flow_h < 0 then legend_flow_h = 0 end

                local s = ns.first_child[nid] or 0
                while s ~= 0 do
                    if s ~= legend_nid then
                        shift_subtree(s, legend_flow_h)
                    end
                    s = ns.next_sibling[s] or 0
                end

                -- 3) Reduce content height by the legend flow space we removed
                children_total_h = children_total_h - legend_flow_h
                if children_total_h < 0 then children_total_h = 0 end
            end
        end

        content_h = children_total_h

        -- In shrink-wrap measuring mode or inline elements, shrink-wrap to widest child
        if (shrinkwrap_measure or is_inline) and auto_width then
            if max_child_w > 0 then
                outer_w = max_child_w + padding_l + padding_r + border_l + border_r
            elseif children_total_h == 0 then
                -- No children at all: shrink to padding+border only
                outer_w = padding_l + padding_r + border_l + border_r
            end
        end
    end

    -- 5. Compute height
    local height_val = resolve_dim_percent_base(computed.height, context, avail_h)
    local outer_h
    if type(height_val) == "number" then
        if computed.box_sizing == "border-box" then
            outer_h = height_val
        else
            outer_h = height_val + padding_t + padding_b + border_t + border_b
        end
    elseif abs_stretch_h ~= nil then
        outer_h = abs_stretch_h
    else
        -- "auto": height from content
        outer_h = content_h + padding_t + padding_b + border_t + border_b

        if not measuring_mode and (ov_y == "scroll" or ov_y == "auto") then
            local target = avail_h - margin_t - margin_b
            if target > 0 then
                outer_h = target
            end
        end
    end

    -- Aspect ratio: if one dimension is auto, derive from the other
    local ar = computed.aspect_ratio
    if ar and type(ar) == "number" and ar > 0 then
        local inner_w = outer_w - padding_l - padding_r - border_l - border_r
        local inner_h = outer_h - padding_t - padding_b - border_t - border_b
        if type(height_val) ~= "number" and type(width_val) == "number" then
            -- Width set, height auto → derive height from width
            outer_h = (inner_w / ar) + padding_t + padding_b + border_t + border_b
        elseif type(width_val) ~= "number" and type(height_val) == "number" then
            -- Height set, width auto → derive width from height
            outer_w = (inner_h * ar) + padding_l + padding_r + border_l + border_r
        end
    end

    local min_width_val = resolve_dim(computed.min_width, context)
    if type(min_width_val) == "number" then
        local min_outer_w = computed.box_sizing == "border-box"
            and min_width_val
            or (min_width_val + padding_l + padding_r + border_l + border_r + scrollbar_w)
        if outer_w < min_outer_w then outer_w = min_outer_w end
    end

    local max_width_val = resolve_dim(computed.max_width, context)
    if type(max_width_val) == "number" then
        local max_outer_w = computed.box_sizing == "border-box"
            and max_width_val
            or (max_width_val + padding_l + padding_r + border_l + border_r + scrollbar_w)
        if outer_w > max_outer_w then outer_w = max_outer_w end
    end

    local min_height_val = resolve_dim_percent_base(computed.min_height, context, avail_h)
    if type(min_height_val) == "number" then
        local min_outer_h = computed.box_sizing == "border-box"
            and min_height_val
            or (min_height_val + padding_t + padding_b + border_t + border_b)
        if outer_h < min_outer_h then outer_h = min_outer_h end
    end

    local max_height_val = resolve_dim_percent_base(computed.max_height, context, avail_h)
    if type(max_height_val) == "number" then
        local max_outer_h = computed.box_sizing == "border-box"
            and max_height_val
            or (max_height_val + padding_t + padding_b + border_t + border_b)
        if outer_h > max_outer_h then outer_h = max_outer_h end
    end

    -- Ensure non-negative
    if outer_w < 0 then outer_w = 0 end
    if outer_h < 0 then outer_h = 0 end

    -- Recalculate content dimensions based on final outer size.
    -- scrollbar_w was reserved earlier for non-root overflow:auto/scroll
    -- containers (platform-queried; see the SCROLLBAR / GUTTER block above);
    -- subtract it here too so the final lay.content_w matches what the
    -- initial content_w resolved to. Without this, lay.content_w gets
    -- overwritten with the full padded-box width and the gutter
    -- reservation only affected intermediate calculations, never the
    -- stored layout.
    local final_content_w = outer_w - padding_l - padding_r - border_l - border_r - scrollbar_w
    local final_content_h = outer_h - padding_t - padding_b - border_t - border_b
    if final_content_w < 0 then final_content_w = 0 end
    if final_content_h < 0 then final_content_h = 0 end

    -- Lay out deferred absolute/fixed children now that this element's
    -- content box is known.  Passing final_content_h here lets top/bottom
    -- pairs stretch correctly within the parent rather than the viewport.
    if abs_children then
        for i = 1, #abs_children do
            engine:_layout_node(abs_children[i], content_x, content_y, final_content_w, final_content_h)
        end
    end

    -- 6. Store fractional CSS geometry. Paint/platform boundaries snap later.
    local lay = ns.layout[nid]
    -- Post-layout fixup: correct bottom-positioned absolute elements
    if abs_bottom_fixup then
        local new_y = abs_bottom_fixup.avail_y + abs_bottom_fixup.avail_h - outer_h - abs_bottom_fixup.offset
        local dy = new_y - box_y
        box_y = new_y
        content_y = content_y + dy
        -- Shift all children by dy
        if dy ~= 0 then
            ns:walk_depth_first(nid, function(child_nid)
                if child_nid == nid then return end
                local cl = ns.layout[child_nid]
                if cl then
                    cl.y = cl.y + dy
                    cl.content_y = cl.content_y + dy
                    cl.pad_y = (cl.pad_y or 0) + dy
                end
            end)
        end
    end
    lay.x         = box_x
    lay.y         = box_y
    lay.w         = outer_w
    lay.h         = outer_h
    lay.content_x = content_x
    lay.content_y = content_y
    lay.content_w = final_content_w
    lay.content_h = final_content_h
    -- Padding box (border box minus borders) -" used for overflow clipping per CSS spec
    lay.pad_x     = box_x + border_l
    lay.pad_y     = box_y + border_t
    lay.pad_w     = outer_w - border_l - border_r
    lay.pad_h     = outer_h - border_t - border_b
    -- Store total children height/width for scroll engine
    lay.scroll_h  = content_h
    lay.scroll_w  = max_child_w

    -- Clear layout dirty
    ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
    -- Layout change implies paint dirty
    ns:mark_dirty(nid, ns.PAINT_DIRTY)
end

return Block



