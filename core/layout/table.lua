------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / table.lua
-- CSS Table Layout: display table/table-row/table-cell.
--
-- Implements auto column width algorithm:
--   1. Normalize children into rows/cells
--   2. Measure cell min/max widths
--   3. Distribute available width to columns
--   4. Place cells with border-spacing
--   5. Support colspan/rowspan, vertical-align
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ValueVM = require("core/style/value_vm")

local TableLayout = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

--- Resolve a CSS value to a number in the given context.
local function resolve_val(val, context)
    if type(val) == "number" then return val end
    if val == nil then return 0 end
    if type(val) == "table" or type(val) == "string" then
        local r = ValueVM.resolve(val, context)
        if type(r) == "number" then return r end
    end
    return 0
end

local function resolve_val_percent_base(val, context, percent_base)
    if type(val) == "number" then return val end
    if val == nil then return 0 end
    local old = context.percent_base
    context.percent_base = percent_base
    local r = ValueVM.resolve(val, context)
    context.percent_base = old
    if type(r) == "number" then return r end
    return 0
end

--- Build a ValueVM context from layout parameters.
local function make_context(engine, parent_w, parent_h, font_size)
    return {
        parent_width  = parent_w,
        parent_height = parent_h,
        font_size     = font_size or 16,
        viewport_w    = engine.viewport_w,
        viewport_h    = engine.viewport_h,
        root_font_size = engine.root_font_size,
    }
end

--- Check if a display value is a table row container.
local function is_row_group(display)
    return display == "table-row-group"
        or display == "table-header-group"
        or display == "table-footer-group"
end

------------------------------------------------------------
-- Normalize: collect rows and cells from the DOM tree
------------------------------------------------------------

--- Collect rows from the table element's children.
--- Returns array of rows, each row = { nid = row_node_id, cells = {cell_nid, ...}, group_nid = ... }
--- Also returns array of row-group nodes (thead/tbody/tfoot) with their row ranges.
local function collect_rows(ns, nid)
    local rows = {}
    local groups = {} -- {nid, first_row, last_row}
    local implicit_row_cells = {}

    local function flush_implicit()
        if #implicit_row_cells > 0 then
            rows[#rows + 1] = { nid = nil, cells = implicit_row_cells }
            implicit_row_cells = {}
        end
    end

    local function add_rows_from(parent_nid, group_nid)
        local cid = ns.first_child[parent_nid]
        if not cid then cid = 0 end
        while cid ~= 0 do
            local comp = ns.computed[cid]
            local d = comp and comp.display or "block"
            if d == "table-row" then
                flush_implicit()
                local cells = {}
                local cell_id = ns.first_child[cid]
                if not cell_id then cell_id = 0 end
                while cell_id ~= 0 do
                    local cc = ns.computed[cell_id]
                    local cd = cc and cc.display or "block"
                    if cd ~= "none" then
                        cells[#cells + 1] = cell_id
                    end
                    cell_id = ns.next_sibling[cell_id] or 0
                end
                rows[#rows + 1] = { nid = cid, cells = cells, group_nid = group_nid }
            elseif is_row_group(d) then
                flush_implicit()
                local first_row = #rows + 1
                add_rows_from(cid, cid)
                local last_row = #rows
                if last_row >= first_row then
                    groups[#groups + 1] = { nid = cid, first_row = first_row, last_row = last_row }
                end
            elseif d == "table-cell" then
                implicit_row_cells[#implicit_row_cells + 1] = cid
            elseif d == "table-caption" or d == "none" then
                -- skip captions and hidden
            else
                -- Treat non-table children as implicit cells
                implicit_row_cells[#implicit_row_cells + 1] = cid
            end
            cid = ns.next_sibling[cid] or 0
        end
    end

    add_rows_from(nid, nil)
    flush_implicit()
    return rows, groups
end

------------------------------------------------------------
-- Build grid: resolve colspan/rowspan into a 2D grid
------------------------------------------------------------

local function build_grid(ns, rows)
    -- grid[r][c] = cell_nid or false (occupied by span)
    local grid = {}
    local col_count = 0

    for r = 1, #rows do
        if not grid[r] then grid[r] = {} end
        local c = 1
        for ci = 1, #rows[r].cells do
            local cell_nid = rows[r].cells[ci]
            -- Skip occupied slots
            while grid[r][c] do c = c + 1 end

            local attrs = ns.attrs[cell_nid]
            local colspan = (attrs and tonumber(attrs.colspan)) or 1
            local rowspan = (attrs and tonumber(attrs.rowspan)) or 1
            if colspan < 1 then colspan = 1 end
            if rowspan < 1 then rowspan = 1 end

            -- Mark grid slots
            for dr = 0, rowspan - 1 do
                local gr = r + dr
                if not grid[gr] then grid[gr] = {} end
                for dc = 0, colspan - 1 do
                    grid[gr][c + dc] = (dr == 0 and dc == 0) and cell_nid or false
                end
            end

            -- Store span info on cell for later
            local pseudo = ns.pseudo[cell_nid]
            if pseudo then
                pseudo._table_col = c
                pseudo._table_row = r
                pseudo._table_colspan = colspan
                pseudo._table_rowspan = rowspan
            end

            local end_col = c + colspan - 1
            if end_col > col_count then col_count = end_col end
            c = c + colspan
        end
        if c - 1 > col_count then col_count = c - 1 end
    end

    return grid, col_count
end

------------------------------------------------------------
-- Measure cell widths
------------------------------------------------------------

local function transform_text(text, mode)
    mode = mode or "none"
    if mode == "uppercase" then
        return (text:gsub("([a-z])", function(c) return string.char(c:byte() - 32) end))
    elseif mode == "lowercase" then
        return (text:gsub("([A-Z])", function(c) return string.char(c:byte() + 32) end))
    elseif mode == "capitalize" then
        return (text:gsub("(%a)([%a]*)", function(f, r)
            local b = f:byte()
            if b >= 0x61 and b <= 0x7A then f = string.char(b - 32) end
            return f .. r
        end))
    end
    return text
end

local function text_width(engine, ns, nid)
    local computed = ns.computed[nid] or {}
    local text = transform_text(ns.text_content[nid] or "", computed.text_transform)
    local font_size = computed.font_size
    if type(font_size) ~= "number" then font_size = 16 end
    local font_family = computed.font_family
    local font_weight = computed.font_weight or 400
    local font_style = computed.font_style or "normal"
    local w = engine:measure_text_width(text, font_size, 0, font_family, font_weight, font_style)
    local white_space = computed.white_space or "normal"
    if white_space == "normal" or white_space == "nowrap" or white_space == "pre-line" then
        local wrapped_w = 0
        local words = {}
        for word in text:gmatch("%S+") do
            words[#words + 1] = word
        end
        if #words > 0 then
            local space_w = engine:measure_text_width(" ", font_size, 0, font_family, font_weight, font_style)
            for i = 1, #words do
                if i > 1 then wrapped_w = wrapped_w + space_w end
                wrapped_w = wrapped_w + engine:measure_text_width(words[i], font_size, 0, font_family, font_weight, font_style)
            end
            if wrapped_w > w then w = wrapped_w end
        end
    end

    local letter_spacing = computed.letter_spacing or 0
    if letter_spacing ~= 0 and #text > 1 then
        w = w + letter_spacing * (#text - 1)
    end
    local word_spacing = computed.word_spacing or 0
    if word_spacing ~= 0 then
        local sc = 0
        for _ in text:gmatch(" ") do sc = sc + 1 end
        w = w + word_spacing * sc
    end
    return w
end

function TableLayout.measure_preferred_cell_width(engine, ns, nid, avail_w)
    local computed = ns.computed[nid] or {}
    local font_size = computed.font_size
    if type(font_size) ~= "number" then font_size = 16 end
    local context = make_context(engine, avail_w, 1e6, font_size)
    local padding = resolve_val(computed.padding_left, context)
        + resolve_val(computed.padding_right, context)
    local bw = resolve_val(computed.border_width, context)
    local bl = resolve_val(computed.border_left_width, context)
    local br = resolve_val(computed.border_right_width, context)
    if computed.border_left_width == nil then bl = bw end
    if computed.border_right_width == nil then br = bw end

    if ns.node_type[nid] == ns.TEXT or
       (not ns:has_children(nid) and ns.text_content[nid] and ns.text_content[nid] ~= "") then
        return math.ceil(text_width(engine, ns, nid) + padding + bl + br)
    end

    local inline_sum = 0
    local block_max = 0
    local has_inline = false
    local child = ns.first_child[nid] or 0
    while child ~= 0 do
        local cc = ns.computed[child] or {}
        local d = cc.display or "inline"
        local cw = TableLayout.measure_preferred_cell_width(engine, ns, child, avail_w)
        if ns.node_type[child] == ns.TEXT or d == "inline" or d == "inline-block" then
            inline_sum = inline_sum + cw
            has_inline = true
        else
            if has_inline and inline_sum > block_max then block_max = inline_sum end
            inline_sum = 0
            has_inline = false
            if cw > block_max then block_max = cw end
        end
        child = ns.next_sibling[child] or 0
    end
    if inline_sum > block_max then block_max = inline_sum end

    -- Add one pixel of slack so preferred table columns do not re-wrap from
    -- fractional font advances after max-content measurement is rounded to the
    -- self-drawn pixel grid.
    return math.ceil(block_max + padding + bl + br + 1)
end

local function measure_cells(engine, ns, rows, grid, col_count, avail_w)
    -- col_min[c], col_max[c] for colspan=1 cells
    local col_min = {}
    local col_max = {}
    for c = 1, col_count do
        col_min[c] = 0
        col_max[c] = 0
    end

    for r = 1, #rows do
        for c = 1, col_count do
            local cell_nid = grid[r] and grid[r][c]
            if cell_nid and cell_nid ~= false then
                local pseudo = ns.pseudo[cell_nid]
                local colspan = (pseudo and pseudo._table_colspan) or 1

                -- Measure cell content at min and max width. Block measurement
                -- at a large width can still under-report text-heavy table
                -- cells when font metrics become ready after first layout, so
                -- supplement max-content with a direct unwrapped text pass.
                local min_w, min_h = engine:measure(cell_nid, 1, 1e6)
                local max_w, max_h = engine:measure(cell_nid, avail_w, 1e6)
                local preferred_w = TableLayout.measure_preferred_cell_width(engine, ns, cell_nid, avail_w)
                if preferred_w > max_w then max_w = preferred_w end

                if colspan == 1 then
                    if min_w > col_min[c] then col_min[c] = min_w end
                    if max_w > col_max[c] then col_max[c] = max_w end
                else
                    -- Distribute spanned width evenly across columns
                    local existing_min = 0
                    local existing_max = 0
                    for sc = c, c + colspan - 1 do
                        existing_min = existing_min + col_min[sc]
                        existing_max = existing_max + col_max[sc]
                    end
                    if min_w > existing_min then
                        local extra = (min_w - existing_min) / colspan
                        for sc = c, c + colspan - 1 do
                            col_min[sc] = col_min[sc] + extra
                        end
                    end
                    if max_w > existing_max then
                        local extra = (max_w - existing_max) / colspan
                        for sc = c, c + colspan - 1 do
                            col_max[sc] = col_max[sc] + extra
                        end
                    end
                end
            end
        end
    end

    return col_min, col_max
end

------------------------------------------------------------
-- table-layout: fixed -" column widths come from the first row's cells,
-- not from a content-measurement pass.  Cells without an explicit width
-- share the remaining space equally.  This is intentionally cheap (one
-- row instead of every row -- every cell) and predictable.
------------------------------------------------------------

local function compute_fixed_widths(ns, grid, col_count, content_w, spacing, context)
    local col_w = {}
    local total_spacing = spacing * (col_count + 1)
    local usable = content_w - total_spacing
    if usable < 0 then usable = 0 end

    local first_row = grid[1]
    if not first_row then
        local per = (col_count > 0) and (usable / col_count) or 0
        for c = 1, col_count do col_w[c] = per end
        return col_w, total_spacing
    end

    local explicit_sum = 0
    local auto_count = 0
    for c = 1, col_count do
        local cell_nid = first_row[c]
        local raw_w = nil
        if cell_nid and cell_nid ~= false then
            local cc = ns.computed[cell_nid]
            raw_w = cc and cc.width
        end
        if raw_w and raw_w ~= "auto" then
            local w = resolve_val(raw_w, context)
            if w > 0 then
                col_w[c] = w
                explicit_sum = explicit_sum + w
            else
                col_w[c] = false  -- auto
                auto_count = auto_count + 1
            end
        else
            col_w[c] = false
            auto_count = auto_count + 1
        end
    end

    local remaining = usable - explicit_sum
    if remaining < 0 then remaining = 0 end
    local per_auto = (auto_count > 0) and (remaining / auto_count) or 0
    for c = 1, col_count do
        if col_w[c] == false then
            col_w[c] = per_auto
        end
    end

    return col_w, total_spacing
end

------------------------------------------------------------
-- Distribute column widths
------------------------------------------------------------

local function distribute_columns(col_min, col_max, col_count, avail_w, spacing, border_w, expand_to_available)
    local col_w = {}
    local total_spacing = spacing * (col_count + 1) + border_w * 2

    -- Sum preferred widths
    local sum_max = 0
    local sum_min = 0
    for c = 1, col_count do
        sum_max = sum_max + col_max[c]
        sum_min = sum_min + col_min[c]
    end

    local usable = avail_w - total_spacing
    if usable < 0 then usable = 0 end

    if sum_max <= usable then
        -- Auto-width tables shrink-wrap to preferred width. Explicit-width
        -- tables distribute remaining space across columns.
        local extra = expand_to_available and (usable - sum_max) or 0
        local per = (col_count > 0) and (extra / col_count) or 0
        for c = 1, col_count do
            col_w[c] = col_max[c] + per
        end
    elseif sum_min <= usable then
        -- Shrink proportionally between min and max
        local range = sum_max - sum_min
        if range < 0.01 then
            for c = 1, col_count do col_w[c] = col_min[c] end
        else
            local factor = (usable - sum_min) / range
            for c = 1, col_count do
                col_w[c] = col_min[c] + (col_max[c] - col_min[c]) * factor
            end
        end
    else
        -- Even min doesn't fit -" use min widths
        for c = 1, col_count do
            col_w[c] = col_min[c]
        end
    end

    return col_w, total_spacing
end

------------------------------------------------------------
-- Main layout function
------------------------------------------------------------

function TableLayout.layout(engine, nid, avail_x, avail_y, avail_w, avail_h)
    local ns = engine.ns
    local computed = ns.computed[nid]
    local lay = ns.layout[nid]
    if not computed or not lay then return end

    local font_size = computed.font_size
    if type(font_size) ~= "number" then font_size = 16 end
    local context = make_context(engine, avail_w, avail_h, font_size)

    -- Box model
    local pt = resolve_val(computed.padding_top, context)
    local pr = resolve_val(computed.padding_right, context)
    local pb = resolve_val(computed.padding_bottom, context)
    local pl = resolve_val(computed.padding_left, context)
    local bw = resolve_val(computed.border_width, context)
    local box_sizing = computed.box_sizing or "content-box"

    -- Resolve width/height: "auto" means no explicit value (like Block.layout)
    local raw_w = computed.width
    local explicit_w = nil
    if raw_w and raw_w ~= "auto" and raw_w ~= "none" then
        local w = resolve_val(raw_w, context)
        if w > 0 then explicit_w = w end
    end
    local raw_h = computed.height
    local explicit_h = nil
    if raw_h and raw_h ~= "auto" and raw_h ~= "none" then
        local h = resolve_val_percent_base(raw_h, context, avail_h)
        if h > 0 then explicit_h = h end
    end

    -- Border spacing
    local border_spacing = resolve_val(computed.border_spacing, context)
    local collapse = (computed.border_collapse == "collapse")
    local spacing = collapse and 0 or border_spacing

    -- Resolve outer width
    local outer_w
    if explicit_w then
        if box_sizing == "border-box" then
            outer_w = explicit_w
        else
            outer_w = explicit_w + pl + pr + bw * 2
        end
    else
        outer_w = avail_w
    end

    local content_w = outer_w - pl - pr - bw * 2

    -- Collect and build grid
    local rows, groups = collect_rows(ns, nid)
    local grid, col_count = build_grid(ns, rows)

    if col_count == 0 then
        -- Empty table
        local empty_h = pt + pb + bw * 2
        if explicit_h then
            empty_h = (box_sizing == "border-box") and explicit_h or (explicit_h + pt + pb + bw * 2)
        end
        lay.x = avail_x
        lay.y = avail_y
        lay.w = outer_w
        lay.h = empty_h
        lay.content_x = avail_x + pl + bw
        lay.content_y = avail_y + pt + bw
        lay.content_w = content_w
        lay.content_h = 0
        lay.pad_x = avail_x + bw
        lay.pad_y = avail_y + bw
        lay.pad_w = outer_w - bw * 2
        lay.pad_h = pt + pb
        lay.scroll_w = content_w
        lay.scroll_h = 0
        ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
        ns:mark_dirty(nid, ns.PAINT_DIRTY)
        return
    end

    -- Column width assignment.  `table-layout: fixed` uses the first row's
    -- explicit cell widths and skips the (expensive) content-measurement
    -- pass entirely; `auto` (the default) measures min/max per cell.
    local col_w, total_spacing_w
    if computed.table_layout == "fixed" then
        col_w, total_spacing_w = compute_fixed_widths(ns, grid, col_count, content_w, spacing, context)
    else
        local col_min, col_max = measure_cells(engine, ns, rows, grid, col_count, content_w)
        col_w, total_spacing_w = distribute_columns(col_min, col_max, col_count, content_w, spacing, 0, explicit_w ~= nil)
    end

    -- Compute column X positions
    local col_x = {}
    local cx = avail_x + bw + pl + spacing
    for c = 1, col_count do
        col_x[c] = cx
        cx = cx + col_w[c] + spacing
    end

    -- Helper: compute cell width from spanned columns
    local function cell_width(c, colspan)
        local w = 0
        for sc = c, c + colspan - 1 do
            w = w + (col_w[sc] or 0)
        end
        if colspan > 1 then
            w = w + spacing * (colspan - 1)
        end
        return w
    end

    -- First pass: layout cells at temporary positions to measure heights
    local row_h = {}
    local temp_y = avail_y + bw + pt + spacing

    for r = 1, #rows do
        row_h[r] = 0
        for c = 1, col_count do
            local cell_nid = grid[r] and grid[r][c]
            if cell_nid and cell_nid ~= false then
                local pseudo = ns.pseudo[cell_nid]
                local colspan = (pseudo and pseudo._table_colspan) or 1
                local rowspan = (pseudo and pseudo._table_rowspan) or 1
                local cw = cell_width(c, colspan)

                -- Layout at temporary Y to measure height
                engine:_layout_node(cell_nid, col_x[c], temp_y, cw, avail_h)

                if rowspan == 1 then
                    local cell_lay = ns.layout[cell_nid]
                    if cell_lay and cell_lay.h > row_h[r] then
                        row_h[r] = cell_lay.h
                    end
                end
            end
        end
        if row_h[r] < 1 then row_h[r] = 1 end
        temp_y = temp_y + row_h[r] + spacing
    end

    -- Distribute rowspan cell heights back to spanned rows
    for r = 1, #rows do
        for c = 1, col_count do
            local cell_nid = grid[r] and grid[r][c]
            if cell_nid and cell_nid ~= false then
                local pseudo = ns.pseudo[cell_nid]
                local rowspan = (pseudo and pseudo._table_rowspan) or 1
                if rowspan > 1 then
                    local cell_lay = ns.layout[cell_nid]
                    if cell_lay then
                        local needed = cell_lay.h
                        local existing = 0
                        for sr = r, r + rowspan - 1 do
                            existing = existing + (row_h[sr] or 0)
                        end
                        existing = existing + spacing * (rowspan - 1)
                        if needed > existing then
                            -- Distribute extra height evenly across spanned rows
                            local extra = (needed - existing) / rowspan
                            for sr = r, r + rowspan - 1 do
                                row_h[sr] = (row_h[sr] or 0) + extra
                            end
                        end
                    end
                end
            end
        end
    end

    -- Compute row Y positions
    local row_y = {}
    local cur_y = avail_y + bw + pt + spacing
    for r = 1, #rows do
        row_y[r] = cur_y

        -- Set row node layout
        local row_nid = rows[r].nid
        if row_nid then
            local row_lay = ns.layout[row_nid]
            if row_lay then
                row_lay.x = avail_x + bw + pl
                row_lay.y = cur_y
                row_lay.w = outer_w - bw * 2 - pl - pr
                row_lay.h = row_h[r]
                row_lay.content_x = row_lay.x
                row_lay.content_y = row_lay.y
                row_lay.content_w = row_lay.w
                row_lay.content_h = row_h[r]
            end
        end

        cur_y = cur_y + row_h[r] + spacing
    end

    -- Set layout for row-group nodes (thead/tbody/tfoot)
    for gi = 1, #groups do
        local g = groups[gi]
        local g_lay = ns.layout[g.nid]
        if g_lay then
            local gy = row_y[g.first_row] or (avail_y + bw + pt)
            local g_last_y = (row_y[g.last_row] or gy) + (row_h[g.last_row] or 0)
            g_lay.x = avail_x + bw + pl
            g_lay.y = gy
            g_lay.w = outer_w - bw * 2 - pl - pr
            g_lay.h = g_last_y - gy
            g_lay.content_x = g_lay.x
            g_lay.content_y = g_lay.y
            g_lay.content_w = g_lay.w
            g_lay.content_h = g_lay.h
            g_lay.pad_x = g_lay.x
            g_lay.pad_y = g_lay.y
            g_lay.pad_w = g_lay.w
            g_lay.pad_h = g_lay.h
        end
    end

    -- Second pass: re-layout cells at correct Y positions, apply vertical-align
    -- Helper to shift a subtree by dy (node + all descendants)
    local function shift_subtree(shift_nid, dy)
        local sl = ns.layout[shift_nid]
        if sl then
            sl.y = sl.y + dy
            sl.content_y = sl.content_y + dy
        end
        local child = ns.first_child[shift_nid]
        if not child then child = 0 end
        while child ~= 0 do
            shift_subtree(child, dy)
            child = ns.next_sibling[child] or 0
        end
    end

    for r = 1, #rows do
        for c = 1, col_count do
            local cell_nid = grid[r] and grid[r][c]
            if cell_nid and cell_nid ~= false then
                local pseudo = ns.pseudo[cell_nid]
                local colspan = (pseudo and pseudo._table_colspan) or 1
                local rowspan = (pseudo and pseudo._table_rowspan) or 1
                local cw = cell_width(c, colspan)

                -- Re-layout cell at correct row Y
                engine:_layout_node(cell_nid, col_x[c], row_y[r], cw, avail_h)

                local cell_lay = ns.layout[cell_nid]
                if cell_lay then
                    -- Compute total height for spanned rows
                    local total_h = 0
                    for sr = r, r + rowspan - 1 do
                        total_h = total_h + (row_h[sr] or 0)
                    end
                    if rowspan > 1 then
                        total_h = total_h + spacing * (rowspan - 1)
                    end

                    -- Vertical alignment: shift only children, keep cell box at row top
                    local cell_comp = ns.computed[cell_nid]
                    local valign = cell_comp and cell_comp.vertical_align or "top"
                    local content_h = cell_lay.h
                    local offset_y = 0

                    if valign == "middle" then
                        offset_y = (total_h - content_h) * 0.5
                    elseif valign == "bottom" then
                        offset_y = total_h - content_h
                    end

                    -- Shift only children (not the cell itself) for vertical alignment
                    if offset_y > 0 then
                        local child = ns.first_child[cell_nid]
                        if not child then child = 0 end
                        while child ~= 0 do
                            shift_subtree(child, offset_y)
                            child = ns.next_sibling[child] or 0
                        end
                        -- Also shift cell's content_y for text rendering
                        cell_lay.content_y = cell_lay.content_y + offset_y
                    end

                    -- Stretch cell box to full row height (box stays at row top)
                    cell_lay.h = total_h
                end
            end
        end
    end

    -- Final table dimensions
    local total_h = cur_y - avail_y - bw - pt
    if explicit_h then
        local target_h = explicit_h
        if box_sizing == "border-box" then
            target_h = explicit_h - pt - pb - bw * 2
        end
        if total_h < target_h then total_h = target_h end
    end

    local actual_w = cx - avail_x + bw + pr
    if explicit_w then actual_w = outer_w end

    lay.x = avail_x
    lay.y = avail_y
    lay.w = actual_w
    lay.h = total_h + pt + pb + bw * 2
    lay.content_x = avail_x + pl + bw
    lay.content_y = avail_y + pt + bw
    lay.content_w = actual_w - pl - pr - bw * 2
    lay.content_h = total_h
    lay.pad_x = avail_x + bw
    lay.pad_y = avail_y + bw
    lay.pad_w = actual_w - bw * 2
    lay.pad_h = total_h + pt + pb
    lay.scroll_w = actual_w - pl - pr - bw * 2
    lay.scroll_h = total_h

    ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
    ns:mark_dirty(nid, ns.PAINT_DIRTY)
end

return TableLayout



