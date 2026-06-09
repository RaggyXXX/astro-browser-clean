------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / bundle_validator.lua
-- Internal validator for parsed-value bundles produced by
-- the HTML parser or by tooling that targets the engine.
--
-- Not part of the public contract.
--
-- Returns { ok = boolean, errors = { string, ... } }.
-- Caller decides what to do with the errors (log, reject, etc.).
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Validator = {}

local function push(errors, message)
    errors[#errors + 1] = message
end

local function is_array_of_numbers(t)
    if type(t) ~= "table" then return false end
    for i = 1, #t do
        if type(t[i]) ~= "number" then return false end
    end
    return true
end

local function is_nonnegative_int(n)
    return type(n) == "number" and n >= 0 and n == math.floor(n)
end

local function validate_nodes(nodes, string_count, errors)
    if type(nodes) ~= "table" then
        push(errors, "nodes: expected table, got " .. type(nodes))
        return
    end

    local required = { "tag", "id_str", "class_list", "parent", "node_type", "text_content", "attrs" }
    for i = 1, #required do
        if type(nodes[required[i]]) ~= "table" then
            push(errors, "nodes." .. required[i] .. ": missing or not a table")
        end
    end

    local n = (nodes.tag and #nodes.tag) or 0
    if n == 0 then
        push(errors, "nodes.tag: empty (need at least one node)")
        return
    end

    -- All arrays must have parallel length n
    for i = 1, #required do
        local arr = nodes[required[i]]
        if type(arr) == "table" and #arr ~= n then
            push(errors, "nodes." .. required[i] .. ": length " .. #arr ..
                         " does not match nodes.tag length " .. n)
        end
    end

    -- Type checks on each node
    for i = 1, n do
        -- tag: must be a valid string id (>0 and <= string_count)
        local tag = nodes.tag[i]
        if not is_nonnegative_int(tag) then
            push(errors, "nodes.tag[" .. i .. "]: expected nonnegative integer, got " .. tostring(tag))
        elseif tag > string_count then
            push(errors, "nodes.tag[" .. i .. "]: string id " .. tag ..
                         " exceeds strings length " .. string_count)
        end

        -- id_str: 0 or valid string id
        local id_str = nodes.id_str[i]
        if id_str == nil then
            -- allow nil → treat as 0
        elseif not is_nonnegative_int(id_str) then
            push(errors, "nodes.id_str[" .. i .. "]: expected nonnegative integer, got " .. tostring(id_str))
        elseif id_str > string_count then
            push(errors, "nodes.id_str[" .. i .. "]: string id " .. id_str ..
                         " exceeds strings length " .. string_count)
        end

        -- class_list: table of string ids
        local cls = nodes.class_list[i]
        if cls ~= nil and type(cls) ~= "table" then
            push(errors, "nodes.class_list[" .. i .. "]: expected table, got " .. type(cls))
        elseif type(cls) == "table" then
            for ci = 1, #cls do
                if not is_nonnegative_int(cls[ci]) then
                    push(errors, "nodes.class_list[" .. i .. "][" .. ci .. "]: not a string id")
                    break
                elseif cls[ci] > string_count then
                    push(errors, "nodes.class_list[" .. i .. "][" .. ci .. "]: string id " .. cls[ci] ..
                                 " exceeds strings length " .. string_count)
                    break
                end
            end
        end

        -- parent: 0 or valid node index
        local parent = nodes.parent[i]
        if not is_nonnegative_int(parent) then
            push(errors, "nodes.parent[" .. i .. "]: expected nonnegative integer, got " .. tostring(parent))
        elseif parent > n then
            push(errors, "nodes.parent[" .. i .. "]: refers to node " .. parent .. " but only " .. n .. " exist")
        elseif parent == i then
            push(errors, "nodes.parent[" .. i .. "]: self-reference")
        end

        -- node_type: 1 (ELEMENT) or 2 (TEXT)
        local nt = nodes.node_type[i]
        if nt ~= 1 and nt ~= 2 then
            push(errors, "nodes.node_type[" .. i .. "]: expected 1 (ELEMENT) or 2 (TEXT), got " .. tostring(nt))
        end

        -- attrs: table or nil
        local attrs = nodes.attrs[i]
        if attrs ~= nil and type(attrs) ~= "table" then
            push(errors, "nodes.attrs[" .. i .. "]: expected table or nil, got " .. type(attrs))
        end
    end

    -- Detect cycles in the parent chain (bounded walk, since a valid tree
    -- can't loop and nodes are < n)
    for i = 1, n do
        local steps = 0
        local cur = nodes.parent[i] or 0
        while cur ~= 0 and steps <= n do
            cur = nodes.parent[cur] or 0
            steps = steps + 1
        end
        if steps > n then
            push(errors, "nodes.parent: cycle detected starting at node " .. i)
            break
        end
    end
end

local function validate_rule(rule, where, errors)
    if type(rule) ~= "table" then
        push(errors, where .. ": expected table, got " .. type(rule))
        return
    end
    if rule.order ~= nil and type(rule.order) ~= "number" then
        push(errors, where .. ".order: expected number, got " .. type(rule.order))
    end
    if rule.specificity ~= nil and type(rule.specificity) ~= "number" then
        push(errors, where .. ".specificity: expected number, got " .. type(rule.specificity))
    end
    if rule.decls ~= nil and type(rule.decls) ~= "table" then
        push(errors, where .. ".decls: expected table, got " .. type(rule.decls))
    end
end

local function validate_rules(rules, errors)
    if rules == nil then return end
    if type(rules) ~= "table" then
        push(errors, "rules: expected table, got " .. type(rules))
        return
    end

    for key, bucket in pairs({ by_id = rules.by_id, by_class = rules.by_class, by_tag = rules.by_tag }) do
        if bucket ~= nil then
            if type(bucket) ~= "table" then
                push(errors, "rules." .. key .. ": expected table")
            else
                for k, arr in pairs(bucket) do
                    if type(arr) ~= "table" then
                        push(errors, "rules." .. key .. "[" .. tostring(k) .. "]: expected array")
                    else
                        for i = 1, #arr do
                            validate_rule(arr[i], "rules." .. key .. "[" .. tostring(k) .. "][" .. i .. "]", errors)
                        end
                    end
                end
            end
        end
    end

    if rules.universal ~= nil then
        if type(rules.universal) ~= "table" then
            push(errors, "rules.universal: expected array")
        else
            for i = 1, #rules.universal do
                validate_rule(rules.universal[i], "rules.universal[" .. i .. "]", errors)
            end
        end
    end

    if rules.complex ~= nil then
        if type(rules.complex) ~= "table" then
            push(errors, "rules.complex: expected array")
        else
            for i = 1, #rules.complex do
                local entry = rules.complex[i]
                if type(entry) ~= "table" or type(entry.parsed) ~= "table" or type(entry.rule) ~= "table" then
                    push(errors, "rules.complex[" .. i .. "]: expected {parsed=table, rule=table}")
                else
                    validate_rule(entry.rule, "rules.complex[" .. i .. "].rule", errors)
                end
            end
        end
    end
end

local function validate_scripts(scripts, errors)
    if scripts == nil then return end
    if type(scripts) ~= "table" then
        push(errors, "scripts: expected array, got " .. type(scripts))
        return
    end
    for i = 1, #scripts do
        local s = scripts[i]
        if type(s) ~= "table" then
            push(errors, "scripts[" .. i .. "]: expected table")
        else
            if type(s.code) ~= "string" then
                push(errors, "scripts[" .. i .. "].code: expected string")
            end
            if s.lang ~= nil and type(s.lang) ~= "string" then
                push(errors, "scripts[" .. i .. "].lang: expected string")
            end
            if s.lang and s.lang ~= "lua" then
                -- Non-fatal: unsupported languages are skipped at runtime,
                -- so just note it.
                push(errors, "scripts[" .. i .. "].lang: '" .. tostring(s.lang) ..
                             "' is not supported, only 'lua' is executed")
            end
        end
    end
end

local function validate_stylesheets(sheets, errors)
    if sheets == nil then return end
    if type(sheets) ~= "table" then
        push(errors, "stylesheets: expected array, got " .. type(sheets))
        return
    end
    for i = 1, #sheets do
        local sh = sheets[i]
        if type(sh) ~= "table" or type(sh.href) ~= "string" then
            push(errors, "stylesheets[" .. i .. "]: expected {href=string, media?=string}")
        end
    end
end

--- Validate a bundle. Always returns; caller checks .ok.
---@param bundle table
---@return table  { ok = boolean, errors = { string, ... }, schema = string|nil }
function Validator.validate(bundle)
    local errors = {}
    local schema

    if type(bundle) ~= "table" then
        return { ok = false, errors = { "bundle: expected table, got " .. type(bundle) } }
    end

    if bundle.meta ~= nil and type(bundle.meta) == "table" then
        schema = bundle.meta.schema
    end

    -- Basic shape
    if type(bundle.strings) ~= "table" then
        push(errors, "strings: missing or not a table")
    end
    local string_count = (type(bundle.strings) == "table") and #bundle.strings or 0

    validate_nodes(bundle.nodes, string_count, errors)
    validate_rules(bundle.rules, errors)
    validate_scripts(bundle.scripts, errors)
    validate_stylesheets(bundle.stylesheets, errors)

    -- Strict checks only when the schema is the current canonical one
    if schema == "astro_ui_ir_v1" then
        if type(bundle.meta.name) ~= "string" then
            push(errors, "meta.name: expected string in strict mode")
        end
    end

    return { ok = #errors == 0, errors = errors, schema = schema }
end

return Validator



