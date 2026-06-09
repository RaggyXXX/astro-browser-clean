------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / utf8.lua
-- UTF-8 codepoint iterator for glyph-by-glyph rendering.
------------------------------------------------------------

local Utf8 = {}

local bit      = require("core/util/bit")
local str_byte = string.byte
local band     = bit.band
local bor      = bit.bor
local lshift   = bit.lshift

--- Iterate over Unicode codepoints in a UTF-8 string.
--- Returns an iterator function that yields one codepoint
--- per call, or nil when the string is exhausted.
---@param s string  UTF-8 encoded string
---@return function  iterator yielding codepoints
function Utf8.codes(s)
    local i = 1
    local len = #s
    return function()
        if i > len then return nil end
        local b = str_byte(s, i)
        local cp, n
        if b < 0x80 then
            cp, n = b, 1
        elseif b < 0xE0 then
            cp, n = band(b, 0x1F), 2
        elseif b < 0xF0 then
            cp, n = band(b, 0x0F), 3
        else
            cp, n = band(b, 0x07), 4
        end
        for j = 2, n do
            local cb = str_byte(s, i + j - 1)
            if not cb or band(cb, 0xC0) ~= 0x80 then
                cp = 0xFFFD  -- replacement character
                break
            end
            cp = bor(lshift(cp, 6), band(cb, 0x3F))
        end
        i = i + n
        return cp
    end
end

--- Count the number of Unicode codepoints in a UTF-8 string.
---@param s string  UTF-8 encoded string
---@return number  codepoint count
function Utf8.len(s)
    local count = 0
    local i = 1
    local len = #s
    while i <= len do
        local b = str_byte(s, i)
        if b < 0x80 then
            i = i + 1
        elseif b < 0xE0 then
            i = i + 2
        elseif b < 0xF0 then
            i = i + 3
        else
            i = i + 4
        end
        count = count + 1
    end
    return count
end

--- Return the byte length of the UTF-8 codepoint starting at byte position i.
--- i is 1-based. Returns 1 for ASCII, 2-4 for multi-byte, 1 for invalid.
---@param s string
---@param i number  1-based byte position
---@return number  byte count of this codepoint
function Utf8.char_len_at(s, i)
    local b = str_byte(s, i)
    if not b or b < 0x80 then return 1
    elseif b < 0xE0 then return 2
    elseif b < 0xF0 then return 3
    else return 4
    end
end

--- Step forward one codepoint from 0-based byte offset pos.
--- Returns the new 0-based offset after the codepoint.
---@param s string
---@param pos number  0-based byte offset
---@return number  new 0-based byte offset
function Utf8.next(s, pos)
    if pos >= #s then return #s end
    return pos + Utf8.char_len_at(s, pos + 1)
end

--- Step backward one codepoint from 0-based byte offset pos.
--- Returns the new 0-based offset at the start of the previous codepoint.
---@param s string
---@param pos number  0-based byte offset
---@return number  new 0-based byte offset
function Utf8.prev(s, pos)
    if pos <= 0 then return 0 end
    local i = pos  -- 0-based: byte before pos is s:byte(pos) (1-based = pos)
    -- Walk back over continuation bytes (10xxxxxx)
    while i > 0 do
        i = i - 1
        local b = str_byte(s, i + 1)  -- convert to 1-based
        if not b or band(b, 0xC0) ~= 0x80 then
            break
        end
    end
    return i
end

return Utf8



