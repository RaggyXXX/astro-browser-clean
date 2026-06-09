------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / input_text.lua
-- Text input component with caret, text selection, editing,
-- caret blinking, horizontal scroll, and onChange callback.
-- Behaves like a Chrome <input type="text">.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Utf8 = require("core/util/utf8")

local InputText = {}
InputText.__index = InputText

------------------------------------------------------------
-- Clipboard
------------------------------------------------------------
local Clipboard = require("core/util/clipboard")
local clipboard_read  = Clipboard.read
local clipboard_write = Clipboard.write

--- Create a new InputText instance.
---@return table  InputText instance
function InputText.new()
    return setmetatable({
        caret_pos           = 0,
        sel_start           = nil,   -- selection anchor (nil = no selection)
        caret_visible       = true,
        caret_blink_timer   = 0,
        BLINK_RATE          = 0.5,
        _scroll_x           = 0,
        _mask_char          = nil,   -- nil=normal, string=password mask character
        _mouse_sel_anchor   = nil,   -- byte offset where mouse-down started
        _mouse_dragging     = false, -- true while mouse is held after click in field
    }, InputText)
end

------------------------------------------------------------
-- Text measurement (must match painters.lua font path)
------------------------------------------------------------

--- Measure text width using the same self-drawn font path as painters.lua.
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
-- Selection helpers
------------------------------------------------------------

--- Get ordered selection range (lo, hi). Returns nil,nil if no selection.
function InputText:_sel_range()
    if not self.sel_start then return nil, nil end
    local a, b = self.sel_start, self.caret_pos
    if a > b then a, b = b, a end
    return a, b
end

--- Returns true if there is an active selection.
function InputText:_has_sel()
    return self.sel_start ~= nil and self.sel_start ~= self.caret_pos
end

--- Delete the selected text, return new text and caret position.
function InputText:_delete_sel(text)
    local lo, hi = self:_sel_range()
    if not lo then return text, self.caret_pos end
    text = text:sub(1, lo) .. text:sub(hi + 1)
    self.sel_start = nil
    return text, lo
end

--- Collapse selection to caret side (direction: "left" or "right").
function InputText:_collapse_sel(direction)
    if not self:_has_sel() then return end
    local lo, hi = self:_sel_range()
    if direction == "left" then
        self.caret_pos = lo
    else
        self.caret_pos = hi
    end
    self.sel_start = nil
end

------------------------------------------------------------
-- Key repeat for editing keys
------------------------------------------------------------

local EDIT_REPEAT_DELAY = 0.42
local EDIT_REPEAT_RATE  = 0.035

--- Check if an editing key should fire (edge + repeat).
---@param input_state table
---@param vk number
---@param dt number
---@return boolean
function InputText:_edit_key_fire(input_state, vk, dt)
    if not self._edit_repeat then self._edit_repeat = {} end
    local down = input_state:is_key_pressed(vk)
    if not down then
        self._edit_repeat[vk] = nil
        return false
    end
    local rep = self._edit_repeat[vk]
    if not rep then
        -- Just pressed
        self._edit_repeat[vk] = { 0, 0 }
        return true
    end
    rep[1] = rep[1] + dt  -- total held time
    rep[2] = rep[2] + dt  -- time since last fire
    if rep[1] >= EDIT_REPEAT_DELAY and rep[2] >= EDIT_REPEAT_RATE then
        rep[2] = 0
        return true
    end
    return false
end

------------------------------------------------------------
-- Word boundary helpers (Ctrl+Left/Right/Backspace/Delete)
------------------------------------------------------------

--- Is a character a "word" char? Checks first byte of the codepoint
--- at 0-based offset. Multi-byte (non-ASCII) chars count as word chars.
local function is_word_at(text, pos)
    if pos < 0 or pos >= #text then return false end
    local b = string.byte(text, pos + 1)
    if not b then return false end
    -- Multi-byte UTF-8 codepoints (accented, CJK, etc.) → word char
    if b >= 0x80 then return true end
    -- ASCII: alphanumeric + underscore
    local ch = string.char(b)
    return ch:match("[%w_]") ~= nil
end

--- Find the start of the previous word from 0-based byte offset pos.
--- Steps by codepoint boundaries using Utf8.prev.
local function word_left(text, pos)
    if pos <= 0 then return 0 end
    local p = pos
    -- Step back one codepoint to look at the char before pos
    p = Utf8.prev(text, p)
    -- Skip non-word codepoints going left
    while p > 0 and not is_word_at(text, p) do
        p = Utf8.prev(text, p)
    end
    -- Skip word codepoints going left
    while p > 0 and is_word_at(text, Utf8.prev(text, p)) do
        p = Utf8.prev(text, p)
    end
    return p
end

--- Find the end of the next word from 0-based byte offset pos.
--- Steps by codepoint boundaries using Utf8.next.
local function word_right(text, pos)
    local len = #text
    if pos >= len then return len end
    local p = pos
    -- Skip non-word codepoints going right
    while p < len and not is_word_at(text, p) do
        p = Utf8.next(text, p)
    end
    -- Skip word codepoints going right
    while p < len and is_word_at(text, p) do
        p = Utf8.next(text, p)
    end
    return p
end

------------------------------------------------------------
-- Password mask helper
------------------------------------------------------------

--- Build masked display text for password fields.
--- Uses codepoint count so 1 mask char = 1 codepoint.
--- Returns: masked string, real→mask offset table, mask→real offset table.
--- For non-password fields returns text, nil, nil.
local function mask_text(text, mask_char)
    if not mask_char then return text, nil, nil end
    local cp_count = Utf8.len(text)
    local out = {}
    for _ = 1, cp_count do
        out[#out + 1] = mask_char
    end
    -- Build bidirectional caret mapping (0-based byte offsets)
    local r2m = {}  -- real byte offset → mask byte offset
    local m2r = {}  -- mask byte offset → real byte offset
    local real_pos = 0
    local mask_pos = 0
    local mc_len = #mask_char
    r2m[0] = 0
    m2r[0] = 0
    for _ = 1, cp_count do
        real_pos = Utf8.next(text, real_pos)
        mask_pos = mask_pos + mc_len
        r2m[real_pos] = mask_pos
        m2r[mask_pos] = real_pos
    end
    return table.concat(out), r2m, m2r
end

------------------------------------------------------------
-- Mouse hit-test: pixel X → caret byte offset
------------------------------------------------------------

--- Build an array of valid codepoint boundary byte offsets (0-based).
--- E.g. for "Hé" (3 bytes: H=1, é=2) → {0, 1, 3}
local function cp_boundaries(text)
    local bounds = { 0 }
    local pos = 0
    local len = #text
    while pos < len do
        pos = Utf8.next(text, pos)
        bounds[#bounds + 1] = pos
    end
    return bounds
end

--- Given a pixel X relative to content_x, find the byte offset
--- in `text` where the caret should be placed.
--- Uses binary search on codepoint boundaries for UTF-8 safety.
local function caret_from_x(ns, nid, text, px, font_size)
    if text == "" or px <= 0 then return 0 end
    local full_w = measure_text(ns, nid, text, font_size)
    if px >= full_w then return #text end

    local bounds = cp_boundaries(text)
    -- Binary search over codepoint boundary indices
    local lo, hi = 1, #bounds  -- indices into bounds[]
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local byte_pos = bounds[mid]
        local byte_next = bounds[mid + 1] or #text
        local w = measure_text(ns, nid, text:sub(1, byte_pos), font_size)
        local w_next = measure_text(ns, nid, text:sub(1, byte_next), font_size)
        local glyph_mid = (w + w_next) / 2
        if px < glyph_mid then
            hi = mid
        else
            lo = mid + 1
        end
    end
    return bounds[lo] or #text
end

------------------------------------------------------------
-- Update
------------------------------------------------------------

--- Per-frame update. Processes text events and key presses
--- when this input has focus.
---@param ns           table   NodeStore instance
---@param nid          number  node id
---@param input_state  table   InputState instance
---@param event_system table   EventSystem instance
---@param dt           number  delta time (seconds)
function InputText:update(ns, nid, input_state, event_system, dt)
    -- Always update validation pseudo-states (even when not focused)
    self:_update_validation(ns, nid)

    if event_system.focus_id ~= nid then return end

    -- Skip input for disabled elements
    local pseudo = ns.pseudo[nid]
    if pseudo and pseudo.disabled then return end

    local VK = input_state.VK
    local ctrl = input_state.ctrl
    local shift = input_state.shift
    local text = ns.text_content[nid] or ""
    local changed = false

    -- Clamp caret to current text length (safety)
    if self.caret_pos > #text then self.caret_pos = #text end
    if self.sel_start and self.sel_start > #text then self.sel_start = #text end

    ------------------------------------------------------------
    -- Mouse: click-to-position caret + drag-to-select
    -- (Skip if user-select: none)
    ------------------------------------------------------------
    local comp_us = ns.computed[nid]
    local user_select = comp_us and comp_us.user_select
    local lay = ns.layout[nid]
    if lay and user_select ~= "none" then
        local mx, my = input_state.cursor_x, input_state.cursor_y
        local comp = ns.computed[nid] or {}
        local font_size = comp.font_size or 16
        local display, _, m2r = mask_text(text, self._mask_char)

        -- For password fields, convert mask-text offset to real-text offset
        local function to_real(mask_pos)
            if not m2r then return mask_pos end
            return m2r[mask_pos] or mask_pos
        end

        -- Check if mouse is inside the input's content area
        local in_x = mx >= lay.content_x and mx <= lay.content_x + (lay.content_w or 0)
        local in_y = my >= lay.content_y and my <= lay.content_y + (lay.content_h or 0)
        local in_bounds = in_x and in_y

        local clicked = input_state:is_mouse_clicked()
        local mouse_down = input_state:is_mouse_down()

        if clicked and in_bounds then
            -- Click: position caret at clicked character
            local px = mx - lay.content_x + self._scroll_x
            local pos = to_real(caret_from_x(ns, nid, display, px, font_size))
            if shift then
                -- Shift+click: extend selection from current caret to click
                if not self.sel_start then
                    self.sel_start = self.caret_pos
                end
                self._mouse_sel_anchor = self.sel_start  -- drag extends from original anchor
            else
                -- Plain click: clear selection, start potential drag
                self.sel_start = nil
                self._mouse_sel_anchor = pos  -- drag extends from click point
            end
            self.caret_pos = pos
            self._mouse_dragging = true
            self:_reset_blink()
        elseif mouse_down and self._mouse_dragging then
            -- Drag: extend selection from anchor to current mouse pos
            local px = mx - lay.content_x + self._scroll_x
            local pos = to_real(caret_from_x(ns, nid, display, px, font_size))
            if self._mouse_sel_anchor then
                if pos ~= self._mouse_sel_anchor then
                    self.sel_start = self._mouse_sel_anchor
                else
                    self.sel_start = nil  -- collapsed back to anchor
                end
            end
            self.caret_pos = pos
            self:_reset_blink()
        end

        if not mouse_down then
            self._mouse_dragging = false
        end
    end

    -- Helper: begin or extend selection
    local function sel_extend()
        if not self.sel_start then
            self.sel_start = self.caret_pos
        end
    end

    -- Ctrl+A: select all (edge-only, no repeat)
    if ctrl and input_state:is_key_edge(VK.A) then
        self.sel_start = 0
        self.caret_pos = #text
        self:_reset_blink()
        -- Do not process further; consume the "a" text event.
        input_state:consume_text_events()
        ns.text_content[nid] = text
        self:_update_scroll(ns, nid)
        return
    end

    -- Ctrl+C: copy selection (edge-only, no repeat)
    if ctrl and input_state:is_key_edge(VK.C) then
        if self:_has_sel() and not self._mask_char then
            local lo, hi = self:_sel_range()
            clipboard_write(text:sub(lo + 1, hi))
        end
        input_state:consume_text_events()
        self:_update_scroll(ns, nid)
        return
    end

    -- Ctrl+X: cut selection (no-op copy for password fields)
    if ctrl and input_state:is_key_edge(VK.X) then
        if self:_has_sel() then
            if not self._mask_char then
                local lo, hi = self:_sel_range()
                clipboard_write(text:sub(lo + 1, hi))
            end
            text, self.caret_pos = self:_delete_sel(text)
            changed = true
        end
        input_state:consume_text_events()
        -- fall through to write back + scroll

    -- Ctrl+V: paste
    elseif ctrl and self:_edit_key_fire(input_state, VK.V, dt) then
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
        -- fall through to write back + scroll
    end

    -- Consume text events (characters typed this frame)
    -- Skip text events when Ctrl is held without Alt (AltGr = Ctrl+Alt, allow those)
    local events
    if ctrl and not input_state.alt then
        input_state:consume_text_events()  -- discard
        events = {}
    else
        events = input_state:consume_text_events()
    end

    -- Insert typed characters (replace selection if active)
    for i = 1, #events do
        local ch = events[i]
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
        end
        text = text:sub(1, self.caret_pos) .. ch .. text:sub(self.caret_pos + 1)
        self.caret_pos = self.caret_pos + #ch
        changed = true
    end

    -- Backspace (with key repeat)
    if self:_edit_key_fire(input_state, VK.BACK, dt) then
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
            changed = true
        elseif ctrl then
            -- Ctrl+Backspace: delete word left
            local target = word_left(text, self.caret_pos)
            text = text:sub(1, target) .. text:sub(self.caret_pos + 1)
            self.caret_pos = target
            changed = true
        elseif self.caret_pos > 0 then
            local prev = Utf8.prev(text, self.caret_pos)
            text = text:sub(1, prev) .. text:sub(self.caret_pos + 1)
            self.caret_pos = prev
            changed = true
        end
        self.sel_start = nil
    end

    -- Delete (with key repeat)
    if self:_edit_key_fire(input_state, VK.DELETE, dt) then
        if self:_has_sel() then
            text, self.caret_pos = self:_delete_sel(text)
            changed = true
        elseif ctrl then
            -- Ctrl+Delete: delete word right
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

    -- Arrow Left (with key repeat)
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

    -- Arrow Right (with key repeat)
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

    -- Home (with key repeat)
    if self:_edit_key_fire(input_state, VK.HOME, dt) then
        if shift then
            sel_extend()
        else
            self.sel_start = nil
        end
        self.caret_pos = 0
        self:_reset_blink()
    end

    -- End (with key repeat)
    if self:_edit_key_fire(input_state, VK.END_KEY, dt) then
        if shift then
            sel_extend()
        else
            self.sel_start = nil
        end
        self.caret_pos = #text
        self:_reset_blink()
    end

    -- Write back changed text
    if changed then
        ns.text_content[nid] = text
        ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        self:_reset_blink()

        -- Re-evaluate validation now that text changed
        self:_update_validation(ns, nid)

    -- Trigger onChange action.
        local attrs = ns.attrs[nid]
        local on_change = attrs and (attrs.onChange or attrs.onchange)
        if on_change then
            event_system:fire_action(on_change, nid)
        end
    end

    -- Update scroll offset in update() so painters and caret use same value
    self:_update_scroll(ns, nid)

    -- Caret blink
    self.caret_blink_timer = self.caret_blink_timer + dt
    if self.caret_blink_timer >= self.BLINK_RATE then
        self.caret_blink_timer = self.caret_blink_timer - self.BLINK_RATE
        self.caret_visible = not self.caret_visible
    end
end

--- Update :placeholder-shown, :valid, :invalid pseudo-states.
--- Called from update() BEFORE the focus guard so validation
--- pseudo-classes work on unfocused inputs too.
function InputText:_update_validation(ns, nid)
    local pseudo = ns.pseudo[nid]
    if not pseudo then return end

    local attrs = ns.attrs[nid]
    local text = ns.text_content[nid] or ""
    local placeholder = attrs and attrs.placeholder

    local old_ps = pseudo.placeholder_shown
    local old_valid = pseudo.valid
    local old_invalid = pseudo.invalid

    pseudo.placeholder_shown = (text == nil or text == "")
        and placeholder ~= nil and placeholder ~= ""

    -- Basic form validation pseudo-states (:valid / :invalid)
    local is_empty = (text == nil or text == "")
    if attrs and attrs.required then
        local field_valid = not is_empty
        -- If not empty and pattern attribute is set, validate against pattern
        if field_valid and attrs.pattern and attrs.pattern ~= "" then
            local ok, match = pcall(string.match, text, "^" .. attrs.pattern .. "$")
            if ok then
                field_valid = (match ~= nil)
            end
        end
        pseudo.valid = field_valid
        pseudo.invalid = not field_valid
    else
        -- Non-required fields: valid unless pattern fails on non-empty value
        if not is_empty and attrs and attrs.pattern and attrs.pattern ~= "" then
            local ok, match = pcall(string.match, text, "^" .. attrs.pattern .. "$")
            if ok then
                pseudo.valid = (match ~= nil)
                pseudo.invalid = (match == nil)
            else
                pseudo.valid = true
                pseudo.invalid = false
            end
        else
            pseudo.valid = true
            pseudo.invalid = false
        end
    end

    -- Mark STYLE_DIRTY when pseudo states actually changed
    if pseudo.placeholder_shown ~= old_ps
        or pseudo.valid ~= old_valid
        or pseudo.invalid ~= old_invalid then
        ns:mark_dirty(nid, ns.STYLE_DIRTY)
    end
end

--- Update horizontal scroll offset. Called from update() to ensure
--- text painter and caret use the same scroll in the same frame.
function InputText:_update_scroll(ns, nid)
    local lay = ns.layout[nid]
    if not lay then return end

    local comp = ns.computed[nid] or {}
    local font_size = comp.font_size or 16
    local text = ns.text_content[nid] or ""
    if self.caret_pos > #text then self.caret_pos = #text end

    -- Use masked text for scroll calculation if password
    local display, r2m = mask_text(text, self._mask_char)
    local mask_caret = r2m and r2m[self.caret_pos] or self.caret_pos
    local before_caret = display:sub(1, mask_caret)
    -- Use same font measurement as painters.lua (glyph cache if available)
    local text_w_before = measure_text(ns, nid, before_caret, font_size)
    local content_w = lay.content_w or 0

    local visible_caret = text_w_before - self._scroll_x
    if visible_caret > content_w then
        self._scroll_x = text_w_before - content_w + 2
    elseif visible_caret < 0 then
        self._scroll_x = text_w_before
    end
    -- Clamp scroll so text doesn't float with blank space on right (Issue 10)
    local full_w = measure_text(ns, nid, display, font_size)
    if full_w <= content_w then
        self._scroll_x = 0
    elseif full_w - self._scroll_x < content_w then
        self._scroll_x = full_w - content_w
    end
    if self._scroll_x < 0 then self._scroll_x = 0 end

    -- Store scroll offset and mask char in pseudo so painters can use it
    local pseudo = ns.pseudo[nid]
    if pseudo then
        pseudo._input_scroll_x = self._scroll_x
        pseudo._input_mask_char = self._mask_char
    end
end

--- Reset caret blink (always visible after any action).
function InputText:_reset_blink()
    self.caret_visible = true
    self.caret_blink_timer = 0
end

------------------------------------------------------------
-- Paint
------------------------------------------------------------

--- Paint selection highlight and caret when this input has focus.
--- Scroll offset is pre-computed in update() via _update_scroll().
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance
function InputText:paint(ns, nid, dl, platform)
    local pseudo = ns.pseudo[nid]
    if not pseudo or not pseudo.focus then return end

    local lay = ns.layout[nid]
    if not lay then return end

    local comp = ns.computed[nid] or {}
    local font_size = comp.font_size or 16
    local text = ns.text_content[nid] or ""
    local content_w = lay.content_w or 0

    -- Use masked text for measurement if password
    local display, r2m = mask_text(text, self._mask_char)

    -- Convert real byte offset → mask byte offset (identity for non-password)
    local function to_mask(real_pos)
        if not r2m then return real_pos end
        return r2m[real_pos] or real_pos
    end

    -- Clamp caret_pos for safety
    if self.caret_pos > #text then self.caret_pos = #text end

    local mask_caret = to_mask(self.caret_pos)
    local before_caret = display:sub(1, mask_caret)
    -- Use same font measurement as painters.lua (glyph cache if available)
    local text_w_before = measure_text(ns, nid, before_caret, font_size)

    local caret_x = lay.content_x + text_w_before - self._scroll_x
    local caret_y = lay.content_y
    local caret_h = platform:get_font_height(font_size)

    -- Paint selection highlight (skip if user-select: none)
    local paint_user_select = comp and comp.user_select
    if self:_has_sel() and paint_user_select ~= "none" then
        local lo, hi = self:_sel_range()
        local mask_lo = to_mask(lo)
        local mask_hi = to_mask(hi)
        local sel_left_text = display:sub(1, mask_lo)
        local sel_right_text = display:sub(1, mask_hi)
        local sel_x1 = lay.content_x + measure_text(ns, nid, sel_left_text, font_size) - self._scroll_x
        local sel_x2 = lay.content_x + measure_text(ns, nid, sel_right_text, font_size) - self._scroll_x

        -- Use ::selection style if available, otherwise default blue highlight
        local sel_style = pseudo and pseudo._selection_style
        local sel_bg = sel_style and sel_style.background_color or { 51, 102, 204, 180 }

        -- Clamp to content area
        local draw_x1 = math.max(lay.content_x, sel_x1)
        local draw_x2 = math.min(lay.content_x + content_w, sel_x2)
        if draw_x2 > draw_x1 then
            dl:rect_fill(draw_x1, caret_y, draw_x2 - draw_x1, caret_h,
                         sel_bg[1], sel_bg[2], sel_bg[3], sel_bg[4])
        end
    end

    -- Paint caret
    if self.caret_visible then
        local cc = comp.caret_color
        local cr, cg, cb, ca
        if cc and type(cc) == "table" then
            cr, cg, cb, ca = cc[1], cc[2], cc[3], cc[4] or 255
        else
            -- fallback to text color or default
            local tc = comp.color
            if tc and type(tc) == "table" then
                cr, cg, cb, ca = tc[1], tc[2], tc[3], tc[4] or 255
            else
                cr, cg, cb, ca = 220, 220, 255, 255
            end
        end
        -- Draw caret as a 2px wide rect for visibility (CSS caret-color applies here)
        dl:rect_fill(caret_x, caret_y, 2, caret_h, cr, cg, cb, ca, 0)
    end
end

return InputText



