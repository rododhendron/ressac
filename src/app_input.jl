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
    # Modal click routing has priority.
    if m.modal !== :none && evt.action === TK.mouse_press &&
       evt.button === TK.mouse_left
        _modal_click!(m, evt.x, evt.y); return
    end
    # Wheel — context-aware. Give the pane under the cursor first dibs
    # (the explorer rates candidates on scroll); fall back to the legacy
    # wheel handler (log / editor scroll) when no pane consumes it.
    if evt.button === TK.mouse_scroll_up || evt.button === TK.mouse_scroll_down
        _workspace_scroll_to_pane!(m, evt) || _mouse_wheel!(m, evt)
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
    # 2. Wheel over log pane → scroll log.
    if m._last_log_rect !== nothing && _in_rect(m._last_log_rect, evt.x, evt.y)
        m.log_scroll = max(0, m.log_scroll + sign)
        return
    end
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

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    if m.keydebug
        _push_app_log!(m, "[KEY] $(evt.key) char=$(repr(evt.char)) action=$(evt.action)")
    end
    # ── CommandLine ── absolute priority when active ─────────────────
    # While the command/search bar is active, EVERY key belongs to it.
    # Nothing else (workspace globals, pane mode, panes) sees the
    # event. Decoupled from any editor — works no matter which pane
    # is focused.
    if is_active(m.command_line)
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
        return
    end
    # ── Panic : coupe-son GLOBAL ─────────────────────────────────────
    # `!` tue le son (patterns + tous les nœuds SC) depuis N'IMPORTE QUEL
    # pane ou modal (lib de synths, scope, explorer…). Seules exceptions :
    # la SAISIE DE TEXTE — barre de commande active (gérée juste au-dessus)
    # et éditeur en insert/command/search (où `!` est un caractère).
    if evt.action === TK.key_press && evt.char == '!'
        ed_panic = _active_editor(m)
        if ed_panic === nothing || ed_panic.mode === :normal
            _panic!(m)
            return
        end
    end
    # ── Sub-project 10: workspace globals + pane mode ────────────────
    # These fire BEFORE any existing dispatch so live-coding shortcuts
    # don't get swallowed by editor modes.
    if evt.action === TK.key_press
        if evt.key === :ctrl && evt.char in '1':'9'
            cmd_workspace_switch!(m.workspaces, Int(evt.char - '0'))
            return
        end
        if evt.key === :ctrl && evt.char == 'F'
            m.floats_hidden = !m.floats_hidden
            return
        end
        # Pane mode dispatch — persistent. Exits: Esc, Enter, Ctrl-W.
        # Recognized ops (s/v/h/j/k/l/c) keep pane mode active so a
        # quick sequence doesn't need a Ctrl-W between each command.
        if _PANE_MODE.active
            if evt.key === :escape || evt.key === :enter ||
               (evt.key === :ctrl && evt.char == 'w')
                _PANE_MODE.active = false
                return
            elseif evt.key === :left
                cmd_focus!(m.workspaces, :left);  return
            elseif evt.key === :down
                cmd_focus!(m.workspaces, :down);  return
            elseif evt.key === :up
                cmd_focus!(m.workspaces, :up);    return
            elseif evt.key === :right
                cmd_focus!(m.workspaces, :right); return
            elseif evt.key === :char && evt.char == 'z'
                _toggle_zoom!(m); return             # z : zoom / dézoom du leaf focalisé
            elseif evt.key === :char
                _dispatch_pane_mode_key(m.workspaces, evt.char)
                return
            end
            return  # eat any other key while in pane mode
        end
        # No editor → treat as :normal so pane mode + ex command stay
        # reachable (the user must be able to `:vsplit editor` to reopen
        # a patterns pane when none is open).
        ed = _active_editor(m)
        in_normal = ed === nothing || ed.mode === :normal
        # Pane mode entry — only from editor normal mode so insert-mode
        # word-delete (Ctrl-W) keeps working.
        if in_normal && evt.key === :ctrl && evt.char == 'w'
            _PANE_MODE.active = true
            return
        end
        # CommandLine entry — ':' opens ex command, '/' opens search.
        # Only when the editor is in :normal (so ':' typed during insert
        # is a literal char). Replaces TK.CodeEditor's built-in
        # :command/:search mode entry, which we never want to trigger.
        if in_normal && evt.key === :char
            if evt.char == ':'
                enter!(m.command_line, :command)
                return
            elseif evt.char == '/'
                enter!(m.command_line, :search)
                return
            end
        end
    end
    # Modal overlay owns all keys BEFORE focus-pane routing, so a modal
    # opened by a pane keystroke (sculpt via explorer `M`) still gets input
    # instead of the still-focused pane swallowing it.
    if m.modal !== :none
        mevt = _normalise_event(evt)
        is_nav = mevt.char == 'j' || mevt.char == 'k' ||
                 mevt.key === :up || mevt.key === :down
        if mevt.action === TK.key_press ||
           (mevt.action === TK.key_repeat && is_nav)
            _handle_modal_key!(m, mevt)
        end
        return
    end
    # ── Sub-project 10: focus-driven key routing ──────────────────────
    # When the focused workspace pane is NOT the legacy patterns editor
    # (_active_editor(m)), its keystrokes must go to that pane's own TK.CodeEditor
    # via PaneImpl.handle_key!, not into the global _active_editor(m) flow that
    # follows below. The patterns pane still goes through the legacy
    # path because _active_editor(m) IS that pane's tabs[1].code_editor — letting
    # the legacy update! body run keeps cursor moves / autocomplete /
    # eval flash / playhead intact.
    r = _route_key_to_focused_pane!(m, evt)
    r === :consumed && return
    # Pane non-éditeur focalisée (touche non consommée) ou aucun éditeur
    # ouvert : seul le scope :global s'applique (aide, hush, scope…).
    if r === :pass || _active_editor(m) === nothing
        dispatch!(((:global, m),), evt)
        return
    end
    # Cause A fix: the legacy update! body below calls
    # `TK.handle_key!(_active_editor(m), evt)`, which short-circuits
    # when `.focused == false`. _render_tree_inner! clears that flag
    # whenever ws.focused_pane is on a different leaf (a side log /
    # doc / scope pane, a synth-role editor, etc.). Without forcing
    # it back to true here, any global keystroke (':', text, vim
    # motions on _active_editor(m)) routed past the workspace pane gets
    # silently dropped. Per-frame view() will re-sync from the tree.
    _active_editor(m).focused = true
    # Piano mode: letter keys → semitones → fire the current synth at
    # that pitch. Octave shift via `[` and `]`. Enter commits the
    # recording (if piano_rec is on), Esc exits.
    if m.piano_active && evt.action === TK.key_press
        if evt.key === :escape
            _piano_stop!(m); return
        elseif evt.key === :enter
            m.piano_rec ? _piano_commit!(m) : _piano_stop!(m); return
        elseif evt.char == '['
            m.piano_octave = max(0, m.piano_octave - 1)
            _push_app_log!(m, "[INFO] piano octave $(m.piano_octave)"); return
        elseif evt.char == ']'
            m.piano_octave = min(9, m.piano_octave + 1)
            _push_app_log!(m, "[INFO] piano octave $(m.piano_octave)"); return
        elseif haskey(_PIANO_KEYMAP, evt.char)
            _piano_play!(m, _PIANO_KEYMAP[evt.char])
            return
        end
        return  # swallow everything else
    end
    # Tap-record mode: capture Space as a hit, Enter to commit, Esc to
    # cancel. Every other key is swallowed so the user can hold the
    # tempo without accidentally editing the buffer.
    if m.tap_recording && evt.action === TK.key_press
        if evt.key === :enter
            _tap_commit!(m); return
        elseif evt.key === :escape
            m.tap_recording = false
            empty!(m.tap_events)
            _push_app_log!(m, "[INFO] tap cancelled"); return
        elseif evt.char == ' '
            _tap_hit!(m); return
        end
        return
    end
    # Paused: any key_press resumes and is then swallowed (so the
    # resume key doesn't double-act as e.g. an insert-mode character).
    if m.paused
        if evt.action === TK.key_press
            m.paused = false
            _push_app_log!(m, "[INFO] resumed")
        end
        return
    end
    evt = _normalise_event(evt)
    ed = _active_editor(m)
    is_press = evt.action === TK.key_press
    # Sélection visuelle : ses propres touches (étendre, d/y/c, m, e, Esc).
    if m.visual_active && is_press
        _visual_handle!(m, ed, evt) && return
    end
    # Track insert-session text so `.` has something to replay.
    _vim_record_keystroke!(m, ed, evt, is_press)
    # ── Registre de bindings (app_keymap.jl) ─────────────────────────
    # Toutes les ACTIONS passent par ici, en mode normal seulement : jamais
    # une touche tapée en insertion ne déclenche une action. Couches :
    # pane focalisée (:patterns | :synth) → :editor → :global. Un binding
    # qui ne matche pas laisse la touche au moteur vim de l'éditeur.
    if ed.mode === :normal
        if m.pending_leader
            # Space déjà pressé : la touche suivante choisit dans :leader.
            is_press || return
            if evt.key === :escape
                m.pending_leader = false; return
            end
            # Modificateur seul (Shift avant un E majuscule…) : on attend.
            (evt.key !== :char || evt.char == '\0') && return
            m.pending_leader = false
            dispatch!(((:leader, m),), evt; prefix = "Space")
            return
        end
        # `g` en attente (posé par l'éditeur) → accords « g t », « g T »…
        prefix = ed.pending_key == 'g' ? "g" : ""
        if dispatch!(_editor_layers(m), evt; prefix = prefix)
            isempty(prefix) || (ed.pending_key = nothing)
            return
        end
    end
    # Operator-motion combos (cw / dw / yw + big variants + e variants).
    # TK only implements the doubled forms (cc/dd/yy) — these proper
    # combos are ours. Each preserves `scroll_offset` so the buffer
    # view doesn't jump when text is mutated.
    if is_press && ed.mode === :normal &&
       ed.pending_key in ('c', 'd', 'y') &&
       evt.char in ('w', 'b', 'W', 'B', 'e', 'E')
        op = ed.pending_key
        ed.pending_key = nothing
        _op_with_motion!(m, ed, op, evt.char)
        return
    end
    # Word motions — override TK's so they ALWAYS advance and wrap
    # across lines reliably, never blocking on punctuation. W / B / E
    # are vim's "big word" variants treating whitespace as the only
    # separator (foo.bar = one jump). Skipped when a multi-key pending
    # is active (handled above as a NOOP) so they don't fire under
    # cw/dw/yw.
    if is_press && ed.mode === :normal &&
       evt.char in ('w', 'b', 'W', 'B') &&
       ed.pending_key === nothing
        kind = (evt.char == 'W' || evt.char == 'B') ? :big : :small
        dir  = (evt.char == 'w' || evt.char == 'W') ? +1 : -1
        _word_motion!(ed, dir, kind)
        return
    end
    # Tab autocomplete in :insert mode. Priority order:
    #   1. If a ghost suggestion is visible, accept it.
    #   2. Otherwise fall through to the existing word-cycle.
    # On any non-Tab keystroke in insert mode we reset the cycle state
    # and recompute the ghost from the new context.
    if is_press && ed.mode === :insert
        # Placeholder navigation takes priority over autocomplete when
        # a snippet expansion is being filled. Tab/Shift-Tab move
        # between $1, $2, …; Esc exits placeholder tracking (the next
        # Esc returns to normal mode via the editor's default).
        if m.placeholder_active && evt.key === :tab
            _placeholder_jump!(m, ed, +1); return
        end
        if m.placeholder_active && evt.key === :backtab
            _placeholder_jump!(m, ed, -1); return
        end
        if m.placeholder_active && evt.key === :escape
            m.placeholder_active = false
            # fall through to TK so Esc still exits insert mode.
        end
        if evt.key === :tab
            if !isempty(m.ghost) && _accept_ghost!(m)
                _compute_ghost!(m)
                return
            end
            if _try_autocomplete!(m, ed)
                m.ghost = ""
                return
            end
        else
            _reset_completion!(m)
            # Snapshot line length pre-edit so the placeholder tracker
            # can shift remaining $N positions by the right delta.
            pre_len = (m.placeholder_active &&
                       1 <= ed.cursor_row <= length(ed.lines)) ?
                      length(ed.lines[ed.cursor_row]) : 0
            TK.handle_key!(ed, evt)
            cmd = TK.pending_command!(ed)
            isempty(cmd) || _handle_ex_command!(m, cmd)
            m.placeholder_active && _placeholder_track_change!(m, ed, pre_len)
            _compute_ghost!(m)
            return
        end
    end
    # Tab in :command (ex-command line, ":synth wob...") autocompletes
    # the command verb itself OR the argument (synth/sample/instrument
    # name) when one already has been typed.
    if is_press && evt.key === :tab && ed.mode === :command
        if _try_ex_autocomplete!(m, ed)
            return
        end
    end
    # Arrow keys navigate the completion picker grid while an
    # ex-command cycle is active. Up/down move by row (±cols), left/
    # right move by one cell with wrap. The picker stays open so the
    # user can refine; Enter accepts the current selection by virtue
    # of the splice having already rewritten the command_buffer.
    if is_press && ed.mode === :command && _completion_picker_active(m)
        if evt.key === :up
            _move_completion_session!(m, :up) && return
        elseif evt.key === :down
            _move_completion_session!(m, :down) && return
        elseif evt.key === :left
            _move_completion_session!(m, :left) && return
        elseif evt.key === :right
            _move_completion_session!(m, :right) && return
        end
    end
    # ↑/↓ in :command (with no completion picker) navigate the ex-cmd
    # history — like a shell prompt. Reset on any other keypress.
    if is_press && ed.mode === :command && !_completion_picker_active(m) &&
       (evt.key === :up || evt.key === :down)
        _ex_history_nav!(m, ed, evt.key)
        return
    end
    # Any other non-Tab / non-arrow key in :command clears the
    # completion cycle (so the splice closure's captured tokens
    # don't go stale).
    if is_press && ed.mode === :command && evt.key !== :tab &&
       !(evt.key in (:up, :down, :left, :right))
        _reset_completion!(m)
        # Editing the buffer also exits history-nav mode so the next ↑
        # restarts from the most-recent entry.
        evt.key === :char && (m.ex_history_idx = 0)
    end
    # Snapshot for normal-mode `.` recording — see _vim_post_normal!.
    pre_text = ed.mode === :normal ? TK.text(ed) : ""
    pre_mode = ed.mode
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    if is_press && pre_mode === :normal
        _vim_post_normal!(m, ed, evt, pre_text)
    end
end

_is_typable_ascii(c::Char) = ncodeunits(c) == 1 && (isprint(c) && c != '\0')

# ---------------------------------------------------------------------
# Live doc row
# ---------------------------------------------------------------------
