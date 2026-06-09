------------------------------------------------------------
-- ext_core_astro_ui_lib / core / components / dialog.lua
-- <dialog> modal/non-modal widget.
--
-- HTML behavior:
--   <dialog>...</dialog>            hidden by default
--   <dialog open>...</dialog>       visible, non-modal
--   <dialog open modal>...</dialog> visible, modal with backdrop (engine-specific
--                                   extension -" HTML uses showModal() JS API)
--
-- Runtime:
--   * Flips computed.display between "none" and "block" based on the `open`
--     attribute (mirrors <details>).
--   * When `modal` is also set, positions as a fullscreen-centered element
--     and paints a dimming backdrop behind it.
--   * ESC closes an open dialog.
--   * Click outside (on backdrop) closes modal dialogs.
--
-- Lua 5.1 safe: no goto, no bitwise ops.
------------------------------------------------------------
local Dialog = {}

--- Update dialog open/closed state.
---@param ns           table   NodeStore
---@param nid          number  node id
---@param input_state  table   InputState
---@param event_system table   EventSystem
---@param input_active boolean if false, skip outside-click + ESC handling
---                            (used during window resize so a resize drag
---                            release isn't interpreted as an outside-click
---                            that closes the dialog). Display-state sync
---                            always runs so the dialog stays visible.
function Dialog.update(ns, nid, input_state, event_system, input_active)
    if input_active == nil then input_active = true end
    local lay  = ns.layout[nid]
    local comp = ns.computed and ns.computed[nid]
    if not comp then return end

    local attrs = ns.attrs[nid] or {}
    local is_open = attrs.open ~= nil
    local is_modal = attrs.modal ~= nil

    local pseudo = ns.pseudo[nid]
    if not pseudo then pseudo = {}; ns.pseudo[nid] = pseudo end
    pseudo._dialog_modal = is_modal

    -- Mirror attribute into computed display.  The UA default is
    -- `display: none`, and style resolve re-applies it every frame -" so we
    -- must always force `block` while open.  Track the _was_open flag
    -- (NOT display state) to detect the transition and arm the
    -- outside-click grace period.
    if is_open then
        comp.display = "block"
        if not pseudo._dialog_was_open then
            pseudo._dialog_was_open = true
            pseudo._dialog_just_opened = true
            ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
            return
        end
    else
        if pseudo._dialog_was_open then
            pseudo._dialog_was_open = false
            ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        end
        comp.display = "none"
        pseudo._dialog_just_opened = nil
        return
    end

    if not input_active then return end

    -- ESC closes the dialog (virtual-key 0x1B). Only handle if event system
    -- reports this dialog as current (best-effort: any open dialog closes).
    if input_state:is_key_edge(0x1B) then
        attrs.open = nil
        comp.display = "none"
        ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
        -- Fire onClose action if present
        if event_system and attrs.onClose then
            local h = event_system._action_handlers[attrs.onClose]
            if h then pcall(h, nid, attrs.onClose) end
        end
        return
    end

    -- For modal dialogs, a click outside the dialog's rect closes it.
    -- Skip on the first frame after opening (grace period: the same click
    -- that triggered the onclick that opened the dialog would otherwise
    -- immediately close it again).
    if pseudo._dialog_just_opened then
        pseudo._dialog_just_opened = nil
        return
    end
    if is_modal and lay and input_state:is_mouse_clicked() then
        local mx, my = input_state.cursor_x, input_state.cursor_y
        local inside = mx >= lay.x and mx < lay.x + lay.w
                    and my >= lay.y and my < lay.y + lay.h
        if not inside then
            attrs.open = nil
            comp.display = "none"
            ns:mark_dirty(nid, ns.LAYOUT_DIRTY + ns.PAINT_DIRTY)
            if event_system and attrs.onClose then
                local h = event_system._action_handlers[attrs.onClose]
                if h then pcall(h, nid, attrs.onClose) end
            end
        end
    end
end

--- Paint the backdrop for a modal dialog.
--- Called from engine before the main paint walk so it ends up beneath the dialog.
---@param ns       table
---@param nid      number
---@param dl       table
---@param platform table
---@param clip_rect table|nil  {x, y, w, h} -" draw the backdrop to cover this region
function Dialog.paint_backdrop(ns, nid, dl, platform, clip_rect)
    local pseudo = ns.pseudo[nid]
    if not pseudo or not pseudo._dialog_modal then return end

    local attrs = ns.attrs[nid]
    if not attrs or attrs.open == nil then return end

    local x, y, w, h
    if clip_rect then
        x, y, w, h = clip_rect[1], clip_rect[2], clip_rect[3], clip_rect[4]
    else
        x, y = 0, 0
        w, h = 4096, 4096  -- large fallback
    end

    -- Dim overlay
    dl:rect_fill(x, y, w, h, 0, 0, 0, 160, 0)
end

return Dialog



