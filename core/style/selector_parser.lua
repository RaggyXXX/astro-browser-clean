------------------------------------------------------------
-- ext_core_astro_ui_lib / core / style / selector_parser.lua
-- CSS selector string -> structured representation.
--
-- Parses selectors like:
--   ".parent > .child:hover"
--   "div .item:first-child"
--   "#main > p + span"
--   ".card:nth-child(2)"
--   ":not(.hidden)"
--   "div:has(> .active)"
--
-- Output: array of segments with combinators:
--   { segments = { {combinator, selectors}, ... } }
-- Each simple selector: {type="class"|"id"|"tag"|"pseudo"|"not", value=...}
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local SelectorParser = {}

SelectorParser.KNOWN_PSEUDO_CLASSES = {
    "active",
    "checked",
    "dir",
    "disabled",
    "empty",
    "enabled",
    "first-child",
    "first-of-type",
    "focus",
    "focus-visible",
    "focus-within",
    "has",
    "hover",
    "invalid",
    "is",
    "lang",
    "last-child",
    "last-of-type",
    "link",
    "not",
    "nth-child",
    "nth-last-child",
    "nth-last-of-type",
    "nth-of-type",
    "only-child",
    "only-of-type",
    "optional",
    "placeholder-shown",
    "read-only",
    "read-write",
    "required",
    "root",
    "valid",
    "visited",
    "where",
}

SelectorParser.KNOWN_PSEUDO_ELEMENTS = {
    "after",
    "before",
    "first-letter",
    "first-line",
    "marker",
}

function SelectorParser.get_known_pseudo_classes()
    local out = {}
    for i = 1, #SelectorParser.KNOWN_PSEUDO_CLASSES do
        out[i] = SelectorParser.KNOWN_PSEUDO_CLASSES[i]
    end
    return out
end

function SelectorParser.get_known_pseudo_elements()
    local out = {}
    for i = 1, #SelectorParser.KNOWN_PSEUDO_ELEMENTS do
        out[i] = SelectorParser.KNOWN_PSEUDO_ELEMENTS[i]
    end
    return out
end

------------------------------------------------------------
-- Helper: parse an+b syntax (odd, even, 2n+1, 3n, n, 5…)
------------------------------------------------------------
local function parse_anb(arg)
    local trimmed = arg:match("^%s*(.-)%s*$")
    if trimmed == "odd" then
        return { a = 2, b = 1 }
    elseif trimmed == "even" then
        return { a = 2, b = 0 }
    else
        local a_str, sign, b_str = trimmed:match("^([%-]?%d*)n%s*([%+%-])%s*(%d+)$")
        if a_str then
            local a = (a_str == "" or a_str == "+") and 1 or (a_str == "-") and -1 or tonumber(a_str)
            local b = tonumber(b_str) or 0
            if sign == "-" then b = -b end
            return { a = a, b = b }
        else
            a_str = trimmed:match("^([%-]?%d*)n$")
            if a_str then
                local a = (a_str == "" or a_str == "+") and 1 or (a_str == "-") and -1 or tonumber(a_str)
                return { a = a, b = 0 }
            else
                return tonumber(trimmed) or 0
            end
        end
    end
end

------------------------------------------------------------
-- Helper: split a selector list on top-level commas
-- (commas not inside parentheses)
------------------------------------------------------------
local function split_selector_list(str)
    local parts = {}
    local depth = 0
    local start = 1
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
        elseif ch == "," and depth == 0 then
            local part = str:sub(start, i - 1):match("^%s*(.-)%s*$")
            if part ~= "" then
                parts[#parts + 1] = part
            end
            start = i + 1
        end
    end
    local last = str:sub(start):match("^%s*(.-)%s*$")
    if last ~= "" then
        parts[#parts + 1] = last
    end
    return parts
end

------------------------------------------------------------
-- Parse a compound selector (e.g. "div.foo:hover")
------------------------------------------------------------

--- Parse a single compound selector into an array of simple selectors.
---@param str string
---@return table  array of {type, value, ...}
local function parse_compound(str)
    local selectors = {}
    local i = 1
    local len = #str

    while i <= len do
        local ch = str:sub(i, i)

        if ch == "#" then
            -- ID selector
            local j = i + 1
            while j <= len and str:sub(j, j):match("[%w_%-]") do
                j = j + 1
            end
            selectors[#selectors + 1] = { type = "id", value = str:sub(i + 1, j - 1) }
            i = j

        elseif ch == "[" then
            -- Attribute selector: [attr], [attr=val], [attr~=val], etc.
            -- Quote-aware bracket scanning
            local j = i + 1
            local in_quote = nil
            local found_close = false
            while j <= len do
                local c = str:sub(j, j)
                if in_quote then
                    if c == in_quote then in_quote = nil end
                elseif c == '"' or c == "'" then
                    in_quote = c
                elseif c == "]" then
                    found_close = true
                    break
                end
                j = j + 1
            end
            if not found_close then
                -- Malformed selector: skip
                i = j
            else
            local inner = str:sub(i + 1, j - 1)
            j = j + 1  -- skip ]

            -- Parse: attr, attr op value, optionally case flag
            local attr_name, op, attr_val, case_flag
            -- Try operator match first: attr op "value" i/s
            local a, o, q, v, cf = inner:match('^%s*([%w_%-]+)%s*([~|^$*]?=)%s*(["\'])(.-)%3%s*([iIsS]?)%s*$')
            if not a then
                -- Unquoted value
                a, o, v, cf = inner:match('^%s*([%w_%-]+)%s*([~|^$*]?=)%s*([^%s%]]+)%s*([iIsS]?)%s*$')
            end
            if a then
                attr_name = a
                op = o
                attr_val = v
                case_flag = (cf == "i" or cf == "I") and "i" or nil
            else
                -- Bare attribute: [attr]
                attr_name = inner:match("^%s*([%w_%-]+)%s*$")
                op = nil
                attr_val = nil
            end

            if attr_name then
                selectors[#selectors + 1] = {
                    type = "attribute",
                    name = attr_name,
                    op = op,
                    value = attr_val,
                    case_flag = case_flag,
                }
            end
            i = j
            end -- close found_close else

        elseif ch == "." then
            -- Class selector
            local j = i + 1
            while j <= len and str:sub(j, j):match("[%w_%-]") do
                j = j + 1
            end
            selectors[#selectors + 1] = { type = "class", value = str:sub(i + 1, j - 1) }
            i = j

        elseif ch == ":" then
            -- Check for :: pseudo-element
            if i + 1 <= len and str:sub(i + 1, i + 1) == ":" then
                -- Pseudo-element (::before, ::after)
                local j = i + 2
                while j <= len and str:sub(j, j):match("[%w_%-]") do
                    j = j + 1
                end
                local pe_name = str:sub(i + 2, j - 1)
                selectors[#selectors + 1] = { type = "pseudo-element", value = pe_name }
                i = j
            else
            -- Pseudo-class
            local j = i + 1
            while j <= len and str:sub(j, j):match("[%w_%-]") do
                j = j + 1
            end
            local pseudo_name = str:sub(i + 1, j - 1)

            -- Check for functional pseudo: :nth-child(N), :not(.class)
            if j <= len and str:sub(j, j) == "(" then
                local k = j + 1
                local depth = 1
                while k <= len and depth > 0 do
                    local c = str:sub(k, k)
                    if c == "(" then depth = depth + 1
                    elseif c == ")" then depth = depth - 1
                    end
                    if depth > 0 then k = k + 1 end
                end
                local arg = str:sub(j + 1, k - 1)
                k = k + 1  -- skip closing )

                if pseudo_name == "nth-child"
                    or pseudo_name == "nth-of-type"
                    or pseudo_name == "nth-last-child"
                    or pseudo_name == "nth-last-of-type" then
                    -- Parse an+b syntax
                    selectors[#selectors + 1] = {
                        type = "pseudo",
                        value = pseudo_name,
                        arg = parse_anb(arg)
                    }
                elseif pseudo_name == "is" or pseudo_name == "where" then
                    -- Parse comma-separated selector list. Each entry supports
                    -- full selectors with combinators (e.g. `:is(.a > .b)`),
                    -- so we call SelectorParser.parse() not parse_compound().
                    local parts = split_selector_list(arg)
                    local selector_args = {}
                    for pi = 1, #parts do
                        selector_args[#selector_args + 1] = SelectorParser.parse(parts[pi])
                    end
                    selectors[#selectors + 1] = {
                        type = pseudo_name,  -- "is" or "where"
                        value = selector_args
                    }
                elseif pseudo_name == "not" then
                    -- Modern :not() takes a selector list, same argument
                    -- grammar as :is(), and uses the max argument specificity.
                    local parts = split_selector_list(arg)
                    local selector_args = {}
                    for pi = 1, #parts do
                        selector_args[#selector_args + 1] = SelectorParser.parse(parts[pi])
                    end
                    selectors[#selectors + 1] = {
                        type = "not",
                        value = selector_args
                    }
                elseif pseudo_name == "has" then
                    -- Parse the argument as a full selector (supports combinators)
                    local has_sel = SelectorParser.parse(arg)
                    selectors[#selectors + 1] = {
                        type = "has",
                        value = has_sel
                    }
                else
                    selectors[#selectors + 1] = { type = "pseudo", value = pseudo_name, arg = arg }
                end
                i = k
            else
                selectors[#selectors + 1] = { type = "pseudo", value = pseudo_name }
                i = j
            end
            end -- close :: if/else

        elseif ch == "*" then
            selectors[#selectors + 1] = { type = "universal" }
            i = i + 1

        elseif ch:match("[%w_%-]") then
            -- Tag selector
            local j = i
            while j <= len and str:sub(j, j):match("[%w_%-]") do
                j = j + 1
            end
            selectors[#selectors + 1] = { type = "tag", value = str:sub(i, j - 1):lower() }
            i = j

        else
            i = i + 1  -- skip unknown
        end
    end

    return selectors
end

------------------------------------------------------------
-- Parse a full selector with combinators
------------------------------------------------------------

--- Parse a CSS selector string into a structured representation.
--- Returns { segments = { {combinator, compound_selectors}, ... } }
--- The first segment has combinator = nil (root).
---@param selector string
---@return table  parsed selector
--- Advance past a compound selector token, skipping brackets and
--- quotes so that spaces/combinators inside [attr="a b"] are not
--- treated as compound boundaries.
local function skip_compound(selector, i, len)
    local in_bracket = 0
    local in_paren = 0
    local in_quote = nil
    while i <= len do
        local ch = selector:sub(i, i)
        if in_quote then
            if ch == in_quote then in_quote = nil end
        elseif ch == '"' or ch == "'" then
            in_quote = ch
        elseif ch == "[" then
            in_bracket = in_bracket + 1
        elseif ch == "]" then
            if in_bracket > 0 then in_bracket = in_bracket - 1 end
        elseif ch == "(" then
            in_paren = in_paren + 1
        elseif ch == ")" then
            if in_paren > 0 then in_paren = in_paren - 1 end
        elseif in_bracket == 0 and in_paren == 0 then
            if ch == " " or ch == ">" or ch == "+" or ch == "~" then
                break
            end
        end
        i = i + 1
    end
    return i
end

function SelectorParser.parse(selector)
    if not selector or selector == "" then
        return { segments = {} }
    end

    -- Trim whitespace
    selector = selector:match("^%s*(.-)%s*$")

    local segments = {}
    local i = 1
    local len = #selector

    -- Parse first compound (no combinator)
    -- Skip leading whitespace
    while i <= len and selector:sub(i, i) == " " do i = i + 1 end

    -- Collect the first compound token (bracket/quote-aware)
    local compound_start = i
    i = skip_compound(selector, i, len)

    if i > compound_start then
        local compound_str = selector:sub(compound_start, i - 1)
        segments[1] = { combinator = nil, selectors = parse_compound(compound_str) }
    end

    -- Parse subsequent segments with combinators
    while i <= len do
        -- Skip whitespace
        local had_space = false
        while i <= len and selector:sub(i, i) == " " do
            i = i + 1
            had_space = true
        end

        if i > len then break end

        local ch = selector:sub(i, i)
        local combinator

        if ch == ">" then
            combinator = "child"
            i = i + 1
        elseif ch == "+" then
            combinator = "adjacent"
            i = i + 1
        elseif ch == "~" then
            combinator = "sibling"
            i = i + 1
        elseif had_space then
            combinator = "descendant"
        else
            break  -- unexpected
        end

        -- Skip whitespace after combinator
        while i <= len and selector:sub(i, i) == " " do i = i + 1 end

        -- Collect next compound (bracket/quote-aware)
        local cs = i
        i = skip_compound(selector, i, len)

        if i > cs then
            local compound_str = selector:sub(cs, i - 1)
            segments[#segments + 1] = {
                combinator = combinator,
                selectors = parse_compound(compound_str)
            }
        end
    end

    return { segments = segments }
end

--- Check if a selector string is complex (needs full parsing).
---@param selector string
---@return boolean
function SelectorParser.is_complex(selector)
    if type(selector) ~= "string" then return false end
    -- Complex if contains combinators, pseudo-classes, or multiple simple selectors
    return selector:find(" ") ~= nil
        or selector:find(">") ~= nil
        or selector:find("+") ~= nil  -- use plain find
        or selector:find("~") ~= nil
        or selector:find(":") ~= nil
        or selector:find("%[") ~= nil
end

--- Compute the specificity of a parsed selector.
---@param parsed table  parsed selector from SelectorParser.parse()
---@return number  specificity value (a*100 + b*10 + c)
function SelectorParser.specificity(parsed)
    local a, b, c = 0, 0, 0  -- IDs, classes/pseudos, tags

    for _, segment in ipairs(parsed.segments) do
        for _, sel in ipairs(segment.selectors) do
            if sel.type == "id" then
                a = a + 1
            elseif sel.type == "class" or sel.type == "pseudo" or sel.type == "attribute" then
                b = b + 1
            elseif sel.type == "tag" or sel.type == "pseudo-element" then
                c = c + 1
            elseif sel.type == "not" then
                -- :not() specificity = max specificity of its selector-list arguments
                local max_spec = 0
                for _, arg_parsed in ipairs(sel.value) do
                    local spec = SelectorParser.specificity(arg_parsed)
                    if spec > max_spec then max_spec = spec end
                end
                local ia = math.floor(max_spec / 10000)
                local ib = math.floor((max_spec % 10000) / 100)
                local ic = max_spec % 100
                a = a + ia
                b = b + ib
                c = c + ic
            elseif sel.type == "is" then
                -- :is() specificity = max specificity of its arguments
                local max_spec = 0
                for _, arg_parsed in ipairs(sel.value) do
                    local spec = SelectorParser.specificity(arg_parsed)
                    if spec > max_spec then max_spec = spec end
                end
                -- Decompose back into a, b, c contributions
                local ia = math.floor(max_spec / 10000)
                local ib = math.floor((max_spec % 10000) / 100)
                local ic = max_spec % 100
                a = a + ia
                b = b + ib
                c = c + ic
            elseif sel.type == "has" then
                -- :has() specificity = specificity of its argument selector
                local has_spec = SelectorParser.specificity(sel.value)
                local ia = math.floor(has_spec / 10000)
                local ib = math.floor((has_spec % 10000) / 100)
                local ic = has_spec % 100
                a = a + ia
                b = b + ib
                c = c + ic
            elseif sel.type == "where" then
                -- :where() always contributes zero specificity
            end
            -- universal (*) adds 0
        end
    end

    return a * 10000 + b * 100 + c
end

return SelectorParser



