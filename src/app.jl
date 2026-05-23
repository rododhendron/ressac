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
    # Modal overlay state — `:none`, `:guide`, `:synth_guide`, `:browse`.
    modal::Symbol                = :none
    modal_scroll::Int            = 0
    # Browser modal state (only meaningful when modal === :browse).
    browser_query::String        = ""
    browser_cursor::Int          = 1
    browser_filter::Symbol       = :all   # :all | :instruments | :samples | :synths
    browser_last_preview::Float64 = 0.0
    logs::Vector{String}         = ["[INFO] Ressac live (Tachikoma) — :q to quit, e to eval, :synth <name> to design a sound"]
    quit::Bool                   = false
    tick::Int                    = 0
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
    # Intercept our normal-mode actions BEFORE handle_key! so the
    # CodeEditor doesn't swallow them (it interprets T/K/S/e/m as
    # potential vim commands and consumes the keystroke).
    if is_press && ed.mode === :normal
        if evt.char == 'e'
            _eval_current_line!(m); return
        elseif evt.char == 'T' && _synth_pane_open(m)
            _test_current_synth!(m); return
        elseif evt.char == 'K' && m.focus === :patterns
            _preview_word_under_cursor!(m); return
        elseif evt.char == 'S' && _synth_pane_open(m)
            _scope_cycle_key!(m); return
        elseif evt.char == 'm' && m.focus === :patterns
            _toggle_mute_current_line!(m); return
        end
    end
    # Tab autocomplete in :insert mode (word under cursor → registry /
    # combinator / @dN macro). Intercept BEFORE the editor types a Tab
    # character into the buffer.
    if is_press && evt.key === :tab && ed.mode === :insert
        if _try_autocomplete!(m, ed)
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
    1 <= ed.cursor_row <= length(ed.lines) || return false
    chars = ed.lines[ed.cursor_row]
    col = ed.cursor_col   # 0-based; we want the word ending at col-1
    isempty(chars) && return false
    is_word = c -> isletter(c) || isdigit(c) || c == '_' || c == '@'
    end_col = col
    start_col = end_col
    while start_col > 0 && is_word(chars[start_col])
        start_col -= 1
    end
    start_col == end_col && return false
    partial = String(chars[(start_col + 1):end_col])
    # Build candidate list: static + live registries.
    candidates = copy(_APP_AUTOCOMPLETE_CANDIDATES)
    append!(candidates, String.(keys(_SAMPLE_REGISTRY)))
    append!(candidates, String.(keys(_INSTRUMENT_REGISTRY)))
    append!(candidates, String.(keys(_SYNTH_REGISTRY)))
    unique!(candidates)
    # Fuzzy rank.
    scored = Tuple{Int,Int,String}[]
    for cand in candidates
        score = _fuzzy_score(partial, cand)
        score === nothing && continue
        push!(scored, (score, length(cand), cand))
    end
    isempty(scored) && return false
    sort!(scored, by = t -> (t[1], t[2], t[3]))
    replacement = scored[1][3]
    # Splice into buffer.
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ed.cursor_row
    line = String(lines[row])
    new_line = line[1:start_col] * replacement *
               (end_col >= lastindex(line) ? "" : line[nextind(line, end_col):end])
    lines[row] = new_line
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row
    ed.cursor_col = start_col + length(replacement)
    return true
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
    elseif (mt = match(r"^doc\s+(\w+)$", cmd)) !== nothing
        _doc_command!(m, mt.captures[1])
    elseif cmd == "doc"
        _push_app_log!(m, "[INFO] :doc <name> — try gain/release/cutoff/cps/gate/…")
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
    _render_app_scope(area, buf)

Draw the current scope frame into `area`. Pulls latest data from the
`_APP_SCOPE_DATA` global. amp = bouncing meter; wave = braille
waveform via Canvas; spectrum = vertical bars (1 column per band).
"""
function _render_app_scope(area::TK.Rect, buf::TK.Buffer)
    type = _APP_SCOPE_TYPE[]
    data = _APP_SCOPE_DATA[]
    h, w = area.height, area.width
    h < 2 && return
    # Title row.
    title = "scope: $type   ([cycle via :scope amp/wave/spectrum/off])"
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
        _app_render_wave(data, body_area, buf)
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

function _app_render_wave(data, area::TK.Rect, buf::TK.Buffer)
    # Use Tachikoma's Canvas: 2 dots per col, 4 dots per row — high res.
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # Adaptive peak normalize so quiet signals fill the panel.
    peak = maximum(abs.(data); init=0.001f0)
    scale = peak < 0.05 ? 1.0 : 1.0 / max(Float64(peak), 0.05)
    # Centre line.
    centre_dy = height_dots ÷ 2
    for dx in 0:(width_dots - 1)
        TK.set_point!(canvas, dx, centre_dy)
    end
    # Plot.
    last_dy = centre_dy
    for dx in 0:(width_dots - 1)
        sample_idx = clamp(round(Int, dx / max(1, width_dots - 1) * (n - 1)) + 1, 1, n)
        val = clamp(Float64(data[sample_idx]) * scale, -1.0, 1.0)
        dy = clamp(round(Int, (1 - (val + 1) / 2) * (height_dots - 1)), 0, height_dots - 1)
        TK.set_point!(canvas, dx, dy)
        # Connect with previous sample so the waveform reads as a continuous line.
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
        _render_app_scope(scope_area, buf)
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
    elseif m.modal !== :none
        _render_modal!(m, f.area, buf)
    end
end

function _push_app_log!(m::RessacApp, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > 200 && popfirst!(m.logs)
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
    name = new_name === nothing ? old_name : String(new_name)
    text = TK.text(tab.editor)
    if new_name !== nothing
        text = replace(text, "SynthDef(\\$(old_name)" => "SynthDef(\\$(name)")
        TK.set_text!(tab.editor, text)
        tab.name = name
    end
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    write(_app_synth_path(name), text)
    _push_app_log!(m, "[INFO] saved synth → $(_app_synth_path(name))")
end

"""
    _test_current_synth!(m)

Reload the synth source on the SC side and fire a preview note via
`/ressac/reloadAndPlay`. Server-side `s.sync` ensures the new
SynthDef is registered before the play fires.
"""
function _test_current_synth!(m::RessacApp; raw::Bool = false)
    _synth_pane_open(m) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    tab = _current_synth_tab(m)
    src = TK.text(tab.editor)
    addr = raw ? "/ressac/evalAndPlay" : "/ressac/reloadAndPlay"
    send_osc(sched.osc, encode(OSCMessage(addr, Any[tab.name, src])))
    label = raw ? "raw" : "via SuperDirt"
    _push_app_log!(m, "[INFO] T — test $(tab.name) ($label)")
end

