------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / layout_engine.lua
-- Layout engine dispatcher: resolves computed styles into
-- concrete layout boxes.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Block       = require("core/layout/block")
local Flex        = require("core/layout/flex")
local Grid        = require("core/layout/grid")
local TableLayout = require("core/layout/table")
local MultiColumn = require("core/layout/multicolumn")
local TextWrap    = require("core/layout/text_wrap")
local Utf8        = require("core/util/utf8")

local ValueVM     = require("core/style/value_vm")
local SvgLayout   = require("core/svg/layout")
local SvgConstants = require("core/svg/constants")

local LE = {}
LE.__index = LE

local ScrollEngine  -- lazy-loaded to avoid circular dependency

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new LayoutEngine.
---@param node_store   table  NodeStore instance
---@param platform     table  Platform adapter instance
---@param font_manager table|nil  FontManager instance (optional)
---@return table  LayoutEngine instance
function LE.new(node_store, platform, font_manager)
    local self = setmetatable({}, LE)
    self.ns           = node_store
    self.platform     = platform
    self.font_manager = font_manager
    self._text_cache    = {}  -- cache key -> width
    self._measure_cache = {}  -- { [nid_w_h_key] = {w, h} }

    -- Viewport dimensions (set before each layout pass)
    self.viewport_w     = 0
    self.viewport_h     = 0
    self.root_font_size = 16

    -- Fixed positioning support
    self._viewport      = nil   -- {x, y, w, h} set at start of layout
    self._fixed_nodes   = {}    -- array of nid for post-layout adjustment

    -- Sticky positioning support
    self._sticky_nodes  = {}    -- array of {nid, threshold_top}

    -- Texture cache reference (set by Engine)
    self.texture_cache  = nil

    -- Default font name (set by Engine)
    self._default_font  = nil

    -- Device pixel ratio. Block._resolve_line_h / Inline.layout_run read
    -- `engine._dpr` to feed the per-component rounding inside GlyphCache's
    -- `line-height: normal` resolver. The `engine` argument to these
    -- functions IS the LayoutEngine instance (not AstroEngine), so we have
    -- to mirror the host's DPR here ourselves - Engine:set_dpr below
    -- propagates the value on every change. Default 1 keeps existing
    -- tests that never opt in unchanged.
    self._dpr           = 1

    return self
end

------------------------------------------------------------
-- Entry point
------------------------------------------------------------

--- Layout the tree starting at root_id within the given
--- available rectangle.
---@param root_id number
---@param avail_x number  available x position
---@param avail_y number  available y position
---@param avail_w number  available width
---@param avail_h number  available height
function LE:layout(root_id, avail_x, avail_y, avail_w, avail_h)
    if root_id == 0 then return end
    -- Per-pass safety: if a font finished loading since the last layout
    -- pass, flush every text-measurement cache BEFORE we start. Previously
    -- the layout could run with stale fallback measurements (pending-font
    -- estimate `count * font_size * 0.5`) and TextWrap cached the wrong
    -- wrap, and later passes with correct measurements still hit the
    -- stale TextWrap cache. The engine's :tick() does this on
    -- font_manager:pop_just_ready, but that flag can race with
    -- the first layout pass - by the time tick runs, layout has
    -- already cached the bad wrap. Catching it at layout-start (when
    -- engine binds a font_manager and we can ask just-ready) guarantees
    -- the first font-aware layout pass sees flushed caches.
    -- Per-pass force-flush of text measurement caches. This guards against
    -- the "font async load races layout" trap: when the first layout pass
    -- runs before the requested font cache is ready, measure_text_width()
    -- falls back to `count * font_size * 0.5` for the missing family.
    -- TextWrap.wrap() then caches the (wrong) wrap result keyed only by
    -- text+max_width+font_id; LE:measure() ALSO caches its full layout
    -- (returns w, h) keyed by (nid, avail_w, avail_h, gen). Once the
    -- font finishes loading, the cached values are still served on
    -- subsequent passes - TextWrap.wrap returns the stale 4-line
    -- result, AND engine:measure returns the stale stretched row
    -- height. The grid uses :measure() for row sizing, so the row
    -- gets locked at the wrong height even though the FINAL block
    -- layout pass for the cell now wraps the text to 2 lines.
    --
    -- Engine.lua's per-tick `_invalidate_font_metric_caches` handled
    -- this via `font_manager:pop_just_ready`, but the flag was racy:
    -- the layout pass would consume the flag's window before the
    -- cache invalidation ran for the same pass. Forcing a flush at
    -- layout-start keeps the caches behaviorally consistent with
    -- the font_manager's current ready state. Cost: one re-measurement
    -- per pass for text-heavy nodes; per-glyph cache in GlyphCache
    -- itself is preserved so character advance lookups stay O(1).
    self._text_cache = {}
    self._measure_cache = {}
    TextWrap.flush_cache()
    -- Re-query the platform's scrollbar gutter width per pass. The value is
    -- typically stable for the lifetime of the engine (it's a host UI
    -- constant), but a host can change it dynamically - e.g. the JS host
    -- swapping it after detecting overlay-scrollbar support, or a settings
    -- toggle in-game. Block.layout reads from engine._scrollbar_gutter_w
    -- and falls back to 15 when the platform method is absent.
    self._scrollbar_gutter_w = nil
    -- Periodic cache eviction safety net (every 300 passes ≈ 5s at 60fps)
    self._layout_pass_count = (self._layout_pass_count or 0) + 1
    if self._layout_pass_count >= 300 then
        self._layout_pass_count = 0
        self._measure_cache = {}
        self._text_cache = {}
        TextWrap.flush_cache()
    end
    if self.scroll_engine then self.scroll_engine:reset_extent_cache() end

    -- Set viewport for this layout pass.  Per the CSS spec, vw/vh/vmin/vmax
    -- and media-query viewport dimensions resolve against the *initial
    -- containing block* - for a window-scoped document, that's the window
    -- content box, not the OS screen.  Using the content rect keeps layouts
    -- like `min-height: 60vmin` sized to the host window instead of the
    -- physical display.
    self._viewport = { x = avail_x, y = avail_y, w = avail_w, h = avail_h }
    self._fixed_nodes = {}
    self._sticky_nodes = {}

    self.viewport_w = avail_w
    self.viewport_h = avail_h

    -- Determine root font size (resolve if it's a calc/unit table)
    local root_computed = self.ns.computed[root_id]
    if root_computed and root_computed.font_size then
        local rfs = root_computed.font_size
        if type(rfs) == "number" then
            self.root_font_size = rfs
        elseif type(rfs) == "table" or type(rfs) == "string" then
            local boot = {
                parent_width = avail_w, parent_height = avail_h,
                font_size = 16, viewport_w = self.viewport_w,
                viewport_h = self.viewport_h, root_font_size = 16,
            }
            local resolved = ValueVM.resolve(rfs, boot)
            self.root_font_size = (type(resolved) == "number") and resolved or 16
        end
    end

    self:_layout_node(root_id, avail_x, avail_y, avail_w, avail_h)

    -- Post-layout: resolve fixed positioning
    self:_resolve_fixed()

    -- Post-layout: resolve sticky positioning
    self:_resolve_sticky(root_id)
end

------------------------------------------------------------
-- Text measurement (cached)
------------------------------------------------------------

--- Measure text width with caching.
---@param text        string
---@param font_size   number
---@param font_id     number|nil
---@param font_family string|nil  custom font name
---@param font_weight number|nil  CSS font weight (100-900)
---@param font_style  string|nil  CSS font style
---@return number  pixel width
function LE:measure_text_width(text, font_size, font_id, font_family, font_weight, font_style)
    font_id = font_id or 0

    -- Custom font path (prefer self-drawn TTF, fall back to platform)
    font_family = font_family or self._default_font
    if font_family and self.font_manager then
        local cache = self.font_manager:get_cache_for(font_family, font_weight or 400, font_style)
        if cache then
            local key = text .. "\0" .. tostring(font_size) .. "\0cf:" .. font_family
                .. ":" .. tostring(font_weight or 400) .. ":" .. tostring(font_style or "normal")
            local cached = self._text_cache[key]
            if cached then return cached end
            local w = self:_measure_custom(text, font_size, cache)
            self._text_cache[key] = w
            return w
        end
    end

    -- Engine mounts always carry FontManager; if a requested self-drawn font
    -- is still loading, use a deterministic temporary estimate instead of
    -- platform-native measurement so Studio/Sylvanas do not diverge.
    if self.font_manager and font_family then
        local key = text .. "\0" .. tostring(font_size) .. "\0pending:" .. tostring(font_family)
            .. ":" .. tostring(font_weight or 400) .. ":" .. tostring(font_style or "normal")
        local cached = self._text_cache[key]
        if cached then return cached end
        local count = 0
        for _ in Utf8.codes(text or "") do count = count + 1 end
        local w = count * (font_size or 16) * 0.5
        self._text_cache[key] = w
        return w
    end

    -- Legacy host-font path for standalone platforms without FontManager.
    local key = text .. "\0" .. tostring(font_size) .. "\0" .. tostring(font_id)
    local cached = self._text_cache[key]
    if cached then return cached end

    local w = self.platform:measure_text_width(text, font_size, font_id)
    self._text_cache[key] = w
    return w
end

--- Measure text width using custom font glyph advances.
---@param text      string
---@param font_size number
---@param cache     table  GlyphCache instance
---@return number  total width in pixels
function LE:_measure_custom(text, font_size, cache)
    return cache:measure_text(text, font_size, Utf8)
end

------------------------------------------------------------
-- Intrinsic size measurement (cached)
------------------------------------------------------------

--- Measure the outer size of a node under an inline constraint.
---@param nid     number  node id
---@param avail_w number  available width constraint
---@param avail_h number  available height constraint
---@param opts    table|nil
---  - mode = "intrinsic" (default): shrink-wrap auto-width to content. The
---    display is temporarily promoted (flex→inline-flex, grid→inline-grid)
---    so the inner algorithm produces a tight preferred width.
---  - mode = "available-width": keep `avail_w` as the inline-size and
---    measure the block-size at that constraint. Used by grid auto-row
---    sizing where the column width is already resolved and we need the
---    height at that exact width (not the intrinsic preferred width).
---@return number, number  width, height (outer box)
function LE:measure(nid, avail_w, avail_h, opts)
    local mode = "intrinsic"
    if type(opts) == "table" and opts.mode then mode = opts.mode end
    local intrinsic_width = (mode ~= "available-width")

    local function cache_dim(v)
        v = tonumber(v) or 0
        return math.floor(v * 16 + 0.5) / 16
    end
    local gen = self.ns.style_gen[nid] or 0
    local key = nid .. ":" .. cache_dim(avail_w) .. ":" .. cache_dim(avail_h)
        .. ":" .. gen .. ":" .. mode
    local cached = self._measure_cache[key]
    if cached then return cached[1], cached[2] end

    -- Run layout at placeholder coordinates with measuring flag
    local computed = self.ns.computed[nid]
    local display = computed and (computed.display or "block") or "block"
    local restore_display = nil
    if computed and intrinsic_width then
        local auto_width = (computed.width == nil or computed.width == "auto")
        if auto_width and display == "flex" then
            restore_display = display
            computed.display = "inline-flex"
            display = "inline-flex"
        elseif auto_width and display == "grid" then
            restore_display = display
            computed.display = "inline-grid"
            display = "inline-grid"
        end
    end

    if display == "flex" or display == "inline-flex" then
        Flex.layout(self, nid, 0, 0, avail_w, avail_h)
    elseif display == "grid" or display == "inline-grid" then
        Grid.layout(self, nid, 0, 0, avail_w, avail_h)
    elseif display == "table" or display == "inline-table" then
        TableLayout.layout(self, nid, 0, 0, avail_w, avail_h)
    else
        Block.layout(self, nid, 0, 0, avail_w, avail_h, opts or true)
    end

    local lay = self.ns.layout[nid]
    local w, h = lay.w, lay.h
    if restore_display then
        computed.display = restore_display
    end

    self._measure_cache[key] = { w, h }
    return w, h
end

------------------------------------------------------------
-- Node dispatch
------------------------------------------------------------

--- Layout a single node, dispatching to the appropriate
--- layout algorithm based on computed.display.
---@param nid     number
---@param avail_x number
---@param avail_y number
---@param avail_w number
---@param avail_h number
function LE:_layout_node(nid, avail_x, avail_y, avail_w, avail_h)
    local ns = self.ns
    local computed = ns.computed[nid]
    if not computed then return end

    local display = computed.display or "block"

    if display == "none" then
        -- Hidden: zero-size layout box
        local lay = ns.layout[nid]
        lay.x = avail_x
        lay.y = avail_y
        lay.w = 0
        lay.h = 0
        lay.content_x = avail_x
        lay.content_y = avail_y
        lay.content_w = 0
        lay.content_h = 0
        return
    end

    -- SVG child nodes (path, circle, rect, g, etc.) are laid out
    -- by SvgLayout, not by the normal flow layout engine.
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)
    if SvgConstants.is_svg_child(tag_str) then
        -- Zero-size placeholder; actual layout done by SvgLayout
        local lay = ns.layout[nid]
        lay.x = avail_x
        lay.y = avail_y
        lay.w = 0
        lay.h = 0
        lay.content_x = avail_x
        lay.content_y = avail_y
        lay.content_w = 0
        lay.content_h = 0
        return
    end

    -- Check for multi-column on block-level elements
    local is_multicol = computed.column_count or computed.column_width

    -- Flex/grid: if any child is layout-dirty, invalidate all siblings'
    -- measure cache (flex/grid sizing depends on sibling sizes)
    if display == "grid" or display == "inline-grid"
       or display == "flex" or display == "inline-flex" then
        local any_child_dirty = false
        local cid = ns.first_child[nid]
        while cid and cid ~= 0 do
            if ns:is_dirty(cid, ns.LAYOUT_DIRTY) then
                any_child_dirty = true
                break
            end
            cid = ns.next_sibling[cid] or 0
        end
        if any_child_dirty then
            cid = ns.first_child[nid]
            while cid and cid ~= 0 do
                ns.style_gen[cid] = (ns.style_gen[cid] or 0) + 1
                cid = ns.next_sibling[cid] or 0
            end
        end
    end

    if display == "grid" or display == "inline-grid" then
        Grid.layout(self, nid, avail_x, avail_y, avail_w, avail_h)
    elseif display == "flex" or display == "inline-flex" then
        Flex.layout(self, nid, avail_x, avail_y, avail_w, avail_h)
    elseif display == "table" or display == "inline-table" then
        TableLayout.layout(self, nid, avail_x, avail_y, avail_w, avail_h)
    elseif display == "table-row" or display == "table-cell"
        or display == "table-row-group" or display == "table-header-group"
        or display == "table-footer-group" or display == "table-caption" then
        Block.layout(self, nid, avail_x, avail_y, avail_w, avail_h)
    elseif is_multicol then
        MultiColumn.layout(self, nid, avail_x, avail_y, avail_w, avail_h)
    else
        Block.layout(self, nid, avail_x, avail_y, avail_w, avail_h)
    end

    -- After CSS box layout, run SVG-specific child layout for <svg> roots
    if tag_str == "svg" then
        SvgLayout.layout_svg_root(self, nid, self._live_resize)
    end

    -- Save layout dimensions for future stoppage comparison
    local lay = ns.layout[nid]
    ns.prev_layout_w[nid] = lay.w
    ns.prev_layout_h[nid] = lay.h

    -- Invalidate parent's extent cache if parent is a scroll container.
    -- Call the *instance* method so we hit this mount's cache rather than
    -- a stale module-level shared one.
    local pid = ns.parent[nid]
    if pid and pid ~= 0 and ns.scroll[pid] and self.scroll_engine then
        self.scroll_engine:invalidate_extent(pid)
    end
end

------------------------------------------------------------
-- Post-layout: fixed positioning
------------------------------------------------------------

--- Adjust fixed-position nodes to be relative to viewport.
function LE:_resolve_fixed()
    local ns = self.ns
    local vp = self._viewport
    if not vp then return end

    for i = 1, #self._fixed_nodes do
        local nid = self._fixed_nodes[i]
        local computed = ns.computed[nid]
        local lay = ns.layout[nid]
        if computed and lay then
            local fs = computed.font_size
            if fs == nil then fs = 14
            elseif type(fs) ~= "number" then
                local boot = { parent_width = vp.w, parent_height = vp.h,
                    font_size = 16, viewport_w = self.viewport_w,
                    viewport_h = self.viewport_h, root_font_size = self.root_font_size }
                local r = ValueVM.resolve(fs, boot)
                fs = (type(r) == "number") and r or 16
            end
            local context = {
                parent_width = vp.w,
                parent_height = vp.h,
                font_size = fs,
                viewport_w = self.viewport_w,
                viewport_h = self.viewport_h,
                root_font_size = self.root_font_size,
            }

            local left_val = ValueVM.resolve(computed.left, context)
            local top_val  = ValueVM.resolve(computed.top, context)
            local right_val = ValueVM.resolve(computed.right, context)
            local bottom_val = ValueVM.resolve(computed.bottom, context)

            local old_x, old_y = lay.x, lay.y
            local old_w, old_h = lay.w, lay.h

            -- Resolve the containing block.  By default fixed elements are
            -- positioned against the viewport, but per CSS spec a transformed
            -- (or filter / will-change: transform / perspective) ancestor
            -- becomes the CB instead.
            local cb_x, cb_y, cb_w, cb_h = vp.x, vp.y, vp.w, vp.h
            local p = ns.parent[nid]
            while p and p ~= 0 do
                local pc = ns.computed[p]
                if pc then
                    local creates_cb = false
                    if pc.transform and pc.transform ~= "none" then creates_cb = true end
                    if not creates_cb and pc.filter and pc.filter ~= "none" then creates_cb = true end
                    if not creates_cb and pc.backdrop_filter and pc.backdrop_filter ~= "none" then creates_cb = true end
                    if not creates_cb and pc.will_change then
                        local wc = tostring(pc.will_change)
                        if wc:find("transform", 1, true) or wc:find("filter", 1, true) or wc:find("perspective", 1, true) then
                            creates_cb = true
                        end
                    end
                    if creates_cb then
                        local pl = ns.layout[p]
                        if pl then cb_x, cb_y, cb_w, cb_h = pl.x, pl.y, pl.w, pl.h end
                        break
                    end
                end
                p = ns.parent[p]
            end

            -- Recompute size from opposing offsets when both are numeric and
            -- the element's own size was auto.  CSS spec: top:0; bottom:0
            -- stretches an auto-height fixed box to the containing block.
            local has_explicit_w = type(computed.width) == "number"
            if not has_explicit_w and computed.width ~= nil and computed.width ~= "auto" then
                local r = ValueVM.resolve(computed.width, context)
                if type(r) == "number" then has_explicit_w = true end
            end
            local has_explicit_h = type(computed.height) == "number"
            if not has_explicit_h and computed.height ~= nil and computed.height ~= "auto" then
                local r = ValueVM.resolve(computed.height, context)
                if type(r) == "number" then has_explicit_h = true end
            end

            if not has_explicit_w and type(left_val) == "number" and type(right_val) == "number" then
                local stretched = cb_w - left_val - right_val
                if stretched > 0 then lay.w = stretched end
            end
            if not has_explicit_h and type(top_val) == "number" and type(bottom_val) == "number" then
                local stretched = cb_h - top_val - bottom_val
                if stretched > 0 then lay.h = stretched end
            end

            -- Position relative to the containing block
            if type(left_val) == "number" then
                lay.x = cb_x + left_val
            elseif type(right_val) == "number" then
                lay.x = cb_x + cb_w - lay.w - right_val
            end

            if type(top_val) == "number" then
                lay.y = cb_y + top_val
            elseif type(bottom_val) == "number" then
                lay.y = cb_y + cb_h - lay.h - bottom_val
            end

            local dx = lay.x - old_x
            local dy = lay.y - old_y
            local dw = lay.w - old_w
            local dh = lay.h - old_h

            -- Update content position (per-side border support)
            local bw_uniform = computed.border_width or 0
            local bl = computed.border_left_width or bw_uniform
            local bt = computed.border_top_width or bw_uniform
            local br = computed.border_right_width or bw_uniform
            local bb = computed.border_bottom_width or bw_uniform
            -- CSS spec: border-style "none"/"hidden" → computed border-width = 0
            local bs_u = computed.border_style or "solid"
            local bs_l = computed.border_left_style or bs_u
            local bs_t = computed.border_top_style or bs_u
            local bs_r = computed.border_right_style or bs_u
            local bs_b = computed.border_bottom_style or bs_u
            if bs_l == "none" or bs_l == "hidden" then bl = 0 end
            if bs_t == "none" or bs_t == "hidden" then bt = 0 end
            if bs_r == "none" or bs_r == "hidden" then br = 0 end
            if bs_b == "none" or bs_b == "hidden" then bb = 0 end
            local padding_l = computed.padding_left or 0
            local padding_t = computed.padding_top or 0
            local padding_r = computed.padding_right or 0
            local padding_b = computed.padding_bottom or 0
            lay.content_x = lay.x + bl + padding_l
            lay.content_y = lay.y + bt + padding_t
            -- Resize the inner boxes when the outer dimensions changed (e.g.
            -- because top:0; bottom:0 stretched the box to the CB).
            if dw ~= 0 or dh ~= 0 then
                local new_content_w = lay.w - bl - br - padding_l - padding_r
                local new_content_h = lay.h - bt - bb - padding_t - padding_b
                if new_content_w < 0 then new_content_w = 0 end
                if new_content_h < 0 then new_content_h = 0 end
                lay.content_w = new_content_w
                lay.content_h = new_content_h
                if lay.pad_x then lay.pad_x = lay.x + bl end
                if lay.pad_y then lay.pad_y = lay.y + bt end
                if lay.pad_w then
                    local pw = lay.w - bl - br
                    lay.pad_w = pw < 0 and 0 or pw
                end
                if lay.pad_h then
                    local ph = lay.h - bt - bb
                    lay.pad_h = ph < 0 and 0 or ph
                end
            end

            -- Shift all descendants by the same delta so content follows the box.
            if dx ~= 0 or dy ~= 0 then
                ns:walk_depth_first(nid, function(child)
                    if child == nid then return end
                    local cl = ns.layout[child]
                    if cl then
                        cl.x = cl.x + dx
                        cl.y = cl.y + dy
                        cl.content_x = cl.content_x + dx
                        cl.content_y = cl.content_y + dy
                        if cl.pad_x then cl.pad_x = cl.pad_x + dx end
                        if cl.pad_y then cl.pad_y = cl.pad_y + dy end
                    end
                end)
            end
        end
    end
end

------------------------------------------------------------
-- Post-layout: sticky positioning
------------------------------------------------------------

--- Resolve sticky positioning after layout.
---@param root_id number
function LE:_resolve_sticky(root_id)
    local ns = self.ns
    if root_id == 0 then return end

    for i = 1, #self._sticky_nodes do
        local entry = self._sticky_nodes[i]
        local nid = entry.nid
        local sticky_top = entry.top

        local lay = ns.layout[nid]
        local parent_id = ns.parent[nid]
        if lay and parent_id and parent_id ~= 0 then
            local parent_lay = ns.layout[parent_id]
            if parent_lay then
                local scroll = ns.scroll[parent_id]
                local scroll_y = (scroll and scroll.y) or 0

                -- The element's normal flow position
                local normal_y = lay.y

                -- Container top edge (viewport-relative)
                local container_top = parent_lay.content_y

                -- If scrolled past threshold, pin it
                if scroll_y > 0 then
                    local threshold = container_top + sticky_top
                    if normal_y < threshold then
                        -- Pin at threshold
                        local pinned_y = threshold
                        -- Clamp: don't scroll past parent's bottom
                        local parent_bottom = parent_lay.content_y + parent_lay.content_h - lay.h
                        if pinned_y > parent_bottom then
                            pinned_y = parent_bottom
                        end
                        lay.y = math.floor(pinned_y)
                        -- Update content_y
                        local computed = ns.computed[nid]
                        local bw_u = computed and computed.border_width or 0
                        local bt_w = computed and computed.border_top_width or bw_u
                        local padding_t = computed and computed.padding_top or 0
                        lay.content_y = lay.y + bt_w + padding_t
                    end
                end
            end
        end
    end
end

return LE



