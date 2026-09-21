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
    _route_key_to_focused_pane!(m, evt) -> Bool

Forward a KeyEvent to the focused workspace pane's PaneImpl
`handle_key!` when the focused pane is NOT the legacy patterns
editor. Returns `true` if the event was consumed by a non-patterns
pane (the caller must early-return); returns `false` for the
patterns pane so the legacy update! body keeps handling cursor
moves, autocomplete, etc.
"""
function _route_key_to_focused_pane!(m::RessacApp, evt::TK.KeyEvent)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    (leaf === nothing || isempty(leaf.tabs)) && return false
    1 <= leaf.current_tab <= length(leaf.tabs) || return false
    pane = leaf.tabs[leaf.current_tab]
    ed = _active_editor(m)        # `nothing` when no editor pane is open
    # While the editor is in ex command mode, ALL keys belong to it —
    # otherwise typed chars after ':' would land in the focused side
    # pane instead of the ex command buffer. Same for :search.
    if ed !== nothing && (ed.mode === :command || ed.mode === :search)
        return false
    end
    # Global shortcuts that always belong to the editor regardless of
    # which workspace pane has focus. ':' opens ex command mode;
    # without this fall-through, ex commands wouldn't be reachable
    # from a focused log / doc / scope side pane.
    if evt.key === :char && evt.char == ':' &&
       ed !== nothing && ed.mode === :normal
        return false
    end
    # Synth-role pane: route T/t/Space (in :normal mode) to the
    # legacy _test_current_synth! path so DSL eval / SC ship still
    # fires. Without this, the EditorPane handle_key! stub is a
    # no-op and pressing T appears to do nothing.
    if pane isa EditorPane &&
       1 <= pane.current_tab <= length(pane.tabs) &&
       pane.tabs[pane.current_tab].role === :synth &&
       pane.tabs[pane.current_tab].code_editor.mode === :normal &&
       evt.key === :char && (evt.char == 'T' || evt.char == 't' ||
                              evt.char == ' ')
        _test_current_synth!(m)
        return true
    end
    # Patterns pane uses _active_editor(m) — legacy path owns it.
    if pane isa EditorPane &&
       1 <= pane.current_tab <= length(pane.tabs) &&
       pane.tabs[pane.current_tab].code_editor === ed
        return false
    end
    # TK.CodeEditor.handle_key! short-circuits to `false` when
    # `.focused` is false — its keymap is gated on focus. Make sure
    # the target editor sees itself as focused before delegating; the
    # next view() refresh keeps it in sync.
    if pane isa EditorPane &&
       1 <= pane.current_tab <= length(pane.tabs)
        pane.tabs[pane.current_tab].code_editor.focused = true
    end
    handle_key!(pane, evt)
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
    return true
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
    cmd_split!(m.workspaces, "editor",
               Dict{String,Any}("buffer_role" => "synth", "name" => name))
    ws = current_workspace(m.workspaces)
    ws === nothing && return true
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    if leaf !== nothing && !isempty(leaf.tabs)
        pane = leaf.tabs[leaf.current_tab]
        pane isa EditorPane && 1 <= pane.current_tab <= length(pane.tabs) &&
            TK.set_text!(pane.tabs[pane.current_tab].code_editor, dsl)
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

# Sculpt studio modal (ouverture, drain explorer `M`, commandes :sculpt/:w,
# routage clavier, rendu) → src/modal_sculpt.jl, inclus plus bas avec les
# autres modaux.

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
    rects = _compute_rects(ws.tree, m._last_ws_area)
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
    rects = _compute_rects(ws.tree, m._last_ws_area)
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
    if _route_key_to_focused_pane!(m, evt)
        return
    end
    # No editor pane open at all → nothing below (the legacy patterns
    # keystroke flow) applies. The focused pane already had its chance
    # via routing above; eat the key.
    _active_editor(m) === nothing && return
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
    # (Modal keys are handled earlier, before focus-pane routing.)
    ed = _active_editor(m)
    is_press = evt.action === TK.key_press
    # Vim `.` repeat — replay the text typed during the last insert
    # session at the current cursor. Intercept BEFORE Tachikoma so the
    # editor doesn't swallow it as a "join lines" or no-op.
    if is_press && ed.mode === :normal && evt.char == '.'
        _vim_replay!(m, ed); return
    end
    # Visual-line mode dispatch — handles selection + operators.
    if m.visual_active && is_press
        _visual_handle!(m, ed, evt) && return
    end
    # `V` (capital) enters visual-line mode.
    if is_press && ed.mode === :normal && evt.char == 'V' && !m.visual_active
        m.visual_active = true
        m.visual_kind = :line
        m.visual_anchor_row = ed.cursor_row
        m.visual_anchor_col = ed.cursor_col
        _push_app_log!(m, "[INFO] V — visual line · j/k extend · d/y/c act · Esc cancel")
        return
    end
    # `v` (lowercase) enters character-wise visual.
    if is_press && ed.mode === :normal && evt.char == 'v' && !m.visual_active
        m.visual_active = true
        m.visual_kind = :char
        m.visual_anchor_row = ed.cursor_row
        m.visual_anchor_col = ed.cursor_col
        _push_app_log!(m, "[INFO] v — visual char · hjkl extend · d/y/c act · Esc cancel")
        return
    end
    # Pattern editor — context-aware ops fire only when the cursor is
    # inside a `p"…"` body. Outside, the keys fall through to the
    # editor's normal vim behaviour (indent / motion).
    if is_press && ed.mode === :normal && _pat_at_cursor(ed) !== nothing
        if evt.char == '>'
            _pat_zoom!(m, ed, +1); return
        elseif evt.char == '<'
            _pat_zoom!(m, ed, -1); return
        elseif evt.char == 'L'
            _pat_shift!(m, ed, +1); return
        elseif evt.char == 'H'
            _pat_shift!(m, ed, -1); return
        elseif evt.char == 'X'
            _pat_silence!(m, ed); return
        end
    end
    # Track insert-session text so `.` has something to replay.
    _vim_record_keystroke!(m, ed, evt, is_press)
    # Tab in :normal swaps focus between patterns and the active synth tab.
    if is_press && evt.key === :tab && ed.mode === :normal && _synth_pane_open(m) &&
       !_is_waveform_sculpt_focused(m)
        _swap_focus!(m)
        return
    end
    # gt / gT cycle synth panes while focused on a synth pane.
    if is_press && ed.mode === :normal &&
       _focused_role(m) === :synth && length(_all_synth_buffers(m)) > 1
        if evt.char == 't' && ed.pending_key == 'g'
            ed.pending_key = nothing
            _cycle_synth_tab!(m; dir=+1)
            return
        elseif evt.char == 'T' && ed.pending_key == 'g'
            ed.pending_key = nothing
            _cycle_synth_tab!(m; dir=-1)
            return
        end
    end
    # Nudge: fires on key_press AND key_repeat so the user can HOLD
    # +/-/*//to scrub through values. Other normal-mode actions stay
    # press-only (we don't want every action to retrigger on held key).
    if ed.mode === :normal &&
       (evt.action === TK.key_press || evt.action === TK.key_repeat) &&
       evt.char in ('+','-','*','/') && _has_number_under_cursor(ed)
        step = evt.char == '+' ? 1 :
               evt.char == '-' ? -1 :
               evt.char == '*' ? 10 : -10
        _nudge_number_under_cursor!(m, ed, step)
        return
    end
    # T (or Space) held: fire repeatedly with accelerating interval.
    # The initial press goes through the normal-mode block below;
    # key_repeat events are handled here so they bypass the press-only
    # gate. Each fire multiplies the interval by config.t_hold_accel
    # (clamped to t_hold_min_ms).
    if ed.mode === :normal && evt.action === TK.key_repeat &&
       (evt.char == 'T' || evt.char == 't' || evt.char == ' ') &&
       _synth_pane_open(m)
        _fire_t_with_accel!(m; held=true)
        return
    end
    # Vim operator + motion combos (cw / dw / yw / c$ / d0 / …).
    # Tachikoma sets ed.pending_key to the operator on the first
    # press (c/d/y) and only knows how to handle cc/dd/yy. We piggyback
    # so the SECOND press dispatches a word-motion-based operation
    # when relevant, otherwise falls through to Tachikoma's own logic
    # (so cc/dd/yy still work).
    if is_press && ed.mode === :normal
        pk = ed.pending_key
        if pk !== nothing && pk in ('c', 'd', 'y') &&
           evt.key === :char && evt.char in ('w', 'b', 'e', 'W', 'B', 'E', '\$', '0')
            ed.pending_key = nothing
            _vim_op_motion!(m, ed, pk, evt.char)
            return
        end
        if pk === nothing && evt.key === :char && evt.char in ('w', 'b', 'W', 'B')
            _vim_word_motion!(ed, evt.char)
            return
        end
    end
    # Space-leader trigger lookup. Runs BEFORE other normal-mode
    # handlers so the trigger char isn't stolen by `e` / `m` / etc.
    # Actions (open picker / modal) win over snippet expansions on the
    # same char, since callbacks don't need cursor state.
    if is_press && ed.mode === :normal && m.pending_leader
        # Escape cancels the leader without firing anything.
        if evt.key === :escape
            m.pending_leader = false; return
        end
        # Ignore non-char keystrokes — this includes modifier-only
        # events (Shift / Alt by themselves) emitted by some terminals
        # in between Space and the actual trigger char. Without this
        # guard, pressing Space then Shift+E would consume the leader
        # on the Shift event and `E` never gets the snippet.
        if evt.key !== :char || evt.char == '\0'
            return
        end
        m.pending_leader = false
        if haskey(_LEADER_ACTIONS, evt.char)
            _LEADER_ACTIONS[evt.char](m); return
        end
        if haskey(_LEADER_SNIPPETS, evt.char)
            _expand_snippet!(m, ed, _LEADER_SNIPPETS[evt.char])
            return
        end
        # Unknown trigger — silently cancel leader.
        return
    end
    # Page-scroll keys (PgUp/PgDn + vim Ctrl-D/Ctrl-U). We handle these
    # ourselves so the view AND cursor move by the same delta — keeps
    # the cursor in the same screen position rather than re-centering.
    # Available in :normal mode in both panes.
    if is_press && ed.mode === :normal
        if evt.key === :pagedown
            _page_scroll!(m, ed, +_viewport_h(m, ed)); return
        elseif evt.key === :pageup
            _page_scroll!(m, ed, -_viewport_h(m, ed)); return
        elseif evt.key === :ctrl && evt.char == 'd'
            _page_scroll!(m, ed, +max(1, _viewport_h(m, ed) ÷ 2)); return
        elseif evt.key === :ctrl && evt.char == 'u'
            _page_scroll!(m, ed, -max(1, _viewport_h(m, ed) ÷ 2)); return
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
    # +/- nudge the number under the cursor (keyboard version of the
    # existing mouse-wheel nudge). Only intercepts when the cursor IS
    # on a number — otherwise falls through to vim's `+`/`-`
    # "next/previous line" motion.
    if is_press && ed.mode === :normal && _focused_role(m) === :patterns
        if evt.char == '+'
            _try_nudge_at!(m, ed, ed.cursor_row, ed.cursor_col, +1) && return
        elseif evt.char == '-'
            _try_nudge_at!(m, ed, ed.cursor_row, ed.cursor_col, -1) && return
        elseif evt.char == '*'
            _try_scale_at!(m, ed, ed.cursor_row, ed.cursor_col, 2.0) && return
        elseif evt.char == '/'
            _try_scale_at!(m, ed, ed.cursor_row, ed.cursor_col, 0.5) && return
        end
    end
    # Intercept our normal-mode actions BEFORE handle_key! so the
    # CodeEditor doesn't swallow them (it interprets T/K/S/e/m as
    # potential vim commands and consumes the keystroke).
    if is_press && ed.mode === :normal
        if evt.char == 'e' && _focused_role(m) === :patterns
            # `e` evals the current line as Julia. Only meaningful in the
            # patterns pane — the synth pane buffer contains SuperCollider
            # code which Julia can't parse, so leave `e` for the editor's
            # vim "end of word" motion there.
            _eval_current_line!(m); return
        elseif evt.char == 'E' && _focused_role(m) === :patterns
            # `E` evals every @dN block in the buffer. Same intercept
            # reasoning as `e` — vim's "end of WORD" motion would
            # otherwise swallow the keystroke. Help text + welcome
            # buffer + README all promise this binding.
            _eval_pattern_blocks!(m, :all); return
        elseif (evt.char == 'T' || evt.char == 't' || evt.char == ' ') &&
               _synth_pane_open(m) && _focused_role(m) === :synth
            # t / T / Space all fire the test in the synth pane. Vim's
            # `t` (till motion) isn't useful there, and giving up the
            # shift keypress is worth it for the iteration speed.
            _fire_t_with_accel!(m)
            return
        elseif evt.char == ' ' && _focused_role(m) === :patterns && !m.tap_recording
            # Space-as-leader for snippet expansion. Patterns pane
            # only — synth pane uses Space to fire the test synth.
            # The next char picks a template from _LEADER_SNIPPETS.
            m.pending_leader = true
            return
        elseif evt.char == 'K' && _focused_role(m) === :patterns
            _preview_word_under_cursor!(m); return
        elseif evt.char == 'S'
            # Allow S anywhere — scope is useful even without a synth
            # pane open (e.g. while a pattern is playing).
            _scope_cycle_key!(m); return
        elseif evt.char == 'm' && _focused_role(m) === :patterns
            _toggle_mute_current_line!(m); return
        elseif evt.char == '?' && _focused_role(m) === :patterns
            # Quick help — opens the guide modal without going through
            # `:?`. Matches the footer hint shown in normal-mode.
            m.modal = :guide; m.modal_scroll = 0
            return
        elseif evt.char == ','
            # Soft hush — pulls patterns from the scheduler but lets
            # SC's currently-playing synths complete their envelope
            # naturally. Use for "stop the loop but don't slaughter
            # the reverb tail".
            _hush!(m); return
        elseif evt.char == '+' && _APP_SCOPE_TYPE[] === :wave
            m.scope_zoom = clamp(m.scope_zoom * 1.5, 0.1, 32.0)
            _push_app_log!(m, "[INFO] scope Y-zoom ×$(round(m.scope_zoom; digits=2))"); return
        elseif evt.char == '-' && _APP_SCOPE_TYPE[] === :wave
            m.scope_zoom = clamp(m.scope_zoom / 1.5, 0.1, 32.0)
            _push_app_log!(m, "[INFO] scope Y-zoom ×$(round(m.scope_zoom; digits=2))"); return
        elseif evt.char == '+' &&
               (_APP_SCOPE_TYPE[] === :reservoir ||
                _APP_SCOPE_TYPE[] === Symbol("reservoir-graph"))
            _APP_SCOPE_RESERVOIR_SPAN[] = clamp(
                _APP_SCOPE_RESERVOIR_SPAN[] / 1.5, 0.1, 60.0)
            _push_app_log!(m, "[INFO] reservoir scope span = $(round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)) s (faster)"); return
        elseif evt.char == '-' &&
               (_APP_SCOPE_TYPE[] === :reservoir ||
                _APP_SCOPE_TYPE[] === Symbol("reservoir-graph"))
            _APP_SCOPE_RESERVOIR_SPAN[] = clamp(
                _APP_SCOPE_RESERVOIR_SPAN[] * 1.5, 0.1, 60.0)
            _push_app_log!(m, "[INFO] reservoir scope span = $(round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)) s (slower)"); return
        elseif evt.char == '=' && _APP_SCOPE_TYPE[] === :wave
            m.scope_zoom = 1.0; m.scope_zoom_x = 1.0
            _push_app_log!(m, "[INFO] scope zoom reset (X & Y)"); return
        elseif evt.char == '>' && _APP_SCOPE_TYPE[] === :wave
            m.scope_zoom_x = clamp(m.scope_zoom_x * 1.5, 0.1, 32.0)
            _push_app_log!(m, "[INFO] scope X-zoom ×$(round(m.scope_zoom_x; digits=2))"); return
        elseif evt.char == '<' && _APP_SCOPE_TYPE[] === :wave
            m.scope_zoom_x = clamp(m.scope_zoom_x / 1.5, 0.1, 32.0)
            _push_app_log!(m, "[INFO] scope X-zoom ×$(round(m.scope_zoom_x; digits=2))"); return
        end
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
