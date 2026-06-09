------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / mask_cache.lua
-- Cache for rasterized SVG shape alpha masks.
-- Each unique (geometry + transform + size) combo produces
-- one alpha buffer + GPU texture.
--
-- Two indices:
--   _cache:    [exact_key] -> entry  (exact match)
--   _by_shape: [shape_key] -> { entry, ... }  (family lookup for resize)
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local Rasterizer = require("core/fonts/rasterizer")

local MaskCache = {}
MaskCache.__index = MaskCache

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local math_abs   = math.abs

local encode_png = Rasterizer.encode_png

function MaskCache:new(platform)
    return setmetatable({
        _platform  = platform,
        _cache     = {},   -- [key] -> { tex_id, w, h, buf }
        _failed    = {},   -- [key] -> true
        _by_shape  = {},   -- [shape_hash] -> { entry, ... }
        _crop_cache = {},  -- [crop_key] -> { tex_id, w, h }
    }, self)
end

--- Build a cache key from geometry hash + target pixel dimensions.
local function make_key(shape_hash, pw, ph)
    return shape_hash .. ":" .. pw .. ":" .. ph
end

--- Rasterize polylines at the given pixel size and cache the result.
---@param shape_hash string   Unique identifier for the shape geometry
---@param polylines  table    Array of polyline arrays (already transformed to pixel coords)
---@param pw         number   Pixel width
---@param ph         number   Pixel height
---@return table|nil  { tex_id, w, h }
function MaskCache:get_or_create(shape_hash, polylines, pw, ph, family_key, fill_rules)
    pw = math_max(1, math_floor(pw))
    ph = math_max(1, math_floor(ph))
    local key = make_key(shape_hash, pw, ph)

    local cached = self._cache[key]
    if cached then return cached end
    if self._failed[key] then return nil end

    if not polylines or #polylines == 0 then
        self._failed[key] = true
        return nil
    end

    -- Build a viewBox that matches the pixel output (identity mapping)
    local viewBox = { x = 0, y = 0, w = pw, h = ph }

    local png, out_w, out_h, buf = Rasterizer.rasterize(polylines, viewBox, pw, ph, fill_rules)
    if not png then
        self._failed[key] = true
        return nil
    end

    local ok, tex_id = pcall(self._platform.load_texture, self._platform, png, out_w, out_h)
    if not ok or not tex_id or tex_id == 0 then
        self._failed[key] = true
        return nil
    end

    local entry = {
        tex_id = tex_id,
        w      = out_w,
        h      = out_h,
        buf    = buf,
    }
    self._cache[key] = entry

    -- Also index by shape family for best-fit lookups during resize
    local fk = family_key or shape_hash
    local family = self._by_shape[fk]
    if not family then
        family = {}
        self._by_shape[fk] = family
    end
    family[#family + 1] = entry

    return entry
end

--- Find the closest cached texture for a shape (for live-resize stretching).
---@param shape_hash string  Shape family key (without size)
---@param target_w   number  Desired width
---@param target_h   number  Desired height
---@return table|nil  { tex_id, w, h }
function MaskCache:get_best_fit(shape_hash, target_w, target_h)
    local family = self._by_shape[shape_hash]
    if not family or #family == 0 then return nil end

    -- If no target size given, return the most recent entry
    if not target_w or not target_h then
        return family[#family]
    end

    local best, best_err = nil, 1e9
    for i = 1, #family do
        local e = family[i]
        local err = math_abs(e.w - target_w) + math_abs(e.h - target_h)
        if err < best_err then
            best = e
            best_err = err
        end
    end
    return best
end

--- Create a cropped texture from an entry's alpha buffer.
--- Caches results by exact crop rect to avoid repeated
--- PNG encode + texture upload for the same crop.
---@param entry table  Cache entry with .buf, .w, .h, .tex_id
---@param cx number    Crop x offset (pixels, integer)
---@param cy number    Crop y offset (pixels, integer)
---@param cw number    Crop width (pixels, integer)
---@param ch number    Crop height (pixels, integer)
---@return number|nil  tex_id of cropped texture
---@return number      cropped width
---@return number      cropped height
function MaskCache:create_cropped(entry, cx, cy, cw, ch)
    if not entry or not entry.buf then return nil end
    cx = math_max(0, math_floor(cx))
    cy = math_max(0, math_floor(cy))
    cw = math_max(1, math_floor(cw))
    ch = math_max(1, math_floor(ch))
    if cx + cw > entry.w then cw = entry.w - cx end
    if cy + ch > entry.h then ch = entry.h - cy end
    if cw < 1 or ch < 1 then return nil end

    -- Check crop cache (exact match)
    local crop_key = tostring(entry.tex_id) .. ":" .. cx .. ":" .. cy .. ":" .. cw .. ":" .. ch
    local cached = self._crop_cache[crop_key]
    if cached then
        return cached.tex_id, cached.w, cached.h
    end

    -- Extract sub-rect from alpha buffer
    local src = entry.buf
    local src_w = entry.w
    local sub = {}
    local di = 1
    for y = cy, cy + ch - 1 do
        local base = y * src_w
        for x = cx, cx + cw - 1 do
            sub[di] = src[base + x + 1]
            di = di + 1
        end
    end

    local png = encode_png(sub, cw, ch)
    if not png then return nil end
    local ok, tex_id = pcall(self._platform.load_texture, self._platform, png, cw, ch)
    if not ok or not tex_id or tex_id == 0 then return nil end

    -- Cache the result
    self._crop_cache[crop_key] = { tex_id = tex_id, w = cw, h = ch }
    return tex_id, cw, ch
end

--- Build run-length encoded spans from an alpha buffer.
--- Cached on the entry so subsequent calls are free.
--- Each row is a flat array: { x0, x1, alpha, x0, x1, alpha, ... }
---@param entry table  Cache entry with .buf, .w, .h
---@return table  Array of rows (1-indexed), each a flat span array
function MaskCache:build_runs(entry)
    if entry.runs then return entry.runs end
    local buf, w, h = entry.buf, entry.w, entry.h
    if not buf or not w or not h then return {} end
    local runs = {}
    for y = 0, h - 1 do
        local row = {}
        local base = y * w
        local x = 0
        while x < w do
            local a = buf[base + x + 1]
            if a and a > 0 then
                local x0 = x
                -- Merge consecutive pixels with same alpha into one span
                x = x + 1
                while x < w do
                    local na = buf[base + x + 1]
                    if na ~= a then break end
                    x = x + 1
                end
                row[#row + 1] = x0
                row[#row + 1] = x
                row[#row + 1] = a
            else
                x = x + 1
            end
        end
        runs[y + 1] = row
    end
    entry.runs = runs
    return runs
end

--- Emit clipped spans as rect_fill commands.
--- Reads directly from the alpha buffer via RLE spans and draws
--- 1px-high rect_fill calls. rect_fill is the only display list
--- primitive that clips properly (via rect_clip intersection).
---
--- This avoids the expensive encode_png + load_texture cycle that
--- create_cropped uses, making it suitable for every-frame use
--- during scroll/resize.
---@param dl      table   DisplayList
---@param entry   table   Cache entry with .buf, .w, .h
---@param cx      number  Crop x in buffer space (integer)
---@param cy      number  Crop y in buffer space (integer)
---@param cw      number  Crop width in buffer space (integer)
---@param ch      number  Crop height in buffer space (integer)
---@param dx      number  Screen x for top-left of crop output
---@param dy      number  Screen y for top-left of crop output
---@param r       number  Red 0-255
---@param g       number  Green 0-255
---@param b       number  Blue 0-255
---@param a_mul   number  Alpha multiplier 0-255
---@param sx      number|nil  Horizontal scale (buffer→screen), default 1
---@param sy      number|nil  Vertical scale (buffer→screen), default 1
function MaskCache:emit_spans(dl, entry, cx, cy, cw, ch, dx, dy, r, g, b, a_mul, sx, sy)
    local runs = self:build_runs(entry)
    if not runs then return end
    sx = sx or 1
    sy = sy or 1
    local cx_end = cx + cw
    local row_h = sy < 1.01 and sy > 0.99 and 1 or math_max(1, math_floor(sy + 0.5))
    for row = 0, ch - 1 do
        local rr = runs[cy + row + 1]
        if rr then
            local screen_y = dy + math_floor(row * sy)
            for i = 1, #rr, 3 do
                local x0, x1, sa = rr[i], rr[i + 1], rr[i + 2]
                -- Skip spans entirely outside crop region
                if x1 > cx and x0 < cx_end then
                    local rx0 = x0 < cx and cx or x0
                    local rx1 = x1 > cx_end and cx_end or x1
                    local out_a = math_floor(sa * a_mul / 255 + 0.5)
                    if rx1 > rx0 and out_a > 0 then
                        local screen_x = dx + math_floor((rx0 - cx) * sx)
                        local span_w = math_max(1, math_floor((rx1 - rx0) * sx))
                        dl:rect_fill(screen_x, screen_y, span_w, row_h, r, g, b, out_a, 0)
                    end
                end
            end
        end
    end
end

--- Clear entire cache (e.g. on window resize).
function MaskCache:clear()
    self._cache = {}
    self._failed = {}
    self._by_shape = {}
    self._crop_cache = {}
end

return MaskCache



