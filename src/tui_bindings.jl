"""
    _dispatch_key!(m, evt)

Mode-aware keystroke router. `evt` must expose `code::String`,
`modifiers::Vector{String}`, `kind::String`. Only acts on Press events.
"""
function _dispatch_key!(m::LiveModel, evt)
    # Accept Press and Repeat so holding a navigation key auto-repeats at
    # the OS key-repeat rate. Crossterm only emits Repeat when keyboard
    # enhancement is enabled (default on non-Windows via TUI.tui()).
    evt.kind == "Press" || evt.kind == "Repeat" || return
    if m.mode === :insert
        _handle_insert!(m, evt)
    elseif m.mode === :normal
        _handle_normal!(m, evt)
    elseif m.mode === :visual_line
        _handle_visual!(m, evt)
    elseif m.mode === :command
        _handle_command!(m, evt)
    elseif m.mode === :guide
        _handle_guide!(m, evt)
    end
end

# ---------------------------------------------------------------------
# Insert mode
# ---------------------------------------------------------------------
function _handle_insert!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        line = m.buffer[m.cursor_row]
        m.cursor_col = clamp(m.cursor_col, 1, max(1, lastindex(line)))
        _clear_completions!(m)
    elseif code == "Enter"
        _split_line!(m)
        _clear_completions!(m)
    elseif code == "Backspace"
        _backspace!(m)
        _clear_completions!(m)
    elseif code == "Left"
        _move_cursor!(m, -1, 0)
        _clear_completions!(m)
    elseif code == "Right"
        _move_cursor!(m, +1, 0)
        _clear_completions!(m)
    elseif code == "Up"
        _move_cursor!(m, 0, -1)
        _clear_completions!(m)
    elseif code == "Down"
        _move_cursor!(m, 0, +1)
        _clear_completions!(m)
    elseif code == "Tab"
        _handle_insert_tab!(m)
    elseif length(code) == 1
        c = first(code)
        # Restrict insertion to printable ASCII. Multi-byte chars (¹, é,
        # emojis) and control bytes that some terminals fire for exotic
        # keys (AltGr combos, dead keys, etc.) are ignored — they have no
        # use in a live-coding code buffer and cause string-indexing
        # crashes if they sneak in.
        if _is_typable_ascii(c)
            _insert_char!(m, c)
            _clear_completions!(m)
        else
            _push_log!(m, "[WARN] ignored non-ASCII key: $(repr(c))")
        end
    end
end

"""
    _extract_partial_word(line, cursor_col) -> (start_col, end_col, word)

Find the partial identifier under the cursor. Walks backward from
`cursor_col - 1` while the char is a word-char (letters/digits/_/@),
then forward from `cursor_col` while the char is a word-char. Empty
result if no word.
"""
function _extract_partial_word(line::AbstractString, cursor_col::Integer)
    n = lastindex(line)
    n == 0 && return (1, 0, "")
    start_col = cursor_col
    while start_col > 1
        prev = prevind(line, start_col)
        prev >= 1 && _is_word_char_simple(line[prev]) || break
        start_col = prev
    end
    end_col = cursor_col - 1
    j = cursor_col
    while j <= n && _is_word_char_simple(line[j])
        end_col = j
        j = nextind(line, j)
    end
    if end_col < start_col
        return (cursor_col, cursor_col - 1, "")
    end
    return (start_col, end_col, line[start_col:end_col])
end

function _handle_insert_tab!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    if isempty(m.completions)
        start_col, end_col, partial = _extract_partial_word(line, m.cursor_col)
        isempty(partial) && return
        ctx = _completion_context(line, m.cursor_col)
        cands = _fuzzy_rank(partial, _buffer_candidates(ctx))
        isempty(cands) && return
        m.completions = cands
        m.completion_cycle_idx = 1
        m.completion_target_range = (start_col, end_col)
        _replace_range_in_line!(m, start_col, end_col, cands[1])
    else
        m.completion_cycle_idx = (m.completion_cycle_idx % length(m.completions)) + 1
        next = m.completions[m.completion_cycle_idx]
        sc, ec = m.completion_target_range
        _replace_range_in_line!(m, sc, ec, next)
    end
end

function _replace_range_in_line!(m::LiveModel, start_col::Int, end_col::Int, replacement::AbstractString)
    line = m.buffer[m.cursor_row]
    prefix = start_col > 1 ? line[1:prevind(line, start_col)] : ""
    suffix = end_col >= lastindex(line) ? "" : line[nextind(line, end_col):end]
    new_line = prefix * replacement * suffix
    m.buffer[m.cursor_row] = new_line
    new_end = lastindex(prefix) + lastindex(replacement)
    m.cursor_col = new_end + 1
    m.completion_target_range = (start_col, new_end)
end

_is_typable_ascii(c::AbstractChar) =
    ncodeunits(c) == 1 && (isprint(c) || c == ' ')

# ---------------------------------------------------------------------
# Normal mode
# ---------------------------------------------------------------------
function _handle_normal!(m::LiveModel, evt)
    code = evt.code

    # Chord resolution: if we're in :gd, gobble digits / non-digits.
    if m.pending_chord === :gd
        if length(code) == 1 && isdigit(only(code))
            m.chord_digits *= code
            return
        else
            digits = m.chord_digits
            m.pending_chord = :none
            m.chord_digits = ""
            if isempty(digits)
                _push_log!(m, "[ERROR] gd: no slot given")
            else
                _goto_slot!(m, parse(Int, digits))
            end
            if code != "Enter" && code != "Esc"
                _handle_normal!(m, evt)
            end
            return
        end
    end

    if m.pending_chord === :g
        if code == "d"
            m.pending_chord = :gd
            m.chord_digits = ""
        elseif code == "g"
            _buffer_start!(m)
            m.pending_chord = :none
        else
            m.pending_chord = :none
        end
        return
    end

    if m.pending_chord === :d
        if code == "d"
            n = max(m.count_prefix, 1)
            m.count_prefix = 0
            _yank_lines!(m, n)
            for _ in 1:n
                length(m.buffer) == 1 && m.buffer[1] == "" && break
                _delete_line!(m)
            end
        end
        m.pending_chord = :none
        return
    end

    if m.pending_chord === :y
        if code == "y"
            n = max(m.count_prefix, 1)
            m.count_prefix = 0
            _yank_lines!(m, n)
        end
        m.pending_chord = :none
        return
    end

    if code == "i"
        m.mode = :insert
    elseif code == "a"
        m.mode = :insert
        line = m.buffer[m.cursor_row]
        m.cursor_col = min(m.cursor_col + 1, lastindex(line) + 1)
    elseif code == "o"
        insert!(m.buffer, m.cursor_row + 1, "")
        m.cursor_row += 1
        m.cursor_col = 1
        m.mode = :insert
    elseif code == "O"
        insert!(m.buffer, m.cursor_row, "")
        m.cursor_col = 1
        m.mode = :insert
    elseif code == "h" || code == "Left"
        _move_cursor!(m, -1, 0)
    elseif code == "l" || code == "Right"
        _move_cursor!(m, +1, 0)
    elseif code == "j" || code == "Down"
        _move_cursor!(m, 0, +1)
    elseif code == "k" || code == "Up"
        _move_cursor!(m, 0, -1)
    elseif code == "0" && m.count_prefix == 0
        _line_start!(m)
    elseif code == "\$"
        _line_end!(m)
    elseif code == "g"
        if m.pending_chord === :none
            m.pending_chord = :g
        end
    elseif code == "G"
        _buffer_end!(m)
    elseif code == "d"
        m.pending_chord = :d
    elseif code == "y"
        m.pending_chord = :y
    elseif code == "x"
        line = m.buffer[m.cursor_row]
        if m.cursor_col <= lastindex(line)
            m.buffer[m.cursor_row] =
                line[1:prevind(line, m.cursor_col)] *
                (m.cursor_col + 1 > lastindex(line) ? "" : line[nextind(line, m.cursor_col):end])
            new_line = m.buffer[m.cursor_row]
            m.cursor_col = min(m.cursor_col, max(1, lastindex(new_line)))
        end
    elseif code == "p"
        _paste_lines!(m; before=false)
    elseif code == "P"
        _paste_lines!(m; before=true)
    elseif code == "m"
        _toggle_mute!(m)
    elseif code == "K"
        _preview_under_cursor!(m)
    elseif code == "V"
        m.mode = :visual_line
        m.visual_anchor = (m.cursor_row, m.cursor_col)
    elseif code == "e"
        n = m.count_prefix
        m.count_prefix = 0
        if n == 0
            _eval_block!(m; mode=:immediate, n=0)
        else
            _eval_block!(m; mode=:deferred, n=n)
        end
    elseif code == "n"
        _repeat_search!(m; reverse=false)
    elseif code == "N"
        _repeat_search!(m; reverse=true)
    elseif code == "?"
        # Hybrid help overlay (SP6). Backward search is still reachable
        # by entering :-mode and starting the buffer with "?", but the
        # one-key shortcut is now reserved for the help popup.
        m.show_help = !m.show_help
    elseif code == ":" || code == "/"
        m.mode = :command
        m.command_prefix = first(code)
        m.command_buffer = ""
    elseif length(code) == 1 && isdigit(only(code))
        m.count_prefix = m.count_prefix * 10 + parse(Int, code)
    elseif code == "c" && _has_modifier(evt, "Ctrl") || code == "c" && _has_modifier(evt, "Control")
        m.quit = true
    elseif code == "Esc"
        m.count_prefix = 0
        m.pending_chord = :none
        m.chord_digits = ""
    end
end

# ---------------------------------------------------------------------
# Visual line mode
# ---------------------------------------------------------------------
function _handle_visual!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "j" || code == "Down"
        _move_cursor!(m, 0, +1)
    elseif code == "k" || code == "Up"
        _move_cursor!(m, 0, -1)
    elseif code == "G"
        _buffer_end!(m)
    elseif code == "g"
        _buffer_start!(m)
    elseif code == "y"
        _yank_selection!(m)
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "d"
        _yank_selection!(m)
        _delete_selection!(m)
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "m"
        rs, re = _visual_range(m)
        for row in rs:re
            m.cursor_row = row
            _toggle_mute!(m)
        end
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "e"
        rs, re = _visual_range(m)
        n = m.count_prefix
        m.count_prefix = 0
        m.cursor_row = rs
        text = join(m.buffer[rs:re], "\n")
        try
            ex = Meta.parse(text)
            slot = _block_slot(text)
            prev = _EVAL_MODE[]
            _EVAL_MODE[] = n == 0 ? (:immediate, 0) : (:deferred, n)
            try
                Core.eval(Main, ex)
            finally
                _EVAL_MODE[] = prev
            end
            slot === nothing || (m.last_eval_block[slot] = (rs, re))
            _push_log!(m, "[INFO] eval block rows $rs:$re")
        catch err
            _push_log!(m, "[ERROR] $(sprint(showerror, err))")
        end
        m.mode = :normal
        m.visual_anchor = nothing
    end
end

_visual_range(m::LiveModel) =
    let (ar, _) = m.visual_anchor
        a, b = minmax(ar, m.cursor_row)
        (a, b)
    end

function _yank_selection!(m::LiveModel)
    rs, re = _visual_range(m)
    m.yank = m.buffer[rs:re]
end

function _delete_selection!(m::LiveModel)
    rs, re = _visual_range(m)
    deleteat!(m.buffer, rs:re)
    isempty(m.buffer) && push!(m.buffer, "")
    m.cursor_row = clamp(rs, 1, length(m.buffer))
    m.cursor_col = 1
end

function _yank_lines!(m::LiveModel, n::Int)
    n = clamp(n, 1, length(m.buffer) - m.cursor_row + 1)
    m.yank = m.buffer[m.cursor_row:(m.cursor_row + n - 1)]
end

function _paste_lines!(m::LiveModel; before::Bool=false)
    isempty(m.yank) && return
    insert_at = before ? m.cursor_row : m.cursor_row + 1
    for (i, line) in enumerate(m.yank)
        insert!(m.buffer, insert_at + i - 1, line)
    end
    m.cursor_row = insert_at
    m.cursor_col = 1
end

# ---------------------------------------------------------------------
# Command mode (:, /, ?)
# ---------------------------------------------------------------------
function _handle_command!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        m.command_buffer = ""
        _clear_completions!(m)
    elseif code == "Enter"
        _execute_command!(m)
        # _execute_command! may have shifted m.mode (e.g. :guide); only
        # fall back to :normal if the command didn't take us elsewhere.
        if m.mode === :command
            m.mode = :normal
        end
        m.command_buffer = ""
        _clear_completions!(m)
    elseif code == "Backspace"
        isempty(m.command_buffer) && return
        m.command_buffer = m.command_buffer[1:prevind(m.command_buffer, end)]
        _clear_completions!(m)
    elseif code == "Tab"
        _handle_command_tab!(m)
    elseif length(code) == 1
        c = first(code)
        if _is_typable_ascii(c)
            m.command_buffer *= code
            _clear_completions!(m)
        end
    end
end

function _clear_completions!(m::LiveModel)
    empty!(m.completions)
    m.completion_cycle_idx = 0
    m.completion_target_range = nothing
end

function _handle_command_tab!(m::LiveModel)
    if isempty(m.completions)
        candidates = _compute_completions(m)
        isempty(candidates) && return
        m.completions = candidates
        m.completion_cycle_idx = 1
        if occursin(' ', m.command_buffer)
            verb, _ = split(m.command_buffer, ' '; limit=2)
            m.command_buffer = String(verb) * " " * candidates[1]
        else
            m.command_buffer = candidates[1]
        end
    else
        m.completion_cycle_idx = (m.completion_cycle_idx % length(m.completions)) + 1
        next = m.completions[m.completion_cycle_idx]
        if occursin(' ', m.command_buffer)
            verb, _ = split(m.command_buffer, ' '; limit=2)
            m.command_buffer = String(verb) * " " * next
        else
            m.command_buffer = next
        end
    end
end

function _execute_command!(m::LiveModel)
    prefix = m.command_prefix
    body = m.command_buffer
    if prefix == ':'
        _execute_ex_command!(m, body)
    elseif prefix == '/'
        try
            rx = Regex(body)
            _run_search!(m, rx; dir=:forward)
        catch err
            _push_log!(m, "[ERROR] bad regex: $(sprint(showerror, err))")
        end
    elseif prefix == '?'
        try
            rx = Regex(body)
            _run_search!(m, rx; dir=:backward)
        catch err
            _push_log!(m, "[ERROR] bad regex: $(sprint(showerror, err))")
        end
    end
end

function _execute_ex_command!(m::LiveModel, body::AbstractString)
    body = strip(body)
    if body == "q" || body == "quit"
        m.quit = true
    elseif startswith(body, "cps ")
        try
            x = parse(Float64, strip(body[5:end]))
            set_cps!(m.scheduler, x)
            _push_log!(m, "[INFO] cps = $x")
        catch err
            _push_log!(m, "[ERROR] cps: $(sprint(showerror, err))")
        end
    elseif (mt = match(r"^goto\s+d(\d+)$", body)) !== nothing
        _goto_slot!(m, parse(Int, mt.captures[1]))
    elseif body == "samples" || startswith(body, "samples ")
        rest = strip(body == "samples" ? "" : body[9:end])
        _execute_samples_command!(m, rest)
    elseif body == "instruments" || startswith(body, "instruments ")
        rest = strip(body == "instruments" ? "" : body[13:end])
        _execute_instruments_command!(m, rest)
    elseif body == "synths" || startswith(body, "synths ")
        rest = strip(body == "synths" ? "" : body[8:end])
        _execute_synths_command!(m, rest)
    elseif body == "guide" || body == "help" || body == "?"
        m.mode = :guide
        m.guide_scroll = 0
        m.pending_chord = :none
    else
        _push_log!(m, "[ERROR] unknown command: $body")
    end
end

"""
    _GUIDE_LINES

In-app cheatsheet shown by `:guide` (alias `:help`, `:?`). Kept as a flat
const vector so the lines stream into the log pane in order — no formatting
beyond what the log widget already does.
"""
const _GUIDE_LINES = String[
    "── Ressac guide ──",
    "Modes:",
    "  i / a / o / O — enter insert mode",
    "  Esc           — back to normal",
    "  V             — visual-line selection",
    "  :  /          — command mode / forward search (? = help overlay)",
    "Normal-mode actions:",
    "  hjkl / arrows — move cursor",
    "  0 \$          — line start / end",
    "  gg / G        — buffer start / end",
    "  gdN           — jump to slot dN",
    "  dd / yy / p / P — delete / yank / paste",
    "  x             — delete char under cursor",
    "  m             — toggle mute on slot under cursor",
    "  K             — preview instrument/sample/synth under cursor",
    "  e             — eval block under cursor (prefix N → defer to slot dN)",
    "Effect chain (pipe):",
    "  gain / speed / lpf / hpf / pan / n / room / delay / shape / set",
    "  gain × | lpf min | hpf max | speed × | rest overwrite",
    "  preset values drop entirely on any pipe key — gain(1.0) is not a no-op",
    "  n / N         — repeat last search forward / backward",
    "Commands (`:` prefix):",
    "  :q                    — quit",
    "  :cps <x>              — set tempo",
    "  :goto d<N>            — jump cursor to first `@dN` block",
    "  :samples [arg]        — list / glob / detail sample banks",
    "  :instruments [arg]    — list / glob / detail instrument presets",
    "  :synths [arg]         — list / glob / detail synths",
    "  :guide                — show this guide",
    "Plugin manifest sections:",
    "  [samples]    roots / bank / metadata",
    "  [instruments.<n>]  declare presets — s required, rest is OSC or metadata",
    "  [synthdefs]  files = [\"*.scd\"]",
    "  [synths.<n>]       metadata for SynthDefs (tags, description)",
    "  [julia]      files = [\"*.jl\"] — runs at plugin load",
]

"""
    _execute_samples_command!(m, arg)

Handle the `:samples [arg]` ex-command:
- empty `arg`            → list all registered sample banks, grouped by plugin
- `arg` containing `*`/`?` (glob) → list banks whose name matches the glob
- otherwise              → show full metadata for the bank named `arg`
"""
function _execute_samples_command!(m::LiveModel, arg::AbstractString)
    if isempty(arg)
        _list_samples_to_log!(m, list_samples(r""))
        return
    end
    if occursin('*', arg) || occursin('?', arg)
        rx = Regex("^" * replace(replace(arg, "*" => ".*"), "?" => ".") * "\$")
        _list_samples_to_log!(m, list_samples(rx))
        return
    end
    entry = sample_info(Symbol(arg))
    if entry === nothing
        _push_log!(m, "[WARN] no sample '$arg' loaded")
        return
    end
    _push_log!(m, "[$(entry.plugin)] $(entry.name): $(length(entry.variants)) variant(s)")
    _push_log!(m, "  path: $(entry.bank_path)")
    for (k, v) in entry.metadata
        _push_log!(m, "  $k: $v")
    end
end

function _list_samples_to_log!(m::LiveModel, entries)
    if isempty(entries)
        _push_log!(m, "(no samples loaded)")
        return
    end
    current_plugin = ""
    for e in entries
        if e.plugin != current_plugin
            _push_log!(m, "── $(e.plugin) ──")
            current_plugin = e.plugin
        end
        tags = get(e.metadata, "tags", String[])
        tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
        bpm = get(e.metadata, "bpm", nothing)
        bpm_str = bpm === nothing ? "" : "  $(bpm) BPM"
        _push_log!(m, "  $(e.name)  $(length(e.variants))v$tag_str$bpm_str")
    end
end

"""
    _execute_instruments_command!(m, arg)

`:instruments [arg]` — same shape as `:samples`. Empty `arg` lists every
registered instrument; glob (`*`/`?`) filters by name; bare name shows
the full preset (params in declared order + metadata).
"""
function _execute_instruments_command!(m::LiveModel, arg::AbstractString)
    if isempty(arg)
        _list_instruments_to_log!(m, list_instruments(r""))
        return
    end
    if occursin('*', arg) || occursin('?', arg)
        rx = Regex("^" * replace(replace(arg, "*" => ".*"), "?" => ".") * "\$")
        _list_instruments_to_log!(m, list_instruments(rx))
        return
    end
    entry = instrument_info(Symbol(arg))
    if entry === nothing
        _push_log!(m, "[WARN] no instrument '$arg' loaded")
        return
    end
    _push_log!(m, "[$(entry.plugin)] $(entry.name):")
    for (k, v) in entry.params
        _push_log!(m, "  $k = $v")
    end
    for (k, v) in entry.metadata
        _push_log!(m, "  ($k) $v")
    end
end

function _list_instruments_to_log!(m::LiveModel, entries)
    if isempty(entries)
        _push_log!(m, "(no instruments loaded)")
        return
    end
    current_plugin = ""
    for e in entries
        if e.plugin != current_plugin
            _push_log!(m, "── $(e.plugin) ──")
            current_plugin = e.plugin
        end
        # Show `s` target alongside name for at-a-glance dispatch info.
        s_target = ""
        for (k, v) in e.params
            if k == "s"
                s_target = " → $v"
                break
            end
        end
        tags = get(e.metadata, "tags", String[])
        tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
        _push_log!(m, "  $(e.name)$s_target$tag_str")
    end
end

"""
    _execute_synths_command!(m, arg)

`:synths [arg]` — same shape as `:samples`/`:instruments`. Synth entries
carry only metadata (the actual SynthDef lives in the audio backend).
"""
function _execute_synths_command!(m::LiveModel, arg::AbstractString)
    if isempty(arg)
        _list_synths_to_log!(m, list_synths(r""))
        return
    end
    if occursin('*', arg) || occursin('?', arg)
        rx = Regex("^" * replace(replace(arg, "*" => ".*"), "?" => ".") * "\$")
        _list_synths_to_log!(m, list_synths(rx))
        return
    end
    entry = synth_info(Symbol(arg))
    if entry === nothing
        _push_log!(m, "[WARN] no synth '$arg' loaded")
        return
    end
    _push_log!(m, "[$(entry.plugin)] $(entry.name):")
    for (k, v) in entry.metadata
        _push_log!(m, "  $k: $v")
    end
end

function _list_synths_to_log!(m::LiveModel, entries)
    if isempty(entries)
        _push_log!(m, "(no synths loaded)")
        return
    end
    current_plugin = ""
    for e in entries
        if e.plugin != current_plugin
            _push_log!(m, "── $(e.plugin) ──")
            current_plugin = e.plugin
        end
        tags = get(e.metadata, "tags", String[])
        tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
        _push_log!(m, "  $(e.name)$tag_str")
    end
end

"""
    _has_modifier(evt, name)

True if `name` (case-insensitive, accepts "Ctrl"/"Control" variants) appears in `evt.modifiers`.
"""
function _has_modifier(evt, name::AbstractString)
    target = lowercase(name)
    for m in evt.modifiers
        s = lowercase(String(m))
        s == target && return true
        # Allow "ctrl"/"control" to alias each other.
        if target in ("ctrl", "control") && s in ("ctrl", "control")
            return true
        end
    end
    return false
end

const _WORD_RX = r"([A-Za-z_][\w]*)(?::(\d+))?"

"""
    _preview_under_cursor!(m::LiveModel)

Identify the name under the cursor (matches `name` or `name:N`) and ship
a one-shot `/dirt/play` OSC bundle for it. Resolution order:

1. **Instrument** — expand the full param bundle in declared order
   (`event_to_osc`-equivalent path). If the cursor word has a `:N` suffix
   it overrides any `n` the preset declared.
2. **Sample** — ship `("s", name)` or `("s", name, "n", N)`.
3. **Synth** — ship `("s", name)`; SuperDirt routes to the corresponding
   SynthDef on the audio side.
4. None of the above → log `[WARN] no instrument/sample/synth '…' loaded`.

`[INFO] preview <kind> <name>` is logged on success.
"""
function _preview_under_cursor!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    isempty(line) && return
    col = clamp(m.cursor_col, 1, lastindex(line) + 1)
    start = col
    while start > 1 && _is_word_char(line[prevind(line, start)])
        start = prevind(line, start)
    end
    stop = col
    while stop <= lastindex(line) && _is_word_char(line[stop])
        stop = nextind(line, stop)
    end
    stop = prevind(line, stop)
    word = start > stop ? "" : line[start:stop]
    isempty(word) && return

    mt = match(_WORD_RX, word)
    if mt === nothing
        _push_log!(m, "[WARN] no instrument/sample/synth '$word' loaded")
        return
    end
    name = Symbol(mt.captures[1])
    variant = mt.captures[2] === nothing ? 0 : parse(Int, mt.captures[2])

    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] preview: no active session")
        return
    end

    if (instr = instrument_info(name)) !== nothing
        args = Any[]
        has_n = false
        for (k, v) in instr.params
            if k == "n"
                has_n = true
                # User-supplied :N overrides preset n.
                if variant != 0
                    push!(args, "n"); push!(args, Int32(variant))
                    continue
                end
            end
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k); push!(args, converted)
        end
        if variant != 0 && !has_n
            push!(args, "n"); push!(args, Int32(variant))
        end
        send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
        _push_log!(m, "[INFO] preview instrument $(mt.captures[1])$(variant == 0 ? "" : ":$variant")")
        return
    end

    if (entry = sample_info(name)) !== nothing
        args = variant == 0 ?
            Any["s", String(name)] :
            Any["s", String(name), "n", Int32(variant)]
        send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
        _push_log!(m, "[INFO] preview sample $(mt.captures[1])$(variant == 0 ? "" : ":$variant")")
        return
    end

    if synth_info(name) !== nothing
        send_osc(sched.osc, encode(OSCMessage("/dirt/play", Any["s", String(name)])))
        _push_log!(m, "[INFO] preview synth $(mt.captures[1])")
        return
    end

    _push_log!(m, "[WARN] no instrument/sample/synth '$(mt.captures[1])' loaded")
end

_is_word_char(c::AbstractChar) = isletter(c) || isdigit(c) || c == '_' || c == ':'

# ---------------------------------------------------------------------
# Guide mode
# ---------------------------------------------------------------------

"""
    _handle_guide!(m, evt)

Keystrokes for the modal :guide overlay. j/k scroll, gg/G jump,
Ctrl-d/u half-page, q/Esc closes. / jumps into :command mode with
the `guide_search_active` flag set so the search routes back here.
"""
function _handle_guide!(m::LiveModel, evt)
    code = evt.code
    if code == "q" || code == "Esc"
        m.mode = :normal
        m.guide_scroll = 0
        m.pending_chord = :none
    elseif code == "j" || code == "Down"
        m.guide_scroll = min(m.guide_scroll + 1, max(0, length(_GUIDE_LINES) - 1))
    elseif code == "k" || code == "Up"
        m.guide_scroll = max(0, m.guide_scroll - 1)
    elseif code == "g"
        if m.pending_chord === :g
            m.guide_scroll = 0
            m.pending_chord = :none
        else
            m.pending_chord = :g
        end
    elseif code == "G"
        m.guide_scroll = max(0, length(_GUIDE_LINES) - 1)
        m.pending_chord = :none
    elseif code == "d" && _has_modifier(evt, "Ctrl")
        m.guide_scroll = min(m.guide_scroll + 10, max(0, length(_GUIDE_LINES) - 1))
    elseif code == "u" && _has_modifier(evt, "Ctrl")
        m.guide_scroll = max(0, m.guide_scroll - 10)
    elseif code == "/"
        m.mode = :command
        m.command_prefix = '/'
        m.command_buffer = ""
        m.guide_search_active = true
    else
        m.pending_chord = :none
    end
end
