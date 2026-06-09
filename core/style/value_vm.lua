------------------------------------------------------------
-- ext_core_astro_ui_lib / core / style / value_vm.lua
-- CSS value resolver: numbers, units, keywords, calc/clamp.
--
-- Resolves values based on type:
--   number          -> as-is
--   "auto"/"none"   -> as-is
--   "Npx"           -> parse N
--   "N%"            -> percentage of context.percent_base or parent_width
--   "Nvw"           -> viewport_w * N / 100
--   "Nvh"           -> viewport_h * N / 100
--   "Nrem"          -> root_font_size * N
--   {type="px",v=N} -> N
--   {type="pct",v=N}-> context.parent_width * N / 100
--   {type="vw",v=N} -> context.viewport_w * N / 100
--   {type="vh",v=N} -> context.viewport_h * N / 100
--   {type="rem",v=N}-> context.root_font_size * N
--   {type="em",v=N} -> context.font_size * N
--   {type="auto"}   -> "auto"
--   {type="color",v={r,g,b,a}} -> the color array
--   {type="keyword",v=str}     -> str
--   {type="calc",expr=...}     -> evaluate calc expression
--   fallback: tonumber or as-is
--
-- Context: { parent_width, parent_height, font_size,
--            viewport_w, viewport_h, root_font_size }
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local VM = {}

------------------------------------------------------------
-- Calc expression evaluator
------------------------------------------------------------

--- Resolve a single unit value to pixels given context.
---@param value number
---@param unit  string
---@param ctx   table
---@return number
local function resolve_unit(value, unit, ctx)
    if unit == "px" then
        return value
    elseif unit == "%" then
        local base = ctx.percent_base
        if base == nil then base = ctx.parent_width or 0 end
        return base * value / 100
    elseif unit == "vw" or unit == "dvw" or unit == "svw" or unit == "lvw" then
        return (ctx.viewport_w or 0) * value / 100
    elseif unit == "vh" or unit == "dvh" or unit == "svh" or unit == "lvh" then
        return (ctx.viewport_h or 0) * value / 100
    elseif unit == "vmin" then
        local vw = ctx.viewport_w or 0
        local vh = ctx.viewport_h or 0
        return (vw < vh and vw or vh) * value / 100
    elseif unit == "vmax" then
        local vw = ctx.viewport_w or 0
        local vh = ctx.viewport_h or 0
        return (vw > vh and vw or vh) * value / 100
    elseif unit == "cqw" or unit == "cqi" then
        return (ctx.container_w or ctx.parent_width or 0) * value / 100
    elseif unit == "cqh" or unit == "cqb" then
        return (ctx.container_h or ctx.parent_height or 0) * value / 100
    elseif unit == "cqmin" then
        local cw = ctx.container_w or ctx.parent_width or 0
        local ch = ctx.container_h or ctx.parent_height or 0
        return (cw < ch and cw or ch) * value / 100
    elseif unit == "cqmax" then
        local cw = ctx.container_w or ctx.parent_width or 0
        local ch = ctx.container_h or ctx.parent_height or 0
        return (cw > ch and cw or ch) * value / 100
    elseif unit == "rem" then
        return (ctx.root_font_size or 16) * value
    elseif unit == "em" then
        return (ctx.font_size or 16) * value
    elseif unit == "ch" then
        -- Approximation: width of "0" at current font ≈ 0.5 em
        return (ctx.font_size or 16) * 0.5 * value
    elseif unit == "ex" then
        -- Approximation: x-height ≈ 0.5 em
        return (ctx.font_size or 16) * 0.5 * value
    end
    return value
end

--- Recursively evaluate a calc AST node.
---@param node table  calc AST node
---@param ctx  table  resolution context
---@return number
local function eval_calc(node, ctx)
    if not node then return 0 end

    local ntype = node.type

    if ntype == "number" then
        return node.value or 0

    elseif ntype == "unit" then
        return resolve_unit(node.value or 0, node.unit or "px", ctx)

    elseif ntype == "op" then
        local left  = eval_calc(node.left, ctx)
        local right = eval_calc(node.right, ctx)
        local op = node.op
        if op == "+" then return left + right
        elseif op == "-" then return left - right
        elseif op == "*" then return left * right
        elseif op == "/" then
            if right == 0 then return 0 end
            return left / right
        end
        return 0

    elseif ntype == "calc" then
        return eval_calc(node.expr, ctx)

    elseif ntype == "clamp" then
        local min_v = eval_calc(node.min, ctx)
        local val   = eval_calc(node.val, ctx)
        local max_v = eval_calc(node.max, ctx)
        if val < min_v then return min_v end
        if val > max_v then return max_v end
        return val

    elseif ntype == "min" then
        local args = node.args
        if not args or #args == 0 then return 0 end
        local result = eval_calc(args[1], ctx)
        for i = 2, #args do
            local v = eval_calc(args[i], ctx)
            if v < result then result = v end
        end
        return result

    elseif ntype == "var" then
        -- var() should have been resolved before eval; treat as 0 if not
        return 0

    elseif ntype == "max" then
        local args = node.args
        if not args or #args == 0 then return 0 end
        local result = eval_calc(args[1], ctx)
        for i = 2, #args do
            local v = eval_calc(args[i], ctx)
            if v > result then result = v end
        end
        return result
    end

    return 0
end

--- Evaluate a parsed calc expression.
---@param calc_ast table  parsed calc AST
---@param context  table  resolution context
---@return number
function VM.eval_calc(calc_ast, context)
    return eval_calc(calc_ast, context or {})
end

------------------------------------------------------------
-- Main resolver
------------------------------------------------------------

--- Resolve a value given a context table.
--- Context: { parent_width=N, parent_height=N, font_size=N,
---            viewport_w=N, viewport_h=N, root_font_size=N }
---@param value   any     the value to resolve
---@param context table   resolution context
---@return any  resolved value
function VM.resolve(value, context)
    context = context or {}

    -- nil
    if value == nil then
        return 0
    end

    -- Plain number
    if type(value) == "number" then
        return value
    end

    -- String values
    if type(value) == "string" then
        local lower_value = value:lower()

        -- Keywords that pass through
        if lower_value == "auto" or lower_value == "none" then
            return lower_value
        end

        -- "Npx" pattern
        local px = lower_value:match("^([%d%.%-]+)px$")
        if px then
            return tonumber(px) or 0
        end

        -- "N%" pattern
        local pct = lower_value:match("^([%d%.%-]+)%%$")
        if pct then
            local n = tonumber(pct) or 0
            local pw = context.percent_base
            if pw == nil then pw = context.parent_width or 0 end
            return pw * n / 100
        end

        -- "Nvw" / "Ndvw" / "Nsvw" / "Nlvw" -" viewport width variants
        local vw = lower_value:match("^([%d%.%-]+)vw$")
            or lower_value:match("^([%d%.%-]+)dvw$")
            or lower_value:match("^([%d%.%-]+)svw$")
            or lower_value:match("^([%d%.%-]+)lvw$")
        if vw then
            local n = tonumber(vw) or 0
            return (context.viewport_w or 0) * n / 100
        end

        -- "Nvh" / "Ndvh" / "Nsvh" / "Nlvh" -" viewport height variants
        local vh = lower_value:match("^([%d%.%-]+)vh$")
            or lower_value:match("^([%d%.%-]+)dvh$")
            or lower_value:match("^([%d%.%-]+)svh$")
            or lower_value:match("^([%d%.%-]+)lvh$")
        if vh then
            local n = tonumber(vh) or 0
            return (context.viewport_h or 0) * n / 100
        end

        -- "Ncqw/cqh/cqi/cqb/cqmin/cqmax" -" container query units
        local cqw = lower_value:match("^([%d%.%-]+)cqw$") or lower_value:match("^([%d%.%-]+)cqi$")
        if cqw then
            local n = tonumber(cqw) or 0
            return (context.container_w or context.parent_width or 0) * n / 100
        end
        local cqh = lower_value:match("^([%d%.%-]+)cqh$") or lower_value:match("^([%d%.%-]+)cqb$")
        if cqh then
            local n = tonumber(cqh) or 0
            return (context.container_h or context.parent_height or 0) * n / 100
        end
        local cqmin = lower_value:match("^([%d%.%-]+)cqmin$")
        if cqmin then
            local n = tonumber(cqmin) or 0
            local cw = context.container_w or context.parent_width or 0
            local ch = context.container_h or context.parent_height or 0
            return (cw < ch and cw or ch) * n / 100
        end
        local cqmax = lower_value:match("^([%d%.%-]+)cqmax$")
        if cqmax then
            local n = tonumber(cqmax) or 0
            local cw = context.container_w or context.parent_width or 0
            local ch = context.container_h or context.parent_height or 0
            return (cw > ch and cw or ch) * n / 100
        end

        -- "Nvmin" / "Nvmax" (must check before vh/vw in case of overlap)
        local vmn = lower_value:match("^([%d%.%-]+)vmin$")
        if vmn then
            local n = tonumber(vmn) or 0
            local vw_px = context.viewport_w or 0
            local vh_px = context.viewport_h or 0
            return (vw_px < vh_px and vw_px or vh_px) * n / 100
        end
        local vmx = lower_value:match("^([%d%.%-]+)vmax$")
        if vmx then
            local n = tonumber(vmx) or 0
            local vw_px = context.viewport_w or 0
            local vh_px = context.viewport_h or 0
            return (vw_px > vh_px and vw_px or vh_px) * n / 100
        end

        -- "Nch" / "Nex" (character / x-height units -" approximation)
        local ch = lower_value:match("^([%d%.%-]+)ch$")
        if ch then
            return (context.font_size or 16) * 0.5 * (tonumber(ch) or 0)
        end
        local ex = lower_value:match("^([%d%.%-]+)ex$")
        if ex then
            return (context.font_size or 16) * 0.5 * (tonumber(ex) or 0)
        end

        -- "Nrem" pattern (must check before em)
        local rem = lower_value:match("^([%d%.%-]+)rem$")
        if rem then
            local n = tonumber(rem) or 0
            return (context.root_font_size or 16) * n
        end

        -- "Nem" pattern
        local em = lower_value:match("^([%d%.%-]+)em$")
        if em then
            local n = tonumber(em) or 0
            return (context.font_size or 16) * n
        end

        -- Try to parse as number
        local n = tonumber(value)
        if n then return n end

        -- Return string as-is (keyword-like)
        return value
    end

    -- Table values (structured)
    if type(value) == "table" then
        local vtype = value.type

        if vtype == "px" then
            return value.v or 0
        end

        if vtype == "pct" then
            local n = value.v or 0
            local pw = context.percent_base
            if pw == nil then pw = context.parent_width or 0 end
            return pw * n / 100
        end

        if vtype == "vw" then
            local n = value.v or 0
            return (context.viewport_w or 0) * n / 100
        end

        if vtype == "vh" then
            local n = value.v or 0
            return (context.viewport_h or 0) * n / 100
        end

        if vtype == "vmin" then
            local n = value.v or 0
            local vw = context.viewport_w or 0
            local vh = context.viewport_h or 0
            return (vw < vh and vw or vh) * n / 100
        end

        if vtype == "vmax" then
            local n = value.v or 0
            local vw = context.viewport_w or 0
            local vh = context.viewport_h or 0
            return (vw > vh and vw or vh) * n / 100
        end

        if vtype == "ch" or vtype == "ex" then
            return (context.font_size or 16) * 0.5 * (value.v or 0)
        end

        if vtype == "rem" then
            local n = value.v or 0
            return (context.root_font_size or 16) * n
        end

        if vtype == "auto" then
            return "auto"
        end

        if vtype == "none" then
            return "none"
        end

        if vtype == "color" then
            local c = value.v
            if type(c) == "table" then
                return { c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 255 }
            end
            return { 0, 0, 0, 255 }
        end

        if vtype == "keyword" then
            return value.v or ""
        end

        if vtype == "em" then
            local n = value.v or 0
            local fs = context.font_size or 16
            return n * fs
        end

        -- Calc expressions (parsed by CalcParser at build time)
        if vtype == "calc" or vtype == "clamp" or vtype == "min" or vtype == "max" then
            return eval_calc(value, context)
        end

        -- Unknown table type, return as-is
        return value
    end

    -- Boolean or other: return as-is
    return value
end

return VM



