------------------------------------------------------------
-- ext_core_astro_ui_lib / core / context_menu.lua
-- Window-independent right-click context menu overlay.
-- Renders directly to the display list AFTER all windows,
-- so it is never clipped by window bounds.
--
-- Performance: zero cost when closed (single nil check).
-- When open: a few rect_fill + text calls, no DOM/style/layout.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local Utf8 = require("core/util/utf8")
local Painters = require("core/paint/painters")

local ContextMenu = {}
ContextMenu.__index = ContextMenu

------------------------------------------------------------
-- Visual constants
------------------------------------------------------------
local FONT_SIZE     = 13
local ITEM_PAD_X    = 20
local ITEM_PAD_Y    = 5
local ITEM_HEIGHT   = FONT_SIZE + ITEM_PAD_Y * 2
local SEP_HEIGHT    = 9
local MIN_WIDTH     = 140
local BORDER_RADIUS = 2
local SHADOW_OFFSET = 3
local SHORTCUT_GAP  = 30  -- gap between label and shortcut text

-- Colors: light browser/Windows-style context menu.
local BG_R, BG_G, BG_B, BG_A       = 255, 255, 255, 255
local BORDER_R, BORDER_G, BORDER_B  = 204, 204, 204
local HOVER_R, HOVER_G, HOVER_B     = 229, 241, 251
local TEXT_R, TEXT_G, TEXT_B         = 0, 0, 0
local DIS_R, DIS_G, DIS_B           = 128, 128, 128
local SEP_R, SEP_G, SEP_B           = 229, 229, 229
local SHADOW_R, SHADOW_G, SHADOW_B  = 0, 0, 0

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

function ContextMenu.new()
    local self = setmetatable({}, ContextMenu)
    self._state = nil  -- nil = closed, table = open state
    return self
end

------------------------------------------------------------
-- Open / Close
------------------------------------------------------------

--- Open the context menu at screen coordinates.
--- Items: array of { label=string, action=fn, disabled=bool, shortcut=string }
---        or { separator=true }
--- screen_w/screen_h: used for edge-aware positioning.
--- font_manager, default_font: for text width measurement.
function ContextMenu:open(mx, my, items, screen_w, screen_h, font_manager, default_font)
    if not items or #items == 0 then
        self._state = nil
        return
    end

    -- Measure item widths to determine menu width
    local max_label_w = 0
    local max_shortcut_w = 0
    local total_h = 0
    for i = 1, #items do
        local item = items[i]
        if item.separator then
            total_h = total_h + SEP_HEIGHT
        else
            total_h = total_h + ITEM_HEIGHT
            local label_w = self:_measure(item.label or "", font_manager, default_font)
            if label_w > max_label_w then max_label_w = label_w end
            if item.shortcut then
                local sw = self:_measure(item.shortcut, font_manager, default_font)
                if sw > max_shortcut_w then max_shortcut_w = sw end
            end
        end
    end

    local menu_w = max_label_w + ITEM_PAD_X * 2
    if max_shortcut_w > 0 then
        menu_w = menu_w + SHORTCUT_GAP + max_shortcut_w
    end
    if menu_w < MIN_WIDTH then menu_w = MIN_WIDTH end

    -- Edge-aware positioning
    local x, y = mx, my
    if x + menu_w > screen_w then
        x = mx - menu_w
        if x < 0 then x = 0 end
    end
    if y + total_h > screen_h then
        y = my - total_h
        if y < 0 then y = 0 end
    end

    -- Precompute shortcut x-offsets (avoid per-frame measurement)
    local shortcut_x = {}
    for i = 1, #items do
        local item = items[i]
        if not item.separator and item.shortcut then
            local sw = self:_measure(item.shortcut, font_manager, default_font)
            shortcut_x[i] = x + menu_w - ITEM_PAD_X - sw
        end
    end

    self._state = {
        x          = x,
        y          = y,
        w          = menu_w,
        h          = total_h,
        items      = items,
        hover_idx  = 0,
        shortcut_x = shortcut_x,
        default_font = default_font or "inter",
    }
end

--- Close the context menu.
function ContextMenu:close()
    self._state = nil
end

--- Is the context menu currently open?
function ContextMenu:is_open()
    return self._state ~= nil
end

------------------------------------------------------------
-- Update (interaction handling)
------------------------------------------------------------

--- Process input. Returns two values:
---   action_fn, consumed_click
--- action_fn: function to call if an item was clicked, or nil.
--- consumed_click: true if a click was consumed (item click or dismiss).
--- Call BEFORE dispatching events to windows so the menu can consume clicks.
function ContextMenu:update(input_state)
    local s = self._state
    if not s then return nil, false end

    local mx = input_state.cursor_x
    local my = input_state.cursor_y

    -- Update hover index
    s.hover_idx = 0
    if mx >= s.x and mx < s.x + s.w and my >= s.y and my < s.y + s.h then
        -- Find which item is under cursor
        local cy = s.y
        for i = 1, #s.items do
            local item = s.items[i]
            local ih = item.separator and SEP_HEIGHT or ITEM_HEIGHT
            if my >= cy and my < cy + ih then
                if not item.separator and not item.disabled then
                    s.hover_idx = i
                end
                break
            end
            cy = cy + ih
        end
    end

    -- Left click
    if input_state:is_mouse_clicked() then
        if s.hover_idx > 0 then
            local action = s.items[s.hover_idx].action
            self:close()
            return action, true
        else
            -- Clicked outside or on disabled/separator: dismiss and consume click
            self:close()
            return nil, true
        end
    end

    -- Escape closes
    if input_state:is_key_edge(0x1B) then
        self:close()
        return nil, true
    end

    return nil, false
end

--- Check if cursor is over the open menu (for blocking pass-through).
function ContextMenu:hit_test(mx, my)
    local s = self._state
    if not s then return false end
    return mx >= s.x and mx < s.x + s.w
       and my >= s.y and my < s.y + s.h
end

------------------------------------------------------------
-- Paint
------------------------------------------------------------

--- Render the context menu overlay. Call AFTER all windows are painted.
function ContextMenu:paint(dl)
    local s = self._state
    if not s then return end

    local x, y, w, h = s.x, s.y, s.w, s.h

    -- Shadow
    dl:rect_fill(x + SHADOW_OFFSET, y + SHADOW_OFFSET, w, h,
                 SHADOW_R, SHADOW_G, SHADOW_B, 80, BORDER_RADIUS)

    -- Background
    dl:rect_fill(x, y, w, h, BG_R, BG_G, BG_B, BG_A, BORDER_RADIUS)

    -- Border
    dl:rect_stroke(x, y, w, h, BORDER_R, BORDER_G, BORDER_B, 255, 1, BORDER_RADIUS)

    -- Items
    local iy = y
    for i = 1, #s.items do
        local item = s.items[i]

        if item.separator then
            -- Separator line
            local sep_y = iy + math.floor(SEP_HEIGHT / 2)
            dl:rect_fill(x + 8, sep_y, w - 16, 1, SEP_R, SEP_G, SEP_B, 255, 0)
            iy = iy + SEP_HEIGHT
        else
            -- Hover highlight
            if i == s.hover_idx then
                dl:rect_fill(x + 1, iy + 1, w - 2, ITEM_HEIGHT - 2,
                             HOVER_R, HOVER_G, HOVER_B, 255, 0)
            end

            -- Label text
            local tr, tg, tb = TEXT_R, TEXT_G, TEXT_B
            if item.disabled then
                tr, tg, tb = DIS_R, DIS_G, DIS_B
            end
            Painters.paint_text(dl, item.label or "", x + ITEM_PAD_X, iy + ITEM_PAD_Y,
                FONT_SIZE, tr, tg, tb, 255, false, s.default_font, 400, "normal")

            -- Shortcut text (right-aligned, x precomputed in open())
            if item.shortcut and s.shortcut_x[i] then
                Painters.paint_text(dl, item.shortcut, s.shortcut_x[i], iy + ITEM_PAD_Y,
                    FONT_SIZE, DIS_R, DIS_G, DIS_B, 255, false, s.default_font, 400, "normal")
            end

            iy = iy + ITEM_HEIGHT
        end
    end
end

------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------

--- Measure text width using font manager.
function ContextMenu:_measure(text, font_manager, default_font)
    if not text or text == "" then return 0 end
    if font_manager then
        local cache = font_manager:get_cache_for(default_font or "inter", 400)
        if cache then
            return cache:measure_text(text, FONT_SIZE, Utf8)
        end
    end
    return #text * 7  -- fallback: rough estimate
end

return ContextMenu



