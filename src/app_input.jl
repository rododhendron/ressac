# src/app_input.jl
# Entrée : TK.update! clavier et souris, routage vers la barre de
# commande, le mode pane, les modaux, la pane focalisée, puis le flux
# legacy de la pane patterns. Drains des requêtes postées par les panes.

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
    # (the explorer rates candidates on scroll); fall back to the legacy
    # wheel handler (log / editor scroll) when no pane consumes it.
    if evt.button === TK.mouse_scroll_up || evt.button === TK.mouse_scroll_down
        _rack_wheel!(m, evt) || _workspace_scroll_to_pane!(m, evt) || _mouse_wheel!(m, evt)
        return
    end
    # Glisser / relâcher : la pane focalisée (sa barre de défilement, sa
    # table) — sans changer le focus.
    if evt.action === TK.mouse_drag || evt.action === TK.mouse_release
        pane = _focused_pane_impl(m)
        pane === nothing || handle_mouse!(pane, evt)
        return
    end
    # Left-click routing.
    if evt.action === TK.mouse_press && evt.button === TK.mouse_left
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
    _route_key_to_focused_pane!(m, evt) -> :editor | :consumed | :pass

Forward a KeyEvent to the focused workspace pane's PaneImpl
`handle_key!` when the focused pane is NOT the legacy patterns
editor. Returns `true` if the event was consumed by a non-patterns
pane (the caller must early-return); returns `false` for the
patterns pane so the legacy update! body keeps handling cursor
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
    # Seams app-level (no-op si rien posté) : un export/onde/sculpt peut
    # être posté par l'explorer OU par un WaveformPane → on draine toujours.
    _drain_explorer_export!(m)
    _drain_explorer_waveform!(m)
    _drain_explorer_sculpt!(m)
    _drain_sculpt_use!(m)
    _drain_drone_request!(m)
    _drain_synthdoc_request!(m)
    # Non consommée par la pane → le scope :global a sa chance (aide,
    # hush, scope…) dans update!.
    return consumed ? :consumed : :pass
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
    _switch_workspace_named!(m, "DESIGN")
    pane = _place_pane!(m, :editor,
                        Dict{String,Any}("buffer_role" => "synth", "name" => name))
    if pane isa EditorPane && 1 <= pane.current_tab <= length(pane.tabs)
        eb = pane.tabs[pane.current_tab]
        eb.synth_mode = :dsl
        TK.set_text!(eb.code_editor, dsl)
        eb.code_editor.mode = :normal
    end
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
while editors / logs fall through to the legacy `_mouse_wheel!`.
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

"""
    _click_tab_bar!(m, x)

A click in the tab strip switches to the tab nearest the click
column. The TabBar lays tabs out left-to-right with single-space
padding, so we approximate by dividing the x offset by the average
tab width.
"""
function _click_tab_bar!(m::RessacApp, x::Int)
    # Synth tab strip was rendered inside the legacy view layout that
    # sub-projet 10 removed. The strip will come back when the synth
    # side panel is folded into the workspace tree as a pane kind;
    # until then, this handler is a no-op so the mouse handler
    # doesn't crash if a stale code path still calls it.
    return
end

# ═══════════════════════════════════════════════════════════════════════
# Le pipeline clavier — une suite d'ÉTAPES ordonnées. Chaque étape reçoit
# l'événement (déjà normalisé) et répond `true` si elle l'a consommé :
# le pipeline s'arrête là. L'ordre EST la règle de priorité, lisible d'un
# coup d'œil dans `_KEY_STAGES` ; chaque étape garde son commentaire.
# ═══════════════════════════════════════════════════════════════════════

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    # Pavé numérique → chiffres et opérateurs, AVANT tout routage : les
    # panes (saisie de valeur du sculpt…) recevaient des `:kp_1` bruts
    # que personne ne lisait, seul le flux éditeur normalisait.
    evt = _normalise_event(evt)
    if m.keydebug
        _push_app_log!(m, "[KEY] $(evt.key) char=$(repr(evt.char)) action=$(evt.action)")
    end
    # Dernier filet : une touche dont l'action lève se lit dans le log,
    # l'application ne tombe pas.
    try
        for stage in _KEY_STAGES
            stage(m, evt) && return
        end
    catch err
        _push_app_log!(m, "[ERROR] touche $(keyname(evt)) — $(first(sprint(showerror, err), 160))")
    end
    return
end

# ── 1. Barre de commande : priorité absolue quand elle est active ────
# Tant que la barre `:` / `/` est ouverte, TOUTE touche lui revient : ni
# les globaux du workspace, ni le mode pane, ni les panes ne la voient.
# Découplée de l'éditeur : marche quelle que soit la pane focalisée.
function _stage_command_line!(m::RessacApp, evt::TK.KeyEvent)
    is_active(m.command_line) || return false
    outcome = handle_key!(m.command_line, evt;
                          complete_fn = q -> _command_completion_candidates(m, q))
    if outcome === :dispatched
        cmd = m.command_line.last_dispatched
        if !isempty(cmd)
            if m.command_line.last_dispatched_mode === :search
                _ex_search!(m, cmd)
            else
                _handle_ex_command!(m, cmd)
            end
        end
    end
    return true
end

# ── 2. Panic : coupe-son GLOBAL ──────────────────────────────────────
# `!` tue le son (patterns + tous les nœuds SC) depuis N'IMPORTE QUELLE
# pane ou modale. Seules exceptions : la SAISIE DE TEXTE — éditeur en
# insertion (où `!` est un caractère) — et l'attente d'un caractère
# littéral (`r!` remplace, `f!` saute au prochain `!`).
function _stage_panic!(m::RessacApp, evt::TK.KeyEvent)
    (evt.action === TK.key_press && evt.char == '!') || return false
    ed = _active_editor(m)
    (ed === nothing || ed.mode === :normal) && !_awaiting_literal(m) || return false
    _panic!(m)
    return true
end

# ── 3. Globaux du workspace et mode pane ─────────────────────────────
# Ils passent AVANT tout le reste pour que les raccourcis de live-coding
# ne soient pas avalés par un mode de l'éditeur.
function _stage_workspace!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return false
    if evt.key === :ctrl && evt.char in '1':'9'
        cmd_workspace_switch!(m.workspaces, Int(evt.char - '0'))
        return true
    end
    if evt.key === :ctrl && evt.char == 'F'
        m.floats_hidden = !m.floats_hidden
        return true
    end
    # Mode pane, persistant. Sorties : Échap, Entrée, Ctrl-W. Les
    # opérations reconnues (s/v/h/j/k/l/c, flèches, z) le laissent actif
    # pour enchaîner sans un Ctrl-W entre chaque ; le reste est avalé.
    if _PANE_MODE.active
        if evt.key === :escape || evt.key === :enter || (evt.key === :ctrl && evt.char == 'w')
            _PANE_MODE.active = false
        elseif evt.key === :left
            cmd_focus!(m.workspaces, :left)
        elseif evt.key === :down
            cmd_focus!(m.workspaces, :down)
        elseif evt.key === :up
            cmd_focus!(m.workspaces, :up)
        elseif evt.key === :right
            cmd_focus!(m.workspaces, :right)
        elseif evt.key === :char && evt.char == 'z'
            _toggle_zoom!(m)                          # z : zoom / dézoom du leaf focalisé
        elseif evt.key === :char
            _dispatch_pane_mode_key(m.workspaces, evt.char)
        end
        return true
    end
    # Sans éditeur, on se comporte comme en mode normal : le mode pane et
    # la commande `:` restent joignables (il faut pouvoir `:vsplit editor`
    # pour rouvrir une pane de patterns quand il n'y en a plus).
    ed = _active_editor(m)
    in_normal = ed === nothing || ed.mode === :normal
    # Entrée en mode pane — depuis le mode normal seulement, pour que
    # Ctrl-W en insertion efface toujours un mot.
    if in_normal && evt.key === :ctrl && evt.char == 'w'
        _PANE_MODE.active = true
        return true
    end
    # Barre de commande : `:` ouvre la commande, `/` la recherche — en mode
    # normal seulement (en insertion `:` est un caractère), hors attente
    # d'un caractère littéral, et `/` seulement si la modale ouverte n'a
    # pas sa propre recherche (le navigateur de sons). Remplace l'entrée
    # :command/:search du CodeEditor, qu'on ne veut jamais déclencher.
    if in_normal && evt.key === :char && !_awaiting_literal(m)
        if evt.char == ':'
            enter!(m.command_line, :command)
            return true
        elseif evt.char == '/' && !_modal_owns_key(m, "/")
            enter!(m.command_line, :search)
            return true
        end
    end
    return false
end

# ── 4. Modale ouverte : elle possède toutes les touches ──────────────
# Avant le routage vers la pane focalisée, pour qu'une modale ouverte
# par une touche de pane (sculpt via `M` de l'explorer) reçoive bien la
# saisie au lieu que la pane encore focalisée l'avale. Les répétitions
# de touche ne passent que pour la navigation.
function _stage_modal!(m::RessacApp, evt::TK.KeyEvent)
    m.modal === :none && return false
    is_nav = evt.char in ('j', 'k', 'd', 'u', 'h', 'l', 'n', 'p', '<', '>') ||
             evt.key in (:up, :down, :left, :right, :pageup, :pagedown)
    if evt.action === TK.key_press || (evt.action === TK.key_repeat && is_nav)
        _handle_modal_key!(m, evt)
    end
    return true
end

# ── 5. Pane focalisée ────────────────────────────────────────────────
# Une pane qui n'est pas l'éditeur actif (journal, doc, scope, sculpt…)
# reçoit la touche par son `handle_key!`. Si elle ne la consomme pas, ou
# s'il n'y a aucun éditeur ouvert, seul le scope :global s'applique
# (aide, hush, scope…). Sinon la touche continue vers l'éditeur, qu'on
# remet focalisé : `_render_tree_inner!` baisse ce drapeau dès que le
# focus est ailleurs, et `TK.handle_key!` l'ignore alors en silence.
function _stage_focused_pane!(m::RessacApp, evt::TK.KeyEvent)
    r = _route_key_to_focused_pane!(m, evt)
    r === :consumed && return true
    if r === :pass || _active_editor(m) === nothing
        dispatch!(((:global, m),), evt)
        return true
    end
    _active_editor(m).focused = true
    return false
end

# ── 6. Piano : les lettres jouent le synth courant ───────────────────
# `[` / `]` changent d'octave, Entrée valide l'enregistrement s'il y en
# a un, Échap sort. Tout le reste est avalé.
function _stage_piano!(m::RessacApp, evt::TK.KeyEvent)
    (m.piano_active && evt.action === TK.key_press) || return false
    if evt.key === :escape
        _piano_stop!(m)
    elseif evt.key === :enter
        m.piano_rec ? _piano_commit!(m) : _piano_stop!(m)
    elseif evt.char == '['
        m.piano_octave = max(0, m.piano_octave - 1)
        _push_app_log!(m, "[INFO] piano octave $(m.piano_octave)")
    elseif evt.char == ']'
        m.piano_octave = min(9, m.piano_octave + 1)
        _push_app_log!(m, "[INFO] piano octave $(m.piano_octave)")
    elseif haskey(_PIANO_KEYMAP, evt.char)
        _piano_play!(m, _PIANO_KEYMAP[evt.char])
    end
    return true
end

# ── 7. Tap : Espace marque un coup, Entrée valide, Échap annule ──────
# Tout le reste est avalé, pour tenir le tempo sans éditer par accident.
function _stage_tap!(m::RessacApp, evt::TK.KeyEvent)
    (m.tap_recording && evt.action === TK.key_press) || return false
    if evt.key === :enter
        _tap_commit!(m)
    elseif evt.key === :escape
        m.tap_recording = false
        empty!(m.tap_events)
        _push_app_log!(m, "[INFO] tap annulé")
    elseif evt.char == ' '
        _tap_hit!(m)
    end
    return true
end

# ── 8. Pause : une touche reprend, et elle est avalée ────────────────
# (pour qu'elle ne s'insère pas aussi comme caractère).
function _stage_paused!(m::RessacApp, evt::TK.KeyEvent)
    m.paused || return false
    if evt.action === TK.key_press
        m.paused = false
        _push_app_log!(m, "[INFO] reprise")
    end
    return true
end

# ── 9. Sélection visuelle : ses propres touches (étendre, d/y/c, m, e, Échap)
function _stage_visual!(m::RessacApp, evt::TK.KeyEvent)
    (m.visual_active && evt.action === TK.key_press) || return false
    return _visual_handle!(m, _active_editor(m), evt)
end

# ── 10. Mémoire de `.` : la session d'insertion est enregistrée ──────
# Un effet de bord, jamais une consommation.
function _stage_vim_record!(m::RessacApp, evt::TK.KeyEvent)
    _vim_record_keystroke!(m, _active_editor(m), evt, evt.action === TK.key_press)
    return false
end

# ── 11. Mode normal : registre de bindings et accords ────────────────
# Toutes les ACTIONS passent par le registre (app_keymap.jl), en mode
# normal seulement : jamais une touche tapée en insertion ne déclenche
# une action. Couches : pane focalisée (:patterns | :synth) → :editor →
# :global. Un binding qui ne matche pas laisse la touche au moteur vim.
function _stage_editor_normal!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    ed.mode === :normal || return false
    is_press = evt.action === TK.key_press
    # Trous d'un snippet : Tab / Maj-Tab sautent, Échap sort.
    if m.placeholder_active && is_press
        evt.key === :tab     && (_placeholder_jump!(m, ed, +1); return true)
        evt.key === :backtab && (_placeholder_jump!(m, ed, -1); return true)
        evt.key === :escape  && (m.placeholder_active = false; return true)
    end
    if m.pending_leader
        # Espace déjà pressé : la touche suivante choisit dans :leader.
        is_press || return true
        if evt.key === :escape
            m.pending_leader = false; return true
        end
        # Modificateur seul (Maj avant un E majuscule…) : on attend.
        (evt.key !== :char || evt.char == '\0') && return true
        m.pending_leader = false
        dispatch!(((:leader, m),), evt; prefix = "Space")
        return true
    end
    # `f` / `t` en attente : le caractère suivant est la cible.
    if m.pending_find !== nothing && is_press
        motion = m.pending_find
        m.pending_find = nothing
        if evt.key === :char && evt.char != '\0'
            _find_char!(m, ed, motion, evt.char)
        end
        return true
    end
    # `r`, `f`, `t`… attendent un caractère LITTÉRAL : le registre ne
    # doit pas l'intercepter, sinon `r!` déclenche le panic et `r `
    # ouvre le menu Espace au lieu de remplacer le caractère.
    if !(is_press && _awaiting_literal(m))
        # `g` en attente (posé par l'éditeur) → accords « g t », « g T »…
        prefix = ed.pending_key == 'g' ? "g" : ""
        if dispatch!(_editor_layers(m), evt; prefix = prefix)
            isempty(prefix) || (ed.pending_key = nothing)
            return true
        end
    end
    # Opérateur + mouvement (cw / dw / yw, variantes majuscules et e) :
    # Tachikoma ne connaît que les formes doublées (cc/dd/yy), celles-ci
    # sont à nous. Chacune garde `scroll_offset` pour que la vue ne saute
    # pas quand le texte change.
    if is_press && ed.pending_key in ('c', 'd', 'y') && evt.char in ('w', 'b', 'W', 'B', 'e', 'E')
        op = ed.pending_key
        ed.pending_key = nothing
        _op_with_motion!(m, ed, op, evt.char)
        return true
    end
    # Mouvements par mot — les nôtres plutôt que ceux de Tachikoma, pour
    # qu'ils avancent TOUJOURS et passent les lignes sans buter sur la
    # ponctuation. W / B sont les « gros mots » de vim (seule l'espace
    # sépare : foo.bar = un saut). Pas quand un opérateur attend (géré
    # juste au-dessus), pour ne pas tirer sous cw/dw/yw.
    if is_press && evt.char in ('w', 'b', 'W', 'B') && ed.pending_key === nothing
        kind = (evt.char == 'W' || evt.char == 'B') ? :big : :small
        dir  = (evt.char == 'w' || evt.char == 'W') ? +1 : -1
        _word_motion!(ed, dir, kind)
        return true
    end
    return false
end

# ── 12. Mode insertion : Tab complète, le reste s'écrit ──────────────
# Tab : accepter la suggestion fantôme si elle est visible, sinon le
# cycle de complétion de mot ; si rien ne s'applique, Tab continue vers
# l'éditeur. Toute autre touche remet le cycle à zéro, s'écrit, puis
# recalcule le fantôme. Les trous d'un snippet passent avant : Tab /
# Maj-Tab sautent de $1 en $2.
function _stage_editor_insert!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    (evt.action === TK.key_press && ed.mode === :insert) || return false
    if m.placeholder_active && evt.key === :tab
        _placeholder_jump!(m, ed, +1); return true
    end
    if m.placeholder_active && evt.key === :backtab
        _placeholder_jump!(m, ed, -1); return true
    end
    if evt.key === :tab
        if !isempty(m.ghost) && _accept_ghost!(m)
            _compute_ghost!(m)
            return true
        end
        if _try_autocomplete!(m, ed)
            m.ghost = ""
            return true
        end
        return false                                # Tab sans complétion : à l'éditeur
    end
    _reset_completion!(m)
    # Longueur de la ligne avant l'édition, pour que le suivi des trous
    # décale les $N restants du bon delta.
    pre_len = (m.placeholder_active && 1 <= ed.cursor_row <= length(ed.lines)) ?
              length(ed.lines[ed.cursor_row]) : 0
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    m.placeholder_active && _placeholder_track_change!(m, ed, pre_len)
    _compute_ghost!(m)
    return true
end

# ── 13. Mode commande du CodeEditor (`:synth wob…`) ──────────────────
# Tab complète le verbe ou l'argument ; les flèches parcourent la grille
# de complétion quand elle est ouverte, sinon ↑/↓ font l'historique
# comme un shell. Toute autre touche ferme le cycle de complétion (pour
# que la fermeture capturée ne pointe pas sur des jetons périmés) — et
# éditer sort du mode historique.
function _stage_editor_command!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    (evt.action === TK.key_press && ed.mode === :command) || return false
    if evt.key === :tab
        _try_ex_autocomplete!(m, ed) && return true
        return false
    end
    if _completion_picker_active(m)
        dir = evt.key === :up ? :up : evt.key === :down ? :down :
              evt.key === :left ? :left : evt.key === :right ? :right : nothing
        dir !== nothing && _move_completion_session!(m, dir) && return true
    elseif evt.key === :up || evt.key === :down
        _ex_history_nav!(m, ed, evt.key)
        return true
    end
    if !(evt.key in (:up, :down, :left, :right))
        _reset_completion!(m)
        evt.key === :char && (m.ex_history_idx = 0)
    end
    return false
end

# ── 14. L'éditeur lui-même : moteur vim de Tachikoma, puis `.` ───────
function _stage_editor!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    is_press = evt.action === TK.key_press
    pre_text = ed.mode === :normal ? TK.text(ed) : ""     # pour l'enregistrement de `.`
    pre_mode = ed.mode
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    if is_press && pre_mode === :normal
        _vim_post_normal!(m, ed, evt, pre_text)
    end
    return true
end

# L'ordre des étapes est la règle de priorité. À partir de la 6e, un
# éditeur actif existe forcément (la 5e a tout renvoyé sinon).
const _KEY_STAGES = (
    _stage_hover!,
    _stage_command_line!,
    _stage_panic!,
    _stage_workspace!,
    _stage_modal!,
    _stage_focused_pane!,
    _stage_piano!,
    _stage_tap!,
    _stage_paused!,
    _stage_visual!,
    _stage_vim_record!,
    _stage_editor_normal!,
    _stage_editor_insert!,
    _stage_editor_command!,
    _stage_editor!,
)

_is_typable_ascii(c::Char) = ncodeunits(c) == 1 && (isprint(c) && c != '\0')

# ---------------------------------------------------------------------
# Live doc row
# ---------------------------------------------------------------------
