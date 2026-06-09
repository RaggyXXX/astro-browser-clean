------------------------------------------------------------
-- ext_core_astro_ui_lib / core / layout / inline.lua
-- Inline run layout: horizontal flow with line wrapping.
-- Handles display: inline and inline-block children grouped
-- into consecutive runs by the parent block layout.
--
-- Two-pass layout: (1) measure + line-break, (2) vertical
-- alignment adjustment per line (vertical-align).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local ValueVM    = require("core/style/value_vm")
local GlyphCache = require("core/fonts/glyph_cache")

local Inline = {}

--- Resolve a numeric value (margin, padding, etc.), defaulting to 0.
local function resolve_num(val, context)
    if val == nil then return 0 end
    local resolved = ValueVM.resolve(val, context)
    if type(resolved) == "number" then return resolved end
    return 0
end

local function resolve_font_size(raw, engine, avail_w, avail_h, parent_font_size)
    if raw == nil then return parent_font_size or 16 end
    if type(raw) == "number" then return raw end
    if raw == "larger" then return (parent_font_size or 16) * 1.2 end
    if raw == "smaller" then return (parent_font_size or 16) / 1.2 end
    local boot = {
        parent_width = avail_w, parent_height = avail_h,
        percent_base = parent_font_size or 16,
        font_size = parent_font_size or 16, viewport_w = engine.viewport_w or 0,
        viewport_h = engine.viewport_h or 0, root_font_size = engine.root_font_size or 16,
    }
    local resolved = ValueVM.resolve(raw, boot)
    if type(resolved) == "number" then return resolved end
    return parent_font_size or 16
end

local function is_inline_display(display)
    return display == "inline" or display == "inline-block"
        or display == "inline-flex" or display == "inline-grid"
end

--- Greedy word-split of inline text across a line break. The first
--- output fragment must fit in `first_w` CSS px; subsequent fragments
--- may use up to `rest_w` CSS px each (one fragment per output line).
---
--- Used by `Inline.layout_run` when a `<span>` with a single TEXT child
--- doesn't fit in the remaining inline-axis space. Without this, the
--- engine bumps the whole span onto a new line as an atomic box, even
--- though browsers split text content at word boundaries and let the
--- first word(s) continue at the end of the current line. See the
--- C-lite implementation note in the call site for the constraints
--- (no inline-block, no nested inline children, normal white-space).
---
--- Returns an array of `{ text, width }` fragments - or `nil` if even
--- a single word from the start of `text` is wider than `first_w`
--- (caller falls back to the legacy whole-box wrap).
---@param engine       table   LayoutEngine (provides measure_text_width)
---@param text         string  text content to split
---@param first_w      number  available width on the current line
---@param rest_w       number  available width on subsequent lines
---@param font_size    number
---@param font_family  string|nil
---@param font_weight  number|nil
---@param font_style   string|nil
---@return table|nil
local function split_text_to_fit(engine, text, first_w, rest_w,
                                  font_size, font_family, font_weight, font_style)
    if not text or text == "" or first_w <= 0 or rest_w <= 0 then return nil end
    local measure = function(s)
        return engine:measure_text_width(s, font_size, 0,
            font_family, font_weight, font_style)
    end
    -- Tokenise into runs of whitespace and runs of non-whitespace, preserving
    -- both. Browsers consume one trailing breakable space at a line break;
    -- we keep the structure simple by attaching leading whitespace to the
    -- following word (e.g. " all" stays together so " " + "all" can fit on
    -- the current line as a unit rather than orphaning the space).
    local tokens = {}
    local i = 1
    local n = #text
    while i <= n do
        local b = text:byte(i)
        if b == 32 or b == 9 then
            -- Run of whitespace
            local j = i
            while j <= n do
                local bb = text:byte(j)
                if bb ~= 32 and bb ~= 9 then break end
                j = j + 1
            end
            tokens[#tokens + 1] = { kind = "ws", text = text:sub(i, j - 1) }
            i = j
        else
            local j = i
            while j <= n do
                local bb = text:byte(j)
                if bb == 32 or bb == 9 then break end
                j = j + 1
            end
            tokens[#tokens + 1] = { kind = "word", text = text:sub(i, j - 1) }
            i = j
        end
    end
    if #tokens == 0 then return nil end

    -- Greedily consume tokens into the current line until adding the next
    -- token would overflow. If at least one word lands on the first line,
    -- record the fragment and start a new fragment for the remainder.
    local frags = {}
    local cur = ""
    local cur_w = 0
    local cur_limit = first_w
    local has_word_on_cur_line = false

    local function flush()
        if cur ~= "" then
            -- Browser behavior: trailing whitespace at a soft break is
            -- collapsed (visible width contributed by the break-eligible
            -- space disappears). Strip it from the fragment before push.
            local trimmed = cur:gsub("%s+$", "")
            local trimmed_w = trimmed == cur and cur_w or measure(trimmed)
            frags[#frags + 1] = { text = trimmed, width = trimmed_w }
        end
        cur = ""
        cur_w = 0
        has_word_on_cur_line = false
    end

    for ti = 1, #tokens do
        local tk = tokens[ti]
        local tw = measure(tk.text)
        if tk.kind == "ws" then
            -- Whitespace just extends the running line; never starts a
            -- fresh fragment on its own.
            if cur == "" and #frags >= 1 then
                -- Leading whitespace of a non-first fragment is collapsed
                -- per the soft-break rule; skip.
            else
                if cur_w + tw <= cur_limit then
                    cur = cur .. tk.text
                    cur_w = cur_w + tw
                else
                    -- Even whitespace can't fit (rare); fall through to
                    -- break at the next word.
                end
            end
        else
            if cur_w + tw <= cur_limit then
                cur = cur .. tk.text
                cur_w = cur_w + tw
                has_word_on_cur_line = true
            else
                -- This word doesn't fit on the current line. Break.
                if not has_word_on_cur_line then
                    -- The first line couldn't fit even one word - caller
                    -- must fall back to the legacy "wrap whole box to
                    -- next line" path.
                    if #frags == 0 then return nil end
                end
                flush()
                cur_limit = rest_w
                -- Place the unfit word at the start of the new fragment.
                if tw > cur_limit then
                    -- A single word is wider than the full content width.
                    -- Place it solo and let later passes handle overflow
                    -- (Chrome lets it overhang; we just emit it).
                    cur = tk.text
                    cur_w = tw
                    has_word_on_cur_line = true
                else
                    cur = tk.text
                    cur_w = tw
                    has_word_on_cur_line = true
                end
            end
        end
    end
    flush()
    if #frags < 2 then return nil end
    return frags
end

--- Compute whether the leading/trailing whitespace of this TEXT contributes
--- to the laid-out width.  Mirrors the rule in block.lua's text-leaf branch
--- and painters.lua so all three modules stay in sync on which edge spaces
--- are interior (inter-sibling) vs line-edge (collapsed).
---@return boolean preserve_lead, boolean preserve_trail
local function _preserve_edges_for_text(ns, nid)
    if ns.node_type[nid] ~= ns.TEXT then return false, false end
    local lead, trail = false, false
    local cur = nid
    while cur and cur ~= 0 do
        local parent = ns.parent[cur]
        if not parent or parent == 0 then break end
        local prev = ns.prev_sibling[cur] or 0
        local nxt  = ns.next_sibling[cur] or 0
        if (not lead) and prev ~= 0 then lead = true end
        if (not trail) and nxt ~= 0 then trail = true end
        if lead and trail then break end
        local ppc = ns.computed[parent]
        local pdisp = ppc and ppc.display or "block"
        local is_inline_ancestor = (pdisp == "inline" or pdisp == "inline-block"
                                    or pdisp == "inline-flex" or pdisp == "inline-grid")
        if not is_inline_ancestor then break end
        cur = parent
    end
    return lead, trail
end

local function preferred_text_width(engine, ns, nid, font_size)
    local cm = ns.computed[nid] or {}
    local text = ns.text_content[nid] or ""
    local font_family = cm.font_family
    local font_weight = cm.font_weight or 400
    local font_style = cm.font_style or "normal"
    -- For width sizing, drop the leading/trailing whitespace that
    -- TextWrap will trim during the layout / paint pass.  Without this
    -- correction the inline run reserves space for an edge that won't be
    -- rendered (e.g. `<p><span> X </span></p>` reserves " X " = 5 chars
    -- but only " X" = 4 are kept once the trailing line-edge space is
    -- collapsed).
    local p_lead, p_trail = _preserve_edges_for_text(ns, nid)
    local measure_text = text
    if cm.white_space == nil or cm.white_space == "normal"
       or cm.white_space == "nowrap" or cm.white_space == "pre-line" then
        if not p_lead  then measure_text = measure_text:gsub("^%s+", "") end
        if not p_trail then measure_text = measure_text:gsub("%s+$", "") end
        -- Collapse interior whitespace to single spaces -" TextWrap does
        -- the same and we want widths to match.
        measure_text = measure_text:gsub("%s+", " ")
    end
    local w = engine:measure_text_width(measure_text, font_size, 0, font_family, font_weight, font_style)
    local white_space = cm.white_space or "normal"
    if white_space == "normal" or white_space == "nowrap" or white_space == "pre-line" then
        local words = {}
        for word in measure_text:gmatch("%S+") do
            words[#words + 1] = word
        end
        if #words > 0 then
            local wrapped_w = 0
            local space_w = engine:measure_text_width(" ", font_size, 0, font_family, font_weight, font_style)
            for i = 1, #words do
                if i > 1 then wrapped_w = wrapped_w + space_w end
                wrapped_w = wrapped_w + engine:measure_text_width(words[i], font_size, 0, font_family, font_weight, font_style)
            end
            -- Re-include preserved edge spaces so wrapped_w reflects the
            -- actual reserved width.
            if p_lead  and measure_text:match("^%s") then
                wrapped_w = wrapped_w + space_w
            end
            if p_trail and measure_text:match("%s$") then
                wrapped_w = wrapped_w + space_w
            end
            if wrapped_w > w then w = wrapped_w end
        end
    end
    return math.ceil(w)
end

local function measure_inline_intrinsic(engine, ns, nid, avail_w, avail_h, parent_font_size, depth)
    if depth > 16 then
        return engine:measure(nid, avail_w, avail_h)
    end

    local cm = ns.computed[nid] or {}
    local display = cm.display or "block"
    if ns.node_type[nid] == ns.TEXT or display ~= "inline" then
        return engine:measure(nid, avail_w, avail_h)
    end

    local ctx = {
        parent_width   = avail_w,
        parent_height  = avail_h,
        font_size      = resolve_font_size(cm.font_size, engine, avail_w, avail_h, parent_font_size),
        viewport_w     = engine.viewport_w or 0,
        viewport_h     = engine.viewport_h or 0,
        root_font_size = engine.root_font_size or 16,
    }
    local padding_l = resolve_num(cm.padding_left, ctx)
    local padding_r = resolve_num(cm.padding_right, ctx)
    local padding_t = resolve_num(cm.padding_top, ctx)
    local padding_b = resolve_num(cm.padding_bottom, ctx)
    local border_w = resolve_num(cm.border_width, ctx)
    local border_l = cm.border_left_width == nil and border_w or resolve_num(cm.border_left_width, ctx)
    local border_r = cm.border_right_width == nil and border_w or resolve_num(cm.border_right_width, ctx)
    local border_t = cm.border_top_width == nil and border_w or resolve_num(cm.border_top_width, ctx)
    local border_b = cm.border_bottom_width == nil and border_w or resolve_num(cm.border_bottom_width, ctx)

    local content_w = 0
    local content_h = 0
    local child = ns.first_child[nid] or 0
    if child == 0 then
        return engine:measure(nid, avail_w, avail_h)
    end

    while child ~= 0 do
        local child_cm = ns.computed[child] or {}
        local child_display = child_cm.display or "block"
        if ns.node_type[child] == ns.TEXT and child_display == "block" then
            child_display = "inline"
        end
        if child_display ~= "none" then
            local cw, ch
            if ns.node_type[child] == ns.TEXT or child_display == "inline" then
                cw, ch = measure_inline_intrinsic(engine, ns, child, avail_w, avail_h, ctx.font_size, depth + 1)
            else
                cw, ch = engine:measure(child, avail_w, avail_h)
            end
            local child_ctx = {
                parent_width   = avail_w,
                parent_height  = avail_h,
                font_size      = resolve_font_size(child_cm.font_size, engine, avail_w, avail_h, ctx.font_size),
                viewport_w     = engine.viewport_w or 0,
                viewport_h     = engine.viewport_h or 0,
                root_font_size = engine.root_font_size or 16,
            }
            local ml = resolve_num(child_cm.margin_left, child_ctx)
            local mr = resolve_num(child_cm.margin_right, child_ctx)
            local mt = resolve_num(child_cm.margin_top, child_ctx)
            local mb = resolve_num(child_cm.margin_bottom, child_ctx)
            content_w = content_w + ml + cw + mr
            local outer_h = mt + ch + mb
            if outer_h > content_h then content_h = outer_h end
        end
        child = ns.next_sibling[child] or 0
    end

    return content_w + padding_l + padding_r + border_l + border_r,
           content_h + padding_t + padding_b + border_t + border_b
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

--- Recursively offset a node and all its descendants by dy.
---@param ns   table   NodeStore
---@param nid  number  node id
---@param dy   number  vertical offset
local function offset_subtree(ns, nid, dy)
    local lay = ns.layout[nid]
    if lay then
        lay.y = lay.y + dy
        lay.content_y = lay.content_y + dy
    end
    local cid = ns.first_child[nid]
    if not cid then cid = 0 end
    while cid ~= 0 do
        offset_subtree(ns, cid, dy)
        cid = ns.next_sibling[cid] or 0
    end
end

------------------------------------------------------------
-- Inline run layout
------------------------------------------------------------

--- Layout a run of consecutive inline / inline-block children
--- horizontally, wrapping to the next line when they exceed
--- the available width.
---
---@param engine      table   LayoutEngine instance
---@param ns          table   NodeStore instance
---@param children    table   array of child node ids
---@param content_x   number  left edge of the content area
---@param start_y     number  y position for the first line
---@param content_w   number  available content width
---@param avail_h     number  available height
---@param container_h number  parent's explicit content height (0 = auto)
---@return number  total_h   total height consumed by all lines
---@return number  max_line_w widest line width (for intrinsic sizing)
function Inline.layout_run(engine, ns, children, content_x, start_y, content_w, avail_h, container_h, parent_font_size, parent_font_family, parent_font_weight, parent_font_style, parent_line_height)
    -- ===========================================================
    -- Pass 1: Measure, lay out, and assign children to lines
    -- ===========================================================
    -- CSS 2.1 §10.8.1 strut: every line box contains an invisible inline
    -- box sized from the container's font metrics.  Without this an empty
    -- `<span></span>` collapses to 0px height; with it, the line keeps
    -- font_size * line-height worth of vertical space even when empty.
    --
    -- Strut height = container's resolved `line-height: normal`, which is
    -- the font-metric (ascent + |descent| + line_gap) from the hhea
    -- table -" NOT a hardcoded 1.2 multiplier. Chrome's "normal" for
    -- Inter 14px lands around 17.27 (not 16.8 from 14 * 1.2), so the
    -- old hardcode produced ~0.5 px tighter per line, accumulating to
    -- visible drift across multi-line paragraphs vs Chrome.
    local pfs = parent_font_size or 16
    local strut_h
    do
        local dpr = (engine and engine._dpr) or 1
        local cache = nil
        local fm = engine and engine.font_manager
        if fm and parent_font_family and fm.get_cache_for then
            cache = fm:get_cache_for(parent_font_family,
                parent_font_weight or 400, parent_font_style or "normal")
        end
        if (parent_line_height == nil or parent_line_height == "normal")
           and engine and engine.platform
           and type(engine.platform.get_normal_line_height) == "function" then
            local ok, h = pcall(engine.platform.get_normal_line_height,
                engine.platform, parent_font_family, pfs, dpr,
                parent_font_weight or 400, parent_font_style or "normal")
            if ok and type(h) == "number" and h > 0 then
                strut_h = h
            end
        end
        if not strut_h
           and engine and engine.platform
           and type(engine.platform.resolve_line_height) == "function" then
            local ok, h = pcall(engine.platform.resolve_line_height,
                engine.platform, parent_line_height, parent_font_family, pfs, dpr,
                parent_font_weight or 400, parent_font_style or "normal")
            if ok and type(h) == "number" and h > 0 then
                strut_h = h
            end
        end
        if not strut_h then
            strut_h = GlyphCache.resolve_line_height(cache, parent_line_height, pfs, dpr)
        end
        -- Quantize to integer CSS px for the line-box stacking pass.
        -- Inline line-box `y` positions are computed by summing strut
        -- heights; without integer quantization the cumulative fractional
        -- residue drifts paragraph bottoms by ~1-3 CSS px (empirically
        -- regresses 7+ parity cases). The device-pixel rounding already
        -- happened inside the resolver -" this is a separate, pre-existing
        -- pixel-snap policy for line stacking, not a duplicate rounding.
        strut_h = math.floor(strut_h + 0.5)
    end
    local lines = {}          -- array of { items = {}, h = 0, y = 0, w = 0 }
    local cur_line = { items = {}, h = strut_h, y = start_y, w = 0 }
    lines[1] = cur_line
    local line_x = content_x

    for i = 1, #children do
        local cid = children[i]
        local child_cm = ns.computed[cid] or {}
        local ctx = {
            parent_width   = content_w,
            parent_height  = avail_h,
            font_size      = resolve_font_size(child_cm.font_size, engine, content_w, avail_h, parent_font_size),
            viewport_w     = engine.viewport_w or 0,
            viewport_h     = engine.viewport_h or 0,
            root_font_size = engine.root_font_size or 16,
        }

        -- Write resolved font_size back so painters can use it
        child_cm.font_size = ctx.font_size

        local ml = resolve_num(child_cm.margin_left, ctx)
        local mr = resolve_num(child_cm.margin_right, ctx)
        local mt = resolve_num(child_cm.margin_top, ctx)
        local mb = resolve_num(child_cm.margin_bottom, ctx)

        -- Measure intrinsic size (shrink-to-fit). Inline elements with
        -- inline children need their text descendants summed, not the
        -- available parent width, otherwise <a>/<strong>/<em> force line
        -- breaks between every inline tag.
        local mw, mh
        if child_cm.display == "inline" and (ns.first_child[cid] or 0) ~= 0 then
            mw, mh = measure_inline_intrinsic(engine, ns, cid, content_w, avail_h, parent_font_size, 0)
        else
            mw, mh = engine:measure(cid, content_w, avail_h)
        end

        -- TEXT nodes should wrap to container width, not use intrinsic
        -- (full unwrapped) width.  This matches browser behavior where
        -- inline text wraps within the containing block.
        local is_text_node = (ns.node_type[cid] == ns.TEXT)
        local layout_w = mw
        if is_text_node then
            local preferred_w = preferred_text_width(engine, ns, cid, ctx.font_size)
            if preferred_w > layout_w then layout_w = preferred_w end
        end
        if is_text_node and layout_w > content_w then
            layout_w = content_w
        end

        local advance = ml + layout_w + mr

        -- C-lite inline text fragment split. When an inline `<span>` with
        -- a single TEXT child can't fit fully on the current line, try
        -- to word-split its text so the first words continue at the end
        -- of the current line and the remainder wraps to the next line.
        -- Without this the whole span is bumped atomically to a fresh
        -- line, which is visibly wrong for paragraphs mixing inline runs
        -- (e.g. `<p>Plain <strong>bold</strong> ... <span>all on one line.</span></p>`
        -- in the `inline-mixed-runs` case).
        --
        -- Constraints (keep risk low -" anything we don't match falls back
        -- to the legacy whole-box wrap path):
        --   * `child_cm.display == "inline"` (not inline-block / replaced)
        --   * exactly one TEXT child, no element children
        --   * `white-space: normal` (pre/nowrap/etc keep their atomic rules)
        --   * current line already has content (line_x > content_x)
        --   * box doesn't fit on remaining inline-axis space
        local placed_via_fragments = false
        if line_x > content_x
           and line_x + advance > content_x + content_w + 2
           and not is_text_node
           and child_cm.display == "inline"
        then
            local text_cid = ns.first_child[cid] or 0
            local text_sib = text_cid ~= 0 and (ns.next_sibling[text_cid] or 0) or 0
            if text_cid ~= 0 and text_sib == 0
               and ns.node_type[text_cid] == ns.TEXT
            then
                local span_ws = child_cm.white_space or "normal"
                if span_ws == "normal" then
                    local remaining_w = content_x + content_w - line_x - ml - mr
                    local full_w      = content_w - ml - mr
                    if remaining_w > 0 and full_w > 0 then
                        local ttext = ns.text_content[text_cid] or ""
                        local frags = split_text_to_fit(engine, ttext,
                            remaining_w, full_w,
                            ctx.font_size,
                            child_cm.font_family, child_cm.font_weight, child_cm.font_style)
                        if frags then
                            -- Build per-fragment paint records and place the
                            -- span across `#frags` consecutive lines.
                            if not ns.layout[text_cid] then ns.layout[text_cid] = {} end
                            local tlay = ns.layout[text_cid]
                            local frag_records = {}
                            local min_x = math.huge
                            local max_x = -math.huge
                            local first_y = cur_line.y
                            -- Fragment 1: continues at end of current line.
                            -- IMPORTANT: do NOT push the span to cur_line.items
                            -- -" pass 2 (vertical-align) would then walk each
                            -- fragment-line and shift the SPAN's layout.y
                            -- once per fragment, compounding the offset and
                            -- pushing the union bbox down by N*strut_h. The
                            -- fragments carry their own pre-computed y; the
                            -- pass-2 baseline shift is meaningless for them.
                            -- Strut-h already keeps each fragment-line tall
                            -- enough so cur_line.h doesn't need updating.
                            local f1 = frags[1]
                            local f1_x = line_x + ml
                            frag_records[1] = { text = f1.text, x = f1_x, y = cur_line.y, w = f1.width, h = strut_h }
                            if f1_x < min_x then min_x = f1_x end
                            if f1_x + f1.width > max_x then max_x = f1_x + f1.width end
                            cur_line.w = (f1_x + f1.width) - content_x
                            -- Fragments 2..N: each on its own new line, left-aligned
                            for fi = 2, #frags do
                                local f = frags[fi]
                                local new_y = cur_line.y + cur_line.h
                                cur_line = { items = {}, h = strut_h, y = new_y, w = 0 }
                                lines[#lines + 1] = cur_line
                                local fx = content_x + ml
                                frag_records[fi] = { text = f.text, x = fx, y = cur_line.y, w = f.width, h = strut_h }
                                if fx < min_x then min_x = fx end
                                if fx + f.width > max_x then max_x = fx + f.width end
                                cur_line.w = (fx + f.width) - content_x
                            end
                            -- TEXT child layout: union bbox + fragment list
                            tlay.x = min_x
                            tlay.y = first_y
                            tlay.w = max_x - min_x
                            tlay.h = (cur_line.y + cur_line.h) - first_y
                            tlay.content_x = tlay.x
                            tlay.content_y = tlay.y
                            tlay.content_w = tlay.w
                            tlay.content_h = tlay.h
                            tlay.fragments = frag_records
                            -- Span layout: same union bbox
                            local slay = ns.layout[cid] or {}
                            slay.x = tlay.x
                            slay.y = tlay.y
                            slay.w = tlay.w
                            slay.h = tlay.h
                            slay.content_x = tlay.x
                            slay.content_y = tlay.y
                            slay.content_w = tlay.w
                            slay.content_h = tlay.h
                            ns.layout[cid] = slay
                            -- Advance line_x past the last fragment
                            line_x = content_x + frags[#frags].width + ml + mr
                            placed_via_fragments = true
                        end
                    end
                end
            end
        end

        if not placed_via_fragments then
            -- Wrap to next line if item doesn't fit and line isn't empty
            if line_x + advance > content_x + content_w + 2 and line_x > content_x then
                cur_line.w = line_x - content_x
                -- Start new line -" strut height keeps empty lines visible.
                local new_y = cur_line.y + cur_line.h
                cur_line = { items = {}, h = strut_h, y = new_y, w = 0 }
                lines[#lines + 1] = cur_line
                line_x = content_x
            end

            -- Position child: TEXT nodes use container width for wrapping
            engine:_layout_node(cid, line_x, cur_line.y, layout_w + ml + mr, avail_h)

            local child_lay = ns.layout[cid]
            local child_outer_h = (child_lay.h or 0) + mt + mb
            if child_outer_h > cur_line.h then cur_line.h = child_outer_h end

            -- Record item in current line for pass 2
            cur_line.items[#cur_line.items + 1] = {
                cid = cid,
                child_h = child_lay.h or 0,
                mt = mt,
                mb = mb,
            }

            line_x = line_x + advance

            -- Clear any stale fragments left over from a previous layout
            -- pass when this span fit normally this time round.
            local tcid = ns.first_child[cid] or 0
            if tcid ~= 0 and ns.layout[tcid] and ns.layout[tcid].fragments then
                ns.layout[tcid].fragments = nil
            end
        end
    end

    -- Finalize last line width
    cur_line.w = line_x - content_x

    -- ===========================================================
    -- Pass 2: Per-line vertical alignment
    -- ===========================================================
    local total_h = 0
    local max_line_w = 0

    container_h = container_h or 0

    for li = 1, #lines do
        local line = lines[li]
        local line_h = line.h
        local line_y = line.y
        -- Use container height when larger (fixed-height parent)
        local eff_h = line_h
        if container_h > 0 and container_h > line_h then
            eff_h = container_h
        end

        if line.w > max_line_w then max_line_w = line.w end

        -- Line baseline: place strut baseline at strut_h * 0.8 from line top.
        -- This is where inline content with `vertical-align: baseline` sits.
        local line_baseline = line_y + math.floor(strut_h * 0.8 + 0.5)

        for ii = 1, #line.items do
            local item = line.items[ii]
            local child_cm = ns.computed[item.cid] or {}
            local va = child_cm.vertical_align or "baseline"

            local child_lay = ns.layout[item.cid]
            if child_lay then
                local child_h = item.child_h
                local dy = 0

                -- Resolve item's intrinsic font_size for sub/super offsets.
                local item_fs = child_cm.font_size
                if type(item_fs) ~= "number" then item_fs = pfs end

                if va == "top" then
                    dy = line_y - child_lay.y
                elseif va == "middle" then
                    -- Align child's mid-height with the strut x-height
                    -- (roughly font_size * 0.5 above the baseline).
                    local mid_y = line_baseline - math.floor(item_fs * 0.25 + 0.5)
                    dy = mid_y - (child_lay.y + math.floor(child_h / 2))
                elseif va == "bottom" then
                    dy = line_y + eff_h - child_h - child_lay.y
                elseif va == "text-top" then
                    -- Top of the strut's content area = baseline - font_size * ascent
                    local text_top = line_baseline - math.floor(item_fs * 0.8 + 0.5)
                    dy = text_top - child_lay.y
                elseif va == "text-bottom" then
                    local text_bot = line_baseline + math.floor(item_fs * 0.2 + 0.5)
                    dy = text_bot - child_h - child_lay.y
                elseif va == "sub" then
                    -- ~20% font_size below baseline
                    dy = line_baseline - math.floor(child_h * 0.8 + 0.5)
                        + math.floor(item_fs * 0.2 + 0.5) - child_lay.y
                elseif va == "super" then
                    -- ~30% font_size above baseline
                    dy = line_baseline - math.floor(child_h * 0.8 + 0.5)
                        - math.floor(item_fs * 0.3 + 0.5) - child_lay.y
                elseif type(va) == "number" then
                    -- Explicit length: positive = raise above baseline (per
                    -- CSS spec).  child's bottom-of-baseline = line_baseline - va.
                    dy = line_baseline - math.floor(child_h * 0.8 + 0.5) - va - child_lay.y
                else
                    -- "baseline" (default): place child's baseline at
                    -- line_baseline.  Approximated as child top + 80% of
                    -- child height for text, or child bottom for replaced.
                    --
                    -- IMPORTANT: when the child is a TEXT node whose intrinsic
                    -- height already spans multiple wrapped lines, the
                    -- painter stacks lines downward from child_lay.y. Treating
                    -- the multi-line stack as a single inline atom with
                    -- baseline = top + 80% of TOTAL height shifts the whole
                    -- box upward by (num_lines - 1) * line_h * 0.8, painting
                    -- the first line above the parent's content_y and the
                    -- last line into the next sibling. The correct baseline
                    -- for an inline TEXT atom is the FIRST line's baseline,
                    -- which lines up with the strut baseline by construction.
                    local is_text_atom = (ns.node_type[item.cid] == ns.TEXT)
                    if is_text_atom and child_h > strut_h + 1 then
                        -- Multi-line TEXT: first line already sits at
                        -- child_lay.y, and its baseline matches the
                        -- strut baseline (same parent font metrics).
                        -- Treating the whole multi-line stack as a single
                        -- inline atom with baseline = top + 80% of total
                        -- height (the legacy formula below) shifts the
                        -- entire box up by (N-1) * line_h * 0.8, painting
                        -- line 1 above the parent's content_y and the last
                        -- line into the next sibling.  The correct baseline
                        -- for an inline TEXT atom is its FIRST line's
                        -- baseline, which is already aligned with the strut
                        -- baseline by construction (same parent font).
                        dy = line_y - child_lay.y
                    else
                        local child_baseline_offset = math.floor(child_h * 0.8 + 0.5)
                        dy = line_baseline - child_baseline_offset - child_lay.y
                    end
                end

                if dy ~= 0 then
                    offset_subtree(ns, item.cid, dy)
                end
            end
        end

        total_h = total_h + line_h
    end

    return total_h, max_line_w
end

return Inline



