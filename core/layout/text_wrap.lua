------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / text_wrap.lua
-- Multi-line text wrapping: whitespace normalization, word
-- segmentation, and greedy line-breaking.
--
-- Supports CSS white-space modes: normal, nowrap, pre,
-- pre-wrap, pre-line.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local TextWrap = {}

local SOFT_HYPHEN = string.char(0xC2, 0xAD)

-- Persistent cache: key -> lines array (survives across frames)
local _cache = {}
local _cache_count = 0
local CACHE_MAX = 4000

local function quantize_width_64(w)
    return math.floor((w or 0) * 64 + 0.5)
end

--- Evict the entire cache when it grows too large.
local function _maybe_evict()
    if _cache_count >= CACHE_MAX then
        _cache = {}
        _cache_count = 0
    end
end

------------------------------------------------------------
-- white_space mode flags
------------------------------------------------------------
-- { collapse_spaces, collapse_newlines, word_wrap }
local MODE_FLAGS = {
    normal    = { true,  true,  true  },
    nowrap    = { true,  true,  false },
    pre       = { false, false, false },
    ["pre-wrap"]  = { false, false, true  },
    ["pre-line"]  = { true,  false, true  },
}

------------------------------------------------------------
-- Whitespace normalization
------------------------------------------------------------

--- Normalize text according to white_space mode.
--- Returns the normalized string.
---@param text             string
---@param collapse_spaces  boolean
---@param collapse_newlines boolean
---@param tab_size         number|nil  tab stop width in spaces (default 8)
---@param preserve_lead    boolean|nil when true, keep one leading space if
---                       the input had any leading whitespace.  Used when
---                       the TEXT has an inline-formatting-context neighbour
---                       BEFORE it (inter-sibling gap, not a line edge).
---@param preserve_trail   boolean|nil mirror of preserve_lead for the
---                       trailing edge - only set when an inline-formatting
---                       neighbour follows this TEXT in the flow.
---@return string
local function normalize(text, collapse_spaces, collapse_newlines, tab_size, preserve_lead, preserve_trail)
    -- Normalize \r\n -> \n, \r -> \n
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    -- Expand tabs to spaces before any collapsing.
    -- In collapsing modes tabs will be collapsed anyway, but expanding
    -- first keeps pre/pre-wrap behavior correct.
    tab_size = tab_size or 8
    if tab_size and tab_size > 0 then
        local result = {}
        local col = 0
        local i = 1
        local len = #text
        while i <= len do
            local ch = text:sub(i, i)
            if ch == "\t" then
                local spaces = tab_size - (col % tab_size)
                result[#result + 1] = string.rep(" ", spaces)
                col = col + spaces
            else
                result[#result + 1] = ch
                col = col + 1
            end
            i = i + 1
        end
        text = table.concat(result)
    end

    if collapse_newlines then
        -- Replace newlines with spaces (they'll be collapsed next)
        text = text:gsub("\n", " ")
    end

    if collapse_spaces then
        -- Collapse runs of spaces to single space
        text = text:gsub(" +", " ")
        -- Trim leading/trailing spaces.  Edges are preserved only when the
        -- caller indicated this TEXT has an inline-formatting neighbour at
        -- that edge - CSS keeps inter-element whitespace as a single space
        -- but still trims line-edge whitespace (a leading inline at the
        -- start of a line, or a trailing inline at the end, should not
        -- introduce visible padding inside the parent box).
        local lead = ""
        local trail = ""
        if preserve_lead and text:match("^%s") then lead = " " end
        if preserve_trail and text:match("%s$") then trail = " " end
        local body = text:match("^%s*(.-)%s*$") or ""
        text = lead .. body .. trail
    end

    return text
end

------------------------------------------------------------
-- CJK codepoint detection (for word-break: keep-all)
------------------------------------------------------------

--- Check if a Unicode codepoint falls in a CJK Unified Ideograph range.
--- Covers CJK Unified Ideographs and Extension A, plus CJK Compatibility
--- Ideographs.  Does NOT include Hangul (which CSS keep-all also protects
--- but is less common in practice).
---@param cp number  Unicode codepoint
---@return boolean
local function is_cjk_cp(cp)
    -- CJK Unified Ideographs:              U+4E00 - U+9FFF
    -- CJK Unified Ideographs Extension A:  U+3400 - U+4DBF
    -- CJK Compatibility Ideographs:        U+F900 - U+FAFF
    -- CJK Unified Ideographs Extension B+: U+20000 - U+2A6DF  (SMP, rare)
    if cp >= 0x4E00 and cp <= 0x9FFF then return true end
    if cp >= 0x3400 and cp <= 0x4DBF then return true end
    if cp >= 0xF900 and cp <= 0xFAFF then return true end
    -- Hangul Syllables: U+AC00 - U+D7AF
    if cp >= 0xAC00 and cp <= 0xD7AF then return true end
    return false
end

--- Decode the first UTF-8 codepoint from `s` starting at byte `pos`.
--- Returns codepoint (number) and the byte length consumed.
---@param s   string
---@param pos number  1-based byte offset
---@return number, number  codepoint, byte_length
local function utf8_decode(s, pos)
    local b = s:byte(pos)
    if not b then return 0, 1 end
    if b < 0x80 then
        return b, 1
    elseif b < 0xE0 then
        local b2 = s:byte(pos + 1) or 0
        local cp = (b - 0xC0) * 64 + (b2 - 0x80)
        return cp, 2
    elseif b < 0xF0 then
        local b2 = s:byte(pos + 1) or 0
        local b3 = s:byte(pos + 2) or 0
        local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
        return cp, 3
    else
        local b2 = s:byte(pos + 1) or 0
        local b3 = s:byte(pos + 2) or 0
        local b4 = s:byte(pos + 3) or 0
        local cp = (b - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
        return cp, 4
    end
end

local function has_soft_hyphen(s)
    return s and s:find(SOFT_HYPHEN, 1, true) ~= nil
end

local function strip_soft_hyphens(s)
    if not has_soft_hyphen(s) then return s end
    return (s:gsub(SOFT_HYPHEN, ""))
end

local function split_soft_hyphen_parts(word)
    local parts = {}
    local start = 1
    while true do
        local pos = word:find(SOFT_HYPHEN, start, true)
        if not pos then
            parts[#parts + 1] = word:sub(start)
            break
        end
        parts[#parts + 1] = word:sub(start, pos - 1)
        start = pos + #SOFT_HYPHEN
    end
    return parts
end

local function join_soft_parts(parts, first_index)
    local out = {}
    for i = first_index, #parts do
        out[#out + 1] = parts[i]
    end
    return table.concat(out, SOFT_HYPHEN)
end

--- Check whether a word contains any CJK codepoints.
--- Short-circuits on the first CJK character found.
---@param word string
---@return boolean
local function word_has_cjk(word)
    local pos = 1
    local len = #word
    while pos <= len do
        local cp, blen = utf8_decode(word, pos)
        if is_cjk_cp(cp) then return true end
        pos = pos + blen
    end
    return false
end

------------------------------------------------------------
-- Word segmentation
------------------------------------------------------------

--- Split text into hard lines (on \n), then into words.
--- Returns array of hard lines, each an array of words.
---@param text              string
---@param collapse_newlines boolean
---@return table  array of { words = {string,...} }
local function segment(text, collapse_newlines)
    local hard_lines = {}

    if collapse_newlines then
        -- All on one logical line (newlines already collapsed)
        hard_lines[1] = { text = text }
    else
        -- Split on preserved newlines
        local start = 1
        while true do
            local nl = text:find("\n", start, true)
            if nl then
                hard_lines[#hard_lines + 1] = { text = text:sub(start, nl - 1) }
                start = nl + 1
            else
                hard_lines[#hard_lines + 1] = { text = text:sub(start) }
                break
            end
        end
    end

    -- Split each hard line into words (split on spaces).
    -- Track whether this hard line started/ended with whitespace so the
    -- caller can re-attach the edge space when preserve_edges is set
    -- (inline-flow context).  gmatch("%S+") discards all whitespace, so
    -- the edge information would otherwise be lost.
    for i = 1, #hard_lines do
        local words = {}
        local line_text = hard_lines[i].text
        for word in line_text:gmatch("%S+") do
            words[#words + 1] = word
        end
        hard_lines[i].words = words
        hard_lines[i].lead_space  = (line_text:match("^%s") ~= nil)
        hard_lines[i].trail_space = (line_text:match("%s$") ~= nil)
    end

    return hard_lines
end

------------------------------------------------------------
-- Greedy line-breaking
------------------------------------------------------------

--- Break a single word character-by-character into lines.
--- UTF-8 safe: determines codepoint byte length from leading byte.
---@param word      string  the word to break
---@param max_width number
---@param font_size number
---@param font_id   number
---@param measurer  table
---@param prefix    string  text already on the current line
---@param prefix_w  number  width of the prefix
---@return table  array of { text = string, width = number }
local function break_word_chars(word, max_width, font_size, font_id, measurer, prefix, prefix_w)
    local lines = {}
    local cur = prefix
    local cur_w = prefix_w
    local len = #word
    local pos = 1

    while pos <= len do
        -- Determine UTF-8 character byte length from leading byte
        local b = word:byte(pos)
        local char_len = 1
        if b >= 0xF0 then char_len = 4
        elseif b >= 0xE0 then char_len = 3
        elseif b >= 0xC0 then char_len = 2
        end
        if pos + char_len - 1 > len then char_len = len - pos + 1 end

        local ch = word:sub(pos, pos + char_len - 1)

        if cur == "" then
            cur = ch
            cur_w = measurer:measure_text_width(cur, font_size, font_id)
        else
            local candidate = cur .. ch
            local candidate_w = measurer:measure_text_width(candidate, font_size, font_id)
            if max_width > 0 and candidate_w > max_width then
                lines[#lines + 1] = { text = cur, width = cur_w }
                cur = ch
                cur_w = measurer:measure_text_width(cur, font_size, font_id)
            else
                cur = candidate
                cur_w = candidate_w
            end
        end

        pos = pos + char_len
    end

    -- Return remaining text as last partial line (caller appends)
    return lines, cur, cur_w
end

local function break_word_soft_hyphens(word, max_width, font_size, font_id, measurer, prefix)
    local lines = {}
    local remaining = word
    local line_prefix = prefix or ""

    while has_soft_hyphen(remaining) do
        local visible_remaining = strip_soft_hyphens(remaining)
        local full_candidate = line_prefix .. visible_remaining
        local full_w = measurer:measure_text_width(full_candidate, font_size, font_id)
        if max_width <= 0 or full_w <= max_width then
            return lines, full_candidate, full_w, #lines > 0
        end

        local parts = split_soft_hyphen_parts(remaining)
        local best_i, best_text, best_w = nil, nil, nil
        local accum = ""
        for i = 1, #parts - 1 do
            accum = accum .. parts[i]
            local candidate = line_prefix .. accum .. "-"
            local w = measurer:measure_text_width(candidate, font_size, font_id)
            if w <= max_width then
                best_i, best_text, best_w = i, candidate, w
            end
        end

        if not best_i then
            local visible = strip_soft_hyphens(remaining)
            return lines, visible, measurer:measure_text_width(visible, font_size, font_id), #lines > 0
        end

        lines[#lines + 1] = { text = best_text, width = best_w }
        remaining = join_soft_parts(parts, best_i + 1)
        line_prefix = ""
    end

    local visible = strip_soft_hyphens(remaining)
    return lines, visible, measurer:measure_text_width(visible, font_size, font_id), #lines > 0
end

--- Wrap words into lines using greedy algorithm (collapsed spaces).
--- Words are joined with single spaces.
--- Supports character-level breaking via word_break / overflow_wrap.
---@param words        table   array of word strings
---@param max_width    number  available width in pixels
---@param font_size    number
---@param font_id      number
---@param measurer     table   object with :measure_text_width(text, font_size, font_id)
---@param word_break   string  "normal"|"break-all"|"keep-all"
---@param overflow_wrap string "normal"|"break-word"
---@return table  array of { text = string, width = number }
local function wrap_words(words, max_width, font_size, font_id, measurer, word_break, overflow_wrap, first_line_shrink)
    if #words == 0 then
        return { { text = "", width = 0 } }
    end

    local break_all   = (word_break == "break-all")
    local keep_all    = (word_break == "keep-all")
    local break_word  = (overflow_wrap == "break-word")

    local lines = {}
    local current_text = ""
    local current_width = 0
    -- ::first-letter can make line 1 effectively narrower: the drop-cap
    -- takes more horizontal space than its normal-font-size counterpart
    -- would.  The delta is passed in `first_line_shrink` (non-negative)
    -- and applies only until the first line is flushed.
    first_line_shrink = first_line_shrink or 0
    local function line_max()
        if max_width <= 0 then return max_width end
        if #lines == 0 and first_line_shrink > 0 then
            local w = max_width - first_line_shrink
            return w > 0 and w or max_width
        end
        return max_width
    end

    for i = 1, #words do
        local word = words[i]
        local visible_word = strip_soft_hyphens(word)
        local word_w = measurer:measure_text_width(visible_word, font_size, font_id)

        -- keep-all: never character-break words that contain CJK codepoints.
        -- The word stays as one unbreakable unit regardless of width.
        local allow_char_break = not keep_all or not word_has_cjk(visible_word)

        local cur_max = line_max()

        if current_text == "" then
            -- First word on line
            if cur_max > 0 and word_w > cur_max and has_soft_hyphen(word) then
                local soft_lines, rem_text, rem_w, did_break = break_word_soft_hyphens(
                    word, cur_max, font_size, font_id, measurer, "")
                if did_break then
                    for j = 1, #soft_lines do
                        lines[#lines + 1] = soft_lines[j]
                    end
                    current_text = rem_text
                    current_width = rem_w
                else
                    current_text = visible_word
                    current_width = word_w
                end
            elseif cur_max > 0 and word_w > cur_max and allow_char_break and (break_all or break_word) then
                -- Word overflows -" break character-by-character
                local char_lines, rem_text, rem_w = break_word_chars(
                    visible_word, cur_max, font_size, font_id, measurer, "", 0)
                for j = 1, #char_lines do
                    lines[#lines + 1] = char_lines[j]
                end
                current_text = rem_text
                current_width = rem_w
            else
                current_text = visible_word
                current_width = word_w
            end
        else
            -- Would adding this word exceed max_width?
            -- Re-measure the FULL candidate line ("current_text .. ' ' .. word")
            -- instead of summing current_width + " " + word width. Chrome
            -- shapes the line as a single run -" kerning between the last
            -- char of current_text and the leading char of " " + word
            -- can shave 0.5-2px off the additive sum. The additive
            -- approach over-reported line widths and produced extra
            -- wrap points (text-indent / tw-normal-long had 1 extra
            -- line in engine vs Chrome -" exactly the cumulative
            -- per-line kerning under-count).
            local candidate = current_text .. " " .. visible_word
            local test_w = measurer:measure_text_width(candidate, font_size, font_id)
            if cur_max > 0 and test_w > cur_max then
                if has_soft_hyphen(word) then
                    local prefix = current_text .. " "
                    local soft_lines, rem_text, rem_w, did_break = break_word_soft_hyphens(
                        word, cur_max, font_size, font_id, measurer, prefix)
                    if did_break then
                        for j = 1, #soft_lines do
                            lines[#lines + 1] = soft_lines[j]
                        end
                        current_text = rem_text
                        current_width = rem_w
                    else
                        lines[#lines + 1] = { text = current_text, width = current_width }
                        cur_max = line_max()
                        soft_lines, rem_text, rem_w, did_break = break_word_soft_hyphens(
                            word, cur_max, font_size, font_id, measurer, "")
                        if did_break then
                            for j = 1, #soft_lines do
                                lines[#lines + 1] = soft_lines[j]
                            end
                            current_text = rem_text
                            current_width = rem_w
                        else
                            current_text = visible_word
                            current_width = word_w
                        end
                    end
                elseif break_all and allow_char_break then
                    -- break-all: break even mid-word at line boundary
                    local prefix = current_text .. " "
                    local prefix_w = measurer:measure_text_width(prefix, font_size, font_id)
                    local char_lines, rem_text, rem_w = break_word_chars(
                        visible_word, cur_max, font_size, font_id, measurer, prefix, prefix_w)
                    for j = 1, #char_lines do
                        lines[#lines + 1] = char_lines[j]
                    end
                    current_text = rem_text
                    current_width = rem_w
                elseif break_word and allow_char_break and word_w > cur_max then
                    -- overflow-wrap: break-word only when the word itself overflows
                    lines[#lines + 1] = { text = current_text, width = current_width }
                    local char_lines, rem_text, rem_w = break_word_chars(
                        visible_word, cur_max, font_size, font_id, measurer, "", 0)
                    for j = 1, #char_lines do
                        lines[#lines + 1] = char_lines[j]
                    end
                    current_text = rem_text
                    current_width = rem_w
                else
                    -- Normal / keep-all: finish current line, start new one
                    lines[#lines + 1] = { text = current_text, width = current_width }
                    current_text = visible_word
                    current_width = word_w
                end
            else
                current_text = current_text .. " " .. visible_word
                current_width = test_w
            end
        end
    end

    -- Don't forget the last line
    if current_text ~= "" or #lines == 0 then
        lines[#lines + 1] = { text = current_text, width = current_width }
    end

    return lines
end

--- Wrap a hard line preserving original whitespace (for pre-wrap).
--- Splits into (whitespace, word) segments so leading indentation
--- and multiple spaces between words are kept.
---@param line_text string  the raw hard-line text (spaces preserved)
---@param max_width number
---@param font_size number
---@param font_id   number
---@param measurer  table
---@return table  array of { text = string, width = number }
local function wrap_preserve_spaces(line_text, max_width, font_size, font_id, measurer)
    -- Split into segments: each is { ws = leading_whitespace, word = word }
    local segments = {}
    local pos = 1
    local len = #line_text
    while pos <= len do
        -- Capture leading whitespace
        local ws = ""
        while pos <= len and (line_text:sub(pos, pos) == " " or line_text:sub(pos, pos) == "\t") do
            ws = ws .. line_text:sub(pos, pos)
            pos = pos + 1
        end
        -- Capture word (non-space chars)
        local word_start = pos
        while pos <= len and line_text:sub(pos, pos) ~= " " and line_text:sub(pos, pos) ~= "\t" do
            pos = pos + 1
        end
        local word = line_text:sub(word_start, pos - 1)
        if #word > 0 or #ws > 0 then
            segments[#segments + 1] = { ws = ws, word = word }
        end
    end

    if #segments == 0 then
        -- All whitespace or empty
        local w = measurer:measure_text_width(line_text, font_size, font_id)
        return { { text = line_text, width = w } }
    end

    local lines = {}
    local current_text = ""
    local current_width = 0

    for i = 1, #segments do
        local seg = segments[i]
        local seg_text = seg.ws .. seg.word
        local seg_w = measurer:measure_text_width(seg_text, font_size, font_id)

        if current_text == "" then
            -- First segment on line: include leading whitespace
            current_text = seg_text
            current_width = seg_w
        else
            local test_w = current_width + seg_w
            if max_width > 0 and test_w > max_width then
                -- Wrap: finish current line
                lines[#lines + 1] = { text = current_text, width = current_width }
                -- New line starts with just the word (drop inter-word whitespace at wrap point)
                current_text = seg.word
                current_width = measurer:measure_text_width(seg.word, font_size, font_id)
            else
                current_text = current_text .. seg_text
                current_width = test_w
            end
        end
    end

    if current_text ~= "" or #lines == 0 then
        lines[#lines + 1] = { text = current_text, width = current_width }
    end

    return lines
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Wrap text into lines according to white_space mode.
---
---@param text          string   the text content
---@param max_width     number   available content width (pixels)
---@param font_size     number
---@param font_id       number
---@param white_space   string   "normal"|"nowrap"|"pre"|"pre-wrap"|"pre-line"
---@param line_h        number   line height in pixels
---@param measurer      table    object with :measure_text_width(text, font_size, font_id)
---@param word_break    string|nil  "normal"|"break-all"|"keep-all"  (optional)
---@param overflow_wrap string|nil  "normal"|"break-word" (optional)
---@param tab_size      number|nil  tab stop width in spaces (optional, default 8)
---@param preserve_lead  boolean|nil keep a leading space if the input had
---                       any leading whitespace.  Set by callers when the
---                       TEXT has an inline-formatting neighbour BEFORE
---                       it (inter-sibling gap, not a line edge).
---@param preserve_trail boolean|nil mirror of preserve_lead for trailing.
---@return table, number  lines: {{text=string, width=number},...}, total_h: number
function TextWrap.wrap(text, max_width, font_size, font_id, white_space, line_h, measurer, word_break, overflow_wrap, tab_size, text_wrap_mode, first_line_shrink, preserve_lead, preserve_trail, first_line_indent)
    -- Validate inputs
    text = text or ""
    white_space = white_space or "normal"
    word_break = word_break or "normal"
    overflow_wrap = overflow_wrap or "normal"
    if not MODE_FLAGS[white_space] then white_space = "normal" end

    -- Check cache (cache stores only lines; total_h computed fresh from line_h)
    tab_size = tab_size or 8
    local cache_key = text .. "\0" .. quantize_width_64(max_width) .. "\0" .. font_size .. "\0" .. font_id
                      .. "\0" .. white_space .. "\0" .. word_break .. "\0" .. overflow_wrap
                      .. "\0" .. tostring(tab_size)
                      .. "\0" .. tostring(text_wrap_mode or "wrap")
                      .. "\0" .. tostring(first_line_shrink or 0)
                      .. "\0" .. (preserve_lead and "1" or "0")
                      .. "\0" .. (preserve_trail and "1" or "0")
                      .. "\0" .. tostring(first_line_indent or 0)
    local cached = _cache[cache_key]
    if cached then
        return cached, #cached * line_h
    end

    local flags = MODE_FLAGS[white_space]
    local collapse_spaces   = flags[1]
    local collapse_newlines = flags[2]
    local do_wrap           = flags[3]

    -- Stage 1: Normalize (expand tabs according to tab_size)
    local norm = normalize(text, collapse_spaces, collapse_newlines, tab_size, preserve_lead, preserve_trail)

    -- Stage 2: Split into hard lines and words
    local hard_lines = segment(norm, collapse_newlines)

    -- Stage 3: Wrap (or not)
    local all_lines = {}

    for i = 1, #hard_lines do
        local hl = hard_lines[i]

        if do_wrap and max_width > 0 then
            -- Greedy word-wrap within this hard line
            local wrapped
            if collapse_spaces then
                -- Only apply first_line_shrink to the first hard line -" any
                -- explicit \n inside the text starts a fresh line at full
                -- width (consistent with browser line-layout behavior).
                local shrink = (i == 1) and first_line_shrink or nil
                wrapped = wrap_words(hl.words, max_width, font_size, font_id, measurer, word_break, overflow_wrap, shrink)
            else
                -- pre-wrap: preserve original whitespace
                wrapped = wrap_preserve_spaces(hl.text, max_width, font_size, font_id, measurer)
            end
            -- Edge spaces are preserved only on the side(s) the caller
            -- marked as an inline-formatting neighbour edge: re-attach the
            -- leading space to the first emitted line and the trailing
            -- space to the last so the inter-sibling whitespace survives
            -- word-wrap (segment() strips it when splitting on `%S+`).
            -- Width is updated to account for the extra space glyph; the
            -- painter renders it as part of the line.
            if collapse_spaces and #wrapped > 0 then
                if preserve_lead and hl.lead_space then
                    local first = wrapped[1]
                    local space_w = measurer:measure_text_width(" ", font_size, font_id)
                    first.text = " " .. first.text
                    first.width = first.width + space_w
                end
                if preserve_trail and hl.trail_space then
                    local last = wrapped[#wrapped]
                    local space_w = measurer:measure_text_width(" ", font_size, font_id)
                    last.text = last.text .. " "
                    last.width = last.width + space_w
                end
            end
            for j = 1, #wrapped do
                all_lines[#all_lines + 1] = wrapped[j]
            end
        else
            -- No wrapping: entire hard line is one output line
            local line_text
            if collapse_spaces then
                -- Words already split; rejoin with single spaces, then
                -- re-attach leading/trailing space when the caller
                -- requested edge-preservation for that side.
                line_text = table.concat(hl.words, " ")
                if preserve_lead and hl.lead_space  then
                    line_text = " " .. line_text
                end
                if preserve_trail and hl.trail_space then
                    line_text = line_text .. " "
                end
            else
                -- Preserve original text (pre/pre-wrap without wrap)
                line_text = hl.text
            end
            line_text = strip_soft_hyphens(line_text)
            local w = measurer:measure_text_width(line_text, font_size, font_id)
            all_lines[#all_lines + 1] = { text = line_text, width = w }
        end
    end

    -- Ensure at least one line
    if #all_lines == 0 then
        all_lines[1] = { text = "", width = 0 }
    end
    if first_line_indent and first_line_indent ~= 0 then
        all_lines[1].indent = first_line_indent
    end

    -- text-wrap: balance / pretty -" rebalance line lengths by binary-searching
    -- for the smallest max-width that keeps the same line count.
    if (text_wrap_mode == "balance" or text_wrap_mode == "pretty")
       and #all_lines > 1 and max_width > 0 then
        local target_line_count = #all_lines
        -- Find the widest line to use as upper bound
        local max_line_w = 0
        for i = 1, #all_lines do
            if all_lines[i].width > max_line_w then max_line_w = all_lines[i].width end
        end
        local lo = max_line_w
        local hi = max_width
        local best_lines = all_lines
        -- Max 6 iterations of binary search keeps cost bounded
        for _ = 1, 6 do
            if hi - lo <= 4 then break end
            local mid = (lo + hi) * 0.5
            local test_lines = {}
            for i = 1, #hard_lines do
                local hl = hard_lines[i]
                if do_wrap and collapse_spaces then
                    local w = wrap_words(hl.words, mid, font_size, font_id, measurer, word_break, overflow_wrap)
                    for j = 1, #w do test_lines[#test_lines + 1] = w[j] end
                else
                    test_lines[#test_lines + 1] = all_lines[1]
                end
            end
            if #test_lines == target_line_count then
                best_lines = test_lines
                hi = mid
            else
                lo = mid
            end
        end
        all_lines = best_lines
    end
    if first_line_indent and first_line_indent ~= 0 then
        all_lines[1].indent = first_line_indent
    end

    local total_h = #all_lines * line_h

    -- Store only lines in cache (total_h depends on line_h which varies per caller)
    if not _cache[cache_key] then
        _maybe_evict()
        _cache_count = _cache_count + 1
    end
    _cache[cache_key] = all_lines

    return all_lines, total_h
end

--- Soft-clear: the persistent cache is kept across frames.
--- Full eviction happens automatically when CACHE_MAX is reached.
function TextWrap.clear_cache()
    -- no-op: cache persists across frames for performance
end

--- Hard-flush: completely wipe the cache.
--- Call when measurement sources change (e.g. font finished loading).
function TextWrap.flush_cache()
    _cache = {}
    _cache_count = 0
end

return TextWrap



