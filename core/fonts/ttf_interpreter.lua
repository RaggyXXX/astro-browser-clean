------------------------------------------------------------
-- ext_core_astro_ui_lib / core / fonts / ttf_interpreter.lua
-- TrueType bytecode interpreter skeleton.
--
-- Phase 7a intentionally does not execute hinting in production paths.
-- This module defines VM state, opcode dispatch, telemetry, and guarded
-- instruction iteration so later phases can fill handlers incrementally.
------------------------------------------------------------

local TtfInterpreter = {}

local bit = require("core/util/bit")

local str_byte = string.byte
local math_floor = math.floor
local band = bit.band

local DEFAULT_MAX_OPS = 100000
local DEFAULT_MAX_CALL_DEPTH = 32
local DEFAULT_MAX_PC_VISITS = 512
local DEFAULT_MAX_STACK = 1024
local F26DOT6_ONE = 64
local F2DOT14_ONE = 16384

------------------------------------------------------------
-- Telemetry and limits
------------------------------------------------------------

local function new_telemetry()
    return {
        unsupported = {},
        skipped = false,
        fail_reason = nil,
        ops = 0,
        calls = 0,
        max_depth = 0,
        call_depth_max = 0,
        skip_depth_max = 0,
        last_opcode = nil,
        opcode_counts = {},
    }
end

local function record_unsupported(state, opcode)
    local key = string.format("0x%02X", opcode or 0)
    state.telemetry.unsupported[key] = (state.telemetry.unsupported[key] or 0) + 1
    state.telemetry.last_opcode = opcode
    state.telemetry.fail_reason = "not implemented: " .. key
end

local function fail(state, reason)
    if state and state.telemetry then
        state.telemetry.fail_reason = reason
    end
    return false, reason
end

------------------------------------------------------------
-- CVT and zones
------------------------------------------------------------

local function scale_to_26_6(value, scale)
    if value >= 0 then
        return math_floor(value * scale * 64 + 0.5)
    end
    return -math_floor((-value) * scale * 64 + 0.5)
end

local function scaled_cvt(font, scale)
    local source = font and font.ttf_hinting and font.ttf_hinting.cvt or {}
    local cvt = {}
    for k, v in pairs(source) do
        if type(k) == "number" and type(v) == "number" then
            cvt[k] = scale_to_26_6(v, scale)
        end
    end
    return cvt
end

local function new_twilight_zone(count)
    local zone = { points = {}, max_points = count or 0, contours = {} }
    for i = 0, (count or 0) - 1 do
        zone.points[i] = {
            x = 0,
            y = 0,
            ox = 0,
            oy = 0,
            touched_x = false,
            touched_y = false,
        }
    end
    return zone
end

local function new_glyph_zone(points, scale)
    local zone = { points = {}, contours = {} }
    local contour_map = {}
    if points then
        for k, pt in pairs(points) do
            if type(k) == "number" and type(pt) == "table" then
                local x = scale_to_26_6(pt.x or 0, scale)
                local y = scale_to_26_6(pt.y or 0, scale)
                zone.points[k] = {
                    x = x,
                    y = y,
                    ox = x,
                    oy = y,
                    on_curve = pt.on_curve,
                    contour_index = pt.contour_index,
                    touched_x = pt.touched_x == true,
                    touched_y = pt.touched_y == true,
                }
                local contour_index = pt.contour_index or 0
                if not contour_map[contour_index] then
                    contour_map[contour_index] = {}
                    zone.contours[#zone.contours + 1] = contour_map[contour_index]
                end
                local contour = contour_map[contour_index]
                contour[#contour + 1] = k
            end
        end
    end
    for _, contour in ipairs(zone.contours) do
        table.sort(contour)
    end
    if #zone.contours == 0 then
        local contour = {}
        for k in pairs(zone.points) do
            if type(k) == "number" then contour[#contour + 1] = k end
        end
        table.sort(contour)
        if #contour > 0 then zone.contours[1] = contour end
    end
    return zone
end

local function maxp_limits(font)
    local maxp = font and font.ttf_hinting and font.ttf_hinting.maxp or font and font.maxp or {}
    local max_stack = maxp.maxStackElements
    if type(max_stack) ~= "number" or max_stack <= 0 then
        max_stack = DEFAULT_MAX_STACK
    end
    return {
        max_ops = DEFAULT_MAX_OPS,
        max_call_depth = DEFAULT_MAX_CALL_DEPTH,
        max_pc_visits = DEFAULT_MAX_PC_VISITS,
        max_stack = max_stack,
    }
end

------------------------------------------------------------
-- VM state
------------------------------------------------------------

function TtfInterpreter.new_state(font, ppem, points, norm_coords)
    local units_per_em = font and font.head and font.head.unitsPerEm or 1000
    local scale = (ppem or units_per_em) / units_per_em
    local hint_maxp = font and font.ttf_hinting and font.ttf_hinting.maxp or {}

    local graphics_state = {
        rp0 = 0,
        rp1 = 0,
        rp2 = 0,
        zp0 = 1,
        zp1 = 1,
        zp2 = 1,
        loop = 1,
        freedom = { x = 1, y = 0 },
        projection = { x = 1, y = 0 },
        dual_projection = { x = 1, y = 0 },
        round_state = {
            mode = "grid",
            period = F26DOT6_ONE,
            phase = 0,
            threshold = 32,
        },
        minimum_distance = true,
        control_value_cut_in = 17 / 16 * F26DOT6_ONE,
        single_width_cut_in = 0,
        single_width_value = 0,
        delta_base = 9,
        delta_shift = 3,
        auto_flip = true,
        instruction_control = 0,
        scan_control = 0,
        scan_type = 0,
        angle_weight = 0,
    }

    local state = {
        font = font,
        ppem = ppem,
        scale = scale,
        norm_coords = norm_coords,

        stack = {},
        stack_top = 0,
        storage = {},
        cvt = scaled_cvt(font, scale),
        functions = {},
        instruction_defs = {},
        call_stack = {},
        if_skip_depth = 0,
        pc_visits = {},
        program_ids = {},
        next_program_id = 0,

        zones = {
            [0] = new_twilight_zone(hint_maxp.maxTwilightPoints or 0),
            [1] = new_glyph_zone(points, scale),
        },

        graphics_state = graphics_state,
        gs = graphics_state,

        telemetry = new_telemetry(),
        limits = maxp_limits(font),
        call_depth = 0,
    }

    return state
end

------------------------------------------------------------
-- Stack helpers
------------------------------------------------------------

function TtfInterpreter.push(state, value)
    if state.stack_top >= state.limits.max_stack then
        error("TrueType stack overflow")
    end
    state.stack_top = state.stack_top + 1
    state.stack[state.stack_top] = value
end

function TtfInterpreter.pop(state)
    if state.stack_top <= 0 then
        error("TrueType stack underflow")
    end
    local value = state.stack[state.stack_top]
    state.stack[state.stack_top] = nil
    state.stack_top = state.stack_top - 1
    return value
end

function TtfInterpreter.peek(state, depth)
    depth = depth or 0
    local index = state.stack_top - depth
    if index <= 0 then
        error("TrueType stack underflow")
    end
    return state.stack[index]
end

function TtfInterpreter.require_stack(state, count, opcode_name)
    if state.stack_top < count then
        error((opcode_name or "opcode") .. " stack underflow")
    end
end

local function read_byte(program, pc, opcode_name)
    local value = str_byte(program, pc)
    if not value then
        error((opcode_name or "opcode") .. " truncated instruction stream")
    end
    return value, pc + 1
end

local function read_word(program, pc, opcode_name)
    local hi = str_byte(program, pc)
    local lo = str_byte(program, pc + 1)
    if not hi or not lo then
        error((opcode_name or "opcode") .. " truncated instruction stream")
    end
    local value = hi * 256 + lo
    if value >= 0x8000 then
        value = value - 0x10000
    end
    return value, pc + 2
end

local function truthy(value)
    return value ~= 0
end

local function bool_value(value)
    if value then
        return 1
    end
    return 0
end

local function round_nearest(value)
    if value >= 0 then
        return math_floor(value + 0.5)
    end
    return -math_floor(-value + 0.5)
end

local function f2dot14_to_unit(value)
    return value / F2DOT14_ONE
end

local function unit_to_f2dot14(value)
    local n = round_nearest(value * F2DOT14_ONE)
    if n > 0x4000 then return 0x4000 end
    if n < -0x4000 then return -0x4000 end
    return n
end

local function copy_vector(v)
    return { x = v.x, y = v.y }
end

local function copy_table_shallow(source)
    local out = {}
    if source then
        for k, v in pairs(source) do
            out[k] = v
        end
    end
    return out
end

local function copy_graphics_state(source)
    local out = {}
    for k, v in pairs(source or {}) do
        if type(v) == "table" then
            out[k] = copy_table_shallow(v)
        else
            out[k] = v
        end
    end
    if source and source.round_state then
        out.round_state = copy_table_shallow(source.round_state)
    end
    if source and source.freedom then out.freedom = copy_vector(source.freedom) end
    if source and source.projection then out.projection = copy_vector(source.projection) end
    if source and source.dual_projection then out.dual_projection = copy_vector(source.dual_projection) end
    return out
end

local function normalize_vector(x, y)
    local len = math.sqrt(x * x + y * y)
    if len == 0 then
        error("zero-length vector")
    end
    return { x = x / len, y = y / len }
end

local function axis_vector(opcode)
    if opcode % 2 == 0 then
        return { x = 0, y = 1 }
    end
    return { x = 1, y = 0 }
end

local function get_zone(state, zone_id, opcode_name)
    local zone = state.zones[zone_id]
    if not zone then
        error((opcode_name or "opcode") .. " invalid zone " .. tostring(zone_id))
    end
    return zone
end

local function get_point(state, zone_id, point_index, opcode_name)
    local zone = get_zone(state, zone_id, opcode_name)
    local point = zone.points[point_index]
    if not point and zone_id == 0 then
        if point_index < 0 or point_index >= (zone.max_points or 0) then
            error((opcode_name or "opcode") .. " invalid point " .. tostring(point_index))
        end
        point = {
            x = 0,
            y = 0,
            ox = 0,
            oy = 0,
            touched_x = false,
            touched_y = false,
        }
        zone.points[point_index] = point
    end
    if not point then
        error((opcode_name or "opcode") .. " invalid point " .. tostring(point_index))
    end
    return point
end

local function each_zone_point(zone, fn)
    for k, point in pairs(zone.points) do
        if type(k) == "number" then
            fn(k, point)
        end
    end
end

local function line_vector(state, opcode, opcode_name)
    TtfInterpreter.require_stack(state, 2, opcode_name)
    local p2_index = TtfInterpreter.pop(state)
    local p1_index = TtfInterpreter.pop(state)
    local p1 = get_point(state, state.gs.zp2, p1_index, opcode_name)
    local p2 = get_point(state, state.gs.zp1, p2_index, opcode_name)
    local x = p2.x - p1.x
    local y = p2.y - p1.y
    if opcode % 2 == 1 then
        x = -x
        y = -y
    end
    return normalize_vector(x, y)
end

local function projected_coord(point, vector, original)
    local x = original and point.ox or point.x
    local y = original and point.oy or point.y
    return x * vector.x + y * vector.y
end

local function mark_touched(point, freedom)
    if math.abs(freedom.x) >= math.abs(freedom.y) then
        point.touched_x = true
    end
    if math.abs(freedom.y) >= math.abs(freedom.x) then
        point.touched_y = true
    end
end

local function move_point_by(point, freedom, distance)
    point.x = point.x + distance * freedom.x
    point.y = point.y + distance * freedom.y
    mark_touched(point, freedom)
end

local function move_point_to_coord(point, projection, freedom, target)
    local current = projected_coord(point, projection, false)
    local delta = target - current
    local dot = projection.x * freedom.x + projection.y * freedom.y
    if dot == 0 then
        error("movement vectors are perpendicular")
    end
    move_point_by(point, freedom, delta / dot)
end

local function set_round_mode(gs, mode, period, phase, threshold)
    gs.round_state = {
        mode = mode,
        period = period,
        phase = phase,
        threshold = threshold,
    }
end

local function decode_super_round(param, base_period)
    local period_selector = math_floor(param / 64) % 4
    local phase_selector = math_floor(param / 16) % 4
    local threshold_selector = param % 16
    local period = base_period

    if period_selector == 0 then
        period = base_period / 2
    elseif period_selector == 1 then
        period = base_period
    elseif period_selector == 2 then
        period = base_period * 2
    end

    local phase = period * phase_selector / 4
    local threshold
    if threshold_selector == 0 then
        threshold = period - 1
    else
        threshold = period * (threshold_selector - 4) / 8
    end

    return {
        mode = "super",
        period = period,
        phase = phase,
        threshold = threshold,
        raw = param,
    }
end

local function round_by_state(gs, value)
    local rs = gs.round_state
    if not rs or rs.mode == "off" then
        return value
    end
    if rs.mode == "down" then
        return math_floor(value / F26DOT6_ONE) * F26DOT6_ONE
    end
    if rs.mode == "up" then
        return -math_floor(-value / F26DOT6_ONE) * F26DOT6_ONE
    end

    local period = rs.period or F26DOT6_ONE
    local phase = rs.phase or 0
    local threshold = rs.threshold
    if threshold == nil then threshold = period / 2 end
    local n = value - phase + threshold
    return math_floor(n / period) * period + phase
end

local function point_delta_from_original(point, projection)
    return projected_coord(point, projection, false) - projected_coord(point, projection, true)
end

local function apply_minimum_distance(gs, distance)
    if not gs.minimum_distance then return distance end
    if distance >= 0 and distance < F26DOT6_ONE then
        return F26DOT6_ONE
    end
    if distance < 0 and distance > -F26DOT6_ONE then
        return -F26DOT6_ONE
    end
    return distance
end

local function decode_move_flags(opcode)
    local bits = opcode % 32
    return {
        set_rp0 = math_floor(bits / 16) % 2 == 1,
        keep_min_dist = math_floor(bits / 8) % 2 == 1,
        round = math_floor(bits / 4) % 2 == 1,
        distance_type = bits % 4,
    }
end

local function delta_amount(gs, arg, family)
    local ppem_base = (gs.delta_base or 9) + family * 16
    local target_ppem = ppem_base + (arg % 16)
    local steps = math_floor(arg / 16) - 8
    if steps >= 0 then steps = steps + 1 end
    local quantum = F26DOT6_ONE / (2 ^ (gs.delta_shift or 3))
    return target_ppem, steps * quantum
end

local function axis_name(vector)
    if math.abs(vector.x) >= math.abs(vector.y) then return "x" end
    return "y"
end

local function interpolate_point_axis(point, before, after, axis)
    local coord = axis
    local original = axis == "x" and "ox" or "oy"
    local o = point[original]
    local o1 = before[original]
    local o2 = after[original]
    local d1 = before[coord] - before[original]
    local d2 = after[coord] - after[original]
    local delta
    if o1 == o2 then
        if o <= o1 then delta = d1 else delta = d2 end
    else
        delta = d1 + (d2 - d1) * (o - o1) / (o2 - o1)
    end
    point[coord] = point[original] + delta
end

------------------------------------------------------------
-- Opcode dispatch
------------------------------------------------------------

local handlers = {}

local function make_stub(opcode)
    return function(state)
        record_unsupported(state, opcode)
        error(state.telemetry.fail_reason)
    end
end

for opcode = 0, 255 do
    handlers[opcode] = make_stub(opcode)
end

local function push_bytes(state, program, pc, count, opcode_name)
    for _ = 1, count do
        local value
        value, pc = read_byte(program, pc, opcode_name)
        TtfInterpreter.push(state, value)
    end
    return pc
end

local function push_words(state, program, pc, count, opcode_name)
    for _ = 1, count do
        local value
        value, pc = read_word(program, pc, opcode_name)
        TtfInterpreter.push(state, value)
    end
    return pc
end

local function instruction_end_pc(program, pc, opcode)
    if opcode == 0x40 or opcode == 0x41 then
        local count = str_byte(program, pc)
        if not count then error("PUSH truncated instruction stream") end
        if opcode == 0x40 then
            return pc + 1 + count
        end
        return pc + 1 + count * 2
    end
    if opcode >= 0xB0 and opcode <= 0xB7 then
        return pc + (opcode - 0xB0 + 1)
    end
    if opcode >= 0xB8 and opcode <= 0xBF then
        return pc + (opcode - 0xB8 + 1) * 2
    end
    return pc
end

local function track_skip_depth(state, depth)
    if depth > state.if_skip_depth then
        state.if_skip_depth = depth
    end
    if depth > state.telemetry.skip_depth_max then
        state.telemetry.skip_depth_max = depth
    end
end

local function scan_to_else_or_eif(state, program, pc)
    local depth = 0
    local scan = pc
    while scan <= #program do
        local opcode = str_byte(program, scan)
        if not opcode then break end
        local next_pc = instruction_end_pc(program, scan + 1, opcode)
        if opcode == 0x58 then
            depth = depth + 1
            track_skip_depth(state, depth)
        elseif opcode == 0x59 then
            if depth == 0 then
                return next_pc
            end
            depth = depth - 1
        elseif opcode == 0x1B and depth == 0 then
            return next_pc
        end
        scan = next_pc
    end
    error("IF missing matching ELSE/EIF")
end

local function scan_to_eif(state, program, pc)
    local depth = 0
    local scan = pc
    while scan <= #program do
        local opcode = str_byte(program, scan)
        if not opcode then break end
        local next_pc = instruction_end_pc(program, scan + 1, opcode)
        if opcode == 0x58 then
            depth = depth + 1
            track_skip_depth(state, depth)
        elseif opcode == 0x59 then
            if depth == 0 then
                return next_pc
            end
            depth = depth - 1
        end
        scan = next_pc
    end
    error("ELSE missing matching EIF")
end

local function scan_to_endf(program, pc, opcode_name)
    local depth = 0
    local scan = pc
    while scan <= #program do
        local opcode = str_byte(program, scan)
        if not opcode then break end
        local next_pc = instruction_end_pc(program, scan + 1, opcode)
        if opcode == 0x2C or opcode == 0x89 then
            depth = depth + 1
        elseif opcode == 0x2D then
            if depth == 0 then
                return scan, next_pc
            end
            depth = depth - 1
        end
        scan = next_pc
    end
    error((opcode_name or "definition") .. " missing ENDF")
end

local function checked_jump(program, target, opcode_name)
    if target < 1 or target > #program + 1 then
        error((opcode_name or "jump") .. " out-of-bounds jump")
    end
    return target
end

local function call_action(state, program, pc, func_id, count, opcode_name)
    local fn = state.functions[func_id]
    if not fn then
        error((opcode_name or "CALL") .. " undefined function " .. tostring(func_id))
    end
    if count <= 0 then
        return nil
    end
    if state.call_depth >= state.limits.max_call_depth then
        error("call depth exceeded")
    end
    return {
        type = "call",
        program = fn.program,
        pc = fn.start_pc,
        return_program = program,
        return_pc = pc,
        func_id = func_id,
        loop_remaining = count - 1,
    }
end

local function idef_action(state, program, pc, opcode)
    local idef = state.instruction_defs and state.instruction_defs[opcode]
    if not idef then return nil end
    if state.call_depth >= state.limits.max_call_depth then
        error("call depth exceeded")
    end
    return {
        type = "call",
        program = idef.program,
        pc = idef.start_pc,
        return_program = program,
        return_pc = pc,
        func_id = "IDEF:" .. tostring(opcode),
        loop_remaining = 0,
    }
end

handlers[0x40] = function(state, program, pc)
    local count
    count, pc = read_byte(program, pc, "NPUSHB")
    return push_bytes(state, program, pc, count, "NPUSHB")
end

handlers[0x41] = function(state, program, pc)
    local count
    count, pc = read_byte(program, pc, "NPUSHW")
    return push_words(state, program, pc, count, "NPUSHW")
end

for opcode = 0xB0, 0xB7 do
    local count = opcode - 0xB0 + 1
    handlers[opcode] = function(state, program, pc)
        return push_bytes(state, program, pc, count, "PUSHB")
    end
end

for opcode = 0xB8, 0xBF do
    local count = opcode - 0xB8 + 1
    handlers[opcode] = function(state, program, pc)
        return push_words(state, program, pc, count, "PUSHW")
    end
end

handlers[0x20] = function(state)
    TtfInterpreter.push(state, TtfInterpreter.peek(state, 0))
end

handlers[0x21] = function(state)
    TtfInterpreter.pop(state)
end

handlers[0x22] = function(state)
    for i = 1, state.stack_top do
        state.stack[i] = nil
    end
    state.stack_top = 0
end

handlers[0x23] = function(state)
    TtfInterpreter.require_stack(state, 2, "SWAP")
    local top = state.stack_top
    state.stack[top], state.stack[top - 1] = state.stack[top - 1], state.stack[top]
end

handlers[0x24] = function(state)
    TtfInterpreter.push(state, state.stack_top)
end

handlers[0x25] = function(state)
    local depth = TtfInterpreter.pop(state)
    if depth < 1 or depth > state.stack_top then
        error("CINDEX stack underflow")
    end
    TtfInterpreter.push(state, state.stack[state.stack_top - depth + 1])
end

handlers[0x26] = function(state)
    local depth = TtfInterpreter.pop(state)
    if depth < 1 or depth > state.stack_top then
        error("MINDEX stack underflow")
    end
    local index = state.stack_top - depth + 1
    local value = state.stack[index]
    for i = index, state.stack_top - 1 do
        state.stack[i] = state.stack[i + 1]
    end
    state.stack[state.stack_top] = value
end

local function binary_handler(name, fn)
    return function(state)
        TtfInterpreter.require_stack(state, 2, name)
        local b = TtfInterpreter.pop(state)
        local a = TtfInterpreter.pop(state)
        TtfInterpreter.push(state, fn(a, b))
    end
end

local function unary_handler(name, fn)
    return function(state)
        TtfInterpreter.require_stack(state, 1, name)
        TtfInterpreter.push(state, fn(TtfInterpreter.pop(state)))
    end
end

handlers[0x60] = binary_handler("ADD", function(a, b) return a + b end)
handlers[0x61] = binary_handler("SUB", function(a, b) return a - b end)
handlers[0x62] = binary_handler("DIV", function(a, b)
    if b == 0 then
        error("DIV by zero")
    end
    local negative = (a < 0) ~= (b < 0)
    local numerator = math.abs(a) * F26DOT6_ONE
    local denominator = math.abs(b)
    local result = math_floor((numerator + denominator / 2) / denominator)
    if negative then result = -result end
    return result
end)
handlers[0x63] = binary_handler("MUL", function(a, b)
    local product = a * b
    local negative = product < 0
    local result = math_floor((math.abs(product) + F26DOT6_ONE / 2) / F26DOT6_ONE)
    if negative then result = -result end
    return result
end)
handlers[0x64] = unary_handler("ABS", function(a)
    if a < 0 then
        return -a
    end
    return a
end)
handlers[0x65] = unary_handler("NEG", function(a) return -a end)
handlers[0x66] = unary_handler("FLOOR", function(a) return math_floor(a / F26DOT6_ONE) * F26DOT6_ONE end)
handlers[0x67] = unary_handler("CEILING", function(a) return -math_floor(-a / F26DOT6_ONE) * F26DOT6_ONE end)
handlers[0x8B] = binary_handler("MAX", function(a, b)
    if a > b then
        return a
    end
    return b
end)
handlers[0x8C] = binary_handler("MIN", function(a, b)
    if a < b then
        return a
    end
    return b
end)

handlers[0x50] = binary_handler("LT", function(a, b) return bool_value(a < b) end)
handlers[0x51] = binary_handler("LTEQ", function(a, b) return bool_value(a <= b) end)
handlers[0x52] = binary_handler("GT", function(a, b) return bool_value(a > b) end)
handlers[0x53] = binary_handler("GTEQ", function(a, b) return bool_value(a >= b) end)
handlers[0x54] = binary_handler("EQ", function(a, b) return bool_value(a == b) end)
handlers[0x55] = binary_handler("NEQ", function(a, b) return bool_value(a ~= b) end)

handlers[0x58] = function(state, program, pc)
    local condition = TtfInterpreter.pop(state)
    if truthy(condition) then
        return nil
    end
    return scan_to_else_or_eif(state, program, pc)
end

handlers[0x59] = function()
end

handlers[0x5A] = binary_handler("AND", function(a, b) return bool_value(truthy(a) and truthy(b)) end)
handlers[0x5B] = binary_handler("OR", function(a, b) return bool_value(truthy(a) or truthy(b)) end)
handlers[0x5C] = unary_handler("NOT", function(a) return bool_value(not truthy(a)) end)
handlers[0x56] = unary_handler("ODD", function(a) return bool_value(math_floor(a / F26DOT6_ONE) % 2 ~= 0) end)
handlers[0x57] = unary_handler("EVEN", function(a) return bool_value(math_floor(a / F26DOT6_ONE) % 2 == 0) end)

handlers[0x00] = function(state)
    local v = axis_vector(0x00)
    state.gs.projection = copy_vector(v)
    state.gs.freedom = copy_vector(v)
end

handlers[0x01] = function(state)
    local v = axis_vector(0x01)
    state.gs.projection = copy_vector(v)
    state.gs.freedom = copy_vector(v)
end

handlers[0x02] = function(state)
    state.gs.projection = axis_vector(0x02)
end

handlers[0x03] = function(state)
    state.gs.projection = axis_vector(0x03)
end

handlers[0x04] = function(state)
    state.gs.freedom = axis_vector(0x04)
end

handlers[0x05] = function(state)
    state.gs.freedom = axis_vector(0x05)
end

handlers[0x06] = function(state)
    state.gs.projection = line_vector(state, 0x06, "SPVTL")
end

handlers[0x07] = function(state)
    state.gs.projection = line_vector(state, 0x07, "SPVTL")
end

handlers[0x08] = function(state)
    state.gs.freedom = line_vector(state, 0x08, "SFVTL")
end

handlers[0x09] = function(state)
    state.gs.freedom = line_vector(state, 0x09, "SFVTL")
end

handlers[0x0A] = function(state)
    TtfInterpreter.require_stack(state, 2, "SPVFS")
    local y = TtfInterpreter.pop(state)
    local x = TtfInterpreter.pop(state)
    state.gs.projection = normalize_vector(f2dot14_to_unit(x), f2dot14_to_unit(y))
end

handlers[0x0B] = function(state)
    TtfInterpreter.require_stack(state, 2, "SFVFS")
    local y = TtfInterpreter.pop(state)
    local x = TtfInterpreter.pop(state)
    state.gs.freedom = normalize_vector(f2dot14_to_unit(x), f2dot14_to_unit(y))
end

handlers[0x0C] = function(state)
    TtfInterpreter.push(state, unit_to_f2dot14(state.gs.projection.x))
    TtfInterpreter.push(state, unit_to_f2dot14(state.gs.projection.y))
end

handlers[0x0D] = function(state)
    TtfInterpreter.push(state, unit_to_f2dot14(state.gs.freedom.x))
    TtfInterpreter.push(state, unit_to_f2dot14(state.gs.freedom.y))
end

handlers[0x0E] = function(state)
    state.gs.freedom = copy_vector(state.gs.projection)
end

handlers[0x0F] = function(state)
    TtfInterpreter.require_stack(state, 5, "ISECT")
    local point_index = TtfInterpreter.pop(state)
    local b1_index = TtfInterpreter.pop(state)
    local b0_index = TtfInterpreter.pop(state)
    local a1_index = TtfInterpreter.pop(state)
    local a0_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp2, point_index, "ISECT")
    local a0 = get_point(state, state.gs.zp0, a0_index, "ISECT")
    local a1 = get_point(state, state.gs.zp0, a1_index, "ISECT")
    local b0 = get_point(state, state.gs.zp1, b0_index, "ISECT")
    local b1 = get_point(state, state.gs.zp1, b1_index, "ISECT")
    local ax = a1.x - a0.x
    local ay = a1.y - a0.y
    local bx = b1.x - b0.x
    local by = b1.y - b0.y
    local denom = ax * by - ay * bx
    if denom == 0 then
        point.x = (a0.x + a1.x + b0.x + b1.x) / 4
        point.y = (a0.y + a1.y + b0.y + b1.y) / 4
    else
        local t = ((b0.x - a0.x) * by - (b0.y - a0.y) * bx) / denom
        point.x = a0.x + t * ax
        point.y = a0.y + t * ay
    end
    point.touched_x = true
    point.touched_y = true
end

local function set_zone_pointer(state, field, opcode_name)
    local zone_id = TtfInterpreter.pop(state)
    get_zone(state, zone_id, opcode_name)
    state.gs[field] = zone_id
end

handlers[0x13] = function(state) set_zone_pointer(state, "zp0", "SZP0") end
handlers[0x14] = function(state) set_zone_pointer(state, "zp1", "SZP1") end
handlers[0x15] = function(state) set_zone_pointer(state, "zp2", "SZP2") end
handlers[0x16] = function(state)
    local zone_id = TtfInterpreter.pop(state)
    get_zone(state, zone_id, "SZPS")
    state.gs.zp0 = zone_id
    state.gs.zp1 = zone_id
    state.gs.zp2 = zone_id
end

handlers[0x17] = function(state)
    local value = TtfInterpreter.pop(state)
    if value < 1 then value = 1 end
    state.gs.loop = value
end

handlers[0x18] = function(state) set_round_mode(state.gs, "grid", F26DOT6_ONE, 0, 32) end
handlers[0x19] = function(state) set_round_mode(state.gs, "half_grid", F26DOT6_ONE, 32, 32) end
handlers[0x1A] = function(state)
    state.gs.minimum_distance = truthy(TtfInterpreter.pop(state))
end

handlers[0x1B] = function(state, program, pc)
    return scan_to_eif(state, program, pc)
end

handlers[0x1C] = function(state, program, pc)
    local offset = TtfInterpreter.pop(state)
    return checked_jump(program, pc + offset, "JMPR")
end

handlers[0x1D] = function(state)
    state.gs.control_value_cut_in = TtfInterpreter.pop(state)
end

handlers[0x1E] = function(state)
    state.gs.single_width_cut_in = TtfInterpreter.pop(state)
end

handlers[0x1F] = function(state)
    state.gs.single_width_value = TtfInterpreter.pop(state)
end

handlers[0x27] = function(state)
    TtfInterpreter.require_stack(state, 2, "ALIGNPTS")
    local p2_index = TtfInterpreter.pop(state)
    local p1_index = TtfInterpreter.pop(state)
    local p1 = get_point(state, state.gs.zp1, p1_index, "ALIGNPTS")
    local p2 = get_point(state, state.gs.zp0, p2_index, "ALIGNPTS")
    local midpoint = (projected_coord(p1, state.gs.projection, false) +
        projected_coord(p2, state.gs.projection, false)) / 2
    move_point_to_coord(p1, state.gs.projection, state.gs.freedom, midpoint)
    move_point_to_coord(p2, state.gs.projection, state.gs.freedom, midpoint)
end

handlers[0x29] = function(state)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp0, point_index, "UTP")
    if axis_name(state.gs.freedom) == "x" then
        point.touched_x = false
    else
        point.touched_y = false
    end
end

handlers[0x2A] = function(state, program, pc)
    TtfInterpreter.require_stack(state, 2, "LOOPCALL")
    local func_id = TtfInterpreter.pop(state)
    local count = TtfInterpreter.pop(state)
    return call_action(state, program, pc, func_id, count, "LOOPCALL")
end

handlers[0x2B] = function(state, program, pc)
    local func_id = TtfInterpreter.pop(state)
    return call_action(state, program, pc, func_id, 1, "CALL")
end

handlers[0x2C] = function(state, program, pc)
    local func_id = TtfInterpreter.pop(state)
    local end_pc, after_endf = scan_to_endf(program, pc, "FDEF")
    state.functions[func_id] = {
        start_pc = pc,
        end_pc = end_pc - 1,
        program = program,
    }
    return after_endf
end

handlers[0x2D] = function()
    return { type = "return" }
end

handlers[0x2E] = function(state)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp0, point_index, "MDAP")
    mark_touched(point, state.gs.freedom)
    state.gs.rp0 = point_index
    state.gs.rp1 = point_index
end

handlers[0x2F] = function(state)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp0, point_index, "MDAP")
    local target = round_by_state(state.gs, projected_coord(point, state.gs.projection, false))
    move_point_to_coord(point, state.gs.projection, state.gs.freedom, target)
    state.gs.rp0 = point_index
    state.gs.rp1 = point_index
end

local function interpolate_untouched_axis(state, axis)
    local zone = get_zone(state, 1, "IUP")
    for _, contour in ipairs(zone.contours) do
        local touched = {}
        for i = 1, #contour do
            local point = zone.points[contour[i]]
            if point and point["touched_" .. axis] then
                touched[#touched + 1] = i
            end
        end
        if #touched == 1 then
            local ref = zone.points[contour[touched[1]]]
            local delta = ref[axis] - ref[axis == "x" and "ox" or "oy"]
            for i = 1, #contour do
                local point = zone.points[contour[i]]
                if point and not point["touched_" .. axis] then
                    point[axis] = point[axis == "x" and "ox" or "oy"] + delta
                end
            end
        elseif #touched > 1 then
            for t = 1, #touched do
                local start_i = touched[t]
                local end_i = touched[t + 1] or touched[1]
                local before = zone.points[contour[start_i]]
                local after = zone.points[contour[end_i]]
                local i = start_i % #contour + 1
                while i ~= end_i do
                    local point = zone.points[contour[i]]
                    if point and not point["touched_" .. axis] then
                        interpolate_point_axis(point, before, after, axis)
                    end
                    i = i % #contour + 1
                end
            end
        end
    end
end

handlers[0x30] = function(state) interpolate_untouched_axis(state, "y") end
handlers[0x31] = function(state) interpolate_untouched_axis(state, "x") end

local function shift_by_reference(state, ref_index, opcode_name)
    local ref = get_point(state, state.gs.zp0, ref_index, opcode_name)
    local distance = point_delta_from_original(ref, state.gs.projection)
    for _ = 1, state.gs.loop do
        local point_index = TtfInterpreter.pop(state)
        local point = get_point(state, state.gs.zp2, point_index, opcode_name)
        move_point_by(point, state.gs.freedom, distance)
    end
    state.gs.loop = 1
end

handlers[0x32] = function(state) shift_by_reference(state, state.gs.rp2, "SHP") end
handlers[0x33] = function(state) shift_by_reference(state, state.gs.rp1, "SHP") end

local function shift_contour_by_reference(state, ref_index, opcode_name)
    local contour_index = TtfInterpreter.pop(state)
    local ref = get_point(state, state.gs.zp0, ref_index, opcode_name)
    local distance = point_delta_from_original(ref, state.gs.projection)
    local zone = get_zone(state, state.gs.zp2, opcode_name)
    each_zone_point(zone, function(_, point)
        if (point.contour_index or 0) == contour_index then
            move_point_by(point, state.gs.freedom, distance)
        end
    end)
end

handlers[0x34] = function(state) shift_contour_by_reference(state, state.gs.rp2, "SHC") end
handlers[0x35] = function(state) shift_contour_by_reference(state, state.gs.rp1, "SHC") end

local function shift_zone_by_reference(state, ref_index, opcode_name)
    local zone_id = TtfInterpreter.pop(state)
    local ref = get_point(state, state.gs.zp0, ref_index, opcode_name)
    local distance = point_delta_from_original(ref, state.gs.projection)
    local zone = get_zone(state, zone_id, opcode_name)
    each_zone_point(zone, function(point_index, point)
        if not (zone_id == state.gs.zp0 and point_index == ref_index) then
            move_point_by(point, state.gs.freedom, distance)
        end
    end)
end

handlers[0x36] = function(state) shift_zone_by_reference(state, state.gs.rp2, "SHZ") end
handlers[0x37] = function(state) shift_zone_by_reference(state, state.gs.rp1, "SHZ") end

handlers[0x38] = function(state)
    TtfInterpreter.require_stack(state, state.gs.loop + 1, "SHPIX")
    local distance = TtfInterpreter.pop(state)
    for _ = 1, state.gs.loop do
        local point_index = TtfInterpreter.pop(state)
        local point = get_point(state, state.gs.zp2, point_index, "SHPIX")
        move_point_by(point, state.gs.freedom, distance)
    end
    state.gs.loop = 1
end

handlers[0x39] = function(state)
    local rp1 = get_point(state, state.gs.zp0, state.gs.rp1, "IP")
    local rp2 = get_point(state, state.gs.zp1, state.gs.rp2, "IP")
    for _ = 1, state.gs.loop do
        local point_index = TtfInterpreter.pop(state)
        local point = get_point(state, state.gs.zp2, point_index, "IP")
        interpolate_point_axis(point, rp1, rp2, axis_name(state.gs.projection))
        mark_touched(point, state.gs.freedom)
    end
    state.gs.loop = 1
end

handlers[0x3A] = function(state)
    TtfInterpreter.require_stack(state, 2, "MSIRP")
    local distance = TtfInterpreter.pop(state)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp1, point_index, "MSIRP")
    local ref = get_point(state, state.gs.zp0, state.gs.rp0, "MSIRP")
    move_point_to_coord(point, state.gs.projection, state.gs.freedom,
        projected_coord(ref, state.gs.projection, false) + distance)
    state.gs.rp1 = state.gs.rp0
    state.gs.rp2 = point_index
end

handlers[0x3B] = function(state)
    handlers[0x3A](state)
    state.gs.rp0 = state.gs.rp2
end

handlers[0x3C] = function(state)
    local ref = get_point(state, state.gs.zp0, state.gs.rp0, "ALIGNRP")
    local target = projected_coord(ref, state.gs.projection, false)
    for _ = 1, state.gs.loop do
        local point_index = TtfInterpreter.pop(state)
        local point = get_point(state, state.gs.zp1, point_index, "ALIGNRP")
        move_point_to_coord(point, state.gs.projection, state.gs.freedom, target)
    end
    state.gs.loop = 1
end

handlers[0x3D] = function(state) set_round_mode(state.gs, "double_grid", F26DOT6_ONE / 2, 0, 16) end

local function miap(state, round_distance)
    TtfInterpreter.require_stack(state, 2, "MIAP")
    local point_index = TtfInterpreter.pop(state)
    local cvt_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp0, point_index, "MIAP")
    local cvt_value = state.cvt[cvt_index] or 0
    local original = projected_coord(point, state.gs.projection, true)
    local current = projected_coord(point, state.gs.projection, false)
    local distance = cvt_value
    if math.abs(cvt_value - original) > state.gs.control_value_cut_in then
        distance = original
    end
    if round_distance then distance = round_by_state(state.gs, distance) end
    move_point_to_coord(point, state.gs.projection, state.gs.freedom, current + distance - current)
    state.gs.rp0 = point_index
    state.gs.rp1 = point_index
end

handlers[0x3E] = function(state) miap(state, false) end
handlers[0x3F] = function(state) miap(state, true) end

handlers[0x42] = function(state)
    TtfInterpreter.require_stack(state, 2, "WS")
    local value = TtfInterpreter.pop(state)
    local location = TtfInterpreter.pop(state)
    state.storage[location] = value
end

handlers[0x43] = function(state)
    local location = TtfInterpreter.pop(state)
    TtfInterpreter.push(state, state.storage[location] or 0)
end

handlers[0x44] = function(state)
    TtfInterpreter.require_stack(state, 2, "WCVTP")
    local value = TtfInterpreter.pop(state)
    local location = TtfInterpreter.pop(state)
    state.cvt[location] = value
end

handlers[0x45] = function(state)
    local location = TtfInterpreter.pop(state)
    TtfInterpreter.push(state, state.cvt[location] or 0)
end

handlers[0x46] = function(state)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp2, point_index, "GC")
    TtfInterpreter.push(state, round_nearest(projected_coord(point, state.gs.projection, false)))
end

handlers[0x47] = function(state)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp2, point_index, "GC")
    TtfInterpreter.push(state, round_nearest(projected_coord(point, state.gs.projection, true)))
end

handlers[0x48] = function(state)
    TtfInterpreter.require_stack(state, 2, "SCFS")
    local point_index = TtfInterpreter.pop(state)
    local value = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp2, point_index, "SCFS")
    move_point_to_coord(point, state.gs.projection, state.gs.freedom, value)
end

handlers[0x49] = function(state)
    TtfInterpreter.require_stack(state, 2, "MD")
    local p2_index = TtfInterpreter.pop(state)
    local p1_index = TtfInterpreter.pop(state)
    local p1 = get_point(state, state.gs.zp0, p1_index, "MD")
    local p2 = get_point(state, state.gs.zp1, p2_index, "MD")
    TtfInterpreter.push(state, round_nearest(projected_coord(p2, state.gs.projection, false) - projected_coord(p1, state.gs.projection, false)))
end

handlers[0x4A] = function(state)
    TtfInterpreter.require_stack(state, 2, "MD")
    local p2_index = TtfInterpreter.pop(state)
    local p1_index = TtfInterpreter.pop(state)
    local p1 = get_point(state, state.gs.zp0, p1_index, "MD")
    local p2 = get_point(state, state.gs.zp1, p2_index, "MD")
    TtfInterpreter.push(state, round_nearest(projected_coord(p2, state.gs.projection, true) - projected_coord(p1, state.gs.projection, true)))
end

handlers[0x4D] = function(state) state.gs.auto_flip = true end
handlers[0x4E] = function(state) state.gs.auto_flip = false end

handlers[0x4B] = function(state)
    TtfInterpreter.push(state, state.ppem or 0)
end

handlers[0x4C] = function(state)
    TtfInterpreter.push(state, (state.ppem or 0) * F26DOT6_ONE)
end

handlers[0x5E] = function(state) state.gs.delta_base = TtfInterpreter.pop(state) end
handlers[0x5F] = function(state) state.gs.delta_shift = TtfInterpreter.pop(state) end

local function apply_delta_points(state, family, opcode_name)
    local count = TtfInterpreter.pop(state)
    TtfInterpreter.require_stack(state, count * 2, opcode_name)
    for _ = 1, count do
        local arg = TtfInterpreter.pop(state)
        local point_index = TtfInterpreter.pop(state)
        local target_ppem, amount = delta_amount(state.gs, arg, family)
        if state.ppem == target_ppem then
            local point = get_point(state, state.gs.zp0, point_index, opcode_name)
            move_point_by(point, state.gs.freedom, amount)
        end
    end
end

local function apply_delta_cvt(state, family, opcode_name)
    local count = TtfInterpreter.pop(state)
    TtfInterpreter.require_stack(state, count * 2, opcode_name)
    for _ = 1, count do
        local arg = TtfInterpreter.pop(state)
        local cvt_index = TtfInterpreter.pop(state)
        local target_ppem, amount = delta_amount(state.gs, arg, family)
        if state.ppem == target_ppem then
            state.cvt[cvt_index] = (state.cvt[cvt_index] or 0) + amount
        end
    end
end

handlers[0x5D] = function(state) apply_delta_points(state, 0, "DELTAP1") end
handlers[0x71] = function(state) apply_delta_points(state, 1, "DELTAP2") end
handlers[0x72] = function(state) apply_delta_points(state, 2, "DELTAP3") end
handlers[0x73] = function(state) apply_delta_cvt(state, 0, "DELTAC1") end
handlers[0x74] = function(state) apply_delta_cvt(state, 1, "DELTAC2") end
handlers[0x75] = function(state) apply_delta_cvt(state, 2, "DELTAC3") end

for opcode = 0x68, 0x6B do
    handlers[opcode] = function(state)
        TtfInterpreter.require_stack(state, 1, "ROUND")
        local value = TtfInterpreter.pop(state)
        TtfInterpreter.push(state, round_by_state(state.gs, value))
    end
end

for opcode = 0x6C, 0x6F do
    handlers[opcode] = function(state)
        TtfInterpreter.require_stack(state, 1, "NROUND")
        local value = TtfInterpreter.pop(state)
        TtfInterpreter.push(state, value)
    end
end

handlers[0x70] = function(state)
    TtfInterpreter.require_stack(state, 2, "WCVTF")
    local value = TtfInterpreter.pop(state)
    local location = TtfInterpreter.pop(state)
    state.cvt[location] = scale_to_26_6(value, state.scale)
end

handlers[0x76] = function(state)
    local param = TtfInterpreter.pop(state)
    state.gs.round_state = decode_super_round(param, F26DOT6_ONE)
end

handlers[0x77] = function(state)
    local param = TtfInterpreter.pop(state)
    state.gs.round_state = decode_super_round(param, F26DOT6_ONE * math.sqrt(2) / 2)
    state.gs.round_state.mode = "super45"
end

handlers[0x78] = function(state, program, pc)
    TtfInterpreter.require_stack(state, 2, "JROT")
    local condition = TtfInterpreter.pop(state)
    local offset = TtfInterpreter.pop(state)
    if truthy(condition) then
        return checked_jump(program, pc + offset, "JROT")
    end
end

handlers[0x79] = function(state, program, pc)
    TtfInterpreter.require_stack(state, 2, "JROF")
    local condition = TtfInterpreter.pop(state)
    local offset = TtfInterpreter.pop(state)
    if not truthy(condition) then
        return checked_jump(program, pc + offset, "JROF")
    end
end

handlers[0x7A] = function(state) set_round_mode(state.gs, "off", F26DOT6_ONE, 0, 0) end
handlers[0x7C] = function(state) set_round_mode(state.gs, "up", F26DOT6_ONE, 0, 0) end
handlers[0x7D] = function(state) set_round_mode(state.gs, "down", F26DOT6_ONE, 0, 0) end
handlers[0x7E] = function(state)
    state.gs.angle_weight = TtfInterpreter.pop(state)
end

handlers[0x85] = function(state)
    state.gs.scan_control = TtfInterpreter.pop(state)
end

handlers[0x86] = function(state)
    state.gs.dual_projection = line_vector(state, 0x86, "SDPVTL")
end

handlers[0x87] = function(state)
    state.gs.dual_projection = line_vector(state, 0x87, "SDPVTL")
end

handlers[0x88] = function(state)
    local selector = TtfInterpreter.pop(state)
    local result = 0
    if band(selector, 0x0001) ~= 0 then
        result = result + 35
    end
    if band(selector, 0x0020) ~= 0 then
        result = result + 0x0040
    end
    if band(selector, 0x0400) ~= 0 then
        local font = state.font
        if font and font.fvar and font.gvar then
            result = result + 0x0400
        end
    end
    TtfInterpreter.push(state, result)
end

handlers[0x89] = function(state, program, pc)
    local opcode = TtfInterpreter.pop(state)
    local end_pc, after_endf = scan_to_endf(program, pc, "IDEF")
    state.instruction_defs[opcode] = {
        start_pc = pc,
        end_pc = end_pc - 1,
        program = program,
    }
    return after_endf
end

handlers[0x8D] = function(state)
    state.gs.scan_type = TtfInterpreter.pop(state)
end

handlers[0x8E] = function(state)
    TtfInterpreter.require_stack(state, 2, "INSTCTRL")
    local value = TtfInterpreter.pop(state)
    local selector = TtfInterpreter.pop(state)
    if selector == 1 or selector == 2 then
        state.gs.instruction_control = value
    end
end

handlers[0x91] = function(state)
    local font = state.font
    local axes = font and font.fvar and font.fvar.axes
    if not axes or #axes == 0 then
        TtfInterpreter.push(state, 0)
        return
    end
    local coords = state.norm_coords or {}
    for i = 1, #axes do
        local coord = coords[i] or 0
        local value
        if coord >= 0 then
            value = math_floor(coord * F2DOT14_ONE + 0.5)
        else
            value = -math_floor((-coord) * F2DOT14_ONE + 0.5)
        end
        TtfInterpreter.push(state, value)
    end
end

handlers[0x92] = function(state)
    TtfInterpreter.push(state, 17)
end

local function mdrp(state, opcode)
    local flags = decode_move_flags(opcode)
    local point_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp1, point_index, "MDRP")
    local ref = get_point(state, state.gs.zp0, state.gs.rp0, "MDRP")
    local distance = projected_coord(point, state.gs.dual_projection, true) -
        projected_coord(ref, state.gs.dual_projection, true)
    if flags.round then distance = round_by_state(state.gs, distance) end
    if flags.keep_min_dist then distance = apply_minimum_distance(state.gs, distance) end
    local target = projected_coord(ref, state.gs.projection, false) + distance
    move_point_to_coord(point, state.gs.projection, state.gs.freedom, target)
    state.gs.rp1 = state.gs.rp0
    state.gs.rp2 = point_index
    if flags.set_rp0 then state.gs.rp0 = point_index end
end

local function mirp(state, opcode)
    TtfInterpreter.require_stack(state, 2, "MIRP")
    local flags = decode_move_flags(opcode)
    local point_index = TtfInterpreter.pop(state)
    local cvt_index = TtfInterpreter.pop(state)
    local point = get_point(state, state.gs.zp1, point_index, "MIRP")
    local ref = get_point(state, state.gs.zp0, state.gs.rp0, "MIRP")
    local original_distance = projected_coord(point, state.gs.dual_projection, true) -
        projected_coord(ref, state.gs.dual_projection, true)
    local distance = state.cvt[cvt_index] or 0
    if state.gs.auto_flip and original_distance < 0 then
        distance = -math.abs(distance)
    end
    if math.abs(distance - original_distance) > state.gs.control_value_cut_in then
        distance = original_distance
    end
    if flags.round then distance = round_by_state(state.gs, distance) end
    if flags.keep_min_dist then distance = apply_minimum_distance(state.gs, distance) end
    move_point_to_coord(point, state.gs.projection, state.gs.freedom,
        projected_coord(ref, state.gs.projection, false) + distance)
    state.gs.rp1 = state.gs.rp0
    state.gs.rp2 = point_index
    if flags.set_rp0 then state.gs.rp0 = point_index end
end

for opcode = 0xC0, 0xDF do
    local encoded = opcode
    handlers[opcode] = function(state) mdrp(state, encoded) end
end

for opcode = 0xE0, 0xFF do
    local encoded = opcode
    handlers[opcode] = function(state) mirp(state, encoded) end
end

TtfInterpreter.handlers = handlers

local function program_id(state, program)
    local id = state.program_ids[program]
    if not id then
        state.next_program_id = state.next_program_id + 1
        id = state.next_program_id
        state.program_ids[program] = id
    end
    return id
end

local function record_pc_visit(state, program, pc)
    local key = program_id(state, program) .. ":" .. pc
    local count = (state.pc_visits[key] or 0) + 1
    state.pc_visits[key] = count
    if count > state.limits.max_pc_visits then
        error("cycle detected at pc " .. tostring(pc))
    end
end

local function enter_call(state, action)
    state.call_depth = state.call_depth + 1
    state.telemetry.calls = state.telemetry.calls + 1
    state.call_stack[state.call_depth] = {
        return_program = action.return_program,
        return_pc = action.return_pc,
        func_id = action.func_id,
        loop_remaining = action.loop_remaining or 0,
        program = action.program,
        pc = action.pc,
    }
    if state.call_depth > state.telemetry.call_depth_max then
        state.telemetry.call_depth_max = state.call_depth
        state.telemetry.max_depth = state.call_depth
    end
    return action.program, action.pc
end

local function leave_call(state)
    if state.call_depth <= 0 then
        error("ENDF outside function call")
    end
    local frame = state.call_stack[state.call_depth]
    if frame.loop_remaining and frame.loop_remaining > 0 then
        frame.loop_remaining = frame.loop_remaining - 1
        return frame.program, frame.pc
    end
    state.call_stack[state.call_depth] = nil
    state.call_depth = state.call_depth - 1
    return frame.return_program, frame.return_pc
end

--- Iterate an instruction stream with guardrails and dispatch.
---@param state table
---@param program string
---@return boolean
---@return table telemetry
function TtfInterpreter.run_instruction_stream(state, program)
    if type(program) ~= "string" or #program == 0 then
        return true, state.telemetry
    end

    local pc = 1
    local current_program = program
    while pc <= #current_program do
        state.telemetry.ops = state.telemetry.ops + 1
        if state.telemetry.ops > state.limits.max_ops then
            fail(state, "opcode budget exceeded")
            return false, state.telemetry
        end
        if state.call_depth > state.limits.max_call_depth then
            fail(state, "call depth exceeded")
            return false, state.telemetry
        end
        if state.call_depth > state.telemetry.max_depth then
            state.telemetry.max_depth = state.call_depth
        end
        if state.call_depth > state.telemetry.call_depth_max then
            state.telemetry.call_depth_max = state.call_depth
        end

        local visit_ok, visit_err = pcall(record_pc_visit, state, current_program, pc)
        if not visit_ok then
            state.telemetry.fail_reason = tostring(visit_err)
            return false, state.telemetry
        end

        local opcode = str_byte(current_program, pc)
        state.telemetry.last_opcode = opcode
        state.telemetry.opcode_counts[opcode] = (state.telemetry.opcode_counts[opcode] or 0) + 1
        pc = pc + 1

        local handler = handlers[opcode]
        local ok, err
        if state.instruction_defs and state.instruction_defs[opcode] then
            ok, err = pcall(idef_action, state, current_program, pc, opcode)
        else
            ok, err = pcall(handler, state, current_program, pc)
        end
        if not ok then
            if not state.telemetry.fail_reason then
                state.telemetry.fail_reason = tostring(err)
            end
            return false, state.telemetry
        end

        if type(err) == "number" then
            pc = err
        elseif type(err) == "table" then
            if err.type == "call" then
                current_program, pc = enter_call(state, err)
            elseif err.type == "return" then
                local return_ok, next_program, next_pc = pcall(leave_call, state)
                if not return_ok then
                    state.telemetry.fail_reason = tostring(next_program)
                    return false, state.telemetry
                end
                current_program, pc = next_program, next_pc
            end
        end

        while pc > #current_program and state.call_depth > 0 do
            local return_ok, next_program, next_pc = pcall(leave_call, state)
            if not return_ok then
                state.telemetry.fail_reason = tostring(next_program)
                return false, state.telemetry
            end
            current_program, pc = next_program, next_pc
        end
    end

    return true, state.telemetry
end

------------------------------------------------------------
-- Public integration API
------------------------------------------------------------

local function ensure_hinting_tables(font)
    return font and font.ttf_hinting
end

local function copy_functions_into(state, font)
    local shared = font and font._ttf_hinting_font_state
    if not shared then return end
    state.functions = copy_table_shallow(shared.functions)
    state.instruction_defs = copy_table_shallow(shared.instruction_defs)
end

local function ppem_key(ppem)
    return tostring(math_floor((ppem or 0) * 64 + 0.5))
end

local function normalized_coords_hash(norm_coords)
    if type(norm_coords) ~= "table" then return "0" end
    local h = 5381
    local any = false
    for i = 1, #norm_coords do
        any = true
        local part = tostring(math_floor((norm_coords[i] or 0) * 1000000 + 0.5))
        for j = 1, #part do
            h = (h * 33 + part:byte(j)) % 4294967296
        end
        h = (h * 33 + 44) % 4294967296
    end
    if not any then return "0" end
    return string.format("%08x", h)
end

local function ppem_variation_key(ppem, norm_coords)
    return ppem_key(ppem) .. ":" .. normalized_coords_hash(norm_coords)
end

function TtfInterpreter.interpret_font_program(font)
    if not ensure_hinting_tables(font) then
        local state = TtfInterpreter.new_state(font, nil, nil)
        state.telemetry.skipped = true
        state.telemetry.fail_reason = "missing TrueType hinting tables"
        return false, state.telemetry
    end
    if font._ttf_hinting_font_state then
        return true, font._ttf_hinting_font_state.telemetry
    end
    local state = TtfInterpreter.new_state(font, nil, nil)
    local ok, telemetry = TtfInterpreter.run_instruction_stream(state, font.ttf_hinting.fpgm or "")
    if ok then
        font._ttf_hinting_font_state = {
            functions = copy_table_shallow(state.functions),
            instruction_defs = copy_table_shallow(state.instruction_defs),
            telemetry = telemetry,
        }
    end
    return ok, telemetry
end

function TtfInterpreter.interpret_pre_program(font, ppem, norm_coords)
    if not ensure_hinting_tables(font) then
        local state = TtfInterpreter.new_state(font, ppem, nil)
        state.telemetry.skipped = true
        state.telemetry.fail_reason = "missing TrueType hinting tables"
        return false, state.telemetry
    end
    if not font._ttf_hinting_font_state then
        local ok, telemetry = TtfInterpreter.interpret_font_program(font)
        if not ok then return false, telemetry end
    end
    if not font._ttf_hinting_ppem then font._ttf_hinting_ppem = {} end
    local key = ppem_variation_key(ppem, norm_coords)
    if font._ttf_hinting_ppem[key] then
        return true, font._ttf_hinting_ppem[key].telemetry
    end
    local state = TtfInterpreter.new_state(font, ppem, nil, norm_coords)
    copy_functions_into(state, font)
    local ok, telemetry = TtfInterpreter.run_instruction_stream(state, font.ttf_hinting.prep or "")
    if ok then
        font._ttf_hinting_ppem[key] = {
            cvt = copy_table_shallow(state.cvt),
            storage = copy_table_shallow(state.storage),
            graphics_state = copy_graphics_state(state.gs),
            telemetry = telemetry,
        }
    end
    return ok, telemetry
end

function TtfInterpreter.interpret_glyph_program(font, glyph_idx, points_or_descriptor, ppem, norm_coords)
    local descriptor = points_or_descriptor
    local points = points_or_descriptor
    if points_or_descriptor and points_or_descriptor.points then
        descriptor = points_or_descriptor
        points = descriptor.points
    else
        descriptor = { points = points_or_descriptor, instructions = "" }
    end
    if not points then
        local state = TtfInterpreter.new_state(font, ppem, nil, norm_coords)
        state.telemetry.skipped = true
        state.telemetry.fail_reason = "glyph has no hintable point zone"
        return true, state.telemetry
    end
    if descriptor.telemetry and descriptor.telemetry.fail_reason then
        local state = TtfInterpreter.new_state(font, ppem, points, norm_coords)
        state.telemetry.skipped = true
        state.telemetry.fail_reason = descriptor.telemetry.fail_reason
        return false, state.telemetry
    end
    local ok, telemetry = TtfInterpreter.interpret_pre_program(font, ppem, norm_coords)
    if not ok then return false, telemetry end
    local state = TtfInterpreter.new_state(font, ppem, points, norm_coords)
    state.glyph_idx = glyph_idx
    copy_functions_into(state, font)
    local ppem_state = font._ttf_hinting_ppem and font._ttf_hinting_ppem[ppem_variation_key(ppem, norm_coords)]
    if ppem_state then
        state.cvt = copy_table_shallow(ppem_state.cvt)
        state.storage = copy_table_shallow(ppem_state.storage)
        if ppem_state.graphics_state then
            state.graphics_state = copy_graphics_state(ppem_state.graphics_state)
            state.gs = state.graphics_state
        end
    end

    ok, telemetry = TtfInterpreter.run_instruction_stream(state, descriptor.instructions or "")
    if not ok then return false, telemetry end

    local scale = state.scale
    if scale == 0 then scale = 1 end
    for k, zone_pt in pairs(state.zones[1].points) do
        if type(k) == "number" and points[k] then
            local pt = points[k]
            pt.original_x = zone_pt.ox / 64 / scale
            pt.original_y = zone_pt.oy / 64 / scale
            pt.x = zone_pt.x / 64 / scale
            pt.y = zone_pt.y / 64 / scale
            pt.touched_x = zone_pt.touched_x == true
            pt.touched_y = zone_pt.touched_y == true
        end
    end
    return true, telemetry
end

return TtfInterpreter



