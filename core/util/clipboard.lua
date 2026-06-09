------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / clipboard.lua
-- Clipboard facade backed by the active platform adapter.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local Clipboard = {}

local _internal = ""     -- fallback when the system clipboard is unavailable
local _platform = nil

--- Configure the active platform adapter.
---@param platform table|nil
function Clipboard.set_platform(platform)
    _platform = platform
end

--- Read text from system clipboard. Falls back to internal buffer.
---@return string
function Clipboard.read()
    if _platform and type(_platform.get_clipboard_text) == "function" then
        local ok, result = pcall(_platform.get_clipboard_text, _platform)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    return _internal
end

--- Write text to system clipboard + internal buffer.
---@param text string
function Clipboard.write(text)
    _internal = text or ""
    if _platform and type(_platform.copy_to_clipboard) == "function" then
        pcall(_platform.copy_to_clipboard, _platform, _internal)
    end
end

return Clipboard



