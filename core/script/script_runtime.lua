------------------------------------------------------------
-- ext_core_astro_ui_lib / core / script / script_runtime.lua
-- Runs <script lang="lua"> blocks from loaded HTML bundles.
-- Provides a sandboxed `astro` API so scripts can:
--   - register action handlers (onClick/onChange etc.)
--   - find nodes by id/class/tag
--   - mutate text, attrs, and classes
--   - read/write per-mount state
--   - navigate (reload / load_url / load_file)
--
-- Scripts get a normal Lua env with most stdlib + `astro`.
-- They cannot reach back into the engine except through `astro`.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ScriptRuntime = {}
local SelectorParser  = require("core/style/selector_parser")
local SelectorMatcher = require("core/style/selector_matcher")
local HTMLParser      = require("core/html/html_parser")

local function compile_lua_chunk(code, chunk_name, env)
    if loadstring then
        local chunk, err = loadstring(code, chunk_name)
        if chunk and setfenv then setfenv(chunk, env) end
        return chunk, err
    end
    return load(code, chunk_name, "t", env)
end

------------------------------------------------------------
-- Selector helpers -" tiny subset of CSS used for
-- scripted node lookups. Supported:
--   "#id"       -" id match
--   ".class"    -" class match
--   "tag"       -" tag match
-- No combinators; scripts should walk children themselves.
------------------------------------------------------------
local function parse_selector(sel)
    if type(sel) ~= "string" or sel == "" then return nil end
    local ok, parsed = pcall(SelectorParser.parse, sel)
    if ok and parsed and parsed.segments then return parsed end
    return nil
end

local function find_all(ns, root_id, sel)
    local parsed = parse_selector(sel)
    if not parsed then return {} end
    local results = {}
    ns:walk_depth_first(root_id, function(nid)
        if ns.node_type[nid] == ns.ELEMENT and SelectorMatcher.matches(ns, nid, parsed) then
            results[#results + 1] = nid
        end
    end)
    return results
end

local function find_first(ns, root_id, sel)
    local parsed = parse_selector(sel)
    if not parsed then return nil end
    local found
    ns:walk_depth_first(root_id, function(nid)
        if not found and ns.node_type[nid] == ns.ELEMENT and SelectorMatcher.matches(ns, nid, parsed) then
            found = nid
        end
    end)
    return found
end

local function selector_matches(ns, nid, sel)
    local parsed = parse_selector(sel)
    return parsed and SelectorMatcher.matches(ns, nid, parsed) or false
end

------------------------------------------------------------
-- Node handle (thin wrapper around a nid)
------------------------------------------------------------
local NodeHandle = {}
NodeHandle.__index = NodeHandle

local function make_handle(ctx, nid)
    if not nid then return nil end
    return setmetatable({
        nid = nid,
        _ctx = ctx,
    }, NodeHandle)
end

local EVENT_ATTR = {
    click       = "onClick",
    dblclick    = "onDblClick",
    change      = "onChange",
    input       = "onInput",
    submit      = "onSubmit",
    reset       = "onReset",
    focus       = "onFocus",
    blur        = "onBlur",
    keydown     = "onKeyDown",
    keyup       = "onKeyUp",
    keypress    = "onKeyPress",
    mousedown   = "onMouseDown",
    mouseup     = "onMouseUp",
    mouseenter  = "onMouseEnter",
    mouseleave  = "onMouseLeave",
    mouseover   = "onMouseOver",
    mouseout    = "onMouseOut",
    mousemove   = "onMouseMove",
    wheel       = "onWheel",
    contextmenu = "onContextMenu",
    close       = "onClose",
}

local function mark_style_layout(ctx, nid)
    local ns = ctx.ns
    if nid and ns and ns.mark_dirty then
        ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
    end
    ctx.mount.style_dirty = true
    ctx.mount.layout_dirty = true
end

local function tag_name(ctx, nid)
    local sid = ctx.ns.tag[nid]
    return sid and ctx.ns._st:get(sid) or ""
end

local function get_node_text(ns, nid)
    if ns.node_type[nid] == ns.TEXT then return ns.text_content[nid] or "" end
    local out = {}
    local function walk(id)
        if ns.node_type[id] == ns.TEXT then
            out[#out + 1] = ns.text_content[id] or ""
        else
            local c = ns.first_child[id] or 0
            while c ~= 0 do
                walk(c)
                c = ns.next_sibling[c] or 0
            end
        end
    end
    walk(nid)
    return table.concat(out)
end

local function get_element_value(handle)
    local ctx, ns, nid = handle._ctx, handle._ctx.ns, handle.nid
    local tag = tag_name(ctx, nid)
    local attrs = ns.attrs[nid] or {}
    if tag == "input" then
        local it = tostring(attrs.type or "text"):lower()
        if it == "checkbox" or it == "radio" then
            local p = ns.pseudo[nid]
            return p and p.checked == true
        end
        return attrs.value ~= nil and tostring(attrs.value) or tostring(ns.text_content[nid] or "")
    elseif tag == "textarea" then
        return tostring(ns.text_content[nid] or attrs.value or "")
    elseif tag == "select" then
        local opts = attrs.options or {}
        local values = attrs.option_values or {}
        local idx = attrs.selected_index or 1
        return attrs.value or values[idx] or opts[idx] or tostring(ns.text_content[nid] or "")
    elseif tag == "checkbox" or tag == "radio" or tag == "switch" then
        local p = ns.pseudo[nid]
        return p and p.checked == true
    end
    return get_node_text(ns, nid)
end

local function set_element_value(handle, value)
    local ctx, ns, nid = handle._ctx, handle._ctx.ns, handle.nid
    local tag = tag_name(ctx, nid)
    local attrs = ns.attrs[nid] or {}
    ns.attrs[nid] = attrs
    if tag == "input" then
        local it = tostring(attrs.type or "text"):lower()
        if it == "checkbox" or it == "radio" then
            ns.pseudo[nid] = ns.pseudo[nid] or {}
            ns.pseudo[nid].checked = value == true or value == "true" or value == 1
        else
            attrs.value = tostring(value or "")
            ns.text_content[nid] = attrs.value
        end
    elseif tag == "textarea" then
        ns.text_content[nid] = tostring(value or "")
        attrs.value = ns.text_content[nid]
    elseif tag == "select" then
        local opts = attrs.options or {}
        local values = attrs.option_values or {}
        for i = 1, #opts do
            if tostring(values[i] or opts[i]) == tostring(value) or tostring(opts[i]) == tostring(value) then
                attrs.selected_index = i
                ns.text_content[nid] = opts[i]
                attrs.value = values[i] or opts[i]
                break
            end
        end
        if attrs.value == nil then attrs.value = value end
    elseif tag == "checkbox" or tag == "radio" or tag == "switch" then
        ns.pseudo[nid] = ns.pseudo[nid] or {}
        ns.pseudo[nid].checked = value == true or value == "true" or value == 1
    else
        handle:set_text(value)
        return
    end
    mark_style_layout(ctx, nid)
end

local function make_event(ctx, event_type, target_nid, current_nid, raw)
    raw = raw or {}
    local e = {
        type = event_type,
        target = make_handle(ctx, target_nid or current_nid),
        currentTarget = make_handle(ctx, current_nid or target_nid),
        clientX = raw.clientX or raw.x or 0,
        clientY = raw.clientY or raw.y or 0,
        button = raw.button or 0,
        ctrlKey = raw.ctrlKey or false,
        shiftKey = raw.shiftKey or false,
        altKey = raw.altKey or false,
        metaKey = raw.metaKey or false,
        key = raw.key,
        code = raw.code,
        keyCode = raw.keyCode,
        deltaX = raw.deltaX or 0,
        deltaY = raw.deltaY or raw.wheel or 0,
        defaultPrevented = false,
        _stopped = false,
        _immediateStopped = false,
    }
    function e:preventDefault() self.defaultPrevented = true end
    function e:stopPropagation() self._stopped = true end
    function e:stopImmediatePropagation() self._immediateStopped = true; self._stopped = true end
    return e
end

function NodeHandle:get_attr(name)
    local attrs = self._ctx.ns.attrs[self.nid]
    return attrs and attrs[name]
end

function NodeHandle:set_attr(name, value)
    local attrs = self._ctx.ns.attrs[self.nid]
    if not attrs then attrs = {}; self._ctx.ns.attrs[self.nid] = attrs end
    attrs[name] = value
    self._ctx.ns:mark_dirty(self.nid, self._ctx.ns.STYLE_DIRTY)
    self._ctx.mount.style_dirty = true
end

function NodeHandle:getAttribute(name) return self:get_attr(name) end
function NodeHandle:setAttribute(name, value) return self:set_attr(name, value) end
function NodeHandle:removeAttribute(name)
    local attrs = self._ctx.ns.attrs[self.nid]
    if attrs then attrs[name] = nil end
    mark_style_layout(self._ctx, self.nid)
end
function NodeHandle:hasAttribute(name)
    local attrs = self._ctx.ns.attrs[self.nid]
    return attrs and attrs[name] ~= nil or false
end

function NodeHandle:set_text(text)
    local ns = self._ctx.ns
    -- Find first text child; if none, create one.
    local first = ns.first_child[self.nid] or 0
    local text_nid
    local cid = first
    while cid ~= 0 do
        if ns.node_type[cid] == 2 then
            text_nid = cid
            break
        end
        cid = ns.next_sibling[cid] or 0
    end
    if text_nid then
        ns.text_content[text_nid] = tostring(text or "")
        ns:mark_dirty(text_nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
    else
        -- Create a new text node as first child.
        -- NodeStore:create_node(tag_str, id_str, classes, ntype, text, attr)
        local tnid = ns:create_node("_text", nil, nil, ns.TEXT, tostring(text or ""), nil)
        if tnid then
            ns:append_child(self.nid, tnid)
        end
    end
    self._ctx.mount.layout_dirty = true
end

function NodeHandle:add_class(class_name)
    local ns = self._ctx.ns
    local cls_list = ns.class_list[self.nid]
    if not cls_list then cls_list = {}; ns.class_list[self.nid] = cls_list end
    local sid = ns._st:intern(class_name)
    for i = 1, #cls_list do
        if cls_list[i] == sid then return end
    end
    cls_list[#cls_list + 1] = sid
    ns:mark_dirty(self.nid, ns.STYLE_DIRTY)
    self._ctx.mount.style_dirty = true
end

function NodeHandle:remove_class(class_name)
    local ns = self._ctx.ns
    local cls_list = ns.class_list[self.nid]
    if not cls_list then return end
    local sid = ns._st:intern(class_name)
    for i = #cls_list, 1, -1 do
        if cls_list[i] == sid then
            table.remove(cls_list, i)
            ns:mark_dirty(self.nid, ns.STYLE_DIRTY)
            self._ctx.mount.style_dirty = true
            return
        end
    end
end

function NodeHandle:has_class(class_name)
    local ns = self._ctx.ns
    local cls_list = ns.class_list[self.nid]
    if not cls_list then return false end
    local sid = ns._st:intern(class_name)
    for i = 1, #cls_list do
        if cls_list[i] == sid then return true end
    end
    return false
end

function NodeHandle:toggle_class(class_name)
    if self:has_class(class_name) then
        self:remove_class(class_name)
    else
        self:add_class(class_name)
    end
end

function NodeHandle:on(event, handler)
    -- Generates an action id under the hood, sets the attr, registers handler.
    local action_id = "_script_" .. event .. "_" .. tostring(self.nid)
    local ctx = self._ctx
    self._ctx.es:register_action(action_id, function(nid, aid, raw_event)
        local e = make_event(ctx, event, raw_event and raw_event.target or nid, self.nid, raw_event)
        return handler(e)
    end)
    -- Canonical attribute name uses camelCase per word ("onMouseDown" not
    -- "onMousedown"), so multi-word events match what the event_system
    -- looks up.  Maps standard DOM event names.
    local attr_name = EVENT_ATTR[event]
        or ("on" .. event:sub(1, 1):upper() .. event:sub(2))
    self:set_attr(attr_name, action_id)
end

function NodeHandle:addEventListener(event, handler)
    return self:on(event, handler)
end

function NodeHandle:removeEventListener(event)
    local attr_name = EVENT_ATTR[event] or ("on" .. event:sub(1, 1):upper() .. event:sub(2))
    local attrs = self._ctx.ns.attrs[self.nid]
    if attrs then attrs[attr_name] = nil; attrs[attr_name:lower()] = nil end
end

------------------------------------------------------------
-- Tree mutation
------------------------------------------------------------

local function _dirty_tree(ctx)
    ctx.mount.style_dirty = true
    ctx.mount.layout_dirty = true
end

--- Append another node (given as a handle) as our last child.
---@param child NodeHandle|nil
function NodeHandle:append(child)
    if not child then return self end
    self._ctx.ns:append_child(self.nid, child.nid)
    _dirty_tree(self._ctx)
    return self
end

function NodeHandle:appendChild(child)
    if child then self._ctx.ns:append_child(self.nid, child.nid); _dirty_tree(self._ctx) end
    return child
end

function NodeHandle:insertBefore(child, reference)
    if child and reference then
        self._ctx.ns:insert_before(child.nid, reference.nid)
        _dirty_tree(self._ctx)
    elseif child then
        self._ctx.ns:append_child(self.nid, child.nid)
        _dirty_tree(self._ctx)
    end
    return child
end

function NodeHandle:removeChild(child)
    if child then child:remove() end
    return child
end

function NodeHandle:replaceChild(new_child, old_child)
    if new_child and old_child then
        self._ctx.ns:insert_before(new_child.nid, old_child.nid)
        old_child:remove()
        _dirty_tree(self._ctx)
    end
    return old_child
end

--- Shortcut: attach self as last child of `parent`.
---@param parent NodeHandle
function NodeHandle:append_to(parent)
    if parent then parent:append(self) end
    return self
end

--- Insert ourselves immediately before `reference` in its parent.
---@param reference NodeHandle
function NodeHandle:insert_before(reference)
    if not reference then return self end
    self._ctx.ns:insert_before(self.nid, reference.nid)
    _dirty_tree(self._ctx)
    return self
end

--- Attach self as the first child of `parent`.
---@param parent NodeHandle
function NodeHandle:prepend_to(parent)
    if not parent then return self end
    self._ctx.ns:prepend_child(parent.nid, self.nid)
    _dirty_tree(self._ctx)
    return self
end

--- Detach self from its parent and recycle the node id.
function NodeHandle:remove()
    local ns = self._ctx.ns
    -- Recursive pre-order removal so all descendants are cleaned up too.
    local stack = { self.nid }
    local collected = {}
    while #stack > 0 do
        local nid = stack[#stack]; stack[#stack] = nil
        collected[#collected + 1] = nid
        local cid = ns.first_child[nid] or 0
        while cid ~= 0 do
            stack[#stack + 1] = cid
            cid = ns.next_sibling[cid] or 0
        end
    end
    local es = self._ctx.es
    if es and es.focus_id and es.focus_id ~= 0 then
        for i = 1, #collected do
            if collected[i] == es.focus_id then
                es:_set_focus(0, false)
                break
            end
        end
    end
    -- Remove children first, self last (so unlink on self is clean)
    for i = #collected, 1, -1 do
        ns:remove_node(collected[i])
    end
    _dirty_tree(self._ctx)
end

--- Remove all child nodes but keep self.
function NodeHandle:clear()
    local ns = self._ctx.ns
    local cid = ns.first_child[self.nid] or 0
    while cid ~= 0 do
        local next_cid = ns.next_sibling[cid] or 0
        -- Use handle-style remove so descendants are cleaned recursively
        local child_handle = make_handle(self._ctx, cid)
        child_handle:remove()
        cid = next_cid
    end
    _dirty_tree(self._ctx)
    return self
end

--- Navigation: parent / first_child / last_child / next_sibling / prev_sibling.
function NodeHandle:parent()
    local pid = self._ctx.ns.parent[self.nid]
    if not pid or pid == 0 then return nil end
    return make_handle(self._ctx, pid)
end

function NodeHandle:first_child()
    local cid = self._ctx.ns.first_child[self.nid]
    if not cid or cid == 0 then return nil end
    return make_handle(self._ctx, cid)
end

function NodeHandle:last_child()
    local cid = self._ctx.ns.last_child[self.nid]
    if not cid or cid == 0 then return nil end
    return make_handle(self._ctx, cid)
end

function NodeHandle:next_sibling()
    local sid = self._ctx.ns.next_sibling[self.nid]
    if not sid or sid == 0 then return nil end
    return make_handle(self._ctx, sid)
end

function NodeHandle:prev_sibling()
    local sid = self._ctx.ns.prev_sibling[self.nid]
    if not sid or sid == 0 then return nil end
    return make_handle(self._ctx, sid)
end

--- Return an array of child handles (at time of call).
function NodeHandle:children()
    local ns = self._ctx.ns
    local out = {}
    local cid = ns.first_child[self.nid] or 0
    while cid ~= 0 do
        out[#out + 1] = make_handle(self._ctx, cid)
        cid = ns.next_sibling[cid] or 0
    end
    return out
end

function NodeHandle:cloneNode(deep)
    local ns = self._ctx.ns
    local function clone_one(nid)
        local tag = ns._st:get(ns.tag[nid])
        local id_sid = ns.id_str[nid]
        local id = (id_sid and id_sid ~= 0) and ns._st:get(id_sid) or nil
        local classes = {}
        local cls = ns.class_list[nid] or {}
        for i = 1, #cls do classes[i] = ns._st:get(cls[i]) end
        local attrs = {}
        for k, v in pairs(ns.attrs[nid] or {}) do attrs[k] = v end
        local copy = ns:create_node(tag, id, classes, ns.node_type[nid], ns.text_content[nid], attrs)
        if deep then
            local c = ns.first_child[nid] or 0
            while c ~= 0 do
                ns:append_child(copy, clone_one(c))
                c = ns.next_sibling[c] or 0
            end
        end
        return copy
    end
    return make_handle(self._ctx, clone_one(self.nid))
end

function NodeHandle:querySelector(sel)
    return make_handle(self._ctx, find_first(self._ctx.ns, self.nid, sel))
end

function NodeHandle:querySelectorAll(sel)
    local nids = find_all(self._ctx.ns, self.nid, sel)
    local out = {}
    for i = 1, #nids do out[i] = make_handle(self._ctx, nids[i]) end
    return out
end

--- Replace own children with elements parsed from an HTML fragment.
---@param html_str string
function NodeHandle:set_html(html_str)
    local ctx = self._ctx
    local ns = ctx.ns
    local st = ns._st

    -- Drop existing children first
    self:clear()

    if not html_str or html_str == "" then return self end

    -- Parse fragment into a temporary bundle and graft its nodes into ours.
    local HTMLParser = require("core/html/html_parser")
    local frag = HTMLParser.parse(html_str, nil)
    if not frag or not frag.nodes or not frag.nodes.tag then return self end

    local f_nodes   = frag.nodes
    local f_strings = frag.strings or {}
    local f_count   = #f_nodes.tag

    -- Map each fragment-local node id to a live node id
    local id_map = {}
    for i = 1, f_count do
        local tag_sid = f_nodes.tag[i]
        local tag_str = f_strings[tag_sid] or "div"
        local id_sid  = f_nodes.id_str[i] or 0
        local id_str  = (id_sid ~= 0) and f_strings[id_sid] or nil
        local cls_sids = f_nodes.class_list[i] or {}
        local cls_names = {}
        for ci = 1, #cls_sids do
            cls_names[ci] = f_strings[cls_sids[ci]]
        end
        local ntype = f_nodes.node_type[i] or 1
        local text  = f_nodes.text_content[i]
        local attr  = f_nodes.attrs[i] or {}
        id_map[i] = ns:create_node(tag_str, id_str, cls_names, ntype, text, attr)
    end

    -- Link children to parents (parent_id 0 = fragment root, maps to self)
    for i = 1, f_count do
        local f_parent = f_nodes.parent[i] or 0
        local live_child = id_map[i]
        if f_parent == 0 then
            ns:append_child(self.nid, live_child)
        else
            ns:append_child(id_map[f_parent], live_child)
        end
    end

    -- Merge any <style> rules from the fragment into the style engine
    if frag.rules and ctx.mount.style_engine then
        ctx.mount.style_engine:append_rules(frag.rules)
    end

    _dirty_tree(ctx)
    return self
end

local function make_class_list(handle)
    return {
        add = function(_, class_name) return handle:add_class(class_name) end,
        remove = function(_, class_name) return handle:remove_class(class_name) end,
        contains = function(_, class_name) return handle:has_class(class_name) end,
        toggle = function(_, class_name)
            local had = handle:has_class(class_name)
            handle:toggle_class(class_name)
            return not had
        end,
    }
end

local function make_dataset(handle)
    return setmetatable({}, {
        __index = function(_, key)
            return handle:get_attr("data-" .. tostring(key):gsub("_", "-"))
        end,
        __newindex = function(_, key, value)
            handle:set_attr("data-" .. tostring(key):gsub("_", "-"), value)
        end,
    })
end

local function make_style(handle)
    return setmetatable({
        setProperty = function(_, name, value)
            local attrs = handle._ctx.ns.attrs[handle.nid] or {}
            handle._ctx.ns.attrs[handle.nid] = attrs
            attrs.style = tostring(attrs.style or "")
            local prop = tostring(name)
            local filtered = {}
            for decl in attrs.style:gmatch("[^;]+") do
                local k = decl:match("^%s*([^:]+)")
                if k and k:match("^%s*(.-)%s*$") ~= prop then filtered[#filtered + 1] = decl end
            end
            filtered[#filtered + 1] = prop .. ":" .. tostring(value)
            attrs.style = table.concat(filtered, ";")
            mark_style_layout(handle._ctx, handle.nid)
        end,
        getPropertyValue = function(_, name)
            local attrs = handle._ctx.ns.attrs[handle.nid] or {}
            local style = tostring(attrs.style or "")
            local prop = tostring(name)
            for decl in style:gmatch("[^;]+") do
                local k, v = decl:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
                if k == prop then return v end
            end
            return ""
        end,
    }, {
        __index = function(t, key)
            local raw = rawget(t, key)
            if raw ~= nil then return raw end
            return t:getPropertyValue((tostring(key):gsub("_", "-")))
        end,
        __newindex = function(t, key, value)
            t:setProperty((tostring(key):gsub("_", "-")), value)
        end,
    })
end

local function element_children(handle)
    local ns = handle._ctx.ns
    local out = {}
    local cid = ns.first_child[handle.nid] or 0
    while cid ~= 0 do
        if ns.node_type[cid] == ns.ELEMENT then out[#out + 1] = make_handle(handle._ctx, cid) end
        cid = ns.next_sibling[cid] or 0
    end
    return out
end

local NodeHandle_methods = NodeHandle
NodeHandle.__index = function(self, key)
    local method = NodeHandle_methods[key]
    if method ~= nil then return method end
    local ns = self._ctx.ns
    if key == "textContent" then return get_node_text(ns, self.nid) end
    if key == "innerHTML" then return get_node_text(ns, self.nid) end
    if key == "outerHTML" then return get_node_text(ns, self.nid) end
    if key == "value" then return get_element_value(self) end
    if key == "checked" then
        local p = ns.pseudo[self.nid]
        return p and p.checked == true
    end
    if key == "disabled" then
        local attrs = ns.attrs[self.nid]
        local p = ns.pseudo[self.nid]
        return (p and p.disabled) or (attrs and attrs.disabled ~= nil) or false
    end
    if key == "id" then
        local sid = ns.id_str[self.nid]
        return (sid and sid ~= 0) and ns._st:get(sid) or ""
    end
    if key == "className" then
        local cls = ns.class_list[self.nid] or {}
        local out = {}
        for i = 1, #cls do out[i] = ns._st:get(cls[i]) end
        return table.concat(out, " ")
    end
    if key == "tagName" or key == "nodeName" then return tag_name(self._ctx, self.nid) end
    if key == "dataset" then return make_dataset(self) end
    if key == "classList" then return make_class_list(self) end
    if key == "style" then return make_style(self) end
    if key == "attributes" then return ns.attrs[self.nid] or {} end
    if key == "parentElement" then return self:parent() end
    if key == "children" then return element_children(self) end
    if key == "firstElementChild" then return element_children(self)[1] end
    if key == "lastElementChild" then local c = element_children(self); return c[#c] end
    if key == "nextElementSibling" then
        local sid = ns.next_sibling[self.nid] or 0
        while sid ~= 0 do
            if ns.node_type[sid] == ns.ELEMENT then return make_handle(self._ctx, sid) end
            sid = ns.next_sibling[sid] or 0
        end
        return nil
    end
    if key == "previousElementSibling" then
        local sid = ns.prev_sibling[self.nid] or 0
        while sid ~= 0 do
            if ns.node_type[sid] == ns.ELEMENT then return make_handle(self._ctx, sid) end
            sid = ns.prev_sibling[sid] or 0
        end
        return nil
    end
    return nil
end

NodeHandle.__newindex = function(self, key, value)
    if key == "textContent" then return self:set_text(value) end
    if key == "innerHTML" then return self:set_html(value) end
    if key == "value" then return set_element_value(self, value) end
    if key == "checked" then
        self._ctx.ns.pseudo[self.nid] = self._ctx.ns.pseudo[self.nid] or {}
        self._ctx.ns.pseudo[self.nid].checked = value == true
        return mark_style_layout(self._ctx, self.nid)
    end
    if key == "disabled" then
        if value then self:set_attr("disabled", true) else self:removeAttribute("disabled") end
        local p = self._ctx.ns.pseudo[self.nid]
        if p then p.disabled = value == true end
        return mark_style_layout(self._ctx, self.nid)
    end
    if key == "id" then
        self._ctx.ns.id_str[self.nid] = self._ctx.ns._st:intern(value)
        return mark_style_layout(self._ctx, self.nid)
    end
    if key == "className" then
        local classes = {}
        for word in tostring(value or ""):gmatch("%S+") do classes[#classes + 1] = self._ctx.ns._st:intern(word) end
        self._ctx.ns.class_list[self.nid] = classes
        return mark_style_layout(self._ctx, self.nid)
    end
    rawset(self, key, value)
end

NodeHandle.__eq = function(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.nid ~= nil and a.nid == b.nid
        and a._ctx == b._ctx
end

function NodeHandle:focus()
    if self._ctx.es and self._ctx.es._set_focus then self._ctx.es:_set_focus(self.nid, false) end
end

function NodeHandle:blur()
    if self._ctx.es and self._ctx.es.focus_id == self.nid then self._ctx.es:_set_focus(0, false) end
end

function NodeHandle:click()
    local attrs = self._ctx.ns.attrs[self.nid] or {}
    local action_id = attrs.onClick or attrs.onclick
    if action_id then self._ctx.es:fire_action(action_id, self.nid) end
end

function NodeHandle:getBoundingClientRect()
    local lay = self._ctx.ns.layout[self.nid] or {}
    return { x = lay.x or 0, y = lay.y or 0, width = lay.w or 0, height = lay.h or 0,
             left = lay.x or 0, top = lay.y or 0,
             right = (lay.x or 0) + (lay.w or 0), bottom = (lay.y or 0) + (lay.h or 0) }
end

local Document = {}
Document.__index = Document

function Document:getElementById(id)
    return make_handle(self._ctx, find_first(self._ctx.ns, self._ctx.root_id, "#" .. tostring(id)))
end

function Document:querySelector(sel)
    return make_handle(self._ctx, find_first(self._ctx.ns, self._ctx.root_id, sel))
end

function Document:querySelectorAll(sel)
    local nids = find_all(self._ctx.ns, self._ctx.root_id, sel)
    local out = {}
    for i = 1, #nids do out[i] = make_handle(self._ctx, nids[i]) end
    return out
end

function Document:createElement(tag)
    local nid = self._ctx.ns:create_node(tostring(tag or "div"), nil, nil, self._ctx.ns.ELEMENT, nil, nil)
    return make_handle(self._ctx, nid)
end

function Document:createTextNode(text)
    local nid = self._ctx.ns:create_node("_text", nil, nil, self._ctx.ns.TEXT, tostring(text or ""), nil)
    return make_handle(self._ctx, nid)
end

local function make_document(ctx)
    return setmetatable({ _ctx = ctx }, Document)
end

local function make_refs(ctx)
    return setmetatable({}, {
        __index = function(_, key)
            local refs = ctx.mount.bundle and ctx.mount.bundle.refs
            local ref_nid = refs and refs[key]
            if ref_nid and ctx.mount.bundle_id_map then
                return make_handle(ctx, ctx.mount.bundle_id_map[ref_nid] or ref_nid)
            end
            return make_handle(ctx, find_first(ctx.ns, ctx.root_id, "#" .. tostring(key)))
        end,
    })
end

local function make_state(raw)
    raw = raw or {}
    raw._watchers = raw._watchers or {}
    local function split_path(path)
        local parts = {}
        for part in tostring(path or ""):gmatch("[^%.]+") do parts[#parts + 1] = part end
        return parts
    end
    local function read_path(tbl, path)
        local parts = split_path(path)
        local cur = tbl
        for i = 1, #parts do
            if type(cur) ~= "table" then return nil end
            cur = rawget(cur, parts[i])
        end
        return cur
    end
    local function write_path(tbl, path, value)
        local parts = split_path(path)
        if #parts == 0 then return nil end
        local cur = tbl
        for i = 1, #parts - 1 do
            local k = parts[i]
            local next_tbl = rawget(cur, k)
            if type(next_tbl) ~= "table" then
                next_tbl = {}
                rawset(cur, k, next_tbl)
            end
            cur = next_tbl
        end
        local leaf = parts[#parts]
        local old = rawget(cur, leaf)
        rawset(cur, leaf, value)
        return old
    end
    function raw:get(path) return read_path(self, path) end
    function raw:set(path, value)
        local old = write_path(self, path, value)
        local watchers = self._watchers[path]
        if watchers then
            for i = 1, #watchers do pcall(watchers[i], value, old) end
        end
    end
    function raw:watch(path, fn)
        if type(fn) ~= "function" then return nil end
        self._watchers[path] = self._watchers[path] or {}
        local list = self._watchers[path]
        list[#list + 1] = fn
        return { path = path, fn = fn }
    end
    return raw
end

local FormData = {}
FormData.__index = FormData

function FormData.new(form)
    local self = setmetatable({ _entries = {} }, FormData)
    if not form then return self end
    local ns = form._ctx.ns
    ns:walk_depth_first(form.nid, function(nid)
        local tag = tag_name(form._ctx, nid)
        local attrs = ns.attrs[nid] or {}
        local name = attrs.name
        if not name or name == "" or attrs.disabled ~= nil then return end
        local h = make_handle(form._ctx, nid)
        local it = tag == "input" and tostring(attrs.type or "text"):lower() or ""
        if it == "submit" or it == "reset" or it == "button" then return end
        if it == "radio" then
            local p = ns.pseudo[nid]
            if p and p.checked then self:append(name, attrs.value or ns.text_content[nid] or "on") end
        elseif it == "checkbox" or tag == "checkbox" or tag == "switch" then
            local p = ns.pseudo[nid]
            if p and p.checked then self:append(name, attrs.value ~= nil and attrs.value or true) end
        elseif tag == "input" or tag == "textarea" or tag == "select" then
            self:append(name, get_element_value(h))
        end
    end)
    return self
end

function FormData:append(name, value)
    self._entries[#self._entries + 1] = { name = name, value = value }
end

function FormData:get(name)
    for i = 1, #self._entries do if self._entries[i].name == name then return self._entries[i].value end end
    return nil
end

function FormData:getAll(name)
    local out = {}
    for i = 1, #self._entries do if self._entries[i].name == name then out[#out + 1] = self._entries[i].value end end
    return out
end

function FormData:has(name) return self:get(name) ~= nil end

function FormData:set(name, value)
    local seen = false
    for i = #self._entries, 1, -1 do
        if self._entries[i].name == name then
            if not seen then self._entries[i].value = value; seen = true else table.remove(self._entries, i) end
        end
    end
    if not seen then self:append(name, value) end
end

function FormData:object()
    local out = {}
    for i = 1, #self._entries do
        local k, v = self._entries[i].name, self._entries[i].value
        if out[k] == nil then
            out[k] = v
        elseif type(out[k]) == "table" then
            out[k][#out[k] + 1] = v
        else
            out[k] = { out[k], v }
        end
    end
    return out
end

--- Create a document handle for host/plugin Lua code.
---@param engine table Engine instance
---@param win_id string window id
---@return table|nil document
function ScriptRuntime.create_document(engine, win_id)
    local mount = engine and engine._mounts and engine._mounts[win_id]
    if not mount or not mount.node_store or not mount.event_system or not mount.root_id then
        return nil
    end
    local ctx = {
        ns = mount.node_store,
        es = mount.event_system,
        mount = mount,
        root_id = mount.root_id,
    }
    return make_document(ctx)
end

------------------------------------------------------------
-- Public entry: run scripts against a freshly-mounted window
------------------------------------------------------------

--- Run all lua scripts in `scripts` against the mount.
---@param engine  table   Engine instance (for astro.load_* / astro.reload)
---@param win_id  string  window id
---@param mount   table   mount structure (node_store, event_system, state, ...)
---@param scripts table   array of { lang, code, attrs } from the bundle
function ScriptRuntime.run_scripts(engine, win_id, mount, scripts)
    scripts = scripts or {}
    local ns = mount.node_store
    local es = mount.event_system
    local root_id = mount.root_id
    local platform = engine.platform

    local ctx = { ns = ns, es = es, mount = mount, root_id = root_id }
    local document = make_document(ctx)
    mount.custom_elements = mount.custom_elements or {}
    local customElements = {
        define = function(_, name, definition)
            name = tostring(name)
            definition = definition or {}
            mount.custom_elements[name] = definition
            if type(definition.template) == "string" and definition.template ~= "" then
                ns:walk_depth_first(root_id, function(nid)
                    if tag_name(ctx, nid) ~= name then return end
                    local host = make_handle(ctx, nid)
                    host.innerHTML = definition.template
                    local props = definition.props or {}
                    for i = 1, #props do
                        local prop = props[i]
                        local value = host:getAttribute(prop)
                        local targets = host:querySelectorAll("[data-prop=" .. tostring(prop) .. "]")
                        for j = 1, #targets do
                            if value ~= nil then targets[j].textContent = value end
                        end
                    end
                end)
            end
        end,
        get = function(_, name)
            return mount.custom_elements[tostring(name)]
        end,
    }
    local window = { document = document, customElements = customElements }
    local console = {
        log = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            platform:log("[console] " .. table.concat(parts, "\t"))
        end,
        warn = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            platform:log_warning("[console] " .. table.concat(parts, "\t"))
        end,
        error = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            platform:log_error("[console] " .. table.concat(parts, "\t"))
        end,
    }
    mount._script_timers = mount._script_timers or {}
    mount._script_timer_next_id = mount._script_timer_next_id or 0
    local function set_timer(fn, ms, interval)
        if type(fn) ~= "function" then return nil end
        mount._script_timer_next_id = mount._script_timer_next_id + 1
        local id = mount._script_timer_next_id
        local now = platform:time()
        mount._script_timers[id] = { fn = fn, at = now + (tonumber(ms) or 0) / 1000, ms = tonumber(ms) or 0, interval = interval }
        return id
    end
    local function clear_timer(id) mount._script_timers[id] = nil end
    mount.state = make_state(mount.state)

    -- Build the `astro` sandbox API
    local astro = {}

    astro.win_id   = win_id
    astro.state    = mount.state
    astro.refs     = make_refs(ctx)
    astro.base_url = mount._base_url
    astro.route    = mount._route

    -- Resolve a reference URL against the mount's base URL.
    -- Scripts can use this to build absolute URLs for dynamic <img> src etc.
    local Url = require("core/util/url")
    function astro.resolve_url(ref)
        if not ref or ref == "" then return ref end
        if Url.is_absolute(ref) then return ref end
        return Url.resolve(mount._base_url, ref)
    end

    function astro.log(msg) platform:log("[script] " .. tostring(msg)) end
    function astro.warn(msg) platform:log_warning("[script] " .. tostring(msg)) end
    function astro.error(msg) platform:log_error("[script] " .. tostring(msg)) end

    -- Global action registration (not tied to a node)
    function astro.register_action(id, fn)
        es:register_action(id, fn)
    end
    astro.on_action = astro.register_action
    function astro.action(id, fn)
        es:register_action(id, fn)
    end

    -- Find nodes
    function astro.find(sel)
        return make_handle(ctx, find_first(ns, root_id, sel))
    end
    function astro.find_all(sel)
        local nids = find_all(ns, root_id, sel)
        local out = {}
        for i = 1, #nids do out[i] = make_handle(ctx, nids[i]) end
        return out
    end

    astro.document = document
    astro.window = window

    function astro.set_text(sel, text)
        local h = astro.find(sel)
        if h then h:set_text(text) end
        return h
    end

    --- Create a new element not yet attached to the tree. Returns a handle.
    ---@param tag   string  tag name ("div", "button", "img" ...) or "_text"
    ---@param opts  table|nil  { id=string, class=string, text=string, attrs=table }
    ---@return table|nil
    function astro.create_element(tag, opts)
        opts = opts or {}
        local classes
        if opts.class and opts.class ~= "" then
            classes = {}
            for word in opts.class:gmatch("%S+") do classes[#classes + 1] = word end
        end
        local ntype = ns.ELEMENT
        if tag == "_text" then ntype = ns.TEXT end
        local nid = ns:create_node(tag, opts.id, classes, ntype, opts.text, opts.attrs)
        if not nid then return nil end
        mount.style_dirty = true
        return make_handle(ctx, nid)
    end

    --- Create a plain text node.
    ---@param text string
    ---@return table|nil
    function astro.create_text(text)
        local nid = ns:create_node("_text", nil, nil, ns.TEXT, tostring(text or ""), nil)
        if not nid then return nil end
        mount.style_dirty = true
        return make_handle(ctx, nid)
    end

    -- Convenience: bind click by selector (most common use case)
    function astro.on_click(sel, handler)
        local h = astro.find(sel)
        if h then h:on("click", handler) end
        return h
    end
    function astro.on_change(sel, handler)
        local h = astro.find(sel)
        if h then h:on("change", handler) end
        return h
    end
    function astro.on_submit(sel, handler)
        local h = astro.find(sel)
        if h then h:on("submit", handler) end
        return h
    end
    function astro.on_reset(sel, handler)
        local h = astro.find(sel)
        if h then h:on("reset", handler) end
        return h
    end

    -- State helpers (sugar over mount.state)
    function astro.get_state(key) return mount.state[key] end
    function astro.set_state(key, value)
        mount.state[key] = value
        mount.style_dirty = true
    end

    -- Navigation -" delegate to engine
    function astro.reload() return engine:reload(win_id) end
    function astro.load_url(url, opts) return engine:load_url(win_id, url, opts) end
    function astro.load_file(path, opts) return engine:load_file(win_id, path, opts) end
    function astro.load_html(html, css, opts) return engine:load_html(win_id, html, css, opts) end

    function astro.mark_dirty(kind) engine:mark_dirty(win_id, kind or "all") end

    -- Expose platform time (Sylvanas has no `os` library)
    function astro.time() return platform:time() end
    function astro.delta_time() return platform:delta_time() end

    -- Build a restricted environment that still has most of stdlib but can't
    -- reach core.graphics, _G, debug, io, etc.
    local env = {
        -- Safe stdlib
        string = string,
        table  = table,
        math   = math,
        pairs  = pairs,
        ipairs = ipairs,
        next   = next,
        type   = type,
        tostring = tostring,
        tonumber = tonumber,
        select = select,
        unpack = unpack,
        error  = error,
        pcall  = pcall,
        xpcall = xpcall,
        print  = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            platform:log("[script] " .. table.concat(parts, "\t"))
        end,
        -- Engine-exposed
        astro = astro,
        state = mount.state,
        document = document,
        window = window,
        console = console,
        FormData = FormData,
        customElements = customElements,
        setTimeout = function(fn, ms) return set_timer(fn, ms, false) end,
        clearTimeout = clear_timer,
        setInterval = function(fn, ms) return set_timer(fn, ms, true) end,
        clearInterval = clear_timer,
        requestAnimationFrame = function(fn) return set_timer(function() fn(platform:time() * 1000) end, 0, false) end,
        cancelAnimationFrame = clear_timer,
    }

    -- Run each script
    for i = 1, #scripts do
        if engine._mounts and engine._mounts[win_id] ~= mount then
            break
        end
        local s = scripts[i]
        if s.lang == "lua" and s.code and s.code ~= "" then
            local chunk, perr = compile_lua_chunk(s.code, "script#" .. tostring(i), env)
            if not chunk then
                platform:log_error("[astro] script parse error: " .. tostring(perr))
            else
                local ok, rerr = pcall(chunk)
                if not ok then
                    platform:log_error("[astro] script run error: " .. tostring(rerr))
                end
            end
        end
    end

    local function register_handler_attr(nid, event_name, attr_name, handler_name)
        if type(handler_name) ~= "string" or handler_name == "" then return end
        local fn = env[handler_name]
        if type(fn) == "function" then
            es:register_action(handler_name, function(target_nid, aid, raw_event)
                return fn(make_event(ctx, event_name, raw_event and raw_event.target or target_nid, nid, raw_event))
            end)
        end
        local attrs = ns.attrs[nid] or {}
        ns.attrs[nid] = attrs
        attrs[attr_name] = handler_name
    end

    local function live_nid(bundle_nid)
        if type(bundle_nid) ~= "number" then return nil end
        return (mount.bundle_id_map and mount.bundle_id_map[bundle_nid]) or bundle_nid
    end

    local function bind_element_to_state(nid, binding)
        local path = binding.path
        if type(path) ~= "string" or path == "" then return end
        local prop = binding.prop or "value"
        local mode = binding.mode or "twoway"
        local h = make_handle(ctx, nid)
        local current = mount.state:get(path)
        if current ~= nil then h[prop] = current end
        mount.state:watch(path, function(new_value)
            if h[prop] ~= new_value then h[prop] = new_value end
        end)
        if mode == "twoway" or mode == "to_state" then
            h:addEventListener(binding.event or "input", function()
                mount.state:set(path, h[prop])
            end)
            if binding.event ~= "change" then
                h:addEventListener("change", function()
                    mount.state:set(path, h[prop])
                end)
            end
        end
    end

    if mount.bundle and mount.bundle.actions then
        for i = 1, #mount.bundle.actions do
            local a = mount.bundle.actions[i]
            local nid = live_nid(a.node_id or a.nid)
            local event_name = a.event or "click"
            local handler = a.handler or a.action or a.action_id
            if nid and handler then
                register_handler_attr(nid, event_name, EVENT_ATTR[event_name] or ("on" .. event_name), handler)
            end
        end
    end

    if mount.bundle and mount.bundle.bindings then
        for i = 1, #mount.bundle.bindings do
            local b = mount.bundle.bindings[i]
            local nid = live_nid(b.node_id or b.nid)
            if nid then bind_element_to_state(nid, b) end
        end
    end

    ns:walk_depth_first(root_id, function(nid)
        local attrs = ns.attrs[nid]
        if not attrs then return end
        for event_name, camel in pairs(EVENT_ATTR) do
            local lower = camel:lower()
            local handler_name = attrs[camel] or attrs[lower]
            if handler_name then register_handler_attr(nid, event_name, camel, handler_name) end
        end
        local data_action = attrs["data-action"]
        if data_action then
            local tag = tag_name(ctx, nid)
            local event_name = (tag == "form") and "submit" or "click"
            local attr_name = EVENT_ATTR[event_name] or "onClick"
            register_handler_attr(nid, event_name, attr_name, data_action)
        end
    end)
end

return ScriptRuntime



