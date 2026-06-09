------------------------------------------------------------
-- ext_core_astro_ui_lib / core / input / input_state.lua
-- Polling-based input state with edge detection, key repeat,
-- and synthesised text events.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local InputState = {}
InputState.__index = InputState

------------------------------------------------------------
-- Windows Virtual-Key code constants
------------------------------------------------------------
local VK = {
    LBUTTON  = 0x01,
    RBUTTON  = 0x02,
    MBUTTON  = 0x04,
    BACK     = 0x08,
    TAB      = 0x09,
    RETURN   = 0x0D,
    SHIFT    = 0x10,
    CONTROL  = 0x11,
    ALT      = 0x12,
    ESCAPE   = 0x1B,
    SPACE    = 0x20,
    PRIOR    = 0x21,  -- Page Up
    NEXT     = 0x22,  -- Page Down
    END_KEY  = 0x23,
    HOME     = 0x24,
    LEFT     = 0x25,
    UP       = 0x26,
    RIGHT    = 0x27,
    DOWN     = 0x28,
    DELETE   = 0x2E,
    -- 0-9
    K0 = 0x30, K1 = 0x31, K2 = 0x32, K3 = 0x33, K4 = 0x34,
    K5 = 0x35, K6 = 0x36, K7 = 0x37, K8 = 0x38, K9 = 0x39,
    -- A-Z
    A = 0x41, B = 0x42, C = 0x43, D = 0x44, E = 0x45,
    F = 0x46, G = 0x47, H = 0x48, I = 0x49, J = 0x4A,
    K = 0x4B, L = 0x4C, M = 0x4D, N = 0x4E, O = 0x4F,
    P = 0x50, Q = 0x51, R = 0x52, S = 0x53, T = 0x54,
    U = 0x55, V = 0x56, W = 0x57, X = 0x58, Y = 0x59,
    Z = 0x5A,
    -- Symbol keys (US layout VK codes)
    OEM_1      = 0xBA,  -- ;:
    OEM_PLUS   = 0xBB,  -- =+
    OEM_COMMA  = 0xBC,  -- ,<
    OEM_MINUS  = 0xBD,  -- -_
    OEM_PERIOD = 0xBE,  -- .>
    OEM_2      = 0xBF,  -- /?
    OEM_3      = 0xC0,  -- `~
    OEM_4      = 0xDB,  -- [{
    OEM_5      = 0xDC,  -- \|
    OEM_6      = 0xDD,  -- ]}
    OEM_7      = 0xDE,  -- '"
}

-- Expose VK table
InputState.VK = VK

------------------------------------------------------------
-- Key repeat configuration
------------------------------------------------------------
local KEY_REPEAT_DELAY = 0.42   -- seconds before repeat starts
local KEY_REPEAT_RATE  = 0.035  -- seconds between repeats

------------------------------------------------------------
-- Mapping tables for text event synthesis
------------------------------------------------------------

-- Shift mapping for number keys and symbol keys (US layout)
local SHIFT_MAP = {
    [VK.K1] = "!", [VK.K2] = "@", [VK.K3] = "#", [VK.K4] = "$",
    [VK.K5] = "%", [VK.K6] = "^", [VK.K7] = "&", [VK.K8] = "*",
    [VK.K9] = "(", [VK.K0] = ")",
    [VK.OEM_1]      = ":",
    [VK.OEM_PLUS]   = "+",
    [VK.OEM_COMMA]  = "<",
    [VK.OEM_MINUS]  = "_",
    [VK.OEM_PERIOD] = ">",
    [VK.OEM_2]      = "?",
    [VK.OEM_3]      = "~",
    [VK.OEM_4]      = "{",
    [VK.OEM_5]      = "|",
    [VK.OEM_6]      = "}",
    [VK.OEM_7]      = '"',
}

local UNSHIFT_MAP = {
    [VK.K0] = "0", [VK.K1] = "1", [VK.K2] = "2", [VK.K3] = "3",
    [VK.K4] = "4", [VK.K5] = "5", [VK.K6] = "6", [VK.K7] = "7",
    [VK.K8] = "8", [VK.K9] = "9",
    [VK.OEM_1]      = ";",
    [VK.OEM_PLUS]   = "=",
    [VK.OEM_COMMA]  = ",",
    [VK.OEM_MINUS]  = "-",
    [VK.OEM_PERIOD] = ".",
    [VK.OEM_2]      = "/",
    [VK.OEM_3]      = "`",
    [VK.OEM_4]      = "[",
    [VK.OEM_5]      = "\\",
    [VK.OEM_6]      = "]",
    [VK.OEM_7]      = "'",
}

-- Build list of text-producing VK codes (A-Z, 0-9, Space, symbols)
local TEXT_VKS = {}
for vk = VK.A, VK.Z do
    TEXT_VKS[#TEXT_VKS + 1] = vk
end
for vk = VK.K0, VK.K9 do
    TEXT_VKS[#TEXT_VKS + 1] = vk
end
TEXT_VKS[#TEXT_VKS + 1] = VK.SPACE
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_1
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_PLUS
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_COMMA
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_MINUS
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_PERIOD
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_2
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_3
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_4
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_5
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_6
TEXT_VKS[#TEXT_VKS + 1] = VK.OEM_7

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

function InputState.new(platform)
    local self = setmetatable({}, InputState)
    self._platform = platform

    -- Current frame state
    self.cursor_x  = 0
    self.cursor_y  = 0
    self.wheel     = 0
    self.shift     = false
    self.ctrl      = false
    self.alt       = false

    -- Key state tables: vk -> boolean
    self._keys      = {}   -- current frame
    self._prev_keys = {}   -- previous frame
    self._edges     = {}   -- edge flags (true = just pressed this frame)

    -- Key repeat tracking: vk -> { first_time, last_repeat_time }
    self._repeat = {}

    -- Text event queue (consumed by widgets)
    self._text_events = {}

    -- Time from platform
    self._time = 0

    return self
end

------------------------------------------------------------
-- Polling
------------------------------------------------------------

--- Snapshot all input for this frame.
--- Must be called once per frame, before any input queries.
---@param time number|nil  current time (overrides platform query for deterministic callers)
function InputState:poll(time)
    local plat = self._platform

    -- Cursor position
    self.cursor_x, self.cursor_y = plat:get_cursor_position()

    -- Wheel delta
    self.wheel = plat:get_wheel_delta()

    -- Time
    self._time = time or plat:time()

    -- Swap key buffers
    local prev = self._prev_keys
    local curr = self._keys
    -- Copy current into previous, then re-poll current.
    for vk, _ in pairs(prev) do
        prev[vk] = nil
    end
    for vk, val in pairs(curr) do
        prev[vk] = val
    end

    -- Poll modifier keys
    self.shift = plat:is_key_pressed(VK.SHIFT)
    self.ctrl  = plat:is_key_pressed(VK.CONTROL)
    self.alt   = plat:is_key_pressed(VK.ALT)

    -- Poll mouse buttons
    curr[VK.LBUTTON] = plat:is_key_pressed(VK.LBUTTON)
    curr[VK.RBUTTON] = plat:is_key_pressed(VK.RBUTTON)
    curr[VK.MBUTTON] = plat:is_key_pressed(VK.MBUTTON)

    -- Poll modifiers into key table too
    curr[VK.SHIFT]   = self.shift
    curr[VK.CONTROL] = self.ctrl
    curr[VK.ALT]     = self.alt

    -- Poll navigation / editing keys
    local nav_keys = {
        VK.BACK, VK.TAB, VK.RETURN, VK.ESCAPE, VK.SPACE,
        VK.PRIOR, VK.NEXT,
        VK.LEFT, VK.UP, VK.RIGHT, VK.DOWN,
        VK.DELETE, VK.HOME, VK.END_KEY,
    }
    for idx = 1, #nav_keys do
        curr[nav_keys[idx]] = plat:is_key_pressed(nav_keys[idx])
    end

    -- Poll A-Z
    for vk = VK.A, VK.Z do
        curr[vk] = plat:is_key_pressed(vk)
    end

    -- Poll 0-9
    for vk = VK.K0, VK.K9 do
        curr[vk] = plat:is_key_pressed(vk)
    end

    -- Poll symbol keys
    local sym_keys = {
        VK.OEM_1, VK.OEM_PLUS, VK.OEM_COMMA, VK.OEM_MINUS,
        VK.OEM_PERIOD, VK.OEM_2, VK.OEM_3, VK.OEM_4,
        VK.OEM_5, VK.OEM_6, VK.OEM_7,
    }
    for idx = 1, #sym_keys do
        curr[sym_keys[idx]] = plat:is_key_pressed(sym_keys[idx])
    end

    -- Compute edge flags
    local edges = self._edges
    for vk, _ in pairs(edges) do
        edges[vk] = nil
    end
    for vk, down in pairs(curr) do
        if down and not prev[vk] then
            edges[vk] = true
        end
    end

    -- Generate text events
    self:_poll_text_keys()
end

------------------------------------------------------------
-- Text event synthesis
------------------------------------------------------------

--- Generate text events from the current keyboard state.
--- Handles key repeat with configurable delay and rate.
function InputState:_poll_text_keys()
    local t = self._time
    local events = self._text_events
    for i = 1, #events do
        events[i] = nil
    end

    for idx = 1, #TEXT_VKS do
        local vk = TEXT_VKS[idx]
        local down = self._keys[vk]

        if down then
            local rep = self._repeat[vk]
            local should_emit = false

            if not self._prev_keys[vk] then
                -- Key just pressed: emit immediately, start repeat timer.
                should_emit = true
                self._repeat[vk] = { t, t }
            elseif rep then
                -- Key held: check repeat timing.
                local first_time    = rep[1]
                local last_repeat   = rep[2]
                local held_duration = t - first_time

                if held_duration >= KEY_REPEAT_DELAY then
                    if t - last_repeat >= KEY_REPEAT_RATE then
                        should_emit = true
                        rep[2] = t
                    end
                end
            end

            if should_emit and not (self.ctrl and not self.alt) then
                local ch = self:_vk_to_char(vk)
                if ch then
                    events[#events + 1] = ch
                end
            end
        else
            -- Key released: clear repeat state.
            self._repeat[vk] = nil
        end
    end
end

--- Convert a VK code to a character string, respecting shift state.
---@param vk number
---@return string|nil
function InputState:_vk_to_char(vk)
    -- Space
    if vk == VK.SPACE then
        return " "
    end

    -- A-Z
    if vk >= VK.A and vk <= VK.Z then
        local base = string.char(vk)  -- VK.A = 0x41 = 'A'
        if self.shift then
            return base  -- uppercase
        else
            return base:lower()  -- lowercase
        end
    end

    -- 0-9 and symbol keys
    if self.shift and SHIFT_MAP[vk] then
        return SHIFT_MAP[vk]
    elseif UNSHIFT_MAP[vk] then
        return UNSHIFT_MAP[vk]
    end

    return nil
end

------------------------------------------------------------
-- Queries
------------------------------------------------------------

--- Return and clear the text event queue.
---@return table  array of single-character strings
function InputState:consume_text_events()
    local events = self._text_events
    self._text_events = {}
    return events
end

--- Is a key currently held down?
---@param vk number  VK code
---@return boolean
function InputState:is_key_pressed(vk)
    return self._keys[vk] == true
end

--- Was a key just pressed this frame (edge-triggered)?
---@param vk number  VK code
---@return boolean
function InputState:is_key_edge(vk)
    return self._edges[vk] == true
end

--- Was ANY key just pressed this frame?
---@return boolean
function InputState:any_key_edge()
    return next(self._edges) ~= nil
end

--- Was the left mouse button just clicked this frame?
---@return boolean
function InputState:is_mouse_clicked()
    return self._edges[VK.LBUTTON] == true
end

--- Is a mouse button currently held? Defaults to left; accepts 1/2/3.
---@return boolean
function InputState:is_mouse_down(button)
    local vk = VK.LBUTTON
    if button == 2 then
        vk = VK.RBUTTON
    elseif button == 3 then
        vk = VK.MBUTTON
    end
    return self._keys[vk] == true
end

--- Was the left mouse button just released this frame?
---@return boolean
function InputState:is_mouse_released()
    return self._prev_keys[VK.LBUTTON] == true and not self._keys[VK.LBUTTON]
end

--- Was the right mouse button just clicked this frame?
---@return boolean
function InputState:is_right_mouse_clicked()
    return self._edges[VK.RBUTTON] == true
end

return InputState



