# src/app_view.jl
# Rendu : TK.view (layout chrome + arbre de panes + modal), status bar,
# strips de workspace/mode, livedoc, footer, journal (log tail) et
# _push_app_log!.

"""
    _render_livedoc_row(m, area, buf)

Pluto-style: look at the word under the cursor in the active editor,
look it up via `_lookup_livedoc`, render one line of doc in green.
Empty when no entry found.
"""
function _render_livedoc_row(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    # Always blank the row first so previous-frame content (e.g. an
    # ex command bar that's no longer active) doesn't leak through.
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width),
                   TK.tstyle(:text))
    ed = _active_editor(m)
    ed === nothing && return        # no editor → no word-under-cursor doc
    1 <= ed.cursor_row <= length(ed.lines) || return
    line_chars = ed.lines[ed.cursor_row]
    isempty(line_chars) && return
    # Find the word at cursor_col (0-based in Tachikoma's CodeEditor).
    col = clamp(ed.cursor_col + 1, 1, length(line_chars))
    word = _word_under_cursor_chars(line_chars, col)
    isempty(word) && return
    doc = _lookup_livedoc(word)
    doc === nothing && return
    # Two-tone row: word in accent, doc in plain text — makes the
    # word jump out so the eye can confirm what's being documented.
    prefix = "  ✎ "
    w = "$word"
    sep = " ──  "
    TK.set_string!(buf, area.x, area.y, prefix, TK.tstyle(:text_dim))
    x = area.x + length(prefix)
    TK.set_string!(buf, x, area.y, w, TK.tstyle(:accent, bold=true))
    x += length(w)
    TK.set_string!(buf, x, area.y, sep, TK.tstyle(:text_dim))
    x += length(sep)
    remaining = max(0, area.width - (x - area.x))
    TK.set_string!(buf, x, area.y,
                   first(String(doc), remaining),
                   TK.tstyle(:text))
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
    _render_workspace_strip!(m, area, buf)

Render workspace tabs at `area` (typically a single-row band at the
very top). The current workspace renders with the accent style,
others with text_dim. Untitled workspaces show as `[N]`.

Used by the workspace dispatcher in Task 5 — not yet called from
`view()` so this is a pure addition.
"""
function _render_workspace_strip!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    x = area.x
    for (i, ws) in enumerate(m.workspaces.workspaces)
        is_current = i == m.workspaces.current_idx
        label = isempty(ws.name) ? "[$i]" : "[$i: $(ws.name)]"
        style = is_current ?
            TK.tstyle(:accent, bold = true) :
            TK.tstyle(:text_dim)
        x + textwidth(label) > area.x + area.width && break
        TK.set_string!(buf, x, area.y, label, style)
        x += textwidth(label) + 1
    end
    # Pane mode hint — visible only while in pane mode. Spells out the
    # exit keys + the recognized ops so the user has a cheat sheet on
    # the strip itself.
    if _PANE_MODE.active
        hint = " · s/v split · hjkl or ←↓↑→ focus · c close · Esc/Enter/C-w exit"
        if x + textwidth(hint) <= area.x + area.width
            TK.set_string!(buf, x, area.y, hint,
                           TK.tstyle(:warning, bold = true))
        end
    end
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
        title       = "COMPLETIONS"
        title_right = "$(m.completion_idx)/$(length(m.completion_candidates)) · Tab next · any other key cancels"
    else
        title       = "LOG"
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
            render!(pane, rect, buf)
            # Focus indicator — repaint the border in the current
            # mode's colour so the accent + the mode strip stay in
            # sync. Overlay paths look up the focused leaf's rect on
            # demand via _focused_editor_rect(m) — no caching needed.
            node.id == focused_id &&
                _repaint_border_focused!(rect, buf, _mode_style(_current_mode_symbol(m); bold = true))
        end
        return
    end
    for child in node.children
        _render_tree_inner!(child, rects, buf, m, focused_id)
    end
end

"""
    _repaint_border_focused!(rect, buf)

Redraw the box-drawing characters of `rect`'s outline in `:accent`
style on top of the dim border that `_render_pane_block_simple!`
already drew. Chars stay the same — only the style attribute
changes — so the focus highlight survives any subsequent overlay
that respects existing chars.
"""
function _repaint_border_focused!(rect::TK.Rect, buf::TK.Buffer,
                                  style::TK.Style = TK.tstyle(:accent, bold = true))
    (rect.width < 2 || rect.height < 2) && return
    # Skip the top row — it carries the pane title which would be
    # erased if we overwrote here. Sides + bottom are enough signal.
    for y in 1:(rect.height - 2)
        TK.set_string!(buf, rect.x, rect.y + y, "│", style)
        TK.set_string!(buf, rect.x + rect.width - 1, rect.y + y, "│", style)
    end
    TK.set_string!(buf, rect.x, rect.y + rect.height - 1,
                   "└" * "─"^(rect.width - 2) * "┘", style)
    # Repaint corner pieces on the top to bridge sides → top border.
    TK.set_string!(buf, rect.x, rect.y, "┌", style)
    TK.set_string!(buf, rect.x + rect.width - 1, rect.y, "┐", style)
    return nothing
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
    ws = current_workspace(m.workspaces)
    ws === nothing && return 10
    for leaf in _all_leaves(ws.tree)
        for t in leaf.tabs
            t isa LogPane && return 0
        end
    end
    return 10
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
    cmdline_active = is_active(m.command_line)
    cmdline_h = cmdline_active ? 1 : 0
    log_h     = _global_log_tail_height(m)
    footer_h  = 1
    livedoc_h = 1
    mode_h    = 1
    strip_h   = 1
    status_h  = 1
    # Top chrome: tempo / state status bar.
    # Bottom chrome stack (top → bottom):
    #   workspace_strip · mode_strip · livedoc · command_bar? · footer · log
    status_y    = area.y
    log_y       = area.y + area.height - log_h
    footer_y    = log_y - footer_h
    cmdline_y   = footer_y - cmdline_h
    livedoc_y   = cmdline_y - livedoc_h
    mode_y      = livedoc_y - mode_h
    strip_y     = mode_y - strip_h
    ws_y        = status_y + status_h
    ws_height   = max(0, strip_y - ws_y)

    # Workspace area — dispatched through _compute_rects. Cached on
    # the model so the mouse handler can hit-test workspace leaves
    # without re-deriving chrome heights.
    if ws_height > 0
        ws_nt = (x = area.x, y = ws_y, w = area.width, h = ws_height)
        m._last_ws_area = ws_nt
        ws = current_workspace(m.workspaces)
        if ws !== nothing
            rects = _compute_rects(ws.tree, ws_nt)
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

    # Top chrome — tempo + state status bar.
    _render_status_bar(m, TK.Rect(area.x, status_y, area.width, status_h), buf)
    # Bottom chrome — workspace tabs + mode strip + livedoc + cmd + footer + log.
    _render_workspace_strip!(m, TK.Rect(area.x, strip_y,   area.width, strip_h),   buf)
    _render_mode_strip!(m,      TK.Rect(area.x, mode_y,    area.width, mode_h),    buf)
    _render_livedoc_row(m,      TK.Rect(area.x, livedoc_y, area.width, livedoc_h), buf)
    if cmdline_active
        render_bar!(m.command_line,
                    TK.Rect(area.x, cmdline_y, area.width, cmdline_h), buf)
    end
    _render_footer(m, TK.Rect(area.x, footer_y, area.width, footer_h), buf)
    if log_h > 0
        log_rect = TK.Rect(area.x, log_y, area.width, log_h)
        # When the CommandLine is showing completion candidates, the
        # log tail area becomes a picker — same chrome row, different
        # content. The user gets the candidate list right where the
        # log used to be, with no extra layout shift.
        if completion_active(m.command_line)
            _render_pane_block_simple!(log_rect, "COMPLETIONS", buf)
            render_picker!(m.command_line,
                           _inner_rect_simple(log_rect), buf)
        else
            _render_global_log_tail!(m, log_rect, buf)
        end
    end

    # Modal overlay sits on top of everything — BUT leaves the bottom row
    # free for a persistent command bar (toujours à disposition, même dans
    # un modal). `marea` = aire du modal moins cette ligne.
    if m.modal !== :none
        marea = TK.Rect(area.x, area.y, area.width, max(1, area.height - 1))
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
        elseif m.modal === :sculpt
            _render_sculpt_modal!(m, marea, buf)
        else
            _render_modal!(m, marea, buf)
        end
        _render_modal_cmdbar!(m, TK.Rect(area.x, area.y + area.height - 1,
                                         area.width, 1), buf)
    end
end

# Barre commande persistante au bas d'un modal : l'input quand elle est
# active, sinon un prompt `:` discret (+ raccourcis utiles selon le modal).
function _render_modal_cmdbar!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    if is_active(m.command_line)
        render_bar!(m.command_line, rect, buf)
    else
        hint = m.modal === :sculpt ?
            ": commande   ·   :w <nom> sauver · :synth <nom> jouer · :sculpt <nom>" :
            ": commande"
        TK.set_string!(buf, rect.x, rect.y, first(hint, rect.width), TK.tstyle(:text_dim))
    end
    return
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

    # Mode info moved to its own strip — status bar is pure
    # tempo + state info now.

    # Sections — each is a tuple of (text, style). They get joined with
    # ` │ ` separators rendered in :text_dim so the eye groups them.
    sections = Vector{Vector{Tuple{String,TK.Style}}}()

    # Logo section
    push!(sections, [("▓ RESSAC", TK.tstyle(:accent, bold = true))])

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
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width),
                   TK.tstyle(:text))
    sep = " │ "
    sep_style = TK.tstyle(:text_dim)
    x = area.x
    for (i, sec) in enumerate(sections)
        if i > 1
            x + textwidth(sep) > area.x + area.width && break
            TK.set_string!(buf, x, area.y, sep, sep_style)
            x += textwidth(sep)
        end
        for (txt, sty) in sec
            x + textwidth(txt) > area.x + area.width && (txt = first(txt,
                max(0, area.x + area.width - x)))
            isempty(txt) && break
            TK.set_string!(buf, x, area.y, txt, sty)
            x += textwidth(txt)
        end
    end
end

# ── Mode info — colour-coded per-mode strip ─────────────────────────
#
# Every editor / global mode maps to a Tachikoma style so the mode
# strip AND the focused-pane border share one accent colour. Picked
# the existing semantic palette so themes carry through.

const _MODE_COLORS = (
    normal  = :primary,
    insert  = :success,
    visual  = :title,
    command = :warning,
    search  = :warning,
    pane    = :error,
)

const _MODE_ORDER = (:normal, :insert, :visual, :command, :search, :pane)

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

"""
    _render_mode_strip!(m, area, buf)

Single-row horizontal mode indicator. Lists every mode in
`_MODE_ORDER`; the current one renders in its mode colour + bold,
the others dim. Replaces the old `⟪ MODE @ focus ⟫` badge — the
user sees ALL modes at once with the current one highlighted.
"""
function _render_mode_strip!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width),
                   TK.tstyle(:text))
    cur = _current_mode_symbol(m)
    sep_style = TK.tstyle(:text_dim)
    x = area.x
    sep = " · "
    for (i, mode) in enumerate(_MODE_ORDER)
        label = String(mode)
        if mode === cur
            label = uppercase(label)
        end
        chunk_w = textwidth(label)
        if i > 1
            x + textwidth(sep) > area.x + area.width && break
            TK.set_string!(buf, x, area.y, sep, sep_style)
            x += textwidth(sep)
        end
        x + chunk_w > area.x + area.width && break
        style = mode === cur ?
            _mode_style(mode; bold = true) :
            TK.tstyle(:text_dim)
        TK.set_string!(buf, x, area.y, label, style)
        x += chunk_w
    end
end

"""
    _render_footer(m, area, buf)

Bottom hints row. Keeps the per-context cheat-sheet but renders the
mode badge in `:accent` and the rest in `:text_dim` so the eye lands
on the mode first.
"""
function _render_footer(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    ed = _active_editor(m)
    # Context-aware hint sets — leader pending / placeholder active
    # win over the default key cheatsheet so the user sees what's
    # available at the moment they need it. Mode label is NOT
    # prefixed here — the status bar already shows ⟪ <MODE> @ … ⟫.
    hints = if m.pending_leader
        [(string(k), v) for (k, v) in _LEADER_LABELS]
    elseif m.placeholder_active
        [("Tab", "next"), ("S-Tab", "prev"), ("Esc", "exit"),
         ("$(m.placeholder_idx)/$(length(m.placeholder_cols))", "filling")]
    elseif ed !== nothing && ed.mode === :normal && _focused_role(m) === :patterns
        [("?", "help"), ("Space", "snippet"), ("e", "eval"),
         ("E", "eval-all"), ("i", "insert"), ("dd.", "repeat"),
         (":tap", "loop"), (":tutorial", "tour"), (":q", "quit")]
    elseif !_synth_pane_open(m)
        [("e", "eval"), ("i", "insert"), ("Esc", "normal"),
         (":synth", "<name>"), (":lib", "library"),
         (":tap", "loop"), (":wiki", "docs"), (":q", "quit")]
    elseif length(_all_synth_buffers(m)) > 1
        [("e", "eval"), ("T", "test"), ("Tab", "swap"),
         ("gt/gT", "cycle"), (":w", "save"), (":close", ""), (":back", "")]
    else
        [("e", "eval"), ("T", "test"), ("Tab", "swap"),
         (":w", "save"), (":back", "close"), (":q", "quit")]
    end
    x = area.x + 1
    sep_style = TK.tstyle(:text_dim)
    key_style = TK.tstyle(:title, bold = true)
    txt_style = TK.tstyle(:text_dim)
    for (i, (k, t)) in enumerate(hints)
        # Stop early if we'd overflow the row.
        chunk_w = textwidth(k) + (isempty(t) ? 0 : 1 + textwidth(t))
        if x + chunk_w + (i == length(hints) ? 0 : 3) > area.x + area.width
            break
        end
        if i > 1
            TK.set_string!(buf, x, area.y, " · ", sep_style)
            x += 3
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
            _push_app_log!(m, "[INFO] $(length(m.logs)) log lines → $name clipboard")
            return
        catch err
            _push_app_log!(m, "[WARN] $name failed: $(sprint(showerror, err))")
        end
    end
    _push_app_log!(m, "[ERROR] :copylogs — no clipboard tool found (install wl-copy, xclip, or xsel)")
end
