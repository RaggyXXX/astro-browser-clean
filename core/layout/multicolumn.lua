------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / multicolumn.lua
-- CSS Multi-Column Layout algorithm.
--
-- Resolves column-count / column-width / column-gap into
-- concrete column positions, lays out children in normal
-- block flow, then distributes them across columns by
-- height.  Also paints column rules between columns.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ValueVM = require("core/style/value_vm")

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local math_ceil  = math.ceil

local MultiColumn = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

--- Build a ValueVM context from engine + computed style.
local function make_context(engine, computed, avail_w, avail_h)
    local fs = computed.font_size
    if type(fs) ~= "number" then fs = 16 end
    return {
        parent_width   = avail_w,
        parent_height  = avail_h,
        font_size      = fs,
        viewport_w     = engine.viewport_w or 0,
        viewport_h     = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
    }
end

--- Resolve a numeric CSS value, defaulting to 0.
local function resolve_num(val, context)
    if val == nil then return 0 end
    local r = ValueVM.resolve(val, context)
    if type(r) == "number" then return r end
    return 0
end

--- Resolve a dimension value, returning number or "auto".
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

--- Collect direct child node IDs (skipping display:none).
local function collect_children(ns, nid)
    local children = {}
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        local cc = ns.computed[cid]
        if cc and (cc.display or "block") ~= "none" then
            children[#children + 1] = cid
        end
        cid = ns.next_sibling[cid] or 0
    end
    return children
end

------------------------------------------------------------
-- Resolve column count
------------------------------------------------------------

--- Determine the actual number of columns and per-column
--- width from the CSS column-count / column-width properties.
---@param col_count  number|nil  column-count (nil = auto)
---@param col_width  number|nil  column-width (nil = auto)
---@param content_w  number      available content width
---@param col_gap    number      gap between columns
---@return number num_cols
---@return number col_w
local function resolve_columns(col_count, col_width, content_w, col_gap)
    if content_w <= 0 then
        return 1, 0
    end

    local num_cols

    if col_count and col_width then
        -- Both specified: use the minimum of column_count and
        -- how many columns of column_width fit.
        local fit = math_floor((content_w + col_gap) / (col_width + col_gap))
        if fit < 1 then fit = 1 end
        num_cols = math_min(col_count, fit)
    elseif col_count then
        num_cols = col_count
    elseif col_width then
        num_cols = math_floor((content_w + col_gap) / (col_width + col_gap))
        if num_cols < 1 then num_cols = 1 end
    else
        -- Neither specified -" caller should not invoke multicolumn,
        -- but handle gracefully as single column.
        num_cols = 1
    end

    if num_cols < 1 then num_cols = 1 end

    -- Column width: distribute remaining space evenly
    local total_gaps = col_gap * (num_cols - 1)
    local col_w = (content_w - total_gaps) / num_cols
    if col_w < 0 then col_w = 0 end

    return num_cols, col_w
end

------------------------------------------------------------
-- Layout
------------------------------------------------------------

--- Perform multi-column layout for a node.
---
--- The node's box model (border, padding) is resolved here,
--- children are laid out into a single tall column first,
--- then split across columns by height.
---
---@param engine  table   LayoutEngine instance
---@param nid     number  node id
---@param avail_x number  available x position
---@param avail_y number  available y position
---@param avail_w number  available width
---@param avail_h number  available height
function MultiColumn.layout(engine, nid, avail_x, avail_y, avail_w, avail_h)
    local ns = engine.ns
    local computed = ns.computed[nid]
    if not computed then return end

    local context = make_context(engine, computed, avail_w, avail_h)

    -- 1. Resolve box model --------------------------------
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

    local margin_t = resolve_num(computed.margin_top, context)
    local margin_b = resolve_num(computed.margin_bottom, context)
    local margin_l = resolve_num(computed.margin_left, context)
    local margin_r = resolve_num(computed.margin_right, context)

    -- Width
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

    local content_w = outer_w - padding_l - padding_r - border_l - border_r
    if content_w < 0 then content_w = 0 end

    local box_x = avail_x + margin_l
    local box_y = avail_y + margin_t
    local content_x = box_x + border_l + padding_l
    local content_y = box_y + border_t + padding_t

    -- 2. Resolve column parameters ------------------------
    local col_count = computed.column_count   -- number or nil
    local col_width = computed.column_width   -- number or nil
    local col_gap   = resolve_num(computed.column_gap, context)
    if col_gap <= 0 and computed.gap then
        col_gap = resolve_num(computed.gap, context)
    end
    -- CSS spec: column-gap default is "normal" = 1em
    if col_gap <= 0 and computed.column_gap == nil and computed.gap == nil then
        col_gap = context.font_size or 16
    end

    local num_cols, col_w = resolve_columns(col_count, col_width, content_w, col_gap)

    -- 3. Collect children ---------------------------------
    local children = collect_children(ns, nid)
    if #children == 0 then
        -- No children: empty box
        local height_val = resolve_dim_percent_base(computed.height, context, avail_h)
        local outer_h
        if type(height_val) == "number" then
            if computed.box_sizing == "border-box" then
                outer_h = height_val
            else
                outer_h = height_val + padding_t + padding_b + border_t + border_b
            end
        else
            outer_h = padding_t + padding_b + border_t + border_b
        end
        if outer_h < 0 then outer_h = 0 end

        local lay = ns.layout[nid]
        lay.x         = box_x
        lay.y         = box_y
        lay.w         = outer_w
        lay.h         = outer_h
        lay.content_x = content_x
        lay.content_y = content_y
        lay.content_w = content_w
        lay.content_h = 0
        lay.pad_x     = box_x + border_l
        lay.pad_y     = box_y + border_t
        lay.pad_w     = outer_w - border_l - border_r
        lay.pad_h     = outer_h - border_t - border_b
        lay.scroll_h  = 0
        lay.scroll_w  = 0
        ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
        ns:mark_dirty(nid, ns.PAINT_DIRTY)
        return
    end

    -- Single column fast path
    if num_cols <= 1 then
        num_cols = 1
        col_w = content_w
    end

    -- 4. Measure all children in a single tall column -----
    --    Layout each child at full col_w to get its height.
    local child_heights = {}
    local total_h = 0
    for i = 1, #children do
        local cid = children[i]
        engine:_layout_node(cid, content_x, content_y + total_h, col_w, avail_h)
        local child_lay = ns.layout[cid]
        local ch = child_lay.h or 0

        -- Include child margins
        local cc = ns.computed[cid]
        local child_ctx = make_context(engine, cc or {}, col_w, avail_h)
        local cm_t = resolve_num(cc and cc.margin_top, child_ctx)
        local cm_b = resolve_num(cc and cc.margin_bottom, child_ctx)
        local outer_ch = ch + cm_t + cm_b

        child_heights[i] = {
            cid      = cid,
            outer_h  = outer_ch,
            margin_t = cm_t,
            margin_b = cm_b,
            h        = ch,
        }
        total_h = total_h + outer_ch
    end

    -- 5. Compute ideal column height ----------------------
    --    Target: distribute content evenly across columns.
    local ideal_col_h = math_ceil(total_h / num_cols)
    if ideal_col_h < 1 then ideal_col_h = 1 end

    -- 6. Assign children to columns (greedy fill) ---------
    --    columns[col_index] = { list of child info entries }
    local columns = {}
    for c = 1, num_cols do
        columns[c] = {}
    end

    local cur_col = 1
    local cur_col_h = 0

    for i = 1, #children do
        local entry = child_heights[i]

        -- If current column is not empty and adding this child
        -- would exceed ideal height, move to next column
        if cur_col < num_cols and #columns[cur_col] > 0 then
            if cur_col_h + entry.outer_h > ideal_col_h then
                cur_col = cur_col + 1
                cur_col_h = 0
            end
        end

        columns[cur_col][#columns[cur_col] + 1] = entry
        cur_col_h = cur_col_h + entry.outer_h
    end

    -- 7. Position children in their assigned columns ------
    local max_col_h = 0

    for c = 1, num_cols do
        local col_x = content_x + (c - 1) * (col_w + col_gap)
        local col_y = content_y
        local col_entries = columns[c]
        local col_used = 0

        for j = 1, #col_entries do
            local entry = col_entries[j]
            local cid = entry.cid
            local child_y = col_y + col_used + entry.margin_t

            -- Re-layout child at its final column position
            engine:_layout_node(cid, col_x, child_y, col_w, avail_h)

            col_used = col_used + entry.outer_h
        end

        if col_used > max_col_h then
            max_col_h = col_used
        end
    end

    -- 8. Compute final height -----------------------------
    local content_h = max_col_h
    local height_val = resolve_dim_percent_base(computed.height, context, avail_h)
    local outer_h
    if type(height_val) == "number" then
        if computed.box_sizing == "border-box" then
            outer_h = height_val
        else
            outer_h = height_val + padding_t + padding_b + border_t + border_b
        end
    else
        outer_h = content_h + padding_t + padding_b + border_t + border_b
    end
    if outer_h < 0 then outer_h = 0 end

    -- Recalculate final content dimensions
    local final_content_w = outer_w - padding_l - padding_r - border_l - border_r
    local final_content_h = outer_h - padding_t - padding_b - border_t - border_b
    if final_content_w < 0 then final_content_w = 0 end
    if final_content_h < 0 then final_content_h = 0 end

    -- 9. Store layout box ---------------------------------
    local lay = ns.layout[nid]
    lay.x         = box_x
    lay.y         = box_y
    lay.w         = outer_w
    lay.h         = outer_h
    lay.content_x = content_x
    lay.content_y = content_y
    lay.content_w = final_content_w
    lay.content_h = final_content_h
    lay.pad_x     = box_x + border_l
    lay.pad_y     = box_y + border_t
    lay.pad_w     = outer_w - border_l - border_r
    lay.pad_h     = outer_h - border_t - border_b
    lay.scroll_h  = content_h
    lay.scroll_w  = content_w

    -- Store column metadata for paint_rules
    lay._mc_num_cols = num_cols
    lay._mc_col_w    = col_w
    lay._mc_col_gap  = col_gap

    -- Clear layout dirty, mark paint dirty
    ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
    ns:mark_dirty(nid, ns.PAINT_DIRTY)
end

------------------------------------------------------------
-- Column rule painting
------------------------------------------------------------

--- Paint column rules (vertical lines between columns).
---
--- Called during the paint phase if column_rule_width > 0
--- and column_rule_style ~= "none".
---
---@param ns  table  NodeStore instance
---@param nid number node id
---@param dl  table  DisplayList instance
function MultiColumn.paint_rules(ns, nid, dl)
    local computed = ns.computed[nid]
    if not computed then return end

    local rule_w = computed.column_rule_width
    if not rule_w or rule_w <= 0 then return end

    local rule_style = computed.column_rule_style or "none"
    if rule_style == "none" then return end

    local rule_color = computed.column_rule_color
    -- Fallback: use text color if no rule color specified
    if not rule_color then
        rule_color = computed.color or {128, 128, 128, 255}
    end

    local lay = ns.layout[nid]
    if not lay then return end

    local num_cols = lay._mc_num_cols
    local col_w    = lay._mc_col_w
    local col_gap  = lay._mc_col_gap

    if not num_cols or num_cols <= 1 then return end

    -- Color components (0-255) -" engine uses byte arrays {r,g,b,a}
    local cr, cg, cb, ca
    if type(rule_color) == "table" then
        if rule_color[1] then
            -- Byte array format {r, g, b, a}
            cr = rule_color[1] or 0
            cg = rule_color[2] or 0
            cb = rule_color[3] or 0
            ca = rule_color[4] or 255
        else
            -- Shouldn't happen, but guard against named-key tables
            cr = rule_color.r or 0
            cg = rule_color.g or 0
            cb = rule_color.b or 0
            ca = rule_color.a or 255
        end
    else
        cr = 128; cg = 128; cb = 128; ca = 255
    end

    -- Clamp
    if cr > 255 then cr = 255 end
    if cg > 255 then cg = 255 end
    if cb > 255 then cb = 255 end
    if ca > 255 then ca = 255 end

    local content_x = lay.content_x
    local content_y = lay.content_y
    local content_h = lay.content_h
    if content_h <= 0 then content_h = lay.h or 0 end

    -- Draw a vertical rule between each pair of adjacent columns.
    -- The rule is centered in the gap.
    for c = 1, num_cols - 1 do
        local col_right_edge = content_x + c * col_w + (c - 1) * col_gap
        local gap_center_x = col_right_edge + col_gap / 2

        local rule_x = math_floor(gap_center_x - rule_w / 2)
        local rule_y = math_floor(content_y)
        local rule_h = math_floor(content_h)

        if rule_style == "solid" then
            -- Solid: filled rectangle
            dl:rect_fill(rule_x, rule_y, math_ceil(rule_w), rule_h, cr, cg, cb, ca, 0)

        elseif rule_style == "dashed" then
            -- Dashed: series of short rectangles
            local dash_len = math_max(math_floor(rule_h / 20), 6)
            local gap_len  = math_max(math_floor(dash_len * 0.6), 3)
            local y_cursor = rule_y
            while y_cursor < rule_y + rule_h do
                local seg_h = math_min(dash_len, rule_y + rule_h - y_cursor)
                dl:rect_fill(rule_x, y_cursor, math_ceil(rule_w), seg_h, cr, cg, cb, ca, 0)
                y_cursor = y_cursor + dash_len + gap_len
            end

        elseif rule_style == "dotted" then
            -- Dotted: series of small squares / circles
            local dot_size = math_max(math_ceil(rule_w), 2)
            local dot_gap  = math_max(dot_size, 3)
            local y_cursor = rule_y
            local dot_x = math_floor(gap_center_x - dot_size / 2)
            while y_cursor < rule_y + rule_h do
                dl:rect_fill(dot_x, y_cursor, dot_size, dot_size, cr, cg, cb, ca, math_floor(dot_size / 2))
                y_cursor = y_cursor + dot_size + dot_gap
            end
        end
        -- "none" already handled above
    end
end

return MultiColumn



