------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / textarea.lua
-- Multi-line text input component with caret, selection,
-- line wrapping, vertical scroll, and onChange callback.
-- Behaves like a Chrome <textarea>.
--
-- Reuses clipboard helpers and key handling patterns from
-- input_text.lua but adds multi-line support (Enter = newline,
-- Up/Down arrow navigation, line-aware Home/End).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Utf8 = require("core/util/utf8")

local Textarea = {}
Textarea.__index = Textarea

------------------------------------------------------------
-- Clipboard
------------------------------------------------------------
local Clipboard = require("core/util/clipboard")
local clipboard_read  = Clipboard.read
local clipboard_write = Clipboard.write

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

function Textarea.new()
    return setmetatable({
        caret_pos         = 0,     -- byte offset into text
        sel_start         = nil,
        caret_visible     = true,
        caret_blink_timer = 0,
        BLINK_RATE        = 0.5,
        _scroll_y         = 0,
        _scroll_x         = 0,
        _edit_repeat      = {},
    }, Textarea)
end

------------------------------------------------------------
-- Text measurement
------------------------------------------------------------

local function measure_text(ns, nid, text, font_size)
    local platform = ns._platform
    if not platform then return 0 end
    if text == "" then return 0 end
    local comp = ns.computed[nid] or {}
    local font_family = comp.font_family or ns._default_font
    local font_weight = comp.font_weight or 400
    local font_style = comp.font_style or "normal"
    local fm = ns._font_manager
    if fm and font_family then
        local cache = fm:get_cache_for(font_family, font_weight, font_style)
        if cache then
            return cache:measure_text(text, font_size, Utf8)
        end
    end
    if fm and font_family then
        local count = 0
        for _ in Utf8.codes(text or "") do count = count + 1 end
        return count * (font_size or 16) * 0.5
    end
    return platform:measure_text_width(text, font_size, 0)
end

------------------------------------------------------------
-- Line helpers
------------------------------------------------------------

--- Split text into lines by newline characters.
--- Returns array of {start=byte_offset, text=line_string}.
--- start is 0-based byte offset of the line's first char.
local function split_lines(text)
    local lines = {}
    local line_count = 0
    local pos = 1
    local len = #text
    while pos <= len do
        local nl = text:find("\n", pos, true)
        if nl then
            line_count = line_count + 1
            lines[line_count] = { start = pos - 1, text = text:sub(pos, nl - 1) }
            pos = nl + 1
        else
            line_count = line_count + 1
            lines[line_count] = { start = pos - 1, text = text:sub(pos) }
            break
        end
    end
    if line_count == 0 or text:sub(-1) == "\n" then
        line_count = line_count + 1
        lines[line_count] = { start = len, text = "" }
    end
    return lines
end

--- Find which line the caret is on (1-based line index, 0-based col).
local function caret_to_line_col(lines, caret_pos)
    for i = 1, #lines do
        local line = lines[i]
        local line_end = line.start + #line.text
        if caret_pos <= line_end then
            return i, caret_pos - line.start
        end
    end
    -- Past end: last line
    local last = lines[#lines]
    return #lines, #last.text
end

--- Convert line + col back to byte offset.
local function line_col_to_pos(lines, line_idx, col)
    line_idx = math.max(1, math.min(#lines, line_idx))
    local line = lines[line_idx]
    col = math.max(0, math.min(#line.text, col))
    return line.start + col
end

------------------------------------------------------------
-- Selection helpers
------------------------------------------------------------

function Textarea:_sel_range()
    if not self.sel_start then return nil, nil end
    local a, b = self.sel_start, self.caret_pos
    if a > b then a, b = b, a end
    return a, b
end

function Textarea:_has_sel()
    return self.sel_start ~= nil and self.sel_start ~= self.caret_pos
end

function Textarea:_delete_sel(text)
    local lo, hi = self:_sel_range()
    if not lo then return text, self.caret_pos end
    text = text:sub(1, lo) .. text:sub(hi + 1)
    self.sel_start = nil
    return text, lo
end

function Textarea:_collapse_sel(direction)
    if not self:_has_sel() then return end
    local lo, hi = self:_sel_range()
    self.caret_pos = (direction == "left") and lo or hi
    self.sel_start = nil
end

------------------------------------------------------------
-- Key repeat
------------------------------------------------------------

local EDIT_REPEAT_DELAY = 0.42
local EDIT_REPEAT_RATE  = 0.035

function Textarea:_edit_key_fire(input_state, vk, dt)
    if not self._edit_repeat then self._edit_repeat = {} end
    local down = input_state:is_key_pressed(vk)
    if not down then
        self._edit_repeat[vk] = nil
        return false
    end
    local rep = self._edit_repeat[vk]
    if not rep then
        self._edit_repeat[vk] = { 0, 0 }
        return true
    end
    rep[1] = rep[1] + dt
    rep[2] = rep[2] + dt
    if rep[1] >= EDIT_REPEAT_DELAY and rep[2] >= EDIT_REPEAT_RATE then
        rep[2] = 0
        return true
    end
    return false
end

------------------------------------------------------------
-- Word boundary helpers
------------------------------------------------------------

--- Check if a codepoint starting at 1-based byte position is a word character.
--- ASCII word chars: [A-Za-z0-9_]. Non-ASCII (multi-byte): always treated as word chars.
local function is_word_byte(s, byte_pos_1based)
    local b = string.byte(s, byte_pos_1based)
    if not b then return false end
    if b >= 0x80 then return true end  -- non-ASCII = word char
    local ch = string.char(b)
    return ch:match("[%w_]") ~= nil
end

local function word_left(text, pos)
    if pos <= 0 then return 0 end
    local p = pos
    -- Skip non-word characters backwards (UTF-8 safe)
    while p > 0 do
        local prev_p = Utf8.prev(text, p)
        if not is_word_byte(text, prev_p + 1) then p = prev_p else break end
    end
    -- Skip word characters backwards
    while p > 0 do
        local prev_p = Utf8.prev(text, p)
        if is_word_byte(text, prev_p + 1) then p = prev_p else break end
    end
    return p
end

local function word_right(text, pos)
    local len = #text
    if pos >= len then return len end
    local p = Utf8.next(text, pos)
    -- Skip non-word characters forwards (UTF-8 safe)
    while p < len and not is_word_byte(text, p + 1) do
        p = Utf8.next(text, p)
    end
    -- Skip word characters forwards
    while p < len and is_word_byte(text, p + 1) do
        p = Utf8.next(text, p)
    end
    return p
end

------------------------------------------------------------
-- Update
------------------------------------------------------------

function Textarea:update(ns, nid, input_state, event_system, dt)
    local lay = ns.layout[nid]
    local comp = ns.computed[nid] or {}
    local attrs = ns.attrs[nid] or {}
    local resize_mode = comp.resize or "none"
    if lay and resize_mode ~= "none" then
        local mx, my = input_state.cursor_x, input_state.cursor_y
        local handle = 12
        local in_handle = mx >= lay.x + lay.w - handle and mx < lay.x + lay.w
            and my >= lay.y + lay.h - handle and my < lay.y + lay.h
        if input_state:is_mouse_clicked() and in_handle then
            self._resizing = {
                x = mx,
                y = my,
                w = lay.w,
                h = lay.h,
            }
            return
        end
        if self._resizing then
            if input_state:is_mouse_down() then
                local next_w = self._resizing.w + (mx - self._resizing.x)
                local next_h = self._resizing.h + (my - self._resizing.y)
                if resize_mode == "vertical" then next_w = self._resizing.w end
                if resize_mode == "horizontal" then next_h = self._resizing.h end
                if next_w < 32 then next_w = 32 end
                if next_h < 24 then next_h = 24 end
                next_w = math.floor(next_w + 0.5)
                next_h = math.floor(next_h + 0.5)
                attrs._astro_resize_width = next_w
                attrs._astro_resize_height = next_h
                comp.width = next_w
                comp.height = next_h
                ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
                return
            else
                self._resizing = nil
            end
        end
    end

    if event_system.focus_id ~= nid then return end

    local pseudo = ns.pseudo[nid]
    if pseudo and pseudo.disabled then return end

    local VK = input_state.VK
    local ctrl = input_state.ctrl
    local shift = input_state.shift
    local text = ns.text_content[nid] or ""
    local changed = false

    if self.caret_pos > #text then self.caret_pos = #text end
    if self.sel_start and self.sel_start > #text then self.sel_start = #text end

    local function sel_extend()
        if not self.sel_start then self.sel_start = self.caret_pos end
    end

    local lines = split_lines(text)

    -- Ctrl+A: select all
    if ctrl and self:_edit_key_fire(input_state, VK.A, dt) then
        self.sel_start = 0
        self.caret_pos = #text
        self:_reset_blink()
        input_state:consume_text_events()
        self:_update_scroll(ns, nid)
        return
    end

    -- Ctrl+C
    if ctrl and self:_edit_key_fire(input_state, VK.C, dt) then
        if self:_has_sel() then
            local lo, hi = self:_sel_range()
            clipboard_write(text:sub(lo + 1, hi))
        end
        input_state:consume_text_events()
        self:_update_scroll(ns, nid)
        return
    end

    -- Ctrl+X
    if ctrl and self:_edit_key_fire(input_state, VK.X, dt) then
        if self:_has_sel() then
            local lo, hi = self:_sel_range()
            clipboard_write(text:sub(lo + 1, hi))
            text, self.caret_pos = self:_delete_sel(text)
            changed = true
        end
        input_state:consume_text_events()
    end

    -- Ctrl+V
    if ctrl and self:_edit_key_fire(input_state, VK.V, dt) then
        local paste = clipboard_read()
        if type(paste) == "string" and paste ~= "" then
            if self:_has_sel() then
                text, self.caret_pos = self:_delete_sel(text)
            end
            text = text:sub(1, self.caret_pos) .. paste .. text:sub(self.caret_pos + 1)
            self.caret_pos = self.caret_pos + #paste
            changed = true
        end
        input_state:consume_text_events()
    end

    -- Enter key: insert newline
    if self:_edit_key_fire(input_state, VK.RETURN, dt) then
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
        end
        text = text:sub(1, self.caret_pos) .. "\n" .. text:sub(self.caret_pos + 1)
        self.caret_pos = self.caret_pos + 1
        changed = true
    end

    -- Consume text events
    local events
    if ctrl and not input_state.alt then
        input_state:consume_text_events()
        events = {}
    else
        events = input_state:consume_text_events()
    end

    -- Insert typed characters
    for i = 1, #events do
        local ch = events[i]
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
        end
        text = text:sub(1, self.caret_pos) .. ch .. text:sub(self.caret_pos + 1)
        self.caret_pos = self.caret_pos + #ch
        changed = true
    end

    -- Backspace
    if self:_edit_key_fire(input_state, VK.BACK, dt) then
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
            changed = true
        elseif ctrl then
            local target = word_left(text, self.caret_pos)
            text = text:sub(1, target) .. text:sub(self.caret_pos + 1)
            self.caret_pos = target
            changed = true
        elseif self.caret_pos > 0 then
            local prev_pos = Utf8.prev(text, self.caret_pos)
            text = text:sub(1, prev_pos) .. text:sub(self.caret_pos + 1)
            self.caret_pos = prev_pos
            changed = true
        end
        self.sel_start = nil
    end

    -- Delete
    if self:_edit_key_fire(input_state, VK.DELETE, dt) then
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
            changed = true
        elseif ctrl then
            local target = word_right(text, self.caret_pos)
            text = text:sub(1, self.caret_pos) .. text:sub(target + 1)
            changed = true
        elseif self.caret_pos < #text then
            local next_pos = Utf8.next(text, self.caret_pos)
            text = text:sub(1, self.caret_pos) .. text:sub(next_pos + 1)
            changed = true
        end
        self.sel_start = nil
    end

    -- Re-split lines after potential text change
    lines = split_lines(text)
    local line_idx, col = caret_to_line_col(lines, self.caret_pos)

    -- Arrow Left
    if self:_edit_key_fire(input_state, VK.LEFT, dt) then
        if shift then
            sel_extend()
            if ctrl then
                self.caret_pos = word_left(text, self.caret_pos)
            else
                self.caret_pos = Utf8.prev(text, self.caret_pos)
            end
        else
            if self:_has_sel() then
                self:_collapse_sel("left")
            elseif ctrl then
                self.caret_pos = word_left(text, self.caret_pos)
            else
                self.caret_pos = Utf8.prev(text, self.caret_pos)
            end
            self.sel_start = nil
        end
        self:_reset_blink()
    end

    -- Arrow Right
    if self:_edit_key_fire(input_state, VK.RIGHT, dt) then
        if shift then
            sel_extend()
            if ctrl then
                self.caret_pos = word_right(text, self.caret_pos)
            else
                self.caret_pos = Utf8.next(text, self.caret_pos)
            end
        else
            if self:_has_sel() then
                self:_collapse_sel("right")
            elseif ctrl then
                self.caret_pos = word_right(text, self.caret_pos)
            else
                self.caret_pos = Utf8.next(text, self.caret_pos)
            end
            self.sel_start = nil
        end
        self:_reset_blink()
    end

    -- Arrow Up: move caret to previous line, same column
    if self:_edit_key_fire(input_state, VK.UP, dt) then
        if shift then sel_extend() else self.sel_start = nil end
        if line_idx > 1 then
            self.caret_pos = line_col_to_pos(lines, line_idx - 1, col)
        else
            self.caret_pos = 0  -- first line: go to start
        end
        self:_reset_blink()
    end

    -- Arrow Down: move caret to next line, same column
    if self:_edit_key_fire(input_state, VK.DOWN, dt) then
        if shift then sel_extend() else self.sel_start = nil end
        if line_idx < #lines then
            self.caret_pos = line_col_to_pos(lines, line_idx + 1, col)
        else
            self.caret_pos = #text  -- last line: go to end
        end
        self:_reset_blink()
    end

    -- Home: go to start of current line
    if self:_edit_key_fire(input_state, VK.HOME, dt) then
        if shift then sel_extend() else self.sel_start = nil end
        if ctrl then
            self.caret_pos = 0
        else
            self.caret_pos = lines[line_idx].start
        end
        self:_reset_blink()
    end

    -- End: go to end of current line
    if self:_edit_key_fire(input_state, VK.END_KEY, dt) then
        if shift then sel_extend() else self.sel_start = nil end
        if ctrl then
            self.caret_pos = #text
        else
            self.caret_pos = lines[line_idx].start + #lines[line_idx].text
        end
        self:_reset_blink()
    end

    -- Write back
    if changed then
        ns.text_content[nid] = text
        ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        self:_reset_blink()
        local attrs = ns.attrs[nid]
        local on_change = attrs and (attrs.onChange or attrs.onchange)
        if on_change then
            event_system:fire_action(on_change, nid)
        end
    end

    self:_update_scroll(ns, nid)

    -- Blink
    self.caret_blink_timer = self.caret_blink_timer + dt
    if self.caret_blink_timer >= self.BLINK_RATE then
        self.caret_blink_timer = self.caret_blink_timer - self.BLINK_RATE
        self.caret_visible = not self.caret_visible
    end
end

------------------------------------------------------------
-- Scroll
------------------------------------------------------------

function Textarea:_update_scroll(ns, nid)
    local lay = ns.layout[nid]
    if not lay then return end

    local comp = ns.computed[nid] or {}
    local font_size = comp.font_size or 16
    local text = ns.text_content[nid] or ""
    if self.caret_pos > #text then self.caret_pos = #text end

    local platform = ns._platform
    local line_h = platform and platform:get_font_height(font_size) or (font_size * 1.2)
    local content_h = lay.content_h or 0

    local lines = split_lines(text)
    local line_idx, col = caret_to_line_col(lines, self.caret_pos)

    -- Vertical scroll: keep caret line visible
    local caret_line_top = (line_idx - 1) * line_h
    local caret_line_bot = caret_line_top + line_h

    if caret_line_bot - self._scroll_y > content_h then
        self._scroll_y = caret_line_bot - content_h
    end
    if caret_line_top - self._scroll_y < 0 then
        self._scroll_y = caret_line_top
    end
    if self._scroll_y < 0 then self._scroll_y = 0 end

    -- Store in pseudo for painters
    local pseudo = ns.pseudo[nid]
    if pseudo then
        pseudo._textarea_scroll_y = self._scroll_y
        pseudo._textarea_caret_pos = self.caret_pos
        pseudo._textarea_sel_start = self.sel_start
    end
end

function Textarea:_reset_blink()
    self.caret_visible = true
    self.caret_blink_timer = 0
end

------------------------------------------------------------
-- Paint
------------------------------------------------------------

function Textarea:paint(ns, nid, dl, platform)
    local pseudo = ns.pseudo[nid]
    local lay = ns.layout[nid]
    if not lay then return end

    local comp = ns.computed[nid] or {}
    if (comp.resize or "none") ~= "none" then
        local x = lay.x + lay.w - 10
        local y = lay.y + lay.h - 10
        dl:line(x + 8, y + 2, x + 2, y + 8, 128, 128, 128, 180, 1)
        dl:line(x + 8, y + 5, x + 5, y + 8, 128, 128, 128, 180, 1)
    end

    if not pseudo or not pseudo.focus then return end

    local font_size = comp.font_size or 16
    local text = ns.text_content[nid] or ""
    local content_w = lay.content_w or 0
    local content_h = lay.content_h or 0

    if self.caret_pos > #text then self.caret_pos = #text end

    local line_h = platform:get_font_height(font_size)
    local lines = split_lines(text)
    local line_idx, col = caret_to_line_col(lines, self.caret_pos)

    local scroll_y = self._scroll_y

    -- Paint selection highlight (skip if user-select: none)
    local paint_user_select = comp and comp.user_select
    if self:_has_sel() and paint_user_select ~= "none" then
        local lo, hi = self:_sel_range()
        local lo_line, lo_col = caret_to_line_col(lines, lo)
        local hi_line, hi_col = caret_to_line_col(lines, hi)

        -- Use ::selection style if available, otherwise default blue highlight
        local sel_style = pseudo and pseudo._selection_style
        local sel_bg = sel_style and sel_style.background_color or { 51, 102, 204, 180 }

        for li = lo_line, hi_line do
            local line = lines[li]
            local y_top = lay.content_y + (li - 1) * line_h - scroll_y
            if y_top + line_h > lay.content_y and y_top < lay.content_y + content_h then
                local s_col = (li == lo_line) and lo_col or 0
                local e_col = (li == hi_line) and hi_col or #line.text

                local x1 = lay.content_x + measure_text(ns, nid, line.text:sub(1, s_col), font_size)
                local x2 = lay.content_x + measure_text(ns, nid, line.text:sub(1, e_col), font_size)

                local dx1 = math.max(lay.content_x, x1)
                local dx2 = math.min(lay.content_x + content_w, x2)
                if dx2 > dx1 then
                    dl:rect_fill(dx1, y_top, dx2 - dx1, line_h,
                                 sel_bg[1], sel_bg[2], sel_bg[3], sel_bg[4])
                end
            end
        end
    end

    -- Paint caret
    if self.caret_visible then
        local caret_line = lines[line_idx]
        local caret_x = lay.content_x + measure_text(ns, nid, caret_line.text:sub(1, col), font_size)
        local caret_y = lay.content_y + (line_idx - 1) * line_h - scroll_y

        if caret_y + line_h > lay.content_y and caret_y < lay.content_y + content_h then
            local cc = comp.caret_color
            local cr, cg, cb, ca
            if cc and type(cc) == "table" then
                cr, cg, cb, ca = cc[1], cc[2], cc[3], cc[4] or 255
            else
                local tc = comp.color
                if tc and type(tc) == "table" then
                    cr, cg, cb, ca = tc[1], tc[2], tc[3], tc[4] or 255
                else
                    cr, cg, cb, ca = 0, 0, 0, 255
                end
            end
            dl:rect_fill(caret_x, caret_y, 1, line_h, cr, cg, cb, ca, 0)
        end
    end
end

return Textarea



