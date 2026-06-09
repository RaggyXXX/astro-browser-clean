------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / crop_cache.lua
-- Glyph texture cropping for software scissor.
--
-- When a glyph overlaps a clip boundary, this module crops
-- the alpha buffer and creates a new texture showing only
-- the visible portion.  Cropped textures are cached by
-- (original tex_id, crop parameters) to avoid re-encoding
-- each frame.
--
-- This is the fundamental solution to clipping without GPU
-- scissor: instead of cull-or-draw, we actually crop the
-- pixel data at clip boundaries.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Rasterizer = require("core/fonts/rasterizer")

local CropCache = {}
CropCache.__index = CropCache

function CropCache.new(platform)
    return setmetatable({
        _platform = platform,
        _cache    = {},   -- [key] -> { tex_id, w, h }
        _gen      = 0,    -- generation counter for cleanup
    }, CropCache)
end

--- Build a cache key from original tex_id + crop amounts.
local function make_key(tex_id, crop_t, crop_b, crop_l, crop_r)
    -- Use string key for exact matching
    return tex_id .. ":" .. crop_t .. ":" .. crop_b .. ":" .. crop_l .. ":" .. crop_r
end

--- Crop a glyph's alpha buffer and return a texture for the
--- visible portion.
---
---@param glyph     table   Glyph data from GlyphCache (must have alpha_buf, buf_w, buf_h, tex_id)
---@param crop_t    number  Rows to remove from top (>= 0)
---@param crop_b    number  Rows to remove from bottom (>= 0)
---@param crop_l    number  Columns to remove from left (>= 0)
---@param crop_r    number  Columns to remove from right (>= 0)
---@return number|nil tex_id  Cropped texture ID
---@return number     w       Cropped width
---@return number     h       Cropped height
function CropCache:get(glyph, crop_t, crop_b, crop_l, crop_r)
    local key = make_key(glyph.tex_id, crop_t, crop_b, crop_l, crop_r)

    local cached = self._cache[key]
    if cached then
        cached.gen = self._gen
        return cached.tex_id, cached.w, cached.h
    end

    local src_w = glyph.buf_w
    local src_h = glyph.buf_h
    local src   = glyph.alpha_buf

    local new_w = src_w - crop_l - crop_r
    local new_h = src_h - crop_t - crop_b
    if new_w <= 0 or new_h <= 0 then return nil, 0, 0 end

    -- Extract visible region from alpha buffer
    local dst = {}
    local di = 0
    for row = crop_t, src_h - crop_b - 1 do
        local base = row * src_w
        for col = crop_l, src_w - crop_r - 1 do
            di = di + 1
            dst[di] = src[base + col + 1]
        end
    end

    -- PNG encode and load texture
    local png = Rasterizer.encode_png(dst, new_w, new_h)
    local ok, tex_id = pcall(self._platform.load_texture, self._platform, png)
    if not ok or not tex_id then return nil, 0, 0 end

    self._cache[key] = { tex_id = tex_id, w = new_w, h = new_h, gen = self._gen }
    return tex_id, new_w, new_h
end

--- Advance generation and purge entries older than 2 generations.
--- Call once per frame.
function CropCache:tick()
    self._gen = self._gen + 1
    -- Purge stale entries every 120 frames (~2s at 60fps)
    if self._gen % 120 == 0 then
        local cutoff = self._gen - 120
        for k, v in pairs(self._cache) do
            if v.gen < cutoff then
                if self._platform and self._platform.release_texture and v.tex_id then
                    self._platform:release_texture(v.tex_id)
                end
                self._cache[k] = nil
            end
        end
    end
end

return CropCache



