------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / details.lua
-- Details/summary disclosure widget: toggles open/closed on
-- click; hides non-summary children when closed.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Details = {}

--- Update: toggle open state on click, manage child visibility.
---@param ns           table  NodeStore instance
---@param nid          number node id
---@param input_state  table  InputState instance
---@param event_system table  EventSystem instance
function Details.update(ns, nid, input_state, event_system)
    local lay = ns.layout[nid]
    if not lay then return end

    local pseudo = ns.pseudo[nid]
    if not pseudo then
        pseudo = {}
        ns.pseudo[nid] = pseudo
    end

    -- Seed initial open state from HTML attribute on first update
    if pseudo.open == nil then
        local attrs = ns.attrs[nid]
        pseudo.open = (attrs and attrs.open ~= nil) or false
    end

    -- Toggle on click within bounds
    if input_state:is_mouse_clicked() then
        local mx, my = input_state.cursor_x, input_state.cursor_y
        -- Only respond to clicks in the summary area (first child region)
        local first_child = ns.first_child[nid]
        local hit_lay = first_child and ns.layout[first_child]
        local hit_target = hit_lay or lay
        if mx >= hit_target.x and mx < hit_target.x + hit_target.w
           and my >= hit_target.y and my < hit_target.y + hit_target.h then
            pseudo.open = not pseudo.open
            ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        end
    end

    -- Manage child visibility: hide all children except first when closed
    local is_open = pseudo.open
    local first = true
    for child_id in ns:children_iter(nid) do
        if first then
            first = false
        else
            local comp = ns.computed and ns.computed[child_id]
            if comp then
                if is_open then
                    -- Restore display (remove our override)
                    if comp._details_hidden then
                        comp.display = comp._details_prev_display
                        comp._details_hidden = nil
                        comp._details_prev_display = nil
                    end
                else
                    -- Hide child
                    if not comp._details_hidden then
                        comp._details_prev_display = comp.display
                        comp._details_hidden = true
                    end
                    comp.display = "none"
                end
            end
        end
    end
end

--- Paint: draw disclosure triangle before the summary content.
---@param ns       table  NodeStore instance
---@param nid      number node id
---@param dl       table  DisplayList instance
---@param platform table  Platform adapter instance (unused)
function Details.paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    local pseudo = ns.pseudo[nid]
    local is_open = pseudo and pseudo.open

    local computed = ns.computed and ns.computed[nid]
    local cr, cg, cb = 160, 160, 160
    if computed and computed.color and type(computed.color) == "table" then
        cr, cg, cb = computed.color[1], computed.color[2], computed.color[3]
    end

    -- Triangle size and position
    local sz = 6
    local tx = lay.x + 2
    local ty = lay.y + math.floor((lay.h - sz) / 2)
    if ty < lay.y then ty = lay.y end

    if is_open then
        -- Downward-pointing triangle (---)
        dl:triangle_fill(tx, ty,
                         tx + sz, ty,
                         tx + math.floor(sz / 2), ty + sz,
                         cr, cg, cb, 255)
    else
        -- Right-pointing triangle (---)
        dl:triangle_fill(tx, ty,
                         tx + sz, ty + math.floor(sz / 2),
                         tx, ty + sz,
                         cr, cg, cb, 255)
    end
end

return Details



