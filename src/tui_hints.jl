# Visual UX support: mode hints, help overlay lines, completion engine.
# Spec: docs/journal/20260522_visual_ux_design.md.

"""
    _fuzzy_score(query, candidate) -> Union{Nothing, Int}

Score how well `candidate` matches `query` as a case-insensitive
subsequence. Lower is tighter. Returns `nothing` if `query` has no
subsequence in `candidate`.

Score = sum of gaps (positions skipped) between consecutive matched
chars. Exact prefix → 0; one-letter gap → 1; etc.
"""
function _fuzzy_score(query::AbstractString, candidate::AbstractString)
    isempty(query) && return 0
    q = lowercase(String(query))
    c = lowercase(String(candidate))
    score = 0
    last_match_pos = 0
    qi = firstindex(q)
    q_end = lastindex(q)
    for (pos, ch) in pairs(c)
        if ch == q[qi]
            if last_match_pos != 0
                score += (pos - last_match_pos - 1)
            end
            last_match_pos = pos
            qi = nextind(q, qi)
            qi > q_end && return score
        end
    end
    return nothing
end

"""
    _fuzzy_rank(query, candidates) -> Vector{String}

Return the subset of `candidates` that fuzzy-match `query`, sorted by
`(score asc, length asc, lexico asc)`. Non-matches are dropped.
"""
function _fuzzy_rank(query::AbstractString, candidates::AbstractVector{<:AbstractString})
    scored = Tuple{Int,Int,String}[]
    for cand in candidates
        s = _fuzzy_score(query, cand)
        s === nothing && continue
        push!(scored, (s, length(cand), String(cand)))
    end
    sort!(scored, by = t -> (t[1], t[2], t[3]))
    return [t[3] for t in scored]
end

"""
    _is_word_char_simple(c) -> Bool

Word-char predicate for completion-target extraction. Does NOT include
`:` (so `bd:1` is two tokens, not one — we don't want to fuzzy-match
into variant indices).
"""
_is_word_char_simple(c::AbstractChar) =
    isletter(c) || isdigit(c) || c == '_' || c == '@'

"""
    _completion_context(line, cursor_col) -> Symbol

Walk `line` left-to-right up to `cursor_col`, tracking whether we are
currently inside a `p"..."` or `m"..."` string. Returns
`:mininotation` if such a string is still open at the cursor,
`:default` otherwise. A `"` not preceded by a recognised opener
toggles a plain-string flag that also blocks default until closed.
"""
function _completion_context(line::AbstractString, cursor_col::Integer)
    in_mn = false
    in_plain = false
    i = firstindex(line)
    last_byte = min(lastindex(line), cursor_col - 1)
    while i <= last_byte
        c = line[i]
        if !in_mn && !in_plain
            ni = nextind(line, i)
            is_opener = ni <= lastindex(line) &&
                        (c == 'p' || c == 'm') && line[ni] == '"' &&
                        (i == firstindex(line) ||
                         !_is_word_char_simple(line[prevind(line, i)]))
            if is_opener
                in_mn = true
                i = nextind(line, ni)
                continue
            end
            if c == '"'
                in_plain = true
            end
        elseif in_mn && c == '"'
            in_mn = false
        elseif in_plain && c == '"'
            in_plain = false
        end
        i = nextind(line, i)
    end
    return in_mn ? :mininotation : :default
end

const _COMMAND_NAMES = [
    "q", "quit", "cps", "goto",
    "samples", "instruments", "synths",
    "guide", "help",
    "browse", "save", "doc", "starter",
    "mute", "unmute", "solo", "unsolo",
]

const _COMBINATOR_NAMES = [
    "pure", "silence", "fast", "slow", "density", "rev", "every",
    "stack", "cat", "mask", "gate",
    "gain", "speed", "lpf", "hpf", "pan", "n", "room", "delay",
    "shape", "set",
    # Auto-generated SuperDirt param helpers — see _SUPERDIRT_PARAM_HELPERS.
    "attack", "release", "hold", "sustain", "legato",
    "cutoff", "resonance", "bandq", "bandf", "hcutoff", "hresonance",
    "crush", "coarse",
    "accelerate", "vibrato", "tremolorate", "tremolodepth",
    "phaserrate", "phaserdepth",
    "delaytime", "delayfeedback",
    "octave", "slide", "pitch1", "pitch2", "pitch3", "detune",
    "sampleloop", "speedup",
    "vowel", "enhance", "leslie", "leslierate", "lesliespeed",
    "pan2", "panspan", "panorbit", "panwidth",
]

"""
    _buffer_candidates(ctx::Symbol) -> Vector{String}

Compute the candidate list for in-buffer autocomplete. `ctx` is either
`:mininotation` (cursor inside `p"..."` or `m"..."`) — registries only
— or `:default`, which also adds combinators and `@d1..@d64` slot
macros.
"""
function _buffer_candidates(ctx::Symbol)::Vector{String}
    out = String[]
    append!(out, String.(keys(_SAMPLE_REGISTRY)))
    append!(out, String.(keys(_INSTRUMENT_REGISTRY)))
    append!(out, String.(keys(_SYNTH_REGISTRY)))
    if ctx === :default
        append!(out, _COMBINATOR_NAMES)
        append!(out, ["@d$i" for i in 1:64])
    end
    unique!(out)
    return out
end

function _command_arg_candidates(verb::AbstractString)
    verb == "samples"     && return String.(keys(_SAMPLE_REGISTRY))
    verb == "instruments" && return String.(keys(_INSTRUMENT_REGISTRY))
    verb == "synths"      && return String.(keys(_SYNTH_REGISTRY))
    return nothing
end

"""
    _compute_completions(m::LiveModel) -> Vector{String}

Compute the current candidate list for `:`-mode autocomplete based on
`m.command_buffer`. Empty buffer → all command names. Verb-only prefix
→ matching command names. Verb + space + partial → matching argument
candidates for that verb (registry lookup), or empty if the verb has
no argument completion.
"""
function _compute_completions(m::LiveModel)::Vector{String}
    buf = m.command_buffer
    if !occursin(' ', buf)
        return _fuzzy_rank(buf, _COMMAND_NAMES)
    end
    verb, rest = split(buf, ' '; limit=2)
    cands = _command_arg_candidates(verb)
    cands === nothing && return String[]
    return _fuzzy_rank(strip(String(rest)), cands)
end

"""
    _MODE_HINTS

Short, terse one-line hint per mode, shown permanently above the logs.
Tells the user the 4-5 most useful next actions for the current mode.
"""
const _MODE_HINTS = Dict{Symbol,String}(
    :normal      => "i|V|:|K|e  |  :browse pour explorer  |  ? = full help",
    :insert      => "Esc back to normal  |  Tab autocomplete",
    :visual_line => "y/d/m/e on selection  |  Esc cancel",
    :command     => "Enter run  |  Tab cycle  |  Esc cancel",
    :guide       => "j/k scroll  |  /search  |  q close",
    :browser     => "j/k nav  |  type filter  |  K/Space preview  |  Tab type  |  Enter insert",
)

_mode_hint(mode::Symbol) = get(_MODE_HINTS, mode, "")

"""
    _HELP_OVERLAY_LINES

Per-mode help body shown by the `?` overlay. Longer than `_MODE_HINTS`
but still terse — one screen, no scroll.
"""
const _HELP_OVERLAY_LINES = Dict{Symbol,Vector{String}}(
    :normal => [
        "NORMAL mode",
        "",
        "  i / a / o / O — enter insert",
        "  hjkl / arrows — move",
        "  0  \$         — line start / end",
        "  gg / G       — buffer start / end",
        "  gdN          — goto slot dN",
        "  dd / yy / p  — delete / yank / paste",
        "  V            — visual line",
        "  :  /         — cmd / forward search",
        "  K            — preview under cursor",
        "  e            — eval block ([N]e = defer N cycles)",
        "  n / N        — repeat search",
        "  ?            — toggle this overlay",
    ],
    :insert => [
        "INSERT mode",
        "",
        "  type        — insert chars",
        "  Tab         — autocomplete identifier under cursor",
        "  arrows      — move",
        "  Backspace   — delete previous char",
        "  Enter       — newline",
        "  Esc         — back to normal",
    ],
    :visual_line => [
        "VISUAL-LINE mode",
        "",
        "  j / k       — extend selection",
        "  y / d       — yank / delete",
        "  m           — toggle mute on each selected line",
        "  e           — eval the selected block",
        "  Esc         — cancel",
    ],
    :command => [
        "COMMAND mode",
        "",
        "  type        — compose command",
        "  Tab         — autocomplete (cycles)",
        "  Enter       — run",
        "  Esc         — cancel",
    ],
    :guide => [
        "GUIDE mode",
        "",
        "  j / k       — scroll",
        "  gg / G      — top / bottom",
        "  /<rx>       — search forward (jumps to first match)",
        "  n / N       — repeat search",
        "  q / Esc     — close",
    ],
)
