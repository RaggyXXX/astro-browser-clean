------------------------------------------------------------
-- ext_core_astro_ui_lib / core / platform / sylvanas_platform.lua
-- Project Sylvanas adapter -- maps the platform interface
-- to the Sylvanas core.* API surface.
--
-- Every core.* call is wrapped in pcall for resilience.
-- Color objects (color.new) and position vectors (vec2.new)
-- are created internally; the rest of the library only
-- passes r,g,b,a integers and plain x,y numbers.
------------------------------------------------------------
local color = require("common/color")
local vec2  = require("common/geometry/vector_2")

local function snap_pos(v)
    return math.floor((v or 0) + 0.5)
end

local function snap_len(v)
    local n = math.floor((v or 0) + 0.5)
    if n < 0 then return 0 end
    return n
end

local Platform = {}
Platform.__index = Platform

function Platform.new()
    local self = setmetatable({}, Platform)
    -- Capabilities detected lazily (core.graphics may not exist yet)
    self._caps_checked = false
    self._has_scissor = false
    self._has_texture_rect = false
    self._clipboard_wnd = nil
    return self
end

--- Detect GPU capabilities on first use (core.graphics may
--- not be populated at Platform.new() time).
local function ensure_caps(self)
    if self._caps_checked then return end
    self._caps_checked = true
    if type(core) == "table" and type(core.graphics) == "table" then
        local g = core.graphics
        self._has_scissor      = type(g.scissor_push) == "function"
        self._has_texture_rect = type(g.draw_texture_rect) == "function"
    end
end

------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------

local function make_color(r, g, b, a)
    return color.new(r or 255, g or 255, b or 255, a or 255)
end

local function make_vec2(x, y)
    return vec2.new(x or 0, y or 0)
end

local function core_table()
    if type(core) == "table" then return core end
    return nil
end

local function core_fn(name)
    local c = core_table()
    if c and type(c[name]) == "function" then return c[name] end
    return nil
end

local function graphics_fn(name)
    local c = core_table()
    local g = c and c.graphics
    if type(g) == "table" and type(g[name]) == "function" then return g[name] end
    return nil
end

local function input_fn(name)
    local c = core_table()
    local input = c and c.input
    if type(input) == "table" and type(input[name]) == "function" then return input[name] end
    return nil
end

local function safe_log(msg)
    local fn = core_fn("log")
    if fn then pcall(fn, tostring(msg)) end
end

------------------------------------------------------------
-- DRAWING
------------------------------------------------------------

function Platform:draw_rect_filled(x, y, w, h, r, g, b, a, rounding)
    local fn = graphics_fn("rect_2d_filled")
    if not fn then return end
    x, y, w, h = snap_pos(x), snap_pos(y), snap_len(w), snap_len(h)
    pcall(fn,
        make_vec2(x, y), w, h,
        make_color(r, g, b, a),
        rounding or 0)
end

function Platform:draw_rect(x, y, w, h, r, g, b, a, thickness, rounding)
    local fn = graphics_fn("rect_2d")
    if not fn then return end
    x, y, w, h = snap_pos(x), snap_pos(y), snap_len(w), snap_len(h)
    pcall(fn,
        make_vec2(x, y), w, h,
        make_color(r, g, b, a),
        thickness or 1,
        rounding or 0)
end

function Platform:draw_line(x1, y1, x2, y2, r, g, b, a, thickness)
    local fn = graphics_fn("line_2d")
    if not fn then return end
    x1, y1, x2, y2 = snap_pos(x1), snap_pos(y1), snap_pos(x2), snap_pos(y2)
    pcall(fn,
        make_vec2(x1, y1),
        make_vec2(x2, y2),
        make_color(r, g, b, a),
        thickness or 1)
end

function Platform:draw_circle_filled(cx, cy, radius, r, g, b, a)
    local fn = graphics_fn("circle_2d_filled")
    if not fn then return end
    cx, cy, radius = snap_pos(cx), snap_pos(cy), snap_len(radius)
    pcall(fn,
        make_vec2(cx, cy),
        radius,
        make_color(r, g, b, a))
end

function Platform:draw_triangle_filled(x1, y1, x2, y2, x3, y3, r, g, b, a)
    local fn = graphics_fn("triangle_2d_filled")
    if not fn then return end
    x1, y1 = snap_pos(x1), snap_pos(y1)
    x2, y2 = snap_pos(x2), snap_pos(y2)
    x3, y3 = snap_pos(x3), snap_pos(y3)
    pcall(fn,
        make_vec2(x1, y1),
        make_vec2(x2, y2),
        make_vec2(x3, y3),
        make_color(r, g, b, a))
end

function Platform:draw_text(text, x, y, font_size, r, g, b, a, centered, font_id)
    local fn = graphics_fn("text_2d")
    if not fn then return end
    x, y = snap_pos(x), snap_pos(y)
    pcall(fn,
        text,
        make_vec2(x, y),
        font_size,
        make_color(r, g, b, a),
        centered or false,
        font_id or 0)
end

function Platform:draw_texture(tex_id, x, y, w, h, r, g, b, a)
    local fn = graphics_fn("draw_texture")
    if not fn then return end
    x, y, w, h = snap_pos(x), snap_pos(y), snap_len(w), snap_len(h)
    pcall(fn,
        tex_id,
        make_vec2(x, y),
        w, h,
        make_color(r, g, b, a),
        false)
end

--- Draw a sub-region of a texture via UV coordinates.
--- uv0_x, uv0_y = top-left UV (0..1); uv1_x, uv1_y = bottom-right UV (0..1).
--- Full texture: uv0 = (0,0), uv1 = (1,1).
function Platform:draw_texture_rect(tex_id, x, y, w, h, uv0_x, uv0_y, uv1_x, uv1_y, r, g, b, a)
    local fn = graphics_fn("draw_texture_rect")
    if not fn then return end
    x, y, w, h = snap_pos(x), snap_pos(y), snap_len(w), snap_len(h)
    pcall(fn,
        tex_id,
        make_vec2(x, y),
        w, h,
        uv0_x, uv0_y, uv1_x, uv1_y,
        make_color(r, g, b, a),
        false)
end

------------------------------------------------------------
-- MEASUREMENT
------------------------------------------------------------

function Platform:measure_text_width(text, font_size, font_id)
    text = tostring(text or "")
    font_size = font_size or 12
    local fn = graphics_fn("get_text_width")
    local ok, result = false, nil
    if fn then ok, result = pcall(fn, text, font_size, font_id or 0) end
    if ok and type(result) == "number" then
        return result
    end
    -- Rough fallback: ~0.6 * font_size per character
    return #text * font_size * 0.6
end

function Platform:get_font_height(font_size)
    return font_size * 1.2
end

function Platform:get_normal_line_height(family, font_size)
    local fam = type(family) == "string" and family:lower() or ""
    if fam == "monospace" or fam == "ui-monospace" then
        -- Chrome's UA generic monospace line boxes are tighter than the
        -- bundled Fira Code hhea metrics. In Sylvanas that difference made
        -- <pre> blocks 2px taller per line and cascaded into late-section
        -- parity drift. Keep glyph rendering self-drawn; only normalize the
        -- CSS line box for generic monospace normal line-height.
        return math.floor((font_size or 16) * 1.2 + 0.5)
    end
    return nil
end

function Platform:resolve_line_height(raw, family, font_size)
    if type(raw) == "number" and raw > 0 and raw < 5 then
        -- Unitless author line-height is a CSS used value, not a font metric.
        -- Sylvanas' DPR-rounded resolver turned 18px * 1.4 section titles
        -- into 26px boxes, while Chrome reports ~25.1875px. Returning the
        -- direct used value removes the repeated section-title cascade
        -- without changing glyph metrics or self-drawn text rendering.
        return raw * (font_size or 16)
    end
    return nil
end

function Platform:should_use_ttf_hinting()
    -- Default OFF in-game: the Lua-implemented TTF bytecode interpreter
    -- (phase 7) runs 207+ opcodes per glyph and causes severe frame lag at
    -- typical Sylvanas DPR (1.3x). The interpreter is correctness-clean but
    -- the per-frame cost is too high without a native fast path.
    -- Enable per-font via FontManager:set_hinting(family, weight, true) only
    -- when the host has a way to amortize the cost.
    return false
end

function Platform:requires_integer_paint_coordinates()
    -- Sylvanas core.graphics rasterizer is most stable when draw calls
    -- receive integer CSS-pixel coordinates. Fractional coordinates from
    -- Phase 9c paint snap (DPR-aware grid) confuse the host's atlas
    -- caching and break glyph IMAGE alignment. Self-drawn glyphs already
    -- round to integers in the painter; we just need to ensure the
    -- display-list replay does NOT re-fractionalize them.
    return true
end

--- CSS-pixel width to reserve for a vertical scrollbar gutter on non-root
--- `overflow: auto|scroll` containers.  Block layout consults this once per
--- pass via core/layout/block.lua so children inside an overflow container
--- report a content-width matching what the host actually paints.
---
--- Sylvanas paints its own thin scrollbar at
---   x = lay.x + lay.w - SB_WIDTH - SB_MARGIN
---     = lay.x + lay.w - 6        - 1         = lay.x + lay.w - 7
--- (see core/scroll/scroll_engine.lua: SB_WIDTH = 6, SB_MARGIN = 1).
--- The reserved gutter must therefore be 7 CSS px so content stops at
--- the painted track's left edge; reserving only 6 leaves a 1-pixel
--- overlap where text/borders would land under the scrollbar.  The
--- ~8 px Chrome's classic scrollbar would additionally reserve isn't
--- ours to claim -" the engine renders the thumb inline atop the
--- gutter and we want flush-to-track content alignment, not extra
--- breathing room.
function Platform:get_scrollbar_gutter_width()
    return 7
end

------------------------------------------------------------
-- TEXTURES
------------------------------------------------------------

function Platform:load_texture(image_data_bytes)
    local fn = graphics_fn("load_texture")
    if not fn then return nil end
    local ok, tex_id, w, h = pcall(fn, image_data_bytes)
    if ok and tex_id then
        return tex_id, w, h
    end
    return nil
end

------------------------------------------------------------
-- CLIPPING
------------------------------------------------------------

--- Push a GPU scissor rectangle.  All subsequent draw calls
--- are clipped to the intersection of (x, y, w, h) and the
--- current scissor rect.
---@param x number
---@param y number
---@param w number
---@param h number
function Platform:clip_push(x, y, w, h)
    ensure_caps(self)
    if self._has_scissor then
        local fn = graphics_fn("scissor_push")
        x, y, w, h = snap_pos(x), snap_pos(y), snap_len(w), snap_len(h)
        if fn then pcall(fn, x, y, w, h) end
    end
end

--- Pop the most recent GPU scissor rectangle.
function Platform:clip_pop()
    if self._has_scissor then
        local fn = graphics_fn("scissor_pop")
        if fn then pcall(fn) end
    end
end

--- Returns true if GPU scissor is available.
function Platform:has_scissor()
    ensure_caps(self)
    return self._has_scissor
end

--- Returns true if draw_texture_rect (UV sub-rect) is available.
function Platform:has_texture_rect()
    ensure_caps(self)
    return self._has_texture_rect
end

------------------------------------------------------------
-- INPUT
------------------------------------------------------------

function Platform:get_cursor_position()
    local fn = core_fn("get_cursor_position")
    if not fn then return 0, 0 end
    local ok, result = pcall(fn)
    if ok and result then
        return result.x or 0, result.y or 0
    end
    return 0, 0
end

function Platform:is_key_pressed(vk_code)
    local fn = input_fn("is_key_pressed")
    if not fn then return false end
    local ok, result = pcall(fn, vk_code)
    if ok then
        return result == true
    end
    return false
end

function Platform:get_wheel_delta()
    -- core.get_mouse_wheel_delta may not exist; guard carefully.
    if type(core) ~= "table" then return 0 end
    if type(core.get_mouse_wheel_delta) ~= "function" then return 0 end
    local ok, result = pcall(core.get_mouse_wheel_delta)
    if ok and type(result) == "number" then
        return result
    end
    return 0
end

------------------------------------------------------------
-- INPUT BLOCKING
------------------------------------------------------------

--- Capture mouse input for this frame, preventing the game
--- from processing mouse clicks (camera, targeting, etc.).
--- Must be called every frame while blocking is desired.
function Platform:capture_mouse()
    if type(core) == "table" and type(core.graphics) == "table"
       and type(core.graphics.capture_next_mouse_input) == "function" then
        pcall(core.graphics.capture_next_mouse_input)
    end
end

--- Capture keyboard input for this frame, preventing the game
--- from processing key presses (WASD, hotkeys, chat, etc.).
--- Must be called every frame while blocking is desired.
function Platform:capture_keyboard()
    if type(core) == "table" and type(core.graphics) == "table"
       and type(core.graphics.capture_next_keyboard_input) == "function" then
        pcall(core.graphics.capture_next_keyboard_input)
    end
end

------------------------------------------------------------
-- TIME
------------------------------------------------------------

local function has_core_fn(name)
    return core_fn(name) ~= nil
end

function Platform:time()
    local fn = core_fn("time")
    if not fn then return 0 end
    local ok, result = pcall(fn)
    if ok and type(result) == "number" then
        return result
    end
    return 0
end

function Platform:delta_time()
    local fn = core_fn("delta_time")
    if not fn then return 0 end
    local ok, result = pcall(fn)
    if ok and type(result) == "number" then
        return result
    end
    return 0
end

function Platform:profiler_ticks()
    if has_core_fn("cpu_time") then
        local ok, result = pcall(core_fn("cpu_time"))
        if ok and type(result) == "number" then
            return result
        end
    end
    if has_core_fn("cpu_ticks") then
        local ok, result = pcall(core_fn("cpu_ticks"))
        if ok and type(result) == "number" then
            return result
        end
    end
    if has_core_fn("game_time") then
        local ok, result = pcall(core_fn("game_time"))
        if ok and type(result) == "number" then
            return result
        end
    end
    return self:time()
end

function Platform:profiler_ticks_per_second()
    if has_core_fn("cpu_time") then
        return 1000000000
    end
    if has_core_fn("cpu_ticks_per_second") then
        local ok, result = pcall(core_fn("cpu_ticks_per_second"))
        if ok and type(result) == "number" and result > 0 then
            return result
        end
    end
    if has_core_fn("game_time") then
        return 1000
    end
    return 1
end

------------------------------------------------------------
-- SCREEN
------------------------------------------------------------

function Platform:get_screen_size()
    local fn = graphics_fn("get_screen_size")
    if not fn then return 1920, 1080 end
    local ok, result = pcall(fn)
    if ok and result then
        return result.x or 1920, result.y or 1080
    end
    return 1920, 1080
end

-- Project Sylvanas authors UI against a 1920x1080 design canvas; the engine
-- draws into the game's actual framebuffer at native resolution. So one
-- engine "layout px" maps to (screen_w / 1920) physical pixels -" the same
-- ratio core.graphics.scale_*_to_screen_size uses internally. The engine's
-- `line-height: normal` resolver and Painters rounding consume this to
-- match Chrome's per-component device-pixel rounding (see Engine:set_dpr).
--
-- Clamped to a sane band to keep rounding numerically stable on weird
-- resolutions (ultra-wide, super-low). Defaults to 1 when the graphics API
-- isn't available yet (e.g. headless boot).
function Platform:get_dpr()
    local fn = graphics_fn("get_screen_size")
    if not fn then return 1 end
    local ok, result = pcall(fn)
    if not ok or not result then return 1 end
    local sw = tonumber(result.x)
    if not sw or sw <= 0 then return 1 end
    local dpr = sw / 1920
    if dpr < 0.5 then return 0.5 end
    if dpr > 4   then return 4   end
    return dpr
end

------------------------------------------------------------
-- FILE I/O
------------------------------------------------------------

function Platform:read_data_file(path)
    local fn = core_fn("read_data_file")
    if not fn then return nil end
    local ok, result = pcall(fn, path)
    if ok then
        return result
    end
    return nil
end

function Platform:write_data_file(path, data)
    local fn = core_fn("write_data_file")
    if not fn then return false, "write_data_file unavailable" end
    local ok, err = pcall(fn, path, data)
    if not ok then
        safe_log("[Astro Platform] write_data_file FAILED: " .. tostring(err))
    end
    return ok, err
end

function Platform:create_data_folder(path)
    local fn = core_fn("create_data_folder")
    if fn then pcall(fn, path) end
end

function Platform:create_data_file(path)
    local fn = core_fn("create_data_file")
    if fn then pcall(fn, path) end
end

------------------------------------------------------------
-- HTTP
------------------------------------------------------------

function Platform:http_get(url, headers_or_cb, callback)
    local actual_cb
    local actual_headers

    if type(headers_or_cb) == "function" then
        actual_cb = headers_or_cb
        actual_headers = nil
    elseif type(headers_or_cb) == "table" then
        actual_cb = callback
        actual_headers = headers_or_cb
    end

    local ok, err
    if actual_headers then
        local fn = core_fn("http_get")
        if not fn then return false, "http_get unavailable" end
        ok, err = pcall(fn, url, actual_headers, actual_cb)
    else
        local fn = core_fn("http_get")
        if not fn then return false, "http_get unavailable" end
        ok, err = pcall(fn, url, actual_cb)
    end

    if not ok then
        safe_log("[Astro HTTP] http_get failed: " .. tostring(err))
        return false, err
    end
    return true
end

------------------------------------------------------------
-- CLIPBOARD
------------------------------------------------------------

local function ensure_clipboard_wnd(self)
    if self._clipboard_wnd then return self._clipboard_wnd end
    local ok, wnd = pcall(function()
        if type(core) == "table" and type(core.menu) == "table"
           and type(core.menu.window) == "function" then
            return core.menu.window("##_astro_cb")
        end
    end)
    if ok and wnd then
        self._clipboard_wnd = wnd
    end
    return self._clipboard_wnd
end

function Platform:get_clipboard_text()
    local wnd = ensure_clipboard_wnd(self)
    if wnd and type(wnd.get_clipboard_text) == "function" then
        local ok, result = pcall(wnd.get_clipboard_text, wnd)
        if ok and type(result) == "string" then
            return result
        end
    end
    return ""
end

function Platform:copy_to_clipboard(text)
    local wnd = ensure_clipboard_wnd(self)
    if wnd and type(wnd.copy_to_clipboard) == "function" then
        local ok, result = pcall(wnd.copy_to_clipboard, wnd, text or "")
        return ok and result ~= false
    end
    return false
end

------------------------------------------------------------
-- AUDIO
------------------------------------------------------------

--- Play a game sound by its SoundKit ID.
---@param sound_id number  WoW SoundKit ID
function Platform:play_sound(sound_id)
    if not sound_id or sound_id <= 0 then return end
    local fn = core_fn("play_sound_by_id")
    if fn then pcall(fn, sound_id) end
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

function Platform:register_render_callback(callback)
    local fn = core_fn("register_on_render_callback")
    if fn then
        local ok, result = pcall(fn, callback)
        return ok and result ~= false
    end
    return false
end

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

function Platform:log(msg)
    local fn = core_fn("log")
    if fn then pcall(fn, tostring(msg)) end
end

function Platform:log_warning(msg)
    local fn = core_fn("log_warning") or core_fn("log")
    if fn then pcall(fn, tostring(msg)) end
end

function Platform:log_error(msg)
    local fn = core_fn("log_error") or core_fn("log")
    if fn then pcall(fn, tostring(msg)) end
end

return Platform



