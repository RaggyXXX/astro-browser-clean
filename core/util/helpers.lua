------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / helpers.lua
-- Pure utility functions -- zero external dependencies.
------------------------------------------------------------
local M = {}

--- Round a number to the nearest integer.
---@param value number
---@return number
function M.round(value)
    return math.floor(value + 0.5)
end

--- Clamp *value* between *min_value* and *max_value* (inclusive).
---@param value number
---@param min_value number
---@param max_value number
---@return number
function M.clamp(value, min_value, max_value)
    return math.max(min_value, math.min(max_value, value))
end

--- Linear interpolation between *a* and *b* by factor *t* (0..1).
---@param a number
---@param b number
---@param t number
---@return number
function M.lerp(a, b, t)
    return a + (b - a) * t
end

--- Shallow-copy a table (one level deep, no metatables).
---@param t table
---@return table
function M.shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

--- Deep-copy a table recursively (no metatables).
---@param t table
---@return table
function M.deep_copy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[M.deep_copy(k)] = M.deep_copy(v)
    end
    return out
end

--- Check whether *s* starts with *prefix*.
---@param s      string
---@param prefix string
---@return boolean
function M.starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

--- Trim leading and trailing whitespace from *s*.
---@param s string
---@return string
function M.trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

--- Split *s* by literal separator *sep* and return an array of parts.
--- An empty string returns `{""}`.  If *sep* is empty, returns each character.
---@param s   string
---@param sep string
---@return table
function M.split(s, sep)
    if sep == nil or sep == "" then
        local parts = {}
        for i = 1, #s do
            parts[#parts + 1] = s:sub(i, i)
        end
        if #parts == 0 then
            parts[1] = ""
        end
        return parts
    end

    local parts = {}
    local start = 1
    local sep_len = #sep
    while true do
        local pos = s:find(sep, start, true)
        if not pos then
            parts[#parts + 1] = s:sub(start)
            break
        end
        parts[#parts + 1] = s:sub(start, pos - 1)
        start = pos + sep_len
    end
    return parts
end

--- Lua 5.1/5.2+ compatible table.unpack wrapper.
M.t_unpack = table.unpack or unpack

--- A do-nothing function.
function M.noop() end

--- AABB overlap test. Returns true if rectangle A overlaps rectangle B.
---@param ax number  x of rect A
---@param ay number  y of rect A
---@param aw number  width  of rect A
---@param ah number  height of rect A
---@param bx number  x of rect B
---@param by number  y of rect B
---@param bw number  width  of rect B
---@param bh number  height of rect B
---@return boolean
function M.rect_intersects(ax, ay, aw, ah, bx, by, bw, bh)
    if aw <= 0 or ah <= 0 or bw <= 0 or bh <= 0 then
        return false
    end
    return ax < bx + bw
       and ax + aw > bx
       and ay < by + bh
       and ay + ah > by
end

--- Intersect rectangle A with clip rectangle C.
--- Returns the clipped x, y, w, h or nil if fully outside.
---@param ax number  x of rect A
---@param ay number  y of rect A
---@param aw number  width  of rect A
---@param ah number  height of rect A
---@param cx number  x of clip rect C
---@param cy number  y of clip rect C
---@param cw number  width  of clip rect C
---@param ch number  height of clip rect C
---@return number|nil, number|nil, number|nil, number|nil
function M.rect_clip(ax, ay, aw, ah, cx, cy, cw, ch)
    local x1 = math.max(ax, cx)
    local y1 = math.max(ay, cy)
    local x2 = math.min(ax + aw, cx + cw)
    local y2 = math.min(ay + ah, cy + ch)
    local rw = x2 - x1
    local rh = y2 - y1
    if rw <= 0 or rh <= 0 then
        return nil
    end
    return x1, y1, rw, rh
end

return M



