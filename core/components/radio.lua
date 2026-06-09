------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / radio.lua
-- Radio button component: circle outline + filled dot when
-- checked. Click selects this radio and deselects siblings
-- with the same name attribute.
--
-- Usage: <radio name="group1" value="opt1"/>
-- Clicking sets pseudo.checked=true on this node and
-- pseudo.checked=false on all sibling radios with same name.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Radio = {}
local ControlParts = require("core/components/control_parts")

--- Paint the radio button: circle + inner dot when checked.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Radio.paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    ControlParts.paint_radio(ns, nid, dl, lay)
end

--- Walk up to find the nearest form ancestor, or root if no form.
--- In HTML, radio groups are scoped to their owning form.
local function find_group_root(ns, nid)
    local cur = nid
    while true do
        local p = ns.parent[cur]
        if not p or p == 0 then return cur end
        local tag_id = ns.tag[p]
        local tag_str = ns._st:get(tag_id)
        if tag_str == "form" then return p end
        cur = p
    end
end

local function is_radio_node(ns, nid)
    local tag_id = ns.tag[nid]
    local tag_str = ns._st:get(tag_id)
    if tag_str == "radio" then return true end
    if tag_str ~= "input" then return false end
    local attrs = ns.attrs[nid]
    return tostring(attrs and attrs.type or ""):lower() == "radio"
end

--- Handle click on a radio button: select this one, deselect
--- all radios with the same name in the entire subtree (like HTML
--- forms where name-matching is document-wide, not sibling-only).
---@param ns   table   NodeStore instance
---@param nid  number  clicked radio node id
---@param event_system table  EventSystem instance
function Radio.on_click(ns, nid, event_system)
    local pseudo = ns.pseudo[nid]
    if not pseudo then return end
    if pseudo.disabled then return end

    -- Already checked: radios don't uncheck on click
    if pseudo.checked then return end

    local attrs = ns.attrs[nid]
    local name = attrs and attrs.name

    -- Deselect all radios with the same name in the tree
    if name then
        local root = find_group_root(ns, nid)
        ns:walk_depth_first(root, function(other_nid)
            if other_nid == nid then return end
            if is_radio_node(ns, other_nid) then
                local other_attrs = ns.attrs[other_nid]
                if other_attrs and other_attrs.name == name then
                    local other_pseudo = ns.pseudo[other_nid]
                    if other_pseudo and other_pseudo.checked then
                        other_pseudo.checked = false
                        ns:mark_dirty(other_nid, ns.STYLE_DIRTY + ns.PAINT_DIRTY)
                    end
                end
            end
        end)
    end

    -- Check this one
    pseudo.checked = true
    ns:mark_dirty(nid, ns.STYLE_DIRTY + ns.PAINT_DIRTY)

    -- Fire onChange action
    local on_change = attrs and (attrs.onChange or attrs.onchange)
    if on_change then
        local handler = event_system._action_handlers[on_change]
        if handler then
            pcall(handler, nid, on_change)
        end
    end
end

return Radio



