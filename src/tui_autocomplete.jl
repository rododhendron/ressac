# Autocomplete — three flavours of completion in one place:
#
#   • Tab in :insert     — _try_autocomplete!: cycles through
#                          `_APP_AUTOCOMPLETE_CANDIDATES` matching the
#                          partial word at cursor (combinators, samples,
#                          synths, instruments). Maintains
#                          `m.completion_*` state across consecutive Tab
#                          presses.
#   • Ghost suggestion   — _compute_ghost! decides what would best fit
#                          at the cursor right now and stashes it in
#                          `m.ghost`. _render_ghost! paints it dim. Tab
#                          accepts via _accept_ghost!. Usage is logged to
#                          ~/.config/ressac/usage.toml so heavy-used
#                          candidates float to the top over time.
#   • Tab in :command    — _try_ex_autocomplete!: completes either the
#                          verb itself (`:syn<Tab>` → `:synth`) or its
#                          argument (`:doc gai<Tab>` → `:doc gain`),
#                          driven by _EX_COMMAND_ARG_KIND.
#
# Extracted from tui_app.jl. Depends on _fuzzy_score (tui_hints.jl),
# RessacApp, the three registries (_SAMPLE/_INSTRUMENT/_SYNTH_REGISTRY),
# and a handful of TK methods — all in scope by the time this file
# is included.

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
    _start_completion_session!(m, candidates, splice; label) -> Bool

Open a Tab-cycle session. Stashes `candidates` + `splice` on the
model, sets idx=1, and immediately invokes `splice(1)` so the
first candidate is written into the active buffer. Returns true
iff candidates is non-empty (consumes Tab).

`splice` is `(i::Int) -> Nothing` — a closure that knows where to
write `candidates[i]`. The closure captures whatever state it
needs (cursor row, range, command-buffer ref, …) so the model
holds no buffer-specific completion fields.

`label` (e.g. "insert", "ex:verb", "ex:starter") prefixes the
picker title so the user knows which surface is being completed.
"""
function _start_completion_session!(m::RessacApp, candidates::Vector{String},
                                    splice; label::AbstractString = "")
    isempty(candidates) && return false
    m.completion_candidates = candidates
    m.completion_idx = 1
    m.completion_splice = splice
    m.completion_label = String(label)
    splice(1)
    return true
end

"""
    _advance_completion_session!(m) -> Bool

Move to the next candidate in the active session (wraps). Calls
the stored splice with the new index. Returns true if a session
was active (Tab consumed), false otherwise.
"""
function _advance_completion_session!(m::RessacApp)
    _completion_picker_active(m) || return false
    m.completion_splice === nothing && return false
    m.completion_idx = m.completion_idx % length(m.completion_candidates) + 1
    m.completion_splice(m.completion_idx)
    return true
end

"""
    _try_autocomplete!(m, ed) -> Bool

Tab in `:insert` mode. Looks at the word under the cursor, fuzzy-
ranks candidates from `_APP_AUTOCOMPLETE_CANDIDATES` + every
registered sample / instrument / synth name, opens a cycle session
that splices the chosen string back into the editor row. Returns
true iff Tab was consumed.
"""
function _try_autocomplete!(m::RessacApp, ed::TK.CodeEditor)
    # Active cycle from the same editor row → advance.
    if _completion_picker_active(m) && m.completion_label == "insert"
        return _advance_completion_session!(m)
    end
    _reset_completion!(m)
    # Locate the word boundary under the cursor.
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
    # Fuzzy-rank against the global candidate pool, top 12.
    candidates = copy(_APP_AUTOCOMPLETE_CANDIDATES)
    append!(candidates, String.(keys(_SAMPLE_REGISTRY)))
    append!(candidates, String.(keys(_INSTRUMENT_REGISTRY)))
    append!(candidates, String.(keys(_SYNTH_REGISTRY)))
    unique!(candidates)
    ranked = _fuzzy_rank(partial, candidates)
    isempty(ranked) && return false
    top = first(ranked, 12)
    row = ed.cursor_row
    splice = _make_editor_splicer(m, ed, row, start_col)
    return _start_completion_session!(m, top, splice; label = "insert")
end

"""
    _make_editor_splicer(m, ed, row, start_col) -> Function

Return `(i::Int) -> Nothing` that replaces the word starting at
`(row, start_col)` in `ed`'s buffer with `m.completion_candidates[i]`,
moves the cursor right after the replacement, and keeps the word-
boundary tracking correct across consecutive Tabs (each new
replacement may have a different length).
"""
function _make_editor_splicer(m::RessacApp, ed::TK.CodeEditor,
                              row::Int, start_col::Int)
    return function (i::Int)
        i in eachindex(m.completion_candidates) || return
        replacement = m.completion_candidates[i]
        txt = TK.text(ed)
        lines = collect(split(txt, '\n'; keepempty=true))
        1 <= row <= length(lines) || return
        line = String(lines[row])
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
        return
    end
end

"""
    _completion_picker_active(m) -> Bool

True while a Tab cycle is in progress (cleared on any non-Tab key
via `_reset_completion!`). When true, the LOG pane is replaced
with a candidate picker that shows the full list and highlights
the current selection.
"""
_completion_picker_active(m::RessacApp) =
    m.completion_idx > 0 && !isempty(m.completion_candidates)

"""
    _render_completion_picker!(m, area, buf)

Drop-in replacement for `_render_logs` while a Tab cycle is active.
One candidate per row, the current selection highlighted with the
accent style + a `▶ ` marker. Auto-scrolls so the selected row
stays visible when the candidate list is taller than the pane.
"""
function _render_completion_picker!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    n = length(m.completion_candidates)
    n == 0 && return
    body_h = area.height
    body_h <= 0 && return
    # Keep the selected row in view (reuses the modal scroll helper).
    scroll = _scroll_to_show(m.completion_idx, n, body_h, 0)
    first_idx = scroll + 1
    last_idx  = min(n, scroll + body_h)
    for (slot, i) in enumerate(first_idx:last_idx)
        slot > body_h && break
        cand = m.completion_candidates[i]
        is_cur = i == m.completion_idx
        marker = is_cur ? "▶ " : "  "
        style  = is_cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
        y = area.y + slot - 1
        row = marker * cand
        TK.set_string!(buf, area.x, y,
                       first(rpad(row, area.width), area.width), style)
    end
end

"""
    _reset_completion!(m)

Clear the Tab-cycle state. Called from update! after handling any key
event in :insert / :command mode that is not Tab — so the next Tab
restarts a fresh autocomplete session.
"""
function _reset_completion!(m::RessacApp)
    m.completion_idx = 0
    empty!(m.completion_candidates)
    m.completion_splice = nothing
    m.completion_label  = ""
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
# Ex-command verbs (`:foo`). Kept here, not derived from the dispatch
# table, because the dispatch lives inside _handle_ex_command! as a chain
# Verbs are derived from the dispatch tables in app.jl via
# `_all_ex_verbs()` (single source of truth). Adding a new
# `_register_literal!` / `_register_regex!` / `_register_special!`
# automatically surfaces it in Tab-completion. No list to maintain
# here — if you find yourself adding entries below, fix the
# extraction in `_extract_regex_verbs` instead.

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
    _try_ex_autocomplete!(m, ed) -> Bool

Tab inside the ex-command line. Splits `command_buffer` on the first
space:
  * no space → cycle over ex-command verbs
  * with space → cycle over the verb-specific argument set

Opens a `_start_completion_session!` so the picker UI (LOG pane
swap) lights up just like the :insert path, and subsequent Tab
presses cycle. Returns true iff Tab was consumed.
"""
function _try_ex_autocomplete!(m::RessacApp, ed::TK.CodeEditor)
    # Active cycle on the same ex-command session → advance.
    if _completion_picker_active(m) && startswith(m.completion_label, "ex:")
        return _advance_completion_session!(m)
    end
    _reset_completion!(m)
    buf = String(ed.command_buffer)
    isempty(buf) && return false
    sp = findfirst(' ', buf)
    if sp === nothing
        # Verb completion.
        partial = buf
        ranked = _fuzzy_rank(partial, _all_ex_verbs())
        isempty(ranked) && return false
        top = first(ranked, 12)
        splice = _make_ex_verb_splicer(m, ed)
        return _start_completion_session!(m, top, splice; label = "ex:verb")
    else
        # Argument completion for a known verb.
        verb = buf[1:sp-1]
        rest = buf[sp+1:end]
        toks = String.(split(rest, ' '; keepempty=true))
        partial = isempty(toks) ? "" : toks[end]
        candidates = _ex_arg_candidates(verb)
        isempty(candidates) && return false
        ranked = _fuzzy_rank(partial, candidates)
        isempty(ranked) && return false
        top = first(ranked, 12)
        splice = _make_ex_arg_splicer(m, ed, verb, toks)
        return _start_completion_session!(m, top, splice; label = "ex:$verb")
    end
end

"""
    _make_ex_verb_splicer(m, ed) -> Function

Splice for ex-command VERB completion. The whole `command_buffer`
gets replaced with the chosen verb (verbs have no space, so the
whole buffer IS the partial).
"""
function _make_ex_verb_splicer(m::RessacApp, ed::TK.CodeEditor)
    return function (i::Int)
        i in eachindex(m.completion_candidates) || return
        empty!(ed.command_buffer)
        append!(ed.command_buffer, collect(m.completion_candidates[i]))
        return
    end
end

"""
    _make_ex_arg_splicer(m, ed, verb, toks) -> Function

Splice for ex-command ARGUMENT completion. The verb + the leading
tokens stay verbatim; only the LAST token (the partial) is
replaced with the chosen candidate. `toks` is the original split
of the rest, captured at session start.
"""
function _make_ex_arg_splicer(m::RessacApp, ed::TK.CodeEditor,
                              verb::AbstractString, toks::Vector{String})
    head = String(verb) * " " *
           (length(toks) > 1 ? join(toks[1:end-1], ' ') * " " : "")
    return function (i::Int)
        i in eachindex(m.completion_candidates) || return
        new_buf = head * m.completion_candidates[i]
        empty!(ed.command_buffer)
        append!(ed.command_buffer, collect(new_buf))
        return
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
