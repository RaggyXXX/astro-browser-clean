------------------------------------------------------------
-- ext_core_astro_ui_lib / core / util / url.lua
-- Tiny URL helpers for resolving relative references against
-- a base URL (the URL a page was loaded from).
--
-- Supports http(s) URLs and sandbox file paths. It does not
-- claim full RFC 3986 compliance; it handles common cases:
--   - absolute URLs: "http://...", "https://...", "data:..."
--   - protocol-relative: "//cdn..."
--   - root-relative: "/foo/bar"
--   - relative: "foo.png", "../foo.png"
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Url = {}

--- True if `ref` is an absolute URL (has a scheme) or data URI.
---@param ref string
---@return boolean
function Url.is_absolute(ref)
    if type(ref) ~= "string" or ref == "" then return false end
    -- http://, https://, file://, data:, ftp://, ws://, etc.
    return ref:find("^%a[%w%+%-%.]*:") ~= nil
end

--- True if `ref` starts with "//" (protocol-relative).
local function is_protocol_relative(ref)
    return type(ref) == "string" and ref:sub(1, 2) == "//"
end

--- True if `ref` starts with "/" (root-relative, http context).
local function is_root_relative(ref)
    return type(ref) == "string" and ref:sub(1, 1) == "/" and ref:sub(2, 2) ~= "/"
end

--- Split an http(s) URL into { scheme, authority, path, query, fragment }.
--- Returns nil for non-http URLs.
local function split_http(url)
    local scheme, rest = url:match("^(https?)://(.+)$")
    if not scheme then return nil end
    local authority, tail = rest:match("^([^/]+)(.*)$")
    if not authority then
        authority = rest
        tail = ""
    end
    local path, query, fragment = tail, "", ""
    local frag_at = path:find("#", 1, true)
    if frag_at then
        fragment = path:sub(frag_at)
        path = path:sub(1, frag_at - 1)
    end
    local q_at = path:find("?", 1, true)
    if q_at then
        query = path:sub(q_at)
        path = path:sub(1, q_at - 1)
    end
    if path == "" then path = "/" end
    return { scheme = scheme, authority = authority, path = path, query = query, fragment = fragment }
end

--- Return the "directory" portion of a URL or path - everything up to
--- and including the last "/", but without the trailing filename.
--- For "https://host/a/b/page.html" -> "https://host/a/b/".
--- For "https://host" -> "https://host/".
--- For "foo/bar.html" → "foo/".
---@param url string
---@return string
function Url.parent(url)
    if type(url) ~= "string" or url == "" then return "" end
    -- Strip fragment and query first
    local base = url
    local frag_at = base:find("#", 1, true)
    if frag_at then base = base:sub(1, frag_at - 1) end
    local q_at = base:find("?", 1, true)
    if q_at then base = base:sub(1, q_at - 1) end

    -- http(s) path segment
    local parts = split_http(base)
    if parts then
        local path = parts.path
        local slash = path:match("^(.*/)[^/]*$")
        if not slash then slash = "/" end
        return parts.scheme .. "://" .. parts.authority .. slash
    end

    -- Fallback: plain path
    local dir = base:match("^(.*/)[^/]*$")
    return dir or ""
end

--- Collapse "./" and "../" segments in a path (without leading scheme).
local function normalize_path(path)
    local segments = {}
    local leading_slash = path:sub(1, 1) == "/"
    for seg in path:gmatch("[^/]+") do
        if seg == "." then
            -- drop
        elseif seg == ".." then
            if #segments > 0 and segments[#segments] ~= ".." then
                segments[#segments] = nil
            elseif not leading_slash then
                segments[#segments + 1] = ".."
            end
        else
            segments[#segments + 1] = seg
        end
    end
    local joined = table.concat(segments, "/")
    if leading_slash then
        return "/" .. joined
    end
    return joined
end

--- Resolve `ref` against `base`, returning an absolute URL or path.
--- If `ref` is already absolute, it is returned unchanged.
---@param base string|nil  base URL (e.g. "https://host/a/b/page.html" or "dir/sub/")
---@param ref  string       reference to resolve
---@return string
function Url.resolve(base, ref)
    if type(ref) ~= "string" or ref == "" then return ref or "" end
    if Url.is_absolute(ref) then return ref end

    if is_protocol_relative(ref) and base then
        -- Inherit scheme from base
        local scheme = base:match("^(%a[%w%+%-%.]*):") or "https"
        return scheme .. ":" .. ref
    end

    if not base or base == "" then return ref end

    -- For http(s): resolve against scheme+authority
    local parts = split_http(base)
    if parts then
        if ref:sub(1, 1) == "?" then
            return parts.scheme .. "://" .. parts.authority .. parts.path .. ref
        end
        if ref:sub(1, 1) == "#" then
            return parts.scheme .. "://" .. parts.authority .. parts.path .. parts.query .. ref
        end
        if is_root_relative(ref) then
            return parts.scheme .. "://" .. parts.authority .. normalize_path(ref)
        end
        -- Relative: append to base's directory
        local base_dir = parts.path:match("^(.*/)[^/]*$") or "/"
        local combined = normalize_path(base_dir .. ref)
        return parts.scheme .. "://" .. parts.authority .. combined
    end

    -- Plain path base (data-file sandbox)
    if ref:sub(1, 1) == "?" or ref:sub(1, 1) == "#" then
        local base_no_frag = base
        local frag_at = base_no_frag:find("#", 1, true)
        if frag_at then base_no_frag = base_no_frag:sub(1, frag_at - 1) end
        if ref:sub(1, 1) == "?" then
            local q_at = base_no_frag:find("?", 1, true)
            if q_at then base_no_frag = base_no_frag:sub(1, q_at - 1) end
        end
        return base_no_frag .. ref
    end
    if is_root_relative(ref) then
        -- Treat as sandbox-root-relative - strip leading /
        return ref:sub(2)
    end
    local base_dir = base:match("^(.*/)") or ""
    return normalize_path(base_dir .. ref)
end

return Url



