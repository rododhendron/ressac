# src/app_view.jl
# Rendu : TK.view (layout chrome + arbre de panes + modal), status bar,
# strips de workspace/mode, livedoc, footer, journal (log tail) et
# _push_app_log!.

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
    border = focused ? TK.tstyle(:accent, bold = true) : TK.tstyle(:border)
    ttl    = focused ? TK.tstyle(:accent, bold = true) : TK.tstyle(:title, bold = true)
    # Right title can opt-in to accent (used for "live" indicators like
    # the active @dN slot list — it's the most action-relevant info
    # on screen and deserves to pop even on unfocused panes).
    right_style = title_right_accent ?
        TK.tstyle(:warning, bold = true) : TK.tstyle(:text_dim)
    block = TK.Block(
        title              = " " * String(title) * " ",
        title_right        = isempty(title_right) ? "" : " " * String(title_right) * " ",
        title_style        = ttl,
        title_right_style  = right_style,
        border_style       = border,
        box                = TK.BOX_ROUNDED,
        title_padding      = 0,
    )
    TK.render(block, rect, buf)
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
    _active_slots_summary(m) -> String

Compact list of slot ids currently scheduled, e.g. "@d1 @d2 @d4".
Empty string when nothing is playing. Goes in the patterns block title
so the user always sees what's live.
"""
function _active_slots_summary(m::RessacApp)
    slots = pattern_keys(m.scheduler)
    isempty(slots) && return ""
    sort!(slots;
          by = s -> try parse(Int, String(s)[2:end]) catch; 999 end)
    join(("@" * String(s) for s in slots), " ")
end


"""
    _render_global_log_tail!(m, area, buf)

Render the global log tail (or the completion picker when active)
into `area`. Extracted from `view()` so the new workspace dispatcher
(sub-project 10) can call it as a chrome row independently of the
workspace area. Behavior-preserving extraction — no visible change.
"""
function _render_global_log_tail!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    if _completion_picker_active(m)
        title       = "COMPLÉTIONS"
        title_right = "$(m.completion_idx)/$(length(m.completion_candidates)) · Tab suivant · autre touche annule"
    else
        title       = "JOURNAL"
        title_right = "$(length(m.logs))" *
                      (m.log_scroll > 0 ? " · ↑$(m.log_scroll)" : "")
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
_rect_to_nt(r::TK.Rect)     = (x = r.x, y = r.y, w = r.width, h = r.height)

"""
    _render_tree!(node, rects, buf, m)

Walk the workspace tree and call each leaf's render! against its
computed rect. Containers recurse. As a side effect, populates
`_focused_editor_rect(m)` from the leaf currently holding `_active_editor(m)`
(via its EditorPane wrapper) so legacy overlay paths (eval flash,
playhead, ghost) and the mouse handler keep working until Task 6
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
                render!(pane, rect, buf)
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
        render!(f.pane, TK.Rect(f.x, f.y, f.w, f.h), buf)
    end
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
    return m.log_tail_rows + 2          # + les deux bordures
end

# `:log` : bascule le journal du bas 3 → 10 → 0 → 3 lignes ; `:log N` fixe.
function _cycle_log_tail!(m::RessacApp, n::Union{Nothing,Int} = nothing)
    m.log_tail_rows = n !== nothing ? clamp(n, 0, 30) :
                      m.log_tail_rows == 3 ? 10 : m.log_tail_rows == 10 ? 0 : 3
    m.log_scroll = 0
    _push_app_log!(m, m.log_tail_rows == 0 ? "[INFO] journal replié (:log pour le rouvrir · :copylogs copie tout)" :
                                             "[INFO] journal : $(m.log_tail_rows) lignes")
    return
end

function TK.view(m::RessacApp, f::TK.Frame)
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

    # Workspace area — dispatched through _compute_rects. Cached on
    # the model so the mouse handler can hit-test workspace leaves
    # without re-deriving chrome heights.
    if ws_height > 0
        ws_nt = (x = area.x, y = ws_y, w = area.width, h = ws_height)
        m._last_ws_area = ws_nt
        ws = current_workspace(m.workspaces)
        if ws !== nothing
            # Un changement de focus dézoome (comme tmux).
            m.zoom_leaf != 0 && m.zoom_leaf != ws.focused_pane && (m.zoom_leaf = 0)
            rects = _workspace_rects(m, ws, ws_nt)
            _render_tree!(ws.tree, rects, buf, m)
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
        if m.modal === :browse
            _render_browser_modal!(m, marea, buf)
        elseif m.modal === :synth_library
            _render_synth_library_modal!(m, marea, buf)
        elseif m.modal === :sccode
            _render_sccode_modal!(m, marea, buf)
        elseif m.modal === :snippets
            _render_snippets_modal!(m, marea, buf)
        elseif m.modal === :wiki
            _render_wiki_modal!(m, marea, buf)
        elseif m.modal === :mixer
            _render_mixer_modal!(m, marea, buf)
        elseif m.modal === :help
            _render_help_modal!(m, marea, buf)
        else
            _render_modal!(m, marea, buf)
        end
    end
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

    # Smooth gradient cycle bar — sub-cell precision via BARS_H glyphs.
    # Full cells use █, the partial cell uses a fractional bar glyph,
    # remaining cells use ░ (very dim). Reads as a clean sweep instead
    # of a chunky "filled/empty" toggle.
    bar_w = 12
    pos = cycle_phase * bar_w
    full = floor(Int, pos)
    frac = pos - full
    partial = frac == 0 ? "" : string(TK.BARS_H[clamp(ceil(Int, frac * 8), 1, 8)])
    rest = bar_w - full - (isempty(partial) ? 0 : 1)
    cycle_bar = "█" ^ full * partial * "░" ^ max(0, rest)

    # Sections — each is a tuple of (text, style). They get joined with
    # ` │ ` separators rendered in :text_dim so the eye groups them.
    sections = Vector{Vector{Tuple{String,TK.Style}}}()

    # Logo — pastille accent.
    push!(sections, [(" RESSAC ", _pill_style(:accent))])

    # Tempo / cycle / events section. BPM assumes 4 beats per cycle
    # (the SuperDirt / TidalCycles convention) so cps=0.5 → 120 BPM.
    bpm = round(Int, sched.cps * 4 * 60)
    tempo_section = Tuple{String,TK.Style}[
        ("♪ $(round(sched.cps; digits = 2)) cps", TK.tstyle(:title, bold = true)),
        (" · ", TK.tstyle(:text_dim)),
        ("$(bpm) bpm", TK.tstyle(:text_dim)),
        ("  ", TK.tstyle(:text)),
        ("◐ ", TK.tstyle(:text_dim)),
        (cycle_bar, TK.tstyle(:accent)),
        ("  ", TK.tstyle(:text)),
        ("✧ $(sched.events_shipped[])", TK.tstyle(:title)),
    ]
    push!(sections, tempo_section)

    # Mode (pastille de sa couleur) + surface focalisée.
    push!(sections, [(" " * _MODE_LABELS_FR[_current_mode_symbol(m)] * " ", _pill_style(_mode_color(m)))])
    push!(sections, [(_surface_label(m), TK.Style(fg = TK.theme().text_bright, bg = TK.theme().border, bold = true))])

    # Synth section (only if a synth pane is open)
    syn = _all_synth_buffers(m)
    if !isempty(syn)
        cur = _current_synth_tab(m)
        synth_label = "♬ $(cur === nothing ? "?" : cur.name)" *
                      (length(syn) > 1 ? " [$(length(syn))]" : "")
        push!(sections, [(synth_label, TK.tstyle(:title, bold = true))])
    end

    # Live-state section (rec / tap / piano / visual) — each gets a
    # priority colour so it pops against the normal title style.
    state_parts = Tuple{String,TK.Style}[]
    m.zoom_leaf != 0 && push!(state_parts, ("⤢ ZOOM", TK.tstyle(:accent, bold = true)))
    if m.recording
        secs = floor(Int, time() - m.recording_start_ts)
        mins, s = divrem(secs, 60)
        push!(state_parts,
            ("● REC $(lpad(mins, 2, '0')):$(lpad(s, 2, '0'))",
             TK.tstyle(:error, bold = true)))
    end
    if m.tap_recording
        label = m.tap_mode === :tempo ? "● TAP-TEMPO" :
                m.tap_mode === :loop  ? "● TAP-LOOP" :
                m.tap_bars > 1        ? "● TAP×$(m.tap_bars) bars" :
                                        "● TAP"
        n = length(m.tap_events)
        push!(state_parts,
            ("$label $(n) hit$(n == 1 ? "" : "s")",
             TK.tstyle(:warning, bold = true)))
    end
    if m.test_note !== nothing && _synth_pane_open(m)
        push!(state_parts, ("♪ T=$(_note_name(m.test_note))", TK.tstyle(:accent, bold = true)))
    end
    if m.piano_active
        label = m.piano_rec ? "● PIANO REC" : "♪ PIANO"
        push!(state_parts,
            ("$label oct=$(m.piano_octave) [$(length(m.piano_events))]",
             TK.tstyle(:warning, bold = true)))
    end
    if m.visual_active && (ved = _active_editor(m)) !== nothing
        r1 = min(m.visual_anchor_row, ved.cursor_row)
        r2 = max(m.visual_anchor_row, ved.cursor_row)
        n = r2 - r1 + 1
        if m.visual_kind === :char
            push!(state_parts,
                ("▌ VISUAL CHAR $(m.visual_anchor_row):$(m.visual_anchor_col)→$(ved.cursor_row):$(ved.cursor_col)",
                 TK.tstyle(:accent, bold = true)))
        else
            push!(state_parts,
                ("▌ VISUAL LINE $r1-$r2 ($n line$(n == 1 ? "" : "s"))",
                 TK.tstyle(:accent, bold = true)))
        end
    end
    isempty(state_parts) || push!(sections, state_parts)

    # ── Render —— left to right ────────────────────────────────────
    # Blank the row first so we don't leak previous-frame content
    # when sections shrink (e.g. recording stops).
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width), _band_style())
    empty!(m._status_hits)
    m._status_y = area.y
    # Workspaces, alignés à droite : le courant en pastille accent, les
    # autres en texte atténué sur le bandeau. Cliquables.
    wsx = area.x + area.width
    for (i, ws) in Iterators.reverse(collect(enumerate(m.workspaces.workspaces)))
        is_cur = i == m.workspaces.current_idx
        label = " " * (isempty(ws.name) ? "$i" : "$i $(ws.name)") * " "
        wsx -= textwidth(label)
        wsx <= area.x + 40 && break
        TK.set_string!(buf, wsx, area.y, label,
                       is_cur ? _pill_style(:accent) : _band_style(fg = TK.theme().text_dim))
        let idx = i
            push!(m._status_hits, (wsx, wsx + textwidth(label) - 1,
                                   () -> (cmd_workspace_switch!(m.workspaces, idx); _ensure_default_workspace!(m))))
        end
    end
    # La pastille RESSAC ouvre l'aide.
    push!(m._status_hits, (area.x, area.x + 7, () -> _open_help!(m)))
    sep = " "
    sep_style = _band_style()
    x = area.x
    xmax = wsx - 1                         # ne pas écraser les workspaces
    for (i, sec) in enumerate(sections)
        if i > 1
            x + textwidth(sep) > xmax && break
            TK.set_string!(buf, x, area.y, sep, sep_style)
            x += textwidth(sep)
        end
        for (txt, sty) in sec
            x + textwidth(txt) > xmax && (txt = first(txt, max(0, xmax - x)))
            isempty(txt) && break
            TK.set_string!(buf, x, area.y, txt, _on_band(sty))
            x += textwidth(txt)
        end
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
    :log => "JOURNAL", :doc => "DOC", :tuning => "GAMME",
)
const _MODAL_LABELS_FR = Dict{Symbol,String}(
    :modal_help => "AIDE", :modal_text => "TEXTE", :modal_browse => "SONS",
    :modal_lib => "LIBRAIRIE", :modal_snippets => "SNIPPETS", :modal_wiki => "WIKI",
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
    normal  = :primary,
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

"""
    _mode_style(mode; bold=false) -> TK.Style

Map a mode symbol to its accent style. Unknown modes fall back to
:accent so the UI never goes uncoloured.
"""
function _mode_style(mode::Symbol; bold::Bool = false)
    palette = get(_MODE_COLORS, mode, :accent)
    return TK.tstyle(palette, bold = bold)
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
function _keybar_layers(m::RessacApp)
    m.modal !== :none && return ((modal_scope(m), m),), ""
    m.pending_leader && return ((:leader, m),), "Space"
    _PANE_MODE.active && return ((:pane_mode, m),), "Ctrl-w"
    m.tap_recording && return ((:tap, m),), ""
    m.piano_active && return ((:piano, m),), ""
    m.visual_active && return ((:visual, m),), ""
    pane = _focused_pane_impl(m)
    if pane !== nothing && pane_scope(pane) !== :none
        return ((pane_scope(pane), pane), (:global, m)), ""
    end
    ed = _active_editor(m)
    ed === nothing && return ((:global, m),), ""
    ed.mode === :insert && return ((:insert, m),), ""
    return _editor_layers(m), ""
end

"""
    _render_footer(m, area, buf)

Barre de touches du bas, GÉNÉRÉE depuis le registre (app_keymap.jl et
les scopes des panes/modaux) : touche en :title, label en :text_dim,
coupée à la largeur. Un placeholder de snippet en cours a sa propre
ligne (Tab / S-Tab / Esc + compteur).
"""
function _render_footer(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width), _band_style())
    empty!(m._keybar_hits)
    m._keybar_y = area.y
    entries = if m.placeholder_active
        NamedTuple[(key = k, label = l, binding = nothing, target = nothing) for (k, l) in
                   [("Tab", "suivant"), ("S-Tab", "précédent"), ("Esc", "sortir"),
                    ("$(m.placeholder_idx)/$(length(m.placeholder_cols))", "placeholders")]]
    else
        layers, prefix = _keybar_layers(m)
        hint_entries(layers; prefix = prefix)
    end
    pairs = Tuple{String,String}[(e.key, e.label) for e in entries]
    th = TK.theme()
    sep_style = _band_style(fg = th.text_dim)
    key_style = _band_style(fg = th.text_bright, bold = true)
    txt_style = _band_style()
    # « ? aide » toujours visible, épinglé à droite ; retiré de la liste.
    # Sous un modal, « : commande » l'accompagne (la barre de commande
    # reste accessible). Sinon, la livedoc du mot sous le curseur prend
    # la partie droite (au plus la moitié de la largeur).
    keep = [e.key != "?" for e in entries]
    entries = entries[keep]; pairs = pairs[keep]
    pin = " ? aide "
    right = area.x + area.width - textwidth(pin)
    if right > area.x + 8
        TK.set_string!(buf, right, area.y, pin, _pill_style(:accent))
        push!(m._keybar_hits, (right, right + textwidth(pin) - 1, () -> _open_help!(m)))
    else
        right = area.x + area.width
    end
    if m.modal !== :none
        cmd = ": commande"
        right -= textwidth(cmd) + 3
        TK.set_string!(buf, right, area.y, ":", key_style)
        TK.set_string!(buf, right + 1, area.y, " commande  ", txt_style)
        push!(m._keybar_hits, (right, right + textwidth(cmd), () -> enter!(m.command_line, :command)))
    elseif (ld = _livedoc_under_cursor(m)) !== nothing
        word, doc = ld
        maxw = area.width ÷ 2
        txt = first("✎ " * word * " — " * doc, maxw)
        right -= textwidth(txt) + 3
        TK.set_string!(buf, right, area.y, "✎ ", txt_style)
        TK.set_string!(buf, right + 2, area.y, word, _band_style(fg = th.accent, bold = true))
        TK.set_string!(buf, right + 2 + textwidth(word), area.y,
                       first(" — " * doc, max(0, textwidth(txt) - 2 - textwidth(word))), txt_style)
        TK.set_string!(buf, right + textwidth(txt), area.y, "   ", txt_style)
    end
    x = area.x + 1
    for (i, (k, t)) in enumerate(pairs)
        chunk_w = textwidth(k) + (isempty(t) ? 0 : 1 + textwidth(t))
        x + chunk_w + (i == 1 ? 0 : 3) > right - 2 && break
        if i > 1
            TK.set_string!(buf, x, area.y, " · ", sep_style)
            x += 3
        end
        # Le morceau « touche libellé » est un bouton : clic = la touche.
        let e = entries[i], x0 = x, x1 = x + chunk_w - 1
            e.binding === nothing ||
                push!(m._keybar_hits, (x0, x1, () -> click_binding!(e.binding, e.target)))
        end
        TK.set_string!(buf, x, area.y, k, key_style)
        x += textwidth(k)
        if !isempty(t)
            TK.set_string!(buf, x, area.y, " " * t, txt_style)
            x += 1 + textwidth(t)
        end
    end
end

"""
    _render_logs(m, area, buf)

Bottom-of-screen log tail with per-level colouring: ERROR in red,
WARN in yellow, INFO in dim text, KEY in accent. Lets the user scan
output by colour rather than parsing every line.
"""
function _render_logs(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    # log_scroll = lines to skip from the bottom. Clamped so we can't
    # scroll past the last entry.
    n = length(m.logs)
    max_scroll = max(0, n - area.height)
    m.log_scroll = clamp(m.log_scroll, 0, max_scroll)
    last_idx = n - m.log_scroll
    first_idx = max(1, last_idx - area.height + 1)
    tail = first_idx <= last_idx ? m.logs[first_idx:last_idx] : String[]
    for (i, line) in enumerate(tail)
        i > area.height && break
        # Severity → (stripe colour, text colour). The stripe is a
        # single ▎ glyph that paints a thin coloured edge on the left
        # so the eye can scan ERROR / WARN at a glance without parsing
        # the prefix tag. INFO and bare lines get a dim stripe to keep
        # the visual rhythm consistent.
        stripe_style, text_style, body = if startswith(line, "[ERROR]")
            (TK.tstyle(:error, bold = true), TK.tstyle(:error),
             SubString(line, 8))
        elseif startswith(line, "[WARN]")
            (TK.tstyle(:warning, bold = true), TK.tstyle(:warning),
             SubString(line, 7))
        elseif startswith(line, "[KEY]")
            (TK.tstyle(:accent, dim = true), TK.tstyle(:accent, dim = true),
             SubString(line, 6))
        elseif startswith(line, "[INFO]")
            (TK.tstyle(:text_dim), TK.tstyle(:text),
             SubString(line, 7))
        else
            (TK.tstyle(:text_dim), TK.tstyle(:text_dim), SubString(line, 1))
        end
        y = area.y + i - 1
        TK.set_string!(buf, area.x, y, "▎", stripe_style)
        # Pad one column after the stripe for legibility.
        TK.set_string!(buf, area.x + 2, y,
                       first(strip(body), max(0, area.width - 2)), text_style)
    end
    # Tiny scroll indicator in the last column when not at the bottom.
    m.log_scroll > 0 && TK.set_string!(buf,
        area.x + area.width - 1, area.y, "↑", TK.tstyle(:warning, bold = true))
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
    m.pending_leader && return (:leader, "Space", ((:leader, m),), true)
    _PANE_MODE.active && return (:pane_mode, "Ctrl-w", ((:pane_mode, m),), false)
    ed = _active_editor(m)
    if ed !== nothing && ed.mode === :normal && ed.pending_key == 'g' &&
       _focused_pane_impl(m) isa EditorPane
        return (:g, "g", _editor_layers(m), false)
    end
    return (:none, "", (), false)
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
    n = length(entries)
    kw = maximum(textwidth(k) for (k, _) in entries)
    cells = String[rpad(k, kw) * "  " * l for (k, l) in entries]
    cw = min(maximum(textwidth, cells), 30) + 2
    ncol = n > 16 ? 3 : n > 8 ? 2 : 1
    ncol = max(1, min(ncol, (area.width - 4) ÷ cw))
    nrow = cld(n, ncol)
    w = min(area.width - 2, ncol * cw + 2)
    h = min(area.height - 1, nrow + 2)
    h < 3 && return
    x0 = area.x + area.width - w - 1
    y0 = area.y + area.height - h
    rect = TK.Rect(x0, y0, w, h)
    inner = _inner_rect(rect)
    blank = " " ^ inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    TK.render(TK.Block(title = " $prefix + … ", title_style = _pill_style(:accent),
                       border_style = TK.tstyle(:accent), box = TK.BOX_ROUNDED,
                       title_padding = 0), rect, buf)
    for (i, (k, l)) in enumerate(entries)
        col, row = divrem(i - 1, nrow)
        y = inner.y + row
        y >= inner.y + inner.height && continue
        x = inner.x + col * cw
        TK.set_string!(buf, x, y, rpad(k, kw), TK.tstyle(:title, bold = true))
        TK.set_string!(buf, x + kw + 2, y, first(l, max(0, cw - kw - 4)), TK.tstyle(:text))
    end
    return
end
