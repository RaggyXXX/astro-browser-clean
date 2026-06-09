------------------------------------------------------------
-- ext_core_astro_ui_lib / core / fonts / glyph_cache.lua
-- Per-font glyph texture cache.
--
-- Stores rasterized glyph textures and metrics for a single
-- parsed font. Glyphs are rasterized on-demand using the
-- scanline rasterizer from core/fonts/rasterizer.lua.
--
-- Each glyph is rasterized at a resolution matched to its
-- display size (with a small margin for AA). The alpha
-- buffer is stored alongside the GPU texture to enable
-- per-pixel rendering at clip boundaries.
--
-- Adapted from ext_lib_ultima_ui for Astro UI.
-- Uses platform adapter for load_texture instead of core.*.
------------------------------------------------------------

local TtfParser  = require("core/fonts/ttf_parser")
local TtfInterpreter = require("core/fonts/ttf_interpreter")
local Rasterizer = require("core/fonts/rasterizer")

local GlyphCache = {}
GlyphCache.__index = GlyphCache

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local math_floor = math.floor
local math_ceil  = math.ceil
local math_max   = math.max
local math_min   = math.min

-- Canvas2D tints glyph alpha textures and then lets the browser composite
-- source-over in its native pipeline.  Chrome text rendering is closer to
-- linear-light blending, so pure coverage alpha tends to make anti-aliased
-- edges too dark in the Studio path.  This LUT approximates the alpha that
-- sRGB source-over needs to produce a linear-light black-on-light edge, mixed
-- conservatively to avoid thinning Inter/Fira stems.
local GAMMA_ALPHA_STRENGTH = 0.45
local gamma_alpha_lut = {}
do
    local function linear_to_srgb(v)
        if v <= 0.0031308 then
            return 12.92 * v
        end
        return 1.055 * (v ^ (1.0 / 2.4)) - 0.055
    end

    for a = 0, 255 do
        local coverage = a / 255
        local gamma_alpha = 1.0 - linear_to_srgb(1.0 - coverage)
        local mixed = coverage + (gamma_alpha - coverage) * GAMMA_ALPHA_STRENGTH
        gamma_alpha_lut[a] = math_floor(mixed * 255 + 0.5)
    end
end

local STANDARD_LIGATURES = {
    { seq = { 0x66, 0x66, 0x69 }, cp = 0xFB03 }, -- ffi
    { seq = { 0x66, 0x66, 0x6C }, cp = 0xFB04 }, -- ffl
    { seq = { 0x66, 0x66 },       cp = 0xFB00 }, -- ff
    { seq = { 0x66, 0x69 },       cp = 0xFB01 }, -- fi
    { seq = { 0x66, 0x6C },       cp = 0xFB02 }, -- fl
}

local function ligature_matches(cps, index, seq)
    if index + #seq - 1 > #cps then return false end
    for i = 1, #seq do
        if cps[index + i - 1] ~= seq[i] then return false end
    end
    return true
end

local function normalize_axis_value(axis, avar_segments, value)
    if value < axis.min then value = axis.min end
    if value > axis.max then value = axis.max end

    local norm
    if value == axis.default then
        norm = 0
    elseif value < axis.default then
        norm = -(axis.default - value) / (axis.default - axis.min)
    else
        norm = (value - axis.default) / (axis.max - axis.default)
    end

    if avar_segments then
        for j = 2, #avar_segments do
            if norm <= avar_segments[j].from then
                local s0 = avar_segments[j - 1]
                local s1 = avar_segments[j]
                local range = s1.from - s0.from
                if math.abs(range) > 0.0001 then
                    local t = (norm - s0.from) / range
                    norm = s0.to + t * (s1.to - s0.to)
                else
                    norm = s1.to
                end
                break
            end
        end
    end

    return norm
end

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new GlyphCache for a parsed font.
---@param font        table  Parsed font from TtfParser.parse()
---@param platform    table  Platform adapter (must have :load_texture)
---@param norm_coords table|nil  Normalized variation coordinates for variable fonts
---@param embolden    number|nil  Synthetic weight strength (0=normal, >0=bolder, <0=lighter)
---@return table GlyphCache instance
function GlyphCache:new(font, platform, norm_coords, embolden)
    local o = {
        _font        = font,
        _platform    = platform,
        _norm_coords = norm_coords,  -- nil for static fonts, table for variable instances
        _embolden    = embolden or 0, -- synthetic weight adjustment
        _size_caches = {},   -- [pixel_size*64 rounded] -> { [glyph_index] -> glyph_data }
        _no_texture  = {},   -- [pixel_size..":"..glyph_index] -> true
        _ttf_hint_fail_logged = {},
        _ttf_hint_broken_logged = false,
        _hint_stats = {
            hinted_glyphs = 0,
            unhinted_glyphs = 0,
            fallback_count = 0,
            opcode_coverage = {},
        },
        _use_my_metrics = {},
    }
    return setmetatable(o, self)
end

function GlyphCache:_hint_mode_signature()
    if self._font and self._font.enable_ttf_hinting == true
       and self._font._ttf_hinting_disabled_session ~= true then
        return "tt:on"
    end
    return "tt:off"
end

local function classify_hint_failure(telemetry)
    local reason = tostring(telemetry and telemetry.fail_reason or "unknown")
    local lower = string.lower(reason)
    if lower:find("not implemented", 1, true)
       or lower:find("unsupported", 1, true)
       or lower:find("composite", 1, true)
       or lower:find("missing truetype", 1, true)
       or lower:find("no hintable", 1, true) then
        return "expected", reason
    end
    if lower:find("stack underflow", 1, true)
       or lower:find("stack overflow", 1, true)
       or lower:find("cycle", 1, true)
       or lower:find("budget", 1, true)
       or lower:find("depth", 1, true)
       or lower:find("truncated", 1, true)
       or lower:find("out%-of%-bounds")
       or lower:find("division", 1, true)
       or lower:find("div by zero", 1, true) then
        return "broken", reason
    end
    return "expected", reason
end

local function merge_opcode_coverage(dst, telemetry)
    if not telemetry then return end
    local counts = telemetry.opcode_counts
    if counts then
        for opcode, count in pairs(counts) do
            if type(opcode) == "number" then
                local key = string.format("0x%02X", opcode)
                dst[key] = (dst[key] or 0) + (count or 0)
            end
        end
    end
    local unsupported = telemetry.unsupported
    if unsupported then
        for opcode, count in pairs(unsupported) do
            dst[opcode] = (dst[opcode] or 0) + (count or 0)
        end
    end
end

function GlyphCache:_log_ttf_hint_failure(pixel_size, glyph_index, telemetry, class)
    local platform = self._platform
    if not platform or type(platform.log) ~= "function" then return end
    local reason = telemetry and telemetry.fail_reason or "unknown"
    if class == "broken" then
        if self._ttf_hint_broken_logged then return end
        self._ttf_hint_broken_logged = true
    end
    local key = tostring(pixel_size) .. ":" .. tostring(glyph_index) .. ":" .. tostring(reason)
    if self._ttf_hint_fail_logged[key] then return end
    self._ttf_hint_fail_logged[key] = true
    platform:log("[Astro Font] TrueType hinting " .. tostring(class or "expected") .. " fallback for glyph "
        .. tostring(glyph_index) .. " at " .. tostring(pixel_size)
        .. "px: " .. tostring(reason))
end

function GlyphCache:_should_use_ttf_hinting(pixel_size, glyph_descriptor)
    local font = self._font
    if not font or font.enable_ttf_hinting ~= true then return false end
    if font._ttf_hinting_disabled_session == true then return false end
    local ppem = pixel_size or 0
    if ppem < 8 or ppem > 18 then return false end
    local h = font.ttf_hinting
    if not h then return false end
    if font._ttf_hinting_has_global_programs == true then return true end
    if type(h.prep) == "string" and #h.prep > 0 then return true end
    if type(h.fpgm) == "string" and #h.fpgm > 0 then return true end
    return glyph_descriptor and type(glyph_descriptor.instructions) == "string"
        and #glyph_descriptor.instructions > 0
end

function GlyphCache:_record_unhinted(fallback)
    self._hint_stats.unhinted_glyphs = self._hint_stats.unhinted_glyphs + 1
    if fallback then
        self._hint_stats.fallback_count = self._hint_stats.fallback_count + 1
    end
end

function GlyphCache:_record_hinted(telemetry)
    self._hint_stats.hinted_glyphs = self._hint_stats.hinted_glyphs + 1
    merge_opcode_coverage(self._hint_stats.opcode_coverage, telemetry)
end

function GlyphCache:_record_hint_failure(pixel_size, glyph_index, telemetry)
    local class, reason = classify_hint_failure(telemetry)
    self:_log_ttf_hint_failure(pixel_size, glyph_index, telemetry, class)
    self._hint_stats.fallback_count = self._hint_stats.fallback_count + 1
    merge_opcode_coverage(self._hint_stats.opcode_coverage, telemetry)
    local font = self._font
    if font then
        font._ttf_hinting_consecutive_failures = (font._ttf_hinting_consecutive_failures or 0) + 1
        if font._ttf_hinting_consecutive_failures >= 5 then
            font._ttf_hinting_disabled_session = true
            font.enable_ttf_hinting = false
            local platform = self._platform
            if platform and type(platform.log) == "function" and not font._ttf_hinting_disabled_logged then
                font._ttf_hinting_disabled_logged = true
                platform:log("[Astro Font] TrueType hinting disabled for "
                    .. tostring(font._ttf_hinting_family_weight or "?")
                    .. " after repeated failures: " .. tostring(reason))
            end
        end
    end
end

function GlyphCache:_coords_for_size(pixel_size)
    local font = self._font
    if not font.fvar or not font.fvar.axes or not font.gvar then
        return self._norm_coords
    end

    local opsz_index = nil
    for i = 1, #font.fvar.axes do
        if font.fvar.axes[i].tag == "opsz" then
            opsz_index = i
            break
        end
    end
    if not opsz_index then return self._norm_coords end

    local coords = {}
    local source = self._norm_coords
    for i = 1, #font.fvar.axes do
        coords[i] = source and source[i] or 0
    end

    coords[opsz_index] = normalize_axis_value(
        font.fvar.axes[opsz_index],
        font.avar and font.avar[opsz_index],
        pixel_size)
    return coords
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Get a rasterized glyph for a codepoint at a given pixel size.
--- Returns glyph data table or nil for empty glyphs (e.g. space).
---
---@param codepoint number  Unicode codepoint
---@param pixel_size number Display size in pixels
---@param shear number|nil  Horizontal shear for italic (e.g. 0.2)
---@return table|nil  { tex_id, tex_w, tex_h, glyph_w, glyph_h, offset_x, offset_y, advance, alpha_buf, buf_w, buf_h }
function GlyphCache:get_glyph(codepoint, pixel_size, shear)
    shear = shear or 0
    local font = self._font
    local raster_rev = Rasterizer.CACHE_REVISION or 1
    local hint_mode = self:_hint_mode_signature()
    local size_key = tostring(math_floor(pixel_size * 64 + 0.5) * 100 + raster_rev) .. ":" .. hint_mode
    local scale = pixel_size / font.head.unitsPerEm

    -- Resolve codepoint to glyph index
    local glyph_index = font.cmap(codepoint)
    if glyph_index == 0 then return nil end

    -- Use separate cache slot for sheared glyphs (italic, skew, etc.)
    -- Quantize shear to 0.01 increments to keep cache manageable.
    local cache_index = glyph_index
    if shear ~= 0 then
        local shear_q = math_floor(shear * 100 + 0.5)  -- quantize to .01
        cache_index = glyph_index + shear_q * 100000    -- unique slot per shear value
    end

    -- Check cache
    local size_cache = self._size_caches[size_key]
    if size_cache and size_cache[cache_index] then
        return size_cache[cache_index]
    end

    -- Check if previously failed
    local fail_key = size_key .. ":" .. cache_index
    if self._no_texture[fail_key] then return nil end

    -- Parse glyph outline (with optional gvar variation data)
    local norm_coords = self:_coords_for_size(pixel_size)
    local polylines, bbox, var_advance, glyph_descriptor = TtfParser.parse_glyph(
        font.data, font.tables, font.loca, glyph_index, font.head.unitsPerEm,
        norm_coords and font.gvar or nil, norm_coords, font.hmtx, font)

    if glyph_descriptor and glyph_descriptor.max_component_depth then
        cache_index = cache_index + glyph_descriptor.max_component_depth * 1000000000
        fail_key = size_key .. ":" .. cache_index
        if size_cache and size_cache[cache_index] then
            return size_cache[cache_index]
        end
        if self._no_texture[fail_key] then return nil end
    end

    local used_ttf_hinting = false
    local hint_fallback = false
    local hint_telemetry = nil
    if self:_should_use_ttf_hinting(pixel_size, glyph_descriptor) then
        local ok, telemetry = TtfInterpreter.interpret_glyph_program(
            font, glyph_index, glyph_descriptor, pixel_size, norm_coords)
        hint_telemetry = telemetry
        if not ok then
            hint_fallback = true
            self:_record_hint_failure(pixel_size, glyph_index, telemetry)
        else
            local hinted_polylines = TtfParser.hinted_zones_to_polylines(
                glyph_descriptor, font.head.unitsPerEm / 200)
            if hinted_polylines and #hinted_polylines > 0 then
                used_ttf_hinting = true
                font._ttf_hinting_consecutive_failures = 0
                polylines = hinted_polylines
                local hb = glyph_descriptor.bbox
                local xMin, yMin, xMax, yMax = 1e9, 1e9, -1e9, -1e9
                local points = glyph_descriptor.points
                for k, pt in pairs(points or {}) do
                    if type(k) == "number" then
                        if pt.x < xMin then xMin = pt.x end
                        if pt.x > xMax then xMax = pt.x end
                        if pt.y < yMin then yMin = pt.y end
                        if pt.y > yMax then yMax = pt.y end
                    end
                end
                if xMin < xMax and yMin < yMax then
                    bbox = { xMin = xMin, yMin = yMin, xMax = xMax, yMax = yMax }
                elseif hb then
                    bbox = hb
                end
            else
                hint_fallback = true
                self:_record_hint_failure(pixel_size, glyph_index, {
                    fail_reason = "hinted outline conversion failed",
                })
            end
        end
    end

    if not polylines or #polylines == 0 or not bbox then
        self._no_texture[fail_key] = true
        return nil
    end

    -- Apply italic shear to polylines (transform outlines before rasterization)
    -- Shear formula: x' = x + shear * (ascent - y)  (top of glyph leans right)
    -- In font units, ascent = font.hhea.ascent (top of em square)
    if shear ~= 0 then
        local ascent_units = font.hhea.ascent
        for pi = 1, #polylines do
            local poly = polylines[pi]
            for vi = 1, #poly do
                local pt = poly[vi]
                pt.x = pt.x + shear * (ascent_units - pt.y)
            end
        end
        -- Recompute bbox after shear
        local new_xMin, new_xMax = 1e9, -1e9
        for pi = 1, #polylines do
            local poly = polylines[pi]
            for vi = 1, #poly do
                local px = poly[vi].x
                if px < new_xMin then new_xMin = px end
                if px > new_xMax then new_xMax = px end
            end
        end
        bbox.xMin = new_xMin
        bbox.xMax = new_xMax
    end

    -- Subtle size-specific autohinting. The returned signature is folded
    -- into the in-memory key so a glyph whose detected stem set changes
    -- does not collide with an unhinted/sheared variant at the same size.
    -- DISABLED 2026-05-18: Rasterizer.fit_glyph_stems returns a Y-DOWN bbox
    -- (from rasterizer-space polylines) but this caller's atlas placement
    -- math at line ~449 expects a TTF-style Y-UP bbox. Result is a
    -- collapsed origin_row / offset_y and glyphs clipped to 2-3 device
    -- rows. Confirmed by probe vs pre-session 2843c98. Re-enable only
    -- when fit_glyph_stems returns bbox in the same Y-up convention as
    -- TtfParser.parse_glyph.
    local hint_signature = "off"
    -- if shear == 0 and Rasterizer.fit_glyph_stems then
    --     polylines, bbox, hint_signature = Rasterizer.fit_glyph_stems(
    --         polylines, bbox, font.head.unitsPerEm, pixel_size)
    -- end
    if hint_signature and hint_signature ~= "off" then
        local h = 0
        for i = 1, #hint_signature do
            h = (h * 33 + string.byte(hint_signature, i)) % 9973
        end
        cache_index = cache_index + h * 10000000
        fail_key = size_key .. ":" .. cache_index
        if size_cache and size_cache[cache_index] then
            return size_cache[cache_index]
        end
        if self._no_texture[fail_key] then return nil end
    end

    -- Compute glyph dimensions in font units
    local glyph_w_units = bbox.xMax - bbox.xMin
    local glyph_h_units = bbox.yMax - bbox.yMin

    if glyph_w_units <= 0 or glyph_h_units <= 0 then
        self._no_texture[fail_key] = true
        return nil
    end

    -- Integer-origin glyph placement: eliminates baseline jitter.
    -- We define an affine map from font-units to pixel coords:
    --   x_px = origin_col + x_font * scale
    --   y_px = origin_row - y_font * scale
    -- origin_col/origin_row are INTEGER → offsets are integer → no rounding drift.
    local PAD_PX = 2  -- 2px padding: 1px AA-bleed + 1px safety

    -- Pixel extents from glyph origin (fractional)
    local px_top    =  bbox.yMax * scale   -- pixels above baseline
    local px_bottom = -bbox.yMin * scale   -- pixels below baseline (positive)
    local px_left   = -bbox.xMin * scale   -- pixels left of pen (positive if xMin<0)
    local px_right  =  bbox.xMax * scale   -- pixels right of pen

    -- Integer origin within texture: ceil guarantees room + integer position
    local origin_col = PAD_PX + math_ceil(math_max(px_left, 0))
    local origin_row = PAD_PX + math_ceil(math_max(px_top, 0))

    -- Texture dimensions: origin + opposite extent + padding (all integers)
    local raster_w = origin_col + math_ceil(math_max(px_right, 0)) + PAD_PX
    local raster_h = origin_row + math_ceil(math_max(px_bottom, 0)) + PAD_PX
    raster_w = math_max(raster_w, 4)
    raster_h = math_max(raster_h, 4)

    -- ViewBox derived directly from the affine map (no fudge)
    --   pixel 0 → x_font = -origin_col / scale
    --   pixel 0 → y_font =  origin_row / scale  (top of texture, y-up)
    local viewBox = {
        x = -origin_col / scale,
        y = -origin_row / scale,   -- y-down in ViewBox convention
        w =  raster_w / scale,
        h =  raster_h / scale,
    }

    -- 2-- supersampled rasterization for AA on curves/diagonals
    local SS = 2
    local ss_w = raster_w * SS
    local ss_h = raster_h * SS
    local _, _, _, alpha_hi = Rasterizer.rasterize(
        polylines, viewBox, ss_w, ss_h)
    if not alpha_hi then
        self._no_texture[fail_key] = true
        return nil
    end

    -- Box-filter downsample: average each 2--2 block
    local alpha_buf = {}
    local inv_ss2 = 1.0 / (SS * SS)
    for y = 0, raster_h - 1 do
        local sy = y * SS
        local dst_base = y * raster_w
        for x = 0, raster_w - 1 do
            local sx = x * SS
            local sum = 0
            for dy = 0, SS - 1 do
                local src_row = (sy + dy) * ss_w
                for dx = 0, SS - 1 do
                    sum = sum + alpha_hi[src_row + sx + dx + 1]
                end
            end
            alpha_buf[dst_base + x + 1] = math_floor(sum * inv_ss2 + 0.5)
        end
    end

    -- Gamma-aware edge compensation for Canvas2D-tinted glyph textures.
    -- Keep solid interiors untouched; only subpixel/AA coverage changes.
    for i = 1, raster_w * raster_h do
        local a = alpha_buf[i]
        if a > 0 and a < 255 then
            alpha_buf[i] = gamma_alpha_lut[a]
        end
    end

    -- Synthetic weight via alpha power curve
    local effective_embolden = self._embolden
    -- No implicit stem-darkening: Canvas2D blends alpha textures over the
    -- page, and extra alpha made Inter/Fira visibly heavier than Chrome.
    if pixel_size <= 16 and effective_embolden == 0 then
        effective_embolden = 0
    end
    if effective_embolden ~= 0 then
        if self._embolden ~= 0 then
            -- Explicit embolden: global power curve
            local power
            if effective_embolden > 0 then
                power = 1.0 / (1.0 + effective_embolden * 1.2)
            else
                power = 1.0 - effective_embolden * 0.8
            end
            for i = 1, raster_w * raster_h do
                local a = alpha_buf[i]
                if a > 0 and a < 255 then
                    alpha_buf[i] = math_floor((a / 255) ^ power * 255 + 0.5)
                end
            end
        else
            -- Auto stem-darkening: mid-range additive boost only
            local boost = effective_embolden
            for i = 1, raster_w * raster_h do
                local a = alpha_buf[i]
                if a >= 24 and a <= 200 then
                    local new_a = a + (255 - a) * boost
                    alpha_buf[i] = math_min(math_floor(new_a + 0.5), 255)
                end
            end
        end
    end

    -- Encode and load texture
    local png = Rasterizer.encode_png(alpha_buf, raster_w, raster_h)

    local ok, tex_id = pcall(self._platform.load_texture, self._platform, png)
    if not ok or not tex_id then
        self._no_texture[fail_key] = true
        return nil
    end

    -- Compute pixel metrics (use varied advance from gvar if available)
    local metrics_glyph_index = glyph_index
    if glyph_descriptor and glyph_descriptor.use_my_metrics_glyph ~= nil then
        metrics_glyph_index = glyph_descriptor.use_my_metrics_glyph
    end
    local hmtx_entry = font.hmtx[metrics_glyph_index]
    local advance
    if var_advance then
        advance = var_advance * scale
    else
        advance = hmtx_entry and (hmtx_entry.advanceWidth * scale) or (pixel_size * 0.5)
    end

    -- Integer offsets: origin_col/origin_row are the pen/baseline
    -- position inside the texture → offset = negative of that.
    -- Pure integers → no per-glyph rounding drift.
    local glyph_data = {
        tex_id    = tex_id,
        tex_w     = raster_w,
        tex_h     = raster_h,
        glyph_w   = raster_w,   -- same as tex: 1:1 mapping
        glyph_h   = raster_h,   -- same as tex: 1:1 mapping
        offset_x  = -origin_col,  -- integer
        offset_y  = -origin_row,  -- integer
        advance   = advance,
        alpha_buf = alpha_buf,
        buf_w     = raster_w,
        buf_h     = raster_h,
    }

    -- Store in cache
    if not size_cache then
        size_cache = {}
        self._size_caches[size_key] = size_cache
    end
    size_cache[cache_index] = glyph_data
    if used_ttf_hinting then
        self:_record_hinted(hint_telemetry)
    else
        self:_record_unhinted(false)
    end

    return glyph_data
end

function GlyphCache:get_hinting_stats()
    local stats = self._hint_stats or {}
    local coverage = {}
    for k, v in pairs(stats.opcode_coverage or {}) do
        coverage[k] = v
    end
    return {
        hinted_glyphs = stats.hinted_glyphs or 0,
        unhinted_glyphs = stats.unhinted_glyphs or 0,
        fallback_count = stats.fallback_count or 0,
        opcode_coverage = coverage,
    }
end

function GlyphCache:_glyph_index(codepoint)
    local cmap = self._font and self._font.cmap
    if not cmap then return 0 end
    return cmap(codepoint) or 0
end

function GlyphCache:_has_glyph(codepoint)
    return self:_glyph_index(codepoint) ~= 0
end

function GlyphCache:_metrics_glyph_index(glyph_index)
    local cached = self._use_my_metrics[glyph_index]
    if cached ~= nil then
        return cached == false and glyph_index or cached
    end
    local resolved = TtfParser.get_use_my_metrics_glyph(self._font, glyph_index)
    if resolved ~= nil then
        self._use_my_metrics[glyph_index] = resolved
        return resolved
    end
    self._use_my_metrics[glyph_index] = false
    return glyph_index
end

--- Apply a small built-in shaping pass for common Latin ligatures.
--- This is not a replacement for GSUB/HarfBuzz, but it lets fonts that
--- expose Unicode presentation ligature glyphs render and measure them.
---@param text string
---@param Utf8 table
---@return table Array of codepoints after simple substitutions.
function GlyphCache:shape_text(text, Utf8)
    local cps = {}
    for cp in Utf8.codes(text or "") do
        cps[#cps + 1] = cp
    end
    if #cps < 2 then return cps end

    local out = {}
    local i = 1
    while i <= #cps do
        local replaced = false
        for li = 1, #STANDARD_LIGATURES do
            local lig = STANDARD_LIGATURES[li]
            if ligature_matches(cps, i, lig.seq) and self:_has_glyph(lig.cp) then
                out[#out + 1] = lig.cp
                i = i + #lig.seq
                replaced = true
                break
            end
        end
        if not replaced then
            out[#out + 1] = cps[i]
            i = i + 1
        end
    end
    return out
end

--- Get the advance width for a codepoint at a pixel size.
--- For variable fonts with norm_coords, uses the cached glyph
--- (triggers rasterization which computes var_advance).
--- For static fonts, fast path reads hmtx directly.
---@param codepoint number
---@param pixel_size number
---@return number  Advance width in pixels
function GlyphCache:get_advance(codepoint, pixel_size)
    local font = self._font
    local scale = pixel_size / font.head.unitsPerEm
    local glyph_index = self:_glyph_index(codepoint)
    if glyph_index == 0 then
        return pixel_size * 0.5
    end

    local metrics_glyph_index = self:_metrics_glyph_index(glyph_index)
    local hmtx_entry = font.hmtx[metrics_glyph_index]
    if not hmtx_entry then return pixel_size * 0.5 end
    local base_aw = hmtx_entry.advanceWidth

    -- Fast variable-font advance path: HVAR table provides per-glyph
    -- advance-width deltas keyed by normalized variation coords.
    -- Adding the delta here matches Chrome's HVAR-aware advance without
    -- the rasterize-the-whole-glyph cost. Falls back to gvar rasterize
    -- only when HVAR is missing.
    if font.hvar and self._norm_coords then
        local norm_coords = self:_coords_for_size(pixel_size)
        local delta = TtfParser.get_hvar_advance_delta(
            font.hvar, glyph_index, norm_coords)
        return (base_aw + delta) * scale
    end

    -- No HVAR: fall back to gvar rasterize path (glyph.advance reflects
    -- phantom-point displacement computed during outline rasterization).
    if font.gvar and font.fvar then
        local glyph = self:get_glyph(codepoint, pixel_size)
        if glyph then return glyph.advance end
    end

    return base_aw * scale
end

--- Get kerning between two codepoints at a pixel size.
---@param left_cp number|nil
---@param right_cp number|nil
---@param pixel_size number
---@return number
function GlyphCache:get_kerning(left_cp, right_cp, pixel_size)
    if not left_cp or not right_cp then return 0 end
    local font = self._font
    if not font then return 0 end
    local left_glyph = self:_glyph_index(left_cp)
    local right_glyph = self:_glyph_index(right_cp)
    if left_glyph == 0 or right_glyph == 0 then return 0 end

    local value = 0
    local kern = font.kern
    if kern then
        local row = kern[left_glyph]
        value = value + ((row and row[right_glyph]) or 0)
    end

    local gpos = font.gpos
    if gpos then
        local row = gpos.pairs and gpos.pairs[left_glyph]
        value = value + ((row and row[right_glyph]) or 0)
        if gpos.class_pairs then
            for i = 1, #gpos.class_pairs do
                local pair = gpos.class_pairs[i]
                if pair.coverage[left_glyph] then
                    local c1 = pair.class1[left_glyph] or 0
                    local c2 = pair.class2[right_glyph] or 0
                    local prow = pair.matrix[c1]
                    value = value + ((prow and prow[c2]) or 0)
                end
            end
        end
    end

    return value * pixel_size / font.head.unitsPerEm
end

--- Measure total text width by summing glyph advances.
--- Applies simple ligature substitution and legacy kern pairs.
---@param text      string  UTF-8 text
---@param pixel_size number
---@param Utf8      table   UTF-8 module (require("core/util/utf8"))
---@return number  total width in pixels
function GlyphCache:measure_text(text, pixel_size, Utf8)
    local total = 0
    local cps = self:shape_text(text, Utf8)
    local prev_cp = nil
    for i = 1, #cps do
        local cp = cps[i]
        total = total + self:get_kerning(prev_cp, cp, pixel_size)
        total = total + self:get_advance(cp, pixel_size)
        prev_cp = cp
    end
    return total
end

--- Get raw font-level metrics at a pixel size (CSS pixels, no DPR rounding).
--- Used by painters/baselines that need the precise unrounded values.
---@param pixel_size number
---@return number ascent   Pixels above baseline
---@return number descent  Pixels below baseline (negative)
---@return number lineGap  Extra line spacing in pixels
function GlyphCache:get_metrics(pixel_size)
    local font = self._font
    local scale = pixel_size / font.head.unitsPerEm
    local a, d, lg = self:_vertical_metrics()
    return a * scale, d * scale, lg * scale
end

function GlyphCache:_vertical_metrics()
    local font = self._font
    local os2 = font and font.os2
    if os2 and os2.sTypoAscender and os2.sTypoDescender and os2.sTypoLineGap then
        local fs = os2.fsSelection or 0
        local use_typo = (math.floor(fs / 128) % 2) == 1
        if use_typo then
            return os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap
        end
    end
    return font.hhea.ascent, font.hhea.descent, font.hhea.lineGap
end

--- Round-half-away-from-zero (Blink's lroundf semantics).
local function lroundf(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

--- Compute `line-height: normal` matching Chrome's per-component device-pixel
--- rounding. Mirrors Blink's `SimpleFontData::PlatformInit()` formula in
--- `third_party/blink/renderer/platform/fonts/simple_font_data.cc`:
---
---     line_spacing = lroundf(ascent) + lroundf(descent) + lroundf(line_gap)
---
--- (Blink's `descent` is positive; our hhea descent is negative -" same result
--- after sign flip.) Rounding happens in DEVICE pixels at the active DPR;
--- the result is divided back to CSS pixels for the layout engine.
---
--- The rounding applies even at DPR=1, so the return value may differ from
--- the raw `a - d + lg` by sub-pixel amounts there too -" that matches what
--- Chrome paints. At non-integer DPRs (Windows 110% scaling, Retina iframes,
--- etc.) the divergence from raw grows to ~0.3 px-per-line.
---@param pixel_size number  CSS pixels
---@param dpr        number|nil  device pixel ratio (default 1)
---@return number line_spacing CSS pixels
function GlyphCache:get_line_spacing(pixel_size, dpr)
    dpr = dpr or 1
    local font = self._font
    local scale = pixel_size / font.head.unitsPerEm
    local a, d, lg = self:_vertical_metrics()
    local a_dev  = a  * scale * dpr
    local d_dev  = d  * scale * dpr  -- negative
    local lg_dev = lg * scale * dpr
    return (lroundf(a_dev) - lroundf(d_dev) + lroundf(lg_dev)) / dpr
end

--- Stateless CSS `line-height` resolver shared by block / inline / painter
--- code paths. Centralising the resolution prevents the three callers from
--- silently disagreeing on how `normal`, multipliers, and absolute px should
--- behave at non-1 DPR.
---
---   raw = nil / "normal"     → font-metric line spacing (DPR-aware)
---   raw = number < 5         → multiplier -- font_size, rounded to device px
---   raw = number >= 5        → absolute px, rounded to device px
---   no font cache available  → font_size * 1.2 (deterministic fallback)
---@param cache      table|nil   GlyphCache for the resolved face (may be nil)
---@param raw        any         the computed line-height value
---@param font_size  number      resolved font-size in CSS px
---@param dpr        number|nil  device pixel ratio (default 1)
---@return number  line height in CSS px
function GlyphCache.resolve_line_height(cache, raw, font_size, dpr)
    dpr = dpr or 1
    if raw == nil or raw == "normal" then
        if cache and cache.get_line_spacing then
            -- Chrome's `getBoundingClientRect()` for paragraphs at non-integer
            -- DPR reports integer-CSS-px line boxes (e.g. Inter 14 reports
            -- h=17 even at DPR 1.1 where the raw font-metric resolves to
            -- 17.27 CSS px). Snapping to integer CSS px here matches the
            -- observable line-box height and prevents fractional-residue
            -- drift accumulating across multi-line paragraphs and section
            -- stacks. See parity-detector tw-* / inline-* cases -" every
            -- multi-line paragraph used to gain ~0.27 CSS px per line at
            -- DPR 1.1, compounding to 5-6 px of section drift before the
            -- tw-pre-* cluster.
            return lroundf(cache:get_line_spacing(font_size, dpr))
        end
        return font_size * 1.2
    end
    if type(raw) == "number" then
        local css
        if raw >= 5 then
            css = raw
        else
            css = raw * font_size
        end
        return lroundf(css * dpr) / dpr
    end
    return font_size * 1.2
end

return GlyphCache



