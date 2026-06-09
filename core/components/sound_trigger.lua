------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / sound_trigger.lua
-- <sound> tag: plays game sounds through the platform adapter.
--
-- Attributes:
--   sound_id  (number)  -" WoW SoundKit ID to play
--   trigger   (string)  -" when to play: "click" | "hover" | "mousedown" | "mouseup"
--   cooldown  (number)  -" min seconds between plays (default 0.15)
--
-- Usage (Builder DSL):
--   B.sound({ sound_id = 888, trigger = "click" }, { B.div({...}, ...) })
--
-- Usage (HTML):
--   <sound sound_id="888" trigger="click"> ... </sound>
--
-- The <sound> tag is a transparent wrapper -" children render
-- normally, and the component fires play_sound_by_id when the
-- trigger condition is met within its layout bounds.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local SoundTrigger = {}
SoundTrigger.__index = SoundTrigger

--- Create a new SoundTrigger instance.
---@return table  SoundTrigger instance
function SoundTrigger.new()
    return setmetatable({
        _was_hovered = false,   -- for hover-enter detection
        _was_pressed = false,   -- for mouseup detection
        _last_play   = 0,       -- timestamp of last play (cooldown)
    }, SoundTrigger)
end

--- Check if cursor is inside layout bounds.
---@param lay   table   layout record {x, y, w, h, ...}
---@param mx    number  cursor x
---@param my    number  cursor y
---@return boolean
local function hit_test(lay, mx, my)
    return mx >= lay.x and mx < lay.x + lay.w
       and my >= lay.y and my < lay.y + lay.h
end

--- Play sound through the platform, respecting cooldown.
---@param self     table   SoundTrigger instance
---@param platform table   Platform instance
---@param sound_id number  SoundKit ID
---@param cooldown number  minimum seconds between plays
local function play(self, platform, sound_id, cooldown)
    if sound_id <= 0 then return end
    local now = platform:time() or 0
    if now - self._last_play < cooldown then return end
    self._last_play = now
    platform:play_sound(sound_id)
end

--- Per-frame update.
---@param ns           table  NodeStore
---@param nid          number node id
---@param input_state  table  InputState
---@param event_system table  EventSystem
---@param dt           number delta time
---@param platform     table  Platform
function SoundTrigger:update(ns, nid, input_state, event_system, dt, platform)
    local lay = ns.layout[nid]
    if not lay or lay.w <= 0 or lay.h <= 0 then return end
    if not platform then return end

    local attrs = ns.attrs[nid] or {}
    local sound_id = tonumber(attrs.sound_id) or 0
    local trigger  = attrs.trigger or "click"
    local cooldown = tonumber(attrs.cooldown) or 0.15

    local mx, my = input_state.cursor_x, input_state.cursor_y
    local inside = hit_test(lay, mx, my)
    local mouse_down = input_state:is_mouse_down()
    local mouse_clicked = input_state:is_mouse_clicked()

    if trigger == "click" then
        if inside and mouse_clicked then
            play(self, platform, sound_id, cooldown)
        end

    elseif trigger == "hover" then
        -- Fire once on hover-enter
        if inside and not self._was_hovered then
            play(self, platform, sound_id, cooldown)
        end

    elseif trigger == "mousedown" then
        if inside and mouse_clicked then
            play(self, platform, sound_id, cooldown)
        end

    elseif trigger == "mouseup" then
        if inside and self._was_pressed and not mouse_down then
            play(self, platform, sound_id, cooldown)
        end
    end

    self._was_hovered = inside
    self._was_pressed = inside and mouse_down
end

return SoundTrigger



