------------------------------------------------------------
-- ext_core_astro_ui_lib / core / fonts / ttf_parser.lua
-- TrueType font binary parser.
--
-- Reads raw TTF binary data (Lua string) and extracts
-- table directory, font metrics, cmap mappings, and glyph
-- outlines as polylines suitable for the scanline rasterizer.
--
-- Glyph outlines are returned in the same format as
-- SvgParser output: arrays of polyline point tables
-- { {x=, y=}, {x=, y=}, ... }
--
-- Limitations:
-- - CFF outlines supported (PostScript cubic Beziers); CFF2 is rejected explicitly
-- - TrueType hinting tables are parsed but not executed by this module
-- - Variable font support: fvar/avar/gvar parsed for weight axis
--
-- Adapted from ext_lib_ultima_ui for Astro UI.
------------------------------------------------------------

local TtfParser = {}

------------------------------------------------------------
-- Local upvalues
------------------------------------------------------------

local bit        = require("core/util/bit")
local str_byte   = string.byte
local math_floor = math.floor
local math_abs   = math.abs
local math_max   = math.max
local band       = bit.band
local bor        = bit.bor
local lshift     = bit.lshift
local rshift     = bit.rshift

------------------------------------------------------------
-- Binary reading helpers (big-endian, 0-based offset)
------------------------------------------------------------

--- Read an unsigned 16-bit big-endian integer.
---@param data string  Raw binary data
---@param off number   0-based byte offset
---@return number
local function read_uint16(data, off)
    local b0, b1 = str_byte(data, off + 1, off + 2)
    if not b0 or not b1 then return nil end
    return lshift(b0, 8) + b1
end

--- Read a signed 16-bit big-endian integer.
---@param data string  Raw binary data
---@param off number   0-based byte offset
---@return number
local function read_int16(data, off)
    local v = read_uint16(data, off)
    if not v then return nil end
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end

--- Read an unsigned 32-bit big-endian integer.
--- Uses multiplication for the high byte to avoid LuaJIT
--- bit.lshift sign extension (lshift(0x80, 24) = negative).
---@param data string  Raw binary data
---@param off number   0-based byte offset
---@return number
local function read_uint32(data, off)
    local b0, b1, b2, b3 = str_byte(data, off + 1, off + 4)
    if not b0 or not b1 or not b2 or not b3 then return nil end
    return b0 * 0x1000000 + lshift(b1, 16) + lshift(b2, 8) + b3
end

--- Read an unsigned 8-bit integer.
---@param data string
---@param off number  0-based byte offset
---@return number
local function read_uint8(data, off)
    return str_byte(data, off + 1)
end

------------------------------------------------------------
-- Quadratic Bezier flattening
------------------------------------------------------------

--- Flatten a quadratic Bezier curve into line segments via
--- recursive adaptive subdivision.
---@param p0x number  Start point X
---@param p0y number  Start point Y
---@param cpx number  Control point X
---@param cpy number  Control point Y
---@param p1x number  End point X
---@param p1y number  End point Y
---@param out table   Output array; points appended as {x=, y=}
---@param tol number  Flatness tolerance
---@param depth number? Max recursion depth
local function flatten_quad(p0x, p0y, cpx, cpy, p1x, p1y, out, tol, depth)
    if not depth then depth = 16 end
    if depth <= 0 then
        out[#out + 1] = { x = p1x, y = p1y }
        return
    end

    local mx = (p0x + p1x) * 0.5
    local my = (p0y + p1y) * 0.5
    local dx = cpx - mx
    local dy = cpy - my
    if dx * dx + dy * dy <= tol * tol then
        out[#out + 1] = { x = p1x, y = p1y }
        return
    end

    local q0x = (p0x + cpx) * 0.5
    local q0y = (p0y + cpy) * 0.5
    local q1x = (cpx + p1x) * 0.5
    local q1y = (cpy + p1y) * 0.5
    local rx  = (q0x + q1x) * 0.5
    local ry  = (q0y + q1y) * 0.5

    flatten_quad(p0x, p0y, q0x, q0y, rx, ry, out, tol, depth - 1)
    flatten_quad(rx, ry, q1x, q1y, p1x, p1y, out, tol, depth - 1)
end

------------------------------------------------------------
-- Cubic Bezier flattening (CFF / PostScript outlines)
------------------------------------------------------------

--- Flatten a cubic Bezier curve into line segments via
--- adaptive De Casteljau subdivision.
---@param p0x number  Start point X
---@param p0y number  Start point Y
---@param c1x number  First control point X
---@param c1y number  First control point Y
---@param c2x number  Second control point X
---@param c2y number  Second control point Y
---@param p1x number  End point X
---@param p1y number  End point Y
---@param out table   Output array; points appended as {x=, y=}
---@param tol number  Flatness tolerance
---@param depth number? Max recursion depth
local function flatten_cubic(p0x, p0y, c1x, c1y, c2x, c2y, p1x, p1y, out, tol, depth)
    if not depth then depth = 16 end
    if depth <= 0 then
        out[#out + 1] = { x = p1x, y = p1y }
        return
    end

    -- Check flatness: max distance of control points from chord
    local dx = p1x - p0x
    local dy = p1y - p0y
    local d2 = dx * dx + dy * dy
    local tol2 = tol * tol

    if d2 < 1e-10 then
        -- Degenerate: all points nearly coincident
        local e1 = (c1x - p0x) * (c1x - p0x) + (c1y - p0y) * (c1y - p0y)
        local e2 = (c2x - p0x) * (c2x - p0x) + (c2y - p0y) * (c2y - p0y)
        if e1 <= tol2 and e2 <= tol2 then
            out[#out + 1] = { x = p1x, y = p1y }
            return
        end
    else
        -- Distance of c1 from line p0→p1
        local cross1 = (c1x - p0x) * dy - (c1y - p0y) * dx
        -- Distance of c2 from line p0→p1
        local cross2 = (c2x - p0x) * dy - (c2y - p0y) * dx
        if (cross1 * cross1 + cross2 * cross2) / d2 <= tol2 then
            out[#out + 1] = { x = p1x, y = p1y }
            return
        end
    end

    -- De Casteljau split at t=0.5
    local m01x = (p0x + c1x) * 0.5;  local m01y = (p0y + c1y) * 0.5
    local m12x = (c1x + c2x) * 0.5;  local m12y = (c1y + c2y) * 0.5
    local m23x = (c2x + p1x) * 0.5;  local m23y = (c2y + p1y) * 0.5
    local m012x = (m01x + m12x) * 0.5; local m012y = (m01y + m12y) * 0.5
    local m123x = (m12x + m23x) * 0.5; local m123y = (m12y + m23y) * 0.5
    local mx = (m012x + m123x) * 0.5;  local my = (m012y + m123y) * 0.5

    flatten_cubic(p0x, p0y, m01x, m01y, m012x, m012y, mx, my, out, tol, depth - 1)
    flatten_cubic(mx, my, m123x, m123y, m23x, m23y, p1x, p1y, out, tol, depth - 1)
end

------------------------------------------------------------
-- Table directory parsing
------------------------------------------------------------

--- Parse the TTF table directory.
---@param data string  Raw TTF binary data
---@return table  Map of tag -> { offset=number, length=number }
function TtfParser.parse_tables(data)
    if type(data) ~= "string" or #data < 12 then return {} end
    local num_tables = read_uint16(data, 4)
    if not num_tables then return {} end
    if 12 + num_tables * 16 > #data then return {} end
    local tables = {}

    for i = 0, num_tables - 1 do
        local rec_off = 12 + i * 16
        local tag = data:sub(rec_off + 1, rec_off + 4)
        local offset = read_uint32(data, rec_off + 8)
        local length = read_uint32(data, rec_off + 12)
        if not offset or not length then return {} end
        if offset < 0 or length < 0 or offset + length > #data then return {} end
        tables[tag] = {
            offset = offset,
            length = length,
        }
    end

    return tables
end

------------------------------------------------------------
-- head table
------------------------------------------------------------

--- Parse the head table for unitsPerEm and loca format.
---@param data string
---@param tables table
---@return table  { unitsPerEm=number, indexToLocFormat=number }
function TtfParser.parse_head(data, tables)
    local t = tables["head"]
    if not t then return { unitsPerEm = 1000, indexToLocFormat = 0 } end
    local off = t.offset
    return {
        unitsPerEm     = read_uint16(data, off + 18),
        indexToLocFormat = read_int16(data, off + 50),
    }
end

------------------------------------------------------------
-- hhea table
------------------------------------------------------------

--- Parse the hhea table for vertical metrics and hmtx count.
---@param data string
---@param tables table
---@return table  { ascent, descent, lineGap, numOfLongHorMetrics }
function TtfParser.parse_hhea(data, tables)
    local t = tables["hhea"]
    if not t then return { ascent = 800, descent = -200, lineGap = 0, numOfLongHorMetrics = 0 } end
    local off = t.offset
    return {
        ascent               = read_int16(data, off + 4),
        descent              = read_int16(data, off + 6),
        lineGap              = read_int16(data, off + 8),
        numOfLongHorMetrics  = read_uint16(data, off + 34),
    }
end

------------------------------------------------------------
-- maxp table
------------------------------------------------------------

--- Parse the maxp table for glyph count and TrueType VM limits.
---@param data string
---@param tables table
---@return table
function TtfParser.parse_maxp(data, tables)
    local t = tables["maxp"]
    if not t then
        return {
            numGlyphs = 0,
            maxZones = 2,
            maxTwilightPoints = 0,
            maxStorage = 0,
            maxFunctionDefs = 0,
            maxInstructionDefs = 0,
            maxStackElements = 1024,
        }
    end
    local off = t.offset
    local maxp = {
        numGlyphs = read_uint16(data, off + 4),
    }
    maxp.maxZones = t.length >= 16 and (read_uint16(data, off + 14) or 2) or 2
    maxp.maxTwilightPoints = t.length >= 18 and (read_uint16(data, off + 16) or 0) or 0
    maxp.maxStorage = t.length >= 20 and (read_uint16(data, off + 18) or 0) or 0
    maxp.maxFunctionDefs = t.length >= 22 and (read_uint16(data, off + 20) or 0) or 0
    maxp.maxInstructionDefs = t.length >= 24 and (read_uint16(data, off + 22) or 0) or 0
    maxp.maxStackElements = t.length >= 26 and (read_uint16(data, off + 24) or 1024) or 1024
    return maxp
end

------------------------------------------------------------
-- TrueType hinting tables
------------------------------------------------------------

--- Parse the cvt table as signed FWORD values.
---@param data string
---@param tables table
---@return table
function TtfParser.parse_cvt(data, tables)
    local t = tables["cvt "]
    local cvt = {}
    if not t then return cvt end
    local count = math_floor(t.length / 2)
    for i = 0, count - 1 do
        cvt[i] = read_int16(data, t.offset + i * 2) or 0
    end
    return cvt
end

--- Parse raw TrueType instruction program tables.
---@param data string
---@param tables table
---@param tag string
---@return string
function TtfParser.parse_program_table(data, tables, tag)
    local t = tables[tag]
    if not t or t.length <= 0 then return "" end
    return data:sub(t.offset + 1, t.offset + t.length)
end

------------------------------------------------------------
-- cmap table (character -> glyph index mapping)
------------------------------------------------------------

--- Parse a Format 4 cmap subtable (BMP plane).
---@param data string
---@param sub_off number  Byte offset to the subtable start
---@return function  codepoint_to_glyph(cp) -> glyph index
local function parse_cmap_format4(data, sub_off)
    local seg_count_x2 = read_uint16(data, sub_off + 6)
    local seg_count = math_floor(seg_count_x2 / 2)

    local end_codes   = {}
    local start_codes = {}
    local id_deltas   = {}
    local id_range_offsets = {}
    local range_off_base   -- byte offset of idRangeOffset array

    local arr_off = sub_off + 14
    for i = 1, seg_count do
        end_codes[i] = read_uint16(data, arr_off + (i - 1) * 2)
    end

    arr_off = arr_off + seg_count * 2 + 2 -- +2 for reservedPad
    for i = 1, seg_count do
        start_codes[i] = read_uint16(data, arr_off + (i - 1) * 2)
    end

    arr_off = arr_off + seg_count * 2
    for i = 1, seg_count do
        id_deltas[i] = read_int16(data, arr_off + (i - 1) * 2)
    end

    arr_off = arr_off + seg_count * 2
    range_off_base = arr_off
    for i = 1, seg_count do
        id_range_offsets[i] = read_uint16(data, arr_off + (i - 1) * 2)
    end

    return function(cp)
        if cp > 0xFFFF then return 0 end
        for i = 1, seg_count do
            if cp <= end_codes[i] then
                if cp < start_codes[i] then return 0 end
                if id_range_offsets[i] == 0 then
                    return band(cp + id_deltas[i], 0xFFFF)
                else
                    local idx_off = id_range_offsets[i] + 2 * (cp - start_codes[i])
                    local actual_off = range_off_base + (i - 1) * 2 + idx_off
                    local glyph_id = read_uint16(data, actual_off)
                    if glyph_id == 0 then return 0 end
                    return band(glyph_id + id_deltas[i], 0xFFFF)
                end
            end
        end
        return 0
    end
end

--- Parse a Format 12 cmap subtable (full Unicode).
---@param data string
---@param sub_off number  Byte offset to the subtable start
---@return function  codepoint_to_glyph(cp) -> glyph index
local function parse_cmap_format12(data, sub_off)
    local num_groups = read_uint32(data, sub_off + 12)
    local groups = {}

    for i = 0, num_groups - 1 do
        local g_off = sub_off + 16 + i * 12
        groups[i + 1] = {
            start_code  = read_uint32(data, g_off),
            end_code    = read_uint32(data, g_off + 4),
            start_glyph = read_uint32(data, g_off + 8),
        }
    end

    return function(cp)
        -- Binary search for the group containing cp
        local lo, hi = 1, #groups
        while lo <= hi do
            local mid = math_floor((lo + hi) / 2)
            local g = groups[mid]
            if cp < g.start_code then
                hi = mid - 1
            elseif cp > g.end_code then
                lo = mid + 1
            else
                return g.start_glyph + (cp - g.start_code)
            end
        end
        return 0
    end
end

--- Parse the cmap table, returning a codepoint-to-glyph lookup function.
--- Prefers Format 12 (full Unicode), falls back to Format 4 (BMP).
---@param data string
---@param tables table
---@return function  codepoint_to_glyph(cp) -> glyph index
function TtfParser.parse_cmap(data, tables)
    local t = tables["cmap"]
    if not t then return function() return 0 end end

    local off = t.offset
    local num_subtables = read_uint16(data, off + 2)

    local fmt4_off  = nil
    local fmt12_off = nil

    for i = 0, num_subtables - 1 do
        local rec = off + 4 + i * 8
        local platform_id = read_uint16(data, rec)
        local encoding_id = read_uint16(data, rec + 2)
        local sub_offset  = read_uint32(data, rec + 4)
        local abs_off     = off + sub_offset

        local format = read_uint16(data, abs_off)

        -- Prefer (3,10) Format 12 for full Unicode
        if format == 12 and platform_id == 3 and encoding_id == 10 then
            fmt12_off = abs_off
        -- Fallback to (3,1) Format 4 for BMP
        elseif format == 4 and platform_id == 3 and encoding_id == 1 then
            fmt4_off = abs_off
        -- Also accept (0,*) Unicode platform
        elseif format == 12 and platform_id == 0 then
            if not fmt12_off then fmt12_off = abs_off end
        elseif format == 4 and platform_id == 0 then
            if not fmt4_off then fmt4_off = abs_off end
        end
    end

    if fmt12_off then
        return parse_cmap_format12(data, fmt12_off)
    elseif fmt4_off then
        return parse_cmap_format4(data, fmt4_off)
    end

    return function() return 0 end
end

------------------------------------------------------------
-- OS/2 table (weight class, italic flag)
------------------------------------------------------------

--- Parse the OS/2 table for weight class, selection flags, and typo metrics.
---@param data string
---@param tables table
---@return table|nil
function TtfParser.parse_os2(data, tables)
    local t = tables["OS/2"]
    if not t then return nil end
    local off = t.offset
    local result = {
        usWeightClass = read_uint16(data, off + 4),
        fsSelection   = read_uint16(data, off + 62),
    }
    if t.length >= 74 then
        result.sTypoAscender  = read_int16(data, off + 68)
        result.sTypoDescender = read_int16(data, off + 70)
        result.sTypoLineGap   = read_int16(data, off + 72)
    end
    if t.length >= 78 then
        result.usWinAscent  = read_uint16(data, off + 74)
        result.usWinDescent = read_uint16(data, off + 76)
    end
    return {
        usWeightClass  = result.usWeightClass,
        fsSelection    = result.fsSelection,
        sTypoAscender  = result.sTypoAscender,
        sTypoDescender = result.sTypoDescender,
        sTypoLineGap   = result.sTypoLineGap,
        usWinAscent    = result.usWinAscent,
        usWinDescent   = result.usWinDescent,
    }
end

------------------------------------------------------------
-- fvar table (font variations axes)
------------------------------------------------------------

--- Read a Fixed 16.16 value as a Lua number.
---@param data string
---@param off number  0-based byte offset
---@return number
local function read_fixed(data, off)
    local hi = read_int16(data, off)
    local lo = read_uint16(data, off + 2)
    return hi + lo / 65536
end

--- Parse the fvar table for variable font axis definitions.
---@param data string
---@param tables table
---@return table|nil  { axes = { { tag, min, default, max, nameID }, ... } }
function TtfParser.parse_fvar(data, tables)
    local t = tables["fvar"]
    if not t then return nil end
    local off = t.offset

    local axes_offset = read_uint16(data, off + 4)
    local axis_count  = read_uint16(data, off + 8)
    local axis_size   = read_uint16(data, off + 10)

    local axes = {}
    for i = 0, axis_count - 1 do
        local a_off = off + axes_offset + i * axis_size
        local tag = data:sub(a_off + 1, a_off + 4)
        axes[i + 1] = {
            tag      = tag,
            min      = read_fixed(data, a_off + 4),
            default  = read_fixed(data, a_off + 8),
            max      = read_fixed(data, a_off + 12),
            nameID   = read_uint16(data, a_off + 18),
        }
    end

    return { axes = axes }
end

------------------------------------------------------------
-- avar table (axis variation normalization)
------------------------------------------------------------

--- Read an F2Dot14 value (signed fixed 2.14).
---@param data string
---@param off number
---@return number
local function read_f2dot14(data, off)
    local v = read_int16(data, off)
    return v / 16384
end

local function round_nearest(value)
    if value >= 0 then
        return math_floor(value + 0.5)
    end
    return -math_floor(-value + 0.5)
end

--- Parse the avar table for axis normalization segment maps.
---@param data string
---@param tables table
---@param axis_count number
---@return table|nil  { [axis_index] = { {from, to}, ... }, ... }
function TtfParser.parse_avar(data, tables, axis_count)
    local t = tables["avar"]
    if not t then return nil end
    local off = t.offset + 8  -- skip version (4) + reserved (2) + axisCount (2)

    local result = {}
    for i = 1, axis_count do
        local count = read_uint16(data, off)
        off = off + 2
        local segments = {}
        for j = 1, count do
            segments[j] = {
                from = read_f2dot14(data, off),
                to   = read_f2dot14(data, off + 2),
            }
            off = off + 4
        end
        result[i] = segments
    end

    return result
end

------------------------------------------------------------
-- Variation coordinate normalization
------------------------------------------------------------

--- Normalize user coordinates to -1..+1 using fvar defaults
--- and optionally apply avar segment maps.
---@param fvar table  Parsed fvar table
---@param avar table|nil  Parsed avar table
---@param user_coords table  { wght=700, ... } tag -> value
---@return table  { [axis_index] = normalized, ... }
function TtfParser.normalize_coords(fvar, avar, user_coords)
    local result = {}
    for i, axis in ipairs(fvar.axes) do
        local val = user_coords[axis.tag] or axis.default
        -- Clamp to axis range
        if val < axis.min then val = axis.min end
        if val > axis.max then val = axis.max end

        -- Normalize to -1..+1
        local norm
        if val == axis.default then
            norm = 0
        elseif val < axis.default then
            norm = -(axis.default - val) / (axis.default - axis.min)
        else
            norm = (val - axis.default) / (axis.max - axis.default)
        end

        -- Apply avar segment map if present
        if avar and avar[i] then
            local segs = avar[i]
            -- Find segment containing norm and interpolate
            for j = 2, #segs do
                if norm <= segs[j].from then
                    local s0 = segs[j - 1]
                    local s1 = segs[j]
                    local range = s1.from - s0.from
                    if math_abs(range) > 0.0001 then
                        local t = (norm - s0.from) / range
                        norm = s0.to + t * (s1.to - s0.to)
                    else
                        norm = s1.to
                    end
                    break
                end
            end
        end

        result[i] = norm
    end
    return result
end

------------------------------------------------------------
-- loca table (glyph offset index)
------------------------------------------------------------

--- Parse the loca table to get byte offsets into glyf for each glyph.
---@param data string
---@param tables table
---@param numGlyphs number
---@param indexToLocFormat number  0 = short (uint16/2), 1 = long (uint32)
---@return table  Array of byte offsets [0..numGlyphs]
function TtfParser.parse_loca(data, tables, numGlyphs, indexToLocFormat)
    local t = tables["loca"]
    if not t then return {} end

    local off = t.offset
    local loca = {}

    if indexToLocFormat == 0 then
        -- Short format: uint16 values, multiply by 2
        for i = 0, numGlyphs do
            loca[i] = read_uint16(data, off + i * 2) * 2
        end
    else
        -- Long format: uint32 values
        for i = 0, numGlyphs do
            loca[i] = read_uint32(data, off + i * 4)
        end
    end

    return loca
end

------------------------------------------------------------
-- hmtx table (horizontal metrics)
------------------------------------------------------------

--- Parse the hmtx table for advance widths and LSBs.
---@param data string
---@param tables table
---@param numGlyphs number
---@param numOfLongHorMetrics number
---@return table  Array indexed by glyph index -> { advanceWidth, lsb }
function TtfParser.parse_hmtx(data, tables, numGlyphs, numOfLongHorMetrics)
    local t = tables["hmtx"]
    if not t then return {} end

    local off = t.offset
    local hmtx = {}
    local last_aw = 0

    -- Full metric records
    for i = 0, numOfLongHorMetrics - 1 do
        local rec = off + i * 4
        local aw  = read_uint16(data, rec)
        local lsb = read_int16(data, rec + 2)
        hmtx[i] = { advanceWidth = aw, lsb = lsb }
        last_aw = aw
    end

    -- Remaining glyphs share the last advance width
    local lsb_off = off + numOfLongHorMetrics * 4
    for i = numOfLongHorMetrics, numGlyphs - 1 do
        local lsb = read_int16(data, lsb_off + (i - numOfLongHorMetrics) * 2)
        hmtx[i] = { advanceWidth = last_aw, lsb = lsb }
    end

    return hmtx
end

------------------------------------------------------------
-- kern table (legacy horizontal kerning)
------------------------------------------------------------

--- Parse legacy 'kern' format 0 pairs.
---@param data string
---@param tables table
---@return table|nil  { [left_glyph] = { [right_glyph] = value_font_units } }
function TtfParser.parse_kern(data, tables)
    local t = tables["kern"]
    if not t then return nil end

    local table_end = t.offset + t.length
    if t.length < 4 then return nil end

    local pos = t.offset
    local version = read_uint16(data, pos)
    local n_tables = read_uint16(data, pos + 2)
    pos = pos + 4

    -- Apple extended kern tables use a different 32-bit header.  Keep this
    -- parser deliberately conservative and handle the Microsoft/OpenType
    -- legacy layout that web fonts commonly include.
    if version ~= 0 then return nil end

    local kern = {}
    local has_pairs = false
    for _ = 1, n_tables do
        if pos + 6 > table_end then break end
        local length = read_uint16(data, pos + 2)
        local coverage = read_uint16(data, pos + 4)
        local format = rshift(coverage, 8)
        local horizontal = band(coverage, 0x0001) ~= 0

        if format == 0 and horizontal and length >= 14 and pos + length <= table_end then
            local p = pos + 6
            local n_pairs = read_uint16(data, p)
            p = p + 8 -- skip nPairs, searchRange, entrySelector, rangeShift
            for _pair = 1, n_pairs do
                if p + 6 > pos + length then break end
                local left = read_uint16(data, p)
                local right = read_uint16(data, p + 2)
                local value = read_int16(data, p + 4)
                if value ~= 0 then
                    local row = kern[left]
                    if not row then
                        row = {}
                        kern[left] = row
                    end
                    row[right] = value
                    has_pairs = true
                end
                p = p + 6
            end
        end

        if length <= 0 then break end
        pos = pos + length
    end

    return has_pairs and kern or nil
end

------------------------------------------------------------
-- GPOS table (pair positioning / modern kerning)
------------------------------------------------------------

local function parse_coverage(data, off)
    local format = read_uint16(data, off)
    local glyphs, set = {}, {}
    if format == 1 then
        local count = read_uint16(data, off + 2)
        for i = 1, count do
            local glyph = read_uint16(data, off + 4 + (i - 1) * 2)
            glyphs[i] = glyph
            set[glyph] = i
        end
    elseif format == 2 then
        local range_count = read_uint16(data, off + 2)
        local p = off + 4
        for _ = 1, range_count do
            local start_glyph = read_uint16(data, p)
            local end_glyph = read_uint16(data, p + 2)
            local start_index = read_uint16(data, p + 4)
            for glyph = start_glyph, end_glyph do
                local idx = start_index + (glyph - start_glyph) + 1
                glyphs[idx] = glyph
                set[glyph] = idx
            end
            p = p + 6
        end
    end
    return { glyphs = glyphs, set = set }
end

local function parse_class_def(data, off)
    local format = read_uint16(data, off)
    local classes = {}
    if format == 1 then
        local start_glyph = read_uint16(data, off + 2)
        local glyph_count = read_uint16(data, off + 4)
        local p = off + 6
        for i = 0, glyph_count - 1 do
            classes[start_glyph + i] = read_uint16(data, p + i * 2)
        end
    elseif format == 2 then
        local range_count = read_uint16(data, off + 2)
        local p = off + 4
        for _ = 1, range_count do
            local start_glyph = read_uint16(data, p)
            local end_glyph = read_uint16(data, p + 2)
            local class_value = read_uint16(data, p + 4)
            for glyph = start_glyph, end_glyph do
                classes[glyph] = class_value
            end
            p = p + 6
        end
    end
    return classes
end

local function value_record_size(format)
    local size = 0
    if band(format, 0x0001) ~= 0 then size = size + 2 end -- xPlacement
    if band(format, 0x0002) ~= 0 then size = size + 2 end -- yPlacement
    if band(format, 0x0004) ~= 0 then size = size + 2 end -- xAdvance
    if band(format, 0x0008) ~= 0 then size = size + 2 end -- yAdvance
    if band(format, 0x0010) ~= 0 then size = size + 2 end -- xPlaDevice/xPlaVariation
    if band(format, 0x0020) ~= 0 then size = size + 2 end -- yPlaDevice/yPlaVariation
    if band(format, 0x0040) ~= 0 then size = size + 2 end -- xAdvDevice/xAdvVariation
    if band(format, 0x0080) ~= 0 then size = size + 2 end -- yAdvDevice/yAdvVariation
    return size
end

local function read_value_record_xadvance(data, pos, format)
    local x_advance = 0
    if band(format, 0x0001) ~= 0 then pos = pos + 2 end
    if band(format, 0x0002) ~= 0 then pos = pos + 2 end
    if band(format, 0x0004) ~= 0 then
        x_advance = read_int16(data, pos)
        pos = pos + 2
    end
    if band(format, 0x0008) ~= 0 then pos = pos + 2 end
    if band(format, 0x0010) ~= 0 then pos = pos + 2 end
    if band(format, 0x0020) ~= 0 then pos = pos + 2 end
    if band(format, 0x0040) ~= 0 then pos = pos + 2 end
    if band(format, 0x0080) ~= 0 then pos = pos + 2 end
    return x_advance, pos
end

local function add_gpos_pair(gpos, left, right, value)
    if value == 0 then return end
    local row = gpos.pairs[left]
    if not row then
        row = {}
        gpos.pairs[left] = row
    end
    row[right] = (row[right] or 0) + value
    gpos.has_pairs = true
end

local function parse_pairpos_subtable(data, sub_off, gpos)
    local pos_format = read_uint16(data, sub_off)
    local coverage_off = read_uint16(data, sub_off + 2)
    local value_format1 = read_uint16(data, sub_off + 4)
    local value_format2 = read_uint16(data, sub_off + 6)
    local coverage = parse_coverage(data, sub_off + coverage_off)

    if pos_format == 1 then
        local pair_set_count = read_uint16(data, sub_off + 8)
        for i = 1, pair_set_count do
            local left_glyph = coverage.glyphs[i]
            local pair_set_off = read_uint16(data, sub_off + 10 + (i - 1) * 2)
            if left_glyph and pair_set_off and pair_set_off ~= 0 then
                local p = sub_off + pair_set_off
                local pair_value_count = read_uint16(data, p)
                p = p + 2
                for _ = 1, pair_value_count do
                    local second_glyph = read_uint16(data, p)
                    p = p + 2
                    local x_advance
                    x_advance, p = read_value_record_xadvance(data, p, value_format1)
                    local _
                    _, p = read_value_record_xadvance(data, p, value_format2)
                    add_gpos_pair(gpos, left_glyph, second_glyph, x_advance)
                end
            end
        end
    elseif pos_format == 2 then
        local class_def1_off = read_uint16(data, sub_off + 8)
        local class_def2_off = read_uint16(data, sub_off + 10)
        local class1_count = read_uint16(data, sub_off + 12)
        local class2_count = read_uint16(data, sub_off + 14)
        local class1 = parse_class_def(data, sub_off + class_def1_off)
        local class2 = parse_class_def(data, sub_off + class_def2_off)
        local size1 = value_record_size(value_format1)
        local size2 = value_record_size(value_format2)
        local record_size = size1 + size2
        local matrix = {}
        local p = sub_off + 16
        local has_matrix = false
        for c1 = 0, class1_count - 1 do
            local row = {}
            for c2 = 0, class2_count - 1 do
                local rec = p + (c1 * class2_count + c2) * record_size
                local x_advance = read_value_record_xadvance(data, rec, value_format1)
                if x_advance ~= 0 then
                    row[c2] = x_advance
                    has_matrix = true
                end
            end
            matrix[c1] = row
        end
        if has_matrix then
            gpos.class_pairs[#gpos.class_pairs + 1] = {
                coverage = coverage.set,
                class1 = class1,
                class2 = class2,
                matrix = matrix,
            }
            gpos.has_pairs = true
        end
    end
end

local function parse_gpos_lookup_subtable(data, lookup_type, sub_off, gpos)
    if lookup_type == 2 then
        parse_pairpos_subtable(data, sub_off, gpos)
    elseif lookup_type == 9 then
        local pos_format = read_uint16(data, sub_off)
        if pos_format == 1 then
            local extension_lookup_type = read_uint16(data, sub_off + 2)
            local extension_offset = read_uint32(data, sub_off + 4)
            parse_gpos_lookup_subtable(data, extension_lookup_type, sub_off + extension_offset, gpos)
        end
    end
end

--- Parse GPOS pair positioning lookups used for modern kerning.
---@param data string
---@param tables table
---@return table|nil
function TtfParser.parse_gpos(data, tables)
    local t = tables["GPOS"]
    if not t or t.length < 10 then return nil end
    local off = t.offset
    local lookup_list_off = read_uint16(data, off + 8)
    if lookup_list_off == 0 then return nil end

    local list_off = off + lookup_list_off
    local lookup_count = read_uint16(data, list_off)
    local gpos = { pairs = {}, class_pairs = {}, has_pairs = false }
    for i = 0, lookup_count - 1 do
        local lookup_off = read_uint16(data, list_off + 2 + i * 2)
        if lookup_off ~= 0 then
            local l_off = list_off + lookup_off
            local lookup_type = read_uint16(data, l_off)
            local subtable_count = read_uint16(data, l_off + 4)
            for s = 0, subtable_count - 1 do
                local sub_off = read_uint16(data, l_off + 6 + s * 2)
                if sub_off ~= 0 then
                    parse_gpos_lookup_subtable(data, lookup_type, l_off + sub_off, gpos)
                end
            end
        end
    end

    return gpos.has_pairs and gpos or nil
end

------------------------------------------------------------
-- gvar table (glyph variation deltas)
------------------------------------------------------------

--- Parse the gvar table header, shared tuples, and glyph offsets.
---@param data string
---@param tables table
---@param numGlyphs number
---@param axisCount number
---@return table|nil  gvar data structure
function TtfParser.parse_gvar(data, tables, numGlyphs, axisCount)
    local t = tables["gvar"]
    if not t then return nil end
    local off = t.offset

    local axis_count   = read_uint16(data, off + 4)
    local shared_count = read_uint16(data, off + 6)
    local shared_off   = read_uint32(data, off + 8)
    local glyph_count  = read_uint16(data, off + 12)
    local flags        = read_uint16(data, off + 14)
    local data_offset  = read_uint32(data, off + 16)

    -- Parse shared tuples (each is axisCount F2Dot14 values)
    local shared_tuples = {}
    local st_off = off + shared_off
    for i = 1, shared_count do
        local tuple = {}
        for a = 1, axis_count do
            tuple[a] = read_f2dot14(data, st_off)
            st_off = st_off + 2
        end
        shared_tuples[i] = tuple
    end

    -- Parse glyph offsets (uint16 or uint32 depending on flags bit 0)
    local offsets = {}
    local off_base = off + 20
    local long_offsets = band(flags, 1) ~= 0
    for i = 0, glyph_count do
        if long_offsets then
            offsets[i] = read_uint32(data, off_base + i * 4)
        else
            offsets[i] = read_uint16(data, off_base + i * 2) * 2
        end
    end

    return {
        axisCount    = axis_count,
        glyphCount   = glyph_count,
        sharedTuples = shared_tuples,
        offsets      = offsets,
        dataOffset   = off + data_offset,
        data         = data,
    }
end

------------------------------------------------------------
-- HVAR table -" horizontal metric variations
------------------------------------------------------------
--
-- HVAR provides per-glyph advance-width deltas for variable fonts.
-- Without it, the engine reads only the BASE hmtx advance regardless
-- of the active variation instance (e.g. weight 400 vs weight 700) -"
-- producing 0.5-1px per-character overstatement vs Chrome's HVAR-aware
-- advance, which compounds over multi-word lines and pushes 1 extra
-- wrap in long paragraphs.
--
-- Minimal advance-width implementation for the current parser pass:
-- variation only, generic across axes (uses normalized coords). LSB/
-- RSB mappings skipped. MVAR/VVAR not parsed. Only the IVS subset
-- needed for advance-width lookup is implemented.
--
-- Spec references:
--   HVAR: https://learn.microsoft.com/typography/opentype/spec/hvar
--   IVS:  https://learn.microsoft.com/typography/opentype/spec/otvarcommonformats
------------------------------------------------------------

--- Parse an ItemVariationStore at `off` (absolute offset into data).
---@param data string
---@param off number  0-based absolute offset
---@return table|nil  { regions, sub_tables }
local function parse_item_variation_store(data, off)
    local format = read_uint16(data, off)
    if format ~= 1 then return nil end  -- only format 1 defined
    local region_list_off  = read_uint32(data, off + 2)
    local ivd_count        = read_uint16(data, off + 6)
    if ivd_count == 0 then return nil end

    -- Parse VariationRegionList
    local rl_off = off + region_list_off
    local axis_count   = read_uint16(data, rl_off)
    local region_count = read_uint16(data, rl_off + 2)
    local regions = {}
    local r_off = rl_off + 4
    for r = 0, region_count - 1 do
        local axes_in_region = {}
        for a = 0, axis_count - 1 do
            local base = r_off + (r * axis_count + a) * 6
            axes_in_region[a + 1] = {
                start_coord = read_f2dot14(data, base),
                peak_coord  = read_f2dot14(data, base + 2),
                end_coord   = read_f2dot14(data, base + 4)
            }
        end
        regions[r + 1] = axes_in_region
    end

    -- Parse ItemVariationData subtables
    local sub_tables = {}
    for s = 0, ivd_count - 1 do
        local ivd_offset = read_uint32(data, off + 8 + s * 4)
        local ivd_abs    = off + ivd_offset
        local item_count        = read_uint16(data, ivd_abs)
        local word_delta_count_raw = read_uint16(data, ivd_abs + 2)
        local region_index_count   = read_uint16(data, ivd_abs + 4)
        -- High bit of word_delta_count_raw is LONG_WORDS flag (deltas use
        -- int32 instead of int16). Per spec § ItemVariationData header.
        local long_words = band(word_delta_count_raw, 0x8000) ~= 0
        local word_delta_count = band(word_delta_count_raw, 0x7FFF)
        local region_indices = {}
        for ri = 0, region_index_count - 1 do
            region_indices[ri + 1] = read_uint16(data, ivd_abs + 6 + ri * 2)
        end
        -- Delta data starts after the region index list
        local delta_start = ivd_abs + 6 + region_index_count * 2
        local long_size = long_words and 4 or 2
        local short_size = long_words and 2 or 1
        local row_size = word_delta_count * long_size
                       + (region_index_count - word_delta_count) * short_size
        local items = {}
        for it = 0, item_count - 1 do
            local row_off = delta_start + it * row_size
            local deltas = {}
            for ri = 0, region_index_count - 1 do
                local v
                if ri < word_delta_count then
                    if long_words then
                        -- int32; combine two uint16 halves
                        local hi = read_uint16(data, row_off + ri * 4)
                        local lo = read_uint16(data, row_off + ri * 4 + 2)
                        v = hi * 65536 + lo
                        if v >= 0x80000000 then v = v - 0x100000000 end
                    else
                        v = read_int16(data, row_off + ri * 2)
                    end
                else
                    local off2 = row_off + word_delta_count * long_size
                                + (ri - word_delta_count) * short_size
                    if long_words then
                        v = read_int16(data, off2)
                    else
                        v = read_uint8(data, off2)
                        if v >= 0x80 then v = v - 0x100 end
                    end
                end
                deltas[ri + 1] = v
            end
            items[it + 1] = deltas
        end
        sub_tables[s + 1] = {
            region_indices = region_indices,
            items = items
        }
    end

    return { regions = regions, sub_tables = sub_tables }
end

--- Parse a DeltaSetIndexMap at `off` (absolute offset into data).
---@param data string
---@param off number
---@return table|nil  { entries = { {outer, inner}, ... } }
local function parse_delta_set_index_map(data, off)
    local format = read_uint16(data, off)
    local entry_format = read_uint16(data, off + 2)
    local map_count
    local entries_off
    if format == 0 then
        map_count = read_uint16(data, off + 4)
        entries_off = off + 6
    elseif format == 1 then
        map_count = read_uint32(data, off + 4)
        entries_off = off + 8
    else
        return nil
    end
    -- entry_format bits per spec:
    --   bits 0-3: INNER_INDEX_BIT_COUNT_MASK → inner index bit count - 1
    --   bits 4-5: MAP_ENTRY_SIZE_MASK >> 4 → entry size - 1
    local inner_bit_count = band(entry_format, 0x0F) + 1
    local entry_size      = band(rshift(entry_format, 4), 0x03) + 1
    local inner_mask = bit.lshift(1, inner_bit_count) - 1
    local entries = {}
    for i = 0, map_count - 1 do
        local p = entries_off + i * entry_size
        local val = 0
        for b = 0, entry_size - 1 do
            val = bit.lshift(val, 8) + read_uint8(data, p + b)
        end
        local inner = band(val, inner_mask)
        local outer = rshift(val, inner_bit_count)
        entries[i + 1] = { outer = outer, inner = inner }
    end
    return { entries = entries }
end

--- Parse the HVAR table.
---@param data string
---@param tables table
---@return table|nil  { item_variation_store, advance_mapping }
function TtfParser.parse_hvar(data, tables)
    local t = tables["HVAR"]
    if not t or t.length < 20 then return nil end
    local off = t.offset
    -- Major + minor version (4 bytes), then offsets:
    local ivs_offset            = read_uint32(data, off + 4)
    local advance_mapping_off   = read_uint32(data, off + 8)
    if ivs_offset == 0 then return nil end

    local ok, ivs = pcall(parse_item_variation_store, data, off + ivs_offset)
    if not ok or not ivs then return nil end

    local advance_mapping = nil
    if advance_mapping_off ~= 0 then
        local ok2, m = pcall(parse_delta_set_index_map, data, off + advance_mapping_off)
        if ok2 then advance_mapping = m end
    end

    return {
        item_variation_store = ivs,
        advance_mapping      = advance_mapping
    }
end

--- Compute the scalar contribution of a variation region for a given
--- set of normalized axis coordinates. Per OpenType §ItemVariationStore.
---@param region table  array of per-axis { start_coord, peak_coord, end_coord }
---@param norm_coords table  array of per-axis normalized coord (-1..+1)
---@return number  scalar in [0, 1]
local function compute_region_scalar(region, norm_coords)
    local scalar = 1.0
    for a = 1, #region do
        local axis = region[a]
        local coord = norm_coords[a] or 0
        local s, p, e = axis.start_coord, axis.peak_coord, axis.end_coord
        if p == 0 then
            -- peak == 0 means this axis contributes 1 unconditionally
            -- IF the region is degenerate; otherwise spec says treat as 1.
        elseif coord == p then
            -- exact peak: scalar 1, no change
        elseif coord < s or coord > e then
            return 0
        elseif coord < p then
            scalar = scalar * ((coord - s) / (p - s))
        else
            scalar = scalar * ((e - coord) / (e - p))
        end
    end
    return scalar
end

--- Compute the advance-width delta (in font units) for a glyph at the
--- given normalized axis coordinates. Returns 0 if HVAR is unavailable
--- or doesn't cover this glyph.
---@param hvar table  Parsed HVAR table
---@param glyph_index number
---@param norm_coords table  array of normalized axis coords (-1..+1)
---@return number  advance delta in font units (add to base hmtx advance)
function TtfParser.get_hvar_advance_delta(hvar, glyph_index, norm_coords)
    if not hvar or not hvar.item_variation_store then return 0 end
    local ivs = hvar.item_variation_store

    -- Resolve outer/inner indices.
    -- With advance_mapping present: glyph_index → entries[glyph_index].outer/inner.
    -- Without: implicit -" glyph_index IS the inner index into sub_tables[1].
    local outer, inner
    if hvar.advance_mapping then
        local e = hvar.advance_mapping.entries[glyph_index + 1]
        if not e then return 0 end
        outer, inner = e.outer, e.inner
    else
        outer = 0
        inner = glyph_index
    end

    local sub = ivs.sub_tables[outer + 1]
    if not sub then return 0 end
    local deltas = sub.items[inner + 1]
    if not deltas then return 0 end

    local total = 0
    for k = 1, #deltas do
        local region = ivs.regions[sub.region_indices[k] + 1]
        if region then
            local s = compute_region_scalar(region, norm_coords)
            if s ~= 0 then total = total + s * deltas[k] end
        end
    end
    return total
end

--- Unpack run-length encoded delta values from gvar.
---@param data string
---@param off number  0-based offset
---@param count number  number of deltas to unpack
---@return table  array of int16 delta values
---@return number  new offset after reading
function TtfParser._unpack_deltas(data, off, count)
    local deltas = {}
    local di = 0
    while di < count do
        local ctrl = read_uint8(data, off)
        off = off + 1
        local run_count = band(ctrl, 0x3F) + 1

        for _ = 1, run_count do
            if di >= count then break end
            di = di + 1
            if band(ctrl, 0x80) ~= 0 then
                -- DELTAS_ARE_ZERO: no data bytes consumed
                deltas[di] = 0
            elseif band(ctrl, 0x40) ~= 0 then
                -- DELTAS_ARE_WORDS: 16-bit signed
                deltas[di] = read_int16(data, off)
                off = off + 2
            else
                -- Default: 8-bit signed
                local v = read_uint8(data, off)
                off = off + 1
                if v >= 128 then v = v - 256 end
                deltas[di] = v
            end
        end
    end
    return deltas, off
end

--- Evaluate the scalar for a single tuple variation record.
---@param peak table  Peak coordinates (per axis)
---@param start_coord table|nil  Start coordinates
---@param end_coord table|nil  End coordinates
---@param norm_coords table  Normalized coordinates
---@param axis_count number
---@return number  scalar 0.0-1.0
function TtfParser._eval_tuple_scalar(peak, start_coord, end_coord, norm_coords, axis_count)
    local scalar = 1.0
    for a = 1, axis_count do
        local p = peak[a]
        local n = norm_coords[a] or 0
        if p == 0 then
            -- This axis has no effect
        elseif n == 0 then
            return 0
        elseif n == p then
            -- Full contribution
        else
            local s = start_coord and start_coord[a] or (p < 0 and -1 or 0)
            local e = end_coord and end_coord[a] or (p > 0 and 1 or 0)
            if p < 0 then
                -- Negative peak: swap sense
                if n > p then
                    if n >= e then return 0 end
                    scalar = scalar * (n - e) / (p - e)
                else
                    if n <= s then return 0 end
                    scalar = scalar * (n - s) / (p - s)
                end
            else
                if n < p then
                    if n <= s then return 0 end
                    scalar = scalar * (n - s) / (p - s)
                else
                    if n >= e then return 0 end
                    scalar = scalar * (e - n) / (e - p)
                end
            end
        end
    end
    return scalar
end

--- Read a packed point number array from gvar serialized data.
--- Returns nil (meaning "all points") + new offset when count is 0.
---@param data string
---@param off number  0-based offset
---@return table|nil  array of 0-based point indices, or nil for "all points"
---@return number     new offset after reading
function TtfParser._read_packed_points(data, off)
    local first = read_uint8(data, off)
    off = off + 1

    local count
    if band(first, 0x80) ~= 0 then
        -- Two-byte count
        local second = read_uint8(data, off)
        off = off + 1
        count = bor(lshift(band(first, 0x7F), 8), second)
    else
        count = band(first, 0x7F)
    end

    if count == 0 then
        return nil, off  -- "all points"
    end

    -- Read packed point indices (cumulative deltas)
    local points = {}
    local pi = 0
    local prev = 0
    while pi < count do
        local ctrl = read_uint8(data, off)
        off = off + 1
        local run_count = band(ctrl, 0x7F) + 1
        local use_words = band(ctrl, 0x80) ~= 0

        for _ = 1, run_count do
            if pi >= count then break end
            pi = pi + 1
            local delta
            if use_words then
                delta = read_uint16(data, off)
                off = off + 2
            else
                delta = read_uint8(data, off)
                off = off + 1
            end
            prev = prev + delta
            points[pi] = prev
        end
    end

    return points, off
end

--- IUP (Interpolate Untouched Points) for one axis along a contour.
--- OpenType spec: when gvar uses sparse point indices, points not in
--- the index list must have their deltas inferred from neighboring
--- touched points along the same contour.
---@param coords table  Original coordinate array (0-indexed, before deltas)
---@param deltas table  Accumulated delta array (0-indexed), modified in-place
---@param touched table  touched[p] = true for explicitly delta'd points
---@param first number  First point index of contour (0-indexed)
---@param last number   Last point index of contour (0-indexed)
local function iup_contour(coords, deltas, touched, first, last)
    if first > last then return end
    local n = last - first + 1
    if n < 2 then return end

    -- Find first touched point in this contour
    local first_touched = nil
    for i = first, last do
        if touched[i] then first_touched = i; break end
    end
    if not first_touched then return end  -- no touched points: deltas stay 0

    -- Walk pairs of consecutive touched points, interpolating between them
    local pt = first_touched
    while true do
        -- Find next touched point (wrapping)
        local next_t = nil
        local j = pt + 1
        if j > last then j = first end
        while j ~= pt do
            if touched[j] then next_t = j; break end
            j = j + 1
            if j > last then j = first end
        end
        if not next_t then break end  -- only one touched point

        -- Interpolate untouched points between pt and next_t
        local i = pt + 1
        if i > last then i = first end
        while i ~= next_t do
            if not touched[i] then
                local c  = coords[i]
                local c1 = coords[pt]
                local c2 = coords[next_t]
                local d1 = deltas[pt]
                local d2 = deltas[next_t]
                if c1 == c2 then
                    -- Same coordinate: average the deltas
                    deltas[i] = (d1 + d2) / 2
                elseif c <= c1 and c <= c2 then
                    -- Before both: use the delta of the nearer one
                    deltas[i] = (c1 < c2) and d1 or d2
                elseif c >= c1 and c >= c2 then
                    -- After both: use the delta of the nearer one
                    deltas[i] = (c1 > c2) and d1 or d2
                else
                    -- Between: linear interpolation
                    local t
                    if c1 < c2 then
                        t = (c - c1) / (c2 - c1)
                    else
                        t = (c - c2) / (c1 - c2)
                        d1, d2 = d2, d1
                    end
                    deltas[i] = d1 + t * (d2 - d1)
                end
            end
            i = i + 1
            if i > last then i = first end
        end

        pt = next_t
        if pt == first_touched then break end
    end
end

--- Apply gvar deltas to glyph point coordinates.
---@param gvar table  Parsed gvar data
---@param glyph_index number
---@param xs table  X coordinates (0-indexed)
---@param ys table  Y coordinates (0-indexed)
---@param num_points number  Number of outline points
---@param norm_coords table  Normalized variation coordinates
---@param end_pts table|nil  Contour end points for IUP
---@return number|nil  varied advance width from phantom points
function TtfParser._apply_gvar(gvar, glyph_index, xs, ys, num_points, norm_coords, hmtx_aw, lsb, end_pts)
    if not gvar then return nil end
    if glyph_index >= gvar.glyphCount then return nil end

    local off_start = gvar.offsets[glyph_index]
    local off_end   = gvar.offsets[glyph_index + 1]
    if off_start == off_end then return nil end  -- no variation data

    local data = gvar.data
    local off = gvar.dataOffset + off_start
    local axis_count = gvar.axisCount

    -- Add 4 phantom points: origin, advance, top, bottom
    local total_pts = num_points + 4
    xs[num_points]     = 0            -- phantom 0: origin x
    ys[num_points]     = 0            -- phantom 0: origin y
    xs[num_points + 1] = hmtx_aw or 0 -- phantom 1: advance x
    ys[num_points + 1] = 0            -- phantom 1: advance y
    xs[num_points + 2] = 0            -- phantom 2: top x
    ys[num_points + 2] = 0            -- phantom 2: top y
    xs[num_points + 3] = 0            -- phantom 3: bottom x
    ys[num_points + 3] = 0            -- phantom 3: bottom y

    -- Read tuple variation header
    local tuple_count_raw = read_uint16(data, off)
    local data_off_base   = read_uint16(data, off + 2)
    off = off + 4

    local tuple_count = band(tuple_count_raw, 0x0FFF)
    local shared_points = nil
    local serial_off = gvar.dataOffset + off_start + data_off_base

    -- Parse shared point numbers (advances serial_off past them)
    if band(tuple_count_raw, 0x8000) ~= 0 then
        shared_points, serial_off = TtfParser._read_packed_points(data, serial_off)
    end

    for _ = 1, tuple_count do
        local var_size = read_uint16(data, off)
        local tup_idx  = read_uint16(data, off + 2)
        off = off + 4

        -- Determine peak coordinates
        local peak
        local start_coord, end_coord

        if band(tup_idx, 0x8000) ~= 0 then
            -- Embedded peak coordinates
            peak = {}
            for a = 1, axis_count do
                peak[a] = read_f2dot14(data, off)
                off = off + 2
            end
        else
            -- Reference shared tuple
            local idx = band(tup_idx, 0x0FFF) + 1
            peak = gvar.sharedTuples[idx]
        end

        if band(tup_idx, 0x4000) ~= 0 then
            -- Intermediate region: read start and end coords
            start_coord = {}
            for a = 1, axis_count do
                start_coord[a] = read_f2dot14(data, off)
                off = off + 2
            end
            end_coord = {}
            for a = 1, axis_count do
                end_coord[a] = read_f2dot14(data, off)
                off = off + 2
            end
        end

        if peak then
            local scalar = TtfParser._eval_tuple_scalar(
                peak, start_coord, end_coord, norm_coords, axis_count)

            if scalar ~= 0 then
                local pts_off = serial_off
                local point_indices = nil
                local has_private = band(tup_idx, 0x2000) ~= 0

                -- Parse private or use shared point numbers
                if has_private then
                    point_indices, pts_off = TtfParser._read_packed_points(data, pts_off)
                else
                    point_indices = shared_points
                end

                -- Unpack deltas: count matches point list, or all points
                local delta_count = point_indices and #point_indices or total_pts
                local dx, new_off = TtfParser._unpack_deltas(data, pts_off, delta_count)
                local dy
                dy, new_off = TtfParser._unpack_deltas(data, new_off, delta_count)

                -- Apply scaled deltas
                if point_indices then
                    -- Sparse: apply deltas to specified points, then IUP
                    -- for untouched points along each contour.
                    local dx_acc = {}  -- accumulated x-deltas (0-indexed)
                    local dy_acc = {}  -- accumulated y-deltas (0-indexed)
                    local touched = {} -- which points got explicit deltas
                    for p = 0, total_pts - 1 do
                        dx_acc[p] = 0
                        dy_acc[p] = 0
                    end
                    for i = 1, #point_indices do
                        local p = point_indices[i]
                        if p < total_pts then
                            dx_acc[p] = (dx[i] or 0) * scalar
                            dy_acc[p] = (dy[i] or 0) * scalar
                            touched[p] = true
                        end
                    end
                    -- IUP: interpolate untouched points per contour
                    if end_pts then
                        local contour_start = 0
                        for ci = 1, #end_pts do
                            local contour_end = end_pts[ci]
                            iup_contour(xs, dx_acc, touched, contour_start, contour_end)
                            iup_contour(ys, dy_acc, touched, contour_start, contour_end)
                            contour_start = contour_end + 1
                        end
                        -- Phantom points (after last contour): if not touched, infer 0
                    end
                    -- Apply accumulated (explicit + IUP-interpolated) deltas
                    for p = 0, total_pts - 1 do
                        xs[p] = xs[p] + dx_acc[p]
                        ys[p] = ys[p] + dy_acc[p]
                    end
                else
                    -- Dense: apply to all points (no IUP needed)
                    for p = 0, total_pts - 1 do
                        if dx[p + 1] then
                            xs[p] = xs[p] + dx[p + 1] * scalar
                        end
                        if dy[p + 1] then
                            ys[p] = ys[p] + dy[p + 1] * scalar
                        end
                    end
                end
            end
        end

        serial_off = serial_off + var_size
    end

    -- Extract varied advance from phantom point 1
    local var_advance = xs[num_points + 1] - xs[num_points]

    -- Remove phantom points
    for i = num_points, num_points + 3 do
        xs[i] = nil
        ys[i] = nil
    end

    return var_advance
end

------------------------------------------------------------
-- Glyph outline parsing
------------------------------------------------------------

local function composite_bbox_from_polylines(polylines)
    if not polylines or #polylines == 0 then return nil end
    local x_min, x_max = 1e9, -1e9
    local y_down_min, y_down_max = 1e9, -1e9
    local seen = false
    for pi = 1, #polylines do
        local poly = polylines[pi]
        for i = 1, #poly do
            local pt = poly[i]
            local x, y = pt.x, pt.y
            if x < x_min then x_min = x end
            if x > x_max then x_max = x end
            if y < y_down_min then y_down_min = y end
            if y > y_down_max then y_down_max = y end
            seen = true
        end
    end
    if not seen then return nil end
    return {
        xMin = x_min,
        yMin = -y_down_max,
        xMax = x_max,
        yMax = -y_down_min,
    }
end

--- Parse a single glyph from the glyf table.
--- Handles both simple and composite glyphs.
--- Returns polylines in the same format as SvgParser:
---   { { {x=,y=}, {x=,y=}, ... }, ... }
--- and bbox {xMin, yMin, xMax, yMax}.
---
--- Coordinates are in font units with Y-axis flipped
--- (positive Y = down) to match screen coordinates.
---
---@param data string
---@param tables table
---@param loca table      Glyph offset array from parse_loca
---@param glyph_index number
---@param unitsPerEm number  For Bezier flattening tolerance
---@param gvar_data table|nil  Parsed gvar data for variable fonts
---@param norm_coords table|nil  Normalized variation coordinates
---@param hmtx table|nil  hmtx table for phantom points
---@return table|nil polylines
---@return table|nil bbox  {xMin, yMin, xMax, yMax}
---@return number|nil var_advance  Varied advance width (font units)
function TtfParser.parse_glyph(data, tables, loca, glyph_index, unitsPerEm, gvar_data, norm_coords, hmtx, font, composite_depth)
    local glyf_table = tables["glyf"]

    -- Route to CFF path if no glyf table but CFF data is available
    if not glyf_table then
        if font and font.cff then
            return TtfParser._parse_cff_glyph(data, font, glyph_index, unitsPerEm)
        end
        return nil, nil
    end

    -- Check for empty glyph (e.g. space)
    if not loca[glyph_index] or not loca[glyph_index + 1] then
        return nil, nil
    end
    if loca[glyph_index] == loca[glyph_index + 1] then
        return nil, nil  -- zero-length glyph (space, etc.)
    end

    local glyf_off = glyf_table.offset + loca[glyph_index]
    local num_contours = read_int16(data, glyf_off)
    local xMin = read_int16(data, glyf_off + 2)
    local yMin = read_int16(data, glyf_off + 4)
    local xMax = read_int16(data, glyf_off + 6)
    local yMax = read_int16(data, glyf_off + 8)

    local tol = (unitsPerEm or 1000) / 200

    -- Get hmtx advance for phantom points
    local hmtx_aw = 0
    local hmtx_lsb = 0
    if hmtx and hmtx[glyph_index] then
        hmtx_aw = hmtx[glyph_index].advanceWidth
        hmtx_lsb = hmtx[glyph_index].lsb
    end

    if num_contours >= 0 then
        -- Simple glyph
        local polylines, var_advance, var_bbox, glyph_descriptor = TtfParser._parse_simple_glyph(
            data, glyf_off, num_contours, tol, gvar_data, norm_coords, glyph_index, hmtx_aw, hmtx_lsb)
        local bbox = var_bbox or { xMin = xMin, yMin = yMin, xMax = xMax, yMax = yMax }
        return polylines, bbox, var_advance, glyph_descriptor
    else
        -- Composite glyph: resolve component outlines with the same variation
        -- coordinates so variable-font composites (for example Inter's "i")
        -- match the requested weight/optical size.
        local polylines, glyph_descriptor = TtfParser._parse_composite_glyph(
            data, tables, loca, glyf_off, unitsPerEm, gvar_data, norm_coords, hmtx, font,
            glyph_index, composite_depth or 0)
        local bbox = composite_bbox_from_polylines(polylines)
            or { xMin = xMin, yMin = yMin, xMax = xMax, yMax = yMax }
        return polylines, bbox, nil, glyph_descriptor
    end
end

------------------------------------------------------------
-- Simple glyph parsing
------------------------------------------------------------

--- Parse a simple glyph's contours into polylines.
---@param data string
---@param glyf_off number  Offset to the glyph header
---@param num_contours number
---@param tol number  Bezier flattening tolerance
---@param gvar_data table|nil  gvar data for variable fonts
---@param norm_coords table|nil  normalized variation coordinates
---@param glyph_index number|nil  glyph index for gvar lookup
---@param hmtx_aw number|nil  advance width from hmtx
---@param hmtx_lsb number|nil  left side bearing from hmtx
---@return table  Polylines array
---@return number|nil  var_advance (varied advance width in font units)
function TtfParser._parse_simple_glyph(data, glyf_off, num_contours, tol, gvar_data, norm_coords, glyph_index, hmtx_aw, hmtx_lsb)
    if num_contours == 0 then
        return {}, nil, nil, {
            kind = "simple",
            points = {},
            end_pts = {},
            instructions = "",
            bbox = {
                xMin = read_int16(data, glyf_off + 2) or 0,
                yMin = read_int16(data, glyf_off + 4) or 0,
                xMax = read_int16(data, glyf_off + 6) or 0,
                yMax = read_int16(data, glyf_off + 8) or 0,
            },
        }
    end

    -- Read endPtsOfContours
    local end_pts = {}
    local off = glyf_off + 10
    for i = 1, num_contours do
        end_pts[i] = read_uint16(data, off)
        off = off + 2
    end

    local num_points = end_pts[num_contours] + 1

    -- Capture instructions for the TrueType VM. Existing callers still
    -- receive flattened outlines; the descriptor is an extra return value.
    local instruction_len = read_uint16(data, off)
    local instructions = ""
    if instruction_len and instruction_len > 0 then
        instructions = data:sub(off + 3, off + 2 + instruction_len)
    end
    off = off + 2 + (instruction_len or 0)

    -- Read flags
    local flags = {}
    local fi = 0
    while fi < num_points do
        local flag = read_uint8(data, off)
        off = off + 1
        flags[fi] = flag
        fi = fi + 1

        -- Repeat flag
        if band(flag, 0x08) ~= 0 then
            local repeat_count = read_uint8(data, off)
            off = off + 1
            for _ = 1, repeat_count do
                flags[fi] = flag
                fi = fi + 1
            end
        end
    end

    -- Read X coordinates
    local xs = {}
    local x = 0
    for i = 0, num_points - 1 do
        local flag = flags[i]
        if band(flag, 0x02) ~= 0 then
            -- x is 1 byte
            local dx = read_uint8(data, off)
            off = off + 1
            if band(flag, 0x10) == 0 then dx = -dx end
            x = x + dx
        elseif band(flag, 0x10) ~= 0 then
            -- x is same as previous (delta = 0)
        else
            -- x is 2 bytes signed
            x = x + read_int16(data, off)
            off = off + 2
        end
        xs[i] = x
    end

    -- Read Y coordinates
    local ys = {}
    local y = 0
    for i = 0, num_points - 1 do
        local flag = flags[i]
        if band(flag, 0x04) ~= 0 then
            -- y is 1 byte
            local dy = read_uint8(data, off)
            off = off + 1
            if band(flag, 0x20) == 0 then dy = -dy end
            y = y + dy
        elseif band(flag, 0x20) ~= 0 then
            -- y is same as previous (delta = 0)
        else
            -- y is 2 bytes signed
            y = y + read_int16(data, off)
            off = off + 2
        end
        ys[i] = y
    end

    -- Apply gvar deltas if variable font coordinates are provided
    local var_advance = nil
    local var_bbox = nil
    if gvar_data and norm_coords and glyph_index then
        var_advance = TtfParser._apply_gvar(
            gvar_data, glyph_index, xs, ys, num_points, norm_coords, hmtx_aw, hmtx_lsb, end_pts)
        -- Recompute bbox from varied coordinates (font units, Y-up)
        local bxMin, byMin = 1e9, 1e9
        local bxMax, byMax = -1e9, -1e9
        for i = 0, num_points - 1 do
            if xs[i] < bxMin then bxMin = xs[i] end
            if xs[i] > bxMax then bxMax = xs[i] end
            if ys[i] < byMin then byMin = ys[i] end
            if ys[i] > byMax then byMax = ys[i] end
        end
        var_bbox = { xMin = bxMin, yMin = byMin, xMax = bxMax, yMax = byMax }
    end

    local descriptor = {
        kind = "simple",
        points = {},
        end_pts = end_pts,
        instructions = instructions,
        bbox = var_bbox or {
            xMin = read_int16(data, glyf_off + 2) or 0,
            yMin = read_int16(data, glyf_off + 4) or 0,
            xMax = read_int16(data, glyf_off + 6) or 0,
            yMax = read_int16(data, glyf_off + 8) or 0,
        },
        phantom_points = {},
    }
    for i = 0, num_points - 1 do
        descriptor.points[i] = {
            x = xs[i],
            y = ys[i],
            on_curve = band(flags[i], 0x01) ~= 0,
            touched_x = false,
            touched_y = false,
            original_x = xs[i],
            original_y = ys[i],
            contour_index = nil,
        }
    end
    local contour_start_for_desc = 0
    for c = 1, num_contours do
        local contour_end = end_pts[c]
        for i = contour_start_for_desc, contour_end do
            descriptor.points[i].contour_index = c
        end
        contour_start_for_desc = contour_end + 1
    end

    -- Build polylines from contours, interpreting on/off curve points.
    -- TTF Y-axis: positive = up. We flip to positive = down for screen coords.
    local polylines = {}
    local pn = 0
    local contour_start = 0

    for c = 1, num_contours do
        local contour_end = end_pts[c]
        local n_pts = contour_end - contour_start + 1

        if n_pts >= 2 then
            -- Collect contour points with on-curve flags
            local pts = {}
            local on_curve = {}
            for i = 0, n_pts - 1 do
                local gi = contour_start + i
                pts[i] = { x = xs[gi], y = -ys[gi] }  -- flip Y
                on_curve[i] = band(flags[gi], 0x01) ~= 0
            end

            -- Walk contour and generate polyline
            local poly = {}
            local poly_n = 0

            -- Find first on-curve point, or create implied one
            local first_on_idx = nil
            for i = 0, n_pts - 1 do
                if on_curve[i] then
                    first_on_idx = i
                    break
                end
            end

            local start_pt
            if first_on_idx then
                start_pt = pts[first_on_idx]
            else
                -- All off-curve: implied on-curve between first two
                start_pt = {
                    x = (pts[0].x + pts[n_pts - 1].x) * 0.5,
                    y = (pts[0].y + pts[n_pts - 1].y) * 0.5,
                }
                first_on_idx = 0
            end

            poly_n = poly_n + 1
            poly[poly_n] = { x = start_pt.x, y = start_pt.y }

            local i = 0
            local cur_x, cur_y = start_pt.x, start_pt.y
            local visited = 0

            i = (first_on_idx + 1) % n_pts
            while visited < n_pts do
                if on_curve[i] then
                    -- Line to on-curve point
                    cur_x, cur_y = pts[i].x, pts[i].y
                    poly_n = poly_n + 1
                    poly[poly_n] = { x = cur_x, y = cur_y }
                    visited = visited + 1
                    i = (i + 1) % n_pts
                else
                    -- Off-curve point: look at next
                    local cp = pts[i]
                    local next_i = (i + 1) % n_pts
                    local end_pt

                    if on_curve[next_i] then
                        -- Next is on-curve: quadratic Bezier to it
                        end_pt = pts[next_i]
                        flatten_quad(cur_x, cur_y, cp.x, cp.y, end_pt.x, end_pt.y, poly, tol)
                        cur_x, cur_y = end_pt.x, end_pt.y
                        poly_n = #poly
                        visited = visited + 2
                        i = (next_i + 1) % n_pts
                    else
                        -- Next is also off-curve: implied on-curve midpoint
                        local mid_x = (cp.x + pts[next_i].x) * 0.5
                        local mid_y = (cp.y + pts[next_i].y) * 0.5
                        flatten_quad(cur_x, cur_y, cp.x, cp.y, mid_x, mid_y, poly, tol)
                        cur_x, cur_y = mid_x, mid_y
                        poly_n = #poly
                        visited = visited + 1
                        i = next_i
                    end
                end
            end

            -- Close contour
            if poly_n >= 3 then
                local first = poly[1]
                local last = poly[poly_n]
                if math_abs(last.x - first.x) > 0.01 or math_abs(last.y - first.y) > 0.01 then
                    poly_n = poly_n + 1
                    poly[poly_n] = { x = first.x, y = first.y }
                end
                pn = pn + 1
                polylines[pn] = poly
            end
        end

        contour_start = contour_end + 1
    end

    return polylines, var_advance, var_bbox, descriptor
end

local function descriptor_points_to_polylines(glyph_descriptor, tol)
    if not glyph_descriptor then return nil end
    local points = glyph_descriptor.points
    local end_pts = glyph_descriptor.end_pts
    if not points or not end_pts then return nil end
    tol = tol or 5

    local polylines = {}
    local pn = 0
    local contour_start = 0

    for c = 1, #end_pts do
        local contour_end = end_pts[c]
        local n_pts = contour_end - contour_start + 1
        if n_pts >= 2 then
            local pts = {}
            local on_curve = {}
            for i = 0, n_pts - 1 do
                local gi = contour_start + i
                local pt = points[gi]
                if not pt then return nil end
                pts[i] = { x = pt.x or 0, y = -(pt.y or 0) }
                on_curve[i] = pt.on_curve == true
            end

            local first_on_idx = nil
            for i = 0, n_pts - 1 do
                if on_curve[i] then
                    first_on_idx = i
                    break
                end
            end

            local start_pt
            if first_on_idx then
                start_pt = pts[first_on_idx]
            else
                start_pt = {
                    x = (pts[0].x + pts[n_pts - 1].x) * 0.5,
                    y = (pts[0].y + pts[n_pts - 1].y) * 0.5,
                }
                first_on_idx = 0
            end

            local poly = { { x = start_pt.x, y = start_pt.y } }
            local poly_n = 1
            local cur_x, cur_y = start_pt.x, start_pt.y
            local i = (first_on_idx + 1) % n_pts
            local visited = 0

            while visited < n_pts do
                if on_curve[i] then
                    cur_x, cur_y = pts[i].x, pts[i].y
                    poly_n = poly_n + 1
                    poly[poly_n] = { x = cur_x, y = cur_y }
                    visited = visited + 1
                    i = (i + 1) % n_pts
                else
                    local cp = pts[i]
                    local next_i = (i + 1) % n_pts
                    if on_curve[next_i] then
                        local end_pt = pts[next_i]
                        flatten_quad(cur_x, cur_y, cp.x, cp.y, end_pt.x, end_pt.y, poly, tol)
                        cur_x, cur_y = end_pt.x, end_pt.y
                        poly_n = #poly
                        visited = visited + 2
                        i = (next_i + 1) % n_pts
                    else
                        local mid_x = (cp.x + pts[next_i].x) * 0.5
                        local mid_y = (cp.y + pts[next_i].y) * 0.5
                        flatten_quad(cur_x, cur_y, cp.x, cp.y, mid_x, mid_y, poly, tol)
                        cur_x, cur_y = mid_x, mid_y
                        poly_n = #poly
                        visited = visited + 1
                        i = next_i
                    end
                end
            end

            if poly_n >= 3 then
                local first = poly[1]
                local last = poly[poly_n]
                if math_abs(last.x - first.x) > 0.01 or math_abs(last.y - first.y) > 0.01 then
                    poly_n = poly_n + 1
                    poly[poly_n] = { x = first.x, y = first.y }
                end
                pn = pn + 1
                polylines[pn] = poly
            end
        end
        contour_start = contour_end + 1
    end

    return polylines
end

--- Convert a hinted glyph point-zone descriptor back to current polylines.
---@param glyph_descriptor table
---@param tol number|nil
---@return table|nil
function TtfParser.hinted_zones_to_polylines(glyph_descriptor, tol)
    return descriptor_points_to_polylines(glyph_descriptor, tol)
end

------------------------------------------------------------
-- Composite glyph parsing
------------------------------------------------------------

function TtfParser.get_use_my_metrics_glyph(font, glyph_index)
    if not font or not font.tables or not font.loca or not font.data then return nil end
    local glyf_table = font.tables["glyf"]
    if not glyf_table then return nil end
    if not font.loca[glyph_index] or not font.loca[glyph_index + 1] then return nil end
    if font.loca[glyph_index] == font.loca[glyph_index + 1] then return nil end

    local glyf_off = glyf_table.offset + font.loca[glyph_index]
    local num_contours = read_int16(font.data, glyf_off)
    if num_contours ~= -1 then return nil end

    local off = glyf_off + 10
    local ARG_1_AND_2_WORDS = 0x0001
    local MORE_COMPONENTS   = 0x0020
    local WE_HAVE_A_SCALE   = 0x0008
    local WE_HAVE_XY_SCALE  = 0x0040
    local WE_HAVE_2X2       = 0x0080
    local USE_MY_METRICS    = 0x0200

    local metrics_glyph = nil
    local has_more = true
    while has_more do
        local comp_flags = read_uint16(font.data, off)
        local comp_glyph = read_uint16(font.data, off + 2)
        if not comp_flags or not comp_glyph then return metrics_glyph end
        off = off + 4
        if band(comp_flags, USE_MY_METRICS) ~= 0 then
            metrics_glyph = comp_glyph
        end
        if band(comp_flags, ARG_1_AND_2_WORDS) ~= 0 then
            off = off + 4
        else
            off = off + 2
        end
        if band(comp_flags, WE_HAVE_A_SCALE) ~= 0 then
            off = off + 2
        elseif band(comp_flags, WE_HAVE_XY_SCALE) ~= 0 then
            off = off + 4
        elseif band(comp_flags, WE_HAVE_2X2) ~= 0 then
            off = off + 8
        end
        has_more = band(comp_flags, MORE_COMPONENTS) ~= 0
    end
    return metrics_glyph
end

--- Parse a composite glyph, recursively resolving components.
---@param data string
---@param tables table
---@param loca table
---@param glyf_off number
---@param unitsPerEm number
---@param gvar_data table|nil
---@param norm_coords table|nil
---@param hmtx table|nil
---@param font table|nil
---@return table  Polylines array
function TtfParser._parse_composite_glyph(data, tables, loca, glyf_off, unitsPerEm, gvar_data, norm_coords, hmtx, font, glyph_index, depth)
    depth = depth or 0
    local tol = (unitsPerEm or 1000) / 200
    local max_depth = 16
    local fallback_polylines = {}
    local fallback_poly_count = 0

    local descriptor = {
        kind = "composite",
        glyph_index = glyph_index,
        composite_depth = depth,
        max_component_depth = depth,
        components = {},
        points = {},
        end_pts = {},
        instructions = "",
        bbox = {
            xMin = read_int16(data, glyf_off + 2) or 0,
            yMin = read_int16(data, glyf_off + 4) or 0,
            xMax = read_int16(data, glyf_off + 6) or 0,
            yMax = read_int16(data, glyf_off + 8) or 0,
        },
        use_my_metrics_glyph = nil,
        overlap_compound = false,
        telemetry = nil,
    }

    if depth >= max_depth then
        descriptor.telemetry = { fail_reason = "composite_depth_exceeded" }
        return {}, descriptor
    end

    local off = glyf_off + 10  -- skip header

    local ARG_1_AND_2_WORDS = 0x0001
    local ARGS_ARE_XY       = 0x0002
    local ROUND_XY_TO_GRID  = 0x0004
    local WE_HAVE_A_SCALE   = 0x0008
    local MORE_COMPONENTS   = 0x0020
    local WE_HAVE_XY_SCALE  = 0x0040
    local WE_HAVE_2X2       = 0x0080
    local WE_HAVE_INSTRUCTIONS = 0x0100
    local USE_MY_METRICS    = 0x0200
    local OVERLAP_COMPOUND  = 0x0400

    local point_count = 0
    local contour_count = 0

    local function append_component_points(comp_desc, component_meta)
        if not comp_desc or not comp_desc.points then return end
        local start_index = point_count
        local contour_offset = contour_count

        local a = component_meta.transform.a
        local b = component_meta.transform.b
        local c_val = component_meta.transform.c
        local d = component_meta.transform.d
        local dx = component_meta.dx or 0
        local dy = component_meta.dy or 0

        if not component_meta.args_are_xy then
            local parent_point = descriptor.points[component_meta.arg1]
            local component_point = comp_desc.points[component_meta.arg2]
            if parent_point and component_point then
                local tx = a * component_point.x + c_val * component_point.y
                local ty = b * component_point.x + d * component_point.y
                dx = parent_point.x - tx
                dy = parent_point.y - ty
                component_meta.dx = dx
                component_meta.dy = dy
            else
                component_meta.dx = 0
                component_meta.dy = 0
                dx, dy = 0, 0
            end
        end

        if component_meta.round_xy_to_grid then
            dx = round_nearest(dx)
            dy = round_nearest(dy)
            component_meta.dx = dx
            component_meta.dy = dy
        end

        for i = 0, component_meta.point_count - 1 do
            local src = comp_desc.points[i]
            if src then
                descriptor.points[start_index + i] = {
                    x = a * (src.x or 0) + c_val * (src.y or 0) + dx,
                    y = b * (src.x or 0) + d * (src.y or 0) + dy,
                    on_curve = src.on_curve == true,
                    touched_x = false,
                    touched_y = false,
                    original_x = a * (src.x or 0) + c_val * (src.y or 0) + dx,
                    original_y = b * (src.x or 0) + d * (src.y or 0) + dy,
                    contour_index = (src.contour_index or 1) + contour_offset,
                }
            end
        end

        for i = 1, #(comp_desc.end_pts or {}) do
            descriptor.end_pts[contour_count + i] = start_index + comp_desc.end_pts[i]
        end

        point_count = point_count + component_meta.point_count
        contour_count = contour_count + #(comp_desc.end_pts or {})
    end

    local last_flags = 0
    local has_more = true
    while has_more do
        local comp_flags = read_uint16(data, off)
        local glyph_idx  = read_uint16(data, off + 2)
        last_flags = comp_flags or 0
        off = off + 4

        -- Read translation
        local dx, dy
        local arg1, arg2
        if band(comp_flags, ARG_1_AND_2_WORDS) ~= 0 then
            if band(comp_flags, ARGS_ARE_XY) ~= 0 then
                dx = read_int16(data, off)
                dy = read_int16(data, off + 2)
                arg1 = dx
                arg2 = dy
            else
                arg1 = read_uint16(data, off)
                arg2 = read_uint16(data, off + 2)
                dx = arg1
                dy = arg2
            end
            off = off + 4
        else
            if band(comp_flags, ARGS_ARE_XY) ~= 0 then
                -- Signed byte pair
                dx = read_uint8(data, off)
                if dx >= 128 then dx = dx - 256 end
                dy = read_uint8(data, off + 1)
                if dy >= 128 then dy = dy - 256 end
                arg1 = dx
                arg2 = dy
            else
                arg1 = read_uint8(data, off)
                arg2 = read_uint8(data, off + 1)
                dx = arg1
                dy = arg2
            end
            off = off + 2
        end

        -- Read transform matrix components. Stored using the TrueType
        -- convention: x' = a*x + c*y + dx, y' = b*x + d*y + dy.
        local a, b, c_val, d = 1, 0, 0, 1
        if band(comp_flags, WE_HAVE_A_SCALE) ~= 0 then
            a = read_int16(data, off) / 16384  -- F2Dot14
            d = a
            off = off + 2
        elseif band(comp_flags, WE_HAVE_XY_SCALE) ~= 0 then
            a = read_int16(data, off) / 16384
            d = read_int16(data, off + 2) / 16384
            off = off + 4
        elseif band(comp_flags, WE_HAVE_2X2) ~= 0 then
            a     = read_int16(data, off) / 16384
            b     = read_int16(data, off + 2) / 16384
            c_val = read_int16(data, off + 4) / 16384
            d     = read_int16(data, off + 6) / 16384
            off = off + 8
        end

        if band(comp_flags, ARGS_ARE_XY) ~= 0 and band(comp_flags, ROUND_XY_TO_GRID) ~= 0 then
            dx = round_nearest(dx)
            dy = round_nearest(dy)
        end

        if band(comp_flags, USE_MY_METRICS) ~= 0 then
            descriptor.use_my_metrics_glyph = glyph_idx
        end
        if band(comp_flags, OVERLAP_COMPOUND) ~= 0 then
            descriptor.overlap_compound = true
        end

        local component_meta = {
            flags = comp_flags,
            glyph_index = glyph_idx,
            arg1 = arg1,
            arg2 = arg2,
            dx = dx,
            dy = dy,
            transform = { a = a, b = b, c = c_val, d = d },
            args_are_xy = band(comp_flags, ARGS_ARE_XY) ~= 0,
            round_xy_to_grid = band(comp_flags, ROUND_XY_TO_GRID) ~= 0,
            use_my_metrics = band(comp_flags, USE_MY_METRICS) ~= 0,
            overlap_compound = band(comp_flags, OVERLAP_COMPOUND) ~= 0,
            point_start = point_count,
            contour_start = contour_count + 1,
            point_count = 0,
        }
        descriptor.components[#descriptor.components + 1] = component_meta

        -- Recursively parse the component glyph with variation state intact.
        local _comp_polys, _comp_bbox, _comp_advance, comp_desc = TtfParser.parse_glyph(
            data, tables, loca, glyph_idx, unitsPerEm, gvar_data, norm_coords, hmtx, font, depth + 1)
        if comp_desc and comp_desc.telemetry and comp_desc.telemetry.fail_reason then
            descriptor.telemetry = comp_desc.telemetry
        elseif not comp_desc and _comp_polys then
            -- Kept for compatibility with third-party callers that monkey-patch
            -- parse_glyph to return legacy polylines without descriptors.
            for pi = 1, #_comp_polys do
                local poly = _comp_polys[pi]
                local transformed = {}
                for pt_i = 1, #poly do
                    local px = poly[pt_i].x
                    local py = poly[pt_i].y
                    transformed[pt_i] = {
                        x = a * px - b * py + dx,
                        y = -c_val * px + d * py - dy,
                    }
                end
                fallback_poly_count = fallback_poly_count + 1
                fallback_polylines[fallback_poly_count] = transformed
            end
        else
            local comp_point_count = 0
            if comp_desc and comp_desc.points then
                for k in pairs(comp_desc.points) do
                    if type(k) == "number" then comp_point_count = math_max(comp_point_count, k + 1) end
                end
            end
            component_meta.point_count = comp_point_count
            if comp_desc and comp_desc.max_component_depth then
                descriptor.max_component_depth = math_max(descriptor.max_component_depth, comp_desc.max_component_depth)
            else
                descriptor.max_component_depth = math_max(descriptor.max_component_depth, depth + 1)
            end
            append_component_points(comp_desc, component_meta)
        end

        has_more = band(comp_flags, MORE_COMPONENTS) ~= 0
    end

    if band(last_flags, WE_HAVE_INSTRUCTIONS) ~= 0 then
        local instruction_len = read_uint16(data, off) or 0
        if instruction_len > 0 then
            descriptor.instructions = data:sub(off + 3, off + 2 + instruction_len)
        end
    end

    local xMin, yMin, xMax, yMax = 1e9, 1e9, -1e9, -1e9
    for k, pt in pairs(descriptor.points) do
        if type(k) == "number" then
            if pt.x < xMin then xMin = pt.x end
            if pt.x > xMax then xMax = pt.x end
            if pt.y < yMin then yMin = pt.y end
            if pt.y > yMax then yMax = pt.y end
        end
    end
    if xMin < xMax and yMin < yMax then
        descriptor.bbox = { xMin = xMin, yMin = yMin, xMax = xMax, yMax = yMax }
    end

    local polylines = descriptor_points_to_polylines(descriptor, tol)
    if polylines and #polylines > 0 then
        return polylines, descriptor
    end
    return fallback_polylines, descriptor
end

------------------------------------------------------------
-- CFF (Compact Font Format) support
------------------------------------------------------------

--- Read a CFF INDEX structure.
--- An INDEX has: count (uint16), offSize (uint8), offsets[count+1], data[].
---@param data string  Raw font data
---@param off number   0-based offset to the INDEX
---@return table  { count, items = { string1, ... }, end_off }
function TtfParser._read_cff_index(data, off)
    local count = read_uint16(data, off)
    if count == 0 then
        return { count = 0, items = {}, end_off = off + 2 }
    end

    local off_size = read_uint8(data, off + 2)
    local offsets = {}

    -- Read count+1 offsets (1-based in the spec)
    for i = 0, count do
        local o = 0
        local base = off + 3 + i * off_size
        for b = 0, off_size - 1 do
            o = o * 256 + read_uint8(data, base + b)
        end
        offsets[i] = o
    end

    local data_start = off + 3 + (count + 1) * off_size - 1  -- -1 because offsets are 1-based

    local items = {}
    for i = 0, count - 1 do
        local item_off = data_start + offsets[i]
        local item_len = offsets[i + 1] - offsets[i]
        items[i] = { offset = item_off, length = item_len }
    end

    local end_off = data_start + offsets[count]

    return { count = count, items = items, end_off = end_off }
end

--- Decode a CFF DICT from binary data.
--- Stack-based encoding: operands push numbers, operators consume them.
---@param data string
---@param off number   0-based offset
---@param len number   length in bytes
---@return table  Dictionary of key -> value(s)
function TtfParser._parse_cff_dict(data, off, len)
    local result = {}
    local stack = {}
    local sp = 0
    local end_off = off + len

    while off < end_off do
        local b0 = read_uint8(data, off)

        if b0 >= 32 and b0 <= 246 then
            -- Single-byte integer: value = b0 - 139
            sp = sp + 1
            stack[sp] = b0 - 139
            off = off + 1
        elseif b0 >= 247 and b0 <= 250 then
            -- Two-byte positive: (b0-247)*256 + b1 + 108
            local b1 = read_uint8(data, off + 1)
            sp = sp + 1
            stack[sp] = (b0 - 247) * 256 + b1 + 108
            off = off + 2
        elseif b0 >= 251 and b0 <= 254 then
            -- Two-byte negative: -(b0-251)*256 - b1 - 108
            local b1 = read_uint8(data, off + 1)
            sp = sp + 1
            stack[sp] = -(b0 - 251) * 256 - b1 - 108
            off = off + 2
        elseif b0 == 28 then
            -- 16-bit signed integer
            sp = sp + 1
            stack[sp] = read_int16(data, off + 1)
            off = off + 3
        elseif b0 == 29 then
            -- 32-bit signed integer
            local v = read_uint32(data, off + 1)
            if v >= 0x80000000 then v = v - 0x100000000 end
            sp = sp + 1
            stack[sp] = v
            off = off + 5
        elseif b0 == 30 then
            -- Real number (BCD encoded) -" read nibbles until 0xF terminator
            off = off + 1
            local s = ""
            local done = false
            while not done and off < end_off do
                local byte = read_uint8(data, off)
                off = off + 1
                for _, nibble in ipairs({ rshift(byte, 4), band(byte, 0x0F) }) do
                    if nibble <= 9 then
                        s = s .. tostring(nibble)
                    elseif nibble == 0x0A then
                        s = s .. "."
                    elseif nibble == 0x0B then
                        s = s .. "E"
                    elseif nibble == 0x0C then
                        s = s .. "E-"
                    elseif nibble == 0x0E then
                        s = s .. "-"
                    elseif nibble == 0x0F then
                        done = true
                        break
                    end
                end
            end
            sp = sp + 1
            stack[sp] = tonumber(s) or 0
        elseif b0 == 12 then
            -- Two-byte operator: 12 XX
            local b1 = read_uint8(data, off + 1)
            off = off + 2
            local key = 1200 + b1  -- encode as 12xx
            if sp == 1 then
                result[key] = stack[1]
            else
                local vals = {}
                for i = 1, sp do vals[i] = stack[i] end
                result[key] = vals
            end
            sp = 0
        else
            -- Single-byte operator
            off = off + 1
            if sp == 1 then
                result[b0] = stack[1]
            else
                local vals = {}
                for i = 1, sp do vals[i] = stack[i] end
                result[b0] = vals
            end
            sp = 0
        end
    end

    return result
end

--- Compute subroutine bias per the CFF spec.
---@param count number  Number of subroutines
---@return number
local function cff_subr_bias(count)
    if count < 1240 then return 107
    elseif count < 33900 then return 1131
    else return 32768
    end
end

--- Interpret a Type 2 charstring and produce polylines.
--- This is a stack-based VM that processes PostScript charstring bytecode.
---@param data string      Raw font data
---@param cs_off number    0-based offset to charstring
---@param cs_len number    Length of charstring
---@param gsubrs table     Global subroutine INDEX items
---@param gsubr_bias number
---@param lsubrs table     Local subroutine INDEX items
---@param lsubr_bias number
---@param default_w number Default glyph width
---@param nominal_w number Nominal width
---@param tol number       Bezier flattening tolerance
---@return table  polylines
---@return number width
function TtfParser._interpret_charstring(data, cs_off, cs_len, gsubrs, gsubr_bias, lsubrs, lsubr_bias, default_w, nominal_w, tol)
    local stack = {}
    local sp = 0
    local polylines = {}
    local pn = 0
    local poly = nil   -- current contour polyline
    local x, y = 0, 0  -- current point (font units, Y-up)
    local width = default_w
    local width_parsed = false
    local n_stems = 0

    -- Call stack for subroutines
    local call_stack = {}
    local call_sp = 0

    -- Current execution state
    local cur_data = data
    local cur_off = cs_off
    local cur_end = cs_off + cs_len

    --- Start a new contour at the current (x, y), flipping Y for screen coords.
    local function new_contour()
        if poly and #poly >= 3 then
            -- Close previous contour
            local first = poly[1]
            local last = poly[#poly]
            if math_abs(last.x - first.x) > 0.01 or math_abs(last.y - first.y) > 0.01 then
                poly[#poly + 1] = { x = first.x, y = first.y }
            end
            pn = pn + 1
            polylines[pn] = poly
        end
        poly = { { x = x, y = -y } }
    end

    --- Add a line-to point, flipping Y.
    local function line_to(tx, ty)
        x, y = tx, ty
        poly[#poly + 1] = { x = x, y = -y }
    end

    --- Add a cubic curve, flipping Y for output.
    local function curve_to(c1x, c1y, c2x, c2y, px, py)
        flatten_cubic(x, -y, c1x, -c1y, c2x, -c2y, px, -py, poly, tol)
        x, y = px, py
    end

    --- Check for optional width operand before first draw operator.
    local function check_width(expected_args)
        if not width_parsed then
            width_parsed = true
            if sp > expected_args then
                -- First extra arg is the width delta
                width = nominal_w + stack[1]
                -- Shift stack down
                for i = 1, sp - 1 do
                    stack[i] = stack[i + 1]
                end
                sp = sp - 1
            end
        end
    end

    --- Skip hint mask bytes based on stem count.
    local function skip_hint_mask()
        local n_bytes = math_floor((n_stems + 7) / 8)
        cur_off = cur_off + n_bytes
    end

    while true do
        if cur_off >= cur_end then
            -- End of current charstring data
            if call_sp > 0 then
                -- Return from subroutine
                local frame = call_stack[call_sp]
                call_sp = call_sp - 1
                cur_data = frame.data
                cur_off = frame.off
                cur_end = frame.end_off
            else
                break
            end
        end

        local b0 = read_uint8(cur_data, cur_off)
        cur_off = cur_off + 1

        if b0 >= 32 then
            -- Number operand
            if b0 >= 32 and b0 <= 246 then
                sp = sp + 1
                stack[sp] = b0 - 139
            elseif b0 >= 247 and b0 <= 250 then
                local b1 = read_uint8(cur_data, cur_off)
                cur_off = cur_off + 1
                sp = sp + 1
                stack[sp] = (b0 - 247) * 256 + b1 + 108
            elseif b0 >= 251 and b0 <= 254 then
                local b1 = read_uint8(cur_data, cur_off)
                cur_off = cur_off + 1
                sp = sp + 1
                stack[sp] = -(b0 - 251) * 256 - b1 - 108
            elseif b0 == 255 then
                -- Fixed 16.16
                local hi = read_int16(cur_data, cur_off)
                local lo = read_uint16(cur_data, cur_off + 2)
                cur_off = cur_off + 4
                sp = sp + 1
                stack[sp] = hi + lo / 65536
            end
        elseif b0 == 28 then
            -- 16-bit signed integer
            sp = sp + 1
            stack[sp] = read_int16(cur_data, cur_off)
            cur_off = cur_off + 2
        elseif b0 == 1 or b0 == 3 or b0 == 18 or b0 == 23 then
            -- hstem, vstem, hstemhm, vstemhm -" hint operators
            check_width(sp - (sp % 2))  -- even number of args expected
            n_stems = n_stems + math_floor(sp / 2)
            sp = 0
        elseif b0 == 19 or b0 == 20 then
            -- hintmask, cntrmask
            check_width(sp - (sp % 2))
            n_stems = n_stems + math_floor(sp / 2)
            sp = 0
            skip_hint_mask()
        elseif b0 == 21 then
            -- rmoveto (dx, dy)
            check_width(2)
            x = x + stack[sp - 1]
            y = y + stack[sp]
            sp = 0
            new_contour()
        elseif b0 == 22 then
            -- hmoveto (dx)
            check_width(1)
            x = x + stack[sp]
            sp = 0
            new_contour()
        elseif b0 == 4 then
            -- vmoveto (dy)
            check_width(1)
            y = y + stack[sp]
            sp = 0
            new_contour()
        elseif b0 == 5 then
            -- rlineto: (dx, dy) pairs
            if not poly then new_contour() end
            for i = 1, sp, 2 do
                line_to(x + stack[i], y + stack[i + 1])
            end
            sp = 0
        elseif b0 == 6 then
            -- hlineto: alternating horizontal/vertical
            if not poly then new_contour() end
            local horiz = true
            for i = 1, sp do
                if horiz then
                    line_to(x + stack[i], y)
                else
                    line_to(x, y + stack[i])
                end
                horiz = not horiz
            end
            sp = 0
        elseif b0 == 7 then
            -- vlineto: alternating vertical/horizontal
            if not poly then new_contour() end
            local vert = true
            for i = 1, sp do
                if vert then
                    line_to(x, y + stack[i])
                else
                    line_to(x + stack[i], y)
                end
                vert = not vert
            end
            sp = 0
        elseif b0 == 8 then
            -- rrcurveto: (dx1,dy1,dx2,dy2,dx3,dy3) groups
            if not poly then new_contour() end
            for i = 1, sp, 6 do
                local c1x = x + stack[i]
                local c1y = y + stack[i + 1]
                local c2x = c1x + stack[i + 2]
                local c2y = c1y + stack[i + 3]
                local px = c2x + stack[i + 4]
                local py = c2y + stack[i + 5]
                curve_to(c1x, c1y, c2x, c2y, px, py)
            end
            sp = 0
        elseif b0 == 24 then
            -- rcurveline: curves then final line
            if not poly then new_contour() end
            local nc = sp - 2  -- last 2 args are line dx,dy
            for i = 1, nc, 6 do
                local c1x = x + stack[i]
                local c1y = y + stack[i + 1]
                local c2x = c1x + stack[i + 2]
                local c2y = c1y + stack[i + 3]
                local px = c2x + stack[i + 4]
                local py = c2y + stack[i + 5]
                curve_to(c1x, c1y, c2x, c2y, px, py)
            end
            line_to(x + stack[sp - 1], y + stack[sp])
            sp = 0
        elseif b0 == 25 then
            -- rlinecurve: lines then final curve
            if not poly then new_contour() end
            local nl = sp - 6  -- last 6 args are curve
            for i = 1, nl, 2 do
                line_to(x + stack[i], y + stack[i + 1])
            end
            local i = nl + 1
            local c1x = x + stack[i]
            local c1y = y + stack[i + 1]
            local c2x = c1x + stack[i + 2]
            local c2y = c1y + stack[i + 3]
            local px = c2x + stack[i + 4]
            local py = c2y + stack[i + 5]
            curve_to(c1x, c1y, c2x, c2y, px, py)
            sp = 0
        elseif b0 == 26 then
            -- vvcurveto: [dx1] {dy1 dx2 dy2 dy3}+
            if not poly then new_contour() end
            local i = 1
            local has_dx1 = (sp % 4) ~= 0
            if has_dx1 then
                local c1x = x + stack[i]
                local c1y = y + stack[i + 1]
                local c2x = c1x + stack[i + 2]
                local c2y = c1y + stack[i + 3]
                local px = c2x
                local py = c2y + stack[i + 4]
                curve_to(c1x, c1y, c2x, c2y, px, py)
                i = i + 5
            end
            while i <= sp do
                local c1x = x
                local c1y = y + stack[i]
                local c2x = c1x + stack[i + 1]
                local c2y = c1y + stack[i + 2]
                local px = c2x
                local py = c2y + stack[i + 3]
                curve_to(c1x, c1y, c2x, c2y, px, py)
                i = i + 4
            end
            sp = 0
        elseif b0 == 27 then
            -- hhcurveto: [dy1] {dx1 dx2 dy2 dx3}+
            if not poly then new_contour() end
            local i = 1
            local has_dy1 = (sp % 4) ~= 0
            if has_dy1 then
                local c1x = x + stack[i + 1]
                local c1y = y + stack[i]
                local c2x = c1x + stack[i + 2]
                local c2y = c1y + stack[i + 3]
                local px = c2x + stack[i + 4]
                local py = c2y
                curve_to(c1x, c1y, c2x, c2y, px, py)
                i = i + 5
            end
            while i <= sp do
                local c1x = x + stack[i]
                local c1y = y
                local c2x = c1x + stack[i + 1]
                local c2y = c1y + stack[i + 2]
                local px = c2x + stack[i + 3]
                local py = c2y
                curve_to(c1x, c1y, c2x, c2y, px, py)
                i = i + 4
            end
            sp = 0
        elseif b0 == 30 then
            -- vhcurveto: alternating v-start then h-start curves
            if not poly then new_contour() end
            local i = 1
            local phase = 0  -- 0 = v-start, 1 = h-start
            while i <= sp do
                local remaining = sp - i + 1
                if phase == 0 then
                    -- v-start: dy1 dx2 dy2 dx3 [+dy3 if last group with extra arg]
                    local c1x = x
                    local c1y = y + stack[i]
                    local c2x = c1x + stack[i + 1]
                    local c2y = c1y + stack[i + 2]
                    local px = c2x + stack[i + 3]
                    local py = c2y
                    if remaining == 5 then
                        py = py + stack[i + 4]
                        i = i + 5
                    else
                        i = i + 4
                    end
                    curve_to(c1x, c1y, c2x, c2y, px, py)
                else
                    -- h-start: dx1 dx2 dy2 dy3 [+dx3 if last group with extra arg]
                    local c1x = x + stack[i]
                    local c1y = y
                    local c2x = c1x + stack[i + 1]
                    local c2y = c1y + stack[i + 2]
                    local px = c2x
                    local py = c2y + stack[i + 3]
                    if remaining == 5 then
                        px = px + stack[i + 4]
                        i = i + 5
                    else
                        i = i + 4
                    end
                    curve_to(c1x, c1y, c2x, c2y, px, py)
                end
                phase = 1 - phase
            end
            sp = 0
        elseif b0 == 31 then
            -- hvcurveto: alternating h-start then v-start curves
            if not poly then new_contour() end
            local i = 1
            local phase = 0  -- 0 = h-start, 1 = v-start
            while i <= sp do
                local remaining = sp - i + 1
                if phase == 0 then
                    -- h-start: dx1 dx2 dy2 dy3 [+dx3 if last group with extra arg]
                    local c1x = x + stack[i]
                    local c1y = y
                    local c2x = c1x + stack[i + 1]
                    local c2y = c1y + stack[i + 2]
                    local px = c2x
                    local py = c2y + stack[i + 3]
                    if remaining == 5 then
                        px = px + stack[i + 4]
                        i = i + 5
                    else
                        i = i + 4
                    end
                    curve_to(c1x, c1y, c2x, c2y, px, py)
                else
                    -- v-start: dy1 dx2 dy2 dx3 [+dy3 if last group with extra arg]
                    local c1x = x
                    local c1y = y + stack[i]
                    local c2x = c1x + stack[i + 1]
                    local c2y = c1y + stack[i + 2]
                    local px = c2x + stack[i + 3]
                    local py = c2y
                    if remaining == 5 then
                        py = py + stack[i + 4]
                        i = i + 5
                    else
                        i = i + 4
                    end
                    curve_to(c1x, c1y, c2x, c2y, px, py)
                end
                phase = 1 - phase
            end
            sp = 0
        elseif b0 == 10 then
            -- callsubr: call local subroutine
            local idx = stack[sp] + lsubr_bias
            sp = sp - 1
            local subr = lsubrs[idx]
            if subr then
                call_sp = call_sp + 1
                call_stack[call_sp] = { data = cur_data, off = cur_off, end_off = cur_end }
                cur_data = data
                cur_off = subr.offset
                cur_end = subr.offset + subr.length
            end
        elseif b0 == 29 then
            -- callgsubr: call global subroutine
            local idx = stack[sp] + gsubr_bias
            sp = sp - 1
            local subr = gsubrs[idx]
            if subr then
                call_sp = call_sp + 1
                call_stack[call_sp] = { data = cur_data, off = cur_off, end_off = cur_end }
                cur_data = data
                cur_off = subr.offset
                cur_end = subr.offset + subr.length
            end
        elseif b0 == 11 then
            -- return from subroutine
            if call_sp > 0 then
                local frame = call_stack[call_sp]
                call_sp = call_sp - 1
                cur_data = frame.data
                cur_off = frame.off
                cur_end = frame.end_off
            end
        elseif b0 == 14 then
            -- endchar
            check_width(0)
            break
        elseif b0 == 12 then
            -- Two-byte escape operators (most are rare, skip gracefully)
            local b1 = read_uint8(cur_data, cur_off)
            cur_off = cur_off + 1
            if b1 == 34 then
                -- hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6
                if not poly then new_contour() end
                local y0 = y  -- save starting y (hflex returns to it)
                local c1x = x + stack[1]; local c1y = y0
                local c2x = c1x + stack[2]; local c2y = c1y + stack[3]
                local px1 = c2x + stack[4]; local py1 = c2y
                curve_to(c1x, c1y, c2x, c2y, px1, py1)
                local c3x = x + stack[5]; local c3y = y
                local c4x = c3x + stack[6]; local c4y = y0
                local px2 = c4x + stack[7]; local py2 = y0
                curve_to(c3x, c3y, c4x, c4y, px2, py2)
                sp = 0
            elseif b1 == 35 then
                -- flex: 6 pairs of dx/dy + fd (ignored)
                if not poly then new_contour() end
                local c1x = x + stack[1]; local c1y = y + stack[2]
                local c2x = c1x + stack[3]; local c2y = c1y + stack[4]
                local px1 = c2x + stack[5]; local py1 = c2y + stack[6]
                curve_to(c1x, c1y, c2x, c2y, px1, py1)
                local c3x = x + stack[7]; local c3y = y + stack[8]
                local c4x = c3x + stack[9]; local c4y = c3y + stack[10]
                local px2 = c4x + stack[11]; local py2 = c4y + stack[12]
                curve_to(c3x, c3y, c4x, c4y, px2, py2)
                sp = 0
            elseif b1 == 36 then
                -- hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
                if not poly then new_contour() end
                local y0 = y  -- save starting y (hflex1 returns to it)
                local c1x = x + stack[1]; local c1y = y0 + stack[2]
                local c2x = c1x + stack[3]; local c2y = c1y + stack[4]
                local px1 = c2x + stack[5]; local py1 = c2y
                curve_to(c1x, c1y, c2x, c2y, px1, py1)
                local c3x = x + stack[6]; local c3y = y
                local c4x = c3x + stack[7]; local c4y = c3y + stack[8]
                local px2 = c4x + stack[9]; local py2 = y0
                curve_to(c3x, c3y, c4x, c4y, px2, py2)
                sp = 0
            elseif b1 == 37 then
                -- flex1: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6
                if not poly then new_contour() end
                local c1x = x + stack[1]; local c1y = y + stack[2]
                local c2x = c1x + stack[3]; local c2y = c1y + stack[4]
                local px1 = c2x + stack[5]; local py1 = c2y + stack[6]
                curve_to(c1x, c1y, c2x, c2y, px1, py1)
                local c3x = x + stack[7]; local c3y = y + stack[8]
                local c4x = c3x + stack[9]; local c4y = c3y + stack[10]
                -- d6: if total dx > total dy, it's dx; else dy
                local total_dx = math_abs(stack[1] + stack[3] + stack[5] + stack[7] + stack[9])
                local total_dy = math_abs(stack[2] + stack[4] + stack[6] + stack[8] + stack[10])
                local px2, py2
                if total_dx > total_dy then
                    px2 = c4x + stack[11]; py2 = c4y
                else
                    px2 = c4x; py2 = c4y + stack[11]
                end
                curve_to(c3x, c3y, c4x, c4y, px2, py2)
                sp = 0
            else
                -- Unknown 2-byte operator -" clear stack
                sp = 0
            end
        else
            -- Unknown operator -" clear stack
            sp = 0
        end
    end

    -- Close final contour
    if poly and #poly >= 3 then
        local first = poly[1]
        local last = poly[#poly]
        if math_abs(last.x - first.x) > 0.01 or math_abs(last.y - first.y) > 0.01 then
            poly[#poly + 1] = { x = first.x, y = first.y }
        end
        pn = pn + 1
        polylines[pn] = poly
    end

    return polylines, width
end

--- Parse the CFF table and extract charstring data.
---@param data string
---@param tables table
---@return table|nil  CFF data structure
function TtfParser.parse_cff(data, tables)
    local cff_table = tables["CFF "] or tables["CFF2"]
    if not cff_table then return nil end
    local base = cff_table.offset

    -- CFF header
    local major = read_uint8(data, base)
    local hdr_size = read_uint8(data, base + 2)
    local is_cff2 = (major >= 2)

    local off = base + hdr_size

    if is_cff2 then
        -- CFF2: Top DICT is at fixed location after header
        -- For now, basic CFF2 support follows same structure
        -- CFF2 has no Name INDEX -" skip to Top DICT
    else
        -- CFF1: Name INDEX
        local name_idx = TtfParser._read_cff_index(data, off)
        off = name_idx.end_off

        -- Top DICT INDEX
        local top_dict_idx = TtfParser._read_cff_index(data, off)
        off = top_dict_idx.end_off

        -- String INDEX (skip)
        local string_idx = TtfParser._read_cff_index(data, off)
        off = string_idx.end_off

        -- Global Subr INDEX
        local gsubr_idx = TtfParser._read_cff_index(data, off)

        -- Decode Top DICT
        local td_item = top_dict_idx.items[0]
        if not td_item then return nil end
        local top_dict = TtfParser._parse_cff_dict(data, td_item.offset, td_item.length)

        -- charStrings offset (operator 17)
        local cs_offset = top_dict[17]
        if not cs_offset then return nil end
        cs_offset = base + cs_offset

        -- CharStrings INDEX
        local cs_idx = TtfParser._read_cff_index(data, cs_offset)

        -- Private DICT (operator 18 = {size, offset})
        local default_w = 0
        local nominal_w = 0
        local lsubr_idx = { count = 0, items = {} }

        local priv = top_dict[18]
        if priv and type(priv) == "table" then
            local priv_size = priv[1]
            local priv_off = base + priv[2]
            local priv_dict = TtfParser._parse_cff_dict(data, priv_off, priv_size)

            -- defaultWidthX (operator 20), nominalWidthX (operator 21)
            default_w = priv_dict[20] or 0
            nominal_w = priv_dict[21] or 0

            -- Local Subr INDEX (operator 19 = offset relative to Private DICT)
            local lsubr_off = priv_dict[19]
            if lsubr_off then
                lsubr_idx = TtfParser._read_cff_index(data, priv_off + lsubr_off)
            end
        end

        return {
            charstrings = cs_idx,
            gsubrs = gsubr_idx,
            gsubr_bias = cff_subr_bias(gsubr_idx.count),
            lsubrs = lsubr_idx,
            lsubr_bias = cff_subr_bias(lsubr_idx.count),
            defaultWidthX = default_w,
            nominalWidthX = nominal_w,
        }
    end

    return nil  -- CFF2 not yet fully implemented
end

--- Parse a single CFF glyph outline into polylines.
---@param data string
---@param font table     Parsed font object (with font.cff)
---@param glyph_index number
---@param unitsPerEm number
---@return table|nil polylines
---@return table|nil bbox
function TtfParser._parse_cff_glyph(data, font, glyph_index, unitsPerEm)
    local cff = font.cff
    if not cff then return nil, nil end

    local cs = cff.charstrings.items[glyph_index]
    if not cs then return nil, nil end

    local tol = (unitsPerEm or 1000) / 200

    local polylines, width = TtfParser._interpret_charstring(
        data, cs.offset, cs.length,
        cff.gsubrs.items, cff.gsubr_bias,
        cff.lsubrs.items, cff.lsubr_bias,
        cff.defaultWidthX, cff.nominalWidthX,
        tol
    )

    if not polylines or #polylines == 0 then
        return nil, nil
    end

    -- Compute bbox from polyline points
    local xMin, yMin = 1e9, 1e9
    local xMax, yMax = -1e9, -1e9
    for i = 1, #polylines do
        local pl = polylines[i]
        for j = 1, #pl do
            local pt = pl[j]
            if pt.x < xMin then xMin = pt.x end
            if pt.x > xMax then xMax = pt.x end
            if pt.y < yMin then yMin = pt.y end
            if pt.y > yMax then yMax = pt.y end
        end
    end

    -- Polyline Y coordinates are already negated (screen space: y → -y).
    -- Convert bbox back to font units (Y-up) to match TTF bbox format,
    -- since glyph_cache.lua applies its own Y-flip: vb_y = -bbox.yMax - pad.
    return polylines, { xMin = xMin, yMin = -yMax, xMax = xMax, yMax = -yMin }
end

------------------------------------------------------------
-- High-level parse (convenience)
------------------------------------------------------------

local COLOR_TABLE_TAGS = { "COLR", "CPAL", "CBDT", "CBLC", "sbix", "SVG " }

local function detect_color_tables(tables)
    local found = {}
    for i = 1, #COLOR_TABLE_TAGS do
        local tag = COLOR_TABLE_TAGS[i]
        if tables[tag] then found[#found + 1] = tag end
    end
    return #found > 0 and found or nil
end

--- Parse all required tables from TTF data in one call.
--- Returns a parsed font object with everything needed for
--- glyph lookup and rendering.
---@param data string  Raw TTF binary data
---@return table|nil  Parsed font object or nil on failure
function TtfParser.parse(data)
    if type(data) ~= "string" or #data < 12 then return nil end

    local tables = TtfParser.parse_tables(data)
    local has_outlines = tables["glyf"] or tables["CFF "] or tables["CFF2"]
    if not tables["head"] or not has_outlines then return nil end
    if tables["head"].length < 54 then return nil end
    if tables["hhea"] and tables["hhea"].length < 36 then return nil end
    if tables["maxp"] and tables["maxp"].length < 6 then return nil end
    if tables["CFF2"] and not tables["glyf"] and not tables["CFF "] then
        return nil, "CFF2 outlines are not supported by the built-in rasterizer"
    end

    local head = TtfParser.parse_head(data, tables)
    local hhea = TtfParser.parse_hhea(data, tables)
    local maxp = TtfParser.parse_maxp(data, tables)
    local cmap = TtfParser.parse_cmap(data, tables)
    local loca = TtfParser.parse_loca(data, tables, maxp.numGlyphs, head.indexToLocFormat)
    local hmtx = TtfParser.parse_hmtx(data, tables, maxp.numGlyphs, hhea.numOfLongHorMetrics)
    local kern = TtfParser.parse_kern(data, tables)
    local gpos = TtfParser.parse_gpos(data, tables)
    local os2  = TtfParser.parse_os2(data, tables)
    local color_tables = detect_color_tables(tables)
    local ttf_hinting = {
        cvt = TtfParser.parse_cvt(data, tables),
        fpgm = TtfParser.parse_program_table(data, tables, "fpgm"),
        prep = TtfParser.parse_program_table(data, tables, "prep"),
        maxp = {
            maxZones = maxp.maxZones,
            maxTwilightPoints = maxp.maxTwilightPoints,
            maxStorage = maxp.maxStorage,
            maxFunctionDefs = maxp.maxFunctionDefs,
            maxInstructionDefs = maxp.maxInstructionDefs,
            maxStackElements = maxp.maxStackElements,
        },
    }

    -- Parse CFF table if no glyf table
    local cff = nil
    if not tables["glyf"] then
        cff = TtfParser.parse_cff(data, tables)
    end

    return {
        data        = data,
        tables      = tables,
        head        = head,
        hhea        = hhea,
        maxp        = maxp,
        cmap        = cmap,
        loca        = loca,
        hmtx        = hmtx,
        kern        = kern,
        gpos        = gpos,
        os2         = os2,
        cff         = cff,
        color_tables = color_tables,
        ttf_hinting = ttf_hinting,
        enable_ttf_hinting = false,
    }
end

return TtfParser



