------------------------------------------------------------
-- ext_core_astro_ui_lib / core / assets / jpeg_decoder.lua
-- Baseline + Progressive JPEG → RGBA decoder (pure Lua 5.1).
--
-- Handles:
--   - Baseline sequential (SOF0) and Progressive (SOF2)
--   - 8-bit precision
--   - YCbCr → RGB with 4:4:4, 4:2:2, 4:2:0 subsampling
--   - Grayscale (1 component)
--   - Standard Huffman coding (DHT)
--   - Restart markers (DRI/RST)
--   - Spectral selection & successive approximation
--
-- Returns flat {r,g,b,a, r,g,b,a, ...} table compatible
-- with TextureCache's entry.rgba format.
------------------------------------------------------------

local byte   = string.byte
local floor  = math.floor
local sqrt   = math.sqrt
local cos    = math.cos
local pi     = math.pi
local sub    = string.sub

------------------------------------------------------------
-- Bit reader for entropy-coded data (MSB-first)
------------------------------------------------------------

local BR = {}
BR.__index = BR

function BR.new(data, pos)
    return setmetatable({
        d   = data,
        p   = pos,
        buf = 0,
        n   = 0,
    }, BR)
end

--- Read next byte, handling 0xFF00 stuffing and restart markers.
function BR:next_byte()
    local b = byte(self.d, self.p)
    if not b then return 0 end
    self.p = self.p + 1
    if b == 0xFF then
        local b2 = byte(self.d, self.p)
        if b2 == 0x00 then
            self.p = self.p + 1  -- skip stuffed zero
        elseif b2 and b2 >= 0xD0 and b2 <= 0xD7 then
            return 0  -- restart marker -" return 0 padding
        end
    end
    return b
end

function BR:bit()
    if self.n == 0 then
        self.buf = self:next_byte()
        self.n = 8
    end
    self.n = self.n - 1
    local shift = 1
    for _ = 1, self.n do shift = shift * 2 end
    return floor(self.buf / shift) % 2
end

function BR:bits(count)
    local val = 0
    for _ = 1, count do
        val = val * 2 + self:bit()
    end
    return val
end

function BR:reset()
    self.buf = 0
    self.n   = 0
end

------------------------------------------------------------
-- Huffman table decoder
------------------------------------------------------------

local function build_huffman(lengths, values)
    local tree = {}
    local vi = 1
    local code = 0
    for bits = 1, 16 do
        local count = lengths[bits] or 0
        if count > 0 then
            if not tree[bits] then tree[bits] = {} end
            for _ = 1, count do
                tree[bits][code] = values[vi]
                vi = vi + 1
                code = code + 1
            end
        end
        code = code * 2
    end
    tree._max = 16
    return tree
end

local function huf_decode(reader, tree)
    local code = 0
    for bits = 1, tree._max do
        code = code * 2 + reader:bit()
        local tbl = tree[bits]
        if tbl then
            local sym = tbl[code]
            if sym ~= nil then return sym end
        end
    end
    return 0
end

--- Read a signed value of `nbits` bits.
local function receive(reader, nbits)
    if nbits == 0 then return 0 end
    local val = reader:bits(nbits)
    local half = 1
    for _ = 2, nbits do half = half * 2 end
    if val < half then
        val = val - (half * 2 - 1)
    end
    return val
end

------------------------------------------------------------
-- IDCT (Inverse Discrete Cosine Transform) -" 8x8
------------------------------------------------------------

local COS_TABLE = {}
for u = 0, 7 do
    COS_TABLE[u] = {}
    for x = 0, 7 do
        COS_TABLE[u][x] = cos((2 * x + 1) * u * pi / 16)
    end
end

local SQRT2_INV = 1 / sqrt(2)

local function idct_8x8(block)
    local out = {}
    local temp = {}
    for y = 0, 7 do
        for x = 0, 7 do
            local sum = 0
            for u = 0, 7 do
                local cu = (u == 0) and SQRT2_INV or 1
                sum = sum + cu * (block[y * 8 + u] or 0) * COS_TABLE[u][x]
            end
            temp[y * 8 + x] = sum
        end
    end
    for x = 0, 7 do
        for y = 0, 7 do
            local sum = 0
            for v = 0, 7 do
                local cv = (v == 0) and SQRT2_INV or 1
                sum = sum + cv * temp[v * 8 + x] * COS_TABLE[v][y]
            end
            out[y * 8 + x] = sum / 4
        end
    end
    return out
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function read_u16(data, pos)
    local b1, b2 = byte(data, pos), byte(data, pos + 1)
    if not b1 or not b2 then return nil end
    return b1 * 256 + b2
end

local function segment_end(data, pos)
    local seg_len = read_u16(data, pos)
    if not seg_len or seg_len < 2 then return nil end
    local seg_end = pos + seg_len
    if seg_end - 1 > #data then return nil end
    return seg_len, seg_end
end

-- Zigzag order: zigzag scan index → natural (row-major) index
local ZIGZAG = {
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
}

------------------------------------------------------------
-- Skip entropy data -" scan forward past byte-stuffed data
-- to find the next 0xFF marker (not 0xFF00 / 0xFFD0-D7).
-- Returns position of the 0xFF byte.
------------------------------------------------------------
local function skip_entropy(data, pos)
    local len = #data
    while pos <= len do
        local b = byte(data, pos)
        if b == 0xFF then
            local b2 = byte(data, pos + 1)
            if not b2 then return pos end
            if b2 == 0x00 then
                pos = pos + 2  -- stuffed byte, skip
            elseif b2 >= 0xD0 and b2 <= 0xD7 then
                pos = pos + 2  -- restart marker, skip
            else
                return pos  -- real marker
            end
        else
            pos = pos + 1
        end
    end
    return pos
end

------------------------------------------------------------
-- decode_jpeg(data) → rgba_table, width, height  or  nil
------------------------------------------------------------

local function decode_jpeg(data)
    if not data or #data < 4 then return nil end
    if byte(data, 1) ~= 0xFF or byte(data, 2) ~= 0xD8 then return nil end

    local width, height, ncomp
    local is_progressive = false
    local components = {}   -- comp_id -> {h_samp, v_samp, qt_id}
    local comp_order = {}   -- ordered list of component ids
    local qt = {}           -- qt[id][natural_pos] = quant value
    local dc_tables = {}
    local ac_tables = {}
    local restart_interval = 0

    -- Collect all scan descriptors: {pos, scan_comps, Ss, Se, Ah, Al}
    local scans = {}

    local pos = 3  -- after SOI

    ----------------------------------------------------------------
    -- Phase 1: Parse all markers, collect scan positions
    ----------------------------------------------------------------
    while pos < #data - 1 do
        local mf = byte(data, pos)
        local mi = byte(data, pos + 1)
        if not mf or not mi then break end
        pos = pos + 2

        if mf ~= 0xFF then
            -- Lost sync -" find next marker
            while pos < #data and byte(data, pos) ~= 0xFF do pos = pos + 1 end
            if pos >= #data then return nil end

        elseif mi == 0xD9 then
            break  -- EOI

        elseif mi == 0xC0 or mi == 0xC2 then
            -- SOF0 (Baseline) or SOF2 (Progressive)
            is_progressive = (mi == 0xC2)
            local seg_len = segment_end(data, pos)
            if not seg_len or seg_len < 8 then return nil end
            if byte(data, pos + 2) ~= 8 then return nil end  -- only 8-bit
            height = read_u16(data, pos + 3)
            width  = read_u16(data, pos + 5)
            ncomp  = byte(data, pos + 7)
            if not width or not height or width <= 0 or height <= 0 then return nil end
            if not ncomp or ncomp < 1 or seg_len < 8 + ncomp * 3 then return nil end
            for i = 0, ncomp - 1 do
                local off = pos + 8 + i * 3
                local cid = byte(data, off)
                local samp = byte(data, off + 1)
                if not cid or not samp then return nil end
                components[cid] = {
                    h_samp = floor(samp / 16),
                    v_samp = samp % 16,
                    qt_id  = byte(data, off + 2),
                }
                if components[cid].h_samp < 1 or components[cid].v_samp < 1
                   or not components[cid].qt_id then
                    return nil
                end
                comp_order[i + 1] = cid
            end
            pos = pos + seg_len

        elseif mi == 0xDB then
            -- DQT
            local seg_len, seg_end = segment_end(data, pos)
            if not seg_len then return nil end
            local qp = pos + 2
            while qp < seg_end do
                local pq_tq = byte(data, qp)
                if not pq_tq then return nil end
                local prec_q = floor(pq_tq / 16)
                local tq = pq_tq % 16
                if prec_q ~= 0 and prec_q ~= 1 then return nil end
                qp = qp + 1
                local qbytes = (prec_q == 0) and 64 or 128
                if qp + qbytes - 1 >= seg_end then return nil end
                qt[tq] = {}
                for i = 0, 63 do
                    if prec_q == 0 then
                        qt[tq][ZIGZAG[i + 1]] = byte(data, qp)
                        qp = qp + 1
                    else
                        qt[tq][ZIGZAG[i + 1]] = read_u16(data, qp)
                        qp = qp + 2
                    end
                end
            end
            pos = seg_end

        elseif mi == 0xC4 then
            -- DHT
            local seg_len, seg_end = segment_end(data, pos)
            if not seg_len then return nil end
            local hp = pos + 2
            while hp < seg_end do
                local tc_th = byte(data, hp)
                if not tc_th or hp + 16 >= seg_end then return nil end
                local tc = floor(tc_th / 16)
                local th = tc_th % 16
                if tc ~= 0 and tc ~= 1 then return nil end
                hp = hp + 1
                local lengths = {}
                local total = 0
                for i = 1, 16 do
                    lengths[i] = byte(data, hp + i - 1)
                    if not lengths[i] then return nil end
                    total = total + lengths[i]
                end
                hp = hp + 16
                if hp + total - 1 >= seg_end then return nil end
                local values = {}
                for i = 1, total do
                    values[i] = byte(data, hp + i - 1)
                end
                hp = hp + total
                local tree = build_huffman(lengths, values)
                if tc == 0 then dc_tables[th] = tree
                else ac_tables[th] = tree end
            end
            pos = seg_end

        elseif mi == 0xDD then
            -- DRI
            local seg_len = segment_end(data, pos)
            if not seg_len or seg_len < 4 then return nil end
            restart_interval = read_u16(data, pos + 2)
            if not restart_interval then return nil end
            pos = pos + seg_len

        elseif mi == 0xDA then
            -- SOS
            local seg_len = segment_end(data, pos)
            if not seg_len or seg_len < 6 then return nil end
            local ns_count = byte(data, pos + 2)
            if not ns_count or ns_count < 1 or seg_len < 6 + ns_count * 2 then return nil end
            local scan_comps = {}
            for i = 0, ns_count - 1 do
                local off = pos + 3 + i * 2
                local cs = byte(data, off)
                local td_ta = byte(data, off + 1)
                if not cs or not td_ta then return nil end
                scan_comps[i + 1] = {
                    id = cs,
                    dc_table = floor(td_ta / 16),
                    ac_table = td_ta % 16,
                }
            end
            local spec_off = pos + 3 + ns_count * 2
            local Ss = byte(data, spec_off)
            local Se = byte(data, spec_off + 1)
            local Ahl = byte(data, spec_off + 2)
            if not Ss or not Se or not Ahl then return nil end
            local Ah = floor(Ahl / 16)
            local Al = Ahl % 16

            local entropy_start = pos + seg_len
            scans[#scans + 1] = {
                pos = entropy_start,
                comps = scan_comps,
                Ss = Ss, Se = Se, Ah = Ah, Al = Al,
            }

            -- Skip past entropy data to continue parsing
            pos = skip_entropy(data, entropy_start)

        else
            -- Skip unknown segment
            if mi >= 0xC0 and mi ~= 0x00 and mi ~= 0x01
               and not (mi >= 0xD0 and mi <= 0xD7) then
                local seg_len = segment_end(data, pos)
                if not seg_len then return nil end
                pos = pos + seg_len
            end
        end
    end

    if not width or not height or not ncomp or #scans == 0 then return nil end

    ----------------------------------------------------------------
    -- Phase 2: Allocate coefficient storage
    ----------------------------------------------------------------
    local max_h, max_v = 1, 1
    for _, cid in ipairs(comp_order) do
        local c = components[cid]
        if c.h_samp > max_h then max_h = c.h_samp end
        if c.v_samp > max_v then max_v = c.v_samp end
    end

    local mcu_w = max_h * 8
    local mcu_h = max_v * 8
    local mcu_cols = floor((width + mcu_w - 1) / mcu_w)
    local mcu_rows = floor((height + mcu_h - 1) / mcu_h)

    -- Per-component: array of 64-element coefficient blocks
    -- coeff_blocks[cid][block_index][0..63] = DCT coefficient (natural order)
    local coeff_blocks = {}
    local blocks_per_row = {}  -- blocks per row for each component
    for _, cid in ipairs(comp_order) do
        local c = components[cid]
        local bw = mcu_cols * c.h_samp
        local bh = mcu_rows * c.v_samp
        blocks_per_row[cid] = bw
        coeff_blocks[cid] = {}
        for bi = 1, bw * bh do
            local blk = {}
            for i = 0, 63 do blk[i] = 0 end
            coeff_blocks[cid][bi] = blk
        end
    end

    ----------------------------------------------------------------
    -- Phase 3: Process each scan
    ----------------------------------------------------------------

    local function handle_restart(reader, dc_pred, scan_comps, mcu_count)
        if restart_interval > 0 and mcu_count > 0
           and mcu_count % restart_interval == 0 then
            reader:reset()
            -- Skip to restart marker
            while reader.p < #data do
                local b = byte(data, reader.p)
                reader.p = reader.p + 1
                if b == 0xFF then
                    local b2 = byte(data, reader.p)
                    if b2 and b2 >= 0xD0 and b2 <= 0xD7 then
                        reader.p = reader.p + 1
                        break
                    end
                end
            end
            for _, sc in ipairs(scan_comps) do
                dc_pred[sc.id] = 0
            end
            return true
        end
        return false
    end

    for _, scan in ipairs(scans) do
        local reader = BR.new(data, scan.pos)
        local Ss, Se, Ah, Al = scan.Ss, scan.Se, scan.Ah, scan.Al
        local scan_comps = scan.comps
        local al_shift = 1
        for _ = 1, Al do al_shift = al_shift * 2 end

        local dc_pred = {}
        for _, sc in ipairs(scan_comps) do
            dc_pred[sc.id] = 0
        end

        local is_dc_scan = (Ss == 0)
        local is_ac_scan = (Ss > 0)
        local is_first   = (Ah == 0)
        local mcu_count  = 0

        if not is_progressive then
            ---------------------------------------------------------
            -- BASELINE: single scan, Ss=0, Se=63, Ah=0, Al=0
            ---------------------------------------------------------
            for mcu_y = 0, mcu_rows - 1 do
                for mcu_x = 0, mcu_cols - 1 do
                    handle_restart(reader, dc_pred, scan_comps, mcu_count)

                    for _, sc in ipairs(scan_comps) do
                        local cid = sc.id
                        local c = components[cid]
                        local dc_ht = dc_tables[sc.dc_table] or dc_tables[0]
                        local ac_ht = ac_tables[sc.ac_table] or ac_tables[0]
                        if not dc_ht or not ac_ht then return nil end
                        local qtab = qt[c.qt_id] or qt[0]
                        local bpr = blocks_per_row[cid]

                        for v = 0, c.v_samp - 1 do
                            for h = 0, c.h_samp - 1 do
                                local bx = mcu_x * c.h_samp + h
                                local by = mcu_y * c.v_samp + v
                                local bi = by * bpr + bx + 1
                                local block = coeff_blocks[cid][bi]

                                -- DC
                                local dc_len = huf_decode(reader, dc_ht)
                                local dc_val = receive(reader, dc_len)
                                dc_pred[cid] = dc_pred[cid] + dc_val
                                block[0] = dc_pred[cid] * (qtab and qtab[0] or 1)

                                -- AC (zigzag 1..63 → natural order)
                                local k = 1
                                while k < 64 do
                                    local rs = huf_decode(reader, ac_ht)
                                    if rs == 0 then break end
                                    local rrrr = floor(rs / 16)
                                    local ssss = rs % 16
                                    k = k + rrrr
                                    if k >= 64 then break end
                                    local ac_val = receive(reader, ssss)
                                    local nat = ZIGZAG[k + 1]
                                    block[nat] = ac_val * (qtab and qtab[nat] or 1)
                                    k = k + 1
                                end
                            end
                        end
                    end
                    mcu_count = mcu_count + 1
                end
            end

        elseif #scan_comps > 1 then
            ---------------------------------------------------------
            -- PROGRESSIVE: interleaved scan (DC only, multiple comps)
            ---------------------------------------------------------
            for mcu_y = 0, mcu_rows - 1 do
                for mcu_x = 0, mcu_cols - 1 do
                    handle_restart(reader, dc_pred, scan_comps, mcu_count)

                    for _, sc in ipairs(scan_comps) do
                        local cid = sc.id
                        local c = components[cid]
                        local dc_ht = dc_tables[sc.dc_table] or dc_tables[0]
                        if not dc_ht then return nil end
                        local bpr = blocks_per_row[cid]

                        for v = 0, c.v_samp - 1 do
                            for h = 0, c.h_samp - 1 do
                                local bx = mcu_x * c.h_samp + h
                                local by = mcu_y * c.v_samp + v
                                local bi = by * bpr + bx + 1
                                local block = coeff_blocks[cid][bi]

                                if is_first then
                                    -- First DC scan
                                    local dc_len = huf_decode(reader, dc_ht)
                                    local dc_val = receive(reader, dc_len)
                                    dc_pred[cid] = dc_pred[cid] + dc_val
                                    block[0] = dc_pred[cid] * al_shift
                                else
                                    -- DC refinement: one bit per block
                                    local bit = reader:bit()
                                    block[0] = block[0] + bit * al_shift
                                end
                            end
                        end
                    end
                    mcu_count = mcu_count + 1
                end
            end

        else
            ---------------------------------------------------------
            -- PROGRESSIVE: non-interleaved scan (single component)
            ---------------------------------------------------------
            local sc = scan_comps[1]
            local cid = sc.id
            local c = components[cid]
            local bpr = blocks_per_row[cid]
            local total_bx = mcu_cols * c.h_samp
            local total_by = mcu_rows * c.v_samp
            -- Non-interleaved: MCU = one block, iterate all blocks
            local blocks_total = total_bx * total_by

            -- For restart interval in non-interleaved scans
            local ri_count = restart_interval
            if restart_interval > 0 then
                -- restart interval counts MCUs (= blocks for non-interleaved)
            end

            if is_dc_scan then
                -- DC scan for single component
                local dc_ht = dc_tables[sc.dc_table] or dc_tables[0]
                if not dc_ht then return nil end

                for by = 0, total_by - 1 do
                    for bx = 0, total_bx - 1 do
                        local bi = by * bpr + bx + 1
                        local block = coeff_blocks[cid][bi]

                        if restart_interval > 0 and mcu_count > 0
                           and mcu_count % restart_interval == 0 then
                            reader:reset()
                            while reader.p < #data do
                                local b = byte(data, reader.p)
                                reader.p = reader.p + 1
                                if b == 0xFF then
                                    local b2 = byte(data, reader.p)
                                    if b2 and b2 >= 0xD0 and b2 <= 0xD7 then
                                        reader.p = reader.p + 1
                                        break
                                    end
                                end
                            end
                            dc_pred[cid] = 0
                        end

                        if is_first then
                            local dc_len = huf_decode(reader, dc_ht)
                            local dc_val = receive(reader, dc_len)
                            dc_pred[cid] = dc_pred[cid] + dc_val
                            block[0] = dc_pred[cid] * al_shift
                        else
                            block[0] = block[0] + reader:bit() * al_shift
                        end
                        mcu_count = mcu_count + 1
                    end
                end

            elseif is_ac_scan and is_first then
                -- First AC scan: decode AC coefficients Ss..Se
                local ac_ht = ac_tables[sc.ac_table] or ac_tables[0]
                if not ac_ht then return nil end

                local eob_run = 0

                for by = 0, total_by - 1 do
                    for bx = 0, total_bx - 1 do
                        local bi = by * bpr + bx + 1
                        local block = coeff_blocks[cid][bi]

                        if restart_interval > 0 and mcu_count > 0
                           and mcu_count % restart_interval == 0 then
                            reader:reset()
                            while reader.p < #data do
                                local b = byte(data, reader.p)
                                reader.p = reader.p + 1
                                if b == 0xFF then
                                    local b2 = byte(data, reader.p)
                                    if b2 and b2 >= 0xD0 and b2 <= 0xD7 then
                                        reader.p = reader.p + 1
                                        break
                                    end
                                end
                            end
                            eob_run = 0
                            dc_pred[cid] = 0
                        end

                        if eob_run > 0 then
                            eob_run = eob_run - 1
                        else
                            local k = Ss
                            while k <= Se do
                                local rs = huf_decode(reader, ac_ht)
                                local rrrr = floor(rs / 16)
                                local ssss = rs % 16

                                if ssss == 0 then
                                    if rrrr == 15 then
                                        k = k + 16  -- ZRL: skip 16 zeros
                                    else
                                        -- EOBn: rrrr encodes run of blocks
                                        eob_run = 1
                                        local pow = 1
                                        for _ = 1, rrrr do pow = pow * 2 end
                                        eob_run = pow
                                        if rrrr > 0 then
                                            eob_run = eob_run + reader:bits(rrrr)
                                        end
                                        eob_run = eob_run - 1
                                        break
                                    end
                                else
                                    k = k + rrrr
                                    if k > Se then break end
                                    local ac_val = receive(reader, ssss)
                                    local nat = ZIGZAG[k + 1]
                                    block[nat] = ac_val * al_shift
                                    k = k + 1
                                end
                            end
                        end
                        mcu_count = mcu_count + 1
                    end
                end

            elseif is_ac_scan and not is_first then
                -- AC refinement scan
                local ac_ht = ac_tables[sc.ac_table] or ac_tables[0]
                if not ac_ht then return nil end

                local eob_run = 0

                for by = 0, total_by - 1 do
                    for bx = 0, total_bx - 1 do
                        local bi = by * bpr + bx + 1
                        local block = coeff_blocks[cid][bi]

                        if restart_interval > 0 and mcu_count > 0
                           and mcu_count % restart_interval == 0 then
                            reader:reset()
                            while reader.p < #data do
                                local b = byte(data, reader.p)
                                reader.p = reader.p + 1
                                if b == 0xFF then
                                    local b2 = byte(data, reader.p)
                                    if b2 and b2 >= 0xD0 and b2 <= 0xD7 then
                                        reader.p = reader.p + 1
                                        break
                                    end
                                end
                            end
                            eob_run = 0
                        end

                        if eob_run > 0 then
                            -- Refine existing nonzero coefficients
                            for k = Ss, Se do
                                local nat = ZIGZAG[k + 1]
                                if block[nat] ~= 0 then
                                    local bit = reader:bit()
                                    if bit == 1 then
                                        if block[nat] > 0 then
                                            block[nat] = block[nat] + al_shift
                                        else
                                            block[nat] = block[nat] - al_shift
                                        end
                                    end
                                end
                            end
                            eob_run = eob_run - 1
                        else
                            local k = Ss
                            while k <= Se do
                                local rs = huf_decode(reader, ac_ht)
                                local rrrr = floor(rs / 16)
                                local ssss = rs % 16

                                if ssss == 0 then
                                    if rrrr == 15 then
                                        -- ZRL + refine
                                        local zeros = 0
                                        while k <= Se and zeros < 16 do
                                            local nat = ZIGZAG[k + 1]
                                            if block[nat] ~= 0 then
                                                local bit = reader:bit()
                                                if bit == 1 then
                                                    if block[nat] > 0 then
                                                        block[nat] = block[nat] + al_shift
                                                    else
                                                        block[nat] = block[nat] - al_shift
                                                    end
                                                end
                                            else
                                                zeros = zeros + 1
                                            end
                                            k = k + 1
                                        end
                                    else
                                        -- EOBn
                                        eob_run = 1
                                        local pow = 1
                                        for _ = 1, rrrr do pow = pow * 2 end
                                        eob_run = pow
                                        if rrrr > 0 then
                                            eob_run = eob_run + reader:bits(rrrr)
                                        end
                                        -- Refine existing nonzero in remaining range
                                        for kk = k, Se do
                                            local nat = ZIGZAG[kk + 1]
                                            if block[nat] ~= 0 then
                                                local bit = reader:bit()
                                                if bit == 1 then
                                                    if block[nat] > 0 then
                                                        block[nat] = block[nat] + al_shift
                                                    else
                                                        block[nat] = block[nat] - al_shift
                                                    end
                                                end
                                            end
                                        end
                                        eob_run = eob_run - 1
                                        break
                                    end
                                else
                                    -- New nonzero coefficient + refine skipped
                                    local ac_val = receive(reader, ssss)
                                    local zeros = rrrr
                                    while k <= Se do
                                        local nat = ZIGZAG[k + 1]
                                        if block[nat] ~= 0 then
                                            local bit = reader:bit()
                                            if bit == 1 then
                                                if block[nat] > 0 then
                                                    block[nat] = block[nat] + al_shift
                                                else
                                                    block[nat] = block[nat] - al_shift
                                                end
                                            end
                                            k = k + 1
                                        elseif zeros == 0 then
                                            block[nat] = ac_val * al_shift
                                            k = k + 1
                                            break
                                        else
                                            zeros = zeros - 1
                                            k = k + 1
                                        end
                                    end
                                end
                            end
                        end
                        mcu_count = mcu_count + 1
                    end
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- Phase 4: Dequantize (progressive) + IDCT + convert to pixels
    ----------------------------------------------------------------
    local comp_data = {}
    local comp_w = {}

    for _, cid in ipairs(comp_order) do
        local c = components[cid]
        local bpr = blocks_per_row[cid]
        local total_bx = mcu_cols * c.h_samp
        local total_by = mcu_rows * c.v_samp
        local cw = total_bx * 8
        comp_w[cid] = cw
        local buf = {}
        comp_data[cid] = buf

        local qtab = qt[c.qt_id] or qt[0]

        for by = 0, total_by - 1 do
            for bx = 0, total_bx - 1 do
                local bi = by * bpr + bx + 1
                local block = coeff_blocks[cid][bi]

                -- For progressive: dequantize (baseline already did this inline)
                if is_progressive and qtab then
                    for i = 0, 63 do
                        block[i] = (block[i] or 0) * (qtab[i] or 1)
                    end
                end

                local pixels = idct_8x8(block)

                local px0 = bx * 8
                local py0 = by * 8
                for py = 0, 7 do
                    local row_off = (py0 + py) * cw + px0
                    for px = 0, 7 do
                        local val = floor(pixels[py * 8 + px] + 128.5)
                        if val < 0 then val = 0 elseif val > 255 then val = 255 end
                        buf[row_off + px + 1] = val
                    end
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- Phase 5: Convert to RGBA
    ----------------------------------------------------------------
    local rgba = {}
    local ri = 0

    if ncomp == 1 then
        local buf = comp_data[comp_order[1]]
        local cw = comp_w[comp_order[1]]
        for y = 0, height - 1 do
            for x = 0, width - 1 do
                local v = buf[y * cw + x + 1] or 128
                ri = ri + 1; rgba[ri] = v
                ri = ri + 1; rgba[ri] = v
                ri = ri + 1; rgba[ri] = v
                ri = ri + 1; rgba[ri] = 255
            end
        end
    elseif ncomp >= 3 then
        local y_id  = comp_order[1]
        local cb_id = comp_order[2]
        local cr_id = comp_order[3]
        local y_buf  = comp_data[y_id]
        local cb_buf = comp_data[cb_id]
        local cr_buf = comp_data[cr_id]
        local y_w  = comp_w[y_id]
        local cb_w = comp_w[cb_id]
        local cr_w = comp_w[cr_id]
        local cb_comp = components[cb_id]
        local cr_comp = components[cr_id]
        local cb_sx = max_h / cb_comp.h_samp
        local cb_sy = max_v / cb_comp.v_samp
        local cr_sx = max_h / cr_comp.h_samp
        local cr_sy = max_v / cr_comp.v_samp

        for y = 0, height - 1 do
            for x = 0, width - 1 do
                local yv  = (y_buf [y * y_w + x + 1] or 128)
                local cbv = (cb_buf[floor(y / cb_sy) * cb_w + floor(x / cb_sx) + 1] or 128)
                local crv = (cr_buf[floor(y / cr_sy) * cr_w + floor(x / cr_sx) + 1] or 128)

                local r = floor(yv + 1.402 * (crv - 128) + 0.5)
                local g = floor(yv - 0.344136 * (cbv - 128) - 0.714136 * (crv - 128) + 0.5)
                local b = floor(yv + 1.772 * (cbv - 128) + 0.5)

                if r < 0 then r = 0 elseif r > 255 then r = 255 end
                if g < 0 then g = 0 elseif g > 255 then g = 255 end
                if b < 0 then b = 0 elseif b > 255 then b = 255 end

                ri = ri + 1; rgba[ri] = r
                ri = ri + 1; rgba[ri] = g
                ri = ri + 1; rgba[ri] = b
                ri = ri + 1; rgba[ri] = 255
            end
        end
    else
        return nil
    end

    return rgba, width, height
end

return decode_jpeg



