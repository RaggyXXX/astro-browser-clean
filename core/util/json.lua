------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / json.lua
-- Self-contained JSON encoder / decoder (Lua 5.1 safe).
-- No external dependencies.
------------------------------------------------------------
local M = {}
M.null = {}

------------------------------------------------------------
-- ENCODER
------------------------------------------------------------

local encode_value  -- forward declaration

local escape_map = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function encode_string(s)
    local buf = { '"' }
    for i = 1, #s do
        local c = s:sub(i, i)
        local esc = escape_map[c]
        if esc then
            buf[#buf + 1] = esc
        elseif c:byte() < 0x20 then
            buf[#buf + 1] = string.format("\\u%04x", c:byte())
        else
            buf[#buf + 1] = c
        end
    end
    buf[#buf + 1] = '"'
    return table.concat(buf)
end

--- Detect whether a table should be encoded as a JSON array.
--- A table is an array if its only keys are contiguous integers 1..n.
local function is_array(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    if count == 0 then
        -- empty table -> treat as array
        return true
    end
    for i = 1, count do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function encode_array(t)
    local parts = {}
    for i = 1, #t do
        parts[#parts + 1] = encode_value(t[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function encode_object(t)
    local parts = {}
    for k, v in pairs(t) do
        local key = tostring(k)
        parts[#parts + 1] = encode_string(key) .. ":" .. encode_value(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(val)
    local vtype = type(val)
    if val == nil or val == M.null then
        return "null"
    elseif vtype == "boolean" then
        return val and "true" or "false"
    elseif vtype == "number" then
        -- Handle special float values
        if val ~= val then
            return "null"  -- NaN
        elseif val == math.huge then
            return "1e999"
        elseif val == -math.huge then
            return "-1e999"
        end
        -- Use integer format when possible for cleaner output
        if val == math.floor(val) and math.abs(val) < 1e15 then
            return string.format("%.0f", val)
        end
        return tostring(val)
    elseif vtype == "string" then
        return encode_string(val)
    elseif vtype == "table" then
        if is_array(val) then
            return encode_array(val)
        else
            return encode_object(val)
        end
    else
        return "null"
    end
end

--- Encode a Lua value (table / string / number / boolean / nil) to a JSON string.
---@param value any
---@return string
function M.encode(value)
    return encode_value(value)
end

------------------------------------------------------------
-- DECODER
------------------------------------------------------------

-- Decoder state: the source string and current position.
local src, pos

local decode_value  -- forward declaration

local function skip_whitespace()
    while pos <= #src do
        local c = src:sub(pos, pos)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            pos = pos + 1
        else
            break
        end
    end
end

local function peek()
    return src:sub(pos, pos)
end

local function next_char()
    local c = src:sub(pos, pos)
    pos = pos + 1
    return c
end

local unescape_map = {
    ['"']  = '"',
    ['\\'] = '\\',
    ['/']  = '/',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
}

local function utf8_from_codepoint(code)
    if code < 0 or code > 0x10FFFF then return nil end
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 64),
            0x80 + (code % 64)
        )
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 4096),
            0x80 + (math.floor(code / 64) % 64),
            0x80 + (code % 64)
        )
    end
    return string.char(
        0xF0 + math.floor(code / 262144),
        0x80 + (math.floor(code / 4096) % 64),
        0x80 + (math.floor(code / 64) % 64),
        0x80 + (code % 64)
    )
end

local function decode_string()
    -- pos should be on the opening quote
    if next_char() ~= '"' then
        return nil
    end
    local buf = {}
    while pos <= #src do
        local c = next_char()
        if c == '"' then
            return table.concat(buf)
        elseif c == '\\' then
            local esc = next_char()
            if esc == 'u' then
                local hex = src:sub(pos, pos + 3)
                if #hex < 4 then return nil end
                pos = pos + 4
                local code = tonumber(hex, 16)
                if not code then return nil end
                if code >= 0xD800 and code <= 0xDBFF then
                    if src:sub(pos, pos + 1) ~= "\\u" then return nil end
                    pos = pos + 2
                    local low_hex = src:sub(pos, pos + 3)
                    if #low_hex < 4 then return nil end
                    pos = pos + 4
                    local low = tonumber(low_hex, 16)
                    if not low or low < 0xDC00 or low > 0xDFFF then return nil end
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                elseif code >= 0xDC00 and code <= 0xDFFF then
                    return nil
                end
                local encoded = utf8_from_codepoint(code)
                if not encoded then return nil end
                buf[#buf + 1] = encoded
            else
                local mapped = unescape_map[esc]
                if mapped then
                    buf[#buf + 1] = mapped
                else
                    return nil
                end
            end
        else
            buf[#buf + 1] = c
        end
    end
    return nil  -- unterminated string
end

local function decode_number()
    local start = pos
    -- optional minus
    if src:sub(pos, pos) == '-' then
        pos = pos + 1
    end
    -- integer part
    if src:sub(pos, pos) == '0' then
        pos = pos + 1
    else
        if not src:sub(pos, pos):match("[1-9]") then return nil end
        while src:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    -- fractional part
    if src:sub(pos, pos) == '.' then
        pos = pos + 1
        if not src:sub(pos, pos):match("[0-9]") then return nil end
        while src:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    -- exponent
    local e = src:sub(pos, pos)
    if e == 'e' or e == 'E' then
        pos = pos + 1
        local sign = src:sub(pos, pos)
        if sign == '+' or sign == '-' then pos = pos + 1 end
        if not src:sub(pos, pos):match("[0-9]") then return nil end
        while src:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    local num = tonumber(src:sub(start, pos - 1))
    return num
end

local function decode_literal(expected, value)
    if src:sub(pos, pos + #expected - 1) == expected then
        pos = pos + #expected
        return value, true
    end
    return nil, false
end

local function decode_array()
    pos = pos + 1  -- skip '['
    skip_whitespace()
    local arr = {}
    if peek() == ']' then
        pos = pos + 1
        return arr
    end
    while true do
        skip_whitespace()
        local val = decode_value()
        arr[#arr + 1] = val
        skip_whitespace()
        local c = peek()
        if c == ']' then
            pos = pos + 1
            return arr
        elseif c == ',' then
            pos = pos + 1
        else
            return nil
        end
    end
end

local function decode_object()
    pos = pos + 1  -- skip '{'
    skip_whitespace()
    local obj = {}
    if peek() == '}' then
        pos = pos + 1
        return obj
    end
    while true do
        skip_whitespace()
        if peek() ~= '"' then return nil end
        local key = decode_string()
        if key == nil then return nil end
        skip_whitespace()
        if next_char() ~= ':' then return nil end
        skip_whitespace()
        local val = decode_value()
        obj[key] = val
        skip_whitespace()
        local c = peek()
        if c == '}' then
            pos = pos + 1
            return obj
        elseif c == ',' then
            pos = pos + 1
        else
            return nil
        end
    end
end

decode_value = function()
    skip_whitespace()
    local c = peek()
    if c == '"' then
        return decode_string()
    elseif c == '{' then
        return decode_object()
    elseif c == '[' then
        return decode_array()
    elseif c == 't' then
        local val, ok = decode_literal("true", true)
        if ok then return val end
        return nil
    elseif c == 'f' then
        local val, ok = decode_literal("false", false)
        if ok then return val end
        return nil
    elseif c == 'n' then
        local _, ok = decode_literal("null", M.null)
        if ok then return M.null end
        return nil
    elseif c == '-' or c:match("[0-9]") then
        return decode_number()
    else
        return nil
    end
end

--- Decode a JSON string into a Lua value.
--- Returns nil on malformed input (never throws).
---@param s string
---@return any
function M.decode(s)
    if type(s) ~= "string" then
        return nil
    end
    local ok, result = pcall(function()
        src = s
        pos = 1
        skip_whitespace()
        if pos > #src then return nil end
        local val = decode_value()
        skip_whitespace()
        -- Ensure we consumed the entire input
        if pos <= #src then
            return nil
        end
        return val
    end)
    if ok then
        return result
    end
    return nil
end

return M



