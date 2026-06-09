------------------------------------------------------------
-- ext_core_astro_ui_lib / core / debug / devtools.lua
-- Debug overlay: bounding boxes, hover chain highlight,
-- node/focus stats.  Toggle with devtools:toggle().
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Devtools = {}
Devtools.__index = Devtools
local Painters = require("core/paint/painters")

--- Create a new Devtools instance.
---@return table  Devtools instance
function Devtools.new()
    return setmetatable({
        enabled    = false,
        show_boxes = true,
        show_hover = true,
        show_stats = true,
    }, Devtools)
end

--- Toggle the debug overlay on/off.
function Devtools:toggle()
    self.enabled = not self.enabled
end

--- Paint the debug overlay.
---@param ns           table  NodeStore instance
---@param root_id      number root node id
---@param dl           table  DisplayList instance
---@param platform     table  Platform adapter instance (unused)
---@param event_system table  EventSystem instance
function Devtools:paint(ns, root_id, dl, platform, event_system)
    if not self.enabled then return end
    if root_id == 0 then return end

    -- Draw bounding boxes for all nodes
    if self.show_boxes then
        ns:walk_depth_first(root_id, function(nid)
            local lay = ns.layout[nid]
            if lay and lay.w > 0 and lay.h > 0 then
                dl:rect_stroke(lay.x, lay.y, lay.w, lay.h,
                               255, 0, 0, 80, 1, 0)
            end
        end)
    end

    -- Highlight hover chain
    if self.show_hover and event_system then
        local chain = event_system.hover_chain
        for i = 1, #chain do
            local nid = chain[i]
            local lay = ns.layout[nid]
            if lay and lay.w > 0 and lay.h > 0 then
                local alpha = 40
                if i == 1 then alpha = 120 end
                dl:rect_fill(lay.x, lay.y, lay.w, lay.h,
                             0, 150, 255, alpha, 0)
            end
        end
    end

    -- Stats overlay
    if self.show_stats then
        local node_count = ns._count or 0
        local hover_count = 0
        if event_system and event_system.hover_chain then
            hover_count = #event_system.hover_chain
        end
        local focus_id = 0
        if event_system then
            focus_id = event_system.focus_id or 0
        end

        local stats_y = 10
        dl:rect_fill(5, 5, 180, 50, 0, 0, 0, 180, 4)
        Painters.paint_text(dl, "Nodes: " .. tostring(node_count),
            10, stats_y, 11, 0, 255, 0, 255, false, Painters._default_font or "inter", 400, "normal")
        Painters.paint_text(dl, "Hover: " .. tostring(hover_count),
            10, stats_y + 14, 11, 0, 255, 0, 255, false, Painters._default_font or "inter", 400, "normal")
        Painters.paint_text(dl, "Focus: " .. tostring(focus_id),
            10, stats_y + 28, 11, 0, 255, 0, 255, false, Painters._default_font or "inter", 400, "normal")
    end
end

return Devtools



