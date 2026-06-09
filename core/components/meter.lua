------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / meter.lua
-- Meter component: display-only bar with low/high/optimum
-- color zones (green / yellow / red).
-- Attributes: value, min, max, low, high, optimum.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Meter = {}

--- Determine fill color based on value vs low/high/optimum thresholds.
---@param val     number  current value
---@param low     number  low threshold
---@param high    number  high threshold
---@param optimum number  optimum value
---@return number, number, number  r, g, b
local function pick_color(val, low, high, optimum)
    -- Green: {80,180,80}  Yellow: {220,180,40}  Red: {220,60,60}
    if optimum <= low then
        -- optimum is in the low region: low values are good
        if val <= low then return 80, 180, 80 end
        if val <= high then return 220, 180, 40 end
        return 220, 60, 60
    elseif optimum >= high then
        -- optimum is in the high region: high values are good
        if val >= high then return 80, 180, 80 end
        if val >= low then return 220, 180, 40 end
        return 220, 60, 60
    else
        -- optimum is in the middle region
        if val >= low and val <= high then return 80, 180, 80 end
        return 220, 180, 40
    end
end

--- Paint the meter bar: track + colored fill.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Meter.paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    local attrs = ns.attrs[nid]
    local min_val = tonumber((attrs and attrs.min) or 0) or 0
    local max_val = tonumber((attrs and attrs.max) or 100) or 100
    local range = max_val - min_val
    if range <= 0 then range = 1 end

    local val = tonumber((attrs and attrs.value) or min_val) or min_val
    if val < min_val then val = min_val end
    if val > max_val then val = max_val end

    local low     = tonumber((attrs and attrs.low)     or (min_val + range * 0.25)) or (min_val + range * 0.25)
    local high    = tonumber((attrs and attrs.high)    or (min_val + range * 0.75)) or (min_val + range * 0.75)
    local optimum = tonumber((attrs and attrs.optimum) or (min_val + range * 0.5))  or (min_val + range * 0.5)

    local ratio = (val - min_val) / range

    local computed = ns.computed and ns.computed[nid]
    local border_radius = (computed and computed.border_radius) or 4
    local bar_height = lay.h
    if bar_height <= 0 then bar_height = 8 end

    -- Track
    dl:rect_fill(lay.x, lay.y, lay.w, bar_height,
                 40, 40, 45, 255, border_radius)

    -- Fill
    local fill_w = math.floor(lay.w * ratio)
    if fill_w > 0 then
        local fr, fg, fb = pick_color(val, low, high, optimum)
        dl:rect_fill(lay.x, lay.y, fill_w, bar_height,
                     fr, fg, fb, 255, border_radius)
    end
end

--- Update: display-only, no interaction.
---@param ns           table  NodeStore instance
---@param nid          number node id
---@param input_state  table  InputState instance (unused)
---@param event_system table  EventSystem instance (unused)
function Meter.update(ns, nid, input_state, event_system)
    -- Display-only; nothing to do.
end

return Meter



