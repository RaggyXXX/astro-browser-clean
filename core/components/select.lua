------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / select.lua
-- Dropdown select component: click to toggle popup,
-- click option to select.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Select = {}
Select.__index = Select
local ControlParts = require("core/components/control_parts")

local function paint_text(ns, nid, dl, text, x, y, font_size, red, green, blue, alpha)
    local comp = ns.computed[nid] or {}
    local family = comp.font_family or ns._default_font
    local weight = comp.font_weight or 400
    local style = comp.font_style or "normal"
    local Painters = require("core/paint/painters")
    Painters.paint_text(dl, text, x, y, font_size, red, green, blue, alpha,
        false, family, weight, style)
end

local function text_line_box(ns, nid, font_size, platform)
    local comp = ns.computed[nid] or {}
    local fm = ns._font_manager
    local family = comp.font_family or ns._default_font
    local weight = comp.font_weight or 400
    local style = comp.font_style or "normal"
    local cache = fm and family and fm:get_cache_for(family, weight, style)
    if cache then
        local ascent, descent, gap = cache:get_metrics(font_size)
        return math.ceil((ascent or 0) - (descent or 0) + (gap or 0))
    end
    if fm and family then
        return math.ceil((font_size or 16) * 1.25)
    end
    if platform and platform.get_font_height then
        return math.ceil(platform:get_font_height(font_size))
    end
    return math.ceil(font_size * 1.25)
end

local function option_height(ns, nid, font_size, platform)
    return ControlParts.option_height(ns, nid, font_size, platform, text_line_box(ns, nid, font_size, platform))
end

--- Create a new Select instance.
---@return table  Select instance
function Select.new()
    return setmetatable({
        open           = false,
        selected_index = 1,
    }, Select)
end

--- Per-frame update.  Handles open/close toggle and option selection.
---@param ns           table  NodeStore instance
---@param nid          number node id
---@param input_state  table  InputState instance
---@param event_system table  EventSystem instance
function Select:update(ns, nid, input_state, event_system)
    local lay = ns.layout[nid]
    if not lay then return end

    -- Keyboard control when focused: Up/Down navigate, Enter/Space toggles popup,
    -- ESC closes popup.  Skip if a text input has focus (handled elsewhere).
    if event_system and event_system.focus_id == nid then
        local attrs = ns.attrs[nid] or {}
        local options = attrs.options or {}
        if #options > 0 then
            local idx = self.selected_index or 1
            if input_state:is_key_edge(0x26) then  -- Up
                idx = idx - 1
                if idx < 1 then idx = #options end
            elseif input_state:is_key_edge(0x28) then  -- Down
                idx = idx + 1
                if idx > #options then idx = 1 end
            end
            if idx ~= self.selected_index then
                self.selected_index = idx
                -- Keep attrs.selected_index in sync with the instance state.
                -- User scripts read attrs.selected_index via get_attr, and
                -- form reset uses attrs._default_selected_index and restores
                -- the attribute value, not the instance value.  If we never
                -- write back the attribute, both read paths see stale data.
                attrs.selected_index = idx
                local values = attrs.option_values or {}
                attrs.value = values[idx] or options[idx]
                ns.text_content[nid] = options[idx]
                ns:mark_dirty(nid, ns.PAINT_DIRTY + ns.LAYOUT_DIRTY)
                local on_change = attrs.onChange or attrs.onchange
                if on_change then event_system:fire_action(on_change, nid) end
            end
            if input_state:is_key_edge(0x0D) or input_state:is_key_edge(0x20) then
                -- Enter/Space toggles dropdown visibility
                self.open = not self.open
                ns:mark_dirty(nid, ns.PAINT_DIRTY)
            elseif input_state:is_key_edge(0x1B) then
                -- ESC closes
                self.open = false
                ns:mark_dirty(nid, ns.PAINT_DIRTY)
            end
        end
    end

    if not input_state:is_mouse_clicked() then return end

    local mx, my = input_state.cursor_x, input_state.cursor_y

    if mx >= lay.x and mx < lay.x + lay.w
       and my >= lay.y and my < lay.y + lay.h then
        -- Click on the select box: toggle dropdown
        self.open = not self.open
        ns:mark_dirty(nid, ns.PAINT_DIRTY)
    elseif self.open then
        -- Check if clicking on an option in the popup
        local attrs = ns.attrs[nid] or {}
        local options = attrs.options or {}
        local comp = ns.computed[nid] or {}
        local fs = comp.font_size or ControlParts.METRICS.control_font_size
        if type(fs) ~= "number" then fs = ControlParts.METRICS.control_font_size end
        local opt_h = option_height(ns, nid, fs, ns._platform)
        local selected = false

        for i = 1, #options do
            local oy = lay.y + lay.h + (i - 1) * opt_h
            if mx >= lay.x and mx < lay.x + lay.w
               and my >= oy and my < oy + opt_h then
                self.selected_index = i
                attrs.selected_index = i
                local values = attrs.option_values or {}
                attrs.value = values[i] or options[i]
                ns.text_content[nid] = options[i]
                self.open = false
                ns:mark_dirty(nid, ns.PAINT_DIRTY + ns.LAYOUT_DIRTY)
                selected = true

                -- Fire onChange action
                local on_change = attrs.onChange or attrs.onchange
                if on_change then
                    event_system:fire_action(on_change, nid)
                end
                break
            end
        end

        -- Click outside options: close popup
        if not selected then
            self.open = false
            ns:mark_dirty(nid, ns.PAINT_DIRTY)
        end
    end
end

--- Paint the dropdown arrow and popup options list.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Select:paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    -- Dropdown arrow triangle
    local aw = 8
    local ax = lay.x + lay.w - aw - 4
    local ay = lay.y + math.floor(lay.h / 2) - 2
    dl:triangle_fill(ax, ay, ax + aw, ay, ax + math.floor(aw / 2), ay + 5,
                     96, 96, 96, 255)
end

function Select:paint_overlay(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay or not self.open then return end
    local computed = ns.computed[nid] or {}
    -- Popup when open
    local attrs = ns.attrs[nid] or {}
    local options = attrs.options or {}
    local fs = computed.font_size or 16
    if type(fs) ~= "number" then fs = 16 end
    local line_box = text_line_box(ns, nid, fs, platform)
    local line_h = computed.line_height
    if type(line_h) ~= "number" then line_h = line_box end
    local opt_h = ControlParts.option_height(ns, nid, fs, platform, line_box)
    local popup_h = #options * opt_h
    local px, py = lay.x, lay.y + lay.h

    -- Popup background
    dl:rect_fill(px, py, lay.w, popup_h, 255, 255, 255, 255, 0)
    dl:rect_stroke(px, py, lay.w, popup_h, 118, 118, 118, 255, 1, 0)

    for i = 1, #options do
        local oy = py + (i - 1) * opt_h
        -- Highlight selected
        if i == self.selected_index then
            dl:rect_fill(px, oy, lay.w, opt_h, 0, 95, 184, 255, 0)
        end
        local tr, tg, tb = 0, 0, 0
        if i == self.selected_index then tr, tg, tb = 255, 255, 255 end
        local text_y = oy + math.max(2, math.floor((opt_h - line_box) / 2))
        paint_text(ns, nid, dl, options[i], px + 5, text_y, fs, tr, tg, tb, 255)
    end
end

return Select



