------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / gradient.lua
-- Linear, radial, and conic gradient rendering with:
--   - Frame-persistent cache (keyed by size + params)
--   - RLE row-merging (same-color runs → single rect_fill)
--   - 2x2 supersampling for repeating gradients (anti-alias)
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Gradient = {}

local math_floor = math.floor
local math_ceil  = math.ceil
local math_sqrt  = math.sqrt
local math_min   = math.min
local math_max   = math.max
local math_abs   = math.abs
local math_atan2 = math.atan2 or math.atan
local math_sin   = math.sin
local math_cos   = math.cos


------------------------------------------------------------
-- Gradient cache
-- Stores RLE-merged rect commands keyed by gradient params.
-- Entries store relative coords (0,0 origin) and are replayed
-- with the element's absolute x,y offset.
------------------------------------------------------------
local _gcache = {}       -- key -> { cmds (flat array stride 8), n, f }
local _gframe = 0        -- current frame counter
local _cache_hits = 0
local _cache_misses = 0

--- Call once per frame to advance the cache generation counter.
--- Expires entries unused for 3+ frames every 120 frames.
function Gradient.begin_frame()
    _gframe = _gframe + 1
    -- Periodic sweep (amortized cost, every 30 frames)
    if _gframe % 30 == 0 then
        local cutoff = _gframe - 3
        for k, v in pairs(_gcache) do
            if v.f < cutoff then
                _gcache[k] = nil
            end
        end
    end
end

--- Flush the entire gradient cache (e.g., on resize).
function Gradient.flush_cache()
    _gcache = {}
end

--- Hash gradient stops into a number for cache keying.
--- Uses a weak-keyed memo table so the hash is computed once per stops table.
local _stops_hash_memo = setmetatable({}, { __mode = "k" })
local function hash_stops(stops)
    local cached = _stops_hash_memo[stops]
    if cached then return cached end
    local n = #stops
    local h = n * 7
    for i = 1, n do
        local s = stops[i]
        local c = s[2]
        h = (h * 65599 + s[1] * 100000 + c[1] * 65536 + c[2] * 256 + c[3] + (c[4] or 255) * 16777216) % 4294967296
    end
    _stops_hash_memo[stops] = h
    return h
end

--- Replay cached gradient commands onto the display list.
--- Commands are stored as a flat array with stride 8: {rx, ry, rw, rh, r, g, b, a, ...}
local function replay_cache(dl, entry, ox, oy)
    entry.f = _gframe
    local cmds = entry.cmds
    local n8 = entry.n * 8
    -- Floor the offset to match integer-grid rasterization
    local fox = math_floor(ox)
    local foy = math_floor(oy)
    local overlap = 0.75
    for i = 1, n8, 8 do
        dl:rect_fill(cmds[i] + fox, cmds[i+1] + foy, cmds[i+2] + overlap, cmds[i+3] + overlap,
                     cmds[i+4], cmds[i+5], cmds[i+6], cmds[i+7], 0)
    end
end

------------------------------------------------------------
-- Color interpolation
------------------------------------------------------------

local function lerp_color(c1, c2, t)
    local a1 = c1[4] or 255
    local a2 = c2[4] or 255
    return math_floor(c1[1] + (c2[1] - c1[1]) * t + 0.5),
           math_floor(c1[2] + (c2[2] - c1[2]) * t + 0.5),
           math_floor(c1[3] + (c2[3] - c1[3]) * t + 0.5),
           math_floor(a1 + (a2 - a1) * t + 0.5)
end

local function color_at(stops, pos)
    local ns = #stops
    if ns == 0 then return 0, 0, 0, 0 end
    if ns == 1 then
        local c = stops[1][2]
        return c[1], c[2], c[3], c[4] or 255
    end
    if pos <= stops[1][1] then
        local c = stops[1][2]
        return c[1], c[2], c[3], c[4] or 255
    end
    if pos >= stops[ns][1] then
        local c = stops[ns][2]
        return c[1], c[2], c[3], c[4] or 255
    end
    for i = 1, ns - 1 do
        local s1 = stops[i]
        local s2 = stops[i + 1]
        if pos >= s1[1] and pos <= s2[1] then
            local range = s2[1] - s1[1]
            if range > 0 then
                return lerp_color(s1[2], s2[2], (pos - s1[1]) / range)
            end
            return lerp_color(s1[2], s2[2], 0)
        end
    end
    local c = stops[ns][2]
    return c[1], c[2], c[3], c[4] or 255
end

local function wrap_repeating(t, stops)
    local first_pos = stops[1][1]
    local last_pos = stops[#stops][1]
    local period = last_pos - first_pos
    if period > 0 then
        t = first_pos + ((t - first_pos) % period)
    end
    return t
end

function Gradient.sample_color(stops, pos)
    return color_at(stops, pos)
end

------------------------------------------------------------
-- Parse direction
------------------------------------------------------------

local function parse_direction(dir)
    if type(dir) == "number" then return dir end
    if type(dir) ~= "string" then return 180 end
    if dir == "to bottom" then return 180 end
    if dir == "to top"    then return 0 end
    if dir == "to right"  then return 90 end
    if dir == "to left"   then return 270 end
    if dir == "to bottom right" or dir == "to right bottom" then return 135 end
    if dir == "to bottom left"  or dir == "to left bottom"  then return 225 end
    if dir == "to top right"    or dir == "to right top"    then return 45 end
    if dir == "to top left"     or dir == "to left top"     then return 315 end
    local deg = dir:match("^([%d%.%-]+)deg$")
    if deg then return tonumber(deg) or 180 end
    return 180
end

------------------------------------------------------------
-- Linear gradient painting (with cache + RLE)
------------------------------------------------------------

function Gradient.paint_linear(dl, x, y, w, h, angle, stops, opacity, num_strips, repeating)
    if not stops or #stops == 0 then return end
    if w <= 0 or h <= 0 then return end

    local deg = parse_direction(angle) % 360
    local rad = deg * math.pi / 180
    local gx = math_sin(rad)
    local gy = -math_cos(rad)
    local max_proj = (math_abs(gx) + math_abs(gy)) * 0.5
    if max_proj <= 0 then max_proj = 0.5 end

    local opacity_factor = (opacity or 255) / 255
    local rep_flag = repeating and "r" or ""

    -- Cache key (use .. concat -" faster than string.format in Lua 5.1)
    local key = "L:" .. w .. ":" .. h .. ":" .. deg .. ":" .. rep_flag .. ":" .. hash_stops(stops) .. ":" .. math_floor(opacity_factor * 255)
    local cached = _gcache[key]
    if cached then
        replay_cache(dl, cached, x, y)
        return
    end

    -- Sampler: project a point (in normalised gradient-box coordinates,
    -- centered around 0) onto the gradient axis, then map to [0,1] across
    -- the axis range.  Same math as Gradient.sample_color_2d, so cardinal
    -- and diagonal angles share a single source of truth.
    local function sample_t(nx_centered, ny_centered)
        local d = nx_centered * gx + ny_centered * gy
        local t = d / max_proj * 0.5 + 0.5
        if repeating then
            t = wrap_repeating(t, stops)
        else
            if t < 0 then t = 0 end
            if t > 1 then t = 1 end
        end
        return t
    end

    local cmds = {}
    local ci = 0

    -- Choose rasterisation mode:
    --   |gx| ≈ 0  → gradient axis is vertical   → full-width horizontal strips
    --   |gy| ≈ 0  → gradient axis is horizontal → full-height vertical strips
    --   otherwise → 2D cell rasterisation (only path that paints true diagonals)
    local is_vert  = math_abs(gx) < 1e-4
    local is_horiz = math_abs(gy) < 1e-4

    if is_vert then
        local strips = num_strips or math_ceil(h)
        if strips < 1 then strips = 1 end
        local prev_r, prev_g, prev_b, prev_a = -1, -1, -1, -1
        local run_sy = 0
        for i = 0, strips - 1 do
            local ny_c = ((i + 0.5) / strips) - 0.5
            local t = sample_t(0, ny_c)
            local r, g, b, a = color_at(stops, t)
            a = math_floor(a * opacity_factor)
            if r ~= prev_r or g ~= prev_g or b ~= prev_b or a ~= prev_a then
                if prev_a > 0 and i > 0 then
                    local sy = math_floor(run_sy * h / strips)
                    local sy2 = math_floor(i * h / strips)
                    ci = ci + 1; cmds[ci] = 0
                    ci = ci + 1; cmds[ci] = sy
                    ci = ci + 1; cmds[ci] = w
                    ci = ci + 1; cmds[ci] = sy2 - sy
                    ci = ci + 1; cmds[ci] = prev_r
                    ci = ci + 1; cmds[ci] = prev_g
                    ci = ci + 1; cmds[ci] = prev_b
                    ci = ci + 1; cmds[ci] = prev_a
                end
                run_sy = i
                prev_r, prev_g, prev_b, prev_a = r, g, b, a
            end
        end
        if prev_a > 0 then
            local sy = math_floor(run_sy * h / strips)
            ci = ci + 1; cmds[ci] = 0
            ci = ci + 1; cmds[ci] = sy
            ci = ci + 1; cmds[ci] = w
            ci = ci + 1; cmds[ci] = h - sy
            ci = ci + 1; cmds[ci] = prev_r
            ci = ci + 1; cmds[ci] = prev_g
            ci = ci + 1; cmds[ci] = prev_b
            ci = ci + 1; cmds[ci] = prev_a
        end
    elseif is_horiz then
        local strips = num_strips or math_ceil(w)
        if strips < 1 then strips = 1 end
        local prev_r, prev_g, prev_b, prev_a = -1, -1, -1, -1
        local run_sx = 0
        for i = 0, strips - 1 do
            local nx_c = ((i + 0.5) / strips) - 0.5
            local t = sample_t(nx_c, 0)
            local r, g, b, a = color_at(stops, t)
            a = math_floor(a * opacity_factor)
            if r ~= prev_r or g ~= prev_g or b ~= prev_b or a ~= prev_a then
                if prev_a > 0 and i > 0 then
                    local sx = math_floor(run_sx * w / strips)
                    local sx2 = math_floor(i * w / strips)
                    ci = ci + 1; cmds[ci] = sx
                    ci = ci + 1; cmds[ci] = 0
                    ci = ci + 1; cmds[ci] = sx2 - sx
                    ci = ci + 1; cmds[ci] = h
                    ci = ci + 1; cmds[ci] = prev_r
                    ci = ci + 1; cmds[ci] = prev_g
                    ci = ci + 1; cmds[ci] = prev_b
                    ci = ci + 1; cmds[ci] = prev_a
                end
                run_sx = i
                prev_r, prev_g, prev_b, prev_a = r, g, b, a
            end
        end
        if prev_a > 0 then
            local sx = math_floor(run_sx * w / strips)
            ci = ci + 1; cmds[ci] = sx
            ci = ci + 1; cmds[ci] = 0
            ci = ci + 1; cmds[ci] = w - sx
            ci = ci + 1; cmds[ci] = h
            ci = ci + 1; cmds[ci] = prev_r
            ci = ci + 1; cmds[ci] = prev_g
            ci = ci + 1; cmds[ci] = prev_b
            ci = ci + 1; cmds[ci] = prev_a
        end
    else
        -- Diagonal: rasterise on a coarse 2D grid (1-2 px per cell) and
        -- RLE-merge horizontally adjacent same-color cells per row.  This
        -- is the path that produces a true rotated gradient -" the old
        -- branch collapsed every diagonal into a pure horizontal/vertical
        -- stack of strips.
        local cell_w = 1
        local cell_h = 1
        local cols = math_ceil(w / cell_w)
        local rows = math_ceil(h / cell_h)
        for cy = 0, rows - 1 do
            local strip_y = cy * cell_h
            local strip_h2 = cell_h
            if strip_y + strip_h2 > h then strip_h2 = h - strip_y end
            if strip_h2 <= 0 then break end
            local ny_c = (strip_y + strip_h2 * 0.5) / h - 0.5

            local prev_r, prev_g, prev_b, prev_a = -1, -1, -1, -1
            local run_sx = 0
            for cx = 0, cols - 1 do
                local strip_x = cx * cell_w
                local strip_w2 = cell_w
                if strip_x + strip_w2 > w then strip_w2 = w - strip_x end
                if strip_w2 > 0 then
                    local nx_c = (strip_x + strip_w2 * 0.5) / w - 0.5
                    local t = sample_t(nx_c, ny_c)
                    local r, g, b, a = color_at(stops, t)
                    a = math_floor(a * opacity_factor)
                    if r ~= prev_r or g ~= prev_g or b ~= prev_b or a ~= prev_a then
                        if prev_a > 0 and cx > 0 then
                            local rs_x = run_sx
                            local rs_w = strip_x - rs_x
                            ci = ci + 1; cmds[ci] = rs_x
                            ci = ci + 1; cmds[ci] = strip_y
                            ci = ci + 1; cmds[ci] = rs_w
                            ci = ci + 1; cmds[ci] = strip_h2
                            ci = ci + 1; cmds[ci] = prev_r
                            ci = ci + 1; cmds[ci] = prev_g
                            ci = ci + 1; cmds[ci] = prev_b
                            ci = ci + 1; cmds[ci] = prev_a
                        end
                        run_sx = strip_x
                        prev_r, prev_g, prev_b, prev_a = r, g, b, a
                    end
                end
            end
            if prev_a > 0 then
                local rs_x = run_sx
                local rs_w = w - rs_x
                ci = ci + 1; cmds[ci] = rs_x
                ci = ci + 1; cmds[ci] = strip_y
                ci = ci + 1; cmds[ci] = rs_w
                ci = ci + 1; cmds[ci] = strip_h2
                ci = ci + 1; cmds[ci] = prev_r
                ci = ci + 1; cmds[ci] = prev_g
                ci = ci + 1; cmds[ci] = prev_b
                ci = ci + 1; cmds[ci] = prev_a
            end
        end
    end

    local entry = { cmds = cmds, n = ci / 8, f = _gframe }
    _gcache[key] = entry
    replay_cache(dl, entry, x, y)
end

------------------------------------------------------------
-- Radial gradient painting
------------------------------------------------------------

local function compute_radial_radii(shape, size_kw, cx, cy, x, y, w, h)
    local dl = math_abs(cx - x)
    local dr = math_abs(cx - (x + w))
    local dt = math_abs(cy - y)
    local db = math_abs(cy - (y + h))
    if shape == "circle" then
        local r
        if size_kw == "closest-side" then
            r = math_min(dl, dr, dt, db)
        elseif size_kw == "farthest-side" then
            r = math_max(dl, dr, dt, db)
        elseif size_kw == "closest-corner" then
            local nx = math_min(dl, dr); local ny = math_min(dt, db)
            r = math_sqrt(nx*nx + ny*ny)
        else
            local fx = math_max(dl, dr); local fy = math_max(dt, db)
            r = math_sqrt(fx*fx + fy*fy)
        end
        return r, r
    else
        local rx, ry
        if size_kw == "closest-side" then
            rx = math_min(dl, dr); ry = math_min(dt, db)
        elseif size_kw == "farthest-side" then
            rx = math_max(dl, dr); ry = math_max(dt, db)
        elseif size_kw == "closest-corner" then
            local nx = math_min(dl, dr); local ny = math_min(dt, db)
            local diag = math_sqrt(nx*nx + ny*ny)
            if diag > 0 then
                local asp = w / math_max(h, 1)
                ry = diag / math_sqrt(asp*asp + 1) * 1.4142135623731
                rx = ry * asp
            else rx = 0; ry = 0 end
        else
            local fx = math_max(dl, dr); local fy = math_max(dt, db)
            local diag = math_sqrt(fx*fx + fy*fy)
            if diag > 0 then
                local asp = w / math_max(h, 1)
                ry = diag / math_sqrt(asp*asp + 1) * 1.4142135623731
                rx = ry * asp
            else rx = 0; ry = 0 end
        end
        return math_max(rx, 1), math_max(ry, 1)
    end
end

function Gradient.paint_radial(dl, x, y, w, h, center, stops, opacity, shape, size_kw, repeating, clip_radius)
    if not stops or #stops == 0 then return end
    if w <= 0 or h <= 0 then return end

    center = center or { 0.5, 0.5 }
    shape = shape or "ellipse"
    size_kw = size_kw or "farthest-corner"
    local opacity_factor = (opacity or 255) / 255
    local rep_flag = repeating and "r" or ""

    -- Cache key (position-independent: keyed by size + gradient params)
    local c1 = center[1] or 0.5
    local c2 = center[2] or 0.5
    local clip_key = clip_radius and math_floor(clip_radius * 64 + 0.5) or 0
    local key = "R:" .. w .. ":" .. h .. ":" .. c1 .. ":" .. c2 .. ":" .. shape .. ":" .. size_kw .. ":" .. rep_flag .. ":" .. hash_stops(stops) .. ":" .. math_floor(opacity_factor * 255) .. ":" .. clip_key
    local cached = _gcache[key]
    if cached then
        replay_cache(dl, cached, x, y)
        return
    end

    -- Compute radii relative to element origin (0,0)
    local cx_rel = w * (center[1] or 0.5)
    local cy_rel = h * (center[2] or 0.5)
    local rx, ry = compute_radial_radii(shape, size_kw, cx_rel, cy_rel, 0, 0, w, h)
    if rx <= 0 and ry <= 0 then return end

    local cell = 1

    local cols = math_ceil(w / cell)
    local rows = math_ceil(h / cell)
    local inv_rx = 1 / rx
    local inv_ry = 1 / ry
    local ss = repeating
    local offA, offB = 0.25, 0.75
    local cr = clip_radius or 0
    if cr < 0 then cr = 0 end
    local function rounded_rect_coverage(px, py)
        if cr <= 0 then return 1 end
        local rr = math_min(cr, w * 0.5, h * 0.5)
        if rr <= 0 then return 1 end
        local ix = px
        local iy = py
        if ix >= rr and ix <= w - rr then return 1 end
        if iy >= rr and iy <= h - rr then return 1 end
        local ccx = (ix < rr) and rr or (w - rr)
        local ccy = (iy < rr) and rr or (h - rr)
        local dx = ix - ccx
        local dy = iy - ccy
        if dx * dx + dy * dy <= rr * rr then return 1 end
        return 0
    end

    local function cell_clip_alpha(px, py)
        if cr <= 0 then return 1 end
        return (rounded_rect_coverage(px + 0.25, py + 0.25)
              + rounded_rect_coverage(px + 0.75, py + 0.25)
              + rounded_rect_coverage(px + 0.25, py + 0.75)
              + rounded_rect_coverage(px + 0.75, py + 0.75)) * 0.25
    end

    -- Build RLE-merged command buffer (relative to 0,0)
    local cmds = {}
    local ci = 0

    for row = 0, rows - 1 do
        local ry_pos = row * cell
        local ch = math_min(cell, math_floor(h) - ry_pos)
        if ch <= 0 then break end

        -- RLE state for this row
        local run_col = 0
        local run_r, run_g, run_b, run_a = -1, -1, -1, -1

        if ss then
            local pyA = ry_pos + offA
            local pyB = ry_pos + offB
            local ndyA = (pyA - cy_rel) * inv_ry
            local ndyB = (pyB - cy_rel) * inv_ry
            local ndyA2 = ndyA * ndyA
            local ndyB2 = ndyB * ndyB
            for col = 0, cols - 1 do
                local px_base = col * cell
                local pxA = px_base + offA
                local pxB = px_base + offB
                local ndxA = (pxA - cx_rel) * inv_rx
                local ndxB = (pxB - cx_rel) * inv_rx
                local t1 = wrap_repeating(math_sqrt(ndxA*ndxA + ndyA2), stops)
                local t2 = wrap_repeating(math_sqrt(ndxB*ndxB + ndyA2), stops)
                local t3 = wrap_repeating(math_sqrt(ndxA*ndxA + ndyB2), stops)
                local t4 = wrap_repeating(math_sqrt(ndxB*ndxB + ndyB2), stops)
                local r1,g1,b1,a1 = color_at(stops, t1)
                local r2,g2,b2,a2 = color_at(stops, t2)
                local r3,g3,b3,a3 = color_at(stops, t3)
                local r4,g4,b4,a4 = color_at(stops, t4)
                local r = math_floor((r1+r2+r3+r4) * 0.25)
                local g = math_floor((g1+g2+g3+g4) * 0.25)
                local b = math_floor((b1+b2+b3+b4) * 0.25)
                local a = math_floor((a1+a2+a3+a4) * 0.25 * opacity_factor * cell_clip_alpha(px_base, ry_pos) + 0.5)
                -- RLE: merge if same color
                if r == run_r and g == run_g and b == run_b and a == run_a then
                    -- extend run
                else
                    if run_a > 0 then
                        local rx_pos = run_col * cell
                        local rw = col * cell - rx_pos
                        ci=ci+1; cmds[ci]=rx_pos; ci=ci+1; cmds[ci]=ry_pos
                        ci=ci+1; cmds[ci]=rw;     ci=ci+1; cmds[ci]=ch
                        ci=ci+1; cmds[ci]=run_r;  ci=ci+1; cmds[ci]=run_g
                        ci=ci+1; cmds[ci]=run_b;  ci=ci+1; cmds[ci]=run_a
                    end
                    run_col = col
                    run_r, run_g, run_b, run_a = r, g, b, a
                end
            end
        else
            local py = ry_pos + 0.5 * cell
            local ndy = (py - cy_rel) * inv_ry
            local ndy2 = ndy * ndy
            for col = 0, cols - 1 do
                local px = (col + 0.5) * cell
                local ndx = (px - cx_rel) * inv_rx
                local t = math_sqrt(ndx * ndx + ndy2)
                if t > 1 then t = 1 end
                local r, g, b, a = color_at(stops, t)
                a = math_floor(a * opacity_factor * cell_clip_alpha(col * cell, ry_pos) + 0.5)
                if r == run_r and g == run_g and b == run_b and a == run_a then
                    -- extend
                else
                    if run_a > 0 then
                        local rx_pos = run_col * cell
                        local rw = col * cell - rx_pos
                        ci=ci+1; cmds[ci]=rx_pos; ci=ci+1; cmds[ci]=ry_pos
                        ci=ci+1; cmds[ci]=rw;     ci=ci+1; cmds[ci]=ch
                        ci=ci+1; cmds[ci]=run_r;  ci=ci+1; cmds[ci]=run_g
                        ci=ci+1; cmds[ci]=run_b;  ci=ci+1; cmds[ci]=run_a
                    end
                    run_col = col
                    run_r, run_g, run_b, run_a = r, g, b, a
                end
            end
        end
        -- Flush last run of this row
        if run_a > 0 then
            local rx_pos = run_col * cell
            local rw = math_min(cols * cell, math_floor(w)) - rx_pos
            if rw > 0 then
                ci=ci+1; cmds[ci]=rx_pos; ci=ci+1; cmds[ci]=ry_pos
                ci=ci+1; cmds[ci]=rw;     ci=ci+1; cmds[ci]=ch
                ci=ci+1; cmds[ci]=run_r;  ci=ci+1; cmds[ci]=run_g
                ci=ci+1; cmds[ci]=run_b;  ci=ci+1; cmds[ci]=run_a
            end
        end
    end

    local entry = { cmds = cmds, n = ci / 8, f = _gframe }
    _gcache[key] = entry
    replay_cache(dl, entry, x, y)
end

------------------------------------------------------------
-- Conic gradient painting
------------------------------------------------------------

function Gradient.paint_conic(dl, x, y, w, h, stops, cx_frac, cy_frac, from_angle, opacity, repeating)
    if not stops or #stops == 0 then return end
    if w <= 0 or h <= 0 then return end

    cx_frac = cx_frac or 0.5
    cy_frac = cy_frac or 0.5
    from_angle = from_angle or 0
    local opacity_factor = (opacity or 255) / 255
    local rep_flag = repeating and "r" or ""

    -- Cache key
    local key = "C:" .. w .. ":" .. h .. ":" .. cx_frac .. ":" .. cy_frac .. ":" .. from_angle .. ":" .. rep_flag .. ":" .. hash_stops(stops) .. ":" .. math_floor(opacity_factor * 255)
    local cached = _gcache[key]
    if cached then
        replay_cache(dl, cached, x, y)
        return
    end

    local gcx = w * cx_frac
    local gcy = h * cy_frac
    local from_rad = from_angle * math.pi / 180
    local TWO_PI = 2 * math.pi
    local inv_TWO_PI = 1 / TWO_PI

    local cell
    if repeating then cell = 1
    else
        local area = w * h
        cell = 2
        if area > 10000 then cell = 3 end
        if area > 40000 then cell = 4 end
    end

    local cols = math_ceil(w / cell)
    local rows = math_ceil(h / cell)
    local ss = repeating
    local offA, offB = 0.25, 0.75

    -- Inline conic_t for performance (avoids closure + function call overhead)
    -- CSS conic: 0deg = top (12 o'clock), clockwise
    -- atan2(dx, -dy): 0 when directly above, positive clockwise

    local cmds = {}
    local ci = 0

    for row = 0, rows - 1 do
        local ry_pos = row * cell
        local ch = math_min(cell, math_floor(h) - ry_pos)
        if ch <= 0 then break end

        local run_col = 0
        local run_r, run_g, run_b, run_a = -1, -1, -1, -1

        if ss then
            local pyA = ry_pos + offA
            local pyB = ry_pos + offB
            local neg_dyA = -(pyA - gcy)
            local neg_dyB = -(pyB - gcy)
            for col = 0, cols - 1 do
                local px_base = col * cell
                local pxA = px_base + offA
                local pxB = px_base + offB
                local dxA = pxA - gcx
                local dxB = pxB - gcx
                local t1 = wrap_repeating(((math_atan2(dxA, neg_dyA) - from_rad) % TWO_PI) * inv_TWO_PI, stops)
                local t2 = wrap_repeating(((math_atan2(dxB, neg_dyA) - from_rad) % TWO_PI) * inv_TWO_PI, stops)
                local t3 = wrap_repeating(((math_atan2(dxA, neg_dyB) - from_rad) % TWO_PI) * inv_TWO_PI, stops)
                local t4 = wrap_repeating(((math_atan2(dxB, neg_dyB) - from_rad) % TWO_PI) * inv_TWO_PI, stops)
                local r1,g1,b1,a1 = color_at(stops, t1)
                local r2,g2,b2,a2 = color_at(stops, t2)
                local r3,g3,b3,a3 = color_at(stops, t3)
                local r4,g4,b4,a4 = color_at(stops, t4)
                local r = math_floor((r1+r2+r3+r4) * 0.25)
                local g = math_floor((g1+g2+g3+g4) * 0.25)
                local b = math_floor((b1+b2+b3+b4) * 0.25)
                local a = math_floor((a1+a2+a3+a4) * 0.25 * opacity_factor)
                if r == run_r and g == run_g and b == run_b and a == run_a then
                    -- extend
                else
                    if run_a > 0 then
                        local rx_pos = run_col * cell
                        local rw = col * cell - rx_pos
                        ci=ci+1; cmds[ci]=rx_pos; ci=ci+1; cmds[ci]=ry_pos
                        ci=ci+1; cmds[ci]=rw;     ci=ci+1; cmds[ci]=ch
                        ci=ci+1; cmds[ci]=run_r;  ci=ci+1; cmds[ci]=run_g
                        ci=ci+1; cmds[ci]=run_b;  ci=ci+1; cmds[ci]=run_a
                    end
                    run_col = col
                    run_r, run_g, run_b, run_a = r, g, b, a
                end
            end
        else
            local py = ry_pos + 0.5 * cell
            local neg_dy = -(py - gcy)
            for col = 0, cols - 1 do
                local px = (col + 0.5) * cell
                local dx = px - gcx
                local angle_rad = math_atan2(dx, neg_dy)
                local t = ((angle_rad - from_rad) % TWO_PI) * inv_TWO_PI
                local r, g, b, a = color_at(stops, t)
                a = math_floor(a * opacity_factor)
                if r == run_r and g == run_g and b == run_b and a == run_a then
                    -- extend
                else
                    if run_a > 0 then
                        local rx_pos = run_col * cell
                        local rw = col * cell - rx_pos
                        ci=ci+1; cmds[ci]=rx_pos; ci=ci+1; cmds[ci]=ry_pos
                        ci=ci+1; cmds[ci]=rw;     ci=ci+1; cmds[ci]=ch
                        ci=ci+1; cmds[ci]=run_r;  ci=ci+1; cmds[ci]=run_g
                        ci=ci+1; cmds[ci]=run_b;  ci=ci+1; cmds[ci]=run_a
                    end
                    run_col = col
                    run_r, run_g, run_b, run_a = r, g, b, a
                end
            end
        end
        -- Flush last run
        if run_a > 0 then
            local rx_pos = run_col * cell
            local rw = math_min(cols * cell, math_floor(w)) - rx_pos
            if rw > 0 then
                ci=ci+1; cmds[ci]=rx_pos; ci=ci+1; cmds[ci]=ry_pos
                ci=ci+1; cmds[ci]=rw;     ci=ci+1; cmds[ci]=ch
                ci=ci+1; cmds[ci]=run_r;  ci=ci+1; cmds[ci]=run_g
                ci=ci+1; cmds[ci]=run_b;  ci=ci+1; cmds[ci]=run_a
            end
        end
    end

    local entry = { cmds = cmds, n = ci / 8, f = _gframe }
    _gcache[key] = entry
    replay_cache(dl, entry, x, y)
end

------------------------------------------------------------
-- 2D gradient sampling for background-clip: text
------------------------------------------------------------

function Gradient.sample_color_2d(grad_info, px, py)
    local stops = grad_info.stops
    if not stops or #stops == 0 then return 0, 0, 0, 0 end

    local ex = grad_info.elem_x or 0
    local ey = grad_info.elem_y or 0
    local ew = grad_info.elem_w or 1
    local eh = grad_info.elem_h or 1
    if ew <= 0 then ew = 1 end
    if eh <= 0 then eh = 1 end

    local gtype = grad_info.grad_type

    if gtype == "radial-gradient" then
        local center = grad_info.center or { 0.5, 0.5 }
        local cx = ex + ew * (center[1] or 0.5)
        local cy = ey + eh * (center[2] or 0.5)
        local shape = grad_info.shape or "ellipse"
        local skw = grad_info.size_kw or "farthest-corner"
        local rrx, rry = compute_radial_radii(shape, skw, cx, cy, ex, ey, ew, eh)
        if rrx <= 0 then rrx = 1 end
        if rry <= 0 then rry = 1 end
        local dx = (px - cx) / rrx
        local dy = (py - cy) / rry
        local t = math_sqrt(dx * dx + dy * dy)
        if grad_info.repeating then
            t = wrap_repeating(t, stops)
        else
            if t > 1 then t = 1 end
        end
        return color_at(stops, t)

    elseif gtype == "conic-gradient" then
        local cxf = 0.5
        local cyf = 0.5
        if grad_info.center then
            cxf = grad_info.center[1] or 0.5
            cyf = grad_info.center[2] or 0.5
        end
        local cx = ex + ew * cxf
        local cy = ey + eh * cyf
        local fa = grad_info.from_angle or 0
        local dx = px - cx
        local dy = py - cy
        local angle_rad = math_atan2(dx, -dy)
        local angle_deg = angle_rad * 180 / math.pi
        local t = ((angle_deg - fa) % 360) / 360
        if grad_info.repeating then t = wrap_repeating(t, stops) end
        return color_at(stops, t)

    else
        local deg = parse_direction(grad_info.angle or 180)
        local rad = deg * math.pi / 180
        local gx = math_sin(rad)
        local gy = -math_cos(rad)
        local nx = (px - ex) / ew
        local ny = (py - ey) / eh
        local dot = (nx - 0.5) * gx + (ny - 0.5) * gy
        local max_proj = (math_abs(gx) + math_abs(gy)) * 0.5
        if max_proj <= 0 then max_proj = 0.5 end
        local t = dot / max_proj * 0.5 + 0.5
        if grad_info.repeating then
            t = wrap_repeating(t, stops)
        else
            if t < 0 then t = 0 end
            if t > 1 then t = 1 end
        end
        return color_at(stops, t)
    end
end

return Gradient



