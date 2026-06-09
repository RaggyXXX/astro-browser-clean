------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / flex.lua
-- CSS Flexbox layout algorithm.
--
-- Implements the full CSS Flexible Box Layout spec:
-- direction, wrap, grow/shrink/basis, justify-content,
-- align-items/self/content, gap, order, auto margins,
-- min/max constraints, baseline alignment.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ValueVM = require("core/style/value_vm")

local Flex = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

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

local function resolve_num(val, context)
    if val == nil then return 0 end
    local r = ValueVM.resolve(val, context)
    if type(r) == "number" then return r end
    return 0
end

local function resolve_font_size(raw, engine, avail_w, avail_h, parent_font_size)
    if raw == nil then return parent_font_size or 16 end
    if type(raw) == "number" then return raw end
    if raw == "larger" then return (parent_font_size or 16) * 1.2 end
    if raw == "smaller" then return (parent_font_size or 16) / 1.2 end
    local boot = {
        parent_width = avail_w, parent_height = avail_h,
        percent_base = parent_font_size or 16,
        font_size = parent_font_size or 16, viewport_w = engine.viewport_w or 0,
        viewport_h = engine.viewport_h or 0, root_font_size = engine.root_font_size or 16,
    }
    local r = ValueVM.resolve(raw, boot)
    if type(r) == "number" then return r end
    return parent_font_size or 16
end

--- Clamp a value between min and max.
--- max == "none" means no upper bound.
local function clamp(val, min_v, max_v)
    if val < min_v then val = min_v end
    if type(max_v) == "number" and val > max_v then val = max_v end
    return val
end

--- Temporarily override computed width/height for a flex item,
--- run a callback, then restore the original values.
--- The flex algorithm determines the used main/cross size (outer);
--- block.lua expects content-box width, so we subtract padding+border.
local function with_flex_size(comp, is_row, main, cross, fn)
    local ow, oh = comp.width, comp.height
    local obs = comp.box_sizing
    -- Force border-box so block.lua treats the value as outer size
    comp.box_sizing = "border-box"
    if is_row then
        comp.width  = main
        comp.height = cross
    else
        comp.width  = cross
        comp.height = main
    end
    fn()
    comp.width  = ow
    comp.height = oh
    comp.box_sizing = obs
end

--- Stable sort by order property (insertion sort for stability).
local function stable_sort_by_order(items)
    for i = 2, #items do
        local key = items[i]
        local j = i - 1
        while j > 0 and items[j].order > key.order do
            items[j + 1] = items[j]
            j = j - 1
        end
        items[j + 1] = key
    end
end

------------------------------------------------------------
-- Main entry point
------------------------------------------------------------

--- Perform flex layout for a container node.
---@param engine  table   LayoutEngine instance
---@param nid     number  container node id
---@param avail_x number
---@param avail_y number
---@param avail_w number
---@param avail_h number
function Flex.layout(engine, nid, avail_x, avail_y, avail_w, avail_h)
    local ns = engine.ns
    local computed = ns.computed[nid]
    if not computed then return end
    local display = computed.display or "flex"

    -- Get parent's resolved font_size for em-based font-size resolution
    local parent_nid = ns.parent[nid]
    local parent_fs = 16
    if parent_nid and parent_nid ~= 0 then
        local pc = ns.computed[parent_nid]
        if pc and type(pc.font_size) == "number" then
            parent_fs = pc.font_size
        end
    end

    local context = {
        parent_width   = avail_w,
        parent_height  = avail_h,
        font_size      = resolve_font_size(computed.font_size, engine, avail_w, avail_h, parent_fs),
        viewport_w     = engine.viewport_w or 0,
        viewport_h     = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
    }

    -- Write resolved font_size back so painters can use it as a plain number
    computed.font_size = context.font_size

    -- ============================================================
    -- Resolve container box model (identical to block.lua)
    -- ============================================================
    local margin_t  = resolve_num(computed.margin_top, context)
    local margin_r  = resolve_num(computed.margin_right, context)
    local margin_b  = resolve_num(computed.margin_bottom, context)
    local margin_l  = resolve_num(computed.margin_left, context)

    local padding_t = resolve_num(computed.padding_top, context)
    local padding_r = resolve_num(computed.padding_right, context)
    local padding_b = resolve_num(computed.padding_bottom, context)
    local padding_l = resolve_num(computed.padding_left, context)

    local border_w  = resolve_num(computed.border_width, context)
    local border_t  = resolve_num(computed.border_top_width, context)
    local border_r  = resolve_num(computed.border_right_width, context)
    local border_b  = resolve_num(computed.border_bottom_width, context)
    local border_l  = resolve_num(computed.border_left_width, context)
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

    -- Container outer width
    local width_val = resolve_dim(computed.width, context)
    local outer_w
    if type(width_val) == "number" then
        if computed.box_sizing == "border-box" then
            outer_w = width_val
        else
            outer_w = width_val + padding_l + padding_r + border_l + border_r
        end
    else
        outer_w = avail_w - margin_l - margin_r
        if outer_w < 0 then outer_w = 0 end
    end

    if display == "inline-flex" and type(width_val) ~= "number" then
        local dir_for_intrinsic = computed.flex_direction or "row"
        local is_row_intrinsic = (dir_for_intrinsic == "row" or dir_for_intrinsic == "row-reverse")
        local gap_for_intrinsic = resolve_num(is_row_intrinsic and (computed.column_gap or computed.gap) or (computed.row_gap or computed.gap), context)
        local used_main = 0
        local max_cross = 0
        local item_count = 0
        local cid = ns.first_child[nid] or 0
        while cid ~= 0 do
            local cc = ns.computed[cid]
            local cd = cc and (cc.display or "block") or "block"
            local cp = cc and (cc.position or "static") or "static"
            if cd ~= "none" and cp ~= "absolute" and cp ~= "fixed" then
                local mw, mh = engine:measure(cid, avail_w, avail_h)
                local child_ctx = {
                    parent_width   = avail_w,
                    parent_height  = avail_h,
                    font_size      = context.font_size,
                    viewport_w     = context.viewport_w,
                    viewport_h     = context.viewport_h,
                    root_font_size = context.root_font_size,
                }
                local ml = resolve_num(cc and cc.margin_left or nil, child_ctx)
                local mr = resolve_num(cc and cc.margin_right or nil, child_ctx)
                local mt = resolve_num(cc and cc.margin_top or nil, child_ctx)
                local mb = resolve_num(cc and cc.margin_bottom or nil, child_ctx)
                if item_count > 0 then used_main = used_main + gap_for_intrinsic end
                if is_row_intrinsic then
                    used_main = used_main + mw + ml + mr
                    local outer_cross = mh + mt + mb
                    if outer_cross > max_cross then max_cross = outer_cross end
                else
                    used_main = used_main + mh + mt + mb
                    local outer_cross = mw + ml + mr
                    if outer_cross > max_cross then max_cross = outer_cross end
                end
                item_count = item_count + 1
            end
            cid = ns.next_sibling[cid] or 0
        end
        if is_row_intrinsic then
            outer_w = used_main + padding_l + padding_r + border_l + border_r
        else
            outer_w = max_cross + padding_l + padding_r + border_l + border_r
        end
        if outer_w < 0 then outer_w = 0 end
    end

    local min_width_val = resolve_dim(computed.min_width, context)
    if type(min_width_val) == "number" then
        local min_outer_w = computed.box_sizing == "border-box"
            and min_width_val
            or (min_width_val + padding_l + padding_r + border_l + border_r)
        if outer_w < min_outer_w then outer_w = min_outer_w end
    end
    local max_width_val = resolve_dim(computed.max_width, context)
    if type(max_width_val) == "number" then
        local max_outer_w = computed.box_sizing == "border-box"
            and max_width_val
            or (max_width_val + padding_l + padding_r + border_l + border_r)
        if outer_w > max_outer_w then outer_w = max_outer_w end
    end

    -- Container position
    local pos = computed.position or "static"
    local box_x, box_y
    if pos == "absolute" then
        local abs_left = resolve_dim(computed.left, context)
        local abs_top  = resolve_dim_percent_base(computed.top, context, avail_h)
        box_x = (type(abs_left) == "number") and (avail_x + abs_left) or (avail_x + margin_l)
        box_y = (type(abs_top)  == "number") and (avail_y + abs_top)  or (avail_y + margin_t)
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

    local content_x = box_x + border_l + padding_l
    local content_y = box_y + border_t + padding_t
    local content_w = outer_w - padding_l - padding_r - border_l - border_r
    if content_w < 0 then content_w = 0 end

    -- ============================================================
    -- Step 1: Determine axes + collect items
    -- ============================================================
    local dir       = computed.flex_direction or "row"
    local wrap_mode = computed.flex_wrap or "nowrap"

    local is_row     = (dir == "row" or dir == "row-reverse")
    local is_reverse = (dir == "row-reverse" or dir == "column-reverse")
    local is_wrap_reverse = (wrap_mode == "wrap-reverse")

    -- Resolve gaps
    local main_gap  = resolve_num(is_row and (computed.column_gap or computed.gap) or (computed.row_gap or computed.gap), context)
    local cross_gap = resolve_num(is_row and (computed.row_gap or computed.gap) or (computed.column_gap or computed.gap), context)

    -- Container height (for column flex + cross sizing)
    local height_val = resolve_dim_percent_base(computed.height, context, avail_h)
    local outer_h_definite = nil  -- nil means auto
    if type(height_val) == "number" then
        if computed.box_sizing == "border-box" then
            outer_h_definite = height_val
        else
            outer_h_definite = height_val + padding_t + padding_b + border_t + border_b
        end
    end

    -- Overflow containers fill available height.
    -- Engine sets overflow_y:"auto" on root nodes before layout.
    local ov_y = computed.overflow_y or "visible"
    if not outer_h_definite and (ov_y == "scroll" or ov_y == "auto") then
        local target = avail_h - margin_t - margin_b
        if target > 0 then
            outer_h_definite = target
        end
    end

    local content_h_definite = nil
    if outer_h_definite then
        content_h_definite = outer_h_definite - padding_t - padding_b - border_t - border_b
        if content_h_definite < 0 then content_h_definite = 0 end
    end

    -- Available main/cross space
    local avail_main  = is_row and content_w or (content_h_definite or 99999)
    local avail_cross = is_row and (content_h_definite or 99999) or content_w

    -- Collect flex items (skip display:none, separate absolute)
    local items = {}
    local abs_children = {}
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        local child_comp = ns.computed[cid]
        local child_display = "block"
        local child_pos = "static"
        if child_comp then
            child_display = child_comp.display or "block"
            child_pos = child_comp.position or "static"
        end

        if child_display == "none" then
            -- Skip: zero-size layout
            local clay = ns.layout[cid]
            clay.x = 0; clay.y = 0; clay.w = 0; clay.h = 0
            clay.content_x = 0; clay.content_y = 0
            clay.content_w = 0; clay.content_h = 0
            clay.pad_x = 0; clay.pad_y = 0
            clay.pad_w = 0; clay.pad_h = 0
        elseif child_pos == "absolute" or child_pos == "fixed" then
            abs_children[#abs_children + 1] = cid
            if child_pos == "fixed" and engine._fixed_nodes then
                engine._fixed_nodes[#engine._fixed_nodes + 1] = cid
            end
        elseif child_pos == "sticky" then
            if engine._sticky_nodes then
                local sticky_top = 0
                if child_comp and child_comp.top then
                    local resolved = resolve_dim_percent_base(child_comp.top, context, content_h_definite or avail_h)
                    if type(resolved) == "number" then sticky_top = resolved end
                end
                engine._sticky_nodes[#engine._sticky_nodes + 1] = { nid = cid, top = sticky_top }
            end
            items[#items + 1] = {
                nid   = cid,
                comp  = child_comp or {},
                order = (child_comp and child_comp.order) or 0,
            }
        else
            items[#items + 1] = {
                nid   = cid,
                comp  = child_comp or {},
                order = (child_comp and child_comp.order) or 0,
            }
        end

        cid = ns.next_sibling[cid] or 0
    end

    -- Sort by order (stable)
    stable_sort_by_order(items)

    -- Layout absolute children relative to content area
    for i = 1, #abs_children do
        engine:_layout_node(abs_children[i], content_x, content_y, content_w, content_h_definite or avail_h)
    end

    -- ============================================================
    -- Step 2: Determine flex base sizes
    -- ============================================================
    local item_ctx = {
        parent_width  = is_row and content_w or (content_h_definite or avail_h),
        parent_height = is_row and (content_h_definite or avail_h) or content_w,
        font_size     = context.font_size,
        viewport_w    = context.viewport_w,
        viewport_h    = context.viewport_h,
        root_font_size = context.root_font_size,
    }

    for i = 1, #items do
        local item = items[i]
        local ic = item.comp

        -- Resolve child's font_size for em-based margins/sizes
        local child_fs = resolve_font_size(ic.font_size, engine,
            is_row and content_w or (content_h_definite or avail_h),
            is_row and (content_h_definite or avail_h) or content_w,
            context.font_size)
        local child_item_ctx = {
            parent_width   = item_ctx.parent_width,
            parent_height  = item_ctx.parent_height,
            font_size      = child_fs,
            viewport_w     = item_ctx.viewport_w,
            viewport_h     = item_ctx.viewport_h,
            root_font_size = item_ctx.root_font_size,
        }

        local basis = resolve_dim(ic.flex_basis, child_item_ctx)
        local main_size_prop = is_row and ic.width or ic.height
        local main_size = resolve_dim(main_size_prop, child_item_ctx)
        local cross_size_prop = is_row and ic.height or ic.width
        local cross_size = resolve_dim(cross_size_prop, child_item_ctx)

        -- Determine flex base size (CSS 9.2)
        local base
        if type(basis) == "number" then
            -- A: Definite flex-basis
            base = basis
        elseif type(main_size) == "number" then
            -- B: flex-basis is auto, definite main size
            base = main_size
        else
            -- C: Measure content
            if is_row then
                local mw, mh = engine:measure(item.nid, content_w, content_h_definite or avail_h)
                base = mw
            else
                -- Column flex: measure height at container width.
                -- Only override width when the item has no definite width
                -- (auto width items should wrap text at container width).
                -- Items with explicit width keep their own width for
                -- correct height measurement.
                local item_has_width = (type(cross_size) == "number")
                if item_has_width then
                    local mw, mh = engine:measure(item.nid, cross_size, content_h_definite or avail_h)
                    base = mh
                else
                    local save_w = ic.width
                    local save_bs = ic.box_sizing
                    ic.width = content_w
                    ic.box_sizing = "border-box"
                    local mw, mh = engine:measure(item.nid, content_w, content_h_definite or avail_h)
                    ic.width = save_w
                    ic.box_sizing = save_bs
                    base = mh
                end
            end
        end

        -- Resolve min/max constraints.
        -- CSS §4.5 Automatic Minimum Size only applies when min-main is `auto`
        -- (the initial value).  An explicit `min-width: 0` / `min-height: 0`
        -- from the author must defeat this rule -" that's the canonical escape
        -- hatch for "let this flex item shrink below its content min-content".
        -- `resolve_num` flattens both nil and an explicit 0 to 0, so we must
        -- inspect the raw computed value here.
        local raw_min_main = is_row and ic.min_width or ic.min_height
        local min_main
        if raw_min_main == nil or raw_min_main == "auto" then
            min_main = 0
            local ov = is_row and (ic.overflow_x or "visible") or (ic.overflow_y or "visible")
            if ov == "visible" then
                min_main = base
            end
        else
            min_main = resolve_num(raw_min_main, child_item_ctx)
        end
        local max_main = resolve_dim(is_row and ic.max_width or ic.max_height, child_item_ctx)

        -- Hypothetical main size = base clamped to min/max
        local hypo = clamp(base, min_main, max_main)

        -- Resolve margins
        local m_main_start = resolve_dim(is_row and ic.margin_left   or ic.margin_top, child_item_ctx)
        local m_main_end   = resolve_dim(is_row and ic.margin_right  or ic.margin_bottom, child_item_ctx)
        local m_cross_start = resolve_dim(is_row and ic.margin_top    or ic.margin_left, child_item_ctx)
        local m_cross_end   = resolve_dim(is_row and ic.margin_bottom or ic.margin_right, child_item_ctx)

        -- Main-axis padding+border (for content-box → outer conversion).
        -- CSS flex-basis and width are content-box semantics by default
        -- (CSS spec §9.7), so hypo_main computed above is content-box for
        -- content-box items. The flex algorithm's line-packing AND the
        -- final layout (via with_flex_size, which treats main as outer)
        -- need OUTER (border-box) sizes -" otherwise line-packing fits
        -- one extra item per row vs Chrome and items render with
        -- shrunken outer boxes. Compute pb once and apply at each site
        -- where content-box → outer conversion is required.
        local bw_def = resolve_num(ic.border_width, child_item_ctx)
        local pb_main = 0
        if is_row then
            pb_main = resolve_num(ic.padding_left, child_item_ctx)
                    + resolve_num(ic.padding_right, child_item_ctx)
                    + (ic.border_left_width  ~= nil and resolve_num(ic.border_left_width,  child_item_ctx) or bw_def)
                    + (ic.border_right_width ~= nil and resolve_num(ic.border_right_width, child_item_ctx) or bw_def)
        else
            pb_main = resolve_num(ic.padding_top,    child_item_ctx)
                    + resolve_num(ic.padding_bottom, child_item_ctx)
                    + (ic.border_top_width    ~= nil and resolve_num(ic.border_top_width,    child_item_ctx) or bw_def)
                    + (ic.border_bottom_width ~= nil and resolve_num(ic.border_bottom_width, child_item_ctx) or bw_def)
        end
        -- `base_is_outer` is true when base/hypo_main is ALREADY in border-box
        -- units -" that's the case when item is box-sizing:border-box, or when
        -- base was measured via engine:measure (which returns outer/border-box).
        -- For content-box authored sizes we still need to add pb_main downstream.
        local base_from_measure = (type(basis) ~= "number" and type(main_size) ~= "number")
        local base_is_outer = base_from_measure or (ic.box_sizing == "border-box")
        local outer_extra = base_is_outer and 0 or pb_main

        -- Store on item
        item.flex_grow   = ic.flex_grow or 0
        item.flex_shrink = ic.flex_shrink or 1
        item.base_size   = base
        item.hypo_main   = hypo
        item.min_main    = min_main
        item.max_main    = max_main
        item.pb_main     = pb_main      -- main-axis padding+border
        item.outer_extra = outer_extra  -- 0 if base_is_outer, else pb_main
        item.cross_size  = cross_size  -- "auto" or number
        item.m_main_start  = m_main_start   -- number or "auto"
        item.m_main_end    = m_main_end     -- number or "auto"
        item.m_cross_start = m_cross_start  -- number or "auto"
        item.m_cross_end   = m_cross_end    -- number or "auto"
        item.align_self    = ic.align_self or "auto"
        item.frozen = false
        item.main_size_final = hypo  -- will be adjusted by grow/shrink
    end

    -- ============================================================
    -- Step 3: Collect items into flex lines
    -- ============================================================
    local lines = {}
    local current_line = {}
    local line_main_used = 0

    if wrap_mode == "nowrap" then
        -- Single line: all items
        lines[1] = items
    else
        for i = 1, #items do
            local item = items[i]
            -- "Outer hypothetical main size" per CSS Flexbox spec §9.3 step 5:
            -- includes padding + border + margin on the main axis. We add
            -- `outer_extra` (= main pb for content-box items, 0 for
            -- border-box / measure-based) so content-box items get the
            -- correct outer-size for line-packing decisions.
            local outer_hypo = item.hypo_main + (item.outer_extra or 0)
                + (type(item.m_main_start) == "number" and item.m_main_start or 0)
                + (type(item.m_main_end) == "number" and item.m_main_end or 0)
            local gap_add = (#current_line > 0) and main_gap or 0

            if #current_line > 0 and (line_main_used + gap_add + outer_hypo) > avail_main then
                -- Wrap: start new line
                lines[#lines + 1] = current_line
                current_line = { item }
                line_main_used = outer_hypo
            else
                current_line[#current_line + 1] = item
                line_main_used = line_main_used + gap_add + outer_hypo
            end
        end
        if #current_line > 0 then
            lines[#lines + 1] = current_line
        end
    end

    if #lines == 0 then lines[1] = {} end

    -- ============================================================
    -- Step 4: Resolve flexible lengths (per line)
    -- ============================================================
    for li = 1, #lines do
        local line = lines[li]
        if #line == 0 then break end

        -- Reset frozen flags
        for i = 1, #line do line[i].frozen = false end

        -- Calculate used main space (in OUTER/border-box units -" must
        -- match the line-packing decision above. Without outer_extra here
        -- the grow/shrink free-space calc treats items as smaller than
        -- they actually occupy on the line and misallocates remainder).
        local used = 0
        for i = 1, #line do
            local it = line[i]
            used = used + it.hypo_main + (it.outer_extra or 0)
                + (type(it.m_main_start) == "number" and it.m_main_start or 0)
                + (type(it.m_main_end) == "number" and it.m_main_end or 0)
        end
        used = used + (#line - 1) * main_gap

        local free = avail_main - used
        local growing = (free > 0)

        -- Iterative freeze loop
        for iteration = 1, #line do
            -- Sum of flex factors for unfrozen items
            local total_factor = 0
            local unfrozen = 0
            for i = 1, #line do
                if not line[i].frozen then
                    unfrozen = unfrozen + 1
                    if growing then
                        total_factor = total_factor + line[i].flex_grow
                    else
                        total_factor = total_factor + (line[i].flex_shrink * line[i].base_size)
                    end
                end
            end

            if unfrozen == 0 or total_factor == 0 then break end

            -- Recalculate free space based on current sizes (also OUTER).
            local current_used = 0
            for i = 1, #line do
                local it = line[i]
                current_used = current_used + it.main_size_final + (it.outer_extra or 0)
                    + (type(it.m_main_start) == "number" and it.m_main_start or 0)
                    + (type(it.m_main_end) == "number" and it.m_main_end or 0)
            end
            current_used = current_used + (#line - 1) * main_gap
            free = avail_main - current_used

            local any_frozen = false
            for i = 1, #line do
                local it = line[i]
                if not it.frozen then
                    local ratio
                    if growing then
                        ratio = it.flex_grow / total_factor
                    else
                        ratio = (it.flex_shrink * it.base_size) / total_factor
                    end

                    local new_size = it.main_size_final + free * ratio
                    local clamped = clamp(new_size, it.min_main, it.max_main)

                    if clamped ~= new_size then
                        -- Item hit a constraint: freeze it
                        it.main_size_final = clamped
                        it.frozen = true
                        any_frozen = true
                    else
                        it.main_size_final = new_size
                    end
                end
            end

            if not any_frozen then break end
        end

        -- Ensure non-negative sizes
        for i = 1, #line do
            if line[i].main_size_final < 0 then
                line[i].main_size_final = 0
            end
        end

    end

    -- ============================================================
    -- Step 5: Determine cross sizes
    -- ============================================================
    local line_cross_sizes = {}

    for li = 1, #lines do
        local line = lines[li]
        local max_cross = 0

        for i = 1, #line do
            local it = line[i]
            -- Measure to get cross size, forcing the flex main size
            -- onto the computed style so block.lua respects it.
            local ow, oh = it.comp.width, it.comp.height
            local obs = it.comp.box_sizing
            it.comp.box_sizing = "border-box"
            if is_row then
                it.comp.width = it.main_size_final
            else
                it.comp.height = it.main_size_final
            end

            local mw, mh
            if is_row then
                engine:_layout_node(it.nid, 0, 0, it.main_size_final, avail_cross)
                local clay = engine.ns.layout[it.nid]
                mw, mh = clay.w, clay.h
            else
                engine:_layout_node(it.nid, 0, 0, avail_cross, it.main_size_final)
                local clay = engine.ns.layout[it.nid]
                mw, mh = clay.w, clay.h
            end

            it.comp.width  = ow
            it.comp.height = oh
            it.comp.box_sizing = obs

            local item_cross = is_row and mh or mw
            local m_cs = type(it.m_cross_start) == "number" and it.m_cross_start or 0
            local m_ce = type(it.m_cross_end) == "number" and it.m_cross_end or 0
            local outer_cross = item_cross + m_cs + m_ce

            -- Aspect ratio: if cross auto, derive from main size
            local item_ar = it.comp.aspect_ratio
            if item_ar and type(item_ar) == "number" and item_ar > 0
               and it.cross_size == "auto" then
                if is_row then
                    -- main = width, cross = height → h = w / ar
                    item_cross = it.main_size_final / item_ar
                else
                    -- main = height, cross = width → w = h * ar
                    item_cross = it.main_size_final * item_ar
                end
                outer_cross = item_cross + m_cs + m_ce
            end

            it.cross_size_final = item_cross
            it.outer_cross = outer_cross

            if outer_cross > max_cross then max_cross = outer_cross end
        end

        line_cross_sizes[li] = max_cross
    end

    -- Single-line container: line cross = container cross (if definite)
    if #lines == 1 and avail_cross < 99999 then
        if line_cross_sizes[1] < avail_cross then
            line_cross_sizes[1] = avail_cross
        end
    end

    -- Apply align-self: stretch
    local container_align = computed.align_items or "stretch"
    for li = 1, #lines do
        local line = lines[li]
        local line_cross = line_cross_sizes[li]
        for i = 1, #line do
            local it = line[i]
            local self_align = it.align_self
            if self_align == "auto" then self_align = container_align end
            local m_cs = type(it.m_cross_start) == "number" and it.m_cross_start or 0
            local m_ce = type(it.m_cross_end) == "number" and it.m_cross_end or 0
            if self_align == "stretch" and it.cross_size == "auto" then
                it.cross_size_final = line_cross - m_cs - m_ce
                if it.cross_size_final < 0 then it.cross_size_final = 0 end
            end
        end
    end

    -- ============================================================
    -- Step 6: Main axis alignment (justify-content + auto margins)
    -- ============================================================
    local justify = computed.justify_content or "flex-start"

    for li = 1, #lines do
        local line = lines[li]
        if #line == 0 then break end

        -- Calculate used main space after grow/shrink.
        -- IMPORTANT: must match the grow/shrink free-space calc above -"
        -- main_size_final is the CONTENT size; for content-box items we
        -- must also account for outer_extra (padding + border on the
        -- main axis) so that justify-content (space-between, space-around,
        -- space-evenly) distributes the SAME free-space the grow pass
        -- saw. Without outer_extra, the available main-space appears
        -- larger than it really is and the alignment gap inflates by
        -- (n -- pb_main).
        local used = 0
        for i = 1, #line do
            local it = line[i]
            used = used + it.main_size_final + (it.outer_extra or 0)
                + (type(it.m_main_start) == "number" and it.m_main_start or 0)
                + (type(it.m_main_end) == "number" and it.m_main_end or 0)
        end
        used = used + (#line - 1) * main_gap
        local remaining = avail_main - used
        if remaining < 0 then remaining = 0 end

        -- Auto margins absorb free space first
        local auto_margin_count = 0
        for i = 1, #line do
            local it = line[i]
            if it.m_main_start == "auto" then auto_margin_count = auto_margin_count + 1 end
            if it.m_main_end == "auto" then auto_margin_count = auto_margin_count + 1 end
        end

        if auto_margin_count > 0 then
            local per_auto = remaining / auto_margin_count
            for i = 1, #line do
                local it = line[i]
                if it.m_main_start == "auto" then it.m_main_start = per_auto end
                if it.m_main_end == "auto" then it.m_main_end = per_auto end
            end
            remaining = 0
        end

        -- Resolve auto cross margins
        for i = 1, #line do
            local it = line[i]
            if it.m_cross_start == "auto" and it.m_cross_end == "auto" then
                local cross_free = line_cross_sizes[li] - it.cross_size_final
                if cross_free < 0 then cross_free = 0 end
                it.m_cross_start = cross_free / 2
                it.m_cross_end = cross_free / 2
            elseif it.m_cross_start == "auto" then
                local m_ce = type(it.m_cross_end) == "number" and it.m_cross_end or 0
                it.m_cross_start = line_cross_sizes[li] - it.cross_size_final - m_ce
                if it.m_cross_start < 0 then it.m_cross_start = 0 end
            elseif it.m_cross_end == "auto" then
                local m_cs = type(it.m_cross_start) == "number" and it.m_cross_start or 0
                it.m_cross_end = line_cross_sizes[li] - it.cross_size_final - m_cs
                if it.m_cross_end < 0 then it.m_cross_end = 0 end
            end
        end

        -- Calculate start offset and gap for justify-content
        local offset = 0
        local extra_gap = 0
        local n = #line

        if justify == "flex-end" then
            offset = remaining
        elseif justify == "center" then
            offset = remaining / 2
        elseif justify == "space-between" then
            if n > 1 then extra_gap = remaining / (n - 1) end
        elseif justify == "space-around" then
            if n > 0 then
                local space = remaining / n
                offset = space / 2
                extra_gap = space
            end
        elseif justify == "space-evenly" then
            if n > 0 then
                local space = remaining / (n + 1)
                offset = space
                extra_gap = space
            end
        end
        -- flex-start: offset = 0, extra_gap = 0 (default)

        -- Store per-line: start offset and extra gap
        line._main_offset = offset
        line._extra_gap = extra_gap
    end

    -- ============================================================
    -- Step 7: Cross axis alignment (align-items / align-self)
    -- ============================================================
    -- Computed per item as cross_offset within its line.

    -- For `align-self: baseline`: per CSS Flexbox §8.3 we compute the
    -- baseline group of each line.  An item's baseline is its first-line
    -- baseline offset from its top edge (ascent for text-bearing boxes,
    -- bottom-of-margin-box for non-baseline items per spec fallback).
    -- The line's "max baseline" is the largest ascent among baseline-aligned
    -- items; every baseline-aligned item is then positioned so its
    -- baseline equals that max ascent.  Without this pass, mixed-font-size
    -- baseline-aligned items don't line up.
    local function ascent_for(it)
        local fs_raw = it.comp.font_size or computed.font_size
        local fs = resolve_font_size(fs_raw, engine, avail_w, avail_h, context.font_size)
        local lh = it.comp.line_height
        if type(lh) ~= "number" then lh = 1.2 end
        local line_px = (lh <= 4) and (lh * fs) or lh
        -- Top half of the line-leading + ascent ≈ 0.8 of font_size from
        -- the line-top, plus half-leading.  This matches Chrome's
        -- "first available baseline" for plain block text.
        local half_leading = (line_px - fs) * 0.5
        if half_leading < 0 then half_leading = 0 end
        return half_leading + fs * 0.8
    end

    for li = 1, #lines do
        local line = lines[li]
        local line_cross = line_cross_sizes[li]

        -- Pass 1: find the line's max baseline ascent among baseline-aligned items.
        local max_ascent = 0
        local has_baseline = false
        for i = 1, #line do
            local it = line[i]
            local self_align = it.align_self
            if self_align == "auto" then self_align = container_align end
            if self_align == "baseline" then
                has_baseline = true
                local m_cs = type(it.m_cross_start) == "number" and it.m_cross_start or 0
                local a = ascent_for(it) + m_cs
                if a > max_ascent then max_ascent = a end
            end
        end

        for i = 1, #line do
            local it = line[i]
            local self_align = it.align_self
            if self_align == "auto" then self_align = container_align end

            local m_cs = type(it.m_cross_start) == "number" and it.m_cross_start or 0
            local m_ce = type(it.m_cross_end) == "number" and it.m_cross_end or 0
            local item_outer_cross = it.cross_size_final + m_cs + m_ce
            local cross_free = line_cross - item_outer_cross

            if self_align == "flex-end" then
                it.cross_offset = cross_free + m_cs
            elseif self_align == "center" then
                it.cross_offset = cross_free / 2 + m_cs
            elseif self_align == "baseline" then
                -- Align this item's first-line baseline to the line's max ascent.
                local my_ascent = ascent_for(it) + m_cs
                it.cross_offset = max_ascent - my_ascent + m_cs
                if it.cross_offset < m_cs then it.cross_offset = m_cs end
            else
                -- flex-start / stretch
                it.cross_offset = m_cs
            end
        end
    end

    -- ============================================================
    -- Step 8: Align flex lines (align-content)
    -- ============================================================
    local total_lines_cross = 0
    for li = 1, #lines do
        total_lines_cross = total_lines_cross + line_cross_sizes[li]
    end
    total_lines_cross = total_lines_cross + (#lines - 1) * cross_gap

    local cross_remaining = avail_cross - total_lines_cross
    -- When cross axis is indefinite (auto height), there is no
    -- remaining space to distribute -" align-content has no effect.
    if cross_remaining < 0 or avail_cross >= 99999 then cross_remaining = 0 end

    local ac = computed.align_content or "stretch"
    local line_offsets = {}
    local line_extra_gap = 0
    local line_start_offset = 0

    if #lines <= 1 or wrap_mode == "nowrap" then
        -- Single-line: align-content has no effect
        line_offsets[1] = 0
    else
        if ac == "flex-end" then
            line_start_offset = cross_remaining
        elseif ac == "center" then
            line_start_offset = cross_remaining / 2
        elseif ac == "space-between" then
            if #lines > 1 then line_extra_gap = cross_remaining / (#lines - 1) end
        elseif ac == "space-around" then
            local space = cross_remaining / #lines
            line_start_offset = space / 2
            line_extra_gap = space
        elseif ac == "space-evenly" then
            local space = cross_remaining / (#lines + 1)
            line_start_offset = space
            line_extra_gap = space
        elseif ac == "stretch" then
            -- Distribute extra cross space equally among lines, then re-grow
            -- each stretched item so it fills the now-larger line.  Without
            -- the second pass, items keep their pre-`align-content` cross
            -- size and the extra room shows as gap inside the line.
            -- CSS Flexbox §9.6.16.
            local per_line = cross_remaining / #lines
            local container_align = computed.align_items or "stretch"
            for li = 1, #lines do
                line_cross_sizes[li] = line_cross_sizes[li] + per_line
                local line = lines[li]
                local lc = line_cross_sizes[li]
                for i = 1, #line do
                    local it = line[i]
                    local self_align = it.align_self
                    if self_align == "auto" then self_align = container_align end
                    if self_align == "stretch" and it.cross_size == "auto" then
                        local m_cs = type(it.m_cross_start) == "number" and it.m_cross_start or 0
                        local m_ce = type(it.m_cross_end)   == "number" and it.m_cross_end   or 0
                        local stretched = lc - m_cs - m_ce
                        if stretched < 0 then stretched = 0 end
                        it.cross_size_final = stretched
                    end
                end
            end
        end
        -- flex-start: line_start_offset = 0

        local cursor = line_start_offset
        for li = 1, #lines do
            line_offsets[li] = cursor
            cursor = cursor + line_cross_sizes[li] + cross_gap + line_extra_gap
        end
    end

    if not line_offsets[1] then line_offsets[1] = 0 end

    -- ============================================================
    -- Step 9: Apply reverse + final placement
    -- ============================================================
    local scroll = ns.scroll[nid]
    local scroll_y = (scroll and scroll.y) or 0
    local scroll_x = (scroll and scroll.x) or 0

    local total_children_h = 0  -- for scroll_h
    local total_children_w = 0  -- for scroll_w

    for li = 1, #lines do
        local line = lines[li]
        local line_offset = line_offsets[li] or 0

        -- For reversed directions, place items from the opposite end.
        -- The justify-content offset/gap were computed for the normal
        -- direction; when reversed, we mirror the start position so
        -- that flex-start packs towards main-end (right / bottom).
        local main_cursor
        if is_reverse then
            -- Total used space on this line (sizes + margins + gaps)
            local line_used = 0
            for i = 1, #line do
                local it = line[i]
                local ms = type(it.m_main_start) == "number" and it.m_main_start or 0
                local me = type(it.m_main_end) == "number" and it.m_main_end or 0
                line_used = line_used + ms + it.main_size_final + me
            end
            line_used = line_used + (#line - 1) * (main_gap + (line._extra_gap or 0))
            -- Mirror: start cursor so items end at avail_main - offset
            main_cursor = avail_main - (line._main_offset or 0) - line_used
        else
            main_cursor = line._main_offset or 0
        end

        -- Reverse item order within line for reversed directions
        local ordered = line
        if is_reverse then
            ordered = {}
            for i = #line, 1, -1 do ordered[#ordered + 1] = line[i] end
        end

        for i = 1, #ordered do
            local it = ordered[i]
            local m_ms = type(it.m_main_start) == "number" and it.m_main_start or 0
            local m_me = type(it.m_main_end) == "number" and it.m_main_end or 0

            -- Compute final x, y.
            -- Flex owns positioning: add margin-start to cursor
            -- BEFORE placing the item, then zero-out the child's
            -- margins so block.lua doesn't add them again.
            main_cursor = main_cursor + m_ms

            -- main_size_final is in CONTENT-BOX units for content-box items
            -- (and BORDER-BOX for border-box items). with_flex_size forces
            -- box_sizing="border-box" + width=main, so we must pass OUTER
            -- size -" otherwise block.lua treats content-box width as the
            -- outer box, shrinking the item by padding+border.
            -- outer_extra was computed earlier: pb_main for content-box,
            -- 0 for border-box / measure-based.
            local outer_extra = it.outer_extra or 0
            local effective_main = it.main_size_final + outer_extra

            local fx, fy, fw, fh
            if is_row then
                fx = content_x + main_cursor - scroll_x
                fy = content_y + line_offset + (it.cross_offset or 0) - scroll_y
                fw = effective_main
                fh = it.cross_size_final
            else
                fx = content_x + line_offset + (it.cross_offset or 0) - scroll_x
                fy = content_y + main_cursor - scroll_y
                fw = it.cross_size_final
                fh = effective_main
            end

            -- Final placement layout -" force flex-determined sizes
            -- onto computed style so block.lua respects them.
            -- Zero margins so block.lua doesn't double-count them
            -- (flex already positioned the item at the correct offset).
            local save_mt = it.comp.margin_top
            local save_mb = it.comp.margin_bottom
            local save_ml = it.comp.margin_left
            local save_mr = it.comp.margin_right
            it.comp.margin_top    = 0
            it.comp.margin_bottom = 0
            it.comp.margin_left   = 0
            it.comp.margin_right  = 0
            with_flex_size(it.comp, is_row, effective_main, it.cross_size_final, function()
                engine:_layout_node(it.nid, fx, fy, fw, fh)
            end)
            it.comp.margin_top    = save_mt
            it.comp.margin_bottom = save_mb
            it.comp.margin_left   = save_ml
            it.comp.margin_right  = save_mr

            main_cursor = main_cursor + effective_main + m_me + main_gap + (line._extra_gap or 0)
        end

        -- Track cross extent for scroll_h and main extent for scroll_w
        total_children_h = total_children_h + line_cross_sizes[li] + cross_gap

        -- Track total main axis used (for horizontal scroll in row mode).
        -- Same outer-size accounting as line-packing above.
        local line_main_used = 0
        for i = 1, #line do
            local it = line[i]
            local ms = type(it.m_main_start) == "number" and it.m_main_start or 0
            local me = type(it.m_main_end) == "number" and it.m_main_end or 0
            line_main_used = line_main_used + ms + it.main_size_final + (it.outer_extra or 0) + me
        end
        line_main_used = line_main_used + (#line - 1) * main_gap
        if line_main_used > total_children_w then total_children_w = line_main_used end
    end
    total_children_h = total_children_h - cross_gap  -- remove trailing gap
    if total_children_h < 0 then total_children_h = 0 end

    -- Reverse line order
    if is_wrap_reverse and #lines > 1 then
        -- Flip line positions: mirror around center of cross axis
        local total_cross = line_offsets[#lines] + line_cross_sizes[#lines]
        for li = 1, #lines do
            local old_offset = line_offsets[li]
            line_offsets[li] = total_cross - old_offset - line_cross_sizes[li]
        end
        -- Re-place items with flipped offsets (margins already zeroed in first pass)
        for li = 1, #lines do
            local line = lines[li]
            local line_offset = line_offsets[li]
            for i = 1, #line do
                local it = line[i]
                local clay = ns.layout[it.nid]
                local save_mt = it.comp.margin_top
                local save_mb = it.comp.margin_bottom
                local save_ml = it.comp.margin_left
                local save_mr = it.comp.margin_right
                it.comp.margin_top    = 0
                it.comp.margin_bottom = 0
                it.comp.margin_left   = 0
                it.comp.margin_right  = 0
                if is_row then
                    local new_y = content_y + line_offset + (it.cross_offset or 0) - scroll_y
                    with_flex_size(it.comp, is_row, it.main_size_final, it.cross_size_final, function()
                        engine:_layout_node(it.nid, clay.x, new_y, clay.w, it.cross_size_final)
                    end)
                else
                    local new_x = content_x + line_offset + (it.cross_offset or 0) - scroll_x
                    with_flex_size(it.comp, is_row, it.main_size_final, it.cross_size_final, function()
                        engine:_layout_node(it.nid, new_x, clay.y, it.cross_size_final, clay.h)
                    end)
                end
                it.comp.margin_top    = save_mt
                it.comp.margin_bottom = save_mb
                it.comp.margin_left   = save_ml
                it.comp.margin_right  = save_mr
            end
        end
    end

    -- ============================================================
    -- Store container layout
    -- ============================================================
    local outer_h
    if outer_h_definite then
        outer_h = outer_h_definite
    else
        if is_row then
            outer_h = total_children_h + padding_t + padding_b + border_t + border_b
        else
            -- Column: total main is the height
            local total_main_final = 0
            for li = 1, #lines do
                local line = lines[li]
                local line_main = 0
                for i = 1, #line do
                    local it = line[i]
                    local m_ms = type(it.m_main_start) == "number" and it.m_main_start or 0
                    local m_me = type(it.m_main_end) == "number" and it.m_main_end or 0
                    line_main = line_main + it.main_size_final + m_ms + m_me
                end
                line_main = line_main + (#line - 1) * main_gap
                if line_main > total_main_final then total_main_final = line_main end
            end
            outer_h = total_main_final + padding_t + padding_b + border_t + border_b
        end
    end

    if outer_w < 0 then outer_w = 0 end
    if outer_h < 0 then outer_h = 0 end

    local final_content_w = outer_w - padding_l - padding_r - border_l - border_r
    local final_content_h = outer_h - padding_t - padding_b - border_t - border_b
    if final_content_w < 0 then final_content_w = 0 end
    if final_content_h < 0 then final_content_h = 0 end

    -- scroll_h: content height for scroll engine.
    -- Based on rendered (post-flex) sizes so scroll extent matches
    -- what children actually occupy.  Items that can't shrink
    -- (flex_shrink:0 or CSS §4.5 min) keep their full size,
    -- causing scroll_h > content_h when overflow occurs.
    local scroll_h_val
    if is_row then
        scroll_h_val = total_children_h
    else
        local max_line_main = 0
        for li = 1, #lines do
            local line = lines[li]
            local line_main = 0
            for i = 1, #line do
                local it = line[i]
                local m_ms = type(it.m_main_start) == "number" and it.m_main_start or 0
                local m_me = type(it.m_main_end) == "number" and it.m_main_end or 0
                line_main = line_main + it.main_size_final + m_ms + m_me
            end
            line_main = line_main + (#line - 1) * main_gap
            if line_main > max_line_main then max_line_main = line_main end
        end
        scroll_h_val = max_line_main
    end

    local lay = ns.layout[nid]
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
    lay.scroll_h  = scroll_h_val
    -- scroll_w: intrinsic content width for horizontal scroll engine
    local scroll_w_val
    if is_row then
        scroll_w_val = total_children_w
    else
        -- For column: total cross extent is the horizontal scrollable width
        scroll_w_val = total_lines_cross
    end
    lay.scroll_w  = scroll_w_val

    ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
    ns:mark_dirty(nid, ns.PAINT_DIRTY)
end

return Flex



