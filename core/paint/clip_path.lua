------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / clip_path.lua
-- CSS clip-path support: inset, circle, ellipse, polygon.
--
-- GPU scissor (dl:clip_push) provides rectangular clipping.
-- For inset(), the scissor rect matches exactly.  For
-- circle() and ellipse(), the scissor provides the AABB and
-- painters use shaped drawing commands (circle_fill, rounded
-- rect_fill) for visual masking.  Polygon uses AABB only.
-- Exact shapes are used for hit testing (ray casting, etc.).
--
-- Supported values:
--   inset(top right bottom left round radius)
--   circle(radius at cx cy)
--   ellipse(rx ry at cx cy)
--   polygon(x1 y1, x2 y2, ...)
--
-- Percentage values stored as strings ("50%"), resolved at
-- apply time relative to the layout box.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ClipPath = {}

local math_min  = math.min
local math_max  = math.max
local math_abs  = math.abs
local math_sqrt = math.sqrt
local math_huge = math.huge

local tonumber  = tonumber
local type      = type

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

--- Strip leading/trailing whitespace.
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

--- Parse a single length value (px number or percentage string).
--- Returns a number (px) or a string like "50%" for percentages.
local function parse_length(s)
    s = trim(s)
    if s:sub(-1) == "%" then
        return s  -- keep as string for later resolution
    end
    -- strip optional "px" suffix
    local n = tonumber(s:match("^([%d%.%-]+)px?$")) or tonumber(s)
    return n
end

--- Resolve a length value against a reference dimension.
--- Strings ending in "%" are resolved as fraction * ref.
--- Numbers pass through unchanged.
local function resolve(val, ref)
    if type(val) == "string" then
        local pct = tonumber(val:match("^([%d%.%-]+)%%$"))
        if pct then
            return pct / 100 * ref
        end
        -- fallback: try as plain number
        return tonumber(val) or 0
    end
    return val or 0
end

--- For circle(), omitted radius resolves to closest-side. Explicit
--- percentages resolve against sqrt(w^2 + h^2) / sqrt(2).
local function resolve_circle_radius(val, w, h)
    if type(val) == "string" then
        if val == "closest-side" then
            return math_min(w, h) * 0.5
        end
        local pct = tonumber(val:match("^([%d%.%-]+)%%$"))
        if pct then
            -- CSS spec: percentage resolved against
            -- sqrt(width^2 + height^2) / sqrt(2)
            local ref = math_sqrt(w * w + h * h) / 1.4142135623731
            return pct / 100 * ref
        end
        return tonumber(val) or 0
    end
    return val or 0
end

------------------------------------------------------------
-- Tokenizer for clip-path function arguments
------------------------------------------------------------

--- Split a string by commas, trimming each part.
local function split_comma(s)
    local parts = {}
    for part in s:gmatch("[^,]+") do
        parts[#parts + 1] = trim(part)
    end
    return parts
end

--- Collect whitespace-separated tokens from a string.
local function tokenize(s)
    local tokens = {}
    for tok in s:gmatch("%S+") do
        tokens[#tokens + 1] = tok
    end
    return tokens
end

------------------------------------------------------------
-- Parsers for each clip-path function
------------------------------------------------------------

--- Parse inset(top right bottom left round radius)
local function parse_inset(args)
    -- Split at "round" keyword
    local main, round_part = args:match("^(.-)%s+round%s+(.+)$")
    if not main then
        main = args
    end

    local tokens = tokenize(main)
    local top, right, bottom, left

    if #tokens == 1 then
        top = parse_length(tokens[1])
        right = top; bottom = top; left = top
    elseif #tokens == 2 then
        top = parse_length(tokens[1])
        right = parse_length(tokens[2])
        bottom = top; left = right
    elseif #tokens == 3 then
        top = parse_length(tokens[1])
        right = parse_length(tokens[2])
        bottom = parse_length(tokens[3])
        left = right
    elseif #tokens >= 4 then
        top = parse_length(tokens[1])
        right = parse_length(tokens[2])
        bottom = parse_length(tokens[3])
        left = parse_length(tokens[4])
    else
        return nil
    end

    local round = 0
    if round_part then
        round = parse_length(trim(round_part)) or 0
    end

    return {
        type   = "inset",
        top    = top,
        right  = right,
        bottom = bottom,
        left   = left,
        round  = round,
    }
end

--- Parse circle(radius at cx cy)
--- Defaults: radius=closest-side, cx=50%, cy=50%
local function parse_circle(args)
    local radius = "closest-side"
    local cx = "50%"
    local cy = "50%"

    -- Check for "at" keyword
    local before_at, after_at = args:match("^(.-)%s+at%s+(.+)$")
    if before_at then
        local r = trim(before_at)
        if r ~= "" then
            radius = parse_length(r)
            -- keep percentage strings
            if type(radius) ~= "string" and radius == nil then
                radius = "closest-side"
            end
        end
        local pos_tokens = tokenize(after_at)
        if pos_tokens[1] then cx = parse_length(pos_tokens[1]) end
        if pos_tokens[2] then cy = parse_length(pos_tokens[2]) end
    else
        local r = trim(args)
        if r ~= "" then
            radius = parse_length(r)
            if type(radius) ~= "string" and radius == nil then
                radius = "closest-side"
            end
        end
    end

    return {
        type   = "circle",
        radius = radius,
        cx     = cx,
        cy     = cy,
    }
end

--- Parse ellipse(rx ry at cx cy)
--- Defaults: rx=50%, ry=50%, cx=50%, cy=50%
local function parse_ellipse(args)
    local rx = "50%"
    local ry = "50%"
    local cx = "50%"
    local cy = "50%"

    local before_at, after_at = args:match("^(.-)%s+at%s+(.+)$")
    if before_at then
        local tokens = tokenize(before_at)
        if tokens[1] then rx = parse_length(tokens[1]) end
        if tokens[2] then ry = parse_length(tokens[2]) end
        local pos_tokens = tokenize(after_at)
        if pos_tokens[1] then cx = parse_length(pos_tokens[1]) end
        if pos_tokens[2] then cy = parse_length(pos_tokens[2]) end
    else
        local tokens = tokenize(args)
        if tokens[1] then rx = parse_length(tokens[1]) end
        if tokens[2] then ry = parse_length(tokens[2]) end
    end

    return {
        type = "ellipse",
        rx   = rx,
        ry   = ry,
        cx   = cx,
        cy   = cy,
    }
end

--- Parse polygon(x1 y1, x2 y2, ...)
--- Percentage values are stored as fractions (0..1).
local function parse_polygon(args)
    local pairs_list = split_comma(args)
    local points = {}

    for i = 1, #pairs_list do
        local tokens = tokenize(pairs_list[i])
        if #tokens >= 2 then
            local px = parse_length(tokens[1])
            local py = parse_length(tokens[2])
            points[#points + 1] = { px, py }
        end
    end

    if #points < 3 then
        return nil
    end

    return {
        type   = "polygon",
        points = points,
    }
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Parse a clip-path string value into a structured description.
---@param val string|table  clip-path CSS value
---@return table|nil  parsed clip-path or nil if invalid
function ClipPath.parse(val)
    if type(val) == "table" then
        -- already parsed
        if val.type then return val end
        return nil
    end
    if type(val) ~= "string" then
        return nil
    end

    val = trim(val)
    if val == "" or val == "none" then
        return nil
    end

    -- Match function-style: name(args)
    local fname, fargs = val:match("^(%a+)%s*%((.*)%)$")
    if not fname then
        return nil
    end

    fname = fname:lower()

    if fname == "inset" then
        return parse_inset(fargs)
    elseif fname == "circle" then
        return parse_circle(fargs)
    elseif fname == "ellipse" then
        return parse_ellipse(fargs)
    elseif fname == "polygon" then
        return parse_polygon(fargs)
    end

    return nil
end

--- Apply clip-path as a scissor rect approximation.
--- Pushes a clip rect onto the display list.
---@param dl table  display list
---@param parsed table  parsed clip-path from ClipPath.parse()
---@param lay table  layout box {x, y, w, h}
---@return boolean  true if clip was pushed (caller must pop)
function ClipPath.push_clip(dl, parsed, lay)
    if not parsed or not lay then
        return false
    end

    local lx, ly, lw, lh = lay.x, lay.y, lay.w, lay.h
    local t = parsed.type

    if t == "inset" then
        local top    = resolve(parsed.top,    lh)
        local right  = resolve(parsed.right,  lw)
        local bottom = resolve(parsed.bottom, lh)
        local left   = resolve(parsed.left,   lw)

        local cx = lx + left
        local cy = ly + top
        local cw = lw - left - right
        local ch = lh - top - bottom

        if cw <= 0 or ch <= 0 then
            -- fully clipped -" push zero-size rect
            dl:clip_push(lx, ly, 0, 0)
            return true
        end

        dl:clip_push(cx, cy, cw, ch)
        return true

    elseif t == "circle" then
        local cx_val = resolve(parsed.cx, lw)
        local cy_val = resolve(parsed.cy, lh)
        local r = resolve_circle_radius(parsed.radius, lw, lh)

        -- Absolute center position
        local acx = lx + cx_val
        local acy = ly + cy_val

        -- Bounding box of circle, clamped to layout box
        local bx = math_max(lx, acx - r)
        local by = math_max(ly, acy - r)
        local bx2 = math_min(lx + lw, acx + r)
        local by2 = math_min(ly + lh, acy + r)

        local bw = bx2 - bx
        local bh = by2 - by

        if bw <= 0 or bh <= 0 then
            dl:clip_push(lx, ly, 0, 0)
            return true
        end

        dl:clip_push(bx, by, bw, bh)
        return true

    elseif t == "ellipse" then
        local cx_val = resolve(parsed.cx, lw)
        local cy_val = resolve(parsed.cy, lh)
        local rx = resolve(parsed.rx, lw)
        local ry = resolve(parsed.ry, lh)

        local acx = lx + cx_val
        local acy = ly + cy_val

        local bx = math_max(lx, acx - rx)
        local by = math_max(ly, acy - ry)
        local bx2 = math_min(lx + lw, acx + rx)
        local by2 = math_min(ly + lh, acy + ry)

        local bw = bx2 - bx
        local bh = by2 - by

        if bw <= 0 or bh <= 0 then
            dl:clip_push(lx, ly, 0, 0)
            return true
        end

        dl:clip_push(bx, by, bw, bh)
        return true

    elseif t == "polygon" then
        local pts = parsed.points
        if not pts or #pts < 3 then
            return false
        end

        -- Bounding-box clip.  True per-vertex polygon clipping needs an
        -- alpha-mask primitive in the display list (see clip_mask_push +
        -- MaskCache pipeline).  Until that lands, AABB is the conservative
        -- choice -" paint may overflow the polygon edges, but hit-test
        -- (which is exact) hides interaction outside the shape, and AABB
        -- never *under*-clips legitimate content the way a mid-row
        -- inscribed-extent approximation does for non-convex polygons.
        local min_x, min_y =  math_huge,  math_huge
        local max_x, max_y = -math_huge, -math_huge
        for i = 1, #pts do
            local ax = lx + resolve(pts[i][1], lw)
            local ay = ly + resolve(pts[i][2], lh)
            if ax < min_x then min_x = ax end
            if ay < min_y then min_y = ay end
            if ax > max_x then max_x = ax end
            if ay > max_y then max_y = ay end
        end

        if min_x < lx then min_x = lx end
        if min_y < ly then min_y = ly end
        if max_x > lx + lw then max_x = lx + lw end
        if max_y > ly + lh then max_y = ly + lh end
        local bw = max_x - min_x
        local bh = max_y - min_y
        if bw <= 0 or bh <= 0 then
            dl:clip_push(lx, ly, 0, 0)
            return true
        end

        dl:clip_push(min_x, min_y, bw, bh)
        return true
    end

    return false
end

--- Resolve a parsed clip-path into absolute screen coordinates.
--- Returns a table with resolved shape parameters for use by painters.
---@param parsed table  parsed clip-path from ClipPath.parse()
---@param lay table  layout box {x, y, w, h}
---@return table|nil  resolved shape info, or nil if invalid
function ClipPath.resolve(parsed, lay)
    if not parsed or not lay then
        return nil
    end

    local lx, ly, lw, lh = lay.x, lay.y, lay.w, lay.h
    local t = parsed.type

    if t == "inset" then
        local top    = resolve(parsed.top,    lh)
        local right  = resolve(parsed.right,  lw)
        local bottom = resolve(parsed.bottom, lh)
        local left   = resolve(parsed.left,   lw)
        local round  = resolve(parsed.round,  math_min(lw, lh))

        local cx = lx + left
        local cy = ly + top
        local cw = lw - left - right
        local ch = lh - top - bottom

        if cw <= 0 or ch <= 0 then
            return { type = "inset", x = lx, y = ly, w = 0, h = 0, round = 0 }
        end

        return { type = "inset", x = cx, y = cy, w = cw, h = ch, round = round }

    elseif t == "circle" then
        local cx_val = resolve(parsed.cx, lw)
        local cy_val = resolve(parsed.cy, lh)
        local r = resolve_circle_radius(parsed.radius, lw, lh)

        return { type = "circle", cx = lx + cx_val, cy = ly + cy_val, r = r }

    elseif t == "ellipse" then
        local cx_val = resolve(parsed.cx, lw)
        local cy_val = resolve(parsed.cy, lh)
        local rx = resolve(parsed.rx, lw)
        local ry = resolve(parsed.ry, lh)

        return { type = "ellipse", cx = lx + cx_val, cy = ly + cy_val, rx = rx, ry = ry }

    elseif t == "polygon" then
        -- Polygon: resolve all points to absolute coordinates
        local pts = parsed.points
        if not pts or #pts < 3 then
            return nil
        end
        local abs_pts = {}
        for i = 1, #pts do
            abs_pts[i] = {
                lx + resolve(pts[i][1], lw),
                ly + resolve(pts[i][2], lh),
            }
        end
        return { type = "polygon", points = abs_pts }
    end

    return nil
end

--- Check if a point is inside the clip-path shape (for hit testing).
---@param parsed table  parsed clip-path
---@param lay table  layout box
---@param px number  point x
---@param py number  point y
---@return boolean  true if point is inside clip
function ClipPath.hit_test(parsed, lay, px, py)
    if not parsed or not lay then
        return true  -- no clip = everything passes
    end

    local lx, ly, lw, lh = lay.x, lay.y, lay.w, lay.h
    local t = parsed.type

    if t == "inset" then
        local top    = resolve(parsed.top,    lh)
        local right  = resolve(parsed.right,  lw)
        local bottom = resolve(parsed.bottom, lh)
        local left   = resolve(parsed.left,   lw)

        local cx = lx + left
        local cy = ly + top
        local cw = lw - left - right
        local ch = lh - top - bottom

        return px >= cx and px <= cx + cw
           and py >= cy and py <= cy + ch

    elseif t == "circle" then
        local cx_val = resolve(parsed.cx, lw)
        local cy_val = resolve(parsed.cy, lh)
        local r = resolve_circle_radius(parsed.radius, lw, lh)

        local acx = lx + cx_val
        local acy = ly + cy_val

        local dx = px - acx
        local dy = py - acy
        return (dx * dx + dy * dy) <= (r * r)

    elseif t == "ellipse" then
        local cx_val = resolve(parsed.cx, lw)
        local cy_val = resolve(parsed.cy, lh)
        local rx = resolve(parsed.rx, lw)
        local ry = resolve(parsed.ry, lh)

        if rx <= 0 or ry <= 0 then
            return false
        end

        local acx = lx + cx_val
        local acy = ly + cy_val

        local dx = (px - acx) / rx
        local dy = (py - acy) / ry
        return (dx * dx + dy * dy) <= 1.0

    elseif t == "polygon" then
        local pts = parsed.points
        if not pts or #pts < 3 then
            return false
        end

        -- Resolve all points to absolute coordinates
        local abs_pts = {}
        for i = 1, #pts do
            abs_pts[i] = {
                lx + resolve(pts[i][1], lw),
                ly + resolve(pts[i][2], lh),
            }
        end

        -- Ray casting algorithm (point-in-polygon)
        local inside = false
        local n = #abs_pts
        local j = n

        for i = 1, n do
            local xi, yi = abs_pts[i][1], abs_pts[i][2]
            local xj, yj = abs_pts[j][1], abs_pts[j][2]

            -- Check if ray from (px, py) going +X crosses edge (i, j)
            if (yi > py) ~= (yj > py) then
                local intersect_x = xj + (py - yj) / (yi - yj) * (xi - xj)
                if px < intersect_x then
                    inside = not inside
                end
            end

            j = i
        end

        return inside
    end

    return true  -- unknown type = no clip
end

return ClipPath



