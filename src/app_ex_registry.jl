# src/app_ex_registry.jl
# Les commandes ex (`:`) : les trois tables de dispatch (littéral / regex /
# spécial), l'enregistrement (`_register_*!`), les verbes complétables, le
# dispatch avec son pont entre modes, l'historique. Les commandes
# elles-mêmes sont dans app_commands.jl.

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

"""
    _command_completion_candidates(m, query) -> Vector{String}

Build the Tab-completion candidate list for the autonomous
`CommandLine`. Returns FULL command strings (verb + optional space
+ arg) so the completion step can directly swap the buffer.
"""
function _command_completion_candidates(m::RessacApp, query::AbstractString)
    q = String(query)
    sp = findfirst(' ', q)
    if sp === nothing
        return first(_fuzzy_rank(q, _ex_verbs_for_mode(m)), 200)
    end
    verb = q[1:sp-1]
    rest = q[sp+1:end]
    toks = String.(split(rest, ' '; keepempty = true))
    partial = isempty(toks) ? "" : toks[end]
    args = _ex_arg_candidates(verb)
    isempty(args) && return String[]
    ranked = first(_fuzzy_rank(partial, args), 200)
    head = isempty(toks) || length(toks) == 1 ? "" :
           join(toks[1:end-1], ' ') * " "
    return ["$verb " * head * a for a in ranked]
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
    # Une commande qui lève ne doit jamais faire tomber l'application :
    # elle se lit dans le log, la session continue.
    try
        _dispatch_ex_command!(m, s)
    catch err
        _push_app_log!(m, "[ERROR] :$s — $(first(sprint(showerror, err), 160))")
    end
    return
end

function _dispatch_ex_command!(m::RessacApp, s::String)
    # 0. Une commande d'un autre mode y emmène d'abord.
    _mode_bridge!(m, s)
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
    _push_app_log!(m, "[WARN] commande inconnue : :$s (? aide · Tab complète)")
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
