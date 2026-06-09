------------------------------------------------------------
-- ext_core_astro_ui_lib / core / dom / string_table.lua
-- Intern strings to integer IDs for compact SoA storage.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ST = {}
ST.__index = ST

function ST.new()
    return setmetatable({
        _str_to_id = {},   -- string -> int
        _id_to_str = {},   -- int -> string
        _next_id = 1,
    }, ST)
end

--- Intern a string and return its integer ID.
--- nil maps to 0; all other values are tostring'd.
---@param value any
---@return number
function ST:intern(value)
    if value == nil then return 0 end
    value = tostring(value)
    local id = self._str_to_id[value]
    if id then return id end
    id = self._next_id
    self._next_id = id + 1
    self._str_to_id[value] = id
    self._id_to_str[id] = value
    return id
end

--- Retrieve the original string for an ID.
---@param id number
---@return string|nil
function ST:get(id)
    return self._id_to_str[id]
end

--- Intern an array of strings and return an array of IDs.
---@param strings table  array of strings
---@return table  array of integer IDs
function ST:bulk_intern(strings)
    local ids = {}
    for i = 1, #strings do
        ids[i] = self:intern(strings[i])
    end
    return ids
end

return ST



