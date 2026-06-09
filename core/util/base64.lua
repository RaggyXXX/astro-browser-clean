------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / base64.lua
-- Base64 decoder for data: URIs.
--
-- Accepts standard base64 and URL-safe base64.  Ignores
-- whitespace.  Returns raw binary string.
--
-- Lua 5.1 safe: no goto, no bitwise ops (modular arithmetic).
------------------------------------------------------------
local Base64 = {}

local ALPHABET = {}  -- char -> 0..63
do
    local std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #std do
        ALPHABET[std:sub(i, i)] = i - 1
    end
    -- URL-safe variants map to the same values
    ALPHABET["-"] = 62
    ALPHABET["_"] = 63
end

local string_char = string.char
local string_sub  = string.sub

--- Decode a base64 string to raw binary.
---@param s string
---@return string|nil   raw bytes, or nil on malformed input
function Base64.decode(s)
    if type(s) ~= "string" then return nil end

    -- Collect valid characters only.  Whitespace is ignored, but padding is
    -- only legal at the end of the encoded stream; accepting `=` in the
    -- middle would silently turn malformed payloads into different bytes.
    local clean = {}
    local clean_n = 0
    local pad_count = 0
    local non_ws_count = 0
    local seen_padding = false
    for i = 1, #s do
        local ch = string_sub(s, i, i)
        if ALPHABET[ch] then
            if seen_padding then return nil end
            non_ws_count = non_ws_count + 1
            clean_n = clean_n + 1
            clean[clean_n] = ch
        elseif ch == "=" then
            seen_padding = true
            pad_count = pad_count + 1
            non_ws_count = non_ws_count + 1
            if pad_count > 2 then return nil end
        elseif ch == " " or ch == "\n" or ch == "\r" or ch == "\t" then
            -- ignore whitespace
        else
            -- unknown character: reject
            return nil
        end
    end

    local out = {}
    local out_n = 0
    if pad_count > 0 and non_ws_count % 4 ~= 0 then
        return nil
    end
    if clean_n % 4 == 1 then
        return nil
    end
    local i = 1
    while i + 3 <= clean_n do
        local b1 = ALPHABET[clean[i]]
        local b2 = ALPHABET[clean[i + 1]]
        local b3 = ALPHABET[clean[i + 2]]
        local b4 = ALPHABET[clean[i + 3]]
        local n = b1 * 262144 + b2 * 4096 + b3 * 64 + b4
        local o1 = math.floor(n / 65536)
        local o2 = math.floor(n / 256) % 256
        local o3 = n % 256
        out_n = out_n + 1; out[out_n] = string_char(o1)
        out_n = out_n + 1; out[out_n] = string_char(o2)
        out_n = out_n + 1; out[out_n] = string_char(o3)
        i = i + 4
    end

    local remainder = clean_n - (i - 1)
    if remainder == 2 then
        local b1 = ALPHABET[clean[i]]
        local b2 = ALPHABET[clean[i + 1]]
        local n = b1 * 4 + math.floor(b2 / 16)
        out_n = out_n + 1; out[out_n] = string_char(n)
    elseif remainder == 3 then
        local b1 = ALPHABET[clean[i]]
        local b2 = ALPHABET[clean[i + 1]]
        local b3 = ALPHABET[clean[i + 2]]
        local n1 = b1 * 4 + math.floor(b2 / 16)
        local n2 = (b2 % 16) * 16 + math.floor(b3 / 4)
        out_n = out_n + 1; out[out_n] = string_char(n1)
        out_n = out_n + 1; out[out_n] = string_char(n2)
    end

    return table.concat(out)
end

--- Parse a data: URI into (mime_type, is_base64, payload_bytes).
--- Returns nil if not a data URI.
--- On success the caller can use payload_bytes directly (e.g. pass to
--- platform:load_texture) without a round-trip through base64/binary.
---@param uri string
---@return string|nil  mime_type
---@return string|nil  raw binary bytes
function Base64.parse_data_uri(uri)
    if type(uri) ~= "string" or uri:sub(1, 5) ~= "data:" then return nil, nil end

    local comma = uri:find(",", 6, true)
    if not comma then return nil, nil end

    local prefix = uri:sub(6, comma - 1)
    local payload = uri:sub(comma + 1)

    -- prefix format: <mime-type>;<param>;...;base64 (mime and params all optional)
    local mime = prefix:match("^([^;]+)") or "application/octet-stream"
    local is_b64 = prefix:find(";base64", 1, true) ~= nil or prefix:find("^base64") ~= nil

    if is_b64 then
        return mime, Base64.decode(payload)
    end
    -- URL-encoded payload
    payload = payload:gsub("%%(%x%x)", function(hex)
        return string_char(tonumber(hex, 16))
    end)
    return mime, payload
end

return Base64



