------------------------------------------------------------
-- ext_core_astro_ui_lib / core / platform / platform_api.lua
-- Platform Interface Specification (documentation only).
--
-- Any platform adapter must implement ALL methods listed
-- below.  The engine and display_list interact with the
-- platform exclusively through this interface, making the
-- rest of the library platform-agnostic.
--
-- Color values are always passed as individual r, g, b, a
-- integers (0-255).  The adapter is responsible for
-- converting them into whatever Color type the host
-- platform expects.
--
-- Coordinate values are plain numbers (pixels).  The
-- adapter converts them to any required vector type.
------------------------------------------------------------

--[[

=== DRAWING ===

platform:draw_rect_filled(x, y, w, h, r, g, b, a, rounding)
    Draw a filled rectangle.
    rounding (number, optional, default 0): corner radius.

platform:draw_rect(x, y, w, h, r, g, b, a, thickness, rounding)
    Draw an outlined (stroked) rectangle.
    thickness (number): line width.
    rounding  (number, optional, default 0): corner radius.

platform:draw_line(x1, y1, x2, y2, r, g, b, a, thickness)
    Draw a straight line between two points.

platform:draw_circle_filled(cx, cy, radius, r, g, b, a)
    Draw a filled circle.

platform:draw_triangle_filled(x1, y1, x2, y2, x3, y3, r, g, b, a)
    Draw a filled triangle.

platform:draw_text(text, x, y, font_size, r, g, b, a, centered, font_id)
    Draw a text string.
    centered (boolean): if true the text is horizontally centered at x.
    font_id  (number, optional, default 0): font index.

platform:draw_texture(tex_id, x, y, w, h, r, g, b, a)
    Draw a loaded texture / image.

platform:draw_texture_rect(tex_id, x, y, w, h, uv0_x, uv0_y, uv1_x, uv1_y, r, g, b, a)
    Draw a texture sub-rectangle using UV coordinates.


=== CLIPPING ===

platform:clip_push(x, y, w, h)
    Push a clipping rectangle for subsequent drawing.

platform:clip_pop()
    Pop the current clipping rectangle.

platform:has_scissor() -> boolean
    Return whether native scissor clipping is available.

platform:has_texture_rect() -> boolean
    Return whether UV texture-rectangle drawing is available.


=== MEASUREMENT ===

platform:measure_text_width(text, font_size, font_id) -> number
    Return the pixel width of the given text string.
    font_id (number, optional, default 0).

platform:get_font_height(font_size) -> number
    Return the approximate pixel height for a given font size.
    (A safe default is font_size * 1.2.)

platform:get_normal_line_height(family, font_size, dpr, weight, style) -> number | nil  (optional)
    Return a platform-specific CSS line box for `line-height: normal`.
    Return nil to let the engine resolve normal from bundled font metrics.

platform:resolve_line_height(raw, family, font_size, dpr, weight, style) -> number | nil  (optional)
    Return a platform-specific CSS line box for non-normal line-height
    values. Return nil to use the shared engine resolver.

platform:get_scrollbar_gutter_width() -> number
    Return the CSS-pixel width that non-root `overflow: auto|scroll`
    containers should reserve for a vertical scrollbar gutter.
    Reference values:
      * 15 -" Windows classic scrollbar (Chrome on Windows default).
      *  7 -" Sylvanas in-game thin scrollbar
             (SB_WIDTH=6 + SB_MARGIN=1 in core/scroll/scroll_engine.lua,
             so content stops flush at the painted track's left edge).
      *  0 -" overlay scrollbars (macOS modern, headless Chrome,
             prefers-reduced-motion: reduce on some platforms).
    The engine calls this once per layout pass; the host may return
    a different value each call (e.g. after detecting an OS
    preference change).  When a platform omits this method, block
    layout assumes 15 so older adapters keep their pre-feature
    behavior.


=== TEXTURES ===

platform:load_texture(image_data_bytes) -> tex_id, width, height | nil
    Load a texture from raw image bytes.
    Returns tex_id, width, height on success; nil on failure.


=== INPUT ===

platform:get_cursor_position() -> x, y
    Return the current mouse cursor position in screen pixels.

platform:is_key_pressed(vk_code) -> boolean
    Return whether a key (Windows virtual-key code) is
    currently held down.

platform:get_wheel_delta() -> number
    Return the mouse-wheel scroll delta since the last frame.
    Must never error; return 0 if the host API is unavailable.

platform:capture_mouse()
platform:capture_keyboard()
    Capture mouse or keyboard input for the current frame when
    the UI owns interaction focus.


=== CLIPBOARD ===

platform:get_clipboard_text() -> string
    Return the system clipboard text or an empty string.

platform:copy_to_clipboard(text) -> boolean
    Copy text to the system clipboard. Return true on success.


=== TIME ===

platform:time() -> number
    Seconds since the host application started / was injected.

platform:delta_time() -> number
    Seconds elapsed since the previous frame.

platform:profiler_ticks() -> number
    Monotonic high-resolution profiler ticks. The Sylvanas adapter prefers
    core.cpu_time() nanoseconds, then core.cpu_ticks(), then core.game_time().

platform:profiler_ticks_per_second() -> number
    Tick frequency for profiler_ticks(). Return 1 for second-based clocks,
    1000 for millisecond clocks, 1000000000 for nanosecond clocks.


=== SCREEN ===

platform:get_screen_size() -> width, height
    Return the current viewport dimensions in pixels.

platform:get_dpr() -> number  (optional)
    Return the device pixel ratio the engine should use for line-height
    per-component rounding (Painters._dpr / Engine._dpr).
    "1 layout px" maps to "N physical pixels" -" return N.
    On browsers this is window.devicePixelRatio. On in-game platforms
    that author against a design canvas (Sylvanas: 1920x1080) it is
    framebuffer_width / design_width.
    The method is OPTIONAL: it may be absent on a platform, AND when
    present it may legitimately return nil or a non-positive value
    (e.g. before the host graphics API is ready). Engine.new calls it
    once at construction and falls back to 1 if it is missing, errors,
    returns nil, or returns a number <= 0. Callers that need to refresh
    DPR at runtime (Retina/standard monitor swap, OS display-scale
    change) should re-invoke engine:set_dpr explicitly; the engine does
    not poll this method.


=== FILE I/O ===
All paths are relative to a sandboxed data directory.

platform:read_data_file(path) -> string | nil
    Read the contents of a data file.  Return nil if it does
    not exist.

platform:write_data_file(path, data)
    Write *data* (string) to a data file, creating or
    overwriting as needed.

platform:create_data_folder(path)
    Ensure a directory exists inside the data sandbox.

platform:create_data_file(path)
    Ensure a file exists (create empty if missing).


=== HTTP ===

platform:http_get(url, headers, callback)
    Perform an asynchronous HTTP GET.
    headers  (table or nil): key-value header pairs.
    callback (function): called with (body_string) on
    completion.


=== AUDIO ===

platform:play_sound(sound_id)
    Play a host/game sound by numeric id.


=== LIFECYCLE ===

platform:register_render_callback(callback) -> boolean
    Register the engine frame callback with the host render loop.


=== LOGGING ===

platform:log(msg)
platform:log_warning(msg)
platform:log_error(msg)
    Write a message to the host log at the appropriate level.

]]

-- This file contains no executable code.
-- See sylvanas_platform.lua for the Project Sylvanas
-- implementation of this interface.
return "platform_api: interface specification (see comments)"



