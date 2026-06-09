------------------------------------------------------------
-- ext_core_astro_ui_lib / core / assets / png_decoder.lua
-- Minimal PNG -> RGBA decoder (pure Lua 5.1).
--
-- Handles PNG color types 0, 2, 3, 4, 6 at their valid
-- bit depths, including packed 1/2/4-bit gray/indexed rows,
-- 16-bit downsampling, tRNS transparency, and Adam7 interlace.
------------------------------------------------------------

local WoffDecoder = require("core/fonts/woff_decoder")
local zlib_decompress = WoffDecoder.zlib_decompress

local byte   = string.byte
local sub    = string.sub
local concat = table.concat
local floor  = math.floor

local PNG_SIG = "\137\080\078\071\013\010\026\010"

local function read_u32_be(data, off)
    local b1, b2, b3, b4 = byte(data, off, off + 3)
    if not b1 or not b2 or not b3 or not b4 then return nil end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function read_u16_be(data, off)
    local b1, b2 = byte(data, off, off + 1)
    if not b1 or not b2 then return nil end
    return b1 * 256 + b2
end

local function ceil_div(a, b)
    return floor((a + b - 1) / b)
end

local function paeth(a, b, c)
    local p  = a + b - c
    local pa = p - a; if pa < 0 then pa = -pa end
    local pb = p - b; if pb < 0 then pb = -pb end
    local pc = p - c; if pc < 0 then pc = -pc end
    if pa <= pb and pa <= pc then return a
    elseif pb <= pc then return b
    else return c end
end

local function valid_bit_depth(color_type, bit_depth)
    if color_type == 0 then
        return bit_depth == 1 or bit_depth == 2 or bit_depth == 4
            or bit_depth == 8 or bit_depth == 16
    elseif color_type == 2 then
        return bit_depth == 8 or bit_depth == 16
    elseif color_type == 3 then
        return bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8
    elseif color_type == 4 or color_type == 6 then
        return bit_depth == 8 or bit_depth == 16
    end
    return false
end

local function decode_png(data)
    if not data or #data < 33 then return nil end
    if sub(data, 1, 8) ~= PNG_SIG then return nil end

    local width, height, bit_depth, color_type, interlace_method
    local palette
    local trns
    local idat_parts = {}
    local pos = 9

    while pos + 8 <= #data do
        local chunk_len = read_u32_be(data, pos)
        if not chunk_len then return nil end
        local chunk_type = sub(data, pos + 4, pos + 7)
        local chunk_data_start = pos + 8
        local chunk_data_end = chunk_data_start + chunk_len - 1
        if chunk_data_end + 4 > #data then return nil end

        if chunk_type == "IHDR" then
            if chunk_len ~= 13 then return nil end
            width      = read_u32_be(data, chunk_data_start)
            height     = read_u32_be(data, chunk_data_start + 4)
            bit_depth  = byte(data, chunk_data_start + 8)
            color_type = byte(data, chunk_data_start + 9)
            local compression = byte(data, chunk_data_start + 10)
            local filter_method = byte(data, chunk_data_start + 11)
            interlace_method = byte(data, chunk_data_start + 12)
            if not width or not height or width <= 0 or height <= 0 then return nil end
            if compression ~= 0 or filter_method ~= 0 then return nil end
            if interlace_method ~= 0 and interlace_method ~= 1 then return nil end
        elseif chunk_type == "PLTE" then
            if chunk_len % 3 ~= 0 then return nil end
            palette = {}
            for i = 0, chunk_len - 1, 3 do
                local r, g, b = byte(data, chunk_data_start + i, chunk_data_start + i + 2)
                palette[#palette + 1] = r
                palette[#palette + 1] = g
                palette[#palette + 1] = b
            end
        elseif chunk_type == "tRNS" then
            trns = sub(data, chunk_data_start, chunk_data_end)
        elseif chunk_type == "IDAT" then
            idat_parts[#idat_parts + 1] = sub(data, chunk_data_start, chunk_data_end)
        elseif chunk_type == "IEND" then
            break
        end

        pos = chunk_data_end + 5
    end

    if not width or not height or #idat_parts == 0 then return nil end
    if not valid_bit_depth(color_type, bit_depth) then return nil end

    local ok, raw = pcall(zlib_decompress, concat(idat_parts))
    if not ok or not raw then return nil end

    local channels = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[color_type]
    if not channels then return nil end

    local filter_bpp = ceil_div(channels * bit_depth, 8)
    if filter_bpp < 1 then filter_bpp = 1 end

    local function row_stride(pixels)
        return ceil_div(pixels * channels * bit_depth, 8)
    end

    local function sample_at(row, sample_index)
        if bit_depth == 8 then
            return row[sample_index] or 0
        elseif bit_depth == 16 then
            local hi = row[(sample_index - 1) * 2 + 1] or 0
            local lo = row[(sample_index - 1) * 2 + 2] or 0
            return hi, hi * 256 + lo
        end
        local bit_pos = (sample_index - 1) * bit_depth
        local bi = floor(bit_pos / 8) + 1
        local shift = 8 - bit_depth - (bit_pos % 8)
        return floor((row[bi] or 0) / (2 ^ shift)) % (2 ^ bit_depth)
    end

    local function scale_sample(v)
        if bit_depth == 8 or bit_depth == 16 then return v or 0 end
        return floor((v or 0) * 255 / ((2 ^ bit_depth) - 1) + 0.5)
    end

    local pal_alpha
    if color_type == 3 and trns then
        pal_alpha = {}
        for i = 1, #trns do pal_alpha[i - 1] = byte(trns, i) end
    end

    local trns_r, trns_g, trns_b
    if color_type == 0 and trns and #trns >= 2 then
        trns_r = read_u16_be(trns, 1)
    elseif color_type == 2 and trns and #trns >= 6 then
        trns_r = read_u16_be(trns, 1)
        trns_g = read_u16_be(trns, 3)
        trns_b = read_u16_be(trns, 5)
    end

    local rgba = {}
    for i = 1, width * height * 4 do rgba[i] = 0 end

    local passes = (interlace_method == 1) and {
        {0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8},
        {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2},
        {0, 1, 1, 2},
    } or { {0, 0, 1, 1} }

    local raw_pos = 1
    for pass_i = 1, #passes do
        local pass = passes[pass_i]
        local x0, y0, dx, dy = pass[1], pass[2], pass[3], pass[4]
        local pw = (width > x0) and ceil_div(width - x0, dx) or 0
        local ph = (height > y0) and ceil_div(height - y0, dy) or 0
        if pw > 0 and ph > 0 then
            local stride = row_stride(pw)
            local curr, prev = {}, {}
            for i = 1, stride do prev[i] = 0 end

            for row_i = 0, ph - 1 do
                local filter = byte(raw, raw_pos)
                if not filter then return nil end
                raw_pos = raw_pos + 1

                for i = 1, stride do
                    curr[i] = byte(raw, raw_pos)
                    if curr[i] == nil then return nil end
                    raw_pos = raw_pos + 1
                end

                if filter == 1 then
                    for i = filter_bpp + 1, stride do
                        curr[i] = (curr[i] + curr[i - filter_bpp]) % 256
                    end
                elseif filter == 2 then
                    for i = 1, stride do curr[i] = (curr[i] + prev[i]) % 256 end
                elseif filter == 3 then
                    for i = 1, stride do
                        local left = (i > filter_bpp) and curr[i - filter_bpp] or 0
                        curr[i] = (curr[i] + floor((left + prev[i]) / 2)) % 256
                    end
                elseif filter == 4 then
                    for i = 1, stride do
                        local left = (i > filter_bpp) and curr[i - filter_bpp] or 0
                        local up = prev[i]
                        local upleft = (i > filter_bpp) and prev[i - filter_bpp] or 0
                        curr[i] = (curr[i] + paeth(left, up, upleft)) % 256
                    end
                elseif filter ~= 0 then
                    return nil
                end

                local y = y0 + row_i * dy
                for px = 0, pw - 1 do
                    local x = x0 + px * dx
                    local ri = (y * width + x) * 4
                    if color_type == 6 then
                        local si = px * 4 + 1
                        rgba[ri + 1] = sample_at(curr, si)
                        rgba[ri + 2] = sample_at(curr, si + 1)
                        rgba[ri + 3] = sample_at(curr, si + 2)
                        rgba[ri + 4] = sample_at(curr, si + 3)
                    elseif color_type == 2 then
                        local si = px * 3 + 1
                        local r, r16 = sample_at(curr, si)
                        local g, g16 = sample_at(curr, si + 1)
                        local b, b16 = sample_at(curr, si + 2)
                        rgba[ri + 1], rgba[ri + 2], rgba[ri + 3] = r, g, b
                        rgba[ri + 4] = (trns_r and (r16 or r) == trns_r
                            and (g16 or g) == trns_g and (b16 or b) == trns_b) and 0 or 255
                    elseif color_type == 0 then
                        local raw_v, raw16 = sample_at(curr, px + 1)
                        local v = scale_sample(raw_v)
                        rgba[ri + 1], rgba[ri + 2], rgba[ri + 3] = v, v, v
                        rgba[ri + 4] = (trns_r and (raw16 or raw_v) == trns_r) and 0 or 255
                    elseif color_type == 4 then
                        local si = px * 2 + 1
                        local v = sample_at(curr, si)
                        rgba[ri + 1], rgba[ri + 2], rgba[ri + 3] = v, v, v
                        rgba[ri + 4] = sample_at(curr, si + 1)
                    elseif color_type == 3 then
                        if not palette then return nil end
                        local idx = sample_at(curr, px + 1)
                        local pi = idx * 3
                        rgba[ri + 1] = palette[pi + 1] or 0
                        rgba[ri + 2] = palette[pi + 2] or 0
                        rgba[ri + 3] = palette[pi + 3] or 0
                        rgba[ri + 4] = pal_alpha and (pal_alpha[idx] or 255) or 255
                    end
                end

                prev, curr = curr, prev
            end
        end
    end

    return rgba, width, height
end

return decode_png



