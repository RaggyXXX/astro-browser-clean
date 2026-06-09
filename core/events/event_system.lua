------------------------------------------------------------
-- ext_core_astro_ui_lib / core / events / event_system.lua
-- Hit testing, hover chain tracking, pointer event dispatch,
-- and action handler system.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Transform = require("core/paint/transform")
local Radio     = require("core/components/radio")
local Utf8      = require("core/util/utf8")
local Painters   = require("core/paint/painters")

local ES = {}
ES.__index = ES

local function control_role(ns, nid)
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)
    if tag_str == "input" then
        local attrs = ns.attrs[nid]
        local input_type = tostring(attrs and attrs.type or "text"):lower()
        if input_type == "checkbox" or input_type == "radio"
           or input_type == "button" or input_type == "submit" or input_type == "reset" then
            return input_type
        end
    end
    return tag_str
end

------------------------------------------------------------
-- Text selection helpers (module-level, no closures)
------------------------------------------------------------

--- Measure text width using the node's font settings.
local function _sel_measure(ns, node_id, text, font_size)
    local platform = ns._platform
    if not platform or text == "" then return 0 end
    local comp = ns.computed[node_id] or {}
    local font_family = comp.font_family or ns._default_font
    local font_weight = comp.font_weight or 400
    local font_style = comp.font_style or "normal"
    local fm = ns._font_manager
    if fm and font_family then
        local cache = fm:get_cache_for(font_family, font_weight, font_style)
        if cache then return cache:measure_text(text, font_size, Utf8) end
    end
    if fm and font_family then
        return Painters.measure_text(text, font_size, font_family, font_weight, font_style)
    end
    return platform:measure_text_width(text, font_size, 0)
end

--- Cached codepoint boundary array (reused across calls to avoid alloc).
local _cp_cache_text = ""
local _cp_cache_result = { 0 }

local function _cp_bounds(text)
    if text == _cp_cache_text then return _cp_cache_result end
    local b = { 0 }
    local pos, len = 0, #text
    while pos < len do
        pos = Utf8.next(text, pos)
        b[#b + 1] = pos
    end
    _cp_cache_text = text
    _cp_cache_result = b
    return b
end

--- Map a pixel x-offset within a text node to a byte position (binary search).
local function _char_at_px(ns, nid, text, px, font_size)
    if text == "" or px <= 0 then return 0 end
    local full_w = _sel_measure(ns, nid, text, font_size)
    if px >= full_w then return #text end
    local bounds = _cp_bounds(text)
    local lo, hi = 1, #bounds
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local bp  = bounds[mid]
        local bn  = bounds[mid + 1] or #text
        local w   = _sel_measure(ns, nid, text:sub(1, bp), font_size)
        local wn  = _sel_measure(ns, nid, text:sub(1, bn), font_size)
        if px < (w + wn) / 2 then hi = mid else lo = mid + 1 end
    end
    return bounds[lo] or #text
end

--- Find the text node the user actually clicked on.
--- Previously this walked the whole ancestor chain, so clicking a non-text
--- leaf like <slider> inside a <section> would find the section's h2 text
--- as the selection anchor - dragging then highlighted the heading above
--- the slider. Restrict the search to the deepest hit node (chain[1]) and
--- its immediate descendants.
local function _sel_find_text(ns, chain)
    if #chain == 0 then return 0 end
    for i = 1, #chain do
        local tag_str = ns._st:get(ns.tag[chain[i]])
        if tag_str == "input" or tag_str == "textarea" or tag_str == "button"
           or tag_str == "select" or tag_str == "checkbox" or tag_str == "radio"
           or tag_str == "slider" or tag_str == "switch" then
            return 0
        end
    end
    local nid = chain[1]
    local comp_sel = ns.computed[nid]
    if comp_sel and comp_sel.user_select == "none" then return 0 end
    if ns.node_type[nid] == ns.TEXT then return nid end
    local cid = ns.first_child[nid]
    while cid and cid ~= 0 do
        if ns.node_type[cid] == ns.TEXT then return cid end
        cid = ns.next_sibling[cid] or 0
    end
    return 0
end

--- Compute byte-offset within a text node from cursor x.
local function _sel_px_to_char(ns, nid, mx)
    local lay = ns.layout[nid]
    if not lay then return 0 end
    local text = ns.text_content[nid] or ""
    local comp = ns.computed[nid] or {}
    if not comp.font_size then
        local pid = ns.parent[nid]
        if pid and pid ~= 0 then comp = ns.computed[pid] or comp end
    end
    return _char_at_px(ns, nid, text, mx - (lay.content_x or lay.x or 0), comp.font_size or 16)
end

--- Find lowest common ancestor of two nodes.
-- Reuses a scratch table to avoid per-call allocation.
local _lca_scratch = {}
local function _sel_common_ancestor(ns, a, b)
    -- Clear scratch
    for k in pairs(_lca_scratch) do _lca_scratch[k] = nil end
    local n = a
    while n and n ~= 0 do _lca_scratch[n] = true; n = ns.parent[n] end
    n = b
    while n and n ~= 0 do
        if _lca_scratch[n] then return n end
        n = ns.parent[n]
    end
    return 0
end

--- Collect text nodes under root in DFS order.
-- Caches result keyed by root to avoid re-walking each frame.
local _dfs_cache_root = 0
local _dfs_cache_ns   = nil
local _dfs_cache_result = {}
local _dfs_stack = {}

local function _sel_text_nodes(ns, root)
    if root == _dfs_cache_root and ns == _dfs_cache_ns then return _dfs_cache_result end
    local out = {}
    local stack = _dfs_stack
    stack[1] = root; local sp = 1
    local node_type   = ns.node_type
    local last_child   = ns.last_child
    local prev_sibling = ns.prev_sibling
    while sp > 0 do
        local n = stack[sp]; sp = sp - 1
        if node_type[n] == ns.TEXT then out[#out + 1] = n end
        local cid = last_child[n]
        while cid and cid ~= 0 do
            sp = sp + 1; stack[sp] = cid
            cid = prev_sibling[cid] or 0
        end
    end
    _dfs_cache_root = root
    _dfs_cache_ns   = ns
    _dfs_cache_result = out
    return out
end

--- Invalidate DFS cache (call when selection ends or tree changes).
local function _sel_invalidate_dfs()
    _dfs_cache_root = 0
    _dfs_cache_ns   = nil
end

--- Clear selection state on tracked nodes.
local function _sel_clear(ns, self_es)
    local changed = false
    for nid in pairs(self_es._sel_nodes) do
        local p = ns.pseudo[nid]
        if p then
            p.selected = false; p.sel_start = nil; p.sel_end = nil
            ns:mark_dirty(nid, ns.PAINT_DIRTY)
            changed = true
        end
    end
    self_es._sel_nodes = {}
    if changed then self_es.pseudo_changed = true end
end

--- Mark a text node as selected with byte range.
local function _sel_mark(ns, nid, s, e, tbl)
    local p = ns.pseudo[nid]
    if p then
        p.selected = true; p.sel_start = s; p.sel_end = e
        tbl[nid] = true
        ns:mark_dirty(nid, ns.PAINT_DIRTY)
    end
end

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new EventSystem.
---@param node_store table  NodeStore instance
---@return table  EventSystem instance
function ES.new(node_store)
    local self = setmetatable({}, ES)
    self.ns             = node_store
    self.hover_chain    = {}       -- array of node ids from root to deepest hit node
    self.focus_id       = 0        -- currently focused node
    self._prev_hover    = {}       -- previous frame's hover chain
    self._action_handlers = {}     -- action_id -> handler function
    self.pseudo_changed   = false  -- set true when pseudo states change
    self._last_hit_mx     = nil    -- last hit_test cursor x (for hover stability)
    self._last_hit_my     = nil    -- last hit_test cursor y
    self._last_hit_root   = nil
    self._last_hit_ox     = nil
    self._last_hit_oy     = nil
    self._last_hit_gen    = nil
    self._focus_via_keyboard = false  -- was focus set via Tab key?
    -- Text selection state (character-level)
    self._sel_anchor_nid  = 0      -- text node where mouse-down started
    self._sel_anchor_char = 0      -- byte offset within that node
    self._sel_dragging    = false  -- mouse held after click
    self._sel_drag_started = false -- moved enough to count as drag
    self._sel_click_mx    = 0
    self._sel_click_my    = 0
    self._sel_nodes       = {}     -- nid -> true for nodes with selection state
    -- Mousedown→mouseup matching for click events.  Chrome fires `click` on
    -- the deepest common ancestor of the mousedown and mouseup targets, NOT
    -- on every press edge.  Dragging away from the press target must
    -- cancel the click.  See `dispatch_pointer_events`.
    self._mousedown_target = 0
    self._mousedown_chain  = {}    -- snapshot of hover chain at mousedown
    -- Tooltip tracking (title-attribute based)
    self._tip_target_nid  = 0
    self._tip_start_time  = 0
    self._tip_visible     = false
    return self
end

------------------------------------------------------------
-- Action registration
------------------------------------------------------------

--- Register an action callback.
---@param action_id string   action identifier
---@param handler_fn function  callback
function ES:register_action(action_id, handler_fn)
    self._action_handlers[action_id] = handler_fn
end

------------------------------------------------------------
-- Hit testing
------------------------------------------------------------

--- Walk the tree front-to-back (last child = highest z) to
--- find the deepest node containing the cursor.  Builds the
--- hover_chain (ancestor path from root to hit node).
---@param root_id  number
---@param mx       number  mouse x
---@param my       number  mouse y
---@param offset_x number  content area x offset
---@param offset_y number  content area y offset
---@return number  hit node id, or 0
function ES:hit_test(root_id, mx, my, offset_x, offset_y)
    self._prev_hover = self.hover_chain

    -- If the mouse hasn't moved since last frame, keep the previous
    -- hover chain.  This prevents feedback loops where a :hover
    -- transform moves the element away from the cursor, causing
    -- hover loss → element snaps back → hover regained → flicker.
    local dirty_gen = self.ns._dirty_gen or 0
    if mx == self._last_hit_mx and my == self._last_hit_my
       and root_id == self._last_hit_root
       and (offset_x or 0) == self._last_hit_ox
       and (offset_y or 0) == self._last_hit_oy
       and dirty_gen == self._last_hit_gen then
        return (self.hover_chain[1] or 0)
    end
    self._last_hit_mx = mx
    self._last_hit_my = my
    self._last_hit_root = root_id
    self._last_hit_ox = offset_x or 0
    self._last_hit_oy = offset_y or 0
    self._last_hit_gen = dirty_gen

    self.hover_chain = {}

    if root_id == 0 then return 0 end

    -- Phase 1: Collect ALL fixed nodes in the tree (full walk, not cursor-dependent).
    -- This matches paint_tree which traverses the whole tree and defers fixed nodes.
    local fixed_nodes = {}
    self:_collect_fixed(root_id, fixed_nodes)

    -- Phase 2: Normal hit-walk (skips fixed children)
    local chain = {}
    local hit = self:_hit_walk(root_id, mx, my, offset_x or 0, offset_y or 0, chain, true)

    -- Phase 3: Test fixed nodes last (highest z-priority, like deferred fixed paint).
    -- Walk in reverse so the last-encountered fixed node (highest z) wins.
    for i = #fixed_nodes, 1, -1 do
        local fix_chain = {}
        local fix_hit = self:_hit_walk_subtree(fixed_nodes[i], mx, my, fix_chain)
        if fix_hit ~= 0 then
            -- Fixed node hit overrides the normal tree hit
            chain = fix_chain
            hit = fix_hit
            break
        end
    end

    self.hover_chain = chain
    return hit
end

--- Collect all position:fixed nodes in the tree (full traversal).
--- Matches paint_tree's collection which is independent of cursor position.
---@param nid number  root node
---@param out table   array to append fixed node ids to
function ES:_collect_fixed(nid, out)
    local ns = self.ns
    local comp = ns.computed[nid]
    if comp then
        if comp.display == "none" then return end
    end
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        local c_comp = ns.computed[cid]
        local c_pos = c_comp and c_comp.position or "static"
        if c_pos == "fixed" then
            out[#out + 1] = cid
        else
            self:_collect_fixed(cid, out)
        end
        cid = ns.next_sibling[cid] or 0
    end
end

--- Recursive hit-walk.  Check if cursor is inside this node's
--- layout box, then check children in reverse order (last child
--- first = highest z).  Returns the deepest hit node id, or 0.
--- When skip_fixed is true, position:fixed children are skipped
--- (they are tested separately at the top level via _collect_fixed).
---@param nid   number  node to test
---@param mx    number  mouse x
---@param my    number  mouse y
---@param ox    number  x offset
---@param oy    number  y offset
---@param chain table   ancestor chain (built up on hit)
---@param skip_fixed boolean|nil  skip position:fixed children
---@return number  hit node id, or 0
function ES:_hit_walk(nid, mx, my, ox, oy, chain, skip_fixed)
    local ns = self.ns
    local lay = ns.layout[nid]
    if not lay then return 0 end

    local comp = ns.computed[nid]
    -- Skip invisible or display:none nodes
    if comp then
        if comp.visibility == "hidden" then return 0 end
        if comp.display == "none" then return 0 end
        -- pointer-events: none → skip entire subtree
        if comp.pointer_events == "none" then return 0 end
    end

    local nx = lay.x + ox
    local ny = lay.y + oy
    local nw = lay.w
    local nh = lay.h

    -- Apply inverse transform for hit testing
    local hit_mx, hit_my = mx, my
    if comp and comp.transform then
        local origin_x = nw / 2
        local origin_y = nh / 2
        if comp.transform_origin then
            local to = comp.transform_origin
            if type(to) == "table" then
                origin_x = to[1] or origin_x
                origin_y = to[2] or origin_y
            end
        end
        local dx, dy, sx, sy, matrix = Transform.resolve(comp.transform, origin_x, origin_y)
        if matrix or dx ~= 0 or dy ~= 0 or sx ~= 1 or sy ~= 1 then
            hit_mx, hit_my = Transform.inverse(mx, my, nx, ny, dx, dy, sx, sy, matrix)
        end
    end

    -- Check if cursor is inside this node's box
    local inside = hit_mx >= nx and hit_mx < nx + nw
                   and hit_my >= ny and hit_my < ny + nh

    if not inside then return 0 end

    -- Clip-path: exact shape hit test (circle, polygon, etc.)
    if comp and comp.clip_path then
        local ok, ClipPath = pcall(require, "core/paint/clip_path")
        if ok and ClipPath and ClipPath.hit_test then
            local parsed = ClipPath.parse(comp.clip_path)
            if parsed and not ClipPath.hit_test(parsed, lay, hit_mx - ox, hit_my - oy) then
                return 0
            end
        end
    end

    -- Collect children in CSS stacking order (matching paint order).
    -- Walk in reverse stacking order (highest z-index first = front to back).
    -- Groups: 1. positioned z>=0 (desc), 2. non-positioned+auto (reverse DOM), 3. positioned z<0 (desc)
    local neg_z   = {}
    local non_pos = {}
    local pos_z   = {}
    local neg_n, np_n, pz_n = 0, 0, 0
    local dom_idx = 0
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        dom_idx = dom_idx + 1
        local c_comp = ns.computed[cid]
        local c_pos = c_comp and c_comp.position or "static"
        -- Skip fixed children (tested at top level, like paint_tree)
        if c_pos == "fixed" and skip_fixed then
            -- nop: handled by _collect_fixed + _hit_walk_subtree
        elseif c_pos == "relative" or c_pos == "absolute" or c_pos == "sticky" or c_pos == "fixed" then
            local zi = c_comp and c_comp.z_index
            if zi == "auto" or zi == nil then
                np_n = np_n + 1
                non_pos[np_n] = cid
            elseif type(zi) == "number" and zi < 0 then
                neg_n = neg_n + 1
                neg_z[neg_n] = { cid, zi, dom_idx }
            else
                local z_num = (type(zi) == "number") and zi or 0
                pz_n = pz_n + 1
                pos_z[pz_n] = { cid, z_num, dom_idx }
            end
        else
            np_n = np_n + 1
            non_pos[np_n] = cid
        end
        cid = ns.next_sibling[cid] or 0
    end
    -- Sort by z-index (ascending); we'll walk in reverse
    if neg_n > 1 then
        table.sort(neg_z, function(a, b)
            if a[2] ~= b[2] then return a[2] < b[2] end
            return a[3] < b[3]
        end)
    end
    if pz_n > 1 then
        table.sort(pos_z, function(a, b)
            if a[2] ~= b[2] then return a[2] < b[2] end
            return a[3] < b[3]
        end)
    end
    -- Build flat children array in paint order (back to front):
    -- neg_z ascending, non_pos DOM order, pos_z ascending
    local children = {}
    local cn = 0
    for i = 1, neg_n do cn = cn + 1; children[cn] = neg_z[i][1] end
    for i = 1, np_n  do cn = cn + 1; children[cn] = non_pos[i] end
    for i = 1, pz_n  do cn = cn + 1; children[cn] = pos_z[i][1] end

    -- Determine if this node clips its children (overflow != visible)
    -- Root node defaults to overflow_y:auto (like Chrome's <html>)
    local clips_children = false
    if comp then
        local is_root_ev = (not ns.parent[nid]) or (ns.parent[nid] == 0)
        local ov_x = comp.overflow_x or "visible"
        local ov_y = comp.overflow_y or (is_root_ev and "auto" or "visible")
        clips_children = (ov_x ~= "visible") or (ov_y ~= "visible")
    end

    -- If this node clips, check cursor is within the padding box
    -- before testing children. Children outside the padding box
    -- are visually hidden and should not be hittable.
    if clips_children and cn > 0 then
        local clip_x = (lay.pad_x or lay.content_x) + ox
        local clip_y = (lay.pad_y or lay.content_y) + oy
        local clip_w = lay.pad_w or lay.content_w
        local clip_h = lay.pad_h or lay.content_h
        if mx < clip_x or mx >= clip_x + clip_w or my < clip_y or my >= clip_y + clip_h then
            -- Cursor is inside this node but outside its content area
            -- (e.g., on the scrollbar or border). Don't hit children.
            chain[#chain + 1] = nid
            return nid
        end
    end

    -- Walk children from last to first (front to back)
    for i = cn, 1, -1 do
        local child_hit = self:_hit_walk(children[i], mx, my, ox, oy, chain, skip_fixed)
        if child_hit ~= 0 then
            chain[#chain + 1] = nid
            return child_hit
        end
    end

    -- No child hit, but we're inside this node
    chain[#chain + 1] = nid  -- self is the deepest hit
    return nid
end

--- Hit-walk a subtree without parent bounds checks (for deferred fixed nodes).
--- Fixed nodes use absolute viewport coordinates, so ox/oy = 0.
---@param nid   number  root of subtree to test
---@param mx    number  mouse x
---@param my    number  mouse y
---@param chain table   ancestor chain (built up on hit)
---@return number  hit node id, or 0
function ES:_hit_walk_subtree(nid, mx, my, chain)
    return self:_hit_walk(nid, mx, my, 0, 0, chain, nil)
end

------------------------------------------------------------
-- Pointer event dispatch
------------------------------------------------------------

--- Compare current hover_chain with _prev_hover for
--- enter/leave events.  Update pseudo.hover and pseudo.active
--- states.  Mark nodes STYLE_DIRTY when pseudo states change.
--- On click: set focus, bubble onClick actions, call
--- component click handlers (checkbox).
---@param input_state table  InputState instance
function ES:dispatch_pointer_events(input_state)
    local ns = self.ns
    local curr = self.hover_chain
    local prev = self._prev_hover
    self.pseudo_changed = false

    -- Build lookup sets before any enter/leave logic uses them.
    local curr_set = {}
    for i = 1, #curr do
        curr_set[curr[i]] = true
    end
    local prev_set = {}
    for i = 1, #prev do
        prev_set[prev[i]] = true
    end

    -- Helper: bubble an event-attribute action up the hover chain.  Stops
    -- at the first handler that returned a truthy "stop" value, or at the
    -- first disabled ancestor.  This is the minimal "event bubbling"
    -- semantics needed to support mousedown/mouseup/mouseenter/mouseleave/
    -- wheel/dblclick handlers in addition to the existing onClick.
    local function fire_event_bubble(chain, camel, lower, evt_obj)
        for ci = 1, #chain do
            local nid = chain[ci]
            local p = ns.pseudo[nid]
            if p and p.disabled then break end
            local at = ns.attrs[nid]
            local aid = at and (at[camel] or at[lower])
            if aid then
                local h = self._action_handlers[aid]
                if h then
                    local ok, ret = pcall(h, nid, aid, evt_obj)
                    if not ok and ns._platform and ns._platform.log_error then
                        ns._platform:log_error("[events] " .. camel .. " handler '"
                            .. tostring(aid) .. "' failed: " .. tostring(ret))
                    end
                end
                if evt_obj and evt_obj._stopped then break end
                -- First handler wins by default (matches existing onClick behavior).
                if not evt_obj then break end
            end
        end
    end

    local function new_event(type_, x, y, deltaY)
        local ev = { type = type_, x = x, y = y, deltaY = deltaY,
                     _stopped = false, _default_prevented = false }
        function ev:stopPropagation() self._stopped = true end
        function ev:preventDefault() self._default_prevented = true end
        return ev
    end

    local function platform_time()
        local platform = ns._platform
        if platform and platform.time then return platform:time() end
        return 0
    end

    -- Hover enter/leave events (fired when a node's hover state changes).
    -- mouseenter/leave do NOT bubble (per DOM spec) -" only sent to the node
    -- whose hover state just changed.
    for i = 1, #curr do
        local nid = curr[i]
        if not prev_set[nid] then
            local at = ns.attrs[nid]
            local aid = at and (at.onMouseEnter or at.onmouseenter)
            if aid then
                local h = self._action_handlers[aid]
                if h then pcall(h, nid, aid, new_event("mouseenter", 0, 0, 0)) end
            end
        end
    end
    for i = 1, #prev do
        local nid = prev[i]
        if not curr_set[nid] then
            local at = ns.attrs[nid]
            local aid = at and (at.onMouseLeave or at.onmouseleave)
            if aid then
                local h = self._action_handlers[aid]
                if h then pcall(h, nid, aid, new_event("mouseleave", 0, 0, 0)) end
            end
        end
    end

    -- mousedown / mouseup / wheel (bubble through current chain).
    local mx_ev = input_state.cursor_x or 0
    local my_ev = input_state.cursor_y or 0
    local mouse_clicked = input_state.is_mouse_clicked and input_state:is_mouse_clicked() or false
    local mouse_down = input_state.is_mouse_down and input_state:is_mouse_down() or false
    local mouse_released = input_state.is_mouse_released and input_state:is_mouse_released() or false
    if mouse_clicked and #curr > 0 then
        fire_event_bubble(curr, "onMouseDown", "onmousedown",
            new_event("mousedown", mx_ev, my_ev, 0))
    end
    if mouse_released and #curr > 0 then
        fire_event_bubble(curr, "onMouseUp", "onmouseup",
            new_event("mouseup", mx_ev, my_ev, 0))
    end
    if input_state.wheel and input_state.wheel ~= 0 and #curr > 0 then
        fire_event_bubble(curr, "onWheel", "onwheel",
            new_event("wheel", mx_ev, my_ev, input_state.wheel))
    end

    -- Double-click detection: two clicks on the same target within 500ms.
    if mouse_clicked and #curr > 0 then
        local now = platform_time()
        local target = curr[1]
        if self._last_click_target == target
           and (now - (self._last_click_time or 0)) <= 0.5 then
            fire_event_bubble(curr, "onDblClick", "ondblclick",
                new_event("dblclick", mx_ev, my_ev, 0))
            self._last_click_target = 0  -- reset so triple-click doesn't re-fire
        else
            self._last_click_target = target
            self._last_click_time = now
        end
    end

    -- Modal-dialog click blocking.  When any open `<dialog modal>` exists,
    -- a click whose hit chain does NOT include the modal subtree must be
    -- consumed (the backdrop closes the dialog via DialogComp.update -" but
    -- the click must NOT also trigger onClicks / form submits / focus
    -- changes on the underlying tree).  We compute this once here so the
    -- click section below can short-circuit.
    local modal_block_click = false
    if ns._dialogs then
        for dlg_nid in pairs(ns._dialogs) do
            local attrs = ns.attrs[dlg_nid]
            if attrs and attrs.open ~= nil and attrs.modal ~= nil then
                -- Is any node in the hover chain a descendant of (or equal to)
                -- the modal?  Walk from each chain entry up looking for dlg_nid.
                local inside = false
                for i = 1, #curr do
                    local cur = curr[i]
                    while cur and cur ~= 0 do
                        if cur == dlg_nid then inside = true; break end
                        cur = ns.parent[cur]
                    end
                    if inside then break end
                end
                if not inside then
                    modal_block_click = true
                    break
                end
            end
        end
    end

    -- Leave events: nodes in prev but not in curr
    for i = 1, #prev do
        local nid = prev[i]
        if not curr_set[nid] then
            if ns.pseudo[nid] then
                ns.pseudo[nid].hover = false
                ns.pseudo[nid].active = false
                ns:mark_dirty(nid, ns.STYLE_DIRTY)
                self.pseudo_changed = true
            end
        end
    end

    -- Enter events: nodes in curr but not in prev
    for i = 1, #curr do
        local nid = curr[i]
        if not prev_set[nid] then
            if ns.pseudo[nid] then
                ns.pseudo[nid].hover = true
                ns:mark_dirty(nid, ns.STYLE_DIRTY)
                self.pseudo_changed = true
            end
        end
    end

    -- Active state: set on mouse down on every ancestor up to the root.
    -- CSS §6.6.1.3 :active matches the originating element of the pointer
    -- press AND each of its ancestors (mirroring :hover propagation), so
    -- a rule like `button:active .icon { ... }` works.  We push the bit
    -- onto every node in `curr`, not just the deepest hit.
    if #curr > 0 and mouse_clicked then
        for i = 1, #curr do
            local nid = curr[i]
            local p = ns.pseudo[nid]
            if p and not p.active then
                p.active = true
                ns:mark_dirty(nid, ns.STYLE_DIRTY)
                self.pseudo_changed = true
            end
        end
    end

    -- Tooltip tracking: find the deepest hover node (or ancestor) with a
    -- `title` attribute.  Reset the start timer when the target changes.
    local tip_nid = 0
    for i = 1, #curr do
        local nid = curr[i]
        local attrs = ns.attrs[nid]
        if attrs and attrs.title and attrs.title ~= "" then
            tip_nid = nid
            break
        end
    end
    if tip_nid ~= self._tip_target_nid then
        self._tip_target_nid = tip_nid
        self._tip_start_time = platform_time()
        self._tip_visible = false
    end
    if not mouse_down then
        -- Mouse is not held: clear active on any active nodes
        for i = 1, #prev do
            local nid = prev[i]
            if ns.pseudo[nid] and ns.pseudo[nid].active then
                ns.pseudo[nid].active = false
                ns:mark_dirty(nid, ns.STYLE_DIRTY)
                self.pseudo_changed = true
            end
        end
        for i = 1, #curr do
            local nid = curr[i]
            if ns.pseudo[nid] and ns.pseudo[nid].active then
                ns.pseudo[nid].active = false
                ns:mark_dirty(nid, ns.STYLE_DIRTY)
                self.pseudo_changed = true
            end
        end
    end

    local labelable_tags = {
        input = true, textarea = true, button = true, select = true,
        slider = true, checkbox = true, switch = true, radio = true,
    }

    local function root_of(nid)
        local cur = nid
        while cur and cur ~= 0 do
            local p = ns.parent[cur]
            if not p or p == 0 then return cur end
            cur = p
        end
        return nid
    end

    local function first_labelable_descendant(label_nid)
        local found = nil
        ns:walk_depth_first(label_nid, function(nid)
            if found or nid == label_nid then return end
            local tag_str = ns._st:get(ns.tag[nid])
            if labelable_tags[tag_str] then found = nid end
        end)
        return found
    end

    local function control_for_label(label_nid)
        local attrs = ns.attrs[label_nid]
        local for_id = attrs and (attrs["for"] or attrs.htmlFor)
        if for_id ~= nil and tostring(for_id) ~= "" then
            local root_id = root_of(label_nid)
            local found = nil
            ns:walk_depth_first(root_id, function(nid)
                if found then return end
                local tag_str = ns._st:get(ns.tag[nid])
                local id_str = ns._st:get(ns.id_str[nid])
                if labelable_tags[tag_str] and id_str == tostring(for_id) then
                    found = nid
                end
            end)
            if found then return found end
        end
        return first_labelable_descendant(label_nid)
    end

    local function label_target_from_chain(chain)
        for i = 1, #chain do
            local nid = chain[i]
            local tag_str = ns._st:get(ns.tag[nid])
            if tag_str == "label" then
                return control_for_label(nid)
            end
        end
        return nil
    end

    local function interactive_target_from_chain(chain)
        local focusable_tags = {
            input = true, textarea = true, button = true, select = true,
            slider = true, checkbox = true, switch = true, radio = true,
        }
        for i = 1, #chain do
            local nid = chain[i]
            local tag_str = ns._st:get(ns.tag[nid])
            local attrs = ns.attrs[nid]
            if focusable_tags[tag_str]
               or (tag_str == "a" and attrs and attrs.href ~= nil)
               or (attrs and attrs.tabindex ~= nil) then
                return nid
            end
            if tag_str == "label" then
                local labeled = control_for_label(nid)
                if labeled then return labeled end
            end
        end
        return chain[1]
    end

    -- Mouse PRESS edge: Chrome sets focus immediately on mousedown but
    -- defers the `click` event until mouseup on a matching target.  Record
    -- the press chain here so the release branch below can match it.
    if mouse_clicked and #curr > 0 and not modal_block_click then
        local focus_target = interactive_target_from_chain(curr)
        local target = curr[1]

        -- Check user-select: none → prevent text selection on this element
        local target_comp = ns.computed[focus_target] or ns.computed[target]
        local target_user_select = target_comp and target_comp.user_select
        if target_user_select == "none" then
            local tp = ns.pseudo[focus_target]
            if tp then tp._user_select_none = true end
        else
            local tp = ns.pseudo[focus_target]
            if tp then tp._user_select_none = false end
        end

        local target_pseudo = ns.pseudo[focus_target]
        local target_disabled = target_pseudo and target_pseudo.disabled
        if not target_disabled then
            self:_set_focus(focus_target, false)
        end

        -- Snapshot the press chain for mouseup matching.
        self._mousedown_target = target
        self._mousedown_chain  = {}
        for i = 1, #curr do self._mousedown_chain[i] = curr[i] end
    end

    -- Mouse RELEASE edge: fire `click` only if the deepest mousedown target
    -- is still present in the current hover chain.  Click target is the
    -- deepest common ancestor of mousedown and mouseup chains (Chrome §
    -- UIEvents).  Dragging away from the press target cancels the click.
    local click_chain = nil
    if mouse_released and self._mousedown_target ~= 0 and #curr > 0 and not modal_block_click then
        local md_set = {}
        for i = 1, #self._mousedown_chain do md_set[self._mousedown_chain[i]] = true end
        for i = 1, #curr do
            if md_set[curr[i]] then
                click_chain = {}
                for j = i, #curr do click_chain[#click_chain + 1] = curr[j] end
                break
            end
        end
    end
    if mouse_released then
        self._mousedown_target = 0
        self._mousedown_chain  = {}
    end

    if click_chain then
        -- chain[1] = deepest hit node, chain[#chain] = root
        local target = click_chain[1]
        local focus_target = interactive_target_from_chain(click_chain)
        local label_activation_target = label_target_from_chain(click_chain)
        local curr = click_chain  -- shadow `curr` so existing code below uses the click chain

        local function activate_control(nid)
            local node_pseudo = ns.pseudo[nid]
            if node_pseudo and node_pseudo.disabled then return false end
            local tag_id = ns.tag[nid]
            local tag_str = ns._st:get(tag_id)
            local role = control_role(ns, nid)
            if role == "checkbox" or role == "switch" then
                local pseudo = ns.pseudo[nid]
                if pseudo then
                    pseudo.checked = not pseudo.checked
                    ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.PAINT_DIRTY)
                end
                local attrs = ns.attrs[nid]
                local onchange_id = attrs and (attrs.onChange or attrs.onchange)
                if onchange_id then
                    local handler = self._action_handlers[onchange_id]
                    if handler then pcall(handler, nid, onchange_id) end
                end
                return true
            elseif role == "radio" then
                Radio.on_click(ns, nid, self)
                return true
            elseif labelable_tags[tag_str] then
                self:_set_focus(nid, false)
                return true
            elseif tag_str == "a" then
                local attrs = ns.attrs[nid]
                if attrs and attrs.href then
                    local handler = self._action_handlers["_link_click"]
                    if handler then pcall(handler, nid, attrs.href) end
                end
                return true
            end
            return false
        end

        local function run_click_activation(chain)
            local default_kind, default_nid = nil, nil
            for i = 1, #chain do
                local nid = chain[i]
                local node_pseudo = ns.pseudo[nid]
                if node_pseudo and node_pseudo.disabled then
                    break
                end
                local attrs = ns.attrs[nid]
                local tag_s = ns._st:get(ns.tag[nid])
                if not default_kind and (tag_s == "button" or tag_s == "input") then
                    local btype = tostring((attrs or {}).type or ""):lower()
                    if (tag_s == "button" and (btype == "" or btype == "submit"))
                       or (tag_s == "input" and btype == "submit") then
                        default_kind, default_nid = "submit", nid
                    elseif btype == "reset" then
                        default_kind, default_nid = "reset", nid
                    end
                end

                local action_id = attrs and (attrs.onClick or attrs.onclick)
                if action_id then
                    local handler = self._action_handlers[action_id]
                    if handler then
                        local ok, err = pcall(handler, nid, action_id)
                        if not ok and ns._platform and ns._platform.log_error then
                            ns._platform:log_error(
                                "[events] onClick handler '" .. tostring(action_id) .. "' failed: " .. tostring(err))
                        end
                    end
                    break
                end
            end

            if default_kind == "submit" then
                local form = self:_find_form_ancestor(default_nid)
                if form then self:_fire_form_submit(form) end
            elseif default_kind == "reset" then
                local form = self:_find_form_ancestor(default_nid)
                if form then self:_reset_form(form) end
            end

            local handled = false
            for i = 1, #chain do
                local nid = chain[i]
                local node_pseudo = ns.pseudo[nid]
                if node_pseudo and node_pseudo.disabled then
                    break
                end
                if activate_control(nid) then
                    handled = true
                    break
                end
            end
            return handled
        end

        local function chain_from_node(nid)
            local chain = {}
            local cur = nid
            while cur and cur ~= 0 do
                chain[#chain + 1] = cur
                cur = ns.parent[cur]
            end
            return chain
        end

        local component_handled = run_click_activation(curr)
        if (not component_handled) and label_activation_target then
            run_click_activation(chain_from_node(label_activation_target))
        end
    end

    -- Resolve CSS cursor from hover chain (deepest node with explicit cursor wins)
    self._cursor = "default"
    for i = 1, #curr do
        local comp = ns.computed[curr[i]]
        if comp and comp.cursor and comp.cursor ~= "default" then
            self._cursor = comp.cursor
            break
        end
    end

    --------------------------------------------------------
    -- Text selection (character-level, zero-cost when idle)
    --------------------------------------------------------
    do
        local mouse_clicked = input_state:is_mouse_clicked()
        local mouse_down    = input_state:is_mouse_down()

        -- Fast path: skip everything when selection is not active
        if not mouse_clicked and not (mouse_down and self._sel_dragging) then
            if self._sel_dragging and not mouse_down then
                self._sel_dragging = false
                self._sel_drag_started = false
                _sel_invalidate_dfs()
            end
        elseif mouse_clicked and #curr > 0 then
            -- Click: clear previous selection + record anchor
            _sel_clear(ns, self)
            _sel_invalidate_dfs()
            local anchor = _sel_find_text(ns, curr)
            self._sel_anchor_nid  = anchor
            self._sel_anchor_char = (anchor ~= 0) and _sel_px_to_char(ns, anchor, input_state.cursor_x) or 0
            self._sel_dragging    = (anchor ~= 0)
            self._sel_drag_started = false
            self._sel_click_mx = input_state.cursor_x
            self._sel_click_my = input_state.cursor_y
            -- Cache previous cursor for change detection
            self._sel_prev_nid  = 0
            self._sel_prev_char = 0

        elseif mouse_down and self._sel_dragging and self._sel_anchor_nid ~= 0 then
            -- Drag threshold
            if not self._sel_drag_started then
                local dx = (input_state.cursor_x or 0) - (self._sel_click_mx or 0)
                local dy = (input_state.cursor_y or 0) - (self._sel_click_my or 0)
                if dx * dx + dy * dy >= 9 then
                    self._sel_drag_started = true
                end
            end

            if self._sel_drag_started then
                local cur_nid = _sel_find_text(ns, curr)
                if cur_nid ~= 0 then
                    local cur_char = _sel_px_to_char(ns, cur_nid, input_state.cursor_x)

                    -- Skip rebuild if nothing changed since last frame
                    if cur_nid == self._sel_prev_nid and cur_char == self._sel_prev_char then
                        -- no-op: selection unchanged
                    else
                        self._sel_prev_nid  = cur_nid
                        self._sel_prev_char = cur_char

                        _sel_clear(ns, self)
                        local new_nodes = {}

                        if cur_nid == self._sel_anchor_nid then
                            local lo, hi = self._sel_anchor_char, cur_char
                            if lo > hi then lo, hi = hi, lo end
                            if lo ~= hi then
                                _sel_mark(ns, cur_nid, lo, hi, new_nodes)
                            end
                        else
                            local ca = _sel_common_ancestor(ns, self._sel_anchor_nid, cur_nid)
                            if ca ~= 0 then
                                local all_text = _sel_text_nodes(ns, ca)
                                local ai, ci
                                for idx = 1, #all_text do
                                    if all_text[idx] == self._sel_anchor_nid then ai = idx end
                                    if all_text[idx] == cur_nid then ci = idx end
                                end
                                if ai and ci then
                                    local lo_idx = ai < ci and ai or ci
                                    local hi_idx = ai < ci and ci or ai
                                    local first_nid  = all_text[lo_idx]
                                    local last_nid   = all_text[hi_idx]
                                    local first_char = (first_nid == self._sel_anchor_nid) and self._sel_anchor_char or cur_char
                                    local last_char  = (last_nid == self._sel_anchor_nid) and self._sel_anchor_char or cur_char

                                    _sel_mark(ns, first_nid, first_char, #(ns.text_content[first_nid] or ""), new_nodes)
                                    for idx = lo_idx + 1, hi_idx - 1 do
                                        _sel_mark(ns, all_text[idx], 0, #(ns.text_content[all_text[idx]] or ""), new_nodes)
                                    end
                                    if last_nid ~= first_nid then
                                        _sel_mark(ns, last_nid, 0, last_char, new_nodes)
                                    end
                                end
                            end
                        end
                        self._sel_nodes = new_nodes
                        self.pseudo_changed = true
                    end
                end
            end
        end
    end
end

--- Get the resolved CSS cursor for the current hover target.
---@return string  cursor name (e.g. "pointer", "text", "default")
function ES:get_cursor()
    return self._cursor or "default"
end

--- Fire an action by id (public API for components).
---@param action_id string  action identifier
---@param nid       number  source node id
function ES:fire_action(action_id, nid)
    local handler = self._action_handlers[action_id]
    if handler then
        pcall(handler, nid, action_id)
    end
end

------------------------------------------------------------
-- Focus helpers
------------------------------------------------------------

--- Internal: set focus to a node, clearing previous focus.
--- Manages focus, focus_visible, and focus_within pseudo states.
---@param nid         number   node to focus (0 to clear)
---@param via_keyboard boolean  true if focus was set via Tab key
function ES:_set_focus(nid, via_keyboard)
    local ns = self.ns
    local old_focus = self.focus_id
    local function fire_focus_event(target_nid, camel, lower, event_type)
        if target_nid == 0 then return end
        local attrs = ns.attrs[target_nid]
        local action_id = attrs and (attrs[camel] or attrs[lower])
        if action_id then
            local handler = self._action_handlers[action_id]
            if handler then
                pcall(handler, target_nid, action_id, { type = event_type, target = target_nid })
            end
        end
    end

    -- Clear old focus
    if old_focus ~= 0 and old_focus ~= nid then
        local p = ns.pseudo[old_focus]
        if p then
            p.focus = false
            p.focus_visible = false
            ns:mark_dirty(old_focus, ns.STYLE_DIRTY)
        end
        self.pseudo_changed = true
        fire_focus_event(old_focus, "onBlur", "onblur", "blur")
    end

    -- Set new focus FIRST (before ancestor walking, so focus is set even if walking errors)
    self.focus_id = nid

    if nid ~= 0 then
        local p = ns.pseudo[nid]
        if p then
            p.focus = true
            local tag_str = ns._st:get(ns.tag[nid])
            local is_text_input = (tag_str == "input" or tag_str == "textarea")
            p.focus_visible = via_keyboard or is_text_input
            ns:mark_dirty(nid, ns.STYLE_DIRTY)
        end
        self.pseudo_changed = true
        if old_focus ~= nid then
            fire_focus_event(nid, "onFocus", "onfocus", "focus")
        end
    end

    -- Focus-within: clear old chain, set new chain (non-critical, wrapped in pcall)
    pcall(function()
        if old_focus ~= 0 and old_focus ~= nid then
            local anc = old_focus
            while anc and anc ~= 0 do
                local ap = ns.pseudo[anc]
                if ap then ap.focus_within = false end
                anc = ns.parent[anc]
            end
        end
        if nid ~= 0 then
            local anc = nid
            while anc and anc ~= 0 do
                local ap = ns.pseudo[anc]
                if ap then ap.focus_within = true end
                anc = ns.parent[anc]
            end
        end
    end)
end

--- Collect all focusable nodes in DOM order, honoring tabindex.
--- Sort order: positive tabindex first (ascending), then DOM-order with
--- tabindex=0 or no tabindex; tabindex=-1 excluded entirely.
---@param root_id number
---@return table  array of focusable nids
function ES:_collect_focusable(root_id)
    local ns = self.ns
    local natural = {}       -- tabindex = 0 or unset
    local indexed = {}       -- {nid, tabindex} for positive values
    local focusable_tags = {
        input = true, textarea = true, button = true, select = true,
        slider = true, checkbox = true, switch = true, radio = true,
    }
    ns:walk_depth_first(root_id, function(nid)
        local tag_str = ns._st:get(ns.tag[nid])
        local attrs = ns.attrs[nid]
        local ti = attrs and attrs.tabindex
        local ti_num = ti and tonumber(ti)

        local is_natural = focusable_tags[tag_str]
            or (tag_str == "a" and attrs and attrs.href ~= nil)
        -- tabindex explicitly -1 removes focusability even for naturally-focusable
        if ti_num and ti_num < 0 then return end

        -- Explicit positive tabindex makes any element focusable, and changes order
        if ti_num and ti_num > 0 then
            local p = ns.pseudo[nid]
            if not (p and p.disabled) then
                indexed[#indexed + 1] = { nid = nid, ti = ti_num, order = #natural + #indexed }
            end
            return
        end

        -- tabindex=0 or unset: use DOM order if naturally focusable or tabindex=0
        if is_natural or ti_num == 0 then
            local p = ns.pseudo[nid]
            if not (p and p.disabled) then
                natural[#natural + 1] = nid
            end
        end
    end)

    -- Stable sort indexed by (ti asc, order asc)
    table.sort(indexed, function(a, b)
        if a.ti ~= b.ti then return a.ti < b.ti end
        return a.order < b.order
    end)

    local result = {}
    for i = 1, #indexed do result[#result + 1] = indexed[i].nid end
    for i = 1, #natural do result[#result + 1] = natural[i] end
    return result
end

------------------------------------------------------------
-- Focus event dispatch (Tab navigation)
------------------------------------------------------------

--- Tab navigation: cycle focus among focusable elements.
---@param input_state table  InputState instance
---@param root_id     number root node for collecting focusable
function ES:dispatch_focus_events(input_state, root_id)
    if not root_id or root_id == 0 then return end
    -- Check for Tab key edge (just pressed this frame)
    local tab_pressed = input_state:is_key_edge(9)  -- Tab = VK_TAB = 9
    if not tab_pressed then return end

    local shift = input_state:is_key_pressed(0x10) or input_state:is_key_pressed(0xA0) or input_state:is_key_pressed(0xA1)  -- VK_SHIFT / VK_LSHIFT / VK_RSHIFT
    local focusable = self:_collect_focusable(root_id)
    if #focusable == 0 then return end

    -- Find current index
    local cur_idx = 0
    for i = 1, #focusable do
        if focusable[i] == self.focus_id then cur_idx = i; break end
    end

    local next_idx
    if shift then
        next_idx = cur_idx > 1 and (cur_idx - 1) or #focusable
    else
        next_idx = cur_idx < #focusable and (cur_idx + 1) or 1
    end

    self:_set_focus(focusable[next_idx], true)
end

--- Find the nearest ancestor <form> of a node (or nil).
function ES:_find_form_ancestor(nid)
    local ns = self.ns
    local cur = ns.parent[nid] or 0
    while cur ~= 0 do
        local tag = ns._st:get(ns.tag[cur])
        if tag == "form" then return cur end
        cur = ns.parent[cur] or 0
    end
    return nil
end

--- Fire the `onSubmit` action on a form node, if any.
function ES:_fire_form_submit(form_nid)
    if not form_nid then return end
    local attrs = self.ns.attrs[form_nid]
    local action_id = attrs and (attrs.onSubmit or attrs.onsubmit)
    if not action_id then return end
    local h = self._action_handlers[action_id]
    if h then pcall(h, form_nid, action_id) end
end

--- Fire the `onReset` action on a form node, if any.
function ES:_fire_form_reset(form_nid)
    if not form_nid then return end
    local attrs = self.ns.attrs[form_nid]
    local action_id = attrs and (attrs.onReset or attrs.onreset)
    if not action_id then return end
    local h = self._action_handlers[action_id]
    if h then pcall(h, form_nid, action_id) end
end

--- Reset form controls to their mount-time default values.
function ES:_reset_form(form_nid)
    if not form_nid then return end
    self:_fire_form_reset(form_nid)
    local ns = self.ns
    ns:walk_depth_first(form_nid, function(nid)
        local tag = ns._st:get(ns.tag[nid])
        local attrs = ns.attrs[nid] or {}
        if tag == "input" then
            local input_type = tostring(attrs.type or "text"):lower()
            if input_type == "checkbox" or input_type == "radio" then
                local p = ns.pseudo[nid]
                if p then p.checked = attrs._default_checked == true end
                ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.PAINT_DIRTY)
            elseif input_type == "range" or input_type == "color" then
                attrs.value = attrs._default_value
                ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
            elseif input_type ~= "button" and input_type ~= "submit" and input_type ~= "reset" then
                local value = tostring(attrs._default_value or "")
                ns.text_content[nid] = value
                attrs.value = value
                ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
            end
        elseif tag == "checkbox" or tag == "radio" or tag == "switch" then
            -- Standalone control tags participate in form reset just like
            -- their `<input type=…>` equivalents.  Their default-checked
            -- state is recorded by apply_checked_attr at mount time.
            local p = ns.pseudo[nid]
            if p then p.checked = attrs._default_checked == true end
            ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.PAINT_DIRTY)
        elseif tag == "slider" then
            attrs.value = attrs._default_value
            ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        elseif tag == "textarea" then
            ns.text_content[nid] = tostring(attrs._default_value or "")
            ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        elseif tag == "select" then
            local options = attrs.options or {}
            local idx = attrs._default_selected_index or 1
            if idx < 1 then idx = 1 end
            if idx > #options then idx = #options end
            attrs.selected_index = idx
            ns.text_content[nid] = options[idx] or ""
            local comp = ns._components and ns._components[nid]
            if comp and comp.inst then
                comp.inst.selected_index = idx
                comp.inst.open = false
            end
            ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        end
    end)
end

--- Dispatch keyboard activation for the currently focused element.
--- Fires:
---   Space      on focused button/checkbox/radio  -" toggles/clicks
---   Enter      on focused button/a              -" fires click (form submit
---                                                  for input-type=submit)
---   Enter      on focused text input inside a   -" submits the form
---              <form>
--- Textarea still consumes Enter natively (newline).
---
---@param input_state table  InputState instance
function ES:dispatch_keyboard_activation(input_state)
    local nid = self.focus_id
    if not nid or nid == 0 then return end

    local ns = self.ns
    local pseudo = ns.pseudo[nid]
    if pseudo and pseudo.disabled then return end

    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)

    -- Text inputs normally consume keys themselves, but Enter on a text-like
    -- input inside a <form> submits the form (classical HTML behavior).
    if tag_str == "input" then
        local attrs = ns.attrs[nid] or {}
        local it = attrs.type or "text"
        local is_text_like = it == "text" or it == "password" or it == "email"
            or it == "url" or it == "search" or it == "tel" or it == "number"
        if is_text_like then
            if input_state:is_key_edge(0x0D) then
                local form = self:_find_form_ancestor(nid)
                if form then self:_fire_form_submit(form) end
            end
            return
        end
    elseif tag_str == "textarea" then
        return
    end

    local space_pressed = input_state:is_key_edge(0x20)   -- VK_SPACE
    local enter_pressed = input_state:is_key_edge(0x0D)   -- VK_RETURN

    if not space_pressed and not enter_pressed then return end

    -- Mark that this frame produced a keyboard activation so text-input
    -- consumers can choose to suppress the character.
    input_state:consume_text_events()

    local role = control_role(ns, nid)

    if role == "checkbox" or role == "switch" then
        if space_pressed then
            local p = pseudo or {}
            ns.pseudo[nid] = p
            p.checked = not p.checked
            ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.PAINT_DIRTY)
            -- Complex-selector cascade (e.g. `:has(:checked) ~ .label`,
            -- `input:checked + label`) only re-runs when the engine sees
            -- pseudo_changed.  Mouse click sets this; keyboard activation
            -- must do the same or those rules go stale.
            self.pseudo_changed = true
            local attrs = ns.attrs[nid]
            local oid = attrs and (attrs.onChange or attrs.onchange)
            if oid then
                local h = self._action_handlers[oid]
                if h then pcall(h, nid, oid) end
            end
        end
    elseif role == "radio" then
        if space_pressed then
            local Radio = require("core/components/radio")
            pcall(Radio.on_click, ns, nid, self)
            self.pseudo_changed = true
        end
    elseif tag_str == "button" or role == "button" or role == "submit" or role == "reset" then
        if space_pressed or enter_pressed then
            local attrs = ns.attrs[nid] or {}
            local action_id = attrs.onClick or attrs.onclick
            if action_id then
                local h = self._action_handlers[action_id]
                if h then pcall(h, nid, action_id) end
            end
            -- Submit: if inside a form and type=submit (or default), fire onSubmit
            local btype = tostring(attrs.type or ""):lower()
            if tag_str == "button" and (btype == "" or btype == "submit") then
                local form = self:_find_form_ancestor(nid)
                if form then self:_fire_form_submit(form) end
            elseif role == "submit" then
                local form = self:_find_form_ancestor(nid)
                if form then self:_fire_form_submit(form) end
            elseif role == "reset" then
                local form = self:_find_form_ancestor(nid)
                if form then self:_reset_form(form) end
            end
        end
    elseif tag_str == "a" then
        if enter_pressed then
            local attrs = ns.attrs[nid] or {}
            if attrs.href then
                local h = self._action_handlers["_link_click"]
                if h then pcall(h, nid, attrs.href) end
            end
        end
    end
end

--- Paint the title-attribute tooltip if the hover has been stable long enough.
--- Called by the engine once per frame, after the main paint walk.
---@param dl          table    DisplayList
---@param input_state table    InputState (for cursor position)
---@param clip_rect   table|nil  {x, y, w, h} to clamp within
function ES:paint_tooltip(dl, input_state, clip_rect)
    if not self._tip_target_nid or self._tip_target_nid == 0 then return end

    local ns = self.ns
    local attrs = ns.attrs[self._tip_target_nid]
    if not attrs or not attrs.title or attrs.title == "" then return end
    -- Defend against id recycling: if the node we recorded as the tooltip
    -- target is no longer part of the current hover chain, we are about to
    -- paint a tooltip for a node the cursor is not over.  This happens when
    -- the underlying nid was freed and reused for an unrelated element that
    -- happens to also carry a `title` attribute.
    local chain = self.hover_chain
    local still_hovered = false
    for i = 1, #chain do
        if chain[i] == self._tip_target_nid then
            still_hovered = true
            break
        end
    end
    if not still_hovered then
        self._tip_target_nid = 0
        self._tip_visible = false
        return
    end

    -- Require 400ms of stable hover before revealing
    local now = (ns._platform and ns._platform.time and ns._platform:time()) or 0
    if not self._tip_visible then
        if now - self._tip_start_time < 0.4 then return end
        self._tip_visible = true
    end

    local text = tostring(attrs.title)
    local font_size = 11
    local platform = ns._platform
    local text_w = Painters.measure_text(text, font_size, ns._default_font, 400, "normal")
    local pad_x, pad_y = 6, 4
    local tw = text_w + pad_x * 2
    local th = font_size + pad_y * 2

    local mx = input_state.cursor_x or 0
    local my = input_state.cursor_y or 0
    local tx = mx + 14
    local ty = my + 18

    if clip_rect then
        local cx, cy, cw, ch = clip_rect[1], clip_rect[2], clip_rect[3], clip_rect[4]
        if tx + tw > cx + cw then tx = cx + cw - tw - 4 end
        if ty + th > cy + ch then ty = my - th - 4 end
        if tx < cx then tx = cx + 2 end
        if ty < cy then ty = cy + 2 end
    end

    -- Drop shadow
    dl:rect_fill(tx + 1, ty + 2, tw, th, 0, 0, 0, 80, 3)
    -- Body
    dl:rect_fill(tx, ty, tw, th, 38, 42, 55, 235, 3)
    -- Border
    dl:rect_stroke(tx, ty, tw, th, 110, 120, 140, 160, 1, 3)
    -- Text
    Painters.paint_text(dl, text, tx + pad_x, ty + pad_y, font_size,
        235, 240, 250, 255, false, ns._default_font, 400, "normal")
end

return ES



