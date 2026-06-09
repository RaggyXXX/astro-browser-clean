------------------------------------------------------------
-- ext_core_astro_ui_lib / core / style / selector_matcher.lua
-- Match a parsed CSS selector against a DOM node.
--
-- Supports: descendant (space), child (>), adjacent (+),
-- general sibling (~), pseudo-classes (:hover, :focus,
-- :active, :first-child, :last-child, :nth-child(N),
-- :nth-of-type, :nth-last-child, :nth-last-of-type,
-- :only-of-type, :required, :optional, :valid, :invalid,
-- :placeholder-shown, :read-only, :read-write,
-- :is(), :where(), :not(), :has()),
-- attribute selectors ([attr], [attr=val], [attr~=val],
-- [attr|=val], [attr^=val], [attr$=val], [attr*=val])
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local SelectorMatcher = {}

------------------------------------------------------------
-- Helper: check if an index matches an an+b formula
------------------------------------------------------------
local function nth_matches(index, nth)
    if type(nth) == "number" then return index == nth end
    local a, b = nth.a, nth.b
    if a == 0 then return index == b end
    local diff = index - b
    if a > 0 then return diff >= 0 and diff % a == 0 end
    if a < 0 then return diff <= 0 and (-diff) % (-a) == 0 end
    return false
end

------------------------------------------------------------
-- Helper: should this node count as a sibling for the purposes of
-- structural pseudo-classes (`:nth-child`, `:first-child`, etc.)?
--
-- Per CSS Selectors L4 §13.* these match against *element children* only -"
-- so text nodes are skipped (handled here via `node_type`).  We also skip
-- synthetic `::before`/`::after` ELEMENTs (marked `attrs._is_pseudo`) so
-- that pseudo elements don't shift the index of author-visible children.
-- Without this, `tbody > tr:nth-child(even)` would break the moment the
-- tbody also has a `::before` rule.
------------------------------------------------------------
local function is_structural_sibling(ns, cid)
    if ns.node_type[cid] ~= ns.ELEMENT then return false end
    local at = ns.attrs[cid]
    if at and at._is_pseudo then return false end
    return true
end

------------------------------------------------------------
-- Compound selector matching
------------------------------------------------------------

-- Forward declaration so match_simple can call match_compound
-- (needed for :is() and :where() which recurse into compound matching)
local match_compound

-- Forward declaration so match_simple :has() can call prev_sibling
local prev_sibling

--- Check if a single simple selector matches a node.
---@param ns       table   NodeStore
---@param nid      number  node id
---@param sel      table   {type, value, ...}
---@return boolean
local function match_simple(ns, nid, sel)
    local stype = sel.type

    if stype == "universal" then
        return true

    elseif stype == "tag" then
        local tag_id = ns.tag[nid]
        local tag_str = ns._st:get(tag_id)
        return tag_str == sel.value

    elseif stype == "class" then
        local cls_list = ns.class_list[nid]
        if not cls_list then return false end
        local target_id = ns._st:intern(sel.value)
        for i = 1, #cls_list do
            if cls_list[i] == target_id then return true end
        end
        return false

    elseif stype == "id" then
        local id_str_id = ns.id_str[nid]
        if not id_str_id or id_str_id == 0 then return false end
        local target_id = ns._st:intern(sel.value)
        return id_str_id == target_id

    elseif stype == "pseudo" then
        local pseudo_name = sel.value

        if pseudo_name == "hover" then
            local pseudo = ns.pseudo[nid]
            return pseudo and pseudo.hover == true

        elseif pseudo_name == "focus" then
            local pseudo = ns.pseudo[nid]
            return pseudo and pseudo.focus == true

        elseif pseudo_name == "active" then
            local pseudo = ns.pseudo[nid]
            return pseudo and pseudo.active == true

        elseif pseudo_name == "checked" then
            local pseudo = ns.pseudo[nid]
            return pseudo and pseudo.checked == true

        elseif pseudo_name == "disabled" then
            local pseudo = ns.pseudo[nid]
            if pseudo and pseudo.disabled then return true end
            local attrs = ns.attrs[nid]
            return attrs and attrs.disabled ~= nil and attrs.disabled ~= false

        elseif pseudo_name == "enabled" then
            -- Only form-associated elements can be :enabled
            local tag_id_e = ns.tag[nid]
            local tag_str_e = ns._st:get(tag_id_e)
            local form_tags = { button=true, input=true, select=true, textarea=true, checkbox=true, switch=true, slider=true }
            if not form_tags[tag_str_e] then return false end
            local pseudo = ns.pseudo[nid]
            if pseudo and pseudo.disabled then return false end
            local attrs = ns.attrs[nid]
            if attrs and attrs.disabled ~= nil and attrs.disabled ~= false then return false end
            return true

        elseif pseudo_name == "first-child" then
            -- CSS Selectors L4 §13: structural pseudo-classes match against
            -- element children of the parent.  Skip text nodes AND synthetic
            -- pseudo-elements (otherwise ::before would steal index 1).
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local cid = ns.first_child[parent_id]
            while cid and cid ~= 0 and not is_structural_sibling(ns, cid) do
                cid = ns.next_sibling[cid] or 0
            end
            return cid == nid

        elseif pseudo_name == "last-child" then
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local cid = ns.first_child[parent_id]
            if not cid or cid == 0 then return false end
            local last = 0
            while cid ~= 0 do
                if is_structural_sibling(ns, cid) then last = cid end
                cid = ns.next_sibling[cid] or 0
            end
            return last == nid

        elseif pseudo_name == "focus-visible" then
            local pseudo = ns.pseudo[nid]
            return pseudo and pseudo.focus_visible == true

        elseif pseudo_name == "focus-within" then
            local pseudo = ns.pseudo[nid]
            return pseudo and pseudo.focus_within == true

        elseif pseudo_name == "link" then
            -- :link matches <a> with href that has NOT been visited
            local tag_id_l = ns.tag[nid]
            local tag_str_l = ns._st:get(tag_id_l)
            if tag_str_l ~= "a" then return false end
            local attrs = ns.attrs[nid]
            if not attrs or not attrs.href then return false end
            local visited = ns._visited_urls
            return not (visited and visited[attrs.href])

        elseif pseudo_name == "visited" then
            -- :visited matches <a> with href that HAS been visited
            local tag_id_v = ns.tag[nid]
            local tag_str_v = ns._st:get(tag_id_v)
            if tag_str_v ~= "a" then return false end
            local attrs = ns.attrs[nid]
            if not attrs or not attrs.href then return false end
            local visited = ns._visited_urls
            return visited and visited[attrs.href] == true

        elseif pseudo_name == "empty" then
            local fc = ns.first_child[nid]
            while fc and fc ~= 0 do
                local at = ns.attrs[fc]
                if not (at and at._is_pseudo) then
                    return false
                end
                fc = ns.next_sibling[fc] or 0
            end
            return true

        elseif pseudo_name == "only-child" then
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local cid = ns.first_child[parent_id]
            local count, hit = 0, false
            while cid and cid ~= 0 do
                if is_structural_sibling(ns, cid) then
                    count = count + 1
                    if cid == nid then hit = true end
                    if count > 1 then return false end
                end
                cid = ns.next_sibling[cid] or 0
            end
            return hit and count == 1

        elseif pseudo_name == "first-of-type" then
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local my_tag = ns.tag[nid]
            local cid = ns.first_child[parent_id]
            if not cid or cid == 0 then return false end
            while cid ~= 0 do
                if ns.tag[cid] == my_tag then return cid == nid end
                cid = ns.next_sibling[cid] or 0
            end
            return false

        elseif pseudo_name == "last-of-type" then
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local my_tag = ns.tag[nid]
            local cid = ns.first_child[parent_id]
            if not cid or cid == 0 then return false end
            local last_of_type = 0
            while cid ~= 0 do
                if ns.tag[cid] == my_tag then last_of_type = cid end
                cid = ns.next_sibling[cid] or 0
            end
            return last_of_type == nid

        elseif pseudo_name == "root" then
            local parent_id = ns.parent[nid]
            return not parent_id or parent_id == 0

        elseif pseudo_name == "nth-child" then
            local nth = sel.arg
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local cid = ns.first_child[parent_id]
            if not cid or cid == 0 then return false end
            local index = 0
            while cid ~= 0 do
                if is_structural_sibling(ns, cid) then
                    index = index + 1
                    if cid == nid then return nth_matches(index, nth) end
                end
                cid = ns.next_sibling[cid] or 0
            end
            return false

        elseif pseudo_name == "nth-of-type" then
            local nth = sel.arg
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local my_tag = ns.tag[nid]
            local cid = ns.first_child[parent_id]
            if not cid or cid == 0 then return false end
            local index = 0
            while cid ~= 0 do
                if ns.tag[cid] == my_tag then
                    index = index + 1
                    if cid == nid then return nth_matches(index, nth) end
                end
                cid = ns.next_sibling[cid] or 0
            end
            return false

        elseif pseudo_name == "nth-last-child" then
            local nth = sel.arg
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            -- Collect structural-siblings only (skip text nodes + pseudos)
            local children = {}
            local cid = ns.first_child[parent_id]
            while cid and cid ~= 0 do
                if is_structural_sibling(ns, cid) then
                    children[#children + 1] = cid
                end
                cid = ns.next_sibling[cid] or 0
            end
            local total = #children
            for ci = 1, total do
                if children[ci] == nid then
                    local index_from_end = total - ci + 1
                    return nth_matches(index_from_end, nth)
                end
            end
            return false

        elseif pseudo_name == "nth-last-of-type" then
            local nth = sel.arg
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local my_tag = ns.tag[nid]
            -- Collect same-tag siblings
            local same_tag = {}
            local cid = ns.first_child[parent_id]
            while cid and cid ~= 0 do
                if ns.tag[cid] == my_tag then
                    same_tag[#same_tag + 1] = cid
                end
                cid = ns.next_sibling[cid] or 0
            end
            local total = #same_tag
            for ci = 1, total do
                if same_tag[ci] == nid then
                    local index_from_end = total - ci + 1
                    return nth_matches(index_from_end, nth)
                end
            end
            return false

        elseif pseudo_name == "lang" then
            -- :lang(en)  -" matches elements whose effective language starts with
            -- the given BCP 47 tag (e.g. "en" also matches "en-US").  Walks up
            -- ancestors looking for a lang attribute.
            local target = (sel.arg or ""):lower():match("^%s*(.-)%s*$")
            if target == "" then return false end
            local cur = nid
            while cur and cur ~= 0 do
                local a = ns.attrs[cur]
                if a and a.lang and a.lang ~= "" then
                    local el = a.lang:lower()
                    if el == target
                       or el:sub(1, #target + 1) == target .. "-" then
                        return true
                    end
                    return false
                end
                cur = ns.parent[cur] or 0
            end
            return false

        elseif pseudo_name == "dir" then
            -- :dir(ltr) / :dir(rtl) -" matches the element's effective direction.
            local target = (sel.arg or ""):lower():match("^%s*(.-)%s*$")
            if target ~= "ltr" and target ~= "rtl" then return false end
            local cur = nid
            while cur and cur ~= 0 do
                local a = ns.attrs[cur]
                if a and a.dir and a.dir ~= "" then
                    return a.dir:lower() == target
                end
                cur = ns.parent[cur] or 0
            end
            return target == "ltr"  -- default

        elseif pseudo_name == "only-of-type" then
            local parent_id = ns.parent[nid]
            if not parent_id or parent_id == 0 then return false end
            local my_tag = ns.tag[nid]
            local cid = ns.first_child[parent_id]
            while cid and cid ~= 0 do
                if cid ~= nid and ns.tag[cid] == my_tag then
                    return false
                end
                cid = ns.next_sibling[cid] or 0
            end
            return true

        elseif pseudo_name == "required" then
            -- Element has required attribute (form controls only)
            local tag_id_req = ns.tag and ns.tag[nid]
            local tag_str_req = tag_id_req and ns._st:get(tag_id_req)
            local is_form = tag_str_req == "input" or tag_str_req == "textarea" or tag_str_req == "select"
            local attrs = ns.attrs[nid]
            if not (is_form and attrs and attrs.required) then return false end
            return true

        elseif pseudo_name == "optional" then
            -- Form element without required attribute
            local tag_id_opt = ns.tag[nid]
            local tag_str_opt = ns._st:get(tag_id_opt)
            local is_form = tag_str_opt == "input" or tag_str_opt == "textarea" or tag_str_opt == "select"
            if not is_form then return false end
            local attrs = ns.attrs[nid]
            if attrs and attrs.required then return false end
            return true

        elseif pseudo_name == "valid" then
            -- Element passes validation (pseudo.valid flag set by component)
            local pseudo = ns.pseudo[nid]
            if not (pseudo and pseudo.valid) then return false end
            return true

        elseif pseudo_name == "invalid" then
            -- Element fails validation (pseudo.invalid flag set by component)
            local pseudo = ns.pseudo[nid]
            if not (pseudo and pseudo.invalid) then return false end
            return true

        elseif pseudo_name == "placeholder-shown" then
            -- Input is empty and showing placeholder
            local pseudo = ns.pseudo[nid]
            if not (pseudo and pseudo.placeholder_shown) then return false end
            return true

        elseif pseudo_name == "read-only" then
            local attrs = ns.attrs[nid]
            if not (attrs and (attrs.readonly or attrs.disabled)) then return false end
            return true

        elseif pseudo_name == "read-write" then
            local tag_id_rw = ns.tag[nid]
            local tag_str_rw = ns._st:get(tag_id_rw)
            local is_editable = tag_str_rw == "input" or tag_str_rw == "textarea"
            if not is_editable then return false end
            local attrs = ns.attrs[nid]
            if attrs and (attrs.readonly or attrs.disabled) then return false end
            return true
        end

        return false

    elseif stype == "attribute" then
        local attrs = ns.attrs[nid]
        if not attrs then return false end
        local attr_name = sel.name
        local op = sel.op
        local actual = attrs[attr_name]

        -- [attr] -" existence check
        if not op then
            return actual ~= nil
        end

        -- For comparison, coerce to string
        if actual == nil then return false end
        if type(actual) == "boolean" then
            actual = actual and attr_name or ""
        else
            actual = tostring(actual)
        end
        local expected = sel.value or ""

        -- Case-insensitive flag
        if sel.case_flag == "i" then
            actual = actual:lower()
            expected = expected:lower()
        end

        if op == "=" then
            return actual == expected
        elseif op == "~=" then
            -- Word match in space-separated list
            for word in actual:gmatch("%S+") do
                if word == expected then return true end
            end
            return false
        elseif op == "|=" then
            -- Exact or prefix followed by "-"
            return actual == expected or actual:sub(1, #expected + 1) == expected .. "-"
        elseif op == "^=" then
            return expected ~= "" and actual:sub(1, #expected) == expected
        elseif op == "$=" then
            return expected ~= "" and actual:sub(-#expected) == expected
        elseif op == "*=" then
            return expected ~= "" and actual:find(expected, 1, true) ~= nil
        end
        return false

    elseif stype == "not" then
        -- :not() matches when none of its selector-list arguments match.
        -- Each argument is a full parsed selector, evaluated with nid as
        -- the key-selector target, like :is() / :where().
        local selector_args = sel.value
        for i = 1, #selector_args do
            if SelectorMatcher.matches(ns, nid, selector_args[i]) then
                return false
            end
        end
        return true

    elseif stype == "has" then
        -- :has() matches if any descendant/child of nid satisfies the argument selector.
        -- sel.value is a full parsed selector with segments.
        local has_parsed = sel.value
        local segments = has_parsed.segments
        if not segments or #segments == 0 then return false end

        -- SelectorParser.parse("> .foo") => [{combinator="child", selectors=[.foo]}]
        -- SelectorParser.parse(".foo")   => [{combinator=nil, selectors=[.foo]}]
        -- combinator="child" => check direct children only
        -- combinator=nil     => check all descendants

        local first_seg = segments[1]
        local first_comb = first_seg.combinator

        if #segments == 1 then
            -- Simple case: single compound selector
            if first_comb == "child" then
                -- :has(> .foo) - only direct children
                local cid = ns.first_child[nid]
                while cid and cid ~= 0 do
                    if match_compound(ns, cid, first_seg.selectors) then
                        return true
                    end
                    cid = ns.next_sibling[cid] or 0
                end
            elseif first_comb == "adjacent" then
                -- :has(+ .foo) - immediately following sibling
                local next_id = ns.next_sibling[nid] or 0
                return next_id ~= 0 and match_compound(ns, next_id, first_seg.selectors)
            elseif first_comb == "sibling" then
                -- :has(~ .foo) - any following sibling
                local sib = ns.next_sibling[nid] or 0
                while sib and sib ~= 0 do
                    if match_compound(ns, sib, first_seg.selectors) then
                        return true
                    end
                    sib = ns.next_sibling[sib] or 0
                end
            else
                -- :has(.foo) - any descendant (depth-first walk)
                local stack = {}
                local cid = ns.first_child[nid]
                while cid and cid ~= 0 do
                    stack[#stack + 1] = cid
                    cid = ns.next_sibling[cid] or 0
                end
                while #stack > 0 do
                    local cur = stack[#stack]
                    stack[#stack] = nil
                    if match_compound(ns, cur, first_seg.selectors) then
                        return true
                    end
                    -- Push children
                    local child = ns.first_child[cur]
                    while child and child ~= 0 do
                        stack[#stack + 1] = child
                        child = ns.next_sibling[child] or 0
                    end
                end
            end
            return false
        else
            -- Multi-segment: e.g. :has(> .foo .bar) or :has(.foo > .bar)
            -- We need to find a descendant that matches the LAST segment,
            -- then verify the full chain leads back to nid's subtree.
            -- Approach: walk all descendants, for each try matching the full
            -- selector chain where the "root" must be within nid's subtree.
            local last_seg = segments[#segments]

            -- Determine search scope based on first combinator
            local candidates = {}
            if first_comb == "child" then
                -- First hop is child-only, but later segments may go deeper.
                -- We still need to search all descendants for the last segment match,
                -- then verify the chain. Collect all descendants.
                local stack = {}
                local cid = ns.first_child[nid]
                while cid and cid ~= 0 do
                    stack[#stack + 1] = cid
                    cid = ns.next_sibling[cid] or 0
                end
                while #stack > 0 do
                    local cur = stack[#stack]
                    stack[#stack] = nil
                    candidates[#candidates + 1] = cur
                    local child = ns.first_child[cur]
                    while child and child ~= 0 do
                        stack[#stack + 1] = child
                        child = ns.next_sibling[child] or 0
                    end
                end
            else
                -- Descendant: collect all descendants
                local stack = {}
                local cid = ns.first_child[nid]
                while cid and cid ~= 0 do
                    stack[#stack + 1] = cid
                    cid = ns.next_sibling[cid] or 0
                end
                while #stack > 0 do
                    local cur = stack[#stack]
                    stack[#stack] = nil
                    candidates[#candidates + 1] = cur
                    local child = ns.first_child[cur]
                    while child and child ~= 0 do
                        stack[#stack + 1] = child
                        child = ns.next_sibling[child] or 0
                    end
                end
            end

            -- For each candidate, check if it matches the last segment,
            -- then walk backwards through the selector chain verifying
            -- each combinator relationship, stopping at nid.
            for _, cand in ipairs(candidates) do
                if match_compound(ns, cand, last_seg.selectors) then
                    -- Walk backwards through segments verifying the chain
                    local si = #segments - 1
                    local cur = cand
                    local ok = true
                    while si >= 1 and ok do
                        local seg_above = segments[si + 1]
                        local comb = seg_above.combinator
                        local target_sels = segments[si].selectors

                        if comb == "child" then
                            local p = ns.parent[cur]
                            if not p or p == 0 then ok = false
                            elseif si == 1 and first_comb == "child" then
                                -- The first segment with child combinator must be a direct child of nid
                                if p ~= nid or not match_compound(ns, p, target_sels) then
                                    ok = false
                                else
                                    cur = p
                                end
                            elseif not match_compound(ns, p, target_sels) then
                                ok = false
                            else
                                cur = p
                            end
                        elseif comb == "descendant" or comb == nil then
                            local anc = ns.parent[cur]
                            local found = false
                            while anc and anc ~= 0 do
                                if match_compound(ns, anc, target_sels) then
                                    -- If this is the first segment with child combinator,
                                    -- ancestor must be a direct child of nid
                                    if si == 1 and first_comb == "child" then
                                        if ns.parent[anc] == nid then
                                            cur = anc
                                            found = true
                                        end
                                    else
                                        cur = anc
                                        found = true
                                    end
                                    if found then break end
                                end
                                -- Don't go above nid
                                if anc == nid then break end
                                anc = ns.parent[anc]
                            end
                            if not found then ok = false end
                        elseif comb == "adjacent" then
                            local prev = prev_sibling(ns, cur)
                            if prev == 0 or not match_compound(ns, prev, target_sels) then
                                ok = false
                            else
                                cur = prev
                            end
                        elseif comb == "sibling" then
                            local par = ns.parent[cur]
                            if not par or par == 0 then ok = false
                            else
                                local sib = ns.first_child[par]
                                local found = false
                                while sib and sib ~= 0 and sib ~= cur do
                                    if match_compound(ns, sib, target_sels) then
                                        cur = sib
                                        found = true
                                    end
                                    sib = ns.next_sibling[sib] or 0
                                end
                                if not found then ok = false end
                            end
                        else
                            ok = false
                        end
                        si = si - 1
                    end

                    if ok then
                        -- Verify the matched chain is within nid's subtree
                        -- cur should be a descendant (or child) of nid
                        if first_comb == "child" then
                            -- cur (the first-segment match) must have nid as parent
                            if ns.parent[cur] == nid then return true end
                        else
                            -- cur must be a descendant of nid
                            local anc = cur
                            while anc and anc ~= 0 do
                                if ns.parent[anc] == nid then return true end
                                anc = ns.parent[anc]
                            end
                        end
                    end
                end
            end
            return false
        end

    elseif stype == "is" or stype == "where" then
        -- :is() / :where() matches if ANY of the parsed selectors match.
        -- Each argument is a full parsed selector (supports combinators),
        -- evaluated with nid as the key-selector target.
        local selector_args = sel.value
        for i = 1, #selector_args do
            if SelectorMatcher.matches(ns, nid, selector_args[i]) then
                return true
            end
        end
        return false
    end

    return false
end

--- Check if a compound selector (array of simple selectors) matches a node.
---@param ns         table   NodeStore
---@param nid        number  node id
---@param selectors  table   array of simple selectors
---@return boolean
match_compound = function(ns, nid, selectors)
    for i = 1, #selectors do
        if not match_simple(ns, nid, selectors[i]) then
            return false
        end
    end
    return true
end

------------------------------------------------------------
-- Find previous sibling
------------------------------------------------------------

--- Get the previous sibling of a node.
---@param ns   table   NodeStore
---@param nid  number  node id
---@return number  previous sibling id, or 0
prev_sibling = function(ns, nid)
    local parent_id = ns.parent[nid]
    if not parent_id or parent_id == 0 then return 0 end
    local cid = ns.first_child[parent_id]
    if not cid or cid == 0 then return 0 end
    if cid == nid then return 0 end  -- first child has no prev
    local prev = cid
    cid = ns.next_sibling[cid] or 0
    while cid ~= 0 do
        if cid == nid then return prev end
        prev = cid
        cid = ns.next_sibling[cid] or 0
    end
    return 0
end

------------------------------------------------------------
-- Full selector matching
------------------------------------------------------------

--- Match a parsed selector against a node.
--- Segments are matched right-to-left (last segment = key selector).
---@param ns      table   NodeStore
---@param nid     number  node id to test
---@param parsed  table   parsed selector from SelectorParser.parse()
---@return boolean
function SelectorMatcher.matches(ns, nid, parsed)
    local segments = parsed.segments
    if not segments or #segments == 0 then return false end

    -- Start from the last segment (key selector)
    local seg_idx = #segments
    local current = nid

    -- The key selector (last segment) must match the target node
    if not match_compound(ns, current, segments[seg_idx].selectors) then
        return false
    end

    -- Walk backwards through segments, checking combinators
    seg_idx = seg_idx - 1

    while seg_idx >= 1 do
        local segment = segments[seg_idx + 1]  -- the segment that specifies the combinator
        local combinator = segment.combinator
        local prev_segment = segments[seg_idx]

        if combinator == "child" then
            -- Parent must match
            local parent_id = ns.parent[current]
            if not parent_id or parent_id == 0 then return false end
            if not match_compound(ns, parent_id, prev_segment.selectors) then
                return false
            end
            current = parent_id

        elseif combinator == "descendant" then
            -- Some ancestor must match
            local ancestor = ns.parent[current]
            if not ancestor then return false end
            local found = false
            while ancestor and ancestor ~= 0 do
                if match_compound(ns, ancestor, prev_segment.selectors) then
                    current = ancestor
                    found = true
                    break
                end
                ancestor = ns.parent[ancestor]
            end
            if not found then return false end

        elseif combinator == "adjacent" then
            -- Immediately preceding sibling must match
            local prev = prev_sibling(ns, current)
            if prev == 0 then return false end
            if not match_compound(ns, prev, prev_segment.selectors) then
                return false
            end
            current = prev

        elseif combinator == "sibling" then
            -- Some preceding sibling must match
            local parent_id = ns.parent[current]
            if not parent_id or parent_id == 0 then return false end
            local cid = ns.first_child[parent_id]
            if not cid or cid == 0 then return false end
            local found = false
            while cid ~= 0 and cid ~= current do
                if match_compound(ns, cid, prev_segment.selectors) then
                    current = cid
                    found = true
                    -- Don't break: keep going to find the closest match
                end
                cid = ns.next_sibling[cid] or 0
            end
            if not found then return false end

        else
            return false
        end

        seg_idx = seg_idx - 1
    end

    return true
end

return SelectorMatcher



