------------------------------------------------------------
-- ext_core_astro_ui_lib / core / assets / texture_cache.lua
-- Async texture loading + caching via platform HTTP + load_texture.
--
-- Follows FontManager's proven async pattern:
--   get(url) → {tex_id, w, h} or nil (triggers async download)
--   pop_just_ready() → true if any texture loaded since last call
--
-- Cache modes:
--   "always"  -" save to disk, load from disk on next run (default)
--   "session" -" keep in memory for this session, no disk persistence
--   "none"    -" re-download every time get() is called
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Rasterizer = require("core/fonts/rasterizer")
local encode_rgba_png = Rasterizer.encode_rgba_png
local decode_png  = require("core/assets/png_decoder")
local decode_jpeg = require("core/assets/jpeg_decoder")
local Base64      = require("core/util/base64")

local TextureCache = {}
TextureCache.__index = TextureCache

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local math_ceil  = math.ceil

-- States for async loading
local STATE_IDLE       = 0
local STATE_LOADING    = 1
local STATE_READY      = 2
local STATE_FAILED     = 3

--- Disk cache directory under scripts_data/.
local CACHE_DIR = "astro_ui_textures"

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new TextureCache.
---@param platform   table   Platform adapter instance
---@param cache_mode string|nil  "always" (default), "session", or "none"
---@return table  TextureCache instance
function TextureCache.new(platform, cache_mode)
    local self = setmetatable({}, TextureCache)
    self.platform       = platform
    self._entries       = {}   -- url -> {state, tex_id, w, h, data, rgba}
    self._just_ready    = false
    self._cache_mode    = cache_mode or "always"
    self._cache_dir_ok  = false
    self._crop_cache    = {}   -- [crop_key] -> { tex_id, w, h }
    self._crop_count    = 0    -- number of entries in crop cache
    self._crop_max      = 64   -- evict when exceeded
    return self
end

------------------------------------------------------------
-- Cache mode control
------------------------------------------------------------

--- Set cache mode at runtime.
---@param mode string  "always", "session", or "none"
function TextureCache:set_cache_mode(mode)
    self._cache_mode = mode or "always"
end

--- Get current cache mode.
---@return string
function TextureCache:get_cache_mode()
    return self._cache_mode
end

--- Clear all cached textures (forces re-download on next get()).
function TextureCache:clear()
    self._entries = {}
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Get a texture by URL. Returns cached result or triggers async load.
---@param url string  texture URL
---@return table|nil  {tex_id=N, w=N, h=N} if ready, nil if loading/failed
function TextureCache:get(url)
    if not url or url == "" then return nil end

    local entry = self._entries[url]

    if not entry then
        -- data: URIs are inline -" no HTTP, no disk cache.
        -- Decode synchronously and hand off to tick() via entry.data.
        if url:sub(1, 5) == "data:" then
            local mime, bytes = Base64.parse_data_uri(url)
            if bytes then
                self._entries[url] = { state = STATE_LOADING, data = bytes, _is_data_uri = true }
            else
                self._entries[url] = { state = STATE_FAILED, _is_data_uri = true }
                self.platform:log_error("[Astro Tex] invalid data URI")
            end
            return nil
        end

        -- Try disk cache first (only in "always" mode)
        if self._cache_mode == "always" then
            local disk_data = self:_read_disk_cache(url)
            if disk_data then
                self._entries[url] = { state = STATE_LOADING, data = disk_data }
                return nil
            end
        end

        -- Start async download
        self._entries[url] = { state = STATE_LOADING }
        self:_start_load(url)
        return nil
    end

    if entry.state == STATE_READY then
        return { tex_id = entry.tex_id, w = entry.w, h = entry.h,
                 rgba = entry.rgba, rgba_w = entry.rgba_w, rgba_h = entry.rgba_h }
    end

    return nil  -- still loading or failed
end

--- Inject a texture directly from PNG bytes (no HTTP needed).
--- Optionally accepts RGBA pixel buffer for software cropping.
---@param url     string       Fake URL key (e.g. "proc://gradient")
---@param data    string       Raw PNG bytes
---@param rgba    table|nil    RGBA pixel buffer {r,g,b,a,...} (4*w*h entries)
---@param pw      number|nil   Pixel width (required if rgba given)
---@param ph      number|nil   Pixel height (required if rgba given)
function TextureCache:inject(url, data, rgba, pw, ph)
    if not url or not data then return end
    self._entries[url] = {
        state = STATE_LOADING,
        data = data,
        rgba = rgba,
        rgba_w = pw,
        rgba_h = ph,
    }
end

--- Create a cropped texture from an RGBA pixel buffer.
--- Caches results by exact crop rect.
---@param tex   table  Texture info from get() -" must have .rgba, .rgba_w, .rgba_h
---@param cx    number Crop x offset (pixels)
---@param cy    number Crop y offset (pixels)
---@param cw    number Crop width (pixels)
---@param ch    number Crop height (pixels)
---@return number|nil  tex_id
---@return number      cropped width
---@return number      cropped height
function TextureCache:create_cropped(tex, cx, cy, cw, ch)
    if not tex or not tex.rgba then return nil end
    cx = math_max(0, math_floor(cx))
    cy = math_max(0, math_floor(cy))
    cw = math_max(1, math_floor(cw))
    ch = math_max(1, math_floor(ch))
    if cx + cw > tex.rgba_w then cw = tex.rgba_w - cx end
    if cy + ch > tex.rgba_h then ch = tex.rgba_h - cy end
    if cw < 1 or ch < 1 then return nil end

    local crop_key = tostring(tex.tex_id) .. ":" .. cx .. ":" .. cy .. ":" .. cw .. ":" .. ch
    local cached = self._crop_cache[crop_key]
    if cached then return cached.tex_id, cached.w, cached.h end

    -- Extract RGBA sub-rect
    local src = tex.rgba
    local src_w = tex.rgba_w
    local sub = {}
    local di = 0
    for y = cy, cy + ch - 1 do
        local base = y * src_w * 4
        for x = cx, cx + cw - 1 do
            local si = base + x * 4
            sub[di + 1] = src[si + 1]
            sub[di + 2] = src[si + 2]
            sub[di + 3] = src[si + 3]
            sub[di + 4] = src[si + 4]
            di = di + 4
        end
    end

    local png = encode_rgba_png(sub, cw, ch)
    if not png then return nil end
    local ok, tex_id, tw, th = pcall(self.platform.load_texture, self.platform, png)
    if not ok or not tex_id or tex_id == 0 then return nil end

    self._crop_cache[crop_key] = { tex_id = tex_id, w = cw, h = ch }
    self._crop_count = self._crop_count + 1

    -- Evict entire crop cache when it grows too large
    if self._crop_count > self._crop_max then
        self._crop_cache = {}
        self._crop_cache[crop_key] = { tex_id = tex_id, w = cw, h = ch }
        self._crop_count = 1
    end

    return tex_id, cw, ch
end

--- Apply a mask image's alpha channel to a source image's RGBA buffer, producing
--- a new texture.  CPU-side composite: src.rgb stays, src.a *= mask.a / 255.
---
--- If mask has no alpha channel (opaque PNG), uses luminance as alpha source
--- (black → transparent, white → opaque, matching CSS mask-mode: alpha/luminance).
---
--- Returns nil while either input texture is still loading.
---@param src_url  string  URL of the source image (must already be in cache)
---@param mask_url string  URL of the mask image
---@return table|nil  {tex_id, w, h} composite, or nil if pending
function TextureCache:get_masked(src_url, mask_url)
    if not src_url or not mask_url or src_url == "" or mask_url == "" then
        return nil
    end

    local comp_key = "mask:" .. src_url .. "|" .. mask_url
    local comp = self._entries[comp_key]
    if comp and comp.state == STATE_READY then
        return { tex_id = comp.tex_id, w = comp.w, h = comp.h }
    end
    if comp and comp.state == STATE_FAILED then
        return nil
    end

    -- Trigger loads for both source and mask (returns nil if still pending)
    local src = self:get(src_url)
    local mask = self:get(mask_url)
    if not src or not mask then return nil end
    if not src.rgba or not mask.rgba then return nil end

    -- Composite: use mask's alpha channel (fall back to luminance if opaque)
    local sw, sh = src.rgba_w or 0, src.rgba_h or 0
    if sw <= 0 or sh <= 0 then return nil end

    local mw, mh = mask.rgba_w or 0, mask.rgba_h or 0
    if mw <= 0 or mh <= 0 then return nil end

    local src_rgba  = src.rgba
    local mask_rgba = mask.rgba
    local out = {}
    local pi = 0
    -- Scale mask to source dimensions via nearest-neighbor sampling
    local sx_ratio = mw / sw
    local sy_ratio = mh / sh

    -- Detect whether mask has meaningful alpha channel; if all opaque, use luminance.
    -- Sample the 4 corners as a heuristic.
    local use_alpha = false
    local corners = { 1, mw, (mh - 1) * mw + 1, mw * mh }
    for i = 1, #corners do
        local ci = (corners[i] - 1) * 4
        local a = mask_rgba[ci + 4] or 255
        if a < 255 then use_alpha = true; break end
    end

    for sy = 0, sh - 1 do
        local my = math_floor(sy * sy_ratio)
        if my >= mh then my = mh - 1 end
        local m_row = my * mw
        for sx = 0, sw - 1 do
            local mx = math_floor(sx * sx_ratio)
            if mx >= mw then mx = mw - 1 end

            local s_i = ((sy * sw) + sx) * 4
            local m_i = (m_row + mx) * 4

            local sr = src_rgba[s_i + 1] or 0
            local sg = src_rgba[s_i + 2] or 0
            local sb = src_rgba[s_i + 3] or 0
            local sa = src_rgba[s_i + 4] or 255

            local mask_factor
            if use_alpha then
                mask_factor = (mask_rgba[m_i + 4] or 0) / 255
            else
                -- Luminance: 0.299*R + 0.587*G + 0.114*B
                local mr = mask_rgba[m_i + 1] or 0
                local mg = mask_rgba[m_i + 2] or 0
                local mb = mask_rgba[m_i + 3] or 0
                mask_factor = (mr * 0.299 + mg * 0.587 + mb * 0.114) / 255
            end

            out[pi + 1] = sr
            out[pi + 2] = sg
            out[pi + 3] = sb
            out[pi + 4] = math_floor(sa * mask_factor)
            pi = pi + 4
        end
    end

    local png = encode_rgba_png(out, sw, sh)
    if not png then
        self._entries[comp_key] = { state = STATE_FAILED }
        return nil
    end
    local ok, tex_id, tw, th = pcall(self.platform.load_texture, self.platform, png)
    if not ok or not tex_id or tex_id == 0 then
        self._entries[comp_key] = { state = STATE_FAILED }
        return nil
    end

    self._entries[comp_key] = {
        state  = STATE_READY,
        tex_id = tex_id,
        w      = tw or sw,
        h      = th or sh,
    }
    return { tex_id = tex_id, w = tw or sw, h = th or sh }
end

--- Check and clear the "just ready" flag.
---@return boolean  true if any texture became ready since last call
function TextureCache:pop_just_ready()
    local val = self._just_ready
    self._just_ready = false
    return val
end

--- Called each frame to process completed downloads.
function TextureCache:tick()
    for url, entry in pairs(self._entries) do
        if entry.state == STATE_LOADING and entry.data then
            local ok, tex_id, w, h = pcall(function()
                return self.platform:load_texture(entry.data)
            end)
            if ok and tex_id and tex_id ~= 0 then
                entry.state  = STATE_READY
                entry.tex_id = tex_id
                entry.w      = w or 0
                entry.h      = h or 0

                -- Decode image → RGBA pixel buffer for read_pixel() / eyedropper
                if not entry.rgba and entry.data then
                    -- Try PNG first, then JPEG
                    local dok, rgba, pw, ph = pcall(decode_png, entry.data)
                    if not (dok and rgba) then
                        dok, rgba, pw, ph = pcall(decode_jpeg, entry.data)
                    end
                    if dok and rgba then
                        entry.rgba   = rgba
                        entry.rgba_w = pw
                        entry.rgba_h = ph
                    end
                end

                -- Save to disk in "always" mode (but never cache data URIs -"
                -- the payload is already inline in the bundle).
                if self._cache_mode == "always" and not entry._is_data_uri then
                    self:_write_disk_cache(url, entry.data)
                end

                -- Keep raw data if RGBA decode failed (non-PNG format)
                if entry.rgba then
                    entry.data = nil
                end
                self._just_ready = true
            else
                entry.state = STATE_FAILED
                entry.data  = nil
            end
        end
    end
end

------------------------------------------------------------
-- Disk cache helpers
------------------------------------------------------------

--- Ensure cache directory exists.
function TextureCache:_ensure_cache_dir()
    if self._cache_dir_ok then return end
    pcall(self.platform.create_data_folder, self.platform, CACHE_DIR)
    self._cache_dir_ok = true
end

--- Convert URL to a safe filename.
---@param url string
---@return string  cache file path
function TextureCache:_cache_path(url)
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    local safe = url:gsub("[^%w%-_%.]+", "_")
    -- Truncate to avoid overly long filenames
    if #safe > 120 then
        safe = safe:sub(1, 60) .. "__" .. safe:sub(-58)
    end
    return CACHE_DIR .. "/" .. string.format("%08x", h) .. "_" .. safe
end

--- Try to read a texture from disk cache.
---@param url string
---@return string|nil  raw binary data, or nil
function TextureCache:_read_disk_cache(url)
    self:_ensure_cache_dir()
    local path = self:_cache_path(url)
    local ok, data = pcall(self.platform.read_data_file, self.platform, path)
    if ok and data and #data > 8 then
        self.platform:log("[Astro Tex] Disk cache hit: " .. url:sub(1, 80))
        return data
    end
    return nil
end

--- Write texture data to disk cache.
---@param url  string
---@param data string  raw binary data
function TextureCache:_write_disk_cache(url, data)
    self:_ensure_cache_dir()
    local path = self:_cache_path(url)
    local ok, err = pcall(function()
        self.platform:create_data_file(path)
        self.platform:write_data_file(path, data)
    end)
    if ok then
        self.platform:log("[Astro Tex] Disk cache saved: " .. url:sub(1, 80))
    end
end

------------------------------------------------------------
-- Internal
------------------------------------------------------------

--- Start an async HTTP download for a texture URL.
---@param url string
function TextureCache:_start_load(url)
    local entry = self._entries[url]
    if not entry then return end

    self.platform:log("[Astro Tex] Downloading: " .. url:sub(1, 120))

    -- Use platform's async HTTP if available
    local self_ref = self
    local ok, started = pcall(function()
        return self.platform:http_get(url, function(http_code, content_type, data, headers)
            if http_code == 200 and data and #data > 0 then
                entry.data = data
            elseif (http_code == 301 or http_code == 302) and headers then
                -- Follow redirect: extract Location header
                local location = nil
                if type(headers) == "table" then
                    location = headers["Location"] or headers["location"]
                elseif type(headers) == "string" then
                    location = headers:match("[Ll]ocation:%s*([^\r\n]+)")
                end
                if location and location ~= "" then
                    pcall(self_ref.platform.log, self_ref.platform,
                        "[Astro Tex] Redirect -> " .. location:sub(1, 120))
                    entry.state = STATE_LOADING
                    entry.data = nil
                    -- Re-use _start_load with the new URL
                    -- (store redirect URL so tick() doesn't double-process)
                    self_ref._entries[url] = nil
                    self_ref._entries[location] = entry
                    -- Also keep original URL pointing to same entry
                    self_ref._entries[url] = entry
                    local rok, rstarted = pcall(function()
                        return self_ref.platform:http_get(location, function(rc2, ct2, d2, h2)
                            if rc2 == 200 and d2 and #d2 > 0 then
                                entry.data = d2
                            else
                                entry.state = STATE_FAILED
                            end
                        end)
                    end)
                    if not rok or rstarted == false then
                        entry.state = STATE_FAILED
                    end
                else
                    entry.state = STATE_FAILED
                end
            else
                entry.state = STATE_FAILED
                pcall(self.platform.log, self.platform,
                    "[Astro Tex] Download FAILED: " .. url:sub(1, 80)
                    .. " http=" .. tostring(http_code))
            end
        end)
    end)

    if not ok or started == false then
        entry.state = STATE_FAILED
    end
end

return TextureCache



