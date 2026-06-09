------------------------------------------------------------
-- ext_core_astro_ui_lib / core / paint / display_list.lua
-- Command buffer with clip stack and replay.
--
-- Commands are stored as compact arrays for minimal GC
-- pressure.  The replay() method walks the buffer,
-- maintains a clip stack for early-cull optimisation, and
-- dispatches draw calls to the platform adapter.
--
-- GPU scissor support handles all
-- pixel-level clipping.  The software clip stack only exists
-- for fast overlap-culling of off-screen draw calls.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local helpers = require("core/util/helpers")
local rect_clip = helpers.rect_clip
local rect_intersects = helpers.rect_intersects
local floor = math.floor
local ceil = math.ceil

local DisplayList = {}
DisplayList.__index = DisplayList

local function valid_dpr(dpr)
    dpr = (type(dpr) == "number" and dpr > 0) and dpr or 1
    return dpr
end

local function paint_snap(v, dpr)
    if v == nil then return 0 end
    if v ~= v then return 0 end
    if v == math.huge or v == -math.huge then return v end
    dpr = valid_dpr(dpr)
    return floor(v * dpr + 0.5) / dpr
end

local function paint_snap_fill_rect(x, y, w, h, dpr)
    local x1 = paint_snap(x, dpr)
    local y1 = paint_snap(y, dpr)
    local x2 = paint_snap((x or 0) + (w or 0), dpr)
    local y2 = paint_snap((y or 0) + (h or 0), dpr)
    return x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1)
end

local function paint_snap_scissor_rect(x, y, w, h, dpr)
    dpr = valid_dpr(dpr)
    local x1 = floor((x or 0) * dpr) / dpr
    local y1 = floor((y or 0) * dpr) / dpr
    local x2 = ceil(((x or 0) + (w or 0)) * dpr) / dpr
    local y2 = ceil(((y or 0) + (h or 0)) * dpr) / dpr
    return x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1)
end

local function paint_snap_text_origin(x, y, dpr)
    return paint_snap(x, dpr), paint_snap(y, dpr)
end

local function paint_snap_centerline(x, dpr)
    return paint_snap(x, dpr)
end

local function paint_snap_stroke_width(w, dpr)
    dpr = valid_dpr(dpr)
    w = w or 0
    if w == 0 then return 0 end
    local sign = w < 0 and -1 or 1
    local snapped = floor(math.abs(w) * dpr + 0.5) / dpr
    if snapped == 0 then snapped = 1 / dpr end
    return snapped * sign
end

DisplayList.paint_snap = paint_snap
DisplayList.paint_snap_fill_rect = paint_snap_fill_rect
DisplayList.paint_snap_scissor_rect = paint_snap_scissor_rect
DisplayList.paint_snap_text_origin = paint_snap_text_origin
DisplayList.paint_snap_centerline = paint_snap_centerline
DisplayList.paint_snap_stroke_width = paint_snap_stroke_width

------------------------------------------------------------
-- Command type constants
------------------------------------------------------------
local CMD = {
    RECT_FILL      = 1,
    RECT_STROKE    = 2,
    TEXT           = 3,
    IMAGE          = 4,
    LINE           = 5,
    CLIP_PUSH      = 6,
    CLIP_POP       = 7,
    CIRCLE_FILL    = 8,
    TRIANGLE_FILL  = 9,
    IMAGE_RECT     = 10,   -- texture with UV sub-rect
    BLEND_PUSH     = 11,   -- push blend mode (mix-blend-mode)
    BLEND_POP      = 12,   -- pop blend mode
    POLYGON_FILL   = 13,
}

-- Expose constants for external use
DisplayList.CMD = CMD

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

function DisplayList.new()
    local self = setmetatable({}, DisplayList)
    self.commands = {}
    self._len = 0
    self._dpr = 1
    -- Pre-allocate clip pool to avoid per-frame allocations during replay
    local pool = {}
    for i = 1, 64 do
        pool[i] = { 0, 0, 0, 0 }
    end
    self._clip_pool = pool
    return self
end

function DisplayList:set_dpr(dpr)
    self._dpr = valid_dpr(dpr)
end

------------------------------------------------------------
-- Buffer management
------------------------------------------------------------

--- Clear all commands.
function DisplayList:clear()
    -- Fast clear: just reset the length counter.
    -- Old entries remain in the table but won't be accessed.
    self._len = 0
end

------------------------------------------------------------
-- Add commands
------------------------------------------------------------

--- Add a filled rectangle.
---@param x number
---@param y number
---@param w number
---@param h number
---@param r number  red   0-255
---@param g number  green 0-255
---@param b number  blue  0-255
---@param a number  alpha 0-255
---@param rounding number|nil  corner radius (default 0)
function DisplayList:rect_fill(x, y, w, h, r, g, b, a, rounding)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.RECT_FILL; c[2]=x; c[3]=y; c[4]=w; c[5]=h
        c[6]=r; c[7]=g; c[8]=b; c[9]=a; c[10]=rounding or 0
        c[11]=nil
    else
        cmds[n] = { CMD.RECT_FILL, x, y, w, h, r, g, b, a, rounding or 0 }
    end
end

--- Add a stroked (outlined) rectangle.
function DisplayList:rect_stroke(x, y, w, h, r, g, b, a, thickness, rounding)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.RECT_STROKE; c[2]=x; c[3]=y; c[4]=w; c[5]=h
        c[6]=r; c[7]=g; c[8]=b; c[9]=a; c[10]=thickness or 1; c[11]=rounding or 0
        c[12]=nil
    else
        cmds[n] = { CMD.RECT_STROKE, x, y, w, h, r, g, b, a, thickness or 1, rounding or 0 }
    end
end

--- Add a text draw command.
---@param text     string
---@param x        number
---@param y        number
---@param font_size number
---@param r number  red
---@param g number  green
---@param b number  blue
---@param a number  alpha
---@param centered boolean|nil
---@param font_id  number|nil
function DisplayList:text(text, x, y, font_size, r, g, b, a, centered, font_id)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.TEXT; c[2]=text; c[3]=x; c[4]=y; c[5]=font_size
        c[6]=r; c[7]=g; c[8]=b; c[9]=a; c[10]=centered or false; c[11]=font_id or 0
        c[12]=nil
    else
        cmds[n] = { CMD.TEXT, text, x, y, font_size, r, g, b, a, centered or false, font_id or 0 }
    end
end

--- Add a texture/image draw command.
function DisplayList:image(tex_id, x, y, w, h, r, g, b, a, pre_clipped)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.IMAGE; c[2]=tex_id; c[3]=x; c[4]=y; c[5]=w; c[6]=h
        c[7]=r; c[8]=g; c[9]=b; c[10]=a; c[11]=pre_clipped
        c[12]=nil
    else
        cmds[n] = { CMD.IMAGE, tex_id, x, y, w, h, r, g, b, a, pre_clipped }
    end
end

--- Add a texture draw with UV sub-rect (for GPU-based partial image display).
--- uv0_x, uv0_y = top-left UV; uv1_x, uv1_y = bottom-right UV.
function DisplayList:image_rect(tex_id, x, y, w, h, uv0_x, uv0_y, uv1_x, uv1_y, r, g, b, a)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.IMAGE_RECT; c[2]=tex_id; c[3]=x; c[4]=y; c[5]=w; c[6]=h
        c[7]=uv0_x; c[8]=uv0_y; c[9]=uv1_x; c[10]=uv1_y
        c[11]=r; c[12]=g; c[13]=b; c[14]=a
    else
        cmds[n] = { CMD.IMAGE_RECT, tex_id, x, y, w, h, uv0_x, uv0_y, uv1_x, uv1_y, r, g, b, a }
    end
end

--- Add a line draw command.
function DisplayList:line(x1, y1, x2, y2, r, g, b, a, thickness)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.LINE; c[2]=x1; c[3]=y1; c[4]=x2; c[5]=y2
        c[6]=r; c[7]=g; c[8]=b; c[9]=a; c[10]=thickness or 1
        c[11]=nil
    else
        cmds[n] = { CMD.LINE, x1, y1, x2, y2, r, g, b, a, thickness or 1 }
    end
end

--- Push a clip rectangle.  Clips are intersected with the
--- current top-of-stack clip.
function DisplayList:clip_push(x, y, w, h, bg_r, bg_g, bg_b, bg_a)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.CLIP_PUSH; c[2]=x; c[3]=y; c[4]=w; c[5]=h
        c[6]=bg_r; c[7]=bg_g; c[8]=bg_b; c[9]=bg_a
        c[10]=nil
    else
        cmds[n] = { CMD.CLIP_PUSH, x, y, w, h, bg_r, bg_g, bg_b, bg_a }
    end
end

--- Pop the most recent clip rectangle.
function DisplayList:clip_pop()
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.CLIP_POP; c[2]=nil
    else
        cmds[n] = { CMD.CLIP_POP }
    end
end

--- Push a blend mode for subsequent draw commands.
---@param mode string  blend mode name (e.g. "multiply", "screen")
function DisplayList:blend_push(mode)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.BLEND_PUSH; c[2]=mode; c[3]=nil
    else
        cmds[n] = { CMD.BLEND_PUSH, mode }
    end
end

--- Pop the most recent blend mode.
function DisplayList:blend_pop()
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.BLEND_POP; c[2]=nil
    else
        cmds[n] = { CMD.BLEND_POP }
    end
end

--- Add a filled circle command.
function DisplayList:circle_fill(cx, cy, radius, r, g, b, a)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.CIRCLE_FILL; c[2]=cx; c[3]=cy; c[4]=radius
        c[5]=r; c[6]=g; c[7]=b; c[8]=a
        c[9]=nil
    else
        cmds[n] = { CMD.CIRCLE_FILL, cx, cy, radius, r, g, b, a }
    end
end

--- Add a filled triangle command.
function DisplayList:triangle_fill(x1, y1, x2, y2, x3, y3, r, g, b, a)
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.TRIANGLE_FILL; c[2]=x1; c[3]=y1; c[4]=x2; c[5]=y2
        c[6]=x3; c[7]=y3; c[8]=r; c[9]=g; c[10]=b; c[11]=a
        c[12]=nil
    else
        cmds[n] = { CMD.TRIANGLE_FILL, x1, y1, x2, y2, x3, y3, r, g, b, a }
    end
end

--- Add a filled polygon command. Points are {{x,y}, ...}; replay
--- triangulates with ear clipping so concave simple polygons render.
function DisplayList:polygon_fill(points, r, g, b, a)
    if type(points) ~= "table" or #points < 3 then return end
    local copy = {}
    for i = 1, #points do
        copy[i] = { points[i][1], points[i][2] }
    end
    local cmds = self.commands
    local n = self._len + 1; self._len = n
    local c = cmds[n]
    if c then
        c[1]=CMD.POLYGON_FILL; c[2]=copy; c[3]=r; c[4]=g; c[5]=b; c[6]=a; c[7]=nil
    else
        cmds[n] = { CMD.POLYGON_FILL, copy, r, g, b, a }
    end
end

------------------------------------------------------------
-- Replay
------------------------------------------------------------

--- Walk the command buffer and dispatch draw calls to
--- *platform*.  GPU scissor (scissor_push/pop) is the PRIMARY
--- clipping mechanism -" it clips all draw calls at the pixel
--- level.  The software clip stack is maintained solely for
--- fast overlap-culling: draw calls whose bounding box falls
--- entirely outside the current clip rect are skipped before
--- they reach the GPU.
---
--- No `goto` is used -- branching is purely if/elseif/else.
---@param platform table  platform adapter instance
function DisplayList:replay(platform)
    local cmds = self.commands
    local dpr = self._dpr or 1
    local clip_stack = {}
    local clip_sp = 0
    local clip_top = nil  -- nil means "no clip / full screen"
    local clip_pool = self._clip_pool or {}  -- reusable {x,y,w,h} tuples
    local pool_n = #clip_pool
    local math_max, math_min = math.max, math.min
    local platform_integer = type(platform.requires_integer_paint_coordinates) == "function"
        and platform:requires_integer_paint_coordinates() == true

    local function _clip_rect(cx, cy, cw, ch)
        if pool_n > 0 then
            local t = clip_pool[pool_n]; pool_n = pool_n - 1
            t[1]=cx; t[2]=cy; t[3]=cw; t[4]=ch
            return t
        end
        return { cx, cy, cw, ch }
    end

    for i = 1, self._len do
        local cmd = cmds[i]
        local ctype = cmd[1]

        if ctype == CMD.CLIP_PUSH then
            -- Intersect new clip with current top (or use as-is).
            local nx, ny, nw, nh = cmd[2], cmd[3], cmd[4], cmd[5]
            if clip_top then
                local cx, cy, cw, ch = rect_clip(nx, ny, nw, nh,
                    clip_top[1], clip_top[2], clip_top[3], clip_top[4])
                clip_sp = clip_sp + 1
                clip_stack[clip_sp] = clip_top
                if cx then
                    clip_top = _clip_rect(cx, cy, cw, ch)
                else
                    clip_top = _clip_rect(0, 0, 0, 0)
                end
            else
                clip_sp = clip_sp + 1
                clip_stack[clip_sp] = false
                clip_top = _clip_rect(nx, ny, nw, nh)
            end
            -- GPU scissor -" primary pixel-level clipping
            local sx, sy, sw, sh = clip_top[1], clip_top[2], clip_top[3], clip_top[4]
            if not platform_integer then
                sx, sy, sw, sh = paint_snap_scissor_rect(sx, sy, sw, sh, dpr)
            end
            platform:clip_push(sx, sy, sw, sh)

        elseif ctype == CMD.CLIP_POP then
            platform:clip_pop()
            -- Return current clip_top to pool for reuse
            if clip_top then
                pool_n = pool_n + 1
                clip_pool[pool_n] = clip_top
            end
            if clip_sp > 0 then
                local prev = clip_stack[clip_sp]
                clip_stack[clip_sp] = nil
                clip_sp = clip_sp - 1
                if prev == false then
                    clip_top = nil
                else
                    clip_top = prev
                end
            else
                clip_top = nil
            end

        ----------------------------------------------------------------
        -- RECT_FILL: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.RECT_FILL then
            local rx, ry, rw, rh = cmd[2], cmd[3], cmd[4], cmd[5]
            if not clip_top
               or rect_intersects(rx, ry, rw, rh,
                    clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                if not platform_integer then
                    rx, ry, rw, rh = paint_snap_fill_rect(rx, ry, rw, rh, dpr)
                end
                platform:draw_rect_filled(rx, ry, rw, rh,
                    cmd[6], cmd[7], cmd[8], cmd[9], cmd[10])
            end

        ----------------------------------------------------------------
        -- RECT_STROKE: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.RECT_STROKE then
            local rx, ry, rw, rh = cmd[2], cmd[3], cmd[4], cmd[5]
            if not clip_top
               or rect_intersects(rx, ry, rw, rh,
                    clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                local thickness = cmd[10]
                if not platform_integer then
                    local x1 = paint_snap_centerline(rx, dpr)
                    local y1 = paint_snap_centerline(ry, dpr)
                    local x2 = paint_snap_centerline(rx + rw, dpr)
                    local y2 = paint_snap_centerline(ry + rh, dpr)
                    rx, ry, rw, rh = x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1)
                    thickness = paint_snap_stroke_width(thickness, dpr)
                end
                platform:draw_rect(rx, ry, rw, rh,
                    cmd[6], cmd[7], cmd[8], cmd[9], thickness, cmd[11])
            end

        ----------------------------------------------------------------
        -- TEXT: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.TEXT then
            local tx, ty = cmd[3], cmd[4]
            local font_size = cmd[5] or 16
            if not clip_top
               or (ty + font_size > clip_top[2]
                   and ty < clip_top[2] + clip_top[4]) then
                platform:draw_text(cmd[2], tx, ty,
                    cmd[5], cmd[6], cmd[7], cmd[8], cmd[9], cmd[10], cmd[11])
            end

        ----------------------------------------------------------------
        -- IMAGE: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.IMAGE then
            local ix, iy, iw, ih = cmd[3], cmd[4], cmd[5], cmd[6]
            if not clip_top
               or rect_intersects(ix, iy, iw, ih,
                    clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                if not platform_integer then
                    ix, iy, iw, ih = paint_snap_fill_rect(ix, iy, iw, ih, dpr)
                end
                platform:draw_texture(cmd[2], ix, iy, iw, ih,
                    cmd[7], cmd[8], cmd[9], cmd[10])
            end

        ----------------------------------------------------------------
        -- IMAGE_RECT: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.IMAGE_RECT then
            local ix, iy, iw, ih = cmd[3], cmd[4], cmd[5], cmd[6]
            if not clip_top
               or rect_intersects(ix, iy, iw, ih,
                    clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                local can_draw_texture_rect = type(platform.draw_texture_rect) == "function"
                if can_draw_texture_rect and type(platform.has_texture_rect) == "function" then
                    local ok, supported = pcall(platform.has_texture_rect, platform)
                    can_draw_texture_rect = (not ok) or supported == true
                end
                if can_draw_texture_rect then
                    if not platform_integer then
                        ix, iy, iw, ih = paint_snap_fill_rect(ix, iy, iw, ih, dpr)
                    end
                    platform:draw_texture_rect(cmd[2], ix, iy, iw, ih,
                        cmd[7], cmd[8], cmd[9], cmd[10],
                        cmd[11], cmd[12], cmd[13], cmd[14])
                elseif type(platform.draw_texture) == "function"
                   and cmd[7] == 0 and cmd[8] == 0
                   and cmd[9] == 1 and cmd[10] == 1 then
                    if not platform_integer then
                        ix, iy, iw, ih = paint_snap_fill_rect(ix, iy, iw, ih, dpr)
                    end
                    platform:draw_texture(cmd[2], ix, iy, iw, ih,
                        cmd[11], cmd[12], cmd[13], cmd[14])
                end
            end

        ----------------------------------------------------------------
        -- LINE: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.LINE then
            local lx1, ly1, lx2, ly2 = cmd[2], cmd[3], cmd[4], cmd[5]
            if not clip_top then
                local thickness = cmd[10]
                if not platform_integer then
                    lx1, ly1 = paint_snap_text_origin(lx1, ly1, dpr)
                    lx2, ly2 = paint_snap_text_origin(lx2, ly2, dpr)
                    thickness = paint_snap_stroke_width(thickness, dpr)
                end
                platform:draw_line(lx1, ly1, lx2, ly2,
                    cmd[6], cmd[7], cmd[8], cmd[9], thickness)
            else
                -- Overlap test using line bounding box
                local minx = math_min(lx1, lx2)
                local miny = math_min(ly1, ly2)
                local maxx = math_max(lx1, lx2)
                local maxy = math_max(ly1, ly2)
                local pad = math_max(cmd[10] or 1, 1) * 0.5
                if rect_intersects(minx - pad, miny - pad,
                        math_max(maxx - minx, 0) + pad * 2,
                        math_max(maxy - miny, 0) + pad * 2,
                        clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                    local thickness = cmd[10]
                    if not platform_integer then
                        lx1, ly1 = paint_snap_text_origin(lx1, ly1, dpr)
                        lx2, ly2 = paint_snap_text_origin(lx2, ly2, dpr)
                        thickness = paint_snap_stroke_width(thickness, dpr)
                    end
                    platform:draw_line(lx1, ly1, lx2, ly2,
                        cmd[6], cmd[7], cmd[8], cmd[9], thickness)
                end
            end

        ----------------------------------------------------------------
        -- CIRCLE_FILL: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.CIRCLE_FILL then
            local cx, cy, cr = cmd[2], cmd[3], cmd[4]
            if not clip_top
               or rect_intersects(cx - cr, cy - cr, cr * 2, cr * 2,
                    clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                if not platform_integer then
                    cx, cy = paint_snap_text_origin(cx, cy, dpr)
                    cr = math.abs(paint_snap_stroke_width(cr, dpr))
                end
                platform:draw_circle_filled(cx, cy, cr,
                    cmd[5], cmd[6], cmd[7], cmd[8])
            end

        ----------------------------------------------------------------
        -- TRIANGLE_FILL: overlap-cull only; GPU scissor clips pixels
        ----------------------------------------------------------------
        elseif ctype == CMD.TRIANGLE_FILL then
            local tx1, ty1 = cmd[2], cmd[3]
            local tx2, ty2 = cmd[4], cmd[5]
            local tx3, ty3 = cmd[6], cmd[7]
            if not clip_top then
                if not platform_integer then
                    tx1, ty1 = paint_snap_text_origin(tx1, ty1, dpr)
                    tx2, ty2 = paint_snap_text_origin(tx2, ty2, dpr)
                    tx3, ty3 = paint_snap_text_origin(tx3, ty3, dpr)
                end
                platform:draw_triangle_filled(tx1, ty1, tx2, ty2, tx3, ty3,
                    cmd[8], cmd[9], cmd[10], cmd[11])
            else
                local minx = math_min(tx1, tx2, tx3)
                local miny = math_min(ty1, ty2, ty3)
                local maxx = math_max(tx1, tx2, tx3)
                local maxy = math_max(ty1, ty2, ty3)
                if rect_intersects(minx, miny, maxx - minx, maxy - miny,
                        clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                    if not platform_integer then
                        tx1, ty1 = paint_snap_text_origin(tx1, ty1, dpr)
                        tx2, ty2 = paint_snap_text_origin(tx2, ty2, dpr)
                        tx3, ty3 = paint_snap_text_origin(tx3, ty3, dpr)
                    end
                    platform:draw_triangle_filled(tx1, ty1, tx2, ty2, tx3, ty3,
                        cmd[8], cmd[9], cmd[10], cmd[11])
                end
            end
        elseif ctype == CMD.POLYGON_FILL then
            local pts = cmd[2]
            if pts and #pts >= 3 then
                local minx, miny, maxx, maxy = pts[1][1], pts[1][2], pts[1][1], pts[1][2]
                for pi = 2, #pts do
                    local px, py = pts[pi][1], pts[pi][2]
                    if px < minx then minx = px end
                    if py < miny then miny = py end
                    if px > maxx then maxx = px end
                    if py > maxy then maxy = py end
                end
                if not clip_top or rect_intersects(minx, miny, maxx - minx, maxy - miny,
                        clip_top[1], clip_top[2], clip_top[3], clip_top[4]) then
                    local function area()
                        local a = 0
                        local j = #pts
                        for pi = 1, #pts do
                            a = a + (pts[j][1] * pts[pi][2] - pts[pi][1] * pts[j][2])
                            j = pi
                        end
                        return a * 0.5
                    end
                    local ccw = area() > 0
                    local idx = {}
                    for pi = 1, #pts do idx[pi] = pi end
                    local function cross(a, b, c)
                        return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
                    end
                    local function point_in_tri(p, a, b, c)
                        local c1 = cross(a, b, p)
                        local c2 = cross(b, c, p)
                        local c3 = cross(c, a, p)
                        return (c1 >= 0 and c2 >= 0 and c3 >= 0) or (c1 <= 0 and c2 <= 0 and c3 <= 0)
                    end
                    local guard = 0
                    while #idx > 3 and guard < 2048 do
                        guard = guard + 1
                        local clipped = false
                        for ii = 1, #idx do
                            local ip = idx[((ii - 2) % #idx) + 1]
                            local ic = idx[ii]
                            local inx = idx[(ii % #idx) + 1]
                            local a, b, c = pts[ip], pts[ic], pts[inx]
                            local convex = ccw and cross(a, b, c) > 0 or cross(a, b, c) < 0
                            if convex then
                                local contains = false
                                for jj = 1, #idx do
                                    local test = idx[jj]
                                    if test ~= ip and test ~= ic and test ~= inx and point_in_tri(pts[test], a, b, c) then
                                        contains = true
                                        break
                                    end
                                end
                                if not contains then
                                    local ax, ay = a[1], a[2]
                                    local bx, by = b[1], b[2]
                                    local cx, cy = c[1], c[2]
                                    if not platform_integer then
                                        ax, ay = paint_snap_text_origin(ax, ay, dpr)
                                        bx, by = paint_snap_text_origin(bx, by, dpr)
                                        cx, cy = paint_snap_text_origin(cx, cy, dpr)
                                    end
                                    platform:draw_triangle_filled(ax, ay, bx, by, cx, cy,
                                        cmd[3], cmd[4], cmd[5], cmd[6])
                                    table.remove(idx, ii)
                                    clipped = true
                                    break
                                end
                            end
                        end
                        if not clipped then break end
                    end
                    if #idx == 3 then
                        local a, b, c = pts[idx[1]], pts[idx[2]], pts[idx[3]]
                        local ax, ay = a[1], a[2]
                        local bx, by = b[1], b[2]
                        local cx, cy = c[1], c[2]
                        if not platform_integer then
                            ax, ay = paint_snap_text_origin(ax, ay, dpr)
                            bx, by = paint_snap_text_origin(bx, by, dpr)
                            cx, cy = paint_snap_text_origin(cx, cy, dpr)
                        end
                        platform:draw_triangle_filled(ax, ay, bx, by, cx, cy,
                            cmd[3], cmd[4], cmd[5], cmd[6])
                    elseif #idx > 3 then
                        for ii = 2, #idx - 1 do
                            local a, b, c = pts[idx[1]], pts[idx[ii]], pts[idx[ii + 1]]
                            local ax, ay = a[1], a[2]
                            local bx, by = b[1], b[2]
                            local cx, cy = c[1], c[2]
                            if not platform_integer then
                                ax, ay = paint_snap_text_origin(ax, ay, dpr)
                                bx, by = paint_snap_text_origin(bx, by, dpr)
                                cx, cy = paint_snap_text_origin(cx, cy, dpr)
                            end
                            platform:draw_triangle_filled(ax, ay, bx, by, cx, cy,
                                cmd[3], cmd[4], cmd[5], cmd[6])
                        end
                    end
                end
            end
        ----------------------------------------------------------------
        -- BLEND_PUSH: forward blend mode to platform
        ----------------------------------------------------------------
        elseif ctype == CMD.BLEND_PUSH then
            if platform.blend_push then platform:blend_push(cmd[2]) end

        ----------------------------------------------------------------
        -- BLEND_POP: restore previous blend mode
        ----------------------------------------------------------------
        elseif ctype == CMD.BLEND_POP then
            if platform.blend_pop then platform:blend_pop() end
        end
        -- Unknown command types are silently ignored.
    end

    -- Save clip pool for reuse next frame
    self._clip_pool = clip_pool
end

return DisplayList



