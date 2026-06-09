------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / checkbox.lua
-- Checkbox component: toggles checked pseudo state on click,
-- paints a box with an inner indicator when checked.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Checkbox = {}
local ControlParts = require("core/components/control_parts")

--- Paint the checkbox: border box + filled indicator when checked.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Checkbox.paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    ControlParts.paint_checkbox(ns, nid, dl, lay)
end

return Checkbox



