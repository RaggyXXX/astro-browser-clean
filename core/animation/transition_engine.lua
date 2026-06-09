------------------------------------------------------------
-- ext_core_astro_ui_lib / core / animation / transition_engine.lua
-- CSS Transition and Animation state machine.
--
-- Transitions: detect property changes → interpolate over duration
-- Animations: keyframe timeline with iteration, direction, easing
-- Easing: cubic-bezier solver (Newton-Raphson, 8 iterations)
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local TransitionEngine = {}
TransitionEngine.__index = TransitionEngine

------------------------------------------------------------
-- Easing functions
------------------------------------------------------------

--- Cubic bezier solver using Newton-Raphson method.
---@param p1x number  control point 1 x
---@param p1y number  control point 1 y
---@param p2x number  control point 2 x
---@param p2y number  control point 2 y
---@param t   number  progress 0..1
---@return number  eased value 0..1
local function cubic_bezier(p1x, p1y, p2x, p2y, t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end

    -- Newton-Raphson to find parameter for x(parameter) = t
    local ax = 3 * p1x - 3 * p2x + 1
    local bx = 3 * p2x - 6 * p1x
    local cx = 3 * p1x

    local ay = 3 * p1y - 3 * p2y + 1
    local by = 3 * p2y - 6 * p1y
    local cy = 3 * p1y

    -- Initial guess
    local x = t
    for _ = 1, 8 do
        local x_val = ((ax * x + bx) * x + cx) * x
        local dx = (3 * ax * x + 2 * bx) * x + cx
        if math.abs(dx) < 1e-7 then break end
        x = x - (x_val - t) / dx
    end

    -- Clamp
    if x < 0 then x = 0 end
    if x > 1 then x = 1 end

    -- Return y value at this parameter
    return ((ay * x + by) * x + cy) * x
end

--- Build a steps() timing function.
---@param n    number  number of steps (must be >= 1)
---@param pos  string  jump position: "start","end","jump-start","jump-end","jump-both","jump-none"
---@return function
local function make_steps(n, pos)
    if n < 1 then n = 1 end
    if pos == "start" or pos == "jump-start" then
        return function(t)
            if t <= 0 then return 1 / n end
            return math.min(math.ceil(t * n) / n, 1)
        end
    elseif pos == "jump-both" then
        -- N+1 output values: jumps at both start and end
        local steps = n + 1
        return function(t)
            return math.min(math.floor(t * n + 1) / steps, 1)
        end
    elseif pos == "jump-none" then
        -- N-1 intervals: no jump at start or end
        if n <= 1 then
            -- jump-none with 1 step is degenerate, treat as linear
            return function(t) return t end
        end
        return function(t)
            return math.min(math.floor(t * n) / (n - 1), 1)
        end
    else
        -- "end" or "jump-end" (default)
        return function(t)
            return math.floor(t * n) / n
        end
    end
end

--- Built-in easing presets.
local EASINGS = {
    linear       = function(t) return t end,
    ease         = function(t) return cubic_bezier(0.25, 0.1, 0.25, 1.0, t) end,
    ["ease-in"]  = function(t) return cubic_bezier(0.42, 0,   1.0,  1.0, t) end,
    ["ease-out"] = function(t) return cubic_bezier(0,    0,   0.58, 1.0, t) end,
    ["ease-in-out"] = function(t) return cubic_bezier(0.42, 0, 0.58, 1.0, t) end,
    ["step-start"] = make_steps(1, "start"),
    ["step-end"]   = make_steps(1, "end"),
}

--- Parse a steps() or cubic-bezier() function string.
---@param name string  e.g. "steps(4, end)" or "cubic-bezier(0.42, 0, 1, 1)"
---@return function|nil  easing function or nil if not parseable
local function parse_easing_function(name)
    -- Try steps(n, position)
    local steps_match = name:match("^%s*steps%s*%((.+)%)%s*$")
    if steps_match then
        local n_str, pos = steps_match:match("^%s*(%d+)%s*,%s*([%w%-]+)%s*$")
        if not n_str then
            -- steps(n) with no position => default is "end"
            n_str = steps_match:match("^%s*(%d+)%s*$")
            pos = "end"
        end
        if n_str then
            return make_steps(tonumber(n_str), pos)
        end
    end

    -- Try cubic-bezier(p1x, p1y, p2x, p2y)
    local cb_match = name:match("^%s*cubic%-bezier%s*%((.+)%)%s*$")
    if cb_match then
        local p1x, p1y, p2x, p2y = cb_match:match(
            "^%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*$"
        )
        if p1x then
            local x1, y1, x2, y2 = tonumber(p1x), tonumber(p1y), tonumber(p2x), tonumber(p2y)
            return function(t) return cubic_bezier(x1, y1, x2, y2, t) end
        end
    end

    return nil
end

--- Get easing function from name or default to ease.
---@param name string|nil
---@return function
local function get_easing(name)
    if not name then return EASINGS["ease"] end
    local preset = EASINGS[name]
    if preset then return preset end
    -- Try parsing as a function like steps() or cubic-bezier()
    local parsed = parse_easing_function(name)
    if parsed then return parsed end
    return EASINGS["ease"]
end

------------------------------------------------------------
-- Interpolation helpers
------------------------------------------------------------

--- Allowed list of animatable properties.
local ANIMATABLE = {
    width = true, height = true,
    padding_top = true, padding_right = true, padding_bottom = true, padding_left = true,
    margin_top = true, margin_right = true, margin_bottom = true, margin_left = true,
    border_width = true, border_radius = true,
    font_size = true, opacity = true,
    left = true, top = true, right = true, bottom = true,
    min_width = true, min_height = true, max_width = true, max_height = true,
    gap = true, row_gap = true, column_gap = true,
    letter_spacing = true, word_spacing = true, text_indent = true,
    -- Colors
    color = true, background_color = true, border_color = true,
    -- Transform
    transform = true,
}

--- Properties that only affect paint (no layout recalc needed).
local PAINT_ONLY = {
    color = true, background_color = true, border_color = true,
    opacity = true, box_shadow = true, text_shadow = true,
    outline_color = true, outline_width = true, outline_offset = true,
    transform = true, filter = true, backdrop_filter = true,
    border_radius = true,
}

--- Properties that are inherited and affect layout.
local INHERITED_LAYOUT = {
    font_size = true, line_height = true,
    letter_spacing = true, word_spacing = true,
}

--- Inherited properties that are paint-only (need cascade to children).
local INHERITED_PAINT = {
    color = true, caret_color = true, accent_color = true,
    visibility = true,
}

--- Properties that invalidate cached text metric keys on computed.
local TEXT_METRIC_PROPS = {
    font_size = true, line_height = true,
    letter_spacing = true, word_spacing = true,
    font_weight = true, font_family = true,
}

--- Interpolate between two values.
---@param from any
---@param to   any
---@param t    number  0..1
---@return any  interpolated value
local function interpolate(prop, from, to, t)
    -- Number lerp
    if type(from) == "number" and type(to) == "number" then
        return from + (to - from) * t
    end

    -- Color lerp (tables with 3-4 numeric entries)
    if type(from) == "table" and type(to) == "table"
       and #from >= 3 and #to >= 3 then
        return {
            math.floor((from[1] or 0) + ((to[1] or 0) - (from[1] or 0)) * t),
            math.floor((from[2] or 0) + ((to[2] or 0) - (from[2] or 0)) * t),
            math.floor((from[3] or 0) + ((to[3] or 0) - (from[3] or 0)) * t),
            math.floor((from[4] or 255) + ((to[4] or 255) - (from[4] or 255)) * t),
        }
    end

    -- Transform lerp (array of operations)
    if prop == "transform" and type(from) == "table" and type(to) == "table" then
        local result = {}
        local max_len = math.max(#from, #to)
        for i = 1, max_len do
            local f = from[i]
            local tt = to[i]
            if f and tt and f.type == tt.type then
                if f.type == "translate" then
                    result[i] = {
                        type = "translate",
                        x = (f.x or 0) + ((tt.x or 0) - (f.x or 0)) * t,
                        y = (f.y or 0) + ((tt.y or 0) - (f.y or 0)) * t,
                    }
                elseif f.type == "scale" then
                    result[i] = {
                        type = "scale",
                        x = (f.x or 1) + ((tt.x or 1) - (f.x or 1)) * t,
                        y = (f.y or 1) + ((tt.y or 1) - (f.y or 1)) * t,
                    }
                elseif f.type == "rotate" then
                    local fd = f.deg or f.v or 0
                    local td = tt.deg or tt.v or 0
                    result[i] = {
                        type = "rotate",
                        deg = fd + (td - fd) * t,
                    }
                elseif f.type == "skew" then
                    local fx = f.x or f.v or 0
                    local tx = tt.x or tt.v or 0
                    local fy = f.y or 0
                    local ty = tt.y or 0
                    result[i] = {
                        type = "skew",
                        x = fx + (tx - fx) * t,
                        y = fy + (ty - fy) * t,
                    }
                elseif f.type == "skewX" or f.type == "skewY" then
                    local fd = f.deg or f.x or f.v or 0
                    local td = tt.deg or tt.x or tt.v or 0
                    result[i] = {
                        type = f.type,
                        deg = fd + (td - fd) * t,
                    }
                else
                    result[i] = t < 0.5 and f or tt
                end
            else
                result[i] = t < 0.5 and (f or tt) or (tt or f)
            end
        end
        return result
    end

    -- Non-interpolatable: snap at halfway
    if t < 0.5 then return from end
    return to
end

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new TransitionEngine for a mount.
---@return table  TransitionEngine instance
function TransitionEngine.new()
    local self = setmetatable({}, TransitionEngine)
    self._transitions = {}  -- nid -> { prop -> {from, to, start_time, duration, delay, easing} }
    self._animations  = {}  -- nid -> { name, keyframes, start_time, duration, delay, iterations, direction, easing, fill_mode }
    self._prev_styles = {}  -- nid -> { prop -> value } snapshot
    self._active      = false  -- true when any transition/animation is running
    self._keyframes   = {}  -- name -> { {pct, decls}, ... }
    self._active_nodes = {}  -- set: nid -> true for nodes with active/potential transitions
    self._active_nodes_count = 0
    return self
end

------------------------------------------------------------
-- Keyframe registration
------------------------------------------------------------

--- Register a keyframes definition.
---@param name      string   animation name
---@param keyframes table    { {0, {prop=value,...}}, {100, {prop=value,...}} }
function TransitionEngine:register_keyframes(name, keyframes)
    self._keyframes[name] = keyframes
end

------------------------------------------------------------
-- Transition detection
------------------------------------------------------------

--- Clean up references for removed nodes.
--- Uses the _removed_nids buffer from NodeStore so cleanup is order-independent
--- (safe even if the node id has already been recycled by a new create_node call).
---@param ns table NodeStore
function TransitionEngine:cleanup_removed(ns)
    local removed = ns._removed_nids
    for i = 1, #removed do
        local nid = removed[i]
        self._prev_styles[nid] = nil
        self._transitions[nid] = nil
        self._animations[nid] = nil
        if self._active_nodes[nid] then
            self._active_nodes[nid] = nil
            self._active_nodes_count = self._active_nodes_count - 1
        end
    end
    -- Drain buffer
    for i = 1, #removed do removed[i] = nil end
end

--- Snapshot current computed styles for transition detection.
---@param ns      table  NodeStore
---@param root_id number
function TransitionEngine:snapshot(ns, root_id)
    if root_id == 0 then return end

    -- Only snapshot nodes with active/potential transitions (not full tree)
    for nid in pairs(self._active_nodes) do
        local computed = ns.computed[nid]
        if not computed then
            -- Node was removed
            self._active_nodes[nid] = nil
            self._active_nodes_count = self._active_nodes_count - 1
        else
            local snap = self._prev_styles[nid]
            if not snap then snap = {}; self._prev_styles[nid] = snap end

            local tp = computed.transition_property
            if tp == "all" then
                for prop in pairs(ANIMATABLE) do
                    local val = computed[prop]
                    if val ~= nil then
                        if type(val) == "table" then
                            local copy = snap[prop]
                            if not copy then copy = {}; snap[prop] = copy end
                            for k in pairs(copy) do copy[k] = nil end
                            for k, v in pairs(val) do copy[k] = v end
                        else
                            snap[prop] = val
                        end
                    end
                end
            elseif tp and ANIMATABLE[tp] then
                local val = computed[tp]
                if val ~= nil then
                    if type(val) == "table" then
                        local copy = snap[tp]
                        if not copy then copy = {}; snap[tp] = copy end
                        for k in pairs(copy) do copy[k] = nil end
                        for k, v in pairs(val) do copy[k] = v end
                    else
                        snap[tp] = val
                    end
                end
            end
        end
    end
end

--- Detect property changes and create transitions.
---@param ns      table   NodeStore
---@param root_id number
---@param time    number  current time in seconds
function TransitionEngine:detect_changes(ns, root_id, time)
    if root_id == 0 then return end

    ns:walk_depth_first(root_id, function(nid)
        local computed = ns.computed[nid]
        if not computed then return end

        -- Register any node with transition/animation properties into active set
        -- so snapshot() will cover them next frame (needed for detect_changes to work)
        if computed.transition_property or computed.animation_name then
            if not self._active_nodes[nid] then
                self._active_nodes[nid] = true
                self._active_nodes_count = self._active_nodes_count + 1
            end
        end

        -- Handle @keyframes animations (independent of transitions and prev snapshot)
        local anim_name = computed.animation_name
        if not anim_name or not self._keyframes[anim_name] then
            -- Animation removed or name cleared: stop any running animation
            if self._animations[nid] then
                self._animations[nid] = nil
            end
        else
            -- Check if animation is already running with identical parameters.
            -- Re-create on any timing change so new values take effect without
            -- requiring the animation-name to change.
            local new_duration   = computed.animation_duration or 0
            local new_delay      = computed.animation_delay or 0
            local new_iterations = computed.animation_iteration_count or 1
            local new_direction  = computed.animation_direction or "normal"
            local new_easing     = computed.animation_timing_function or "ease"
            local new_fill_mode  = computed.animation_fill_mode or "none"

            local existing = self._animations[nid]
            local needs_new = not existing
                or existing.name ~= anim_name
                or existing.duration ~= new_duration
                or existing.delay ~= new_delay
                or existing.iterations ~= new_iterations
                or existing.direction ~= new_direction
                or existing.easing ~= new_easing
                or existing.fill_mode ~= new_fill_mode
            if needs_new then
                self._animations[nid] = {
                    name = anim_name,
                    keyframes = self._keyframes[anim_name],
                    start_time = time,
                    duration = new_duration,
                    delay = new_delay,
                    iterations = new_iterations,
                    direction = new_direction,
                    easing = new_easing,
                    fill_mode = new_fill_mode,
                }
                self._active = true
                -- Register in active set for scoped snapshot()
                if not self._active_nodes[nid] then
                    self._active_nodes[nid] = true
                    self._active_nodes_count = self._active_nodes_count + 1
                end
            end
        end

        -- Handle CSS transitions (requires prev snapshot)
        local prev = self._prev_styles[nid]
        if not prev then return end

        local trans_prop = computed.transition_property
        if not trans_prop then return end

        local duration = computed.transition_duration or 0
        if duration <= 0 then return end

        local delay = computed.transition_delay or 0
        local easing_name = computed.transition_timing_function or "ease"

        -- Check which properties changed
        local check_props = {}
        if trans_prop == "all" then
            for prop, _ in pairs(ANIMATABLE) do
                check_props[prop] = true
            end
        elseif ANIMATABLE[trans_prop] then
            check_props[trans_prop] = true
        end

        for prop, _ in pairs(check_props) do
            local old_val = prev[prop]
            local new_val = computed[prop]

            if old_val ~= nil and new_val ~= nil then
                local changed = false
                if type(old_val) == "number" and type(new_val) == "number" then
                    changed = math.abs(old_val - new_val) > 0.01
                elseif type(old_val) == "table" and type(new_val) == "table" then
                    for k, v in pairs(old_val) do
                        if new_val[k] ~= v then changed = true; break end
                    end
                elseif old_val ~= new_val then
                    changed = true
                end

                if changed then
                    -- Create or update transition
                    if not self._transitions[nid] then
                        self._transitions[nid] = {}
                    end

                    -- If there's an existing transition for this prop, use its current
                    -- interpolated value as the new "from"
                    local existing = self._transitions[nid][prop]
                    local from_val = old_val
                    if existing and existing._current then
                        from_val = existing._current
                    end

                    self._transitions[nid][prop] = {
                        from = from_val,
                        to = new_val,
                        start_time = time,
                        duration = duration,
                        delay = delay,
                        easing = easing_name,
                    }
                    self._active = true
                    -- Register in active set for scoped snapshot()
                    if not self._active_nodes[nid] then
                        self._active_nodes[nid] = true
                        self._active_nodes_count = self._active_nodes_count + 1
                    end
                end
            end
        end
    end)
end

------------------------------------------------------------
-- Tick: apply transition/animation overrides
------------------------------------------------------------

--- Invalidate cached text metric keys when an animated property changes text measurement.
---@param computed table
---@param prop     string
local function invalidate_text_cache(computed, prop)
    if TEXT_METRIC_PROPS[prop] then
        computed._wrap_font_key = nil
        computed._measurer = nil
        computed._paint_measurer = nil
    end
end

--- Classify a property change into dirty flags and merge into the dirty_nodes table.
--- STYLE_DIRTY=1, LAYOUT_DIRTY=2, PAINT_DIRTY=4
---@param dirty_nodes table  { [nid] = flags_bitmask }
---@param nid         number node id
---@param prop        string property name
local function flag_prop(dirty_nodes, nid, prop)
    local f = dirty_nodes[nid] or 0
    if INHERITED_LAYOUT[prop] then
        -- Inherited layout: all flags (7) -" triggers cascade to children
        f = 7
    elseif INHERITED_PAINT[prop] then
        -- Inherited paint: STYLE_DIRTY(1) + PAINT_DIRTY(4) -" cascade without layout
        if f % 2 == 0 then f = f + 1 end
        if math.floor(f / 4) % 2 == 0 then f = f + 4 end
    elseif PAINT_ONLY[prop] then
        -- Paint only: set PAINT_DIRTY(4)
        if math.floor(f / 4) % 2 == 0 then f = f + 4 end
    else
        -- Layout-affecting: LAYOUT_DIRTY(2) + PAINT_DIRTY(4)
        if math.floor(f / 2) % 2 == 0 then f = f + 2 end
        if math.floor(f / 4) % 2 == 0 then f = f + 4 end
    end
    dirty_nodes[nid] = f
end

--- Tick all active transitions and animations, applying overrides to computed styles.
---@param ns   table   NodeStore
---@param time number  current time in seconds
---@return boolean  true if any transition/animation is still active
function TransitionEngine:tick(ns, time)
    -- Catch removals that happened after cleanup_removed (e.g. pseudo-node
    -- recycling during style resolve).  Safe to call twice per frame -" the
    -- second call sees an empty buffer.
    self:cleanup_removed(ns)

    local any_active = false
    local dirty_nodes = {}  -- { [nid] = flags_bitmask }

    -- Process transitions
    for nid, props in pairs(self._transitions) do
        local computed = ns.computed[nid]
        if not computed then
            self._transitions[nid] = nil
        else
            local any_prop_active = false
            for prop, trans in pairs(props) do
                local elapsed = time - trans.start_time - trans.delay
                if elapsed < 0 then
                    -- Still in delay: use "from" value
                    computed[prop] = trans.from
                    invalidate_text_cache(computed, prop)
                    flag_prop(dirty_nodes, nid, prop)
                    trans._current = trans.from
                    any_prop_active = true
                    any_active = true
                elseif elapsed >= trans.duration then
                    -- Transition complete: use "to" value
                    computed[prop] = trans.to
                    invalidate_text_cache(computed, prop)
                    flag_prop(dirty_nodes, nid, prop)
                    trans._current = nil
                    props[prop] = nil  -- remove completed transition
                else
                    -- In progress: interpolate
                    local raw_t = elapsed / trans.duration
                    local easing_fn = get_easing(trans.easing)
                    local t = easing_fn(raw_t)
                    local val = interpolate(prop, trans.from, trans.to, t)
                    computed[prop] = val
                    invalidate_text_cache(computed, prop)
                    flag_prop(dirty_nodes, nid, prop)
                    trans._current = val
                    any_prop_active = true
                    any_active = true
                end
            end

            if not any_prop_active then
                self._transitions[nid] = nil
            end
        end
    end

    -- Process animations
    for nid, anim in pairs(self._animations) do
        local computed = ns.computed[nid]
        if not computed then
            self._animations[nid] = nil
        else
            -- Handle animation-play-state: paused
            local play_state = computed.animation_play_state or "running"
            if play_state == "paused" then
                if not anim._paused then
                    -- Just became paused: record the elapsed time at pause
                    anim._paused = true
                    anim._paused_elapsed = time - anim.start_time
                end
                -- Keep animation active but don't advance; use frozen time
                any_active = true
                -- Still need to render at the paused position, so use the
                -- frozen elapsed value by temporarily adjusting start_time
                -- for the rest of this tick iteration.
            else
                if anim._paused then
                    -- Just resumed: adjust start_time so elapsed continues
                    -- from where it was paused
                    anim.start_time = time - anim._paused_elapsed
                    anim._paused = nil
                    anim._paused_elapsed = nil
                end
            end

            -- Compute effective elapsed time
            local effective_time = time
            if anim._paused then
                effective_time = anim.start_time + anim._paused_elapsed
            end
            local elapsed = effective_time - anim.start_time - anim.delay

            if elapsed < 0 then
                -- In delay period
                if anim.fill_mode == "backwards" or anim.fill_mode == "both" then
                    -- Apply first keyframe
                    local kf = anim.keyframes[1]
                    if kf then
                        for prop, val in pairs(kf[2]) do
                            computed[prop] = val
                            invalidate_text_cache(computed, prop)
                            flag_prop(dirty_nodes, nid, prop)
                        end
                    end
                end
                any_active = true
            else
                local total_duration = anim.duration
                if total_duration <= 0 then
                    self._animations[nid] = nil
                else
                    local iteration = math.floor(elapsed / total_duration)
                    local max_iter = anim.iterations

                    if max_iter ~= "infinite" and max_iter >= 0 and iteration >= max_iter then
                        -- Animation complete
                        if anim.fill_mode == "forwards" or anim.fill_mode == "both" then
                            local kf = anim.keyframes[#anim.keyframes]
                            if kf then
                                for prop, val in pairs(kf[2]) do
                                    computed[prop] = val
                                    invalidate_text_cache(computed, prop)
                                    flag_prop(dirty_nodes, nid, prop)
                                end
                            end
                        end
                        self._animations[nid] = nil
                    else
                        -- In progress
                        local raw_t = (elapsed % total_duration) / total_duration

                        -- Handle direction
                        local dir = anim.direction
                        if dir == "reverse" then
                            raw_t = 1 - raw_t
                        elseif dir == "alternate" then
                            if iteration % 2 == 1 then raw_t = 1 - raw_t end
                        elseif dir == "alternate-reverse" then
                            if iteration % 2 == 0 then raw_t = 1 - raw_t end
                        end

                        -- Convert raw_t (linear 0..1) to percentage for keyframe selection
                        local pct = raw_t * 100

                        -- Find surrounding keyframes using LINEAR time (not eased)
                        local keyframes = anim.keyframes
                        local kf_from, kf_to
                        for ki = 1, #keyframes - 1 do
                            if pct >= keyframes[ki][1] and pct <= keyframes[ki + 1][1] then
                                kf_from = keyframes[ki]
                                kf_to = keyframes[ki + 1]
                                break
                            end
                        end

                        if kf_from and kf_to then
                            local kf_range = kf_to[1] - kf_from[1]
                            local kf_t = 0
                            if kf_range > 0 then
                                kf_t = (pct - kf_from[1]) / kf_range
                            end
                            -- Apply easing per-segment (CSS spec: easing within each keyframe interval)
                            local easing_fn = get_easing(anim.easing)
                            kf_t = easing_fn(kf_t)

                            -- Interpolate each property
                            local from_props = kf_from[2]
                            local to_props = kf_to[2]

                            -- Collect all properties from both keyframes
                            local all_props = {}
                            for prop, _ in pairs(from_props) do all_props[prop] = true end
                            for prop, _ in pairs(to_props) do all_props[prop] = true end

                            for prop, _ in pairs(all_props) do
                                local fv = from_props[prop] or computed[prop]
                                local tv = to_props[prop] or computed[prop]
                                if fv ~= nil and tv ~= nil then
                                    computed[prop] = interpolate(prop, fv, tv, kf_t)
                                    invalidate_text_cache(computed, prop)
                                    flag_prop(dirty_nodes, nid, prop)
                                end
                            end
                        end

                        any_active = true
                    end
                end
            end
        end
    end

    self._active = any_active

    -- Deregister nodes from active set when all transitions + animations are done
    -- AND the node no longer has transition/animation properties (so snapshot is no longer needed)
    for nid in pairs(self._active_nodes) do
        if not self._transitions[nid] and not self._animations[nid] then
            local computed = ns.computed[nid]
            if not computed or (not computed.transition_property and not computed.animation_name) then
                self._active_nodes[nid] = nil
                self._active_nodes_count = self._active_nodes_count - 1
            end
        end
    end

    return any_active, dirty_nodes
end

--- Check if any transitions or animations are active.
---@return boolean
function TransitionEngine:is_active()
    return self._active
end

return TransitionEngine



