------------------------------------------------------------
-- ext_core_astro_ui_lib / core / fonts / woff_decoder.lua
-- WOFF to TTF converter.
--
-- Decodes WOFF (Web Open Font Format) files to raw TTF
-- using pure Lua deflate decompression (RFC 1951).
-- This enables loading fonts from CDNs that only serve WOFF.
--
-- Adapted from ext_lib_ultima_ui for Astro UI.
------------------------------------------------------------

local WoffDecoder = {}

local byte   = string.byte
local char   = string.char
local sub    = string.sub
local concat = table.concat
local floor  = math.floor

--- Pre-computed powers of 2 for bit manipulation.
local POW2 = {}
for i = 0, 30 do POW2[i] = 2 ^ i end

------------------------------------------------------------
-- Binary reading helpers (big-endian, 0-based offset)
------------------------------------------------------------

local function read_u16(data, off)
    local b1, b2 = byte(data, off + 1, off + 2)
    if not b1 or not b2 then return nil end
    return b1 * 256 + b2
end

local function read_u32(data, off)
    local b1, b2, b3, b4 = byte(data, off + 1, off + 4)
    if not b1 or not b2 or not b3 or not b4 then return nil end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

------------------------------------------------------------
-- Binary writing helpers (big-endian)
------------------------------------------------------------

local function write_u16(n)
    return char(floor(n / 256) % 256, n % 256)
end

local function write_u32(n)
    return char(
        floor(n / 16777216) % 256,
        floor(n / 65536) % 256,
        floor(n / 256) % 256,
        n % 256)
end

------------------------------------------------------------
-- Bit reader (LSB-first, for deflate)
------------------------------------------------------------

local BR = {}
BR.__index = BR

function BR.new(data, pos)
    return setmetatable({
        d   = data,
        p   = pos,   -- 1-based byte position
        buf = 0,
        n   = 0,
    }, BR)
end

function BR:bits(count)
    while self.n < count do
        self.buf = self.buf + byte(self.d, self.p) * POW2[self.n]
        self.p = self.p + 1
        self.n = self.n + 8
    end
    local val = self.buf % POW2[count]
    self.buf = floor(self.buf / POW2[count])
    self.n = self.n - count
    return val
end

function BR:align()
    self.buf = 0
    self.n   = 0
end

------------------------------------------------------------
-- Huffman tree builder & decoder
------------------------------------------------------------

local function build_tree(lengths, max_sym)
    local bl = {}
    local mx = 0
    for i = 0, max_sym do
        local len = lengths[i] or 0
        if len > 0 then
            bl[len] = (bl[len] or 0) + 1
            if len > mx then mx = len end
        end
    end
    if mx == 0 then return nil end

    local nc = {}
    local code = 0
    for bits = 1, mx do
        code = (code + (bl[bits - 1] or 0)) * 2
        nc[bits] = code
    end

    local t = {}
    for i = 0, max_sym do
        local len = lengths[i] or 0
        if len > 0 then
            if not t[len] then t[len] = {} end
            t[len][nc[len]] = i
            nc[len] = nc[len] + 1
        end
    end
    t._mx = mx
    return t
end

local function huf_decode(reader, tree)
    local code = 0
    for len = 1, tree._mx do
        code = code * 2 + reader:bits(1)
        local tbl = tree[len]
        if tbl then
            local sym = tbl[code]
            if sym ~= nil then return sym end
        end
    end
    return nil
end

------------------------------------------------------------
-- Deflate tables (RFC 1951)
------------------------------------------------------------

-- Length codes 257-285: base values and extra bits
local LEN_BASE  = {}
local LEN_EXTRA = {}
do
    for i = 0, 7 do
        LEN_BASE[257 + i]  = 3 + i
        LEN_EXTRA[257 + i] = 0
    end
    local code = 265
    local base = 11
    for extra = 1, 5 do
        for _ = 0, 3 do
            LEN_BASE[code]  = base
            LEN_EXTRA[code] = extra
            base = base + POW2[extra]
            code = code + 1
        end
    end
    LEN_BASE[285]  = 258
    LEN_EXTRA[285] = 0
end

-- Distance codes 0-29: base values and extra bits
local DIST_BASE  = {}
local DIST_EXTRA = {}
do
    for i = 0, 3 do
        DIST_BASE[i]  = i + 1
        DIST_EXTRA[i] = 0
    end
    local code = 4
    local base = 5
    for extra = 1, 13 do
        for _ = 0, 1 do
            DIST_BASE[code]  = base
            DIST_EXTRA[code] = extra
            base = base + POW2[extra]
            code = code + 1
        end
    end
end

-- Fixed Huffman trees (lazily built)
local _fixed_lit, _fixed_dist

local function get_fixed_trees()
    if _fixed_lit then return _fixed_lit, _fixed_dist end
    local ll = {}
    for i = 0,   143 do ll[i] = 8 end
    for i = 144, 255 do ll[i] = 9 end
    for i = 256, 279 do ll[i] = 7 end
    for i = 280, 287 do ll[i] = 8 end
    _fixed_lit = build_tree(ll, 287)
    local dl = {}
    for i = 0, 31 do dl[i] = 5 end
    _fixed_dist = build_tree(dl, 31)
    return _fixed_lit, _fixed_dist
end

-- Code-length alphabet order (RFC 1951 sec 3.2.7)
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

------------------------------------------------------------
-- Inflate (RFC 1951 DEFLATE decompression)
------------------------------------------------------------

--- Decompress a raw DEFLATE stream.
---@param data string     Compressed data
---@param start_pos number 1-based start position
---@return string          Decompressed data
local function inflate(data, start_pos)
    local r = BR.new(data, start_pos or 1)
    local out = {}
    local on  = 0   -- output count

    repeat
        local bfinal = r:bits(1)
        local btype  = r:bits(2)

        if btype == 0 then
            ------------------------------------------------
            -- Stored block (no compression)
            ------------------------------------------------
            r:align()
            local len = r:bits(8) + r:bits(8) * 256
            r:bits(8); r:bits(8)  -- skip NLEN
            for _ = 1, len do
                on = on + 1
                out[on] = char(r:bits(8))
            end

        elseif btype == 1 or btype == 2 then
            ------------------------------------------------
            -- Huffman compressed block
            ------------------------------------------------
            local lit_t, dist_t

            if btype == 1 then
                lit_t, dist_t = get_fixed_trees()
            else
                -- Dynamic Huffman: decode the trees
                local hlit  = r:bits(5) + 257
                local hdist = r:bits(5) + 1
                local hclen = r:bits(4) + 4

                local cl = {}
                for i = 0, 18 do cl[i] = 0 end
                for i = 1, hclen do
                    cl[CL_ORDER[i]] = r:bits(3)
                end
                local cl_tree = build_tree(cl, 18)

                local all = {}
                local idx = 0
                local total = hlit + hdist
                while idx < total do
                    local sym = huf_decode(r, cl_tree)
                    if sym < 16 then
                        all[idx] = sym
                        idx = idx + 1
                    elseif sym == 16 then
                        local rep = r:bits(2) + 3
                        local prev = all[idx - 1] or 0
                        for _ = 1, rep do all[idx] = prev; idx = idx + 1 end
                    elseif sym == 17 then
                        local rep = r:bits(3) + 3
                        for _ = 1, rep do all[idx] = 0; idx = idx + 1 end
                    elseif sym == 18 then
                        local rep = r:bits(7) + 11
                        for _ = 1, rep do all[idx] = 0; idx = idx + 1 end
                    end
                end

                local ll = {}
                for i = 0, hlit - 1  do ll[i] = all[i] or 0 end
                local dl = {}
                for i = 0, hdist - 1 do dl[i] = all[hlit + i] or 0 end

                lit_t  = build_tree(ll, hlit - 1)
                dist_t = build_tree(dl, hdist - 1)
            end

            -- Decode symbols
            while true do
                local sym = huf_decode(r, lit_t)
                if not sym or sym == 256 then
                    break
                elseif sym < 256 then
                    on = on + 1
                    out[on] = char(sym)
                else
                    -- Length/distance pair
                    local length   = LEN_BASE[sym]  + r:bits(LEN_EXTRA[sym])
                    local dist_sym = huf_decode(r, dist_t)
                    local distance = DIST_BASE[dist_sym] + r:bits(DIST_EXTRA[dist_sym])

                    for _ = 1, length do
                        local src = on - distance + 1
                        on = on + 1
                        out[on] = out[src]
                    end
                end
            end
        end
    until bfinal == 1

    return concat(out)
end

------------------------------------------------------------
-- Zlib wrapper (2-byte header + deflate + 4-byte checksum)
------------------------------------------------------------

--- Decompress zlib-wrapped data.
---@param data string  Zlib compressed data
---@return string      Decompressed data
local function zlib_decompress(data)
    -- Skip 2-byte zlib header, inflate the deflate stream.
    return inflate(data, 3)
end

------------------------------------------------------------
-- WOFF detection
------------------------------------------------------------

--- Check if data starts with the WOFF magic bytes.
---@param data string
---@return boolean
function WoffDecoder.is_woff(data)
    if type(data) ~= "string" then return false end
    if #data < 4 then return false end
    return byte(data, 1) == 0x77    -- 'w'
       and byte(data, 2) == 0x4F    -- 'O'
       and byte(data, 3) == 0x46    -- 'F'
       and byte(data, 4) == 0x46    -- 'F'
end

--- Check if data starts with the WOFF2 magic bytes.
--- WOFF2 uses Brotli compression and is intentionally rejected by
--- FontManager unless a Brotli decoder is available.
---@param data string
---@return boolean
function WoffDecoder.is_woff2(data)
    if type(data) ~= "string" then return false end
    if #data < 4 then return false end
    return byte(data, 1) == 0x77    -- 'w'
       and byte(data, 2) == 0x4F    -- 'O'
       and byte(data, 3) == 0x46    -- 'F'
       and byte(data, 4) == 0x32    -- '2'
end

------------------------------------------------------------
-- WOFF to TTF conversion
------------------------------------------------------------

--- Decode a WOFF file to raw TTF data.
---@param woff_data string  Raw WOFF file data
---@return string|nil        Raw TTF data, or nil on error
function WoffDecoder.decode(woff_data)
    if not WoffDecoder.is_woff(woff_data) then return nil end
    if #woff_data < 44 then return nil end

    local flavor    = read_u32(woff_data, 4)
    local numTables = read_u16(woff_data, 12)
    if not flavor or not numTables then return nil end

    -- Validate: need at least header + directory
    local dir_end = 44 + numTables * 20
    if #woff_data < dir_end then return nil end

    -- Parse table directory and extract/decompress each table
    local tables = {}
    for i = 0, numTables - 1 do
        local base = 44 + i * 20
        local tag        = sub(woff_data, base + 1, base + 4)
        local offset     = read_u32(woff_data, base + 4)
        local compLen    = read_u32(woff_data, base + 8)
        local origLen    = read_u32(woff_data, base + 12)
        local checksum   = read_u32(woff_data, base + 16)
        if not offset or not compLen or not origLen or not checksum then return nil end
        if offset < dir_end or compLen < 0 or origLen < 0 then return nil end
        if offset + compLen > #woff_data then return nil end

        -- Extract table data
        local raw_chunk = sub(woff_data, offset + 1, offset + compLen)
        local table_data
        if compLen == origLen then
            -- Uncompressed
            table_data = raw_chunk
        else
            -- Zlib compressed
            local ok, result = pcall(zlib_decompress, raw_chunk)
            if not ok or not result then return nil end
            table_data = result
        end
        if #table_data ~= origLen then return nil end

        tables[#tables + 1] = {
            tag      = tag,
            checksum = checksum,
            data     = table_data,
            length   = origLen,
        }
    end

    -- Reconstruct sfnt (TTF) file
    local entrySelector = 0
    local searchRange   = 1
    while searchRange * 2 <= numTables do
        searchRange   = searchRange * 2
        entrySelector = entrySelector + 1
    end
    searchRange = searchRange * 16
    local rangeShift = numTables * 16 - searchRange

    -- Build header
    local parts = {}
    parts[#parts + 1] = write_u32(flavor)
    parts[#parts + 1] = write_u16(numTables)
    parts[#parts + 1] = write_u16(searchRange)
    parts[#parts + 1] = write_u16(entrySelector)
    parts[#parts + 1] = write_u16(rangeShift)

    -- Calculate table data offsets (after header + all records)
    local data_start = 12 + numTables * 16
    local offset = data_start
    for _, t in ipairs(tables) do
        t.offset = offset
        -- Pad to 4-byte boundary
        local padded = t.length
        local rem = padded % 4
        if rem ~= 0 then padded = padded + (4 - rem) end
        offset = offset + padded
    end

    -- Write table records
    for _, t in ipairs(tables) do
        parts[#parts + 1] = t.tag
        parts[#parts + 1] = write_u32(t.checksum)
        parts[#parts + 1] = write_u32(t.offset)
        parts[#parts + 1] = write_u32(t.length)
    end

    -- Write table data with padding
    for _, t in ipairs(tables) do
        parts[#parts + 1] = t.data
        local rem = #t.data % 4
        if rem ~= 0 then
            parts[#parts + 1] = string.rep("\0", 4 - rem)
        end
    end

    return concat(parts)
end

--- Expose zlib decompression for reuse (e.g. PNG decoder).
WoffDecoder.zlib_decompress = zlib_decompress

return WoffDecoder



