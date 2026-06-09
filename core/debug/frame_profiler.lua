------------------------------------------------------------
-- ext_core_astro_ui_lib / core / debug / frame_profiler.lua
-- Lightweight pipeline-phase profiler with injectable clock.
-- Ring buffer of last 120 frames, zero-cost when disabled.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local FrameProfiler = {}
FrameProfiler.__index = FrameProfiler

local function fallback_ticks()
    if type(os) == "table" and type(os.clock) == "function" then
        return os.clock()
    end
    return 0
end

local function fallback_tps()
    return 1
end

-- Phase indices (fixed slots, no table alloc per measurement)
FrameProfiler.PHASE_INPUT   = 1
FrameProfiler.PHASE_EVENTS  = 2
FrameProfiler.PHASE_STYLE   = 3
FrameProfiler.PHASE_LAYOUT  = 4
FrameProfiler.PHASE_PAINT   = 5
FrameProfiler.PHASE_REPLAY  = 6
FrameProfiler.PHASE_TOTAL   = 7
FrameProfiler.NUM_PHASES    = 7

-- Metric indices (appended after phases in each ring slot)
FrameProfiler.METRIC_DIRTY_STYLE   = 8
FrameProfiler.METRIC_DIRTY_LAYOUT  = 9
FrameProfiler.METRIC_NODES_PAINTED = 10
FrameProfiler.METRIC_THROTTLED     = 11
FrameProfiler.SLOT_SIZE            = 11

local RING_SIZE = 120

function FrameProfiler.new(ticks_fn, tps_fn)
    local self = setmetatable({}, FrameProfiler)
    self._enabled = false
    self._ticks_fn = ticks_fn or fallback_ticks
    self._tps_fn = tps_fn or fallback_tps
    self._ring = {}             -- flat array: [frame_pos * SLOT_SIZE + phase] = ticks
    self._ring_pos = 0          -- current write position (0-based)
    self._ring_count = 0        -- how many frames stored
    self._frame_start = 0       -- cpu_ticks at frame begin
    self._phase_start = 0       -- cpu_ticks at phase begin
    self._tps = 0               -- ticks per second (cached)
    -- Pre-allocate ring buffer
    for i = 1, RING_SIZE * FrameProfiler.SLOT_SIZE do
        self._ring[i] = 0
    end
    return self
end

function FrameProfiler:enable()
    self._enabled = true
    local ok, tps = pcall(self._tps_fn)
    self._tps = ok and tps or 1000000
end

function FrameProfiler:disable()
    self._enabled = false
end

function FrameProfiler:is_enabled()
    return self._enabled
end

function FrameProfiler:begin_frame()
    if not self._enabled then return end
    self._frame_start = self._ticks_fn()
    -- Clear this ring slot
    local base = self._ring_pos * FrameProfiler.SLOT_SIZE
    for i = 1, FrameProfiler.SLOT_SIZE do
        self._ring[base + i] = 0
    end
end

function FrameProfiler:begin_phase(phase_idx)
    if not self._enabled then return end
    self._phase_start = self._ticks_fn()
end

function FrameProfiler:end_phase(phase_idx)
    if not self._enabled then return end
    local elapsed = self._ticks_fn() - self._phase_start
    local base = self._ring_pos * FrameProfiler.SLOT_SIZE
    self._ring[base + phase_idx] = elapsed
end

--- Write a pre-computed tick duration for a phase (for accumulator pattern).
---@param phase_idx number  phase slot index
---@param ticks     number  accumulated tick count
function FrameProfiler:set_phase_ticks(phase_idx, ticks)
    if not self._enabled then return end
    local base = self._ring_pos * FrameProfiler.SLOT_SIZE
    self._ring[base + phase_idx] = ticks
end

function FrameProfiler:set_metric(metric_idx, value)
    if not self._enabled then return end
    local base = self._ring_pos * FrameProfiler.SLOT_SIZE
    self._ring[base + metric_idx] = value
end

function FrameProfiler:end_frame()
    if not self._enabled then return end
    local total = self._ticks_fn() - self._frame_start
    local base = self._ring_pos * FrameProfiler.SLOT_SIZE
    self._ring[base + FrameProfiler.PHASE_TOTAL] = total
    self._ring_pos = (self._ring_pos + 1) % RING_SIZE
    if self._ring_count < RING_SIZE then
        self._ring_count = self._ring_count + 1
    end
end

function FrameProfiler:get_stats()
    if self._ring_count == 0 then return nil end
    local tps = self._tps
    if tps == 0 then tps = 1 end
    local stats = {}
    local phase_names = { "input", "events", "style", "layout", "paint", "replay", "total" }
    local ring = self._ring
    local ring_pos = self._ring_pos
    local ring_count = self._ring_count
    local slot_size = FrameProfiler.SLOT_SIZE

    for pi = 1, FrameProfiler.NUM_PHASES do
        local sum, min_v, max_v = 0, math.huge, 0
        local values = {}
        for fi = 0, ring_count - 1 do
            local idx = ((ring_pos - 1 - fi) % RING_SIZE) * slot_size + pi
            local v = ring[idx]
            sum = sum + v
            if v < min_v then min_v = v end
            if v > max_v then max_v = v end
            values[#values + 1] = v
        end
        -- Sort for P95
        table.sort(values)
        local p95_idx = math.ceil(#values * 0.95)
        if p95_idx < 1 then p95_idx = 1 end
        stats[phase_names[pi]] = {
            avg_ms = (sum / ring_count) / tps * 1000,
            min_ms = min_v / tps * 1000,
            max_ms = max_v / tps * 1000,
            p95_ms = values[p95_idx] / tps * 1000,
        }
    end

    -- Dirty metrics (averages only)
    local metric_names  = { "dirty_style_count", "dirty_layout_count", "nodes_painted", "throttled_frames" }
    local metric_indices = {
        FrameProfiler.METRIC_DIRTY_STYLE,
        FrameProfiler.METRIC_DIRTY_LAYOUT,
        FrameProfiler.METRIC_NODES_PAINTED,
        FrameProfiler.METRIC_THROTTLED,
    }
    for mi = 1, #metric_names do
        local sum = 0
        for fi = 0, ring_count - 1 do
            local idx = ((ring_pos - 1 - fi) % RING_SIZE) * slot_size + metric_indices[mi]
            sum = sum + ring[idx]
        end
        stats[metric_names[mi]] = sum / ring_count
    end
    stats.frame_count = ring_count
    return stats
end

return FrameProfiler



