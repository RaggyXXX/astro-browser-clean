------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / grid.lua
-- CSS Grid layout algorithm.
--
-- Supports:
--   grid-template-columns / grid-template-rows
--   grid-auto-rows / grid-auto-columns
--   grid-column / grid-row (placement)
--   gap / row_gap / column_gap
--   justify-items / align-items
--   Track types: px, %, fr, auto, repeat()
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ValueVM = require("core/style/value_vm")

local Grid = {}

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

local function with_grid_stretch_size(comp, force_w, force_h, used_w, used_h, fn)
    local ow, oh = comp.width, comp.height
    local obs = comp.box_sizing
    if force_w then comp.width = used_w end
    if force_h then comp.height = used_h end
    if force_w or force_h then comp.box_sizing = "border-box" end
    fn()
    comp.width = ow
    comp.height = oh
    comp.box_sizing = obs
end

------------------------------------------------------------
-- Track parser
------------------------------------------------------------
local clone_track

--- Parse a track definition string like "1fr 200px 2fr" or
--- "repeat(3, 1fr)" or "100px 1fr auto" into an array of
--- track descriptors.
---@param str string|number|table|nil
---@return table  array of {type="fr"|"px"|"pct"|"auto"|"minmax"|"fit_content", value/min/max}

--- Parse a single track-size value: "1fr", "200px", "50%", "auto",
--- "min-content", "max-content".  Returns nil on unknown input.
local function parse_single_track(tok)
    if not tok or tok == "" then return nil end
    if tok == "auto" then return { type = "auto", value = 0 } end
    if tok == "min-content" then return { type = "min_content", value = 0 } end
    if tok == "max-content" then return { type = "max_content", value = 0 } end
    local fr = tok:match("^([%d%.]+)fr$")
    if fr then return { type = "fr", value = tonumber(fr) or 1 } end
    local px = tok:match("^([%d%.%-]+)px$")
    if px then return { type = "px", value = tonumber(px) or 0 } end
    local pct = tok:match("^([%d%.]+)%%$")
    if pct then return { type = "pct", value = tonumber(pct) or 0 } end
    local n = tonumber(tok)
    if n then return { type = "px", value = n } end
    return nil
end

--- Split a track list into top-level tokens, respecting balanced
--- parentheses so `minmax(0, 1fr)` stays one token.
local function split_tokens(str)
    local out = {}
    local depth = 0
    local buf = {}
    for i = 1, #str do
        local c = str:sub(i, i)
        if c == "(" then
            depth = depth + 1
            buf[#buf + 1] = c
        elseif c == ")" then
            depth = depth - 1
            buf[#buf + 1] = c
        elseif c:match("%s") and depth == 0 then
            if #buf > 0 then
                out[#out + 1] = table.concat(buf)
                buf = {}
            end
        else
            buf[#buf + 1] = c
        end
    end
    if #buf > 0 then out[#out + 1] = table.concat(buf) end
    return out
end

--- Split a comma-separated function argument list at top-level
--- (respects nested parens).
local function split_args(str)
    local out = {}
    local depth = 0
    local buf = {}
    for i = 1, #str do
        local c = str:sub(i, i)
        if c == "(" then depth = depth + 1; buf[#buf + 1] = c
        elseif c == ")" then depth = depth - 1; buf[#buf + 1] = c
        elseif c == "," and depth == 0 then
            out[#out + 1] = table.concat(buf):match("^%s*(.-)%s*$")
            buf = {}
        else buf[#buf + 1] = c end
    end
    if #buf > 0 then out[#out + 1] = table.concat(buf):match("^%s*(.-)%s*$") end
    return out
end

local function parse_tracks(str)
    if not str or str == "" then return {} end
    if type(str) == "number" then return { { type = "px", value = str } } end
    if type(str) == "table" then return str end  -- already parsed

    local tracks = {}
    local tokens = split_tokens(str)

    for i = 1, #tokens do
        local tok = tokens[i]

        -- repeat(n, body) - expand fixed repeats immediately. Auto-repeat
        -- needs the used grid size, so keep it as a descriptor for later.
        local rn, rbody = tok:match("^repeat%(%s*([%w%-]+)%s*,%s*(.-)%)$")
        if rn and rbody then
            if rn == "auto-fill" or rn == "auto-fit" then
                tracks[#tracks + 1] = { type = "auto_repeat", mode = rn, body = parse_tracks(rbody) }
            else
                local count = tonumber(rn) or 1
                local inner = parse_tracks(rbody)
                for _ = 1, count do
                    for j = 1, #inner do tracks[#tracks + 1] = inner[j] end
                end
            end
        -- minmax(min, max)
        elseif tok:find("^minmax%(") then
            local args = tok:match("^minmax%((.+)%)$")
            if args then
                local parts = split_args(args)
                if #parts == 2 then
                    local mn = parse_single_track(parts[1]) or { type = "auto", value = 0 }
                    local mx = parse_single_track(parts[2]) or { type = "auto", value = 0 }
                    tracks[#tracks + 1] = { type = "minmax", min = mn, max = mx }
                end
            end
        -- fit-content(size)
        elseif tok:find("^fit%-content%(") then
            local arg = tok:match("^fit%-content%((.+)%)$")
            if arg then
                local v = parse_single_track(arg) or { type = "auto", value = 0 }
                tracks[#tracks + 1] = { type = "fit_content", value = v }
            end
        else
            local single = parse_single_track(tok)
            if single then tracks[#tracks + 1] = single end
        end
    end

    return tracks
end

local function min_track_width(track, available, context)
    if not track then return 0 end
    if track.type == "px" then return track.value or 0 end
    if track.type == "pct" then return (available or 0) * (track.value or 0) / 100 end
    if track.type == "minmax" then
        return min_track_width(track.min, available, context)
    end
    if track.type == "fit_content" then
        return min_track_width(track.value, available, context)
    end
    return 0
end

local function expand_auto_repeat_tracks(tracks, available, gap, context, item_count)
    local out = {}
    local has_auto = false
    for i = 1, #tracks do
        local t = tracks[i]
        if type(t) == "table" and t.type == "auto_repeat" then
            has_auto = true
            local body = t.body or {}
            local body_min = 0
            for j = 1, #body do
                body_min = body_min + min_track_width(body[j], available, context)
            end
            if #body > 1 then body_min = body_min + (#body - 1) * (gap or 0) end
            if body_min <= 0 then body_min = available > 0 and available or 1 end
            local count = math.floor(((available or 0) + (gap or 0)) / (body_min + (gap or 0)))
            if count < 1 then count = 1 end
            if t.mode == "auto-fit" and item_count and item_count > 0 and item_count < count then
                count = item_count
            end
            for _ = 1, count do
                for j = 1, #body do out[#out + 1] = clone_track(body[j]) end
            end
        else
            out[#out + 1] = t
        end
    end
    return out, has_auto
end

function clone_track(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            out[k] = clone_track(v)
        else
            out[k] = v
        end
    end
    return out
end

local function resolve_track_limit(track, available, context)
    if type(track) ~= "table" then return nil end
    if track.type == "px" then return track.value or 0 end
    if track.type == "pct" then return (available or 0) * (track.value or 0) / 100 end
    if track.type == "minmax" then
        local mn = resolve_track_limit(track.min, available, context) or 0
        local mx = resolve_track_limit(track.max, available, context)
        if mx == nil then return mn end
        if mx < mn then return mn end
        return mx
    end
    if track.type == "fit_content" then
        return resolve_track_limit(track.value, available, context)
    end
    return nil
end

local function track_floor(track, available, context)
    if type(track) ~= "table" then return 0 end
    local floor_track = track.min_floor or track.min
    local n = resolve_track_limit(floor_track, available, context)
    if n and n > 0 then return n end
    return 0
end

------------------------------------------------------------
-- Placement parser
------------------------------------------------------------

--- Parse a grid-column or grid-row value.  Supports:
---   "1"               → line 1, span 1
---   "1 / 3"           → line 1 to line 3
---   "1 / -1"          → line 1 to last (resolved later when tracks known)
---   "span 3"          → auto-placed with 3-track span
---   "1 / span 2"      → start at 1, span 2
---   "auto"            → unresolved
---@param val any
---@return number|nil  start line (negative = from end, or nil if "span"/auto)
---@return number|nil  end line   (may be nil if span-only, or negative)
---@return number|nil  span       (explicit span count)
local function parse_placement(val)
    if not val or val == "auto" then return nil, nil, nil end

    if type(val) == "number" then
        return val, val + 1, nil
    end

    if type(val) == "string" then
        val = val:match("^%s*(.-)%s*$")

        -- Pure span form: "span N"
        local span_only = val:match("^span%s+(%d+)$")
        if span_only then
            return nil, nil, tonumber(span_only)
        end

        -- "a / b" form (b may be numeric, "-N", or "span N")
        local s_str, e_str = val:match("^(.-)%s*/%s*(.-)$")
        if s_str then
            local s_num = tonumber(s_str)
            local e_num = tonumber(e_str)
            local e_span = e_str:match("^span%s+(%d+)$")
            if s_num and e_span then
                return s_num, nil, tonumber(e_span)
            elseif s_num and e_num then
                return s_num, e_num, nil
            end
        end

        -- Single number (positive or negative)
        local n = tonumber(val)
        if n then return n, (n > 0) and (n + 1) or nil, nil end
    end

    return nil, nil, nil
end

--- Parse explicit start/end properties
--- Returns start-line, end-line, and optional span-count.  Callers may
--- resolve negative lines / spans against the actual track count.
---@param start_val any
---@param end_val any
---@param shorthand any  combined "grid-column" or "grid-row" value
---@return number|nil, number|nil, number|nil
local function resolve_placement(start_val, end_val, shorthand)
    local s, e, span

    if shorthand and shorthand ~= "auto" then
        s, e, span = parse_placement(shorthand)
    end

    if start_val and start_val ~= "auto" then
        local ss, _, sp = parse_placement(start_val)
        s = ss or s
        span = sp or span
    end
    if end_val and end_val ~= "auto" then
        local _, ee, sp = parse_placement(end_val)
        e = ee or e
        span = sp or span
    end

    -- If we have start + span but no end: end = start + span
    if s and span and not e then e = s + span end
    -- If we have span but no start: caller will auto-place
    -- If we have start but no end: span 1
    if s and not e and not span then e = s + 1 end

    return s, e, span
end

------------------------------------------------------------
-- Grid layout
------------------------------------------------------------

--- Perform CSS Grid layout for a container node.
---@param engine  table   LayoutEngine instance
---@param nid     number  container node id
---@param avail_x number
---@param avail_y number
---@param avail_w number
---@param avail_h number
function Grid.layout(engine, nid, avail_x, avail_y, avail_w, avail_h)
    local ns = engine.ns
    local computed = ns.computed[nid]
    if not computed then return end
    local display = computed.display or "grid"

    -- Get parent's resolved font_size for em-unit resolution
    local parent_nid = ns.parent[nid]
    local parent_fs = 16
    if parent_nid and parent_nid ~= 0 then
        local parent_cm = ns.computed[parent_nid]
        if parent_cm and type(parent_cm.font_size) == "number" then
            parent_fs = parent_cm.font_size
        end
    end

    local context = {
        parent_width  = avail_w,
        parent_height = avail_h,
        font_size     = resolve_font_size(computed.font_size, engine, avail_w, avail_h, parent_fs),
        viewport_w    = engine.viewport_w or 0,
        viewport_h    = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
    }

    -- Write resolved font_size back so painters can use it as a plain number
    computed.font_size = context.font_size

    -- Resolve container box model
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

    if display == "inline-grid" and type(width_val) ~= "number" then
        local col_tracks_intrinsic = parse_tracks(computed.grid_template_columns)
        local col_gap_intrinsic = resolve_num(computed.column_gap or computed.gap, context)
        local explicit_w = 0
        local all_definite = (#col_tracks_intrinsic > 0)
        for i = 1, #col_tracks_intrinsic do
            local tr = col_tracks_intrinsic[i]
            if tr.type == "px" then
                explicit_w = explicit_w + tr.value
            else
                all_definite = false
                break
            end
        end
        if all_definite then
            explicit_w = explicit_w + math.max(0, #col_tracks_intrinsic - 1) * col_gap_intrinsic
            outer_w = explicit_w + padding_l + padding_r + border_l + border_r
            if outer_w < 0 then outer_w = 0 end
        end
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

    -- Container height
    local height_val = resolve_dim_percent_base(computed.height, context, avail_h)
    local outer_h_definite = nil
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

    -- Parse track definitions
    local col_tracks = parse_tracks(computed.grid_template_columns)
    local row_tracks = parse_tracks(computed.grid_template_rows)
    local auto_rows_def = parse_tracks(computed.grid_auto_rows or "auto")
    local auto_cols_def = parse_tracks(computed.grid_auto_columns or "auto")

    -- Named-area resolution map: builds { [name] = {col_start, col_end, row_start, row_end} }
    -- from a grid-template-areas value like {rows = { {"header","header"}, {"nav","main"} }}
    local area_map = nil
    local gta = computed.grid_template_areas
    if type(gta) == "table" and gta.type == "grid_template_areas" and gta.rows then
        area_map = {}
        local rows = gta.rows
        for r = 1, #rows do
            local row = rows[r]
            for c = 1, #row do
                local name = row[c]
                if name and name ~= "." and name ~= "" then
                    local a = area_map[name]
                    if not a then
                        area_map[name] = { col_start = c, col_end = c + 1,
                                           row_start = r, row_end = r + 1 }
                    else
                        -- Extend existing span
                        if c < a.col_start then a.col_start = c end
                        if c + 1 > a.col_end then a.col_end = c + 1 end
                        if r < a.row_start then a.row_start = r end
                        if r + 1 > a.row_end then a.row_end = r + 1 end
                    end
                end
            end
        end
        -- Ensure at least one row track per area row
        if #rows > #row_tracks then
            for _ = #row_tracks + 1, #rows do
                row_tracks[#row_tracks + 1] = { type = "auto", value = 0 }
            end
        end
    end

    -- Gaps
    local row_gap = resolve_num(computed.row_gap or computed.gap, context)
    local col_gap = resolve_num(computed.column_gap or computed.gap, context)

    local auto_flow = tostring(computed.grid_auto_flow or "row")
    local flow_column = auto_flow:find("column", 1, true) ~= nil
    local flow_dense = auto_flow:find("dense", 1, true) ~= nil

    -- Collect grid items
    local items = {}
    local abs_children = {}
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        local child_comp = ns.computed[cid]
        local child_display = child_comp and child_comp.display or "block"
        local child_pos = child_comp and child_comp.position or "static"

        if child_display == "none" then
            local clay = ns.layout[cid]
            clay.x = 0; clay.y = 0; clay.w = 0; clay.h = 0
            clay.content_x = 0; clay.content_y = 0; clay.content_w = 0; clay.content_h = 0
            clay.pad_x = 0; clay.pad_y = 0; clay.pad_w = 0; clay.pad_h = 0
        elseif child_pos == "absolute" or child_pos == "fixed" then
            abs_children[#abs_children + 1] = cid
        else
            local col_s, col_e, col_span = resolve_placement(
                child_comp and child_comp.grid_column_start,
                child_comp and child_comp.grid_column_end,
                child_comp and child_comp.grid_column
            )
            local row_s, row_e, row_span = resolve_placement(
                child_comp and child_comp.grid_row_start,
                child_comp and child_comp.grid_row_end,
                child_comp and child_comp.grid_row
            )

            -- grid-area: may be { type="grid_area", name="foo" } → look up in parent's
            -- area_map; or { type="grid_area", row_start, col_start, ... } numeric form.
            local ga = child_comp and child_comp.grid_area
            if type(ga) == "table" and ga.type == "grid_area" then
                if ga.name and area_map and area_map[ga.name] then
                    local a = area_map[ga.name]
                    if not col_s then col_s = a.col_start end
                    if not col_e then col_e = a.col_end end
                    if not row_s then row_s = a.row_start end
                    if not row_e then row_e = a.row_end end
                else
                    if not row_s then row_s = ga.row_start end
                    if not col_s then col_s = ga.col_start end
                    if not row_e then row_e = ga.row_end end
                    if not col_e then col_e = ga.col_end end
                end
            end

            items[#items + 1] = {
                nid = cid,
                comp = child_comp or {},
                col_start = col_s,
                col_end = col_e,
                col_span = col_span,
                row_start = row_s,
                row_end = row_e,
                row_span = row_span,
            }
        end

        cid = ns.next_sibling[cid] or 0
    end

    col_tracks = expand_auto_repeat_tracks(col_tracks, content_w, col_gap, context, #items)
    row_tracks = expand_auto_repeat_tracks(row_tracks, content_h_definite or avail_h, row_gap, context, #items)

    -- Determine grid dimensions
    local num_cols = #col_tracks
    local num_rows = #row_tracks

    -- Resolve negative lines against the declared track count
    -- (e.g. grid-column: 1 / -1 → span all columns).  Negative line N
    -- counts from the last explicit line: -1 = num_cols+1, -2 = num_cols, …
    local function resolve_neg(line, total)
        if line and line < 0 then return total + line + 2 end
        return line
    end
    for i = 1, #items do
        local item = items[i]
        item.col_start = resolve_neg(item.col_start, num_cols)
        item.col_end   = resolve_neg(item.col_end,   num_cols)
        item.row_start = resolve_neg(item.row_start, num_rows)
        item.row_end   = resolve_neg(item.row_end,   num_rows)
        -- Apply span when we have start + span but no explicit end
        if item.col_start and item.col_span and not item.col_end then
            item.col_end = item.col_start + item.col_span
        end
        if item.row_start and item.row_span and not item.row_end then
            item.row_end = item.row_start + item.row_span
        end
    end

    -- Expand grid based on explicit placements
    for i = 1, #items do
        local item = items[i]
        if item.col_end and item.col_end - 1 > num_cols then
            num_cols = item.col_end - 1
        end
        if item.row_end and item.row_end - 1 > num_rows then
            num_rows = item.row_end - 1
        end
    end

    -- Default: at least 1 column if items exist
    if num_cols == 0 and #items > 0 then num_cols = 1 end

    -- Auto-placement for items without explicit placement
    local grid_cells = {}  -- [row][col] = true (occupied)

    local function item_col_span(item)
        local span = item.col_span
        if (not span) and item.col_start and item.col_end then
            span = item.col_end - item.col_start
        end
        if not span or span < 1 then span = 1 end
        return span
    end

    local function item_row_span(item)
        local span = item.row_span
        if (not span) and item.row_start and item.row_end then
            span = item.row_end - item.row_start
        end
        if not span or span < 1 then span = 1 end
        return span
    end

    local function can_place(row, col, col_span, row_span, bound_rows)
        if col < 1 or row < 1 then return false end
        if (not flow_column) and col + col_span - 1 > num_cols then return false end
        if bound_rows and flow_column and num_rows > 0 and row + row_span - 1 > num_rows then return false end
        for r = row, row + row_span - 1 do
            if grid_cells[r] then
                for c = col, col + col_span - 1 do
                    if grid_cells[r][c] then return false end
                end
            end
        end
        return true
    end

    local function scan_for_place(start_row, start_col, col_span, row_span)
        local row = start_row or 1
        local col = start_col or 1
        while true do
            if can_place(row, col, col_span, row_span, flow_column) then
                return row, col
            end
            if flow_column then
                row = row + 1
                if num_rows > 0 and row + row_span - 1 > num_rows then
                    row = 1
                    col = col + 1
                end
            else
                col = col + 1
                if col + col_span - 1 > num_cols then
                    col = 1
                    row = row + 1
                end
            end
        end
    end

    local function mark_cells(row, col, col_span, row_span)
        for r = row, row + row_span - 1 do
            if not grid_cells[r] then grid_cells[r] = {} end
            for c = col, col + col_span - 1 do
                grid_cells[r][c] = true
            end
        end
        if col + col_span - 1 > num_cols then num_cols = col + col_span - 1 end
        if row + row_span - 1 > num_rows then num_rows = row + row_span - 1 end
    end

    for i = 1, #items do
        local item = items[i]
        local cs = item.col_start
        local rs = item.row_start
        if cs and item.col_span and not item.col_end then
            item.col_end = cs + item.col_span
        end
        if rs and item.row_span and not item.row_end then
            item.row_end = rs + item.row_span
        end
    end

    -- First, place explicitly positioned items
    for i = 1, #items do
        local item = items[i]
        if item.col_start and item.row_start and item.col_end and item.row_end then
            mark_cells(item.row_start, item.col_start, item_col_span(item), item_row_span(item))
        end
    end

    -- Auto-place remaining items
    local auto_row, auto_col = 1, 1
    for i = 1, #items do
        local item = items[i]
        if not item.col_start or not item.row_start then
            local cspan = item_col_span(item)
            local rspan = item_row_span(item)
            if (not flow_column) and num_cols < cspan then num_cols = cspan end
            if flow_column and num_rows < rspan then num_rows = rspan end
            if item.col_start and item.col_start + cspan - 1 > num_cols then
                num_cols = item.col_start + cspan - 1
            end
            if item.row_start and item.row_start + rspan - 1 > num_rows then
                num_rows = item.row_start + rspan - 1
            end

            if item.col_start and not item.row_start then
                local row = 1
                while not can_place(row, item.col_start, cspan, rspan) do
                    row = row + 1
                end
                item.row_start = row
                item.row_end = row + rspan
                item.col_end = item.col_start + cspan
                mark_cells(item.row_start, item.col_start, cspan, rspan)
            elseif item.row_start and not item.col_start then
                local col = 1
                while not can_place(item.row_start, col, cspan, rspan) do
                    col = col + 1
                    if col + cspan - 1 > num_cols then
                        num_cols = col + cspan - 1
                    end
                end
                item.col_start = col
                item.col_end = col + cspan
                item.row_end = item.row_start + rspan
                mark_cells(item.row_start, item.col_start, cspan, rspan)
            else
                local start_row = flow_dense and 1 or auto_row
                local start_col = flow_dense and 1 or auto_col
                local row, col = scan_for_place(start_row, start_col, cspan, rspan)
                auto_row = row
                auto_col = col
                item.col_start = auto_col
                item.col_end = auto_col + cspan
                item.row_start = auto_row
                item.row_end = auto_row + rspan
                mark_cells(item.row_start, item.col_start, cspan, rspan)

                if flow_column then
                    auto_row = auto_row + rspan
                    if num_rows > 0 and auto_row > num_rows then
                        auto_row = 1
                        auto_col = auto_col + cspan
                    end
                else
                    auto_col = auto_col + cspan
                    if auto_col > num_cols then
                        auto_col = 1
                        auto_row = auto_row + 1
                    end
                end
            end
        end
    end

    -- Extend track arrays with auto tracks if needed
    while #col_tracks < num_cols do
        local tmpl = auto_cols_def[1] or { type = "auto", value = 0 }
        col_tracks[#col_tracks + 1] = clone_track(tmpl)
    end
    while #row_tracks < num_rows do
        local tmpl = auto_rows_def[1] or { type = "auto", value = 0 }
        row_tracks[#row_tracks + 1] = clone_track(tmpl)
    end

    -- ============================================================
    -- Resolve column sizes
    -- ============================================================
    local col_sizes = {}
    local total_col_gaps = (num_cols > 1) and (num_cols - 1) * col_gap or 0
    local available_for_cols = content_w - total_col_gaps
    if available_for_cols < 0 then available_for_cols = 0 end

    local fixed_used = 0
    local fr_total = 0
    local auto_cols_list = {}

    -- Flatten minmax / fit-content tracks to their effective behavior:
    -- minmax(min, max) with max=fr → fr growing from min base
    -- minmax(min, max) with max=px/% → resolve to max
    -- fit-content(size) → treat as auto clamped by size (approximated as auto)
    for c = 1, num_cols do
        local t = col_tracks[c]
        if t and t.type == "minmax" then
            local mn, mx = t.min or {type="auto"}, t.max or {type="auto"}
            if mx.type == "fr" then
                col_tracks[c] = { type = "fr", value = mx.value or 1, min_floor = mn }
            elseif mx.type == "auto" or mx.type == "min_content" or mx.type == "max_content" then
                col_tracks[c] = clone_track(mx)
                col_tracks[c].min_floor = mn
            else
                local min_px = resolve_track_limit(mn, available_for_cols, context) or 0
                local max_px = resolve_track_limit(mx, available_for_cols, context) or 0
                if max_px < min_px then max_px = min_px end
                col_tracks[c] = { type = "px", value = max_px }
            end
        elseif t and t.type == "fit_content" then
            col_tracks[c] = { type = "auto", value = 0, fit_limit = t.value }
        end
    end

    for c = 1, num_cols do
        local track = col_tracks[c]
        if track.type == "px" then
            col_sizes[c] = track.value
            fixed_used = fixed_used + track.value
        elseif track.type == "pct" then
            col_sizes[c] = content_w * track.value / 100
            fixed_used = fixed_used + col_sizes[c]
        elseif track.type == "fr" then
            local floor_px = track_floor(track, available_for_cols, context)
            col_sizes[c] = floor_px
            fixed_used = fixed_used + floor_px
            fr_total = fr_total + track.value
        elseif track.type == "min_content" or track.type == "max_content" then
            local floor_px = track_floor(track, available_for_cols, context)
            col_sizes[c] = floor_px
            fixed_used = fixed_used + floor_px
            auto_cols_list[#auto_cols_list + 1] = c
        else -- auto
            local floor_px = track_floor(track, available_for_cols, context)
            col_sizes[c] = floor_px
            fixed_used = fixed_used + floor_px
            auto_cols_list[#auto_cols_list + 1] = c
        end
    end

    -- Measure auto columns (content-based).  CSS spec: the auto track's
    -- base size is the max-content contribution when unconstrained, but
    -- clamped against remaining grid width so fr tracks still have room.
    -- min_content variant uses a small fixed measurement width to encourage
    -- word-wrap; max_content uses the full available width.
    for _, c in ipairs(auto_cols_list) do
        local track = col_tracks[c]
        local is_min = track.type == "min_content"
        local measure_w
        if is_min then
            measure_w = 60  -- encourages narrowest wrap the text allows
        else
            measure_w = available_for_cols
        end
        local max_w = 0
        for i = 1, #items do
            local item = items[i]
            if item.col_start == c and item.col_end == c + 1 then
                local mw, _ = engine:measure(item.nid, measure_w, content_h_definite or avail_h)
                if mw > max_w then max_w = mw end
            end
        end
        -- Cap auto column at max half of the remaining pre-auto space when
        -- fr tracks exist -" otherwise a long-text auto column eats all the
        -- fr share and the main column collapses to zero.
        if fr_total > 0 then
            local pre_auto_remaining = available_for_cols - fixed_used
            if pre_auto_remaining < 0 then pre_auto_remaining = 0 end
            local cap = pre_auto_remaining * 0.4
            if cap > 0 and max_w > cap then max_w = cap end
        end
        local limit = resolve_track_limit(track.fit_limit, available_for_cols, context)
        if limit and max_w > limit then max_w = limit end
        if max_w < (col_sizes[c] or 0) then max_w = col_sizes[c] or 0 end
        fixed_used = fixed_used + max_w - (col_sizes[c] or 0)
        col_sizes[c] = max_w
    end

    -- Distribute spanning items across auto tracks (CSS Grid spec
    -- §11.5.1 "increase sizes to accommodate spanning items").
    --
    -- The non-spanning auto sizing above considers only items with
    -- col_span == 1 (line 943's filter), so a spanning text-heavy item
    -- over auto tracks gets ZERO contribution to track sizes and ends
    -- up wrapping into the narrow columns sized by short non-spanning
    -- cells (the grid-spanning-intrinsic case had Engine
    -- render a +200px-tall narrow column where Chrome kept it 2 lines).
    --
    -- Practical pass: measure spanning items at
    -- max-content (engine:measure with a very wide constraint),
    -- subtract the current sum of spanned tracks + intervening gaps,
    -- and distribute any deficit equally across the spanned auto
    -- tracks. Items spanning only non-auto tracks (px/%/fr) are
    -- skipped -" we deliberately don't redistribute fixed widths.
    -- This isn't the full CSS Grid track-sizing algorithm, but it
    -- targets the exact "long text in span-2 auto cell" class.
    for i = 1, #items do
        local item = items[i]
        if item.col_span and item.col_span > 1
           and item.col_start and item.col_end then
            local spanned_auto = {}
            for c = item.col_start, item.col_end - 1 do
                local t = col_tracks[c]
                if t and (t.type == "auto"
                          or t.type == "min_content"
                          or t.type == "max_content") then
                    spanned_auto[#spanned_auto + 1] = c
                end
            end
            if #spanned_auto > 0 then
                -- Preferred (max-content) outer width of the spanning item.
                -- engine:measure returns the laid-out outer/border-box size
                -- under the given width constraint; a very wide constraint
                -- approximates max-content for text-heavy items.
                local pref_w = engine:measure(item.nid, 99999,
                    content_h_definite or avail_h)
                local current_sum = 0
                for c = item.col_start, item.col_end - 1 do
                    current_sum = current_sum + (col_sizes[c] or 0)
                end
                current_sum = current_sum + (item.col_span - 1) * col_gap
                local deficit = pref_w - current_sum
                if deficit > 0 then
                    -- Cap deficit at the remaining container space.
                    -- Without this, a long unbreakable span-item measured
                    -- at 99999 expands its spanned tracks past the
                    -- container width -" engine grids ended up at 701px
                    -- in a 400px container. Chrome shrinks the deficit
                    -- so totals fit; the spanning item then wraps to
                    -- match. This is a conservative approximation of
                    -- CSS Grid §11.5 "limit growth to free space".
                    local remaining_in_container = available_for_cols - fixed_used
                    if remaining_in_container < 0 then remaining_in_container = 0 end
                    if deficit > remaining_in_container then
                        deficit = remaining_in_container
                    end
                    if deficit > 0 then
                        local share = deficit / #spanned_auto
                        for _, c in ipairs(spanned_auto) do
                            col_sizes[c] = (col_sizes[c] or 0) + share
                            fixed_used = fixed_used + share
                        end
                    end
                end
            end
        end
    end

    -- Distribute remaining space to fr tracks
    local remaining = available_for_cols - fixed_used
    if remaining < 0 then remaining = 0 end
    if fr_total > 0 then
        for c = 1, num_cols do
            if col_tracks[c].type == "fr" then
                col_sizes[c] = col_sizes[c] + remaining * (col_tracks[c].value / fr_total)
            end
        end
    end

    -- ============================================================
    -- Resolve row sizes
    -- ============================================================
    local row_sizes = {}
    local total_row_gaps = (num_rows > 1) and (num_rows - 1) * row_gap or 0
    local available_for_rows = (content_h_definite or 99999) - total_row_gaps
    if available_for_rows < 0 then available_for_rows = 0 end

    local row_fixed_used = 0
    local row_fr_total = 0
    local auto_rows_list = {}

    -- Flatten row minmax / fit-content -" same policy as columns.
    for r = 1, num_rows do
        local t = row_tracks[r]
        if t and t.type == "minmax" then
            local mn, mx = t.min or {type="auto"}, t.max or {type="auto"}
            if mx.type == "fr" then
                row_tracks[r] = { type = "fr", value = mx.value or 1, min_floor = mn }
            elseif mx.type == "auto" or mx.type == "min_content" or mx.type == "max_content" then
                row_tracks[r] = clone_track(mx)
                row_tracks[r].min_floor = mn
            else
                local min_px = resolve_track_limit(mn, available_for_rows, context) or 0
                local max_px = resolve_track_limit(mx, available_for_rows, context) or 0
                if max_px < min_px then max_px = min_px end
                row_tracks[r] = { type = "px", value = max_px }
            end
        elseif t and t.type == "fit_content" then
            row_tracks[r] = { type = "auto", value = 0, fit_limit = t.value }
        end
    end

    for r = 1, num_rows do
        local track = row_tracks[r]
        if track.type == "px" then
            row_sizes[r] = track.value
            row_fixed_used = row_fixed_used + track.value
        elseif track.type == "pct" then
            row_sizes[r] = (content_h_definite or avail_h) * track.value / 100
            row_fixed_used = row_fixed_used + row_sizes[r]
        elseif track.type == "fr" then
            local floor_px = track_floor(track, available_for_rows, context)
            row_sizes[r] = floor_px
            row_fixed_used = row_fixed_used + floor_px
            row_fr_total = row_fr_total + track.value
        elseif track.type == "min_content" or track.type == "max_content" then
            local floor_px = track_floor(track, available_for_rows, context)
            row_sizes[r] = floor_px
            row_fixed_used = row_fixed_used + floor_px
            auto_rows_list[#auto_rows_list + 1] = r
        else -- auto
            local floor_px = track_floor(track, available_for_rows, context)
            row_sizes[r] = floor_px
            row_fixed_used = row_fixed_used + floor_px
            auto_rows_list[#auto_rows_list + 1] = r
        end
    end

    -- Measure auto rows by laying out items at resolved column widths.
    -- We pass mode="available-width" so the measurement keeps item_w as the
    -- inline-size -" text wraps at the column width and we read the resulting
    -- block-size. Default intrinsic mode would shrink-wrap each item to its
    -- preferred width and return the unwrapped (taller) height, inflating row
    -- height by an extra line for spanning text items.
    local row_measure_opts = { mode = "available-width" }
    for _, r in ipairs(auto_rows_list) do
        local max_h = 0
        for i = 1, #items do
            local item = items[i]
            if item.row_start == r and item.row_end == r + 1 then
                -- Calculate item width from spanned columns
                local item_w = 0
                for c = item.col_start, item.col_end - 1 do
                    item_w = item_w + (col_sizes[c] or 0)
                    if c > item.col_start then item_w = item_w + col_gap end
                end
                local _, mh = engine:measure(item.nid, item_w, available_for_rows, row_measure_opts)
                if mh > max_h then max_h = mh end
            end
        end
        local track = row_tracks[r]
        local limit = resolve_track_limit(track.fit_limit, available_for_rows, context)
        if limit and max_h > limit then max_h = limit end
        if max_h < (row_sizes[r] or 0) then max_h = row_sizes[r] or 0 end
        row_fixed_used = row_fixed_used + max_h - (row_sizes[r] or 0)
        row_sizes[r] = max_h
    end

    -- Distribute remaining space to fr row tracks
    local row_remaining = available_for_rows - row_fixed_used
    if row_remaining < 0 then row_remaining = 0 end
    if row_fr_total > 0 then
        for r = 1, num_rows do
            if row_tracks[r].type == "fr" then
                row_sizes[r] = row_sizes[r] + row_remaining * (row_tracks[r].value / row_fr_total)
            end
        end
    end

    -- ============================================================
    -- Compute track positions
    -- ============================================================
    local function align_tracks(sizes, count, gap, available, mode)
        local total = 0
        for i = 1, count do total = total + (sizes[i] or 0) end
        if count > 1 then total = total + (count - 1) * gap end
        local free = available - total
        if free < 0 then free = 0 end

        mode = mode or "start"
        if mode == "normal" then mode = "start" end
        if mode == "flex-start" or mode == "left" or mode == "top" then mode = "start" end
        if mode == "flex-end" or mode == "right" or mode == "bottom" then mode = "end" end

        local offset = 0
        local out_gap = gap
        if mode == "end" then
            offset = free
        elseif mode == "center" then
            offset = free / 2
        elseif mode == "space-between" and count > 1 then
            out_gap = gap + free / (count - 1)
        elseif mode == "space-around" and count > 0 then
            local extra = free / count
            offset = extra / 2
            out_gap = gap + extra
        elseif mode == "space-evenly" and count > 0 then
            local extra = free / (count + 1)
            offset = extra
            out_gap = gap + extra
        end
        return offset, out_gap
    end

    local col_offset, effective_col_gap = align_tracks(
        col_sizes, num_cols, col_gap, content_w, computed.justify_content
    )
    local align_content_h = content_h_definite
    if not align_content_h then
        align_content_h = 0
        for r = 1, num_rows do align_content_h = align_content_h + (row_sizes[r] or 0) end
        if num_rows > 1 then align_content_h = align_content_h + (num_rows - 1) * row_gap end
    end
    local row_offset, effective_row_gap = align_tracks(
        row_sizes, num_rows, row_gap, align_content_h, computed.align_content
    )

    local col_positions = {}  -- left edge of each column
    local cursor = col_offset
    for c = 1, num_cols do
        col_positions[c] = cursor
        cursor = cursor + col_sizes[c] + effective_col_gap
    end

    local row_positions = {}  -- top edge of each row
    cursor = row_offset
    for r = 1, num_rows do
        row_positions[r] = cursor
        cursor = cursor + row_sizes[r] + effective_row_gap
    end

    -- Scroll offset
    local scroll = ns.scroll[nid]
    local scroll_x = (scroll and scroll.x) or 0
    local scroll_y = (scroll and scroll.y) or 0

    -- ============================================================
    -- Position and lay out items
    -- ============================================================
    local justify_items = computed.justify_items or "stretch"
    local align_items = computed.align_items or "stretch"

    local function normalize_self(value, fallback)
        local v = value
        if not v or v == "auto" or v == "normal" then v = fallback or "stretch" end
        if v == "flex-start" or v == "self-start" then v = "start" end
        if v == "flex-end" or v == "self-end" then v = "end" end
        if v == "left" then v = "start" end
        if v == "right" then v = "end" end
        return v
    end

    for i = 1, #items do
        local item = items[i]
        local cs, ce = item.col_start, item.col_end
        local rs, re = item.row_start, item.row_end

        -- Calculate cell position and size
        local cell_x = col_positions[cs] or 0
        local cell_y = row_positions[rs] or 0

        local cell_w = 0
        for c = cs, ce - 1 do
            cell_w = cell_w + (col_sizes[c] or 0)
            if c > cs then cell_w = cell_w + effective_col_gap end
        end

        local cell_h = 0
        for r = rs, re - 1 do
            cell_h = cell_h + (row_sizes[r] or 0)
            if r > rs then cell_h = cell_h + effective_row_gap end
        end

        -- Apply justify-items / align-items
        local item_x = content_x + cell_x - scroll_x
        local item_y = content_y + cell_y - scroll_y
        local item_w = cell_w
        local item_h = cell_h

        -- Check item's own size constraints
        local ic = item.comp
        local item_ctx = { parent_width = cell_w, parent_height = cell_h, font_size = context.font_size }
        local explicit_w = resolve_dim(ic.width, item_ctx)
        local explicit_h = resolve_dim(ic.height, item_ctx)
        local justify_self = normalize_self(ic.justify_self, justify_items)
        local align_self = normalize_self(ic.align_self, align_items)

        if type(explicit_w) == "number" then
            item_w = explicit_w
        elseif justify_self ~= "stretch" then
            local mw = engine:measure(item.nid, cell_w, cell_h)
            if type(mw) == "number" and mw > 0 and mw < cell_w then item_w = mw end
        end
        if justify_self == "center" then
            item_x = item_x + (cell_w - item_w) / 2
        elseif justify_self == "end" then
            item_x = item_x + cell_w - item_w
        end

        if type(explicit_h) == "number" then
            item_h = explicit_h
        elseif align_self ~= "stretch" then
            local _, mh = engine:measure(item.nid, item_w, cell_h)
            if type(mh) == "number" and mh > 0 and mh < cell_h then item_h = mh end
        end
        if align_self == "center" then
            item_y = item_y + (cell_h - item_h) / 2
        elseif align_self == "end" then
            item_y = item_y + cell_h - item_h
        end

        local force_w = (justify_self == "stretch" and type(explicit_w) ~= "number")
        local force_h = (align_self == "stretch" and type(explicit_h) ~= "number")
        with_grid_stretch_size(ic, force_w, force_h, item_w, item_h, function()
            engine:_layout_node(item.nid, item_x, item_y, item_w, item_h)
        end)
    end

    -- Layout absolute children
    for i = 1, #abs_children do
        engine:_layout_node(abs_children[i], content_x, content_y, content_w, content_h_definite or avail_h)
    end

    -- ============================================================
    -- Store container layout
    -- ============================================================
    local total_content_h = 0
    for r = 1, num_rows do
        total_content_h = total_content_h + row_sizes[r]
    end
    total_content_h = total_content_h + total_row_gaps
    local total_content_w = 0
    for c = 1, num_cols do
        total_content_w = total_content_w + (col_sizes[c] or 0)
    end
    if num_cols > 1 then
        total_content_w = total_content_w + (num_cols - 1) * effective_col_gap
    end

    local outer_h
    if outer_h_definite then
        outer_h = outer_h_definite
    else
        outer_h = total_content_h + padding_t + padding_b + border_t + border_b
    end

    if outer_w < 0 then outer_w = 0 end
    if outer_h < 0 then outer_h = 0 end

    local final_content_w = outer_w - padding_l - padding_r - border_l - border_r
    local final_content_h = outer_h - padding_t - padding_b - border_t - border_b
    if final_content_w < 0 then final_content_w = 0 end
    if final_content_h < 0 then final_content_h = 0 end

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
    lay.scroll_w  = total_content_w
    lay.scroll_h  = total_content_h

    ns:clear_dirty(nid, ns.LAYOUT_DIRTY)
    ns:mark_dirty(nid, ns.PAINT_DIRTY)
end

return Grid



