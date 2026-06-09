------------------------------------------------------------
-- ext_core_astro_ui_lib / core / dom / node_store.lua
-- Structure-of-Arrays DOM node store.
--
-- All node data is stored in parallel arrays indexed by
-- node_id (1-based).  Deleted nodes are recycled via a
-- free list.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local NS = {}
NS.__index = NS

------------------------------------------------------------
-- Node type constants
------------------------------------------------------------
NS.ELEMENT = 1
NS.TEXT    = 2

------------------------------------------------------------
-- Dirty flag constants (powers of 2, handled with modular
-- arithmetic -- NO bitwise ops)
------------------------------------------------------------
NS.STYLE_DIRTY  = 1
NS.LAYOUT_DIRTY = 2
NS.PAINT_DIRTY  = 4

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new NodeStore backed by the given StringTable.
---@param string_table table  StringTable instance
---@return table  NodeStore instance
function NS.new(string_table)
    local self = setmetatable({}, NS)
    self._st = string_table

    -- SoA arrays (parallel, indexed by node id)
    self.tag          = {}   -- interned tag string id
    self.id_str       = {}   -- interned id attribute string id
    self.class_list   = {}   -- table of interned class ids
    self.parent       = {}   -- parent node id (0 = none)
    self.first_child  = {}   -- first child id (0 = none)
    self.last_child   = {}   -- last child id (0 = none)
    self.next_sibling = {}   -- next sibling id (0 = none)
    self.prev_sibling = {}   -- prev sibling id (0 = none)
    self.node_type    = {}   -- ELEMENT or TEXT
    self.text_content = {}   -- text string (for TEXT nodes)
    self.attrs        = {}   -- attribute table (or empty table)
    self.computed     = {}   -- computed style table
    self.layout       = {}   -- layout box table {x,y,w,h,...}
    self.dirty        = {}   -- dirty bit flags
    self.subtree_dirty = {}  -- non-zero if any descendant has dirty flags
    self.pseudo       = {}   -- pseudo-state table (hover, focus, active)
    self.scroll       = {}   -- scroll state table
    self.style_gen    = {}   -- per-node style generation counter (for layout cache)
    self.prev_layout_w = {}  -- previous computed width (for layout stoppage)
    self.prev_layout_h = {}  -- previous computed height (for layout stoppage)
    self.li_index      = {}  -- cached list-item index (1-based, for <li> nodes)

    -- Allocation bookkeeping
    self._next_id = 1
    self._free    = {}       -- stack of recycled node ids
    self._count   = 0        -- live node count
    self._removed_nids = {}  -- buffer of removed nids for transition engine cleanup
    self._dirty_gen = 0      -- increments when hit-test-relevant state changes

    -- Fast-lookup registries (avoid full-tree walks per frame)
    self._checkboxes = {}    -- nid -> true
    self._radios     = {}    -- nid -> true
    self._progress   = {}    -- nid -> true
    self._meters     = {}    -- nid -> true
    self._details    = {}    -- nid -> true
    self._dialogs    = {}    -- nid -> true

    return self
end

------------------------------------------------------------
-- Allocation
------------------------------------------------------------

--- Allocate a fresh (or recycled) node id.
---@return number  node id
function NS:_alloc_id()
    local free_ids = self._free
    local free_count = #free_ids
    if free_count > 0 then
        local node_id = free_ids[free_count]
        free_ids[free_count] = nil
        return node_id
    end
    local node_id = self._next_id
    self._next_id = node_id + 1
    return node_id
end

------------------------------------------------------------
-- Node creation
------------------------------------------------------------

--- Create a new node and return its id.
---@param tag_str   string|nil   tag name (e.g. "div")
---@param id_str    string|nil   id attribute
---@param classes   table|nil    array of class name strings
---@param ntype     number|nil   ELEMENT (1) or TEXT (2), default ELEMENT
---@param text      string|nil   text content (for TEXT nodes)
---@param attr      table|nil    attribute table
---@return number  node id
function NS:create_node(tag_str, id_str, classes, ntype, text, attr)
    local node_id = self:_alloc_id()
    self._count = self._count + 1

    -- Intern strings
    self.tag[node_id]      = self._st:intern(tag_str)
    self.id_str[node_id]   = self._st:intern(id_str)

    -- Intern class list
    local cls = {}
    if classes then
        for i = 1, #classes do
            cls[i] = self._st:intern(classes[i])
        end
    end
    self.class_list[node_id] = cls

    -- Tree links (unlinked)
    self.parent[node_id]       = 0
    self.first_child[node_id]  = 0
    self.last_child[node_id]   = 0
    self.next_sibling[node_id] = 0
    self.prev_sibling[node_id] = 0

    -- Content
    self.node_type[node_id]    = ntype or NS.ELEMENT
    self.text_content[node_id] = text or ""
    self.attrs[node_id]        = attr or {}

    -- Runtime state
    self.computed[node_id] = {}
    self.layout[node_id]   = { x = 0, y = 0, w = 0, h = 0,
                           content_x = 0, content_y = 0,
                           content_w = 0, content_h = 0 }
    self.dirty[node_id]    = 7  -- STYLE_DIRTY + LAYOUT_DIRTY + PAINT_DIRTY
    self.pseudo[node_id]   = { hover = false, focus = false, active = false, disabled = false }
    self.scroll[node_id]   = { x = 0, y = 0 }
    self._dirty_gen = (self._dirty_gen or 0) + 1

    local input_type = nil
    if tag_str == "input" and attr and attr.type ~= nil then
        input_type = tostring(attr.type):lower()
    end

    -- Register checkbox/radio for fast paint lookup
    if tag_str == "checkbox" or (tag_str == "input" and input_type == "checkbox") then
        self._checkboxes[node_id] = true
    elseif tag_str == "radio" or (tag_str == "input" and input_type == "radio") then
        self._radios[node_id] = true
    elseif tag_str == "progress" then
        self._progress[node_id] = true
    elseif tag_str == "meter" then
        self._meters[node_id] = true
    elseif tag_str == "details" then
        self._details[node_id] = true
    elseif tag_str == "dialog" then
        self._dialogs[node_id] = true
    end

    return node_id
end

------------------------------------------------------------
-- Tree manipulation
------------------------------------------------------------

function NS:_would_create_tree_cycle(child_id, parent_id)
    if not child_id or child_id == 0 or not parent_id or parent_id == 0 then
        return false
    end
    if child_id == parent_id then return true end
    local pid = parent_id
    while pid and pid ~= 0 do
        if pid == child_id then return true end
        pid = self.parent[pid]
    end
    return false
end

--- Append child_id as the last child of parent_id.
---@param parent_id number
---@param child_id  number
function NS:append_child(parent_id, child_id)
    if self:_would_create_tree_cycle(child_id, parent_id) then return false end
    -- Unlink child from any previous parent first
    local old_parent = self.parent[child_id]
    if old_parent ~= 0 then
        self:_unlink_from_parent(child_id)
        -- Reindex old parent's list items (sibling order changed)
        if old_parent ~= parent_id then
            self:_reindex_list_items(old_parent)
        end
    end

    self.parent[child_id] = parent_id
    self.prev_sibling[child_id] = self.last_child[parent_id]
    self.next_sibling[child_id] = 0

    local last = self.last_child[parent_id]
    if last ~= 0 then
        self.next_sibling[last] = child_id
    else
        -- First child
        self.first_child[parent_id] = child_id
    end
    self.last_child[parent_id] = child_id
    self:_reindex_list_items(parent_id)
    self._dirty_gen = (self._dirty_gen or 0) + 1
    if parent_id ~= 0 then
        self:mark_dirty(parent_id, NS.LAYOUT_DIRTY + NS.PAINT_DIRTY)
    end
    if old_parent ~= 0 and old_parent ~= parent_id then
        self:mark_dirty(old_parent, NS.LAYOUT_DIRTY + NS.PAINT_DIRTY)
    end

    -- Propagate subtree_dirty up new ancestor chain if child carries dirty state
    if (self.dirty[child_id] or 0) ~= 0 or self.subtree_dirty[child_id] then
        local pid = parent_id
        while pid and pid ~= 0 do
            if self.subtree_dirty[pid] then break end
            self.subtree_dirty[pid] = 1
            pid = self.parent[pid]
        end
    end
end

--- Insert child_id immediately before reference_id in reference_id's parent.
--- Unlinks child from its current parent first.
---@param child_id     number
---@param reference_id number  sibling to insert before
function NS:insert_before(child_id, reference_id)
    if child_id == reference_id then return false end
    local parent_id = self.parent[reference_id]
    if not parent_id or parent_id == 0 then
        -- Reference has no parent; fall back to append to root 0
        return self:append_child(0, child_id)
    end
    if self:_would_create_tree_cycle(child_id, parent_id) then return false end

    -- Unlink child from previous parent
    local old_parent = self.parent[child_id]
    if old_parent ~= 0 then
        self:_unlink_from_parent(child_id)
        if old_parent ~= parent_id then
            self:_reindex_list_items(old_parent)
        end
    end

    local prev = self.prev_sibling[reference_id]
    self.parent[child_id] = parent_id
    self.prev_sibling[child_id] = prev
    self.next_sibling[child_id] = reference_id
    self.prev_sibling[reference_id] = child_id
    if prev ~= 0 then
        self.next_sibling[prev] = child_id
    else
        self.first_child[parent_id] = child_id
    end
    self:_reindex_list_items(parent_id)
    self._dirty_gen = (self._dirty_gen or 0) + 1
    if parent_id ~= 0 then
        self:mark_dirty(parent_id, NS.LAYOUT_DIRTY + NS.PAINT_DIRTY)
    end
    if old_parent ~= 0 and old_parent ~= parent_id then
        self:mark_dirty(old_parent, NS.LAYOUT_DIRTY + NS.PAINT_DIRTY)
    end

    -- Propagate subtree_dirty (same as append_child)
    if (self.dirty[child_id] or 0) ~= 0 or self.subtree_dirty[child_id] then
        local pid = parent_id
        while pid and pid ~= 0 do
            if self.subtree_dirty[pid] then break end
            self.subtree_dirty[pid] = 1
            pid = self.parent[pid]
        end
    end
end

--- Prepend child_id as the first child of parent_id.
--- Unlinks child from its current parent first.
---@param parent_id number
---@param child_id  number
function NS:prepend_child(parent_id, child_id)
    local first = self.first_child[parent_id] or 0
    if first == 0 then
        return self:append_child(parent_id, child_id)
    end
    return self:insert_before(child_id, first)
end

--- Recompute li_index for all <li> children of a parent.
---@param parent_nid number
function NS:_reindex_list_items(parent_nid)
    if parent_nid == 0 then return end
    local idx = 0
    local cid = self.first_child[parent_nid]
    while cid and cid ~= 0 do
        local tag = self._st:get(self.tag[cid])
        if tag == "li" then
            idx = idx + 1
            self.li_index[cid] = idx
        end
        cid = self.next_sibling[cid] or 0
    end
end

--- Unlink a node from its parent (internal helper).
---@param nid number
function NS:_unlink_from_parent(nid)
    local pid = self.parent[nid]
    if pid == 0 then return end

    local prev = self.prev_sibling[nid]
    local next_ = self.next_sibling[nid]

    if prev ~= 0 then
        self.next_sibling[prev] = next_
    else
        self.first_child[pid] = next_
    end

    if next_ ~= 0 then
        self.prev_sibling[next_] = prev
    else
        self.last_child[pid] = prev
    end

    self.parent[nid] = 0
    self.prev_sibling[nid] = 0
    self.next_sibling[nid] = 0
end

--- Remove a node from the tree and recycle its id.
--- Does NOT remove children -- caller should walk and
--- remove children first if desired.
---@param nid number
function NS:remove_node(nid)
    local old_parent = self.parent[nid]
    self:_unlink_from_parent(nid)
    self._dirty_gen = (self._dirty_gen or 0) + 1
    -- Reindex list items in the old parent (sibling order changed)
    if old_parent and old_parent ~= 0 then
        self:_reindex_list_items(old_parent)
        self:mark_dirty(old_parent, NS.LAYOUT_DIRTY + NS.PAINT_DIRTY)
    end

    -- Clear arrays
    self.tag[nid]          = nil
    self.id_str[nid]       = nil
    self.class_list[nid]   = nil
    self.parent[nid]       = nil
    self.first_child[nid]  = nil
    self.last_child[nid]   = nil
    self.next_sibling[nid] = nil
    self.prev_sibling[nid] = nil
    self.node_type[nid]    = nil
    self.text_content[nid] = nil
    self.attrs[nid]        = nil
    self.computed[nid]     = nil
    self.layout[nid]       = nil
    self.dirty[nid]         = nil
    self.subtree_dirty[nid] = nil
    self.pseudo[nid]        = nil
    self.scroll[nid]        = nil
    self.li_index[nid]      = nil
    -- style_gen intentionally NOT cleared -" keeps incrementing across node
    -- recycling so stale measure_cache entries (keyed by nid:gen) are never hit

    -- Unregister from fast-lookup sets
    self._checkboxes[nid] = nil
    self._radios[nid]     = nil
    self._progress[nid]   = nil
    self._meters[nid]     = nil
    self._details[nid]    = nil
    self._dialogs[nid]    = nil
    if self._components then
        self._components[nid] = nil
    end

    -- Record removal for transition engine cleanup (order-independent)
    local rem = self._removed_nids
    rem[#rem + 1] = nid

    -- Notify scroll engine to clear extent cache for recycled nid
    if self._on_node_remove then self._on_node_remove(nid) end

    -- Recycle
    self._free[#self._free + 1] = nid
    self._count = self._count - 1
end

------------------------------------------------------------
-- Dirty flag helpers (must be declared before walk_depth_first_dirty)
------------------------------------------------------------

--- Test if bit `f` is set in `d` (no division, Lua 5.1 safe).
--- d % (f*2) >= f  is equivalent to  bit.band(d, f) ~= 0
local function _has_bit(d, f)
    return d % (f + f) >= f
end

------------------------------------------------------------
-- Iteration
------------------------------------------------------------

--- Return an iterator over the children of parent_id.
--- Usage:  for child_id in ns:children_iter(pid) do ... end
---@param parent_id number
---@return function  iterator
function NS:children_iter(parent_id)
    local nid = self.first_child[parent_id]
    if not nid then nid = 0 end
    return function()
        if nid == 0 then return nil end
        local current = nid
        nid = self.next_sibling[nid] or 0
        return current
    end
end

--- Iterative depth-first walk starting at root_id.
--- Calls visitor_fn(nid) for every node (including root).
--- Stack-based, NOT recursive.
---@param root_id   number
---@param visitor_fn function
function NS:walk_depth_first(root_id, visitor_fn)
    if root_id == 0 then return end
    -- Allocate per-call stack (safe for reentrant visitors)
    local stack = { root_id }
    local sp = 1
    local last_child   = self.last_child
    local prev_sibling = self.prev_sibling
    while sp > 0 do
        local nid = stack[sp]
        sp = sp - 1
        visitor_fn(nid)

        local cid = last_child[nid]
        if cid and cid ~= 0 then
            while cid ~= 0 do
                sp = sp + 1
                stack[sp] = cid
                cid = prev_sibling[cid] or 0
            end
        end
    end
end

--- Walk depth-first but skip subtrees where no node has the given dirty bit.
---@param root_id   number    root node
---@param dirty_bit number    flag bit to check (1=STYLE, 2=LAYOUT, 4=PAINT)
---@param visitor_fn function called for each node that has dirty_bit set
function NS:walk_depth_first_dirty(root_id, dirty_bit, visitor_fn)
    if root_id == 0 then return end
    -- Local stack per call: visitors that re-enter the walker (directly or
    -- indirectly via another NodeStore method) used to corrupt the previous
    -- frame's iteration state when a single shared `self._walk_stack` was
    -- reused.  The allocation cost is trivial against the per-frame cascade.
    local stack = { root_id }
    local sp = 1
    local last_child    = self.last_child
    local prev_sibling  = self.prev_sibling
    local dirty         = self.dirty
    local subtree_dirty = self.subtree_dirty
    while sp > 0 do
        local nid = stack[sp]
        sp = sp - 1
        local d = dirty[nid] or 0
        local is_dirty = _has_bit(d, dirty_bit)
        if is_dirty then
            visitor_fn(nid)
        end
        -- Only descend if this node is dirty OR has dirty descendants
        if is_dirty or subtree_dirty[nid] then
            local cid = last_child[nid]
            while cid and cid ~= 0 do
                sp = sp + 1
                stack[sp] = cid
                cid = prev_sibling[cid] or 0
            end
        end
    end
end

------------------------------------------------------------
-- Bundle mounting
------------------------------------------------------------

--- Build the full DOM from a parsed-value bundle.
--- The bundle shape is internal and not part of the public contract.
---@param bundle table  parsed value from HTMLParser.parse / compiled output
---@return number  root node id
function NS:mount_bundle(bundle)
    if not bundle then return 0 end

    local strings = bundle.strings or {}
    local nodes   = bundle.nodes   or {}

    -- Intern all bundle strings via string table
    local str_ids = self._st:bulk_intern(strings)

    local count = #(nodes.tag or {})
    if count == 0 then return 0 end

    -- Allocate all nodes
    local id_map = {}  -- bundle index -> real node id
    for i = 1, count do
        local tag_str_idx   = nodes.tag[i] or 0
        local id_str_idx    = nodes.id_str and nodes.id_str[i] or 0
        local cls_indices   = nodes.class_list and nodes.class_list[i] or {}
        local ntype         = nodes.node_type and nodes.node_type[i] or NS.ELEMENT
        local text          = nodes.text_content and nodes.text_content[i] or ""
        local attr          = nodes.attrs and nodes.attrs[i] or {}

        -- Resolve tag and id from bundle string table
        local tag_s = nil
        if tag_str_idx > 0 and tag_str_idx <= #strings then
            tag_s = strings[tag_str_idx]
        end
        local id_s = nil
        if id_str_idx > 0 and id_str_idx <= #strings then
            id_s = strings[id_str_idx]
        end

        -- Resolve class names from bundle string indices
        local class_names = {}
        for ci = 1, #cls_indices do
            local si = cls_indices[ci]
            if si > 0 and si <= #strings then
                class_names[ci] = strings[si]
            end
        end

        local nid = self:create_node(tag_s, id_s, class_names, ntype, text, attr)
        id_map[i] = nid
    end

    -- Build tree from parent[] array.  Direct link-setting (bypassing
    -- append_child) is required because append_child calls
    -- _reindex_list_items(parent) per child -" which walks the whole sibling
    -- chain.  For N children under the same parent that's O(N²) (a 1000-row
    -- table previously cost ~500k string fetches just to mount).  We
    -- record parents that have any <li> child and run a single reindex per
    -- parent at the end.
    local parents = nodes.parent or {}
    local parents_with_li = {}
    local first_child_local  = self.first_child
    local last_child_local   = self.last_child
    local prev_sibling_local = self.prev_sibling
    local next_sibling_local = self.next_sibling
    local parent_local       = self.parent
    local tag_local          = self.tag
    local st                 = self._st
    for i = 1, count do
        local pi = parents[i] or 0
        if pi > 0 and id_map[pi] then
            local real_parent = id_map[pi]
            local real_child  = id_map[i]
            local last = last_child_local[real_parent]
            parent_local[real_child]       = real_parent
            prev_sibling_local[real_child] = last
            next_sibling_local[real_child] = 0
            if last ~= 0 then
                next_sibling_local[last] = real_child
            else
                first_child_local[real_parent] = real_child
            end
            last_child_local[real_parent] = real_child
            if not parents_with_li[real_parent] and st:get(tag_local[real_child]) == "li" then
                parents_with_li[real_parent] = true
            end
        elseif pi ~= 0 and not id_map[pi] then
            -- Malformed bundle: parent index references a non-existent
            -- bundle node.  Leave the node detached (still allocated) but
            -- surface the problem rather than silently leaking nids forever.
            if self._platform and self._platform.log_warning then
                self._platform:log_warning("[NodeStore] mount_bundle: orphan node " .. tostring(id_map[i]) .. " has invalid parent index " .. tostring(pi))
            end
        end
    end

    -- One-shot reindex per parent with <li> children
    for parent_nid in pairs(parents_with_li) do
        self:_reindex_list_items(parent_nid)
    end

    -- Propagate subtree_dirty from every root of the mounted subtree so
    -- ancestors know they have dirty descendants (append_child does this
    -- per child, but we bypassed it).  All newly-created nodes have
    -- dirty bits set in create_node already.
    local subtree_dirty_local = self.subtree_dirty
    for i = 1, count do
        local pi = parents[i] or 0
        if pi > 0 and id_map[pi] then
            local pid = id_map[pi]
            while pid and pid ~= 0 do
                if subtree_dirty_local[pid] then break end
                subtree_dirty_local[pid] = 1
                pid = parent_local[pid]
            end
        end
    end

    self._last_mount_id_map = id_map

    -- Return the root (first node with no parent)
    for i = 1, count do
        local pi = parents[i] or 0
        if pi == 0 then
            return id_map[i]
        end
    end

    -- Fallback: return the first allocated node
    return id_map[1] or 0
end

------------------------------------------------------------
-- Dirty flags (modular arithmetic, NO bitwise ops)
-- (_has_bit is declared above, before Iteration section)
------------------------------------------------------------

local _FLAG_BITS = { 1, 2, 4 }  -- STYLE_DIRTY, LAYOUT_DIRTY, PAINT_DIRTY

--- Add dirty flags to a node.
---@param nid   number  node id
---@param flags number  flag bits to set
function NS:mark_dirty(nid, flags)
    local d = self.dirty[nid] or 0
    local changed = false
    for i = 1, 3 do
        local f = _FLAG_BITS[i]
        if _has_bit(flags, f) and not _has_bit(d, f) then
            d = d + f
            changed = true
        end
    end
    if not changed then return end
    self._dirty_gen = (self._dirty_gen or 0) + 1
    -- Lazy counter that lets the engine skip its O(N) `pairs(ns.dirty)`
    -- scan on idle frames.  Only increment when the node was clean.
    if (self.dirty[nid] or 0) == 0 then
        self._dirty_count = (self._dirty_count or 0) + 1
    end
    self.dirty[nid] = d
    -- Propagate subtree_dirty up to ancestors
    local parent = self.parent
    local subtree_dirty = self.subtree_dirty
    local pid = parent[nid]
    while pid and pid ~= 0 do
        if subtree_dirty[pid] then break end  -- already marked, ancestors already know
        subtree_dirty[pid] = 1
        pid = parent[pid]
    end
end

--- Mark ancestors of a node dirty with the given flags.
--- Walks parent chain upward, stopping when all flags already set.
---@param nid   number  starting node (NOT marked itself)
---@param flags number  flag bits to set

function NS:mark_ancestors_dirty(nid, flags)
    local pid = self.parent[nid]
    while pid and pid ~= 0 do
        local d = self.dirty[pid] or 0
        local dominated = true
        for i = 1, 3 do
            local f = _FLAG_BITS[i]
            if _has_bit(flags, f) and not _has_bit(d, f) then
                dominated = false
                break
            end
        end
        if dominated then break end
        self:mark_dirty(pid, flags)
        pid = self.parent[pid]
    end
end

--- Clear all subtree_dirty flags (after full tree pass).
--- NOTE: do NOT clear individual nodes -" that would orphan dirty descendants.
function NS:clear_all_subtree_dirty()
    local sd = self.subtree_dirty
    for k in pairs(sd) do sd[k] = nil end
end

--- Remove dirty flags from a node.
---@param nid   number  node id
---@param flags number  flag bits to clear
function NS:clear_dirty(nid, flags)
    local d = self.dirty[nid] or 0
    local before = d
    for i = 1, 3 do
        local f = _FLAG_BITS[i]
        if _has_bit(flags, f) and _has_bit(d, f) then
            d = d - f
        end
    end
    self.dirty[nid] = d
    if before > 0 and d == 0 then
        self._dirty_count = (self._dirty_count or 1) - 1
        if self._dirty_count < 0 then self._dirty_count = 0 end
    end
end

--- Check if a specific dirty flag is set.
---@param nid  number  node id
---@param flag number  single flag bit to test
---@return boolean
function NS:is_dirty(nid, flag)
    local d = self.dirty[nid] or 0
    return _has_bit(d, flag)
end

--- Check if a node has any children.
---@param nid number  node id
---@return boolean
function NS:has_children(nid)
    local fc = self.first_child[nid]
    return fc ~= nil and fc ~= 0
end

return NS



