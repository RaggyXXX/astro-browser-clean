------------------------------------------------------------
-- ext_core_astro_ui_lib / core / html / html_parser.lua
-- HTML string parser. Tokenizes HTML and produces a parsed
-- value the engine can mount.
--
-- Input:  HTML string + optional CSS string
-- Output: opaque parsed value (pass to Engine:mount)
--
-- Supports: elements, attributes, text nodes, self-closing
-- tags, void elements, <style> extraction, inline styles,
-- HTML entities, comments.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local CSSParser = require("core/html/css_parser")

local HTMLParser = {}

------------------------------------------------------------
-- HTML entities
------------------------------------------------------------
local ENTITIES = {
    amp  = "&",  lt   = "<",  gt   = ">",
    quot = '"',  apos = "'",  nbsp = "\194\160",
    copy = "\194\169",  reg  = "\194\174",
    mdash = "\226\128\148", ndash = "\226\128\147",
    laquo = "\194\171", raquo = "\194\187",
    bull  = "\226\128\162", hellip = "\226\128\166",
    trade = "\226\132\162",
}

local REPLACEMENT_CHAR = "\239\191\189"

--- Encode a Unicode code point to UTF-8 bytes (Lua 5.1 safe)
local function codepoint_to_utf8(n)
    if not n or n == 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then
        return REPLACEMENT_CHAR
    end
    if n < 0x80 then
        return string.char(n)
    elseif n < 0x800 then
        return string.char(
            0xC0 + math.floor(n / 64),
            0x80 + (n % 64))
    elseif n < 0x10000 then
        return string.char(
            0xE0 + math.floor(n / 4096),
            0x80 + math.floor((n % 4096) / 64),
            0x80 + (n % 64))
    elseif n < 0x110000 then
        return string.char(
            0xF0 + math.floor(n / 262144),
            0x80 + math.floor((n % 262144) / 4096),
            0x80 + math.floor((n % 4096) / 64),
            0x80 + (n % 64))
    end
    return ""
end

local function decode_entities(s)
    if not s then return s end
    -- Named entities
    s = s:gsub("&(%a+);", function(name)
        return ENTITIES[name] or ("&" .. name .. ";")
    end)
    -- Numeric entities (full Unicode via UTF-8)
    s = s:gsub("&#(%d+);", function(num)
        local n = tonumber(num)
        if n then
            return codepoint_to_utf8(n)
        end
        return "&#" .. num .. ";"
    end)
    -- Hex entities (full Unicode via UTF-8)
    s = s:gsub("&#x(%x+);", function(hex)
        local n = tonumber(hex, 16)
        if n then
            return codepoint_to_utf8(n)
        end
        return "&#x" .. hex .. ";"
    end)
    return s
end

------------------------------------------------------------
-- Void elements (self-closing, no end tag needed)
------------------------------------------------------------
local VOID_ELEMENTS = {}
local void_list = {
    "area", "base", "br", "col", "embed", "hr", "img",
    "input", "link", "meta", "param", "source", "track", "wbr",
}
for i = 1, #void_list do
    VOID_ELEMENTS[void_list[i]] = true
end

------------------------------------------------------------
-- Raw text elements (contents are not parsed as HTML)
------------------------------------------------------------
local RAW_TEXT_ELEMENTS = {}
local raw_list = { "script", "style", "textarea", "title" }
for i = 1, #raw_list do
    RAW_TEXT_ELEMENTS[raw_list[i]] = true
end

local SKIPPED_VISUAL_ELEMENTS = {
    head = true,
    link = true,
    meta = true,
    script = true,
    title = true,
}

-- HTML5 §13.2 implicit close rules.  When a new start tag opens, certain
-- currently-open parent tags must be implicitly closed first so the new
-- element becomes a sibling instead of a descendant.  This is the most
-- visible piece of the HTML5 parsing algorithm -" without it, authoring
-- `<li>foo<li>bar</ul>` produces nested li elements that confuse layout
-- and selectors.
--
-- Map: parent-tag-to-close -> set of OPENING tags that close it.
local IMPLICITLY_CLOSED_BY = {
    p        = {  -- §13.2.6.4.7: any block-level start tag closes an open <p>
        p = true, div = true, section = true, article = true, nav = true,
        aside = true, header = true, footer = true, main = true,
        h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
        ul = true, ol = true, dl = true, menu = true,
        table = true, form = true, fieldset = true,
        blockquote = true, pre = true, hr = true, address = true,
        figure = true, figcaption = true, details = true, summary = true,
        hgroup = true,
    },
    li       = { li = true },
    dt       = { dt = true, dd = true },
    dd       = { dt = true, dd = true },
    option   = { option = true, optgroup = true },
    optgroup = { optgroup = true },
    tr       = { tr = true, tbody = true, thead = true, tfoot = true },
    td       = { td = true, th = true, tr = true, tbody = true, thead = true, tfoot = true },
    th       = { td = true, th = true, tr = true, tbody = true, thead = true, tfoot = true },
    thead    = { tbody = true, tfoot = true },
    tbody    = { thead = true, tfoot = true, tbody = true },
    tfoot    = { thead = true, tbody = true },
}

local function copy_set(set)
    local copy = {}
    for k, v in pairs(set) do
        copy[k] = v
    end
    return copy
end

--- Return parser metadata used by compatibility audits.
function HTMLParser.get_parser_metadata()
    return {
        void_elements = copy_set(VOID_ELEMENTS),
        raw_text_elements = copy_set(RAW_TEXT_ELEMENTS),
        skipped_visual_elements = copy_set(SKIPPED_VISUAL_ELEMENTS),
        accepts_unknown_tags = true,
    }
end

------------------------------------------------------------
-- HTML Tokenizer
-- Produces tokens: {type, tag, attrs, text, self_closing}
-- Types: "open", "close", "text", "comment", "doctype"
------------------------------------------------------------

--- Parse attributes from an attribute string.
--- Handles: key="value", key='value', key=value, key (boolean)
local function parse_attributes(attr_str)
    if not attr_str or attr_str == "" then return {} end
    local attrs = {}
    local pos = 1
    local len = #attr_str

    -- HTML5 §13.2.5.32: when a duplicate attribute name is seen on the same
    -- start tag, the second (and later) occurrence is silently ignored.  We
    -- centralise the assignment so every code path below follows first-wins.
    local function put(name, value)
        if attrs[name] == nil then attrs[name] = value end
    end

    while pos <= len do
        -- Skip whitespace
        local ws = attr_str:find("[^%s]", pos)
        if not ws then break end
        pos = ws

        -- Match attribute name
        local name_s, name_e = attr_str:find("^[%w%-_:]+", pos)
        if not name_s then break end
        local name = attr_str:sub(name_s, name_e):lower()
        pos = name_e + 1

        -- Skip whitespace
        ws = attr_str:find("[^%s]", pos)
        if not ws then
            -- Boolean attribute at end
            put(name, "true")
            break
        end
        pos = ws

        -- Check for =
        if attr_str:sub(pos, pos) == "=" then
            pos = pos + 1
            -- Skip whitespace after =
            ws = attr_str:find("[^%s]", pos)
            if not ws then
                put(name, "")
                break
            end
            pos = ws

            local first_ch = attr_str:sub(pos, pos)
            if first_ch == '"' then
                -- Double-quoted value
                local close = attr_str:find('"', pos + 1, true)
                if close then
                    put(name, decode_entities(attr_str:sub(pos + 1, close - 1)))
                    pos = close + 1
                else
                    put(name, decode_entities(attr_str:sub(pos + 1)))
                    break
                end
            elseif first_ch == "'" then
                -- Single-quoted value
                local close = attr_str:find("'", pos + 1, true)
                if close then
                    put(name, decode_entities(attr_str:sub(pos + 1, close - 1)))
                    pos = close + 1
                else
                    put(name, decode_entities(attr_str:sub(pos + 1)))
                    break
                end
            else
                -- Unquoted value (until whitespace or > or /)
                local val_end = attr_str:find("[%s/>]", pos)
                if val_end then
                    put(name, decode_entities(attr_str:sub(pos, val_end - 1)))
                    pos = val_end
                else
                    put(name, decode_entities(attr_str:sub(pos)))
                    break
                end
            end
        else
            -- Boolean attribute
            put(name, "true")
        end
    end

    return attrs
end

--- Find the end of an HTML tag, respecting quoted attribute values.
--- Returns the position of the closing >.
local function find_tag_end(html, start, len)
    local scan = start
    while scan <= len do
        local ch = html:sub(scan, scan)
        if ch == '"' then
            local close = html:find('"', scan + 1, true)
            if close then scan = close + 1
            else scan = len + 1 end
        elseif ch == "'" then
            local close = html:find("'", scan + 1, true)
            if close then scan = close + 1
            else scan = len + 1 end
        elseif ch == ">" then
            return scan
        else
            scan = scan + 1
        end
    end
    return nil
end

--- Tokenize HTML string into an array of tokens.
local function tokenize(html)
    local tokens = {}
    local pos = 1
    local len = #html

    while pos <= len do
        -- Find next tag (< followed by a letter, /, or !)
        local tag_start = html:find("<", pos, true)

        -- Validate that this looks like a real tag, not just "2 < 3"
        if tag_start then
            local next_ch = html:sub(tag_start + 1, tag_start + 1)
            if next_ch ~= "/" and next_ch ~= "!" and not next_ch:find("[%a]") then
                -- Not a real tag, treat < as text and continue
                local text = html:sub(pos, tag_start)
                -- Look for next real tag from after this <
                local next_tag = tag_start + 1
                local found_real = false
                while next_tag <= len do
                    local nt = html:find("<", next_tag, true)
                    if not nt then break end
                    local nc = html:sub(nt + 1, nt + 1)
                    if nc == "/" or nc == "!" or nc:find("[%a]") then
                        -- Found a real tag, emit text up to it
                        text = html:sub(pos, nt - 1)
                        tag_start = nt
                        found_real = true
                        break
                    end
                    next_tag = nt + 1
                end
                if not found_real then
                    -- No more real tags, rest is text
                    text = html:sub(pos)
                    if text:find("%S") then
                        tokens[#tokens + 1] = { type = "text", text = decode_entities(text) }
                    end
                    break
                else
                    if text:find("%S") then
                        tokens[#tokens + 1] = { type = "text", text = decode_entities(text) }
                    end
                end
            end
        end

        if not tag_start then
            -- Rest is text
            local text = html:sub(pos)
            if text:find("%S") then
                tokens[#tokens + 1] = { type = "text", text = decode_entities(text) }
            end
            break
        end

        -- Text before tag
        if tag_start > pos then
            local text = html:sub(pos, tag_start - 1)
            if text:find("%S") then
                tokens[#tokens + 1] = { type = "text", text = decode_entities(text) }
            end
        end

        -- Comment: <!-- ... -->
        if html:sub(tag_start, tag_start + 3) == "<!--" then
            local comment_end = html:find("-->", tag_start + 4, true)
            if comment_end then
                tokens[#tokens + 1] = { type = "comment", text = html:sub(tag_start + 4, comment_end - 1) }
                pos = comment_end + 3
            else
                pos = len + 1
            end

        -- DOCTYPE: <!DOCTYPE ...>
        elseif html:sub(tag_start, tag_start + 8):upper() == "<!DOCTYPE" then
            local dt_end = html:find(">", tag_start + 9, true)
            if dt_end then
                tokens[#tokens + 1] = { type = "doctype" }
                pos = dt_end + 1
            else
                pos = len + 1
            end

        -- Closing tag: </tag>
        elseif html:sub(tag_start + 1, tag_start + 1) == "/" then
            local tag_end = html:find(">", tag_start + 2, true)
            if tag_end then
                local tag_name = html:sub(tag_start + 2, tag_end - 1):match("^%s*(%S+)")
                if tag_name then
                    tokens[#tokens + 1] = { type = "close", tag = tag_name:lower() }
                end
                pos = tag_end + 1
            else
                pos = len + 1
            end

        -- Opening tag: <tag attrs...> or <tag attrs... />
        else
            local tag_end = find_tag_end(html, tag_start + 1, len)
            if tag_end then
                local inner = html:sub(tag_start + 1, tag_end - 1)
                local self_closing = false
                if inner:sub(-1) == "/" then
                    inner = inner:sub(1, -2)
                    self_closing = true
                end

                local tag_name = inner:match("^(%S+)")
                if tag_name then
                    tag_name = tag_name:lower()
                    local attr_str = inner:sub(#tag_name + 1)
                    local attrs = parse_attributes(attr_str)
                    self_closing = self_closing or VOID_ELEMENTS[tag_name]

                    tokens[#tokens + 1] = {
                        type = "open",
                        tag = tag_name,
                        attrs = attrs,
                        self_closing = self_closing,
                    }

                    -- Raw text elements: grab everything until closing tag
                    if RAW_TEXT_ELEMENTS[tag_name] and not self_closing then
                        -- Case-insensitive: build pattern like <[sS][cC][rR]...>
                        local ci_pat = "</"
                        for ci = 1, #tag_name do
                            local ch = tag_name:sub(ci, ci)
                            ci_pat = ci_pat .. "[" .. ch:lower() .. ch:upper() .. "]"
                        end
                        ci_pat = ci_pat .. "%s*>"
                        local raw_end_s, raw_end_e = html:find(ci_pat, tag_end + 1)
                        if raw_end_s then
                            local raw_content = html:sub(tag_end + 1, raw_end_s - 1)
                            if tag_name == "style" then
                                tokens[#tokens + 1] = { type = "style_content", text = raw_content }
                            elseif tag_name == "script" then
                                tokens[#tokens + 1] = {
                                    type = "script_content",
                                    text = raw_content,
                                    attrs = attrs,
                                }
                            else
                                tokens[#tokens + 1] = { type = "text", text = raw_content }
                            end
                            tokens[#tokens + 1] = { type = "close", tag = tag_name }
                            tag_end = raw_end_e
                        end
                    end
                end
                pos = tag_end + 1
            else
                pos = len + 1
            end
        end
    end

    return tokens
end

------------------------------------------------------------
-- Tree builder: tokens → bundle format (SoA arrays)
------------------------------------------------------------

--- Parse HTML (with optional CSS) into a value mountable by Engine:mount.
--- The returned value is opaque: its shape is internal and may change
--- between versions. Treat it as a token, not as data to inspect.
---@param html_str string  raw HTML
---@param css_str  string|nil  optional CSS (in addition to <style> tags)
---@return table  opaque parsed value for Engine:mount()
function HTMLParser.parse(html_str, css_str)
    if not html_str then html_str = "" end

    -- String interning
    local strings = {}
    local str_map = {}

    local function intern(s)
        if not s then return 0 end
        if str_map[s] then return str_map[s] end
        strings[#strings + 1] = s
        str_map[s] = #strings
        return #strings
    end

    -- Node arrays (SoA)
    local nodes = {
        tag          = {},
        id_str       = {},
        class_list   = {},
        parent       = {},
        node_type    = {},
        text_content = {},
        attrs        = {},
    }
    local node_count = 0

    local function add_element(tag_str, id, classes, parent_idx, attrs)
        node_count = node_count + 1
        local idx = node_count
        nodes.tag[idx]          = intern(tag_str)
        nodes.id_str[idx]       = id and intern(id) or 0
        local cls = {}
        if classes then
            for word in classes:gmatch("%S+") do
                cls[#cls + 1] = intern(word)
            end
        end
        nodes.class_list[idx]   = cls
        nodes.parent[idx]       = parent_idx
        nodes.node_type[idx]    = 1  -- ELEMENT
        nodes.text_content[idx] = ""
        nodes.attrs[idx]        = attrs or {}
        return idx
    end

    -- Whitespace-preserving ancestor tags.  Text inside any of these (or
    -- their descendants) must keep its original newlines/tabs/runs of
    -- spaces; otherwise `white-space: pre*` and the `<textarea>` default
    -- value cannot be honoured because the data is already gone.
    local PRESERVE_WS_TAGS = {
        pre      = true,
        textarea = true,
    }

    local function add_text(text, parent_idx, preserve_ws)
        if not preserve_ws then
            -- Collapse space/tab runs but PRESERVE newlines. CSS spec:
            -- whitespace handling is a render-time concern controlled by
            -- the `white-space` property -" the parser can't decide that
            -- because the relevant CSS is not yet resolved. The previous
            -- behavior was to collapse all whitespace (\n included) at
            -- parse time, which destroyed the data `white-space: pre-wrap`
            -- and `pre-line` need to honor explicit line breaks. The
            -- text_wrap normalize() step still collapses \n when the
            -- effective `white-space` mode has `collapse_newlines=true`
            -- (normal / nowrap) -" so this change is non-regressing for
            -- the common case while making pre-wrap/pre-line work.
            text = text:gsub("[ \t]+", " ")
            if text:match("^%s*$") then return nil end -- whitespace-only
        elseif text == "" then
            return nil
        end

        node_count = node_count + 1
        local idx = node_count
        nodes.tag[idx]          = intern("_text")
        nodes.id_str[idx]       = 0
        nodes.class_list[idx]   = {}
        nodes.parent[idx]       = parent_idx
        nodes.node_type[idx]    = 2  -- TEXT
        nodes.text_content[idx] = text
        nodes.attrs[idx]        = {}
        return idx
    end

    -- Tokenize
    local tokens = tokenize(html_str)

    -- Collect <style> content, <script> blocks, and <link rel=stylesheet>
    local style_blocks = {}
    local scripts      = {}
    local stylesheets  = {}

    -- Build tree
    local stack = {}  -- parent stack (node indices)
    local current_parent = 0
    local preserve_ws_depth = 0  -- > 0 when inside <pre>/<textarea> subtree

    local function pop_frame()
        local frame = stack[#stack]
        stack[#stack] = nil
        current_parent = frame.parent
        if frame.entered_preserve then
            preserve_ws_depth = preserve_ws_depth - 1
            if preserve_ws_depth < 0 then preserve_ws_depth = 0 end
        end
        return frame
    end

    -- Implicit root: if first token isn't html/body, wrap in div
    -- Actually, let's just build the tree as-is; the engine handles any root.

    for ti = 1, #tokens do
        local tok = tokens[ti]

        if tok.type == "style_content" then
            style_blocks[#style_blocks + 1] = tok.text

        elseif tok.type == "script_content" then
            -- Capture script bodies so the engine can execute them.
            local lang = (tok.attrs and (tok.attrs.lang or tok.attrs.type)) or "lua"
            lang = tostring(lang):lower()
            -- Accept "lua", "text/lua", "application/lua"
            if lang:find("lua", 1, true) then
                lang = "lua"
            end
            scripts[#scripts + 1] = {
                lang  = lang,
                code  = tok.text or "",
                attrs = tok.attrs or {},
            }

        elseif tok.type == "open" then
            local tag = tok.tag
            local attrs = tok.attrs or {}

            -- Skip <html>, <head>, <body>, <meta>, <link>, <script> tags
            -- (they don't produce visual nodes - scripts/stylesheets captured separately)
            if tag == "link" then
                -- Capture <link rel="stylesheet" href="..."> for async loading
                local rel = (attrs.rel or ""):lower()
                if rel == "stylesheet" and attrs.href and attrs.href ~= "" then
                    stylesheets[#stylesheets + 1] = {
                        href  = attrs.href,
                        media = attrs.media,
                    }
                end
                if not tok.self_closing then
                    stack[#stack + 1] = { nid = -1, parent = current_parent, tag = tag }
                    current_parent = -1
                end
            elseif SKIPPED_VISUAL_ELEMENTS[tag] and tag ~= "link" then
                if not tok.self_closing then
                    -- Push to skip children
                    stack[#stack + 1] = { nid = -1, parent = current_parent, tag = tag }
                    current_parent = -1  -- sentinel: skip mode
                end
            elseif current_parent == -1 then
                -- Inside a skipped element, skip children too
                if not tok.self_closing then
                    stack[#stack + 1] = { nid = -1, parent = -1, tag = tag }
                end
            else
                -- HTML5 implicit close: if the current open parent must be
                -- closed by this start tag (e.g. opening <li> while a <li>
                -- is open), pop the stack first so the new element is a
                -- sibling instead of a descendant.  Walks up while
                -- ancestors match -" this lets `<p><em>foo<div>` close the
                -- <p> through the <em> (the <em> stays open).
                while #stack > 0 and current_parent > 0 do
                    local parent_tag = strings[nodes.tag[current_parent]]
                    local close_rule = parent_tag and IMPLICITLY_CLOSED_BY[parent_tag]
                    if close_rule and close_rule[tag] then
                        pop_frame()
                    else
                        break
                    end
                end

                -- Extract id, class from attrs
                local id = attrs.id
                local class = attrs.class
                -- Remove id/class from attrs (stored separately)
                attrs.id = nil
                attrs.class = nil

                local nid = add_element(tag, id, class, current_parent, attrs)

                if not tok.self_closing then
                    local enters_preserve = PRESERVE_WS_TAGS[tag] == true
                    stack[#stack + 1] = {
                        nid = nid,
                        parent = current_parent,
                        tag = tag,
                        entered_preserve = enters_preserve,
                    }
                    current_parent = nid
                    if enters_preserve then
                        preserve_ws_depth = preserve_ws_depth + 1
                    end
                end
            end

        elseif tok.type == "close" then
            -- HTML recovery: an end tag closes the matching open element,
            -- implicitly closing any still-open descendants above it.  A
            -- stray end tag with no matching open element is ignored.
            local match_idx = nil
            for si = #stack, 1, -1 do
                if stack[si].tag == tok.tag then
                    match_idx = si
                    break
                end
            end
            if match_idx then
                while #stack >= match_idx do
                    pop_frame()
                end
            end

        elseif tok.type == "text" then
            local preserve = preserve_ws_depth > 0
            if current_parent > 0 then
                add_text(tok.text, current_parent, preserve)
            elseif current_parent == 0 and tok.text:find("%S") then
                -- Text outside any element - wrap in implicit root
                -- Only if we have actual content
                if node_count == 0 then
                    current_parent = add_element("div", nil, nil, 0, {})
                end
                add_text(tok.text, current_parent, preserve)
            end
            -- Skip text inside -1 (skip mode)
        end
    end

    -- Ensure at least one root node
    if node_count == 0 then
        add_element("div", nil, nil, 0, {})
    end

    -- Parse CSS (combine <style> blocks + external CSS)
    local all_css = ""
    for i = 1, #style_blocks do
        all_css = all_css .. "\n" .. style_blocks[i]
    end
    if css_str and css_str ~= "" then
        all_css = all_css .. "\n" .. css_str
    end

    local rules, css_imports = CSSParser.parse(all_css)

    -- Merge @import URLs into the stylesheets list so the engine's
    -- <link>-loading pipeline can fetch them in order.
    if css_imports and #css_imports > 0 then
        for i = 1, #css_imports do
            stylesheets[#stylesheets + 1] = {
                href  = css_imports[i].url,
                media = css_imports[i].media,
            }
        end
    end

    return {
        meta        = { name = "html_bundle", schema = "astro_ui_ir_v1" },
        strings     = strings,
        nodes       = nodes,
        rules       = rules,
        scripts     = scripts,
        stylesheets = stylesheets,
    }
end

--- Parse just an HTML fragment (no <style> extraction, no CSS).
--- Returns the same bundle format.
---@param html_str string
---@return table
function HTMLParser.parse_fragment(html_str)
    return HTMLParser.parse(html_str, nil)
end

--- Convenience: parse HTML with CSS and mount to engine.
---@param engine  table  Engine instance
---@param win_id  string  window ID
---@param html    string  HTML content
---@param css     string|nil  CSS content
---@param opts    table|nil  mount options
function HTMLParser.mount(engine, win_id, html, css, opts)
    local bundle = HTMLParser.parse(html, css)
    engine:mount(win_id, bundle, opts)
end

return HTMLParser



