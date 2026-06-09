------------------------------------------------------------
-- ext_core_astro_ui_lib / core / scroll / scroll_engine.lua
-- Scroll engine: wheel scrolling, scrollbar thumb drag,
-- track click, arrow key scrolling, page up/down,
-- and scrollbar painting for overflow containers.
-- Supports both vertical and horizontal scrolling.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ScrollEngine = {}
ScrollEngine.__index = ScrollEngine

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local SCROLL_SPEED    = 30   -- pixels per wheel tick
local ARROW_SPEED     = 40   -- pixels per arrow key press
local SB_WIDTH        = 6    -- scrollbar track width
local SB_MARGIN       = 1    -- margin from edge
local MIN_THUMB_H     = 20   -- minimum thumb height (vertical)
local MIN_THUMB_W     = 20   -- minimum thumb width (horizontal)
local SMOOTH_FACTOR   = 0.35 -- ease-out lerp factor per frame (higher = snappier)
local SMOOTH_SNAP     = 0.5  -- snap threshold in pixels
local SNAP_IDLE_FRAMES = 4   -- frames with no scroll input before snap triggers
local SNAP_PROXIMITY_RATIO = 0.5 -- proximity threshold as fraction of container size

-- VK codes (duplicated to avoid require cycle)
local VK_LBUTTON = 0x01
local VK_UP      = 0x26
local VK_DOWN    = 0x28
local VK_LEFT    = 0x25
local VK_RIGHT   = 0x27
local VK_PRIOR   = 0x21  -- Page Up
local VK_NEXT    = 0x22  -- Page Down
local VK_HOME    = 0x24
local VK_END_KEY = 0x23

local function focused_control_consumes_scroll_keys(ns, event_system)
    if not event_system then return false end
    local fid = event_system.focus_id
    if not fid or fid == 0 then return false end

    local tag = ns._st:get(ns.tag[fid] or 0)
    if tag == "textarea" or tag == "select" then return true end
    if tag == "input" then
        local attrs = ns.attrs[fid] or {}
        local typ = tostring(attrs.type or "text"):lower()
        if typ == "text" or typ == "search" or typ == "url" or typ == "email"
           or typ == "password" or typ == "tel" or typ == "number"
           or typ == "range" or typ == "color" then
            return true
        end
    end

    local comp = ns._components and ns._components[fid]
    if comp then
        return comp.type == "input" or comp.type == "textarea"
            or comp.type == "select" or comp.type == "slider"
            or comp.type == "input-number" or comp.type == "input-color"
    end
    return false
end

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new ScrollEngine.
---@param node_store table  NodeStore instance
---@param platform table|nil Platform adapter instance
---@return table  ScrollEngine instance
function ScrollEngine.new(node_store, platform)
    return setmetatable({
        ns = node_store,
        platform = platform,
        -- Vertical thumb drag state
        _drag_nid    = nil,   -- node id being dragged
        _drag_offset = 0,     -- mouse offset within thumb at drag start
        -- Horizontal thumb drag state
        _drag_h_nid    = nil,
        _drag_h_offset = 0,
        -- Smooth scroll animation targets (keyed by node id)
        _smooth_target_y = {},  -- nid -> target scroll.y
        _smooth_target_x = {},  -- nid -> target scroll.x
        -- Scroll-snap state (keyed by node id)
        _snap_idle = {},        -- nid -> frames since last scroll input
        _snap_pending = {},     -- nid -> true when snap needs processing
        _snap_active = {},      -- nid -> true when currently animating to snap point
        -- Per-instance content extent cache (must NOT be module-scope: each
        -- mount has its own NodeStore with its own nid namespace, and a
        -- shared cache hands the new mount stale extents on the first frame
        -- after navigation/reload).
        _extent_cache = {},
    }, ScrollEngine)
end

local function overlay_scrollbars_hidden(se)
    local pl = se and se.platform
    if not pl or type(pl.get_scrollbar_gutter_width) ~= "function" then
        return false
    end
    local ok, gutter = pcall(pl.get_scrollbar_gutter_width, pl)
    return ok and gutter == 0
end

------------------------------------------------------------
-- Helpers: vertical scrollbar
------------------------------------------------------------

--- Invalidate extent cache for a scroll container (instance method).
function ScrollEngine:invalidate_extent(nid)
    local cache = self._extent_cache
    local entry = cache and cache[nid]
    if entry then entry.dirty = true end
end

--- Remove extent cache entry for a deleted node (instance method, prevents
--- stale data on nid reuse).
function ScrollEngine:clear_extent(nid)
    if self._extent_cache then self._extent_cache[nid] = nil end
end

--- Compute the actual content extent by walking children.
--- This is layout-algorithm-agnostic: works for flex, block, grid.
--- Results are cached and invalidated when a child's layout changes.
---@param se    table  ScrollEngine
---@param ns    table  NodeStore
---@param nid   number Parent node id
---@return number bottom  Maximum bottom edge of all children (absolute y)
local function children_extent_y(se, ns, nid)
    local cache = se._extent_cache
    local entry = cache[nid]
    if entry and not entry.dirty then
        return entry.y
    end

    local max_bottom = 0
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        -- Skip out-of-flow children (absolute/fixed) -" they don't
        -- contribute to the scrollable content extent.
        local cc = ns.computed[cid]
        local cpos = cc and cc.position or "static"
        if cpos ~= "absolute" and cpos ~= "fixed" then
            local cl = ns.layout[cid]
            if cl then
                local cb = cl.y + cl.h
                if cb > max_bottom then max_bottom = cb end
            end
        end
        cid = ns.next_sibling[cid] or 0
    end

    cache[nid] = { y = max_bottom, dirty = false }
    return max_bottom
end

--- Compute the total scrollable content height for a node.
--- Prefers the layout-engine-computed scroll_h (which knows the full
--- children stack before height constraint), but also checks actual
--- child positions as a layout-agnostic fallback.  Uses whichever
--- is larger so both block-layout and flex-layout containers work.
---@param ns    table  NodeStore
---@param nid   number Node id
---@param lay   table  Layout record
---@param scroll table Scroll record
---@return number total_h
local function compute_total_h(se, ns, nid, lay, scroll)
    -- Primary: layout-engine value (block/flex/grid/table all set scroll_h
    -- to the full children stack height BEFORE the height constraint).
    -- This is scroll-position-independent and always stable.
    local from_layout = lay.scroll_h or 0
    if from_layout > 0 then return from_layout end

    -- Fallback: walk actual child positions (only when scroll_h is missing).
    -- Children are positioned with scroll offset applied, so add scroll.y
    -- back to get the true content extent.
    local extent = children_extent_y(se, ns, nid)
    if extent > 0 then
        local from_children = (extent - lay.content_y) + (scroll.y or 0)
        if from_children > 0 then return from_children end
    end

    return lay.content_h or 0
end

--- Compute vertical scrollbar geometry for a node.
---@return table|nil  {sb_x, sb_y, sb_h, thumb_y, thumb_h, total_h, view_h, max_scroll}
local function scrollbar_geom(se, ns, nid)
    local comp = ns.computed[nid]
    if not comp then return nil end

    -- Engine sets overflow_y:"auto" on root nodes before layout,
    -- so this just reads the computed value.
    local ov_y = comp.overflow_y or "visible"
    if ov_y ~= "scroll" and ov_y ~= "auto" then return nil end

    local lay = ns.layout[nid]
    local scroll = ns.scroll[nid]
    if not lay or not scroll then return nil end

    local total_h = compute_total_h(se, ns, nid, lay, scroll)
    local view_h  = lay.content_h or lay.h or 0
    if total_h <= view_h then return nil end

    local sb_x = lay.x + lay.w - SB_WIDTH - SB_MARGIN
    local sb_y = lay.y
    local sb_h = lay.h

    local thumb_ratio = view_h / total_h
    local thumb_h     = math.max(MIN_THUMB_H, math.floor(sb_h * thumb_ratio))
    local max_scroll  = math.max(0, total_h - view_h)
    local scroll_ratio = 0
    if max_scroll > 0 then
        scroll_ratio = scroll.y / max_scroll
    end
    local thumb_y = sb_y + math.floor((sb_h - thumb_h) * scroll_ratio)

    return {
        sb_x       = sb_x,
        sb_y       = sb_y,
        sb_h       = sb_h,
        thumb_y    = thumb_y,
        thumb_h    = thumb_h,
        total_h    = total_h,
        view_h     = view_h,
        max_scroll = max_scroll,
    }
end

------------------------------------------------------------
-- Helpers: horizontal scrollbar
------------------------------------------------------------

--- Compute horizontal scrollbar geometry for a node.
---@return table|nil  {sb_x, sb_y, sb_w, thumb_x, thumb_w, total_w, view_w, max_scroll}
local function scrollbar_geom_h(ns, nid)
    local comp = ns.computed[nid]
    if not comp then return nil end

    local ov_x = comp.overflow_x or "visible"
    if ov_x ~= "scroll" and ov_x ~= "auto" then return nil end

    local lay = ns.layout[nid]
    local scroll = ns.scroll[nid]
    if not lay or not scroll then return nil end

    local total_w = lay.scroll_w or lay.content_w or 0
    local view_w  = lay.content_w or lay.w or 0
    if total_w <= view_w then return nil end

    local sb_x = lay.x
    local sb_y = lay.y + lay.h - SB_WIDTH - SB_MARGIN
    local sb_w = lay.w

    local thumb_ratio = view_w / total_w
    local thumb_w     = math.max(MIN_THUMB_W, math.floor(sb_w * thumb_ratio))
    local max_scroll  = math.max(0, total_w - view_w)
    local scroll_ratio = 0
    if max_scroll > 0 then
        scroll_ratio = scroll.x / max_scroll
    end
    local thumb_x = sb_x + math.floor((sb_w - thumb_w) * scroll_ratio)

    return {
        sb_x       = sb_x,
        sb_y       = sb_y,
        sb_w       = sb_w,
        thumb_x    = thumb_x,
        thumb_w    = thumb_w,
        total_w    = total_w,
        view_w     = view_w,
        max_scroll = max_scroll,
    }
end

--- Clamp and apply vertical scroll offset for a node (instant).
local function apply_scroll(ns, nid, new_y, max_scroll)
    local scroll = ns.scroll[nid]
    if not scroll then return end
    scroll.y = math.floor(math.max(0, math.min(max_scroll, new_y)) + 0.5)
    ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
end

--- Clamp and apply horizontal scroll offset for a node (instant).
local function apply_scroll_x(ns, nid, new_x, max_scroll)
    local scroll = ns.scroll[nid]
    if not scroll then return end
    scroll.x = math.floor(math.max(0, math.min(max_scroll, new_x)) + 0.5)
    ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
end

--- Check if a node has scroll-behavior: smooth.
local function is_smooth(ns, nid)
    local comp = ns.computed[nid]
    return comp and comp.scroll_behavior == "smooth"
end

------------------------------------------------------------
-- Scroll-snap helpers
------------------------------------------------------------

--- Parse scroll-snap-type value into axis and strictness.
--- Returns axis ("x","y","both",nil) and strictness ("mandatory","proximity",nil).
---@param val string  e.g. "y mandatory", "x proximity", "none"
---@return string|nil axis
---@return string|nil strictness
local function parse_snap_type(val)
    if not val or val == "none" then return nil, nil end
    local axis, strict = val:match("^(%S+)%s+(%S+)$")
    if axis and strict then
        return axis, strict
    end
    return nil, nil
end

--- Find snap points for direct children along a given axis.
--- Returns a list of scroll offsets that would align each child's
--- snap-align edge with the container's viewport edge.
---@param ns    table  NodeStore
---@param nid   number Container node id
---@param axis  string "x" or "y" or "both"
---@param is_y  boolean true to compute Y snap points, false for X
---@return table  array of {offset=number, align=string}
local function collect_snap_points(ns, nid, axis, is_y)
    local points = {}
    local lay = ns.layout[nid]
    if not lay then return points end

    local comp = ns.computed[nid]
    local container_origin, container_size
    local scroll_pad_start, scroll_pad_end = 0, 0
    if is_y then
        container_origin = lay.content_y or lay.y
        container_size   = lay.content_h or lay.h or 0
        if comp then
            scroll_pad_start = tonumber(comp.scroll_padding_top) or 0
            scroll_pad_end   = tonumber(comp.scroll_padding_bottom) or 0
        end
    else
        container_origin = lay.content_x or lay.x
        container_size   = lay.content_w or lay.w or 0
        if comp then
            scroll_pad_start = tonumber(comp.scroll_padding_left) or 0
            scroll_pad_end   = tonumber(comp.scroll_padding_right) or 0
        end
    end

    local scroll = ns.scroll[nid]
    if not scroll then return points end
    local cur_offset = is_y and (scroll.y or 0) or (scroll.x or 0)

    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        local cc = ns.computed[cid]
        local cl = ns.layout[cid]
        if cc and cl then
            local cpos = cc.position or "static"
            if cpos ~= "absolute" and cpos ~= "fixed" then
                local align = cc.scroll_snap_align or "none"
                if align ~= "none" then
                    -- Child edge in content-flow coordinates
                    -- (layout positions include scroll offset, so undo it)
                    local child_start, child_size
                    if is_y then
                        child_start = (cl.y - container_origin) + cur_offset
                        child_size  = cl.h or 0
                    else
                        child_start = (cl.x - container_origin) + cur_offset
                        child_size  = cl.w or 0
                    end

                    -- Apply scroll-margin from the child element
                    local child_margin_start, child_margin_end = 0, 0
                    if cc then
                        if is_y then
                            child_margin_start = tonumber(cc.scroll_margin_top) or 0
                            child_margin_end   = tonumber(cc.scroll_margin_bottom) or 0
                        else
                            child_margin_start = tonumber(cc.scroll_margin_left) or 0
                            child_margin_end   = tonumber(cc.scroll_margin_right) or 0
                        end
                    end

                    local snap_offset
                    if align == "start" then
                        -- Snap so child start aligns with container start + scroll-padding
                        snap_offset = child_start - scroll_pad_start - child_margin_start
                    elseif align == "end" then
                        -- Snap so child end aligns with container end - scroll-padding
                        snap_offset = child_start + child_size + child_margin_end - container_size + scroll_pad_end
                    elseif align == "center" then
                        -- Snap so child center aligns with container center (adjusted for padding)
                        local effective_size = container_size - scroll_pad_start - scroll_pad_end
                        snap_offset = child_start - child_margin_start + (child_size + child_margin_start + child_margin_end - effective_size) / 2 - scroll_pad_start
                    end
                    if snap_offset then
                        points[#points + 1] = snap_offset
                    end
                end
            end
        end
        cid = ns.next_sibling[cid] or 0
    end
    return points
end

--- Find the closest snap point to the current scroll offset.
---@param points     table   array of offset numbers
---@param cur_offset number  current scroll offset
---@return number|nil  closest snap offset, or nil if no points
local function closest_snap_point(points, cur_offset)
    if #points == 0 then return nil end
    local best = points[1]
    local best_dist = math.abs(best - cur_offset)
    for i = 2, #points do
        local d = math.abs(points[i] - cur_offset)
        if d < best_dist then
            best = points[i]
            best_dist = d
        end
    end
    return best
end

------------------------------------------------------------
-- Smooth scroll helpers (methods, need access to self)
------------------------------------------------------------

--- Set vertical scroll target.  If smooth, animates; otherwise instant.
function ScrollEngine:set_scroll_y(nid, new_y, max_scroll)
    local ns = self.ns
    local clamped = math.max(0, math.min(max_scroll, new_y))
    if is_smooth(ns, nid) then
        self._smooth_target_y[nid] = clamped
    else
        self._smooth_target_y[nid] = nil
        apply_scroll(ns, nid, clamped, max_scroll)
    end
end

--- Set horizontal scroll target.  If smooth, animates; otherwise instant.
function ScrollEngine:set_scroll_x(nid, new_x, max_scroll)
    local ns = self.ns
    local clamped = math.max(0, math.min(max_scroll, new_x))
    if is_smooth(ns, nid) then
        self._smooth_target_x[nid] = clamped
    else
        self._smooth_target_x[nid] = nil
        apply_scroll_x(ns, nid, clamped, max_scroll)
    end
end

--- Animate all active smooth scroll targets toward their goals.
--- Call once per frame before update (or at the start of update).
function ScrollEngine:animate_smooth()
    local ns = self.ns
    -- Vertical
    for nid, target in pairs(self._smooth_target_y) do
        local scroll = ns.scroll[nid]
        if scroll then
            local cur = scroll.y
            local diff = target - cur
            if diff < SMOOTH_SNAP and diff > -SMOOTH_SNAP then
                -- Close enough: snap and stop animating
                scroll.y = target
                self._smooth_target_y[nid] = nil
            else
                -- Round toward target to guarantee progress every frame
                local next_y = cur + diff * SMOOTH_FACTOR
                if diff > 0 then
                    scroll.y = math.ceil(next_y)
                else
                    scroll.y = math.floor(next_y)
                end
            end
            ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        else
            self._smooth_target_y[nid] = nil
        end
    end
    -- Horizontal
    for nid, target in pairs(self._smooth_target_x) do
        local scroll = ns.scroll[nid]
        if scroll then
            local cur = scroll.x
            local diff = target - cur
            if diff < SMOOTH_SNAP and diff > -SMOOTH_SNAP then
                scroll.x = target
                self._smooth_target_x[nid] = nil
            else
                local next_x = cur + diff * SMOOTH_FACTOR
                if diff > 0 then
                    scroll.x = math.ceil(next_x)
                else
                    scroll.x = math.floor(next_x)
                end
            end
            ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        else
            self._smooth_target_x[nid] = nil
        end
    end
end

------------------------------------------------------------
-- Scroll-snap: idle detection and snap trigger
------------------------------------------------------------

--- Mark that a scroll container received input this frame.
--- Resets the idle counter so snap won't trigger yet.
function ScrollEngine:_snap_mark_active(nid)
    local ns = self.ns
    local comp = ns.computed[nid]
    if not comp then return end
    local snap_type = comp.scroll_snap_type
    if not snap_type or snap_type == "none" then return end
    self._snap_idle[nid] = 0
    self._snap_pending[nid] = true
    self._snap_active[nid] = nil  -- cancel any in-progress snap animation
end

--- Process scroll-snap for all containers that are pending.
--- Called once per frame after animate_smooth.
function ScrollEngine:process_snap()
    local ns = self.ns

    -- Advance idle counters for containers that have pending snaps
    for nid, _ in pairs(self._snap_pending) do
        local idle = self._snap_idle[nid] or 0
        idle = idle + 1
        self._snap_idle[nid] = idle

        -- Don't trigger snap until idle long enough
        if idle >= SNAP_IDLE_FRAMES then
            -- Also wait until any smooth animation finishes
            if self._smooth_target_y[nid] or self._smooth_target_x[nid] then
                -- Still animating from user input; keep waiting
                self._snap_idle[nid] = 0
            else
                self:_trigger_snap(nid)
                self._snap_pending[nid] = nil
                self._snap_idle[nid] = nil
            end
        end
    end
end

--- Actually compute and start the snap animation for a container.
function ScrollEngine:_trigger_snap(nid)
    local ns = self.ns
    local comp = ns.computed[nid]
    if not comp then return end

    local axis, strictness = parse_snap_type(comp.scroll_snap_type)
    if not axis or not strictness then return end

    local lay = ns.layout[nid]
    local scroll = ns.scroll[nid]
    if not lay or not scroll then return end

    -- Y-axis snapping
    if axis == "y" or axis == "both" then
        local total_h = compute_total_h(self, ns, nid, lay, scroll)
        local view_h  = lay.content_h or lay.h or 0
        local max_scroll_y = math.max(0, total_h - view_h)
        if max_scroll_y > 0 then
            local points = collect_snap_points(ns, nid, axis, true)
            local target = closest_snap_point(points, scroll.y)
            if target then
                target = math.max(0, math.min(max_scroll_y, target))
                local dist = math.abs(target - scroll.y)
                local do_snap = false
                if strictness == "mandatory" then
                    do_snap = true
                elseif strictness == "proximity" then
                    do_snap = dist <= view_h * SNAP_PROXIMITY_RATIO
                end
                if do_snap and dist > SMOOTH_SNAP then
                    -- Use smooth animation to reach the snap point
                    self._smooth_target_y[nid] = target
                    self._snap_active[nid] = true
                end
            end
        end
    end

    -- X-axis snapping
    if axis == "x" or axis == "both" then
        local total_w = lay.scroll_w or lay.content_w or 0
        local view_w  = lay.content_w or lay.w or 0
        local max_scroll_x = math.max(0, total_w - view_w)
        if max_scroll_x > 0 then
            local points = collect_snap_points(ns, nid, axis, false)
            local target = closest_snap_point(points, scroll.x)
            if target then
                target = math.max(0, math.min(max_scroll_x, target))
                local dist = math.abs(target - scroll.x)
                local do_snap = false
                if strictness == "mandatory" then
                    do_snap = true
                elseif strictness == "proximity" then
                    do_snap = dist <= view_w * SNAP_PROXIMITY_RATIO
                end
                if do_snap and dist > SMOOTH_SNAP then
                    self._smooth_target_x[nid] = target
                    self._snap_active[nid] = true
                end
            end
        end
    end
end

------------------------------------------------------------
-- Update
------------------------------------------------------------

--- Clamp all scroll offsets after layout.
--- Clamp all scroll offsets after layout.
--- Returns true if any offset was clamped (caller should re-layout).
function ScrollEngine:clamp_offsets()
    local ns = self.ns
    local clamped = false
    for nid, scroll in pairs(ns.scroll) do
        local lay = ns.layout[nid]
        if lay and scroll then
            -- Vertical
            local total_h = compute_total_h(self, ns, nid, lay, scroll)
            local view_h  = lay.content_h or lay.h or 0
            local max_scroll_y = math.max(0, total_h - view_h)
            if scroll.y > max_scroll_y then
                scroll.y = max_scroll_y
                ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
                clamped = true
            end
            -- Horizontal
            local total_w = lay.scroll_w or lay.content_w or 0
            local view_w  = lay.content_w or lay.w or 0
            local max_scroll_x = math.max(0, total_w - view_w)
            if scroll.x > max_scroll_x then
                scroll.x = max_scroll_x
                ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
                clamped = true
            end
        end
    end
    return clamped
end

--- Per-frame update.  Handles all scroll interactions.
---@param input_state  table  InputState instance
---@param event_system table  EventSystem instance
function ScrollEngine:update(input_state, event_system)
    -- Advance smooth scroll animations each frame
    self:animate_smooth()
    -- Process scroll-snap idle detection and snapping
    self:process_snap()

    local ns = self.ns
    local mx, my = input_state.cursor_x, input_state.cursor_y
    local mouse_down    = input_state:is_mouse_down()
    local mouse_clicked = input_state:is_mouse_clicked()

    ----------------------------------------------------
    -- 1. Handle ongoing vertical thumb drag
    ----------------------------------------------------
    if self._drag_nid then
        if mouse_down then
            local nid = self._drag_nid
            local g = scrollbar_geom(self, ns, nid)
            if g then
                local track_space = g.sb_h - g.thumb_h
                if track_space > 0 then
                    local rel_y = my - self._drag_offset - g.sb_y
                    local ratio = rel_y / track_space
                    ratio = math.max(0, math.min(1, ratio))
                    apply_scroll(ns, nid, math.floor(ratio * g.max_scroll), g.max_scroll)
                    self:_snap_mark_active(nid)
                end
            end
            return  -- drag consumes input
        else
            self._drag_nid = nil
        end
    end

    ----------------------------------------------------
    -- 1b. Handle ongoing horizontal thumb drag
    ----------------------------------------------------
    if self._drag_h_nid then
        if mouse_down then
            local nid = self._drag_h_nid
            local g = scrollbar_geom_h(ns, nid)
            if g then
                local track_space = g.sb_w - g.thumb_w
                if track_space > 0 then
                    local rel_x = mx - self._drag_h_offset - g.sb_x
                    local ratio = rel_x / track_space
                    ratio = math.max(0, math.min(1, ratio))
                    apply_scroll_x(ns, nid, math.floor(ratio * g.max_scroll), g.max_scroll)
                    self:_snap_mark_active(nid)
                end
            end
            return
        else
            self._drag_h_nid = nil
        end
    end

    ----------------------------------------------------
    -- 2. Find hovered scroll containers (vertical + horizontal)
    --    overscroll-behavior: if a container has "contain" or "none",
    --    it captures scroll events even when at its scroll limits,
    --    preventing propagation to parent containers.
    ----------------------------------------------------
    local hover_nid_v = nil   -- vertical scroll container
    local hover_nid_h = nil   -- horizontal scroll container
    local raw_wheel = input_state.wheel
    local wheel_dir = raw_wheel > 0 and 1 or (raw_wheel < 0 and -1 or 0)
    local chain = event_system.hover_chain
    for i = 1, #chain do
        local nid = chain[i]
        local comp = ns.computed[nid]
        if comp then
            local lay = ns.layout[nid]
            local scroll = ns.scroll[nid]
            if lay and scroll then
                -- Vertical
                if not hover_nid_v then
                    local ov_y = comp.overflow_y or "visible"
                    local has_overflow_y = (ov_y == "auto" or ov_y == "scroll" or ov_y == "hidden")
                    local total_h = has_overflow_y and compute_total_h(self, ns, nid, lay, scroll) or 0
                    local view_h  = has_overflow_y and (lay.content_h or lay.h or 0) or 0
                    local has_content_overflow_y = total_h > view_h
                    if (ov_y == "scroll" or ov_y == "auto") and has_content_overflow_y then
                        local osb_y = comp.overscroll_behavior_y or "auto"
                        -- With "auto" overscroll: propagate to parent when at scroll limit
                        if osb_y == "auto" and wheel_dir ~= 0 then
                            local max_scroll_y = math.max(0, total_h - view_h)
                            local cur_y = scroll.y or 0
                            local at_top = cur_y <= 0 and wheel_dir > 0
                            local at_bottom = cur_y >= max_scroll_y and wheel_dir < 0
                            if not at_top and not at_bottom then
                                hover_nid_v = nid
                            end
                            -- at limit + auto → skip, let parent handle it
                        else
                            -- contain/none or no wheel: always capture
                            hover_nid_v = nid
                        end
                    end
                    -- Block propagation for contain/none even without scrollable content
                    if not hover_nid_v and has_content_overflow_y and has_overflow_y then
                        local osb_y = comp.overscroll_behavior_y or "auto"
                        if osb_y == "contain" or osb_y == "none" then
                            hover_nid_v = nid
                        end
                    end
                end
                -- Horizontal
                if not hover_nid_h then
                    local ov_x = comp.overflow_x or "visible"
                    local has_overflow_x = (ov_x == "auto" or ov_x == "scroll" or ov_x == "hidden")
                    local total_w = has_overflow_x and (lay.scroll_w or lay.content_w or 0) or 0
                    local view_w  = has_overflow_x and (lay.content_w or lay.w or 0) or 0
                    local has_content_overflow_x = total_w > view_w
                    if (ov_x == "scroll" or ov_x == "auto") and has_content_overflow_x then
                        local osb_x = comp.overscroll_behavior_x or "auto"
                        if osb_x == "auto" and wheel_dir ~= 0 then
                            local max_scroll_x = math.max(0, total_w - view_w)
                            local cur_x = scroll.x or 0
                            local at_left = cur_x <= 0 and wheel_dir > 0
                            local at_right = cur_x >= max_scroll_x and wheel_dir < 0
                            if not at_left and not at_right then
                                hover_nid_h = nid
                            end
                        else
                            hover_nid_h = nid
                        end
                    end
                    -- Block propagation for contain/none
                    if not hover_nid_h and has_content_overflow_x and has_overflow_x then
                        local osb_x = comp.overscroll_behavior_x or "auto"
                        if osb_x == "contain" or osb_x == "none" then
                            hover_nid_h = nid
                        end
                    end
                end
            end
        end
        if hover_nid_v and hover_nid_h then break end
    end

    ----------------------------------------------------
    -- 3. Mouse click: start thumb drag or track click
    ----------------------------------------------------
    if mouse_clicked then
        -- Check horizontal scrollbar first (at bottom edge)
        if hover_nid_h then
            local g = scrollbar_geom_h(ns, hover_nid_h)
            if g then
                if my >= g.sb_y and my < g.sb_y + SB_WIDTH + SB_MARGIN then
                    if mx >= g.thumb_x and mx < g.thumb_x + g.thumb_w then
                        -- Click on horizontal thumb: start drag
                        self._drag_h_nid    = hover_nid_h
                        self._drag_h_offset = mx - g.thumb_x
                        return
                    elseif mx >= g.sb_x and mx < g.sb_x + g.sb_w then
                        -- Click on horizontal track: page jump
                        local scroll = ns.scroll[hover_nid_h]
                        if scroll then
                            if mx < g.thumb_x then
                                self:set_scroll_x(hover_nid_h,
                                    scroll.x - g.view_w, g.max_scroll)
                            else
                                self:set_scroll_x(hover_nid_h,
                                    scroll.x + g.view_w, g.max_scroll)
                            end
                            self:_snap_mark_active(hover_nid_h)
                        end
                        return
                    end
                end
            end
        end

        -- Check vertical scrollbar
        if hover_nid_v then
            local g = scrollbar_geom(self, ns, hover_nid_v)
            if g then
                if mx >= g.sb_x and mx < g.sb_x + SB_WIDTH + SB_MARGIN then
                    if my >= g.thumb_y and my < g.thumb_y + g.thumb_h then
                        self._drag_nid    = hover_nid_v
                        self._drag_offset = my - g.thumb_y
                        return
                    elseif my >= g.sb_y and my < g.sb_y + g.sb_h then
                        local scroll = ns.scroll[hover_nid_v]
                        if scroll then
                            if my < g.thumb_y then
                                self:set_scroll_y(hover_nid_v,
                                    scroll.y - g.view_h, g.max_scroll)
                            else
                                self:set_scroll_y(hover_nid_v,
                                    scroll.y + g.view_h, g.max_scroll)
                            end
                            self:_snap_mark_active(hover_nid_v)
                        end
                        return
                    end
                end
            end
        end
    end

    ----------------------------------------------------
    -- 4. Mouse wheel (Shift+wheel = horizontal)
    --    Accumulate fractional deltas across frames so
    --    smooth-scroll mice don't overshoot, but integer
    --    mice still feel crisp.
    ----------------------------------------------------
    -- raw_wheel already read above for overscroll direction check
    self._wheel_accum = (self._wheel_accum or 0) + raw_wheel
    local wheel = 0
    if self._wheel_accum >= 1 or self._wheel_accum <= -1 then
        -- Consume full ticks, keep fractional remainder
        if self._wheel_accum > 0 then
            wheel = math.floor(self._wheel_accum)
        else
            wheel = math.ceil(self._wheel_accum)
        end
        self._wheel_accum = self._wheel_accum - wheel
    end
    if wheel ~= 0 then
        local is_shift = input_state.shift

        -- Determine if the horizontal container is a closer (deeper) target
        -- than the vertical one.  When a purely-horizontal scroll container
        -- is nested inside a vertical one, normal wheel should scroll it
        -- horizontally instead of scrolling the parent vertically.
        local h_is_deeper = false
        if hover_nid_h and hover_nid_v and hover_nid_h ~= hover_nid_v then
            -- Walk hover_chain: whichever appears first is deeper (closer to cursor)
            for ci = 1, #chain do
                if chain[ci] == hover_nid_h then h_is_deeper = true;  break end
                if chain[ci] == hover_nid_v then break end
            end
        end

        if is_shift and hover_nid_h then
            -- Shift+wheel -> horizontal scroll
            local scroll = ns.scroll[hover_nid_h]
            local lay = ns.layout[hover_nid_h]
            if scroll and lay then
                local total_w = lay.scroll_w or lay.content_w or 0
                local view_w  = lay.content_w or lay.w or 0
                local max_scroll = math.max(0, total_w - view_w)
                local base_x = self._smooth_target_x[hover_nid_h] or scroll.x
                self:set_scroll_x(hover_nid_h,
                    base_x - wheel * SCROLL_SPEED, max_scroll)
                self:_snap_mark_active(hover_nid_h)
            end
        elseif h_is_deeper then
            -- Horizontal container is closer to cursor than vertical:
            -- redirect normal wheel to horizontal scroll
            local scroll = ns.scroll[hover_nid_h]
            local lay = ns.layout[hover_nid_h]
            if scroll and lay then
                local total_w = lay.scroll_w or lay.content_w or 0
                local view_w  = lay.content_w or lay.w or 0
                local max_scroll = math.max(0, total_w - view_w)
                local base_x = self._smooth_target_x[hover_nid_h] or scroll.x
                self:set_scroll_x(hover_nid_h,
                    base_x - wheel * SCROLL_SPEED, max_scroll)
                self:_snap_mark_active(hover_nid_h)
            end
        elseif hover_nid_v then
            -- Normal wheel -> vertical scroll
            local scroll = ns.scroll[hover_nid_v]
            local lay = ns.layout[hover_nid_v]
            if scroll and lay then
                local total_h = compute_total_h(self, ns, hover_nid_v, lay, scroll)
                local view_h  = lay.content_h or lay.h or 0
                local max_scroll = math.max(0, total_h - view_h)
                local base_y = self._smooth_target_y[hover_nid_v] or scroll.y
                self:set_scroll_y(hover_nid_v,
                    base_y - wheel * SCROLL_SPEED, max_scroll)
                self:_snap_mark_active(hover_nid_v)
            end
        elseif hover_nid_h then
            -- No vertical scroll container at all:
            -- plain wheel scrolls horizontally
            local scroll = ns.scroll[hover_nid_h]
            local lay = ns.layout[hover_nid_h]
            if scroll and lay then
                local total_w = lay.scroll_w or lay.content_w or 0
                local view_w  = lay.content_w or lay.w or 0
                local max_scroll = math.max(0, total_w - view_w)
                local base_x = self._smooth_target_x[hover_nid_h] or scroll.x
                self:set_scroll_x(hover_nid_h,
                    base_x - wheel * SCROLL_SPEED, max_scroll)
                self:_snap_mark_active(hover_nid_h)
            end
        end
    end

    ----------------------------------------------------
    -- 5. Keyboard: arrow keys, page up/down, home/end
    ----------------------------------------------------
    if hover_nid_v and not focused_control_consumes_scroll_keys(ns, event_system) then
        local scroll = ns.scroll[hover_nid_v]
        local lay = ns.layout[hover_nid_v]
        if scroll and lay then
            local total_h = compute_total_h(self, ns, hover_nid_v, lay, scroll)
            local view_h  = lay.content_h or lay.h or 0
            local max_scroll = math.max(0, total_h - view_h)
            local base_y = self._smooth_target_y[hover_nid_v] or scroll.y
            local new_y = nil

            if input_state:is_key_edge(VK_UP) then
                new_y = base_y - ARROW_SPEED
            elseif input_state:is_key_edge(VK_DOWN) then
                new_y = base_y + ARROW_SPEED
            elseif input_state:is_key_edge(VK_PRIOR) then
                new_y = base_y - view_h
            elseif input_state:is_key_edge(VK_NEXT) then
                new_y = base_y + view_h
            elseif input_state:is_key_edge(VK_HOME) then
                new_y = 0
            elseif input_state:is_key_edge(VK_END_KEY) then
                new_y = max_scroll
            end

            if new_y then
                self:set_scroll_y(hover_nid_v, new_y, max_scroll)
                self:_snap_mark_active(hover_nid_v)
            end
        end
    end

    -- Horizontal arrow keys
    if hover_nid_h and not focused_control_consumes_scroll_keys(ns, event_system) then
        local scroll = ns.scroll[hover_nid_h]
        local lay = ns.layout[hover_nid_h]
        if scroll and lay then
            local total_w = lay.scroll_w or lay.content_w or 0
            local view_w  = lay.content_w or lay.w or 0
            local max_scroll = math.max(0, total_w - view_w)
            local base_x = self._smooth_target_x[hover_nid_h] or scroll.x
            local new_x = nil

            if input_state:is_key_edge(VK_LEFT) then
                new_x = base_x - ARROW_SPEED
            elseif input_state:is_key_edge(VK_RIGHT) then
                new_x = base_x + ARROW_SPEED
            end

            if new_x then
                self:set_scroll_x(hover_nid_h, new_x, max_scroll)
                self:_snap_mark_active(hover_nid_h)
            end
        end
    end
end

------------------------------------------------------------
-- Painting
------------------------------------------------------------

--- Paint vertical scrollbar for a node if it has overflow scroll/auto.
---@param ns  table  NodeStore instance
---@param nid number node id
---@param dl  table  DisplayList instance
function ScrollEngine:paint_scrollbar(ns, nid, dl)
    if overlay_scrollbars_hidden(self) then
        return
    end

    -- Resolve user-configurable scrollbar-color / scrollbar-width from the
    -- element's computed style.  Width keywords: "auto" (default), "thin", "none".
    local comp = ns.computed and ns.computed[nid]
    local track_color = { 40, 40, 45, 100 }    -- default track
    local thumb_color = { 100, 100, 110, 200 } -- default thumb
    local thumb_hover = { 140, 140, 155, 240 } -- default hover/drag thumb
    if comp then
        local sbc = comp.scrollbar_color
        if type(sbc) == "table" and sbc.type ~= nil then
            -- Parsed as {thumb={...}, track={...}}
            if type(sbc.thumb) == "table" then
                thumb_color = sbc.thumb
                thumb_hover = {
                    math.min(255, (sbc.thumb[1] or 0) + 40),
                    math.min(255, (sbc.thumb[2] or 0) + 40),
                    math.min(255, (sbc.thumb[3] or 0) + 40),
                    sbc.thumb[4] or 255,
                }
            end
            if type(sbc.track) == "table" then track_color = sbc.track end
        end
    end

    local sw = SB_WIDTH
    local sbw_kw = comp and comp.scrollbar_width
    if sbw_kw == "thin" then sw = 4
    elseif sbw_kw == "none" then return
    elseif type(sbw_kw) == "number" then sw = sbw_kw end

    -- Vertical scrollbar
    local g = scrollbar_geom(self, ns, nid)
    if g then
        dl:rect_fill(g.sb_x, g.sb_y, sw, g.sb_h, track_color[1], track_color[2], track_color[3], track_color[4] or 100, 2)
        local is_dragging = (self._drag_nid == nid)
        local c = is_dragging and thumb_hover or thumb_color
        dl:rect_fill(g.sb_x, g.thumb_y, sw, g.thumb_h, c[1], c[2], c[3], c[4] or 200, 2)
    end

    -- Horizontal scrollbar
    local gh = scrollbar_geom_h(ns, nid)
    if gh then
        dl:rect_fill(gh.sb_x, gh.sb_y, gh.sb_w, sw, track_color[1], track_color[2], track_color[3], track_color[4] or 100, 2)
        local is_dragging = (self._drag_h_nid == nid)
        local c = is_dragging and thumb_hover or thumb_color
        dl:rect_fill(gh.thumb_x, gh.sb_y, gh.thumb_w, sw, c[1], c[2], c[3], c[4] or 200, 2)
    end
end

--- Clear entire extent cache (call at start of layout pass if needed -"
--- e.g. after a viewport resize that may invalidate every container).
function ScrollEngine:reset_extent_cache()
    self._extent_cache = {}
end

return ScrollEngine



