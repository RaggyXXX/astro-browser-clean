------------------------------------------------------------
-- ext_core_astro_ui_lib / core / style / counters.lua
-- CSS Counters: counter-reset, counter-increment,
-- counter()/counters() resolution in content strings.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local Counters = {}

------------------------------------------------------------
-- Parse counter-reset / counter-increment property value.
-- Format: "name1 value1 name2 value2 ..."
-- If a token after a name is not a number, it is treated as
-- the next name (value defaults to default_value).
-- "none" resets / clears.
--
-- @param str            string   raw CSS value
-- @param default_value  number   0 for reset, 1 for increment
-- @return table  array of {name=string, value=number}
------------------------------------------------------------
function Counters.parse_counter_prop(str, default_value)
    if not str or str == "" or str == "none" then
        return {}
    end

    local result = {}
    -- tokenise on whitespace
    local tokens = {}
    for tok in str:gmatch("[^%s]+") do
        tokens[#tokens + 1] = tok
    end

    local i = 1
    while i <= #tokens do
        local name = tokens[i]
        i = i + 1
        -- peek at next token for optional numeric value
        local val = default_value
        if i <= #tokens then
            local num = tonumber(tokens[i])
            if num then
                val = num
                i = i + 1
            end
        end
        result[#result + 1] = { name = name, value = val }
    end

    return result
end

------------------------------------------------------------
-- Deep-copy a counter scope table.
------------------------------------------------------------
local function copy_scope(src)
    local dst = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            -- v is a stack of values (for counters())
            local s = {}
            for j = 1, #v do s[j] = v[j] end
            dst[k] = s
        else
            dst[k] = v
        end
    end
    return dst
end

------------------------------------------------------------
-- Resolve counter() and counters() inside a content string.
--
-- Content strings may contain:
--   "Section " counter(chapter) ". " counter(section)
--   counters(item, ".")
--   counter(page, upper-roman)       (style ignored, decimal only)
--
-- String literals are delimited by matching quotes.
-- counter()/counters() calls are replaced by their values.
--
-- @param content_str   string   raw content value
-- @param counter_state table    {name = {v1, v2, ...}} stack per counter
-- @return string  resolved plain text
------------------------------------------------------------
function Counters.resolve_content(content_str, counter_state, attrs)
    if not content_str or content_str == "" or content_str == "none" or content_str == "normal" then
        return ""
    end

    local out = {}
    local pos = 1
    local len = #content_str

    while pos <= len do
        local ch = content_str:sub(pos, pos)

        -- quoted string literal
        if ch == '"' or ch == "'" then
            local quote = ch
            local j = pos + 1
            while j <= len do
                local c = content_str:sub(j, j)
                if c == '\\' then
                    j = j + 2 -- skip escaped char
                elseif c == quote then
                    j = j + 1
                    break
                else
                    j = j + 1
                end
            end
            -- extract inner string (without quotes)
            out[#out + 1] = content_str:sub(pos + 1, j - 2)
            pos = j

        -- counters() -" must check before counter()
        elseif content_str:sub(pos, pos + 8) == "counters(" then
            local close = content_str:find(")", pos + 9, true)
            if close then
                local args = content_str:sub(pos + 9, close - 1)
                -- parse: name, "separator" [, style]
                local name, sep = args:match('^%s*([%w_%-]+)%s*,%s*"([^"]*)"%s*')
                if not name then
                    name, sep = args:match("^%s*([%w_%-]+)%s*,%s*'([^']*)'%s*")
                end
                if name then
                    local stack = counter_state[name]
                    if stack and #stack > 0 then
                        local parts = {}
                        for i = 1, #stack do
                            parts[i] = tostring(stack[i])
                        end
                        out[#out + 1] = table.concat(parts, sep)
                    else
                        out[#out + 1] = "0"
                    end
                else
                    out[#out + 1] = ""
                end
                pos = close + 1
            else
                pos = pos + 1
            end

        -- attr(name [, type-or-fallback]) -" substitutes an HTML attribute's value
        elseif content_str:sub(pos, pos + 4) == "attr(" then
            local close = content_str:find(")", pos + 5, true)
            if close then
                local args = content_str:sub(pos + 5, close - 1)
                -- parse: name or "name, fallback"
                local name, rest = args:match("^%s*([%w_%-]+)%s*,?%s*(.-)%s*$")
                if name then
                    local val = attrs and attrs[name]
                    if val == nil or val == "" then
                        -- fallback: if rest is a quoted string, use it; else empty
                        if rest and rest ~= "" then
                            local fb = rest:match('^"([^"]*)"$')
                                or rest:match("^'([^']*)'$")
                            if fb then val = fb else val = rest end
                        else
                            val = ""
                        end
                    end
                    out[#out + 1] = tostring(val)
                end
                pos = close + 1
            else
                pos = pos + 1
            end

        -- counter()
        elseif content_str:sub(pos, pos + 7) == "counter(" then
            local close = content_str:find(")", pos + 8, true)
            if close then
                local args = content_str:sub(pos + 8, close - 1)
                -- parse: name [, style]  (style ignored)
                local name = args:match("^%s*([%w_%-]+)")
                if name then
                    local stack = counter_state[name]
                    if stack and #stack > 0 then
                        out[#out + 1] = tostring(stack[#stack])
                    else
                        out[#out + 1] = "0"
                    end
                else
                    out[#out + 1] = ""
                end
                pos = close + 1
            else
                pos = pos + 1
            end

        -- whitespace between tokens -" skip
        elseif ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            pos = pos + 1

        -- unknown token -" skip character
        else
            pos = pos + 1
        end
    end

    return table.concat(out)
end

------------------------------------------------------------
-- Resolve counters for the entire DOM tree.
--
-- Walk depth-first, maintaining a counter scope (a table
-- mapping counter names to stacks of integer values).
--
-- counter-reset creates or resets the innermost scope value.
-- counter-increment increments the innermost scope value.
--
-- For nodes whose computed content contains counter()/
-- counters(), the text_content is set to the resolved string.
--
-- @param ns       table   NodeStore
-- @param root_nid number  root node id
------------------------------------------------------------
function Counters.resolve(ns, root_nid)
    if not root_nid or root_nid == 0 then return end

    -- Recursive DFS.  counter_state maps name -> {v1, v2, ...}
    -- where the last element is the "current" value and earlier
    -- elements are parent scopes (for counters()).

    local computed = ns.computed
    local text_content = ns.text_content
    local first_child = ns.first_child
    local next_sibling = ns.next_sibling

    local function walk(nid, state)
        if nid == 0 or nid == nil then return end

        local comp = computed[nid]
        local did_reset = {} -- names we pushed a new scope for

        -- 1. counter-reset: push new scope value
        if comp then
            local cr = comp.counter_reset
            if cr and cr ~= "none" then
                local entries = Counters.parse_counter_prop(cr, 0)
                for i = 1, #entries do
                    local e = entries[i]
                    local name = e.name
                    if not state[name] then
                        state[name] = {}
                    end
                    -- push new scope
                    local stack = state[name]
                    stack[#stack + 1] = e.value
                    did_reset[name] = true
                end
            end
        end

        -- 2. counter-increment: increment innermost scope
        if comp then
            local ci = comp.counter_increment
            if ci and ci ~= "none" then
                local entries = Counters.parse_counter_prop(ci, 1)
                for i = 1, #entries do
                    local e = entries[i]
                    local name = e.name
                    local stack = state[name]
                    if not stack or #stack == 0 then
                        -- auto-instantiate at 0 then increment
                        state[name] = { 0 }
                        stack = state[name]
                    end
                    stack[#stack] = stack[#stack] + e.value
                end
            end
        end

        -- Attr lookup: for ::before/::after pseudo-nodes, attr() resolves against
        -- the originating element's attrs (the parent of the pseudo node).
        local parent_attrs = nil
        local parent_nid = ns.parent[nid]
        if parent_nid and parent_nid ~= 0 then
            parent_attrs = ns.attrs[parent_nid]
        end
        local own_attrs = ns.attrs[nid]

        -- 3. resolve content property if it uses counter() or attr()
        if comp then
            local content = comp.content
            if content and type(content) == "string" then
                if content:find("counter", 1, true) or content:find("attr(", 1, true) then
                    text_content[nid] = Counters.resolve_content(content, state, own_attrs or parent_attrs)
                end
            end
        end

        -- 3b. Also resolve counter()/attr() in text_content for pseudo-elements
        -- (pseudo nodes store content in text_content, not comp.content)
        local tc = text_content[nid]
        if tc and type(tc) == "string"
           and (tc:find("counter", 1, true) or tc:find("attr(", 1, true)) then
            text_content[nid] = Counters.resolve_content(tc, state, parent_attrs or own_attrs)
        end

        -- 4. recurse into children
        local child = first_child[nid]
        while child and child ~= 0 do
            walk(child, state)
            child = next_sibling[child]
        end

        -- 5. pop scopes we pushed
        for name, _ in pairs(did_reset) do
            local stack = state[name]
            if stack and #stack > 0 then
                stack[#stack] = nil
            end
        end
    end

    walk(root_nid, {})
end

return Counters



