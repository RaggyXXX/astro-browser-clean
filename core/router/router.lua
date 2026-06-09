------------------------------------------------------------
-- ext_core_astro_ui_lib / core / router / router.lua
-- Client-side router for one window. Nested layouts + page outlets.
--
-- Usage:
--   local Router = require("core/router/router")
--   local r = Router.new(engine, "app")
--   r:set_layout(shell_bundle)                -- optional shared shell
--   r:register("/",            dashboard_bundle)
--   r:register("/settings",    settings_bundle)
--   r:register("/users/:id",   user_bundle)
--   r:register("/products/*",  products_bundle)
--   r:navigate("/")
--
-- Bundles loaded into a layout are grafted into the layout's nearest
-- data-outlet / #outlet node via DOM mutation -" the shared shell stays
-- mounted across navigations, preserving script state and avoiding
-- flicker. Without a layout, each navigate is a full engine:mount.
--
-- Nested layouts: register a layout-descriptor:
--   r:register("/settings", {
--       layout   = settings_shell_bundle,
--       children = {
--           { path = "/settings/profile",  page = profile_bundle  },
--           { path = "/settings/security", page = security_bundle },
--       },
--   })
--
-- The engine walks the layout stack on each navigation: remounts only
-- the layouts that changed, and swaps the deepest outlet.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Router = {}
Router.__index = Router

local ScriptRuntime = require("core/script/script_runtime")
local StyleEngine   = require("core/style/style_engine")
local InputText     = require("core/components/input_text")
local TextareaComp  = require("core/components/textarea")
local SelectComp    = require("core/components/select")
local Slider        = require("core/components/slider")
local SwitchComp    = require("core/components/switch")
local InputNumber   = require("core/components/input_number")
local InputColor    = require("core/components/input_color")
local ParticleEmitter = require("core/components/particle_emitter")
local SoundTrigger  = require("core/components/sound_trigger")

local function update_history(self, path, params, replace)
    local entry = { path = path, params = params }
    if replace then
        if self._history_idx > 0 then
            self._history[self._history_idx] = entry
        else
            self._history[1] = entry
            self._history_idx = 1
        end
        return
    end
    for i = #self._history, self._history_idx + 1, -1 do
        self._history[i] = nil
    end
    self._history[#self._history + 1] = entry
    self._history_idx = #self._history
end

------------------------------------------------------------
-- Path / pattern compilation
------------------------------------------------------------

--- Compile a path pattern (e.g. "/users/:id", "/files/*") into a
--- Lua-pattern + list of captured param names.
---@param path string
---@return string  lua pattern anchored at start/end
---@return table   list of param names in capture order
local function compile_pattern(path)
    local param_names = {}
    -- Escape Lua pattern magic chars except what we want to keep
    local p = path:gsub("[%%%.%(%)%+%?%^%$%[%]]", "%%%0")
    -- :name → capture group
    p = p:gsub(":([%w_]+)", function(name)
        param_names[#param_names + 1] = name
        return "([^/]+)"
    end)
    -- * → greedy any
    p = p:gsub("%*", ".*")
    return "^" .. p .. "$", param_names
end

--- Parse a URL-like path into { pathname, query = {k=v, ...}, hash }.
local function split_path(full)
    if type(full) ~= "string" then return { pathname = "/", query = {} } end
    local hash_at = full:find("#", 1, true)
    local hash = nil
    if hash_at then
        hash = full:sub(hash_at + 1)
        full = full:sub(1, hash_at - 1)
    end
    local q_at = full:find("?", 1, true)
    local query = {}
    if q_at then
        local q = full:sub(q_at + 1)
        full = full:sub(1, q_at - 1)
        for pair in q:gmatch("[^&]+") do
            local k, v = pair:match("^([^=]+)=?(.*)$")
            if k then query[k] = v or "" end
        end
    end
    return { pathname = full, query = query, hash = hash }
end

------------------------------------------------------------
-- DOM helpers
------------------------------------------------------------

--- Find the first descendant (or self) whose attrs[data-outlet] or id
--- matches `name`.  `name` nil means "any outlet".
---@param ns    table
---@param root  number
---@param name  string|nil
---@return number|nil
local function find_outlet(ns, root, name)
    if not root or root == 0 then return nil end
    local found = nil
    ns:walk_depth_first(root, function(nid)
        if found then return end
        local attrs = ns.attrs[nid]
        if attrs then
            local o = attrs["data-outlet"]
            if o and (name == nil or o == name) then
                found = nid
                return
            end
            -- Convention: id="outlet" also works
            if not name then
                local id_sid = ns.id_str[nid]
                if id_sid and id_sid ~= 0 and ns._st:get(id_sid) == "outlet" then
                    found = nid
                    return
                end
            end
        end
    end)
    return found
end

--- Remove all children of a node.
local function clear_children(ns, nid)
    local cid = ns.first_child[nid] or 0
    while cid ~= 0 do
        local next_cid = ns.next_sibling[cid] or 0
        -- Walk + remove subtree
        local stack = { cid }
        local collected = {}
        while #stack > 0 do
            local top = stack[#stack]; stack[#stack] = nil
            collected[#collected + 1] = top
            local c = ns.first_child[top] or 0
            while c ~= 0 do
                stack[#stack + 1] = c
                c = ns.next_sibling[c] or 0
            end
        end
        for i = #collected, 1, -1 do
            ns:remove_node(collected[i])
        end
        cid = next_cid
    end
end

--- Graft a bundle's node tree as children of `outlet`.  Returns the list of
--- grafted root nids (usually just the page's virtual root).
local function graft_bundle(ns, outlet, bundle)
    local p_nodes   = bundle.nodes
    local p_strings = bundle.strings or {}
    local f_count   = p_nodes and #p_nodes.tag or 0
    if f_count == 0 then return {} end

    local id_map = {}
    for i = 1, f_count do
        local tag_sid = p_nodes.tag[i]
        local tag_str = p_strings[tag_sid] or "div"
        local id_sid  = p_nodes.id_str[i] or 0
        local id_str  = (id_sid ~= 0) and p_strings[id_sid] or nil
        local cls_sids = p_nodes.class_list[i] or {}
        local cls_names = {}
        for ci = 1, #cls_sids do
            cls_names[ci] = p_strings[cls_sids[ci]]
        end
        local ntype = p_nodes.node_type[i] or 1
        local text  = p_nodes.text_content[i]
        local attr  = p_nodes.attrs[i] or {}
        id_map[i] = ns:create_node(tag_str, id_str, cls_names, ntype, text, attr)
    end
    local roots = {}
    for i = 1, f_count do
        local f_parent = p_nodes.parent[i] or 0
        local live = id_map[i]
        if f_parent == 0 then
            ns:append_child(outlet, live)
            roots[#roots + 1] = live
        else
            ns:append_child(id_map[f_parent], live)
        end
    end
    return roots
end

local function collect_text(ns, nid)
    local out = {}
    local function walk(id)
        if ns.node_type[id] == ns.TEXT then
            out[#out + 1] = ns.text_content[id] or ""
        end
        local c = ns.first_child[id] or 0
        while c ~= 0 do
            walk(c)
            c = ns.next_sibling[c] or 0
        end
    end
    walk(nid)
    return table.concat(out)
end

local function clear_text_descendants(ns, nid)
    local cid = ns.first_child[nid] or 0
    while cid ~= 0 do
        if ns.node_type[cid] == ns.TEXT then
            ns.text_content[cid] = ""
        else
            clear_text_descendants(ns, cid)
        end
        cid = ns.next_sibling[cid] or 0
    end
end

local function normalize_select_options(ns, select_nid)
    local attrs = ns.attrs[select_nid] or {}
    if attrs.options and type(attrs.options) == "table" then return end
    local options = {}
    local option_values = {}
    local selected_index = 1
    local function collect(parent)
        local child = ns.first_child[parent] or 0
        while child ~= 0 do
            local tag = ns._st:get(ns.tag[child])
            if tag == "option" then
                local option_attrs = ns.attrs[child] or {}
                local label = option_attrs.label or collect_text(ns, child)
                label = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if label ~= "" then
                    options[#options + 1] = label
                    option_values[#option_values + 1] = option_attrs.value ~= nil and tostring(option_attrs.value) or label
                    if option_attrs.selected ~= nil then selected_index = #options end
                end
            elseif tag == "optgroup" then
                collect(child)
            end
            child = ns.next_sibling[child] or 0
        end
    end
    collect(select_nid)
    if #options > 0 then
        attrs.options = options
        attrs.option_values = option_values
        attrs.selected_index = selected_index
        attrs._default_selected_index = selected_index
        attrs.value = option_values[selected_index] or options[selected_index] or options[1] or ""
        ns.attrs[select_nid] = attrs
        ns.text_content[select_nid] = options[selected_index] or options[1] or ""
    end
end

local function normalize_form_value(ns, nid, tag_str)
    local attrs = ns.attrs[nid] or {}
    if tag_str == "input" then
        local input_type = tostring(attrs.type or "text"):lower()
        if input_type ~= "checkbox" and input_type ~= "radio"
           and input_type ~= "range" and input_type ~= "color"
           and input_type ~= "file" then
            local value = attrs.value
            if input_type == "submit" and value == nil then
                value = "Submit"
            elseif input_type == "reset" and value == nil then
                value = "Reset"
            elseif value == nil then
                value = ""
            end
            ns.text_content[nid] = tostring(value)
            attrs._default_value = tostring(value)
        elseif input_type == "range" or input_type == "color" then
            attrs._default_value = attrs.value
        elseif input_type == "checkbox" or input_type == "radio" then
            attrs._default_checked = attrs.checked ~= nil and attrs.checked ~= false
        end
        ns.attrs[nid] = attrs
    elseif tag_str == "textarea" then
        ns.text_content[nid] = collect_text(ns, nid)
        attrs._default_value = ns.text_content[nid]
        ns.attrs[nid] = attrs
        clear_text_descendants(ns, nid)
    end
end

local function initialize_grafted_subtree(mount, roots)
    if not mount or not roots then return end
    local ns = mount.node_store
    if not ns then return end
    mount.components = mount.components or {}
    ns._components = mount.components
    local function apply_checked(nid)
        local attrs = ns.attrs[nid] or {}
        local pseudo = ns.pseudo[nid]
        if pseudo and attrs.checked ~= nil and attrs.checked ~= false then
            pseudo.checked = true
            attrs._default_checked = true
            ns.attrs[nid] = attrs
        end
    end
    for ri = 1, #roots do
        ns:walk_depth_first(roots[ri], function(nid)
            local tag_str = ns._st:get(ns.tag[nid])
            if tag_str == "input" then
                normalize_form_value(ns, nid, tag_str)
                local attrs = ns.attrs[nid] or {}
                local input_type = tostring(attrs.type or "text"):lower()
                if input_type == "number" then
                    mount.components[nid] = { type = "input-number", inst = InputNumber.new() }
                elseif input_type == "color" then
                    mount.components[nid] = { type = "input-color", inst = InputColor.new() }
                elseif input_type == "range" then
                    mount.components[nid] = { type = "slider", inst = Slider.new() }
                elseif input_type == "checkbox" then
                    apply_checked(nid)
                    ns._checkboxes[nid] = true
                elseif input_type == "radio" then
                    apply_checked(nid)
                    ns._radios[nid] = true
                elseif input_type ~= "button" and input_type ~= "submit" and input_type ~= "reset" then
                    local inst = InputText.new()
                    if input_type == "password" then
                        inst._mask_char = string.char(226, 128, 162)
                        if ns.pseudo[nid] then ns.pseudo[nid]._input_mask_char = inst._mask_char end
                    end
                    mount.components[nid] = { type = "input", inst = inst }
                end
            elseif tag_str == "textarea" then
                normalize_form_value(ns, nid, tag_str)
                mount.components[nid] = { type = "textarea", inst = TextareaComp.new() }
            elseif tag_str == "select" then
                normalize_select_options(ns, nid)
                local inst = SelectComp.new()
                local attrs = ns.attrs[nid] or {}
                if type(attrs.selected_index) == "number" then inst.selected_index = attrs.selected_index end
                mount.components[nid] = { type = "select", inst = inst }
            elseif tag_str == "slider" then
                mount.components[nid] = { type = "slider", inst = Slider.new() }
            elseif tag_str == "switch" then
                apply_checked(nid)
                mount.components[nid] = { type = "switch", inst = SwitchComp.new() }
            elseif tag_str == "checkbox" then
                apply_checked(nid)
            elseif tag_str == "radio" then
                apply_checked(nid)
            elseif tag_str == "particle-emitter" then
                mount.components[nid] = { type = "particle-emitter", inst = ParticleEmitter.new() }
            elseif tag_str == "sound" then
                mount.components[nid] = { type = "sound", inst = SoundTrigger.new() }
            end
        end)
    end
end

------------------------------------------------------------
-- Router
------------------------------------------------------------

--- Create a router bound to a window.
---@param engine table
---@param win_id string
---@param opts   table|nil  { outlet = "main" }  -" optional outlet name
---@return table
function Router.new(engine, win_id, opts)
    opts = opts or {}
    local self = setmetatable({}, Router)
    self.engine     = engine
    self.win_id     = win_id
    self.outlet     = opts.outlet  -- name to match, nil = any
    self._routes    = {}            -- array of {regex, param_names, tree-entry}
    self._layout    = nil           -- root layout bundle
    self._history   = {}
    self._history_idx = 0
    -- Tracks which layouts are currently mounted (in order from outermost in)
    self._mounted_layouts = {}
    -- The last page info so we can skip redundant navigates
    self._current   = nil
    -- Set true when the layout has been mounted at least once
    self._shell_mounted = false
    return self
end

--- Set the single shared layout for this router.
--- The layout bundle is expected to contain an element with
--- `data-outlet` or id="outlet" where pages will be rendered.
---@param layout_bundle table
function Router:set_layout(layout_bundle)
    self._layout = layout_bundle
end

--- Register a route. `spec` can be either:
---   * a bundle (page)                       -" flat route
---   * { layout = bundle, children = {...} } -" nested layout with sub-routes
---@param path string
---@param spec table  page bundle OR { layout, children }
function Router:register(path, spec)
    self:_register(path, spec, {})
end

function Router:_register(path, spec, layout_stack)
    local regex, param_names = compile_pattern(path)
    self._routes[#self._routes + 1] = {
        path        = path,
        regex       = regex,
        param_names = param_names,
        spec        = spec,
        layouts     = layout_stack or {},
    }
    -- Recursive register for nested layout children
    if spec and spec.children then
        local child_layouts = {}
        for i = 1, #(layout_stack or {}) do child_layouts[i] = layout_stack[i] end
        if spec.layout then child_layouts[#child_layouts + 1] = spec.layout end
        for i = 1, #spec.children do
            local ch = spec.children[i]
            if ch and ch.path then
                self:_register(ch.path, ch.page or ch, child_layouts)
            end
        end
    end
end

--- Match a pathname against registered routes.  Returns the spec + params,
--- or nil if none matches.
---@param pathname string
---@return table|nil  spec
---@return table       params
function Router:_match(pathname)
    for i = 1, #self._routes do
        local r = self._routes[i]
        -- `string.match` returns no values for a successful match of a
        -- pattern without captures, so `#caps == 0` cannot reliably tell
        -- "no match" from "matched, no params".  Use `string.find` to test
        -- match status independently of capture count, then `string.match`
        -- to actually extract captures.
        local match_start = pathname:find(r.regex)
        if match_start ~= nil then
            local caps = { pathname:match(r.regex) }
            local params = {}
            for j = 1, #r.param_names do
                params[r.param_names[j]] = caps[j]
            end
            return r.spec, params, r.path, r.layouts
        end
    end
    return nil, {}, nil, nil
end

--- Hook all <a data-route href="..."> links in the current mount so
--- clicks navigate through the router instead of triggering a full
--- engine:load_url.  Idempotent.
function Router:_hook_nav_links()
    local mount = self.engine._mounts[self.win_id]
    if not mount then return end
    local ns = mount.node_store
    local es = mount.event_system
    if not es or not ns then return end

    local self_ref = self
    es:register_action("__router_click", function(nid)
        local attrs = ns.attrs[nid]
        local href = attrs and attrs.href
        if href and href ~= "" then
            self_ref:navigate(href)
        end
    end)

    ns:walk_depth_first(mount.root_id, function(nid)
        local attrs = ns.attrs[nid]
        if not attrs then return end
        local tag = ns._st:get(ns.tag[nid])
        if tag == "a" and attrs["data-route"] ~= nil then
            -- Prefer the router-hook over the default _link_click action
            attrs.onClick = attrs.onClick or "__router_click"
            attrs.onclick = attrs.onclick or "__router_click"
        end
    end)
end

--- Inject the `astro.route` API into the mount's script env.  Called
--- immediately before running a page's scripts so navigation helpers
--- are available.
function Router:_inject_route_api(mount, params, pathname)
    local route = {
        path     = pathname,
        params   = params or {},
        query    = (self._current and self._current.query) or {},
    }
    local self_ref = self
    function route.navigate(path, opts) self_ref:navigate(path, opts) end
    function route.back()   self_ref:back()   end
    function route.forward() self_ref:forward() end
    function route.replace(path) self_ref:navigate(path, { replace = true }) end
    mount._route = route
    return route
end

--- Mount the layout (idempotent across navigations) and return the outlet nid.
function Router:_ensure_layout()
    local mount = self.engine._mounts[self.win_id]

    -- If no layout bundle, nothing to do; pages are full-mounts.
    if not self._layout then return nil end

    -- First-time mount -" or shell was replaced
    if not self._shell_mounted then
        self.engine:mount(self.win_id, self._layout)
        self._shell_mounted = true
        self:_hook_nav_links()
    end

    mount = self.engine._mounts[self.win_id]
    if not mount then return nil end
    return find_outlet(mount.node_store, mount.root_id, self.outlet)
end

--- Navigate to a path.  Pushes onto history unless opts.replace = true.
---@param path string
---@param opts table|nil  { replace = boolean, params = table }
function Router:navigate(path, opts)
    opts = opts or {}
    local parts = split_path(path)
    local spec, params, matched_path, matched_layouts = self:_match(parts.pathname)
    if not spec then
        self.engine.platform:log_warning("[router] no route for: " .. parts.pathname)
        return false
    end

    -- A layout-descriptor is { layout = bundle, children = {...} }.
    -- When the matched spec IS a layout-descriptor, we set the layout and
    -- wait for a child path to render content.  This shouldn't normally
    -- be navigated to directly -" but we accept it.
    local page_bundle
    if type(spec) == "table" and spec.layout and not spec.nodes then
        -- Register the inner layout as current and bail -" the caller is
        -- expected to navigate to a concrete child path.
        self._layout = spec.layout
        self._shell_mounted = false
        self.engine.platform:log_warning(
            "[router] navigated to layout-only path " .. parts.pathname ..
            " - render the layout shell, no page content")
        -- Update `_current` and history so subsequent back()/forward()
        -- agree with the rendered shell; otherwise the history index would
        -- point at an entry that `_current` knows nothing about and we'd
        -- replay stale `back` targets after a layout-only navigate.
        self._current = {
            path   = parts.pathname,
            params = params,
            query  = parts.query,
        }
        update_history(self, path, params, opts.replace)
        self:_ensure_layout()
        return true
    elseif type(spec) == "table" and spec.page then
        page_bundle = spec.page
    else
        page_bundle = spec  -- raw bundle
    end

    self._current = {
        path   = parts.pathname,
        params = params,
        query  = parts.query,
    }
    update_history(self, path, params, opts.replace)

    local has_nested_layouts = matched_layouts and #matched_layouts > 0
    if has_nested_layouts then
        local base_layout = self._layout or matched_layouts[1]
        if not base_layout then return false end
        self.engine:mount(self.win_id, base_layout)
        self._shell_mounted = true
        local mount = self.engine._mounts[self.win_id]
        if not mount then return false end
        local ns = mount.node_store
        local route = self:_inject_route_api(mount, params, parts.pathname)
        local rules = {}
        if base_layout.rules then
            for i = 1, #base_layout.rules do rules[#rules + 1] = base_layout.rules[i] end
        end
        local start_i = self._layout and 1 or 2
        local outlet = find_outlet(ns, mount.root_id, self.outlet)
        for li = start_i, #matched_layouts do
            if not outlet then return false end
            clear_children(ns, outlet)
            local layout_bundle = matched_layouts[li]
            local roots = graft_bundle(ns, outlet, layout_bundle)
            initialize_grafted_subtree(mount, roots)
            if layout_bundle.rules then
                for i = 1, #layout_bundle.rules do rules[#rules + 1] = layout_bundle.rules[i] end
            end
            outlet = nil
            for ri = 1, #roots do
                outlet = find_outlet(ns, roots[ri], self.outlet)
                if outlet then break end
            end
        end
        if not outlet then outlet = find_outlet(ns, mount.root_id, self.outlet) end
        if not outlet then return false end
        clear_children(ns, outlet)
        local roots = graft_bundle(ns, outlet, page_bundle)
        initialize_grafted_subtree(mount, roots)
        if mount.style_engine then mount.style_engine:load_rules(rules) end
        if page_bundle.rules and mount.style_engine then mount.style_engine:append_rules(page_bundle.rules) end
        if page_bundle.scripts and #page_bundle.scripts > 0 then
            pcall(ScriptRuntime.run_scripts, self.engine, self.win_id, mount, page_bundle.scripts)
        end
        self:_hook_nav_links()
        mount.style_dirty = true
        mount.layout_dirty = true
        return true
    end

    local outlet = self:_ensure_layout()
    local route = nil

    if outlet and self._layout then
        -- Outlet-swap: shell stays mounted, only outlet content changes
        local mount = self.engine._mounts[self.win_id]
        local ns = mount.node_store
        clear_children(ns, outlet)
        local roots = graft_bundle(ns, outlet, page_bundle)
        initialize_grafted_subtree(mount, roots)

        route = self:_inject_route_api(mount, params, parts.pathname)

        if mount.style_engine then
            mount.style_engine:load_rules((mount.bundle and mount.bundle.rules) or (self._layout and self._layout.rules) or {})
        end
        if page_bundle.rules then
            mount.style_engine:append_rules(page_bundle.rules)
        end
        if page_bundle.scripts and #page_bundle.scripts > 0 then
            pcall(ScriptRuntime.run_scripts, self.engine, self.win_id, mount, page_bundle.scripts)
        end
        self:_hook_nav_links()  -- pick up newly-rendered data-route links
        mount.style_dirty = true
        mount.layout_dirty = true
    else
        -- No layout: full-page navigation
        route = {
            path     = parts.pathname,
            params   = params or {},
            query    = parts.query or {},
        }
        local self_ref = self
        function route.navigate(p, nav_opts) self_ref:navigate(p, nav_opts) end
        function route.back() self_ref:back() end
        function route.forward() self_ref:forward() end
        function route.replace(p) self_ref:navigate(p, { replace = true }) end
        self.engine:mount(self.win_id, page_bundle, { route = route })
        local mount = self.engine._mounts[self.win_id]
        if mount then
            mount._route = route
            self:_hook_nav_links()
        end
    end
    return true
end

--- Navigate to the previous path in history.
function Router:back()
    if self._history_idx <= 1 then return false end
    self._history_idx = self._history_idx - 1
    local entry = self._history[self._history_idx]
    if not entry then return false end
    self:navigate(entry.path, { replace = true })
    return true
end

--- Navigate forward in history.
function Router:forward()
    if self._history_idx >= #self._history then return false end
    self._history_idx = self._history_idx + 1
    local entry = self._history[self._history_idx]
    if not entry then return false end
    self:navigate(entry.path, { replace = true })
    return true
end

--- Get the current route {path, params, query}.
function Router:current()
    return self._current
end

return Router



