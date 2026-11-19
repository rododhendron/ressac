# src/app_view.jl
# Rendu : TK.view (chrome + arbre de panes + modal), status line, barre de
# touches, journal (une ligne par défaut) et _push_app_log!.

"""
    _creation_hint(m) -> Union{Nothing,String}

Indice de création affiché à la place de la livedoc quand le curseur
est sur une ligne vide de la pane patterns, ou juste après un `|>`.
"""
function _creation_hint(m::RessacApp)
    _focused_role(m) === :patterns || return nothing
    ed = _active_editor(m)
    ed === nothing && return nothing
    1 <= ed.cursor_row <= length(ed.lines) || return nothing
    line = String(ed.lines[ed.cursor_row])
    _ = line
    if m.placeholder_active
        n = length(m.placeholder_cols)
        return "✎ trou $(m.placeholder_idx)/$n : i remplit · Tab suivant · u annule"
    end
    if isempty(strip(line))
        return "✎ vide : Espace d slot · Espace I snippets · K doc"
    end
    if endswith(rstrip(line), "|>") && ed.mode === :insert
        return "✎ |> gain(0.8) · lpf(800) · fast(2) · every(4, rev) · Tab complète"
    end
    return nothing
end

"""
    _livedoc_under_cursor(m) -> Union{Nothing,Tuple{String,String}}

(mot, doc) du mot sous le curseur de l'éditeur actif s'il est documenté
(params SuperDirt, UGens…), sinon `nothing`. Affiché à droite de la
barre de touches.
"""
function _livedoc_under_cursor(m::RessacApp)
    ed = _active_editor(m)
    ed === nothing && return nothing
    1 <= ed.cursor_row <= length(ed.lines) || return nothing
    line_chars = ed.lines[ed.cursor_row]
    isempty(line_chars) && return nothing
    col = clamp(ed.cursor_col + 1, 1, length(line_chars))
    word = _word_under_cursor_chars(line_chars, col)
    doc = isempty(word) ? nothing : _lookup_livedoc(word)
    if doc === nothing
        # Pas de doc sur le mot : celle de l'appel qui l'englobe
        # (`every(4, fast(2))` avec le curseur sur 4 → every).
        word = _enclosing_call(line_chars, col)
        isempty(word) && return nothing
        doc = _lookup_livedoc(word)
        doc === nothing && return nothing
    end
    return (String(word), String(doc))
end

# Nom de l'appel dont la parenthèse ouvrante non fermée précède `col`
# (profondeur comptée), sans suffixe .ar/.kr ; "" si aucun.
function _enclosing_call(chars::Vector{Char}, col::Integer)
    depth = 0
    i = min(col, length(chars))
    while i >= 1
        c = chars[i]
        if c == ')'
            depth += 1
        elseif c == '('
            if depth == 0
                w = _word_under_cursor_chars(chars, max(1, i - 1))
                w = replace(w, r"\.(ar|kr|ir)$" => "")
                return isempty(w) ? "" : w
            end
            depth -= 1
        end
        i -= 1
    end
    return ""
end

function _word_under_cursor_chars(chars::Vector{Char}, col::Integer)
    n = length(chars)
    n == 0 && return ""
    col = clamp(col, 1, n)
    is_word = c -> isletter(c) || isdigit(c) || c == '_' || c == '.'
    start_col = col
    while start_col > 1 && is_word(chars[start_col - 1])
        start_col -= 1
    end
    end_col = col - 1
    while end_col + 1 <= n && is_word(chars[end_col + 1])
        end_col += 1
    end
    end_col < start_col && return ""
    return String(chars[start_col:end_col])
end

# ---------------------------------------------------------------------
# Modal handlers
# ---------------------------------------------------------------------

"""
    _render_pane_block!(m, rect, buf; title, title_right="", focused=false)

Draw a rounded-border `TK.Block` over `rect` with title chips on the
top edge. Focused panes get a brighter accent border so the eye knows
where keys land; unfocused panes use the dim `:border` style.

The block consumes 1 row + 1 col of `rect` on each side; callers
should pass `_inner_rect(rect)` to any content widget that follows.
"""
function _render_pane_block!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer;
                             title::AbstractString,
                             title_right::AbstractString = "",
                             focused::Bool = false,
                             title_right_accent::Bool = false)
    (rect.width < 2 || rect.height < 1) && return
    _clear_rect!(buf, rect)
    _band!(buf, rect.x, rect.y, rect.width, String(title); right = String(title_right),
           focus = focused ? _ui().o : nothing)
    return
end

"""
    _inner_rect(rect) -> TK.Rect

Return the area inside a `TK.Block` border (1-cell inset on each side).
Mirrors `TK.inner_area` without needing the Block instance.
"""
function _inner_rect(rect::TK.Rect)
    TK.Rect(rect.x + 1, rect.y + 1,
            max(0, rect.width - 2), max(0, rect.height - 2))
end



"""
    _render_global_log_tail!(m, area, buf)

Render the global log tail (or the completion picker when active)
into `area`. Extracted from `view()` so the new workspace dispatcher
can call it as a chrome row independently of the
workspace area. Behavior-preserving extraction — no visible change.
"""
function _render_global_log_tail!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    if area.height == 1 && !_completion_picker_active(m)
        # Une seule ligne : la dernière chose dite, sans cadre.
        m._last_log_rect = area
        _render_logs(m, area, buf)
        return
    end
    if _completion_picker_active(m)
        title       = "COMPLÉTIONS"
        title_right = "$(m.completion_idx)/$(length(m.completion_candidates)) · Tab suivant · autre touche annule"
    else
        title       = "JOURNAL"
        title_right = "$(length(m.logs))" * (m.log_view.following ? "" : " · ↑")
    end
    _render_pane_block!(m, area, buf;
        title = title, title_right = title_right, focused = false)
    log_inner = _inner_rect(area)
    m._last_log_rect = log_inner
    if _completion_picker_active(m)
        _render_completion_picker!(m, log_inner, buf)
    else
        _render_logs(m, log_inner, buf)
    end
end

"""
    _nt_to_rect(nt) -> TK.Rect

Convert a workspace-manager NamedTuple `(x, y, w, h)` rect to a
`TK.Rect`. `_compute_rects` returns NamedTuples (no Tachikoma dep
in workspace_manager.jl); pane render! consumes Rect via `.width` /
`.height` accessors.
"""
_nt_to_rect(nt::NamedTuple) = TK.Rect(nt.x, nt.y, nt.w, nt.h)

"""
    _render_tree!(node, rects, buf, m)

Walk the workspace tree and call each leaf's render! against its
computed rect. Containers recurse. As a side effect, populates
`_focused_editor_rect(m)` from the leaf currently holding `_active_editor(m)`
(via its EditorPane wrapper) so the overlays (eval flash, playhead,
ghost) and the mouse handler find it.
rewires them through `_compute_rects` directly.
"""
function _render_tree!(node::LayoutNode, rects::Dict, buf::TK.Buffer,
                       m::RessacApp)
    ws = current_workspace(m.workspaces)
    focused_id = ws === nothing ? 0 : ws.focused_pane
    _render_tree_inner!(node, rects, buf, m, focused_id)
end

function _render_tree_inner!(node::LayoutNode, rects::Dict, buf::TK.Buffer,
                             m::RessacApp, focused_id::Int)
    if node isa PaneLeaf
        r_nt = get(rects, node.id, nothing)
        r_nt === nothing && return
        rect = _nt_to_rect(r_nt)
        if 1 <= node.current_tab <= length(node.tabs)
            pane = node.tabs[node.current_tab]
            # Sync per-pane editor focus + tick so cursor blink /
            # mode-aware rendering matches the workspace focus.
            if pane isa EditorPane
                for (i, tab) in enumerate(pane.tabs)
                    tab.code_editor.tick = m.tick
                    tab.code_editor.focused =
                        (node.id == focused_id && i == pane.current_tab)
                end
            end
            # La pane focalisée se dessine dans la couleur du mode (cadre +
            # titre en pastille) : on lui passe la couleur par le Ref
            # global lu par _render_pane_block_simple!.
            _PANE_FOCUS_COLOR[] = node.id == focused_id ? _mode_color(m) : nothing
            try
                _render_pane_guarded!(m, pane, rect, buf)
                pane isa EditorPane && _render_slot_marks!(m, pane, rect, buf)
                pane isa EditorPane && _render_cursor_line!(m, pane, rect, buf)
                pane isa EditorPane && _render_knob!(m, pane, rect, buf)
            finally
                _PANE_FOCUS_COLOR[] = nothing
            end
        end
        return
    end
    for child in node.children
        _render_tree_inner!(child, rects, buf, m, focused_id)
    end
end


function _render_floats!(floats::Vector{FloatingPane}, buf::TK.Buffer,
                         m::RessacApp)
    for f in sort(floats; by = x -> x.z_order)
        _render_pane_guarded!(m, f.pane, TK.Rect(f.x, f.y, f.w, f.h), buf)
    end
end

# Une pane dont le rendu lève ne fait tomber ni l'app ni ses voisines : son
# rectangle affiche l'erreur, le journal la garde (dédupliquée d'une frame à
# l'autre par `_push_app_log!`).
function _render_pane_guarded!(m::RessacApp, pane::PaneImpl, rect::TK.Rect, buf::TK.Buffer)
    try
        render!(pane, rect, buf)
    catch err
        msg = first(sprint(showerror, err), 160)
        _push_app_log!(m, "[ERROR] affichage de la pane « $(title(pane)) » — $msg")
        rect.width > 0 && rect.height > 0 &&
            TK.set_string!(buf, rect.x, rect.y,
                           first("✗ " * msg, rect.width), TK.tstyle(:error))
    end
    return nothing
end

"""
    _global_log_tail_height(m) -> Int

Number of rows reserved for the global log tail chrome at the
bottom of the screen. Collapses to 0 when any workspace tree leaf
holds a LogPane (avoid duplicate rendering).
"""
function _global_log_tail_height(m::RessacApp)
    m.log_tail_rows <= 0 && return 0
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        for leaf in _all_leaves(ws.tree), t in leaf.tabs
            t isa LogPane && return 0
        end
    end
    m.log_tail_rows == 1 && return 1    # une ligne : la dernière, sans cadre
    return m.log_tail_rows + 2          # + les deux bordures
end

# `:log` : le journal du bas, 1 ligne → 3 → 10 → replié → 1 ; `:log N` fixe.
function _cycle_log_tail!(m::RessacApp, n::Union{Nothing,Int} = nothing)
    m.log_tail_rows = n !== nothing ? clamp(n, 0, 30) :
                      m.log_tail_rows == 1 ? 3 : m.log_tail_rows == 3 ? 10 : m.log_tail_rows == 10 ? 0 : 1
    _scroll_end!(m.log_view)
    _push_app_log!(m, m.log_tail_rows == 0 ? "[INFO] journal replié (:log pour le rouvrir · :copylogs copie tout)" :
                                             "[INFO] journal : $(m.log_tail_rows) lignes")
    return
end

function TK.view(m::RessacApp, f::TK.Frame)
    # Ce que les threads de fond (scheduler, écoute OSC) ont à dire.
    for line in _drain_notices!()
        _push_app_log!(m, line)
    end
    # …et les résultats des travaux de fond (requêtes, rendus hors-ligne).
    _drain_jobs!(m)
    # Dernier filet, comme pour les touches : Tachikoma relance toute
    # exception sortie de `view`, ce qui ferme la session en plein jeu.
    try
        _view!(m, f)
    catch err
        _push_app_log!(m, "[ERROR] affichage — $(first(sprint(showerror, err), 160))")
    end
    return
end

function _view!(m::RessacApp, f::TK.Frame)
    # Paused: skip the whole draw so the terminal's last frame stays put
    # and the user can shift-drag-select + copy without our next render
    # wiping the highlight. update! flips paused=false on any keypress,
    # which will cause the next view() to render normally and the
    # selection to clear — by then the user has already copied.
    m.paused && return
    m.tick += 1
    _ensure_default_workspace!(m)
    # Tick every editor in the tree so cursor blink animates. The
    # per-pane render in _render_tree_inner! also syncs .tick, but
    # doing it up-front covers panes scrolled out of the current
    # frame too.
    let ws = current_workspace(m.workspaces)
        if ws !== nothing
            for leaf in _all_leaves(ws.tree)
                for tab in leaf.tabs
                    if tab isa EditorPane
                        for b in tab.tabs
                            b.code_editor.tick = m.tick
                        end
                    end
                end
            end
        end
    end
    # Un onglet de la réserve se souvient d'être le dernier ouvert ; un motif
    # en écoute s'arrête dès qu'on quitte les motifs.
    _reserve_index(m.modal) === nothing || (m.reserve_tab = m.modal)
    m.modal === :patterns || _patterns_preview_stop!(m)
    _redefine_tick!(m)                # un son dont on a tiré un nombre
    _explore_slot_tick!(m)            # l'explorateur ouvert sur un slot : le candidat joue dans le pattern
    _audio_tick!(m)                   # SuperCollider vient de répondre : rebrancher les sorties choisies
    _update_live_doc!(m)
    _synth_workspace_sync!(m)         # la DOC d'un son relit son texte
    _tutorial_tick!(m)                # le tutoriel avance quand l'étape est faite (après la synchro : il lit le texte)
    buf = f.buffer

    area = f.area
    # Chrome : status line en haut ; en bas la barre de touches (ou la
    # barre de commande quand elle est active) puis le journal (0 / 3 /
    # 10 lignes + bordures). Tout le reste est le workspace.
    log_h     = completion_active(m.command_line) ? 12 : _global_log_tail_height(m)
    status_y  = area.y
    keybar_y  = area.y + area.height - 1 - log_h
    log_y     = keybar_y + 1
    ws_y      = status_y + 1
    ws_height = max(0, keybar_y - ws_y)
    _sc_ping!(m.scheduler.osc)
    # Workspace area — dispatched through _compute_rects. Cached on
    # the model so the mouse handler can hit-test workspace leaves
    # without re-deriving chrome heights.
    if ws_height > 0
        ws_nt = (x = area.x, y = ws_y, w = area.width, h = ws_height)
        m._last_ws_area = ws_nt
        _volet_follow_width!(m)       # le son gagne sa colonne sur un grand écran
        _fiche_fit_width!(m)          # la fiche : une colonne de lecture, pas un tiers
        _son_fit_width!(m)            # un son : texte et DOC côte à côte si l'écran le permet
        ws = current_workspace(m.workspaces)
        if ws !== nothing
            # Un changement de focus dézoome (comme tmux).
            m.zoom_leaf != 0 && m.zoom_leaf != ws.focused_pane && (m.zoom_leaf = 0)
            rects = _workspace_rects(m, ws, ws_nt)
            _render_tree!(ws.tree, rects, buf, m)
            _render_resize_highlight!(m, buf)
            m.floats_hidden || _render_floats!(ws.floats, buf, m)
        end
    else
        m._last_ws_area = nothing
    end

    # Overlays — only painted when the patterns editor is visible in
    # the workspace tree (_focused_editor_rect(m) is set by _render_tree!).
    if _focused_editor_rect(m) !== nothing
        _render_eval_flash!(m, _focused_editor_rect(m), buf)
        _render_visual_selection!(m, _focused_editor_rect(m), buf)
        _render_playhead!(m, _focused_editor_rect(m), buf)
    end
    _load_ghost_usage!()
    if _focused_editor_rect(m) !== nothing
        _render_ghost!(m, _focused_editor_rect(m), buf)
    end

    _render_status_bar(m, TK.Rect(area.x, status_y, area.width, 1), buf)
    keybar_rect = TK.Rect(area.x, keybar_y, area.width, 1)
    if is_active(m.command_line)
        render_bar!(m.command_line, keybar_rect, buf)
    else
        _render_footer(m, keybar_rect, buf)
    end
    if log_h > 0
        log_rect = TK.Rect(area.x, log_y, area.width, log_h)
        # When the CommandLine is showing completion candidates, the
        # log tail area becomes a picker — same chrome rows, different
        # content.
        if completion_active(m.command_line)
            _render_pane_block_simple!(log_rect, "COMPLETIONS", buf)
            render_picker!(m.command_line,
                           _inner_rect_simple(log_rect), buf)
        else
            _render_global_log_tail!(m, log_rect, buf)
        end
    end

    # Which-key : popup des suites possibles d'un préfixe (Space, g, Ctrl-w),
    # juste au-dessus de la barre de touches.
    _render_whichkey!(m, TK.Rect(area.x, ws_y, area.width, max(1, keybar_y - ws_y)), buf)

    # Modal : par-dessus le workspace, JAMAIS sur la barre de touches (qui
    # montre ses raccourcis) ni sur le journal.
    if m.modal !== :none
        marea = TK.Rect(area.x, ws_y, area.width, max(1, keybar_y - ws_y))
        _ui_dim!(buf, marea)          # ce qui flotte éteint le reste
        if m.modal === :browse
            _render_browser_modal!(m, marea, buf)
        elseif m.modal === :synth_library
            _render_synth_library_modal!(m, marea, buf)
        elseif m.modal === :outputs
            _render_outputs_modal!(m, marea, buf)
        elseif m.modal === :sccode
            _render_sccode_modal!(m, marea, buf)
        elseif m.modal === :snippets
            _render_snippets_modal!(m, marea, buf)
        elseif m.modal === :mixer
            _render_mixer_modal!(m, marea, buf)
        elseif m.modal === :patterns
            _render_patterns_modal!(m, marea, buf)
        elseif m.modal === :sessions
            _render_sessions_modal!(m, marea, buf)
        elseif m.modal === :atelier
            _render_atelier_modal!(m, marea, buf)
        elseif m.modal === :evolve
            _render_evolve_modal!(m, marea, buf)
        elseif m.modal === :palette
            _render_palette_modal!(m, marea, buf)
        elseif m.modal === :help
            _render_help_modal!(m, marea, buf)
        else
            _render_modal!(m, marea, buf)
        end
    end
    _render_hover!(m, buf)
    _ui_finish!(buf)                  # les fonds et les couleurs exactes
end



# ---------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------

"""
    _render_status_bar(m, area, buf)

Top row: ressac badge + tempo + cycle phase bar + event count +
synth tab name (if open), right-aligned mode/focus badge. Colours
come from the active Tachikoma theme so it respects the user's
`:theme` choice.
"""
function _render_status_bar(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    sched = m.scheduler
    # t_start can be 0 / NaN if the scheduler hasn't been started yet —
    # in either case "0 cycle phase" is the right default for the bar.
    raw_phase = sched.t_start > 0 ?
                ((time() - sched.t_start) * sched.cps) % 1.0 : 0.0
    cycle_phase = isnan(raw_phase) ? 0.0 : clamp(raw_phase, 0.0, 0.999)

    # Les quatre temps du cycle : pleins jusqu'au temps en cours.
    beat = sched.t_start > 0 ? floor(Int, cycle_phase * 4) + 1 : 0
    cycle_bar = "▮" ^ beat * "▯" ^ (4 - beat)

    p = _ui()
    band = p.s1
    on(c; bold = false) = TK.Style(fg = c, bg = band, bold = bold)
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width), TK.Style(bg = band))
    empty!(m._status_hits)
    m._status_y = area.y

    # ── À droite : ce qui joue ───────────────────────────────────────
    right = Tuple{String,TK.Style}[]
    add!(txt, sty) = push!(right, (txt, sty))
    # La ligne de commande occupe la ligne d'état : son mode se dit ici.
    let mode = _current_mode_symbol(m)
        mode in (:command, :search) &&
            (add!(" " * _MODE_LABELS_FR[mode] * " ", _chip(_ui_rgb(_mode_color(m)))); add!("   ", on(p.tx)))
    end
    m.zoom_leaf != 0 && (add!("ZOOM", on(p.o; bold = true)); add!("   ", on(p.tx)))
    if m.recording
        secs = floor(Int, time() - m.recording_start_ts)
        mins, s = divrem(secs, 60)
        add!(" REC $(lpad(mins, 2, '0')):$(lpad(s, 2, '0')) ", _chip(p.r)); add!("   ", on(p.tx))
    end
    if m.loop !== nothing
        n = length(m.loop.hits)
        add!(" BOUCLE $(m.loop.slot) ", _chip(p.r))
        add!(" $n frappe$(n == 1 ? "" : "s") · o ferme   ", on(p.r))
    end
    if m.tap_recording
        label = m.tap_mode === :tempo ? "TAP-TEMPO" :
                m.tap_mode === :loop  ? "TAP-LOOP" :
                m.tap_bars > 1        ? "TAP×$(m.tap_bars) bars" : "TAP"
        n = length(m.tap_events)
        add!(" $label ", _chip(p.y)); add!(" $(n) hit$(n == 1 ? "" : "s")   ", on(p.y))
    end
    if m.test_note !== nothing && _synth_pane_open(m)
        add!("♪ T=$(_note_name(m.test_note))   ", on(p.o; bold = true))
    end
    if m.piano_active
        label = m.piano_rec ? "PIANO REC" : "PIANO"
        add!(" $label ", _chip(p.y)); add!(" oct=$(m.piano_octave) [$(length(m.piano_events))]   ", on(p.y))
    end
    if m.visual_active && (ved = _active_editor(m)) !== nothing
        r1 = min(m.visual_anchor_row, ved.cursor_row)
        r2 = max(m.visual_anchor_row, ved.cursor_row)
        n = r2 - r1 + 1
        add!(m.visual_kind === :char ?
             "VISUAL CHAR $(m.visual_anchor_row):$(m.visual_anchor_col)→$(ved.cursor_row):$(ved.cursor_col)   " :
             "VISUAL LINE $r1-$r2 ($n line$(n == 1 ? "" : "s"))   ", on(p.o; bold = true))
    end
    # Tempo : BPM suppose 4 temps par cycle (la convention de Tidal).
    bpm = round(Int, sched.cps * 4 * 60)
    add!("♪ $(round(sched.cps; digits = 2)) cps", on(p.n)); add!(" · ", on(p.x))
    add!("$(bpm)", on(p.tx; bold = true)); add!(" bpm   ", on(p.d))
    add!("▮"^beat, on(p.o)); add!("▮"^(4 - beat), on(p.x)); add!("   ", on(p.tx))
    add!("cycle $(sched.t_start > 0 ? _cycle_index(sched) : 0)", on(p.d)); add!("   ", on(p.tx))
    # SuperCollider répond-il ? (Rien tant qu'on ne peut pas le savoir.)
    sc = _sc_state()
    sc === :alive  && (add!("● SC", on(p.g; bold = true)); add!("   ", on(p.tx)))
    sc === :silent && (add!("○ SC ne répond pas — `just audio`", on(p.r; bold = true)); add!("   ", on(p.tx)))
    aud = _AUDIO_SETTINGS[]
    if aud !== nothing && !isempty(aud.casque)
        add!(aud.preview ? "◖ casque · essais" : "◖ casque", on(aud.preview ? p.v : p.d)); add!(" ", on(p.tx))
    end

    # ── À gauche : le nom, puis ce qui est ouvert ────────────────────
    x = area.x
    xmax = area.x + area.width - 1
    put!(txt, sty) = begin
        room = xmax - x + 1
        room <= 0 && return
        t = textwidth(txt) > room ? first(txt, room) : txt
        TK.set_string!(buf, x, area.y, t, sty); x += textwidth(t)
    end
    # La pastille RESSAC ouvre l'aide.
    put!(" RESSAC ", _chip(p.o))
    push!(m._status_hits, (area.x, area.x + 7, () -> _open_help!(m)))
    put!(" ", on(p.tx))
    fb = _focused_buffer(m)
    tab(label, active; mark = "") = begin
        sty = active ? TK.Style(fg = p.tx, bg = p.bg, bold = true) : on(p.n)
        put!(" " * label, sty)
        isempty(mark) || put!(" " * mark, active ? TK.Style(fg = p.o, bg = p.bg, bold = true) : on(p.o))
        put!(" ", sty); put!(" ", on(p.tx))
    end
    tab(_session_label(m), fb !== nothing && fb.role === :patterns)
    syn = _all_synth_buffers(m)
    cur = _current_synth_tab(m)
    for (_, b) in syn
        tab("♬ " * b.name, fb === b || (fb === nothing && cur === b))
    end

    # La droite se pose depuis le bord ; elle cède devant la gauche.
    rw = sum(textwidth(t) for (t, _) in right; init = 0)
    while !isempty(right) && area.x + area.width - rw < x + 1
        rw -= textwidth(popfirst!(right)[1])
    end
    rx = area.x + area.width - rw
    for (t, sty) in right
        TK.set_string!(buf, rx, area.y, t, sty); rx += textwidth(t)
    end
end

# ── Mode info — colour-coded per-mode strip ─────────────────────────
#
# Every editor / global mode maps to a Tachikoma style so the mode
# strip AND the focused-pane border share one accent colour. Picked
# the existing semantic palette so themes carry through.

const _MODE_LABELS_FR = Dict{Symbol,String}(
    :normal => "NORMAL", :insert => "INSERTION", :visual => "VISUEL",
    :command => "COMMANDE", :search => "RECHERCHE", :pane => "PANE",
)
const _PANE_LABELS_FR = Dict{Symbol,String}(
    :explorer => "EXPLORER", :waveform => "ONDE", :sculpt => "SCULPT",
    :log => "JOURNAL", :doc => "DOC", :wiki => "WIKI", :notes => "NOTES", :tuning => "GAMME",
)
const _MODAL_LABELS_FR = Dict{Symbol,String}(
    :modal_help => "AIDE", :modal_text => "TEXTE", :modal_browse => "SONS",
    :modal_lib => "LIBRAIRIE", :modal_snippets => "SNIPPETS", :modal_patterns => "PATTERNS", :listing => "LISTE", :modal_evolve => "VARIATIONS", :modal_palette => "PALETTE",
    :modal_mixer => "MIXER", :modal_sccode => "SCCODE",
)

"""
    _surface_label(m) -> String

Nom de la surface focalisée pour la status line : le modal ouvert, la
pane éditeur (PATTERNS / SYNTH · nom) ou la pane (EXPLORER, ONDE…).
"""
function _surface_label(m::RessacApp)
    m.modal !== :none && return get(_MODAL_LABELS_FR, modal_scope(m), uppercase(String(m.modal)))
    pane = _focused_pane_impl(m)
    pane === nothing && return "—"
    if pane isa EditorPane
        b = _focused_buffer(m)
        b === nothing && return "ÉDITEUR"
        return b.role === :patterns ? "PATTERNS" : "SYNTH · $(b.name)"
    end
    ps = pane_scope(pane)
    return get(_PANE_LABELS_FR, ps, uppercase(String(ps)))
end

const _MODE_COLORS = (
    normal  = :accent,
    insert  = :success,
    visual  = :title,
    command = :warning,
    search  = :warning,
    pane    = :error,
)


"""
    _current_mode_symbol(m) -> Symbol

Resolve the currently-active mode using the same precedence as the
mode strip + focus border:

  1. pane mode (Ctrl-W) wins (most specific gesture)
  2. CommandLine :command / :search
  3. editor visual mode
  4. editor :normal / :insert
"""
function _current_mode_symbol(m::RessacApp)
    _PANE_MODE.active && return :pane
    m.command_line.mode === :command && return :command
    m.command_line.mode === :search  && return :search
    m.visual_active && return :visual
    ed = _active_editor(m)
    return ed === nothing ? :normal : ed.mode   # no editor → neutral NORMAL
end

# Couleur (du thème) du mode courant — cadre de la pane focalisée, badge.
_mode_color(m::RessacApp) = getfield(TK.theme(), get(_MODE_COLORS, _current_mode_symbol(m), :accent))
# Bandeau de chrome (status line, barre de touches) : texte sur la couleur
# de bordure du thème. Un style sans fond posé dessus prend le bandeau.
_band_style(; fg = TK.theme().text, bold = false) = TK.Style(fg = fg, bg = TK.theme().border, bold = bold)
_on_band(sty::TK.Style) = sty.bg isa TK.NoColor ?
    TK.Style(fg = sty.fg, bg = TK.theme().border, bold = sty.bold, dim = sty.dim, italic = sty.italic) : sty


"""
    _keybar_layers(m) -> (layers, prefix)

Couches du registre à afficher dans la barre de touches selon le
contexte : modal ouvert, leader Space, mode pane, tap/piano/visuel,
insertion, pane focalisée (+ global), éditeur (rôle + éditeur + global).
"""
# La barre de touches : les gestes du mode d'abord (ce qu'on cherche en
# arrivant dans une pane), puis ceux de la pane, puis le global.
function _keybar_layers(m::RessacApp)
    pairs, prefix = _visible_layers(m)
    i = findfirst(((sc, _),) -> scope_layer(sc) === :mode, pairs)
    i === nothing || i == 1 || (p = pairs[i]; deleteat!(pairs, i); pushfirst!(pairs, p))
    return pairs, prefix
end

"""
    _render_footer(m, area, buf)

Barre de touches du bas, GÉNÉRÉE depuis le registre (app_keymap.jl et
les scopes des panes/modaux) : touche en :title, label en :text_dim,
coupée à la largeur. Un placeholder de snippet en cours a sa propre
ligne (Tab / S-Tab / Esc + compteur).
"""
function _render_footer(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    p = _ui()
    band = p.s1
    on(c; bold = false) = TK.Style(fg = c, bg = band, bold = bold)
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width), TK.Style(bg = band))
    empty!(m._keybar_hits)
    m._keybar_y = area.y
    # À gauche : le mode (pastille de sa couleur), puis où l'on est.
    x = area.x
    mode = " " * _MODE_LABELS_FR[_current_mode_symbol(m)] * " "
    TK.set_string!(buf, x, area.y, mode, _chip(_ui_rgb(_mode_color(m)))); x += textwidth(mode) + 2
    where_ = _surface_label(m)
    TK.set_string!(buf, x, area.y, where_, on(p.tx; bold = true)); x += textwidth(where_) + 2
    if m.modal === :none && (ed = _active_editor(m)) !== nothing
        pos = "$(ed.cursor_row):$(ed.cursor_col + 1)"
        TK.set_string!(buf, x, area.y, pos, on(p.n)); x += textwidth(pos) + 2
        # Sur une ligne vide : ce qu'on peut y créer.
        if (hint = _creation_hint(m)) !== nothing
            txt = first(hint, area.width ÷ 3)
            TK.set_string!(buf, x, area.y, txt, on(p.n)); x += textwidth(txt) + 2
        end
    end
    left_end = x
    # À droite : quatre touches au plus, puis « ? aide ». Le reste est dans
    # l'aide et dans le menu Espace.
    entries = if m.placeholder_active
        NamedTuple[(key = k, label = l, binding = nothing, target = nothing) for (k, l) in
                   [("Tab", "suivant"), ("S-Tab", "précédent"), ("Esc", "sortir"),
                    ("$(m.placeholder_idx)/$(length(m.placeholder_cols))", "placeholders")]]
    else
        layers, prefix = _keybar_layers(m)
        hint_entries(layers; prefix = prefix)
    end
    entries = [e for e in entries if e.key != "?"]
    pin = "? aide "
    right = area.x + area.width - textwidth(pin)
    if right > left_end + 4
        TK.set_string!(buf, right, area.y, "?", on(p.tx; bold = true))
        TK.set_string!(buf, right + 1, area.y, " aide ", on(p.d))
        push!(m._keybar_hits, (right, right + textwidth(pin) - 1, () -> _open_help!(m)))
    else
        right = area.x + area.width
    end
    if m.modal !== :none
        cmd = ": commande"
        right -= textwidth(cmd) + 3
        if right > left_end
            TK.set_string!(buf, right, area.y, ":", on(p.tx; bold = true))
            TK.set_string!(buf, right + 1, area.y, " commande", on(p.d))
            push!(m._keybar_hits, (right, right + textwidth(cmd), () -> enter!(m.command_line, :command)))
        end
    end
    # Les touches se posent de droite à gauche, dans l'ordre du registre.
    shown = NamedTuple[]
    budget = right - left_end - 3
    limit = m.modal === :none ? 6 : 8
    for e in entries
        length(shown) >= limit && break
        w = textwidth(e.key) + (isempty(e.label) ? 0 : 1 + textwidth(e.label)) + 3
        w > budget && break
        budget -= w
        push!(shown, e)
    end
    total = sum(textwidth(e.key) + (isempty(e.label) ? 0 : 1 + textwidth(e.label)) + 3 for e in shown; init = 0)
    x = right - total
    for e in shown
        w = textwidth(e.key) + (isempty(e.label) ? 0 : 1 + textwidth(e.label))
        let e = e, x0 = x, x1 = x + w - 1
            e.binding === nothing ||
                push!(m._keybar_hits, (x0, x1, () -> click_binding!(e.binding, e.target)))
        end
        TK.set_string!(buf, x, area.y, e.key, on(p.tx; bold = true)); x += textwidth(e.key)
        if !isempty(e.label)
            TK.set_string!(buf, x, area.y, " " * e.label, on(p.d)); x += 1 + textwidth(e.label)
        end
        x += 3
    end
end

"""
    _render_logs(m, area, buf)

Le journal du bas : les lignes colorées par niveau (`_log_spans`) dans
le ScrollPane `m.log_view`, qui suit le bas et garde la position quand
on remonte (touches, molette, barre).
"""
function _render_logs(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    TK.set_content!(m.log_view, _log_spans(m.logs))
    TK.render(m.log_view, area, buf)
    return
end

"""
    _render_synth_library_modal!(m, area, buf)

Centered list of `_SYNTH_LIBRARY` entries. Each row shows the synth
name, its category, and the one-line description. Cursor row inverted
so the user can see what Enter will instantiate.
"""

function _push_app_log!(m::RessacApp, line::AbstractString)
    # Flatten embedded newlines & carriage returns to a visible glyph
    # so a multi-line message (a Julia stacktrace, a ParseError diagram)
    # stays inside its log row instead of pushing the rest of the layout
    # down. Also trim trailing whitespace so collapsed-glyph runs don't
    # leave dangling separators.
    s = rstrip(replace(replace(String(line), "\r\n" => " ↩ "), "\n" => " ↩ "))
    # Dedupe consecutive identical entries — if the same line is being
    # pushed repeatedly (key-repeat on T, autofiring scope updates, …),
    # collapse to "<line>  ×N" in place rather than letting the buffer
    # fill with copies. Match against the rendered form so the run-count
    # suffix doesn't itself defeat the comparison.
    if !isempty(m.logs)
        last = m.logs[end]
        prev_base, prev_count = _split_log_count(last)
        if prev_base == s
            m.logs[end] = "$s  ×$(prev_count + 1)"
            return
        end
    end
    push!(m.logs, s)
    length(m.logs) > 200 && popfirst!(m.logs)
end

function _split_log_count(line::AbstractString)
    mt = match(r"^(.*?)\s+×(\d+)$", line)
    mt === nothing && return (String(line), 1)
    return (String(mt.captures[1]), parse(Int, mt.captures[2]))
end

"""
    _copy_logs_to_clipboard!(m)

Pipe the current log buffer to a clipboard tool so the user can paste
elsewhere (we're inside a TUI capturing mouse, so terminal-native
selection requires Shift-drag and is finicky — this is the reliable
path). Tries wl-copy (Wayland) first, falls back to xclip (X11) and
xsel; reports which one worked, or what failed.
"""
function _copy_logs_to_clipboard!(m::RessacApp)
    text = join(m.logs, "\n")
    for (name, argv) in (
        ("wl-copy", `wl-copy`),
        ("xclip",   `xclip -selection clipboard`),
        ("xsel",    `xsel --clipboard --input`),
    )
        Sys.which(name) === nothing && continue
        try
            open(pipeline(argv; stderr=devnull), "w") do io
                write(io, text)
            end
            _push_app_log!(m, "[INFO] $(length(m.logs)) lignes de journal → presse-papier ($name)")
            return
        catch err
            _push_app_log!(m, "[WARN] $name a échoué : $(sprint(showerror, err))")
        end
    end
    _push_app_log!(m, "[ERROR] :copylogs — aucun outil de presse-papier (installe wl-copy, xclip ou xsel)")
end

# ── Which-key ──────────────────────────────────────────────────────
const _WHICHKEY_DELAY_S = 0.3

"""
    _whichkey_state(m) -> (kind, prefix, layers, immediate)

Préfixe en attente : `:leader` (Space, immédiat), `:g` (g de l'éditeur,
après délai), `:pane_mode` (Ctrl-w, après délai), ou `:none`.
"""
function _whichkey_state(m::RessacApp)
    m.modal !== :none && return (:none, "", (), false)
    layers, prefix = _visible_layers(m)
    isempty(prefix) && return (:none, "", (), false)
    kind = prefix == "Space" ? :leader : prefix == "Ctrl-w" ? :pane_mode : prefix == "&" ? :atelier : :g
    return (kind, prefix, layers, prefix == "Space" || prefix == "&")
end

"""
    _render_whichkey!(m, area, buf)

Popup which-key ancré en bas à droite de `area` : une ligne par suite
possible du préfixe (« d  slot @dN »), sur 1 à 3 colonnes selon le
nombre. Met à jour `prefix_kind` / `prefix_since` (la vue est appelée
à chaque frame, c'est notre horloge).
"""
function _render_whichkey!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    kind, prefix, layers, immediate = _whichkey_state(m)
    if kind !== m.prefix_kind
        m.prefix_kind = kind
        m.prefix_since = time()
    end
    kind === :none && return
    immediate || time() - m.prefix_since >= _WHICHKEY_DELAY_S || return
    entries = Tuple{String,String}[]
    seen = Set{String}()
    for (scope, target) in layers
        for (k, b) in prefix_bindings(scope, prefix; target = target)
            k in seen && continue
            push!(seen, k); push!(entries, (k, hint_label(b)))
        end
    end
    isempty(entries) && return
    p = _ui()
    # Les suites rangées en colonnes titrées (le menu Espace des patterns),
    # ou d'un seul tenant pour les autres préfixes.
    groups = Pair{String,Vector{Tuple{String,String}}}[]
    if kind === :leader && any(((sc, _),) -> sc === :leader, layers)
        left = copy(entries)
        for (title, keys) in _LEADER_COLUMNS
            got = Tuple{String,String}[]
            for c in keys
                i = findfirst(e -> e[1] == string(c), left)
                i === nothing || push!(got, popat!(left, i))
            end
            isempty(got) || push!(groups, title => got)
        end
        isempty(left) || push!(groups, "AUTRES" => left)
    else
        push!(groups, "" => entries)
    end
    kw = maximum(textwidth(k) for (k, _) in entries)
    cw = min(maximum(textwidth(l) for (_, l) in entries) + kw + 5, 30)
    maxcols = max(1, (area.width - 4) ÷ cw)
    titled = any(g -> !isempty(g.first), groups)
    # Autant de lignes qu'il en faut pour que tout tienne en largeur.
    nrow = 4
    while sum(cld(length(g.second), nrow) for g in groups) > maxcols && nrow < area.height - 5
        nrow += 1
    end
    h = min(area.height - 1, nrow + 3 + (titled ? 1 : 0))
    h < 3 && return
    rect = TK.Rect(area.x, area.y + area.height - h, area.width, h)
    _clear_rect!(buf, rect)
    _surface!(rect, p.s2)
    _band!(buf, rect.x, rect.y, rect.width, prefix == "Space" ? "ESPACE" : "$prefix + …";
           right = "une touche choisit · Échap ne fait rien", focus = p.o, bg = p.s3)
    col = 0
    y0 = rect.y + 2 + (titled ? 1 : 0)
    for (title, items) in groups
        x = rect.x + 2 + col * cw
        titled && TK.set_string!(buf, x, rect.y + 2, first(title, cw - 1), TK.Style(fg = p.n))
        for (i, (k, l)) in enumerate(items)
            c, row = divrem(i - 1, nrow)
            y = y0 + row
            y >= rect.y + rect.height && continue
            xx = x + c * cw
            xx + kw + 2 >= rect.x + rect.width && continue
            TK.set_string!(buf, xx, y, rpad(k, kw), TK.Style(fg = p.o, bold = true))
            TK.set_string!(buf, xx + kw + 2, y, first(l, max(0, cw - kw - 4)), TK.Style(fg = p.tx))
        end
        col += cld(length(items), nrow)
    end
    return
end
