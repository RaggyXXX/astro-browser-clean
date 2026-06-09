------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / control_parts.lua
-- Internal anonymous control parts used to keep self-drawn form
-- controls visually consistent with Chrome-like defaults.
--
-- This is not public Shadow DOM. It is a small renderer-side
-- part layer for native-looking controls inside Astro.
------------------------------------------------------------

local Parts = {}

Parts.METRICS = {
    control_font_size = 13.333,
    checkbox_size = 13,
    radio_size = 13,
    range_width = 129,
    range_height = 16,
    range_track_h = 4,
    range_thumb_r = 6,
    select_option_min_h = 24,
}

function Parts.is_disabled(ns, nid)
    local pseudo = ns.pseudo and ns.pseudo[nid]
    return pseudo and pseudo.disabled
end

function Parts.is_focused(ns, nid)
    local pseudo = ns.pseudo and ns.pseudo[nid]
    return pseudo and (pseudo.focus or pseudo.focus_visible)
end

function Parts.accent(ns, nid)
    local computed = ns.computed and ns.computed[nid]
    local ac = computed and computed.accent_color
    if type(ac) == "table" then
        return ac[1] or 0, ac[2] or 95, ac[3] or 184
    end
    return 0, 95, 184
end

function Parts.focus_ring(ns, nid, dl, x, y, w, h, radius)
    if not Parts.is_focused(ns, nid) then return end
    dl:rect_stroke(x - 2, y - 2, w + 4, h + 4, 16, 16, 16, 255, 1, radius or 2)
end

function Parts.range_metrics(lay)
    local thumb_r = Parts.METRICS.range_thumb_r
    local track_h = Parts.METRICS.range_track_h
    local track_x = lay.x + thumb_r
    local track_w = lay.w - thumb_r * 2
    if track_w < 0 then track_w = 0 end
    local track_y = lay.y + math.floor((lay.h - track_h) / 2)
    local thumb_y = lay.y + math.floor(lay.h / 2)
    return track_x, track_y, track_w, track_h, thumb_r, thumb_y
end

function Parts.paint_range(ns, nid, dl, lay, ratio)
    if not lay then return end
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    local disabled = Parts.is_disabled(ns, nid)
    local ar, ag, ab = Parts.accent(ns, nid)
    if disabled then ar, ag, ab = 155, 155, 155 end

    local tx, ty, tw, th, tr, thumb_y = Parts.range_metrics(lay)
    local fill_w = math.floor(tw * ratio + 0.5)

    -- Chrome-like range: neutral track with accent-colored lower segment
    -- and circular thumb.
    dl:rect_fill(tx, ty, tw, th, 59, 59, 59, disabled and 120 or 255, 2)
    if fill_w > 0 then
        dl:rect_fill(tx, ty, fill_w, th, ar, ag, ab, disabled and 140 or 255, 2)
    end

    local thumb_x = tx + fill_w
    dl:circle_fill(thumb_x, thumb_y, tr, ar, ag, ab, disabled and 160 or 255)
    Parts.focus_ring(ns, nid, dl, lay.x, lay.y, lay.w, lay.h, 2)
end

function Parts.paint_checkbox(ns, nid, dl, lay)
    if not lay then return end
    local pseudo = ns.pseudo[nid] or {}
    local disabled = pseudo.disabled
    local checked = pseudo.checked
    local ar, ag, ab = Parts.accent(ns, nid)
    local a = disabled and 130 or 255
    local size = math.min(lay.w or 0, lay.h or 0)
    if size < 1 then return end
    local x = lay.x
    local y = lay.y + math.floor(((lay.h or size) - size) / 2)

    if checked then
        dl:rect_fill(x, y, size, size, ar, ag, ab, a, 1)
        dl:rect_stroke(x, y, size, size, ar, ag, ab, a, 1, 1)
        dl:line(x + size * 0.22, y + size * 0.54,
                x + size * 0.42, y + size * 0.74,
                255, 255, 255, a, 2)
        dl:line(x + size * 0.40, y + size * 0.74,
                x + size * 0.80, y + size * 0.28,
                255, 255, 255, a, 2)
    else
        local br = disabled and 170 or 118
        dl:rect_fill(x, y, size, size, 255, 255, 255, disabled and 150 or 255, 1)
        dl:rect_stroke(x, y, size, size, br, br, br, 255, 1, 1)
    end
    Parts.focus_ring(ns, nid, dl, x, y, size, size, 1)
end

function Parts.paint_radio(ns, nid, dl, lay)
    if not lay then return end
    local pseudo = ns.pseudo[nid] or {}
    local disabled = pseudo.disabled
    local checked = pseudo.checked
    local size = math.min(lay.w or 0, lay.h or 0)
    local cx = lay.x + size * 0.5
    local cy = lay.y + (lay.h or size) * 0.5
    local radius = size * 0.5
    if radius < 1 then return end

    local br = disabled and 170 or 118
    dl:circle_fill(cx, cy, radius, br, br, br, 255)
    dl:circle_fill(cx, cy, math.max(0.5, radius - 1.5), 255, 255, 255, disabled and 150 or 255)
    if checked then
        local ar, ag, ab = Parts.accent(ns, nid)
        if disabled then ar, ag, ab = 120, 120, 120 end
        dl:circle_fill(cx, cy, radius * 0.45, ar, ag, ab, disabled and 160 or 255)
    end
    Parts.focus_ring(ns, nid, dl, lay.x, lay.y + math.floor(((lay.h or size) - size) / 2), size, size, radius)
end

function Parts.option_height(ns, nid, font_size, platform, line_box)
    local computed = ns.computed[nid] or {}
    local line_h = computed.line_height
    if type(line_h) ~= "number" then
        line_h = line_box or font_size * 1.25
    end
    return math.max(Parts.METRICS.select_option_min_h, math.ceil(line_h + 4), math.ceil((line_box or line_h) + 4))
end

return Parts



