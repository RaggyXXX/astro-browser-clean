------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / particle_emitter.lua
-- Particle emitter component: SoA pool with swap-and-pop
-- recycling for zero steady-state allocation.
--
-- Tag: <particle-emitter>
-- All config via element attrs (not CSS properties).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local helpers = require("core/util/helpers")
local lerp    = helpers.lerp

local ParticleEmitter = {}
ParticleEmitter.__index = ParticleEmitter

local PI2 = math.pi * 2
local math_random = math.random
local math_sqrt   = math.sqrt
local math_cos    = math.cos
local math_sin    = math.sin
local math_floor  = math.floor
local math_min    = math.min
local math_max    = math.max

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new ParticleEmitter instance.
---@return table  ParticleEmitter instance
function ParticleEmitter.new()
    return setmetatable({
        -- SoA pool arrays (lazy-allocated)
        px       = nil,
        py       = nil,
        vx       = nil,
        vy       = nil,
        life     = nil,
        max_life = nil,

        -- Active particle count
        count    = 0,

        -- Pool capacity
        capacity = 0,

        -- Emission accumulator (fractional particles)
        _emit_acc = 0,

        -- Burst tracking: true once initial burst has fired
        _burst_done = false,

        -- Previous _burst attr value (to detect new runtime bursts)
        _prev_burst = nil,

        -- Burst interval timer
        _burst_timer = 0,

        -- Cached config (avoid per-frame allocation)
        _cfg = nil,
        _last_attrs = nil,
    }, ParticleEmitter)
end

------------------------------------------------------------
-- Pool management
------------------------------------------------------------

--- Ensure pool arrays are allocated to at least `cap` slots.
---@param cap number  desired capacity
function ParticleEmitter:_ensure_pool(cap)
    if self.capacity >= cap then return end

    local px       = {}
    local py       = {}
    local vx       = {}
    local vy       = {}
    local life     = {}
    local max_life = {}

    -- Copy existing particles
    local old_n = self.count
    if old_n > 0 then
        for i = 1, old_n do
            px[i]       = self.px[i]
            py[i]       = self.py[i]
            vx[i]       = self.vx[i]
            vy[i]       = self.vy[i]
            life[i]     = self.life[i]
            max_life[i] = self.max_life[i]
        end
    end

    self.px       = px
    self.py       = py
    self.vx       = vx
    self.vy       = vy
    self.life     = life
    self.max_life = max_life
    self.capacity = cap
end

------------------------------------------------------------
-- Spawn / Kill
------------------------------------------------------------

--- Spawn one particle (positions relative to emitter center).
---@param cfg table   resolved attribute config
function ParticleEmitter:_spawn(cfg)
    if self.count >= self.capacity then return end

    local n = self.count + 1
    self.count = n

    -- Emission shape offset
    local ox, oy = 0, 0
    local shape = cfg.emit_shape
    if shape == "circle" then
        local r = math_sqrt(math_random()) * (cfg.emit_radius or 0)
        local a = math_random() * PI2
        ox = math_cos(a) * r
        oy = math_sin(a) * r
    elseif shape == "box" then
        ox = (math_random() - 0.5) * (cfg.emit_width or 0)
        oy = (math_random() - 0.5) * (cfg.emit_height or 0)
    end

    -- Store relative to emitter center (not absolute)
    self.px[n] = ox
    self.py[n] = oy

    -- Velocity from angle + speed
    local angle = cfg.angle_min + math_random() * (cfg.angle_max - cfg.angle_min)
    local speed = cfg.speed_min + math_random() * (cfg.speed_max - cfg.speed_min)
    self.vx[n] = math_cos(angle) * speed
    self.vy[n] = math_sin(angle) * speed

    -- Lifetime
    local lt = cfg.lifetime_min + math_random() * (cfg.lifetime_max - cfg.lifetime_min)
    self.life[n]     = lt
    self.max_life[n] = lt
end

--- Kill particle at index i (swap-and-pop O(1) removal).
---@param i number  index to kill
function ParticleEmitter:_kill(i)
    local n = self.count
    if i < n then
        -- Swap with last
        self.px[i]       = self.px[n]
        self.py[i]       = self.py[n]
        self.vx[i]       = self.vx[n]
        self.vy[i]       = self.vy[n]
        self.life[i]     = self.life[n]
        self.max_life[i] = self.max_life[n]
    end
    -- Clear last slot (helps GC, not strictly needed for numbers)
    self.px[n]       = nil
    self.py[n]       = nil
    self.vx[n]       = nil
    self.vy[n]       = nil
    self.life[n]     = nil
    self.max_life[n] = nil

    self.count = n - 1
end

------------------------------------------------------------
-- Config resolution
------------------------------------------------------------

--- Resolve attrs into a flat config table with defaults.
---@param attrs table  raw node attributes
---@return table  resolved config
local function resolve_config(attrs)
    return {
        max_particles = attrs.max_particles or 200,
        emit_rate     = attrs.emit_rate or 30,
        emit_shape    = attrs.emit_shape or "point",
        emit_radius   = attrs.emit_radius or 0,
        emit_width    = attrs.emit_width or 0,
        emit_height   = attrs.emit_height or 0,
        burst_count    = attrs.burst_count or 0,
        burst_interval = attrs.burst_interval or 0,
        lifetime_min  = attrs.lifetime_min or 0.8,
        lifetime_max  = attrs.lifetime_max or 1.5,
        speed_min     = attrs.speed_min or 40,
        speed_max     = attrs.speed_max or 80,
        angle_min     = attrs.angle_min or 0,
        angle_max     = attrs.angle_max or PI2,
        gravity_x     = attrs.gravity_x or 0,
        gravity_y     = attrs.gravity_y or -30,
        drag          = attrs.drag or 0,
        size_start    = attrs.size_start or 4,
        size_end      = attrs.size_end or 1,
        color_start_r = attrs.color_start_r or 255,
        color_start_g = attrs.color_start_g or 180,
        color_start_b = attrs.color_start_b or 50,
        color_start_a = attrs.color_start_a or 255,
        color_end_r   = attrs.color_end_r or 255,
        color_end_g   = attrs.color_end_g or 60,
        color_end_b   = attrs.color_end_b or 20,
        color_end_a   = attrs.color_end_a or 0,
        shape         = attrs.shape or "circle",
        paused        = attrs.paused or false,
    }
end

------------------------------------------------------------
-- Update
------------------------------------------------------------

--- Per-frame update: emission, physics, lifetime.
---@param ns           table  NodeStore instance
---@param nid          number node id
---@param input_state  table  InputState instance
---@param event_system table  EventSystem instance
---@param dt           number delta time in seconds
function ParticleEmitter:update(ns, nid, input_state, event_system, dt)
    local attrs = ns.attrs[nid] or {}
    if attrs ~= self._last_attrs then
        self._cfg = resolve_config(attrs)
        self._last_attrs = attrs
    end
    local cfg = self._cfg

    -- Clamp dt to avoid spiral-of-death
    dt = math_min(dt, 0.1)

    -- Ensure pool
    self:_ensure_pool(cfg.max_particles)

    -- Paused: skip everything
    if cfg.paused then return end

    -- Need layout to confirm element is positioned
    local lay = ns.layout[nid]
    if not lay then return end

    -- Burst logic (initial + repeating via burst_interval)
    if cfg.burst_count > 0 then
        if not self._burst_done then
            -- Initial burst on first frame with layout
            self._burst_done = true
            self._burst_timer = 0
            for _ = 1, cfg.burst_count do
                self:_spawn(cfg)
            end
        elseif cfg.burst_interval > 0 then
            -- Repeating burst
            self._burst_timer = self._burst_timer + dt
            if self._burst_timer >= cfg.burst_interval then
                self._burst_timer = self._burst_timer - cfg.burst_interval
                for _ = 1, cfg.burst_count do
                    self:_spawn(cfg)
                end
            end
        end
    end

    -- Runtime burst trigger via _burst attr
    local burst_val = attrs._burst
    if burst_val and burst_val ~= self._prev_burst then
        self._prev_burst = burst_val
        local burst_n = type(burst_val) == "number" and burst_val or cfg.burst_count
        if burst_n > 0 then
            for _ = 1, burst_n do
                self:_spawn(cfg)
            end
        end
    end

    -- Continuous emission
    if cfg.emit_rate > 0 then
        self._emit_acc = self._emit_acc + cfg.emit_rate * dt
        local to_spawn = math_floor(self._emit_acc)
        if to_spawn > 0 then
            self._emit_acc = self._emit_acc - to_spawn
            for _ = 1, to_spawn do
                self:_spawn(cfg)
            end
        end
    end

    -- Physics + lifetime
    local gx, gy = cfg.gravity_x, cfg.gravity_y
    local drag = cfg.drag
    local has_drag = drag > 0
    local drag_factor = 1
    if has_drag then
        drag_factor = math_max(0, 1 - drag * dt)
    end

    local i = 1
    while i <= self.count do
        -- Decrease lifetime
        self.life[i] = self.life[i] - dt

        if self.life[i] <= 0 then
            self:_kill(i)
            -- Don't increment: swapped particle now at i
        else
            -- Apply gravity
            self.vx[i] = self.vx[i] + gx * dt
            self.vy[i] = self.vy[i] + gy * dt

            -- Apply drag
            if has_drag then
                self.vx[i] = self.vx[i] * drag_factor
                self.vy[i] = self.vy[i] * drag_factor
            end

            -- Integrate position
            self.px[i] = self.px[i] + self.vx[i] * dt
            self.py[i] = self.py[i] + self.vy[i] * dt

            i = i + 1
        end
    end
end

------------------------------------------------------------
-- Paint
------------------------------------------------------------

--- Paint all active particles via display list primitives.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  SylvanasPlatform instance
function ParticleEmitter:paint(ns, nid, dl, platform)
    local n = self.count
    if n == 0 then return end

    local cfg = self._cfg
    if not cfg then return end

    -- Emitter layout for coordinate conversion + clip boundary
    local lay = ns.layout[nid]
    if not lay then return end

    -- Push clip rect -" display_list strict containment handles the rest
    dl:clip_push(lay.x, lay.y, lay.w, lay.h, 0, 0, 0, 0)

    local center_x = lay.x + lay.w * 0.5
    local center_y = lay.y + lay.h * 0.5

    local size_start = cfg.size_start
    local size_end   = cfg.size_end
    local sr, sg, sb, sa = cfg.color_start_r, cfg.color_start_g, cfg.color_start_b, cfg.color_start_a
    local er, eg, eb, ea = cfg.color_end_r, cfg.color_end_g, cfg.color_end_b, cfg.color_end_a
    local draw_shape = cfg.shape

    local use_circle = (draw_shape == "circle")

    for i = 1, n do
        local ml = self.max_life[i]
        local t = (ml > 0) and (1 - self.life[i] / ml) or 1  -- 0 at birth, 1 at death

        -- Interpolate size
        local sz = lerp(size_start, size_end, t)
        local half = sz * 0.5

        -- Absolute position (relative coords + current center)
        local px_i = center_x + self.px[i]
        local py_i = center_y + self.py[i]

        -- Interpolate color
        local cr = math_floor(lerp(sr, er, t) + 0.5)
        local cg = math_floor(lerp(sg, eg, t) + 0.5)
        local cb = math_floor(lerp(sb, eb, t) + 0.5)
        local ca = math_floor(lerp(sa, ea, t) + 0.5)

        if ca > 0 then
            if use_circle then
                dl:circle_fill(px_i, py_i, half, cr, cg, cb, ca)
            else
                dl:rect_fill(px_i - half, py_i - half, sz, sz, cr, cg, cb, ca)
            end
        end
    end

    dl:clip_pop()
end

return ParticleEmitter



