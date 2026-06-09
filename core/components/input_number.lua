------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / input_number.lua
-- Number input component: text entry + up/down spinner buttons.
-- Attributes: min, max, step, value.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local InputText = require("core/components/input_text")

local InputNumber = {}
InputNumber.__index = InputNumber

--- Create a new InputNumber instance.
---@return table  InputNumber instance
function InputNumber.new()
    local self = setmetatable({
        _input = InputText.new(),
        _repeat_timer = 0,
        _repeat_dir   = 0,   -- -1 or +1 while held
    }, InputNumber)
    return self
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function clamp(value, min_value, max_value)
    if min_value and value < min_value then return min_value end
    if max_value and value > max_value then return max_value end
    return value
end

local function get_attrs(ns, nid)
    local attrs = ns.attrs[nid] or {}
    local min_value = attrs.min and tonumber(attrs.min)
    local max_value = attrs.max and tonumber(attrs.max)
    local step  = tonumber(attrs.step) or 1
    local current_value = tonumber(attrs.value) or 0
    return min_value, max_value, step, current_value, attrs
end

local function set_value(ns, nid, new_value, event_system)
    local attrs = ns.attrs[nid]
    if not attrs then attrs = {}; ns.attrs[nid] = attrs end
    local old_value = attrs.value
    attrs.value = new_value
    -- Sync display text
    ns.text_content[nid] = tostring(new_value)
    if ns.mark_dirty then
        ns:mark_dirty(nid, (ns.LAYOUT_DIRTY or 0) + (ns.PAINT_DIRTY or 0))
    end
    if event_system and old_value ~= new_value then
        local attrs = ns.attrs[nid]
        local on_change = attrs and (attrs.onChange or attrs.onchange)
        if on_change then
            pcall(function() event_system:fire_action(on_change, nid) end)
        end
    end
end

------------------------------------------------------------
-- Update
------------------------------------------------------------

function InputNumber:update(ns, nid, input_state, event_system, dt)
    local lay = ns.layout[nid]
    if not lay then return end

    local min_v, max_v, step, val, attrs = get_attrs(ns, nid)

    -- Spinner button zone: right 20px
    local btn_w = 20
    local btn_x = lay.x + lay.w - btn_w
    local half_h = lay.h * 0.5

    -- Click detection on spinner buttons
    if input_state:is_mouse_clicked() then
        local mx, my = input_state.cursor_x, input_state.cursor_y
        if mx >= btn_x and mx < btn_x + btn_w and my >= lay.y and my < lay.y + lay.h then
            if my < lay.y + half_h then
                -- Up arrow
                local new_val = clamp(val + step, min_v, max_v)
                set_value(ns, nid, new_val, event_system)
                self._repeat_dir = 1
                self._repeat_timer = 0.4  -- initial delay
            else
                -- Down arrow
                local new_val = clamp(val - step, min_v, max_v)
                set_value(ns, nid, new_val, event_system)
                self._repeat_dir = -1
                self._repeat_timer = 0.4
            end
            return  -- don't pass click to text input
        end
    end

    -- Key repeat while holding mouse on spinner
    if self._repeat_dir ~= 0 then
        if input_state:is_mouse_down() then
            self._repeat_timer = self._repeat_timer - dt
            if self._repeat_timer <= 0 then
                self._repeat_timer = 0.08  -- fast repeat
                local min_v2, max_v2, step2, val2 = get_attrs(ns, nid)
                local new_val = clamp(val2 + step2 * self._repeat_dir, min_v2, max_v2)
                set_value(ns, nid, new_val, event_system)
            end
        else
            self._repeat_dir = 0
        end
    end

    -- Sync attrs.value into text_content before text input reads it.
    local cur_text = ns.text_content[nid] or ""
    local expected = tostring(attrs.value or 0)
    if cur_text == "" then
        ns.text_content[nid] = expected
    end

    -- Delegate to inner text input for keyboard editing
    self._input:update(ns, nid, input_state, event_system, dt)

    -- Filter: strip non-numeric characters (allow digits, minus, dot)
    local edited_text = ns.text_content[nid] or ""
    local filtered = edited_text:gsub("[^%d%.%-]", "")
    if filtered ~= edited_text then
        ns.text_content[nid] = filtered
        -- Adjust caret position if chars were removed
        if self._input.caret_pos > #filtered then
            self._input.caret_pos = #filtered
        end
    end

    -- Parse filtered text back to number
    local num = tonumber(filtered)
    if num then
        num = clamp(num, min_v, max_v)
        attrs.value = num
    end
end

------------------------------------------------------------
-- Paint
------------------------------------------------------------

function InputNumber:paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end
    local computed = ns.computed[nid] or {}

    -- Paint text portion (excluding spinner area)
    self._input:paint(ns, nid, dl, platform)

    -- Spinner buttons
    local btn_w = 20
    local btn_x = lay.x + lay.w - btn_w
    local half_h = lay.h * 0.5
    local opacity = computed.opacity or 255

    -- Button background
    local a = math.floor(200 * opacity / 255)
    dl:rect_fill(btn_x, lay.y, btn_w, lay.h, 50, 50, 55, a, 0)
    -- Divider
    dl:rect_fill(btn_x, lay.y + half_h - 0.5, btn_w, 1, 70, 70, 75, a, 0)

    -- Chevron size (identical for both)
    local chev_w = 4   -- half-width
    local chev_h = 3   -- half-height
    local cx = math.floor(btn_x + btn_w * 0.5)
    local cr, cg, cb = 180, 180, 185

    -- Up chevron (centered in upper half)
    local cy_up = math.floor(lay.y + half_h * 0.5)
    dl:line(cx - chev_w, cy_up + chev_h, cx, cy_up - chev_h, cr, cg, cb, a)
    dl:line(cx, cy_up - chev_h, cx + chev_w, cy_up + chev_h, cr, cg, cb, a)

    -- Down chevron (centered in lower half - mirror of up)
    local cy_dn = math.floor(lay.y + half_h + half_h * 0.5)
    dl:line(cx - chev_w, cy_dn - chev_h, cx, cy_dn + chev_h, cr, cg, cb, a)
    dl:line(cx, cy_dn + chev_h, cx + chev_w, cy_dn - chev_h, cr, cg, cb, a)

    -- Left border line
    dl:rect_fill(btn_x, lay.y, 1, lay.h, 70, 70, 75, a, 0)
end

return InputNumber



