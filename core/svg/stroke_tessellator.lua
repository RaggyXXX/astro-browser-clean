------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / stroke_tessellator.lua
-- Convert a polyline into filled polygons representing the
-- stroked outline. Supports linecap (butt/square/round)
-- and linejoin (miter/bevel/round).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local StrokeTessellator = {}

local math_sqrt = math.sqrt
local math_cos  = math.cos
local math_sin  = math.sin
local math_pi   = math.pi
local math_atan2 = math.atan2 or math.atan
local math_abs  = math.abs
local math_min  = math.min

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function vec_len(dx, dy)
    return math_sqrt(dx*dx + dy*dy)
end

local function normalize(dx, dy)
    local len = vec_len(dx, dy)
    if len < 1e-10 then return 0, 0 end
    return dx / len, dy / len
end

--- Generate arc points from angle a0 to a1 around (cx, cy) with radius r.
local function arc_points(cx, cy, r, a0, a1, out)
    local da = a1 - a0
    local steps = math.max(4, math.ceil(math_abs(da) / (math_pi * 0.25)))
    local step = da / steps
    for i = 0, steps do
        local a = a0 + i * step
        out[#out + 1] = { x = cx + math_cos(a) * r, y = cy + math_sin(a) * r }
    end
end

------------------------------------------------------------
-- Main tessellation
------------------------------------------------------------

--- Tessellate a polyline into fill polygons for the stroke.
---@param points    table  Array of {x=, y=} points
---@param width     number Stroke width
---@param linecap   string "butt"|"square"|"round"
---@param linejoin  string "miter"|"bevel"|"round"
---@param miterlimit number Miter limit ratio (default 4)
---@param closed    boolean Whether the path is closed
---@return table  Array of polylines (each an array of {x=,y=})
function StrokeTessellator.tessellate(points, width, linecap, linejoin, miterlimit, closed)
    width = width or 1
    linecap = linecap or "butt"
    linejoin = linejoin or "miter"
    miterlimit = miterlimit or 4
    local hw = width * 0.5

    local n = #points
    if n < 2 then return {} end

    -- Remove duplicate consecutive points
    local pts = { points[1] }
    for i = 2, n do
        local prev = pts[#pts]
        if math_abs(points[i].x - prev.x) > 1e-6 or math_abs(points[i].y - prev.y) > 1e-6 then
            pts[#pts + 1] = points[i]
        end
    end
    n = #pts
    if n < 2 then return {} end

    -- Compute per-segment normals
    local normals = {}
    for i = 1, n - 1 do
        local dx = pts[i+1].x - pts[i].x
        local dy = pts[i+1].y - pts[i].y
        local nx, ny = normalize(-dy, dx)
        normals[i] = { x = nx, y = ny }
    end

    -- Build left and right offset curves
    local left = {}
    local right = {}

    for i = 1, n do
        local n1 = normals[math_min(i, n-1)]
        local n0 = normals[math.max(i - 1, 1)]
        local is_first = (i == 1)
        local is_last = (i == n)
        local is_endpoint = (is_first or is_last) and not closed

        if is_endpoint then
            -- Use single segment normal
            local norm = is_first and normals[1] or normals[n-1]
            left[#left + 1]  = { x = pts[i].x + norm.x * hw, y = pts[i].y + norm.y * hw }
            right[#right + 1] = { x = pts[i].x - norm.x * hw, y = pts[i].y - norm.y * hw }
        else
            -- Join: average normals
            local mod_base = n - (closed and 0 or 1)
            local prev_idx = (i - 2) % mod_base + 1
            local curr_idx = (i - 1) % mod_base + 1
            -- Wrap to valid normal range [1, n-1] for closed paths
            if prev_idx > n - 1 then prev_idx = closed and ((prev_idx - 1) % (n - 1) + 1) or (n - 1) end
            if curr_idx > n - 1 then curr_idx = closed and ((curr_idx - 1) % (n - 1) + 1) or (n - 1) end

            local nx0, ny0 = normals[prev_idx].x, normals[prev_idx].y
            local nx1, ny1 = normals[curr_idx].x, normals[curr_idx].y

            -- Average normal direction
            local mx, my = normalize(nx0 + nx1, ny0 + ny1)

            -- Compute miter length
            local dot = nx0 * mx + ny0 * my
            if math_abs(dot) < 1e-6 then dot = 1e-6 end
            local miter_len = hw / dot

            local use_miter = linejoin == "miter" and (miter_len / hw) <= miterlimit

            if use_miter then
                left[#left + 1]  = { x = pts[i].x + mx * miter_len, y = pts[i].y + my * miter_len }
                right[#right + 1] = { x = pts[i].x - mx * miter_len, y = pts[i].y - my * miter_len }
            elseif linejoin == "round" then
                -- Left side: arc from n0 to n1
                local a0 = math_atan2(ny0, nx0)
                local a1 = math_atan2(ny1, nx1)
                -- Fix winding
                local da = a1 - a0
                if da > math_pi then a1 = a1 - 2 * math_pi
                elseif da < -math_pi then a1 = a1 + 2 * math_pi end
                arc_points(pts[i].x, pts[i].y, hw, a0, a1, left)
                -- Right side: opposite arc
                arc_points(pts[i].x, pts[i].y, hw, a0 + math_pi, a1 + math_pi, right)
            else
                -- Bevel: two points
                left[#left + 1]  = { x = pts[i].x + nx0 * hw, y = pts[i].y + ny0 * hw }
                left[#left + 1]  = { x = pts[i].x + nx1 * hw, y = pts[i].y + ny1 * hw }
                right[#right + 1] = { x = pts[i].x - nx0 * hw, y = pts[i].y - ny0 * hw }
                right[#right + 1] = { x = pts[i].x - nx1 * hw, y = pts[i].y - ny1 * hw }
            end
        end
    end

    -- Build outline polygon: left forward + right reversed
    local outline = {}
    for i = 1, #left do
        outline[#outline + 1] = left[i]
    end
    for i = #right, 1, -1 do
        outline[#outline + 1] = right[i]
    end

    -- Add line caps for open paths
    if not closed and n >= 2 then
        if linecap == "round" then
            -- Start cap
            local n1 = normals[1]
            local a_start = math_atan2(n1.y, n1.x)
            local cap_start = {}
            arc_points(pts[1].x, pts[1].y, hw, a_start + math_pi * 0.5, a_start + math_pi * 1.5, cap_start)
            -- End cap
            local nn = normals[n-1]
            local a_end = math_atan2(nn.y, nn.x)
            local cap_end = {}
            arc_points(pts[n].x, pts[n].y, hw, a_end - math_pi * 0.5, a_end + math_pi * 0.5, cap_end)
            -- Return outline + caps as separate polylines for rasterizer
            return { outline, cap_start, cap_end }
        elseif linecap == "square" then
            -- Extend endpoints by hw along tangent
            local dx1, dy1 = normalize(pts[2].x - pts[1].x, pts[2].y - pts[1].y)
            outline[1].x = outline[1].x - dx1 * hw
            outline[1].y = outline[1].y - dy1 * hw
            outline[#left].x = outline[#left].x - dx1 * hw
            outline[#left].y = outline[#left].y - dy1 * hw

            local dxn, dyn = normalize(pts[n].x - pts[n-1].x, pts[n].y - pts[n-1].y)
            local ri_start = #left + 1
            outline[ri_start].x = outline[ri_start].x + dxn * hw
            outline[ri_start].y = outline[ri_start].y + dyn * hw
            outline[#outline].x = outline[#outline].x + dxn * hw
            outline[#outline].y = outline[#outline].y + dyn * hw
        end
        -- butt: nothing extra
    end

    return { outline }
end

return StrokeTessellator



