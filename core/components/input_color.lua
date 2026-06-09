------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / input_color.lua
-- Color input: swatch + tabbed popup picker (macOS-style).
-- Tabs: 1=Spectrum(SV+Hue) 2=Sliders(RGB) 3=Palettes 4=Image Eyedropper
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local TextureCache = require("core/assets/texture_cache")
local ReactIcons   = require("core/icons/react_icons")
local Painters     = require("core/paint/painters")

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local math_abs   = math.abs
local math_pi    = math.pi
local math_cos   = math.cos
local math_sin   = math.sin

local InputColor = {}
InputColor.__index = InputColor

local function measure_ui_text(text, font_size)
    return Painters.measure_text(text or "", font_size or 12, "inter", 400, "normal")
end

local function draw_ui_text(dl, text, x, y, font_size, r, g, b, a, centered)
    return Painters.paint_text(dl, text or "", x, y, font_size or 12,
        r or 255, g or 255, b or 255, a == nil and 255 or a,
        centered == true, "inter", 400, "normal")
end

------------------------------------------------------------
-- Clipboard
------------------------------------------------------------
local Clipboard = require("core/util/clipboard")
local clipboard_read = Clipboard.read

function InputColor.new()
    return setmetatable({
        _open     = false,
        _tab      = 1,
        _hue      = 210,
        _sat      = 0.8,
        _val      = 0.9,
        _alpha    = 1.0,
        _dragging = nil,
        -- Image eyedropper (tab 4)
        _img_url      = "",
        _img_caret    = 0,
        _url_focused  = false,
        _tex_cache    = nil,
        _img_entry    = nil,
        _img_status   = "idle",
        _img_scroll_x = 0,
        _img_scroll_y = 0,
        _img_zoom     = 1,
        _blink_timer  = 0,
        -- Hover preview (image eyedropper)
        _pick_r = 128, _pick_g = 128, _pick_b = 128,
        -- Editable hex/pct fields
        _hex_focused = false, _hex_text = "", _hex_caret = 0, _hex_sel = nil,
        _pct_focused = false, _pct_text = "", _pct_caret = 0, _pct_sel = nil,
        -- Key repeat state tables for inline fields
        _hex_repeat = {}, _pct_repeat = {}, _url_repeat = {},
        -- URL selection
        _url_sel = nil,
        -- Mouse drag state for mini field selection
        _mini_drag_field = nil,   -- "hex"/"pct"/"url" or nil
        _mini_drag_anchor = nil,  -- byte offset anchor for drag selection
        -- URL field scroll offset (pixels, like InputText._scroll_x)
        _url_scroll_x = 0,
        -- React icons for tab bar
        _react_icons = nil,
    }, InputColor)
end

------------------------------------------------------------
-- Color math
------------------------------------------------------------

local function hsv_to_rgb(hue, saturation, value)
    hue = hue % 360
    local chroma = value * saturation
    local x = chroma * (1 - math_abs((hue / 60) % 2 - 1))
    local m = value - chroma
    local r, g, b
    if hue < 60 then      r, g, b = chroma, x, 0
    elseif hue < 120 then r, g, b = x, chroma, 0
    elseif hue < 180 then r, g, b = 0, chroma, x
    elseif hue < 240 then r, g, b = 0, x, chroma
    elseif hue < 300 then r, g, b = x, 0, chroma
    else                  r, g, b = chroma, 0, x
    end
    return math_floor((r + m) * 255 + 0.5),
           math_floor((g + m) * 255 + 0.5),
           math_floor((b + m) * 255 + 0.5)
end

local function rgb_to_hsv(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max_channel = math_max(r, g, b)
    local min_channel = math_min(r, g, b)
    local delta = max_channel - min_channel
    local hue, saturation, value
    value = max_channel
    saturation = (max_channel == 0) and 0 or (delta / max_channel)
    if delta == 0 then
        hue = 0
    elseif max_channel == r then
        hue = 60 * (((g - b) / delta) % 6)
    elseif max_channel == g then
        hue = 60 * ((b - r) / delta + 2)
    else
        hue = 60 * ((r - g) / delta + 4)
    end
    return hue, saturation, value
end

local function hex_to_rgb(hex)
    if not hex or type(hex) ~= "string" then return 0, 0, 0, 1 end
    hex = hex:gsub("^#", "")
    if #hex >= 6 then
        local r = tonumber(hex:sub(1, 2), 16) or 0
        local g = tonumber(hex:sub(3, 4), 16) or 0
        local b = tonumber(hex:sub(5, 6), 16) or 0
        local al = 1
        if #hex >= 8 then
            al = (tonumber(hex:sub(7, 8), 16) or 255) / 255
        end
        return r, g, b, al
    end
    return 0, 0, 0, 1
end

local function rgb_to_hex(r, g, b, alpha)
    if alpha and alpha < 1 then
        local aa = math_floor(alpha * 255 + 0.5)
        return string.format("#%02x%02x%02x%02x", r, g, b, aa)
    end
    return string.format("#%02x%02x%02x", r, g, b)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

------------------------------------------------------------
-- Design constants (matching reference macOS picker)
------------------------------------------------------------

-- Popup frame
local POP_W       = 340         -- wider for readability
local POP_PAD     = 18          -- generous padding
local POP_RAD     = 14          -- popup corner radius
local CONTENT_W   = POP_W - POP_PAD * 2

-- Tab bar
local TAB_H       = 48          -- taller tab container
local TAB_GAP     = 12          -- gap below tabs
local TAB_CIRCLE  = 30          -- diameter of each tab circle
local TAB_SPACING = 10          -- gap between tab circles
local TAB_ICONS   = {
    { pack = "fi", name = "droplet" },    -- Tab 1: Spectrum
    { pack = "fi", name = "sliders" },    -- Tab 2: RGB Sliders
    { pack = "fi", name = "grid" },       -- Tab 3: Palettes
    { pack = "fi", name = "crosshair" },  -- Tab 4: Eyedropper
}

-- SV field
local SV_H        = 200         -- taller SV field
local SV_RAD      = 0           -- SV field corner radius (square = no overlay/mask mismatch)

-- Bars
local BAR_H       = 18          -- thicker hue/alpha bars
local BAR_RAD     = 9           -- pill-shaped bar ends
local GAP         = 12          -- spacing between sections

-- Preview + fields
local PREVIEW_SZ  = 40          -- bigger preview square
local HEX_H       = 34          -- taller hex/percent fields
local HEX_RAD     = 8           -- field corner radius
local SLIDER_R    = 8           -- thumb radius

-- Colors (darker, more refined)
local BG           = {26, 26, 34}     -- popup background
local BG_DARKER    = {18, 18, 24}     -- recessed areas / fields
local BORDER       = {42, 42, 52}     -- subtle border
local BORDER_FOCUS = {70, 120, 200}   -- focused border
local TEXT_PRIMARY = {200, 200, 214}   -- primary text
local TEXT_DIM     = {100, 100, 118}   -- placeholder / hint text
local TAB_BG      = {22, 22, 30}     -- recessed tab container
local TAB_BORDER  = {36, 36, 46}     -- tab container border
local THUMB_RING  = {255, 255, 255}   -- thumb outer ring

------------------------------------------------------------
-- Layout: popup height varies by tab
------------------------------------------------------------

local function pop_height(tab)
    if tab == 1 then
        -- tabs + SV field + preview+alpha+rainbow bars + hex+pct
        return POP_PAD + TAB_H + TAB_GAP
             + SV_H + GAP                        -- SV field
             + PREVIEW_SZ + GAP                  -- preview + 2 bars
             + HEX_H + POP_PAD                   -- hex + pct
    elseif tab == 2 then
        return POP_PAD + TAB_H + TAB_GAP
             + (BAR_H + GAP + 18) * 3            -- 3 labeled sliders
             + GAP + PREVIEW_SZ + GAP
             + HEX_H + POP_PAD
    elseif tab == 3 then
        return POP_PAD + TAB_H + TAB_GAP
             + 160 + GAP + HEX_H + POP_PAD       -- palette grid
    end
    -- Tab 4: URL + image + preview
    return POP_PAD + TAB_H + TAB_GAP
         + HEX_H + GAP + 192 + GAP + HEX_H + POP_PAD
end

local function popup_rect(lay, ns, tab)
    local vw, vh = 1920, 1080
    if ns and ns._platform and ns._platform.get_screen_size then
        local ok, w, h = pcall(ns._platform.get_screen_size, ns._platform)
        if ok and w and h then vw, vh = w, h end
    end
    local ph = pop_height(tab)
    local px = lay.x
    local py = lay.y + lay.h + 6
    if py + ph > vh then py = lay.y - ph - 6 end
    if py < 0 then py = 0 end
    if px + POP_W > vw then px = vw - POP_W - 4 end
    if px < 0 then px = 0 end
    return px, py, POP_W, ph
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function in_rect(mx, my, rx, ry, rw, rh)
    return mx >= rx and mx < rx + rw and my >= ry and my < ry + rh
end

local function fire_change(self, ns, nid, event_system)
    local r, g, b = hsv_to_rgb(self._hue, self._sat, self._val)
    local attrs = ns.attrs[nid]
    if not attrs then attrs = {}; ns.attrs[nid] = attrs end
    attrs.value = rgb_to_hex(r, g, b, self._alpha)
    local on_change = attrs.onChange or attrs.onchange
    if event_system and on_change then
        pcall(function() event_system:fire_action(on_change, nid) end)
    end
end

local function get_rgb(self)
    return hsv_to_rgb(self._hue, self._sat, self._val)
end

local function read_pixel(entry, pixel_x, pixel_y)
    if not entry or not entry.rgba then return nil end
    local pw = entry.rgba_w or 0
    local ph = entry.rgba_h or 0
    if pixel_x < 0 or pixel_x >= pw or pixel_y < 0 or pixel_y >= ph then
        return nil
    end
    local idx = (pixel_y * pw + pixel_x) * 4
    local r = entry.rgba[idx + 1]
    if not r then return nil end
    return r, entry.rgba[idx + 2] or 0, entry.rgba[idx + 3] or 0
end

--- Draw a slider thumb: white outer ring + colored fill.
local function draw_thumb(dl, cx, cy, ir, ig, ib, a)
    dl:circle_fill(cx, cy, SLIDER_R + 2, THUMB_RING[1], THUMB_RING[2], THUMB_RING[3], a)
    dl:circle_fill(cx, cy, SLIDER_R - 1, ir, ig, ib, a)
end

------------------------------------------------------------
-- Key repeat for inline fields (mirrors InputText._edit_key_fire)
------------------------------------------------------------
local EDIT_REPEAT_DELAY = 0.42
local EDIT_REPEAT_RATE  = 0.035

--- Check if an editing key should fire (edge + repeat).
--- rep_state is a table stored per-field, keyed by vk.
local function key_fire(rep_state, input_state, vk, dt)
    local down = input_state:is_key_pressed(vk)
    if not down then
        rep_state[vk] = nil
        return false
    end
    local rep = rep_state[vk]
    if not rep then
        rep_state[vk] = { 0, 0 }
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

--- Mini field selection helpers
local function mini_sel_range(caret, sel)
    if not sel then return nil, nil end
    local lo, hi = sel, caret
    if lo > hi then lo, hi = hi, lo end
    return lo, hi
end

local function mini_has_sel(caret, sel)
    return sel ~= nil and sel ~= caret
end

local function mini_delete_sel(text, caret, sel)
    local lo, hi = mini_sel_range(caret, sel)
    if not lo then return text, caret, nil end
    text = text:sub(1, lo) .. text:sub(hi + 1)
    return text, lo, nil
end

--- Hit-test for mini fields: pixel X → caret byte offset.
--- text_x is the pixel X where text starts, font_sz is font size.
local function mini_caret_from_x(text, mx, text_x, font_sz, platform)
    local px = mx - text_x
    if px <= 0 or text == "" then return 0 end
    local full_w = measure_ui_text(text, font_sz)
    if px >= full_w then return #text end
    -- Linear scan (mini fields are short, no need for binary search)
    for i = 1, #text do
        local w = measure_ui_text(text:sub(1, i), font_sz)
        local w_prev = (i > 1) and measure_ui_text(text:sub(1, i - 1), font_sz) or 0
        local mid = (w_prev + w) / 2
        if px < mid then return i - 1 end
    end
    return #text
end

--- Mini inline text field: handles keyboard input for a focused field.
--- Returns updated text, caret, and sel (selection anchor, nil = no selection).
---@param text string
---@param caret number
---@param sel number|nil    selection anchor (nil = no selection)
---@param input_state table
---@param dt number         delta time for key repeat
---@param rep_state table   per-field repeat state (e.g. self._hex_repeat)
---@return string, number, number|nil
local function mini_field_keys(text, caret, sel, input_state, dt, rep_state)
    local shift = input_state.shift

    -- Ctrl+V paste
    if input_state.ctrl and key_fire(rep_state, input_state, 0x56, dt) then
        local pasted = clipboard_read()
        if pasted and pasted ~= "" then
            pasted = pasted:gsub("[\r\n\t]", "")
            if mini_has_sel(caret, sel) then
                text, caret, sel = mini_delete_sel(text, caret, sel)
            end
            text = text:sub(1, caret) .. pasted .. text:sub(caret + 1)
            caret = caret + #pasted
        end
        input_state:consume_text_events()
        return text, caret, nil
    end
    -- Ctrl+A: select all
    if input_state.ctrl and key_fire(rep_state, input_state, 0x41, dt) then
        input_state:consume_text_events()
        return text, #text, 0
    end
    -- Ctrl+C: copy selection
    if input_state.ctrl and key_fire(rep_state, input_state, 0x43, dt) then
        if mini_has_sel(caret, sel) then
            local lo, hi = mini_sel_range(caret, sel)
            Clipboard.write(text:sub(lo + 1, hi))
        end
        input_state:consume_text_events()
        return text, caret, sel
    end
    -- Ctrl+X: cut selection
    if input_state.ctrl and key_fire(rep_state, input_state, 0x58, dt) then
        if mini_has_sel(caret, sel) then
            local lo, hi = mini_sel_range(caret, sel)
            Clipboard.write(text:sub(lo + 1, hi))
            text, caret, sel = mini_delete_sel(text, caret, sel)
        end
        input_state:consume_text_events()
        return text, caret, sel
    end
    -- Backspace
    if key_fire(rep_state, input_state, 0x08, dt) then
        if mini_has_sel(caret, sel) then
            text, caret, sel = mini_delete_sel(text, caret, sel)
        elseif caret > 0 then
            text = text:sub(1, caret - 1) .. text:sub(caret + 1)
            caret = caret - 1
        end
        return text, caret, nil
    end
    -- Delete
    if key_fire(rep_state, input_state, 0x2E, dt) then
        if mini_has_sel(caret, sel) then
            text, caret, sel = mini_delete_sel(text, caret, sel)
        elseif caret < #text then
            text = text:sub(1, caret) .. text:sub(caret + 2)
        end
        return text, caret, nil
    end
    -- Left
    if key_fire(rep_state, input_state, 0x25, dt) then
        if shift then
            if not sel then sel = caret end
            return text, math_max(0, caret - 1), sel
        end
        if mini_has_sel(caret, sel) then
            local lo = mini_sel_range(caret, sel)
            return text, lo, nil
        end
        return text, math_max(0, caret - 1), nil
    end
    -- Right
    if key_fire(rep_state, input_state, 0x27, dt) then
        if shift then
            if not sel then sel = caret end
            return text, math_min(#text, caret + 1), sel
        end
        if mini_has_sel(caret, sel) then
            local _, hi = mini_sel_range(caret, sel)
            return text, hi, nil
        end
        return text, math_min(#text, caret + 1), nil
    end
    -- Home
    if key_fire(rep_state, input_state, 0x24, dt) then
        if shift then
            if not sel then sel = caret end
            return text, 0, sel
        end
        return text, 0, nil
    end
    -- End
    if key_fire(rep_state, input_state, 0x23, dt) then
        if shift then
            if not sel then sel = caret end
            return text, #text, sel
        end
        return text, #text, nil
    end
    -- Discard text events when Ctrl is held (prevent Ctrl+S etc. inserting chars)
    if input_state.ctrl and not input_state.alt then
        input_state:consume_text_events()
        return text, caret, sel
    end
    -- Character input (replaces selection)
    local chars = input_state:consume_text_events()
    if chars then
        for ci = 1, #chars do
            local ch = chars[ci]
            if mini_has_sel(caret, sel) then
                text, caret, sel = mini_delete_sel(text, caret, sel)
            end
            text = text:sub(1, caret) .. ch .. text:sub(caret + 1)
            caret = caret + #ch
            sel = nil
        end
    end
    return text, caret, sel
end

------------------------------------------------------------
-- Palette data
------------------------------------------------------------

local PALETTE = {
    "#000000","#1a1a1a","#333333","#4d4d4d","#666666","#808080","#999999","#b3b3b3","#cccccc","#e6e6e6","#ffffff",
    "#ff0000","#ff4d00","#ff8000","#ffb300","#ffe600","#ccff00","#80ff00","#33ff00","#00ff1a","#00ff66","#00ffb3",
    "#00ffff","#00b3ff","#0066ff","#001aff","#3300ff","#6600ff","#9900ff","#cc00ff","#ff00e6","#ff0099","#ff004d",
    "#ffb3b3","#ffd9b3","#ffffb3","#d9ffb3","#b3ffb3","#b3ffd9","#b3ffff","#b3d9ff","#b3b3ff","#d9b3ff","#ffb3ff",
    "#800000","#804000","#808000","#408000","#008000","#008040","#008080","#004080","#000080","#400080","#800080",
    "#cc6666","#cc9966","#cccc66","#99cc66","#66cc66","#66cc99","#66cccc","#6699cc","#6666cc","#9966cc","#cc66cc",
}

------------------------------------------------------------
-- Update
------------------------------------------------------------

function InputColor:update(ns, nid, input_state, event_system, dt)
    local lay = ns.layout[nid]
    if not lay then return end
    local attrs = ns.attrs[nid]
    if not attrs then attrs = {}; ns.attrs[nid] = attrs end

    self._blink_timer = (self._blink_timer or 0) + (dt or 0)

    local mx, my = input_state.cursor_x, input_state.cursor_y
    local clicked = input_state:is_mouse_clicked()
    local mouse_down = input_state:is_mouse_down()

    if not self._open then
        if clicked and in_rect(mx, my, lay.x, lay.y, lay.w, lay.h) then
            self._open = true
            local r, g, b, al = hex_to_rgb(attrs.value or "#1c54ed")
            self._hue, self._sat, self._val = rgb_to_hsv(r, g, b)
            self._alpha = al
            self._pick_r, self._pick_g, self._pick_b = r, g, b
            self._url_focused = (self._tab == 4)
        end
        return
    end

    local px, py, pw, ph = popup_rect(lay, ns, self._tab)

    -- Escape
    if input_state:is_key_edge(0x1B) then
        self._open = false; self._dragging = nil
        self._hex_focused = false; self._pct_focused = false
        return
    end

    -- Tab bar hit test (circular buttons)
    local tab_count = 4
    local tab_total_w = TAB_CIRCLE * tab_count + TAB_SPACING * (tab_count - 1)
    local tab_x0 = px + (POP_W - tab_total_w) / 2
    local tab_cy = py + POP_PAD + TAB_H / 2
    if clicked then
        for t = 1, tab_count do
            local tcx = tab_x0 + (t - 1) * (TAB_CIRCLE + TAB_SPACING) + TAB_CIRCLE / 2
            local dx = mx - tcx
            local dy = my - tab_cy
            if dx * dx + dy * dy <= (TAB_CIRCLE / 2 + 2) * (TAB_CIRCLE / 2 + 2) then
                self._tab = t
                self._dragging = nil
                self._hex_focused = false; self._pct_focused = false
                self._url_focused = (t == 4)  -- auto-focus URL field on tab 4
                return
            end
        end
    end

    -- Content area starts below tab bar
    local cy_top = py + POP_PAD + TAB_H + TAB_GAP

    ----------------------------------------
    -- Tab 1: Spectrum
    -- Layout: SV field → preview + alpha bar + rainbow bar → hex + pct
    ----------------------------------------
    if self._tab == 1 then
        local cx = px + POP_PAD
        -- SV field (directly below tabs)
        local svy = cy_top
        local svw = CONTENT_W
        local svh = SV_H

        -- Below SV: preview + 2 bars stacked
        local bot_y = svy + svh + GAP
        local bar_x = cx + PREVIEW_SZ + GAP
        local bar_w = CONTENT_W - PREVIEW_SZ - GAP
        local hue_bar_y = bot_y + BAR_H + 6   -- rainbow hue bar below alpha

        -- Hex / Percent field positions
        local prev_h = BAR_H * 2 + 6
        local hex_y = bot_y + prev_h + GAP
        local hex_w = math_floor(CONTENT_W * 0.65)
        local pct_x = cx + hex_w + GAP
        local pct_w = CONTENT_W - hex_w - GAP

        -- Helper: commit hex field
        local function commit_hex()
            if not self._hex_focused then return end
            self._hex_focused = false
            local txt = self._hex_text
            if txt:sub(1, 1) ~= "#" then txt = "#" .. txt end
            if #txt >= 4 then  -- at least #rgb
                local r, g, b, al = hex_to_rgb(txt)
                self._hue, self._sat, self._val = rgb_to_hsv(r, g, b)
                if #txt > 7 then self._alpha = al end
                fire_change(self, ns, nid, event_system)
            end
        end

        -- Helper: commit pct field
        local function commit_pct()
            if not self._pct_focused then return end
            self._pct_focused = false
            local txt = self._pct_text:gsub("%%", "")
            local num = tonumber(txt)
            if num then
                self._alpha = clamp(num / 100, 0, 1)
                fire_change(self, ns, nid, event_system)
            end
        end

        if clicked then
            -- Unfocus / commit previous field on any click
            local old_hex = self._hex_focused
            local old_pct = self._pct_focused
            if old_hex then commit_hex() end
            if old_pct then commit_pct() end

            if in_rect(mx, my, cx, hex_y, hex_w, HEX_H) then
                self._hex_focused = true
                self._blink_timer = 0
                if not old_hex then
                    -- First click on hex field: populate text
                    local r, g, b = get_rgb(self)
                    self._hex_text = rgb_to_hex(r, g, b, self._alpha)
                end
                -- Position caret from mouse click
                local plat = ns._platform
                if plat then
                    self._hex_caret = mini_caret_from_x(self._hex_text, mx, cx + 10, 13, plat)
                else
                    self._hex_caret = #self._hex_text
                end
                self._hex_sel = nil
                self._mini_drag_field = "hex"
                self._mini_drag_anchor = self._hex_caret
            elseif in_rect(mx, my, pct_x, hex_y, pct_w, HEX_H) then
                self._pct_focused = true
                self._blink_timer = 0
                if not old_pct then
                    self._pct_text = tostring(math_floor(self._alpha * 100 + 0.5))
                end
                local plat = ns._platform
                if plat then
                    self._pct_caret = mini_caret_from_x(self._pct_text, mx, pct_x + 10, 13, plat)
                else
                    self._pct_caret = #self._pct_text
                end
                self._pct_sel = nil
                self._mini_drag_field = "pct"
                self._mini_drag_anchor = self._pct_caret
            elseif in_rect(mx, my, cx, svy, svw, svh) then
                self._dragging = "sv"
            elseif in_rect(mx, my, bar_x, bot_y, bar_w, BAR_H) then
                self._dragging = "alpha"
            elseif in_rect(mx, my, bar_x, hue_bar_y, bar_w, BAR_H) then
                self._dragging = "hue"
            elseif not in_rect(mx, my, px, py, pw, ph) then
                self._open = false; self._dragging = nil; return
            end
        end

        if not mouse_down then
            self._dragging = nil
            self._mini_drag_field = nil
        end

        -- Mini field mouse drag-to-select
        if mouse_down and not clicked and self._mini_drag_field and self._mini_drag_anchor then
            local plat = ns._platform
            if plat then
                if self._mini_drag_field == "hex" and self._hex_focused then
                    local pos = mini_caret_from_x(self._hex_text, mx, cx + 10, 13, plat)
                    if pos ~= self._mini_drag_anchor then
                        self._hex_sel = self._mini_drag_anchor
                    else
                        self._hex_sel = nil
                    end
                    self._hex_caret = pos
                    self._blink_timer = 0
                elseif self._mini_drag_field == "pct" and self._pct_focused then
                    local pos = mini_caret_from_x(self._pct_text, mx, pct_x + 10, 13, plat)
                    if pos ~= self._mini_drag_anchor then
                        self._pct_sel = self._mini_drag_anchor
                    else
                        self._pct_sel = nil
                    end
                    self._pct_caret = pos
                    self._blink_timer = 0
                end
            end
        end

        if self._dragging == "hue" then
            self._hue = clamp((mx - bar_x) / math_max(bar_w - 1, 1) * 360, 0, 360)
            fire_change(self, ns, nid, event_system)
        elseif self._dragging == "sv" then
            self._sat = clamp((mx - cx) / math_max(svw - 1, 1), 0, 1)
            self._val = clamp(1 - (my - svy) / math_max(svh - 1, 1), 0, 1)
            fire_change(self, ns, nid, event_system)
        elseif self._dragging == "alpha" then
            self._alpha = clamp((mx - bar_x) / math_max(bar_w - 1, 1), 0, 1)
            fire_change(self, ns, nid, event_system)
        end

        -- Hex field keyboard input
        if self._hex_focused then
            self._blink_timer = self._blink_timer + dt
            if input_state:is_key_edge(0x0D) then  -- Enter
                commit_hex()
                input_state:consume_text_events()
            elseif input_state:is_key_edge(0x09) then  -- Tab → jump to pct
                commit_hex()
                self._pct_focused = true
                self._blink_timer = 0
                self._pct_text = tostring(math_floor(self._alpha * 100 + 0.5))
                self._pct_caret = #self._pct_text
                self._pct_sel = nil
                input_state:consume_text_events()
            else
                self._hex_text, self._hex_caret, self._hex_sel =
                    mini_field_keys(self._hex_text, self._hex_caret, self._hex_sel, input_state, dt, self._hex_repeat)
                self._blink_timer = 0
            end
        end

        -- Pct field keyboard input
        if self._pct_focused then
            self._blink_timer = self._blink_timer + dt
            if input_state:is_key_edge(0x0D) then  -- Enter
                commit_pct()
                input_state:consume_text_events()
            elseif input_state:is_key_edge(0x09) then  -- Tab → jump to hex
                commit_pct()
                self._hex_focused = true
                self._blink_timer = 0
                local r, g, b = get_rgb(self)
                self._hex_text = rgb_to_hex(r, g, b, self._alpha)
                self._hex_caret = #self._hex_text
                self._hex_sel = nil
                input_state:consume_text_events()
            else
                self._pct_text, self._pct_caret, self._pct_sel =
                    mini_field_keys(self._pct_text, self._pct_caret, self._pct_sel, input_state, dt, self._pct_repeat)
                self._blink_timer = 0
            end
        end

    ----------------------------------------
    -- Tab 2: RGB Sliders
    ----------------------------------------
    elseif self._tab == 2 then
        local cr, cg, cb = get_rgb(self)
        local sl_x = px + POP_PAD
        local val_text_w = 40
        local sl_w = CONTENT_W - val_text_w
        local row_h = BAR_H + GAP + 18   -- bar + gap + label space

        local ry = cy_top + 16
        local gy = ry + row_h
        local by = gy + row_h

        if clicked then
            if in_rect(mx, my, sl_x, ry, sl_w, BAR_H) then
                self._dragging = "r"
            elseif in_rect(mx, my, sl_x, gy, sl_w, BAR_H) then
                self._dragging = "g"
            elseif in_rect(mx, my, sl_x, by, sl_w, BAR_H) then
                self._dragging = "b"
            elseif not in_rect(mx, my, px, py, pw, ph) then
                self._open = false; self._dragging = nil; return
            end
        end

        if not mouse_down then self._dragging = nil end

        if self._dragging == "r" or self._dragging == "g" or self._dragging == "b" then
            local t = clamp((mx - sl_x) / math_max(sl_w - 1, 1), 0, 1)
            local nr, ng, nb = cr, cg, cb
            if self._dragging == "r" then nr = math_floor(t * 255)
            elseif self._dragging == "g" then ng = math_floor(t * 255)
            else nb = math_floor(t * 255) end
            self._hue, self._sat, self._val = rgb_to_hsv(nr, ng, nb)
            fire_change(self, ns, nid, event_system)
        end

    ----------------------------------------
    -- Tab 3: Palettes
    ----------------------------------------
    elseif self._tab == 3 then
        if clicked then
            local grid_x = px + POP_PAD
            local grid_y = cy_top
            local cols = 11
            local cell = math_floor(CONTENT_W / cols)
            for i = 1, #PALETTE do
                local col = (i - 1) % cols
                local row = math_floor((i - 1) / cols)
                local cx = grid_x + col * cell
                local cy = grid_y + row * cell
                if in_rect(mx, my, cx, cy, cell, cell) then
                    local pr, pg, pb = hex_to_rgb(PALETTE[i])
                    self._hue, self._sat, self._val = rgb_to_hsv(pr, pg, pb)
                    fire_change(self, ns, nid, event_system)
                    break
                end
            end
            if not in_rect(mx, my, px, py, pw, ph) then
                self._open = false; self._dragging = nil; return
            end
        end

    ----------------------------------------
    -- Tab 4: Image Eyedropper
    ----------------------------------------
    elseif self._tab == 4 then
        if not self._tex_cache and ns._platform then
            self._tex_cache = TextureCache.new(ns._platform, "session")
        end
        if self._tex_cache then
            self._tex_cache:tick()
            if self._img_status == "loading" and self._img_url ~= "" then
                local entry = self._tex_cache:get(self._img_url)
                if entry and entry.tex_id then
                    self._img_entry = entry
                    self._img_status = "ready"
                    self._img_scroll_x = 0
                    self._img_scroll_y = 0
                    self._img_zoom = 1
                end
            end
        end

        local url_x = px + POP_PAD
        local url_y = cy_top
        local url_w = CONTENT_W
        local url_h = HEX_H
        local img_x = url_x
        local img_y = url_y + url_h + GAP
        local img_w = CONTENT_W
        local img_h = 192

        if clicked then
            if in_rect(mx, my, url_x, url_y, url_w, url_h) then
                self._url_focused = true
                self._blink_timer = 0
                local plat = ns._platform
                if plat then
                    -- Account for scroll offset in URL field
                    self._img_caret = mini_caret_from_x(
                        self._img_url, mx, url_x + 10 - self._url_scroll_x, 12, plat)
                end
                self._url_sel = nil
                self._mini_drag_field = "url"
                self._mini_drag_anchor = self._img_caret
            elseif in_rect(mx, my, img_x, img_y, img_w, img_h) then
                self._url_focused = false
                if self._img_entry and self._img_entry.rgba then
                    local entry = self._img_entry
                    local iw = entry.rgba_w or entry.w or 1
                    local ih = entry.rgba_h or entry.h or 1
                    local scale = math_min(img_w / iw, img_h / ih, 1) * self._img_zoom
                    local disp_w = math_floor(iw * scale)
                    local disp_h = math_floor(ih * scale)
                    local disp_x = math_floor(img_x + (img_w - disp_w) / 2 + self._img_scroll_x)
                    local disp_y = math_floor(img_y + (img_h - disp_h) / 2 + self._img_scroll_y)
                    if disp_w > 0 and disp_h > 0 then
                        local pixel_x = math_floor((mx - disp_x) / scale)
                        local pixel_y = math_floor((my - disp_y) / scale)
                        local pr, pg, pb = read_pixel(entry, pixel_x, pixel_y)
                        if pr then
                            self._pick_r, self._pick_g, self._pick_b = pr, pg, pb
                            self._hue, self._sat, self._val = rgb_to_hsv(pr, pg, pb)
                            fire_change(self, ns, nid, event_system)
                        end
                    end
                end
            elseif not in_rect(mx, my, px, py, pw, ph) then
                self._open = false; self._dragging = nil; return
            else
                self._url_focused = false
            end
        end

        -- Wheel zoom
        if input_state.wheel and input_state.wheel ~= 0
           and in_rect(mx, my, img_x, img_y, img_w, img_h) then
            local old_zoom = self._img_zoom
            self._img_zoom = clamp(self._img_zoom + input_state.wheel * 0.15, 0.25, 8)
            if self._img_entry then
                local ratio = self._img_zoom / old_zoom
                local cx_rel = mx - (img_x + img_w / 2 + self._img_scroll_x)
                local cy_rel = my - (img_y + img_h / 2 + self._img_scroll_y)
                self._img_scroll_x = self._img_scroll_x - cx_rel * (ratio - 1)
                self._img_scroll_y = self._img_scroll_y - cy_rel * (ratio - 1)
            end
        end

        -- URL field mouse drag-to-select
        if mouse_down and not clicked and self._mini_drag_field == "url"
           and self._mini_drag_anchor and self._url_focused then
            local plat = ns._platform
            if plat then
                local pos = mini_caret_from_x(
                    self._img_url, mx, url_x + 10 - self._url_scroll_x, 12, plat)
                if pos ~= self._mini_drag_anchor then
                    self._url_sel = self._mini_drag_anchor
                else
                    self._url_sel = nil
                end
                self._img_caret = pos
                self._blink_timer = 0
            end
        end
        if not mouse_down then
            self._mini_drag_field = nil
        end

        -- URL keyboard input (unified via mini_field_keys)
        if self._url_focused then
            self._blink_timer = self._blink_timer + dt
            -- Enter: load image (edge-only, no repeat -" prevent repeated HTTP fetches)
            if input_state:is_key_edge(0x0D) then
                if self._img_url ~= "" and self._tex_cache then
                    self._img_status = "loading"
                    self._img_entry = nil
                    self._tex_cache:get(self._img_url)
                end
                input_state:consume_text_events()
            else
                local old_url, old_caret = self._img_url, self._img_caret
                self._img_url, self._img_caret, self._url_sel =
                    mini_field_keys(self._img_url, self._img_caret, self._url_sel, input_state, dt, self._url_repeat)
                if self._img_url ~= old_url or self._img_caret ~= old_caret then
                    self._blink_timer = 0  -- reset blink on any change/move
                end
            end
            -- Update URL scroll offset so caret stays visible
            local plat = ns._platform
            if plat then
                local url_font = 12
                local url_field_w = CONTENT_W - 24  -- ew - 2*padding
                local before = self._img_url:sub(1, self._img_caret)
                local w_before = measure_ui_text(before, url_font)
                local vis = w_before - self._url_scroll_x
                if vis > url_field_w then
                    self._url_scroll_x = w_before - url_field_w + 2
                elseif vis < 0 then
                    self._url_scroll_x = w_before
                end
                if self._url_scroll_x < 0 then self._url_scroll_x = 0 end
            end
        end

        -- Hover preview from image
        if self._img_entry and self._img_entry.rgba
           and in_rect(mx, my, img_x, img_y, img_w, img_h) then
            local entry = self._img_entry
            local iw = entry.rgba_w or entry.w or 1
            local ih = entry.rgba_h or entry.h or 1
            local scale = math_min(img_w / iw, img_h / ih, 1) * self._img_zoom
            local disp_w = math_floor(iw * scale)
            local disp_h = math_floor(ih * scale)
            local disp_x = math_floor(img_x + (img_w - disp_w) / 2 + self._img_scroll_x)
            local disp_y = math_floor(img_y + (img_h - disp_h) / 2 + self._img_scroll_y)
            if disp_w > 0 and disp_h > 0 then
                local pixel_x = math_floor((mx - disp_x) / scale)
                local pixel_y = math_floor((my - disp_y) / scale)
                local pr, pg, pb = read_pixel(entry, pixel_x, pixel_y)
                if pr then
                    self._pick_r, self._pick_g, self._pick_b = pr, pg, pb
                end
            end
        end
    end
end

------------------------------------------------------------
-- Paint
------------------------------------------------------------

function InputColor:paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end
    local attrs = ns.attrs[nid] or {}
    local computed = ns.computed[nid] or {}
    local a = math_floor(computed.opacity or 255)

    local value = attrs.value or "#000000"
    local cr, cg, cb, c_alpha = hex_to_rgb(value)

    -- Swatch button (with checkerboard for alpha)
    local swatch_rad = computed.border_radius or 4
    if c_alpha < 1 then
        -- Checkerboard background
        local csz = 5
        for gy = 0, lay.h - 1, csz do
            for gx = 0, lay.w - 1, csz do
                local dark = ((math_floor(gx / csz) + math_floor(gy / csz)) % 2 == 0)
                local cc = dark and 45 or 65
                local cw = math_min(csz, lay.w - gx)
                local ch = math_min(csz, lay.h - gy)
                dl:rect_fill(lay.x + gx, lay.y + gy, cw, ch, cc, cc, cc, a, 0)
            end
        end
        dl:rect_fill(lay.x, lay.y, lay.w, lay.h, cr, cg, cb, math_floor(c_alpha * a), swatch_rad)
    else
        dl:rect_fill(lay.x, lay.y, lay.w, lay.h, cr, cg, cb, a, swatch_rad)
    end
    dl:rect_stroke(lay.x, lay.y, lay.w, lay.h, 70, 70, 80, a, 1, swatch_rad)
    local fs = math_min(computed.font_size or 12, 12)
    local lum = cr * 0.299 + cg * 0.587 + cb * 0.114
    local tc = lum > 128 and 0 or 255
    draw_ui_text(dl, value, lay.x + lay.w * 0.5 - measure_ui_text(value, fs) * 0.5,
        lay.y + lay.h * 0.5 - fs * 0.5, fs, tc, tc, tc, a, false)

    if not self._open then return end

    local px, py, pw, ph = popup_rect(lay, ns, self._tab)

    -- ===== POPUP SHADOW + BACKGROUND =====
    -- Multi-layer shadow for depth
    dl:rect_fill(px + 6, py + 8, pw, ph, 0, 0, 0, 50, POP_RAD + 2)
    dl:rect_fill(px + 3, py + 4, pw, ph, 0, 0, 0, 35, POP_RAD)
    -- Background
    dl:rect_fill(px, py, pw, ph, BG[1], BG[2], BG[3], 252, POP_RAD)
    dl:rect_stroke(px, py, pw, ph, BORDER[1], BORDER[2], BORDER[3], 180, 1, POP_RAD)

    -- ===== TAB BAR (recessed pill container with reactive color circles) =====
    local tab_count = 4
    local tab_total_w = TAB_CIRCLE * tab_count + TAB_SPACING * (tab_count - 1)
    local container_w = tab_total_w + 24   -- 12px padding each side
    local container_x = px + (POP_W - container_w) / 2
    local container_y = py + POP_PAD
    local container_h = TAB_H

    -- Recessed container (darker bg + inner shadow fake)
    dl:rect_fill(container_x, container_y, container_w, container_h,
                 TAB_BG[1], TAB_BG[2], TAB_BG[3], a, container_h / 2)
    dl:rect_stroke(container_x, container_y, container_w, container_h,
                   TAB_BORDER[1], TAB_BORDER[2], TAB_BORDER[3], math_floor(a * 0.7), 1, container_h / 2)

    -- Lazy-init ReactIcons (needs platform) -" register only the 4 tab icons
    if not self._react_icons then
        self._react_icons = ReactIcons.new(platform)
        local ri_init = self._react_icons
        -- Feather-style stroke icons (stroke_w=2, auto-expanded to filled polygons)
        -- Tab 1: Droplet
        ri_init:register_inline("fi", "droplet",
            "M12 2.69l5.66 5.66a8 8 0 11-11.31 0z", "0 0 24 24", 2)
        -- Tab 2: Sliders
        ri_init:register_inline("fi", "sliders",
            "M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6",
            "0 0 24 24", 2)
        -- Tab 3: Grid
        ri_init:register_inline("fi", "grid",
            "M3 3h7v7H3zM14 3h7v7h-7zM14 14h7v7h-7zM3 14h7v7H3z",
            "0 0 24 24", 2)
        -- Tab 4: Crosshair
        ri_init:register_inline("fi", "crosshair",
            "M12 2v4M12 18v4M2 12h4M18 12h4M12 8v8M8 12h8",
            "0 0 24 24", 2)
    end
    local ri = self._react_icons

    -- Tab circles with SVG icons
    local tab_x0 = px + (POP_W - tab_total_w) / 2
    local tab_cy = container_y + container_h / 2
    local icon_sz = 16  -- icon pixel size inside circle

    for t = 1, tab_count do
        local tcx = tab_x0 + (t - 1) * (TAB_CIRCLE + TAB_SPACING) + TAB_CIRCLE / 2
        local is_active = (t == self._tab)
        local r_outer = TAB_CIRCLE / 2

        if is_active then
            -- Active: glow ring + filled bg
            dl:circle_fill(tcx, tab_cy, r_outer + 2, 70, 120, 200, math_floor(a * 0.3))
            dl:circle_fill(tcx, tab_cy, r_outer, 50, 50, 60, a)
            dl:circle_fill(tcx, tab_cy, r_outer - 2, 60, 60, 72, a)
        else
            -- Inactive: subtle circle
            dl:circle_fill(tcx, tab_cy, r_outer - 1, 38, 38, 48, a)
            dl:circle_fill(tcx, tab_cy, r_outer - 3, 48, 48, 58, a)
        end

        -- Draw SVG icon centered in circle
        local icon_info = TAB_ICONS[t]
        if icon_info then
            local ic_r, ic_g, ic_b, ic_a
            if is_active then
                ic_r, ic_g, ic_b, ic_a = 200, 220, 255, a
            else
                ic_r, ic_g, ic_b, ic_a = 140, 140, 160, math_floor(a * 0.7)
            end
            ri:draw_centered(dl, icon_info.pack, icon_info.name, icon_sz,
                tcx - r_outer, tab_cy - r_outer, TAB_CIRCLE, TAB_CIRCLE,
                ic_r, ic_g, ic_b, ic_a)
        end
    end

    local cy_top = py + POP_PAD + TAB_H + TAB_GAP

    -- ===== TAB 1: SPECTRUM =====
    if self._tab == 1 then
        local cx = px + POP_PAD
        local thr, thg, thb = hsv_to_rgb(self._hue, 1, 1)

        -- SV field (directly below tabs)
        local svy = cy_top
        local svw = CONTENT_W
        local svh = SV_H
        local hr2, hg2, hb2 = hsv_to_rgb(self._hue, 1, 1)
        dl:rect_fill(cx, svy, svw, svh, hr2, hg2, hb2, a, SV_RAD)

        -- Overlays: draw full-width strips, then mask corners with
        -- the popup background color using the same rounded-rect primitive.
        local sv_cols = math_floor(svw)
        local sv_rows = math_floor(svh)

        -- White overlay (saturation: left=white, right=hue)
        for i = 0, sv_cols - 1 do
            local wa = math_floor((1 - i / math_max(sv_cols - 1, 1)) * 255)
            if wa > 0 then
                dl:rect_fill(cx + i, svy, 1, svh,
                             255, 255, 255, math_floor(wa * a / 255), 0)
            end
        end

        -- Black overlay (value: top=light, bottom=dark)
        for i = 0, sv_rows - 1 do
            local ba = math_floor(i / math_max(sv_rows - 1, 1) * 255)
            if ba > 0 then
                dl:rect_fill(cx, svy + i, svw, 1,
                             0, 0, 0, math_floor(ba * a / 255), 0)
            end
        end

        -- No corner cleanup needed -" SV field uses square corners (SV_RAD=0)

        dl:rect_stroke(cx, svy, svw, svh, BORDER[1], BORDER[2], BORDER[3], math_floor(a * 0.6), 1, SV_RAD)

        -- SV cursor
        local cur_x = cx + self._sat * math_max(svw - 1, 1)
        local cur_y = svy + (1 - self._val) * math_max(svh - 1, 1)
        dl:circle_fill(cur_x, cur_y, SLIDER_R + 3, 255, 255, 255, a)
        dl:circle_fill(cur_x, cur_y, SLIDER_R, cr, cg, cb, a)

        -- Bottom section: Preview + 2 bars
        local bot_y = svy + svh + GAP
        local bar_x = cx + PREVIEW_SZ + GAP
        local bar_w = CONTENT_W - PREVIEW_SZ - GAP

        -- Preview square (with checkerboard for alpha)
        local prev_h = BAR_H * 2 + 6  -- covers both bars
        local ca = self._alpha  -- color alpha 0..1
        if ca < 1 then
            -- Checkerboard to indicate transparency
            local csz = 6
            for gy = 0, prev_h - 1, csz do
                for gx = 0, PREVIEW_SZ - 1, csz do
                    local dark = ((math_floor(gx / csz) + math_floor(gy / csz)) % 2 == 0)
                    local cc = dark and 40 or 60
                    local cw = math_min(csz, PREVIEW_SZ - gx)
                    local ch = math_min(csz, prev_h - gy)
                    dl:rect_fill(cx + gx, bot_y + gy, cw, ch, cc, cc, cc, a, 0)
                end
            end
            dl:rect_fill(cx, bot_y, PREVIEW_SZ, prev_h, cr, cg, cb, math_floor(ca * a), 6)
        else
            dl:rect_fill(cx, bot_y, PREVIEW_SZ, prev_h, cr, cg, cb, a, 6)
        end
        dl:rect_stroke(cx, bot_y, PREVIEW_SZ, prev_h, BORDER[1], BORDER[2], BORDER[3], a, 1, 6)

        -- Color/alpha bar (top bar) -" circle-inset columns
        local alpha_cols = math_floor(bar_w)
        local bR = BAR_RAD
        local sqrt = math.sqrt
        dl:rect_fill(bar_x, bot_y, bar_w, BAR_H, 45, 45, 45, a, bR)
        for i = 0, alpha_cols - 1 do
            local t = i / math_max(alpha_cols - 1, 1)
            local ga = math_floor(t * 255)
            local y_inset = 0
            if i < bR then
                local dx = bR - i
                y_inset = math_floor(bR - sqrt(bR * bR - dx * dx) + 0.5)
            elseif i > alpha_cols - bR - 1 then
                local dx = i - (alpha_cols - bR - 1)
                y_inset = math_floor(bR - sqrt(bR * bR - dx * dx) + 0.5)
            end
            local dark = (math_floor(i / 4) % 2 == 0)
            local cc = dark and 35 or 55
            dl:rect_fill(bar_x + i, bot_y + y_inset, 1, BAR_H - y_inset * 2,
                         cc, cc, cc, a, 0)
            if ga > 0 then
                dl:rect_fill(bar_x + i, bot_y + y_inset, 1, BAR_H - y_inset * 2,
                             cr, cg, cb, math_floor(ga * a / 255), 0)
            end
        end
        dl:rect_stroke(bar_x, bot_y, bar_w, BAR_H, BORDER[1], BORDER[2], BORDER[3], a, 1, bR)
        local at_x = bar_x + self._alpha * math_max(bar_w - 1, 1)
        draw_thumb(dl, at_x, bot_y + BAR_H * 0.5, cr, cg, cb, a)

        -- Hue rainbow bar (bottom bar) -" circle-inset columns
        local hue2_y = bot_y + BAR_H + 6
        dl:rect_fill(bar_x, hue2_y, bar_w, BAR_H, 255, 0, 0, a, bR)
        for i = 0, alpha_cols - 1 do
            local h = i / math_max(alpha_cols - 1, 1) * 360
            local rr, rg, rb = hsv_to_rgb(h, 1, 1)
            local y_inset = 0
            if i < bR then
                local dx = bR - i
                y_inset = math_floor(bR - sqrt(bR * bR - dx * dx) + 0.5)
            elseif i > alpha_cols - bR - 1 then
                local dx = i - (alpha_cols - bR - 1)
                y_inset = math_floor(bR - sqrt(bR * bR - dx * dx) + 0.5)
            end
            dl:rect_fill(bar_x + i, hue2_y + y_inset, 1, BAR_H - y_inset * 2,
                         rr, rg, rb, a, 0)
        end
        dl:rect_stroke(bar_x, hue2_y, bar_w, BAR_H, BORDER[1], BORDER[2], BORDER[3], a, 1, bR)
        local ht2_x = bar_x + (self._hue / 360) * math_max(bar_w - 1, 1)
        draw_thumb(dl, ht2_x, hue2_y + BAR_H * 0.5, thr, thg, thb, a)

        -- Hex + Percent fields (editable)
        local hex_y = bot_y + prev_h + GAP
        local hex_w = math_floor(CONTENT_W * 0.65)
        local hex_bdr = self._hex_focused and BORDER_FOCUS or BORDER
        dl:rect_fill(cx, hex_y, hex_w, HEX_H, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, HEX_RAD)
        dl:rect_stroke(cx, hex_y, hex_w, HEX_H, hex_bdr[1], hex_bdr[2], hex_bdr[3],
                       self._hex_focused and a or math_floor(a * 0.5), 1, HEX_RAD)
        local hex_display = self._hex_focused and self._hex_text or value
        -- Selection highlight
        if self._hex_focused and mini_has_sel(self._hex_caret, self._hex_sel) then
            local lo, hi = mini_sel_range(self._hex_caret, self._hex_sel)
            local sx1 = cx + 10 + measure_ui_text(self._hex_text:sub(1, lo), 13)
            local sx2 = cx + 10 + measure_ui_text(self._hex_text:sub(1, hi), 13)
            dl:rect_fill(sx1, hex_y + 5, sx2 - sx1, HEX_H - 10, 51, 102, 204, math_floor(a * 0.7), 0)
        end
        draw_ui_text(dl, hex_display, cx + 10, hex_y + HEX_H * 0.5 - 6, 13,
            TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, false)
        -- Caret
        if self._hex_focused then
            local blink = math_floor((self._blink_timer or 0) * 2) % 2
            if blink == 0 then
                local before_hex = self._hex_text:sub(1, self._hex_caret)
                local caret_x = cx + 10 + measure_ui_text(before_hex, 13)
                dl:rect_fill(caret_x, hex_y + 6, 1, HEX_H - 12,
                             TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, 0)
            end
        end

        local pct_x = cx + hex_w + GAP
        local pct_w = CONTENT_W - hex_w - GAP
        local pct_bdr = self._pct_focused and BORDER_FOCUS or BORDER
        dl:rect_fill(pct_x, hex_y, pct_w, HEX_H, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, HEX_RAD)
        dl:rect_stroke(pct_x, hex_y, pct_w, HEX_H, pct_bdr[1], pct_bdr[2], pct_bdr[3],
                       self._pct_focused and a or math_floor(a * 0.5), 1, HEX_RAD)
        local pct_display = self._pct_focused and self._pct_text
                            or (tostring(math_floor(self._alpha * 100 + 0.5)) .. "%")
        -- Selection highlight
        if self._pct_focused and mini_has_sel(self._pct_caret, self._pct_sel) then
            local lo, hi = mini_sel_range(self._pct_caret, self._pct_sel)
            local sx1 = pct_x + 10 + measure_ui_text(self._pct_text:sub(1, lo), 13)
            local sx2 = pct_x + 10 + measure_ui_text(self._pct_text:sub(1, hi), 13)
            dl:rect_fill(sx1, hex_y + 5, sx2 - sx1, HEX_H - 10, 51, 102, 204, math_floor(a * 0.7), 0)
        end
        draw_ui_text(dl, pct_display, pct_x + 10, hex_y + HEX_H * 0.5 - 6, 13,
            TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, false)
        -- Caret
        if self._pct_focused then
            local blink = math_floor((self._blink_timer or 0) * 2) % 2
            if blink == 0 then
                local before_pct = self._pct_text:sub(1, self._pct_caret)
                local caret_x = pct_x + 10 + measure_ui_text(before_pct, 13)
                dl:rect_fill(caret_x, hex_y + 6, 1, HEX_H - 12,
                             TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, 0)
            end
        end

    -- ===== TAB 2: RGB SLIDERS =====
    elseif self._tab == 2 then
        local sl_x = px + POP_PAD
        local sl_w = CONTENT_W
        local row_h = BAR_H + GAP + 18

        local labels = {"R", "G", "B"}
        local label_colors = {{255, 100, 100}, {100, 255, 100}, {100, 100, 255}}
        local channels = {cr, cg, cb}

        for ch = 1, 3 do
            local by = cy_top + 16 + (ch - 1) * row_h
            -- Label
            draw_ui_text(dl, labels[ch], sl_x, by - 16, 12,
                label_colors[ch][1], label_colors[ch][2], label_colors[ch][3], a, false)
            -- Gradient bar (circle-inset columns to respect rounded corners)
            local val_text_w = 40  -- reserve space for "255" text
            local bar_w2 = sl_w - val_text_w
            local bar_cols = math_floor(bar_w2)
            local bR = BAR_RAD
            local sqrt = math.sqrt
            -- Left-end base color (channel=0) as rounded background
            local base_r = (ch == 1) and 0 or cr
            local base_g = (ch == 2) and 0 or cg
            local base_b = (ch == 3) and 0 or cb
            dl:rect_fill(sl_x, by, bar_w2, BAR_H, base_r, base_g, base_b, a, bR)
            for i = 0, bar_cols - 1 do
                local cv = math_floor(i / math_max(bar_cols - 1, 1) * 255)
                local rr = (ch == 1) and cv or cr
                local gg = (ch == 2) and cv or cg
                local bb = (ch == 3) and cv or cb
                -- Vertical inset near rounded corners
                local y_inset = 0
                if i < bR then
                    local dx = bR - i
                    y_inset = math_floor(bR - sqrt(bR * bR - dx * dx) + 0.5)
                elseif i > bar_cols - bR - 1 then
                    local dx = i - (bar_cols - bR - 1)
                    y_inset = math_floor(bR - sqrt(bR * bR - dx * dx) + 0.5)
                end
                dl:rect_fill(sl_x + i, by + y_inset, 1, BAR_H - y_inset * 2,
                             rr, gg, bb, a, 0)
            end
            dl:rect_stroke(sl_x, by, bar_w2, BAR_H, BORDER[1], BORDER[2], BORDER[3], a, 1, bR)
            -- Thumb
            local tx = sl_x + channels[ch] / 255 * math_max(bar_w2 - 1, 1)
            draw_thumb(dl, tx, by + BAR_H * 0.5, cr, cg, cb, a)
            -- Value text (inside popup bounds)
            draw_ui_text(dl, tostring(channels[ch]), sl_x + bar_w2 + 6, by + 1, 11,
                TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], a, false)
        end

        -- Preview + hex (with checkerboard for alpha)
        local prev_y = cy_top + 16 + 3 * row_h + GAP
        local ca2 = self._alpha
        if ca2 < 1 then
            local csz = 5
            for gy = 0, PREVIEW_SZ - 1, csz do
                for gx = 0, PREVIEW_SZ - 1, csz do
                    local dark = ((math_floor(gx / csz) + math_floor(gy / csz)) % 2 == 0)
                    local cc = dark and 40 or 60
                    dl:rect_fill(sl_x + gx, prev_y + gy, math_min(csz, PREVIEW_SZ - gx), math_min(csz, PREVIEW_SZ - gy), cc, cc, cc, a, 0)
                end
            end
            dl:rect_fill(sl_x, prev_y, PREVIEW_SZ, PREVIEW_SZ, cr, cg, cb, math_floor(ca2 * a), 6)
        else
            dl:rect_fill(sl_x, prev_y, PREVIEW_SZ, PREVIEW_SZ, cr, cg, cb, a, 6)
        end
        dl:rect_stroke(sl_x, prev_y, PREVIEW_SZ, PREVIEW_SZ, BORDER[1], BORDER[2], BORDER[3], a, 1, 6)

        local rgb_text = "R:" .. cr .. "  G:" .. cg .. "  B:" .. cb
        draw_ui_text(dl, rgb_text, sl_x + PREVIEW_SZ + GAP, prev_y + PREVIEW_SZ * 0.5 - 5, 11,
            TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], a, false)

        local hex_y = prev_y + PREVIEW_SZ + GAP
        dl:rect_fill(sl_x, hex_y, CONTENT_W, HEX_H, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, HEX_RAD)
        dl:rect_stroke(sl_x, hex_y, CONTENT_W, HEX_H, BORDER[1], BORDER[2], BORDER[3], math_floor(a * 0.5), 1, HEX_RAD)
        draw_ui_text(dl, value, sl_x + 10, hex_y + HEX_H * 0.5 - 6, 13,
            TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, false)

    -- ===== TAB 3: PALETTES =====
    elseif self._tab == 3 then
        local grid_x = px + POP_PAD
        local grid_y = cy_top
        local pal_cols = 11
        local cell = math_floor(CONTENT_W / pal_cols)

        for i = 1, #PALETTE do
            local col = (i - 1) % pal_cols
            local row = math_floor((i - 1) / pal_cols)
            local cx2 = grid_x + col * cell
            local cy2 = grid_y + row * cell
            local pr, pg, pb = hex_to_rgb(PALETTE[i])
            dl:rect_fill(cx2 + 1, cy2 + 1, cell - 2, cell - 2, pr, pg, pb, a, 4)

            if PALETTE[i]:lower() == value:lower() then
                dl:rect_stroke(cx2, cy2, cell, cell, 255, 255, 255, a, 2, 4)
            end
        end

        local pal_rows = math.ceil(#PALETTE / pal_cols)
        local hex_y = grid_y + pal_rows * cell + GAP
        dl:rect_fill(grid_x, hex_y, CONTENT_W, HEX_H, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, HEX_RAD)
        dl:rect_stroke(grid_x, hex_y, CONTENT_W, HEX_H, BORDER[1], BORDER[2], BORDER[3], math_floor(a * 0.5), 1, HEX_RAD)
        draw_ui_text(dl, value, grid_x + 10, hex_y + HEX_H * 0.5 - 6, 13,
            TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, false)

        local prev_x3 = grid_x + CONTENT_W - PREVIEW_SZ
        local ca3 = self._alpha
        if ca3 < 1 then
            local csz = 4
            for gy = 0, HEX_H - 1, csz do
                for gx = 0, PREVIEW_SZ - 1, csz do
                    local dark = ((math_floor(gx / csz) + math_floor(gy / csz)) % 2 == 0)
                    local cc = dark and 40 or 60
                    dl:rect_fill(prev_x3 + gx, hex_y + gy, math_min(csz, PREVIEW_SZ - gx), math_min(csz, HEX_H - gy), cc, cc, cc, a, 0)
                end
            end
            dl:rect_fill(prev_x3, hex_y, PREVIEW_SZ, HEX_H, cr, cg, cb, math_floor(ca3 * a), HEX_RAD)
        else
            dl:rect_fill(prev_x3, hex_y, PREVIEW_SZ, HEX_H, cr, cg, cb, a, HEX_RAD)
        end

    -- ===== TAB 4: IMAGE EYEDROPPER =====
    elseif self._tab == 4 then
        local ex = px + POP_PAD
        local ew = CONTENT_W

        -- URL field
        local url_y = cy_top
        local url_h = HEX_H
        local focused = self._url_focused
        dl:rect_fill(ex, url_y, ew, url_h, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, HEX_RAD)
        local bdr = focused and BORDER_FOCUS or BORDER
        dl:rect_stroke(ex, url_y, ew, url_h, bdr[1], bdr[2], bdr[3], a, 1, HEX_RAD)

        local url_text_y = url_y + url_h * 0.5 - 6
        local url_pad = 12
        local url_font = 12
        local url_inner_w = ew - url_pad * 2
        if self._img_url == "" then
            draw_ui_text(dl, "Paste image URL + Enter", ex + url_pad, url_text_y, url_font,
                TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], a, false)
        else
            -- Clip text to field bounds, draw with scroll offset
            dl:clip_push(ex + url_pad, url_y, url_inner_w, url_h)
            -- Selection highlight
            if focused and mini_has_sel(self._img_caret, self._url_sel) then
                local lo, hi = mini_sel_range(self._img_caret, self._url_sel)
                local sx1 = ex + url_pad + measure_ui_text(self._img_url:sub(1, lo), url_font) - self._url_scroll_x
                local sx2 = ex + url_pad + measure_ui_text(self._img_url:sub(1, hi), url_font) - self._url_scroll_x
                dl:rect_fill(sx1, url_y + 5, sx2 - sx1, url_h - 10, 51, 102, 204, math_floor(a * 0.7), 0)
            end
            draw_ui_text(dl, self._img_url, ex + url_pad - self._url_scroll_x, url_text_y, url_font,
                TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, false)
            dl:clip_pop()
        end

        -- Caret (pixel-accurate via platform measurement)
        if focused then
            local blink = math_floor((self._blink_timer or 0) * 2) % 2
            if blink == 0 then
                local before_url = self._img_url:sub(1, self._img_caret)
                local w_before = measure_ui_text(before_url, url_font)
                local caret_x = ex + url_pad + w_before - self._url_scroll_x
                dl:rect_fill(caret_x, url_y + 6, 1, url_h - 12,
                             TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, 0)
            end
        end

        -- Image area
        local img_y = url_y + url_h + GAP
        local img_h = 192
        dl:rect_fill(ex, img_y, ew, img_h, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, SV_RAD)

        if self._img_status == "idle" then
            draw_ui_text(dl, "No image loaded", ex + ew * 0.5 - measure_ui_text("No image loaded", 12) * 0.5,
                img_y + img_h * 0.5 - 5, 12, TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], a, false)
        elseif self._img_status == "loading" then
            draw_ui_text(dl, "Loading...", ex + ew * 0.5 - measure_ui_text("Loading...", 12) * 0.5,
                img_y + img_h * 0.5 - 5, 12, 70, 130, 220, a, false)
        elseif self._img_status == "ready" and self._img_entry then
            local entry = self._img_entry
            local iw = entry.rgba_w or entry.w or 1
            local ih = entry.rgba_h or entry.h or 1
            local scale = math_min(ew / iw, img_h / ih, 1) * self._img_zoom
            local disp_w = math_floor(iw * scale)
            local disp_h = math_floor(ih * scale)
            local disp_x = math_floor(ex + (ew - disp_w) / 2 + self._img_scroll_x)
            local disp_y = math_floor(img_y + (img_h - disp_h) / 2 + self._img_scroll_y)
            dl:clip_push(ex, img_y, ew, img_h)
            dl:image(entry.tex_id, disp_x, disp_y, disp_w, disp_h, 255, 255, 255, a)
            dl:clip_pop()
        end

        dl:rect_stroke(ex, img_y, ew, img_h, BORDER[1], BORDER[2], BORDER[3], math_floor(a * 0.5), 1, SV_RAD)

        -- Preview row
        local prev_y = img_y + img_h + GAP
        dl:rect_fill(ex, prev_y, PREVIEW_SZ, HEX_H,
                     self._pick_r, self._pick_g, self._pick_b, a, 6)
        dl:rect_stroke(ex, prev_y, PREVIEW_SZ, HEX_H, BORDER[1], BORDER[2], BORDER[3], a, 1, 6)

        local pick_hex = rgb_to_hex(self._pick_r, self._pick_g, self._pick_b)
        local hex_x = ex + PREVIEW_SZ + GAP
        local hex_fw = ew - PREVIEW_SZ - GAP
        dl:rect_fill(hex_x, prev_y, hex_fw, HEX_H, BG_DARKER[1], BG_DARKER[2], BG_DARKER[3], a, HEX_RAD)
        dl:rect_stroke(hex_x, prev_y, hex_fw, HEX_H, BORDER[1], BORDER[2], BORDER[3], math_floor(a * 0.5), 1, HEX_RAD)
        draw_ui_text(dl, pick_hex, hex_x + 10, prev_y + HEX_H * 0.5 - 6, 13,
            TEXT_PRIMARY[1], TEXT_PRIMARY[2], TEXT_PRIMARY[3], a, false)
        draw_ui_text(dl, "R:" .. self._pick_r .. " G:" .. self._pick_g .. " B:" .. self._pick_b,
            hex_x + 90, prev_y + HEX_H * 0.5 - 5, 11,
            TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], a, false)
    end
end

return InputColor



