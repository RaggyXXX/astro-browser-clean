------------------------------------------------------------
-- ext_core_astro_ui_lib / core / engine.lua
-- Engine orchestrator: owns platform, display list, input,
-- window manager, and the full DOM/style/layout/paint
-- pipeline.  Drives the per-frame update/render pipeline
-- via the platform render callback.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Bootstrap do
    local ok, result = pcall(require, "root/ext_core_astro_ui_lib/core/require_bootstrap")
    Bootstrap = ok and result or require("core/require_bootstrap")
end

Bootstrap.install()

local DisplayList      = require("core/paint/display_list")
local InputState       = require("core/input/input_state")
local WindowManager    = require("core/window/window_manager")

-- Phase 2 subsystems
local StringTable   = require("core/dom/string_table")
local NodeStore     = require("core/dom/node_store")
local EventSystem   = require("core/events/event_system")
local StyleEngine   = require("core/style/style_engine")
local LayoutEngine  = require("core/layout/layout_engine")
local Painters      = require("core/paint/painters")
local Gradient      = require("core/paint/gradient")
-- Phase 3 subsystems
local InputText    = require("core/components/input_text")
local TextareaComp = require("core/components/textarea")
local Checkbox     = require("core/components/checkbox")
local Radio        = require("core/components/radio")
local SwitchComp   = require("core/components/switch")
local Slider       = require("core/components/slider")
local SelectComp   = require("core/components/select")
local ScrollEngine     = require("core/scroll/scroll_engine")
local Devtools         = require("core/debug/devtools")
local ParticleEmitter  = require("core/components/particle_emitter")
local InputNumber      = require("core/components/input_number")
local InputColor       = require("core/components/input_color")
local SoundTrigger     = require("core/components/sound_trigger")
local Counters         = require("core/style/counters")
local TextWrap         = require("core/layout/text_wrap")
local ContextMenu      = require("core/context_menu")
local Progress         = require("core/components/progress")
local MeterComp        = require("core/components/meter")
local DetailsComp      = require("core/components/details")
local DialogComp       = require("core/components/dialog")

-- HTML parser (for load_html/load_file/load_url)
local HTMLParser   = require("core/html/html_parser")

-- Script runtime (runs <script lang="lua"> blocks)
local ScriptRuntime = require("core/script/script_runtime")

-- URL resolver (for relative <img src>, <link href>, etc.)
local Url          = require("core/util/url")
local Clipboard    = require("core/util/clipboard")

-- Bundle validator (for compiler-produced bundles)
local BundleValidator = require("core/util/bundle_validator")

-- Font system
local FontManager  = require("core/fonts/font_manager")

-- Icon system
local IconCache    = require("core/icons/icon_cache")

-- Profiler
local FrameProfiler    = require("core/debug/frame_profiler")

-- Tier 1: Texture cache + Transition engine
local TextureCache     = require("core/assets/texture_cache")
local TransitionEngine = require("core/animation/transition_engine")

-- SVG rendering
local SvgRenderer = require("core/svg/renderer")
local SvgConstants = require("core/svg/constants")

local Engine = {}
Engine.__index = Engine

local function shift_layout_tree(ns, root_id, dx, dy)
    if dx == 0 and dy == 0 then return end
    ns:walk_depth_first(root_id, function(nid)
        local lay = ns.layout[nid]
        if lay then
            if lay.x then lay.x = lay.x + dx end
            if lay.y then lay.y = lay.y + dy end
            if lay.content_x then lay.content_x = lay.content_x + dx end
            if lay.content_y then lay.content_y = lay.content_y + dy end
            if lay.pad_x then lay.pad_x = lay.pad_x + dx end
            if lay.pad_y then lay.pad_y = lay.pad_y + dy end
        end
    end)
end

local function node_is_in_open_dialog(ns, nid)
    local cur = nid
    while cur and cur ~= 0 do
        local tag_id = ns.tag and ns.tag[cur]
        local tag = tag_id and ns._st:get(tag_id)
        if tag == "dialog" then
            local attrs = ns.attrs and ns.attrs[cur]
            return attrs and attrs.open ~= nil
        end
        cur = ns.parent and ns.parent[cur]
    end
    return false
end

local function intersect_rect(ax, ay, aw, ah, bx, by, bw, bh)
    local x1 = math.max(ax, bx)
    local y1 = math.max(ay, by)
    local x2 = math.min(ax + aw, bx + bw)
    local y2 = math.min(ay + ah, by + bh)
    return x1, y1, x2 - x1, y2 - y1
end

local function component_ancestor_clip_rect(ns, root_id, nid)
    local x, y, w, h
    local has_clip = false
    local anc = ns.parent and ns.parent[nid] or 0

    while anc and anc ~= 0 do
        local computed = ns.computed and ns.computed[anc]
        local lay = ns.layout and ns.layout[anc]
        if computed and lay then
            local is_root = (anc == root_id) or (not ns.parent[anc]) or (ns.parent[anc] == 0)
            local root_default_overflow = is_root
                and computed.overflow == nil
                and computed.overflow_x == nil
                and computed.overflow_y == nil
            local ox = computed.overflow_x or computed.overflow or "visible"
            local oy = computed.overflow_y or computed.overflow or (is_root and "auto" or "visible")
            if not root_default_overflow and (ox ~= "visible" or oy ~= "visible") then
                local cx = lay.pad_x or lay.content_x or lay.x or 0
                local cy = lay.pad_y or lay.content_y or lay.y or 0
                local cw = lay.pad_w or lay.content_w or lay.w or 0
                local ch = lay.pad_h or lay.content_h or lay.h or 0
                if has_clip then
                    x, y, w, h = intersect_rect(x, y, w, h, cx, cy, cw, ch)
                else
                    x, y, w, h = cx, cy, cw, ch
                    has_clip = true
                end
                if w <= 0 or h <= 0 then
                    return nil, nil, nil, nil, true
                end
            end
        end
        anc = ns.parent and ns.parent[anc] or 0
    end

    if not has_clip then
        return nil, nil, nil, nil, false
    end

    local cr = Painters._clip_rect
    if cr then
        x, y, w, h = intersect_rect(x, y, w, h, cr[1], cr[2], cr[3], cr[4])
        if w <= 0 or h <= 0 then
            return nil, nil, nil, nil, true
        end
    end

    return x, y, w, h, true
end

local function pcall_component_method_with_clip(dl, ns, root_id, nid, method, inst, platform)
    local cx, cy, cw, ch, needs_clip = component_ancestor_clip_rect(ns, root_id, nid)
    if needs_clip and not cx then
        return true
    end
    if needs_clip then dl:clip_push(cx, cy, cw, ch) end
    local ok, err = pcall(method, inst, ns, nid, dl, platform)
    if needs_clip then dl:clip_pop() end
    return ok, err
end

local function pcall_component_function_with_clip(dl, ns, root_id, nid, fn, platform)
    local cx, cy, cw, ch, needs_clip = component_ancestor_clip_rect(ns, root_id, nid)
    if needs_clip and not cx then
        return true
    end
    if needs_clip then dl:clip_push(cx, cy, cw, ch) end
    local ok, err = pcall(fn, ns, nid, dl, platform)
    if needs_clip then dl:clip_pop() end
    return ok, err
end

local function platform_ticks(platform)
    if platform and type(platform.profiler_ticks) == "function" then
        local ok, ticks = pcall(platform.profiler_ticks, platform)
        if ok and type(ticks) == "number" then
            return ticks
        end
    end
    if platform and type(platform.time) == "function" then
        local ok, now = pcall(platform.time, platform)
        if ok and type(now) == "number" then
            return now
        end
    end
    return 0
end

local function platform_ticks_per_second(platform)
    if platform and type(platform.profiler_ticks_per_second) == "function" then
        local ok, tps = pcall(platform.profiler_ticks_per_second, platform)
        if ok and type(tps) == "number" and tps > 0 then
            return tps
        end
    end
    return 1
end

local function create_platform(config)
    if config.platform then
        return config.platform
    end
    if config.platform_factory then
        return config.platform_factory()
    end
    local SylvanasPlatform = require("core/platform/sylvanas_platform")
    return SylvanasPlatform.new()
end

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new Engine instance.
---@param config table|nil  optional configuration overrides
---@return table  Engine instance
function Engine.new(config)
    config = config or {}

    local self = setmetatable({}, Engine)

    -- Core subsystems
    self.platform       = create_platform(config)
    if type(Clipboard.set_platform) == "function" then
        Clipboard.set_platform(self.platform)
    end
    self.display_list   = DisplayList.new()
    self.input          = InputState.new(self.platform)
    self.window_manager = WindowManager.new()

    -- Device pixel ratio. Engine layout and `line-height: normal` rounding
    -- must match the host browser/game DPR for sub-pixel parity. Callers
    -- pass `config.dpr` at boot and `engine:set_dpr(...)` whenever the
    -- host's DPR changes (window moved between Retina/standard monitors,
    -- Windows display-scale switched, etc.). Default 1.0 means "treat CSS
    -- pixels as device pixels" -" that matches every existing test that
    -- doesn't explicitly opt in.
    --
    -- When the host did not pass an explicit `config.dpr`, ask the platform
    -- for its native scale (Sylvanas derives this from screen_w / 1920;
    -- browser hosts override via __astro_set_dpr right after Engine.new).
    -- The method is optional on the platform interface -" missing or
    -- returning nil falls back to 1, preserving legacy mock platform behavior.
    local resolved_dpr = config.dpr
    if resolved_dpr == nil and self.platform and type(self.platform.get_dpr) == "function" then
        local ok, platform_dpr = pcall(self.platform.get_dpr, self.platform)
        if ok and type(platform_dpr) == "number" and platform_dpr > 0 then
            resolved_dpr = platform_dpr
        end
    end
    self._dpr = resolved_dpr or 1

    -- Font system
    self.font_manager   = FontManager:new(self.platform)
    self.default_font   = config.default_font or "inter"
    Painters._font_manager = self.font_manager
    Painters._default_font = self.default_font
    Painters._dpr = self._dpr
    if self.display_list and self.display_list.set_dpr then
        self.display_list:set_dpr(self._dpr)
    end
    SvgRenderer._font_manager = self.font_manager
    SvgRenderer._default_font = self.default_font

    -- Auto-load default font
    self.font_manager:load(self.default_font)

    -- Icon system
    self.icon_cache = IconCache:new(self.platform)
    Painters._icon_cache = self.icon_cache

    -- Texture cache ("always" = disk cache, "session" = memory only, "none" = re-download)
    self.texture_cache = TextureCache.new(self.platform, config.texture_cache_mode or "always")
    Painters._texture_cache = self.texture_cache

    -- Mount registry: win_id -> mount structure
    self._mounts = {}

    -- Running state
    self._running = false

    -- External drag passthrough
    self._was_over_window = false
    self._external_drag   = false

    -- Optional user callbacks
    self._on_frame = config.on_frame or nil

    -- Context menu (window-independent overlay)
    self.context_menu = ContextMenu.new()

    -- Global keyframes registry (shared across mounts)
    self._keyframes = {}

    -- Time tracking for transitions/animations
    self._start_time = nil

    -- Frame profiler
    local profiler_platform = self.platform
    self._profiler = FrameProfiler.new(function()
        return platform_ticks(profiler_platform)
    end, function()
        return platform_ticks_per_second(profiler_platform)
    end)

    -- Frame throttling
    self._last_ui_frame_time = 0
    self._ui_fps_cap = 60
    self._ui_idle_fps_cap = 30
    self._force_frame = false
    self._is_idle = false
    self._idle_frame_count = 0
    self._idle_threshold = 30

    return self
end

------------------------------------------------------------
-- Device pixel ratio
------------------------------------------------------------

--- Update the device pixel ratio. Mirrors the new value into the static
--- Painters DPR so paint-side per-component rounding matches layout-side
--- rounding for `line-height: normal`. Marks every mount layout-dirty so
--- font-metric caches that key on `(family, weight, style, font_size)` are
--- re-evaluated under the new DPR. Cheap when DPR is unchanged.
---@param dpr number  device pixel ratio (e.g. 1, 1.1, 1.5, 2)
function Engine:set_dpr(dpr)
    dpr = tonumber(dpr) or 1
    if dpr <= 0 then dpr = 1 end
    if self._dpr == dpr then return end
    self._dpr = dpr
    Painters._dpr = dpr
    if self.display_list and self.display_list.set_dpr then
        self.display_list:set_dpr(dpr)
    end
    -- Propagate to every mount's LayoutEngine so Block._resolve_line_h /
    -- Inline.layout_run see the new DPR on the next re-layout pass.
    for _, mount in pairs(self._mounts) do
        if mount then
            if mount.layout_engine then
                mount.layout_engine._dpr = dpr
            end
            mount.layout_dirty = true
        end
    end
    -- The frame-throttle gate is consulted BEFORE we observe the dirty
    -- flags, so without forcing the next frame the engine could replay
    -- the cached display-list once more under stale line-height. Also
    -- invalidate the display-list length cache so the next paint pass
    -- doesn't short-circuit on a stale tail.
    self._force_frame = true
    self._dl_len = nil
end

--- Get the current device pixel ratio.
---@return number
function Engine:get_dpr()
    return self._dpr or 1
end

------------------------------------------------------------
-- Window management
------------------------------------------------------------

--- Create a window via the window manager.
---@param config table  window config (see WindowManager:create_window)
---@return table  window object
function Engine:create_window(config)
    return self.window_manager:create_window(config)
end

------------------------------------------------------------
-- Keyframe registration
------------------------------------------------------------

--- Register a keyframes definition for animations.
---@param name      string  animation name
---@param keyframes table   { {0, {prop=value,...}}, {100, {prop=value,...}} }
function Engine:register_keyframes(name, keyframes)
    self._keyframes[name] = keyframes
    -- Push to existing mounts
    for _, mount in pairs(self._mounts) do
        if mount.transition_engine then
            mount.transition_engine:register_keyframes(name, keyframes)
        end
    end
end

------------------------------------------------------------
-- Mounting
------------------------------------------------------------

--- Mount a parsed-value bundle (from HTMLParser.parse, or compiled output)
--- into a window. The bundle is treated as opaque.
---@param win_id string
---@param bundle table|nil
---@param opts   table|nil

--- Validate a parsed-value bundle. Returns { ok, errors, schema }.
--- Internal entry point -" not part of the supported public surface.
---@param bundle table
---@return table
function Engine.validate_bundle(bundle)
    return BundleValidator.validate(bundle)
end

--- Coerce a window argument to a string id.  Plugin authors occasionally
--- pass the full window table returned by `engine:create_window(...)`
--- where the public API expects the string id; without this normalisation
--- the engine ends up storing `_mounts[window_table]` while every later
--- lookup uses `_mounts[win.id]`, leaving the mount silently unreachable
--- (R3, observed via bridge probe 2026-05-23).
---@param arg string|table
---@return string|nil
local function _coerce_win_id(arg)
    if type(arg) == "string" then return arg end
    if type(arg) == "table" and type(arg.id) == "string" then return arg.id end
    return nil
end

--- Internal: look up a mount by win-id-or-window-table.  Use this anywhere
--- a public engine method indexes `self._mounts` so plugin authors can
--- pass either the string id or the table returned by create_window -"
--- both forms route to the same mount entry.
---@param win_id string|table
---@return table|nil mount
function Engine:_get_mount(win_id)
    local key = _coerce_win_id(win_id)
    if key == nil then return nil end
    return self._mounts[key]
end

function Engine:mount(win_id, bundle, opts)
    win_id = _coerce_win_id(win_id) or win_id
    self._last_loaded_win_id = win_id
    -- Drop any cached display-list snapshot.  If the previous mount on
    -- this window was already painted, the cached snapshot holds draw
    -- calls into now-replaced textures/glyphs and the throttled-frame
    -- replay path (around line 1148/1404) would render the old tree.
    self._dl_len = nil
    opts = opts or {}

    -- Validate early; log errors but don't refuse the mount (compilers may
    -- produce bundles that violate a specific field while still being
    -- mostly renderable). Strict failure is opt-in via opts.strict = true.
    if bundle then
        local v = BundleValidator.validate(bundle)
        if not v.ok then
            for i = 1, #v.errors do
                self.platform:log_warning("[astro bundle] " .. v.errors[i])
            end
            if opts.strict then
                self.platform:log_error("[astro bundle] validation failed, refusing mount (strict mode)")
                return
            end
        end
    end

    if not bundle then
        self._mounts[win_id] = {
            bundle        = nil,
            string_table  = nil,
            node_store    = nil,
            event_system  = nil,
            style_engine  = nil,
            layout_engine = nil,
            root_id       = 0,
            actions       = opts.actions or {},
            state         = {},
            style_dirty   = true,
            layout_dirty  = true,
        }
        return
    end

    -- Create subsystems for this window
    local st = StringTable.new()
    local ns = NodeStore.new(st)
    ns._platform = self.platform  -- expose platform for components (text measurement)
    ns._font_manager = self.font_manager
    ns._default_font = self.default_font
    ns._visited_urls = {}  -- track visited URLs for :link/:visited selectors

    -- Mount the bundle's DOM tree
    local root_id = ns:mount_bundle(bundle)
    local bundle_id_map = ns._last_mount_id_map or {}

    -- Create event system
    local es = EventSystem.new(ns)

    -- Create style engine and load rules
    local se = StyleEngine.new(ns)
    ns._style_engine = se  -- back-ref so painters/components can reach registries
    if bundle.rules then
        se:load_rules(bundle.rules)
    end

    -- Create layout engine (with font manager for custom font measurement)
    local le = LayoutEngine.new(ns, self.platform, self.font_manager)
    le.texture_cache = self.texture_cache
    le._default_font = self.default_font
    -- Mirror the engine's DPR onto the LayoutEngine so Block._resolve_line_h
    -- / Inline.layout_run can read `engine._dpr` directly (the `engine`
    -- argument they receive IS the LayoutEngine instance, not AstroEngine).
    -- Without this, `line-height: normal` resolves at the dpr=1 fallback
    -- branch even on Retina/110% hosts, producing visible line-height
    -- drift (e.g. fira-code @12 → 16 instead of the dpr-aware 15.45,
    -- compounding 1-3 px per case after the first <pre>/<code>).
    le._dpr = self._dpr

    -- Create scroll engine
    local scroll = ScrollEngine.new(ns, self.platform)
    -- Clear this mount's extent cache when nodes are recycled.  Must bind
    -- the specific scroll-engine instance: a free-function reference would
    -- carry no `self` and earlier left the cache module-scope, leaking
    -- across mounts.
    ns._on_node_remove = function(nid) scroll:clear_extent(nid) end
    -- Hand the scroll engine to the layout engine so it can invalidate the
    -- extent cache when descendant geometry changes.
    le.scroll_engine = scroll

    -- Create devtools
    local devtools = Devtools.new()

    -- Create transition engine
    local te = TransitionEngine.new()
    -- Register global keyframes
    for name, kf in pairs(self._keyframes) do
        te:register_keyframes(name, kf)
    end
    -- Register CSS @keyframes from parsed rules
    if bundle.rules and bundle.rules.keyframes then
        for name, kf in pairs(bundle.rules.keyframes) do
            te:register_keyframes(name, kf)
        end
    end

    -- Register @font-face rules
    if bundle.rules and bundle.rules.font_faces then
        for i = 1, #bundle.rules.font_faces do
            local ff = bundle.rules.font_faces[i]
            if ff.family and ff.src then
                self:register_font(ff.family, ff.src, ff.weight, ff.style)
            end
        end
    end

    -- Register action handlers from opts
    if opts.actions then
        for action_id, handler_fn in pairs(opts.actions) do
            es:register_action(action_id, handler_fn)
        end
    end

    -- Built-in <a> link click handler
    local engine_ref = self
    local mount_win_id = win_id
    es:register_action("_link_click", function(nid, href)
        -- Track visited URL for :visited selector
        if ns._visited_urls then
            ns._visited_urls[href] = true
        end
        -- Mark style dirty so :visited/:link selectors re-evaluate
        pcall(function() engine_ref:mark_dirty(mount_win_id, "style") end)
        -- Delegate to user navigation handler, if set -" user can return false
        -- to let the browser default take over, or return true to suppress it.
        if engine_ref._nav_handler then
            local ok, handled = pcall(engine_ref._nav_handler, href, mount_win_id)
            if ok and handled then return end
        end
        -- Browser default: navigate the same window to the href.
        if href and href ~= "" and href ~= "#" then
            -- in-page anchors "#foo" are no-ops for now
            if href:sub(1, 1) == "#" then return end

            local mount_ref = engine_ref._mounts[mount_win_id]
            local base = mount_ref and mount_ref._base_url
            local resolved = href
            if base and not Url.is_absolute(href) then
                resolved = Url.resolve(base, href)
            end

            if Url.is_absolute(resolved) and resolved:find("^https?:") then
                engine_ref:load_url(mount_win_id, resolved)
            else
                -- Treat as sandbox file path
                engine_ref:load_file(mount_win_id, resolved)
            end
        end
    end)

    local function collect_text(nid)
        local text = ns.text_content[nid] or ""
        local cid = ns.first_child[nid] or 0
        while cid ~= 0 do
            text = text .. collect_text(cid)
            cid = ns.next_sibling[cid] or 0
        end
        return text
    end

    local function normalize_select_options(select_nid)
        local attrs = ns.attrs[select_nid] or {}
        if attrs.options and #attrs.options > 0 then
            if not ns.text_content[select_nid] or ns.text_content[select_nid] == "" then
                ns.text_content[select_nid] = attrs.options[1] or ""
            end
            return
        end

        local options = {}
        local option_values = {}
        local selected_index = 1

        local function collect_option_nodes(parent_nid)
            local child = ns.first_child[parent_nid] or 0
            while child ~= 0 do
                local child_tag = st:get(ns.tag[child])
                if child_tag == "option" then
                    local option_attrs = ns.attrs[child] or {}
                    local label = option_attrs.label or collect_text(child)
                    label = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if label ~= "" then
                        options[#options + 1] = label
                        option_values[#option_values + 1] = option_attrs.value ~= nil and tostring(option_attrs.value) or label
                        if option_attrs.selected ~= nil then
                            selected_index = #options
                        end
                    end
                elseif child_tag == "optgroup" then
                    collect_option_nodes(child)
                end
                child = ns.next_sibling[child] or 0
            end
        end
        collect_option_nodes(select_nid)

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

    local function clear_text_descendants(nid)
        local cid = ns.first_child[nid] or 0
        while cid ~= 0 do
            if ns.node_type[cid] == ns.TEXT then
                ns.text_content[cid] = ""
            else
                clear_text_descendants(cid)
            end
            cid = ns.next_sibling[cid] or 0
        end
    end

    local function normalize_form_value(nid, tag_str)
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
        elseif tag_str == "textarea" then
            ns.text_content[nid] = collect_text(nid)
            attrs._default_value = ns.text_content[nid]
            clear_text_descendants(nid)
        end
    end

    -- Create component instances for stateful components
    local components = {}
    -- Per HTML §4.10.5 only one radio in a given form+name group may be
    -- pre-checked.  Walk later DOM order wins (the parser produces nodes
    -- in document order, so the *last* `<input type=radio name=g checked>`
    -- is the one that survives).
    local checked_radio_group = {}  -- (form_nid|0) .. "\0" .. name -> nid
    local function radio_group_key(nid, attrs)
        local name = attrs and attrs.name
        if not name or name == "" then return nil end
        local form_nid = 0
        local cur = ns.parent[nid]
        while cur and cur ~= 0 do
            local t = st:get(ns.tag[cur])
            if t == "form" then form_nid = cur; break end
            cur = ns.parent[cur]
        end
        return form_nid .. "\0" .. name
    end
    local function apply_checked_attr(nid)
        local attrs = ns.attrs[nid] or {}
        local pseudo = ns.pseudo[nid]
        if pseudo and attrs.checked ~= nil and attrs.checked ~= false then
            pseudo.checked = true
            -- Record the default-checked flag so form reset can restore it.
            attrs._default_checked = true
            -- Radio-button group exclusivity: the previous winner in this
            -- (form, name) group is downgraded so only one stays selected.
            local tag_str = st:get(ns.tag[nid])
            local input_type = tag_str == "input" and tostring(attrs.type or ""):lower() or nil
            if tag_str == "radio" or input_type == "radio" then
                local key = radio_group_key(nid, attrs)
                if key then
                    local prev_nid = checked_radio_group[key]
                    if prev_nid and prev_nid ~= nid then
                        local prev_pseudo = ns.pseudo[prev_nid]
                        if prev_pseudo then prev_pseudo.checked = false end
                        local prev_attrs = ns.attrs[prev_nid]
                        if prev_attrs then prev_attrs._default_checked = false end
                    end
                    checked_radio_group[key] = nid
                end
            end
        end
    end
    ns:walk_depth_first(root_id, function(nid)
        local tag_id = ns.tag[nid]
        local tag_str = st:get(tag_id)
        if tag_str == "input" then
            normalize_form_value(nid, tag_str)
            local attrs = ns.attrs[nid]
            local input_type = tostring(attrs and attrs.type or "text"):lower()
            if input_type == "number" then
                components[nid] = { type = "input-number", inst = InputNumber.new() }
            elseif input_type == "color" then
                components[nid] = { type = "input-color", inst = InputColor.new() }
            elseif input_type == "range" then
                components[nid] = { type = "slider", inst = Slider.new() }
            elseif input_type == "checkbox" then
                apply_checked_attr(nid)
                ns._checkboxes[nid] = true
            elseif input_type == "radio" then
                apply_checked_attr(nid)
                ns._radios[nid] = true
            elseif input_type == "button" or input_type == "submit" or input_type == "reset" then
                -- Native button inputs are clickable controls, not editable text fields.
            else
                -- text, password, email, url, search, tel, date, time, file
                local inst = InputText.new()
                if input_type == "password" then
                    inst._mask_char = string.char(226, 128, 162)  -- bullet U+2022
                    local pseudo = ns.pseudo[nid]
                    if pseudo then
                        pseudo._input_mask_char = inst._mask_char
                    end
                end
                components[nid] = { type = "input", inst = inst }
            end
        elseif tag_str == "textarea" then
            normalize_form_value(nid, tag_str)
            components[nid] = { type = "textarea", inst = TextareaComp.new() }
        elseif tag_str == "slider" then
            components[nid] = { type = "slider", inst = Slider.new() }
        elseif tag_str == "switch" then
            apply_checked_attr(nid)
            components[nid] = { type = "switch", inst = SwitchComp.new() }
        elseif tag_str == "checkbox" then
            apply_checked_attr(nid)
        elseif tag_str == "radio" then
            apply_checked_attr(nid)
        elseif tag_str == "select" then
            normalize_select_options(nid)
            local inst = SelectComp.new()
            local attrs = ns.attrs[nid] or {}
            if type(attrs.selected_index) == "number" then
                inst.selected_index = attrs.selected_index
            end
            components[nid] = { type = "select", inst = inst }
        elseif tag_str == "particle-emitter" then
            components[nid] = { type = "particle-emitter", inst = ParticleEmitter.new() }
        elseif tag_str == "sound" then
            components[nid] = { type = "sound", inst = SoundTrigger.new() }
        end
    end)
    ns._components = components

    -- Store mount
    local mount = {
        bundle            = bundle,
        string_table      = st,
        node_store        = ns,
        event_system      = es,
        style_engine      = se,
        layout_engine     = le,
        scroll_engine     = scroll,
        devtools          = devtools,
        transition_engine = te,
        components        = components,
        root_id           = root_id,
        bundle_id_map     = bundle_id_map,
        actions           = opts.actions or {},
        state             = bundle.state or {},
        _route            = opts.route,
        style_dirty       = true,
        layout_dirty      = true,
    }
    self._mounts[win_id] = mount

    -- Run inline <script lang="lua"> blocks after mount is fully registered,
    -- so scripts can call engine:load_url(win_id, ...) etc. reentrantly.
    if (bundle.scripts and #bundle.scripts > 0) or bundle.actions or bundle.bindings then
        local ok, err = pcall(ScriptRuntime.run_scripts, self, win_id, mount, bundle.scripts)
        if not ok then
            self.platform:log_error("[astro] script runtime error: " .. tostring(err))
        end
        if self._mounts[win_id] ~= mount then
            return
        end
    end

    -- Honor the `autofocus` attribute: focus the first element that has it.
    pcall(function()
        ns:walk_depth_first(root_id, function(nid)
            if mount._autofocused then return end
            local attrs = ns.attrs[nid]
            if attrs and attrs.autofocus ~= nil then
                es:_set_focus(nid, false)
                mount._autofocused = true
            end
        end)
    end)

    self:mark_dirty(win_id, "all")
end

------------------------------------------------------------
-- Browser-style loaders
-- These wrap HTMLParser + mount() so consumers can treat the
-- engine as a browser: feed it HTML/CSS and it renders.
------------------------------------------------------------

--- Mount a window from raw HTML (+ optional CSS) strings.
--- The window must already be created via create_window().
---@param win_id string      window id
---@param html   string      HTML content
---@param css    string|nil  optional external CSS
---@param opts   table|nil   { actions = {...}, source = "..." }
function Engine:load_html(win_id, html, css, opts)
    win_id = _coerce_win_id(win_id) or win_id
    opts = opts or {}
    local bundle = HTMLParser.parse(html, css)
    self:mount(win_id, bundle, opts)
    -- Track source + base URL for reload() and relative-reference resolution
    local mount = self._mounts[win_id]
    if mount then
        mount._source = {
            kind   = opts.source_kind or "html",
            html   = html,
            css    = css,
            url    = opts.source_url,
            path   = opts.source_path,
            opts   = opts,
        }
        -- Base URL: priority is opts.base_url > url-source > file-source > nil
        local base = opts.base_url
        if not base and opts.source_url then
            base = Url.parent(opts.source_url)
        elseif not base and opts.source_path then
            base = Url.parent(opts.source_path)
        end
        mount._base_url = base
        -- Kick off async loads for <link rel=stylesheet>
        if bundle.stylesheets and #bundle.stylesheets > 0 then
            self:_load_stylesheets(win_id, bundle.stylesheets, base)
        end
    end
end

--- Async-load each <link rel=stylesheet>, parse, and merge into the
--- mount's style engine.  Each arrival triggers a style re-cascade.
---@param win_id string
---@param sheets table  array of { href = string, media = string|nil }
---@param base   string|nil  base URL for resolving relative hrefs
function Engine:_load_stylesheets(win_id, sheets, base, seen, depth)
    local CSSParser = require("core/html/css_parser")
    local self_ref = self
    seen = seen or {}
    depth = depth or 0
    -- Depth cap protects against pathological circular @import chains even
    -- when `seen` detection should already have cut the cycle.
    if depth > 16 then
        self.platform:log_warning("[astro] stylesheet @import depth > 16, aborting")
        return
    end

    local function apply_css(css_str, href)
        local mount = self_ref._mounts[win_id]
        if not mount or not mount.style_engine then return end
        if not css_str or css_str == "" then return end
        local ok, rules, imports = pcall(CSSParser.parse, css_str)
        if not ok or not rules then
            self_ref.platform:log_error("[astro] <link> CSS parse failed: " .. tostring(href))
            return
        end
        mount.style_engine:append_rules(rules)
        -- Register any newly arrived @font-face / @keyframes
        if rules.font_faces then
            for i = 1, #rules.font_faces do
                local ff = rules.font_faces[i]
                if ff.family and ff.src then
                    self_ref:register_font(ff.family, ff.src, ff.weight, ff.style)
                end
            end
        end
        if rules.keyframes and mount.transition_engine then
            for name, kf in pairs(rules.keyframes) do
                mount.transition_engine:register_keyframes(name, kf)
            end
        end
        mount.style_dirty = true
        mount.layout_dirty = true

        -- Recursively fetch @import-ed stylesheets relative to this sheet's URL
        if imports and #imports > 0 then
            local child_sheets = {}
            for i = 1, #imports do
                child_sheets[i] = { href = imports[i].url, media = imports[i].media }
            end
            self_ref:_load_stylesheets(win_id, child_sheets, href, seen, depth + 1)
        end
    end

    for i = 1, #sheets do
        local sheet = sheets[i]
        local href = sheet.href
        if href and href ~= "" then
            local resolved = Url.resolve(base, href)
            if seen[resolved] then
                -- Already fetched this one (or in flight) -" break cycle
            else
                seen[resolved] = true
                if Url.is_absolute(resolved) and resolved:find("^https?:") then
                    -- HTTP(S) fetch -" async
                    self.platform:http_get(resolved, function(http_code, content_type, data)
                        local body = data
                        local code = http_code
                        if type(http_code) == "string" and data == nil and content_type == nil then
                            body = http_code
                            code = 200
                        end
                        if not body or (type(code) == "number" and code >= 400) then
                            self_ref.platform:log_error("[astro] <link> HTTP " .. tostring(code) .. ": " .. resolved)
                            return
                        end
                        apply_css(body, resolved)
                    end)
                else
                    -- Local data-file path
                    local body = self.platform:read_data_file(resolved)
                    if body then
                        apply_css(body, resolved)
                    else
                        self.platform:log_error("[astro] <link> not found: " .. tostring(resolved))
                    end
                end
            end
        end
    end
end

--- Default error page template. Overridden via opts.error_page (a function
--- that returns an HTML string given `err` and `url`).
local function _default_error_page(err, url)
    local esc = function(s)
        s = tostring(s or "")
        return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    end
    return [[<!DOCTYPE html>
<html><head><style>
  body { background: #1a1d2e; color: #e6e8f0; padding: 32px; font-family: inter; }
  .code { font-size: 48px; font-weight: 700; color: #ff6b6b; margin-bottom: 8px; }
  .msg  { font-size: 14px; color: #a6b0cf; margin-bottom: 16px; }
  .url  { font-size: 11px; color: #7b829a; font-family: monospace;
          padding: 8px 10px; background: #262a44; border-radius: 6px;
          word-break: break-all; }
  .hint { font-size: 12px; color: #7b829a; margin-top: 24px; }
</style></head>
<body>
  <div class="code">]] .. esc(err) .. [[</div>
  <div class="msg">Failed to load page.</div>
  <div class="url">]] .. esc(url) .. [[</div>
  <div class="hint">Check the URL, your network, or the file path.</div>
</body></html>]]
end

--- Render an error page in the given window.
---@param win_id string
---@param err    any      error code or message
---@param url    string   URL or path that failed
---@param opts   table|nil  may contain error_page = function(err, url) → html
function Engine:_show_error_page(win_id, err, url, opts)
    opts = opts or {}
    local render = opts.error_page or _default_error_page
    local html_ok, html = pcall(render, err, url)
    if not html_ok or type(html) ~= "string" then
        html = _default_error_page(err, url)
    end
    self:load_html(win_id, html, nil, { source_kind = "error" })
end

--- Mount a window from a local data-file path (read via platform:read_data_file).
--- If a .css file with the same basename exists next to it, it's loaded too.
---@param win_id string
---@param path   string  relative path inside the data sandbox
---@param opts   table|nil  { actions, css_path, error_page }
---@return boolean  true if load succeeded
function Engine:load_file(win_id, path, opts)
    win_id = _coerce_win_id(win_id) or win_id
    opts = opts or {}
    local html = self.platform:read_data_file(path)
    if not html then
        self.platform:log_error("[astro] load_file: cannot read " .. tostring(path))
        self:_show_error_page(win_id, "File not found", path, opts)
        return false
    end
    local css = nil
    local css_path = opts.css_path
    if not css_path then
        -- Convention: foo.html → foo.css
        local base = path:match("^(.+)%.html?$")
        if base then css_path = base .. ".css" end
    end
    if css_path then
        css = self.platform:read_data_file(css_path)
    end
    opts.source_kind = "file"
    opts.source_path = path
    opts.source_css_path = css_path
    self:load_html(win_id, html, css, opts)
    return true
end

--- Mount a window from a remote URL. Async: returns immediately; the
--- window is mounted once the HTTP response arrives.
--- If the response contains `<style>` blocks they are extracted; separate
--- CSS fetch is not performed (keep it simple -" use <link>-free docs).
---@param win_id string
---@param url    string
---@param opts   table|nil  { actions, on_load, on_error }
function Engine:load_url(win_id, url, opts)
    win_id = _coerce_win_id(win_id) or win_id
    opts = opts or {}
    local self_ref = self
    local on_load = opts.on_load
    local on_error = opts.on_error

    self.platform:http_get(url, function(http_code, content_type, data, headers)
        -- Sylvanas http_get callback signature: (code, type, body, headers)
        -- Some builds pass just (body) -" tolerate both.
        local body = data
        local code = http_code
        if type(http_code) == "string" and data == nil and content_type == nil then
            body = http_code
            code = 200
        end
        if not body or body == "" or (type(code) == "number" and code >= 400) then
            local err_code = tostring(code or "?")
            self_ref.platform:log_error("[astro] load_url: HTTP " .. err_code .. " for " .. url)
            if on_error then pcall(on_error, code, url) end
            self_ref:_show_error_page(win_id, "HTTP " .. err_code, url, opts)
            return
        end
        opts.source_kind = "url"
        opts.source_url = url
        local ok, err = pcall(self_ref.load_html, self_ref, win_id, body, nil, opts)
        if not ok then
            self_ref.platform:log_error("[astro] load_url parse/mount failed: " .. tostring(err))
            if on_error then pcall(on_error, err, url) end
            self_ref:_show_error_page(win_id, "Parse error", url, opts)
            return
        end
        if on_load then pcall(on_load, url) end
    end)
end

--- Reload the window from whatever source was last loaded.
--- No-op if the window was mounted via a raw bundle (no source recorded).
---@param win_id string
function Engine:reload(win_id)
    win_id = _coerce_win_id(win_id) or win_id
    local mount = self._mounts[win_id]
    if not mount or not mount._source then return false end
    local src = mount._source
    if src.kind == "html" then
        self:load_html(win_id, src.html, src.css, src.opts)
    elseif src.kind == "file" then
        self:load_file(win_id, src.path, src.opts)
    elseif src.kind == "url" then
        self:load_url(win_id, src.url, src.opts)
    else
        return false
    end
    return true
end

--- Return a JavaScript-like document handle for normal plugin Lua.
---@param win_id string
---@return table|nil
function Engine:document(win_id)
    win_id = _coerce_win_id(win_id) or win_id or self._last_loaded_win_id
    return ScriptRuntime.create_document(self, win_id)
end

function Engine:query_selector(win_id, selector)
    local document = self:document(win_id)
    return document and document:querySelector(selector) or nil
end

function Engine:query_selector_all(win_id, selector)
    local document = self:document(win_id)
    return document and document:querySelectorAll(selector) or {}
end

function Engine:on(win_id, event, selector, handler)
    local document = self:document(win_id)
    if not document then return nil end
    local nodes = document:querySelectorAll(selector)
    for i = 1, #nodes do
        nodes[i]:addEventListener(event, handler)
    end
    if #nodes == 1 then return nodes[1] end
    return nodes
end

function Engine:on_click(win_id, selector, handler)
    return self:on(win_id, "click", selector, handler)
end

function Engine:on_change(win_id, selector, handler)
    return self:on(win_id, "change", selector, handler)
end

function Engine:on_input(win_id, selector, handler)
    return self:on(win_id, "input", selector, handler)
end

function Engine:getElementById(win_id, id)
    if id == nil then
        id = win_id
        win_id = self._last_loaded_win_id
    end
    local document = self:document(win_id)
    return document and document:getElementById(id) or nil
end

function Engine:querySelector(win_id, selector)
    if selector == nil then
        selector = win_id
        win_id = self._last_loaded_win_id
    end
    return self:query_selector(win_id, selector)
end

function Engine:querySelectorAll(win_id, selector)
    if selector == nil then
        selector = win_id
        win_id = self._last_loaded_win_id
    end
    return self:query_selector_all(win_id, selector)
end

function Engine:onClick(win_id, selector, handler)
    if handler == nil then
        handler = selector
        selector = win_id
        win_id = self._last_loaded_win_id
    end
    return self:on_click(win_id, selector, handler)
end

function Engine:onChange(win_id, selector, handler)
    if handler == nil then
        handler = selector
        selector = win_id
        win_id = self._last_loaded_win_id
    end
    return self:on_change(win_id, selector, handler)
end

function Engine:onInput(win_id, selector, handler)
    if handler == nil then
        handler = selector
        selector = win_id
        win_id = self._last_loaded_win_id
    end
    return self:on_input(win_id, selector, handler)
end

--- Set a state value for a mounted window.
---@param win_id string
---@param key    string
---@param value  any
function Engine:set_state(win_id, key, value)
    win_id = _coerce_win_id(win_id) or win_id
    local mount = self._mounts[win_id]
    if mount then
        mount.state[key] = value
        self:mark_dirty(win_id, "all")
    end
end

--- Mark a window as needing re-render.
---@param win_id string
---@param kind   string  "style" | "layout" | "all"
function Engine:mark_dirty(win_id, kind)
    win_id = _coerce_win_id(win_id) or win_id
    local mount = self._mounts[win_id]
    if mount then
        if kind == "all" then
            mount.style_dirty  = true
            mount.layout_dirty = true
        elseif kind == "style" then
            mount.style_dirty  = true
            mount.layout_dirty = true
        elseif kind == "layout" then
            mount.layout_dirty = true
        end
    end
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

--- Start the render loop by registering the frame callback.
function Engine:start()
    if self._running then return end
    self._running = true

    -- Set screen bounds before loading geometry (so saved positions get clamped)
    local ok_ss, sw, sh = pcall(self.platform.get_screen_size, self.platform)
    if ok_ss and sw then
        self.window_manager:set_screen_size(sw, sh)
    end

    -- Load saved window geometry
    self.window_manager:load_geometry(self.platform)

    -- Initialize SVG renderer mask cache
    SvgRenderer.init(self.platform)

    -- Register render callback.  The callback itself is pcall-wrapped so a
    -- thrown error inside _frame() (bad computed value, recycled nid, etc.)
    -- logs instead of tearing down the host process.  Consecutive errors
    -- within a short window suppress themselves to keep the log readable.
    local engine = self
    engine._frame_err_count = 0
    engine._frame_err_last_time = 0
    local function on_render()
        if not engine._running then return end
        local ok, err = xpcall(function() engine:_frame() end, function(e)
            -- Attach a Lua traceback for the first few errors so the actual
            -- call site is visible in the log.
            return tostring(e) .. "\n" .. debug.traceback("", 2)
        end)
        if not ok then
            engine._frame_err_count = engine._frame_err_count + 1
            local now = engine.platform and engine.platform:time() or 0
            -- Log the first 5 errors in full, then rate-limit to once / 2 s
            local should_log = engine._frame_err_count <= 5
                or (now - engine._frame_err_last_time) > 2
            if should_log then
                engine._frame_err_last_time = now
                pcall(engine.platform.log_error, engine.platform,
                    "[astro] frame #" .. engine._frame_err_count .. " error: " .. tostring(err))
            end
        end
    end

    if self.platform and type(self.platform.register_render_callback) == "function" then
        local ok, err = pcall(self.platform.register_render_callback, self.platform, on_render)
        if not ok then
            pcall(self.platform.log_error, self.platform,
                "[astro] register_render_callback failed: " .. tostring(err))
        end
    else
        if self.platform and type(self.platform.log_error) == "function" then
            pcall(self.platform.log_error, self.platform,
                "[astro] platform missing register_render_callback")
        end
    end
end

--- Stop the render loop.
function Engine:stop()
    self._running = false
    self.window_manager:save_geometry(self.platform)
end

--- Full cleanup.
function Engine:destroy()
    self:stop()
    -- Drop the cached display-list length so a stale paint cannot replay
    -- (the underlying buffer is reset elsewhere; we just have to forget
    -- the snapshot pointer).
    self._dl_len = nil
    self._mounts = {}
    -- Release per-engine caches.  Without these the host pins ~megabytes
    -- of font glyphs, icons and textures even after the engine is gone.
    if self.font_manager and type(self.font_manager.reset) == "function" then
        pcall(self.font_manager.reset, self.font_manager)
    end
    self.icon_cache    = nil
    self.texture_cache = nil
    self.display_list  = nil
    self.window_manager = nil
    -- Painter module-level state belongs to whoever called paint_tree last.
    -- Reset to nil so the next engine in this Lua state starts clean.
    Painters._font_manager  = nil
    Painters._default_font  = nil
    Painters._icon_cache    = nil
    Painters._texture_cache = nil
    Painters._clip_rect     = nil
    Painters._base_url      = nil
    SvgRenderer._font_manager = nil
    SvgRenderer._default_font = "inter"
    if SvgRenderer and type(SvgRenderer.reset_runtime_caches) == "function" then
        pcall(SvgRenderer.reset_runtime_caches)
    end
end

local function process_script_timers(engine, mount)
    local timers = mount._script_timers
    if not timers then return false end
    local now = engine.platform:time()
    local dirty = false
    for id, timer in pairs(timers) do
        if timer and now >= timer.at then
            if timer.interval then
                timer.at = now + (timer.ms or 0) / 1000
            else
                timers[id] = nil
            end
            local ok, err = pcall(timer.fn)
            if not ok then engine.platform:log_error("[astro] timer error: " .. tostring(err)) end
            dirty = true
        end
    end
    if dirty then
        mount.style_dirty = true
        mount.layout_dirty = true
    end
    return dirty
end

------------------------------------------------------------
-- Font API
------------------------------------------------------------

--- Register a custom font by name and URL.
---@param name string  Font identifier (e.g. "inter")
---@param url  string|nil  Download URL
---@param weight any|nil CSS font-weight from @font-face
---@param style any|nil CSS font-style from @font-face
function Engine:register_font(name, url, weight, style)
    if url then
        local load_key, weight_specific = self.font_manager:register_face(name, url, weight, style)
        if weight_specific then
            self.font_manager:_queue_load_key(load_key)
            return
        end
    end
    self.font_manager:load(name)
end

function Engine:set_hinting(family, weight, enabled)
    if not self.font_manager or type(self.font_manager.set_hinting) ~= "function" then
        return false
    end
    return self.font_manager:set_hinting(family, weight, enabled)
end

function Engine:get_hinting_stats()
    if not self.font_manager or type(self.font_manager.get_hinting_stats) ~= "function" then
        return { fonts = {}, total = { hinted = 0, fallback = 0, opcodes_seen = {} } }
    end
    return self.font_manager:get_hinting_stats()
end

------------------------------------------------------------
-- Icon API
------------------------------------------------------------

--- Register an icon from a react-icons-style tree.
---@param name string       Icon identifier
---@param icon_tree table   { tag="svg", attr={viewBox=...}, child={...} }
function Engine:register_icon(name, icon_tree)
    self.icon_cache:register(name, icon_tree)
end

--- Register a single-path icon (shorthand).
---@param name string       Icon identifier
---@param d string          SVG path data
---@param viewBox string?   ViewBox string (default "0 0 24 24")
function Engine:register_icon_path(name, d, viewBox)
    self.icon_cache:register_path(name, d, viewBox)
end

--- Set a navigation handler for <a> link clicks.
--- Handler receives (href, target) and should return true if handled.
---@param handler function|nil
function Engine:set_navigation_handler(handler)
    self._nav_handler = handler
end

--- Set the color scheme for media query evaluation ("light" or "dark").
---@param scheme string  "light" | "dark"
function Engine:set_color_scheme(scheme)
    for _, mount in pairs(self._mounts) do
        if mount.style_engine then
            mount.style_engine:set_color_scheme(scheme)
            mount.style_dirty = true
        end
    end
end

--- Drain the font_manager's pending load + parse queues synchronously,
--- up to `max_steps`. Used by hosts that need fonts ready BEFORE the
--- first layout pass (Studio's parity preview) to avoid the
--- "font-async-load races first layout pass" trap. Does NOT block on
--- network -" only drains disk/raw-cache pre-populated bytes via the
--- existing tick() phases. Returns true if any work happened.
---
--- Defensive guard added alongside the
--- get_cache_for() synchronous-parse fix in font_manager.lua. The
--- font_manager fix handles the gap between "bytes in _raw_cache" and
--- "FontCache available"; this helper handles the gap between
--- "bytes registered via platform read_data_file pre-cache" and
--- "_raw_cache populated by tick() Phase 1".
function Engine:ensure_fonts_loaded(max_steps)
    max_steps = max_steps or 8
    local fm = self.font_manager
    if not fm then return false end
    local did_anything = false
    for _ = 1, max_steps do
        local pending = fm._pending and #fm._pending or 0
        local queue = fm._load_queue and #fm._load_queue or 0
        if pending == 0 and queue == 0 then break end
        fm:tick()
        did_anything = true
    end
    if did_anything and fm:pop_just_ready() then
        self:_invalidate_font_metric_caches()
    end
    return did_anything
end

function Engine:_invalidate_font_metric_caches()
    TextWrap.flush_cache()
    for _, mount in pairs(self._mounts) do
        mount.style_dirty = true
        mount.layout_dirty = true
        if mount.layout_engine then
            mount.layout_engine._text_cache = {}
            mount.layout_engine._measure_cache = {}
        end
        local ns = mount.node_store
        if ns then
            for _, comp in pairs(ns.computed) do
                comp._measurer = nil
                comp._paint_measurer = nil
                comp._wrap_font_key = nil
            end
        end
    end
end

------------------------------------------------------------
-- Per-frame pipeline
------------------------------------------------------------

--- The per-frame update/render pipeline.
function Engine:_frame()
    local prof = self._profiler
    local prof_on = prof and prof._enabled
    local abs_time = self.platform:time()

    -- Track time for transitions/animations
    if not self._start_time then
        self._start_time = abs_time
    end
    local current_time = abs_time - self._start_time

    -- 0. ALWAYS poll input first -" even on throttled frames
    self.input:poll()
    local drag_active = self.window_manager._drag and self.input:is_mouse_down()
    local mouse_capture_issued = false
    if drag_active then
        pcall(self.platform.capture_mouse, self.platform)
        mouse_capture_issued = true
    end

    -- 0b. Detect input activity → force frame + reset idle
    -- Only use edge signals (not held-state) to avoid bypassing cap during hold
    local inp = self.input
    if inp:is_mouse_clicked() or inp:any_key_edge() or inp.wheel ~= 0
       or inp:is_right_mouse_clicked() then
        self._force_frame = true
        self._idle_frame_count = 0
        self._is_idle = false
    end
    if drag_active then
        self._force_frame = true
        self._idle_frame_count = 0
        self._is_idle = false
    end

    -- 0c. Frame throttle gate: skip full pipeline if not enough time elapsed
    if not self._force_frame then
        local cap = self._is_idle and self._ui_idle_fps_cap or self._ui_fps_cap
        local min_interval = 1.0 / cap
        if (abs_time - self._last_ui_frame_time) < min_interval then
            -- Throttled frame: only replay cached display list
            if self._dl_len and self._dl_len > 0 then
                if prof_on then prof:begin_frame() end
                if prof_on then prof:begin_phase(FrameProfiler.PHASE_REPLAY) end
                self.display_list._len = self._dl_len
                self.display_list:replay(self.platform)
                if prof_on then
                    prof:end_phase(FrameProfiler.PHASE_REPLAY)
                    prof:set_metric(FrameProfiler.METRIC_THROTTLED, 1)
                    prof:end_frame()
                end
            end
            return
        end
    end
    self._force_frame = false
    self._last_ui_frame_time = abs_time

    -- Full frame begins
    if prof_on then prof:begin_frame() end

    -- 1. Input phase (poll already done above; measure remaining input work)
    if prof_on then prof:begin_phase(FrameProfiler.PHASE_INPUT) end

    -- 1b. Update screen bounds for window clamping
    local ok_ss, sw, sh = false, nil, nil
    if drag_active and self._prev_screen_w and self._prev_screen_h then
        ok_ss, sw, sh = true, self._prev_screen_w, self._prev_screen_h
    else
        ok_ss, sw, sh = pcall(self.platform.get_screen_size, self.platform)
    end
    local screen_changed = false
    if ok_ss and sw then
        if self._prev_screen_w ~= sw or self._prev_screen_h ~= sh then
            screen_changed = true
            self._prev_screen_w = sw
            self._prev_screen_h = sh
        end
        self.window_manager:set_screen_size(sw, sh)
    end

    -- 2. Update window chrome
    local chrome_consumed = self.window_manager:update(self.input)
    drag_active = self.window_manager._drag and self.input:is_mouse_down()
    if drag_active and not mouse_capture_issued then
        pcall(self.platform.capture_mouse, self.platform)
        mouse_capture_issued = true
    end

    -- 3. Determine if cursor is over any window
    local cursor_over_window = false
    local windows = self.window_manager:get_windows()
    for i = 1, #windows do
        local w = windows[i]
        if w.visible then
            local mx, my = self.input.cursor_x, self.input.cursor_y
            if mx >= w.x and mx < w.x + w.w and my >= w.y and my < w.y + w.h then
                cursor_over_window = true
                break
            end
        end
    end

    -- Window focus gates keyboard capture: when a window is focused, we
    -- block all keyboard from the game (the user's explicit preference).
    -- When no window is focused, the game receives everything.  Focus is
    -- set only by a mouse-down inside a window (see WindowManager), so
    -- clicking in the game world unfocuses and hands input back.
    --
    -- Also clear focus_id on all non-focused windows so their inputs lose
    -- the :focus pseudo (no stale outline, no stale caret, and their
    -- update() becomes a no-op).
    local focused_win_id = self.window_manager:get_focused_window_id()
    for win_id, mount in pairs(self._mounts) do
        if mount.event_system then
            local es = mount.event_system
            if win_id ~= focused_win_id and es.focus_id ~= 0 then
                -- Use _set_focus(0) so :focus / :focus-visible /
                -- :focus-within all clear properly on the old target
                -- (direct assignment leaves stale pseudo flags, and the
                -- outline + caret would linger on a background window).
                pcall(es._set_focus, es, 0, false)
                mount.style_dirty = true
            end
        end
    end

    local any_scroll_drag = false
    for _, mount in pairs(self._mounts) do
        if mount.scroll_engine and (mount.scroll_engine._drag_nid or mount.scroll_engine._drag_h_nid) then
            any_scroll_drag = true
            break
        end
    end

    -- External drag detection
    local mouse_held = self.input:is_mouse_down(1)
                    or self.input:is_mouse_down(2)
                    or self.input:is_mouse_down(3)
    local we_initiated_drag = self.window_manager._drag or any_scroll_drag

    if we_initiated_drag then
        self._external_drag = false
    elseif cursor_over_window and not self._was_over_window and mouse_held then
        self._external_drag = true
    end
    if self._external_drag and not mouse_held then
        self._external_drag = false
    end
    self._was_over_window = cursor_over_window

    -- Input capture
    -- Right-mouse is WoW's camera-drag trigger. When the user is holding it,
    -- the game hides the cursor and expects uninterrupted mouselook input.
    -- If our engine captures the mouse while the cursor coincidentally
    -- hovers our window, WoW loses that input and the camera-drag gets
    -- stuck even after release.  Yield the mouse while rmb is held, unless
    -- we ourselves initiated the drag (window chrome / scrollbar).
    local rmb_held = self.input:is_key_pressed(0x02)  -- VK_RBUTTON
    if not self._external_drag and not (rmb_held and not we_initiated_drag) then
        if cursor_over_window or self.window_manager._drag or any_scroll_drag then
            if not mouse_capture_issued then
                if type(self.platform.capture_mouse) == "function" then
                    pcall(self.platform.capture_mouse, self.platform)
                end
                mouse_capture_issued = true
            end
        end
    end
    -- Keyboard: capture ALL keys when a window is focused, not just when
    -- a text input has focus.  The user's contract is "focused window =
    -- game blocked, unfocused = game works".  To unfocus, click anywhere
    -- outside our windows -" that click reaches the game and the next
    -- frame stops capturing entirely.  Still yield while rmb is held so
    -- WoW's camera-drag keybinds aren't eaten.
    if focused_win_id and not rmb_held then
        if type(self.platform.capture_keyboard) == "function" then
            pcall(self.platform.capture_keyboard, self.platform)
        end
    end

    -- 3.5. Tick font manager + texture cache
    if not drag_active then
        self.font_manager:tick()
        if self.font_manager:pop_just_ready() then
            self:_invalidate_font_metric_caches()
        end

        self.texture_cache:tick()
        if self.texture_cache:pop_just_ready() then
            for _, mount in pairs(self._mounts) do
                mount.layout_dirty = true
            end
        end
    end

    for _, mount in pairs(self._mounts) do
        process_script_timers(self, mount)
    end

    if prof_on then prof:end_phase(FrameProfiler.PHASE_INPUT) end

    -- 4. Determine if any mount needs repaint
    local any_paint_needed = false
    for _, mount in pairs(self._mounts) do
        if mount.style_dirty or mount.layout_dirty then
            any_paint_needed = true
            break
        end
    end

    -- Screen resize forces repaint (window positions may have changed)
    if not any_paint_needed and screen_changed then
        any_paint_needed = true
    end

    -- Check for active animations, scroll drags, hover changes, window drags,
    -- component repaints, input focus (cursor blink), or mouse interaction
    if not any_paint_needed then
        local wm_drag = self.window_manager._drag
        if wm_drag then
            any_paint_needed = true
        elseif self.input.wheel ~= 0 then
            any_paint_needed = true
        elseif self.input:is_mouse_clicked() or self.input:is_mouse_down()
               or self.input:is_mouse_released()
               or self.input:is_right_mouse_clicked() then
            any_paint_needed = true
        else
            for _, mount in pairs(self._mounts) do
                -- Active animations force repaint
                if mount.transition_engine and mount.transition_engine:is_active() then
                    any_paint_needed = true
                    break
                end
                -- Scroll drag or smooth-scroll/snap animation active
                if mount.scroll_engine then
                    local se = mount.scroll_engine
                    if se._drag_nid or se._drag_h_nid
                       or next(se._smooth_target_y) or next(se._smooth_target_x)
                       or next(se._snap_active) or next(se._snap_pending) then
                        any_paint_needed = true
                        break
                    end
                end
                -- Focused input (cursor blink)
                if mount.event_system then
                    local fid = mount.event_system.focus_id
                    if fid ~= 0 and mount.components and mount.components[fid] then
                        any_paint_needed = true
                        break
                    end
                end
                -- Particle emitters always need repaint
                if mount.components then
                    for _, comp in pairs(mount.components) do
                        if comp.type == "particle-emitter" then
                            any_paint_needed = true
                            break
                        end
                    end
                end
                if any_paint_needed then break end
            end
        end
    end

    -- Pseudo state changes (hover in/out) detected during event dispatch
    -- will set style_dirty, which is caught above. But the event dispatch
    -- happens AFTER this check, inside the per-window loop. So we also
    -- check if the cursor moved (potential hover change).
    if not any_paint_needed then
        local cx, cy = self.input.cursor_x, self.input.cursor_y
        local px, py = self._prev_cx or 0, self._prev_cy or 0
        if cx ~= px or cy ~= py then
            any_paint_needed = true
        end
        self._prev_cx, self._prev_cy = cx, cy
    end

    -- Check for any keyboard activity (Tab focus, arrow scroll, typing)
    if not any_paint_needed then
        if self.input:any_key_edge() then
            any_paint_needed = true
        end
    end

    -- Run user frame callback before potential skip (it may mark mounts dirty)
    if self._on_frame then
        local ok, err = pcall(self._on_frame, self)
        if not ok then
            self.platform:log_error("[astro] on_frame error: " .. tostring(err))
        end
        -- Re-check if on_frame dirtied anything
        if not any_paint_needed then
            for _, mount in pairs(self._mounts) do
                if mount.style_dirty or mount.layout_dirty then
                    any_paint_needed = true
                    break
                end
            end
        end
    end

    -- If nothing needs repaint AND we have a cached display list, replay it
    if not any_paint_needed and self._dl_len and self._dl_len > 0 then
        -- Update idle counter on the frame-skip path too (otherwise idle never activates)
        self._idle_frame_count = self._idle_frame_count + 1
        if self._idle_frame_count >= self._idle_threshold then
            self._is_idle = true
        end
        if prof_on then prof:begin_phase(FrameProfiler.PHASE_REPLAY) end
        self.display_list._len = self._dl_len
        self.display_list:replay(self.platform)
        if prof_on then
            prof:end_phase(FrameProfiler.PHASE_REPLAY)
            prof:set_metric(FrameProfiler.METRIC_THROTTLED, 1)
            prof:end_frame()
        end
        return
    end

    -- Profiler: events/style/layout/paint are interleaved per-window, so we
    -- measure them cumulatively using local accumulators
    local _prof_events_t, _prof_style_t, _prof_layout_t, _prof_paint_t = 0, 0, 0, 0
    local _prof_dirty_style, _prof_dirty_layout, _prof_nodes_painted = 0, 0, 0
    local function _prof_ticks()
        return platform_ticks(self.platform)
    end
    local _prof_tick  -- reusable local for phase boundary

    if prof_on then _prof_tick = _prof_ticks() end  -- events pre-loop timing start

    -- 4a. Context menu interaction (consumes clicks before windows)
    local ctx_menu_consumed = false
    if self.context_menu:is_open() then
        if self.input:is_right_mouse_clicked() then
            -- Right-click while open: close old menu, do NOT consume -"
            -- let the right-click reach _open_context_menu for new target.
            self.context_menu:close()
        else
            local action, consumed = self.context_menu:update(self.input)
            if action then
                pcall(action)
            end
            -- Block left-clicks: either the update consumed a click (item or dismiss)
            -- or the cursor is over the still-open menu (hover tracking)
            if consumed then
                ctx_menu_consumed = true
            elseif self.context_menu:is_open() and self.context_menu:hit_test(self.input.cursor_x, self.input.cursor_y) then
                ctx_menu_consumed = true
            end
        end
    end

    -- 4b. Clear the display list and advance gradient cache
    self.display_list:clear()
    Gradient.begin_frame()

    -- 4.5. Determine event target window
    local event_win_id = nil
    if not self.window_manager._drag and not self._external_drag then
        if any_scroll_drag then
            for wid, mount in pairs(self._mounts) do
                if mount.scroll_engine and (mount.scroll_engine._drag_nid or mount.scroll_engine._drag_h_nid) then
                    event_win_id = wid
                    break
                end
            end
        end
        if not event_win_id then
            for i = #windows, 1, -1 do
                local w = windows[i]
                if w.visible then
                    local mx, my = self.input.cursor_x, self.input.cursor_y
                    if mx >= w.x and mx < w.x + w.w and my >= w.y and my < w.y + w.h then
                        event_win_id = w.id
                        break
                    end
                end
            end
        end
    end

    if prof_on then _prof_events_t = _prof_events_t + (_prof_ticks() - _prof_tick) end

    -- 5. Paint each visible window
    for i = 1, #windows do
        local win = windows[i]
        if win.visible then
            self.window_manager:paint_chrome_bg(self.display_list, win)

            if not win.minimized then
            local mount = self._mounts[win.id]
            if mount and mount.root_id and mount.root_id ~= 0 then
                local cx, cy, cw, ch = self.window_manager:get_content_rect(win)

                local prev = mount._prev_rect
                if not prev or prev[1] ~= cx or prev[2] ~= cy or prev[3] ~= cw or prev[4] ~= ch then
                    if prev and prev[3] == cw and prev[4] == ch
                       and not mount.style_dirty and not mount.layout_dirty then
                        shift_layout_tree(mount.node_store, mount.root_id, cx - prev[1], cy - prev[2])
                    else
                        mount.layout_dirty = true
                        mount.style_dirty = true  -- media queries may change on size changes
                    end
                    mount._prev_rect = { cx, cy, cw, ch }
                end
                -- Pass window bg for image masking (dark default)
                self.display_list:clip_push(cx, cy, cw, ch, 30, 30, 30, 255)

                Painters._clip_rect = { cx, cy, cw, ch }

                if prof_on then _prof_tick = _prof_ticks() end  -- per-window events start

                local root_id = mount.root_id
                local ns = mount.node_store
                local es = mount.event_system
                local se = mount.style_engine
                local le = mount.layout_engine
                local te = mount.transition_engine

                local is_event_target = (win.id == event_win_id) and not ctx_menu_consumed

                if is_event_target then
                    -- Hit test
                    local ok_ht, err_ht = pcall(es.hit_test, es, root_id, self.input.cursor_x, self.input.cursor_y, 0, 0)
                    if not ok_ht then
                        self.platform:log_error("[astro] hit_test error in " .. win.id .. ": " .. tostring(err_ht))
                    end

                    -- Dispatch pointer events
                    local ok_ev, err_ev = pcall(es.dispatch_pointer_events, es, self.input)
                    if not ok_ev then
                        self.platform:log_error("[astro] event error in " .. win.id .. ": " .. tostring(err_ev))
                    end

                    -- Re-entrancy guard: an action handler invoked by the
                    -- pointer dispatch above may have called engine:load_html /
                    -- load_url / reload, replacing this window's mount.  The
                    -- locals captured into `mount`/`ns`/`es`/... still point
                    -- at the discarded tree.  Mark the local mount stale so
                    -- the rest of the per-window pipeline bails out before
                    -- using its node_store / style_engine / etc.  Lua 5.1 has
                    -- no `goto`/`continue`, so the bail-out propagates via
                    -- nested `if mount_stale then ... end` guards below.
                    if self._mounts[win.id] ~= mount then
                        mount._stale = true
                    end

                    -- Tab focus navigation
                    local ok_fv, err_fv = pcall(es.dispatch_focus_events, es, self.input, root_id)
                    -- Keyboard activation (Space/Enter) on the currently focused element
                    pcall(es.dispatch_keyboard_activation, es, self.input)
                    if not ok_fv then
                        self.platform:log_error("[astro] focus error in " .. win.id .. ": " .. tostring(err_fv))
                    end

                    -- Scroll engine update
                    local ok_sc, err_sc = pcall(mount.scroll_engine.update, mount.scroll_engine, self.input, es)
                    if not ok_sc then
                        self.platform:log_error("[astro] scroll error in " .. win.id .. ": " .. tostring(err_sc))
                    end
                    local _se = mount.scroll_engine
                    if self.input.wheel ~= 0
                       or _se._drag_nid
                       or _se._drag_h_nid
                       or self.input:is_key_edge(0x25)
                       or self.input:is_key_edge(0x26)
                       or self.input:is_key_edge(0x27)
                       or self.input:is_key_edge(0x28)
                       or self.input:is_key_edge(0x21)
                       or self.input:is_key_edge(0x22)
                       or self.input:is_key_edge(0x24)
                       or self.input:is_key_edge(0x23)
                       or next(_se._smooth_target_y)
                       or next(_se._smooth_target_x)
                       or next(_se._snap_active)
                    then
                        -- Scroll changes child positions -" trigger full re-layout
                        -- so children are positioned with the new scroll offset.
                        -- (The scroll delta fast-path was disabled because it caused
                        -- visual stalls where the UI wouldn't repaint until the
                        -- cursor moved out of the window and back in.)
                        mount.layout_dirty = true
                    end


                    -- Right-click: open context menu
                    if self.input:is_right_mouse_clicked() then
                        self:_open_context_menu(win.id, mount, es)
                    end

                    -- If pseudo states changed, mark style dirty
                    if es.pseudo_changed then
                        mount.style_dirty = true
                        -- With complex selectors, pseudo changes may affect
                        -- nodes beyond the hover chain, so mark all dirty
                        if #se.rules_complex > 0 then
                            ns:walk_depth_first(root_id, function(child_nid)
                                ns:mark_dirty(child_nid, ns.STYLE_DIRTY)
                            end)
                        end
                    end
                end

                -- Component updates.  Components run for every visible
                -- window (validation, caret blink, animation), but pointer
                -- input must only reach the topmost event target window.
                -- Keyboard input remains available to the focused window.
                local dt = self.platform:delta_time()
                local component_input = self.input
                if not is_event_target then
                    local keyboard_active = (win.id == focused_win_id)
                    local raw_input = self.input
                    component_input = {
                        cursor_x = raw_input.cursor_x,
                        cursor_y = raw_input.cursor_y,
                        wheel = 0,
                        shift = raw_input.shift,
                        ctrl = raw_input.ctrl,
                        alt = raw_input.alt,
                        VK = raw_input.VK,
                        is_mouse_clicked = function() return false end,
                        is_mouse_down = function() return false end,
                        is_mouse_released = function() return false end,
                        is_right_mouse_clicked = function() return false end,
                        is_key_edge = function(_, vk)
                            return keyboard_active and raw_input:is_key_edge(vk) or false
                        end,
                        is_key_pressed = function(_, vk)
                            return keyboard_active and raw_input:is_key_pressed(vk) or false
                        end,
                        consume_text_events = function()
                            if keyboard_active then return raw_input:consume_text_events() end
                            return {}
                        end,
                    }
                end
                for comp_nid, comp in pairs(mount.components) do
                    local ok_cu, err_cu = pcall(function()
                        if comp.type == "input" then
                            comp.inst:update(ns, comp_nid, component_input, es, dt)
                        elseif comp.type == "textarea" then
                            comp.inst:update(ns, comp_nid, component_input, es, dt)
                        elseif comp.type == "slider" then
                            comp.inst:update(ns, comp_nid, component_input, es)
                        elseif comp.type == "select" then
                            comp.inst:update(ns, comp_nid, component_input, es)
                        elseif comp.type == "particle-emitter" then
                            comp.inst:update(ns, comp_nid, component_input, es, dt)
                        elseif comp.type == "input-number" then
                            comp.inst:update(ns, comp_nid, component_input, es, dt)
                        elseif comp.type == "input-color" then
                            comp.inst:update(ns, comp_nid, component_input, es, dt)
                        elseif comp.type == "sound" then
                            comp.inst:update(ns, comp_nid, component_input, es, dt, self.platform)
                        end
                    end)
                    if not ok_cu then
                        self.platform:log_error("[astro] component error in " .. win.id .. ": " .. tostring(err_cu))
                    end
                end

                -- Promote per-node dirty bits into mount-level flags so the
                -- style/layout passes know they need to run.  Skip the scan
                -- when both flags are already set -" there is nothing more to
                -- learn -" and also when the NS-tracked counters say the tree
                -- is entirely clean.  This eliminates the O(N) walk that
                -- previously ran every frame on idle pages.
                if not (mount.style_dirty and mount.layout_dirty) then
                    if (ns._dirty_count or 0) > 0 then
                        for _, flags in pairs(ns.dirty) do
                            if flags and flags > 0 then
                                if flags % 2 == 1 then
                                    mount.style_dirty = true
                                end
                                if math.floor(flags / 2) % 2 == 1 then
                                    mount.layout_dirty = true
                                end
                                if mount.style_dirty and mount.layout_dirty then
                                    break
                                end
                            end
                        end
                    end
                end

                -- Profiler: end per-window events, start style
                if prof_on then
                    _prof_events_t = _prof_events_t + (_prof_ticks() - _prof_tick)
                    _prof_tick = _prof_ticks()
                end

                -- Transition snapshot (before style resolve)
                if te then
                    pcall(function()
                        te:cleanup_removed(ns)
                        te:snapshot(ns, root_id)
                    end)
                end

                -- Update viewport for media queries.  When the viewport
                -- actually changed (window resize, window creation) mark the
                -- full tree style-dirty so @media rules re-evaluate this
                -- frame instead of waiting for an unrelated trigger.
                local prev_vw = mount._prev_viewport_w or 0
                local prev_vh = mount._prev_viewport_h or 0
                if prev_vw ~= cw or prev_vh ~= ch then
                    mount._prev_viewport_w = cw
                    mount._prev_viewport_h = ch
                    mount.style_dirty = true
                    mount.layout_dirty = true
                    -- Mark every node so the cascade re-runs everywhere
                    ns:walk_depth_first(root_id, function(n)
                        ns:mark_dirty(n, ns.STYLE_DIRTY)
                    end)
                end
                se:set_viewport(cw, ch)

                -- Style resolve (if dirty)
                if prof_on and mount.style_dirty then _prof_dirty_style = _prof_dirty_style + 1 end
                if mount.style_dirty then
                    local ok_st, err_st = pcall(se.resolve, se, root_id)
                    if not ok_st then
                        self.platform:log_error("[astro] style error in " .. win.id .. ": " .. tostring(err_st))
                    end
                    mount.style_dirty = false
                    mount.layout_dirty = true

                    -- Resolve CSS counters (counter-reset/increment → content)
                    pcall(Counters.resolve, ns, root_id)

                    -- Drain any removals that happened during style resolve
                    -- (e.g. pseudo-node recycling) before detect_changes sees them
                    if te then
                        pcall(te.cleanup_removed, te, ns)
                    end

                    -- Detect transition changes after style resolve
                    if te then
                        pcall(te.detect_changes, te, ns, root_id, current_time)
                    end
                end

                -- Tick transitions/animations (apply overrides to computed styles)
                if te then
                    local ok_te, result_active, result_dirty = pcall(te.tick, te, ns, current_time)
                    -- Process dirty flags even when animation just finished
                    -- (result_active may be false on the final tick, but
                    -- result_dirty still contains the last frame's changes)
                    if ok_te and result_dirty then
                        local needs_layout = false
                        for anim_nid, anim_flags in pairs(result_dirty) do
                            ns:mark_dirty(anim_nid, anim_flags)
                            -- Propagate layout dirty to ancestors
                            if math.floor(anim_flags / 2) % 2 == 1 then
                                ns:mark_ancestors_dirty(anim_nid, 2 + 4)
                                needs_layout = true
                            end
                            -- Inherited properties: cascade to children
                            -- STYLE_DIRTY (bit 1) = inherited property changed
                            if anim_flags % 2 == 1 then
                                -- Determine what children need:
                                -- inherited layout (flags>=7) → STYLE+LAYOUT
                                -- inherited paint  (flags=5)  → STYLE+PAINT only
                                local child_flags = (math.floor(anim_flags / 2) % 2 == 1) and (1 + 2) or (1 + 4)
                                -- Only mark direct children dirty -" Task 5's
                                -- incremental resolver cascades inheritance automatically
                                local cid = ns.first_child[anim_nid]
                                while cid and cid ~= 0 do
                                    ns:mark_dirty(cid, child_flags)
                                    cid = ns.next_sibling[cid] or 0
                                end
                                mount.style_dirty = true
                            end
                        end
                        if needs_layout then
                            mount.layout_dirty = true
                        end
                        -- Re-resolve style immediately when animations
                        -- changed inherited properties, so children
                        -- pick up the new value in this same frame.
                        if mount.style_dirty then
                            pcall(se.resolve, se, root_id)
                            mount.layout_dirty = true
                            -- Re-apply animated values (resolve overwrites computed)
                            pcall(te.tick, te, ns, current_time)
                        end
                    end
                end

                -- If a resize drag just ended, force re-layout to clear SVG live_resize flag
                if le._live_resize then
                    local drag = self.window_manager._drag
                    if not (drag and drag.mode == "resize" and drag.win_id == win.id) then
                        mount.layout_dirty = true
                    end
                end

                -- Details toggle update (after style resolve so display overrides persist)
                pcall(function()
                    for det_nid in pairs(ns._details) do
                        DetailsComp.update(ns, det_nid, self.input, es)
                    end
                end)
                -- If any details node toggled, it set display:none on children
                -- which requires a layout pass
                for det_nid in pairs(ns._details) do
                    local df = ns.dirty[det_nid]
                    if df and df > 0 then
                        mount.layout_dirty = true
                        break
                    end
                end

                -- Dialog open/close handling (same pattern as details).
                -- Dialog.update ALWAYS runs so display stays in sync with
                -- the `open` attr (style resolve re-applies UA `display:none`
                -- every frame; update flips it back to block).  The input
                -- gating (skip outside-click + ESC during resize / when
                -- another window is focused) is passed into the component
                -- via the input_active flag.
                local wm_drag = self.window_manager._drag
                local is_resizing_this = wm_drag and wm_drag.mode == "resize"
                                         and wm_drag.win_id == win.id
                local dialog_input_active = is_event_target and not is_resizing_this
                pcall(function()
                    for dlg_nid in pairs(ns._dialogs) do
                        DialogComp.update(ns, dlg_nid, self.input, es, dialog_input_active)
                    end
                end)
                for dlg_nid in pairs(ns._dialogs) do
                    local df = ns.dirty[dlg_nid]
                    if df and df > 0 then
                        mount.layout_dirty = true
                        break
                    end
                end

                -- Profiler: end style phase, start layout phase
                if prof_on then
                    _prof_style_t = _prof_style_t + (_prof_ticks() - _prof_tick)
                    _prof_tick = _prof_ticks()
                end

                -- Layout (if dirty) or scroll-only fast path
                if prof_on and mount.layout_dirty then _prof_dirty_layout = _prof_dirty_layout + 1 end
                if mount.layout_dirty then
                    -- Full layout: sizes, positions, text wrap, flex, etc.
                    local root_comp = ns.computed[root_id]
                    if root_comp then
                        local rov = root_comp.overflow_y
                        if not rov or rov == "visible" then
                            root_comp.overflow_y = "auto"
                        end
                    end

                    -- Detect active window resize for SVG performance optimization
                    local drag = self.window_manager._drag
                    le._live_resize = (drag and drag.mode == "resize" and drag.win_id == win.id) or false

                    local ok_ly, err_ly = pcall(le.layout, le, root_id, cx, cy, cw, ch)
                    if not ok_ly then
                        self.platform:log_error("[astro] layout error in " .. win.id .. ": " .. tostring(err_ly))
                    end
                    -- Clamp scroll offsets; if any were clamped, re-layout so
                    -- children reflect the corrected scroll.y in this frame.
                    if mount.scroll_engine:clamp_offsets() then
                        pcall(le.layout, le, root_id, cx, cy, cw, ch)
                    end
                    mount.layout_dirty = false
                    -- Bump the engine-wide layout generation counter so
                    -- external mirrors (e.g. the studio JS-side layoutRects
                    -- cache) can detect that node positions/sizes may have
                    -- changed without piggy-backing on the input/dirty path.
                    -- Without this, async font load completion re-lays out
                    -- the tree but the JS mirror keeps the pre-font rects,
                    -- producing a 4-6 CSS-px clip offset in pixel-diff.
                    self._layout_gen = (self._layout_gen or 0) + 1
                    mount.scroll_dirty = false
                    -- Snapshot scroll offsets for delta tracking
                    self:_snapshot_scroll(mount, ns)

                    -- @container query two-pass: after layout finishes we
                    -- know each containment root's box size. If any changed
                    -- (including the first-frame nil→N transition), re-run
                    -- the cascade so @container rules can pick up the new
                    -- sizes, then re-layout once. Gated on _container_groups
                    -- so bundles without @container pay no cost.
                    if #se._container_groups > 0 and se:check_container_changes(root_id) then
                        ns:walk_depth_first(root_id, function(n)
                            ns:mark_dirty(n, ns.STYLE_DIRTY + ns.LAYOUT_DIRTY)
                        end)
                        pcall(se.resolve, se, root_id)
                        pcall(le.layout, le, root_id, cx, cy, cw, ch)
                        self._layout_gen = (self._layout_gen or 0) + 1
                    end

                elseif mount.scroll_dirty then
                    -- Fast path: only scroll offsets changed, no sizes.
                    -- Apply position deltas instead of full re-layout.
                    local ok_sd, err_sd = pcall(self._apply_scroll_deltas, self, mount, ns, root_id, le)
                    if not ok_sd then
                        -- Fallback: if delta application fails, do full layout
                        self.platform:log_error("[astro] scroll-delta fallback in " .. win.id .. ": " .. tostring(err_sd))
                        pcall(le.layout, le, root_id, cx, cy, cw, ch)
                        self:_snapshot_scroll(mount, ns)
                    end
                    mount.scroll_dirty = false
                end

                -- Profiler: end layout phase, start paint phase
                if prof_on then
                    _prof_layout_t = _prof_layout_t + (_prof_ticks() - _prof_tick)
                    _prof_tick = _prof_ticks()
                end

                -- Set SVG interactive flag for span-based rendering during scroll/resize.
                -- When active, partially visible SVGs use rect_fill spans instead of
                -- expensive per-frame PNG encode + texture upload for crops.
                -- Per-window: only the window being resized/scrolled uses span mode.
                local wm_drag = self.window_manager._drag
                local is_resizing = wm_drag and wm_drag.mode == "resize" and wm_drag.win_id == win.id
                local scr = mount.scroll_engine
                local is_scrolling = self.input.wheel ~= 0
                                  or (scr and (scr._drag_nid or scr._drag_h_nid))
                                  or self.input:is_key_edge(0x25) or self.input:is_key_edge(0x26)
                                  or self.input:is_key_edge(0x27) or self.input:is_key_edge(0x28)
                                  or self.input:is_key_edge(0x21) or self.input:is_key_edge(0x22)
                                  or self.input:is_key_edge(0x24) or self.input:is_key_edge(0x23)
                SvgRenderer._interactive = is_resizing or is_scrolling or false

                -- Paint tree.  Set per-mount base URL so painters can
                -- resolve relative <img src> against the page origin.
                Painters._base_url = mount._base_url
                local _dl_before = prof_on and self.display_list._len or 0

                local win_cr = Painters._clip_rect
                -- Skip painting if a mid-frame script call replaced this
                -- mount.  Painting the stale tree would reference recycled
                -- node ids; the new mount is style/layout dirty and will
                -- paint on the next frame.
                local ok_pt, err_pt = true, nil
                if not mount._stale and self._mounts[win.id] == mount then
                    ok_pt, err_pt = pcall(Painters.paint_tree, ns, root_id, self.display_list, self.platform)
                end
                if not ok_pt then
                    self.platform:log_error("[astro] paint error in " .. win.id .. ": " .. tostring(err_pt))
                end
                if prof_on then _prof_nodes_painted = _prof_nodes_painted + (self.display_list._len - _dl_before) end

                -- Component custom painting
                for comp_nid, comp in pairs(mount.components) do
                    if comp.inst and comp.inst.paint then
                        local defer_dialog_control = (comp.type == "select" and node_is_in_open_dialog(ns, comp_nid))
                        if not defer_dialog_control then
                            local ok_cp, err_cp = pcall_component_method_with_clip(
                                self.display_list, ns, root_id, comp_nid,
                                comp.inst.paint, comp.inst, self.platform)
                            if not ok_cp then
                                self.platform:log_error("[astro] comp paint error in " .. win.id .. ": " .. tostring(err_cp))
                            end
                        end
                    end
                end

                -- Checkbox + Radio + Progress + Meter + Details custom painting (registry-based)
                pcall(function()
                    for cb_nid in pairs(ns._checkboxes) do
                        pcall_component_function_with_clip(self.display_list, ns, root_id, cb_nid, Checkbox.paint, self.platform)
                    end
                    for rb_nid in pairs(ns._radios) do
                        pcall_component_function_with_clip(self.display_list, ns, root_id, rb_nid, Radio.paint, self.platform)
                    end
                    for pg_nid in pairs(ns._progress) do
                        pcall_component_function_with_clip(self.display_list, ns, root_id, pg_nid, Progress.paint, self.platform)
                    end
                    for mt_nid in pairs(ns._meters) do
                        pcall_component_function_with_clip(self.display_list, ns, root_id, mt_nid, MeterComp.paint, self.platform)
                    end
                    for dt_nid in pairs(ns._details) do
                        pcall_component_function_with_clip(self.display_list, ns, root_id, dt_nid, DetailsComp.paint, self.platform)
                    end
                end)

                -- Scrollbar painting (iterate scroll registry, not full tree)
                pcall(function()
                    for sb_nid in pairs(ns.scroll) do
                        mount.scroll_engine:paint_scrollbar(ns, sb_nid, self.display_list)
                    end
                end)

                -- Open dropdowns paint after page/component scrollbars so the
                -- popup behaves like browser top-layer control chrome within
                -- the window instead of being clipped behind range/scroll UI.
                for comp_nid, comp in pairs(mount.components) do
                    if comp.type == "select" and comp.inst and comp.inst.paint_overlay then
                        if not node_is_in_open_dialog(ns, comp_nid) then
                            local ok_so, err_so = pcall(comp.inst.paint_overlay, comp.inst, ns, comp_nid, self.display_list, self.platform)
                            if not ok_so then
                                self.platform:log_error("[astro] select overlay paint error in " .. win.id .. ": " .. tostring(err_so))
                            end
                        end
                    end
                end

                -- Paint modal backdrops AFTER the main tree + scrollbars so the
                -- dim overlay sits above normal content and BELOW the dialog.
                for dlg_nid in pairs(ns._dialogs) do
                    pcall(DialogComp.paint_backdrop, ns, dlg_nid, self.display_list, self.platform, win_cr)
                end

                -- Paint deferred position:fixed subtrees AFTER scrollbars so
                -- modals / overlays stay on top of scroll chrome beneath them.
                pcall(Painters.paint_fixed_deferred, ns, self.display_list, self.platform)

                -- Selects inside open dialogs belong to the same top layer as
                -- the dialog. Paint their control chrome and popup after the
                -- deferred dialog subtree so the chevron/options are not
                -- covered by the modal itself.
                for comp_nid, comp in pairs(mount.components) do
                    if comp.type == "select" and comp.inst and node_is_in_open_dialog(ns, comp_nid) then
                        if comp.inst.paint then
                            local ok_cp, err_cp = pcall_component_method_with_clip(
                                self.display_list, ns, root_id, comp_nid,
                                comp.inst.paint, comp.inst, self.platform)
                            if not ok_cp then
                                self.platform:log_error("[astro] dialog select paint error in " .. win.id .. ": " .. tostring(err_cp))
                            end
                        end
                        if comp.inst.paint_overlay then
                            local ok_so, err_so = pcall(comp.inst.paint_overlay, comp.inst, ns, comp_nid, self.display_list, self.platform)
                            if not ok_so then
                                self.platform:log_error("[astro] dialog select overlay paint error in " .. win.id .. ": " .. tostring(err_so))
                            end
                        end
                    end
                end

                -- Devtools overlay
                if mount.devtools.enabled then
                    pcall(mount.devtools.paint, mount.devtools, ns, root_id, self.display_list, self.platform, es)
                end

                -- Tooltip (title attribute) painted last so it sits on top.
                pcall(es.paint_tooltip, es, self.display_list, self.input, Painters._clip_rect)

                self.display_list:clip_pop()

                -- Clear PAINT_DIRTY (bit 4) after paint.  PAINT_DIRTY was
                -- never cleared, causing mark_dirty early returns that skip
                -- subtree_dirty propagation on future frames.
                local _dirty = ns.dirty
                for dnid, dval in pairs(_dirty) do
                    if dval >= 4 then
                        -- Clear bit 4 using modular arithmetic (Lua 5.1 safe)
                        local has4 = dval % 8 >= 4
                        if has4 then _dirty[dnid] = dval - 4 end
                    end
                end

                -- Profiler: end paint phase for this window
                if prof_on then
                    _prof_paint_t = _prof_paint_t + (_prof_ticks() - _prof_tick)
                end
            elseif mount and mount.bundle then
                local cx, cy, cw, ch = self.window_manager:get_content_rect(win)
                self.display_list:clip_push(cx, cy, cw, ch, 30, 30, 30, 255)

                if type(mount.bundle) == "table" and type(mount.bundle.paint) == "function" then
                    local ok, err = pcall(mount.bundle.paint, mount.bundle, {
                        dl       = self.display_list,
                        input    = self.input,
                        state    = mount.state,
                        x        = cx,
                        y        = cy,
                        w        = cw,
                        h        = ch,
                        platform = self.platform,
                    })
                    if not ok then
                        self.platform:log_error("[astro] paint error in " .. win.id .. ": " .. tostring(err))
                    end
                end

                self.display_list:clip_pop()
            end
            end

            self.window_manager:paint_chrome_fg(self.display_list, win)
        end
    end

    -- Profiler: write accumulated phase times + metrics
    if prof_on then
        prof:set_phase_ticks(FrameProfiler.PHASE_EVENTS, _prof_events_t)
        prof:set_phase_ticks(FrameProfiler.PHASE_STYLE, _prof_style_t)
        prof:set_phase_ticks(FrameProfiler.PHASE_LAYOUT, _prof_layout_t)
        prof:set_phase_ticks(FrameProfiler.PHASE_PAINT, _prof_paint_t)
        prof:set_metric(FrameProfiler.METRIC_DIRTY_STYLE, _prof_dirty_style)
        prof:set_metric(FrameProfiler.METRIC_DIRTY_LAYOUT, _prof_dirty_layout)
        prof:set_metric(FrameProfiler.METRIC_NODES_PAINTED, _prof_nodes_painted)
    end

    -- 5b. Paint context menu overlay (window-independent, on top of everything)
    self.context_menu:paint(self.display_list)

    -- 5c. Idle detection: if no dirty flags or animations for N frames → idle mode
    local has_active_anims = false
    for _, mount in pairs(self._mounts) do
        if mount.transition_engine and mount.transition_engine:is_active() then
            has_active_anims = true
            break
        end
    end
    if not any_paint_needed and not has_active_anims then
        self._idle_frame_count = self._idle_frame_count + 1
        if self._idle_frame_count >= self._idle_threshold then
            self._is_idle = true
        end
    else
        self._idle_frame_count = 0
        self._is_idle = false
    end

    -- 6. Cache display list length for frame-skip, then replay
    if prof_on then prof:begin_phase(FrameProfiler.PHASE_REPLAY) end
    self._dl_len = self.display_list._len
    self.display_list:replay(self.platform)
    if prof_on then prof:end_phase(FrameProfiler.PHASE_REPLAY) end

    if prof_on then prof:end_frame() end
end

------------------------------------------------------------
-- Frame Throttling API
------------------------------------------------------------

--- Set the UI frame rate caps.
---@param active_fps number|nil  max FPS when active (default 60)
---@param idle_fps   number|nil  max FPS when idle (default 30)
function Engine:set_fps_cap(active_fps, idle_fps)
    active_fps = tonumber(active_fps) or 60
    idle_fps = tonumber(idle_fps) or 30
    if active_fps < 1 then active_fps = 1 end
    if active_fps > 300 then active_fps = 300 end
    if idle_fps < 1 then idle_fps = 1 end
    if idle_fps > 300 then idle_fps = 300 end
    self._ui_fps_cap = active_fps
    self._ui_idle_fps_cap = idle_fps
end

------------------------------------------------------------
-- Profiler API
------------------------------------------------------------

--- Enable the built-in frame profiler.
function Engine:enable_profiler()
    if self._profiler then self._profiler:enable() end
end

--- Disable the built-in frame profiler.
function Engine:disable_profiler()
    if self._profiler then self._profiler:disable() end
end

--- Get frame statistics from the profiler.
---@return table|nil  stats with avg/min/max/p95 per phase, or nil if disabled/no data
function Engine:get_frame_stats()
    if self._profiler then return self._profiler:get_stats() end
    return nil
end

------------------------------------------------------------
-- Scroll fast-path helpers
------------------------------------------------------------

--- Snapshot current scroll offsets for delta tracking next frame.
---@param mount table  mount structure
---@param ns    table  NodeStore instance
function Engine:_snapshot_scroll(mount, ns)
    local prev = mount._prev_scroll
    if not prev then
        prev = {}
        mount._prev_scroll = prev
    end
    for container_nid, scroll_data in pairs(ns.scroll) do
        local p = prev[container_nid]
        if not p then
            p = { x = 0, y = 0 }
            prev[container_nid] = p
        end
        p.x = scroll_data.x or 0
        p.y = scroll_data.y or 0
    end
end

--- Apply scroll offset deltas to descendant positions.
--- Avoids full re-layout when only scroll offsets changed.
---@param mount   table  mount structure
---@param ns      table  NodeStore instance
---@param root_id number root node id
---@param le      table  LayoutEngine instance
function Engine:_apply_scroll_deltas(mount, ns, root_id, le)
    local prev = mount._prev_scroll
    if not prev then
        -- No previous snapshot -" first frame; fall back to full layout
        mount.layout_dirty = true
        return
    end

    -- Custom walk that shifts descendants but SKIPS position:fixed subtrees.
    -- Fixed nodes are viewport-relative and must not move with scroll.
    local function shift_descendants(container_nid, dx, dy)
        local stack = {}
        local sp = 0
        -- Push direct children of the container
        local cid = ns.last_child[container_nid]
        while cid and cid ~= 0 do
            sp = sp + 1; stack[sp] = cid
            cid = ns.prev_sibling[cid] or 0
        end
        while sp > 0 do
            local nid = stack[sp]; sp = sp - 1
            local comp = ns.computed[nid]
            -- Skip position:fixed subtrees (they are viewport-relative)
            if comp and comp.position == "fixed" then
                -- do not shift, do not push children
            else
                local child_lay = ns.layout[nid]
                if child_lay then
                    child_lay.x = child_lay.x - dx
                    child_lay.y = child_lay.y - dy
                    if child_lay.content_x then child_lay.content_x = child_lay.content_x - dx end
                    if child_lay.content_y then child_lay.content_y = child_lay.content_y - dy end
                end
                -- Push children
                local c = ns.last_child[nid]
                while c and c ~= 0 do
                    sp = sp + 1; stack[sp] = c
                    c = ns.prev_sibling[c] or 0
                end
            end
        end
    end

    -- Save pre-clamp scroll values so we can detect clamping corrections
    local pre_clamp = {}
    for container_nid, scroll_data in pairs(ns.scroll) do
        pre_clamp[container_nid] = {
            x = scroll_data.x or 0,
            y = scroll_data.y or 0,
        }
    end

    -- Phase 1: apply deltas from prev to current scroll values
    for container_nid, scroll_data in pairs(ns.scroll) do
        local p = prev[container_nid]
        local prev_y = p and p.y or 0
        local prev_x = p and p.x or 0
        local dy = (scroll_data.y or 0) - prev_y
        local dx = (scroll_data.x or 0) - prev_x
        if dy ~= 0 or dx ~= 0 then
            shift_descendants(container_nid, dx, dy)
        end
    end

    -- Snapshot sticky positions BEFORE re-resolve so we can shift children
    local sticky_before = {}
    if le._sticky_nodes then
        for i = 1, #le._sticky_nodes do
            local entry = le._sticky_nodes[i]
            local lay = ns.layout[entry.nid]
            if lay then
                sticky_before[entry.nid] = { x = lay.x, y = lay.y }
            end
        end
    end

    -- Re-resolve sticky positions with updated scroll offsets
    if le._resolve_sticky then
        le:_resolve_sticky(root_id)
    end

    -- Shift sticky children by the delta the sticky node moved
    if le._sticky_nodes then
        for i = 1, #le._sticky_nodes do
            local entry = le._sticky_nodes[i]
            local sb = sticky_before[entry.nid]
            local lay = ns.layout[entry.nid]
            if sb and lay then
                local sdy = lay.y - sb.y
                local sdx = lay.x - sb.x
                if sdy ~= 0 or sdx ~= 0 then
                    shift_descendants(entry.nid, -sdx, -sdy)
                end
            end
        end
    end

    -- Re-resolve fixed positions (viewport-relative, unaffected by scroll)
    if le._resolve_fixed then
        le:_resolve_fixed()
    end

    -- Phase 2: clamp may further adjust scroll offsets
    if mount.scroll_engine:clamp_offsets() then
        -- Apply correction delta (clamped - pre_clamp) for each container
        for container_nid, scroll_data in pairs(ns.scroll) do
            local pc = pre_clamp[container_nid]
            if pc then
                local dy = (scroll_data.y or 0) - pc.y
                local dx = (scroll_data.x or 0) - pc.x
                if dy ~= 0 or dx ~= 0 then
                    shift_descendants(container_nid, dx, dy)
                end
            end
        end
        if le._resolve_sticky then
            le:_resolve_sticky(root_id)
        end
        if le._resolve_fixed then
            le:_resolve_fixed()
        end
    end

    -- Update snapshot
    self:_snapshot_scroll(mount, ns)
end

------------------------------------------------------------
-- Context menu helpers
------------------------------------------------------------

--- Build and open a context menu for a right-click event.
---@param win_id string       window id
---@param mount  table        mount structure
---@param es     table        event system
function Engine:_open_context_menu(win_id, mount, es)
    local ns = mount.node_store
    local items = {}
    local chain = es.hover_chain

    -- 1. Check for text selection → add Copy / Select All
    local has_selection = false
    for nid in pairs(es._sel_nodes) do
        if ns.pseudo[nid] and ns.pseudo[nid].selected then
            has_selection = true
            break
        end
    end

    if has_selection then
        -- Snapshot selected nodes in DOM (DFS) order for deterministic copy.
        -- Node IDs can be recycled, so numeric sort is not reliable.
        local Clipboard = require("core/util/clipboard")
        local sel_set = es._sel_nodes
        local sel_ordered = {}
        local root_id = mount.root_id
        if root_id and root_id ~= 0 then
            ns:walk_depth_first(root_id, function(nid)
                if sel_set[nid] then
                    sel_ordered[#sel_ordered + 1] = nid
                end
            end)
        end
        items[#items + 1] = {
            label = "Copy",
            shortcut = "Ctrl+C",
            action = function()
                local parts = {}
                for i = 1, #sel_ordered do
                    local nid = sel_ordered[i]
                    local p = ns.pseudo[nid]
                    local text = ns.text_content[nid] or ""
                    if p and p.sel_start and p.sel_end and text ~= "" then
                        local s = p.sel_start + 1
                        local e = p.sel_end
                        if s <= e and s >= 1 and e <= #text then
                            parts[#parts + 1] = text:sub(s, e)
                        end
                    end
                end
                if #parts > 0 then
                    Clipboard.write(table.concat(parts, ""))
                end
            end,
        }
    end

    -- 2. Check if right-clicked on a text node → add Select All
    local text_nid = 0
    for i = 1, #chain do
        local nid = chain[i]
        if ns.node_type[nid] == ns.TEXT then
            text_nid = nid
            break
        end
        local cid = ns.first_child[nid]
        while cid and cid ~= 0 do
            if ns.node_type[cid] == ns.TEXT then text_nid = cid; break end
            cid = ns.next_sibling[cid] or 0
        end
        if text_nid ~= 0 then break end
    end

    -- 3. Check for input field context
    local input_nid = 0
    local input_comp = nil
    if mount.components then
        for i = 1, #chain do
            local nid = chain[i]
            local comp = mount.components[nid]
            if comp and (comp.type == "input" or comp.type == "textarea") then
                input_nid = nid
                input_comp = comp
                break
            end
        end
    end

    if input_nid ~= 0 and input_comp then
        -- Input field context menu
        local inst = input_comp.inst
        local Clipboard = require("core/util/clipboard")

        -- Check if input has a selection
        local input_has_sel = inst and inst._has_sel and inst:_has_sel()
        local is_password = inst and inst._mask_char
        local input_pseudo = ns.pseudo[input_nid]
        local is_disabled = input_pseudo and input_pseudo.disabled

        if #items > 0 then
            items[#items + 1] = { separator = true }
        end
        -- Helper: fire onChange + validation after text edits
        local function _after_edit()
            mount.style_dirty  = true
            mount.layout_dirty = true
            if inst._update_validation then
                inst:_update_validation(ns, input_nid)
            end
            local attrs = ns.attrs[input_nid]
            local on_change = attrs and (attrs.onChange or attrs.onchange)
            if on_change then
                local handler = es._action_handlers[on_change]
                if handler then pcall(handler, input_nid, on_change) end
            end
        end

        items[#items + 1] = {
            label = "Cut",
            shortcut = "Ctrl+X",
            disabled = not input_has_sel or is_disabled,
            action = function()
                if inst and inst:_has_sel() then
                    local text = ns.text_content[input_nid] or ""
                    if not is_password then
                        local lo, hi = inst:_sel_range()
                        Clipboard.write(text:sub(lo + 1, hi))
                    end
                    text, inst.caret_pos = inst:_delete_sel(text)
                    ns.text_content[input_nid] = text
                    ns:mark_dirty(input_nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
                    _after_edit()
                end
            end,
        }
        items[#items + 1] = {
            label = "Copy",
            shortcut = "Ctrl+C",
            disabled = not input_has_sel or is_password,
            action = function()
                if inst and inst:_has_sel() and not is_password then
                    local text = ns.text_content[input_nid] or ""
                    local lo, hi = inst:_sel_range()
                    Clipboard.write(text:sub(lo + 1, hi))
                end
            end,
        }
        items[#items + 1] = {
            label = "Paste",
            shortcut = "Ctrl+V",
            disabled = is_disabled,
            action = function()
                local paste = Clipboard.read()
                if type(paste) == "string" and paste ~= "" and inst then
                    local text = ns.text_content[input_nid] or ""
                    if inst:_has_sel() then
                        text, inst.caret_pos = inst:_delete_sel(text)
                    end
                    text = text:sub(1, inst.caret_pos) .. paste .. text:sub(inst.caret_pos + 1)
                    inst.caret_pos = inst.caret_pos + #paste
                    ns.text_content[input_nid] = text
                    ns:mark_dirty(input_nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
                    _after_edit()
                end
            end,
        }
        items[#items + 1] = { separator = true }
        items[#items + 1] = {
            label = "Select All",
            shortcut = "Ctrl+A",
            action = function()
                if inst then
                    local text = ns.text_content[input_nid] or ""
                    inst.sel_start = 0
                    inst.caret_pos = #text
                    ns:mark_dirty(input_nid, ns.PAINT_DIRTY)
                end
            end,
        }
    elseif text_nid ~= 0 or has_selection then
        -- Text context: Select All for text nodes
        if #items > 0 then
            items[#items + 1] = { separator = true }
        end
        items[#items + 1] = {
            label = "Select All",
            shortcut = "Ctrl+A",
            action = function()
                -- Find the container parent and select all text nodes within it
                local container = text_nid ~= 0 and (ns.parent[text_nid] or 0) or 0
                if container == 0 then return end
                -- Walk up to find a block-level container
                local root = container
                local rp = ns.parent[root]
                if rp and rp ~= 0 then root = rp end
                -- Select all text nodes under root
                local new_nodes = {}
                ns:walk_depth_first(root, function(nid)
                    if ns.node_type[nid] == ns.TEXT then
                        local text = ns.text_content[nid] or ""
                        if text ~= "" then
                            local p = ns.pseudo[nid]
                            if p then
                                p.selected = true
                                p.sel_start = 0
                                p.sel_end = #text
                                new_nodes[nid] = true
                                ns:mark_dirty(nid, ns.PAINT_DIRTY)
                            end
                        end
                    end
                end)
                es._sel_nodes = new_nodes
                es.pseudo_changed = true
            end,
        }
    end

    -- 4. Custom items from onContextMenu attribute (bubble up hover chain)
    local custom_items = nil
    for i = 1, #chain do
        local nid = chain[i]
        local attrs = ns.attrs[nid]
        if attrs and attrs.onContextMenu then
            local handler = es._action_handlers[attrs.onContextMenu]
            if handler then
                local ok, result = pcall(handler, nid, attrs.onContextMenu)
                if ok and type(result) == "table" then
                    custom_items = result
                end
            end
            break
        end
    end

    if custom_items and #custom_items > 0 then
        if #items > 0 then
            items[#items + 1] = { separator = true }
        end
        for i = 1, #custom_items do
            items[#items + 1] = custom_items[i]
        end
    end

    -- Open the menu if we have items
    if #items > 0 then
        local ok_ss, sw, sh = pcall(self.platform.get_screen_size, self.platform)
        if not ok_ss then sw, sh = 1920, 1080 end
        self.context_menu:open(
            self.input.cursor_x, self.input.cursor_y,
            items, sw, sh,
            self.font_manager, self.default_font
        )
    end
end

return Engine



