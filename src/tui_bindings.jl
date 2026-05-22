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
    elseif code == "Enter"
        _split_line!(m)
    elseif code == "Backspace"
        _backspace!(m)
    elseif code == "Left"
        _move_cursor!(m, -1, 0)
    elseif code == "Right"
        _move_cursor!(m, +1, 0)
    elseif code == "Up"
        _move_cursor!(m, 0, -1)
    elseif code == "Down"
        _move_cursor!(m, 0, +1)
    elseif length(code) == 1
        c = first(code)
        # Restrict insertion to printable ASCII. Multi-byte chars (¹, é,
        # emojis) and control bytes that some terminals fire for exotic
        # keys (AltGr combos, dead keys, etc.) are ignored — they have no
        # use in a live-coding code buffer and cause string-indexing
        # crashes if they sneak in.
        if _is_typable_ascii(c)
            _insert_char!(m, c)
        else
            _push_log!(m, "[WARN] ignored non-ASCII key: $(repr(c))")
        end
    end
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
    elseif code == ":" || code == "/" || code == "?"
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
    elseif code == "Enter"
        _execute_command!(m)
        m.mode = :normal
        m.command_buffer = ""
    elseif code == "Backspace"
        isempty(m.command_buffer) && return
        m.command_buffer = m.command_buffer[1:prevind(m.command_buffer, end)]
    elseif length(code) == 1
        c = first(code)
        _is_typable_ascii(c) && (m.command_buffer *= code)
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
    else
        _push_log!(m, "[ERROR] unknown command: $body")
    end
end

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

Identify the sample name under the cursor (matches `name` or `name:N`),
look it up in the sample registry, and ship a one-shot `/dirt/play`
OSC bundle through the active scheduler's client. Logs `[INFO] preview …`
on success or `[WARN] no sample '…' loaded` on miss.
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
        _push_log!(m, "[WARN] no sample '$word' loaded")
        return
    end
    name = Symbol(mt.captures[1])
    variant = mt.captures[2] === nothing ? 0 : parse(Int, mt.captures[2])

    entry = sample_info(name)
    if entry === nothing
        _push_log!(m, "[WARN] no sample '$(mt.captures[1])' loaded")
        return
    end

    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] preview: no active session")
        return
    end
    args = variant == 0 ?
        Any["s", String(name)] :
        Any["s", String(name), "n", Int32(variant)]
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
    _push_log!(m, "[INFO] preview $(mt.captures[1])$(variant == 0 ? "" : ":$variant")")
end

_is_word_char(c::AbstractChar) = isletter(c) || isdigit(c) || c == '_' || c == ':'
