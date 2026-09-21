# src/app_commands.jl
# Commandes ex (`:`) : les trois tables de dispatch (littéral / regex /
# spécial), l'enregistrement de chaque commande et ses handlers (session,
# layout, tuning, SC, alias, thème, starter, doc, import…), l'historique.

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
        return first(_fuzzy_rank(q, _all_ex_verbs()), 200)
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
    _ex_search!(m, query)

Forward search for `query` in the currently active editor's buffer.
Placeholder for sub-projet 11 — for now just logs the request.
"""
function _ex_search!(m::RessacApp, query::AbstractString)
    _push_app_log!(m, "[INFO] /$(query)  (recherche : à câbler)")
end

# ── Lifecycle ────────────────────────────────────────────────────────
# Bodies wrapped in `m -> fn(m)` instead of bare `fn` so the function
# names resolve at CALL time, not at registration time — most helpers
# are defined later in the same file.
# :q ferme la pane focalisée ; sur la dernière pane du workspace, quitte
# l'app. :qa / :q! quittent tout de suite.
_register_literal!(m -> _close_pane_or_quit!(m),  "q", "quit")
_register_literal!(m -> _quit!(m),               "q!", "qa", "qa!")

# Sub-project 10: save the workspace layout before exit so the next
# session restores it. Errors are logged and swallowed — refusing
# to quit because of a serializer bug would be hostile.
# Nombre de panes (tuiles + flottantes) du workspace courant.
function _pane_count(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return 0
    return length(collect(_all_leaves(ws.tree))) + length(ws.floats)
end

function _close_pane_or_quit!(m::RessacApp)
    if _pane_count(m) > 1
        cmd_close!(m.workspaces)
        m.zoom_leaf = 0
        _push_app_log!(m, "[INFO] pane fermée — :q sur la dernière pane quitte (:qa quitte tout de suite)")
    else
        _quit!(m)
    end
    return
end

# Échap en mode normal sur la dernière pane : la première pression
# prévient, la seconde (< 2 s) quitte.
function _esc_quit_step!(m::RessacApp)
    now = time()
    if now - m.esc_quit_at < 2.0
        _quit!(m)
    else
        m.esc_quit_at = now
        _push_app_log!(m, "[INFO] Échap encore pour quitter Ressac (dernière pane) — :qa quitte tout de suite")
    end
    return
end

function _quit!(m::RessacApp)
    try
        save_layout(m.workspaces, _default_layout_path())
    catch err
        _push_app_log!(m, "[WARN] sauvegarde du layout échouée : $(sprint(showerror, err))")
    end
    m.quit = true
end
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

# ── Workspace + pane ex commands (sub-project 10) ──────────────────
_register_regex!(r"^workspace\s+new(?:\s+(\S+))?$",
    (m, mt) -> begin
        nm = mt.captures[1] === nothing ? "" : String(mt.captures[1])
        cmd_workspace!(m.workspaces, :new; name = nm)
    end)
_register_literal!(m -> cmd_workspace!(m.workspaces, :close),
                   "workspace close")
_register_literal!(m -> cmd_workspace!(m.workspaces, :next),
                   "workspace next", "wsnext")
_register_literal!(m -> cmd_workspace!(m.workspaces, :prev),
                   "workspace prev", "wsprev")
_register_regex!(r"^workspace\s+(\S+)$",
    (m, mt) -> cmd_workspace_named!(m.workspaces, mt.captures[1]))

# Shape `^vsplit\s*(\S*)$` — leading literal + \s matches the third
# extraction shape so the verb surfaces in Tab completion. Empty
# capture means "editor" kind.
_register_regex!(r"^vsplit\s*(\S*)$",
    (m, mt) -> begin
        kind = isempty(mt.captures[1]) ? "editor" : String(mt.captures[1])
        cmd_vsplit!(m.workspaces, kind, Dict{String,Any}())
    end)
_register_regex!(r"^hsplit\s*(\S*)$",
    (m, mt) -> begin
        kind = isempty(mt.captures[1]) ? "editor" : String(mt.captures[1])
        cmd_hsplit!(m.workspaces, kind, Dict{String,Any}())
    end)
_register_literal!(m -> cmd_close!(m.workspaces),
                   "pclose", "paneclose")
_register_literal!(m -> cmd_float!(m.workspaces),  "float")
_register_literal!(m -> cmd_tile!(m.workspaces),   "tile")

# ── Workspace layouts (sub-project 10) ──────────────────────────────
_register_regex!(r"^layout\s+save\s+([\w-]+)$", (m, mt) -> _layout_save!(m, mt.captures[1]))
_register_regex!(r"^layout\s+load\s+([\w-]+)$", (m, mt) -> _layout_load!(m, mt.captures[1]))
# No-arg shortcuts: `:layout save` → save to "last", `:layout load`
# → load "last". Useful as a quick checkpoint when the user can't
# come up with a name on the fly.
_register_literal!(m -> _layout_save!(m, "last"), "layout save")
_register_literal!(m -> _layout_load!(m, "last"), "layout load")

function _layout_save!(m::RessacApp, name::AbstractString)
    try
        save_layout(m.workspaces, _named_layout_path(name))
        _push_app_log!(m, "[INFO] :layout save $name — sauvé")
    catch err
        _push_app_log!(m,
            "[ERROR] :layout save $name : $(sprint(showerror, err))")
    end
end

function _layout_load!(m::RessacApp, name::AbstractString)
    path = _named_layout_path(name)
    if !isfile(path)
        _push_app_log!(m,
            "[WARN] :layout load $name — layout introuvable : $path")
        return
    end
    empty!(m.workspaces.workspaces)
    m.workspaces.current_idx = 0
    try
        load_layout!(m.workspaces, path)
        _ensure_default_workspace!(m)
        _push_app_log!(m, "[INFO] :layout load $name — chargé")
    catch err
        _push_app_log!(m,
            "[ERROR] :layout load $name : $(sprint(showerror, err))")
        _ensure_default_workspace!(m)
    end
end

# ── :tuning <variant> handlers ──────────────────────────────────────
# Each handler builds + registers a Scale and logs the resulting
# symbol so the user can reference it via `pat |> scale(:<name>)`.

function _tuning_edo!(m::RessacApp, n_str::AbstractString)
    try
        n = parse(Int, n_str)
        name = Symbol("edo_$n")
        register_scale!(edo(name, n))
        _push_app_log!(m, "[INFO] :tuning edo $n — :$name enregistrée (scale(:$name))")
    catch err
        _push_app_log!(m, "[ERROR] :tuning edo: $(sprint(showerror, err))")
    end
end

function _tuning_ratios!(m::RessacApp, body::AbstractString)
    try
        tokens = split(strip(body), r"\s+")
        ratios = [_parse_ratio_token(t) for t in tokens]
        name = Symbol("ratios_" * join(tokens, "_") |>
                       s -> replace(s, "/" => "o"))   # `_` and `o` only, valid Symbol
        register_scale!(from_ratios(name, ratios))
        _push_app_log!(m, "[INFO] :tuning ratios — :$name enregistrée (scale(:$name))")
    catch err
        _push_app_log!(m, "[ERROR] :tuning ratios: $(sprint(showerror, err))")
    end
end

# Parse a ratio token: "9/8" → 9/8 (Rational), "1.5" → 1.5 (Float),
# "2" → 2 (Int).
function _parse_ratio_token(t::AbstractString)
    if occursin('/', t)
        parts = split(t, '/')
        length(parts) == 2 || throw(ArgumentError("bad ratio: $t"))
        return parse(Int, parts[1]) // parse(Int, parts[2])
    end
    tryparse(Int, t) !== nothing && return parse(Int, t)
    return parse(Float64, t)
end

function _tuning_bp!(m::RessacApp, variant_str::AbstractString)
    try
        variant = Symbol(variant_str)
        name = Symbol("bp_$variant")
        register_scale!(bohlen_pierce(name; variant = variant))
        _push_app_log!(m, "[INFO] :tuning bp $variant — :$name enregistrée")
    catch err
        _push_app_log!(m, "[ERROR] :tuning bp: $(sprint(showerror, err))")
    end
end

function _tuning_golden!(m::RessacApp, n::Int)
    try
        name = Symbol("golden_$n")
        register_scale!(golden_meantone(name; n_steps = n))
        _push_app_log!(m, "[INFO] :tuning golden $n — :$name enregistrée")
    catch err
        _push_app_log!(m, "[ERROR] :tuning golden: $(sprint(showerror, err))")
    end
end

function _tuning_fib!(m::RessacApp, n_str)
    try
        n = n_str === nothing ? 7 : parse(Int, n_str)
        name = Symbol("fib_$n")
        register_scale!(fibonacci_scale(name; n_steps = n))
        _push_app_log!(m, "[INFO] :tuning fib $n — :$name enregistrée")
    catch err
        _push_app_log!(m, "[ERROR] :tuning fib: $(sprint(showerror, err))")
    end
end

function _tuning_cf!(m::RessacApp, body::AbstractString)
    try
        coeffs = [parse(Int, t) for t in split(strip(body), r"\s+")]
        name = Symbol("cf_" * join(coeffs, "_"))
        register_scale!(continued_fraction_scale(name, coeffs))
        _push_app_log!(m, "[INFO] :tuning cf $(join(coeffs, ' ')) — :$name enregistrée")
    catch err
        _push_app_log!(m, "[ERROR] :tuning cf: $(sprint(showerror, err))")
    end
end

function _tuning_sb!(m::RessacApp, depth_str)
    try
        depth = depth_str === nothing ? 5 : parse(Int, depth_str)
        name = Symbol("sb_$depth")
        register_scale!(stern_brocot(name; depth = depth))
        _push_app_log!(m, "[INFO] :tuning sb $depth — :$name enregistrée")
    catch err
        _push_app_log!(m, "[ERROR] :tuning sb: $(sprint(showerror, err))")
    end
end

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
        "[INFO] :audio-in start  → envoie le SynthDef \\ressac_audio_in et écoute\n" *
        "       :audio-in stop   → libère le nœud d'écoute"),
    "audio-in")

# ── Scope ───────────────────────────────────────────────────────────
_register_literal!(m -> _scope_command!(m, :off),    "scope")
_register_regex!(r"^scope\s+([\w-]+)$",
    (m, mt) -> _scope_command!(m, Symbol(mt.captures[1])))
# :scope reservoir <varname> — attach a global var to the reservoir scope.
_register_regex!(r"^scope\s+reservoir\s+([\w-]+)$",
    (m, mt) -> _scope_reservoir!(m, Symbol(mt.captures[1])))

# ── Modals (browse / lib / sccode / snip / guides) ───────────────────
_register_literal!(m -> _open_help!(m),
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
        "[INFO] thèmes : " * join(_available_themes(), ", ")),
    "theme")
_register_regex!(r"^theme\s+(\w+)$",
    (m, mt) -> _theme_switch(m, mt))
_register_literal!(m -> _reload_config_action(m),    "reload-config", "reload-cfg")
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :safety on|off — limiteur master + DC block + HPF 10 Hz (ON par défaut)"),
    "safety")
_register_regex!(r"^safety\s+(on|off)$",
    (m, mt) -> _safety_toggle(m, mt))

# ── Misc / utilities ────────────────────────────────────────────────
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :doc <nom> — essaie gain/release/cutoff/cps/gate/…"),
    "doc")
_register_regex!(r"^doc\s+(\w+)$",
    (m, mt) -> _doc_command!(m, mt.captures[1]))
_register_literal!(m -> _keydebug_toggle(m),         "keydebug")
_register_literal!(m -> (m.paused = true;
        _push_app_log!(m, "[INFO] en pause — shift-glisser pour sélectionner et copier, une touche reprend")),
    "pause", "freeze")
_register_literal!(m -> _copy_logs_to_clipboard!(m), "copylogs", "yanklogs")
_register_literal!(m -> _cycle_log_tail!(m), "log")
# Les trois workspaces de travail (Ctrl-1/2/3 aussi).
_register_literal!(m -> _switch_workspace_named!(m, "PLAY"),    "play")
_register_literal!(m -> _switch_workspace_named!(m, "DESIGN"),  "design")
_register_literal!(m -> _switch_workspace_named!(m, "EXPLORE"), "explore")
_register_literal!(m -> _toggle_zoom!(m), "zoom")
_register_regex!(r"^log\s+(\d+)$", (m, mt) -> _cycle_log_tail!(m, parse(Int, mt.captures[1])))

# ── Starter / scale / cps ───────────────────────────────────────────
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :starter <genre> — " * join(list_starters(), ", ")),
    "starter")
_register_regex!(r"^starter\s+([\w.-]+)$",
    (m, mt) -> _starter_command!(m, mt.captures[1]))

# ── Explainer : :explain [nom] ──────────────────────────────────────
# Explique un synth — `:explain <nom>` lit plugins/user-synths/<nom>.jl
# (structurel si génome embarqué/DSL reconnu) ; `:explain` seul explique
# le buffer focalisé. Résultat dans un modal scrollable.
function _explain_command!(m::RessacApp, name::AbstractString)
    nm = strip(String(name))
    lines = if isempty(nm)
        ed = _active_editor(m)
        g = ed === nothing ? nothing : genome_from_dsl(TK.text(ed))
        g === nothing ? ["(buffer courant : pas un synth DSL reconnu)"] : explain_genome(g)
    else
        path = joinpath(pwd(), "plugins", "user-synths", "$nm.jl")
        explain_synth_file(path)
    end
    m.explain_lines = vcat(["EXPLAIN · $(isempty(nm) ? "buffer courant" : nm)", ""], lines)
    m.modal = :explain
    m.modal_scroll = 0
    return
end
_register_literal!(m -> _explain_command!(m, ""), "explain")
_register_regex!(r"^explain\s+([\w.-]+)$",
    (m, mt) -> _explain_command!(m, mt.captures[1]))

# :sculpt [nom] → src/app_sculpt.jl (avec _open_sculpt_pane! / _save_sculpt!).

# ── SC autodiscover commands (sub-project 8) ────────────────────────
_register_literal!(m -> _sc_rediscover_command!(m), "sc-rediscover")
_register_literal!(m -> _sc_cache_info_command!(m), "sc-cache-info")

"""
    _sc_rediscover_command!(m)

Force re-discovery of SC UGen docs. Deletes `cache_meta.toml` so the
next `_handle_sc_discover` invocation treats the cache as invalid,
then calls the handler synchronously. The docs/*.md files stay in
place during the delete — if discovery fails halfway, the user
still has the old docs to fall back on.
"""
function _sc_rediscover_command!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_app_log!(m,
            "[ERROR] :sc-rediscover demande une session SC active — lance d'abord le live")
        return
    end
    cache_dir = Main._sc_cache_dir()
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    if isfile(meta_path)
        rm(meta_path)
        _push_app_log!(m, "[INFO] :sc-rediscover — cache vidé, redécouverte en cours")
    end
    plugin_dir = joinpath(pwd(), "plugins", "sc-discoverer")
    try
        Main._handle_sc_discover(plugin_dir, Dict{String,Any}(), "sc-discoverer")
        _push_app_log!(m, "[INFO] :sc-rediscover — terminé. Relance le live pour recharger les docs.")
    catch err
        _push_app_log!(m, "[ERROR] :sc-rediscover a échoué : $(sprint(showerror, err))")
    end
end

"""
    _sc_cache_info_command!(m)

Print the contents of `cache_meta.toml` + cache dir path to the log.
Useful for debugging stale caches or verifying SC version matches.
"""
function _sc_cache_info_command!(m::RessacApp)
    cache_dir = Main._sc_cache_dir()
    _push_app_log!(m, "[INFO] :sc-cache-info — répertoire du cache : $cache_dir")
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    if !isfile(meta_path)
        _push_app_log!(m, "[INFO] :sc-cache-info — pas encore de cache_meta.toml (jamais découvert)")
        return
    end
    for line in eachline(meta_path)
        _push_app_log!(m, "[INFO]   $line")
    end
    docs_dir = joinpath(cache_dir, "docs")
    if isdir(docs_dir)
        n = count(f -> endswith(f, ".md"), readdir(docs_dir))
        _push_app_log!(m, "[INFO] :sc-cache-info — $n fichiers MD en cache")
    end
end

# :import path  →  copies a .wav into plugins/user-samples/<basename>/
#                  and registers it so it's usable as a sample name.
# :import path as name  → same but rename to `name`.
_register_regex!(r"^import\s+(\S+?)\s+as\s+(\w+)$",
    (m, mt) -> _import_wav!(m, mt.captures[1], mt.captures[2]))
_register_regex!(r"^import\s+(\S+)$",
    (m, mt) -> _import_wav!(m, mt.captures[1], nothing))
_register_literal!(m -> _push_app_log!(m,
        "[INFO] $(length(list_scales())) gamme(s) enregistrée(s) — `:scale list` pour la liste"),
    "scale")
_register_literal!(m -> _push_app_log!(m,
        "[INFO] gammes : " * join(list_scales(), ", ")),
    "scale list")

# ── :tuning <variant> — build + register a new Scale ────────────────
# Each variant builds a Scale via the constructors in core_tuning,
# registers it under a deterministic name, and logs the name so the
# user can reference it via `pat |> scale(:<name>)`.
_register_regex!(r"^tuning\s+edo\s+(\d+)$",
    (m, mt) -> _tuning_edo!(m, mt.captures[1]))
_register_regex!(r"^tuning\s+ratios\s+(.+)$",
    (m, mt) -> _tuning_ratios!(m, mt.captures[1]))
_register_literal!(m -> _tuning_bp!(m, "lambda"), "tuning bp")
_register_regex!(r"^tuning\s+bp\s+(\w+)$",
    (m, mt) -> _tuning_bp!(m, mt.captures[1]))
_register_literal!(m -> _tuning_golden!(m, 12), "tuning golden")
_register_regex!(r"^tuning\s+golden\s+(\d+)$",
    (m, mt) -> _tuning_golden!(m, parse(Int, mt.captures[1])))
_register_regex!(r"^tuning\s+fib(?:\s+(\d+))?$",
    (m, mt) -> _tuning_fib!(m, mt.captures[1]))
_register_regex!(r"^tuning\s+cf\s+(.+)$",
    (m, mt) -> _tuning_cf!(m, mt.captures[1]))
_register_regex!(r"^tuning\s+sb(?:\s+(\d+))?$",
    (m, mt) -> _tuning_sb!(m, mt.captures[1]))

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
# _save_sculpt! (sauve le génome sculpté en .jl re-jouable/re-sculptable)
# → src/app_sculpt.jl.

function _save_or_session(m::RessacApp)
    if _focused_sculpt_pane(m) !== nothing
        _save_sculpt!(m, "")
    elseif _focused_role(m) === :synth && _synth_pane_open(m)
        _save_current_synth!(m)
    else
        _save_session_app!(m, "_last")
    end
end
function _save_or_session_named(m::RessacApp, mt::RegexMatch)
    if _focused_sculpt_pane(m) !== nothing
        _save_sculpt!(m, mt.captures[1])
    elseif _focused_role(m) === :synth && _synth_pane_open(m)
        _save_current_synth!(m; new_name = mt.captures[1])
    else
        _save_session_app!(m, mt.captures[1])
    end
end
function _theme_switch(m::RessacApp, mt::RegexMatch)
    name = Symbol(mt.captures[1])
    if _apply_theme!(name)
        _push_app_log!(m, "[INFO] thème → $name")
    else
        _push_app_log!(m, "[ERROR] thème « $name » introuvable — essaie : " *
                       join(_available_themes()[1:min(end,8)], ", ") * ", …")
    end
end
function _reload_config_action(m::RessacApp)
    cfg = _load_ressac_config!()
    _apply_theme!(cfg.theme)
    _push_app_log!(m, "[INFO] config rechargée — thème=$(cfg.theme), t_init=$(cfg.t_hold_initial_ms)ms accel=$(cfg.t_hold_accel)")
end
function _safety_toggle(m::RessacApp, mt::RegexMatch)
    on = mt.captures[1] == "on"
    sched = _LIVE_SCHEDULER[]
    if sched !== nothing
        send_osc(sched.osc, encode(OSCMessage("/ressac/safety", Any[Int32(on ? 1 : 0)])))
    end
    _push_app_log!(m, "[INFO] safety $(on ? "ON" : "OFF") — limiteur master + DC block + HPF 10 Hz")
end
function _keydebug_toggle(m::RessacApp)
    m.keydebug = !m.keydebug
    _push_app_log!(m, "[INFO] keydebug $(m.keydebug ? "ON" : "OFF") — chaque touche sera journalisée")
end
function _cps_set(m::RessacApp, mt::RegexMatch)
    try
        set_cps!(m.scheduler, parse(Float64, mt.captures[1]))
        _push_app_log!(m, "[INFO] cps = $(mt.captures[1])")
    catch err
        _push_app_log!(m, "[ERROR] cps : $(sprint(showerror, err))")
    end
end

# ── Alias commands ────────────────────────────────────────────────
function _alias_list!(m::RessacApp)
    if isempty(_SYNTH_ALIASES)
        _push_app_log!(m, "[INFO] aucun alias — `:alias <alias> <nom_sc>` pour en ajouter")
        return
    end
    pairs_sorted = sort!(collect(_SYNTH_ALIASES); by = p -> String(p[1]))
    lines = ["$(alias) → $(sc_name)" for (alias, sc_name) in pairs_sorted]
    _push_app_log!(m, "[INFO] alias : " * join(lines, ", "))
end

function _alias_remove!(m::RessacApp, alias::Symbol)
    if unregister_synth_alias!(alias)
        _push_app_log!(m, "[INFO] alias :$alias retiré")
    else
        _push_app_log!(m, "[WARN] :alias-rm — pas d'alias « $alias »")
    end
end

function _alias_rename!(m::RessacApp, old::Symbol, new::Symbol)
    target = get(_SYNTH_ALIASES, old, nothing)
    if target === nothing
        _push_app_log!(m, "[WARN] :alias-rename — pas d'alias « $old »")
        return
    end
    if haskey(_SYNTH_ALIASES, new) && _SYNTH_ALIASES[new] !== target
        _push_app_log!(m, "[ERROR] :alias-rename — « $new » pointe déjà vers « $(_SYNTH_ALIASES[new]) ». :alias-rm $new d'abord.")
        return
    end
    unregister_synth_alias!(old)
    register_synth_alias!(new, target)
    _push_app_log!(m, "[INFO] alias :$old → :$new (tous deux vers $target)")
end

function _alias_set!(m::RessacApp, alias::Symbol, sc_name::Symbol)
    if register_synth_alias!(alias, sc_name)
        if alias === sc_name
            _push_app_log!(m, "[INFO] alias :$alias est l'identité (inutile)")
        else
            _push_app_log!(m, "[INFO] alias :$alias → $sc_name")
        end
    else
        existing = get(_SYNTH_ALIASES, alias, nothing)
        _push_app_log!(m, "[ERROR] :alias — « $alias » pointe déjà vers « $existing ». :alias-rm $alias d'abord.")
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

"""
    _open_or_reuse_editable_pane!(m; role, name) -> CodeEditor | Nothing

Resolve the target editor for a content command (`:starter`, …) without
relying on the ambient `_active_editor`. Reuses an EMPTY editable pane
(any `EditorPane`, role-agnostic — patterns / synth / …) if one exists
in the focused workspace; otherwise opens a fresh editor pane. Returns
the target `CodeEditor`, or `nothing` if the pane couldn't be created.
"""
function _open_or_reuse_editable_pane!(m::RessacApp;
                                       role::AbstractString = "patterns",
                                       name::AbstractString = "main")
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        for leaf in _all_leaves(ws.tree)
            for (ti, tab) in enumerate(leaf.tabs)
                tab isa EditorPane || continue
                1 <= tab.current_tab <= length(tab.tabs) || continue
                ce = tab.tabs[tab.current_tab].code_editor
                if isempty(strip(TK.text(ce)))
                    ws.focused_pane = leaf.id
                    leaf.current_tab = ti
                    return ce
                end
            end
        end
    end
    cmd_vsplit!(m.workspaces, "editor",
                Dict{String,Any}("buffer_role" => role, "name" => name))
    ws2 = current_workspace(m.workspaces)
    ws2 === nothing && return nothing
    pane = _focused_pane_impl(m)
    (pane isa EditorPane && 1 <= pane.current_tab <= length(pane.tabs)) || return nothing
    return pane.tabs[pane.current_tab].code_editor
end

"""
    _starter_command!(m, genre)

Load a starter sketch into a target editor pane (reusing an empty
editable pane or opening a fresh one — never clobbering a pane the user
is working in). Packs with their own `panes=[...]` spec rebuild the
layout and seed its primary editor instead.
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
                "[WARN] :starter — « $genre » est ambigu : " *
                join(sort!(matches), ", "))
            return
        else
            _push_app_log!(m,
                "[WARN] :starter — pas de pack « $genre » — essaie : " *
                join(sort!(all_keys), ", "))
            return
        end
    end
    # If the snippet declares panes = [...], rebuild the focused
    # workspace BEFORE seeding the buffer so the text lands in the
    # newly-installed primary editor pane (not the about-to-be-replaced
    # one). Errors are logged so a malformed spec doesn't kill the
    # :starter command outright.
    if !isempty(snip.panes)
        try
            apply_snippet_panes!(m.workspaces, snip.panes, snip.mode;
                                 snippet_name = snip.name)
        catch err
            _push_app_log!(m,
                "[ERROR] :starter — application des panes échouée : $(sprint(showerror, err))")
        end
    end
    # Target a pane explicitly. A starter with its own panes=[...] spec
    # already built the layout above → seed its primary editor. Otherwise
    # reuse an empty editable pane or open a fresh one (never clobber a
    # pane the user is working in).
    ed = isempty(snip.panes) ?
        _open_or_reuse_editable_pane!(m; name = "starter") :
        _active_editor(m)
    ed === nothing && return
    TK.set_text!(ed, snip.resolved_content)
    ed.cursor_row = 1
    ed.cursor_col = 0
    _push_app_log!(m, "[INFO] :starter $key chargé — e évalue chaque @dN, E tout")
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
        _push_app_log!(m, "[ERROR] :import — aucun fichier : $src_path")
        return
    end
    name = name_or_nothing === nothing ?
        splitext(basename(src_path))[1] : String(name_or_nothing)
    name = replace(name, r"[^A-Za-z0-9_]" => "_")
    isempty(name) && (_push_app_log!(m, "[ERROR] :import — nom vide"); return)
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
        "[INFO] :import → $(name) ($(length(variants)) variante$(length(variants) == 1 ? "" : "s")) " *
        "— dans un pattern : p\"$(name)\"")
end

# ---------------------------------------------------------------------
# Live mute / solo on the scheduler (no buffer mutation)
# ---------------------------------------------------------------------

function _save_session_app!(m::RessacApp, name::AbstractString)
    dir = joinpath(pwd(), "sessions")
    isdir(dir) || mkpath(dir)
    path = joinpath(dir, String(name) * ".txt")
    ed = _active_editor(m)
    if ed === nothing
        _push_app_log!(m, "[ERROR] :save — aucune pane éditeur à sauver"); return
    end
    try
        write(path, TK.text(ed))
        _push_app_log!(m, "[INFO] session sauvée → $path")
    catch err
        _push_app_log!(m, "[ERROR] :save : $(sprint(showerror, err))")
    end
end

function _load_session_app!(m::RessacApp, name::AbstractString)
    path = joinpath(pwd(), "sessions", String(name) * ".txt")
    if !isfile(path)
        _push_app_log!(m, "[ERROR] :load — aucun fichier : $path — :sessions pour la liste")
        return
    end
    try
        ed = _open_or_reuse_editable_pane!(m; name = String(name))
        ed === nothing && return
        TK.set_text!(ed, read(path, String))
        ed.cursor_row = 1; ed.cursor_col = 0
        _push_app_log!(m, "[INFO] session « $name » chargée — E évalue tous les blocs")
    catch err
        _push_app_log!(m, "[ERROR] :load : $(sprint(showerror, err))")
    end
end

function _list_sessions_app!(m::RessacApp)
    dir = joinpath(pwd(), "sessions")
    if !isdir(dir)
        _push_app_log!(m, "[INFO] pas encore de répertoire sessions — :save <nom> le crée")
        return
    end
    files = sort!([f for f in readdir(dir) if endswith(f, ".txt")])
    if isempty(files)
        _push_app_log!(m, "[INFO] (aucune session sauvée)")
        return
    end
    names = join((splitext(f)[1] for f in files), ", ")
    _push_app_log!(m, "[INFO] sessions : $names  (:load <nom>)")
end

function _doc_command!(m::RessacApp, name::AbstractString)
    entry = lookup_doc(String(name))
    if entry === nothing
        # Fall back to _lookup_livedoc (covers the _SC_UGEN_DOCS branch
        # for SC UGens that aren't in the plugin doc tree).
        desc = _lookup_livedoc(name)
        if desc === nothing
            _push_app_log!(m, "[WARN] :doc — aucune entrée pour « $name »")
            return
        end
        _push_app_log!(m, "[doc] $name — $desc")
        return
    end
    _push_app_log!(m, "[doc] $name — $(entry.short)")
    isempty(entry.examples) && return
    _push_app_log!(m, "[doc]   exemples :")
    for ex in entry.examples
        _push_app_log!(m, "[doc]     $ex")
    end
end
