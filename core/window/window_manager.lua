------------------------------------------------------------
-- ext_core_astro_ui_lib / core / window / window_manager.lua
-- Self-drawn window chrome: title bar, border, close button,
-- edge/corner resize with hover glow, z-order, drag,
-- screen clamping, and geometry persistence.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local helpers = require("core/util/helpers")
local json    = require("core/util/json")

local WindowManager = {}
WindowManager.__index = WindowManager
local Painters = require("core/paint/painters")

------------------------------------------------------------
-- Chrome constants
------------------------------------------------------------
local TITLE_BAR_HEIGHT  = 24
local CLOSE_BUTTON_SIZE = 16
local EDGE_ZONE         = 4   -- px from border for edge resize detection
local CORNER_ZONE       = 14  -- px from corner for corner resize detection

-- Expose for external use
WindowManager.TITLE_BAR_HEIGHT  = TITLE_BAR_HEIGHT
WindowManager.CLOSE_BUTTON_SIZE = CLOSE_BUTTON_SIZE
WindowManager.EDGE_ZONE         = EDGE_ZONE
WindowManager.CORNER_ZONE       = CORNER_ZONE

------------------------------------------------------------
-- Default window chrome colors (r, g, b, a)
-- Override via WindowManager:set_theme({ key = {r,g,b,a}, ... })
------------------------------------------------------------
local DEFAULT_COLORS = {
    title_bar        = { 229, 229, 229, 255 },
    title_bar_active = { 238, 238, 238, 255 },
    title_text       = { 32,  33,  36, 255 },
    border           = { 0,   0,   0, 255 },
    close_bg         = { 180, 50,  50, 255 },
    close_fg         = { 255, 255, 255, 255 },
    background       = { 255, 255, 255, 255 },
    edge_glow        = { 26, 115, 232 },          -- Chrome-like blue focus/resize hint
}

local function round_px(v)
    v = tonumber(v) or 0
    return math.floor(v + 0.5)
end

local function snap_window_geometry(win)
    win.x = round_px(win.x)
    win.y = round_px(win.y)
    win.w = round_px(win.w)
    win.h = round_px(win.h)
end

------------------------------------------------------------
-- Persistence path
------------------------------------------------------------
local GEOMETRY_FOLDER = "astro_ui"
local GEOMETRY_FILE   = "astro_ui/window_geometry.json"

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

function WindowManager.new()
    local self = setmetatable({}, WindowManager)

    -- Ordered array of window objects, index 1 = back, last = front.
    self._windows = {}

    -- Lookup: id -> window
    self._by_id = {}

    -- Active theme (starts as a copy of defaults)
    self._colors = {}
    for k, v in pairs(DEFAULT_COLORS) do
        self._colors[k] = v
    end

    -- Drag / resize state
    self._drag = nil

    -- Hover state (updated every frame for glow painting)
    self._hover = nil

    -- Screen bounds (set by engine via set_screen_size)
    self._screen_w = 0
    self._screen_h = 0

    -- Explicit focus: only set by a mouse-down landing inside a window.
    -- Keyboard capture is gated on this (not on hover) so typing in WoW
    -- isn't stolen just because the cursor happens to pass over a window
    -- that has a previously-focused input.
    self._focused_win_id = nil

    return self
end

--- Return the id of the window that currently has focus (last clicked),
--- or nil if no window is focused (user clicked outside).
function WindowManager:get_focused_window_id()
    return self._focused_win_id
end

--- Override one or more chrome colors.
--- Only provided keys are changed; the rest keep their current value.
---@param overrides table  e.g. { edge_glow = {49,195,255}, border = {80,80,90,255} }
function WindowManager:set_theme(overrides)
    if type(overrides) ~= "table" then return end
    for k, v in pairs(overrides) do
        if DEFAULT_COLORS[k] then
            self._colors[k] = v
        end
    end
end

--- Reset all chrome colors back to defaults.
function WindowManager:reset_theme()
    for k, v in pairs(DEFAULT_COLORS) do
        self._colors[k] = v
    end
end

--- Set the screen dimensions for window clamping.
function WindowManager:set_screen_size(w, h)
    self._screen_w = round_px(w or 0)
    self._screen_h = round_px(h or 0)
end

--- Clamp a window so it stays fully within the screen bounds.
function WindowManager:_clamp_to_screen(win)
    snap_window_geometry(win)

    local sw, sh = self._screen_w, self._screen_h
    if sw <= 0 or sh <= 0 then return end

    if win.w > sw then win.w = sw end
    if win.h > sh then win.h = sh end
    if win.x < 0 then win.x = 0 end
    if win.y < 0 then win.y = 0 end
    if win.x + win.w > sw then win.x = sw - win.w end
    if win.y + win.h > sh then win.y = sh - win.h end
    snap_window_geometry(win)
end

------------------------------------------------------------
-- Edge/corner hit detection
------------------------------------------------------------

--- Determine which resize zone the cursor is in for a window.
--- Returns zone string ("n","s","e","w","ne","nw","se","sw")
--- or nil if not in any resize zone.
local function _detect_resize_zone(win, mx, my)
    local x, y, w, h = win.x, win.y, win.w, win.h
    local cz = CORNER_ZONE
    local ez = EDGE_ZONE

    -- Corners use a larger zone for easier grabbing
    -- Check corners first (they take priority over edges)
    -- Top-left corner
    if mx >= x - ez and mx < x + cz and my >= y - ez and my < y + cz then
        return "nw"
    end
    -- Top-right corner
    if mx > x + w - cz and mx <= x + w + ez and my >= y - ez and my < y + cz then
        return "ne"
    end
    -- Bottom-left corner
    if mx >= x - ez and mx < x + cz and my > y + h - cz and my <= y + h + ez then
        return "sw"
    end
    -- Bottom-right corner
    if mx > x + w - cz and mx <= x + w + ez and my > y + h - cz and my <= y + h + ez then
        return "se"
    end

    -- Edges use a narrower zone (only the border strip)
    local on_left   = (mx >= x - ez and mx < x + ez)
    local on_right  = (mx > x + w - ez and mx <= x + w + ez)
    local on_top    = (my >= y - ez and my < y + ez)
    local on_bottom = (my > y + h - ez and my <= y + h + ez)

    if on_top    and mx >= x and mx <= x + w then return "n" end
    if on_bottom and mx >= x and mx <= x + w then return "s" end
    if on_left   and my >= y and my <= y + h then return "w" end
    if on_right  and my >= y and my <= y + h then return "e" end

    return nil
end

------------------------------------------------------------
-- Window creation
------------------------------------------------------------

function WindowManager:create_window(config)
    local win = {
        id        = config.id or ("win_" .. tostring(#self._windows + 1)),
        title     = config.title or "Window",
        x         = config.x or 100,
        y         = config.y or 100,
        w         = config.w or 400,
        h         = config.h or 300,
        min_w     = config.min_w or 120,
        min_h     = config.min_h or 80,
        max_w     = config.max_w,               -- optional upper bound
        max_h     = config.max_h,
        visible   = config.visible ~= false,
        resizable = config.resizable ~= false,
        closable  = config.closable ~= false,
        minimizable = config.minimizable ~= false,
        maximizable = config.maximizable ~= false,
        minimized = false,
        maximized = false,
        _pre_state = nil,   -- saved {x,y,w,h} before minimize/maximize
        _mounted_bundle = nil,
        _dirty          = "all",
        _state          = {},
    }

    self._windows[#self._windows + 1] = win
    self._by_id[win.id] = win
    self:_clamp_to_screen(win)
    return win
end

------------------------------------------------------------
-- Lookup / z-order
------------------------------------------------------------

function WindowManager:get_window(win_id)
    return self._by_id[win_id]
end

--- Toggle minimized: when on, only the title bar is shown (height collapses).
---@param win_id string
function WindowManager:toggle_minimize(win_id)
    local win = self._by_id[win_id]
    if not win or not win.minimizable then return end
    if win.minimized then
        local s = win._pre_state
        if s and s.min_h_pre then win.h = s.min_h_pre end
        win.minimized = false
    else
        win._pre_state = win._pre_state or {}
        win._pre_state.min_h_pre = win.h
        win.h = TITLE_BAR_HEIGHT
        win.minimized = true
    end
    self:_clamp_to_screen(win)
end

--- Toggle maximized: grow to screen bounds (respecting max_w / max_h caps
--- declared by the author). A second call restores the previous geometry.
---@param win_id string
function WindowManager:toggle_maximize(win_id)
    local win = self._by_id[win_id]
    if not win or not win.maximizable then return end
    if win.maximized then
        local s = win._pre_state
        if s then win.x, win.y, win.w, win.h = s.x or win.x, s.y or win.y, s.w or win.w, s.h or win.h end
        win.maximized = false
    else
        win._pre_state = { x = win.x, y = win.y, w = win.w, h = win.h }
        local target_w = self._screen_w > 0 and self._screen_w or win.w
        local target_h = self._screen_h > 0 and self._screen_h or win.h
        if win.max_w and win.max_w < target_w then target_w = win.max_w end
        if win.max_h and win.max_h < target_h then target_h = win.max_h end
        win.x = 0; win.y = 0
        win.w = target_w; win.h = target_h
        win.maximized = true
        win.minimized = false
    end
    self:_clamp_to_screen(win)
end

function WindowManager:bring_to_front(win_id)
    local windows = self._windows
    for i = 1, #windows do
        if windows[i].id == win_id then
            local win = table.remove(windows, i)
            windows[#windows + 1] = win
            return
        end
    end
end

function WindowManager:get_windows()
    return self._windows
end

--- Return the front-most visible window under a point.
function WindowManager:_hit_test(px, py)
    local windows = self._windows
    for i = #windows, 1, -1 do
        local win = windows[i]
        if win.visible then
            if px >= win.x and px < win.x + win.w
               and py >= win.y and py < win.y + win.h then
                return win
            end
        end
    end
    return nil
end

--- Return the front-most visible window whose resize zone
--- the cursor is in (searches slightly outside window bounds).
function WindowManager:_hit_test_resize(px, py)
    local windows = self._windows
    for i = #windows, 1, -1 do
        local win = windows[i]
        if win.visible and win.resizable and not win.minimized then
            local zone = _detect_resize_zone(win, px, py)
            if zone then
                return win, zone
            end
        end
    end
    return nil, nil
end

------------------------------------------------------------
-- Content rect
------------------------------------------------------------

function WindowManager:get_content_rect(win)
    local cx = win.x + 1
    local cy = win.y + TITLE_BAR_HEIGHT
    local cw = win.w - 2
    local ch = win.h - TITLE_BAR_HEIGHT - 1
    if cw < 0 then cw = 0 end
    if ch < 0 then ch = 0 end
    return cx, cy, cw, ch
end

------------------------------------------------------------
-- Update (input handling)
------------------------------------------------------------

--- Apply resize drag delta to a window based on the drag zone.
local function _apply_resize(win, d, mx, my)
    local dx = mx - d.ox
    local dy = my - d.oy
    local zone = d.zone

    -- East component: grow width
    if zone == "e" or zone == "se" or zone == "ne" then
        win.w = math.max(win.min_w, d.ow + dx)
    end
    -- West component: move x + shrink width
    if zone == "w" or zone == "sw" or zone == "nw" then
        local new_w = d.ow - dx
        if new_w < win.min_w then
            win.x = d.orig_x + d.ow - win.min_w
            win.w = win.min_w
        else
            win.x = d.orig_x + dx
            win.w = new_w
        end
    end
    -- South component: grow height
    if zone == "s" or zone == "se" or zone == "sw" then
        win.h = math.max(win.min_h, d.oh + dy)
    end
    -- North component: move y + shrink height
    if zone == "n" or zone == "ne" or zone == "nw" then
        local new_h = d.oh - dy
        if new_h < win.min_h then
            win.y = d.orig_y + d.oh - win.min_h
            win.h = win.min_h
        else
            win.y = d.orig_y + dy
            win.h = new_h
        end
    end
end

function WindowManager:update(input)
    local mx, my = input.cursor_x, input.cursor_y
    local mouse_down    = input:is_mouse_down()
    local mouse_clicked = input:is_mouse_clicked()

    -- Update hover state every frame (for glow painting)
    if not self._drag then
        local hover_win, hover_zone = self:_hit_test_resize(mx, my)
        if hover_win then
            self._hover = { win_id = hover_win.id, zone = hover_zone }
        else
            self._hover = nil
        end
    end

    -- Handle ongoing drag / resize
    if self._drag then
        if mouse_down then
            local d   = self._drag
            local win = self._by_id[d.win_id]
            if win then
                if d.mode == "move" then
                    win.x = round_px(mx - d.ox)
                    win.y = round_px(my - d.oy)
                else
                    _apply_resize(win, d, mx, my)
                end
                self:_clamp_to_screen(win)
            end
            return true
        else
            self._drag = nil
            return false
        end
    end

    -- No drag active: check for new interactions on click
    if not mouse_clicked then
        return false
    end

    -- Check resize zones FIRST (they extend slightly outside the window)
    local rz_win, rz_zone = self:_hit_test_resize(mx, my)
    if rz_win and rz_zone then
        -- Don't start resize from the title bar area (top edge overlaps)
        local in_title = (my >= rz_win.y and my < rz_win.y + TITLE_BAR_HEIGHT)
        local is_top_edge = (rz_zone == "n" or rz_zone == "ne" or rz_zone == "nw")
        if not (in_title and is_top_edge) then
            self:bring_to_front(rz_win.id)
            self._focused_win_id = rz_win.id
            self._drag = {
                win_id = rz_win.id,
                mode   = "resize",
                zone   = rz_zone,
                ox     = mx,
                oy     = my,
                ow     = rz_win.w,
                oh     = rz_win.h,
                orig_x = rz_win.x,
                orig_y = rz_win.y,
            }
            return true
        end
    end

    local hit_win = self:_hit_test(mx, my)
    if not hit_win then
        -- Click landed outside any window: unfocus so keyboard goes to the
        -- underlying game and any remaining focused input stops capturing.
        self._focused_win_id = nil
        return false
    end

    -- Bring clicked window to front + mark it focused
    self:bring_to_front(hit_win.id)
    self._focused_win_id = hit_win.id

    -- Title-bar buttons, right-aligned: [min] [max] [X]
    local btn_y = math.floor(hit_win.y + (TITLE_BAR_HEIGHT - CLOSE_BUTTON_SIZE) / 2)
    local btn_stride = CLOSE_BUTTON_SIZE + 4
    local cb_x = hit_win.x + hit_win.w - btn_stride
    local max_x = cb_x - btn_stride
    local min_x = max_x - btn_stride

    -- Close button
    if hit_win.closable
       and mx >= cb_x and mx < cb_x + CLOSE_BUTTON_SIZE
       and my >= btn_y and my < btn_y + CLOSE_BUTTON_SIZE then
        hit_win.visible = false
        if self._focused_win_id == hit_win.id then
            self._focused_win_id = nil
        end
        return true
    end
    -- Maximize / restore button
    if hit_win.maximizable
       and mx >= max_x and mx < max_x + CLOSE_BUTTON_SIZE
       and my >= btn_y and my < btn_y + CLOSE_BUTTON_SIZE then
        self:toggle_maximize(hit_win.id)
        return true
    end
    -- Minimize / restore button
    if hit_win.minimizable
       and mx >= min_x and mx < min_x + CLOSE_BUTTON_SIZE
       and my >= btn_y and my < btn_y + CLOSE_BUTTON_SIZE then
        self:toggle_minimize(hit_win.id)
        return true
    end

    -- Check title bar (drag to move)
    if my >= hit_win.y and my < hit_win.y + TITLE_BAR_HEIGHT then
        self._drag = {
            win_id = hit_win.id,
            mode   = "move",
            ox     = mx - hit_win.x,
            oy     = my - hit_win.y,
        }
        return true
    end

    -- Click inside window content area
    return true
end

------------------------------------------------------------
-- Painting
------------------------------------------------------------

function WindowManager:paint_chrome(dl, win)
    self:paint_chrome_bg(dl, win)
    self:paint_chrome_fg(dl, win)
end

function WindowManager:paint_chrome_bg(dl, win)
    if not win.visible then return end
    local x, y, w, h = round_px(win.x), round_px(win.y), round_px(win.w), round_px(win.h)
    local c = self._colors

    dl:rect_fill(x, y, w, h,
        c.background[1], c.background[2],
        c.background[3], c.background[4], 0)
end

function WindowManager:paint_chrome_fg(dl, win)
    if not win.visible then return end

    local x, y, w, h = round_px(win.x), round_px(win.y), round_px(win.w), round_px(win.h)
    local is_front = (self._windows[#self._windows] == win)
    local c = self._colors

    -- Title bar
    local tb = is_front and c.title_bar_active or c.title_bar
    dl:rect_fill(x, y, w, TITLE_BAR_HEIGHT,
        tb[1], tb[2], tb[3], tb[4], 0)

    -- Title text
    Painters.paint_text(dl, win.title, x + 8, y + 4, 13,
        c.title_text[1], c.title_text[2],
        c.title_text[3], c.title_text[4],
        false, Painters._default_font or "inter", 400, "normal")

    -- Bottom border line
    dl:rect_fill(x, y + h - 1, w, 1,
        c.background[1], c.background[2], c.background[3], 255, 0)

    -- Title-bar buttons right-aligned: [min] [max] [X]
    local btn_y = math.floor(y + (TITLE_BAR_HEIGHT - CLOSE_BUTTON_SIZE) / 2)
    local btn_stride = CLOSE_BUTTON_SIZE + 4
    local cb_x = x + w - btn_stride
    local max_x = cb_x - btn_stride
    local min_x = max_x - btn_stride
    local pad = 4

    if win.closable then
        dl:rect_fill(cb_x, btn_y, CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE,
            c.close_bg[1], c.close_bg[2], c.close_bg[3], c.close_bg[4], 2)
        dl:line(cb_x + pad, btn_y + pad,
                cb_x + CLOSE_BUTTON_SIZE - pad - 1, btn_y + CLOSE_BUTTON_SIZE - pad - 1,
                c.close_fg[1], c.close_fg[2], c.close_fg[3], c.close_fg[4], 2)
        dl:line(cb_x + CLOSE_BUTTON_SIZE - pad - 1, btn_y + pad,
                cb_x + pad, btn_y + CLOSE_BUTTON_SIZE - pad - 1,
                c.close_fg[1], c.close_fg[2], c.close_fg[3], c.close_fg[4], 2)
    end

    if win.maximizable then
        dl:rect_fill(max_x, btn_y, CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE,
            245, 245, 245, 200, 2)
        if win.maximized then
            -- Restore icon: two offset squares
            dl:rect_stroke(max_x + 3, btn_y + 2, 9, 9, 32, 33, 36, 255, 1, 1)
            dl:rect_fill(max_x + 5, btn_y + 5, 8, 8, 245, 245, 245, 255, 1)
            dl:rect_stroke(max_x + 5, btn_y + 5, 8, 8, 32, 33, 36, 255, 1, 1)
        else
            -- Maximize icon: square outline
            dl:rect_stroke(max_x + 3, btn_y + 3, CLOSE_BUTTON_SIZE - 6, CLOSE_BUTTON_SIZE - 6,
                32, 33, 36, 255, 1, 1)
        end
    end

    if win.minimizable then
        dl:rect_fill(min_x, btn_y, CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE,
            245, 245, 245, 200, 2)
        -- Minimize icon: bottom horizontal bar
        local by = btn_y + CLOSE_BUTTON_SIZE - 5
        dl:rect_fill(min_x + 3, by, CLOSE_BUTTON_SIZE - 6, 2,
            32, 33, 36, 255, 0)
    end

    -- Border
    dl:rect_stroke(x, y, w, h,
        c.border[1], c.border[2],
        c.border[3], c.border[4], 1, 0)

    -- Edge/corner hover glow (radiates outward from the border)
    if win.resizable and self._hover and self._hover.win_id == win.id then
        local zone = self._hover.zone
        local gr, gg, gb = c.edge_glow[1], c.edge_glow[2], c.edge_glow[3]

        local glow_n = (zone == "n" or zone == "ne" or zone == "nw")
        local glow_s = (zone == "s" or zone == "se" or zone == "sw")
        local glow_w = (zone == "w" or zone == "nw" or zone == "sw")
        local glow_e = (zone == "e" or zone == "ne" or zone == "se")

        -- Core: bright line on the border itself
        if glow_n then dl:rect_fill(x, y, w, 1, gr, gg, gb, 90, 0) end
        if glow_s then dl:rect_fill(x, y + h - 1, w, 1, gr, gg, gb, 90, 0) end
        if glow_w then dl:rect_fill(x, y, 1, h, gr, gg, gb, 90, 0) end
        if glow_e then dl:rect_fill(x + w - 1, y, 1, h, gr, gg, gb, 90, 0) end

        -- Outer glow: 5 layers radiating outward, smooth fade
        local outer = { 65, 42, 25, 14, 6 }
        for i = 1, #outer do
            local a = outer[i]
            if glow_n then dl:rect_fill(x - i, y - i, w + i * 2, 1, gr, gg, gb, a, 0) end
            if glow_s then dl:rect_fill(x - i, y + h - 1 + i, w + i * 2, 1, gr, gg, gb, a, 0) end
            if glow_w then dl:rect_fill(x - i, y - i, 1, h + i * 2, gr, gg, gb, a, 0) end
            if glow_e then dl:rect_fill(x + w - 1 + i, y - i, 1, h + i * 2, gr, gg, gb, a, 0) end
        end

        -- Inner glow: 2 layers inside the border, subtle
        local inner = { 55, 25 }
        for i = 1, #inner do
            local a = inner[i]
            if glow_n then dl:rect_fill(x, y + i, w, 1, gr, gg, gb, a, 0) end
            if glow_s then dl:rect_fill(x, y + h - 1 - i, w, 1, gr, gg, gb, a, 0) end
            if glow_w then dl:rect_fill(x + i, y, 1, h, gr, gg, gb, a, 0) end
            if glow_e then dl:rect_fill(x + w - 1 - i, y, 1, h, gr, gg, gb, a, 0) end
        end
    end
end

------------------------------------------------------------
-- Geometry persistence
------------------------------------------------------------

function WindowManager:save_geometry(platform)
    local data = {}
    for i = 1, #self._windows do
        local win = self._windows[i]
        data[win.id] = {
            x = win.x,
            y = win.y,
            w = win.w,
            h = win.h,
            visible = win.visible,
        }
    end
    local encoded = json.encode(data)
    if encoded then
        platform:create_data_folder(GEOMETRY_FOLDER)
        platform:write_data_file(GEOMETRY_FILE, encoded)
    end
end

function WindowManager:load_geometry(platform)
    local raw = platform:read_data_file(GEOMETRY_FILE)
    if not raw or raw == "" then return end

    local data = json.decode(raw)
    if type(data) ~= "table" then return end

    for i = 1, #self._windows do
        local win = self._windows[i]
        local saved = data[win.id]
        if type(saved) == "table" then
            if type(saved.x) == "number" then win.x = saved.x end
            if type(saved.y) == "number" then win.y = saved.y end
            if type(saved.w) == "number" then
                win.w = math.max(win.min_w, saved.w)
            end
            if type(saved.h) == "number" then
                win.h = math.max(win.min_h, saved.h)
            end
            if type(saved.visible) == "boolean" then
                win.visible = saved.visible
            end
            self:_clamp_to_screen(win)
        end
    end
end

return WindowManager



