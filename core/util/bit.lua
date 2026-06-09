------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / bit.lua
-- Lua 5.1-compatible bit operations.
--
-- Uses a host-provided bit table when available, otherwise falls
-- back to arithmetic implementations over unsigned 32-bit values.
------------------------------------------------------------

local host_bit = rawget(_G, "bit")
if type(host_bit) == "table"
   and host_bit.band and host_bit.bor and host_bit.bxor
   and host_bit.lshift and host_bit.rshift then
    return host_bit
end

local Bit = {}
local TWO_32 = 4294967296

local function u32(n)
    n = tonumber(n) or 0
    n = n % TWO_32
    if n < 0 then n = n + TWO_32 end
    return math.floor(n)
end

local function bitop(a, b, op)
    a = u32(a)
    b = u32(b)
    local result = 0
    local bit_value = 1
    for _ = 1, 32 do
        local abit = a % 2
        local bbit = b % 2
        if op(abit, bbit) then
            result = result + bit_value
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit_value = bit_value * 2
    end
    return result
end

function Bit.band(a, b, ...)
    local result = bitop(a, b, function(x, y) return x == 1 and y == 1 end)
    local n = select("#", ...)
    for i = 1, n do
        result = Bit.band(result, select(i, ...))
    end
    return result
end

function Bit.bor(a, b, ...)
    local result = bitop(a, b, function(x, y) return x == 1 or y == 1 end)
    local n = select("#", ...)
    for i = 1, n do
        result = Bit.bor(result, select(i, ...))
    end
    return result
end

function Bit.bxor(a, b, ...)
    local result = bitop(a, b, function(x, y) return x ~= y end)
    local n = select("#", ...)
    for i = 1, n do
        result = Bit.bxor(result, select(i, ...))
    end
    return result
end

function Bit.lshift(a, disp)
    disp = tonumber(disp) or 0
    if disp < 0 then return Bit.rshift(a, -disp) end
    if disp >= 32 then return 0 end
    return u32(u32(a) * (2 ^ disp))
end

function Bit.rshift(a, disp)
    disp = tonumber(disp) or 0
    if disp < 0 then return Bit.lshift(a, -disp) end
    if disp >= 32 then return 0 end
    return math.floor(u32(a) / (2 ^ disp))
end

return Bit



