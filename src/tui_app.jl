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
    # Tab-cycle autocomplete state. Shared between :insert Tab (word
    # under cursor) and :command Tab (ex-command verb / arg). On the
    # first Tab, the entry point gathers candidates + builds a
    # `completion_splice` closure that knows how to write the chosen
    # string back into the appropriate buffer. Subsequent Tabs just
    # cycle through `completion_candidates` and re-invoke the splice.
    # Any non-Tab key clears via `_reset_completion!` so the next
    # Tab starts fresh.
    completion_candidates::Vector{String} = String[]
    completion_idx::Int          = 0
    completion_splice::Union{Function,Nothing} = nothing
    completion_label::String     = ""           # picker title prefix
    # Multi-column grid layout published by `_render_completion_picker!`
    # at draw time so arrow-key navigation (up/down = ±cols, left/right
    # = ±1) can compute the next cell without re-deriving the picker
    # geometry. Stays 1 until the first render of a session.
    completion_cols::Int         = 1
    # Ex-command history cursor. 0 = inactive (next ↑ in :command yanks
    # the latest entry); 1..N indexes into `_EX_COMMAND_HISTORY` from
    # the END (1 = most recent). Reset to 0 on submit / Esc.
    ex_history_idx::Int          = 0
    # Reservoir scope — visible time span in wall-clock seconds. The
    # renderer maps `span_seconds` of recent history into the area's
    # width, so a spike at the right edge takes `span_seconds` to
    # scroll all the way to the left.
    #
    # `+` zooms IN (smaller span, less time visible, faster apparent
    # scroll, individual spikes pop). `-` zooms OUT (more time, slower).
    # Bounded to [0.1, 60] seconds.
    scope_reservoir_span_seconds::Float64 = 1.5
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
        _scope_cycle_key!(m; dir = sign > 0 ? +1 : -1)
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
    _try_scale_at!(m, ed, row, col, factor) -> Bool

Multiplicative nudge of the number under (row, col) by `factor` (e.g.
`2.0` for `*`, `0.5` for `/`). Integer values round to int; floats
keep their decimal places. Returns true iff a number was found.
"""
function _try_scale_at!(m::RessacApp, ed::TK.CodeEditor,
                        row::Int, col::Int, factor::Float64)
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
        val = parse(Float64, txt) * factor
        dot = findfirst('.', txt)
        decimals = length(txt) - dot
        string(round(val; digits = decimals))
    else
        string(Int(round(parse(Int, txt) * factor)))
    end
    new_line = (s > 1 ? line[1:s-1] : "") * new_str *
               (e >= lastindex(line) ? "" : line[e+1:end])
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    _push_app_log!(m, "[INFO] scale $txt → $new_str  @ row $row")
    return true
end

"""
    _viewport_h(m, ed) -> Int

Visible-line height of the pane currently hosting `ed`. Falls back to
a conservative 20 if no layout has been recorded yet (first frame).
"""
function _viewport_h(m::RessacApp, ed::TK.CodeEditor)
    rect = ed === m.editor ? m.layout_patterns : m.layout_synth
    rect === nothing && return 20
    return max(1, rect.height)
end

"""
    _word_motion!(ed, dir, kind)

Move the cursor by one word and keep its SCREEN row stable. `dir`=`+1`
forward (w/W), `-1` back (b/B). `kind`=`:small` uses letter+digit+`_`
as word chars (TK lowercase semantics, but always advances and wraps
lines); `:big` uses whitespace as the only separator (vim W/B).

Screen-row preservation: whatever the visible offset of the cursor
was before, it's the same after. The view follows the cursor, never
the other way around — no surprise re-centering when crossing a
buffer-page boundary.
"""
function _word_motion!(ed::TK.CodeEditor, dir::Int, kind::Symbol)
    n_rows = length(ed.lines)
    n_rows == 0 && return

    is_space(c) = c == ' ' || c == '\t'
    is_word(c) = kind === :big ? !is_space(c) :
                                 (isletter(c) || isdigit(c) || c == '_')
    # For :small motion we have THREE classes (word, punct, space).
    # For :big motion we have TWO (non-space, space).
    function classify(c)
        is_space(c) && return :sp
        is_word(c)  && return :wd
        return :pn
    end

    pre_screen_row = ed.cursor_row - ed.scroll_offset
    row = ed.cursor_row
    line = ed.lines[row]
    n = length(line)
    pos = ed.cursor_col + 1   # 1-based

    if dir > 0
        # Forward — skip current class run, then any whitespace, wrap
        # across lines until we land on a non-space char (or EOF).
        if 1 <= pos <= n
            cls = classify(line[pos])
            if cls === :wd
                while pos <= n && is_word(line[pos]); pos += 1; end
            elseif cls === :pn
                while pos <= n && !is_word(line[pos]) && !is_space(line[pos]); pos += 1; end
            end
        end
        while true
            while pos <= n && is_space(line[pos]); pos += 1; end
            if pos > n
                if row < n_rows
                    row += 1; line = ed.lines[row]; n = length(line); pos = 1
                else
                    pos = max(n, 1)
                    break
                end
            else
                break
            end
        end
    else
        # Backward — step back at least one char, skip whitespace
        # (wrapping lines), then back to the start of the current class.
        if pos > 1
            pos -= 1
        elseif row > 1
            row -= 1; line = ed.lines[row]; n = length(line); pos = max(n, 1)
        end
        while true
            while pos > 0 && is_space(line[pos])
                pos -= 1
            end
            if pos == 0
                if row > 1
                    row -= 1; line = ed.lines[row]; n = length(line); pos = n
                else
                    pos = 1; break
                end
            else
                break
            end
        end
        # Step back to start of the class run we just landed on.
        if pos > 0
            cls = classify(line[pos])
            if cls === :wd
                while pos > 1 && is_word(line[pos - 1]); pos -= 1; end
            elseif cls === :pn
                while pos > 1 && !is_word(line[pos - 1]) && !is_space(line[pos - 1])
                    pos -= 1
                end
            end
        end
    end

    line_len = length(ed.lines[row])
    ed.cursor_row = row
    ed.cursor_col = clamp(pos - 1, 0, max(line_len - 1, 0))
    # Re-anchor scroll_offset so cursor stays on the SAME screen row.
    ed.scroll_offset = max(0, ed.cursor_row - pre_screen_row)
    return
end

"""
    _word_end_motion!(ed, kind)

Land on the LAST char of the current word (or the next word if on
whitespace). `kind=:small` honours the word-class boundary (alnum +
`_` vs punctuation); `:big` treats whitespace as the only separator.
Used by `e` / `E` and by the `cw` / `cW` operator combos (vim quirk
where cw acts like ce).
"""
function _word_end_motion!(ed::TK.CodeEditor, kind::Symbol)
    n_rows = length(ed.lines)
    n_rows == 0 && return
    is_space(c) = c == ' ' || c == '\t'
    is_word(c) = kind === :big ? !is_space(c) :
                                 (isletter(c) || isdigit(c) || c == '_')

    row = ed.cursor_row
    line = ed.lines[row]
    n = length(line)
    pos = ed.cursor_col + 1   # 1-based

    # If on space (or past EOL), advance to next non-space — possibly
    # wrapping across lines.
    if pos > n || (pos >= 1 && is_space(line[pos]))
        while true
            while pos <= n && is_space(line[pos]); pos += 1; end
            if pos > n
                if row < n_rows
                    row += 1; line = ed.lines[row]; n = length(line); pos = 1
                else
                    pos = max(n, 1); break
                end
            else
                break
            end
        end
    end
    if pos < 1 || pos > n
        ed.cursor_row = row
        ed.cursor_col = max(n - 1, 0)
        return
    end

    # On a non-space char — extend forward through the current class run.
    cls_is_word = is_word(line[pos])
    if cls_is_word
        while pos < n && is_word(line[pos + 1]); pos += 1; end
    else
        while pos < n && !is_word(line[pos + 1]) && !is_space(line[pos + 1])
            pos += 1
        end
    end

    ed.cursor_row = row
    ed.cursor_col = clamp(pos - 1, 0, max(n - 1, 0))
    return
end

"""
    _big_word_motion!(ed, dir, target)

Legacy E (end-of-word) motion, kept for the `E` key wire-up. Forward-
only, lands on the last char of the current/next word.
"""
function _big_word_motion!(ed::TK.CodeEditor, dir::Int, target::Symbol)
    is_space(c) = c == ' ' || c == '\t'
    n_rows = length(ed.lines)
    n_rows == 0 && return
    row = ed.cursor_row
    col = ed.cursor_col  # 0-based
    line = ed.lines[row]

    # Convert to 1-based pos in current line; handle line wraps as we go.
    pos = col + 1
    line_len = length(line)

    if dir > 0
        # Forward: W → next word start ; E → next word end.
        if target === :start
            # Skip the current non-space run, then any whitespace.
            while pos <= line_len && !is_space(line[pos]); pos += 1; end
            while pos <= line_len && is_space(line[pos]); pos += 1; end
            while pos > line_len && row < n_rows
                row += 1; line = ed.lines[row]; line_len = length(line); pos = 1
                while pos <= line_len && is_space(line[pos]); pos += 1; end
            end
        else  # :end
            # If already at/past end of current word, advance into next.
            if pos > line_len || is_space(line[pos])
                while pos <= line_len && is_space(line[pos]); pos += 1; end
                while pos > line_len && row < n_rows
                    row += 1; line = ed.lines[row]; line_len = length(line); pos = 1
                    while pos <= line_len && is_space(line[pos]); pos += 1; end
                end
            elseif pos < line_len && is_space(line[pos + 1])
                # On last char of a word — jump to next.
                while pos <= line_len && !is_space(line[pos]); pos += 1; end
                while pos <= line_len && is_space(line[pos]); pos += 1; end
                while pos > line_len && row < n_rows
                    row += 1; line = ed.lines[row]; line_len = length(line); pos = 1
                    while pos <= line_len && is_space(line[pos]); pos += 1; end
                end
            end
            # Now pos is the first char of a word — advance to its end.
            while pos < line_len && !is_space(line[pos + 1]); pos += 1; end
        end
    else
        # Backward (B): move to previous word's start.
        if pos > 1
            pos -= 1
            while pos > 0 && is_space(line[pos]); pos -= 1; end
            while pos > 1 && !is_space(line[pos - 1]); pos -= 1; end
        elseif row > 1
            row -= 1; line = ed.lines[row]; line_len = length(line)
            pos = line_len
            while pos > 0 && is_space(line[pos]); pos -= 1; end
            while pos > 1 && !is_space(line[pos - 1]); pos -= 1; end
        end
    end

    pos = clamp(pos, 1, max(line_len, 1))
    ed.cursor_row = row
    ed.cursor_col = clamp(pos - 1, 0, max(line_len - 1, 0))
    return
end

"""
    _op_with_motion!(m, ed, op::Char, motion::Char)

Run a vim operator-motion combo (`cw`/`dw`/`yw`/`cW`/`dW`/`yW`/`ce`/
`de`/`ye`/`cE`/`dE`/`yE`). Computes the motion's target, deletes (or
yanks) the range from the cursor to that target, and — for `c` —
drops into insert mode. **Preserves `scroll_offset` end-to-end** so
the buffer view stays put even though the text mutated.

Notes:
  * `cw` follows vim convention and behaves like `ce` (deletes to the
    end of the word, NOT to the start of the next one — keeps the
    trailing whitespace alone).
  * `dw`/`yw` use the start-of-next-word target.
"""
function _op_with_motion!(m::RessacApp, ed::TK.CodeEditor,
                          op::Char, motion::Char)
    kind = (motion in ('W', 'B', 'E')) ? :big : :small
    dir  = (motion in ('w', 'W', 'e', 'E')) ? +1 : -1
    # Vim quirk: cw / cW target END of word, not start-of-next.
    use_end = (motion in ('e', 'E')) || (op == 'c' && motion in ('w', 'W'))

    saved_scroll = ed.scroll_offset
    src_row, src_col = ed.cursor_row, ed.cursor_col

    # Compute the target by running the motion on a tiny clone so the
    # real editor state is untouched until we apply the edit.
    probe = TK.CodeEditor()
    TK.set_text!(probe, TK.text(ed))
    probe.cursor_row = src_row
    probe.cursor_col = src_col
    if use_end
        _word_end_motion!(probe, kind)
        dst_row = probe.cursor_row
        dst_col = probe.cursor_col + 1   # +1 = exclusive end (include last word char)
    else
        _word_motion!(probe, dir, kind)
        dst_row = probe.cursor_row
        dst_col = probe.cursor_col
    end

    # Normalise so (src) <= (dst) — backward motions (b/B) flip.
    if (dst_row, dst_col) < (src_row, src_col)
        src_row, src_col, dst_row, dst_col = dst_row, dst_col, src_row, src_col
    end
    if src_row == dst_row && src_col == dst_col
        return
    end

    # Build the yanked text. Char-wise yank (yank_is_linewise=false).
    lines = collect(split(TK.text(ed), '\n'; keepempty = true))
    dst_col = clamp(dst_col, 0, length(lines[dst_row]))
    src_col = clamp(src_col, 0, length(lines[src_row]))
    yanked_str = if src_row == dst_row
        SubString(lines[src_row], src_col + 1, dst_col)
    else
        first_part = SubString(lines[src_row], src_col + 1, length(lines[src_row]))
        middle = src_row + 1 <= dst_row - 1 ?
                 lines[src_row + 1 : dst_row - 1] : SubString{String}[]
        last_part = SubString(lines[dst_row], 1, dst_col)
        join([first_part, middle..., last_part], '\n')
    end
    ed.yank_buffer = [collect(line) for line in split(yanked_str, '\n')]
    ed.yank_is_linewise = false

    if op == 'y'
        # Yank only — leave cursor at the original position (vim quirk
        # for character-wise yank).
        ed.cursor_row = src_row
        ed.cursor_col = src_col
        ed.scroll_offset = saved_scroll
        _push_app_log!(m, "[INFO] $op$motion — yanked $(length(yanked_str)) char(s)")
        return
    end

    # Delete the range. Rebuild affected lines, then collapse.
    if src_row == dst_row
        lines[src_row] = lines[src_row][1:src_col] *
                         lines[src_row][dst_col + 1 : end]
    else
        lines[src_row] = lines[src_row][1:src_col] *
                         lines[dst_row][dst_col + 1 : end]
        deleteat!(lines, src_row + 1 : dst_row)
    end
    isempty(lines) && push!(lines, "")

    # `set_text!` resets scroll_offset to 0 — save & restore.
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = clamp(src_row, 1, length(ed.lines))
    ed.cursor_col = clamp(src_col, 0,
                          max(length(ed.lines[ed.cursor_row]) - 1, 0))
    ed.scroll_offset = saved_scroll

    if op == 'c'
        ed.mode = :insert
    end
    _push_app_log!(m, "[INFO] $op$motion done")
    return
end

"""
    _page_scroll!(m, ed, delta)

Move both cursor and `scroll_offset` by `delta` rows so the cursor
stays at the same screen position. Unlike vim's `j`-times-N which
auto-recenters on overshoot, this keeps the view stable when the
cursor hits buffer edges.
"""
function _page_scroll!(m::RessacApp, ed::TK.CodeEditor, delta::Int)
    n = length(ed.lines)
    n == 0 && return
    new_row = clamp(ed.cursor_row + delta, 1, n)
    actual = new_row - ed.cursor_row
    ed.cursor_row = new_row
    ed.scroll_offset = max(0, ed.scroll_offset + actual)
    ed.cursor_col = clamp(ed.cursor_col, 0,
                          max(0, length(ed.lines[ed.cursor_row])))
    return
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
    if is_press && ed.mode === :normal && m.focus === :patterns
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
        if evt.char == 'e' && m.focus === :patterns
            # `e` evals the current line as Julia. Only meaningful in the
            # patterns pane — the synth pane buffer contains SuperCollider
            # code which Julia can't parse, so leave `e` for the editor's
            # vim "end of word" motion there.
            _eval_current_line!(m); return
        elseif evt.char == 'E' && m.focus === :patterns
            # `E` evals every @dN block in the buffer. Same intercept
            # reasoning as `e` — vim's "end of WORD" motion would
            # otherwise swallow the keystroke. Help text + welcome
            # buffer + README all promise this binding.
            _eval_pattern_blocks!(m, :all); return
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
        elseif evt.char == '+' &&
               (_APP_SCOPE_TYPE[] === :reservoir ||
                _APP_SCOPE_TYPE[] === Symbol("reservoir-graph"))
            m.scope_reservoir_span_seconds = clamp(
                m.scope_reservoir_span_seconds / 1.5, 0.1, 60.0)
            _push_app_log!(m, "[INFO] reservoir scope span = $(round(m.scope_reservoir_span_seconds; digits=2)) s (faster)"); return
        elseif evt.char == '-' &&
               (_APP_SCOPE_TYPE[] === :reservoir ||
                _APP_SCOPE_TYPE[] === Symbol("reservoir-graph"))
            m.scope_reservoir_span_seconds = clamp(
                m.scope_reservoir_span_seconds * 1.5, 0.1, 60.0)
            _push_app_log!(m, "[INFO] reservoir scope span = $(round(m.scope_reservoir_span_seconds; digits=2)) s (slower)"); return
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

include("tui_pattern_editor.jl")
include("tui_leader_snippets.jl")


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

include("tui_autocomplete.jl")

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
    # Detect the logical block the cursor is on, then mute/unmute its
    # ROOT line — the @dN call sits there. For multi-line blocks we
    # comment every line of the block so the parser doesn't trip on
    # orphan continuation arguments while the slot is muted.
    (root_row, end_row) = _logical_block_range(lines, row)
    root_line = String(lines[root_row])

    if (mt = match(_ACTIVE_SLOT_RX_APP, root_line)) !== nothing
        slot = Symbol(mt.captures[1])
        # Prepend "# " to every line of the block so indentation is
        # preserved exactly (and unmute can strip the same prefix).
        for r in root_row:end_row
            lines[r] = "# " * lines[r]
        end
        TK.set_text!(m.editor, join(lines, '\n'))
        m.editor.cursor_row = row
        m.editor.cursor_col = col + 2
        unset_pattern!(m.scheduler, slot)
        # Best-effort voice kill: free any drones on the SC side that
        # would otherwise hang now that the pattern stopped scheduling.
        _kill_voices_for_line!(m, join(lines[root_row:end_row], "\n"))
        _push_app_log!(m, "[INFO] muted $slot")
    elseif match(_COMMENTED_SLOT_RX_APP, root_line) !== nothing
        # Strip EXACTLY the "# " (or bare "#") we added at mute time.
        # The previous greedy `^\s*#+\s*` regex ate the line's natural
        # indentation on continuation rows like "#     drive=600.0".
        for r in root_row:end_row
            s = String(lines[r])
            if startswith(s, "# ")
                lines[r] = s[3:end]
            elseif startswith(s, "#")
                lines[r] = s[2:end]
            end
        end
        TK.set_text!(m.editor, join(lines, '\n'))
        m.editor.cursor_row = row
        m.editor.cursor_col = max(0, col - 2)
        # Re-eval so the slot comes back live — `_eval_current_line!`
        # uses the same block detection, so multi-line blocks evaluate
        # correctly from any cursor row inside them.
        _eval_current_line!(m)
    else
        _push_app_log!(m, "[WARN] m: cursor block isn't a slot def, no-op")
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

function _scope_cycle_key!(m::RessacApp; dir::Int = +1)
    # Use the shared cycle order so new scope types added in
    # tui_scope.jl automatically show up under S without a separate
    # edit here. `dir = -1` reverses (used by scroll-down on the
    # scope pane).
    order = _SCOPE_CYCLE_ORDER
    i = findfirst(==(_APP_SCOPE_TYPE[]), order)
    i === nothing && (i = 1)
    next_i = dir > 0 ? (i % length(order)) + 1 :
                       (i == 1 ? length(order) : i - 1)
    next = order[next_i]
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

# Verbs (autocomplete candidates) populated automatically by the
# `_register_*!` helpers. Single source of truth — the autocomplete
# in autocomplete.jl unions `keys(_LITERAL_DISPATCH)` with these,
# so adding a new command via `_register_regex!` or `_register_special!`
# makes it Tab-completable without touching another file.
const _REGEX_VERBS   = Set{String}()
const _SPECIAL_VERBS = Set{String}()

"""
    _extract_regex_verbs(rx::Regex) -> Vector{String}

Parse a dispatcher regex source and return the leading literal verbs
that the user would type. Handles three shapes:

  * `^foo\\s+...`           → ["foo"]
  * `^(?:foo|bar)\\s+...`   → ["foo", "bar"]   (alternation)
  * `^foo(?:bar)?\\s+...`   → ["foo", "foobar"] (optional suffix)

Falls back to `[]` for regexes whose leading shape isn't a simple verb
(currently only `_SHORTCUT_RX`, which is inline DSL syntax, not a
discoverable ex-command). Anything that *is* a verb gets surfaced in
autocomplete automatically — no list to maintain in sync.
"""
function _extract_regex_verbs(rx::Regex)
    src = rx.pattern
    startswith(src, "^") || return String[]
    s = SubString(src, 2)
    # Shape A: ^(?:alt1|alt2)... — pure alternation (no nested `?`).
    m = match(r"^\(\?:([^()]+)\)\\s", s)
    if m !== nothing && occursin('|', m.captures[1]) && !occursin('?', m.captures[1])
        return [String(strip(w)) for w in split(m.captures[1], '|') if !isempty(strip(w))]
    end
    # Shape B: ^prefix(?:suffix)?... — prefix + optional suffix
    m = match(r"^([A-Za-z0-9_\-]+)\(\?:([A-Za-z0-9_\-]+)\)\?", s)
    if m !== nothing
        return [String(m.captures[1]), String(m.captures[1] * m.captures[2])]
    end
    # Shape C: ^literal-word followed by \s or $ — plain verb.
    m = match(r"^([A-Za-z0-9_\-]+)(?:\\s|\$)", s)
    m !== nothing && return [String(m.captures[1])]
    return String[]
end

_register_literal!(action, aliases::String...) =
    (for a in aliases; _LITERAL_DISPATCH[a] = action; end)

function _register_regex!(rx::Regex, action)
    push!(_REGEX_DISPATCH, (rx, action))
    for v in _extract_regex_verbs(rx)
        push!(_REGEX_VERBS, v)
    end
end

function _register_special!(pred, action; verbs::Vector{String} = String[])
    push!(_SPECIAL_DISPATCH, (pred, action))
    for v in verbs
        push!(_SPECIAL_VERBS, v)
    end
end

"""
    _all_ex_verbs() -> Vector{String}

Every command verb the user can type after `:`. Union of:
  * `keys(_LITERAL_DISPATCH)` — exact-match verbs (e.g. `panic`, `q`)
  * `_REGEX_VERBS`            — extracted from each regex registration
  * `_SPECIAL_VERBS`          — explicit list from `_register_special!`

Sorted for stable ordering. Used by autocomplete.jl to keep the
Tab-completion candidate set in sync with the dispatch tables.
"""
_all_ex_verbs() = sort!(collect(union(keys(_LITERAL_DISPATCH),
                                       _REGEX_VERBS,
                                       _SPECIAL_VERBS)))

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

# ── Audio input → reservoir bridge ─────────────────────────────────
_register_regex!(r"^audio-in\s+start$",
    (m, _) -> _audio_in_start!(m))
_register_regex!(r"^audio-in\s+stop$",
    (m, _) -> _audio_in_stop!(m))
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :audio-in start  → ship \\ressac_audio_in SynthDef + listen\n" *
        "       :audio-in stop   → free the listener node"),
    "audio-in")

# ── Scope ───────────────────────────────────────────────────────────
_register_literal!(m -> _scope_command!(m, :off),    "scope")
_register_regex!(r"^scope\s+([\w-]+)$",
    (m, mt) -> _scope_command!(m, Symbol(mt.captures[1])))
# :scope reservoir <varname> — attach a global var to the reservoir scope.
_register_regex!(r"^scope\s+reservoir\s+([\w-]+)$",
    (m, mt) -> _scope_reservoir!(m, Symbol(mt.captures[1])))

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

# ── Synth alias management ─────────────────────────────────────────
# Aliases are short, user-typed names that resolve to SC SynthDef
# names. See _SYNTH_ALIASES + register_synth_alias! in plugins.jl.
_register_literal!(m -> _alias_list!(m),             "alias-ls", "aliases")
_register_regex!(r"^alias-rm\s+(\w+)$",
    (m, mt) -> _alias_remove!(m, Symbol(mt.captures[1])))
_register_regex!(r"^alias-rename\s+(\w+)\s+(\w+)$",
    (m, mt) -> _alias_rename!(m, Symbol(mt.captures[1]), Symbol(mt.captures[2])))
_register_regex!(r"^alias\s+(\w+)\s+(\w+)$",
    (m, mt) -> _alias_set!(m, Symbol(mt.captures[1]), Symbol(mt.captures[2])))
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
        "[INFO] :starter <genre> — " * join(list_starters(), ", ")),
    "starter")
_register_regex!(r"^starter\s+([\w.-]+)$",
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
    end;
    verbs = ["e"])

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

# ── Alias commands ────────────────────────────────────────────────
function _alias_list!(m::RessacApp)
    if isempty(_SYNTH_ALIASES)
        _push_app_log!(m, "[INFO] no aliases registered — `:alias <alias> <sc_name>` to add one")
        return
    end
    pairs_sorted = sort!(collect(_SYNTH_ALIASES); by = p -> String(p[1]))
    lines = ["$(alias) → $(sc_name)" for (alias, sc_name) in pairs_sorted]
    _push_app_log!(m, "[INFO] aliases: " * join(lines, ", "))
end

function _alias_remove!(m::RessacApp, alias::Symbol)
    if unregister_synth_alias!(alias)
        _push_app_log!(m, "[INFO] removed alias :$alias")
    else
        _push_app_log!(m, "[WARN] :alias-rm — no alias '$alias'")
    end
end

function _alias_rename!(m::RessacApp, old::Symbol, new::Symbol)
    target = get(_SYNTH_ALIASES, old, nothing)
    if target === nothing
        _push_app_log!(m, "[WARN] :alias-rename — no alias '$old'")
        return
    end
    if haskey(_SYNTH_ALIASES, new) && _SYNTH_ALIASES[new] !== target
        _push_app_log!(m, "[ERROR] :alias-rename — '$new' already points to '$(_SYNTH_ALIASES[new])'. :alias-rm $new first.")
        return
    end
    unregister_synth_alias!(old)
    register_synth_alias!(new, target)
    _push_app_log!(m, "[INFO] alias :$old → :$new (both point to $target)")
end

function _alias_set!(m::RessacApp, alias::Symbol, sc_name::Symbol)
    if register_synth_alias!(alias, sc_name)
        if alias === sc_name
            _push_app_log!(m, "[INFO] alias :$alias is identity (no aliasing needed)")
        else
            _push_app_log!(m, "[INFO] alias :$alias → $sc_name")
        end
    else
        existing = get(_SYNTH_ALIASES, alias, nothing)
        _push_app_log!(m, "[ERROR] :alias — '$alias' already points to '$existing'. :alias-rm $alias first.")
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
    # Record into history BEFORE dispatch (so even commands that error
    # are recallable for editing). Skip empties + exact duplicates of
    # the most recent entry so up-arrow doesn't get stuck on repeats.
    if !isempty(s) && (isempty(_EX_COMMAND_HISTORY) ||
                       last(_EX_COMMAND_HISTORY) != s)
        push!(_EX_COMMAND_HISTORY, s)
        while length(_EX_COMMAND_HISTORY) > _EX_HISTORY_CAP
            popfirst!(_EX_COMMAND_HISTORY)
        end
    end
    m.ex_history_idx = 0   # any new command resets the navigation cursor
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

# Ring of recent ex-commands ; `m.ex_history_idx` tracks where the
# up/down navigation currently sits. 0 means "no navigation in
# progress, the next ↑ should yank the most recent entry".
const _EX_HISTORY_CAP = 200
const _EX_COMMAND_HISTORY = String[]

"""
    _ex_history_nav!(m, ed, dir)

Up/Down navigation through `_EX_COMMAND_HISTORY` while in :command
mode. Yanks the historical command into the active `command_buffer`
so the user can edit + re-submit. `dir ∈ (:up, :down)`.
"""
function _ex_history_nav!(m::RessacApp, ed::TK.CodeEditor, dir::Symbol)
    n = length(_EX_COMMAND_HISTORY)
    n == 0 && return
    if dir === :up
        m.ex_history_idx = min(n, m.ex_history_idx + 1)
    elseif dir === :down
        m.ex_history_idx = max(0, m.ex_history_idx - 1)
    end
    if m.ex_history_idx == 0
        empty!(ed.command_buffer)
    else
        entry = _EX_COMMAND_HISTORY[end - m.ex_history_idx + 1]
        empty!(ed.command_buffer)
        append!(ed.command_buffer, collect(entry))
    end
    return
end

"""
    _starter_command!(m, genre)

Replace the patterns buffer with a starter sketch (the same packs the
old TUI used). User can :back to whatever they had before? No — we
overwrite without confirmation; vim convention says you should :w
first if you want to keep things.
"""
function _starter_command!(m::RessacApp, genre::AbstractString)
    key = String(genre)
    snip = lookup_snippet(key)
    if snip === nothing || snip.mode !== :starter
        # Prefix match against starter names only.
        all_keys = list_starters()
        matches = filter(k -> startswith(k, key), all_keys)
        if length(matches) == 1
            key = matches[1]
            snip = lookup_snippet(key)
        elseif length(matches) > 1
            _push_app_log!(m,
                "[WARN] :starter — '$genre' is ambiguous: " *
                join(sort!(matches), ", "))
            return
        else
            _push_app_log!(m,
                "[WARN] :starter — no pack '$genre' — try: " *
                join(sort!(all_keys), ", "))
            return
        end
    end
    TK.set_text!(m.editor, snip.resolved_content)
    m.editor.cursor_row = 1
    m.editor.cursor_col = 0
    _push_app_log!(m, "[INFO] loaded :starter $key — eval each @dN with e")
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
    pat = pattern_get(m.scheduler, slot)
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
    for (other_slot, pat) in pattern_snapshot(m.scheduler)
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

# Modal renderers + key handlers — each one extracted to its own
# src/modal_*.jl file. Includes happen here so the load order
# stays predictable (every helper / type they reference is already
# defined further up in app.jl).
include("modal_browser.jl")
include("modal_mixer.jl")
include("modal_synth_library.jl")


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

"""
    _safe_history_snapshot(hist) -> Vector{Vector{Bool}}

Snapshot the reservoir's history vector without racing the scheduler
thread's `push!` / `popfirst!`. Slots that aren't yet assigned (the
array is mid-grow) are silently skipped. Cost = a length read + N
isassigned checks ; OK at 30 FPS.
"""
function _safe_history_snapshot(hist::Vector{Vector{Bool}})
    snap = Vector{Vector{Bool}}()
    n = length(hist)
    sizehint!(snap, n)
    for i in 1:n
        @inbounds isassigned(hist, i) || continue
        try
            push!(snap, hist[i])
        catch
            # mid-mutation; bail rather than crash the renderer
            break
        end
    end
    snap
end

"""
    _sync_cursor_style!(ed)

Vim-style caret: distinct colour per mode so the user can see at a
glance whether they're in `:normal`, `:insert`, `:command`, or visual.
Insert lights the accent in warning; normal stays default accent
block; command uses :title; visual uses :success.
"""
function _sync_cursor_style!(ed::TK.CodeEditor)
    th = TK.theme()
    ed.cursor_style = if ed.mode === :insert
        TK.Style(; fg = th.bg, bg = th.warning, bold = true)
    elseif ed.mode === :command
        TK.Style(; fg = th.bg, bg = th.title,   bold = true)
    elseif ed.mode === :search
        TK.Style(; fg = th.bg, bg = th.warning)
    else  # :normal (and visual modes — we paint the selection separately)
        TK.Style(; fg = th.bg, bg = th.accent,  bold = true)
    end
    return ed
end

"""
    _refresh_scope_reservoir!(m)

Re-resolve the scope's attached reservoir from its variable name.
Called automatically after a cascade re-eval rebinds the underlying
variable — keeps the visualisation tracking the live reservoir
instead of the now-stale object. Preserves the current scope mode
(raster vs graph) and recomputes the graph layout on demand.
"""
function _refresh_scope_reservoir!(m::RessacApp)
    name = _APP_SCOPE_RESERVOIR_NAME[]
    name === :none && return
    isdefined(Main, name) || return
    obj = getfield(Main, name)
    target = if obj isa Main.Reservoir.CoupledReservoirs
        obj.members[obj.output_idx]
    else
        obj
    end
    try
        Main.Reservoir.record_history!(target, _SCOPE_RESERVOIR_CAPACITY)
    catch
        return
    end
    _APP_SCOPE_RESERVOIR[] = target
    if _APP_SCOPE_TYPE[] === Symbol("reservoir-graph") &&
       target isa Main.Reservoir.AdExReservoir
        _APP_GRAPH_LAYOUT[] = _force_directed_layout(target.W, target.N)
    end
    return
end

function _audio_in_start!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[ERROR] :audio-in start — no live session"); return)
    _ensure_app_scope_listener!()
    code = "if(~ressacAudioInNode.notNil) { ~ressacAudioInNode.free }; " *
           "~ressacAudioInNode = Synth(\\ressac_audio_in);"
    send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[code])))
    _push_app_log!(m, "[INFO] :audio-in started — speak / play into the input")
    return
end

function _audio_in_stop!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[ERROR] :audio-in stop — no live session"); return)
    code = "if(~ressacAudioInNode.notNil) { ~ressacAudioInNode.free; ~ressacAudioInNode = nil };"
    send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[code])))
    _AUDIO_IN_VALUE[] = 0.0
    empty!(_AUDIO_IN_BANDS[])
    _push_app_log!(m, "[INFO] :audio-in stopped")
    return
end

function _scope_command!(m::RessacApp, type::Symbol)
    if _app_scope_set!(type)
        _push_app_log!(m, "[INFO] :scope $type")
        # For the graph view, pre-compute the force-directed layout
        # ONCE so the renderer can just look up positions every frame.
        # Cost ≈ N² × iterations; ~30 ms for N=32, iterations=120.
        if type === Symbol("reservoir-graph")
            r = _APP_SCOPE_RESERVOIR[]
            if r !== nothing && isdefined(Main, :Reservoir) &&
               r isa Main.Reservoir.AdExReservoir
                _APP_GRAPH_LAYOUT[] = _force_directed_layout(r.W, r.N)
            end
        end
    else
        _push_app_log!(m, "[ERROR] :scope — unknown type or no live session")
    end
end

"""
    _scope_reservoir!(m, varname)

Attach the global variable `varname` (must hold a reservoir) to the
visual scope. Enables history recording on the reservoir and switches
the scope into `:reservoir` mode. Detaches by re-running with a
non-reservoir or with `:off`.
"""
function _scope_reservoir!(m::RessacApp, varname::Symbol)
    if !isdefined(Main, varname)
        _push_app_log!(m, "[ERROR] :scope reservoir — '$varname' not defined in Main")
        return
    end
    obj = getfield(Main, varname)
    # We rely on `record_history!` being callable on the object —
    # the AdEx and RECA implementations both expose it, as does
    # any CoupledReservoirs (it forwards to the output member).
    try
        if obj isa Main.Reservoir.CoupledReservoirs
            target = obj.members[obj.output_idx]
            Main.Reservoir.record_history!(target, _SCOPE_RESERVOIR_CAPACITY)
            _APP_SCOPE_RESERVOIR[] = target
        else
            Main.Reservoir.record_history!(obj, _SCOPE_RESERVOIR_CAPACITY)
            _APP_SCOPE_RESERVOIR[] = obj
        end
        _APP_SCOPE_RESERVOIR_NAME[] = varname
        _APP_SCOPE_TYPE[] = :reservoir
        _push_app_log!(m, "[INFO] :scope reservoir $varname")
    catch err
        _push_app_log!(m, "[ERROR] :scope reservoir '$varname': " *
                          sprint(showerror, err))
    end
    return
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
    title = if type === :wave
        "scope: wave  Y×$(round(m.scope_zoom; digits=2)) X×$(round(m.scope_zoom_x; digits=2))   (+/-/= amp,  >/</= time)"
    elseif type === :reservoir
        rname = _APP_SCOPE_RESERVOIR_NAME[]
        sp = round(m.scope_reservoir_span_seconds; digits=2)
        "scope: reservoir · $rname   span=$(sp)s   (+/- adjust, rows = neurons, ◼ = spike)"
    elseif type === Symbol("reservoir-graph")
        rname = _APP_SCOPE_RESERVOIR_NAME[]
        "scope: reservoir-graph · $rname   (● = spike fires, edges = synapses from firing units)"
    else
        "scope: $type   (S cycles, :scope <type> picks: amp wave spectrum xy goni spectrogram peak pitch onset hist corr reservoir reservoir-graph)"
    end
    TK.set_string!(buf, area.x, area.y, rpad(first(title, w), w),
                   TK.tstyle(:accent, bold=true))
    body_y = area.y + 1
    body_h = h - 1
    body_area = TK.Rect(area.x, body_y, w, body_h)
    # Reservoir scope handles itself — it has no `data` from the OSC
    # listener, only reads from the attached reservoir's history field.
    if type === :reservoir
        _app_render_reservoir(body_area, buf, m)
        return
    end
    if type === Symbol("reservoir-graph")
        _app_render_reservoir_graph(body_area, buf, m)
        return
    end
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

"""
    _app_render_reservoir(area, buf)

Raster plot of the currently-attached reservoir's spike history. Rows
are neurons (downsampled if N > area.height); columns are recent steps
(oldest left, newest right). A solid block ◼ marks a spike at that
(neuron, step) cell. If the reservoir is RECA, the plot looks like a
classic cellular-automaton trail.
"""
function _app_render_reservoir(area::TK.Rect, buf::TK.Buffer, m::RessacApp)
    r = _APP_SCOPE_RESERVOIR[]
    if r === nothing
        TK.set_string!(buf, area.x, area.y,
                       "  (no reservoir attached — use :scope reservoir <var>)",
                       TK.tstyle(:text_dim))
        return
    end
    # Snapshot the history vector once so the scheduler thread can keep
    # pushing while we render. `r.history` is mutated by `step!` on the
    # scheduler task, so a live `hist[i]` would race with `push!` /
    # `popfirst!` (the array can be in a transient state with undef
    # backing slots during reallocation).
    hist = _safe_history_snapshot(r.history)
    if isempty(hist)
        TK.set_string!(buf, area.x, area.y,
                       "  (waiting for spikes — drive the reservoir to populate)",
                       TK.tstyle(:text_dim))
        return
    end
    N = length(r)
    H = area.height
    W = area.width
    H < 1 || W < 1 && return

    # Time-span view: `span_seconds` of recent wall-clock time fits
    # into the area. Estimate step rate from the live scheduler.
    sched = _LIVE_SCHEDULER[]
    cps = sched === nothing ? 0.5 : sched.cps
    steps_per_sec = r.spc * cps
    n_visible_steps = max(1,
        round(Int, m.scope_reservoir_span_seconds * steps_per_sec))
    first_hist_idx = max(1, length(hist) - n_visible_steps + 1)

    # Braille rendering: each terminal cell encodes a 2 cols × 4 rows
    # sub-grid → 8× density. "Now" sits on the right edge so newer
    # spikes always enter from the right and scroll leftward.
    sub_W = W * 2
    sub_H = H * 4
    steps_per_subcol = n_visible_steps / sub_W
    n_sub_rows = min(N, sub_H)
    sub_row_of_neuron = n_sub_rows == N ?
        collect(1:N) :
        [round(Int, 1 + (i - 1) * (N - 1) / (n_sub_rows - 1)) for i in 1:n_sub_rows]
    last_hist_idx = length(hist)

    # Pre-compute the (col, row) → bit mapping for Braille dots:
    #   col=0,row=0→dot1 (bit0)   col=1,row=0→dot4 (bit3)
    #   col=0,row=1→dot2 (bit1)   col=1,row=1→dot5 (bit4)
    #   col=0,row=2→dot3 (bit2)   col=1,row=2→dot6 (bit5)
    #   col=0,row=3→dot7 (bit6)   col=1,row=3→dot8 (bit7)
    bit_of(col0::Int, row0::Int) =
        col0 == 0 ? (row0 == 0 ? 0 : row0 == 1 ? 1 : row0 == 2 ? 2 : 6) :
                    (row0 == 0 ? 3 : row0 == 1 ? 4 : row0 == 2 ? 5 : 7)

    active_style = TK.tstyle(:accent, bold = true)
    medium_style = TK.tstyle(:accent)
    quiet_style  = TK.tstyle(:text_dim)

    for cell_col in 1:W
        for cell_row in 1:H
            # 4×2 sub-cells make up this Braille cell.
            bits = 0
            spike_count = 0
            for sub_col_off in 0:1, sub_row_off in 0:3
                sub_col = (cell_col - 1) * 2 + sub_col_off + 1   # 1-based
                sub_row = (cell_row - 1) * 4 + sub_row_off + 1
                sub_row > n_sub_rows && continue
                n_idx = sub_row_of_neuron[sub_row]
                # Right-align: rightmost sub_col = newest history entry.
                offset_from_right = sub_W - sub_col
                h_hi = last_hist_idx - floor(Int, offset_from_right * steps_per_subcol)
                h_lo = last_hist_idx - ceil(Int, (offset_from_right + 1) * steps_per_subcol) + 1
                h_lo > length(hist) && continue
                h_lo = clamp(h_lo, 1, length(hist))
                h_hi = clamp(h_hi, h_lo, length(hist))
                spiked = false
                @inbounds for h_idx in h_lo:h_hi
                    snap = hist[h_idx]
                    if n_idx <= length(snap) && snap[n_idx]
                        spiked = true
                        break
                    end
                end
                if spiked
                    bits |= 1 << bit_of(sub_col_off, sub_row_off)
                    spike_count += 1
                end
            end
            x = area.x + cell_col - 1
            y = area.y + cell_row - 1
            if bits == 0
                TK.set_char!(buf, x, y, '⠀', quiet_style)
            else
                ch = Char(0x2800 + bits)
                # Style by density — many sub-cells active = brighter.
                style = spike_count >= 5 ? active_style :
                        spike_count >= 2 ? medium_style :
                                            TK.tstyle(:accent)
                TK.set_char!(buf, x, y, ch, style)
            end
        end
    end
    return
end

"""
    _app_render_reservoir_graph(area, buf)

Spatial graph view of the attached reservoir. Neurons sit on a circle;
edges are drawn FROM currently-spiking neurons toward the neurons
they connect to. Edge character density (·, ▒, ▓) maps to absolute
weight; positive weights render in :success (excitatory), negative
in :error (inhibitory). Quiet neurons stay as `o`, spikers as `●` in
:accent bold so they "blink" each step they fire.

Only works on plain `AdExReservoir` (needs the W matrix). For RECA
or coupled groups, the raster scope is more meaningful.
"""
function _app_render_reservoir_graph(area::TK.Rect, buf::TK.Buffer, m::RessacApp)
    r = _APP_SCOPE_RESERVOIR[]
    if r === nothing
        TK.set_string!(buf, area.x, area.y,
                       "  (no reservoir attached — use :scope reservoir <var>)",
                       TK.tstyle(:text_dim))
        return
    end
    if !isdefined(Main, :Reservoir) || !(r isa Main.Reservoir.AdExReservoir)
        TK.set_string!(buf, area.x, area.y,
                       "  (graph view needs an AdEx reservoir — try :scope reservoir for raster)",
                       TK.tstyle(:text_dim))
        return
    end
    N = r.N
    H, W = area.height, area.width
    H < 3 || W < 6 && return

    # Position layout: prefer the cached force-directed layout (set by
    # `:scope reservoir-graph`); fall back to a circle if absent.
    layout = _APP_GRAPH_LAYOUT[]
    positions = Vector{Tuple{Int,Int}}(undef, N)
    if length(layout) == N
        # layout coords are in [0, 1]² — map into the area with a small
        # inset so nodes don't sit right on the border.
        inset_x = 2
        inset_y = 1
        ux_w = max(1, W - 2 * inset_x)
        uy_h = max(1, H - 2 * inset_y)
        for i in 1:N
            ux, uy = layout[i]
            x = round(Int, area.x + inset_x + ux * ux_w)
            y = round(Int, area.y + inset_y + uy * uy_h)
            positions[i] = (clamp(x, area.x, area.x + W - 1),
                            clamp(y, area.y, area.y + H - 1))
        end
    else
        cx = area.x + W / 2
        cy = area.y + H / 2
        rx = max(2.0, (W - 4) / 2)
        ry = max(1.5, (H - 2) / 2)
        for i in 1:N
            θ = 2π * (i - 1) / N - π / 2
            x = round(Int, cx + rx * cos(θ))
            y = round(Int, cy + ry * sin(θ))
            positions[i] = (clamp(x, area.x, area.x + W - 1),
                            clamp(y, area.y, area.y + H - 1))
        end
    end

    # Edge weight threshold — only draw the meaningful synapses to keep
    # the picture readable. Use 30% of the max |W| as the floor.
    max_w = maximum(abs, r.W)
    threshold = max_w * 0.3

    # Snapshot history once — see _app_render_reservoir for the race
    # rationale (scheduler thread writes while we read).
    hist = _safe_history_snapshot(r.history)
    sched = _LIVE_SCHEDULER[]
    cps = sched === nothing ? 0.5 : sched.cps
    steps_per_sec = r.N == 0 ? 1.0 : r.spc * cps
    n_window = clamp(round(Int, m.scope_reservoir_span_seconds * steps_per_sec),
                     1, length(hist))
    recency = zeros(Float64, N)
    if !isempty(hist) && n_window > 0
        first_idx = max(1, length(hist) - n_window + 1)
        @inbounds for h_idx in first_idx:length(hist)
            snap = hist[h_idx]
            # Newer entries weighted higher (linear ramp).
            weight = (h_idx - first_idx + 1) / n_window
            for i in 1:min(N, length(snap))
                snap[i] && (recency[i] = max(recency[i], weight))
            end
        end
    end

    # Brightness tiers from recency.
    node_glyph(rec) = rec > 0.8 ? ('●', TK.tstyle(:accent, bold = true)) :
                      rec > 0.4 ? ('●', TK.tstyle(:accent)) :
                      rec > 0.1 ? ('◯', TK.tstyle(:text)) :
                                    ('o', TK.tstyle(:text_dim))
    edge_style(w, src_rec) = begin
        base = w > 0 ? TK.tstyle(:success) : TK.tstyle(:error)
        src_rec > 0.5 ? (w > 0 ? TK.tstyle(:success, bold = true) :
                                  TK.tstyle(:error,   bold = true)) :
                        base
    end

    # Draw edges from any RECENTLY active neuron (not just current step).
    @inbounds for src in 1:N
        src_rec = recency[src]
        src_rec < 0.1 && continue
        sx, sy = positions[src]
        for dst in 1:N
            dst == src && continue
            w = r.W[dst, src]
            absw = abs(w)
            absw < threshold && continue
            tx, ty = positions[dst]
            density = absw / max_w
            # Edge char picks up both weight magnitude AND src recency
            # so fresher spikes leave brighter edge trails.
            combined = density * (0.4 + 0.6 * src_rec)
            ch = combined > 0.55 ? '▓' :
                 combined > 0.25 ? '▒' : '·'
            style = edge_style(w, src_rec)
            for (x, y) in _bresenham_line(sx, sy, tx, ty)
                (x == sx && y == sy) && continue
                (x == tx && y == ty) && continue
                TK.set_char!(buf, x, y, ch, style)
            end
        end
    end

    # Draw nodes on top — brightness reflects recency.
    @inbounds for i in 1:N
        x, y = positions[i]
        ch, style = node_glyph(recency[i])
        TK.set_char!(buf, x, y, ch, style)
    end
    return
end

"Integer-only line walk between two points (Bresenham). Used by the
reservoir graph view to draw edges on the character grid."
function _bresenham_line(x0::Int, y0::Int, x1::Int, y1::Int)
    pts = Tuple{Int,Int}[]
    dx = abs(x1 - x0); dy = abs(y1 - y0)
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx - dy
    x, y = x0, y0
    while true
        push!(pts, (x, y))
        x == x1 && y == y1 && break
        e2 = 2 * err
        if e2 > -dy
            err -= dy; x += sx
        end
        if e2 < dx
            err += dx; y += sy
        end
    end
    pts
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
    _scroll_to_show(cursor, total, body_h, scroll) -> Int

Updated scroll offset so that `cursor` (1-based) is visible inside the
window `[scroll+1, scroll+body_h]`. "Scroll-as-needed" semantics — if
cursor is already in view, leaves `scroll` alone (no jumpy
re-centering on every keystroke). When forced to move, scrolls just
enough to bring the cursor to the nearest edge of the window.

Result is clamped to `[0, max(0, total - body_h)]` so the window
never reveals empty rows past the end of a short list.

Pure helper — used by every list-style modal (browse / lib) to keep
the cursor visible as the user j/k's past the bottom of the viewport.
"""
function _scroll_to_show(cursor::Int, total::Int, body_h::Int, scroll::Int)
    body_h <= 0 && return 0
    new_scroll = scroll
    if cursor < new_scroll + 1
        new_scroll = max(0, cursor - 1)
    elseif cursor > new_scroll + body_h
        new_scroll = cursor - body_h
    end
    return clamp(new_scroll, 0, max(0, total - body_h))
end

"""
    _open_modal!(m, kind, cursor_field=nothing)

Universal modal entry. Sets `m.modal = kind`, resets `modal_scroll`
to 0, and (when given) resets `cursor_field` to 1. Modals with
their own query / search / page state set those fields after calling
this. Pass `cursor_field = nothing` for scroll-only modals (e.g. wiki).
"""
function _open_modal!(m::RessacApp, kind::Symbol,
                     cursor_field::Union{Symbol,Nothing} = nothing)
    m.modal = kind
    m.modal_scroll = 0
    cursor_field === nothing || setfield!(m, cursor_field, 1)
    return nothing
end

"""
    _modal_cursor_nav!(m, evt, cursor_field, n) -> Bool

Standard list-modal cursor navigation: `j` / `:down` increments,
`k` / `:up` decrements. Reads + writes the cursor field via Symbol
lookup so each modal can keep its own (`browser_cursor`,
`mixer_cursor`, …). Cursor stays clamped to `[1, max(n, 1)]`.

Returns `true` iff the event was a nav key and was consumed — the
modal's handler should early-return in that case.
"""
function _modal_cursor_nav!(m::RessacApp, evt::TK.KeyEvent,
                            cursor_field::Symbol, n::Int)
    if evt.char == 'j' || evt.key === :down
        cur = getfield(m, cursor_field)
        setfield!(m, cursor_field, min(cur + 1, max(n, 1)))
        return true
    elseif evt.char == 'k' || evt.key === :up
        cur = getfield(m, cursor_field)
        setfield!(m, cursor_field, max(cur - 1, 1))
        return true
    end
    return false
end

"""
    _modal_close_key!(m, evt) -> Bool

Standard modal close: `Esc` or `q` closes the modal. Returns `true`
iff the modal was closed. Modals that need query-aware Esc (clear
the query first, close on the second Esc) should NOT call this and
handle Esc themselves.
"""
function _modal_close_key!(m::RessacApp, evt::TK.KeyEvent)
    if evt.key === :escape || evt.char == 'q'
        m.modal = :none
        return true
    end
    return false
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
    n_playing = length(pattern_keys(m.scheduler))
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
        _sync_cursor_style!(m.editor)
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
            _sync_cursor_style!(m.editor)
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
                    _sync_cursor_style!(_current_synth_tab(m).editor)
                    TK.render(_current_synth_tab(m).editor, synth_rows[2], buf)
                    m.layout_synth_tabs = synth_rows[1]
                    m.layout_synth = synth_rows[2]
                end
            else
                m.layout_synth = synth_inner
                _sync_cursor_style!(_current_synth_tab(m).editor)
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
        _render_visual_selection!(m, m.layout_patterns, buf)
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

    # Footer (key hints) + bottom pane with per-level coloring + bordered block.
    # Bottom pane content swaps to a completion picker while a Tab
    # cycle is active; otherwise it's the rolling log.
    _render_footer(m, footer_area, buf)
    if _completion_picker_active(m)
        title       = "COMPLETIONS"
        title_right = "$(m.completion_idx)/$(length(m.completion_candidates)) · Tab next · any other key cancels"
    else
        title       = "LOG"
        title_right = "$(length(m.logs))" *
                      (m.log_scroll > 0 ? " · ↑$(m.log_scroll)" : "")
    end
    _render_pane_block!(m, logs_area, buf;
        title = title, title_right = title_right, focused = false)
    log_inner = _inner_rect(logs_area)
    m.layout_logs = log_inner
    if _completion_picker_active(m)
        _render_completion_picker!(m, log_inner, buf)
    else
        _render_logs(m, log_inner, buf)
    end

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

include("tui_editor_ops.jl")

include("modal_wiki.jl")

include("modal_snippets.jl")

include("tui_input_modes.jl")

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
    _humanize_eval_error(e, src) -> String

Map common Julia exceptions thrown during pattern eval into one-line
hints that point a non-dev user toward a fix. Falls back to the raw
`showerror` text when no recogniser matches.

  • UndefVarError(:foo)   → "le nom `foo` n'existe pas — :browse / :doc"
  • MethodError on |>      → "type mismatch in the pipe chain — check the |> args"
  • Meta.parse ParseError → "syntax error at position N — check brackets / quotes"
  • LoadError wrapper      → unwrap once and recurse
"""
function _humanize_eval_error(e, src::AbstractString)
    if e isa LoadError
        return _humanize_eval_error(e.error, src)
    end
    if e isa UndefVarError
        nm = String(e.var)
        return "unknown name `$nm` — :browse to see loaded sounds, or :doc $nm"
    end
    if e isa Base.Meta.ParseError
        # Pull out the position if present in the message.
        msg = sprint(showerror, e)
        return "parse error — check matching brackets / quotes in this line · $(first(msg, 90))"
    end
    if e isa MethodError
        fname = string(e.f)
        # Symbol-into-pipe-callback is the most common mistake — give
        # a targeted hint when the failed call ate a Symbol.
        if any(a -> a isa Symbol, e.args)
            return "type mismatch on `$fname` — a Symbol slipped into a Pattern slot. " *
                   "Wrap the name in `pure(:foo)` or use `p\"foo\"`."
        end
        return "no method `$fname` for these arguments — check the |> chain types"
    end
    if e isa ArgumentError
        return "bad arg: $(e.msg)"
    end
    if e isa BoundsError
        return "out-of-range index — pattern length doesn't match `n()` / `degree()` source"
    end
    # Fallback: trim the raw error to one readable line.
    raw = sprint(showerror, e)
    return first(replace(raw, r"\s*\n\s*" => " · "), 160)
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
            # Try to render a human-readable hint based on common
            # Julia error classes. The raw stacktrace stays available
            # in :keydebug logs if the user needs it; the modal log
            # should be actionable, not technical.
            hint = _humanize_eval_error(e, src)
            _push_app_log!(m, "[ERROR] eval $slot: $hint")
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
    _delim_depth(s) -> Int

Net depth of unclosed `(`, `[`, `{` minus matching closers in `s`,
skipping string literals and `#` comments. Used by
`_logical_block_range` to detect multi-line expressions even when a
mid-block line on its own would parse as `:error` (which is what
happens for the tail of a multi-line array literal, e.g.
`     collect(37:48), collect(49:60)],`).
"""
function _delim_depth(s::AbstractString)
    depth = 0
    in_str = false
    str_char = ' '
    in_cmt = false
    i = firstindex(s)
    n = lastindex(s)
    while i <= n
        c = s[i]
        if in_cmt
            c == '\n' && (in_cmt = false)
        elseif in_str
            if c == '\\' && i < n
                i = nextind(s, i)  # skip escaped char
            elseif c == str_char
                in_str = false
            end
        else
            if c == '#'
                in_cmt = true
            elseif c == '"'
                in_str = true; str_char = '"'
            elseif c == '(' || c == '[' || c == '{'
                depth += 1
            elseif c == ')' || c == ']' || c == '}'
                depth -= 1
            end
        end
        i = nextind(s, i)
    end
    depth
end

"""
    _logical_block_range(lines, row) -> (start_row, end_row)

Find the range of lines that form a single logical Julia expression
containing `row`. Walks UP through `|>` continuations and any lines
that leave an open bracket / paren / brace; walks DOWN until those
brackets all close AND the gathered text parses (or we hit EOF).
Comment prefixes (`# ` / `#`) are stripped first so muted blocks have
the same range as their active twin.
"""
function _logical_block_range(lines::AbstractVector, row::Int)
    1 <= row <= length(lines) || return (row, row)
    _strip_cmt(s) = replace(String(s), r"^\s*#+\s*" => "")

    # depths[i] = net delim depth at the START of line i (1-based).
    # Walking up while depths[i] > 0 means "still inside an unclosed
    # bracket from a previous line" — i.e. line i is a continuation.
    stripped = _strip_cmt.(lines)
    depths = zeros(Int, length(lines) + 1)
    for i in 1:length(lines)
        depths[i + 1] = depths[i] + _delim_depth(stripped[i])
    end

    start_row = row
    while start_row > 1
        cur = stripped[start_row]
        if startswith(lstrip(cur), "|>") || depths[start_row] > 0
            start_row -= 1
        else
            break
        end
    end

    end_row = row
    # First close every still-open bracket from start_row's perspective.
    while end_row < length(lines) && depths[end_row + 1] > depths[start_row]
        end_row += 1
    end
    # Then keep extending while the joined block is still parse-incomplete
    # or the next line continues with `|>`.
    while end_row < length(lines)
        block = join(stripped[start_row:end_row], "\n")
        parsed = Meta.parse(block; raise = false)
        is_inc = parsed isa Expr && parsed.head === :incomplete
        next_cont = startswith(lstrip(stripped[end_row + 1]), "|>")
        if is_inc || next_cont
            end_row += 1
        else
            break
        end
    end
    return (start_row, end_row)
end

function _eval_current_line!(m::RessacApp)
    ce = _active_editor(m)
    txt = TK.text(ce)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ce.cursor_row
    1 <= row <= length(lines) || return
    isempty(strip(lines[row])) && return
    (start_row, end_row) = _logical_block_range(lines, row)
    block = join(lines[start_row:end_row], "\n")
    try
        ex = Meta.parse(block)
        result = Core.eval(Main, ex)
        rstr = sprint(io -> show(IOContext(io, :limit=>true, :displaysize=>(1, 60)), result))
        _push_app_log!(m, "[INFO] eval ⇒ $rstr")
        # Cascade: if this eval rebound any top-level names, sweep the
        # buffer for `@dN` blocks that reference them and re-eval, so the
        # slots pick up the new value. Single-level (no recursive cascade).
        rebound = _names_bound_by(ex)
        if !isempty(rebound)
            _cascade_dN_reeval!(m, lines, rebound, start_row, end_row)
            # If the scope is attached to a name we just rebound, re-
            # resolve the reference so the visualisation tracks the
            # fresh reservoir instead of the dead one. Pre-computes the
            # graph layout when applicable.
            if _APP_SCOPE_RESERVOIR_NAME[] in rebound
                _refresh_scope_reservoir!(m)
            end
        end
    catch err
        _push_app_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end

# Collect names bound by a top-level expression. Handles assignments,
# function definitions, and `const`. Used by the cascade re-eval to
# decide which dependent @dN blocks need refreshing.
function _names_bound_by(ex)
    names = Set{Symbol}()
    _collect_bound_names!(names, ex)
    names
end

_collect_bound_names!(::Set{Symbol}, ::Any) = nothing

function _collect_bound_names!(names::Set{Symbol}, ex::Expr)
    if ex.head === :(=)
        lhs = ex.args[1]
        if lhs isa Symbol
            push!(names, lhs)
        elseif lhs isa Expr && lhs.head === :call
            fname = lhs.args[1]
            fname isa Symbol && push!(names, fname)
        elseif lhs isa Expr && lhs.head === :tuple
            for s in lhs.args
                s isa Symbol && push!(names, s)
            end
        end
    elseif ex.head === :function
        sig = ex.args[1]
        if sig isa Expr && sig.head === :call
            fname = sig.args[1]
            fname isa Symbol && push!(names, fname)
        end
    elseif ex.head === :const || ex.head === :global
        for sub in ex.args
            _collect_bound_names!(names, sub)
        end
    elseif ex.head === :block
        for sub in ex.args
            _collect_bound_names!(names, sub)
        end
    end
    return
end

# Walk the buffer, find every `@dN ...` block (multi-line aware), and
# re-eval those whose AST references any of `rebound`. The block being
# eval'd (rows in `skip_first..skip_last`) is excluded.
function _cascade_dN_reeval!(m::RessacApp, lines::Vector,
                              rebound::Set{Symbol},
                              skip_first::Int, skip_last::Int)
    n = length(lines)
    i = 1
    n_cascade = 0
    while i <= n
        line = lines[i]
        if !occursin(r"^\s*@d\d+\b", line)
            i += 1
            continue
        end
        # Found a @dN line — extend down while incomplete.
        end_row = i
        block = String(line)
        while end_row < n
            parsed = Meta.parse(block; raise = false)
            if parsed isa Expr && parsed.head === :incomplete
                end_row += 1
                block = join(lines[i:end_row], "\n")
            else
                break
            end
        end
        # Skip the just-evaled block to avoid double-firing.
        if !(end_row < skip_first || i > skip_last)
            i = end_row + 1
            continue
        end
        # Parse + check for any reference to a rebound name.
        try
            ex = Meta.parse(block)
            if _refs_any(ex, rebound)
                Core.eval(Main, ex)
                n_cascade += 1
            end
        catch err
            _push_app_log!(m,
                "[WARN] cascade row $i: $(sprint(showerror, err))")
        end
        i = end_row + 1
    end
    n_cascade > 0 &&
        _push_app_log!(m, "[INFO] cascade re-evaled $n_cascade slot$(n_cascade == 1 ? "" : "s")")
    return
end

# AST walk: returns true iff `ex` references any symbol in `names`.
_refs_any(ex::Symbol, names::Set{Symbol}) = ex in names
function _refs_any(ex::Expr, names::Set{Symbol})
    for arg in ex.args
        _refs_any(arg, names) && return true
    end
    return false
end
_refs_any(::Any, ::Set{Symbol}) = false

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
            # Eval in the SynthDSL submodule so unqualified UGen names
            # (saw, sin_osc, rlpf, …) resolve. Main only has the Pattern
            # signal variants of the colliding names (saw, tri, square).
            Core.eval(SynthDSL, Meta.parse(src))
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

