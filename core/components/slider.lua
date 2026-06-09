------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / slider.lua
-- Slider component: track + thumb, drag for value.
-- Attributes: min, max, step, value.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Slider = {}
Slider.__index = Slider
local ControlParts = require("core/components/control_parts")

--- Create a new Slider instance.
---@return table  Slider instance
function Slider.new()
    return setmetatable({
        dragging = false,
    }, Slider)
end

--- Per-frame update.  Handles click-to-grab and drag.
---@param ns           table  NodeStore instance
---@param nid          number node id
---@param input_state  table  InputState instance
---@param event_system table  EventSystem instance
function Slider:update(ns, nid, input_state, event_system)
    local lay = ns.layout[nid]
    if not lay then return end

    local attrs = ns.attrs[nid] or {}
    -- HTML parser leaves numeric attrs as strings; coerce safely.
    local min_val = tonumber(attrs.min) or 0
    local max_val = tonumber(attrs.max) or 100
    local val = tonumber(attrs.value) or min_val

    -- Start drag on click inside the slider
    if input_state:is_mouse_clicked() then
        local mx, my = input_state.cursor_x, input_state.cursor_y
        if mx >= lay.x and mx < lay.x + lay.w
           and my >= lay.y and my < lay.y + lay.h then
            self.dragging = true
        end
    end

    -- End drag when mouse released
    if not input_state:is_mouse_down() then
        self.dragging = false
    end

    -- While dragging, update value
    if self.dragging then
        if lay.w <= 0 then return end
        local track_x, _, track_w, _, thumb_r = ControlParts.range_metrics(lay)
        if track_w <= 0 then track_w = 1 end
        local ratio = (input_state.cursor_x - track_x) / track_w
        ratio = math.max(0, math.min(1, ratio))
        val = min_val + ratio * (max_val - min_val)

        local step = tonumber(attrs.step) or 1
        if step > 0 then
            val = math.floor(val / step + 0.5) * step
        end

        -- Clamp to range
        val = math.max(min_val, math.min(max_val, val))
        attrs.value = val
        ns:mark_dirty(nid, ns.PAINT_DIRTY)

        -- Fire onChange action (HTML parser lowercases attribute names,
        -- so accept both spellings).
        local on_change = attrs.onChange or attrs.onchange
        if on_change and event_system then
            event_system:fire_action(on_change, nid)
        end
    end

    -- Keyboard step when focused: left/right and up/down adjust by step; Home/End jump to bounds.
    if event_system and event_system.focus_id == nid then
        local step = tonumber(attrs.step) or 1
        if step <= 0 then step = 1 end
        local delta_value = 0
        if input_state:is_key_edge(0x25) or input_state:is_key_edge(0x28) then
            delta_value = -step   -- Left or Down
        elseif input_state:is_key_edge(0x27) or input_state:is_key_edge(0x26) then
            delta_value = step    -- Right or Up
        elseif input_state:is_key_edge(0x24) then
            val = min_val; delta_value = nil  -- Home
        elseif input_state:is_key_edge(0x23) then
            val = max_val; delta_value = nil  -- End
        end
        if delta_value ~= 0 then
            if delta_value then val = val + delta_value end
            val = math.max(min_val, math.min(max_val, val))
            attrs.value = val
            ns:mark_dirty(nid, ns.PAINT_DIRTY)
            local on_change = attrs.onChange or attrs.onchange
            if on_change then event_system:fire_action(on_change, nid) end
        end
    end
end

--- Paint the slider: track, filled portion, and thumb.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Slider:paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    local attrs = ns.attrs[nid] or {}
    -- HTML parser leaves numeric attrs as strings; coerce safely.
    local min_val = tonumber(attrs.min) or 0
    local max_val = tonumber(attrs.max) or 100
    local val = tonumber(attrs.value) or min_val
    local range = max_val - min_val
    if range <= 0 then range = 1 end
    local ratio = (val - min_val) / range

    ControlParts.paint_range(ns, nid, dl, lay, ratio)
end

return Slider



