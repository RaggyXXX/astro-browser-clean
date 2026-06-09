------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / button.lua
-- Button component: visual feedback on hover/active/checked
-- pseudo states.  UA defaults are in style_engine.lua;
-- this module handles pseudo-state dirty marking and
-- optional custom painting.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Button = {}

--- Called when an event changes pseudo state for a button.
--- Marks style dirty so the style engine re-resolves with
--- hover/active/focus style overrides.
---@param ns          table   NodeStore instance
---@param nid         number  node id
---@param event_type  string  "enter"|"leave"|"down"|"up"|"click"
---@param input_state table   InputState instance (unused here)
function Button.on_event(ns, nid, event_type, input_state)
    local pseudo = ns.pseudo[nid]
    if not pseudo then return end

    if event_type == "enter" then
        pseudo.hover = true
        ns:mark_dirty(nid, ns.STYLE_DIRTY)
    elseif event_type == "leave" then
        pseudo.hover = false
        pseudo.active = false
        ns:mark_dirty(nid, ns.STYLE_DIRTY)
    elseif event_type == "down" then
        pseudo.active = true
        ns:mark_dirty(nid, ns.STYLE_DIRTY)
    elseif event_type == "up" then
        pseudo.active = false
        ns:mark_dirty(nid, ns.STYLE_DIRTY)
    end
end

--- Optional additional painting for buttons beyond what
--- painters.lua already does (background, border, text).
--- Currently a no-op; override if custom decoration is needed.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance
function Button.paint_custom(ns, nid, dl, platform)
    -- Default painting is handled by painters.lua.
    -- This hook is available for future button-specific
    -- decorations (icons, ripple effects, etc.).
end

return Button



