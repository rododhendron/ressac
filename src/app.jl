# New Tachikoma-based TUI for Ressac. Lives alongside the existing
# TerminalUserInterfaces.jl-based TUI during the migration. Entry point
# is `live2()` (parallel to `live()`); once feature parity is reached
# `live()` will switch over and the old `tui_*.jl` files get removed.
#
# Architecture: Elm (Model/update!/view). The Ressac scheduler + audio
# layer is unchanged — only the editor + viz layer is being replaced.

using Tachikoma
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
    if m.modal !== :none && evt.action === TK.key_press
        _handle_modal_key!(m, evt)
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
    # T held: fire repeatedly with accelerating interval. The initial
    # press goes through the normal-mode block below; key_repeat events
    # are handled here so they bypass the press-only gate. Each fire
    # multiplies the interval by config.t_hold_accel (clamped to
    # t_hold_min_ms), so a held T ramps from ~4 fires/sec up to ~17.
    if ed.mode === :normal && evt.action === TK.key_repeat &&
       evt.char == 'T' && _synth_pane_open(m)
        _fire_t_with_accel!(m; held=true)
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
        elseif evt.char == 'T' && _synth_pane_open(m)
            _fire_t_with_accel!(m)
            return
        elseif evt.char == 'K' && m.focus === :patterns
            _preview_word_under_cursor!(m); return
        elseif evt.char == 'S' && _synth_pane_open(m)
            _scope_cycle_key!(m); return
        elseif evt.char == 'm' && m.focus === :patterns
            _toggle_mute_current_line!(m); return
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
    "theme", "reload-config", "reload-cfg",
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
    order = (:off, :amp, :wave, :spectrum)
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
        _save_current_synth!(m)
    elseif (mt = match(r"^w\s+(\w+)$", cmd)) !== nothing
        _save_current_synth!(m; new_name = mt.captures[1])
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

function _handle_synthlib_key!(m::RessacApp, evt::TK.KeyEvent)
    n = length(_SYNTH_LIBRARY)
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
    1 <= m.synthlib_cursor <= length(_SYNTH_LIBRARY) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    entry = _SYNTH_LIBRARY[m.synthlib_cursor]
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
    1 <= m.synthlib_cursor <= length(_SYNTH_LIBRARY) || return
    entry = _SYNTH_LIBRARY[m.synthlib_cursor]
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
    text = "📖 $word — $doc"
    TK.set_string!(buf, area.x, area.y,
                   first(text, area.width),
                   TK.tstyle(:success))
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
        "scope: $type   (S cycles : amp → wave → spectrum → off)"
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
    bands = min(n, width_dots)
    for band_idx in 1:bands
        val = clamp(Float64(data[band_idx]), 0.0, 1.0)
        bar_dy = clamp(round(Int, val * (height_dots - 1)), 0, height_dots - 1)
        dx = (band_idx - 1) * (width_dots ÷ max(1, bands))
        for h in 0:bar_dy
            TK.set_point!(canvas, dx, height_dots - 1 - h)
        end
    end
    TK.render(canvas, area, buf)
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

    # Status bar
    sched = m.scheduler
    status = "ressac | $(round(sched.cps; digits=3)) cps | ev:$(sched.events_shipped[])"
    if _synth_pane_open(m)
        status *= " | synth: $(_current_synth_tab(m).name).scd"
        if length(m.synth_tabs) > 1
            status *= " [tab $(m.synth_tab_idx)/$(length(m.synth_tabs))]"
        end
    end
    TK.set_string!(buf, status_area.x, status_area.y,
                   rpad(status, status_area.width), TK.tstyle(:title, bold=true))

    # Editor body — split horizontally when at least one synth tab open.
    if !_synth_pane_open(m)
        TK.render(m.editor, body_area, buf)
    else
        cols = TK.split_layout(TK.Layout(TK.Horizontal, [TK.Fill(), TK.Fill()]), body_area)
        if length(cols) >= 2
            TK.render(m.editor, cols[1], buf)
            # Right pane: optional TabBar on top (when >1 tabs) + editor below.
            if length(m.synth_tabs) > 1
                synth_rows = TK.split_layout(
                    TK.Layout(TK.Vertical, [TK.Fixed(1), TK.Fill()]), cols[2])
                if length(synth_rows) >= 2
                    bar = TK.TabBar([tab.name for tab in m.synth_tabs];
                                    active  = m.synth_tab_idx,
                                    focused = (m.focus === :synth))
                    TK.render(bar, synth_rows[1], buf)
                    TK.render(_current_synth_tab(m).editor, synth_rows[2], buf)
                end
            else
                TK.render(_current_synth_tab(m).editor, cols[2], buf)
            end
        end
    end

    # Scope panel (if any)
    if scope_area !== nothing
        _render_app_scope(m, scope_area, buf)
    end

    # Live doc row — word under cursor → doc string
    _render_livedoc_row(m, livedoc_area, buf)

    # Footer (mode + hint)
    ed = _active_editor(m)
    mode_label = uppercase(String(ed.mode))
    footer = if !_synth_pane_open(m)
        " [$mode_label]  e=eval  i=insert  Esc=normal  :synth <name>  :q=quit"
    elseif length(m.synth_tabs) > 1
        " [$mode_label @ $(m.focus)]  e=eval  T=test  Tab=swap  gt/gT=cycle tab  :w save  :close drop  :back exit"
    else
        " [$mode_label @ $(m.focus)]  e=eval  T=test  Tab=swap  :w save  :back close  :q"
    end
    TK.set_string!(buf, footer_area.x, footer_area.y,
                   rpad(footer, footer_area.width), TK.tstyle(:accent))

    # Logs (last N)
    tail = m.logs[max(1, end - logs_area.height + 1):end]
    for (i, line) in enumerate(tail)
        i > logs_area.height && break
        TK.set_string!(buf,
                       logs_area.x,
                       logs_area.y + i - 1,
                       first(line, logs_area.width),
                       TK.tstyle(:text_dim))
    end

    # Modal overlay (after everything else so it sits on top).
    if m.modal === :browse
        _render_browser_modal!(m, f.area, buf)
    elseif m.modal === :synth_library
        _render_synth_library_modal!(m, f.area, buf)
    elseif m.modal !== :none
        _render_modal!(m, f.area, buf)
    end
end

"""
    _render_synth_library_modal!(m, area, buf)

Centered list of `_SYNTH_LIBRARY` entries. Each row shows the synth
name, its category, and the one-line description. Cursor row inverted
so the user can see what Enter will instantiate.
"""
function _render_synth_library_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    aw, ah = area.width, area.height
    box_w = max(60, min(aw - 4, 100))
    box_h = max(10, min(ah - 4, length(_SYNTH_LIBRARY) + 6))
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    # Title.
    suffix_w = max(0, box_w - 56)
    title = "┌ synth library — j/k move, Space preview, Enter open, q close " * "─" ^ suffix_w * "┐"
    TK.set_string!(buf, box_x, box_y, first(title, box_w),
                   TK.tstyle(:title, bold=true))
    # Body rows.
    for (i, entry) in enumerate(_SYNTH_LIBRARY)
        i + 1 >= box_h - 1 && break
        is_cur = i == m.synthlib_cursor
        marker = is_cur ? "▶ " : "  "
        text = "$marker$(rpad(entry.name, 12)) [$(rpad(entry.category, 5))]  $(entry.description)"
        style = is_cur ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text)
        line = "│ " * first(text, box_w - 4) * " │"
        TK.set_string!(buf, box_x, box_y + i, line, style)
    end
    # Footer.
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
        # Plain :w — overwrite the current tab's backing file.
        write(_app_synth_path(old_name), text)
        register_synth!(SynthEntry(Symbol(old_name), "user-synths", Dict{String,Any}(
            "description" => "live-edited synth", "tags" => ["user"])))
        _push_app_log!(m, "[INFO] saved synth → $(_app_synth_path(old_name))")
    else
        # :w newname — Save-As semantics. Write a NEW file under the
        # given name with the SynthDef declaration rewritten to match,
        # register it, and open it in a fresh tab so the user lands on
        # the new file with the old one still available for revisits.
        name = String(new_name)
        new_text = replace(text, "SynthDef(\\$(old_name)" => "SynthDef(\\$(name)")
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
    # Default T uses /ressac/evalAndPlay: SC interprets + s.syncs + fires
    # `Synth(name, [\out, 0])` directly. The SynthDef's own param defaults
    # (freq, gain, sustain, release, ...) are heard exactly as written —
    # no SuperDirt override of n→freq or amp gain. Matches the model the
    # user signed off on. :test-raw used to be the explicit form; both
    # now go through the same code path because :test-raw was redundant.
    addr = raw ? "/ressac/evalAndPlay" : "/ressac/evalAndPlay"
    send_osc(sched.osc, encode(OSCMessage(addr, Any[tab.name, src])))
    _push_app_log!(m, "[INFO] T — test $(tab.name) (synth defaults active)")
end

