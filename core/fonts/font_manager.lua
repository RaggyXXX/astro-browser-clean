------------------------------------------------------------
-- ext_core_astro_ui_lib / core / fonts / font_manager.lua
-- Central coordinator for custom font loading, caching,
-- and management.
--
-- Instance-based design (not singleton) for Astro UI.
-- Uses platform adapter for HTTP, file I/O, and logging.
--
-- Usage:
--   local FontManager = require("core/fonts/font_manager")
--   local fm = FontManager:new(platform)
--   fm:register("inter", "https://example.com/Inter.ttf")
--   fm:load("inter")
--   -- call fm:tick() each frame
--   local cache = fm:get_cache_for("inter")
--   if cache then
--       local glyph = cache:get_glyph(65, 16) -- 'A' at 16px
--   end
--
-- Adapted from ext_lib_ultima_ui for Astro UI.
------------------------------------------------------------

local TtfParser    = require("core/fonts/ttf_parser")
local GlyphCache   = require("core/fonts/glyph_cache")
local WoffDecoder  = require("core/fonts/woff_decoder")

local FontManager = {}
FontManager.__index = FontManager
FontManager.enable_ttf_hinting_default = false

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local str_lower = string.lower
local str_gsub  = string.gsub

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

------------------------------------------------------------
-- Default font registry
------------------------------------------------------------

--- Built-in Google Fonts URL templates.
local DEFAULT_FONTS = {
    ["inter"]           = "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz%2Cwght%5D.ttf",
    ["tinos"]           = "https://raw.githubusercontent.com/google/fonts/main/ofl/tinos/Tinos-Regular.ttf",
    ["roboto"]          = "https://raw.githubusercontent.com/google/fonts/main/ofl/roboto/Roboto%5Bwdth%2Cwght%5D.ttf",
    ["opensans"]        = "https://raw.githubusercontent.com/google/fonts/main/ofl/opensans/OpenSans%5Bwdth%2Cwght%5D.ttf",
    ["noto-sans"]       = "https://raw.githubusercontent.com/google/fonts/main/ofl/notosans/NotoSans%5Bwdth%2Cwght%5D.ttf",
    ["noto-sans-sc"]    = "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf",
    ["lato"]            = "https://raw.githubusercontent.com/google/fonts/main/ofl/lato/Lato-Regular.ttf",
    ["montserrat"]      = "https://raw.githubusercontent.com/google/fonts/main/ofl/montserrat/Montserrat%5Bwght%5D.ttf",
    ["source-sans"]     = "https://raw.githubusercontent.com/google/fonts/main/ofl/sourcesans3/SourceSans3%5Bwght%5D.ttf",
    ["fira-code"]       = "https://raw.githubusercontent.com/google/fonts/main/ofl/firacode/FiraCode%5Bwght%5D.ttf",
    ["jetbrains-mono"]  = "https://raw.githubusercontent.com/google/fonts/main/ofl/jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf",
    ["playwrite-nz"]    = "https://raw.githubusercontent.com/google/fonts/main/ofl/playwritenzbasic/PlaywriteNZBasic%5Bwght%5D.ttf",
    ["therover"]        = "https://fonts.cdnfonts.com/s/30480/Therover.woff",
    ["warcraft"]        = "https://font.download/cdn/webfont/warcraft/Warcraft-Yj2j.woff",
    ["friz-quadrata"]   = "https://fonts.cdnfonts.com/s/14269/friz-quadrata-regular-os-5870333951e7c.woff",
    ["poppins"]         = "https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-Regular.ttf",
    ["raleway"]         = "https://raw.githubusercontent.com/google/fonts/main/ofl/raleway/Raleway%5Bwght%5D.ttf",
    ["oswald"]          = "https://raw.githubusercontent.com/google/fonts/main/ofl/oswald/Oswald%5Bwght%5D.ttf",
    ["ubuntu"]          = "https://raw.githubusercontent.com/google/fonts/main/ofl/ubuntu/Ubuntu%5Bwdth%2Cwght%5D.ttf",
}

--- Disk cache directory under scripts_data/.
local CACHE_DIR = "astro_ui_fonts"

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new FontManager instance.
---@param platform table  Platform adapter (must have http_get, read_data_file, write_data_file, create_data_folder, create_data_file, log, load_texture)
---@return table FontManager instance
function FontManager:new(platform)
    local o = {
        _platform       = platform,
        _fonts          = {},          -- font_name -> url
        _family_names   = {},          -- public family names for UI/debug lists
        _font_caches    = {},          -- font_name -> GlyphCache instance (default weight)
        _raw_cache      = {},          -- font_name -> raw binary string
        _pending        = {},          -- queue of font keys waiting to be parsed
        _downloading    = {},          -- font names currently being downloaded
        _failed         = {},          -- font names that failed to load
        _cache_dir_ready = false,
        _just_ready     = false,       -- true if a font became ready since last pop
        -- Deferred load queue (disk reads spread across frames)
        _load_queue     = {},          -- ordered list of keys to load
        _load_queued    = {},          -- set: key -> true if in _load_queue
        -- Variable font / multi-weight support
        _font_weights   = {},          -- name -> { [weight] = url } (static per-weight)
        _font_faces     = {},          -- name -> array of { weight, style, key, url }
        _weight_keys    = {},          -- internal load key -> { family, weight, style }
        _weight_caches  = {},          -- name -> { [quantized_weight] = GlyphCache }
        _variable_info  = {},          -- name -> parsed font with fvar/avar/gvar
        _font_options   = {},          -- font key -> config flags
        _hinting_overrides = {},       -- font key -> true/false
    }

    o.enable_ttf_hinting_default = FontManager.enable_ttf_hinting_default
    if platform and type(platform.should_use_ttf_hinting) == "function" then
        local ok, enabled = pcall(platform.should_use_ttf_hinting, platform)
        if ok and enabled ~= nil then
            o.enable_ttf_hinting_default = enabled == true
        end
    end

    -- Copy default font registry
    for k, v in pairs(DEFAULT_FONTS) do
        o._fonts[k] = v
        o._family_names[k] = true
    end

    return setmetatable(o, self)
end

------------------------------------------------------------
-- Local helpers
------------------------------------------------------------

--- Ensure the cache directory exists.
---@param self table  FontManager instance
local function ensure_cache_dir(self)
    if self._cache_dir_ready then return end
    pcall(self._platform.create_data_folder, self._platform, CACHE_DIR)
    self._cache_dir_ready = true
end

--- Sanitize a font name for use as a filename.
---@param name string
---@return string
local function cache_filename(name)
    local url = nil
    if type(name) == "table" then
        url = name.url
        name = name.name
    end
    local safe = str_gsub(str_lower(name), "[^%w%-_]", "_")
    if url and url ~= "" then
        local h = 5381
        for i = 1, #url do
            h = (h * 33 + url:byte(i)) % 4294967296
        end
        safe = safe .. "__" .. string.format("%08x", h)
    end
    return CACHE_DIR .. "/" .. safe .. ".ttf"
end

local function weight_cache_key(family_key, weight)
    return family_key .. "__w" .. tostring(weight)
end

local function normalize_style(style)
    if type(style) ~= "string" then return "normal" end
    local s = trim(str_lower(style))
    if s:find("^italic") then return "italic" end
    if s:find("^oblique") then return "oblique" end
    return "normal"
end

local function style_weight_cache_key(family_key, weight, style)
    style = normalize_style(style)
    if style == "normal" then
        return (weight == 400) and family_key or weight_cache_key(family_key, weight)
    end
    return family_key .. "__" .. style .. "__w" .. tostring(weight)
end

local function hinting_tables_have_global_programs(font)
    local h = font and font.ttf_hinting
    return h and ((type(h.prep) == "string" and #h.prep > 0)
        or (type(h.fpgm) == "string" and #h.fpgm > 0))
end

function FontManager:_apply_hinting_policy(font, key)
    if not font then return end
    key = key or ""
    local options = self._font_options[key]
    local override = self._hinting_overrides[key]
    if override == nil and options and options.enable_ttf_hinting ~= nil then
        override = options.enable_ttf_hinting == true
    end
    font.enable_ttf_hinting_default = self.enable_ttf_hinting_default == true
    font.enable_ttf_hinting_override = override
    font.enable_ttf_hinting = override == true
        or (override == nil and font.enable_ttf_hinting_default == true)
    font._ttf_hinting_font_key = key
    font._ttf_hinting_family_weight = key
    font._ttf_hinting_has_global_programs = hinting_tables_have_global_programs(font)
end

local GENERIC_FAMILY_MAP = {
    ["arial"]         = "inter",
    ["helvetica"]     = "inter",
    ["helvetica neue"] = "inter",
    ["segoe ui"]      = "inter",
    ["sans-serif"]    = "inter",
    ["ui-sans-serif"] = "inter",
    ["system-ui"]     = "inter",
    ["times"]         = "tinos",
    ["times new roman"] = "tinos",
    ["serif"]         = "tinos",
    ["monospace"]     = "fira-code",
    ["ui-monospace"]  = "fira-code",
    ["cursive"]       = "playwrite-nz",
    ["fantasy"]       = "inter",
}

local function append_unique(list, seen, key)
    if key and key ~= "" and not seen[key] then
        list[#list + 1] = key
        seen[key] = true
    end
end

--- Decode raw font data (TTF or WOFF) and return the parsed font.
---@param self     table   FontManager instance
---@param raw_data string  Raw binary font data (TTF or WOFF)
---@param name     string  Font name (for logging)
---@return table|nil  Parsed font object
local function decode_and_parse(self, raw_data, name)
    local platform = self._platform
    local ttf_data = raw_data
    if WoffDecoder.is_woff2 and WoffDecoder.is_woff2(raw_data) then
        local decoded = nil
        if type(platform.decode_woff2) == "function" then
            local ok, result = pcall(platform.decode_woff2, platform, raw_data)
            if ok and type(result) == "string" and #result > 0 then decoded = result end
        end
        if not decoded and type(platform.brotli_decompress) == "function"
           and type(WoffDecoder.decode_woff2_with_brotli) == "function" then
            local ok, result = pcall(WoffDecoder.decode_woff2_with_brotli, raw_data, function(buf)
                return platform:brotli_decompress(buf)
            end)
            if ok and type(result) == "string" and #result > 0 then decoded = result end
        end
        if not decoded then
            platform:log("[Astro Font] WOFF2 unsupported without a platform Brotli decoder: " .. (name or "?"))
            return nil
        end
        platform:log("[Astro Font] WOFF2 decoded by platform: " .. (name or "?"))
        ttf_data = decoded
    elseif WoffDecoder.is_woff(raw_data) then
        platform:log("[Astro Font] Decoding WOFF: " .. (name or "?") .. " (" .. #raw_data .. " bytes)")
        ttf_data = WoffDecoder.decode(raw_data)
        if not ttf_data then
            platform:log("[Astro Font] WOFF DECODE FAILED: " .. (name or "?"))
            return nil
        end
        platform:log("[Astro Font] WOFF decoded: " .. #raw_data .. " -> " .. #ttf_data .. " bytes")
    end

    local font, parse_err = TtfParser.parse(ttf_data)
    if not font then
        platform:log("[Astro Font] PARSE FAILED: " .. (name or "?")
            .. " (" .. #ttf_data .. " bytes)"
            .. (parse_err and (" | " .. parse_err) or ""))
        return nil
    end
    if font.color_tables and #font.color_tables > 0 then
        platform:log("[Astro Font] Color font tables present but color glyph layers are not rendered yet: "
            .. (name or "?") .. " | " .. table.concat(font.color_tables, ","))
    end
    self:_apply_hinting_policy(font, name or "")
    platform:log("[Astro Font] Parsed: " .. (name or "?")
        .. " | unitsPerEm=" .. font.head.unitsPerEm
        .. " | glyphs=" .. font.maxp.numGlyphs
        .. " | ascent=" .. font.hhea.ascent
        .. " | descent=" .. font.hhea.descent)
    return font
end

--- Remove a key from the deferred parse queue. Used when a synchronous
--- cache lookup consumes _raw_cache before the next tick() parse phase.
---@param self table
---@param key string
local function remove_pending_key(self, key)
    local pending = self._pending
    for i = #pending, 1, -1 do
        if pending[i] == key then
            table.remove(pending, i)
        end
    end
end

--- Parse raw font bytes and install the resulting GlyphCache. This is the
--- single parse path used by both tick() and synchronous cache lookup, so
--- variable-font setup stays identical in async and first-layout code paths.
---@param self table
---@param key string
---@param reason string|nil
---@return table|nil GlyphCache
local function parse_raw_key(self, key, reason)
    if self._font_caches[key] then return self._font_caches[key] end
    if self._failed[key] then return nil end

    local raw = self._raw_cache[key]
    if not raw then return nil end

    remove_pending_key(self, key)

    local reason_suffix = reason and ("/" .. reason) or ""
    self._platform:log("[Astro Font] Parsing" .. reason_suffix .. ": " .. key .. " (" .. #raw .. " bytes)")

    local font = decode_and_parse(self, raw, key)
    local cache = nil
    if font then
        -- Detect variable fonts (fvar table present)
        local fvar = TtfParser.parse_fvar(font.data, font.tables)
        if fvar then
            font.fvar = fvar
            font.avar = TtfParser.parse_avar(font.data, font.tables, #fvar.axes)
            font.gvar = TtfParser.parse_gvar(font.data, font.tables, font.maxp.numGlyphs, #fvar.axes)
            -- HVAR provides per-glyph advance-width deltas at variation
            -- instances. Without it, get_advance() reads only the base
            -- hmtx -" drifting from Chrome by ~0.5-1px per glyph on
            -- non-default-weight variable instances.
            font.hvar = TtfParser.parse_hvar(font.data, font.tables)
            self._variable_info[key] = font
            cache = GlyphCache:new(font, self._platform)
            self._font_caches[key] = cache
            self._platform:log("[Astro Font] Variable font: " .. key
                .. " | axes=" .. #fvar.axes
                .. " | gvar=" .. (font.gvar and "yes" or "no")
                .. " | hvar=" .. (font.hvar and "yes" or "no"))
        else
            cache = GlyphCache:new(font, self._platform)
            self._font_caches[key] = cache
        end
        self._just_ready = true
        self._platform:log("[Astro Font] Ready: " .. key)
    else
        self._failed[key] = true
    end

    -- Free raw data after parse to save memory.
    self._raw_cache[key] = nil
    return cache
end

--- If a disk/download hit has already supplied raw bytes, resolve them now.
--- This prevents first-layout text measurement from falling back while the
--- font is merely waiting for the next deferred parse tick.
---@param self table
---@param key string
---@return table|nil GlyphCache
local function ensure_parsed_if_raw(self, key)
    if self._font_caches[key] then return self._font_caches[key] end
    if self._raw_cache[key] and not self._failed[key] then
        return parse_raw_key(self, key, "sync")
    end
    return nil
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Register a custom font with a download URL.
--- Overrides built-in entries with the same name.
---@param name string  Font identifier (e.g. "my-font")
---@param url string|table   Direct URL to a .ttf/.woff file, or { url=..., enable_ttf_hinting=... }
---@param options table|nil  Per-font config flags
function FontManager:register(name, url, options)
    local key = str_lower(name)
    if type(url) == "table" then
        options = url
        url = options.url
    end
    self._fonts[key] = url
    self._family_names[key] = true
    self._font_options[key] = options or nil
    if options and options.enable_ttf_hinting ~= nil then
        self._hinting_overrides[key] = options.enable_ttf_hinting == true
    end
    -- Clear failure state so it can be retried
    self._failed[key] = nil
end

--- Convert CSS font-weight values to a numeric weight.
---@param weight any
---@param parent_weight number|nil
---@return number
function FontManager:_normalize_weight(weight, parent_weight)
    if type(weight) == "string" then
        local s = str_lower(weight):match("^%s*(.-)%s*$")
        if s == "normal" then return 400 end
        if s == "bold" then return 700 end
        if s == "bolder" then
            return math.min(900, (parent_weight or 400) + 300)
        end
        if s == "lighter" then
            return math.max(100, (parent_weight or 400) - 300)
        end
        local n = tonumber(s)
        if n then return n end
    elseif type(weight) == "number" then
        return weight
    end
    return 400
end

--- Parse a single @font-face font-weight value.
--- Weight ranges ("100 900") return nil and are treated as variable/base faces.
---@param weight any
---@return number|nil
function FontManager:_single_weight(weight)
    if weight == nil then return nil end
    if type(weight) == "number" then return weight end
    if type(weight) ~= "string" then return nil end
    local s = str_lower(weight):match("^%s*(.-)%s*$")
    if s == "normal" then return 400 end
    if s == "bold" then return 700 end
    if s == "bolder" then return 700 end
    if s == "lighter" then return 300 end
    if s:find("%s") then return nil end
    return tonumber(s)
end

--- Register one @font-face rule, using static weight registration when possible.
---@param name string
---@param url string
---@param weight any|nil
---@return string load_key
---@return boolean weight_specific
function FontManager:register_face(name, url, weight, style, options)
    local single = self:_single_weight(weight)
    local style_key = normalize_style(style)
    if single or style_key ~= "normal" then
        return self:register_weight(name, single or 400, url, style_key, options), true
    end
    self:register(name, url, options)
    return str_lower(name), false
end

--- Register a per-weight static font file.
---@param name   string  Font family name
---@param weight number  CSS weight (100-900)
---@param url    string  URL to the weight-specific TTF/WOFF
---@param style  string|table|nil CSS font-style, or options table
---@param options table|nil Per-font config flags
---@return string load_key
function FontManager:register_weight(name, weight, url, style, options)
    local key = str_lower(name)
    if type(style) == "table" and options == nil then
        options = style
        style = nil
    end
    local q = self:_quantize_weight(self:_normalize_weight(weight))
    local style_key = normalize_style(style)
    local load_key = style_weight_cache_key(key, q, style_key)
    self._family_names[key] = true
    if not self._font_weights[key] then self._font_weights[key] = {} end
    if style_key == "normal" then
        self._font_weights[key][q] = { url = url, key = load_key }
    end
    if not self._font_faces[key] then self._font_faces[key] = {} end
    self._font_faces[key][#self._font_faces[key] + 1] = {
        url = url,
        key = load_key,
        weight = q,
        style = style_key,
    }
    self._fonts[load_key] = url
    self._font_options[load_key] = options or nil
    if options and options.enable_ttf_hinting ~= nil then
        self._hinting_overrides[load_key] = options.enable_ttf_hinting == true
    end
    if load_key ~= key then
        self._weight_keys[load_key] = { family = key, weight = q, style = style_key }
    end
    self._failed[load_key] = nil
    return load_key
end

--- Set or clear a per-font TrueType hinting override.
---@param family string
---@param weight number|string|nil
---@param enabled boolean|nil
---@return boolean
function FontManager:set_hinting(family, weight, enabled)
    if not family then return false end
    local key = str_lower(family)
    local load_key = key
    if weight ~= nil then
        local q = self:_quantize_weight(self:_normalize_weight(weight))
        local face = self:_select_static_face(key, q, "normal")
        load_key = (face and face.key) or style_weight_cache_key(key, q, "normal")
    end

    if enabled == nil then
        self._hinting_overrides[load_key] = nil
    else
        self._hinting_overrides[load_key] = enabled == true
    end

    local cache = self._font_caches[load_key]
    if cache and cache._font then
        self:_apply_hinting_policy(cache._font, load_key)
    end
    local weight_caches = self._weight_caches[key]
    if weight_caches then
        for _, wc in pairs(weight_caches) do
            if wc and wc._font then self:_apply_hinting_policy(wc._font, load_key) end
        end
    end
    return true
end

--- Check if a font is ready (parsed and cached).
---@param name string
---@return boolean
function FontManager:is_ready(name)
    return self._font_caches[str_lower(name)] ~= nil
end

--- Check if a font is currently loading.
---@param name string
---@return boolean
function FontManager:is_loading(name)
    local key = str_lower(name)
    if self._downloading[key] then return true end
    if self._raw_cache[key] and not self._font_caches[key] and not self._failed[key] then return true end
    return false
end

--- Check if a font failed to load.
---@param name string
---@return boolean
function FontManager:has_failed(name)
    return self._failed[str_lower(name)] == true
end

local function strip_family_quotes(token)
    token = trim(token)
    local first = token:sub(1, 1)
    local last = token:sub(-1)
    if #token >= 2 and ((first == '"' and last == '"') or (first == "'" and last == "'")) then
        token = token:sub(2, -2)
        token = token:gsub('\\"', '"'):gsub("\\'", "'")
    end
    return token
end

--- Split a CSS font-family stack into normalized cache candidate keys.
---@param name string|table
---@return table
function FontManager:_family_candidates(name)
    local result, seen = {}, {}
    if type(name) == "table" then
        for i = 1, #name do
            local key = str_lower(strip_family_quotes(tostring(name[i])))
            append_unique(result, seen, GENERIC_FAMILY_MAP[key] or key)
        end
        return result
    end

    local raw = tostring(name or "")
    local token = {}
    local quote = nil
    for i = 1, #raw do
        local ch = raw:sub(i, i)
        if quote then
            token[#token + 1] = ch
            if ch == quote then quote = nil end
        elseif ch == '"' or ch == "'" then
            quote = ch
            token[#token + 1] = ch
        elseif ch == "," then
            local key = str_lower(strip_family_quotes(table.concat(token)))
            append_unique(result, seen, GENERIC_FAMILY_MAP[key] or key)
            token = {}
        else
            token[#token + 1] = ch
        end
    end
    local key = str_lower(strip_family_quotes(table.concat(token)))
    append_unique(result, seen, GENERIC_FAMILY_MAP[key] or key)
    return result
end

local function style_candidates(style)
    local s = normalize_style(style)
    if s == "italic" then
        return { "italic", "oblique", "normal" }
    elseif s == "oblique" then
        return { "oblique", "italic", "normal" }
    end
    return { "normal" }
end

function FontManager:_get_variable_cache_for_key(key, qw)
    local var_info = self._variable_info[key]
    if var_info then
        local default_w = 400
        if var_info.fvar and var_info.fvar.axes then
            for i = 1, #var_info.fvar.axes do
                local axis = var_info.fvar.axes[i]
                if axis.tag == "wght" then
                    default_w = axis.default or 400
                    break
                end
            end
        end
        if qw == self:_quantize_weight(default_w) then
            return self._font_caches[key]
        end
        if not self._weight_caches[key] then self._weight_caches[key] = {} end
        if not self._weight_caches[key][qw] then
            self._platform:log("[Astro Font] Creating variable weight: " .. key .. " w=" .. qw)
            local norm = TtfParser.normalize_coords(var_info.fvar, var_info.avar, { wght = qw })
            self._weight_caches[key][qw] = GlyphCache:new(var_info, self._platform, norm)
        end
        return self._weight_caches[key][qw]
    end
    return nil
end

function FontManager:_select_static_face(key, qw, style)
    local faces = self._font_faces[key]
    if not faces then return nil end

    local styles = style_candidates(style)
    for si = 1, #styles do
        local wanted_style = styles[si]
        local exact = nil
        local best, best_dist = nil, 999999
        local count, non_regular_count, has_regular = 0, 0, false
        for i = 1, #faces do
            local face = faces[i]
            if face.style == wanted_style then
                count = count + 1
                if face.weight == qw then exact = face end
                if face.weight ~= 400 then non_regular_count = non_regular_count + 1 end
                if face.weight == 400 then has_regular = true end
                local dist = math.abs(face.weight - qw)
                if dist < best_dist then
                    best_dist = dist
                    best = face
                end
            end
        end
        if exact then return exact end
        if best and (wanted_style ~= "normal" or non_regular_count > 0 or not has_regular) then
            return best
        end
        if count > 0 and wanted_style ~= "normal" then
            return best
        end
    end

    return nil
end

function FontManager:_get_cache_for_single(key, weight, style)
    if not key or key == "" then return nil end
    weight = self:_normalize_weight(weight or 400)
    local qw = self:_quantize_weight(weight)

    -- If tick() already read/downloaded the raw bytes, parse them before
    -- returning nil. Otherwise the first layout pass can cache fallback
    -- measurements and stale wraps before the next deferred parse tick.
    ensure_parsed_if_raw(self, key)

    -- 1. Variable font: lazy-create instance for requested weight.
    local variable_cache = self:_get_variable_cache_for_key(key, qw)
    if variable_cache then return variable_cache end

    -- 2. Static per-weight font files registered via register_weight/@font-face.
    local face = self:_select_static_face(key, qw, style)
    if face then
        local load_key = face.key
        ensure_parsed_if_raw(self, load_key)
        local cache = self:_get_variable_cache_for_key(load_key, qw) or self._font_caches[load_key]
        if cache then return cache end
        self:_queue_load_key(load_key)
        if normalize_style(style) ~= "normal" then
            return self._font_caches[key]
        end
        return nil
    end

    -- 3. Synthetic weight: create emboldened/lightened cache from base font
    local base = self._font_caches[key]
    if not base and self._fonts[key] then
        self:_queue_load_key(key)
    end
    if not base or qw == 400 then return base end
    if not self._weight_caches[key] then self._weight_caches[key] = {} end
    if not self._weight_caches[key][qw] then
        local embolden = (qw - 400) / 300
        self._platform:log("[Astro Font] Creating SYNTHETIC weight: " .. key .. " w=" .. qw .. " embolden=" .. embolden)
        self._weight_caches[key][qw] = GlyphCache:new(base._font, self._platform, nil, embolden)
    end
    return self._weight_caches[key][qw]
end

--- Get the GlyphCache for a specific font stack, weight, and style.
--- For variable fonts, lazily creates weight instances.
--- For static per-weight files, finds closest available weight.
--- Returns nil if no candidate is ready yet.
---@param name   string|table  Font family or CSS fallback stack
---@param weight number|nil  CSS font weight (100-900), default 400
---@param style  string|nil  CSS font-style
---@return table|nil  GlyphCache instance
function FontManager:get_cache_for(name, weight, style)
    if not name then return nil end
    local candidates = self:_family_candidates(name)
    for i = 1, #candidates do
        local cache = self:_get_cache_for_single(candidates[i], weight, style)
        if cache then return cache end
    end
    return nil
end

--- Quantize a weight to the nearest 100 (100-900).
---@param w number
---@return number
function FontManager:_quantize_weight(w)
    local q = math.floor(w / 100 + 0.5) * 100
    if q < 100 then q = 100 end
    if q > 900 then q = 900 end
    return q
end

--- Find the closest available weight in a cache table.
---@param caches table  { [weight] = GlyphCache }
---@param target number
---@return number|nil  closest weight key
function FontManager:_find_closest_weight(caches, target)
    local best_w = nil
    local best_dist = 999999
    for w in pairs(caches) do
        local dist = math.abs(w - target)
        if dist < best_dist then
            best_dist = dist
            best_w = w
        end
    end
    return best_w
end

--- Returns true if any font became ready since last call.
--- Resets the flag after reading.
---@return boolean
function FontManager:pop_just_ready()
    local r = self._just_ready
    self._just_ready = false
    return r
end

--- Queue loading of an already-normalized font key.
---@param key string
---@return boolean queued
function FontManager:_queue_load_key(key)
    if self._font_caches[key] then return false end
    if self._raw_cache[key] then return false end
    if self._failed[key] then return false end
    if self._downloading[key] then return false end
    if self._load_queued[key] then return false end

    self._load_queued[key] = true
    self._load_queue[#self._load_queue + 1] = key
    return true
end

--- Trigger loading of a font by name.
--- Fully non-blocking: queues the font for deferred loading
--- in tick(), which handles disk cache reads, downloads, and
--- parsing -" one step per frame to avoid frame stalls.
---@param name string
function FontManager:load(name)
    local key = str_lower(name)

    -- Already parsed, pending, failed, or queued -" nothing to do
    if self._font_caches[key] then return end
    if self._raw_cache[key] then return end
    if self._failed[key] then return end
    if self._downloading[key] then return end
    if self._load_queued[key] then return end

    -- Queue for deferred disk-cache check in tick()
    self._load_queued[key] = true
    self._load_queue[#self._load_queue + 1] = key
end

--- Internal: attempt disk cache read + download for one font.
--- Called from tick() to spread I/O across frames.
---@param key string  Lowercased font name
local function deferred_load_one(self, key)
    -- Re-check: might have been resolved by a prior tick
    if self._font_caches[key] or self._raw_cache[key]
       or self._failed[key] or self._downloading[key] then
        return
    end

    local url = self._fonts[key]
    if not url then
        self._failed[key] = true
        return
    end

    -- Try disk cache (validate magic bytes to reject corrupted files).
    -- Include the resolved URL in the path so @font-face updates for the same
    -- family do not reuse stale bytes from an older source.
    ensure_cache_dir(self)
    local path = cache_filename({ name = key, url = url })
    local ok, raw = pcall(self._platform.read_data_file, self._platform, path)
    if ok and raw and #raw > 256 then
        local b1, b2, b3, b4 = string.byte(raw, 1, 4)
        local sig_ok = (b1 == 0 and b2 == 1 and b3 == 0 and b4 == 0)  -- TTF
                    or (b1 == 0x4F and b2 == 0x54 and b3 == 0x54 and b4 == 0x4F)  -- OTTO (OTF)
                    or (b1 == 0x77 and b2 == 0x4F and b3 == 0x46 and b4 == 0x46)  -- wOFF
                    or (b1 == 0x77 and b2 == 0x4F and b3 == 0x46 and b4 == 0x32)  -- wOF2
        if sig_ok then
            self._platform:log("[Astro Font] Disk cache hit: " .. key .. " (" .. #raw .. " bytes)")
            self._raw_cache[key] = raw
            self._pending[#self._pending + 1] = key
            return
        else
            self._platform:log("[Astro Font] Disk cache CORRUPTED (bad signature): " .. key .. " (" .. #raw .. " bytes) - re-downloading")
        end
    end

    self._downloading[key] = true
    self._platform:log("[Astro Font] Downloading: " .. key .. " from " .. url)

    local mgr = self
    local ok_start, started = pcall(self._platform.http_get, self._platform, url, function(http_code, content_type, data, headers)
        mgr._downloading[key] = nil

        if http_code ~= 200 or not data or #data == 0 then
            pcall(mgr._platform.log, mgr._platform, "[Astro Font] Download FAILED: " .. key .. " http=" .. tostring(http_code))
            mgr._failed[key] = true
            return
        end

        pcall(mgr._platform.log, mgr._platform, "[Astro Font] Downloaded: " .. key .. " (" .. #data .. " bytes)")

        -- Store raw data and queue for deferred parsing
        mgr._raw_cache[key] = data
        mgr._pending[#mgr._pending + 1] = key

        -- Persist to disk cache
        local wok, werr = pcall(function()
            mgr._platform:create_data_file(path)
            mgr._platform:write_data_file(path, data)
        end)
        if not wok then
            pcall(mgr._platform.log, mgr._platform, "[Astro Font] Disk cache write failed: " .. tostring(werr))
        end
    end)
    if not ok_start or started == false then
        self._downloading[key] = nil
        self._failed[key] = true
    end
end

--- Process one deferred operation per frame. Call from the
--- main update loop to spread I/O and parsing across frames.
---
--- Priority: load queue (disk reads) first, then parse queue.
--- This ensures each frame does at most one heavy operation.
function FontManager:tick()
    -- Phase 1: deferred disk-cache read (one per frame)
    if #self._load_queue > 0 then
        local key = table.remove(self._load_queue, 1)
        self._load_queued[key] = nil
        deferred_load_one(self, key)
        return  -- one heavy op per frame
    end

    -- Phase 2: deferred parsing (one per frame)
    if #self._pending == 0 then return end
    local key = table.remove(self._pending, 1)
    local raw = self._raw_cache[key]
    if not raw or self._font_caches[key] or self._failed[key] then return end

    parse_raw_key(self, key, "tick")
end

--- Get a sorted list of all registered font names.
---@return table  Array of lowercase font key strings
function FontManager:get_registered_names()
    local names = {}
    for key in pairs(self._family_names) do
        names[#names + 1] = key
    end
    table.sort(names)
    return names
end

function FontManager:get_hinting_stats()
    local fonts = {}
    local total = { hinted = 0, fallback = 0, opcodes_seen = {} }
    local seen = {}

    local function add_cache(key, cache)
        if not cache or seen[cache] then return end
        seen[cache] = true
        if type(cache.get_hinting_stats) ~= "function" then return end
        local stats = cache:get_hinting_stats()
        fonts[key] = stats
        total.hinted = total.hinted + (stats.hinted_glyphs or 0)
        total.fallback = total.fallback + (stats.fallback_count or 0)
        for op, count in pairs(stats.opcode_coverage or {}) do
            total.opcodes_seen[op] = (total.opcodes_seen[op] or 0) + count
        end
    end

    for key, cache in pairs(self._font_caches) do
        add_cache(key, cache)
    end
    for family, caches in pairs(self._weight_caches) do
        for weight, cache in pairs(caches) do
            add_cache(family .. "__w" .. tostring(weight), cache)
        end
    end
    return { fonts = fonts, total = total }
end

--- Clear the failure flag for a font so the next load()
--- attempt will try to download it again.
---@param name string
function FontManager:retry(name)
    local key = str_lower(name)
    self._failed[key] = nil
end

return FontManager



