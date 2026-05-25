# New Tachikoma-based TUI for Ressac. Lives alongside the existing
# TerminalUserInterfaces.jl-based TUI during the migration. Entry point
# is `live2()` (parallel to `live()`); once feature parity is reached
# `live()` will switch over and the old `tui_*.jl` files get removed.
#
# Architecture: Elm (Model/update!/view). The Ressac scheduler + audio
# layer is unchanged — only the editor + viz layer is being replaced.

using Tachikoma
using Dates
const TK = Tachikoma

"""
    SynthTab

One open synth in the side panel. Holds the editable file name and a
CodeEditor with its own buffer + cursor. The side panel is open when
`RessacApp.synth_tabs` is non-empty.
"""
mutable struct SynthTab
    name::String
    editor::TK.CodeEditor
    # `:dsl` (the default for new tabs) — buffer holds Julia DSL code;
    # T evals the buffer as Julia and the @synth macro inside sends
    # the compiled SC to SuperCollider. `:sc` — legacy raw SuperCollider
    # SynthDef in the buffer; T ships the text verbatim.
    mode::Symbol
    SynthTab(name, editor; mode::Symbol=:dsl) = new(name, editor, mode)
end

"""
    _STARTER_BUFFER

Buffer text shown on first `live()` if no session is loaded. Doubles
as the minimal-but-runnable demo: 4-on-the-floor kick + closed hat +
clap on beat 3 + sub bass. The leading comments orient a first-time
user — they cover the four keys needed to actually play this back
(Esc, then E, then `m` to mute, then `:q` to quit), and point to
`:tutorial` for the interactive guide.
"""
const _STARTER_BUFFER = """
# Welcome to Ressac — press Esc, then E to play these patterns.
# Use m on a @dN line to mute · :tutorial for the 5-min tour · :q to quit.

cps!(0.5)
@d1 p"bd bd bd bd"
@d2 p"~ ~ cp ~"
@d3 p"hh hh hh hh" |> gain(0.4)
"""

"""
    RessacApp

Top-level Tachikoma model. Holds the live scheduler, a patterns
CodeEditor, an optional stack of synth tabs (side panel when
non-empty), and the focus toggle for keystroke routing.
"""

@kwdef mutable struct RessacApp <: TK.Model
    scheduler::Scheduler
    editor::TK.CodeEditor = TK.CodeEditor(;
        text     = _STARTER_BUFFER,
        # No `block=` here — view() wraps the patterns pane in its own
        # focus-aware Block (see _render_pane_block!) so adding one on
        # the editor itself would draw nested borders.
        focused  = true,
        tick     = 0,
        mode     = :normal,
    )
    synth_tabs::Vector{SynthTab} = SynthTab[]
    synth_tab_idx::Int           = 0      # 1-based; 0 when no tabs open
    focus::Symbol                = :patterns
    # Modal overlay state — `:none`, `:guide`, `:synth_guide`, `:browse`,
    # `:synth_library`.
    modal::Symbol                = :none
    modal_scroll::Int            = 0
    # Synth library picker state (only meaningful when modal === :synth_library).
    synthlib_cursor::Int         = 1
    # Snippet picker state (only meaningful when modal === :snippets).
    snip_cursor::Int             = 1
    snip_query::String           = ""
    snip_search_mode::Bool       = false
    # Active category tab — empty string = "all". Tab / Shift-Tab cycle.
    snip_category::String        = ""
    # Wiki state (only meaningful when modal === :wiki). Pages re-read
    # at every :wiki so editing a .md file in docs/wiki/ takes effect
    # without restarting.
    wiki_pages::Vector{_WikiPage} = _WikiPage[]
    wiki_idx::Int                = 1
    wiki_scroll::Int             = 0
    # Vim-style `.` repeat. We capture the text typed during the last
    # i/a/o-insert session and re-type it on `.` press.
    vim_in_insert::Bool          = false
    vim_insert_buf::String       = ""
    vim_last_insert::String      = ""
    # Normal-mode `.` repeat: track keystrokes whose combined effect
    # changed the buffer (dd, x, p, J, ...) so `.` can replay them.
    # `pending` accumulates keystrokes since the last buffer change;
    # whenever the buffer changes while in :normal, pending becomes
    # the new `last_normal`. `last_kind` picks which of last_insert /
    # last_normal `.` should replay.
    vim_pending_normal::Vector{TK.KeyEvent} = TK.KeyEvent[]
    vim_last_normal::Vector{TK.KeyEvent}    = TK.KeyEvent[]
    vim_last_kind::Symbol        = :none   # :insert, :normal, or :none
    # Visual-line mode. `V` enters; j/k/arrows extend selection;
    # d/y/c operate on the line range [min(anchor, cursor),
    # max(anchor, cursor)] then exit; Esc cancels without action.
    visual_active::Bool          = false
    visual_anchor_row::Int       = 1
    visual_anchor_col::Int       = 0
    # :line (capital V, whole-line yank/delete) or :char (lowercase v,
    # character-wise across rows). Default :line for backward compat.
    visual_kind::Symbol          = :line
    # Space-leader snippet expansion. `pending_leader` flips true after
    # Space in normal mode and waits for the trigger char; the trigger
    # expands a template that may contain $1, $2, … placeholders.
    # `placeholder_active` is then true while the user fills them, with
    # Tab navigating to the next position. All positions are tracked on
    # the same `placeholder_row` for now (every current template fits a
    # single line; multi-line would require a parallel `placeholder_rows`).
    pending_leader::Bool         = false
    placeholder_active::Bool     = false
    placeholder_row::Int         = 0
    placeholder_cols::Vector{Int} = Int[]
    placeholder_idx::Int         = 0
    # Post-eval flash — rows that were just evaluated (one per @dN
    # block). _render_eval_flash! paints them in :success for the
    # FLASH_DURATION_S window, fading toward the end.
    eval_flash_rows::Vector{Int} = Int[]
    eval_flash_ts::Float64       = 0.0
    # Mixer modal state — cursor for j/k navigation among active slots.
    mixer_cursor::Int            = 1
    # Playhead parse cache: per-row (line_hash, parsed-NamedTuple-or-nothing).
    # Skips the regex + body split when a line hasn't changed between
    # frames — at 120 fps with 40 visible lines that's ~5000 alloc/sec
    # of garbage we don't produce. Pruned each render to the visible
    # window so it stays bounded.
    playhead_cache::Dict{Int,Tuple{UInt64,Any}} = Dict{Int,Tuple{UInt64,Any}}()
    # sccode browser state (only meaningful when modal === :sccode).
    # `entries` is the list fetched from sccode.org; `page` is the page
    # number we're on; cursor is the highlighted row (1-based).
    sccode_entries::Vector{_SccodeEntry} = _SccodeEntry[]
    sccode_cursor::Int           = 1
    sccode_page::Int             = 1
    sccode_loading::Bool         = false
    # Live filter — substring match against title + id. Toggled with `/`;
    # chars append to query in search_mode, Esc exits search_mode but
    # keeps the filter, q closes the modal entirely.
    sccode_query::String         = ""
    sccode_search_mode::Bool     = false
    # Tag filter for `:sccode-tag <tag>` (URL ?tag=…). Empty = no tag.
    sccode_tag::String           = ""
    # Browser modal state (only meaningful when modal === :browse).
    browser_query::String        = ""
    browser_cursor::Int          = 1
    browser_filter::Symbol       = :all   # :all | :instruments | :samples | :synths
    browser_last_preview::Float64 = 0.0
    logs::Vector{String}         = ["[INFO] Ressac live (Tachikoma) — :q to quit, e to eval, :synth <name> to design a sound"]
    quit::Bool                   = false
    tick::Int                    = 0
    # Manual zoom for the wave scope. Two independent axes — Y for
    # amplitude (+ / - / =), X for time-window width (> / < / |). Both
    # default 1.0; >1 zooms in, <1 zooms out. Only meaningful while
    # scope is :wave and the user is in normal mode.
    scope_zoom::Float64          = 1.0       # Y / amplitude
    scope_zoom_x::Float64        = 1.0       # X / time
    # Tab-cycle autocomplete state. completion_idx 0 = no active cycle.
    # On first Tab: gather fuzzy-ranked candidates, replace word with [1].
    # On subsequent Tab presses (with no other intervening key): advance
    # to the next candidate, replace again. Any non-Tab key in insert
    # mode clears the cycle so the next Tab restarts from scratch.
    completion_candidates::Vector{String} = String[]
    completion_idx::Int          = 0
    completion_row::Int          = 0
    completion_range::Tuple{Int,Int} = (0, 0)   # (start_col, end_col) 0-based
    # :keydebug toggles a verbose-input mode that pushes every KeyEvent
    # received from the terminal to the log pane. Lets the user see the
    # exact symbol + char + action for any keystroke when diagnosing
    # layout or terminal issues.
    keydebug::Bool               = false
    # :pause freezes the render loop so the user can shift-drag-select
    # and copy text from the terminal without the next frame overwriting
    # the selection highlight. Any keypress (handled in update!) resumes.
    paused::Bool                 = false
    # Held-T acceleration state. last_t_fire = time() of the previous
    # `_test_current_synth!` call; t_hold_interval_ms = current wait
    # before the next fire (decays toward config.t_hold_min_ms).
    last_t_fire::Float64         = 0.0
    t_hold_interval_ms::Float64  = 0.0
    # WAV recording. Set when /ressac/recStart fires; cleared on stop.
    # Status bar reads this to show ● REC.
    recording::Bool              = false
    recording_path::String       = ""
    recording_start_ts::Float64  = 0.0
    # Layout rects refreshed every frame in view(). The mouse handler
    # uses these to map (x, y) → which pane was clicked and where.
    # nothing = the pane wasn't on screen on the last frame.
    layout_patterns::Union{Nothing,TK.Rect} = nothing
    layout_synth::Union{Nothing,TK.Rect}    = nothing
    layout_synth_tabs::Union{Nothing,TK.Rect} = nothing
    layout_scope::Union{Nothing,TK.Rect}    = nothing
    layout_logs::Union{Nothing,TK.Rect}     = nothing
    # Per-modal row → entry-index mapping built during render so the
    # mouse handler can resolve "click row N" → "select entry K".
    modal_rows::Vector{Tuple{Int,Int}}   = Tuple{Int,Int}[]  # (screen_y, entry_idx)
    # Log scroll offset (lines from the bottom). 0 = bottom, increases
    # backwards into history. Bumped by wheel events over the log pane.
    log_scroll::Int                      = 0
    # Tap-to-record rhythm. `:tap [sample] [steps]` enters this mode;
    # Space records a hit at the current time, Enter commits the
    # quantized pattern into the buffer, Esc cancels. Any other key is
    # swallowed so the user can focus on tapping.
    tap_recording::Bool                  = false
    tap_events::Vector{Float64}          = Float64[]
    tap_sample::String                   = "bd"
    tap_steps::Int                       = 16
    tap_bars::Int                        = 1            # play the same pattern N bars → average
    tap_mode::Symbol                     = :pattern     # :pattern or :tempo (cps from taps)
    # Piano mode — letter keys map to semitones, hitting one fires the
    # current synth at that pitch. `piano_rec` toggles recording so
    # Enter commits the played notes as `@dN :synth |> n(p"...")`.
    piano_active::Bool                   = false
    piano_rec::Bool                      = false
    piano_synth::String                  = "fmbell"
    piano_octave::Int                    = 4               # MIDI octave (4 ≈ A4 = 440Hz region)
    piano_events::Vector{Tuple{Float64,Int}} = Tuple{Float64,Int}[]
    piano_steps::Int                     = 16
    # Ghost autocomplete — a faded suggestion that follows the cursor in
    # insert mode. Tab accepts it (and bumps its usage count in the
    # global ranking). Computed on every insert keystroke from the
    # surrounding context.
    ghost::String                        = ""
    ghost_row::Int                       = 0
    ghost_col::Int                       = 0   # 0-based; the col AT which the suggestion would be inserted
end

# Kitty CSI u reports numpad keys with their own :kp_<n> symbol instead
# of a :char event, so the CodeEditor (which only inserts on :char) drops
# them silently. Translate the numpad symbol set into the equivalent
# printable char + :char key so the editor handles them like regular
# digit / punctuation keystrokes.
const _NUMPAD_TO_CHAR = Dict{Symbol,Char}(
    :kp_0 => '0', :kp_1 => '1', :kp_2 => '2', :kp_3 => '3', :kp_4 => '4',
    :kp_5 => '5', :kp_6 => '6', :kp_7 => '7', :kp_8 => '8', :kp_9 => '9',
    :kp_decimal => '.', :kp_divide => '/', :kp_multiply => '*',
    :kp_subtract => '-', :kp_add => '+', :kp_equal => '=',
    :kp_separator => ',',
)

function _normalise_event(evt::TK.KeyEvent)
    c = get(_NUMPAD_TO_CHAR, evt.key, nothing)
    c === nothing && return evt
    return TK.KeyEvent(:char, c, evt.action)
end

"""
    _active_editor(m) -> CodeEditor

The currently-focused editor (patterns OR active synth tab).
"""
function _active_editor(m::RessacApp)
    if m.focus === :synth && !isempty(m.synth_tabs)
        return m.synth_tabs[m.synth_tab_idx].editor
    end
    return m.editor
end

_synth_pane_open(m::RessacApp) = !isempty(m.synth_tabs)
_current_synth_tab(m::RessacApp) = m.synth_tabs[m.synth_tab_idx]

TK.should_quit(m::RessacApp) = m.quit

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
    # Wheel — context-aware.
    if evt.button === TK.mouse_scroll_up || evt.button === TK.mouse_scroll_down
        _mouse_wheel!(m, evt)
        return
    end
    # Left-click routing.
    if evt.action === TK.mouse_press && evt.button === TK.mouse_left
        # Tab bar?
        if m.layout_synth_tabs !== nothing && _in_rect(m.layout_synth_tabs, evt.x, evt.y)
            _click_tab_bar!(m, evt.x); return
        end
        # Synth editor?
        if m.layout_synth !== nothing && _in_rect(m.layout_synth, evt.x, evt.y)
            m.focus = :synth; _refresh_focus_flags!(m)
            _click_into_editor!(_current_synth_tab(m).editor,
                                m.layout_synth, evt.x, evt.y); return
        end
        # Patterns editor?
        if m.layout_patterns !== nothing && _in_rect(m.layout_patterns, evt.x, evt.y)
            m.focus = :patterns; _refresh_focus_flags!(m)
            _click_into_editor!(m.editor, m.layout_patterns, evt.x, evt.y)
            return
        end
        # Scope panel click → cycle.
        if m.layout_scope !== nothing && _in_rect(m.layout_scope, evt.x, evt.y)
            _scope_cycle_key!(m); return
        end
    end
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
    # 1. Hover wheel-nudge in any editor.
    for (rect, ed) in ((m.layout_patterns, m.editor),
                       (m.layout_synth, _synth_pane_open(m) ?
                                        _current_synth_tab(m).editor : nothing))
        rect === nothing && continue
        ed === nothing && continue
        _in_rect(rect, evt.x, evt.y) || continue
        rc = _screen_to_editor_pos(ed, rect, evt.x, evt.y)
        rc === nothing && return
        row, col = rc
        if _try_nudge_at!(m, ed, row, col, sign * mag)
            return
        end
        return  # over editor but no number → don't fall through
    end
    # 2. Wheel over log pane → scroll log.
    if m.layout_logs !== nothing && _in_rect(m.layout_logs, evt.x, evt.y)
        m.log_scroll = max(0, m.log_scroll + sign)
        return
    end
    # 3. Wheel over scope → cycle.
    if m.layout_scope !== nothing && _in_rect(m.layout_scope, evt.x, evt.y)
        sign > 0 ? _scope_cycle_key!(m) : _scope_cycle_key!(m)
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
    _try_nudge_at!(m, ed, row, col, step) -> Bool

Find the numeric literal that COVERS the (row, col) coordinate and
nudge it by `step`. Returns true if a number was found and nudged.
Doesn't touch the keyboard cursor — useful for wheel-over-number
hover.
"""
function _try_nudge_at!(m::RessacApp, ed::TK.CodeEditor, row::Int, col::Int, step::Int)
    1 <= row <= length(ed.lines) || return false
    line = String(ed.lines[row])
    best = nothing
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        s - 1 <= col <= e && (best = mt; break)
    end
    best === nothing && return false
    txt = best.match
    s = best.offset
    e = s + length(txt) - 1
    is_float = occursin('.', txt)
    new_str = if is_float
        delta = abs(step) == 10 ? (step > 0 ? 0.1 : -0.1) : Float64(step)
        val = parse(Float64, txt) + delta
        dot = findfirst('.', txt)
        decimals = length(txt) - dot
        string(round(val; digits = decimals))
    else
        string(parse(Int, txt) + step)
    end
    new_line = (s > 1 ? line[1:s-1] : "") * new_str *
               (e >= lastindex(line) ? "" : line[e+1:end])
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    _push_app_log!(m, "[INFO] nudge $txt → $new_str  @ row $row")
    return true
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
    isempty(m.synth_tabs) && return
    rect = m.layout_synth_tabs
    rect === nothing && return
    rel = clamp(x - rect.x, 0, rect.width - 1)
    slot_w = max(4, rect.width ÷ length(m.synth_tabs))
    idx = clamp(rel ÷ slot_w + 1, 1, length(m.synth_tabs))
    m.synth_tab_idx = idx
    m.focus = :synth
    _refresh_focus_flags!(m)
end

"""
    _modal_click!(m, x, y)

Click in a modal — map y to the row that was rendered there and set
the appropriate cursor. We track the (screen_y → entry_idx) mapping
during render via m.modal_rows.
"""
function _modal_click!(m::RessacApp, x::Int, y::Int)
    isempty(m.modal_rows) && return
    for (yy, idx) in m.modal_rows
        if y == yy
            if m.modal === :synth_library
                m.synthlib_cursor = idx
            elseif m.modal === :snippets
                m.snip_cursor = idx
            elseif m.modal === :sccode
                m.sccode_cursor = idx
            end
            return
        end
    end
end

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    if m.keydebug
        _push_app_log!(m, "[KEY] $(evt.key) char=$(repr(evt.char)) action=$(evt.action)")
    end
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
    if m.modal !== :none
        # Modal navigation (j/k/up/down) wants key-repeat too so the user
        # can hold the key to scrub through a long list. Action keys
        # (Space preview, Enter load, q close, /search, ...) stay
        # press-only — we don't want Enter held to import 80 synths.
        is_nav = evt.char == 'j' || evt.char == 'k' ||
                 evt.key === :up || evt.key === :down
        if evt.action === TK.key_press ||
           (evt.action === TK.key_repeat && is_nav)
            _handle_modal_key!(m, evt)
        end
        return
    end
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
    if is_press && evt.key === :tab && ed.mode === :normal && _synth_pane_open(m)
        _swap_focus!(m)
        return
    end
    # gt / gT cycle synth tabs while focused on the synth pane.
    if is_press && ed.mode === :normal &&
       m.focus === :synth && length(m.synth_tabs) > 1
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
    # Intercept our normal-mode actions BEFORE handle_key! so the
    # CodeEditor doesn't swallow them (it interprets T/K/S/e/m as
    # potential vim commands and consumes the keystroke).
    if is_press && ed.mode === :normal
        if evt.char == 'e' && m.focus === :patterns
            # `e` evals the current line as Julia. Only meaningful in the
            # patterns pane — the synth pane buffer contains SuperCollider
            # code which Julia can't parse, so leave `e` for the editor's
            # vim "end of word" motion there.
            _eval_current_line!(m); return
        elseif (evt.char == 'T' || evt.char == 't' || evt.char == ' ') &&
               _synth_pane_open(m) && m.focus === :synth
            # t / T / Space all fire the test in the synth pane. Vim's
            # `t` (till motion) isn't useful there, and giving up the
            # shift keypress is worth it for the iteration speed.
            _fire_t_with_accel!(m)
            return
        elseif evt.char == ' ' && m.focus === :patterns && !m.tap_recording
            # Space-as-leader for snippet expansion. Patterns pane
            # only — synth pane uses Space to fire the test synth.
            # The next char picks a template from _LEADER_SNIPPETS.
            m.pending_leader = true
            return
        elseif evt.char == 'K' && m.focus === :patterns
            _preview_word_under_cursor!(m); return
        elseif evt.char == 'S'
            # Allow S anywhere — scope is useful even without a synth
            # pane open (e.g. while a pattern is playing).
            _scope_cycle_key!(m); return
        elseif evt.char == 'm' && m.focus === :patterns
            _toggle_mute_current_line!(m); return
        elseif evt.char == '?' && m.focus === :patterns
            # Quick help — opens the guide modal without going through
            # `:?`. Matches the footer hint shown in normal-mode.
            m.modal = :guide; m.modal_scroll = 0
            return
        elseif evt.char == '!'
            # Single-key panic: stops all patterns + frees all SC nodes.
            # Bound to `!` so the vim `.` repeat-last-action keystroke
            # passes through to the editor unchanged.
            _panic!(m); return
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
        if _try_ex_autocomplete!(ed)
            return
        end
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

# ---------------------------------------------------------------------
# Insert-mode Tab autocomplete
# ---------------------------------------------------------------------

const _APP_AUTOCOMPLETE_CANDIDATES = String[
    # Combinators / helpers
    "pure", "silence", "fast", "slow", "density", "rev", "every",
    "stack", "cat", "mask", "gate", "degree",
    "gain", "speed", "lpf", "hpf", "pan", "n", "room", "delay",
    "shape", "set", "freq",
    "attack", "release", "hold", "sustain", "legato",
    "cutoff", "resonance", "bandq", "bandf", "hcutoff", "hresonance",
    "crush", "coarse",
    "accelerate", "vibrato", "tremolorate", "tremolodepth",
    "phaserrate", "phaserdepth",
    "delaytime", "delayfeedback",
    "octave", "slide", "pitch1", "pitch2", "pitch3", "detune",
    "vowel", "enhance",
    # Slot macros @d1..@d64
    ("@d$i" for i in 1:64)...,
]

"""
    _try_autocomplete!(m, ed) -> Bool

Look at the word under the cursor and replace it with the first
candidate that fuzzy-matches. Returns true if anything was inserted
(consuming the Tab keypress); false otherwise so the editor handles
Tab normally.

Candidate sources: combinators + ~40 OSC params + 64 @dN macros +
every registered sample / instrument / synth name.
"""
function _try_autocomplete!(m::RessacApp, ed::TK.CodeEditor)
    # Tab pressed again with an active cycle: just advance to the next
    # candidate, swap it into the previously-replaced range.
    if m.completion_idx > 0 && m.completion_row == ed.cursor_row &&
       !isempty(m.completion_candidates)
        m.completion_idx = m.completion_idx % length(m.completion_candidates) + 1
        repl = m.completion_candidates[m.completion_idx]
        _splice_completion!(m, ed, repl)
        _push_app_log!(m, "[INFO] tab $(m.completion_idx)/$(length(m.completion_candidates)): $(repl)")
        return true
    end
    # Fresh autocomplete: collect candidates, replace with the best.
    1 <= ed.cursor_row <= length(ed.lines) || return false
    chars = ed.lines[ed.cursor_row]
    col = ed.cursor_col
    isempty(chars) && return false
    is_word = c -> isletter(c) || isdigit(c) || c == '_' || c == '@'
    end_col = col
    start_col = end_col
    while start_col > 0 && is_word(chars[start_col])
        start_col -= 1
    end
    start_col == end_col && return false
    partial = String(chars[(start_col + 1):end_col])
    candidates = copy(_APP_AUTOCOMPLETE_CANDIDATES)
    append!(candidates, String.(keys(_SAMPLE_REGISTRY)))
    append!(candidates, String.(keys(_INSTRUMENT_REGISTRY)))
    append!(candidates, String.(keys(_SYNTH_REGISTRY)))
    unique!(candidates)
    scored = Tuple{Int,Int,String}[]
    for cand in candidates
        score = _fuzzy_score(partial, cand)
        score === nothing && continue
        push!(scored, (score, length(cand), cand))
    end
    isempty(scored) && return false
    sort!(scored, by = t -> (t[1], t[2], t[3]))
    # Cap the cycle list so we don't loop through hundreds of fuzzy
    # matches when the partial is a single letter.
    top = first(scored, 12)
    m.completion_candidates = String[t[3] for t in top]
    m.completion_idx = 1
    m.completion_row = ed.cursor_row
    m.completion_range = (start_col, end_col)
    _splice_completion!(m, ed, m.completion_candidates[1])
    if length(m.completion_candidates) > 1
        _push_app_log!(m, "[INFO] tab 1/$(length(m.completion_candidates)): " *
                       join(first(m.completion_candidates, 8), "  "))
    end
    return true
end

"""
    _splice_completion!(m, ed, replacement)

Replace `completion_range` on `completion_row` with `replacement` and
reposition the cursor right after it. Updates the stored range so the
next Tab cycle replaces this exact span (whose end column shifted).
"""
function _splice_completion!(m::RessacApp, ed::TK.CodeEditor, replacement::AbstractString)
    row = m.completion_row
    start_col, _ = m.completion_range
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    1 <= row <= length(lines) || return
    line = String(lines[row])
    # We need the CURRENT end_col: the end of the previous replacement
    # since the stored end might be stale after a swap. Walk from
    # start_col to find the first non-word boundary.
    chars = collect(line)
    is_word = c -> isletter(c) || isdigit(c) || c == '_' || c == '@'
    end_col = start_col
    while end_col < length(chars) && is_word(chars[end_col + 1])
        end_col += 1
    end
    new_line = (start_col > 0 ? String(chars[1:start_col]) : "") *
               replacement *
               (end_col >= length(chars) ? "" : String(chars[(end_col + 1):end]))
    lines[row] = new_line
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row
    ed.cursor_col = start_col + length(replacement)
    m.completion_range = (start_col, start_col + length(replacement))
end

"""
    _reset_completion!(m)

Clear the Tab-cycle state. Called from update! after handling any key
event in :insert mode that is not Tab — so the next Tab restarts a
fresh autocomplete from the (presumably new) word under the cursor.
"""
function _reset_completion!(m::RessacApp)
    m.completion_idx = 0
    empty!(m.completion_candidates)
end

# ---------------------------------------------------------------------
# Ghost autocomplete — Copilot-style faded suggestion at the cursor
# ---------------------------------------------------------------------

const _GHOST_USAGE_PATH = joinpath(homedir(), ".config", "ressac", "usage.toml")

# In-memory mirror of the usage counts. Loaded lazily; persisted after
# every accept. Keys are "kind:value" so we can rank within a category
# (e.g. "combinator:gain" vs "sample:bd") without collisions.
const _GHOST_USAGE = Ref{Dict{String,Int}}(Dict{String,Int}())
const _GHOST_USAGE_LOADED = Ref{Bool}(false)

function _load_ghost_usage!()
    _GHOST_USAGE_LOADED[] && return
    _GHOST_USAGE_LOADED[] = true
    isfile(_GHOST_USAGE_PATH) || return
    try
        data = TOML.parsefile(_GHOST_USAGE_PATH)
        if haskey(data, "counts") && data["counts"] isa AbstractDict
            for (k, v) in data["counts"]
                v isa Number && (_GHOST_USAGE[][String(k)] = Int(v))
            end
        end
    catch
    end
end

function _save_ghost_usage!()
    dir = dirname(_GHOST_USAGE_PATH)
    isdir(dir) || mkpath(dir)
    try
        open(_GHOST_USAGE_PATH, "w") do io
            println(io, "# Ressac ghost-autocomplete usage counts.")
            println(io, "# Higher counts → ranked first in suggestions.")
            println(io, "[counts]")
            for k in sort!(collect(keys(_GHOST_USAGE[])))
                println(io, "\"$(k)\" = $(_GHOST_USAGE[][k])")
            end
        end
    catch
    end
end

_ghost_bump!(kind::String, value::String) = begin
    key = "$(kind):$(value)"
    _GHOST_USAGE[][key] = get(_GHOST_USAGE[], key, 0) + 1
end

_ghost_count(kind::String, value::String) =
    get(_GHOST_USAGE[], "$(kind):$(value)", 0)

# Static lists per category. Suggested in usage-weighted order at
# completion time; first hit becomes the ghost.
const _GHOST_COMBINATORS = String[
    "gain", "lpf", "hpf", "pan", "n", "fast", "slow", "room", "delay",
    "shape", "cutoff", "resonance", "octave", "set", "degree", "every",
    "rev", "mask", "gate", "stack", "cat", "speed", "attack", "release",
    "sustain", "hold", "legato",
]

const _GHOST_SET_PARAMS = String[
    "gain", "freq", "rate", "cutoff", "q", "depth", "centre", "shape",
    "attack", "decay", "sustain", "release", "pan", "speed",
]

"""
    _ghost_context(line, col) -> (kind::Symbol, partial::String, candidates::Vector{String})

Inspect the surrounding text to decide what category of completion
to offer. Falls back to `:any` when nothing specific fits.
"""
function _ghost_context(line::AbstractString, col::Int)
    # Take everything from the line start up to the cursor; the
    # context regexes are anchored at the END so they match the latest
    # incomplete construct. `col` is a character count, but `line` may
    # contain multi-byte UTF-8 chars (¹ ▓ etc.), so slice by character
    # rather than by byte to avoid StringIndexError.
    prefix = if col <= 0
        ""
    else
        buf = IOBuffer(); n = 0
        for c in line
            n >= col && break
            print(buf, c); n += 1
        end
        String(take!(buf))
    end
    if (m = match(r"\|>\s*(\w*)$", prefix)) !== nothing
        return (:combinator, String(m.captures[1]), _GHOST_COMBINATORS)
    elseif (m = match(r"set\(:(\w*)$", prefix)) !== nothing
        return (:setparam, String(m.captures[1]), _GHOST_SET_PARAMS)
    elseif (m = match(r"p\"([^\"]*)$", prefix)) !== nothing
        # Inside p"…". Take the LAST whitespace-separated chunk as the
        # partial sample/synth name being typed.
        body = String(m.captures[1])
        last_chunk = ""
        if !isempty(body) && !isspace(body[end])
            i = lastindex(body)
            while i > firstindex(body) && !isspace(body[i])
                i = prevind(body, i)
            end
            last_chunk = isspace(body[i]) ?
                body[nextind(body, i):end] : body
        end
        cands = String[]
        append!(cands, String.(keys(_SAMPLE_REGISTRY)))
        append!(cands, String.(keys(_INSTRUMENT_REGISTRY)))
        append!(cands, String.(keys(_SYNTH_REGISTRY)))
        unique!(cands)
        return (:sample, last_chunk, cands)
    elseif (m = match(r"degree\((\w*)$", prefix)) !== nothing
        return (:degree, String(m.captures[1]), ["0", "1", "2", "3", "4", "5", "6", "7"])
    end
    # Generic — current word fuzzy-matched against everything.
    if (m = match(r"([@\w]+)$", prefix)) !== nothing
        partial = String(m.captures[1])
        cands = String[]
        append!(cands, _GHOST_COMBINATORS)
        append!(cands, String.(keys(_SAMPLE_REGISTRY)))
        append!(cands, String.(keys(_SYNTH_REGISTRY)))
        unique!(cands)
        return (:any, partial, cands)
    end
    return (:none, "", String[])
end

"""
    _compute_ghost!(m)

Recompute the ghost suggestion based on the current cursor position
in the active editor. Called on every keystroke in insert mode.
"""
function _compute_ghost!(m::RessacApp)
    ed = _active_editor(m)
    ed.mode === :insert || (m.ghost = ""; return)
    1 <= ed.cursor_row <= length(ed.lines) || (m.ghost = ""; return)
    line = String(ed.lines[ed.cursor_row])
    col = ed.cursor_col
    kind, partial, cands = _ghost_context(line, col)
    if kind === :none || isempty(cands)
        m.ghost = ""; return
    end
    # Filter by partial — must start with what's typed (prefix match
    # feels more like Copilot than fuzzy here).
    matching = [c for c in cands
                if startswith(lowercase(c), lowercase(partial)) && c != partial]
    if isempty(matching)
        m.ghost = ""; return
    end
    # Rank by usage count desc, then by length, then alpha.
    kind_key = String(kind)
    sort!(matching, by = c -> (-_ghost_count(kind_key, c), length(c), c))
    suggestion = matching[1]
    completion = suggestion[length(partial) + 1 : end]
    m.ghost = completion
    m.ghost_row = ed.cursor_row
    m.ghost_col = col
end

"""
    _accept_ghost!(m)

Splice the ghost text into the buffer at the cursor and bump the
usage count for the (kind, value) pair so it ranks higher next
time.
"""
function _accept_ghost!(m::RessacApp)
    isempty(m.ghost) && return false
    ed = _active_editor(m)
    ed.cursor_row == m.ghost_row || (m.ghost = ""; return false)
    line = String(ed.lines[m.ghost_row])
    col = m.ghost_col
    # Char-indexed split (UTF-8 safe). line[1:col] would byte-slice
    # and crash on multi-byte chars like ¹ ° ▓ when col is a char count.
    before, after = _char_split(line, col)
    new_line = before * m.ghost * after
    TK.set_text!(ed, _set_one_line(ed, m.ghost_row, new_line))
    ed.cursor_row = m.ghost_row
    ed.cursor_col = col + length(m.ghost)
    # Bump usage. Recompute the full token (partial + accepted suffix)
    # so the ranking key is the full identifier.
    kind, partial, _ = _ghost_context(line, col)
    if kind !== :none
        full = partial * m.ghost
        _ghost_bump!(String(kind), full)
        _save_ghost_usage!()
    end
    m.ghost = ""
    return true
end

"""
    _render_ghost!(m, rect, buf)

Draw the suggestion in dim style starting at the cursor cell. Each
character of the ghost overwrites an empty cell to the RIGHT of the
cursor — never replaces existing content.
"""
function _render_ghost!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    isempty(m.ghost) && return
    ed = _active_editor(m)
    ed.mode === :insert || return
    ed.cursor_row == m.ghost_row || return
    ed.cursor_col == m.ghost_col || return
    has_block = ed.block !== nothing
    inset_top = has_block ? 1 : 0
    inset_left = has_block ? 1 : 0
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    screen_y = rect.y + inset_top + (m.ghost_row - 1 - ed.scroll_offset)
    base_x = rect.x + inset_left + gw + (m.ghost_col - ed.h_scroll)
    (screen_y < rect.y + inset_top || screen_y >= rect.y + rect.height) && return
    for (i, ch) in enumerate(m.ghost)
        x = base_x + i - 1
        x < rect.x + inset_left + gw && continue
        x >= rect.x + rect.width && break
        TK.set_char!(buf, x, screen_y, ch, TK.tstyle(:text_dim))
    end
end

# ---------------------------------------------------------------------
# Pattern shortcut DSL — `:s<verb><args>[N]` and `:sn<verb><args>[N]`
# ---------------------------------------------------------------------
#
# Compact ex-commands to append common combinators to the current line
# without leaving normal mode for long. Each call expands to
# " |> verb(args)" appended to the cursor's line. A leading `n`
# (`:sn…`) inserts a newline BEFORE the snippet so the appended call
# lands on its own line under the pattern; a trailing `N` (`:s…N`)
# adds a newline AFTER, leaving the cursor on a fresh line for the
# next thought.

const _SHORTCUT_VERBS = Dict{String,String}(
    "g"  => "gain",      "l" => "lpf",       "h"  => "hpf",
    "p"  => "pan",       "f" => "fast",      "w"  => "slow",
    "r"  => "room",      "d" => "delay",     "s"  => "shape",
    "t"  => "gate",      "o" => "octave",    "c"  => "cutoff",
    "q"  => "resonance", "rv" => "rev",      "sp" => "speed",
)

# Sorted so longer verbs match first (gt/rv/sp before single chars).
const _SHORTCUT_RX = let
    verbs = sort(collect(keys(_SHORTCUT_VERBS)); by=length, rev=true)
    Regex("^s(n?)(" * join(verbs, "|") * ")([0-9.\\s\\-]*)(N?)\$")
end

"""
    _apply_pattern_shortcut!(m, nl_before, verb, args, nl_after)

Translate a shortcut into ` |> <fn>(<args>)` and splice it into the
buffer at the cursor's row. The `t` verb interprets its args as a
bitstring (e.g. "010110") and expands to `gate(p"0 1 0 1 1 0")`.
"""
function _apply_pattern_shortcut!(m::RessacApp, nl_before::Bool,
                                  verb::String, args::AbstractString,
                                  nl_after::Bool)
    ed = _active_editor(m)
    full_verb = _SHORTCUT_VERBS[verb]
    snippet = if verb == "t"
        bits = filter(c -> c == '0' || c == '1', args)
        spaced = join(string.(collect(bits)), " ")
        isempty(spaced) ?
            " |> gate(p\"\")" :
            " |> gate(p\"$(spaced)\")"
    elseif isempty(args)
        " |> $(full_verb)()"
    else
        " |> $(full_verb)($(args))"
    end
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(lines))
    line = String(lines[row])
    if nl_before
        # Snippet lands on a NEW line under the current one. Source
        # indent + 4 extra spaces visually marks it as a continuation
        # of the pipeline started above.
        base_indent = length(line) - length(lstrip(line))
        indent = " " ^ (base_indent + 4)
        insert!(lines, row + 1, indent * lstrip(snippet))
        ed.cursor_row = row + 1
        ed.cursor_col = length(lines[row + 1])
    else
        lines[row] = line * snippet
        ed.cursor_col = length(lines[row])
    end
    if nl_after
        # Same indentation as the line we just wrote, so the next
        # snippet the user adds chains visually too.
        base_indent = ed.cursor_row <= length(lines) ?
            length(lines[ed.cursor_row]) - length(lstrip(lines[ed.cursor_row])) : 0
        next_indent = " " ^ (nl_before ? base_indent : base_indent + 4)
        insert!(lines, ed.cursor_row + 1, next_indent)
        ed.cursor_row += 1
        ed.cursor_col = length(next_indent)
    end
    TK.set_text!(ed, join(lines, '\n'))
    _push_app_log!(m, "[INFO] shortcut → $(strip(snippet))")
end

# ---------------------------------------------------------------------
# Playhead — highlights the active token in active patterns
# ---------------------------------------------------------------------

# Match @dN at the start of a line, followed by a p"…" block somewhere
# after it. We capture the slot number and the byte offsets of the p"
# string contents (between the quotes) so we know which character to
# highlight when the phase lands inside.
const _PLAYHEAD_LINE_RX = r"@d(\d+).*?\bp\"([^\"]*)\""

"""
    _render_playhead!(m, rect, buf)

For every visible line in the patterns editor that maps to a slot
currently shipping events, overlay a highlight on the mininotation
token that's playing right now. Equal-time subdivision at top
level — `p"bd hh sn hh"` splits into 4 equal slots, the active
one gets the accent background.

Bracketed / Euclidean / `<…>` constructs are treated as one
top-level token; precise highlighting inside them is a follow-up.
"""
function _render_playhead!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    sched = m.scheduler
    sched.t_start > 0 || return
    isempty(sched.patterns) && return
    phase = ((time() - sched.t_start) * sched.cps) % 1.0
    phase = clamp(phase, 0.0, 0.9999)
    has_block = m.editor.block !== nothing
    inset_top = has_block ? 1 : 0
    inset_bot = has_block ? 1 : 0   # the block has a bottom border too
    inset_left = has_block ? 1 : 0
    gw = m.editor.show_line_numbers ? ndigits(max(length(m.editor.lines), 1)) + 1 : 0
    # Iterate only the visible window — bounded by scroll_offset above
    # and rect.height-borders below. Avoids both the "highlight bleeds
    # onto the bottom border" jump and the O(n) scan over hidden lines.
    body_h = rect.height - inset_top - inset_bot
    first_row = m.editor.scroll_offset + 1
    last_row  = min(length(m.editor.lines), first_row + body_h - 1)
    # Prune cache entries outside the visible window so it stays bounded
    # to ~rect.height rows even if the user scrolls a large buffer.
    for k in keys(m.playhead_cache)
        (k < first_row || k > last_row) && delete!(m.playhead_cache, k)
    end
    for i in first_row:last_row
        screen_row = rect.y + inset_top + (i - 1 - m.editor.scroll_offset)
        line_chars = m.editor.lines[i]
        # Cache key = hash(line content). Cheap to compute and avoids
        # the regex + body split when the line hasn't changed between
        # frames. nothing-valued cache entries are kept so we don't
        # re-parse lines that don't match the regex.
        line_hash = hash(line_chars)
        cached = get(m.playhead_cache, i, nothing)
        parsed = if cached !== nothing && cached[1] == line_hash
            cached[2]
        else
            p = _playhead_parse(line_chars)
            m.playhead_cache[i] = (line_hash, p)
            p
        end
        parsed === nothing && continue
        haskey(sched.patterns, parsed.slot) || continue
        # Re-paint the slot prefix (`@dN`) in :warning bold so the eye
        # can spot active lines instantly even before the playhead token
        # highlight kicks in. Inactive @dN lines (slot not in
        # sched.patterns) skip this branch entirely.
        slot_screen_x_start = rect.x + inset_left + gw +
                              parsed.slot_start_col - ed_h_scroll(m.editor)
        for k in 0:(parsed.slot_str_len - 1)
            sx = slot_screen_x_start + k
            sx < rect.x + inset_left + gw && continue
            sx >= rect.x + rect.width && break
            line_col = parsed.slot_start_col + k + 1
            line_col <= length(line_chars) || break
            TK.set_char!(buf, sx, screen_row, line_chars[line_col],
                         TK.tstyle(:warning, bold = true))
        end
        # Active token highlight.
        n = length(parsed.tokens)
        active = clamp(floor(Int, phase * n) + 1, 1, n)
        tok_start_in_body, tok_stop_in_body = parsed.tokens[active]
        for body_col in tok_start_in_body:tok_stop_in_body
            screen_x = rect.x + inset_left + gw + parsed.body_start_col +
                       body_col - ed_h_scroll(m.editor)
            screen_x < rect.x + inset_left + gw && continue
            screen_x >= rect.x + rect.width && break
            buf_col = parsed.body_start_col + body_col + 1
            ch = buf_col <= length(line_chars) ? line_chars[buf_col] : ' '
            TK.set_char!(buf, screen_x, screen_row, ch,
                         TK.tstyle(:accent, bold = true))
        end
    end
end

"""
    _playhead_parse(line_chars) -> Union{Nothing, NamedTuple}

Run the @dN regex + body token-split once per (changed) line. The
result is cached in `m.playhead_cache` keyed on the line hash so
unchanged rows skip this work. Returning `nothing` when no @dN
match keeps the cache shape consistent for both match and no-match.
"""
function _playhead_parse(line_chars::Vector{Char})
    line = String(line_chars)
    mt = match(_PLAYHEAD_LINE_RX, line)
    mt === nothing && return nothing
    body = String(mt.captures[2])
    isempty(body) && return nothing
    tokens = _split_minino_top(body)
    isempty(tokens) && return nothing
    return (slot           = Symbol("d", mt.captures[1]),
            slot_str_len   = 2 + length(mt.captures[1]),
            slot_start_col = mt.offsets[1] - 2,
            body_start_col = mt.offsets[2] - 1,
            tokens         = tokens)
end

ed_h_scroll(ed::TK.CodeEditor) = ed.h_scroll

"""
    _render_eval_flash!(m, rect, buf)

After `:e` (or `E`) evals a block, paint the corresponding @dN line
in :success bold so the user gets a visual "this just ran" pulse.
Fades over `_EVAL_FLASH_DURATION` seconds; after that nothing draws
until the next eval.
"""
const _EVAL_FLASH_DURATION = 0.6
function _render_eval_flash!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    isempty(m.eval_flash_rows) && return
    age = time() - m.eval_flash_ts
    age > _EVAL_FLASH_DURATION && (empty!(m.eval_flash_rows); return)
    # Fade: full strength at age=0, none at duration. We pick :success
    # for the first half, then :accent dim — gives a "green then settle"
    # feel without needing per-cell alpha.
    style = age < _EVAL_FLASH_DURATION / 2 ?
        TK.tstyle(:success, bold = true) :
        TK.tstyle(:success)
    gw = m.editor.show_line_numbers ?
         ndigits(max(length(m.editor.lines), 1)) + 1 : 0
    first_row = m.editor.scroll_offset + 1
    last_row  = first_row + rect.height - 1
    for row in m.eval_flash_rows
        (row < first_row || row > last_row) && continue
        screen_y = rect.y + (row - first_row)
        row <= length(m.editor.lines) || continue
        line_chars = m.editor.lines[row]
        # Repaint each char on the row in the flash style, preserving
        # the source char. Skip the line-number gutter.
        for (col_in_line, ch) in enumerate(line_chars)
            screen_x = rect.x + gw + col_in_line - 1 - m.editor.h_scroll
            screen_x < rect.x + gw && continue
            screen_x >= rect.x + rect.width && break
            TK.set_char!(buf, screen_x, screen_y, ch, style)
        end
    end
end

"""
    _split_minino_top(body) -> Vector{Tuple{Int,Int}}

Split `body` (the inside of a `p"…"` string) into top-level
whitespace-separated tokens. Returns a vector of (start, stop)
columns relative to `body` (0-based, inclusive). Tokens inside
[…] / <…> / (…) are treated as a single unit.
"""
function _split_minino_top(body::AbstractString)
    out = Tuple{Int,Int}[]
    n = length(body)
    depth = 0
    tok_start = -1
    for (i, c) in enumerate(body)
        col = i - 1
        if c == '[' || c == '<' || c == '('
            depth += 1
            tok_start == -1 && (tok_start = col)
        elseif c == ']' || c == '>' || c == ')'
            depth = max(0, depth - 1)
        elseif isspace(c) && depth == 0
            if tok_start >= 0
                push!(out, (tok_start, col - 1))
                tok_start = -1
            end
        else
            tok_start == -1 && (tok_start = col)
        end
    end
    tok_start >= 0 && push!(out, (tok_start, n - 1))
    return out
end

# ---------------------------------------------------------------------
# Pattern editor — context-aware ops on the p"…" the cursor sits in
# ---------------------------------------------------------------------

"""
    _pat_at_cursor(ed) -> Union{Nothing, NamedTuple}

If the editor's cursor is inside a `p"…"` (or `n("…")` etc.) on the
current line, return a NamedTuple describing the pattern so callers
can mutate it:

  • `row`             — 1-based line index
  • `body`            — the string between the quotes
  • `body_start_col`  — column where `body[1]` lives (0-based)
  • `tokens`          — `Vector{Tuple{Int,Int}}` from `_split_minino_top`
  • `tok_idx`         — which token contains the cursor (or nearest)

Returns `nothing` when the cursor isn't inside a `p"…"` string.
"""
function _pat_at_cursor(ed::TK.CodeEditor)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return nothing
    line = String(ed.lines[row])
    # Find the p"…" enclosing the cursor. Scan for the last `p"` start
    # at or before the cursor that has its closing `"` after the cursor.
    cur = ed.cursor_col
    rx = r"\bp\"([^\"]*)\""
    for mt in eachmatch(rx, line)
        body_start = mt.offsets[1] - 1            # 0-based col of body[1]
        body_end   = body_start + length(mt.captures[1])  # exclusive
        if body_start - 2 <= cur <= body_end
            body = String(mt.captures[1])
            tokens = _split_minino_top(body)
            isempty(tokens) && return nothing
            # Which token contains the cursor? Cursor col is relative
            # to line; translate to body-relative.
            cur_in_body = clamp(cur - body_start, 0, length(body))
            idx = findlast(t -> t[1] <= cur_in_body <= t[2] + 1, tokens)
            idx === nothing && (idx = length(tokens))
            return (row = row, body = body,
                    body_start_col = body_start,
                    tokens = tokens, tok_idx = idx)
        end
    end
    return nothing
end

"""
    _pat_replace_body!(m, ed, info, new_body)

Rewrite the line `info.row` swapping the pattern body for `new_body`.
The `p"` quotes stay. Cursor is repositioned at the start of the new
body — callers can re-find their token afterwards if needed.
"""
function _pat_replace_body!(m::RessacApp, ed::TK.CodeEditor, info, new_body::AbstractString)
    line = String(ed.lines[info.row])
    # body_start_col / body length are char counts, never byte indices.
    before, rest    = _char_split(line, info.body_start_col)
    _, after        = _char_split(rest, length(info.body))
    new_line = before * String(new_body) * after
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    lines[info.row] = new_line
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = info.row
    ed.cursor_col = clamp(info.body_start_col, 0, length(ed.lines[info.row]))
end

"""
    _pat_zoom!(m, ed, dir)

`dir = +1` doubles the resolution: every adjacent pair of tokens
gets a `~` inserted between them, so a `p"bd hh"` becomes
`p"bd ~ hh ~"` — the audio stays exactly the same, but each
original step is now two cells and the user has slots to fill.

`dir = -1` halves: keep every other token, drop the in-between
ones. Lossy if the dropped slots had hits — warns in the log.
"""
function _pat_zoom!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] zoom: cursor isn't in a p\"…\"")
    body = info.body
    tokens = info.tokens
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    if dir > 0
        # Interleave a rest after every token to double the grid.
        new_tokens = String[]
        for s in strs
            push!(new_tokens, s); push!(new_tokens, "~")
        end
        new_body = join(new_tokens, " ")
        _pat_replace_body!(m, ed, info, new_body)
        _push_app_log!(m, "[INFO] pattern zoom ×2 → $(length(new_tokens)) steps")
    else
        # Keep odd-indexed (1, 3, 5, …) tokens; warn if any dropped
        # token wasn't a silence.
        kept = String[]
        dropped_hits = 0
        for (i, s) in enumerate(strs)
            if isodd(i)
                push!(kept, s)
            elseif s != "~"
                dropped_hits += 1
            end
        end
        isempty(kept) && (kept = ["~"])
        new_body = join(kept, " ")
        _pat_replace_body!(m, ed, info, new_body)
        if dropped_hits > 0
            _push_app_log!(m,
                "[WARN] pattern zoom ÷2 → $(length(kept)) steps · " *
                "dropped $(dropped_hits) hit$(dropped_hits == 1 ? "" : "s")")
        else
            _push_app_log!(m, "[INFO] pattern zoom ÷2 → $(length(kept)) steps")
        end
    end
end

"""
    _pat_shift!(m, ed, dir)

Swap the token at cursor with its neighbour in `dir` (±1) within
the same `p"…"`. Cursor follows the moved token so successive
presses keep moving the same note.
"""
function _pat_shift!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] shift: cursor isn't in a p\"…\"")
    tokens = info.tokens
    i = info.tok_idx
    j = i + dir
    (1 <= j <= length(tokens)) || return _push_app_log!(m, "[INFO] shift: at edge of pattern")
    body = info.body
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    strs[i], strs[j] = strs[j], strs[i]
    new_body = join(strs, " ")
    _pat_replace_body!(m, ed, info, new_body)
    # Re-tokenise and place cursor inside the moved token at its new index.
    info2 = _pat_at_cursor(ed)
    if info2 !== nothing && j <= length(info2.tokens)
        ed.cursor_col = info.body_start_col + info2.tokens[j][1]
    end
end

"""
    _pat_silence!(m, ed)

Replace the token under cursor with `~`. Same shape as `x` in vim,
but operates at token granularity inside a pattern.
"""
function _pat_silence!(m::RessacApp, ed::TK.CodeEditor)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] silence: cursor isn't in a p\"…\"")
    body = info.body
    tokens = info.tokens
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    strs[info.tok_idx] = "~"
    new_body = join(strs, " ")
    _pat_replace_body!(m, ed, info, new_body)
end

"""
    _pat_subdivide!(m, ed, n)

Set the token under cursor to subdivide N times — `bd` → `bd*N` —
or strip the subdivision when `n == 1`. Maps musically:

    1 = noire (no subdivision, plain token)
    2 = croche
    3 = triolet
    4 = double croche
    6 = sextolet
    8 = triple croche

If the token already ends in `*K`, the K is replaced by N.
"""
function _pat_subdivide!(m::RessacApp, ed::TK.CodeEditor, n::Int)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] subdivide: cursor isn't in a p\"…\"")
    body = info.body
    tokens = info.tokens
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    tok = strs[info.tok_idx]
    # Strip any existing *K suffix at the top level (skip if inside [] etc).
    base = replace(tok, r"\*\d+$" => "")
    new_tok = n <= 1 ? base : "$(base)*$(n)"
    strs[info.tok_idx] = new_tok
    new_body = join(strs, " ")
    _pat_replace_body!(m, ed, info, new_body)
    name = n == 1 ? "noire" :
           n == 2 ? "croche" :
           n == 3 ? "triolet" :
           n == 4 ? "double croche" :
           n == 6 ? "sextolet" :
           n == 8 ? "triple croche" : "×$n"
    _push_app_log!(m, "[INFO] subdivide: $tok → $new_tok ($name)")
end

# ---------------------------------------------------------------------
# Space-leader snippet expansion + placeholder navigation
# ---------------------------------------------------------------------
#
# Workflow: in normal mode, Space → trigger char → template expands at
# cursor with the cursor on $1, editor auto-enters insert. Tab jumps
# to $2 / $3 / … (Shift-Tab goes back). Esc exits placeholder mode
# and falls back to standard insert→normal on the second press.

"""
    _LEADER_SNIPPETS

Trigger char → template. `\$N` markers are tabstops. Single-line for
now; the placeholder tracker assumes everything fits on the row
where the snippet was inserted. Add multi-line templates only after
extending the tracker to (row, col) tuples.
"""
const _LEADER_SNIPPETS = Dict{Char,String}(
    'd' => "@d\$1 p\"\$2\"",
    'g' => "|> gain(\$1)",
    'l' => "|> lpf(\$1)",
    'h' => "|> hpf(\$1)",
    'p' => "|> pan(\$1)",
    'f' => "|> fast(\$1)",
    's' => "|> slow(\$1)",
    'r' => "|> room(\$1)",
    'n' => "|> n(p\"\$1\")",
    'e' => "|> every(\$1, \$2)",
    'm' => "|> mask(p\"\$1\")",
    'D' => "|> delay(\$1) |> delaytime(\$2) |> delayfeedback(\$3)",
    'c' => "|> cat([p\"\$1\", p\"\$2\"])",
    'S' => "|> stack(p\"\$1\", p\"\$2\")",
    'v' => "rev",     # no placeholder, just inserts as-is
    # ── Euclidean rhythms (Bjorklund k-of-n) ──
    # `E` = generic euclidean token: sample, k, n. Drop it inside a
    # p"…" or as the body of a fresh pattern.  Examples:
    #   Space E → bd Tab 3 Tab 8 → bd(3,8)         # jersey kick
    #   Space E → cp Tab 1 Tab 8 → cp(1,8)         # single clap
    'E' => "\$1(\$2,\$3)",
    # `R` for rotated euclidean — useful for off-beat snares / claps.
    # E.g. Space R → cp Tab 1 Tab 8 Tab 4 → cp(1,8,4)  # clap on beat 3
    'R' => "\$1(\$2,\$3,\$4)",
    # `J` = jersey starter — full @dN line with the iconic 3-against-8
    # kick, ready to eval. Two placeholders: slot id + gain.
    'J' => "@d\$1 p\"bd(3,8)\" |> gain(\$2)",
)

"""
    _LEADER_ACTIONS

Triggers that fire a callback instead of expanding text — useful
for opening pickers / modals. `Space b` → browser, `Space ?` →
guide, etc. Resolved before `_LEADER_SNIPPETS` so they take
priority on the same char.
"""
const _LEADER_ACTIONS = Dict{Char,Function}(
    'b' => m -> _open_browser!(m),       # all sounds (samples + insts + synths)
    'L' => m -> _open_synth_library!(m), # synth library
    '?' => m -> (m.modal = :guide;  m.modal_scroll = 0),
    'w' => m -> _open_wiki!(m),
    'I' => m -> _open_snippets!(m),      # I for "insert snippet" picker
)

"""
    _LEADER_LABELS

Short labels for the footer hint shown while a leader is pending.
Keep each label terse — the footer is one row.
"""
const _LEADER_LABELS = Pair{Char,String}[
    'd' => "slot",   'g' => "gain",   'l' => "lpf",
    'h' => "hpf",    'p' => "pan",    'f' => "fast",
    's' => "slow",   'r' => "room",   'n' => "n()",
    'e' => "every",  'm' => "mask",   'D' => "delay-chain",
    'c' => "cat",    'S' => "stack",  'v' => "rev",
    'E' => "eucl",   'R' => "eucl-rot", 'J' => "jersey",
    # ── pickers ──
    'b' => "▸browse-sounds", 'L' => "▸synth-lib", 'I' => "▸snippets",
    'w' => "▸wiki",  '?' => "▸guide",
]

"""
    _parse_snippet_template(tpl) -> (text::String, placeholder_cols::Vector{Int})

Strip `\$N` markers and return the bare text plus the column
positions (0-based, relative to text start) where each placeholder
ends up. Markers must be `\$` followed by a single digit.
"""
function _parse_snippet_template(tpl::AbstractString)
    out = IOBuffer()
    cols = Tuple{Int,Int}[]  # (placeholder_idx, col_in_text)
    i = firstindex(tpl)
    col = 0
    while i <= ncodeunits(tpl)
        c = tpl[i]
        if c == '$' && i < ncodeunits(tpl) && isdigit(tpl[i+1])
            n = parse(Int, string(tpl[i+1]))
            push!(cols, (n, col))
            i = nextind(tpl, i, 2)
        else
            print(out, c)
            col += 1
            i = nextind(tpl, i)
        end
    end
    sort!(cols; by = first)
    return (String(take!(out)), [c for (_, c) in cols])
end

"""
    _expand_snippet!(m, ed, template)

Insert `template`'s text at the cursor, record placeholder positions,
move the cursor onto the first one, and switch to insert mode with
placeholder tracking armed. Templates without placeholders just get
inserted and we stay in normal mode (no nav needed).
"""
function _expand_snippet!(m::RessacApp, ed::TK.CodeEditor, template::AbstractString)
    text, ph_offsets = _parse_snippet_template(template)
    # Insert text at cursor on the current row.
    row = ed.cursor_row
    col = ed.cursor_col
    1 <= row <= length(ed.lines) || return
    line = String(ed.lines[row])
    new_line = line[1:col] * text * line[col+1:end]
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    lines[row] = new_line
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row
    if isempty(ph_offsets)
        ed.cursor_col = col + length(text)
        return
    end
    # Absolute placeholder columns = insert column + relative offset.
    m.placeholder_row    = row
    m.placeholder_cols   = [col + off for off in ph_offsets]
    m.placeholder_idx    = 1
    m.placeholder_active = true
    ed.cursor_col = m.placeholder_cols[1]
    ed.mode = :insert
end

"""
    _placeholder_jump!(m, ed, dir)

Move to the next (`dir = +1`) or previous (`dir = -1`) placeholder.
Going past the last placeholder exits placeholder mode (stays in
insert so the user can keep typing).
"""
function _placeholder_jump!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    m.placeholder_active || return false
    new_idx = m.placeholder_idx + dir
    if new_idx < 1 || new_idx > length(m.placeholder_cols)
        m.placeholder_active = false
        return true
    end
    m.placeholder_idx = new_idx
    ed.cursor_row = m.placeholder_row
    ed.cursor_col = clamp(m.placeholder_cols[new_idx], 0, length(ed.lines[m.placeholder_row]))
    return true
end

"""
    _placeholder_track_change!(m, ed, pre_len)

Called after a buffer-modifying key in insert mode while
`placeholder_active`. Adjusts all placeholder columns after the
cursor by the delta `(post_len - pre_len)` so they stay aligned as
the user fills in text. Also deactivates if the user moved to a
different row.
"""
function _placeholder_track_change!(m::RessacApp, ed::TK.CodeEditor, pre_len::Int)
    m.placeholder_active || return
    if ed.cursor_row != m.placeholder_row
        m.placeholder_active = false; return
    end
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || (m.placeholder_active = false; return)
    post_len = length(ed.lines[row])
    delta = post_len - pre_len
    delta == 0 && return
    cur = ed.cursor_col
    # Shift placeholders that sit at or after the cursor by delta.
    # Don't move the placeholder the user is currently filling — only
    # the ones AHEAD so they don't slide under typed text.
    for i in eachindex(m.placeholder_cols)
        i == m.placeholder_idx && continue
        if m.placeholder_cols[i] >= cur
            m.placeholder_cols[i] += delta
        end
    end
end

# ---------------------------------------------------------------------
# Vim word motions + operator combos (cw / dw / yw / c$ / d0 / …)
# ---------------------------------------------------------------------

"""
    _word_bounds(line, col, big=false) -> (start, stop)

Return the half-open [start, stop) range of the word at/after `col`
(0-based). `big` selects WORD (whitespace-delimited) vs word
(alphanumeric-delimited). Matches vim's `w` motion: jumps to the
next word's first char, deleting up through but not including the
following whitespace.
"""
function _word_bounds(line::AbstractString, col::Int; big::Bool=false)
    n = length(line)
    is_word = if big
        c -> !isspace(c)
    else
        c -> isletter(c) || isdigit(c) || c == '_'
    end
    col = clamp(col, 0, n)
    # Skip current word
    i = col + 1
    while i <= n && is_word(line[i]); i += 1; end
    # Skip whitespace
    while i <= n && isspace(line[i]); i += 1; end
    stop = i - 1
    return (col, stop)
end

"""
    _word_back_bounds(line, col, big=false) -> col

Position of the previous word's first char.
"""
function _word_back_bounds(line::AbstractString, col::Int; big::Bool=false)
    n = length(line)
    is_word = big ? (c -> !isspace(c)) :
                    (c -> isletter(c) || isdigit(c) || c == '_')
    col = clamp(col, 0, n)
    col == 0 && return 0
    i = col
    # Step back past whitespace
    while i > 0 && i <= n && isspace(line[i]); i -= 1; end
    # Step back to the start of the current word
    while i > 0 && i <= n && is_word(line[i]); i -= 1; end
    return i
end

function _vim_word_motion!(ed::TK.CodeEditor, ch::Char)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return
    line = String(ed.lines[row])
    big = (ch == 'W' || ch == 'B')
    if ch == 'w' || ch == 'W'
        _, stop = _word_bounds(line, ed.cursor_col; big=big)
        ed.cursor_col = clamp(stop, 0, max(length(line) - 1, 0))
    elseif ch == 'b' || ch == 'B'
        ed.cursor_col = _word_back_bounds(line, ed.cursor_col; big=big)
    end
end

"""
    _vim_op_motion!(m, ed, op, motion)

Execute one of cw / cb / c\$ / c0 (and their d/y variants). `op`
is the operator char; `motion` is one of the supported motion
chars. Word boundaries reuse the same helpers as the standalone
motions so behaviour stays consistent.
"""
function _vim_op_motion!(m::RessacApp, ed::TK.CodeEditor, op::Char, motion::Char)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return
    line = String(ed.lines[row])
    n = length(line)
    col = ed.cursor_col
    range_start, range_stop = if motion == 'w' || motion == 'W'
        # Vim's cw is special: it stops at the END of the current word,
        # not the next-word-start. Mirror that — operating on
        # whitespace-included `w` deletes the gap too which is dw, but
        # cw leaves it.
        is_word = motion == 'W' ? (c -> !isspace(c)) :
                                  (c -> isletter(c) || isdigit(c) || c == '_')
        i = col + 1
        while i <= n && is_word(line[i]); i += 1; end
        word_end = i - 1
        if op == 'c'
            (col, word_end)
        else
            # dw/yw extend through trailing whitespace.
            while i <= n && isspace(line[i]); i += 1; end
            (col, i - 1)
        end
    elseif motion == 'b' || motion == 'B'
        new_col = _word_back_bounds(line, col; big = motion == 'B')
        (new_col, col - 1)
    elseif motion == 'e' || motion == 'E'
        is_word = motion == 'E' ? (c -> !isspace(c)) :
                                  (c -> isletter(c) || isdigit(c) || c == '_')
        i = col + 1
        # If on whitespace, skip ahead to next word first.
        while i <= n && isspace(line[i]); i += 1; end
        while i <= n && is_word(line[i]); i += 1; end
        (col, i - 1)
    elseif motion == '\$'
        (col, n)
    elseif motion == '0'
        (0, col - 1)
    else
        return
    end
    range_start = clamp(range_start, 0, n)
    range_stop  = clamp(range_stop, range_start, n)
    captured = range_start < range_stop ?
        line[range_start + 1 : range_stop] : ""
    if op == 'y'
        # Yank only — leave the buffer alone, set Tachikoma's yank.
        ed.yank_buffer = [collect(captured)]
        ed.yank_is_linewise = false
        return
    end
    # d / c — splice the slice out.
    new_line = (range_start > 0 ? line[1:range_start] : "") *
               (range_stop >= n ? "" : line[range_stop + 1 : end])
    ed.yank_buffer = [collect(captured)]
    ed.yank_is_linewise = false
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    ed.cursor_row = row
    ed.cursor_col = range_start
    if op == 'c'
        ed.mode = :insert
    end
end

# Number-nudge regex: optional sign, digits, optional fractional part.
# Anchored at the START of the candidate span, not the line — we'll
# scan around the cursor for the nearest match.
const _NUMBER_RX = r"-?\d+(?:\.\d+)?"

"""
    _has_number_under_cursor(ed) -> Bool

True iff the cursor sits inside a numeric literal — used to decide
whether + / - in normal mode should nudge the value or fall through
to scope zoom. Cheap: a regex scan of one line.
"""
function _has_number_under_cursor(ed::TK.CodeEditor)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return false
    line = String(ed.lines[row])
    col = ed.cursor_col
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        s - 1 <= col <= e && return true
    end
    return false
end

"""
    _nudge_number_under_cursor!(m, ed, step)

Find a numeric literal touching the cursor and add `step` to it. Ints
get +/- step as-is; floats get scaled (step=±10 → ±0.1, step=±1 →
±1.0) so the nudge keys behave intuitively across both. Preserves the
number's decimal precision (1.20 stays two-decimal).
"""
function _nudge_number_under_cursor!(m::RessacApp, ed::TK.CodeEditor, step::Int)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return
    line = String(ed.lines[row])
    col = ed.cursor_col
    # Find the number-match whose span covers col, or the nearest one.
    best = nothing
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        if s - 1 <= col <= e   # 0-based col vs 1-based offsets
            best = mt
            break
        end
    end
    best === nothing && return
    txt = best.match
    s = best.offset
    e = s + length(txt) - 1
    is_float = occursin('.', txt)
    new_str = if is_float
        delta = abs(step) == 10 ? (step > 0 ? 0.1 : -0.1) : Float64(step)
        val = parse(Float64, txt) + delta
        # Preserve precision of the original (count decimals).
        dot = findfirst('.', txt)
        decimals = length(txt) - dot
        # Round to that many decimals to avoid 0.1+0.2 floating noise.
        rounded = round(val; digits = decimals)
        # Format with fixed decimals so "1.2 → 1.3" keeps one digit.
        string(rounded)
    else
        val = parse(Int, txt) + step
        string(val)
    end
    new_line = (s > 1 ? line[1:s-1] : "") * new_str *
               (e >= lastindex(line) ? "" : line[e+1:end])
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    ed.cursor_row = row
    # Keep cursor on the same logical position relative to the number's start.
    ed.cursor_col = clamp(col + (length(new_str) - length(txt)), 0,
                          length(ed.lines[row]))
    _push_app_log!(m, "[INFO] nudge $txt → $new_str")
end

"""
    _set_one_line(ed, row, new_line) -> joined text

Build the full buffer text with `row` replaced by `new_line`. Helper
for nudge so we don't have to expand split/join inline at the call
site.
"""
function _set_one_line(ed::TK.CodeEditor, row::Int, new_line::AbstractString)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    1 <= row <= length(lines) || return txt
    lines[row] = String(new_line)
    return join(lines, '\n')
end

"""
    _char_split(line, col) -> (prefix, suffix)

Split `line` at character position `col` (0-based, char count not
byte count). Safe with multi-byte UTF-8 — never indexes by byte.
The cursor model used by Tachikoma's CodeEditor is char-based, so
any string mutation derived from cursor positions must split here
rather than via `line[1:col]`.
"""
function _char_split(line::AbstractString, col::Int)
    col <= 0 && return ("", String(line))
    pre = IOBuffer(); n = 0; byte_idx = firstindex(line)
    for c in line
        n >= col && break
        print(pre, c); n += 1
        byte_idx = nextind(line, byte_idx)
    end
    suf = byte_idx > ncodeunits(line) ? "" :
          String(SubString(line, byte_idx))
    return (String(take!(pre)), suf)
end

# Ex-command verbs (`:foo`). Kept here, not derived from the dispatch
# table, because the dispatch lives inside _handle_ex_command! as a chain
# of `match()` calls; centralising the list keeps autocomplete and the
# real handler in step manually — when adding a verb, add it here too.
const _EX_COMMAND_VERBS = String[
    "q", "quit", "synth", "back", "close", "w", "write", "test", "test-raw",
    "tabs", "tabnext", "tabprev", "tabprevious", "scope", "guide",
    "synth-guide", "browse", "doc", "starter", "scale", "cps",
    "mute", "unmute", "solo", "save-session", "load-session",
    "save-synth", "save-synth-as", "reload", "keydebug", "pause", "freeze",
    "copylogs", "yanklogs", "synthlib", "synth-library", "lib",
    "theme", "reload-config", "reload-cfg", "sccode", "sc",
    "panic", "hush", "stop", "sccode-tag", "sctag",
    "snip", "snippets", "snippet",
    "rec", "record", "export", "export-synth",
    "scratch", "sandbox", "e", "dsl", "dsl-guide", "synth-dsl", "safety",
    "tap", "tap-tempo", "taptempo", "bpm", "tap-strict", "tap-bar",
    "piano", "piano-rec", "piano-record",
    "wiki", "docs", "doc-wiki",
    "save", "load", "sessions", "ls-sessions",
    "tutorial", "tour", "start",
    "import",
    "mixer", "mix",
]

# Verbs that take a name argument autocompleted against the synth / sample
# / instrument registries (so `:synth wo<Tab>` finds wob1, `:doc gai<Tab>`
# finds gain). The empty value `:_all` is a sentinel — see the lookup.
const _EX_COMMAND_ARG_KIND = Dict{String,Symbol}(
    "synth"          => :synths,
    "save-synth-as"  => :synths,
    "browse"         => :all,
    "doc"            => :all,
    "starter"        => :starters,
    "scale"          => :scales,
    "mute"           => :slots,
    "unmute"         => :slots,
    "solo"           => :slots,
    "scope"          => :scopes,
    "load"           => :sessions,
    "load-session"   => :sessions,
)

const _EX_COMMAND_ARG_LITERALS = Dict{String,Vector{String}}(
    "scope" => ["off", "amp", "wave", "spectrum"],
)

"""
    _try_ex_autocomplete!(ed) -> Bool

Tab inside the ex-command line. Splits `command_buffer` on the first
space: no space → autocomplete the verb; with space → autocomplete the
argument against the verb-specific candidate set. Returns true if the
buffer was rewritten (and the Tab consumed).
"""
function _try_ex_autocomplete!(ed::TK.CodeEditor)
    buf = String(ed.command_buffer)
    isempty(buf) && return false
    sp = findfirst(' ', buf)
    if sp === nothing
        # Autocomplete the verb itself.
        partial = buf
        scored = Tuple{Int,Int,String}[]
        for verb in _EX_COMMAND_VERBS
            sc = _fuzzy_score(partial, verb)
            sc === nothing && continue
            push!(scored, (sc, length(verb), verb))
        end
        isempty(scored) && return false
        sort!(scored, by = t -> (t[1], t[2], t[3]))
        replacement = scored[1][3]
        empty!(ed.command_buffer)
        append!(ed.command_buffer, collect(replacement))
        return true
    else
        verb = buf[1:sp-1]
        rest = buf[sp+1:end]
        # Last token in `rest` is the partial to complete; earlier tokens
        # are kept verbatim. `_doc` etc. take just one arg, but being
        # token-aware here is the right shape for multi-arg verbs later.
        toks = split(rest, ' '; keepempty=true)
        partial = isempty(toks) ? "" : String(toks[end])
        candidates = _ex_arg_candidates(verb)
        isempty(candidates) && return false
        scored = Tuple{Int,Int,String}[]
        for cand in candidates
            sc = _fuzzy_score(partial, cand)
            sc === nothing && continue
            push!(scored, (sc, length(cand), cand))
        end
        isempty(scored) && return false
        sort!(scored, by = t -> (t[1], t[2], t[3]))
        replacement = scored[1][3]
        toks[end] = replacement
        new_rest = join(toks, ' ')
        new_buf = verb * " " * new_rest
        empty!(ed.command_buffer)
        append!(ed.command_buffer, collect(new_buf))
        return true
    end
end

function _ex_arg_candidates(verb::AbstractString)
    kind = get(_EX_COMMAND_ARG_KIND, String(verb), nothing)
    kind === nothing && return String[]
    if kind === :scopes
        return _EX_COMMAND_ARG_LITERALS["scope"]
    elseif kind === :synths
        return String.(keys(_SYNTH_REGISTRY))
    elseif kind === :starters
        return collect(keys(_STARTER_PACKS))
    elseif kind === :scales
        return String.(keys(_SCALES))
    elseif kind === :slots
        return [string('d', i) for i in 1:16]   # :mute d3 etc.
    elseif kind === :sessions
        dir = joinpath(pwd(), "sessions")
        isdir(dir) || return String[]
        return [splitext(f)[1] for f in readdir(dir) if endswith(f, ".txt")]
    elseif kind === :all
        out = String[]
        append!(out, String.(keys(_SYNTH_REGISTRY)))
        append!(out, String.(keys(_INSTRUMENT_REGISTRY)))
        append!(out, String.(keys(_SAMPLE_REGISTRY)))
        unique!(out)
        return out
    end
    return String[]
end

const _ACTIVE_SLOT_RX_APP   = r"^\s*@(d\d+)\b"
const _COMMENTED_SLOT_RX_APP = r"^\s*#+\s*@(d\d+)\b"

"""
    _toggle_mute_current_line!(m)

`m` key in patterns/normal mode. If the line under the cursor is an
uncommented `@dN ...` slot def → prefix it with `# ` and call
`unset_pattern!(scheduler, :dN)`. If it's commented → strip the `#`
and re-eval so the pattern comes back. Other lines log a warning.
"""
function _toggle_mute_current_line!(m::RessacApp)
    txt = TK.text(m.editor)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = m.editor.cursor_row
    col = m.editor.cursor_col
    1 <= row <= length(lines) || return
    line = String(lines[row])
    if (mt = match(_ACTIVE_SLOT_RX_APP, line)) !== nothing
        slot = Symbol(mt.captures[1])
        lines[row] = "# " * line
        TK.set_text!(m.editor, join(lines, '\n'))
        m.editor.cursor_row = row
        m.editor.cursor_col = col
        unset_pattern!(m.scheduler, slot)
        # Best-effort voice kill: parse the slot line for synth/sample
        # names and free any running voices with those defNames on SC.
        # Drones (auto_env=false) wouldn't otherwise stop on mute since
        # they have no envelope releasing them.
        _kill_voices_for_line!(m, line)
        _push_app_log!(m, "[INFO] muted $slot")
    elseif match(_COMMENTED_SLOT_RX_APP, line) !== nothing
        lines[row] = replace(line, r"^\s*#+\s*" => ""; count=1)
        TK.set_text!(m.editor, join(lines, '\n'))
        m.editor.cursor_row = row
        m.editor.cursor_col = max(0, col - 2)
        # Re-eval the now-uncommented line so the pattern comes back live.
        _eval_current_line!(m)
    else
        _push_app_log!(m, "[WARN] m: cursor line isn't a slot def, no-op")
    end
end

"""
    _kill_voices_for_line!(m, line)

Scan `line` for sample / synth / instrument names and send a
`/ressac/freeByName` for each one to SC, freeing any running voice.
Without this, muting a drone (auto_env=false) doesn't silence it —
the pattern stops scheduling but the existing voice keeps running.

Names are pulled from:
  • the leading `:name`     (e.g. `@d1 :drone |> ...`)
  • the body of `p"…"`      (mini-notation tokens — bd, hh, sn, …)
  • the body of `gate(:n, …)` and `pure(:n)` calls
"""
function _kill_voices_for_line!(m::RessacApp, line::AbstractString)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    names = Set{Symbol}()
    # Leading :name after @dN.
    mt = match(r"@d\d+\s+:(\w+)", line)
    mt !== nothing && push!(names, Symbol(mt.captures[1]))
    # p"…" mini-notation: pull alphabetic tokens (skip ~ and numbers).
    for mp in eachmatch(r"\bp\"([^\"]*)\"", line)
        body = String(mp.captures[1])
        for tok_match in eachmatch(r"[A-Za-z_]\w*", body)
            push!(names, Symbol(tok_match.match))
        end
    end
    # gate(:name, …)  /  pure(:name)  /  :name |> …
    for mn in eachmatch(r":(\w+)", line)
        push!(names, Symbol(mn.captures[1]))
    end
    isempty(names) && return
    for name in names
        send_osc(sched.osc,
            encode(OSCMessage("/ressac/freeByName", Any[String(name)])))
    end
end

"""
    _preview_word_under_cursor!(m)

K in normal mode — find the identifier under the cursor and ship a
one-shot /dirt/play. Resolution order: instrument → sample → synth.
A trailing `:N` suffix overrides the n param.
"""
function _preview_word_under_cursor!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    ed = _active_editor(m)
    1 <= ed.cursor_row <= length(ed.lines) || return
    line_chars = ed.lines[ed.cursor_row]
    isempty(line_chars) && return
    col = clamp(ed.cursor_col + 1, 1, length(line_chars))
    # Word allows : suffix for variant indices.
    is_word = c -> isletter(c) || isdigit(c) || c == '_' || c == ':'
    start_col = col
    while start_col > 1 && is_word(line_chars[start_col - 1])
        start_col -= 1
    end
    end_col = col - 1
    while end_col + 1 <= length(line_chars) && is_word(line_chars[end_col + 1])
        end_col += 1
    end
    end_col < start_col && return
    word = String(line_chars[start_col:end_col])
    mt = match(r"^([A-Za-z_]\w*)(?::(\d+))?$", word)
    mt === nothing && (_push_app_log!(m, "[WARN] K — no name at cursor"); return)
    name = Symbol(mt.captures[1])
    variant = mt.captures[2] === nothing ? 0 : parse(Int, mt.captures[2])

    args = Any[]
    kind = "?"
    if (instr = instrument_info(name)) !== nothing
        kind = "instrument"
        has_n = false
        for (k, v) in instr.params
            if k == "n"
                has_n = true
                if variant != 0
                    push!(args, "n"); push!(args, Int32(variant)); continue
                end
            end
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k); push!(args, converted)
        end
        variant != 0 && !has_n && (push!(args, "n"); push!(args, Int32(variant)))
    elseif sample_info(name) !== nothing
        kind = "sample"
        push!(args, "s"); push!(args, String(name))
        variant != 0 && (push!(args, "n"); push!(args, Int32(variant)))
    elseif synth_info(name) !== nothing
        kind = "synth"
        push!(args, "s"); push!(args, String(name))
    else
        _push_app_log!(m, "[WARN] K — no instrument/sample/synth '$(mt.captures[1])'")
        return
    end
    push!(args, "cut"); push!(args, Int32(_PREVIEW_CUT_GROUP))
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
    _push_app_log!(m, "[INFO] K — preview $kind $(mt.captures[1])")
end

function _scope_cycle_key!(m::RessacApp)
    # Use the shared cycle order so new scope types added in
    # tui_scope.jl automatically show up under S without a separate
    # edit here.
    order = _SCOPE_CYCLE_ORDER
    i = findfirst(==(_APP_SCOPE_TYPE[]), order)
    i === nothing && (i = 1)
    next = order[(i % length(order)) + 1]
    _app_scope_set!(next)
    _push_app_log!(m, "[INFO] scope → $next")
end

function _swap_focus!(m::RessacApp)
    m.focus = m.focus === :patterns ? :synth : :patterns
    _refresh_focus_flags!(m)
end

"""
    _handle_ex_command!(m, cmd)

Parse a Tachikoma-side command (string after `:`) and run the
corresponding Ressac action. Unknown commands log a warning.
"""
# ─────────────────────────────────────────────────────────────────────
# Ex-command dispatch tables
# ─────────────────────────────────────────────────────────────────────
#
# Each command is registered in one of three layers, checked in order:
#
#   _LITERAL_DISPATCH (Dict, O(1) lookup) — exact-match verbs like
#       `:q`, `:panic`. Multiple aliases register the same action.
#   _REGEX_DISPATCH (Vector, linear scan) — verbs with captures, like
#       `:synth foo`, `:cps 0.5`. Lambdas receive (m, regex_match).
#   _SPECIAL_DISPATCH (Vector, linear scan, predicate fn) — for the
#       few cases that don't fit a single regex (currently just `:e`
#       and the `:e1e5...` family).
#
# Adding a command = one line in the right table. The order regex
# entries are inserted matters only when two patterns could overlap;
# in practice they don't.

const _LITERAL_DISPATCH = Dict{String, Function}()
const _REGEX_DISPATCH   = Tuple{Regex,Function}[]
const _SPECIAL_DISPATCH = Tuple{Function,Function}[]

_register_literal!(action, aliases::String...) =
    (for a in aliases; _LITERAL_DISPATCH[a] = action; end)
_register_regex!(rx::Regex, action) =
    push!(_REGEX_DISPATCH, (rx, action))
_register_special!(pred, action) =
    push!(_SPECIAL_DISPATCH, (pred, action))

# ── Lifecycle ────────────────────────────────────────────────────────
# Bodies wrapped in `m -> fn(m)` instead of bare `fn` so the function
# names resolve at CALL time, not at registration time — most helpers
# are defined later in the same file.
_register_literal!(m -> (m.quit = true),         "q", "quit", "q!", "qa", "qa!")
_register_literal!(m -> _panic!(m),              "panic")
_register_literal!(m -> _hush!(m),               "hush", "stop", "silence")

# ── Synth tabs ───────────────────────────────────────────────────────
_register_literal!(m -> _open_sandbox_synth!(m),     "synth", "scratch", "sandbox")
_register_literal!(m -> _close_synth_pane!(m),       "back")
_register_literal!(m -> _close_active_synth_tab!(m), "close")
_register_literal!(m -> _list_synth_tabs!(m),        "tabs")
_register_literal!(m -> _cycle_synth_tab!(m; dir=+1),  "tabnext", "tabn")
_register_literal!(m -> _cycle_synth_tab!(m; dir=-1),  "tabprev", "tabp")
_register_regex!(r"^synth\s+(\w+)$",
    (m, mt) -> _open_synth_tab!(m, mt.captures[1]))

# ── Save / sessions — context-sensitive on focus ─────────────────────
_register_literal!(m -> _save_or_session(m),     "w", "save-synth")
_register_regex!(r"^w\s+(\S+)$",
    (m, mt) -> _save_or_session_named(m, mt))
_register_regex!(r"^save-session\s+(\S+)$",
    (m, mt) -> _save_session_app!(m, mt.captures[1]))
_register_regex!(r"^load-session\s+(\S+)$",
    (m, mt) -> _load_session_app!(m, mt.captures[1]))
# Short aliases — :save <name> / :load <name> / :sessions list.
_register_regex!(r"^save\s+(\S+)$",
    (m, mt) -> _save_session_app!(m, mt.captures[1]))
_register_regex!(r"^load\s+(\S+)$",
    (m, mt) -> _load_session_app!(m, mt.captures[1]))
_register_literal!(m -> _list_sessions_app!(m),
                   "sessions", "ls-sessions")

# ── Test ────────────────────────────────────────────────────────────
_register_literal!(m -> _synth_pane_open(m) && _test_current_synth!(m),
                   "test", "t")
_register_literal!(m -> _synth_pane_open(m) && _test_current_synth!(m; raw=true),
                   "test-raw")

# ── Scope ───────────────────────────────────────────────────────────
_register_literal!(m -> _scope_command!(m, :off),    "scope")
_register_regex!(r"^scope\s+(\w+)$",
    (m, mt) -> _scope_command!(m, Symbol(mt.captures[1])))

# ── Modals (browse / lib / sccode / snip / guides) ───────────────────
_register_literal!(m -> (m.modal = :guide; m.modal_scroll = 0),
                   "guide", "help", "?")
_register_literal!(m -> (m.modal = :tutorial; m.modal_scroll = 0),
                   "tutorial", "tour", "start")
_register_literal!(m -> (m.modal = :synth_guide; m.modal_scroll = 0),
                   "synth-guide")
_register_literal!(m -> (m.modal = :dsl_guide; m.modal_scroll = 0),
                   "dsl", "dsl-guide", "synth-dsl")
_register_literal!(m -> _open_wiki!(m),
                   "wiki", "docs", "doc-wiki")
_register_literal!(m -> _open_browser!(m),           "browse", "b")
_register_literal!(m -> _open_synth_library!(m),     "synthlib", "synth-library", "lib")
_register_literal!(m -> _open_mixer!(m),             "mixer", "mix")
_register_literal!(m -> _open_snippets!(m),          "snip", "snippets", "snippet")
_register_literal!(m -> _open_sccode!(m),            "sccode", "sc")
_register_regex!(r"^(?:sccode|sc)\s+(\S+)$",
    (m, mt) -> _direct_load_sccode!(m, mt.captures[1]))
_register_regex!(r"^(?:sccode-tag|sctag)\s+(\S+)$",
    (m, mt) -> _open_sccode!(m; tag = mt.captures[1]))

# ── Recording / export ──────────────────────────────────────────────
_register_literal!(m -> _toggle_recording!(m),       "rec", "record")
_register_literal!(m -> _export_current_synth!(m),   "export", "export-synth")
_register_regex!(r"^export(?:-synth)?\s+(\S+)$",
    (m, mt) -> _export_current_synth!(m; duration = parse(Float64, mt.captures[1])))
_register_regex!(r"^rec(?:ord)?\s+start\s+(\S+)$",
    (m, mt) -> _start_recording!(m, mt.captures[1]))
_register_regex!(r"^rec(?:ord)?\s+start$",
    (m, _) -> _start_recording!(m))
_register_regex!(r"^rec(?:ord)?\s+stop$",
    (m, _) -> _stop_recording!(m))

# ── Tap / piano ─────────────────────────────────────────────────────
_register_literal!(m -> _tap_start!(m),              "tap")
_register_regex!(r"^tap\s+(\w+)$",
    (m, mt) -> _tap_start!(m; sample = String(mt.captures[1])))
_register_regex!(r"^tap\s+(\w+)\s+(\d+)$",
    (m, mt) -> _tap_start!(m;
        sample = String(mt.captures[1]),
        steps  = parse(Int, mt.captures[2])))
_register_regex!(r"^tap\s+(\w+)\s+(\d+)\s+(\d+)$",
    (m, mt) -> _tap_start!(m;
        sample = String(mt.captures[1]),
        steps  = parse(Int, mt.captures[2]),
        bars   = parse(Int, mt.captures[3])))
_register_literal!(m -> _tap_start!(m; mode = :tempo),
                   "tap-tempo", "taptempo", "bpm")
# Legacy single-bar quantization for users who want the old behaviour.
# `:tap` itself defaults to loop-detection now (handles repeats AND
# falls back to single-bar when nothing repeats).
_register_literal!(m -> _tap_start!(m; mode = :pattern),
                   "tap-strict", "tap-bar")
_register_regex!(r"^tap-strict\s+(\w+)$",
    (m, mt) -> _tap_start!(m; sample = String(mt.captures[1]), mode = :pattern))
_register_literal!(m -> _piano_start!(m),            "piano")
_register_literal!(m -> _piano_start!(m; record = true),
                   "piano-rec", "piano-record")
_register_regex!(r"^piano\s+(\w+)$",
    (m, mt) -> _piano_start!(m; synth = String(mt.captures[1])))
_register_regex!(r"^piano-rec\s+(\w+)$",
    (m, mt) -> _piano_start!(m; synth = String(mt.captures[1]), record = true))

# ── Theme / config / safety ─────────────────────────────────────────
_register_literal!(m -> _push_app_log!(m,
        "[INFO] themes: " * join(_available_themes(), ", ")),
    "theme")
_register_regex!(r"^theme\s+(\w+)$",
    (m, mt) -> _theme_switch(m, mt))
_register_literal!(m -> _reload_config_action(m),    "reload-config", "reload-cfg")
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :safety on|off — toggle master limiter + DC block + 10Hz HPF (default ON)"),
    "safety")
_register_regex!(r"^safety\s+(on|off)$",
    (m, mt) -> _safety_toggle(m, mt))

# ── Misc / utilities ────────────────────────────────────────────────
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :doc <name> — try gain/release/cutoff/cps/gate/…"),
    "doc")
_register_regex!(r"^doc\s+(\w+)$",
    (m, mt) -> _doc_command!(m, mt.captures[1]))
_register_literal!(m -> _keydebug_toggle(m),         "keydebug")
_register_literal!(m -> (m.paused = true;
        _push_app_log!(m, "[INFO] paused — shift-drag to select & copy, any key resumes")),
    "pause", "freeze")
_register_literal!(m -> _copy_logs_to_clipboard!(m), "copylogs", "yanklogs")

# ── Starter / scale / cps ───────────────────────────────────────────
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :starter <genre> — " * join(sort!(collect(keys(_STARTER_PACKS))), ", ")),
    "starter")
_register_regex!(r"^starter\s+(\w+)$",
    (m, mt) -> _starter_command!(m, mt.captures[1]))
# :import path  →  copies a .wav into plugins/user-samples/<basename>/
#                  and registers it so it's usable as a sample name.
# :import path as name  → same but rename to `name`.
_register_regex!(r"^import\s+(\S+?)\s+as\s+(\w+)$",
    (m, mt) -> _import_wav!(m, mt.captures[1], mt.captures[2]))
_register_regex!(r"^import\s+(\S+)$",
    (m, mt) -> _import_wav!(m, mt.captures[1], nothing))
_register_literal!(m -> _push_app_log!(m,
        "[INFO] current scale: $(_CURRENT_SCALE[])"),
    "scale")
_register_regex!(r"^scale\s+(\w+)$",
    (m, mt) -> _scale_set(m, mt))
_register_regex!(r"^cps\s+(\S+)$",
    (m, mt) -> _cps_set(m, mt))

# ── Mute / solo ─────────────────────────────────────────────────────
_register_regex!(r"^mute\s+(d\d+)$",
    (m, mt) -> _mute_pattern_slot!(m, Symbol(mt.captures[1])))
_register_regex!(r"^unmute\s+(d\d+)$",
    (m, mt) -> _unmute_pattern_slot!(m, Symbol(mt.captures[1])))
_register_literal!(m -> _unmute_all_patterns!(m),    "unmute", "unsolo")
_register_regex!(r"^solo\s+(d\d+)$",
    (m, mt) -> _solo_pattern_slot!(m, Symbol(mt.captures[1])))

# ── Pattern shortcut DSL (:sg0.9 etc) — matched by _SHORTCUT_RX ──────
_register_regex!(_SHORTCUT_RX,
    (m, mt) -> _apply_pattern_shortcut!(m,
        mt.captures[1] == "n",
        String(mt.captures[2]),
        strip(String(mt.captures[3])),
        mt.captures[4] == "N"))

# ── Eval combinators (:e / :e1e5e6) ──────────────────────────────────
_register_special!(
    cmd -> cmd == "e" || (occursin('e', cmd) &&
                          all(c -> c == 'e' || isdigit(c), cmd)),
    (m, cmd) -> begin
        if cmd == "e"
            _eval_pattern_blocks!(m, :all)
        else
            ids = filter(!isempty, split(cmd, 'e'; keepempty=false))
            _eval_pattern_blocks!(m, Symbol[Symbol("d", n) for n in ids])
        end
    end)

# Small named helpers — kept out of the inline lambdas above so they
# stay readable + greppable. Each takes (m, mt::RegexMatch).
function _save_or_session(m::RessacApp)
    if m.focus === :synth && _synth_pane_open(m)
        _save_current_synth!(m)
    else
        _save_session_app!(m, "_last")
    end
end
function _save_or_session_named(m::RessacApp, mt::RegexMatch)
    if m.focus === :synth && _synth_pane_open(m)
        _save_current_synth!(m; new_name = mt.captures[1])
    else
        _save_session_app!(m, mt.captures[1])
    end
end
function _theme_switch(m::RessacApp, mt::RegexMatch)
    name = Symbol(mt.captures[1])
    if _apply_theme!(name)
        _push_app_log!(m, "[INFO] theme → $name")
    else
        _push_app_log!(m, "[ERROR] theme '$name' not found — try: " *
                       join(_available_themes()[1:min(end,8)], ", ") * ", …")
    end
end
function _reload_config_action(m::RessacApp)
    cfg = _load_ressac_config!()
    _apply_theme!(cfg.theme)
    _push_app_log!(m, "[INFO] config reloaded — theme=$(cfg.theme), t_init=$(cfg.t_hold_initial_ms)ms accel=$(cfg.t_hold_accel)")
end
function _safety_toggle(m::RessacApp, mt::RegexMatch)
    on = mt.captures[1] == "on"
    sched = _LIVE_SCHEDULER[]
    if sched !== nothing
        send_osc(sched.osc, encode(OSCMessage("/ressac/safety", Any[Int32(on ? 1 : 0)])))
    end
    _push_app_log!(m, "[INFO] safety $(on ? "ON" : "OFF") — master limiter + DC block + 10Hz HPF")
end
function _keydebug_toggle(m::RessacApp)
    m.keydebug = !m.keydebug
    _push_app_log!(m, "[INFO] keydebug $(m.keydebug ? "ON" : "OFF") — every keypress will be logged")
end
function _scale_set(m::RessacApp, mt::RegexMatch)
    name = Symbol(mt.captures[1])
    if haskey(_SCALES, name)
        _CURRENT_SCALE[] = name
        _push_app_log!(m, "[INFO] scale set to :$name (use degree(x))")
    else
        _push_app_log!(m, "[WARN] :scale — unknown '$name'")
    end
end
function _cps_set(m::RessacApp, mt::RegexMatch)
    try
        set_cps!(m.scheduler, parse(Float64, mt.captures[1]))
        _push_app_log!(m, "[INFO] cps = $(mt.captures[1])")
    catch err
        _push_app_log!(m, "[ERROR] cps: $(sprint(showerror, err))")
    end
end

"""
    _handle_ex_command!(m, cmd)

Dispatch an ex-command (without the leading `:`). Layered: literal
lookup first, then regex scan, then the special-predicate scan, then
unknown fallback.
"""
function _handle_ex_command!(m::RessacApp, cmd::AbstractString)
    s = String(cmd)
    # 1. Literal exact-match (O(1))
    h = get(_LITERAL_DISPATCH, s, nothing)
    h !== nothing && (h(m); return)
    # 2. Regex patterns with captures
    for (rx, fn) in _REGEX_DISPATCH
        mt = match(rx, s)
        mt !== nothing && (fn(m, mt); return)
    end
    # 3. Predicate-based specials (irregular grammars)
    for (pred, fn) in _SPECIAL_DISPATCH
        pred(s) && (fn(m, s); return)
    end
    _push_app_log!(m, "[WARN] unknown command: :$s")
end

"""
    _starter_command!(m, genre)

Replace the patterns buffer with a starter sketch (the same packs the
old TUI used). User can :back to whatever they had before? No — we
overwrite without confirmation; vim convention says you should :w
first if you want to keep things.
"""
function _starter_command!(m::RessacApp, genre::AbstractString)
    pack = get(_STARTER_PACKS, String(genre), nothing)
    if pack === nothing
        _push_app_log!(m, "[WARN] :starter — no pack '$genre'")
        return
    end
    TK.set_text!(m.editor, join(pack, "\n"))
    m.editor.cursor_row = 1
    m.editor.cursor_col = 0
    _push_app_log!(m, "[INFO] loaded :starter $genre — eval each @dN with e")
end

"""
    _import_wav!(m, src_path, name_or_nothing)

Copy `src_path` into `plugins/user-samples/<name>/<name>_0.wav` and
register it as a single-variant SampleEntry so the user can call it
in patterns immediately. If `name_or_nothing` is nothing, the
basename (minus extension) of `src_path` becomes the sample name.

Also fires `/dirt/loadSampleFolder` on the SC side so SuperDirt
picks up the new audio without a restart.

Subsequent imports of the same name add `_1`, `_2`, … variants under
the existing folder rather than overwriting — calling `:s bd` then
plays one variant at random, with `n(N)` picking a specific one.
"""
function _import_wav!(m::RessacApp, src_path::AbstractString,
                     name_or_nothing::Union{Nothing,AbstractString})
    src_path = String(src_path)
    if !isfile(src_path)
        _push_app_log!(m, "[ERROR] :import — no file at $src_path")
        return
    end
    name = name_or_nothing === nothing ?
        splitext(basename(src_path))[1] : String(name_or_nothing)
    name = replace(name, r"[^A-Za-z0-9_]" => "_")
    isempty(name) && (_push_app_log!(m, "[ERROR] :import — empty name"); return)
    dest_dir = joinpath(pwd(), "plugins", "user-samples", name)
    isdir(dest_dir) || mkpath(dest_dir)
    # Find the next variant index — preserves existing samples in the
    # folder so the user can pile up versions like bd_0, bd_1, bd_2…
    existing = filter(f -> endswith(f, ".wav"), readdir(dest_dir))
    idx = length(existing)
    dest = joinpath(dest_dir, "$(name)_$(idx).wav")
    try
        cp(src_path, dest; force = false)
    catch err
        _push_app_log!(m, "[ERROR] :import copy → $(sprint(showerror, err))")
        return
    end
    # Register (or re-register with the extra variant). variants must
    # be the full sorted list of files in the bank folder.
    variants = sort!([joinpath(dest_dir, f) for f in readdir(dest_dir)
                      if endswith(f, ".wav")])
    sym = Symbol(name)
    haskey(_SAMPLE_REGISTRY, sym) && delete!(_SAMPLE_REGISTRY, sym)
    register_sample!(SampleEntry(sym, "user-samples", dest_dir, variants,
        Dict{String,Any}("description" => "imported via :import")))
    # Tell SuperDirt to load the (new or extended) folder.
    sched = _LIVE_SCHEDULER[]
    sched !== nothing && send_osc(sched.osc,
        encode(OSCMessage("/dirt/loadSampleFolder", Any[dest_dir])))
    _push_app_log!(m,
        "[INFO] :import → $(name) ($(length(variants)) variant$(length(variants) == 1 ? "" : "s")) " *
        "— use it in patterns: p\"$(name)\"")
end

# ---------------------------------------------------------------------
# Live mute / solo on the scheduler (no buffer mutation)
# ---------------------------------------------------------------------

const _APP_MUTED_PATTERNS = Dict{Symbol, Pattern}()

function _mute_pattern_slot!(m::RessacApp, slot::Symbol)
    pat = get(m.scheduler.patterns, slot, nothing)
    if pat === nothing
        _push_app_log!(m, "[WARN] :mute — slot $slot has no live pattern")
        return
    end
    _APP_MUTED_PATTERNS[slot] = pat
    unset_pattern!(m.scheduler, slot)
    _push_app_log!(m, "[INFO] muted $slot")
end

function _unmute_pattern_slot!(m::RessacApp, slot::Symbol)
    pat = get(_APP_MUTED_PATTERNS, slot, nothing)
    if pat === nothing
        _push_app_log!(m, "[WARN] :unmute — $slot wasn't muted")
        return
    end
    set_pattern!(m.scheduler, slot, pat)
    delete!(_APP_MUTED_PATTERNS, slot)
    _push_app_log!(m, "[INFO] unmuted $slot")
end

function _unmute_all_patterns!(m::RessacApp)
    n = length(_APP_MUTED_PATTERNS)
    for (slot, pat) in _APP_MUTED_PATTERNS
        set_pattern!(m.scheduler, slot, pat)
    end
    empty!(_APP_MUTED_PATTERNS)
    _push_app_log!(m, "[INFO] unmuted $n slot(s)")
end

function _save_session_app!(m::RessacApp, name::AbstractString)
    dir = joinpath(pwd(), "sessions")
    isdir(dir) || mkpath(dir)
    path = joinpath(dir, String(name) * ".txt")
    try
        write(path, TK.text(m.editor))
        _push_app_log!(m, "[INFO] saved session → $path")
    catch err
        _push_app_log!(m, "[ERROR] save-session: $(sprint(showerror, err))")
    end
end

function _load_session_app!(m::RessacApp, name::AbstractString)
    path = joinpath(pwd(), "sessions", String(name) * ".txt")
    if !isfile(path)
        _push_app_log!(m, "[ERROR] load: no file at $path — try :sessions to list")
        return
    end
    try
        TK.set_text!(m.editor, read(path, String))
        m.editor.cursor_row = 1; m.editor.cursor_col = 0
        _push_app_log!(m, "[INFO] loaded session '$name' — press E to eval all blocks")
    catch err
        _push_app_log!(m, "[ERROR] load-session: $(sprint(showerror, err))")
    end
end

function _list_sessions_app!(m::RessacApp)
    dir = joinpath(pwd(), "sessions")
    if !isdir(dir)
        _push_app_log!(m, "[INFO] no sessions dir yet — :save <name> creates it")
        return
    end
    files = sort!([f for f in readdir(dir) if endswith(f, ".txt")])
    if isempty(files)
        _push_app_log!(m, "[INFO] (no saved sessions)")
        return
    end
    names = join((splitext(f)[1] for f in files), ", ")
    _push_app_log!(m, "[INFO] sessions: $names  (use :load <name>)")
end

function _solo_pattern_slot!(m::RessacApp, solo_slot::Symbol)
    muted = 0
    for (other_slot, pat) in collect(m.scheduler.patterns)
        other_slot == solo_slot && continue
        _APP_MUTED_PATTERNS[other_slot] = pat
        unset_pattern!(m.scheduler, other_slot)
        muted += 1
    end
    _push_app_log!(m, "[INFO] solo $solo_slot (silenced $muted others)")
end

function _doc_command!(m::RessacApp, name::AbstractString)
    desc = _lookup_livedoc(name)
    if desc === nothing
        _push_app_log!(m, "[WARN] :doc — no entry for '$name'")
        return
    end
    _push_app_log!(m, "[doc] $name — $desc")
    # Surface any registered usage examples. Each line gets its own
    # log entry so it copy-pastes cleanly with :copylogs.
    examples = get(_PARAM_EXAMPLES, String(name), String[])
    isempty(examples) && return
    _push_app_log!(m, "[doc]   examples:")
    for ex in examples
        _push_app_log!(m, "[doc]     $ex")
    end
end

# ---------------------------------------------------------------------
# Browser modal
# ---------------------------------------------------------------------

function _open_browser!(m::RessacApp)
    m.modal = :browse
    m.browser_query = ""
    m.browser_cursor = 1
    m.browser_filter = :all
    m.modal_scroll = 0
end

# Mixer modal — extracted to src/modal_mixer.jl
include("modal_mixer.jl")


# Synth library picker — extracted to src/modal_synth_library.jl
include("modal_synth_library.jl")

function _browser_entries(m::RessacApp)
    out = _BrowserEntry[]
    if m.browser_filter === :all || m.browser_filter === :instruments
        for e in values(_INSTRUMENT_REGISTRY)
            push!(out, _BrowserEntry(:instrument, e.name, e.plugin, _instrument_summary(e)))
        end
    end
    if m.browser_filter === :all || m.browser_filter === :samples
        for e in values(_SAMPLE_REGISTRY)
            push!(out, _BrowserEntry(:sample, e.name, e.plugin, _sample_summary(e)))
        end
    end
    if m.browser_filter === :all || m.browser_filter === :synths
        for e in values(_SYNTH_REGISTRY)
            push!(out, _BrowserEntry(:synth, e.name, e.plugin, _synth_summary(e)))
        end
    end
    isempty(m.browser_query) || (out = filter(e -> _fuzzy_score(m.browser_query, String(e.name)) !== nothing, out))
    sort!(out; by = e -> (String(e.kind), String(e.name)))
    return out
end

function _handle_browser_key!(m::RessacApp, evt::TK.KeyEvent)
    entries = _browser_entries(m)
    n = length(entries)
    if evt.key === :escape || (evt.char == 'q' && isempty(m.browser_query))
        m.modal = :none
    elseif evt.key === :enter
        if 1 <= m.browser_cursor <= n
            _browser_insert!(m, entries[m.browser_cursor])
        end
        m.modal = :none
    elseif evt.char == 'j' || evt.key === :down
        m.browser_cursor = min(m.browser_cursor + 1, max(n, 1))
    elseif evt.char == 'k' || evt.key === :up
        m.browser_cursor = max(m.browser_cursor - 1, 1)
    elseif evt.char == 'K' || evt.char == ' '
        if 1 <= m.browser_cursor <= n
            _browser_preview!(m, entries[m.browser_cursor])
        end
    elseif evt.key === :tab
        filters = (:all, :instruments, :samples, :synths)
        i = findfirst(==(m.browser_filter), filters)
        m.browser_filter = filters[(i % length(filters)) + 1]
        m.browser_cursor = 1
    elseif evt.key === :backspace
        if !isempty(m.browser_query)
            m.browser_query = m.browser_query[1:prevind(m.browser_query, end)]
            m.browser_cursor = 1
        end
    elseif evt.char != '\0' && _is_typable_ascii(evt.char)
        m.browser_query *= string(evt.char)
        m.browser_cursor = 1
    end
end

function _browser_preview!(m::RessacApp, entry::_BrowserEntry)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    now = time()
    now - m.browser_last_preview < 0.05 && return
    m.browser_last_preview = now
    args = Any[]
    if entry.kind === :instrument
        instr = instrument_info(entry.name)
        instr === nothing && return
        for (k, v) in instr.params
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k); push!(args, converted)
        end
    elseif entry.kind === :sample
        push!(args, "s"); push!(args, String(entry.name))
    elseif entry.kind === :synth
        push!(args, "s"); push!(args, String(entry.name))
        push!(args, "release"); push!(args, Float32(0.4))
    end
    push!(args, "cut"); push!(args, Int32(_PREVIEW_CUT_GROUP))
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
end

function _browser_insert!(m::RessacApp, entry::_BrowserEntry)
    ed = _active_editor(m)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ed.cursor_row
    1 <= row <= length(lines) || (push!(lines, ""); row = length(lines))
    line = lines[row]
    col = clamp(ed.cursor_col, 0, lastindex(line))
    name = String(entry.name)
    prefix = col > 0 ? line[1:col] : ""
    suffix = col >= lastindex(line) ? "" : line[col+1:end]
    lines[row] = prefix * name * suffix
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_col = lastindex(prefix) + lastindex(name)
    _push_app_log!(m, "[INFO] inserted $(entry.kind) $name")
end

function _render_browser_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    entries = _browser_entries(m)
    n = length(entries)
    inner = _render_modal_block!(buf, area;
        title = "BROWSE SOUNDS",
        title_right = "Tab category · / search · j/k · Space preview · Enter insert · q",
        w_max = 120,
        h_target = max(14, min(area.height - 4, n + 8)))
    inner.width < 20 && return
    # ── Row 1: category tab strip ─────────────────────────────────
    filters = (:all, :instruments, :samples, :synths)
    tab_x = inner.x
    for (i, f) in enumerate(filters)
        label = String(f)
        chip  = " " * label * " "
        is_active = f === m.browser_filter
        sty = is_active ? TK.tstyle(:accent, bold = true) :
                          TK.tstyle(:text_dim)
        tab_x + textwidth(chip) > inner.x + inner.width && break
        TK.set_string!(buf, tab_x, inner.y, chip, sty)
        tab_x += textwidth(chip)
        if i < length(filters) && tab_x + 2 < inner.x + inner.width
            TK.set_string!(buf, tab_x, inner.y, "·", TK.tstyle(:text_dim))
            tab_x += 1
        end
    end
    # ── Row 2: search bar ─────────────────────────────────────────
    sb_text = "⌕ " * m.browser_query * "▏"
    TK.set_string!(buf, inner.x, inner.y + 1,
                   first(rpad(sb_text, inner.width), inner.width),
                   TK.tstyle(:text_dim))
    # Body fills rows 3..end.
    body_y = inner.y + 2
    body_h = inner.height - 2
    visible = m.modal_scroll + 1 <= n ?
              entries[(m.modal_scroll + 1):min(end, m.modal_scroll + body_h)] :
              _BrowserEntry[]
    for i in 1:body_h
        line = ""
        if i <= length(visible)
            e = visible[i]
            abs_idx = m.modal_scroll + i
            marker = abs_idx == m.browser_cursor ? "▶ " : "  "
            kind_letter = e.kind === :instrument ? "I" :
                          e.kind === :sample     ? "S" : "Y"
            line = "$(marker)[$kind_letter] $(rpad(String(e.name), 18))  $(e.summary)"
        end
        style = if i <= length(visible) && (m.modal_scroll + i) == m.browser_cursor
            TK.tstyle(:accent, bold = true)
        else
            TK.tstyle(:text)
        end
        TK.set_string!(buf, inner.x, body_y + i - 1,
                       first(rpad(line, inner.width), inner.width), style)
    end
end

_is_typable_ascii(c::Char) = ncodeunits(c) == 1 && (isprint(c) && c != '\0')

# ---------------------------------------------------------------------
# Live doc row
# ---------------------------------------------------------------------

"""
    _render_livedoc_row(m, area, buf)

Pluto-style: look at the word under the cursor in the active editor,
look it up via `_lookup_livedoc`, render one line of doc in green.
Empty when no entry found.
"""
function _render_livedoc_row(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    ed = _active_editor(m)
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

_modal_lines(m::RessacApp) =
    m.modal === :guide       ? _GUIDE_LINES :
    m.modal === :synth_guide ? _SYNTH_GUIDE_LINES :
    m.modal === :dsl_guide   ? _DSL_GUIDE_LINES :
    m.modal === :tutorial    ? _TUTORIAL_LINES :
    String[]

"""
    _TUTORIAL_LINES

The 5-minute onboarding tour for users coming from GUI DAWs. Each
"card" is a group of lines separated by a blank header; users scroll
with j/k. Designed to be readable end-to-end in under 5 minutes
without prior knowledge of vim or live-coding.
"""
const _TUTORIAL_LINES = String[
    "── 5-minute tour: from zero to first beat ──",
    "(j/k or ↑/↓ to scroll · q to close · :wiki for the full docs)",
    "",
    "▓ CARD 1 — Two modes, like vim",
    "  NORMAL mode (you start here) — keys are commands",
    "  INSERT mode — keys type letters into the buffer",
    "",
    "    i      enter INSERT (start typing)",
    "    Esc    back to NORMAL (commands again)",
    "",
    "  The mode shows in the bottom-left corner: [NORMAL] / [INSERT].",
    "",
    "▓ CARD 2 — Make a sound",
    "  In NORMAL mode, press:",
    "",
    "    E      eval ALL @dN blocks in the buffer (you'll hear them)",
    "    e      eval just the line under the cursor",
    "",
    "  Lines you eval flash green for a moment. The playhead",
    "  (orange-ish bar) shows which note plays right now.",
    "",
    "▓ CARD 3 — Stop / mute / panic",
    "",
    "    m      mute the @dN slot under the cursor (toggles)",
    "    :hush  soft stop (sounds fade out naturally)",
    "    ,      same as :hush, one keystroke",
    "    !      PANIC: kill every running sound immediately",
    "",
    "▓ CARD 4 — Discover sounds & snippets",
    "",
    "    Space b   browse all available sounds (Tab cycles types)",
    "    :snip     browse multi-line snippet templates",
    "    Space d   templated pattern line: @d_ p\"_\" (Tab between fields)",
    "    Space g   templated gain pipe: |> gain(_)",
    "    :starter house|trap|lofi|ambient   load a genre starter",
    "",
    "▓ CARD 5 — Where to go next",
    "",
    "    :guide      the full keybinding cheat-sheet",
    "    :wiki       deeper docs (mini-notation, DSL, scope, themes)",
    "    :doc gain   description + usage examples for any param",
    "    :tap        tap a rhythm, Ressac writes the @dN line",
    "    :synth wob  open a synth-design tab on the right",
    "",
    "When you're ready to start fresh: select all (V then G), d to delete,",
    "i to insert, type your own patterns. Use Esc + e to hear them.",
    "",
    "Press q to close this tour. Run :tutorial any time to come back.",
]

const _DSL_GUIDE_LINES = String[
    "── Synth DSL — Julia → SuperCollider ── (j/k scroll, q close)",
    "",
    "Bring it in: `using Ressac.SynthDSL`",
    "",
    "▓ MINIMAL — three tokens, full SynthDef:",
    "",
    "    @synth :bare saw(:freq)",
    "",
    "Auto-fills freq=220, sustain=0.5, gain=0.5, an Env.linen envelope",
    "(doneAction:2 so it self-frees), multiply by :gain, and DirtPan",
    "routing to SuperDirt.",
    "",
    "▓ EXPLICIT PARAMS:",
    "",
    "    @synth :acid (freq=80, cutoff=2000, q=0.3) saw(:freq) |>",
    "        rlpf(:cutoff, :q) |> tanh_drive(1.5)",
    "",
    "    @synth :wob (freq=80) saw(:freq) |>",
    "        rlpf(lfo(6; low=300, high=2000), 0.25)",
    "",
    "▓ DRONE (no auto-free):",
    "",
    "    @synth :pad (freq=110, sustain=999) (auto_env=false,)",
    "        saw(:freq) |> low_pass(800) |> stereo_pan(0)",
    "",
    "▓ ENVELOPES — multiplied into the chain:",
    "",
    "    saw(:freq) |> env_perc(0.005, :sustain)        # snappy",
    "    saw(:freq) |> env_linen(0.01, :sustain, 0.2)   # held",
    "    saw(:freq) |> env_adsr(0.01, 0.1, 0.6, 0.3)    # gated (needs :gate)",
    "    sin_osc(:freq) |> env_sine(:sustain)           # bell curve",
    "    saw(:freq) |> env_pairs([0.1, 0.4, 0.5], [0, 1, 0.3, 0]; curve=:exp)",
    "",
    "▓ FILTERS:",
    "    low_pass(2000)               high_pass(200)",
    "    band_pass(1000, 0.4)         band_reject(800, 0.4)",
    "    rlpf(1500, 0.3)              rhpf(800, 0.3)        # resonant",
    "    moog_ff(1200, 2)             leak_dc()",
    "    b_low_pass(2000)             b_peak_eq(1000, 0.7, 6)",
    "",
    "▓ MODULATORS — return Sig, not curried:",
    "    lfo(6; low=300, high=2000)   # sin lfo mapped to range",
    "    lfo_saw / lfo_tri / lfo_pulse",
    "    line(start, stop, dur)       x_line(...)         # one-shot ramps",
    "    lag_kr(input, lag_time)      # smooths an input over time",
    "",
    "▓ DELAYS / REVERB:",
    "    delay_n(0.25) / delay_l / delay_c",
    "    comb_l(0.05, 1.5)            # delay + feedback",
    "    free_verb(0.6, 0.8, 0.5)     # mix, room, damp",
    "    g_verb(roomsize=30, revtime=4)",
    "",
    "▓ NOISE:",
    "    white() / pink() / brown() / gray()",
    "    dust(60)                     # random impulses",
    "    crackle(1.95)                # chaos generator",
    "",
    "▓ SHAPING:",
    "    tanh_drive(1.5)              # soft saturation",
    "    soft_clip() / cubic() / clip(-0.8, 0.8) / fold() / wrap()",
    "    decimator(11025, 8)          # bit-crush",
    "",
    "▓ ARITHMETIC — Sig supports + - * / and pipes:",
    "    sin_osc(:freq) + 0.3 * white()    # carrier + bit of hiss",
    "    saw(:freq) * lfo(2)               # ring-mod",
    "",
    "▓ STEREO:",
    "    stereo_pan(lfo(0.5))           # auto-pan",
    "    stereo_balance(other_sig, 0)   # crossfade",
    "    splay(0.8)                     # widen a multichannel input",
    "",
    "▓ PATTERNS — use the registered synth:",
    "",
    "    @d1 :acid |> n(p\"0 3 5 7 3 5 0 7\")",
    "",
    "▓ COOKBOOK — copy-paste-tweak:",
    "",
    "  # Kick:",
    "    @synth :kick (sustain=0.4) sin_osc(line(80, 40, 0.05)) |> env_perc(0.001, :sustain)",
    "",
    "  # FM bell:",
    "    @synth :fmbell (freq=440, sustain=1.5) sin_osc(:freq + sin_osc(:freq*1.41) *",
    "        line(800, 50, 0.5)) |> env_perc(0, :sustain)",
    "",
    "  # Acid bass with env on cutoff:",
    "    @synth :acid (freq=60, sustain=0.3) saw(:freq) |>",
    "        rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)",
    "",
    "  # Plucked string (Karplus-ish):",
    "    @synth :pluck (freq=220) comb_l(line(1/220, 1/220, 0.001), 0.7) *",
    "        white() |> env_perc(0.001, 0.001)",
    "",
    "  # Pad with chorus + reverb:",
    "    @synth :pad (freq=220, sustain=4) (auto_env=false,)",
    "        saw(:freq) + saw(:freq * 1.007) + saw(:freq * 0.993) |>",
    "        low_pass(2000) |> free_verb(0.5, 0.9, 0.5)",
    "",
    "▓ INSPECT WITHOUT PLAYING:",
    "    synth_source(:name, sig; params=...)   # returns the SC string",
    "",
]

function _handle_modal_key!(m::RessacApp, evt::TK.KeyEvent)
    if m.modal === :browse
        _handle_browser_key!(m, evt)
        return
    elseif m.modal === :synth_library
        _handle_synthlib_key!(m, evt)
        return
    elseif m.modal === :sccode
        _handle_sccode_key!(m, evt)
        return
    elseif m.modal === :snippets
        _handle_snippets_key!(m, evt)
        return
    elseif m.modal === :wiki
        _handle_wiki_key!(m, evt)
        return
    elseif m.modal === :mixer
        _handle_mixer_key!(m, evt)
        return
    end
    lines = _modal_lines(m)
    n = length(lines)
    if evt.key === :escape || evt.char == 'q'
        m.modal = :none; m.modal_scroll = 0
    elseif evt.char == 'j' || evt.key === :down
        m.modal_scroll = min(m.modal_scroll + 1, max(0, n - 1))
    elseif evt.char == 'k' || evt.key === :up
        m.modal_scroll = max(0, m.modal_scroll - 1)
    elseif evt.char == 'G'
        m.modal_scroll = max(0, n - 1)
    elseif evt.char == 'g'
        m.modal_scroll = 0
    end
end

"""
    _render_modal!(m, area, buf)

Draw a centered modal box over the rendered scene. Pulls the line
vector from `_modal_lines(m)`, applies `m.modal_scroll`, clips lines
to box width.
"""
function _render_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    lines = _modal_lines(m)
    isempty(lines) && return
    title = m.modal === :guide       ? "GUIDE" :
            m.modal === :synth_guide ? "SYNTH GUIDE" :
            m.modal === :dsl_guide   ? "DSL GUIDE" :
            m.modal === :tutorial    ? "TUTORIAL · 5-minute tour" : "INFO"
    inner = _render_modal_block!(buf, area;
        title = title,
        title_right = "j/k scroll · q close",
        w_max = 100,
        h_target = min(length(lines) + 2, area.height - 4))
    visible_end = min(length(lines), m.modal_scroll + inner.height)
    visible = m.modal_scroll + 1 <= length(lines) ?
              lines[(m.modal_scroll + 1):visible_end] :
              String[]
    for i in 1:inner.height
        line = i <= length(visible) ? visible[i] : ""
        TK.set_string!(buf, inner.x, inner.y + i - 1,
                       first(line, inner.width), TK.tstyle(:text))
    end
end

function _scope_command!(m::RessacApp, type::Symbol)
    if _app_scope_set!(type)
        _push_app_log!(m, "[INFO] :scope $type")
    else
        _push_app_log!(m, "[ERROR] :scope — unknown type or no live session")
    end
end

"""
    _render_app_scope(m, area, buf)

Draw the current scope frame into `area`. Pulls latest data from the
`_APP_SCOPE_DATA` global. amp = bouncing meter; wave = braille
waveform via Canvas (zoom from `m.scope_zoom`); spectrum = vertical
bars (1 column per band).
"""
function _render_app_scope(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    type = _APP_SCOPE_TYPE[]
    data = _APP_SCOPE_DATA[]
    h, w = area.height, area.width
    h < 2 && return
    # Title row — show the zoom for wave so the user sees the keys' effect.
    title = type === :wave ?
        "scope: wave  Y×$(round(m.scope_zoom; digits=2)) X×$(round(m.scope_zoom_x; digits=2))   (+/-/= amp,  >/</= time)" :
        "scope: $type   (S cycles, :scope <type> picks: amp wave spectrum xy goni spectrogram peak pitch onset hist corr)"
    TK.set_string!(buf, area.x, area.y, rpad(first(title, w), w),
                   TK.tstyle(:accent, bold=true))
    body_y = area.y + 1
    body_h = h - 1
    body_area = TK.Rect(area.x, body_y, w, body_h)
    if isempty(data)
        TK.set_string!(buf, area.x, body_y,
                       "  (waiting for audio — press T to test the synth)",
                       TK.tstyle(:text_dim))
        return
    end
    if type === :amp
        _app_render_amp(data, body_area, buf)
    elseif type === :wave
        _app_render_wave(data, body_area, buf;
                         zoom = m.scope_zoom, zoom_x = m.scope_zoom_x)
    elseif type === :spectrum
        _app_render_spectrum(data, body_area, buf)
    elseif type === :xy
        _app_render_xy(data, body_area, buf; rotate45=false)
    elseif type === :goni
        _app_render_xy(data, body_area, buf; rotate45=true)
    elseif type === :spectrogram
        _app_render_spectrogram(body_area, buf)
    elseif type === :peak
        _app_render_peak(data, body_area, buf)
    elseif type === :pitch
        _app_render_pitch(data, body_area, buf)
    elseif type === :onset
        _app_render_onset(data, body_area, buf)
    elseif type === :hist
        _app_render_hist(data, body_area, buf)
    elseif type === :corr
        _app_render_corr(data, body_area, buf)
    end
end

function _app_render_amp(data, area::TK.Rect, buf::TK.Buffer)
    amp = clamp(Float64(data[1]), 0.0, 1.0)
    bar_w = floor(Int, amp * area.width)
    bar = "▌" ^ bar_w
    db = amp > 0 ? round(20 * log10(amp); digits=1) : -Inf
    label = " amp $(round(amp; digits=3)) ($(db) dB)"
    TK.set_string!(buf, area.x, area.y,
                   rpad(bar * label, area.width),
                   TK.tstyle(:primary))
end

function _app_render_wave(data, area::TK.Rect, buf::TK.Buffer;
                          zoom::Float64 = 1.0, zoom_x::Float64 = 1.0)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # X-zoom: keep a slice of `data` centred around the midpoint. Larger
    # zoom_x → narrower visible slice → fewer samples stretched across
    # the same column count, so each cycle of the waveform appears
    # wider on screen. zoom_x<1 isn't very useful (only 64 samples
    # arrive — you'd just be padding) but we still clamp at >=2 samples
    # to keep the renderer's interpolation defined.
    n_visible = clamp(round(Int, n / max(zoom_x, 0.01)), 2, n)
    start_idx = max(1, (n - n_visible) ÷ 2 + 1)
    end_idx   = min(n, start_idx + n_visible - 1)
    sliced = @view data[start_idx:end_idx]
    nv = length(sliced)
    # Adaptive peak normalize so quiet signals fill the panel; user zoom
    # then multiplies on top of that. zoom=1.0 means "fill the panel";
    # zoom>1 pushes the wave off-screen on transients (deliberate — lets
    # the user see fine structure in quiet sections).
    peak = maximum(abs.(sliced); init=0.001f0)
    auto_scale = peak < 0.05 ? 1.0 : 1.0 / max(Float64(peak), 0.05)
    scale = auto_scale * zoom
    centre_dy = height_dots ÷ 2
    last_dy = centre_dy
    for dx in 0:(width_dots - 1)
        sample_idx = clamp(round(Int, dx / max(1, width_dots - 1) * (nv - 1)) + 1, 1, nv)
        val = clamp(Float64(sliced[sample_idx]) * scale, -1.0, 1.0)
        dy = clamp(round(Int, (1 - (val + 1) / 2) * (height_dots - 1)), 0, height_dots - 1)
        TK.set_point!(canvas, dx, dy)
        if dx > 0
            for fill_dy in min(dy, last_dy):max(dy, last_dy)
                TK.set_point!(canvas, dx, fill_dy)
            end
        end
        last_dy = dy
    end
    TK.render(canvas, area, buf)
end

function _app_render_spectrum(data, area::TK.Rect, buf::TK.Buffer)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # Map each x-column in dot-space to its corresponding band. This
    # produces filled bars instead of skinny one-dot spikes.
    for dx in 0:(width_dots - 1)
        band_idx = clamp(floor(Int, dx * n / width_dots) + 1, 1, n)
        val = clamp(Float64(data[band_idx]), 0.0, 1.0)
        bar_dy = clamp(round(Int, val * (height_dots - 1)), 0, height_dots - 1)
        for h in 0:bar_dy
            TK.set_point!(canvas, dx, height_dots - 1 - h)
        end
    end
    TK.render(canvas, area, buf)
end

"""
    _app_render_xy(data, area, buf; rotate45=false)

XY / Lissajous scatter of stereo samples. `data` is laid out as
[L0, R0, L1, R1, …] — we draw each (L, R) as a single dot in the
canvas, mapping `[-1, 1]` × `[-1, 1]` to the panel rect. When
`rotate45` is true we rotate to (L+R, L-R) for goniometer mode:
mono signals collapse to a vertical line, perfectly out-of-phase
ones collapse to horizontal — the standard mixing aid.
"""
function _app_render_xy(data, area::TK.Rect, buf::TK.Buffer; rotate45::Bool=false)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n < 4 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    peak = maximum(abs.(data); init=0.001f0)
    scale = peak < 0.1 ? 1.0 : 1.0 / max(Float64(peak), 0.1)
    cx = width_dots ÷ 2
    cy = height_dots ÷ 2
    # Cross-hairs (mid lines, very faint) — anchors the axes when the
    # signal is quiet. Only the centre column + centre row.
    for dx in 0:(width_dots - 1)
        TK.set_point!(canvas, dx, cy)
    end
    for dy in 0:(height_dots - 1)
        TK.set_point!(canvas, cx, dy)
    end
    # Lissajous: draw lines between consecutive points so the trace
    # forms a closed curve instead of a sparse scatter.
    last_dx = last_dy = -1
    for i in 1:2:(n-1)
        l = Float64(data[i]) * scale
        r = Float64(data[i+1]) * scale
        x, y = if rotate45
            ((l + r) / sqrt(2), (l - r) / sqrt(2))
        else
            (l, r)
        end
        dx = clamp(cx + round(Int, x * cx), 0, width_dots - 1)
        dy = clamp(cy - round(Int, y * cy), 0, height_dots - 1)
        if last_dx >= 0
            TK.line!(canvas, last_dx, last_dy, dx, dy)
        else
            TK.set_point!(canvas, dx, dy)
        end
        last_dx, last_dy = dx, dy
    end
    TK.render(canvas, area, buf)
end

"""
    _app_render_spectrogram(area, buf)

Waterfall display: vertical = time (most recent at the bottom),
horizontal = frequency. Pulls from `_APP_SPECTROGRAM_HISTORY` so
each call uses the buffered last ~60 frames. Shading via the
░▒▓█ ramp — no colour gradient needed.
"""
function _app_render_spectrogram(area::TK.Rect, buf::TK.Buffer)
    history = _APP_SPECTROGRAM_HISTORY[]
    isempty(history) && return
    rows = min(area.height, length(history))
    cols = area.width
    glyphs = (' ', '░', '▒', '▓', '█')
    # Latest frame at the bottom of the panel; older frames stack upward.
    for r in 0:(rows - 1)
        frame_idx = length(history) - r
        frame_idx < 1 && break
        frame = history[frame_idx]
        nb = length(frame)
        nb == 0 && continue
        for c in 0:(cols - 1)
            band = clamp(floor(Int, c * nb / cols) + 1, 1, nb)
            v = clamp(Float64(frame[band]), 0.0, 1.0)
            g = glyphs[clamp(1 + floor(Int, v * (length(glyphs) - 1)), 1, length(glyphs))]
            TK.set_string!(buf, area.x + c, area.y + (area.height - 1 - r),
                           string(g), TK.tstyle(:primary))
        end
    end
end

"""
    _app_render_peak(data, area, buf)

VU-style peak meter with a slow-decay hold marker and a clip
indicator. `data = [peak, hold, clipped]`.
"""
function _app_render_peak(data, area::TK.Rect, buf::TK.Buffer)
    length(data) >= 1 || return
    peak = clamp(Float64(data[1]), 0.0, 1.0)
    hold = length(data) >= 2 ? clamp(Float64(data[2]), 0.0, 1.0) : peak
    clipped = length(data) >= 3 && Float64(data[3]) > 0.5
    w = area.width
    bar_w = floor(Int, peak * w)
    hold_x = floor(Int, hold * w)
    bar = "█" ^ bar_w
    pad = " " ^ max(0, w - bar_w)
    style_bar = clipped ? TK.tstyle(:error, bold=true) : TK.tstyle(:primary)
    TK.set_string!(buf, area.x, area.y, bar * pad, style_bar)
    if 0 <= hold_x < w
        TK.set_string!(buf, area.x + hold_x, area.y, "│",
                       TK.tstyle(:warning, bold=true))
    end
    db = peak > 0 ? round(20 * log10(peak); digits=1) : -Inf
    label = "  peak $(round(peak; digits=3))  hold $(round(hold; digits=3))  ($(db) dB)" *
            (clipped ? "  CLIP" : "")
    TK.set_string!(buf, area.x, area.y + 1,
                   first(label, w), clipped ? TK.tstyle(:error) : TK.tstyle(:text_dim))
end

"""
    _app_render_pitch(data, area, buf)

Pitch tracker. `data = [freq, hasFreq]`. Shows Hz reading, derives
a note name from equal-temperament, dims the line when hasFreq <
0.5 (low confidence).
"""
function _app_render_pitch(data, area::TK.Rect, buf::TK.Buffer)
    length(data) >= 1 || return
    freq = Float64(data[1])
    conf = length(data) >= 2 ? Float64(data[2]) : 1.0
    if freq < 20 || freq > 20000
        TK.set_string!(buf, area.x, area.y,
                       "  pitch — no signal", TK.tstyle(:text_dim))
        return
    end
    midi = 69 + 12 * log2(freq / 440)
    note_idx = mod(round(Int, midi), 12) + 1
    octave = (round(Int, midi) ÷ 12) - 1
    notes = ("C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B")
    label = "  ♬  $(round(freq; digits=1)) Hz   →   $(notes[note_idx])$octave   (conf $(round(conf; digits=2)))"
    style = conf > 0.5 ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, area.x, area.y, first(label, area.width), style)
end

"""
    _app_render_onset(data, area, buf)

Onset detector flash. When a transient is detected SC sends a
sustained ~80 ms latch (1.0 → 0). We render a full-panel block
proportional to that latch value, so the panel "pulses" on each
hit.
"""
function _app_render_onset(data, area::TK.Rect, buf::TK.Buffer)
    v = length(data) >= 1 ? clamp(Float64(data[1]), 0.0, 1.0) : 0.0
    # Single-row pulse — width tracks the latch value so it visually
    # decays after each hit. A label underneath shows the live value
    # so the user knows the detector is alive even between hits.
    bar_w = floor(Int, v * area.width)
    bar = "█" ^ bar_w * "·" ^ (area.width - bar_w)
    style = v > 0.5 ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, area.x, area.y, first(bar, area.width), style)
    label = "  onset detector — flashes on each transient (latch $(round(v; digits=2)))"
    if area.height >= 2
        TK.set_string!(buf, area.x, area.y + 1,
                       first(label, area.width), TK.tstyle(:text_dim))
    end
end

"""
    _app_render_hist(data, area, buf)

Sample-value histogram. 32 vertical bars showing how often a
sample landed in each amplitude bin (-1 to +1). Useful for spotting
DC offset or asymmetric distortion.
"""
function _app_render_hist(data, area::TK.Rect, buf::TK.Buffer)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    peak = maximum(data; init=0.001f0)
    norm = peak < 0.01 ? 1.0 : 1.0 / Float64(peak)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # Fill every dot column with the matching bin so bars look solid,
    # not skinny one-dot spikes (same fix as spectrum).
    for dx in 0:(width_dots - 1)
        band_idx = clamp(floor(Int, dx * n / width_dots) + 1, 1, n)
        v = clamp(Float64(data[band_idx]) * norm, 0.0, 1.0)
        bar_h = clamp(round(Int, v * (height_dots - 1)), 0, height_dots - 1)
        for h in 0:bar_h
            TK.set_point!(canvas, dx, height_dots - 1 - h)
        end
    end
    TK.render(canvas, area, buf)
end

"""
    _app_render_corr(data, area, buf)

Stereo correlation meter. -1 = out of phase, 0 = uncorrelated,
+1 = mono. Standard mixing aid — red zone below 0 warns about
mono-summing issues.
"""
function _app_render_corr(data, area::TK.Rect, buf::TK.Buffer)
    v = length(data) >= 1 ? clamp(Float64(data[1]), -1.0, 1.0) : 0.0
    w = area.width
    cx = w ÷ 2
    pos = clamp(cx + round(Int, v * cx), 0, w - 1)
    # Draw the axis line.
    line_chars = fill('─', w)
    line_chars[cx + 1] = '┼'
    line_chars[clamp(pos + 1, 1, w)] = '●'
    TK.set_string!(buf, area.x, area.y, String(line_chars),
                   v < 0 ? TK.tstyle(:error, bold=true) : TK.tstyle(:primary))
    label = "  L-R correlation: $(round(v; digits=3))   (-1 phase-inverted  ·  0 stereo  ·  +1 mono)"
    TK.set_string!(buf, area.x, area.y + 1,
                   first(label, w), TK.tstyle(:text_dim))
end

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
    _render_modal_block!(buf, area; title, title_right="", w_max=100, h_target=20) -> Rect

Center a bordered modal inside `area`. Clears the inner rect first so
the underlying editor / panes don't bleed through, then draws a
`TK.Block` with rounded corners + accent border. Returns the inner
`Rect` so the caller can pour content into it without computing
offsets.

The right-aligned title is the conventional spot for the help line
("j/k scroll · q close" etc.) — keep it short so it never collides
with the left title on narrow terminals.
"""
function _render_modal_block!(buf::TK.Buffer, area::TK.Rect;
                              title::AbstractString,
                              title_right::AbstractString = "",
                              w_min::Int = 40, w_max::Int = 100,
                              h_target::Int = 20)
    aw, ah = area.width, area.height
    box_w = clamp(w_max, w_min, max(w_min, aw - 4))
    box_h = clamp(h_target, 8, max(8, ah - 4))
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    rect = TK.Rect(box_x, box_y, box_w, box_h)
    inner = _inner_rect(rect)
    # Clear inner first so any cells previously drawn by the editor /
    # panes underneath get overwritten with blank text style. Without
    # this the modal looks "transparent" on the body.
    blank = " " ^ inner.width
    bg_style = TK.tstyle(:text)
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, bg_style)
    end
    block = TK.Block(
        title              = " " * String(title) * " ",
        title_right        = isempty(title_right) ? "" :
                             " " * String(title_right) * " ",
        title_style        = TK.tstyle(:accent, bold = true),
        title_right_style  = TK.tstyle(:text_dim),
        border_style       = TK.tstyle(:accent),
        box                = TK.BOX_ROUNDED,
        title_padding      = 0,
    )
    TK.render(block, rect, buf)
    return inner
end

"""
    _active_slots_summary(m) -> String

Compact list of slot ids currently scheduled, e.g. "@d1 @d2 @d4".
Empty string when nothing is playing. Goes in the patterns block title
so the user always sees what's live.
"""
function _active_slots_summary(m::RessacApp)
    sched = m.scheduler
    isempty(sched.patterns) && return ""
    slots = sort!(collect(keys(sched.patterns));
                  by = s -> try parse(Int, String(s)[2:end]) catch; 999 end)
    join(("@" * String(s) for s in slots), " ")
end

function TK.view(m::RessacApp, f::TK.Frame)
    # Paused: skip the whole draw so the terminal's last frame stays put
    # and the user can shift-drag-select + copy without our next render
    # wiping the highlight. update! flips paused=false on any keypress,
    # which will cause the next view() to render normally and the
    # selection to clear — by then the user has already copied.
    m.paused && return
    m.tick += 1
    m.editor.tick = m.tick
    for tab in m.synth_tabs
        tab.editor.tick = m.tick
    end
    buf = f.buffer

    scope_active = _APP_SCOPE_TYPE[] !== :off
    scope_height = scope_active ? 14 : 0
    # Layout rows: status / editor (fill) / [scope] / livedoc / footer / logs.
    # Each major pane (patterns, synth, scope, logs) gets wrapped in a
    # TK.Block which consumes 2 rows / 2 cols of border, so the visible
    # body is `inner_area(block, outer)`. Heights stay the same — borders
    # eat into the fill, not into adjacent rows.
    constraints = scope_active ?
        [TK.Fixed(1), TK.Fill(), TK.Fixed(scope_height), TK.Fixed(1), TK.Fixed(1), TK.Fixed(10)] :
        [TK.Fixed(1), TK.Fill(), TK.Fixed(1), TK.Fixed(1), TK.Fixed(10)]
    rows = TK.split_layout(TK.Layout(TK.Vertical, constraints), f.area)
    length(rows) < 5 && return
    if scope_active
        status_area, body_area, scope_area, livedoc_area, footer_area, logs_area =
            rows[1], rows[2], rows[3], rows[4], rows[5], rows[6]
    else
        status_area, body_area, livedoc_area, footer_area, logs_area =
            rows[1], rows[2], rows[3], rows[4], rows[5]
        scope_area = nothing
    end

    # Status bar — left: app badge + tempo + cycle progress + counters,
    # right: mode + focus. Icons stay ASCII-safe (no emoji) so any
    # monospace font renders them aligned.
    _render_status_bar(m, status_area, buf)

    # Editor body — split horizontally when at least one synth tab open.
    # Record each pane's INNER rect (post-border) so the mouse handler
    # routes clicks / hovers to the editor area, not the border chars.
    m.layout_synth = nothing
    m.layout_synth_tabs = nothing
    pat_focused = (m.focus === :patterns)
    n_playing = length(m.scheduler.patterns)
    pat_right = n_playing == 0 ? "" :
                "● $(n_playing) playing  $(_active_slots_summary(m))"
    if !_synth_pane_open(m)
        _render_pane_block!(m, body_area, buf;
            title = "PATTERNS",
            title_right = pat_right,
            focused = pat_focused,
            title_right_accent = n_playing > 0)
        inner = _inner_rect(body_area)
        m.layout_patterns = inner
        TK.render(m.editor, inner, buf)
    else
        cols = TK.split_layout(TK.Layout(TK.Horizontal, [TK.Fill(), TK.Fill()]), body_area)
        if length(cols) >= 2
            _render_pane_block!(m, cols[1], buf;
                title = "PATTERNS",
                title_right = pat_right,
                focused = pat_focused,
                title_right_accent = n_playing > 0)
            pat_inner = _inner_rect(cols[1])
            m.layout_patterns = pat_inner
            TK.render(m.editor, pat_inner, buf)

            synth_focused = (m.focus === :synth)
            tab = _current_synth_tab(m)
            ext = tab.mode === :dsl ? ".jl" : ".scd"
            synth_title = "SYNTH · $(tab.name)$ext [$(tab.mode)]"
            synth_right = length(m.synth_tabs) > 1 ?
                "$(m.synth_tab_idx)/$(length(m.synth_tabs))" : ""
            _render_pane_block!(m, cols[2], buf;
                title = synth_title,
                title_right = synth_right,
                focused = synth_focused)
            synth_inner = _inner_rect(cols[2])
            if length(m.synth_tabs) > 1
                synth_rows = TK.split_layout(
                    TK.Layout(TK.Vertical, [TK.Fixed(1), TK.Fill()]), synth_inner)
                if length(synth_rows) >= 2
                    bar = TK.TabBar([tab.name for tab in m.synth_tabs];
                                    active  = m.synth_tab_idx,
                                    focused = synth_focused)
                    TK.render(bar, synth_rows[1], buf)
                    TK.render(_current_synth_tab(m).editor, synth_rows[2], buf)
                    m.layout_synth_tabs = synth_rows[1]
                    m.layout_synth = synth_rows[2]
                end
            else
                m.layout_synth = synth_inner
                TK.render(_current_synth_tab(m).editor, synth_inner, buf)
            end
        end
    end

    # Scope panel (if any) — wrapped in its own block so the mode is
    # visible in the title and zoom info on the right.
    m.layout_scope = scope_area
    if scope_area !== nothing
        scope_mode = String(_APP_SCOPE_TYPE[])
        _render_pane_block!(m, scope_area, buf;
            title = "SCOPE · $scope_mode",
            title_right = scope_mode == "wave" ? "zoom ×$(round(m.scope_zoom_x; digits=1))" : "",
            focused = false)
        _render_app_scope(m, _inner_rect(scope_area), buf)
    end

    # Post-eval flash — green pulse on the lines just successfully
    # evaluated. Paints BEFORE the playhead so the playhead's accent
    # still wins on the active token.
    if m.layout_patterns !== nothing
        _render_eval_flash!(m, m.layout_patterns, buf)
    end

    # Playhead — highlights the active token in every @dN p"..." line
    # that's currently shipping events. Overlays AFTER the editor
    # rendered so we paint on top of the existing cells.
    if m.layout_patterns !== nothing
        _render_playhead!(m, m.layout_patterns, buf)
    end

    # Ghost autocomplete — faded suggestion at the cursor in the active
    # editor pane. Lazy-loads usage stats on first render.
    _load_ghost_usage!()
    if m.focus === :synth && m.layout_synth !== nothing
        _render_ghost!(m, m.layout_synth, buf)
    elseif m.layout_patterns !== nothing
        _render_ghost!(m, m.layout_patterns, buf)
    end

    # Live doc row — word under cursor → doc string
    _render_livedoc_row(m, livedoc_area, buf)

    # Footer (key hints) + logs with per-level coloring + bordered block.
    _render_footer(m, footer_area, buf)
    log_right = "$(length(m.logs))" *
                (m.log_scroll > 0 ? " · ↑$(m.log_scroll)" : "")
    _render_pane_block!(m, logs_area, buf;
        title = "LOG", title_right = log_right, focused = false)
    log_inner = _inner_rect(logs_area)
    m.layout_logs = log_inner
    _render_logs(m, log_inner, buf)

    # Modal overlay (after everything else so it sits on top).
    if m.modal === :browse
        _render_browser_modal!(m, f.area, buf)
    elseif m.modal === :synth_library
        _render_synth_library_modal!(m, f.area, buf)
    elseif m.modal === :sccode
        _render_sccode_modal!(m, f.area, buf)
    elseif m.modal === :snippets
        _render_snippets_modal!(m, f.area, buf)
    elseif m.modal === :wiki
        _render_wiki_modal!(m, f.area, buf)
    elseif m.modal === :mixer
        _render_mixer_modal!(m, f.area, buf)
    elseif m.modal !== :none
        _render_modal!(m, f.area, buf)
    end
end

# ---------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------

"""
    _start_recording!(m, name=nothing)

Open a WAV file under `./recordings/` and tell SC to start
streaming the master mix into it. `name` defaults to a
timestamped filename so successive recordings don't clobber.
"""
function _start_recording!(m::RessacApp, name=nothing)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[ERROR] rec: no live session"); return)
    if m.recording
        _push_app_log!(m, "[WARN] rec: already recording → $(m.recording_path)")
        return
    end
    dir = joinpath(pwd(), "recordings")
    isdir(dir) || mkpath(dir)
    fname = if name === nothing
        ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
        "ressac_$(ts).wav"
    else
        endswith(String(name), ".wav") ? String(name) : String(name) * ".wav"
    end
    path = joinpath(dir, fname)
    send_osc(sched.osc, encode(OSCMessage("/ressac/recStart", Any[path])))
    m.recording = true
    m.recording_path = path
    m.recording_start_ts = time()
    _push_app_log!(m, "[INFO] rec ● → $(path)")
end

"""
    _stop_recording!(m)

Send /ressac/recStop to SC and clear local state. SC closes the
WAV file cleanly; the user can immediately play it back from disk.
"""
function _stop_recording!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    if !m.recording
        _push_app_log!(m, "[WARN] rec stop: not recording")
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/recStop", Any[])))
    secs = round(time() - m.recording_start_ts; digits=1)
    _push_app_log!(m, "[INFO] rec ■ $(secs)s → $(m.recording_path)")
    m.recording = false
    m.recording_path = ""
end

_toggle_recording!(m::RessacApp) =
    m.recording ? _stop_recording!(m) : _start_recording!(m)

"""
    _export_current_synth!(m; duration = 4.0)

One-shot WAV export of the currently-open synth. Sequence:

  1. Pull all patterns (`hush!`) so nothing else lands in the take.
  2. Write to `./recordings/<synthname>_<ts>.wav`, sample the SC
     master out for `duration` seconds.
  3. While the recording is live, fire the synth once via the same
     /ressac/evalAndPlay path that T uses (so we capture exactly
     what the user hears when they hit T).
  4. After `duration` seconds, stop the recording.

Runs the timing on an `@async` Task so the UI stays interactive.
"""
function _export_current_synth!(m::RessacApp; duration::Float64 = 4.0)
    _synth_pane_open(m) ||
        (_push_app_log!(m, "[ERROR] export: open a synth first (:synth <name>)"); return)
    sched = _LIVE_SCHEDULER[]
    sched === nothing &&
        (_push_app_log!(m, "[ERROR] export: no live session"); return)
    m.recording &&
        (_push_app_log!(m, "[WARN] export: stop the current :rec first"); return)
    tab = _current_synth_tab(m)
    src = TK.text(tab.editor)
    dir = joinpath(pwd(), "recordings")
    isdir(dir) || mkpath(dir)
    ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    fname = "$(tab.name)_$(ts).wav"
    path = joinpath(dir, fname)
    # 1. quiet the scheduler so the take is just this synth.
    hush!(sched)
    # 2. open the WAV.
    send_osc(sched.osc, encode(OSCMessage("/ressac/recStart", Any[path])))
    m.recording = true
    m.recording_path = path
    m.recording_start_ts = time()
    _push_app_log!(m, "[INFO] export ● $(fname) ($(duration)s)")
    # 3+4. fire the synth then schedule the stop. @async keeps the UI
    # responsive while we sleep the take's duration.
    @async begin
        try
            # SC's prepareForRecord allocates a disk buffer and isn't
            # instantaneous — wait long enough for the Routine in the
            # OSCdef to actually engage record before we fire the note.
            # A side-effect of the wait: the WAV has a fade-in margin of
            # silence which is convenient for downstream editing.
            sleep(0.3)
            send_osc(sched.osc,
                     encode(OSCMessage("/ressac/evalAndPlay",
                                        Any[tab.name, src])))
            sleep(duration)
            send_osc(sched.osc, encode(OSCMessage("/ressac/recStop", Any[])))
            m.recording = false
            m.recording_path = ""
            _push_app_log!(m, "[INFO] export ■ → $(path)")
        catch err
            _push_app_log!(m, "[ERROR] export: $(sprint(showerror, err))")
            m.recording = false
        end
    end
end

# ---------------------------------------------------------------------
# Vim visual-line mode (V)
# ---------------------------------------------------------------------

"""
    _visual_handle!(m, ed, evt) -> Bool

Dispatch keys while in visual-line mode. Returns true if the event
was consumed; false to let the rest of `update!` handle it (e.g. a
key we don't know about — Tachikoma will own it).

  • j / k / arrows → extend the selection
  • d              → delete the selected lines (yank first)
  • y              → yank lines, return to normal
  • c              → delete + enter insert
  • Esc            → exit without action
"""
function _visual_handle!(m::RessacApp, ed::TK.CodeEditor, evt::TK.KeyEvent)
    if evt.key === :escape
        m.visual_active = false
        _push_app_log!(m, "[INFO] visual cancelled")
        return true
    end
    # Both kinds share vertical motion (j/k); :char additionally tracks
    # horizontal (h/l, arrows, w/b/0/$).
    if evt.char == 'j' || evt.key === :down
        ed.cursor_row = min(ed.cursor_row + 1, length(ed.lines))
        if m.visual_kind === :char
            ed.cursor_col = clamp(ed.cursor_col, 0, length(ed.lines[ed.cursor_row]))
        end
        return true
    end
    if evt.char == 'k' || evt.key === :up
        ed.cursor_row = max(1, ed.cursor_row - 1)
        if m.visual_kind === :char
            ed.cursor_col = clamp(ed.cursor_col, 0, length(ed.lines[ed.cursor_row]))
        end
        return true
    end
    if m.visual_kind === :char
        if evt.char == 'h' || evt.key === :left
            ed.cursor_col = max(0, ed.cursor_col - 1); return true
        end
        if evt.char == 'l' || evt.key === :right
            row_len = length(ed.lines[ed.cursor_row])
            ed.cursor_col = min(row_len, ed.cursor_col + 1); return true
        end
        if evt.char == '0'
            ed.cursor_col = 0; return true
        end
        if evt.char == '\$'
            ed.cursor_col = length(ed.lines[ed.cursor_row]); return true
        end
    end
    if evt.char == 'd' || evt.char == 'y' || evt.char == 'c'
        _visual_apply!(m, ed, evt.char)
        return true
    end
    m.visual_active = false
    return false
end

"""
    _visual_apply!(m, ed, op)

Run an operator (`'d'` / `'y'` / `'c'`) on the line range
between visual_anchor_row and cursor_row, then exit visual mode.
"""
function _visual_apply!(m::RessacApp, ed::TK.CodeEditor, op::Char)
    if m.visual_kind === :char
        _visual_apply_char!(m, ed, op)
    else
        _visual_apply_line!(m, ed, op)
    end
    m.visual_active = false
end

function _visual_apply_line!(m::RessacApp, ed::TK.CodeEditor, op::Char)
    r1 = min(m.visual_anchor_row, ed.cursor_row)
    r2 = max(m.visual_anchor_row, ed.cursor_row)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    r1 = clamp(r1, 1, length(lines))
    r2 = clamp(r2, 1, length(lines))
    selected = lines[r1:r2]
    if op == 'y'
        ed.yank_buffer = [collect(line) for line in selected]
        ed.yank_is_linewise = true
        _push_app_log!(m, "[INFO] V — yanked $(length(selected)) line(s)")
    elseif op == 'd' || op == 'c'
        ed.yank_buffer = [collect(line) for line in selected]
        ed.yank_is_linewise = true
        deleteat!(lines, r1:r2)
        isempty(lines) && push!(lines, "")
        new_txt = join(lines, '\n')
        TK.set_text!(ed, new_txt)
        ed.cursor_row = clamp(r1, 1, length(ed.lines))
        ed.cursor_col = 0
        if op == 'c'
            insert!(ed.lines, ed.cursor_row, Char[])
            ed.cursor_col = 0
            ed.mode = :insert
        end
        _push_app_log!(m, "[INFO] V — $(op == 'c' ? "changed" : "deleted") $(length(selected)) line(s)")
        ed === m.editor && _unschedule_removed_slots!(m, txt, new_txt)
    end
end

"""
    _visual_apply_char!(m, ed, op)

Char-wise visual: collect chars from (anchor_row, anchor_col) to
(cursor_row, cursor_col) inclusive (normalised so start <= end), then
yank / delete / change. Single-line ranges stay on the same row;
multi-line ranges keep the prefix of the start row, the suffix of
the end row, and drop everything in between.
"""
function _visual_apply_char!(m::RessacApp, ed::TK.CodeEditor, op::Char)
    a_r, a_c = m.visual_anchor_row, m.visual_anchor_col
    c_r, c_c = ed.cursor_row,         ed.cursor_col
    # Normalise: (r1, c1) is the visually-earlier point.
    if (c_r, c_c) < (a_r, a_c)
        r1, c1, r2, c2 = c_r, c_c, a_r, a_c
    else
        r1, c1, r2, c2 = a_r, a_c, c_r, c_c
    end
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    r1 = clamp(r1, 1, length(lines))
    r2 = clamp(r2, 1, length(lines))
    c1 = clamp(c1, 0, length(lines[r1]))
    c2 = clamp(c2 + 1, c1, length(lines[r2]))  # +1 = inclusive on end
    # Build the yanked text. char-wise so yank_is_linewise = false.
    yanked = if r1 == r2
        lines[r1][c1+1 : c2]
    else
        join([lines[r1][c1+1 : end],
              lines[r1+1 : r2-1]...,
              lines[r2][1 : c2]], '\n')
    end
    ed.yank_buffer = [collect(line) for line in split(yanked, '\n')]
    ed.yank_is_linewise = false
    if op == 'y'
        _push_app_log!(m, "[INFO] v — yanked $(length(yanked)) char(s)")
        return
    end
    # Delete the range. Rebuild affected lines, then collapse.
    if r1 == r2
        lines[r1] = lines[r1][1 : c1] * lines[r1][c2+1 : end]
    else
        lines[r1] = lines[r1][1 : c1] * lines[r2][c2+1 : end]
        deleteat!(lines, (r1+1) : r2)
    end
    isempty(lines) && push!(lines, "")
    new_txt = join(lines, '\n')
    TK.set_text!(ed, new_txt)
    ed.cursor_row = clamp(r1, 1, length(ed.lines))
    ed.cursor_col = clamp(c1, 0, length(ed.lines[ed.cursor_row]))
    if op == 'c'
        ed.mode = :insert
    end
    _push_app_log!(m, "[INFO] v — $(op == 'c' ? "changed" : "deleted") $(length(yanked)) char(s)")
    ed === m.editor && _unschedule_removed_slots!(m, txt, new_txt)
end

# ---------------------------------------------------------------------
# Vim `.` repeat — minimal: replay last insert-mode session
# ---------------------------------------------------------------------

"""
    _vim_record_keystroke!(m, ed, evt, is_press)

Track whether we just entered insert mode (i / a / o / O / I / A)
or left it (Esc), and accumulate the typed characters in between.
On the next `.` press, `_vim_replay!` re-types those characters.
"""
function _vim_record_keystroke!(m::RessacApp, ed::TK.CodeEditor,
                                evt::TK.KeyEvent, is_press::Bool)
    is_press || return
    if !m.vim_in_insert && ed.mode === :normal &&
       evt.key === :char && evt.char in ('i', 'a', 'o', 'O', 'I', 'A')
        # We're about to enter insert via this key (Tachikoma will
        # process it just after we return). Start a fresh buffer.
        m.vim_in_insert = true
        m.vim_insert_buf = ""
        return
    end
    if m.vim_in_insert && ed.mode === :insert
        if evt.key === :char && evt.char != '\0'
            m.vim_insert_buf *= string(evt.char)
        elseif evt.key === :enter
            m.vim_insert_buf *= "\n"
        end
    end
    if m.vim_in_insert && evt.key === :escape
        # Insert session ended — freeze it as the last-replay target.
        m.vim_last_insert = m.vim_insert_buf
        m.vim_in_insert = false
        m.vim_last_kind  = :insert
    end
end

"""
    _slots_in_text(txt) -> Set{Symbol}

Return the set of `@dN` slot symbols present as ACTIVE (uncommented)
slot definitions in `txt`. A line starting with `#` is treated as
muted and contributes nothing. Used to detect which slots disappear
across a buffer mutation so the scheduler can stop them.
"""
const _SLOT_PRESENT_RX = r"^\s*@(d\d+)\b"
function _slots_in_text(txt::AbstractString)
    out = Set{Symbol}()
    for line in eachline(IOBuffer(String(txt)))
        mt = match(_SLOT_PRESENT_RX, line)
        mt !== nothing && push!(out, Symbol(mt.captures[1]))
    end
    return out
end

"""
    _unschedule_removed_slots!(m, pre_text, post_text)

Compare active slot sets between two snapshots; for each slot that
was present before, isn't present after, AND is still scheduled,
call `unset_pattern!` so the audio stops with the text. Mirrors
what users expect from `dd` on a live `@dN` line.
"""
function _unschedule_removed_slots!(m::RessacApp,
                                    pre_text::AbstractString,
                                    post_text::AbstractString)
    pre  = _slots_in_text(pre_text)
    post = _slots_in_text(post_text)
    removed = setdiff(pre, post)
    isempty(removed) && return
    sched = m.scheduler
    actually = Symbol[]
    for slot in removed
        haskey(sched.patterns, slot) || continue
        unset_pattern!(sched, slot)
        push!(actually, slot)
    end
    isempty(actually) && return
    names = join(("@" * String(s) for s in sort!(actually; by = String)), " ")
    _push_app_log!(m, "[INFO] unscheduled $(names) (line deleted)")
end

"""
    _vim_post_normal!(m, ed, evt, pre_text)

Called AFTER Tachikoma has processed a keystroke that began in
:normal mode. Detects whether that keystroke (or the sequence of
recent keystrokes) modified the buffer — if so, captures the
sequence as the new `.`-target.

Two-key commands like `dd` work because the first `d` produces no
buffer change (still pending), so we accumulate it; the second `d`
triggers the change and we record both.
"""
function _vim_post_normal!(m::RessacApp, ed::TK.CodeEditor,
                            evt::TK.KeyEvent, pre_text::String)
    # The `.` key itself must never enter the recording — it's a
    # meta-command, not part of any sequence.
    evt.key === :char && evt.char == '.' && return
    # Entering insert mode hands recording to _vim_record_keystroke!;
    # discard whatever was pending in normal-mode buffer.
    if ed.mode === :insert
        empty!(m.vim_pending_normal); return
    end
    # Esc, arrows, scroll keys, etc — not part of an edit sequence
    # but they shouldn't poison pending either, so just ignore.
    if evt.key !== :char
        return
    end
    push!(m.vim_pending_normal, evt)
    # Cap pending length so a runaway sequence (typos in normal mode)
    # doesn't grow forever.
    length(m.vim_pending_normal) > 8 && popfirst!(m.vim_pending_normal)
    post_text = TK.text(ed)
    if post_text != pre_text
        m.vim_last_normal = copy(m.vim_pending_normal)
        m.vim_last_kind   = :normal
        empty!(m.vim_pending_normal)
        # Pattern lines that just vanished from the buffer should
        # stop playing. Only meaningful in the patterns pane —
        # synth-pane edits don't drive the scheduler directly.
        ed === m.editor &&
            _unschedule_removed_slots!(m, pre_text, post_text)
    end
end

"""
    _vim_replay!(m, ed)

Replay `vim_last_insert` at the current cursor by synthesising
char-event handle_key! calls into the editor. The editor must be in
:normal mode when `.` is pressed; we enter insert (via 'i'), type
the characters, then Esc back to normal.
"""
function _vim_replay!(m::RessacApp, ed::TK.CodeEditor)
    if m.vim_last_kind === :normal && !isempty(m.vim_last_normal)
        for k in m.vim_last_normal
            TK.handle_key!(ed, k)
        end
        seq = join(string(k.char) for k in m.vim_last_normal)
        _push_app_log!(m, "[INFO] . — repeated `$(seq)`")
        return
    end
    if m.vim_last_kind === :insert
        text = m.vim_last_insert
        isempty(text) &&
            (_push_app_log!(m, "[INFO] . — nothing to repeat"); return)
        TK.handle_key!(ed, TK.KeyEvent(:char, 'i', TK.key_press))
        for c in text
            if c == '\n'
                TK.handle_key!(ed, TK.KeyEvent(:enter, '\0', TK.key_press))
            else
                TK.handle_key!(ed, TK.KeyEvent(:char, c, TK.key_press))
            end
        end
        TK.handle_key!(ed, TK.KeyEvent(:escape, '\0', TK.key_press))
        _push_app_log!(m, "[INFO] . — repeated last insert ($(length(text)) chars)")
        return
    end
    _push_app_log!(m, "[INFO] . — nothing to repeat")
end

# Wiki modal — extracted to src/modal_wiki.jl
include("modal_wiki.jl")


# ---------------------------------------------------------------------
# Snippets — context-aware multi-line templates
# ---------------------------------------------------------------------

"""
    _snip_context(m) -> Symbol

`:patterns` when the patterns pane is focused, `:synth_dsl` or
`:synth_sc` when a synth pane is open and focused — distinguished
so the picker only offers snippets that match the active tab's
authoring language (DSL Julia vs raw SuperCollider).
"""
function _snip_context(m::RessacApp)
    if m.focus === :synth && _synth_pane_open(m)
        tab = _current_synth_tab(m)
        return tab.mode === :dsl ? :synth_dsl : :synth_sc
    end
    return :patterns
end

function _snippets_visible(m::RessacApp)
    ctx = _snip_context(m)
    base = _snippets_for_context(ctx)
    # Filter by active category tab (empty == "all").
    if !isempty(m.snip_category)
        base = [s for s in base if s.category == m.snip_category]
    end
    isempty(m.snip_query) && return base
    q = lowercase(m.snip_query)
    return [s for s in base
            if occursin(q, lowercase(s.trigger)) ||
               occursin(q, lowercase(s.category)) ||
               occursin(q, lowercase(s.description))]
end

"""
    _snip_categories(m) -> Vector{String}

Categories available for the current context, in declaration order so
the tabs follow the visual grouping in snippets.jl. The empty string
"" is prepended as the implicit "all" tab.
"""
function _snip_categories(m::RessacApp)
    ctx = _snip_context(m)
    base = _snippets_for_context(ctx)
    cats = String[""]
    seen = Set{String}()
    for s in base
        s.category in seen && continue
        push!(seen, s.category); push!(cats, s.category)
    end
    return cats
end

"""
    _snip_cycle_category!(m, dir)

Move the active category tab by `dir` (±1), wrapping around. Resets
the cursor to the top of the new filtered list so the user lands on
the first snippet of the category.
"""
function _snip_cycle_category!(m::RessacApp, dir::Int)
    cats = _snip_categories(m)
    isempty(cats) && return
    cur = findfirst(==(m.snip_category), cats)
    cur === nothing && (cur = 1)
    new = mod1(cur + dir, length(cats))
    m.snip_category = cats[new]
    m.snip_cursor = 1
end

function _open_snippets!(m::RessacApp)
    m.modal = :snippets
    m.snip_cursor = 1
    m.snip_query = ""
    m.snip_search_mode = false
    m.snip_category = ""
end

function _handle_snippets_key!(m::RessacApp, evt::TK.KeyEvent)
    if m.snip_search_mode
        if evt.key === :escape
            m.snip_search_mode = false
        elseif evt.key === :enter
            m.snip_search_mode = false
        elseif evt.key === :backspace
            isempty(m.snip_query) || (m.snip_query = m.snip_query[1:end-1])
            m.snip_cursor = 1
        elseif evt.key === :char && isprint(evt.char)
            m.snip_query *= string(evt.char)
            m.snip_cursor = 1
        end
        return
    end
    n = length(_snippets_visible(m))
    if evt.key === :escape || evt.char == 'q'
        if !isempty(m.snip_query)
            m.snip_query = ""; m.snip_cursor = 1
        elseif !isempty(m.snip_category)
            m.snip_category = ""; m.snip_cursor = 1
        else
            m.modal = :none
        end
    elseif evt.char == '/'
        m.snip_search_mode = true
    elseif evt.key === :tab || evt.char == 'l' || evt.key === :right
        _snip_cycle_category!(m, +1)
    elseif evt.char == 'h' || evt.key === :left
        _snip_cycle_category!(m, -1)
    elseif evt.char == 'j' || evt.key === :down
        m.snip_cursor = min(m.snip_cursor + 1, max(n, 1))
    elseif evt.char == 'k' || evt.key === :up
        m.snip_cursor = max(m.snip_cursor - 1, 1)
    elseif evt.char == ' '
        _preview_snippet!(m)
    elseif evt.key === :enter || evt.char == '\r'
        _insert_snippet!(m)
    end
end

"""
    _preview_snippet!(m)

Dump the snippet body line-by-line into the log so the user can read
exactly what Enter would insert. Cheap and reversible.
"""
function _preview_snippet!(m::RessacApp)
    snips = _snippets_visible(m)
    1 <= m.snip_cursor <= length(snips) || return
    s = snips[m.snip_cursor]
    _push_app_log!(m, "[INFO] snippet preview: $(s.trigger) — $(s.description)")
    for line in split(strip(s.body), '\n')
        _push_app_log!(m, "        $line")
    end
end

"""
    _insert_snippet!(m)

Splice the snippet body into the active editor at the cursor. The
snippet is dedented (we trim the leading indent that's in the
source-file string literal) and inserted as a NEW line below the
current one — so the user's existing line content is preserved.
After insertion the cursor lands at the START of the first new line.
"""
function _insert_snippet!(m::RessacApp)
    snips = _snippets_visible(m)
    1 <= m.snip_cursor <= length(snips) || return
    s = snips[m.snip_cursor]
    ed = _active_editor(m)
    # Dedent: figure out the smallest indent across all non-empty lines
    # and strip it. Lets the snippet source stay readable in Julia code
    # without polluting the user's buffer.
    body_lines = split(strip(s.body), '\n')
    min_indent = typemax(Int)
    for line in body_lines
        stripped = lstrip(line)
        isempty(stripped) && continue
        min_indent = min(min_indent, length(line) - length(stripped))
    end
    min_indent === typemax(Int) && (min_indent = 0)
    dedented = [length(line) >= min_indent ? line[min_indent + 1 : end] : line
                for line in body_lines]
    # Splice after the cursor's current row.
    txt = TK.text(ed)
    src_lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(src_lines))
    inserted = String.(dedented)
    new_lines = vcat(src_lines[1:row], inserted, src_lines[row+1:end])
    TK.set_text!(ed, join(new_lines, '\n'))
    ed.cursor_row = row + 1
    ed.cursor_col = 0
    m.modal = :none
    _push_app_log!(m, "[INFO] inserted snippet $(s.trigger) ($(length(inserted)) lines)")
end

function _render_snippets_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    snips = _snippets_visible(m)
    ctx = _snip_context(m)
    ctx_label = ctx === :synth_dsl ? "synth DSL (.jl)" :
                ctx === :synth_sc  ? "synth SC (.scd)" : "patterns"
    inner = _render_modal_block!(buf, area;
        title = "SNIPPETS · $ctx_label",
        title_right = "Tab/h-l category · / search · j/k · Space preview · Enter insert · q",
        w_max = 110,
        h_target = max(14, area.height - 4))
    inner.width < 20 && return
    # ── Row 1: category tab strip ─────────────────────────────────
    cats = _snip_categories(m)
    tab_x = inner.x
    for cat in cats
        label = cat == "" ? "all" : cat
        chip  = " " * label * " "
        is_active = cat == m.snip_category
        sty = is_active ? TK.tstyle(:accent, bold = true) :
                          TK.tstyle(:text_dim)
        tab_x + textwidth(chip) > inner.x + inner.width && break
        TK.set_string!(buf, tab_x, inner.y, chip, sty)
        tab_x += textwidth(chip)
        # Subtle dot separator
        if cat != cats[end] && tab_x + 2 < inner.x + inner.width
            TK.set_string!(buf, tab_x, inner.y, "·", TK.tstyle(:text_dim))
            tab_x += 1
        end
    end
    # ── Row 2: search bar ─────────────────────────────────────────
    sb_prefix = m.snip_search_mode ? "/" : "⌕ "
    sb_text = sb_prefix * m.snip_query * (m.snip_search_mode ? "▏" : "")
    sb_style = m.snip_search_mode ?
        TK.tstyle(:accent, bold = true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, inner.x, inner.y + 1,
                   first(rpad(sb_text, inner.width), inner.width), sb_style)
    # ── Body: rows 3..(end-1), footer on last row ────────────────
    body_y0 = inner.y + 2
    body_h  = inner.height - 3
    n = length(snips)
    if n == 0
        msg = isempty(m.snip_query) ?
            "(no snippets in category '$(m.snip_category)')" :
            "(no match for \"$(m.snip_query)\")"
        TK.set_string!(buf, inner.x + 1, body_y0, msg, TK.tstyle(:text_dim))
    else
        start_i = max(1, m.snip_cursor - body_h ÷ 2)
        end_i = min(n, start_i + body_h - 1)
        start_i = max(1, end_i - body_h + 1)
        empty!(m.modal_rows)
        for (slot, i) in enumerate(start_i:end_i)
            s = snips[i]
            is_cur = i == m.snip_cursor
            marker = is_cur ? "▶ " : "  "
            label = "$(marker)$(rpad(s.trigger, 18)) [$(rpad(s.category, 9))]  $(s.description)"
            style = is_cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
            screen_y = body_y0 + slot - 1
            TK.set_string!(buf, inner.x, screen_y,
                           first(rpad(label, inner.width), inner.width), style)
            push!(m.modal_rows, (screen_y, i))
        end
    end
    cat_label = isempty(m.snip_category) ? "all" : m.snip_category
    foot = "$(n) shown · ctx = $ctx_label · cat = $cat_label"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(rpad(foot, inner.width), inner.width),
                   TK.tstyle(:text_dim))
end

# ---------------------------------------------------------------------
# Piano mode — letter keys → semitones → fire current synth
# ---------------------------------------------------------------------
#
# Chromatic keyboard layout. Both qwerty (z = C) and azerty (w = C
# because azerty's bottom-left key is W in the same physical spot)
# point to the same notes — so the layout works on both without
# reconfiguring. Black keys (#) live on the row above naturals:
#
#     s d _ g h j _ s d _ g h …      ← black keys (sharps)
#     z x c v b n m , . / + …         ← naturals (qwerty)
#     w x c v b n , ; : ! § …         ← naturals (azerty)
#
# 13 keys give a chromatic octave + 1.
const _PIANO_KEYMAP = Dict{Char,Int}(
    # Bottom row naturals + middle row sharps. Covers one chromatic
    # octave + one note; `[` and `]` shift the octave for more range.
    # Both qwerty (z=C) and azerty (w=C, same physical spot) bindings
    # are defined so the layout works without per-layout config.
    'z' => 0,  'w' => 0,   # C
    's' => 1,              # C#
    'x' => 2,              # D
    'd' => 3,              # D#
    'c' => 4,              # E
    'v' => 5,              # F
    'g' => 6,              # F#
    'b' => 7,              # G
    'h' => 8,              # G#
    'n' => 9,              # A
    'j' => 10,             # A#
    ',' => 11, 'm' => 11,  # B
    ';' => 12, '.' => 12,  # C above
)

function _piano_start!(m::RessacApp;
                       synth::AbstractString = m.piano_synth,
                       record::Bool = false)
    m.piano_active = true
    m.piano_rec = record
    m.piano_synth = String(synth)
    empty!(m.piano_events)
    mode_label = record ? "RECORD" : "PLAY"
    _push_app_log!(m, "[INFO] piano $mode_label — synth=$(m.piano_synth) · " *
                   "[/] octave · Enter " *
                   (record ? "commit" : "exit") * " · Esc exit")
    _push_app_log!(m, "         keys: z=C s=C# x=D d=D# c=E v=F g=F# b=G h=G# n=A j=A# ,=B")
end

function _piano_stop!(m::RessacApp)
    m.piano_active = false
    m.piano_rec = false
    empty!(m.piano_events)
    _push_app_log!(m, "[INFO] piano off")
end

"""
    _piano_play!(m, semitone)

Fire the current synth at the pitch corresponding to `semitone` (0
= C in the current octave). Sends `/ressac/play <synth> freq <hz>`
which the SC OSCdef converts to a fresh Synth instance. If recording
is active, also stash the (timestamp, semitone) for later commit.
"""
function _piano_play!(m::RessacApp, semitone::Int)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    midi = m.piano_octave * 12 + semitone
    freq = 440.0 * 2.0 ^ ((midi - 69) / 12)
    args = Any[m.piano_synth, "freq", Float32(freq)]
    send_osc(sched.osc, encode(OSCMessage("/ressac/play", args)))
    if m.piano_rec
        push!(m.piano_events, (time(), semitone))
    end
    _push_app_log!(m, "[INFO] piano ♪ midi=$midi freq=$(round(Int, freq))Hz")
end

"""
    _piano_commit!(m)

Quantize the recorded note events into a `:synth |> n(p"...")`
pattern and insert it below the cursor. Same quantization scheme
as tap mode — bar = first→last interval over `piano_steps` cells.
"""
function _piano_commit!(m::RessacApp)
    m.piano_active = false
    n = length(m.piano_events)
    if n < 2
        _push_app_log!(m, "[WARN] piano: need at least 2 notes")
        empty!(m.piano_events)
        return
    end
    first_t = m.piano_events[1][1]
    last_t  = m.piano_events[end][1]
    bar = max(last_t - first_t, 1e-6)
    N = m.piano_steps
    cells = fill("~", N)
    for (t, semi) in m.piano_events
        idx = clamp(round(Int, (t - first_t) / bar * (N - 1)) + 1, 1, N)
        cells[idx] = string(semi)
    end
    slot = _next_free_d_slot(m.editor)
    line = "@d$(slot) :$(m.piano_synth) |> n(p\"" * join(cells, " ") * "\")"
    _insert_line_after_cursor!(m.editor, line)
    empty!(m.piano_events)
    m.piano_rec = false
    _push_app_log!(m, "[INFO] piano committed → $(line)")
end

# ---------------------------------------------------------------------
# Tap-to-record rhythm
# ---------------------------------------------------------------------

"""
    _tap_start!(m; sample="bd", steps=16)

Enter tap-record mode. Status bar shows `● TAP …` while active.
Space records a hit at the current time, Enter quantizes the hits
to `steps` and inserts the resulting `@dN p"..."` below the cursor,
Esc cancels.
"""
function _tap_start!(m::RessacApp; sample::AbstractString = "bd",
                                    steps::Int = 16,
                                    bars::Int = 1,
                                    mode::Symbol = :loop)
    m.tap_recording = true
    empty!(m.tap_events)
    m.tap_sample = String(sample)
    m.tap_steps  = steps
    m.tap_bars   = max(1, bars)
    m.tap_mode   = mode
    if mode === :tempo
        _push_app_log!(m,
            "[INFO] tap-tempo — Space on each beat (≥2 taps), Enter to apply cps, Esc cancel · 4 taps = 1 bar")
    elseif mode === :loop
        _push_app_log!(m,
            "[INFO] tap-loop — repeat the rhythm a few times · Space on hits, Enter commit, Esc cancel · sample=$(sample)")
    elseif bars > 1
        _push_app_log!(m,
            "[INFO] tap — play the same pattern $(bars)× · Space on hits, Enter commit, Esc cancel · steps=$(steps)")
    else
        _push_app_log!(m,
            "[INFO] tap — Space ONLY on hits (no extra downbeat at end), Enter commit, Esc cancel · sample=$(sample), steps=$(steps)")
    end
end

function _tap_hit!(m::RessacApp)
    push!(m.tap_events, time())
    # Status bar already shows the live count; only log every 4 hits
    # (and always the very first) to keep the log panel readable.
    n = length(m.tap_events)
    if n == 1 || n % 4 == 0
        _push_app_log!(m, "[INFO] tap #$(n)")
    end
end

"""
    _tap_commit!(m)

Quantize the recorded hits over `m.tap_steps` divisions, build a
mini-notation string, and insert `@d<next-free-slot> p"..."` below
the cursor. The bar length is taken from the first→last tap
interval; both endpoints land on the first and last grid step
respectively.
"""
function _tap_commit!(m::RessacApp)
    m.tap_recording = false
    n = length(m.tap_events)
    if n < 2
        _push_app_log!(m, "[WARN] tap: need at least 2 hits")
        empty!(m.tap_events)
        return
    end
    if m.tap_mode === :tempo
        _tap_apply_tempo!(m); return
    end
    if m.tap_mode === :loop
        _tap_commit_auto!(m); return
    end
    if m.tap_bars > 1
        _tap_commit_fixed_bars!(m); return
    end
    # Default single-bar: same extend-by-one-interval quantization as
    # before, predictable and what most users expect.
    first_t = m.tap_events[1]; last_t = m.tap_events[end]
    avg_interval = (last_t - first_t) / (n - 1)
    bar = (last_t - first_t) + avg_interval
    N = m.tap_steps
    cells = fill("~", N)
    for t in m.tap_events
        idx = clamp(floor(Int, (t - first_t) / bar * N) + 1, 1, N)
        cells[idx] = m.tap_sample
    end
    _tap_emit_line!(m, cells, "")
end

# ── Fixed-bar averaging (explicit `:tap sample steps bars`) ─────────
function _tap_commit_fixed_bars!(m::RessacApp)
    n = length(m.tap_events)
    first_t = m.tap_events[1]; last_t = m.tap_events[end]
    avg_interval = (last_t - first_t) / (n - 1)
    total = (last_t - first_t) + avg_interval
    bar = total / m.tap_bars
    N = m.tap_steps
    votes = zeros(Int, N)
    for t in m.tap_events
        phase = mod(t - first_t, bar) / bar
        idx = clamp(floor(Int, phase * N) + 1, 1, N)
        votes[idx] += 1
    end
    threshold = max(1, ceil(Int, m.tap_bars / 2))
    cells = [v >= threshold ? m.tap_sample : "~" for v in votes]
    _tap_emit_line!(m, cells, "(averaged over $(m.tap_bars) bars)")
end

# ── Dynamic period & confidence detection ───────────────────────────
"""
    _detect_tap_period(events) -> (period, n_bars, steps, confidence, cells)

Estimate the loop period the user is tapping by scanning candidate
periods (cumulative IOI sums) and scoring each by how tightly the
folded tap positions cluster. The best-fit candidate becomes the
bar; the step count is inferred from the smallest inter-tap
interval relative to that bar. Confidence = max-bin / total taps,
in [0, 1] — higher means tighter alignment.
"""
function _detect_tap_period(events::Vector{Float64};
                            cps_hint::Union{Nothing,Real} = nothing)
    n = length(events)
    n < 4 && return nothing
    first_t = events[1]
    total = events[end] - first_t
    iois = diff(events)
    # Candidate periods = cumulative sums of the first k IOIs PLUS,
    # if the user has a tempo running, multiples of the bar length.
    # The latter handles the case where someone taps the rhythm in
    # time with the existing scheduler — the bar boundary is rarely
    # a tap onset so cumsum alone won't surface it.
    candidates = Float64[]
    s = 0.0
    for ioi in iois
        s += ioi
        0.2 <= s <= total && length(candidates) < 30 && push!(candidates, s)
    end
    if cps_hint !== nothing && cps_hint > 0
        bar = 1.0 / cps_hint
        for mult in (0.5, 1.0, 2.0, 4.0)
            p = bar * mult
            0.2 <= p <= total && push!(candidates, p)
        end
    end
    isempty(candidates) && return nothing
    unique!(sort!(candidates))

    best_period = total
    best_score  = -Inf
    # 16 bins instead of 32: each bin is ~1/16 of the period (≈ 62ms
    # for a 1s bar), which absorbs ±30ms of human tap jitter without
    # smearing taps across adjacent bins. With 32 bins, hits at the
    # same musical phase often split across two bins and look like
    # two distinct positions, killing the hot_count signal.
    n_bins = 16
    for p in candidates
        p <= 0.001 && continue
        n_reps = total / p
        bins = zeros(Int, n_bins)
        for t in events
            f = mod(t - first_t, p) / p
            bins[clamp(floor(Int, f * n_bins) + 1, 1, n_bins)] += 1
        end
        # A "hot bin" needs ≥ 2/3 of the reps' worth of taps AND ≥ 2.
        # The 2/3 (instead of 1/2) is crucial: it rejects sub-divisors
        # of the true period. For a jersey tap (hits at 0, 3, 6 of 8),
        # the candidate p = 3/8 of the bar looks "periodic" with bins
        # at phases 0 and 1/4 — but each of those bins only has half
        # the taps, since the rhythm doesn't actually repeat at p.
        # 2/3 threshold makes that fail; only the true bar survives.
        hot_threshold = max(2, ceil(Int, n_reps * 2 / 3))
        hot_count  = count(b -> b >= hot_threshold, bins)
        tight_taps = sum(b for b in bins if b >= hot_threshold; init = 0)

        score = tight_taps / n
        hot_count < 2 && (score *= 0.2)   # need ≥ 2 distinct hit positions
        # Softer n_reps penalty — 1.5 to 1.8 is still "two-ish bars",
        # which is the minimum useful loop and worth keeping in play.
        if     n_reps < 1.3;  score *= 0.4
        elseif n_reps < 1.8;  score *= 0.8
        end
        n_reps > 8.0 && (score *= 0.7)
        # Slight bias toward integer rep counts.
        frac = abs(n_reps - round(n_reps))
        score *= (1.0 - 0.3 * frac)
        # Bonus when the period sits at or near a bar boundary of the
        # current tempo — strong signal the user was tapping in time.
        if cps_hint !== nothing && cps_hint > 0
            bar = 1.0 / cps_hint
            ratio = p / bar
            cps_frac = abs(ratio - round(ratio))
            cps_frac < 0.1 && (score *= 1.3)
        end

        if score > best_score
            best_score = score; best_period = p
        end
    end

    # If no candidate looks like a real loop, defer to single-bar
    # quantization. The n_reps floor used to be 1.5, which rejected
    # the common "I tapped the pattern twice without the 3rd-bar
    # downbeat" case (n_reps ≈ 1.375 for a 2-hit-per-bar rhythm).
    # Drop to 1.25 — any candidate with n_reps below that is genuinely
    # under-evidence and the score-based fallback handles it.
    n_reps_best = total / best_period
    (best_score < 0.5 || n_reps_best < 1.25) && return nothing

    n_bars = max(1, round(Int, n_reps_best))

    # Step inference: smallest "musical" S where the folded tap
    # positions snap CLEANLY to integer step indices. Cleanly = avg
    # fractional-step error < 0.06. We also require the grid to be
    # at least as fine as the smallest inter-tap interval, else we
    # collapse two hits onto one step.
    musical_steps = (3, 4, 6, 8, 12, 16, 24, 32)
    min_ioi = minimum(iois)
    min_S = max(3, ceil(Int, best_period / max(min_ioi, 0.01)))
    # Pick the smallest S with the LOWEST average snap error. Iterating
    # from smallest upward and tracking the minimum lets equal-err
    # candidates be broken by "smaller is better" (more compact output).
    steps = 16
    best_err = Inf
    for S in musical_steps
        S < min_S && continue
        err = 0.0
        for t in events
            f = mod(t - first_t, best_period) / best_period * S
            err += abs(f - round(f))
        end
        avg = err / n
        # Strict improvement: 0.01 epsilon so float noise doesn't make
        # a finer S "tie" with a coarser one that's actually perfect.
        if avg + 0.01 < best_err
            steps = S
            best_err = avg
        end
    end

    votes = zeros(Int, steps)
    for t in events
        f = mod(t - first_t, best_period) / best_period
        idx = clamp(floor(Int, f * steps) + 1, 1, steps)
        votes[idx] += 1
    end
    threshold = max(1, ceil(Int, n_bars / 2))
    cells_idx = findall(v -> v >= threshold, votes)
    return (period = best_period, n_bars = n_bars, steps = steps,
            confidence = clamp(best_score, 0.0, 1.0),
            n_hits = length(cells_idx),
            votes = votes,
            threshold = threshold)
end

function _tap_commit_auto!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    cps_hint = sched === nothing ? nothing : sched.cps
    analysis = _detect_tap_period(m.tap_events; cps_hint = cps_hint)
    # In both branches we want to: pick a cps from the tap timing,
    # apply it immediately, insert the cps! line, then insert + eval
    # the pattern. The branches only differ in how the cells/period
    # are computed.
    bar_dur, cells, suffix = if analysis === nothing
        # No repetition detected — quantize the single pass over
        # m.tap_steps divisions. Use total + avg as the bar so the
        # last tap gets its own step.
        n = length(m.tap_events)
        first_t = m.tap_events[1]; last_t = m.tap_events[end]
        avg = (last_t - first_t) / (n - 1)
        bar = (last_t - first_t) + avg
        N = m.tap_steps
        cs = fill("~", N)
        for t in m.tap_events
            idx = clamp(floor(Int, (t - first_t) / bar * N) + 1, 1, N)
            cs[idx] = m.tap_sample
        end
        (bar, cs, "(no loop detected — single-bar fit)")
    else
        cs = [v >= analysis.threshold ? m.tap_sample : "~" for v in analysis.votes]
        pct = round(Int, analysis.confidence * 100)
        rating = analysis.confidence > 0.75 ? "high" :
                 analysis.confidence > 0.55 ? "ok"   : "low — try more reps"
        target_cps = round(1.0 / analysis.period; digits = 3)
        suf = "(period=$(round(analysis.period; digits=2))s · " *
              "$(analysis.n_bars) bar$(analysis.n_bars == 1 ? "" : "s") · " *
              "$(analysis.steps) steps · cps=$(target_cps) · " *
              "confidence $(pct)% [$rating])"
        # Density warning — likely a stream rather than a rhythm.
        density = analysis.n_hits / analysis.steps
        if density > 0.85
            _push_app_log!(m,
                "[WARN] tap result is $(round(Int, density*100))% filled — " *
                "looks like a steady stream. Tap only the accents, or use :tap-strict for raw quantization.")
        end
        (analysis.period, cs, suf)
    end
    target_cps = round(1.0 / bar_dur; digits = 3)
    # Always emit + apply. If the new cps equals the current, set_cps!
    # is a cheap no-op and the user still sees the value reflected.
    _insert_line_after_cursor!(m.editor, "cps!($(target_cps))")
    sched !== nothing && set_cps!(sched, target_cps)
    slot = _tap_emit_line!(m, cells, suffix)
    # Eval the inserted @dN block — the user shouldn't have to press e.
    _eval_pattern_blocks!(m, Symbol[Symbol("d", slot)])
end

function _tap_emit_line!(m::RessacApp, cells, suffix)
    slot = _next_free_d_slot(m.editor)
    line = "@d$(slot) p\"" * join(cells, " ") * "\""
    _insert_line_after_cursor!(m.editor, line)
    empty!(m.tap_events)
    _push_app_log!(m, "[INFO] tap → $(line)   $(suffix)")
    return slot
end

"""
    _tap_apply_tempo!(m)

Compute cps from the recorded taps and apply via `set_cps!`.
Convention: 4 taps = 1 bar (cycle), so cps = 1 / (4 × avg_interval).
With 3+ taps the average is more stable; 2 taps just take the
single inter-tap interval.
"""
function _tap_apply_tempo!(m::RessacApp)
    n = length(m.tap_events)
    if n < 2
        _push_app_log!(m, "[WARN] tap-tempo: need at least 2 taps")
        empty!(m.tap_events)
        return
    end
    avg_interval = (m.tap_events[end] - m.tap_events[1]) / (n - 1)
    cps = 1.0 / (4.0 * avg_interval)   # 4 taps per cycle convention
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[WARN] tap-tempo: no live session"); return)
    set_cps!(sched, cps)
    bpm = cps * 4 * 60
    _push_app_log!(m, "[INFO] tap-tempo → cps=$(round(cps; digits=3))  (~$(round(Int, bpm)) BPM, $(n) taps)")
    empty!(m.tap_events)
end

function _next_free_d_slot(ed::TK.CodeEditor)
    used = Set{Int}()
    for mt in eachmatch(r"@d(\d+)", TK.text(ed))
        push!(used, parse(Int, mt.captures[1]))
    end
    n = 1
    while n in used; n += 1; end
    return n
end

function _insert_line_after_cursor!(ed::TK.CodeEditor, line::AbstractString)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(lines))
    insert!(lines, row + 1, String(line))
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row + 1
    ed.cursor_col = length(line)
end

# ---------------------------------------------------------------------
# Panic
# ---------------------------------------------------------------------

"""
    _panic!(m)

Single-key emergency stop. Pulls every active pattern from the
scheduler (so no fresh OSC events ship) AND sends `/ressac/panic` to
SuperCollider which calls `s.freeAll` — every running synth dies. The
scheduler stays up so the next pattern eval starts cleanly.
"""
function _panic!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing || hush!(sched)
    if sched !== nothing
        send_osc(sched.osc, encode(OSCMessage("/ressac/panic", Any[])))
    end
    _push_app_log!(m, "[INFO] PANIC — all sound killed")
end

"""
    _hush!(m)

Softer counterpart to `_panic!`: clears every pattern from the
scheduler so no new events fire, but does NOT free running synths
on the SC server. Notes already in the air play out their
envelopes naturally — reverb tails, drone fade-outs, release
phases all complete cleanly. Bound to `,` and the :hush / :stop /
:silence ex-commands.
"""
function _hush!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    hush!(sched)
    _push_app_log!(m, "[INFO] hush — patterns stopped, tails ringing out")
end

# sccode.org browser modal — extracted to src/modal_sccode.jl to keep
# app.jl from growing past 6k lines. Function definitions live there;
# this include preserves the load order (all helpers + types they
# reference, like RessacApp and _render_modal_block!, are already in
# scope at this point in app.jl).
include("modal_sccode.jl")

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

    ed = _active_editor(m)
    badge = "⟪ $(uppercase(String(ed.mode))) @ $(m.focus) ⟫"

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
    if _synth_pane_open(m)
        synth_label = "♬ $(_current_synth_tab(m).name)" *
                      (length(m.synth_tabs) > 1 ?
                       " [$(m.synth_tab_idx)/$(length(m.synth_tabs))]" : "")
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
    if m.visual_active
        r1 = min(m.visual_anchor_row, m.editor.cursor_row)
        r2 = max(m.visual_anchor_row, m.editor.cursor_row)
        n = r2 - r1 + 1
        if m.visual_kind === :char
            push!(state_parts,
                ("▌ VISUAL CHAR $(m.visual_anchor_row):$(m.visual_anchor_col)→$(m.editor.cursor_row):$(m.editor.cursor_col)",
                 TK.tstyle(:accent, bold = true)))
        else
            push!(state_parts,
                ("▌ VISUAL LINE $r1-$r2 ($n line$(n == 1 ? "" : "s"))",
                 TK.tstyle(:accent, bold = true)))
        end
    end
    isempty(state_parts) || push!(sections, state_parts)

    # ── Render —— left to right ────────────────────────────────────
    # Compute total length first, truncate sections that don't fit
    # rather than overflow into the right badge.
    sep = " │ "
    sep_style = TK.tstyle(:text_dim)
    available = area.width - textwidth(badge) - 1  # 1 col for right pad
    x = area.x
    for (i, sec) in enumerate(sections)
        if i > 1
            x + textwidth(sep) > area.x + available && break
            TK.set_string!(buf, x, area.y, sep, sep_style)
            x += textwidth(sep)
        end
        for (txt, sty) in sec
            x + textwidth(txt) > area.x + available && (txt = first(txt,
                max(0, area.x + available - x)))
            isempty(txt) && break
            TK.set_string!(buf, x, area.y, txt, sty)
            x += textwidth(txt)
        end
    end
    # Right badge — fill the gap with the dim border char so the status
    # row looks intentional rather than empty.
    fill_x = x
    badge_x = area.x + area.width - textwidth(badge)
    if badge_x > fill_x
        TK.set_string!(buf, fill_x, area.y,
            " " ^ (badge_x - fill_x), TK.tstyle(:text_dim))
    end
    TK.set_string!(buf, max(area.x, badge_x), area.y,
        first(badge, area.width), TK.tstyle(:accent, bold = true))
end

"""
    _render_footer(m, area, buf)

Bottom hints row. Keeps the per-context cheat-sheet but renders the
mode badge in `:accent` and the rest in `:text_dim` so the eye lands
on the mode first.
"""
function _render_footer(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    ed = _active_editor(m)
    mode_label = uppercase(String(ed.mode))
    # Context-aware hint sets — leader pending / placeholder active
    # win over the default key cheatsheet so the user sees what's
    # available at the moment they need it.
    hints = if m.pending_leader
        [(string(k), v) for (k, v) in _LEADER_LABELS]
    elseif m.placeholder_active
        [("Tab", "next"), ("S-Tab", "prev"), ("Esc", "exit"),
         ("$(m.placeholder_idx)/$(length(m.placeholder_cols))", "filling")]
    elseif ed.mode === :normal && m.focus === :patterns
        [("?", "help"), ("Space", "snippet"), ("e", "eval"),
         ("E", "eval-all"), ("i", "insert"), ("dd.", "repeat"),
         (":tap", "loop"), (":tutorial", "tour"), (":q", "quit")]
    elseif !_synth_pane_open(m)
        [("e", "eval"), ("i", "insert"), ("Esc", "normal"),
         (":synth", "<name>"), (":lib", "library"),
         (":tap", "loop"), (":wiki", "docs"), (":q", "quit")]
    elseif length(m.synth_tabs) > 1
        [("e", "eval"), ("T", "test"), ("Tab", "swap"),
         ("gt/gT", "cycle"), (":w", "save"), (":close", ""), (":back", "")]
    else
        [("e", "eval"), ("T", "test"), ("Tab", "swap"),
         (":w", "save"), (":back", "close"), (":q", "quit")]
    end
    x = area.x
    # Mode chip
    chip = " $mode_label "
    TK.set_string!(buf, x, area.y, chip, TK.tstyle(:accent, bold = true))
    x += textwidth(chip) + 1
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

"""
    _eval_pattern_blocks!(m, target)

Walk the patterns buffer collecting `@dN ... [|> ... ]*` blocks,
ignoring lines whose `@dN` is preceded by `#` (muted). When the
same slot is defined multiple times the LATEST non-muted block
wins. Then eval each block whose slot is in `target` (or all of
them when `target === :all`). Logs a one-line summary.
"""
function _eval_pattern_blocks!(m::RessacApp, target)
    txt = TK.text(m.editor)
    lines = collect(split(txt, '\n'; keepempty=true))
    blocks = Dict{Symbol,String}()
    i = 1
    head_rx = r"^\s*(#+\s*)?@d(\d+)\b"
    while i <= length(lines)
        line = lines[i]
        mt = match(head_rx, line)
        if mt === nothing
            i += 1
            continue
        end
        # Capture the whole block: this line + continuation lines.
        j = i + 1
        while j <= length(lines) && startswith(lstrip(lines[j]), "|>")
            j += 1
        end
        if mt.captures[1] === nothing
            slot = Symbol("d", mt.captures[2])
            blocks[slot] = join(lines[i:j-1], " ")
        end
        i = j
    end
    targets = target === :all ?
        sort!(collect(keys(blocks)); by=s -> parse(Int, String(s)[2:end])) :
        target
    ok = 0; err = 0
    ok_slots = Symbol[]
    for slot in targets
        src = get(blocks, slot, nothing)
        src === nothing && continue
        try
            ex = Meta.parse(src)
            Core.eval(Main, ex)
            ok += 1
            push!(ok_slots, slot)
        catch e
            err += 1
            _push_app_log!(m, "[ERROR] eval $slot: $(sprint(showerror, e))")
        end
    end
    # Record the rows we just successfully evaluated so the view can
    # flash them green for a few frames — visual confirmation of "this
    # line is now live".
    flash = Int[]
    for (idx, line) in enumerate(lines)
        mt = match(head_rx, line)
        mt === nothing && continue
        mt.captures[1] === nothing || continue   # skip commented
        Symbol("d", mt.captures[2]) in ok_slots && push!(flash, idx)
    end
    m.eval_flash_rows = flash
    m.eval_flash_ts   = time()
    suffix = err > 0 ? " ($err failed)" : ""
    _push_app_log!(m, "[INFO] :e — ran $ok block$(ok == 1 ? "" : "s")$suffix")
end

"""
    _eval_current_line!(m)

Eval the line at the currently-focused editor's cursor. Continuation
lines starting with `|>` (immediately above OR below) get joined into
one logical block so the snippet DSL (`:snf2` → newline + `|> fast(2)`)
evaluates as a single expression.
"""
function _eval_current_line!(m::RessacApp)
    ce = _active_editor(m)
    txt = TK.text(ce)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ce.cursor_row
    1 <= row <= length(lines) || return
    isempty(strip(lines[row])) && return
    # Gather the logical block — the cursor row plus any contiguous
    # continuation lines that start with `|>` so the snippet DSL
    # (`:snf2` → newline + `|> fast(2)`) evaluates as one expression.
    start_row = row
    while start_row > 1 && startswith(lstrip(lines[start_row]), "|>")
        start_row -= 1
    end
    end_row = row
    while end_row < length(lines) && startswith(lstrip(lines[end_row + 1]), "|>")
        end_row += 1
    end
    block = join(lines[start_row:end_row], " ")
    try
        ex = Meta.parse(block)
        result = Core.eval(Main, ex)
        rstr = sprint(io -> show(IOContext(io, :limit=>true, :displaysize=>(1, 60)), result))
        _push_app_log!(m, "[INFO] eval ⇒ $rstr")
    catch err
        _push_app_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end

# ---------------------------------------------------------------------
# Synth pane management
# ---------------------------------------------------------------------

_app_synth_path(name::AbstractString; mode::Symbol = :dsl) =
    joinpath(pwd(), "plugins", "user-synths",
             String(name) * (mode === :dsl ? ".jl" : ".scd"))

"""
    _STARTER_DSL(name)

Default body for a fresh sandbox / unnamed synth tab in DSL mode.
"""
_STARTER_DSL(name) = """
# T = test  ·  :w <name> = save as  ·  :dsl = DSL guide  ·  :snip = snippets

@synth :$(name) (freq=220, sustain=0.5) sin_osc(:freq)
"""

"""
    _open_sandbox_synth!(m)

Open a fresh synth tab with a randomised name (`sketch_<id>`) and
the starter template — no manual naming needed. The user iterates
in the tab; `:w realname` later renames it onto disk via the
existing save-as path.
"""
function _open_sandbox_synth!(m::RessacApp)
    # 3-char base36 id, e.g. "sketch_a7p". Cheap, collision-resistant
    # enough for interactive use; if it ever does collide
    # _open_synth_tab! switches to the existing tab which is also fine.
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    id = String([chars[rand(1:length(chars))] for _ in 1:3])
    name = "sketch_$(id)"
    _open_synth_tab!(m, name)
    _push_app_log!(m, "[INFO] sandbox synth '$name' — :w <realname> to save under a chosen name")
end

"""
    _open_synth_tab!(m, name)

If `name` is already an open tab, switch to it. Otherwise create a
new tab (loading the source from disk or a starter template) and
push it onto the stack.
"""
function _open_synth_tab!(m::RessacApp, name::AbstractString)
    name = String(name)
    existing = findfirst(t -> t.name == name, m.synth_tabs)
    if existing !== nothing
        m.synth_tab_idx = existing
        m.focus = :synth
        _refresh_focus_flags!(m)
        _push_app_log!(m, "[INFO] switched to tab '$name'")
        return
    end
    # Mode detection: prefer existing `.jl` (DSL) on disk; fall back to
    # `.scd` (raw SC); otherwise create a fresh DSL tab with the
    # starter template — DSL is the primary authoring mode now.
    dsl_path = _app_synth_path(name; mode = :dsl)
    sc_path  = _app_synth_path(name; mode = :sc)
    src, mode = if isfile(dsl_path)
        (read(dsl_path, String), :dsl)
    elseif isfile(sc_path)
        (read(sc_path, String), :sc)
    else
        (_STARTER_DSL(name), :dsl)
    end
    ext = mode === :dsl ? ".jl" : ".scd"
    editor = TK.CodeEditor(;
        text  = src,
        # No `block=` — the outer SYNTH pane wrapper provides the border
        # and shows name/ext/mode in its title_right (see view()).
        focused = true,
        tick    = m.tick,
        mode    = :normal,
    )
    push!(m.synth_tabs, SynthTab(name, editor; mode = mode))
    m.synth_tab_idx = length(m.synth_tabs)
    m.focus = :synth
    _refresh_focus_flags!(m)
    _push_app_log!(m, "[INFO] opened synth '$name' [$mode] — T test, :w save, Tab swap")
end

"""
    _refresh_focus_flags!(m)

Set the `focused` field on every editor to match `m.focus`. Called
after any focus/tab change. Cleaner than relying on _swap_focus!
side effects which made the caret invisible the first time
the user opened a synth pane.
"""
function _refresh_focus_flags!(m::RessacApp)
    m.editor.focused = (m.focus === :patterns)
    for (i, tab) in enumerate(m.synth_tabs)
        tab.editor.focused = (m.focus === :synth && i == m.synth_tab_idx)
    end
end

"""
    _close_synth_pane!(m)

Close every tab and return focus to the patterns editor. Triggered
by `:back`. To drop just the active tab, see `_close_active_synth_tab!`.
"""
function _close_synth_pane!(m::RessacApp)
    isempty(m.synth_tabs) && return
    empty!(m.synth_tabs)
    m.synth_tab_idx = 0
    m.focus = :patterns
    m.editor.focused = true
    _push_app_log!(m, "[INFO] closed synth pane")
end

"""
    _close_active_synth_tab!(m)

Drop the active tab. If it was the last one, falls through to
`_close_synth_pane!` (which restores focus to patterns).
"""
function _close_active_synth_tab!(m::RessacApp)
    isempty(m.synth_tabs) && return
    name = _current_synth_tab(m).name
    deleteat!(m.synth_tabs, m.synth_tab_idx)
    if isempty(m.synth_tabs)
        m.synth_tab_idx = 0
        m.focus = :patterns
        m.editor.focused = true
        _push_app_log!(m, "[INFO] closed last synth tab '$name'")
    else
        m.synth_tab_idx = clamp(m.synth_tab_idx - 1, 1, length(m.synth_tabs))
        m.focus = :synth; _refresh_focus_flags!(m)
        _push_app_log!(m, "[INFO] closed '$name' — now on '$(_current_synth_tab(m).name)'")
    end
end

function _cycle_synth_tab!(m::RessacApp; dir::Int = +1)
    length(m.synth_tabs) <= 1 && return
    n = length(m.synth_tabs)
    m.synth_tab_idx = mod(m.synth_tab_idx + dir - 1, n) + 1
    m.focus = :synth; _refresh_focus_flags!(m)
end

function _list_synth_tabs!(m::RessacApp)
    if isempty(m.synth_tabs)
        _push_app_log!(m, "[INFO] no synth tabs open")
        return
    end
    for (i, tab) in enumerate(m.synth_tabs)
        marker = i == m.synth_tab_idx ? "▶" : " "
        _push_app_log!(m, "  $marker $i. $(tab.name)")
    end
end

"""
    _save_current_synth!(m; new_name=nothing)

Persist the synth source to `plugins/user-synths/<name>.scd`. If
`new_name` is given, save under that name AND switch the editor to
the new identity (rewriting the `SynthDef(\\old, ...)` declaration).
"""
function _save_current_synth!(m::RessacApp; new_name::Union{Nothing,AbstractString}=nothing)
    _synth_pane_open(m) || (_push_app_log!(m, "[ERROR] :w — no synth open"); return)
    tab = _current_synth_tab(m)
    old_name = tab.name
    text = TK.text(tab.editor)
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    align = tab.mode === :dsl ? _align_dsl_synth_name : _align_synthdef_name
    if new_name === nothing
        # Plain :w — overwrite the current tab's backing file at the
        # extension that matches its mode (.jl for DSL, .scd for SC).
        text = align(text, old_name)
        TK.set_text!(tab.editor, text)
        write(_app_synth_path(old_name; mode = tab.mode), text)
        register_synth!(SynthEntry(Symbol(old_name), "user-synths",
            Dict{String,Any}("description" => "live-edited synth",
                             "tags" => ["user", String(tab.mode)])))
        _push_app_log!(m, "[INFO] saved synth → $(_app_synth_path(old_name; mode = tab.mode))")
    else
        # :w newname — Save-As. Same mode as the originating tab; the
        # name token in the source gets rewritten to match.
        name = String(new_name)
        new_text = align(text, name)
        write(_app_synth_path(name; mode = tab.mode), new_text)
        register_synth!(SynthEntry(Symbol(name), "user-synths",
            Dict{String,Any}("description" => "live-edited synth",
                             "tags" => ["user", String(tab.mode)])))
        _push_app_log!(m, "[INFO] saved synth as → $(_app_synth_path(name; mode = tab.mode))")
        _open_synth_tab!(m, name)
    end
end

"""
    _fire_t_with_accel!(m; held=false)

Drive a single T press, throttled by `config.t_hold_initial_ms` /
`t_hold_min_ms` / `t_hold_accel`. On a fresh press (`held=false`) we
reset the interval to its initial value and fire immediately. On
key_repeat we only fire if at least `t_hold_interval_ms` ms have
elapsed since the last fire — and on each successful fire the
interval shrinks toward the floor.
"""
function _fire_t_with_accel!(m::RessacApp; held::Bool=false)
    cfg = ressac_config()
    now = time() * 1000   # ms
    if !held
        # Fresh press → fire, reset interval clock.
        m.t_hold_interval_ms = Float64(cfg.t_hold_initial_ms)
        m.last_t_fire = now
        _test_current_synth!(m)
        return
    end
    # key_repeat path: gate by interval.
    if now - m.last_t_fire < m.t_hold_interval_ms
        return
    end
    m.t_hold_interval_ms = max(Float64(cfg.t_hold_min_ms),
                               m.t_hold_interval_ms * cfg.t_hold_accel)
    m.last_t_fire = now
    _test_current_synth!(m)
end

"""
    _test_current_synth!(m; raw=false)

Reload the synth source on the SC side and fire a preview note via
`/ressac/evalAndPlay`. Server-side `s.sync` ensures the new SynthDef
is registered before the play fires.
"""
function _test_current_synth!(m::RessacApp; raw::Bool = false)
    _synth_pane_open(m) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    tab = _current_synth_tab(m)
    src = TK.text(tab.editor)
    if tab.mode === :dsl
        # DSL mode: realign the @synth name to the tab name (same
        # contract as SC mode's SynthDef name), then eval the buffer
        # as Julia. The @synth macro inside calls play_synth which
        # compiles to SC and ships to /ressac/evalAndPlay itself.
        src = _align_dsl_synth_name(src, tab.name)
        try
            Core.eval(Main, Meta.parse(src))
            _push_app_log!(m, "[INFO] T — test $(tab.name) (DSL → compiled SC)")
        catch err
            _push_app_log!(m, "[ERROR] DSL eval: $(sprint(showerror, err))")
        end
    else
        # SC raw mode (legacy): ship the buffer verbatim.
        src = _align_synthdef_name(src, tab.name)
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay",
                                              Any[tab.name, src])))
        _push_app_log!(m, "[INFO] T — test $(tab.name) (raw SC)")
    end
end

"""
    _align_dsl_synth_name(src, target)

Rewrite the FIRST `@synth :<old>` token in a DSL buffer to match
`target`. Idempotent when they already match; no-op if no @synth
declaration is found.
"""
function _align_dsl_synth_name(src::AbstractString, target::AbstractString)
    mt = match(r"@synth\s+:(\w+)", src)
    mt === nothing && return src
    current = mt.captures[1]
    current == target && return src
    return replace(src, r"@synth\s+:(\w+)" =>
                   SubstitutionString("@synth :$(target)"); count = 1)
end

"""
    _align_synthdef_name(src, target)

Replace the FIRST `SynthDef(\\<anything>, …)` declaration in `src`
so its name matches `target`. Returns the rewritten source. If no
SynthDef declaration is found, `src` is returned unchanged — the
user might be experimenting with a non-SynthDef snippet and we
don't want to fight them.
"""
function _align_synthdef_name(src::AbstractString, target::AbstractString)
    m = match(r"(SynthDef\s*\(\s*\\)(\w+)", src)
    m === nothing && return src
    current = m.captures[2]
    current == target && return src
    return replace(src, r"(SynthDef\s*\(\s*\\)(\w+)" => SubstitutionString("\\1$(target)"); count=1)
end

