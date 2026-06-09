------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / switch.lua
-- Self-drawn toggle switch control.
--
-- Lua 5.1 safe.
------------------------------------------------------------
local Switch = {}
Switch.__index = Switch

function Switch.new()
    return setmetatable({}, Switch)
end

local function color_from(computed, checked)
    if checked then
        local ac = computed and computed.accent_color
        if ac and type(ac) == "table" then
            return ac[1] or 0, ac[2] or 95, ac[3] or 184, ac[4] or 255
        end
        return 0, 95, 184, 255
    end
    return 230, 230, 230, 255
end

function Switch:paint(ns, nid, dl, platform)
    local lay = ns.layout[nid]
    if not lay then return end

    local pseudo = ns.pseudo[nid] or {}
    local computed = ns.computed[nid] or {}
    local checked = pseudo.checked == true
    local disabled = pseudo.disabled == true

    local x, y, w, h = lay.x, lay.y, lay.w, lay.h
    if w <= 0 or h <= 0 then return end

    local radius = math.floor(h / 2)
    local tr, tg, tb, ta = color_from(computed, checked)
    if disabled then ta = math.floor(ta * 0.45) end

    dl:rect_fill(x, y, w, h, tr, tg, tb, ta, radius)
    dl:rect_stroke(x, y, w, h, 118, 118, 118, disabled and 120 or 255, 1, radius)

    local pad = 2
    local thumb_r = math.floor((h - pad * 2) / 2)
    local cx
    if checked then
        cx = x + w - pad - thumb_r
    else
        cx = x + pad + thumb_r
    end
    local cy = y + math.floor(h / 2)
    local sr = disabled and 190 or 255
    dl:circle_fill(cx, cy, thumb_r, sr, sr, sr, disabled and 170 or 255)

    if pseudo.focus then
        dl:rect_stroke(x - 2, y - 2, w + 4, h + 4, 0, 95, 184, 180, 1, radius + 2)
    end
end

return Switch



