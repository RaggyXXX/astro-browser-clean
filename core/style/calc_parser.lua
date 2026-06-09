------------------------------------------------------------
-- ext_core_astro_ui_lib / core / style / calc_parser.lua
-- CSS function expression parser: calc(), clamp(), min(), max()
--
-- Input:  "calc(100% - 40px)" or "clamp(12px, 2vw, 24px)"
-- Output: AST with {type="calc"|"clamp"|"min"|"max", ...}
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local CalcParser = {}

------------------------------------------------------------
-- Tokenizer
------------------------------------------------------------

local TOKEN_NUM    = "num"
local TOKEN_UNIT   = "unit"
local TOKEN_OP     = "op"
local TOKEN_LPAREN = "("
local TOKEN_RPAREN = ")"
local TOKEN_COMMA  = ","
local TOKEN_FUNC   = "func"
local TOKEN_VAR    = "var"

local function is_alpha(ch)
    return ch:match("[A-Za-z]") ~= nil
end

local function is_unit_char(ch)
    return ch == "%" or ch:match("[A-Za-z]") ~= nil
end

local LENGTH_UNITS = {
    ["%"] = true,
    px = true,
    vw = true, dvw = true, svw = true, lvw = true,
    vh = true, dvh = true, svh = true, lvh = true,
    vmin = true, vmax = true,
    cqw = true, cqi = true, cqh = true, cqb = true, cqmin = true, cqmax = true,
    rem = true, em = true, ch = true, ex = true,
}

--- Tokenize a calc/clamp/min/max expression string.
---@param str string
---@return table  array of {type, value} tokens
local function tokenize(str)
    local tokens = {}
    local i = 1
    local len = #str

    while i <= len do
        local ch = str:sub(i, i)

        -- Skip whitespace
        if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
            i = i + 1

        -- Function names: calc, clamp, min, max
        elseif is_alpha(ch) then
            local j = i
            while j <= len and is_alpha(str:sub(j, j)) do
                j = j + 1
            end
            local word = str:sub(i, j - 1):lower()
            if word == "calc" or word == "clamp" or word == "min" or word == "max" then
                tokens[#tokens + 1] = { TOKEN_FUNC, word }
            elseif word == "var" then
                -- Parse var(--name) or var(--name, fallback)
                -- Consume the opening paren
                if j <= len and str:sub(j, j) == "(" then
                    j = j + 1
                    -- Find matching closing paren (handle nested parens for fallback)
                    local depth = 1
                    local start = j
                    while j <= len and depth > 0 do
                        local c = str:sub(j, j)
                        if c == "(" then depth = depth + 1
                        elseif c == ")" then depth = depth - 1 end
                        if depth > 0 then j = j + 1 end
                    end
                    local inner = str:sub(start, j - 1)
                    -- Split on first comma for name and fallback
                    local var_name, fallback = inner:match("^([^,]+),?%s*(.*)")
                    if var_name then
                        var_name = var_name:match("^%s*(.-)%s*$")  -- trim
                    end
                    if fallback == "" then fallback = nil end
                    tokens[#tokens + 1] = { TOKEN_VAR, { var_name, fallback } }
                    j = j + 1  -- skip closing paren
                end
            end
            i = j

        -- Numbers (possibly with decimal, possibly negative via unary minus handled elsewhere)
        elseif ch:match("[%d%.]") then
            local j = i
            while j <= len and str:sub(j, j):match("[%d%.]") do
                j = j + 1
            end
            local num_str = str:sub(i, j - 1)
            -- Check for unit suffix
            local k = j
            while k <= len and is_unit_char(str:sub(k, k)) do
                k = k + 1
            end
            local unit_str = str:sub(j, k - 1):lower()
            if unit_str == "" then
                tokens[#tokens + 1] = { TOKEN_NUM, tonumber(num_str) or 0 }
            else
                tokens[#tokens + 1] = { TOKEN_UNIT, { tonumber(num_str) or 0, unit_str } }
            end
            i = k

        elseif ch == "+" or ch == "-" then
            -- Check if this is a unary minus (before a number)
            -- Unary if: first token, or after (, or after , or after op
            local prev = tokens[#tokens]
            local is_unary = not prev
                or prev[1] == TOKEN_LPAREN
                or prev[1] == TOKEN_COMMA
                or prev[1] == TOKEN_OP
                or prev[1] == TOKEN_FUNC

            if is_unary and (ch == "-" or ch == "+") then
                -- Check if next char is a digit or dot
                local next_ch = str:sub(i + 1, i + 1)
                if next_ch:match("[%d%.]") then
                    -- Parse as signed number
                    local j = i + 1
                    while j <= len and str:sub(j, j):match("[%d%.]") do
                        j = j + 1
                    end
                    local num_str = str:sub(i, j - 1)
                    local k = j
                    while k <= len and is_unit_char(str:sub(k, k)) do
                        k = k + 1
                    end
                    local unit_str = str:sub(j, k - 1):lower()
                    if unit_str == "" then
                        tokens[#tokens + 1] = { TOKEN_NUM, tonumber(num_str) or 0 }
                    else
                        tokens[#tokens + 1] = { TOKEN_UNIT, { tonumber(num_str) or 0, unit_str } }
                    end
                    i = k
                elseif ch == "+" then
                    -- Unary plus with no following digit: skip it
                    i = i + 1
                else
                    tokens[#tokens + 1] = { TOKEN_OP, ch }
                    i = i + 1
                end
            else
                tokens[#tokens + 1] = { TOKEN_OP, ch }
                i = i + 1
            end

        elseif ch == "*" or ch == "/" then
            tokens[#tokens + 1] = { TOKEN_OP, ch }
            i = i + 1

        elseif ch == "(" then
            tokens[#tokens + 1] = { TOKEN_LPAREN, "(" }
            i = i + 1

        elseif ch == ")" then
            tokens[#tokens + 1] = { TOKEN_RPAREN, ")" }
            i = i + 1

        elseif ch == "," then
            tokens[#tokens + 1] = { TOKEN_COMMA, "," }
            i = i + 1

        else
            i = i + 1  -- skip unknown
        end
    end

    return tokens
end

------------------------------------------------------------
-- Recursive descent parser
------------------------------------------------------------

-- Parser state
local _tokens, _pos, _invalid

local function peek()
    return _tokens[_pos]
end

local function consume()
    local t = _tokens[_pos]
    _pos = _pos + 1
    return t
end

local function expect(ttype)
    local t = consume()
    if not t or t[1] ~= ttype then
        _invalid = true
        return nil
    end
    return t
end

-- Forward declarations
local parse_expr

--- Parse a primary value: number, unit, function call, or parenthesized expression
local function parse_primary()
    local t = peek()
    if not t then return nil end

    if t[1] == TOKEN_NUM then
        consume()
        return { type = "number", value = t[2] }
    end

    if t[1] == TOKEN_UNIT then
        consume()
        if not LENGTH_UNITS[t[2][2]] then
            _invalid = true
            return nil
        end
        return { type = "unit", value = t[2][1], unit = t[2][2] }
    end

    if t[1] == TOKEN_VAR then
        consume()
        return { type = "var", name = t[2][1], fallback = t[2][2] }
    end

    if t[1] == TOKEN_FUNC then
        local func_name = t[2]
        consume()
        if not expect(TOKEN_LPAREN) then return nil end

        if func_name == "calc" then
            local expr = parse_expr()
            if not expr then _invalid = true; return nil end
            if not expect(TOKEN_RPAREN) then return nil end
            return { type = "calc", expr = expr }

        elseif func_name == "clamp" then
            local min_val = parse_expr()
            if not min_val then _invalid = true; return nil end
            if not expect(TOKEN_COMMA) then return nil end
            local val = parse_expr()
            if not val then _invalid = true; return nil end
            if not expect(TOKEN_COMMA) then return nil end
            local max_val = parse_expr()
            if not max_val then _invalid = true; return nil end
            if not expect(TOKEN_RPAREN) then return nil end
            return { type = "clamp", min = min_val, val = val, max = max_val }

        elseif func_name == "min" then
            local args = {}
            args[1] = parse_expr()
            if not args[1] then _invalid = true; return nil end
            while peek() and peek()[1] == TOKEN_COMMA do
                consume()
                args[#args + 1] = parse_expr()
                if not args[#args] then _invalid = true; return nil end
            end
            if not expect(TOKEN_RPAREN) then return nil end
            return { type = "min", args = args }

        elseif func_name == "max" then
            local args = {}
            args[1] = parse_expr()
            if not args[1] then _invalid = true; return nil end
            while peek() and peek()[1] == TOKEN_COMMA do
                consume()
                args[#args + 1] = parse_expr()
                if not args[#args] then _invalid = true; return nil end
            end
            if not expect(TOKEN_RPAREN) then return nil end
            return { type = "max", args = args }
        end
    end

    if t[1] == TOKEN_LPAREN then
        consume()
        local expr = parse_expr()
        if not expr then _invalid = true; return nil end
        if not expect(TOKEN_RPAREN) then return nil end
        return expr
    end

    -- Skip unknown token
    _invalid = true
    return nil
end

--- Parse multiplication and division (higher precedence)
local function parse_mul()
    local left = parse_primary()
    while true do
        local t = peek()
        if not t or t[1] ~= TOKEN_OP then break end
        if t[2] ~= "*" and t[2] ~= "/" then break end
        consume()
        local right = parse_primary()
        if not left or not right then _invalid = true; return nil end
        left = { type = "op", op = t[2], left = left, right = right }
    end
    return left
end

--- Parse addition and subtraction (lower precedence)
parse_expr = function()
    local left = parse_mul()
    while true do
        local t = peek()
        if not t or t[1] ~= TOKEN_OP then break end
        if t[2] ~= "+" and t[2] ~= "-" then break end
        consume()
        local right = parse_mul()
        if not left or not right then _invalid = true; return nil end
        left = { type = "op", op = t[2], left = left, right = right }
    end
    return left
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Parse a CSS calc/clamp/min/max expression string into an AST.
---@param str string  e.g. "calc(100% - 40px)" or "clamp(12px, 2vw, 24px)"
---@return table|nil  AST node
function CalcParser.parse(str)
    if not str or type(str) ~= "string" then return nil end

    _tokens = tokenize(str)
    _pos = 1
    _invalid = false

    if #_tokens == 0 then return nil end

    local result = parse_expr()
    if _invalid or not result or _pos <= #_tokens then return nil end
    return result
end

--- Check if a string contains a CSS function expression.
---@param str string
---@return boolean
function CalcParser.is_calc(str)
    if type(str) ~= "string" then return false end
    local lower = str:lower()
    return lower:find("calc%(") ~= nil
        or lower:find("clamp%(") ~= nil
        or lower:find("min%(") ~= nil
        or lower:find("max%(") ~= nil
end

return CalcParser



