------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / progress.lua
-- Progress bar component: display-only horizontal bar.
-- Attributes: value (0-100), max (default 100).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Progress = {}

--- Paint the progress bar: track + filled portion.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Progress.paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    local attrs = ns.attrs[nid]
    local max_val = tonumber((attrs and attrs.max) or 100) or 100
    if max_val <= 0 then max_val = 100 end
    local val = tonumber((attrs and attrs.value) or 0) or 0
    if val < 0 then val = 0 end
    if val > max_val then val = max_val end

    local ratio = val / max_val

    local computed = ns.computed and ns.computed[nid]
    local border_radius = (computed and computed.border_radius) or 4
    local bar_height = lay.h
    if bar_height <= 0 then bar_height = 8 end

    -- Track: dark background
    dl:rect_fill(lay.x, lay.y, lay.w, bar_height,
                 40, 40, 45, 255, border_radius)

    -- Fill: accent color
    local fill_w = math.floor(lay.w * ratio)
    if fill_w > 0 then
        local ac = computed and computed.accent_color
        local fr, fg, fb = 60, 120, 220
        if ac and type(ac) == "table" then
            fr, fg, fb = ac[1], ac[2], ac[3]
        end
        dl:rect_fill(lay.x, lay.y, fill_w, bar_height,
                     fr, fg, fb, 255, border_radius)
    end
end

--- Update: sync pseudo states (no interaction).
---@param ns           table  NodeStore instance
---@param nid          number node id
---@param input_state  table  InputState instance (unused)
---@param event_system table  EventSystem instance (unused)
function Progress.update(ns, nid, input_state, event_system)
    -- Display-only; nothing to do.
end

return Progress



