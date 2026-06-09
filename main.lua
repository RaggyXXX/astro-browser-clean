------------------------------------------------------------
-- ext_core_astro_ui_lib / main.lua
-- Public runtime entry point for Astro Browser.
------------------------------------------------------------

local Bootstrap do
    local ok, result = pcall(require, "root/ext_core_astro_ui_lib/core/require_bootstrap")
    Bootstrap = ok and result or require("core/require_bootstrap")
end

Bootstrap.install()

local Engine = Bootstrap.require_public("core/engine")
local HTMLParser = Bootstrap.require_public("core/html/html_parser")
local CSSParser = Bootstrap.require_public("core/html/css_parser")

local AstroBrowser = {
    Engine = Engine,
    HTMLParser = HTMLParser,
    CSSParser = CSSParser,
}

function AstroBrowser.new(config)
    return Engine.new(config)
end

function AstroBrowser.replace_global(config)
    local previous_engine = _G.AstroEngine
    if previous_engine and type(previous_engine.destroy) == "function" then
        pcall(previous_engine.destroy, previous_engine)
    end

    local engine = Engine.new(config)
    _G.AstroEngine = engine
    return engine
end

return AstroBrowser
