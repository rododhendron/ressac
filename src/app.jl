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
end

"""
    RessacApp

Top-level Tachikoma model. Holds the live scheduler, a patterns
CodeEditor, an optional stack of synth tabs (side panel when
non-empty), and the focus toggle for keystroke routing.
"""

@kwdef mutable struct RessacApp <: TK.Model
    scheduler::Scheduler
    editor::TK.CodeEditor = TK.CodeEditor(;
        text     = "@d1 p\"bd hh sn hh\"",
        block    = TK.Block(title = "patterns",
                            border_style = TK.tstyle(:border),
                            title_style  = TK.tstyle(:title)),
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
       (evt.char == 'T' || evt.char == ' ') && _synth_pane_open(m)
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
        elseif (evt.char == 'T' || evt.char == ' ') && _synth_pane_open(m)
            # Space and T both fire the test — Space is right there
            # under the thumb, faster than reaching for a capital T
            # when iterating on a sound.
            _fire_t_with_accel!(m)
            return
        elseif evt.char == 'K' && m.focus === :patterns
            _preview_word_under_cursor!(m); return
        elseif evt.char == 'S'
            # Allow S anywhere — scope is useful even without a synth
            # pane open (e.g. while a pattern is playing).
            _scope_cycle_key!(m); return
        elseif evt.char == 'm' && m.focus === :patterns
            _toggle_mute_current_line!(m); return
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
    # Tab autocomplete in :insert mode (word under cursor → registry /
    # combinator / @dN macro). Intercept BEFORE the editor types a Tab
    # character into the buffer. On any other key in :insert, reset the
    # cycle state so the next Tab starts fresh.
    if is_press && ed.mode === :insert
        if evt.key === :tab
            if _try_autocomplete!(m, ed)
                return
            end
        else
            _reset_completion!(m)
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
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
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
        # Snippet lands on a NEW line under the current one. Same
        # indentation as the source line so it visually chains.
        indent = " " ^ (length(line) - length(lstrip(line)))
        insert!(lines, row + 1, indent * lstrip(snippet))
        ed.cursor_row = row + 1
        ed.cursor_col = length(lines[row + 1])
    else
        lines[row] = line * snippet
        ed.cursor_col = length(lines[row])
    end
    if nl_after
        insert!(lines, ed.cursor_row + 1, "")
        ed.cursor_row += 1
        ed.cursor_col = 0
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
    inset_left = has_block ? 1 : 0
    gw = m.editor.show_line_numbers ? ndigits(max(length(m.editor.lines), 1)) + 1 : 0
    for (i, line_chars) in enumerate(m.editor.lines)
        # Map buffer row → screen row through scroll_offset.
        screen_row = rect.y + inset_top + (i - 1 - m.editor.scroll_offset)
        screen_row < rect.y + inset_top && continue
        screen_row >= rect.y + rect.height && break
        line = String(line_chars)
        mt = match(_PLAYHEAD_LINE_RX, line)
        mt === nothing && continue
        slot = Symbol("d", mt.captures[1])
        haskey(sched.patterns, slot) || continue
        body = String(mt.captures[2])
        isempty(body) && continue
        # Find the body's column span inside the line. m.offsets gives
        # the byte offset of the start of capture #2; convert to a
        # display column (we assume ASCII for mininotation — bd / hh
        # etc — which is fine in practice).
        body_offset = mt.offsets[2]
        body_start_col = body_offset - 1   # 0-based column of first char inside the quotes
        body_len = length(body)
        # Top-level token split by whitespace, ignoring whitespace
        # inside [...] / <...> / (...). Simple state machine.
        tokens = _split_minino_top(body)
        isempty(tokens) && continue
        n = length(tokens)
        active = clamp(floor(Int, phase * n) + 1, 1, n)
        tok_start_in_body, tok_stop_in_body = tokens[active]
        # Convert body-relative positions to screen x.
        screen_x_start = rect.x + inset_left + gw + body_start_col + tok_start_in_body - ed_h_scroll(m.editor)
        screen_x_stop  = rect.x + inset_left + gw + body_start_col + tok_stop_in_body  - ed_h_scroll(m.editor)
        # Clip to pane rect.
        for body_col in tok_start_in_body:tok_stop_in_body
            screen_x = rect.x + inset_left + gw + body_start_col +
                       body_col - ed_h_scroll(m.editor)
            screen_x < rect.x + inset_left + gw && continue
            screen_x >= rect.x + rect.width && break
            # Pull the source char from the buffer line so the underlay
            # text shows through with the new style.
            buf_col = body_start_col + body_col + 1   # 1-based char index in line
            ch = buf_col <= length(line_chars) ? line_chars[buf_col] : ' '
            TK.set_char!(buf, screen_x, screen_row, ch,
                         TK.tstyle(:accent, bold=true))
        end
    end
end

ed_h_scroll(ed::TK.CodeEditor) = ed.h_scroll

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
    "scratch", "sandbox",
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
function _handle_ex_command!(m::RessacApp, cmd::AbstractString)
    if cmd in ("q", "quit", "q!", "qa", "qa!")
        m.quit = true
    elseif (mt = match(r"^synth\s+(\w+)$", cmd)) !== nothing
        _open_synth_tab!(m, mt.captures[1])
    elseif cmd in ("synth", "scratch", "sandbox")
        # No name → spawn a fresh sandbox tab. The starter template
        # loads with a randomised :sketch_<id> name; rename happens on
        # `:w <real_name>` (which uses the existing save-as path).
        _open_sandbox_synth!(m)
    elseif cmd == "back"
        _close_synth_pane!(m)
    elseif cmd == "close"
        _close_active_synth_tab!(m)
    elseif cmd == "tabs"
        _list_synth_tabs!(m)
    elseif cmd in ("tabnext", "tabn")
        _cycle_synth_tab!(m; dir=+1)
    elseif cmd in ("tabprev", "tabp")
        _cycle_synth_tab!(m; dir=-1)
    elseif cmd in ("w", "save-synth")
        # `:w` in synth pane saves the synth; in patterns pane saves
        # the buffer as the default session (./sessions/_last.txt).
        if m.focus === :synth && _synth_pane_open(m)
            _save_current_synth!(m)
        else
            _save_session_app!(m, "_last")
        end
    elseif (mt = match(r"^w\s+(\S+)$", cmd)) !== nothing
        # `:w <name>` — in synth pane = save-as. In patterns pane = save
        # this buffer as ./sessions/<name>.txt.
        if m.focus === :synth && _synth_pane_open(m)
            _save_current_synth!(m; new_name = mt.captures[1])
        else
            _save_session_app!(m, mt.captures[1])
        end
    elseif cmd in ("test", "t")
        _synth_pane_open(m) && _test_current_synth!(m)
    elseif cmd == "test-raw"
        _synth_pane_open(m) && _test_current_synth!(m; raw=true)
    elseif (mt = match(r"^scope\s+(\w+)$", cmd)) !== nothing
        _scope_command!(m, Symbol(mt.captures[1]))
    elseif cmd == "scope"
        _scope_command!(m, :off)
    elseif cmd in ("guide", "help", "?")
        m.modal = :guide; m.modal_scroll = 0
    elseif cmd == "synth-guide"
        m.modal = :synth_guide; m.modal_scroll = 0
    elseif cmd in ("browse", "b")
        _open_browser!(m)
    elseif cmd in ("synthlib", "synth-library", "lib")
        _open_synth_library!(m)
    elseif cmd in ("snip", "snippets", "snippet")
        _open_snippets!(m)
    elseif cmd in ("sccode", "sc")
        _open_sccode!(m)
    elseif (mt = match(r"^(?:sccode|sc)\s+(\S+)$", cmd)) !== nothing
        _direct_load_sccode!(m, mt.captures[1])
    elseif (mt = match(r"^(?:sccode-tag|sctag)\s+(\S+)$", cmd)) !== nothing
        _open_sccode!(m; tag = mt.captures[1])
    elseif cmd in ("panic",)
        _panic!(m)
    elseif cmd in ("hush", "stop", "silence")
        _hush!(m)
    elseif cmd in ("rec", "record")
        _toggle_recording!(m)
    elseif (mt = match(_SHORTCUT_RX, cmd)) !== nothing
        # Compact pattern shortcut DSL — :sg0.9 → append " |> gain(0.9)",
        # :sng0.9 → newline first, :sg0.9N → newline after.
        _apply_pattern_shortcut!(m,
            mt.captures[1] == "n",
            String(mt.captures[2]),
            strip(String(mt.captures[3])),
            mt.captures[4] == "N")
    elseif (mt = match(r"^export(?:-synth)?\s+(\S+)$", cmd)) !== nothing
        _export_current_synth!(m; duration = parse(Float64, mt.captures[1]))
    elseif cmd in ("export", "export-synth")
        _export_current_synth!(m)
    elseif (mt = match(r"^rec(?:ord)?\s+start\s+(\S+)$", cmd)) !== nothing
        _start_recording!(m, mt.captures[1])
    elseif (mt = match(r"^rec(?:ord)?\s+start$", cmd)) !== nothing
        _start_recording!(m)
    elseif (mt = match(r"^rec(?:ord)?\s+stop$", cmd)) !== nothing
        _stop_recording!(m)
    elseif (mt = match(r"^theme\s+(\w+)$", cmd)) !== nothing
        name = Symbol(mt.captures[1])
        if _apply_theme!(name)
            _push_app_log!(m, "[INFO] theme → $name")
        else
            _push_app_log!(m, "[ERROR] theme '$name' not found — try: " *
                           join(_available_themes()[1:min(end,8)], ", ") * ", …")
        end
    elseif cmd == "theme"
        _push_app_log!(m, "[INFO] themes: " * join(_available_themes(), ", "))
    elseif cmd in ("reload-config", "reload-cfg")
        cfg = _load_ressac_config!()
        _apply_theme!(cfg.theme)
        _push_app_log!(m, "[INFO] config reloaded — theme=$(cfg.theme), t_init=$(cfg.t_hold_initial_ms)ms accel=$(cfg.t_hold_accel)")
    elseif (mt = match(r"^doc\s+(\w+)$", cmd)) !== nothing
        _doc_command!(m, mt.captures[1])
    elseif cmd == "doc"
        _push_app_log!(m, "[INFO] :doc <name> — try gain/release/cutoff/cps/gate/…")
    elseif cmd == "keydebug"
        m.keydebug = !m.keydebug
        _push_app_log!(m, "[INFO] keydebug $(m.keydebug ? "ON" : "OFF") — every keypress will be logged")
    elseif cmd in ("pause", "freeze")
        m.paused = true
        _push_app_log!(m, "[INFO] paused — shift-drag to select & copy, any key resumes")
    elseif cmd in ("copylogs", "yanklogs")
        _copy_logs_to_clipboard!(m)
    elseif (mt = match(r"^starter\s+(\w+)$", cmd)) !== nothing
        _starter_command!(m, mt.captures[1])
    elseif cmd == "starter"
        _push_app_log!(m, "[INFO] :starter <genre> — " *
                         join(sort!(collect(keys(_STARTER_PACKS))), ", "))
    elseif (mt = match(r"^scale\s+(\w+)$", cmd)) !== nothing
        name = Symbol(mt.captures[1])
        if haskey(_SCALES, name)
            _CURRENT_SCALE[] = name
            _push_app_log!(m, "[INFO] scale set to :$name (use degree(x))")
        else
            _push_app_log!(m, "[WARN] :scale — unknown '$name'")
        end
    elseif cmd == "scale"
        _push_app_log!(m, "[INFO] current scale: $(_CURRENT_SCALE[])")
    elseif (mt = match(r"^cps\s+(\S+)$", cmd)) !== nothing
        try
            set_cps!(m.scheduler, parse(Float64, mt.captures[1]))
            _push_app_log!(m, "[INFO] cps = $(mt.captures[1])")
        catch err
            _push_app_log!(m, "[ERROR] cps: $(sprint(showerror, err))")
        end
    elseif (mt = match(r"^mute\s+(d\d+)$", cmd)) !== nothing
        _mute_pattern_slot!(m, Symbol(mt.captures[1]))
    elseif (mt = match(r"^unmute\s+(d\d+)$", cmd)) !== nothing
        _unmute_pattern_slot!(m, Symbol(mt.captures[1]))
    elseif cmd == "unmute"
        _unmute_all_patterns!(m)
    elseif (mt = match(r"^solo\s+(d\d+)$", cmd)) !== nothing
        _solo_pattern_slot!(m, Symbol(mt.captures[1]))
    elseif cmd == "unsolo"
        _unmute_all_patterns!(m)
    elseif (mt = match(r"^save-session\s+(\S+)$", cmd)) !== nothing
        _save_session_app!(m, mt.captures[1])
    elseif (mt = match(r"^load-session\s+(\S+)$", cmd)) !== nothing
        _load_session_app!(m, mt.captures[1])
    else
        _push_app_log!(m, "[WARN] unknown command: :$cmd")
    end
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
        _push_app_log!(m, "[ERROR] load-session: no file at $path")
        return
    end
    try
        TK.set_text!(m.editor, read(path, String))
        m.editor.cursor_row = 1; m.editor.cursor_col = 0
        _push_app_log!(m, "[INFO] loaded session '$name'")
    catch err
        _push_app_log!(m, "[ERROR] load-session: $(sprint(showerror, err))")
    end
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
    else
        _push_app_log!(m, "[doc] $name — $desc")
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

# ---------------------------------------------------------------------
# Synth library picker
# ---------------------------------------------------------------------

function _open_synth_library!(m::RessacApp)
    m.modal = :synth_library
    m.synthlib_cursor = 1
end

"""
    _synthlib_all_entries() -> Vector{_SynthLibEntry}

Built-in starter pack + every `plugins/user-synths/*.scd` the user has
saved, exposed as the same `_SynthLibEntry` shape. User entries get
category "user" and an excerpt of their first comment line as the
description, so the modal renders them alongside the built-ins.
"""
function _synthlib_all_entries()
    entries = copy(_SYNTH_LIBRARY)
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || return entries
    for f in sort!(readdir(dir))
        endswith(f, ".scd") || continue
        name = String(splitext(f)[1])
        # Don't double-list a user file that shadows a built-in name —
        # the user's edits are what they want to revisit.
        existing = findfirst(e -> e.name == name, entries)
        path = joinpath(dir, f)
        src = try read(path, String) catch; "" end
        desc = _first_comment_line(src)
        if existing !== nothing
            entries[existing] = _SynthLibEntry(name, "user", desc, src)
        else
            push!(entries, _SynthLibEntry(name, "user", desc, src))
        end
    end
    return entries
end

function _first_comment_line(src::AbstractString)
    for line in split(src, '\n'; limit=20)
        s = strip(line)
        startswith(s, "//") || continue
        body = strip(replace(String(s), r"^//+\s*" => ""))
        isempty(body) && continue
        return first(body, 60)
    end
    return "user synth"
end

function _handle_synthlib_key!(m::RessacApp, evt::TK.KeyEvent)
    n = length(_synthlib_all_entries())
    if evt.key === :escape || evt.char == 'q'
        m.modal = :none
    elseif evt.char == 'j' || evt.key === :down
        m.synthlib_cursor = min(m.synthlib_cursor + 1, n)
    elseif evt.char == 'k' || evt.key === :up
        m.synthlib_cursor = max(m.synthlib_cursor - 1, 1)
    elseif evt.char == ' '
        _preview_synth_from_library!(m)
    elseif evt.key === :enter || evt.char == '\r'
        _instantiate_synth_from_library!(m)
    end
end

"""
    _preview_synth_from_library!(m)

Fire the synth at the cursor with its own defaults — same OSC path
T uses for the editor's T-test (`/ressac/evalAndPlay`: SC interprets
the source, syncs, then `Synth(name, [\\out, 0])`). Lets the user
audition library entries before deciding to instantiate one.
"""
function _preview_synth_from_library!(m::RessacApp)
    entries = _synthlib_all_entries()
    1 <= m.synthlib_cursor <= length(entries) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    entry = entries[m.synthlib_cursor]
    send_osc(sched.osc,
             encode(OSCMessage("/ressac/evalAndPlay",
                                Any[entry.name, entry.source])))
    _push_app_log!(m, "[INFO] preview $(entry.name) (defaults)")
end

"""
    _instantiate_synth_from_library!(m)

Selected library entry → write the source to plugins/user-synths/
<name>.scd (renaming if the file already exists so we don't clobber the
user's edits) and open it as a new synth tab. The user can iterate on
the copy without affecting the canonical template.
"""
function _instantiate_synth_from_library!(m::RessacApp)
    entries = _synthlib_all_entries()
    1 <= m.synthlib_cursor <= length(entries) || return
    entry = entries[m.synthlib_cursor]
    # User-saved synths: don't deep-copy, just open the existing file.
    if entry.category == "user"
        m.modal = :none
        _open_synth_tab!(m, entry.name)
        return
    end
    name = entry.name
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    # If <name>.scd already exists, append -2, -3, ... so we never
    # overwrite a synth the user has been working on.
    target = joinpath(dir, "$name.scd")
    n = 1
    while isfile(target)
        n += 1
        target = joinpath(dir, "$name-$n.scd")
    end
    final_name = n == 1 ? name : "$name-$n"
    # The SynthDef declaration inside `source` is hard-coded to the
    # original name; rewrite it so the file's name matches the
    # SynthDef name (SC needs them to match for the load path).
    src = replace(entry.source, "SynthDef(\\$(entry.name)" => "SynthDef(\\$(final_name)")
    write(target, src)
    m.modal = :none
    _open_synth_tab!(m, final_name)
    _push_app_log!(m, "[INFO] synth library: instantiated $final_name from \"$(entry.name)\"")
end

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
    aw, ah = area.width, area.height
    box_w = max(60, min(aw - 4, 120))
    box_h = max(12, min(ah - 4, length(entries) + 6))
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    inner_w = box_w - 2
    # Title row.
    title_str = "┌ browse — j/k nav, K preview, Tab filter, Enter insert, Esc close " *
                "─" ^ max(0, box_w - 60) * "┐"
    TK.set_string!(buf, box_x, box_y, first(title_str, box_w),
                   TK.tstyle(:title, bold=true))
    # Header: filter + query
    header = "│ filter: $(m.browser_filter)     query: $(m.browser_query)█" *
             " " ^ max(0, inner_w - 30 - length(m.browser_query)) * "│"
    TK.set_string!(buf, box_x, box_y + 1, first(header, box_w), TK.tstyle(:text))
    # Separator
    TK.set_string!(buf, box_x, box_y + 2, "│" * "─" ^ inner_w * "│",
                   TK.tstyle(:text_dim))
    # Body
    body_y = box_y + 3
    body_h = box_h - 4
    visible = m.modal_scroll + 1 <= length(entries) ?
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
        padded = "│" * rpad(first(line, inner_w), inner_w) * "│"
        style = if i <= length(visible) && (m.modal_scroll + i) == m.browser_cursor
            TK.tstyle(:accent, bold=true)
        else
            TK.tstyle(:text)
        end
        TK.set_string!(buf, box_x, body_y + i - 1, padded, style)
    end
    # Bottom border
    bot = "└ $(length(entries)) match$(length(entries) == 1 ? "" : "es") " *
          "─" ^ max(0, inner_w - 20) * "┘"
    TK.set_string!(buf, box_x, box_y + box_h - 1, first(bot, box_w),
                   TK.tstyle(:title, bold=true))
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
    String[]

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
    aw, ah = area.width, area.height
    box_w = max(40, min(aw - 4, 100))
    box_h = max(8, min(ah - 4, length(lines) + 4))
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    inner_w = box_w - 2
    inner_h = box_h - 2
    # Title.
    title = m.modal === :guide ? ":guide" :
            m.modal === :synth_guide ? ":synth-guide" : ""
    title_str = "┌ $title — j/k scroll, q close" * "─" ^ max(0, box_w - length(title) - 30) * "┐"
    TK.set_string!(buf, box_x, box_y, first(title_str, box_w),
                   TK.tstyle(:title, bold=true))
    # Body.
    visible_end = min(length(lines), m.modal_scroll + inner_h)
    visible = m.modal_scroll + 1 <= length(lines) ?
              lines[(m.modal_scroll + 1):visible_end] :
              String[]
    for i in 1:inner_h
        line = i <= length(visible) ? visible[i] : ""
        padded = "│" * rpad(first(line, inner_w), inner_w) * "│"
        TK.set_string!(buf, box_x, box_y + i, padded, TK.tstyle(:text))
    end
    # Bottom border.
    bot = "└" * "─" ^ inner_w * "┘"
    TK.set_string!(buf, box_x, box_y + box_h - 1, bot, TK.tstyle(:title, bold=true))
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
    # Layout rows: status / editor (fill) / [scope] / livedoc / footer / logs
    constraints = scope_active ?
        [TK.Fixed(1), TK.Fill(), TK.Fixed(scope_height), TK.Fixed(1), TK.Fixed(1), TK.Fixed(8)] :
        [TK.Fixed(1), TK.Fill(), TK.Fixed(1), TK.Fixed(1), TK.Fixed(8)]
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
    # Record each pane's screen rect so the mouse handler can route
    # clicks / hovers to the right widget.
    m.layout_synth = nothing
    m.layout_synth_tabs = nothing
    if !_synth_pane_open(m)
        m.layout_patterns = body_area
        TK.render(m.editor, body_area, buf)
    else
        cols = TK.split_layout(TK.Layout(TK.Horizontal, [TK.Fill(), TK.Fill()]), body_area)
        if length(cols) >= 2
            m.layout_patterns = cols[1]
            TK.render(m.editor, cols[1], buf)
            if length(m.synth_tabs) > 1
                synth_rows = TK.split_layout(
                    TK.Layout(TK.Vertical, [TK.Fixed(1), TK.Fill()]), cols[2])
                if length(synth_rows) >= 2
                    bar = TK.TabBar([tab.name for tab in m.synth_tabs];
                                    active  = m.synth_tab_idx,
                                    focused = (m.focus === :synth))
                    TK.render(bar, synth_rows[1], buf)
                    TK.render(_current_synth_tab(m).editor, synth_rows[2], buf)
                    m.layout_synth_tabs = synth_rows[1]
                    m.layout_synth = synth_rows[2]
                end
            else
                m.layout_synth = cols[2]
                TK.render(_current_synth_tab(m).editor, cols[2], buf)
            end
        end
    end

    # Scope panel (if any)
    m.layout_scope = scope_area
    if scope_area !== nothing
        _render_app_scope(m, scope_area, buf)
    end

    # Playhead — highlights the active token in every @dN p"..." line
    # that's currently shipping events. Overlays AFTER the editor
    # rendered so we paint on top of the existing cells.
    if m.layout_patterns !== nothing
        _render_playhead!(m, m.layout_patterns, buf)
    end

    # Live doc row — word under cursor → doc string
    _render_livedoc_row(m, livedoc_area, buf)

    # Footer (key hints) + logs with per-level coloring.
    _render_footer(m, footer_area, buf)
    m.layout_logs = logs_area
    _render_logs(m, logs_area, buf)

    # Modal overlay (after everything else so it sits on top).
    if m.modal === :browse
        _render_browser_modal!(m, f.area, buf)
    elseif m.modal === :synth_library
        _render_synth_library_modal!(m, f.area, buf)
    elseif m.modal === :sccode
        _render_sccode_modal!(m, f.area, buf)
    elseif m.modal === :snippets
        _render_snippets_modal!(m, f.area, buf)
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
# Snippets — context-aware multi-line templates
# ---------------------------------------------------------------------

"""
    _snip_context(m) -> Symbol

`:patterns` when the patterns pane is focused, `:synth` when a
synth pane is open and focused. Used by the picker to filter
snippets that don't make sense in the current pane.
"""
function _snip_context(m::RessacApp)
    (m.focus === :synth && _synth_pane_open(m)) ? :synth : :patterns
end

function _snippets_visible(m::RessacApp)
    ctx = _snip_context(m)
    base = _snippets_for_context(ctx)
    isempty(m.snip_query) && return base
    q = lowercase(m.snip_query)
    return [s for s in base
            if occursin(q, lowercase(s.trigger)) ||
               occursin(q, lowercase(s.category)) ||
               occursin(q, lowercase(s.description))]
end

function _open_snippets!(m::RessacApp)
    m.modal = :snippets
    m.snip_cursor = 1
    m.snip_query = ""
    m.snip_search_mode = false
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
        else
            m.modal = :none
        end
    elseif evt.char == '/'
        m.snip_search_mode = true
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
    aw, ah = area.width, area.height
    box_w = max(60, min(aw - 4, 110))
    box_h = max(12, ah - 4)
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    ctx_label = _snip_context(m) === :synth ? "synth pane" : "patterns pane"
    title = "┌ snippets ($ctx_label) — / search, j/k move, Space preview, Enter insert, q close "
    title = title * "─" ^ max(0, box_w - length(title) - 1) * "┐"
    TK.set_string!(buf, box_x, box_y, first(title, box_w),
                   TK.tstyle(:title, bold=true))
    # Search bar.
    sb_prefix = m.snip_search_mode ? "  /" : "  ⌕ "
    sb_text = sb_prefix * m.snip_query *
              (m.snip_search_mode ? "▏" : "")
    sb_style = m.snip_search_mode ?
        TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, box_x, box_y + 1,
                   "│ " * rpad(first(sb_text, box_w - 4), box_w - 4) * " │",
                   sb_style)
    # Body.
    body_h = box_h - 4
    n = length(snips)
    if n == 0
        msg = isempty(m.snip_query) ?
            "(no snippets for this context)" :
            "(no match for \"$(m.snip_query)\")"
        TK.set_string!(buf, box_x + 2, box_y + 3, msg, TK.tstyle(:text_dim))
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
            style = is_cur ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text)
            line = "│ " * first(label, box_w - 4) * " │"
            screen_y = box_y + 1 + slot
            TK.set_string!(buf, box_x, screen_y, line, style)
            push!(m.modal_rows, (screen_y, i))
        end
    end
    pageline = "│ " * rpad("$(n) snippets shown · ctx = $(_snip_context(m))", box_w - 4) * " │"
    TK.set_string!(buf, box_x, box_y + box_h - 2, first(pageline, box_w),
                   TK.tstyle(:text_dim))
    foot = "└" * "─" ^ (box_w - 2) * "┘"
    TK.set_string!(buf, box_x, box_y + box_h - 1, foot,
                   TK.tstyle(:title, bold=true))
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

# ---------------------------------------------------------------------
# sccode.org browser
# ---------------------------------------------------------------------

"""
    _open_sccode!(m)

Open the sccode browser modal and synchronously fetch the first page
of entries. Sccode loads in 1-2s typically; if the user wants more
they hit `n`/`p` to paginate.
"""
function _open_sccode!(m::RessacApp; tag::AbstractString = "")
    m.modal = :sccode
    m.sccode_cursor = 1
    m.sccode_page = 1
    m.sccode_loading = true
    m.sccode_query = ""
    m.sccode_search_mode = false
    m.sccode_tag = String(tag)
    banner = isempty(tag) ? "page 1" : "tag=$(tag), page 1"
    _push_app_log!(m, "[INFO] sccode: fetching $(banner)…")
    try
        m.sccode_entries = _sccode_fetch_list(1; tag = m.sccode_tag)
        m.sccode_loading = false
        _push_app_log!(m, "[INFO] sccode: $(length(m.sccode_entries)) entries loaded")
    catch err
        m.sccode_loading = false
        m.sccode_entries = _SccodeEntry[]
        _push_app_log!(m, "[ERROR] sccode list: $(sprint(showerror, err))")
    end
end

"""
    _direct_load_sccode!(m, ref)

`ref` is either a bare id ("1-5iP") or a full sccode.org URL. Fetches
the source and opens it as a synth tab via the same code path as the
browser's Enter — no modal flow, single command, one keypress to play.
"""
function _direct_load_sccode!(m::RessacApp, ref::AbstractString)
    id = ref
    mt = match(r"sccode\.org/([0-9][\w-]*)", String(ref))
    mt !== nothing && (id = String(mt.captures[1]))
    src = try
        _sccode_fetch_source(id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(id): $(sprint(showerror, err))")
        return
    end
    name = _sccode_extract_synthdef_name(src)
    name === nothing && (name = "sccode_" * replace(String(id), "-" => "_"))
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    target = joinpath(dir, "$(name).scd")
    final_name = name
    n = 1
    while isfile(target)
        n += 1
        final_name = "$name-$n"
        target = joinpath(dir, "$(final_name).scd")
    end
    write(target, "// Imported from sccode.org/$(id)\n//\n" * src)
    register_synth!(SynthEntry(Symbol(final_name), "user-synths",
                               Dict{String,Any}("description" => "imported from sccode",
                                                "tags" => ["sccode"])))
    _open_synth_tab!(m, final_name)
    _push_app_log!(m, "[INFO] sccode/$(id) → plugins/user-synths/$(final_name).scd")
end

"""
    _sccode_filtered(m) -> Vector{_SccodeEntry}

Apply the live query filter against title + id (case-insensitive
substring). When the query is empty just returns the raw list.
"""
function _sccode_filtered(m::RessacApp)
    isempty(m.sccode_query) && return m.sccode_entries
    q = lowercase(m.sccode_query)
    return [e for e in m.sccode_entries
            if occursin(q, lowercase(e.title)) || occursin(q, lowercase(e.id))]
end

function _handle_sccode_key!(m::RessacApp, evt::TK.KeyEvent)
    # Search mode: chars append, backspace pops, Esc/Enter exit (keep query).
    if m.sccode_search_mode
        if evt.key === :escape
            m.sccode_search_mode = false
        elseif evt.key === :enter
            m.sccode_search_mode = false
        elseif evt.key === :backspace
            isempty(m.sccode_query) || (m.sccode_query = m.sccode_query[1:end-1])
            m.sccode_cursor = 1
        elseif evt.key === :char && isprint(evt.char)
            m.sccode_query *= string(evt.char)
            m.sccode_cursor = 1
        end
        return
    end
    n = length(_sccode_filtered(m))
    if evt.key === :escape || evt.char == 'q'
        # Esc with non-empty query clears the filter first; second Esc closes.
        if !isempty(m.sccode_query)
            m.sccode_query = ""
            m.sccode_cursor = 1
        else
            m.modal = :none
        end
    elseif evt.char == '/'
        m.sccode_search_mode = true
    elseif evt.char == 'j' || evt.key === :down
        m.sccode_cursor = min(m.sccode_cursor + 1, max(n, 1))
    elseif evt.char == 'k' || evt.key === :up
        m.sccode_cursor = max(m.sccode_cursor - 1, 1)
    elseif evt.char == 'n'
        _sccode_paginate!(m, +1)
    elseif evt.char == 'p'
        _sccode_paginate!(m, -1)
    elseif evt.char == ' '
        _preview_sccode_filtered!(m)
    elseif evt.key === :enter || evt.char == '\r'
        _load_sccode_filtered!(m)
    end
end

# Wrappers that route through the filtered list so cursor indexing
# matches what the user sees in the modal.
_preview_sccode_filtered!(m::RessacApp) = _sccode_act!(m, _preview_sccode_by_entry!)
_load_sccode_filtered!(m::RessacApp)    = _sccode_act!(m, _load_sccode_by_entry!)

function _sccode_act!(m::RessacApp, f)
    filtered = _sccode_filtered(m)
    1 <= m.sccode_cursor <= length(filtered) || return
    f(m, filtered[m.sccode_cursor])
end

function _preview_sccode_by_entry!(m::RessacApp, entry::_SccodeEntry)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    src = try
        _sccode_fetch_source(entry.id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(entry.id): $(sprint(showerror, err))")
        return
    end
    name = _sccode_extract_synthdef_name(src)
    if name === nothing
        _push_app_log!(m, "[WARN] sccode $(entry.id): no SynthDef, raw eval")
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[entry.id, src])))
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[name, src])))
    _push_app_log!(m, "[INFO] preview sccode/$(entry.id) → $(name)")
end

function _load_sccode_by_entry!(m::RessacApp, entry::_SccodeEntry)
    src = try
        _sccode_fetch_source(entry.id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(entry.id): $(sprint(showerror, err))")
        return
    end
    base = _sccode_extract_synthdef_name(src)
    base === nothing && (base = "sccode_" * replace(entry.id, "-" => "_"))
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    target = joinpath(dir, "$(base).scd")
    final_name = base
    n = 1
    while isfile(target)
        n += 1
        final_name = "$base-$n"
        target = joinpath(dir, "$(final_name).scd")
    end
    header = "// Imported from sccode.org/$(entry.id) — \"$(entry.title)\"\n//\n"
    write(target, header * src)
    register_synth!(SynthEntry(Symbol(final_name), "user-synths",
                               Dict{String,Any}("description" => "imported from sccode",
                                                "tags" => ["sccode"])))
    m.modal = :none
    _open_synth_tab!(m, final_name)
    _push_app_log!(m, "[INFO] sccode/$(entry.id) → plugins/user-synths/$(final_name).scd")
end

function _sccode_paginate!(m::RessacApp, delta::Int)
    new_page = max(1, m.sccode_page + delta)
    new_page == m.sccode_page && return
    m.sccode_loading = true
    try
        m.sccode_entries = _sccode_fetch_list(new_page; tag = m.sccode_tag)
        m.sccode_page = new_page
        m.sccode_cursor = 1
        _push_app_log!(m, "[INFO] sccode page $new_page — $(length(m.sccode_entries)) entries")
    catch err
        _push_app_log!(m, "[ERROR] sccode page $new_page: $(sprint(showerror, err))")
    finally
        m.sccode_loading = false
    end
end

"""
    _preview_sccode!(m)

Fetch the SC source for the cursor entry (cached after first hit) and
fire it via `/ressac/evalAndPlay`. If the snippet isn't a SynthDef
(no `\\name` decl), we still send it but log a warning — many sccode
snippets are full apps, not SynthDefs, and won't play meaningfully.
"""
function _preview_sccode!(m::RessacApp)
    1 <= m.sccode_cursor <= length(m.sccode_entries) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    entry = m.sccode_entries[m.sccode_cursor]
    src = try
        _sccode_fetch_source(entry.id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(entry.id): $(sprint(showerror, err))")
        return
    end
    name = _sccode_extract_synthdef_name(src)
    if name === nothing
        _push_app_log!(m, "[WARN] sccode $(entry.id): no SynthDef found, sending raw eval anyway")
        # /ressac/evalAndPlay expects (name, src); pass a placeholder name.
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[entry.id, src])))
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[name, src])))
    _push_app_log!(m, "[INFO] preview sccode/$(entry.id) → $(name)")
end

"""
    _load_sccode!(m)

Save the cursor entry into plugins/user-synths/<name>.scd (suffix
-2/-3/... to avoid clobber) and open it in a new tab. If no SynthDef
name can be extracted, falls back to the snippet id.
"""
function _load_sccode!(m::RessacApp)
    1 <= m.sccode_cursor <= length(m.sccode_entries) || return
    entry = m.sccode_entries[m.sccode_cursor]
    src = try
        _sccode_fetch_source(entry.id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(entry.id): $(sprint(showerror, err))")
        return
    end
    base = _sccode_extract_synthdef_name(src)
    base === nothing && (base = "sccode_" * replace(entry.id, "-" => "_"))
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    target = joinpath(dir, "$(base).scd")
    final_name = base
    n = 1
    while isfile(target)
        n += 1
        final_name = "$base-$n"
        target = joinpath(dir, "$(final_name).scd")
    end
    # Prepend a header comment so the user knows where this came from
    # (and can revisit the original page later).
    header = "// Imported from sccode.org/$(entry.id) — \"$(entry.title)\"\n//\n"
    write(target, header * src)
    register_synth!(SynthEntry(Symbol(final_name), "user-synths",
                               Dict{String,Any}("description" => "imported from sccode",
                                                "tags" => ["sccode"])))
    m.modal = :none
    _open_synth_tab!(m, final_name)
    _push_app_log!(m, "[INFO] sccode/$(entry.id) → plugins/user-synths/$(final_name).scd")
end

function _render_sccode_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    aw, ah = area.width, area.height
    box_w = max(60, min(aw - 4, 120))
    box_h = max(10, ah - 4)
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    title = "┌ sccode.org — / search, j/k move, Space play, Enter import, n/p page, q close "
    title = title * "─" ^ max(0, box_w - length(title) - 1) * "┐"
    TK.set_string!(buf, box_x, box_y, first(title, box_w),
                   TK.tstyle(:title, bold=true))
    if m.sccode_loading
        TK.set_string!(buf, box_x + 2, box_y + 1,
                       "  fetching…", TK.tstyle(:warning))
        foot = "└" * "─" ^ (box_w - 2) * "┘"
        TK.set_string!(buf, box_x, box_y + box_h - 1, foot,
                       TK.tstyle(:title, bold=true))
        return
    end
    # Search bar row right under the title.
    sb_prefix = m.sccode_search_mode ? "  /" : "  ⌕ "
    sb_text = sb_prefix * m.sccode_query *
              (m.sccode_search_mode ? "▏" : "")
    sb_style = m.sccode_search_mode ?
        TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, box_x, box_y + 1,
                   "│ " * rpad(first(sb_text, box_w - 4), box_w - 4) * " │",
                   sb_style)
    # Filtered list.
    filtered = _sccode_filtered(m)
    body_h = box_h - 4   # title + search + page-footer + bottom border
    n = length(filtered)
    if n == 0
        msg = isempty(m.sccode_query) ?
            "(no entries — try `n` for next page)" :
            "(no match for \"$(m.sccode_query)\")"
        TK.set_string!(buf, box_x + 2, box_y + 3, msg, TK.tstyle(:text_dim))
    else
        start_i = max(1, m.sccode_cursor - body_h ÷ 2)
        end_i = min(n, start_i + body_h - 1)
        start_i = max(1, end_i - body_h + 1)
        empty!(m.modal_rows)
        for (slot, i) in enumerate(start_i:end_i)
            e = filtered[i]
            is_cur = i == m.sccode_cursor
            marker = is_cur ? "▶ " : "  "
            label = "$(marker)#$(rpad(e.id, 8)) $(e.title)"
            style = is_cur ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text)
            line = "│ " * first(label, box_w - 4) * " │"
            screen_y = box_y + 1 + slot
            TK.set_string!(buf, box_x, screen_y, line, style)
            push!(m.modal_rows, (screen_y, i))
        end
    end
    # Page indicator near the bottom.
    pageinfo = "page $(m.sccode_page) · $(n) shown of $(length(m.sccode_entries))"
    isempty(m.sccode_tag) || (pageinfo *= " · tag=$(m.sccode_tag)")
    pageline = "│ " * rpad(pageinfo, box_w - 4) * " │"
    TK.set_string!(buf, box_x, box_y + box_h - 2, first(pageline, box_w),
                   TK.tstyle(:text_dim))
    foot = "└" * "─" ^ (box_w - 2) * "┘"
    TK.set_string!(buf, box_x, box_y + box_h - 1, foot,
                   TK.tstyle(:title, bold=true))
end

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
    bar_w = 10
    filled = clamp(floor(Int, cycle_phase * bar_w), 0, bar_w)
    bar = "█" ^ filled * "░" ^ (bar_w - filled)

    cps_str = "♪ $(round(sched.cps; digits=2)) cps"
    cycle_str = "◐ $bar"
    ev_str = "✧ $(sched.events_shipped[])"
    synth_str = if _synth_pane_open(m)
        s = "♬ $(_current_synth_tab(m).name)"
        length(m.synth_tabs) > 1 ?
            s * " [$(m.synth_tab_idx)/$(length(m.synth_tabs))]" : s
    else
        ""
    end
    ed = _active_editor(m)
    badge = "  ⟪ $(uppercase(String(ed.mode))) @ $(m.focus) ⟫"

    # Compose left segment with bullet separators.
    parts = String[]
    push!(parts, "▓ ressac")
    push!(parts, cps_str)
    push!(parts, cycle_str)
    push!(parts, ev_str)
    isempty(synth_str) || push!(parts, synth_str)
    if m.recording
        secs = floor(Int, time() - m.recording_start_ts)
        mins, s = divrem(secs, 60)
        push!(parts, "● REC $(lpad(mins, 2, '0')):$(lpad(s, 2, '0'))")
    end
    left = join(parts, "  •  ")

    # Layout: left + right pad + badge. Truncate left if too tight.
    available = area.width - length(badge)
    left_trimmed = first(left, max(available, 0))
    pad = max(0, available - length(left_trimmed))
    full = left_trimmed * " " ^ pad * badge
    TK.set_string!(buf, area.x, area.y,
                   first(full, area.width),
                   TK.tstyle(:title, bold=true))
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
    hint = if !_synth_pane_open(m)
        "e eval • i insert • Esc normal • :synth <name> • :lib library • :theme • :q"
    elseif length(m.synth_tabs) > 1
        "e eval • T test (hold=accel) • Tab swap • gt/gT cycle • :w save • :close • :back"
    else
        "e eval • T test (hold=accel) • Tab swap • :w save • :back close • :q"
    end
    badge = "[$mode_label]"
    TK.set_string!(buf, area.x, area.y, badge,
                   TK.tstyle(:accent, bold=true))
    TK.set_string!(buf, area.x + length(badge) + 1, area.y,
                   first(hint, max(0, area.width - length(badge) - 1)),
                   TK.tstyle(:text_dim))
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
        style = if startswith(line, "[ERROR]")
            TK.tstyle(:error)
        elseif startswith(line, "[WARN]")
            TK.tstyle(:warning)
        elseif startswith(line, "[KEY]")
            TK.tstyle(:accent, dim=true)
        elseif startswith(line, "[INFO]")
            TK.tstyle(:text)
        else
            TK.tstyle(:text_dim)
        end
        TK.set_string!(buf, area.x, area.y + i - 1,
                       first(line, area.width), style)
    end
    # Tiny scroll indicator in the last column when not at the bottom.
    m.log_scroll > 0 && TK.set_string!(buf,
        area.x + area.width - 1, area.y, "↑", TK.tstyle(:warning, bold=true))
end

"""
    _render_synth_library_modal!(m, area, buf)

Centered list of `_SYNTH_LIBRARY` entries. Each row shows the synth
name, its category, and the one-line description. Cursor row inverted
so the user can see what Enter will instantiate.
"""
function _render_synth_library_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    entries = _synthlib_all_entries()
    aw, ah = area.width, area.height
    box_w = max(60, min(aw - 4, 100))
    box_h = max(10, min(ah - 4, length(entries) + 6))
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    suffix_w = max(0, box_w - 56)
    title = "┌ synth library — j/k move, Space preview, Enter open, q close " * "─" ^ suffix_w * "┐"
    TK.set_string!(buf, box_x, box_y, first(title, box_w),
                   TK.tstyle(:title, bold=true))
    empty!(m.modal_rows)
    for (i, entry) in enumerate(entries)
        i + 1 >= box_h - 1 && break
        is_cur = i == m.synthlib_cursor
        marker = is_cur ? "▶ " : "  "
        tag = entry.category == "user" ? "[user]  ★" : "[$(rpad(entry.category, 5))]"
        text = "$marker$(rpad(entry.name, 14)) $tag  $(entry.description)"
        base_style = entry.category == "user" ?
            TK.tstyle(:success) : TK.tstyle(:text)
        style = is_cur ? TK.tstyle(:accent, bold=true) : base_style
        line = "│ " * first(text, box_w - 4) * " │"
        screen_y = box_y + i
        TK.set_string!(buf, box_x, screen_y, line, style)
        push!(m.modal_rows, (screen_y, i))
    end
    foot = "└" * "─" ^ (box_w - 2) * "┘"
    TK.set_string!(buf, box_x, box_y + box_h - 1, foot,
                   TK.tstyle(:title, bold=true))
end

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
    _eval_current_line!(m)

Eval the line at the currently-focused editor's cursor.
"""
function _eval_current_line!(m::RessacApp)
    ce = _active_editor(m)
    txt = TK.text(ce)
    lines = split(txt, '\n'; keepempty=true)
    row = ce.cursor_row
    1 <= row <= length(lines) || return
    line = lines[row]
    isempty(strip(line)) && return
    try
        ex = Meta.parse(line)
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

_app_synth_path(name::AbstractString) =
    joinpath(pwd(), "plugins", "user-synths", String(name) * ".scd")

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
        m.focus = :synth; _refresh_focus_flags!(m)   # ensure the right editor has focused=true
        _push_app_log!(m, "[INFO] switched to tab '$name'")
        return
    end
    path = _app_synth_path(name)
    src = isfile(path) ? read(path, String) : join(_STARTER_SYNTHDEF(name), "\n")
    editor = TK.CodeEditor(;
        text  = src,
        block = TK.Block(title = "synth: $name.scd",
                         border_style = TK.tstyle(:border),
                         title_style  = TK.tstyle(:title)),
        focused = true,
        tick    = m.tick,
        mode    = :normal,
    )
    push!(m.synth_tabs, SynthTab(name, editor))
    m.synth_tab_idx = length(m.synth_tabs)
    m.focus = :synth
    _refresh_focus_flags!(m)
    _push_app_log!(m, "[INFO] opened synth '$name' — T test, :w save, Tab swap, gt cycle, :close drop")
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
    if new_name === nothing
        # Plain :w — overwrite the current tab's backing file. Auto-align
        # the SynthDef name in case the user edited it inconsistently.
        text = _align_synthdef_name(text, old_name)
        TK.set_text!(tab.editor, text)
        write(_app_synth_path(old_name), text)
        register_synth!(SynthEntry(Symbol(old_name), "user-synths", Dict{String,Any}(
            "description" => "live-edited synth", "tags" => ["user"])))
        _push_app_log!(m, "[INFO] saved synth → $(_app_synth_path(old_name))")
    else
        # :w newname — Save-As. Rewrite the SynthDef name to match.
        name = String(new_name)
        new_text = _align_synthdef_name(text, name)
        write(_app_synth_path(name), new_text)
        register_synth!(SynthEntry(Symbol(name), "user-synths", Dict{String,Any}(
            "description" => "live-edited synth", "tags" => ["user"])))
        _push_app_log!(m, "[INFO] saved synth as → $(_app_synth_path(name))")
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
    # Auto-rewrite the SynthDef name to match the tab name. Lets the
    # user duplicate / rename / save-as without remembering to update
    # the `\name` token by hand — the contract is "tab name ↔ SynthDef
    # name", and we enforce it on every fire. Idempotent when they
    # already match.
    src = _align_synthdef_name(src, tab.name)
    addr = raw ? "/ressac/evalAndPlay" : "/ressac/evalAndPlay"
    send_osc(sched.osc, encode(OSCMessage(addr, Any[tab.name, src])))
    _push_app_log!(m, "[INFO] T — test $(tab.name) (synth defaults active)")
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

