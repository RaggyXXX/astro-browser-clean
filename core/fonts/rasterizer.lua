------------------------------------------------------------
-- ext_core_astro_ui_lib / core / fonts / rasterizer.lua
-- Scanline rasterizer and PNG encoder for pixel-perfect
-- font glyph rendering.
--
-- Converts polylines from TtfParser into anti-aliased RGBA
-- PNG images. Uses scanline fill with the SVG nonzero
-- winding rule, which naturally handles holes without any
-- polygon bridging. Output is white-on-transparent PNG
-- suitable for color tinting via draw_texture().
--
-- Adapted from ext_lib_ultima_ui for Astro UI.
------------------------------------------------------------

local Rasterizer = {}

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local bit        = require("core/util/bit")
local math_floor = math.floor
local math_min   = math.min
local math_max   = math.max
local math_ceil  = math.ceil
local math_abs   = math.abs
local str_char   = string.char
local str_byte   = string.byte
local tbl_concat = table.concat
local band       = bit.band
local bxor       = bit.bxor
local rshift     = bit.rshift

--- Default output dimension (pixels, square).
local RASTER_SIZE = 64

--- Sub-scanlines per pixel row for anti-aliasing.
--- 8 gives smooth edges without excessive cost.
local AA_SAMPLES = 8

--- Raster behavior revision. GlyphCache folds this into texture cache keys
--- so deterministic hinting/raster changes cannot reuse older glyph images.
Rasterizer.CACHE_REVISION = 2

------------------------------------------------------------
-- CRC-32 (required for PNG chunk checksums)
------------------------------------------------------------

local crc32_table = {}
do
    local POLY = 0xEDB88320
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if band(c, 1) == 1 then
                c = bxor(rshift(c, 1), POLY)
            else
                c = rshift(c, 1)
            end
        end
        crc32_table[i] = c
    end
end

local function crc32(data)
    local c = 0xFFFFFFFF
    for i = 1, #data do
        c = bxor(crc32_table[band(bxor(c, str_byte(data, i)), 0xFF)],
                 rshift(c, 8))
    end
    return bxor(c, 0xFFFFFFFF)
end

------------------------------------------------------------
-- Adler-32 (required for zlib wrapper in PNG)
------------------------------------------------------------

local function adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + str_byte(data, i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

------------------------------------------------------------
-- Minimal PNG encoder
------------------------------------------------------------

local function be32(n)
    return str_char(band(rshift(n, 24), 0xFF),
                    band(rshift(n, 16), 0xFF),
                    band(rshift(n, 8), 0xFF),
                    band(n, 0xFF))
end

local function le16(n)
    return str_char(band(n, 0xFF), band(rshift(n, 8), 0xFF))
end

local function png_chunk(ctype, data)
    local payload = ctype .. data
    return be32(#data) .. payload .. be32(crc32(payload))
end

--- Precomputed 4-byte RGBA strings for each alpha level.
--- White (255,255,255) with variable alpha; color tinting
--- is applied at draw_texture time via multiplication.
local alpha_pixel = {}
for a = 0, 255 do
    alpha_pixel[a] = str_char(255, 255, 255, a)
end
local filter_none = str_char(0)

--- Encode an alpha buffer as a white-on-transparent PNG.
---@param buf table   buf[y*w + x + 1] = alpha (0..255)
---@param w number    Image width
---@param h number    Image height
---@return string     Binary PNG data
local function encode_png(buf, w, h)
    local parts = { str_char(137, 80, 78, 71, 13, 10, 26, 10) }
    local pn = 1

    -- IHDR: 8-bit RGBA
    pn = pn + 1
    parts[pn] = png_chunk("IHDR",
        be32(w) .. be32(h) .. str_char(8, 6, 0, 0, 0))

    -- Build raw scanline data (filter=None + RGBA per pixel)
    local rows = {}
    local rn = 0
    for y = 0, h - 1 do
        rn = rn + 1; rows[rn] = filter_none
        local base = y * w
        for x = 0, w - 1 do
            rn = rn + 1
            rows[rn] = alpha_pixel[buf[base + x + 1]]
        end
    end
    local raw = tbl_concat(rows)

    -- IDAT: zlib header + stored DEFLATE blocks + Adler-32
    local zlib = { str_char(0x78, 0x01) }
    local zn = 1
    local raw_len = #raw
    local pos = 1
    while pos <= raw_len do
        local blen = math_min(raw_len - pos + 1, 65535)
        local is_final = (pos + blen > raw_len) and 1 or 0
        zn = zn + 1; zlib[zn] = str_char(is_final)
        zn = zn + 1; zlib[zn] = le16(blen)
        zn = zn + 1; zlib[zn] = le16(band(bxor(blen, 0xFFFF), 0xFFFF))
        zn = zn + 1; zlib[zn] = raw:sub(pos, pos + blen - 1)
        pos = pos + blen
    end
    zn = zn + 1; zlib[zn] = be32(adler32(raw))

    pn = pn + 1
    parts[pn] = png_chunk("IDAT", tbl_concat(zlib))

    -- IEND
    pn = pn + 1
    parts[pn] = png_chunk("IEND", "")

    return tbl_concat(parts)
end

--- Encode an RGBA pixel buffer as PNG.
--- buf is a flat table: {r,g,b,a, r,g,b,a, ...} with 4 entries per pixel.
---@param buf table   RGBA pixel data (length = w*h*4)
---@param w   number  Image width
---@param h   number  Image height
---@return string     Binary PNG data
local function encode_rgba_png(buf, w, h)
    local parts = { str_char(137, 80, 78, 71, 13, 10, 26, 10) }
    local pn = 1

    pn = pn + 1
    parts[pn] = png_chunk("IHDR",
        be32(w) .. be32(h) .. str_char(8, 6, 0, 0, 0))

    local rows = {}
    local rn = 0
    for y = 0, h - 1 do
        rn = rn + 1; rows[rn] = filter_none
        local base = y * w * 4
        for x = 0, w - 1 do
            local pi = base + x * 4
            rn = rn + 1
            rows[rn] = str_char(buf[pi + 1], buf[pi + 2], buf[pi + 3], buf[pi + 4])
        end
    end
    local raw = tbl_concat(rows)

    local zlib = { str_char(0x78, 0x01) }
    local zn = 1
    local raw_len = #raw
    local pos = 1
    while pos <= raw_len do
        local blen = math_min(raw_len - pos + 1, 65535)
        local is_final = (pos + blen > raw_len) and 1 or 0
        zn = zn + 1; zlib[zn] = str_char(is_final)
        zn = zn + 1; zlib[zn] = le16(blen)
        zn = zn + 1; zlib[zn] = le16(band(bxor(blen, 0xFFFF), 0xFFFF))
        zn = zn + 1; zlib[zn] = raw:sub(pos, pos + blen - 1)
        pos = pos + blen
    end
    zn = zn + 1; zlib[zn] = be32(adler32(raw))

    pn = pn + 1
    parts[pn] = png_chunk("IDAT", tbl_concat(zlib))
    pn = pn + 1
    parts[pn] = png_chunk("IEND", "")

    return tbl_concat(parts)
end

------------------------------------------------------------
-- Scanline rasterizer
------------------------------------------------------------

--- Rasterize polylines into a PNG image.
---
--- Uses scanline fill with SVG nonzero winding rule and
--- multi-sample anti-aliasing. Holes are handled naturally
--- by opposite winding directions -- no polygon bridging
--- or preprocessing needed.
---
--- Output is white-on-transparent; color tinting happens
--- at draw time via draw_texture's color parameter.
---
--- When out_h is provided, uses non-uniform scaling to fill
--- the full out_w x out_h rectangle (for font glyphs where
--- draw_texture restores the correct aspect ratio).
--- When out_h is nil, uses uniform scaling centered in a
--- square output (for SVG icons).
---
---@param polylines  table   Array of polyline arrays from TtfParser
---@param viewBox    table   {x, y, w, h}
---@param out_w      number? Output width in pixels (default 64)
---@param out_h      number? Output height (nil = square + uniform scale)
---@param fill_rules nil|string|table  nil=nonzero, "evenodd"=all evenodd, table=per-polyline
---@return string           Binary PNG data
---@return number           Width
---@return number           Height
---@return table            Alpha buffer (0..255 per pixel)
function Rasterizer.rasterize(polylines, viewBox, out_w, out_h, fill_rules)
    out_w = out_w or RASTER_SIZE
    if out_w < 1 then return nil end

    -- Determine output mode
    local uniform = (out_h == nil)
    if uniform then out_h = out_w end
    if out_h < 1 then return nil end

    -- Determine fill rule mode:
    --   "nonzero"  = all polylines use nonzero (default, backward compatible)
    --   "evenodd"  = all polylines use evenodd
    --   "mixed"    = per-polyline rules (requires two-pass approach)
    local fill_mode = "nonzero"
    local fr_table = nil  -- per-polyline lookup when mixed
    if fill_rules then
        if type(fill_rules) == "string" then
            fill_mode = (fill_rules == "evenodd") and "evenodd" or "nonzero"
        elseif type(fill_rules) == "table" then
            -- Check if any polyline uses evenodd and if any uses nonzero
            local has_eo, has_nz = false, false
            for p = 1, #polylines do
                if fill_rules[p] == "evenodd" then
                    has_eo = true
                else
                    has_nz = true
                end
            end
            if has_eo and has_nz then
                fill_mode = "mixed"
                fr_table = fill_rules
            elseif has_eo then
                fill_mode = "evenodd"
            end
            -- else all nonzero (default)
        end
    end

    -- ViewBox -> pixel coordinate transform.
    local sx, sy, ox, oy
    if uniform then
        -- Uniform scaling: preserve aspect ratio, centered (icons).
        local scale = math_min(out_w / viewBox.w, out_h / viewBox.h)
        sx = scale
        sy = scale
        ox = -viewBox.x * sx + (out_w - viewBox.w * sx) / 2
        oy = -viewBox.y * sy + (out_h - viewBox.h * sy) / 2
    else
        -- Non-uniform scaling: fill entire output (font glyphs).
        sx = out_w / viewBox.w
        sy = out_h / viewBox.h
        ox = -viewBox.x * sx
        oy = -viewBox.y * sy
    end

    -- Build edge table from all polylines.
    local edges = {}
    local ne = 0

    for p = 1, #polylines do
        local poly = polylines[p]
        local pn = #poly
        if pn >= 3 then
            for i = 1, pn do
                local j = (i % pn) + 1  -- wraps last->first
                local px1 = poly[i].x * sx + ox
                local py1 = poly[i].y * sy + oy
                local px2 = poly[j].x * sx + ox
                local py2 = poly[j].y * sy + oy

                if py1 < py2 then
                    ne = ne + 1
                    edges[ne] = { px1, py1, px2, py2, 1, p }
                elseif py1 > py2 then
                    ne = ne + 1
                    edges[ne] = { px2, py2, px1, py1, -1, p }
                end
                -- py1 == py2: horizontal edge, skip
            end
        end
    end

    -- Winding test helper: nonzero vs evenodd
    local function is_fill_nz(w) return w ~= 0 end
    local function is_fill_eo(w) return w % 2 ~= 0 end

    -- Scanline rasterizer for a given edge set and winding test.
    -- Fills coverage into the provided buf (0..255 per pixel).
    local function rasterize_pass(edge_set, edge_count, is_fill, buf_out)
        local cov = {}
        for i = 0, out_w - 1 do cov[i] = 0 end

        local inv_aa = 1.0 / AA_SAMPLES

        for y = 0, out_h - 1 do
            -- Reset coverage for this row
            for i = 0, out_w - 1 do cov[i] = 0 end

            for s = 0, AA_SAMPLES - 1 do
                local scan_y = y + (s + 0.5) * inv_aa

                -- Collect intersections at this sub-scanline
                local ix_buf = {}
                local dir_buf = {}
                local ni = 0

                for e = 1, edge_count do
                    local edge = edge_set[e]
                    local ey1 = edge[2]
                    local ey2 = edge[4]
                    if scan_y >= ey1 and scan_y < ey2 then
                        local t = (scan_y - ey1) / (ey2 - ey1)
                        ni = ni + 1
                        ix_buf[ni] = edge[1] + t * (edge[3] - edge[1])
                        dir_buf[ni] = edge[5]
                    end
                end

                -- Insertion sort by x (fast for small n)
                for i = 2, ni do
                    local kx = ix_buf[i]
                    local kd = dir_buf[i]
                    local j = i - 1
                    while j >= 1 and ix_buf[j] > kx do
                        ix_buf[j + 1] = ix_buf[j]
                        dir_buf[j + 1] = dir_buf[j]
                        j = j - 1
                    end
                    ix_buf[j + 1] = kx
                    dir_buf[j + 1] = kd
                end

                -- Walk intersections with winding rule.
                local winding = 0
                local fill_x = nil

                for i = 1, ni do
                    local was_fill = is_fill(winding)
                    winding = winding + dir_buf[i]
                    local now_fill = is_fill(winding)

                    if not was_fill and now_fill then
                        fill_x = ix_buf[i]
                    elseif was_fill and not now_fill then
                        local x0 = math_max(fill_x, 0)
                        local x1 = math_min(ix_buf[i], out_w)
                        if x0 < x1 then
                            local px0 = math_floor(x0)
                            local px1 = math_min(math_floor(x1), out_w - 1)
                            if px0 == px1 then
                                cov[px0] = cov[px0] + (x1 - x0)
                            else
                                cov[px0] = cov[px0] + (px0 + 1 - x0)
                                for px = px0 + 1, px1 - 1 do
                                    cov[px] = cov[px] + 1
                                end
                                cov[px1] = cov[px1] + (x1 - px1)
                            end
                        end
                    end
                end
            end

            -- Convert coverage to alpha values
            local base = y * out_w
            for x = 0, out_w - 1 do
                local a = cov[x] * inv_aa
                if a > 0 then
                    if a > 1 then a = 1 end
                    buf_out[base + x + 1] = math_floor(a * 255 + 0.5)
                end
            end
        end
    end

    -- Alpha buffer (0..255 per pixel)
    local buf = {}
    local total = out_w * out_h
    for i = 1, total do buf[i] = 0 end

    if fill_mode == "mixed" then
        -- Two-pass: split edges by fill rule, rasterize separately, max-blend.
        local nz_edges, eo_edges = {}, {}
        local nz_ne, eo_ne = 0, 0
        for e = 1, ne do
            local edge = edges[e]
            if fr_table[edge[6]] == "evenodd" then
                eo_ne = eo_ne + 1
                eo_edges[eo_ne] = edge
            else
                nz_ne = nz_ne + 1
                nz_edges[nz_ne] = edge
            end
        end

        -- Rasterize nonzero group
        local buf_nz = {}
        for i = 1, total do buf_nz[i] = 0 end
        if nz_ne > 0 then
            rasterize_pass(nz_edges, nz_ne, is_fill_nz, buf_nz)
        end

        -- Rasterize evenodd group
        local buf_eo = {}
        for i = 1, total do buf_eo[i] = 0 end
        if eo_ne > 0 then
            rasterize_pass(eo_edges, eo_ne, is_fill_eo, buf_eo)
        end

        -- Max-blend both buffers
        for i = 1, total do
            local a = buf_nz[i]
            local b = buf_eo[i]
            buf[i] = (a > b) and a or b
        end
    else
        -- Single rule for all edges
        local is_fill = (fill_mode == "evenodd") and is_fill_eo or is_fill_nz
        rasterize_pass(edges, ne, is_fill, buf)
    end

    return encode_png(buf, out_w, out_h), out_w, out_h, buf
end

Rasterizer.encode_png = encode_png
Rasterizer.encode_rgba_png = encode_rgba_png

------------------------------------------------------------
-- Pragmatic UI-size autohinting
------------------------------------------------------------

local function clone_polylines(polylines)
    local out = {}
    for p = 1, #polylines do
        local src = polylines[p]
        local dst = {}
        for i = 1, #src do
            local pt = src[i]
            dst[i] = { x = pt.x, y = pt.y }
        end
        out[p] = dst
    end
    return out
end

local function round_nearest(v)
    if v >= 0 then return math_floor(v + 0.5) end
    return -math_floor(-v + 0.5)
end

local function insert_edge(edges, n, pos, span)
    if span < 0.65 then return n end
    n = n + 1
    edges[n] = { pos = pos, span = span }
    return n
end

local function collect_axis_edges(polylines, scale, axis)
    local edges = {}
    local n = 0
    for p = 1, #polylines do
        local poly = polylines[p]
        local pn = #poly
        for i = 1, pn do
            local j = (i % pn) + 1
            local a, b = poly[i], poly[j]
            if axis == "x" then
                local dx = (b.x - a.x) * scale
                local dy = (b.y - a.y) * scale
                if math_abs(dx) <= 0.18 and math_abs(dy) >= 1.8 then
                    n = insert_edge(edges, n, ((a.x + b.x) * 0.5) * scale, math_abs(dy))
                end
            else
                local dx = (b.x - a.x) * scale
                local dy = (b.y - a.y) * scale
                if math_abs(dy) <= 0.18 and math_abs(dx) >= 1.8 then
                    n = insert_edge(edges, n, ((a.y + b.y) * 0.5) * scale, math_abs(dx))
                end
            end
        end
    end
    return edges, n
end

local function sort_edges(edges, n)
    for i = 2, n do
        local key = edges[i]
        local j = i - 1
        while j >= 1 and edges[j].pos > key.pos do
            edges[j + 1] = edges[j]
            j = j - 1
        end
        edges[j + 1] = key
    end
end

local function cluster_edges(edges, n)
    if n == 0 then return {}, 0 end
    sort_edges(edges, n)
    local clusters = {}
    local cn = 0
    local sum, weight, pos0 = 0, 0, nil
    for i = 1, n do
        local e = edges[i]
        if not pos0 or math_abs(e.pos - pos0) <= 0.32 then
            pos0 = pos0 or e.pos
            sum = sum + e.pos * e.span
            weight = weight + e.span
        else
            cn = cn + 1
            clusters[cn] = { pos = sum / weight, weight = weight }
            pos0 = e.pos
            sum = e.pos * e.span
            weight = e.span
        end
    end
    cn = cn + 1
    clusters[cn] = { pos = sum / weight, weight = weight }
    return clusters, cn
end

local function build_axis_hints(clusters, count, pixel_size)
    local hints = {}
    local hn = 0
    local max_delta = (pixel_size <= 14) and 0.22 or 0.16
    local influence = (pixel_size <= 14) and 0.95 or 0.78

    for i = 1, count do
        local c = clusters[i]
        if c.weight >= 2.4 then
            local target = round_nearest(c.pos)
            local delta = target - c.pos
            if math_abs(delta) > 0.01 and math_abs(delta) <= max_delta then
                hn = hn + 1
                hints[hn] = { pos = c.pos, delta = delta, radius = influence, weight = c.weight }
            end
        end
    end
    return hints, hn
end

local function apply_axis_hints(polylines, scale, axis, hints, hint_count)
    if hint_count == 0 then return end
    for p = 1, #polylines do
        local poly = polylines[p]
        for i = 1, #poly do
            local pt = poly[i]
            local px = (axis == "x") and (pt.x * scale) or (pt.y * scale)
            local delta, weight = 0, 0
            for h = 1, hint_count do
                local hint = hints[h]
                local dist = math_abs(px - hint.pos)
                if dist < hint.radius then
                    local w = 1.0 - (dist / hint.radius)
                    w = w * w
                    delta = delta + hint.delta * w
                    weight = weight + w
                end
            end
            if weight > 0 then
                local d_units = (delta / weight) / scale
                if axis == "x" then
                    pt.x = pt.x + d_units
                else
                    pt.y = pt.y + d_units
                end
            end
        end
    end
end

local function append_hint_signature(parts, prefix, hints, hint_count)
    parts[#parts + 1] = prefix
    parts[#parts + 1] = tostring(hint_count)
    for i = 1, hint_count do
        local h = hints[i]
        parts[#parts + 1] = ":"
        parts[#parts + 1] = tostring(round_nearest(h.pos * 64))
        parts[#parts + 1] = "/"
        parts[#parts + 1] = tostring(round_nearest(h.delta * 256))
    end
end

local function recompute_bbox(polylines)
    local xMin, yMin, xMax, yMax = 1e30, 1e30, -1e30, -1e30
    for p = 1, #polylines do
        local poly = polylines[p]
        for i = 1, #poly do
            local pt = poly[i]
            if pt.x < xMin then xMin = pt.x end
            if pt.x > xMax then xMax = pt.x end
            if pt.y < yMin then yMin = pt.y end
            if pt.y > yMax then yMax = pt.y end
        end
    end
    if xMin == 1e30 then return nil end
    return { xMin = xMin, yMin = yMin, xMax = xMax, yMax = yMax }
end

--- Light autohinting for grayscale UI text. This intentionally avoids full
--- TrueType bytecode behavior; it only nudges strong vertical and horizontal
--- outline features toward nearby device-pixel edges when the correction is
--- small enough to preserve the font's shape.
function Rasterizer.fit_glyph_stems(polylines, bbox, units_per_em, pixel_size)
    if not polylines or not bbox or not units_per_em or not pixel_size then
        return polylines, bbox, "off"
    end
    if pixel_size < 9 or pixel_size > 24 then
        return polylines, bbox, "off"
    end

    local scale = pixel_size / units_per_em
    local fitted = clone_polylines(polylines)

    local x_edges, x_count = collect_axis_edges(fitted, scale, "x")
    local y_edges, y_count = collect_axis_edges(fitted, scale, "y")
    local x_clusters, xc = cluster_edges(x_edges, x_count)
    local y_clusters, yc = cluster_edges(y_edges, y_count)
    local x_hints, xh = build_axis_hints(x_clusters, xc, pixel_size)
    local y_hints, yh = build_axis_hints(y_clusters, yc, pixel_size)

    apply_axis_hints(fitted, scale, "x", x_hints, xh)
    apply_axis_hints(fitted, scale, "y", y_hints, yh)

    local new_bbox = recompute_bbox(fitted) or bbox
    local sig = { "ui" }
    append_hint_signature(sig, "x", x_hints, xh)
    append_hint_signature(sig, "y", y_hints, yh)
    return fitted, new_bbox, tbl_concat(sig)
end

return Rasterizer



