------------------------------------------------------------
-- ext_core_astro_ui_lib / core / svg / constants.lua
-- SVG tag classification helpers.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local Constants = {}

local SVG_SHAPE_TAGS = {
    path     = true,
    circle   = true,
    rect     = true,
    ellipse  = true,
    line     = true,
    polyline = true,
    polygon  = true,
}

local SVG_CONTAINER_TAGS = {
    svg = true,
    g   = true,
}

local SVG_TEXT_TAGS = {
    ["svg-text"] = true,
    text = true,
}

local function sorted_keys(set)
    local out = {}
    for k in pairs(set) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

function Constants.get_shape_tags()
    return sorted_keys(SVG_SHAPE_TAGS)
end

function Constants.get_container_tags()
    return sorted_keys(SVG_CONTAINER_TAGS)
end

function Constants.get_text_tags()
    return sorted_keys(SVG_TEXT_TAGS)
end

function Constants.get_all_tags()
    local seen = {}
    local out = {}
    local groups = { SVG_SHAPE_TAGS, SVG_CONTAINER_TAGS, SVG_TEXT_TAGS }
    for gi = 1, #groups do
        for tag in pairs(groups[gi]) do
            if not seen[tag] then
                seen[tag] = true
                out[#out + 1] = tag
            end
        end
    end
    table.sort(out)
    return out
end

--- Check if tag is an SVG shape element.
function Constants.is_svg_shape(tag)
    return SVG_SHAPE_TAGS[tag] == true
end

--- Check if tag is an SVG container (svg or g).
function Constants.is_svg_container(tag)
    return SVG_CONTAINER_TAGS[tag] == true
end

--- Check if tag is any SVG node (shape, container, or text).
function Constants.is_svg_node(tag)
    return SVG_SHAPE_TAGS[tag] == true
        or SVG_CONTAINER_TAGS[tag] == true
        or SVG_TEXT_TAGS[tag] == true
end

--- Check if tag is an SVG child (everything except the root <svg>).
function Constants.is_svg_child(tag)
    if tag == "svg" then return false end
    return Constants.is_svg_node(tag)
end

return Constants



