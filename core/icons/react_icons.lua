------------------------------------------------------------
-- ext_core_astro_ui_lib / core / icons / react_icons.lua
-- Async loader for react-icons SVGs from source repos.
--
-- Usage:
--   local ri = ReactIcons.new(platform, icon_cache)
--   ri:request("fi", "eye")          -- async fetch
--   ri:tick()                         -- call each frame
--   local ok = ri:draw(dl, "fi", "eye", 16, x, y, r, g, b, a)
--
-- Caches SVG text to disk so icons only download once.
-- Integrates with existing IconCache for rasterization.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------

local IconCache = require("core/icons/icon_cache")

local ReactIcons = {}
ReactIcons.__index = ReactIcons

local math_floor = math.floor

------------------------------------------------------------
-- Icon pack registry: prefix -> URL template + name transform
------------------------------------------------------------

local PACKS = {
    fi = {
        url = "https://raw.githubusercontent.com/feathericons/feather/main/icons/%s.svg",
        transform = "kebab",
    },
    lu = {
        url = "https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/%s.svg",
        transform = "kebab",
    },
    hi2 = {
        url = "https://raw.githubusercontent.com/tailwindlabs/heroicons/master/optimized/24/outline/%s.svg",
        transform = "kebab",
    },
    bs = {
        url = "https://raw.githubusercontent.com/twbs/icons/main/icons/%s.svg",
        transform = "kebab",
    },
    tb = {
        url = "https://raw.githubusercontent.com/tabler/tabler-icons/main/icons/outline/%s.svg",
        transform = "kebab",
    },
    pi = {
        url = "https://raw.githubusercontent.com/phosphor-icons/core/main/raw/regular/%s.svg",
        transform = "kebab",
    },
}

local CACHE_DIR = "astro_ui_icons"

------------------------------------------------------------
-- Name transforms
------------------------------------------------------------

--- Convert "arrow-left" style name (already kebab) -" identity.
--- Convert "ArrowLeft" CamelCase to "arrow-left" kebab-case.
local function to_kebab(name)
    -- If already lowercase with hyphens, pass through
    if not name:find("[A-Z]") then return name end
    -- Insert hyphen before each uppercase letter, then lowercase
    local result = name:gsub("(%u)", function(c)
        return "-" .. c:lower()
    end)
    -- Remove leading hyphen if present
    if result:sub(1, 1) == "-" then result = result:sub(2) end
    return result
end

------------------------------------------------------------
-- SVG text parsing -" recursive tree parser
------------------------------------------------------------

--- Deep-copy an SVG node tree (for <use> element resolution).
local function deep_copy(node)
    if type(node) ~= "table" then return node end
    local copy = {}
    for k, v in pairs(node) do
        if k == "child" then
            copy.child = {}
            for i = 1, #v do
                copy.child[i] = deep_copy(v[i])
            end
        elseif type(v) == "table" then
            copy[k] = {}
            for kk, vv in pairs(v) do copy[k][kk] = vv end
        else
            copy[k] = v
        end
    end
    return copy
end

--- Parse CSS class rules from a <style> block.
--- Returns table: class_name -> { prop_underscore = value, ... }
local function parse_style_classes(svg)
    local class_styles = {}
    local style_content = svg:match("<style[^>]*>(.-)</style>")
    if not style_content then return class_styles end

    -- Remove CSS comments
    style_content = style_content:gsub("/%*.-%*/", "")

    -- Parse: .cls-name { prop: value; ... }
    -- Also handles compound selectors: .cls-1, .cls-2 { ... }
    for selectors, props_str in style_content:gmatch("([^{]+){([^}]+)}") do
        local props = {}
        for prop, val in props_str:gmatch("([%w%-]+)%s*:%s*([^;]+)") do
            local key = prop:gsub("%-", "_"):match("^%s*(.-)%s*$")
            val = val:match("^%s*(.-)%s*$")
            props[key] = val
        end
        -- Apply to each .class in the selector list
        for cls in selectors:gmatch("%.([%w_%-]+)") do
            class_styles[cls] = props
        end
    end
    return class_styles
end

--- Parse attributes from a tag string like ' id="foo" class="bar"'.
--- Handles both double-quoted and single-quoted values.
--- Returns table with underscore-normalized keys.
local function parse_attrs(attr_str)
    local attr = {}
    if not attr_str then return attr end
    -- Double-quoted: key="value"
    for k, v in attr_str:gmatch('([%w%-_:]+)="([^"]*)"') do
        local key = k:gsub("%-", "_"):gsub(":", "_")
        attr[key] = v
    end
    -- Single-quoted: key='value' (only set if not already from double-quotes)
    for k, v in attr_str:gmatch("([%w%-_:]+)='([^']*)'") do
        local key = k:gsub("%-", "_"):gsub(":", "_")
        if not attr[key] then attr[key] = v end
    end
    return attr
end

--- Merge class styles into a node's attr table (class styles are defaults,
--- inline attrs take precedence).
local function apply_class_styles(node, class_styles)
    if not node.attr or not node.attr.class then return end
    -- A node can have multiple classes: class="cls-1 cls-2"
    for cls in node.attr.class:gmatch("([^%s]+)") do
        local styles = class_styles[cls]
        if styles then
            for k, v in pairs(styles) do
                if not node.attr[k] then
                    node.attr[k] = v
                end
            end
        end
    end
end

--- Recursively apply class styles to a node tree.
local function apply_class_styles_recursive(node, class_styles)
    apply_class_styles(node, class_styles)
    if node.child then
        for i = 1, #node.child do
            apply_class_styles_recursive(node.child[i], class_styles)
        end
    end
end

--- Extract icon tree from raw SVG text.
--- Returns: { tag="svg", attr={...}, child={...} } or nil
local function parse_svg_text(svg)
    if not svg or svg == "" then return nil end

    -- 1) Parse CSS <style> classes
    local class_styles = parse_style_classes(svg)

    -- 2) Strip <style>, <title>, <desc> blocks from content before tokenizing
    local clean = svg:gsub("<style[^>]*>.-</style>", "")
    clean = clean:gsub("<title[^>]*>.-</title>", "")
    clean = clean:gsub("<desc[^>]*>.-</desc>", "")
    -- Strip XML comments
    clean = clean:gsub("<!%-%-.-%--%>", "")

    -- 3) Extract root <svg> attributes
    local svg_open = clean:match("<svg([^>]-)>") or clean:match("<svg([^>]-)/>") or ""
    local root_attr = parse_attrs(svg_open)

    -- viewBox fallback from width/height
    if not root_attr.viewBox then
        local w = tonumber(root_attr.width) or 24
        local h = tonumber(root_attr.height) or 24
        root_attr.viewBox = "0 0 " .. w .. " " .. h
    end

    -- 4) Extract content between <svg ...> and </svg>
    local inner = clean:match("<svg[^>]*>(.-)</svg>")
    if not inner then return nil end

    -- 5) Stack-based tokenizer: walk through all tags in inner content
    --    We collect tokens: { type="open"|"close"|"selfclose", tag=..., attr_str=... }
    local tokens = {}
    -- Match all tags (opening, closing, self-closing)
    -- Pattern explanation: < optional / , then tag name, then attrs, then optional / before >
    for full_tag in inner:gmatch("<([^>]+)>") do
        -- Skip processing instructions, CDATA, etc.
        local first = full_tag:sub(1, 1)
        if first ~= "!" and first ~= "?" then
            if first == "/" then
                -- Closing tag: </tagname>
                local tag_name = full_tag:match("^/(%w+)")
                if tag_name then
                    tokens[#tokens + 1] = { type = "close", tag = tag_name }
                end
            elseif full_tag:sub(-1) == "/" then
                -- Self-closing tag: <tagname attrs/>
                local tag_name = full_tag:match("^(%w+)")
                local attr_str = full_tag:match("^%w+(.*)/") or ""
                if tag_name then
                    tokens[#tokens + 1] = { type = "selfclose", tag = tag_name, attr_str = attr_str }
                end
            else
                -- Opening tag: <tagname attrs>
                local tag_name = full_tag:match("^(%w+)")
                local attr_str = full_tag:match("^%w+(.*)") or ""
                if tag_name then
                    tokens[#tokens + 1] = { type = "open", tag = tag_name, attr_str = attr_str }
                end
            end
        end
    end

    -- 6) Build tree from tokens using a stack
    local root = { tag = "svg", attr = root_attr, child = {} }
    local stack = { root }  -- stack[#stack] is current parent
    local defs = {}          -- [id] -> node subtree
    local in_defs = 0        -- depth counter for <defs> nesting

    for i = 1, #tokens do
        local tok = tokens[i]
        local parent = stack[#stack]

        if tok.type == "selfclose" then
            local node = { tag = tok.tag, attr = parse_attrs(tok.attr_str) }

            -- Handle <use> element: resolve href from defs
            if tok.tag == "use" then
                local href = node.attr.href or node.attr.xlink_href
                if href then
                    local ref_id = href:match("#(.+)")
                    if ref_id and defs[ref_id] then
                        local ref_node = deep_copy(defs[ref_id])
                        -- Apply use's x/y as translate
                        local ux = tonumber(node.attr.x) or 0
                        local uy = tonumber(node.attr.y) or 0
                        if ux ~= 0 or uy ~= 0 then
                            ref_node = { tag = "g", attr = { transform = "translate(" .. ux .. "," .. uy .. ")" }, child = { ref_node } }
                        end
                        -- Apply use's own transform
                        if node.attr.transform then
                            ref_node = { tag = "g", attr = { transform = node.attr.transform }, child = { ref_node } }
                        end
                        node = ref_node
                    end
                end
            end

            if in_defs > 0 then
                -- Inside <defs>: collect by id, don't add to renderable tree
                if node.attr and node.attr.id then
                    defs[node.attr.id] = node
                end
            else
                parent.child[#parent.child + 1] = node
            end

        elseif tok.type == "open" then
            local node = { tag = tok.tag, attr = parse_attrs(tok.attr_str), child = {} }

            if tok.tag == "defs" then
                in_defs = in_defs + 1
                -- Push defs node onto stack so children get attached to it
                stack[#stack + 1] = node
            else
                if in_defs > 0 then
                    -- Inside <defs>: push onto stack but don't add to parent yet
                    stack[#stack + 1] = node
                else
                    parent.child[#parent.child + 1] = node
                    stack[#stack + 1] = node
                end
            end

        elseif tok.type == "close" then
            if #stack > 1 then
                local closed = stack[#stack]
                stack[#stack] = nil  -- pop

                if tok.tag == "defs" then
                    in_defs = in_defs - 1
                    -- Collect all children of defs by their id
                    if closed.child then
                        for j = 1, #closed.child do
                            local c = closed.child[j]
                            if c.attr and c.attr.id then
                                defs[c.attr.id] = c
                            end
                        end
                    end
                elseif in_defs > 0 then
                    -- Closing a tag inside <defs>: attach to defs parent
                    local defs_parent = stack[#stack]
                    if defs_parent and defs_parent.child then
                        defs_parent.child[#defs_parent.child + 1] = closed
                    end
                    -- Also register by id if it has one
                    if closed.attr and closed.attr.id then
                        defs[closed.attr.id] = closed
                    end
                end
            end
        end
    end

    -- 7) Apply class styles recursively
    if next(class_styles) then
        apply_class_styles_recursive(root, class_styles)
    end

    -- 8) Return nil if no renderable children
    if #root.child == 0 then return nil end

    return root
end

------------------------------------------------------------
-- Constructor
------------------------------------------------------------

--- Create a new ReactIcons loader.
---@param platform   table  Platform adapter (http_get, disk I/O)
---@param icon_cache table  IconCache instance (or nil, creates own)
---@return table ReactIcons instance
function ReactIcons.new(platform, icon_cache)
    local self = setmetatable({}, ReactIcons)
    self._platform    = platform
    self._icon_cache  = icon_cache or IconCache:new(platform)
    self._pending     = {}    -- [key] -> "loading" | "done" | "failed"
    self._disk_ok     = false
    -- Copy shared PACKS so register_pack is per-instance
    local packs = {}
    for k, v in pairs(PACKS) do packs[k] = v end
    self._packs       = packs
    return self
end

------------------------------------------------------------
-- Disk cache
------------------------------------------------------------

function ReactIcons:_ensure_dir()
    if self._disk_ok then return end
    local ok = pcall(self._platform.create_data_folder, self._platform, CACHE_DIR)
    self._disk_ok = ok
end

function ReactIcons:_disk_key(pack, name)
    return CACHE_DIR .. "/" .. pack .. "_" .. name .. ".svg"
end

function ReactIcons:_read_disk(pack, name)
    self:_ensure_dir()
    local path = self:_disk_key(pack, name)
    local ok, data = pcall(self._platform.read_data_file, self._platform, path)
    if ok and data and #data > 10 then return data end
    return nil
end

function ReactIcons:_write_disk(pack, name, svg_text)
    self:_ensure_dir()
    local path = self:_disk_key(pack, name)
    pcall(function()
        self._platform:create_data_file(path)
        self._platform:write_data_file(path, svg_text)
    end)
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Get the IconCache (for direct register_path / get calls).
---@return table IconCache
function ReactIcons:cache()
    return self._icon_cache
end

--- Register a custom pack URL template.
---@param prefix    string  Pack prefix (e.g. "md")
---@param url_tmpl  string  URL with %s placeholder for icon name
---@param transform string  "kebab" or "identity"
function ReactIcons:register_pack(prefix, url_tmpl, transform)
    self._packs[prefix] = { url = url_tmpl, transform = transform or "kebab" }
end

--- Request an icon. Triggers async download if not cached.
--- Call tick() each frame to process completed downloads.
---@param pack string  Pack prefix (e.g. "fi")
---@param name string  Icon name (e.g. "eye" or "Eye")
function ReactIcons:request(pack, name)
    local key = pack .. ":" .. name
    local st = self._pending[key]
    if st and st ~= "failed" then return end  -- already loading or done

    -- Check if already registered in icon cache
    if self._icon_cache:has(key) then
        self._pending[key] = "done"
        return
    end

    -- Try disk cache first
    local disk_svg = self:_read_disk(pack, name)
    if disk_svg then
        local tree = parse_svg_text(disk_svg)
        if tree then
            self._icon_cache:register(key, tree)
            self._pending[key] = "done"
            return
        end
    end

    -- Resolve URL
    local pack_info = self._packs[pack]
    if not pack_info then
        self._pending[key] = "failed"
        return
    end

    local file_name = name
    if pack_info.transform == "kebab" then
        file_name = to_kebab(name)
    end
    local url = string.format(pack_info.url, file_name)

    -- Start async download
    self._pending[key] = "loading"
    local self_ref = self
    local ok = pcall(function()
        self._platform:http_get(url, function(http_code, content_type, data, headers)
            if http_code == 200 and data and #data > 10 then
                local tree = parse_svg_text(data)
                if tree then
                    self_ref._icon_cache:register(key, tree)
                    self_ref._pending[key] = "done"
                    -- Save to disk
                    self_ref:_write_disk(pack, name, data)
                    return
                end
            end
            self_ref._pending[key] = "failed"
        end)
    end)
    if not ok then
        self._pending[key] = "failed"
    end
end

--- Check icon status.
---@param pack string
---@param name string
---@return string  "none" | "loading" | "done" | "failed"
function ReactIcons:status(pack, name)
    return self._pending[pack .. ":" .. name] or "none"
end

--- Tick (no-op currently -" HTTP callbacks handle state).
function ReactIcons:tick()
    -- Reserved for future batching / retry logic
end

--- Draw an icon if available. Returns false if not ready yet.
---@param dl         table   DisplayList
---@param pack       string  Pack prefix
---@param name       string  Icon name
---@param size       number  Pixel size
---@param x          number  Draw x
---@param y          number  Draw y
---@param r          number  Tint red 0-255
---@param g          number  Tint green 0-255
---@param b          number  Tint blue 0-255
---@param a          number  Tint alpha 0-255
---@param clip       table|nil  Optional clip rect {x,y,w,h}
---@return boolean   true if drawn
function ReactIcons:draw(dl, pack, name, size, x, y, r, g, b, a, clip)
    local key = pack .. ":" .. name
    -- Auto-request if not yet requested
    if not self._pending[key] then
        self:request(pack, name)
    end
    if self._pending[key] ~= "done" then return false end

    local entry = self._icon_cache:get(key, size)
    if not entry then return false end

    if clip then
        return self._icon_cache:draw_clipped(dl, key, size, x, y, clip, r, g, b, a)
    end
    dl:image(entry.tex_id, x, y, entry.w, entry.h, r, g, b, a)
    return true
end

--- Convenience: request + draw centered in a box.
---@param dl   table   DisplayList
---@param pack string  Pack prefix
---@param name string  Icon name
---@param size number  Icon pixel size
---@param bx   number  Box x
---@param by   number  Box y
---@param bw   number  Box width
---@param bh   number  Box height
---@param r    number  Tint red
---@param g    number  Tint green
---@param b    number  Tint blue
---@param a    number  Tint alpha
---@return boolean
function ReactIcons:draw_centered(dl, pack, name, size, bx, by, bw, bh, r, g, b, a)
    local key = pack .. ":" .. name
    if not self._pending[key] then self:request(pack, name) end
    if self._pending[key] ~= "done" then return false end

    local entry = self._icon_cache:get(key, size)
    if not entry then return false end

    local ix = math_floor(bx + (bw - entry.w) / 2)
    local iy = math_floor(by + (bh - entry.h) / 2)
    dl:image(entry.tex_id, ix, iy, entry.w, entry.h, r, g, b, a)
    return true
end

--- Register an inline SVG path (no download needed).
--- Useful for bundling essential icons as fallbacks.
---@param pack    string  Pack prefix
---@param name    string  Icon name
---@param d       string  SVG path d attribute
---@param viewBox string? ViewBox (default "0 0 24 24")
---@param stroke_w number? Stroke width (default 0 = filled icon)
function ReactIcons:register_inline(pack, name, d, viewBox, stroke_w)
    local key = pack .. ":" .. name
    if stroke_w and stroke_w > 0 then
        -- Register as stroke-based icon with full attr
        self._icon_cache:register(key, {
            tag = "svg",
            attr = { viewBox = viewBox or "0 0 24 24", stroke = "currentColor", stroke_width = tostring(stroke_w), fill = "none" },
            child = { { tag = "path", attr = { d = d } } },
        })
    else
        self._icon_cache:register_path(key, d, viewBox)
    end
    self._pending[key] = "done"
end

------------------------------------------------------------
-- Built-in essential icons (no download needed)
------------------------------------------------------------

--- Register commonly used icons inline.
--- Call once during initialization.
function ReactIcons:register_builtins()
    local SW = 2  -- Feather icons use stroke-width="2"
    -- Feather: eye
    self:register_inline("fi", "eye",
        "M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8zM12 9a3 3 0 100 6 3 3 0 000-6z",
        "0 0 24 24", SW)
    -- Feather: eyedropper / pipette (custom)
    self:register_inline("fi", "pipette",
        "M21.17 2.83a2.83 2.83 0 00-4 0l-2.12 2.12-1.42-1.42-1.41 1.42 1.41 1.41-7.78 7.78a2 2 0 00-.59 1.42V18h2.44a2 2 0 001.42-.59l7.78-7.78 1.41 1.41 1.42-1.41-1.42-1.42 2.12-2.12a2.83 2.83 0 000-4z",
        "0 0 24 24", SW)
    -- Feather: sliders
    self:register_inline("fi", "sliders",
        "M4 21v-7m0-4V3m8 18v-9m0-4V3m8 18v-3m0-4V3M1 14h6M9 8h6M17 16h6",
        "0 0 24 24", SW)
    -- Feather: grid
    self:register_inline("fi", "grid",
        "M3 3h7v7H3zm11 0h7v7h-7zm0 11h7v7h-7zM3 14h7v7H3z",
        "0 0 24 24", SW)
    -- Feather: image
    self:register_inline("fi", "image",
        "M19 3H5a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2V5a2 2 0 00-2-2zM8.5 10a1.5 1.5 0 110-3 1.5 1.5 0 010 3zM21 19l-5-7-5 7H7l3-4.5-2-3L3 19",
        "0 0 24 24", SW)
    -- Feather: droplet
    self:register_inline("fi", "droplet",
        "M12 2.69l5.66 5.66a8 8 0 11-11.31 0z",
        "0 0 24 24", SW)
    -- Feather: copy
    self:register_inline("fi", "copy",
        "M20 9h-9a2 2 0 00-2 2v9a2 2 0 002 2h9a2 2 0 002-2v-9a2 2 0 00-2-2zM5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1",
        "0 0 24 24", SW)
    -- Feather: check
    self:register_inline("fi", "check",
        "M20 6L9 17l-5-5",
        "0 0 24 24", SW)
    -- Feather: crosshair
    self:register_inline("fi", "crosshair",
        "M12 2a10 10 0 100 20 10 10 0 000-20zm0 4a6 6 0 110 12 6 6 0 010-12zM2 12h4m12 0h4M12 2v4m0 12v4",
        "0 0 24 24", SW)
    -- Feather: palette (custom compact)
    self:register_inline("fi", "palette",
        "M12 2C6.49 2 2 6.49 2 12s4.49 10 10 10a2 2 0 002-2v-1.5a2 2 0 011.99-2H17a5 5 0 005-5c0-4.97-4.49-9.5-10-9.5zM6.5 13a1.5 1.5 0 110-3 1.5 1.5 0 010 3zm3-4a1.5 1.5 0 110-3 1.5 1.5 0 010 3zm5 0a1.5 1.5 0 110-3 1.5 1.5 0 010 3zm3 4a1.5 1.5 0 110-3 1.5 1.5 0 010 3z",
        "0 0 24 24", SW)
end

return ReactIcons



