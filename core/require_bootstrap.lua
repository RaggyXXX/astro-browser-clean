------------------------------------------------------------
-- ext_core_astro_ui_lib / core / require_bootstrap.lua
-- Cross-plugin require compatibility for Project Sylvanas.
------------------------------------------------------------

local M = {}

M.root = "root/ext_core_astro_ui_lib/"

local ASTRO_PREFIXES = {
    core = true,
    docs = true,
    tools = true,
}

function M.install()
    if rawget(_G, "__ASTRO_UI_REQUIRE_INSTALLED") then
        return
    end

    local raw_require = require

    _G.__ASTRO_UI_REQUIRE_INSTALLED = true
    _G.__ASTRO_UI_RAW_REQUIRE = raw_require

    _G.require = function(name)
        if type(name) == "string" then
            local prefix = name:match("^([^/]+)/")
            if prefix and ASTRO_PREFIXES[prefix] then
                local ok, result = pcall(raw_require, name)
                if ok then
                    return result
                end
                return raw_require(M.root .. name)
            end
        end

        return raw_require(name)
    end
end

function M.require_public(name)
    local ok, result = pcall(require, M.root .. name)
    if ok then
        return result
    end
    return require(name)
end

return M



