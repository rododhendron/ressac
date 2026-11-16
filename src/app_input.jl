# src/app_input.jl
# Entrée souris : TK.update!(m, ::MouseEvent), le routage d'une touche
# vers la pane focalisée, les drains des requêtes postées par les panes.
# Le clavier : app_layers.jl (la pile) et app_key_engines.jl (les moteurs).

"""
    TK.update!(m::RessacApp, evt::TK.MouseEvent)

Full mouse routing. Each pane records its rect during render so we
can map (x, y) → which widget under the pointer. Behaviours:

  • Wheel over a number (in any editor pane)     → nudge ±1
    + Shift                                       → nudge ±10
  • Wheel over the log pane (and no number)      → scroll log
  • Wheel over the scope panel                   → cycle scope
  • Left-click in patterns pane                  → focus + move cursor
  • Left-click in synth pane                     → focus + move cursor
  • Left-click on tab bar                        → switch synth tab
  • Left-click in modal row                      → highlight that row
  • Middle-click in modal row                    → highlight + activate (Enter)
"""
function TK.update!(m::RessacApp, evt::TK.MouseEvent)
    # Même filet que le clavier : un geste de souris qui lève se lit dans
    # le journal, la session continue.
    try
        _mouse_update!(m, evt)
    catch err
        _push_app_log!(m, "[ERROR] souris — $(first(sprint(showerror, err), 160))")
    end
    return
end

function _mouse_update!(m::RessacApp, evt::TK.MouseEvent)
    # La bulle de glossaire suit la souris (déplacements, clic dedans).
    m.modal === :none && _hover_mouse!(m, evt) && return
    evt.action === TK.mouse_move && return
    # Boutons du chrome (barre de touches, status line) — même sous un
    # modal, dont la barre montre les raccourcis.
    if evt.action === TK.mouse_press && evt.button === TK.mouse_left
        _chrome_click!(m, evt.x, evt.y) && return
    end
    # Une modale ouverte prend la souris (clic, molette) avant tout le reste.
    m.modal !== :none && _modal_mouse!(m, evt) && return
    # Wheel — context-aware. Give the pane under the cursor first dibs
    # (the explorer rates candidates on scroll); fall back to the general
    # wheel handler (log / editor scroll) when no pane consumes it.
    if evt.button === TK.mouse_scroll_up || evt.button === TK.mouse_scroll_down
        _rack_wheel!(m, evt) || _workspace_scroll_to_pane!(m, evt) || _mouse_wheel!(m, evt)
        return
    end
    # Une bordure en cours de glissement prend tout jusqu'au relâchement.
    m.resize_drag !== nothing && _resize_drag!(m, evt) && return
    # Glisser / relâcher : la pane focalisée (sa barre de défilement, sa
    # table) — sans changer le focus.
    if evt.action === TK.mouse_drag || evt.action === TK.mouse_release
        pane = _focused_pane_impl(m)
        pane === nothing || handle_mouse!(pane, evt)
        return
    end
    # Left-click routing.
    if evt.action === TK.mouse_press && evt.button === TK.mouse_left
        # Une bordure entre deux panes : on la saisit pour la glisser.
        _resize_press!(m, evt) && return
        # Focused editor — fast path (still the most common click).
        # Drives off _focused_editor_rect(m), refilled by _render_tree!
        # for whatever editor pane currently has focus.
        if _focused_editor_rect(m) !== nothing && _in_rect(_focused_editor_rect(m), evt.x, evt.y)
            _click_into_editor!(_active_editor(m), _focused_editor_rect(m), evt.x, evt.y)
            return
        end
        # Workspace tree hit-test — focuses the clicked leaf and
        # delegates to its PaneImpl.handle_mouse!. Floats first
        # (top of z stack wins), then tile leaves.
        if _workspace_mouse_dispatch!(m, evt); return; end
    end
end

# Touches de l'éditeur qui consomment le caractère suivant tel quel :
# `r` remplace, `f`/`F`/`t`/`T` cherchent un caractère sur la ligne.
const _LITERAL_PENDING = ('r',)

# L'éditeur (ou Ressac, pour f/t) attend un caractère littéral : aucune
# action globale ne doit l'intercepter.
_awaiting_literal(m::RessacApp) =
    m.pending_find !== nothing ||
    ((ed = _active_editor(m)) !== nothing && ed.mode === :normal &&
     ed.pending_key in _LITERAL_PENDING)

"""
    _modal_owns_key(m, chord) -> Bool

Vrai si le modal ouvert déclare ce raccourci : l'app lui laisse alors la
touche, même quand elle en a un autre usage (le navigateur de sons a sa
propre recherche sur `/`).
"""
_modal_owns_key(m::RessacApp, chord::AbstractString) =
    m.modal !== :none && lookup(modal_scope(m), chord; target = m) !== nothing

"""
    _text_entry_active(m) -> Bool

Vrai quand la frappe va dans une saisie de modale (la recherche de la
palette, le `/` d'une liste, la recherche du navigateur de sons). Tant que
c'est le cas, aucune touche globale ne passe devant : `!` est un caractère,
pas un PANIC ; `:` et Ctrl-w aussi.
"""
function _text_entry_active(m::RessacApp)
    m.modal === :none && return false
    m.modal === :browse && return m.browser_search.focused
    pk = _modal_picker(m)
    return pk !== nothing && pk.searching
end

"""
    _route_key_to_focused_pane!(m, evt) -> :editor | :consumed | :pass

Forward a KeyEvent to the focused workspace pane's PaneImpl
`handle_key!` when the focused pane is NOT the active
editor. Returns `true` if the event was consumed by a non-patterns
pane (the caller must early-return); returns `false` for the
editor pane so the editor engines keep handling cursor
moves, autocomplete, etc.
"""
function _route_key_to_focused_pane!(m::RessacApp, evt::TK.KeyEvent)
    ws = current_workspace(m.workspaces)
    ws === nothing && return :editor
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    (leaf === nothing || isempty(leaf.tabs)) && return :editor
    1 <= leaf.current_tab <= length(leaf.tabs) || return :editor
    pane = leaf.tabs[leaf.current_tab]
    ed = _active_editor(m)        # `nothing` when no editor pane is open
    # While the editor is in ex command mode, ALL keys belong to it —
    # otherwise typed chars after ':' would land in the focused side
    # pane instead of the ex command buffer. Same for :search.
    if ed !== nothing && (ed.mode === :command || ed.mode === :search)
        return :editor
    end
    # Global shortcuts that always belong to the editor regardless of
    # which workspace pane has focus. ':' opens ex command mode;
    # without this fall-through, ex commands wouldn't be reachable
    # from a focused log / doc / scope side pane.
    if evt.key === :char && evt.char == ':' &&
       ed !== nothing && ed.mode === :normal
        return :editor
    end
    # Pane éditeur focalisée (patterns OU synth) : son CodeEditor est
    # `_active_editor(m)` → c'est le flux éditeur de update! qui la sert
    # (registre :patterns/:synth/:editor/:global, puis moteur vim).
    if pane isa EditorPane &&
       1 <= pane.current_tab <= length(pane.tabs) &&
       pane.tabs[pane.current_tab].code_editor === ed
        return :editor
    end
    # TK.CodeEditor.handle_key! short-circuits to `false` when
    # `.focused` is false — its keymap is gated on focus. Make sure
    # the target editor sees itself as focused before delegating; the
    # next view() refresh keeps it in sync.
    if pane isa EditorPane &&
       1 <= pane.current_tab <= length(pane.tabs)
        pane.tabs[pane.current_tab].code_editor.focused = true
    end
    consumed = handle_key!(pane, evt) === true
    # Ex-command bridge: when an EditorPane finishes a `:foo` command
    # via its own TK.CodeEditor command mode, drain it and dispatch
    # through Ressac's ex command pipeline. Without this, `:q` typed
    # in a focused side pane would never quit the app.
    if pane isa EditorPane &&
       1 <= pane.current_tab <= length(pane.tabs)
        cmd = TK.pending_command!(pane.tabs[pane.current_tab].code_editor)
        isempty(cmd) || _handle_ex_command!(m, cmd)
    end
    return consumed ? :consumed : :pass
end

# Les requêtes qu'une pane ou un geste de mode postent à l'app (export,
# onde, sculpt, U depuis un studio seul, réévaluation d'un drone, onglet
# de la DOC) : drainées après CHAQUE touche résolue, quelle que soit la
# couche qui l'a consommée. No-op si rien n'est posté.
function _drain_requests!(m::RessacApp)
    _drain_explorer_export!(m)
    _drain_explorer_waveform!(m)
    _drain_explorer_sculpt!(m)
    _drain_sculpt_use!(m)
    _drain_synthdoc_request!(m)
    return
end

"""
    _drain_explorer_export!(m) -> Bool

If a SynthExplorerPane posted an export request (via `e`), open an
editor tab holding the rendered DSL. The pane has no WorkspaceManager
handle, so it routes the request through `_EXPLORER_EXPORT_REQUEST`.
"""
function _drain_explorer_export!(m::RessacApp)
    req = _EXPLORER_EXPORT_REQUEST[]
    req === nothing && return false
    _EXPLORER_EXPORT_REQUEST[] = nothing
    name, dsl = req
    # Le candidat s'édite dans DESIGN (l'explorer reste dans EXPLORE).
    _open_synth_text_in_design!(m, name, dsl)
    return true
end

"""
    _drain_explorer_waveform!(m) -> Bool

If a SynthExplorerPane posted a waveform request (via `V`), open a
:waveform pane rendering the focused candidate's NRT audio. Same seam
pattern as the export drain (the pane has no WorkspaceManager handle).
"""
function _drain_explorer_waveform!(m::RessacApp)
    req = _EXPLORER_WAVEFORM_REQUEST[]
    req === nothing && return false
    _EXPLORER_WAVEFORM_REQUEST[] = nothing
    gser, label = req
    cmd_split!(m.workspaces, "waveform",
               Dict{String,Any}("genome" => gser, "label" => label))
    return true
end

# Sculpt (ouverture d'une pane sculpt, drain explorer `M`, :sculpt/:w)
# → src/app_sculpt.jl.

"""
    _workspace_scroll_to_pane!(m, evt) -> Bool

Route a scroll event to the tile pane under the cursor, returning true
only if that pane's `handle_mouse!` consumed it. Lets panes that care
about the wheel (the synth explorer rates candidates) intercept it
while editors / logs fall through to the general `_mouse_wheel!`.
"""
function _workspace_scroll_to_pane!(m::RessacApp, evt::TK.MouseEvent)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    m._last_ws_area === nothing && return false
    rects = _workspace_rects(m, ws, m._last_ws_area)
    for (leaf_id, r) in rects
        if _in_rect_xywh(r.x, r.y, r.w, r.h, evt.x, evt.y)
            leaf = _find_leaf_by_id(ws.tree, leaf_id)
            (leaf isa PaneLeaf && !isempty(leaf.tabs) &&
             1 <= leaf.current_tab <= length(leaf.tabs)) || return false
            return handle_mouse!(leaf.tabs[leaf.current_tab], evt) === true
        end
    end
    return false
end

"""
    _workspace_mouse_dispatch!(m, evt) -> Bool

Hit-test floats (top z wins) then tile leaves via `_compute_rects`.
On hit, sets `ws.focused_pane` and calls `handle_mouse!` on the
clicked pane. Returns true when a pane consumed the event.
"""
function _workspace_mouse_dispatch!(m::RessacApp, evt::TK.MouseEvent)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    if !m.floats_hidden
        for f in sort(ws.floats; by = x -> -x.z_order)
            if _in_rect_xywh(f.x, f.y, f.w, f.h, evt.x, evt.y)
                handle_mouse!(f.pane, evt)
                return true
            end
        end
    end
    m._last_ws_area === nothing && return false
    rects = _workspace_rects(m, ws, m._last_ws_area)
    for (leaf_id, r) in rects
        if _in_rect_xywh(r.x, r.y, r.w, r.h, evt.x, evt.y)
            ws.focused_pane = leaf_id
            # Boutons du cadre (⊞ ⊟ ⤢ ✕) avant la pane elle-même.
            act = _pane_button_at(TK.Rect(r.x, r.y, r.w, r.h), evt.x, evt.y)
            if act !== nothing
                _pane_button_action!(m, act)
                return true
            end
            leaf = _find_leaf_by_id(ws.tree, leaf_id)
            if leaf isa PaneLeaf && !isempty(leaf.tabs) &&
               1 <= leaf.current_tab <= length(leaf.tabs)
                handle_mouse!(leaf.tabs[leaf.current_tab], evt)
            end
            return true
        end
    end
    return false
end

# Boutons du cadre d'une pane (elle est déjà focalisée).
function _pane_button_action!(m::RessacApp, act::Symbol)
    if act === :vsplit
        cmd_vsplit!(m.workspaces, "editor", Dict{String,Any}())
    elseif act === :hsplit
        cmd_hsplit!(m.workspaces, "editor", Dict{String,Any}())
    elseif act === :zoom
        _toggle_zoom!(m)
    elseif act === :close
        cmd_close!(m.workspaces)
    end
    return
end

# Clic sur la barre de touches / la status line : exécute le bouton
# sous le curseur. Les zones sont remplies par le rendu.
function _chrome_click!(m::RessacApp, x::Int, y::Int)
    _rack_click!(m, y) && return true
    hits = y == m._keybar_y ? m._keybar_hits :
           y == m._status_y ? m._status_hits : nothing
    hits === nothing && return false
    for (x0, x1, f) in hits
        if x0 <= x <= x1
            f()
            return true
        end
    end
    return y == m._keybar_y || y == m._status_y   # le bandeau avale le clic
end

_in_rect_xywh(x::Int, y::Int, w::Int, h::Int, px::Int, py::Int) =
    px >= x && px < x + w && py >= y && py < y + h

function _find_leaf_by_id(node::LayoutNode, leaf_id::Int)
    if node isa PaneLeaf
        return node.id == leaf_id ? node : nothing
    end
    for child in node.children
        hit = _find_leaf_by_id(child, leaf_id)
        hit === nothing || return hit
    end
    return nothing
end

_in_rect(r::TK.Rect, x::Int, y::Int) =
    x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height

"""
    _mouse_wheel!(m, evt)

Wheel dispatch. Priority: hover-nudge a number in whichever editor
the pointer is over (cursor doesn't have to be on the number — the
mouse position resolves it). Falls back to log scroll for wheels
over the log pane, scope cycle for wheels over the scope panel.
"""
function _mouse_wheel!(m::RessacApp, evt::TK.MouseEvent)
    sign = evt.button === TK.mouse_scroll_up ? 1 : -1
    mag  = evt.shift ? 10 : 1
    # 1. Hover wheel-nudge in the focused editor.
    rect = _focused_editor_rect(m)
    ed = _active_editor(m)
    if rect !== nothing && _in_rect(rect, evt.x, evt.y)
        rc = _screen_to_editor_pos(ed, rect, evt.x, evt.y)
        rc === nothing && return
        row, col = rc
        _try_nudge_at!(m, ed, row, col, sign * mag)
        return  # over editor — don't fall through even if no number
    end
    # 2. Wheel over the bottom log → the ScrollPane scrolls (it knows its area).
    TK.set_content!(m.log_view, _log_spans(m.logs))
    TK.handle_mouse!(m.log_view, evt) && return
end

"""
    _screen_to_editor_pos(ed, rect, x, y) -> Union{Tuple{Int,Int},Nothing}

Convert screen (x, y) into a 1-based (row, col-0-based) inside the
CodeEditor. Accounts for the editor's `top_line` scroll offset.
Returns nothing when (x, y) is outside the rect or past the
buffer's bounds.
"""
function _screen_to_editor_pos(ed::TK.CodeEditor, rect::TK.Rect, x::Int, y::Int)
    _in_rect(rect, x, y) || return nothing
    # CodeEditor render layout:
    #   `rect` is the full pane; if a block is set it draws a border
    #   1 row / 1 col deep on each side. Inside that, an optional
    #   gutter (line numbers + a `│` separator) takes the leftmost
    #   `gw` cols. The code area is what remains; vertical scroll is
    #   `scroll_offset` (0-based lines hidden above), horizontal is
    #   `h_scroll` (0-based cols hidden to the left).
    has_block = ed.block !== nothing
    inset_top = has_block ? 1 : 0
    inset_left = has_block ? 1 : 0
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    visual_row = y - (rect.y + inset_top)
    visual_col = x - (rect.x + inset_left + gw)
    (visual_row < 0 || visual_col < 0) && return nothing
    row = ed.scroll_offset + visual_row + 1
    1 <= row <= length(ed.lines) || return nothing
    col = clamp(ed.h_scroll + visual_col, 0, length(ed.lines[row]))
    return (row, col)
end

"""
    _click_into_editor!(ed, rect, x, y)

Move the editor's cursor to the screen position the user clicked.
Cheap wrapper around _screen_to_editor_pos.
"""
function _click_into_editor!(ed::TK.CodeEditor, rect::TK.Rect, x::Int, y::Int)
    rc = _screen_to_editor_pos(ed, rect, x, y)
    rc === nothing && return
    ed.cursor_row, ed.cursor_col = rc
end
