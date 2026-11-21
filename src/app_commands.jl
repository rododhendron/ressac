# src/app_commands.jl
# Les commandes ex, une par ligne : `_register_literal!` / `_register_regex!`
# / `_register_special!` (tables et dispatch : app_ex_registry.jl) et leurs
# handlers — session, layout, tuning, SC, alias, thème, starter, import…
# La doc vivante et la pane DOC : app_livedoc.jl.

"""
    _ex_search!(m, query)

Forward search for `query` in the currently active editor's buffer.
Pas d'import d'archive pour l'instant : on le dit.
"""
# `/texte` : cherche dans le texte de l'éditeur. Le curseur va sur la
# première occurrence à partir de sa position (en bouclant), toutes sont
# surlignées, `n` / `N` passent à la suivante / la précédente. `/` seul
# efface la recherche.
function _ex_search!(m::RessacApp, query::AbstractString)
    ed = _active_editor(m)
    ed === nothing && (_push_app_log!(m, "[WARN] / — pas de texte où chercher ici"); return)
    ed.search_query = collect(String(query))
    TK._update_search_matches!(ed)
    if isempty(query)
        _push_app_log!(m, "[INFO] recherche effacée")
    elseif isempty(ed.search_matches)
        _push_app_log!(m, "[INFO] /$(query) — introuvable")
    else
        (row, col) = ed.search_matches[ed.search_match_idx]
        ed.cursor_row = row; ed.cursor_col = col - 1
        k = length(ed.search_matches)
        _push_app_log!(m, "[INFO] /$(query) — $(ed.search_match_idx)/$k · n suivante, N précédente")
    end
    return
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
    ws = current_workspace(m.workspaces)
    pl = ws === nothing ? nothing : _patterns_leaf(ws)
    on_patterns = pl !== nothing && ws.focused_pane == pl.id
    if m.volet !== :fiche && (on_patterns || _focus_in_volet(m))
        # Un volet est ouvert : :q le ferme, la fiche revient, les patterns
        # reprennent le clavier.
        _close_volet!(m)
        _push_app_log!(m, "[INFO] volet fermé — :q de nouveau pour quitter (:qa quitte tout de suite)")
    elseif !on_patterns
        _close_focused_pane!(m)                   # la fiche rend le clavier ; une pane scindée se ferme
    else
        _quit!(m)
    end
    return
end

function _quit!(m::RessacApp)
    _session_state_save!(m)
    try
        save_layout(m.workspaces, _default_layout_path())
    catch err
        _push_app_log!(m, "[WARN] sauvegarde du layout échouée : $(sprint(showerror, err))")
    end
    m.quit = true
end
_register_literal!(m -> _panic!(m),              "panic")
_register_literal!(m -> _hush!(m),               "hush", "stop", "silence")
# Disposition du clavier : la table Maj (`?` sur AZERTY est Maj+`,`).
function _keyboard_command!(m::RessacApp, arg::AbstractString)
    a = lowercase(strip(arg))
    if isempty(a)
        _push_app_log!(m, "[INFO] clavier : $(_KEYBOARD[]) — :keyboard azerty|qwerty|auto")
    elseif a == "auto"
        (l, src) = _setup_keyboard!(:auto)
        _push_app_log!(m, "[INFO] clavier : $l ($src)")
    elseif a in ("azerty", "qwerty")
        apply_keyboard_layout!(Symbol(a))
        _push_app_log!(m, "[INFO] clavier : $a")
    else
        _push_app_log!(m, "[WARN] :keyboard azerty | qwerty | auto")
    end
    return
end
_register_literal!(m -> _keyboard_command!(m, ""), "keyboard", "clavier")
_register_regex!(r"^(?:keyboard|clavier)\s+(\S+)$", (m, mt) -> _keyboard_command!(m, mt.captures[1]))
# Transitions : comment les prochains @dN prennent la place des anciens.
function _set_transition!(m::RessacApp, mode::Symbol, n::Int)
    _EVAL_MODE[] = (mode, n)
    _push_app_log!(m, mode === :immediate ? "[INFO] transitions : immédiat — un @dN remplace tout de suite" :
                      mode === :deferred  ? "[INFO] transitions : jump $n — un @dN attend $(n == 1 ? "le prochain cycle" : "$n cycles")" :
                                            "[INFO] transitions : xfade $n — un @dN fond sur $n cycle$(n > 1 ? "s" : "")")
    return
end
_register_literal!(m -> _set_transition!(m, :immediate, 0), "now")
_register_literal!(m -> _set_transition!(m, :deferred, 1),  "jump")
_register_regex!(r"^jump\s+(\d+)$",  (m, mt) -> _set_transition!(m, :deferred, parse(Int, mt.captures[1])))
_register_literal!(m -> _set_transition!(m, :xfade, 4),     "xfade")
_register_regex!(r"^xfade\s+(\d+)$", (m, mt) -> _set_transition!(m, :xfade, max(1, parse(Int, mt.captures[1]))))

# ── Synth tabs ───────────────────────────────────────────────────────
_register_literal!(m -> _open_sandbox_synth!(m),     "synth", "scratch", "sandbox")
# `:back` : la fiche revient à droite, le clavier dans le texte.
_register_literal!(m -> _close_volet!(m), "back", "fiche", "close")
_register_regex!(r"^synth\s+(\w+)$",
    (m, mt) -> _open_sound!(m, mt.captures[1]))

# ── Save / sessions — context-sensitive on focus ─────────────────────
# `:w` écrit la session (le texte, sons compris). Un son se range dans la
# réserve par `:save` (ou `Espace W`), le curseur dessus.
_register_literal!(m -> _write_focused!(m, ""),     "w")
_register_regex!(r"^w\s+(\S+)$", (m, mt) -> _write_focused!(m, mt.captures[1]))
# Les sessions, avec les verbes de vim (app_sessions.jl).
_register_literal!(m -> _reload_focused!(m),               "e")
_register_literal!(m -> _reload_focused!(m; force = true), "e!")
_register_regex!(r"^e\s+(\S+)$",  (m, mt) -> _session_open!(m, mt.captures[1]))
_register_regex!(r"^e!\s+(\S+)$", (m, mt) -> _session_open!(m, mt.captures[1]; force = true))
_register_literal!(m -> _session_new!(m),               "enew")
_register_literal!(m -> _session_new!(m; force = true), "enew!")
_register_literal!(m -> _open_sessions_modal!(m), "sessions", "ls")
_register_literal!(m -> _open_reserve!(m), "réserve", "reserve")
_register_literal!(m -> _format_current_synth!(m), "format", "fmt")

# ── Workspaces et panes ──────────────────
_register_regex!(r"^workspace\s+new(?:\s+(\S+))?$",
    (m, mt) -> begin
        nm = mt.captures[1] === nothing ? "" : String(mt.captures[1])
        cmd_workspace!(m.workspaces, :new; name = nm)
    end)

# Shape `^vsplit\s*(\S*)$` — leading literal + \s matches the third
# extraction shape so the verb surfaces in Tab completion. Empty
# capture means "editor" kind.
_register_regex!(r"^vsplit\s*(\S*)$",
    (m, mt) -> _split_command!(m, "vsplit", cmd_vsplit!, mt.captures[1]))
_register_regex!(r"^hsplit\s*(\S*)$",
    (m, mt) -> _split_command!(m, "hsplit", cmd_hsplit!, mt.captures[1]))

# `:vsplit [type]` / `:hsplit [type]` : un type de pane inconnu se dit dans
# le journal (avant, la commande ne faisait rien, sans un mot).
function _split_command!(m::RessacApp, verb::AbstractString, split!, kind_arg::AbstractString)
    kind = isempty(kind_arg) ? "editor" : String(kind_arg)
    if !haskey(_PANE_KINDS, Symbol(kind))
        known = join(sort!(String.(collect(keys(_PANE_KINDS)))), ", ")
        _push_app_log!(m, "[ERROR] :$verb — type de pane inconnu « $kind » (types : $known)")
        return
    end
    split!(m.workspaces, kind, Dict{String,Any}())
    return
end
_register_literal!(m -> _close_focused_pane!(m),
                   "pclose", "paneclose")
_register_literal!(m -> cmd_float!(m.workspaces),  "float")
_register_literal!(m -> cmd_tile!(m.workspaces),   "tile")

# ── Dispositions sauvées ──────────────────────────────
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
    # La disposition est lue À CÔTÉ, en entier ; ce qui est à l'écran n'est
    # remplacé que si elle est bonne. (Avant, les workspaces étaient vidés
    # d'abord : un fichier abîmé emportait le texte en cours, et le journal
    # disait « chargé ».)
    fresh = try
        read_layout(path)
    catch err
        _push_app_log!(m, "[ERROR] :layout load $name — rien n'est changé : $(sprint(showerror, err))")
        return
    end
    _adopt_layout!(m.workspaces, fresh)
    _ensure_default_workspace!(m)
    _push_app_log!(m, "[INFO] :layout load $name — chargé")
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
_register_literal!(m -> _test_current_synth!(m), "test", "t")

# ── Audio input → reservoir bridge ─────────────────────────────────
_register_regex!(r"^audio-in\s+start$",
    (m, _) -> _audio_in_start!(m))
_register_regex!(r"^audio-in\s+stop$",
    (m, _) -> _audio_in_stop!(m))
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :audio-in start  → envoie le SynthDef \\ressac_audio_in et écoute\n" *
        "       :audio-in stop   → libère le nœud d'écoute"),
    "audio-in")

"""
    _open_notes_pane!(m)

`:notes` — ouvre (ou focalise) le visualiseur de notes à côté des
patterns.
"""
function _open_notes_pane!(m::RessacApp)
    pane = _find_pane(m, NotesPane)
    if pane === nothing
        pane = _place_pane!(m, :notes, Dict{String,Any}())
        pane isa NotesPane || return
        _focus_pane!(m, pane)
        _push_app_log!(m, "[INFO] notes — + / − élargit ou resserre la fenêtre · Ctrl-w z zoome · :q ferme")
    else
        _focus_pane!(m, pane)
    end
    return
end

"""
    _clash_report!(m)

`:clash` — ce qui se cogne dans les slots qui jouent : attaques
simultanées, bandes qui se recouvrent, avec la correction à essayer.
"""
function _clash_report!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing || isempty(sched.patterns)
        _push_app_log!(m, "[INFO] :clash — rien ne joue pour l'instant")
        return
    end
    found = clashes(sched.patterns)
    if isempty(found)
        _show_listing!(m, "COLLISIONS",
                       ["Rien ne se cogne : les attaques ne tombent pas ensemble.", "",
                        "`:doc duck` · `:doc avoid` · `:doc slot_band` pour dégager à l'avance."])
        return
    end
    lines = String["Ce qui se gêne dans les slots qui jouent, du plus net au moins net.", "",
                   rpad("voix", 16) * rpad("ensemble", 12) * "à essayer", ""]
    for (a, b, share, note) in found
        push!(lines, rpad("$a ↔ $b", 16) * rpad("$(round(Int, 100 * share)) %", 12) * note)
    end
    push!(lines, "")
    push!(lines, "duck(\"bd*4\") baisse sous un autre · avoid(…) écarte les attaques")
    push!(lines, "slot_band(i, n) donne une fenêtre de fréquences · fan(i, n) écarte en stéréo")
    push!(lines, "declash([…]) applique les trois d'un coup")
    _show_listing!(m, "COLLISIONS", lines)
    return
end

"""
    _scales_listing() -> Vector{String}

Les gammes enregistrées avec leur nombre de degrés et leur période,
pour choisir sans aller lire le code.
"""
function _scales_listing()
    out = String["`:doc scale` explique l'usage · `@d1 :pad |> n(0:6) |> scale(:nom)`", ""]
    for name in list_scales()
        sc = lookup_scale(name)
        sc === nothing && continue
        per = round(Int, sc.period_cents)
        push!(out, rpad(String(name), 24) * "$(length(sc.cents)) degrés · période $(per) ¢")
    end
    return out
end

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
_register_literal!(m -> _open_tutorial!(m), "tutorial", "tour", "start")
_register_literal!(m -> _open_modal!(m, :synth_guide),
                   "synth-guide")
_register_literal!(m -> _open_modal!(m, :dsl_guide),
                   "dsl", "dsl-guide", "synth-dsl")
_register_literal!(m -> _open_wiki!(m),
                   "wiki", "docs", "doc-wiki")
_register_regex!(r"^(?:wiki|docs)\s+(.+)$", (m, mt) -> _open_wiki!(m; page = String(mt.captures[1])))
_register_literal!(m -> _open_browser!(m),           "browse", "b")
_register_literal!(m -> _open_synth_library!(m),     "synthlib", "synth-library", "lib")
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :add <nom> — installe une recette de la librairie (Espace L pour la liste)"),
    "add")
_register_regex!(r"^add\s+([\w-]+)$", (m, mt) -> _add_synth_from_library!(m, mt.captures[1]))
_register_literal!(m -> _open_mixer!(m),             "mixer", "mix")
_register_literal!(m -> _open_snippets!(m),          "snip", "snippets", "snippet")
_register_literal!(m -> _open_patterns_modal!(m),    "pats", "patterns", "patlib")
_register_literal!(m -> _open_evolve_modal!(m),      "vary", "variations", "evolve")
_register_literal!(m -> _open_palette!(m),           "palette", "p")
_register_literal!(m -> _clash_report!(m),           "clash", "clashes", "collisions")
_register_literal!(m -> _open_notes_pane!(m),        "notes", "roll", "piano-roll")
_register_literal!(m -> (m.lanes = !m.lanes;
        _push_app_log!(m, "[INFO] pistes en bout de ligne " * (m.lanes ? "affichées" : "cachées"))),
    "pistes", "lanes", "inline")
_register_literal!(m -> (m.calm = !m.calm;
        _push_app_log!(m, m.calm ? "[INFO] écran calme : plus rien ne s'allume au coup" :
                                   "[INFO] les lignes s'allument de nouveau au coup")),
    "calme", "calm")
_register_literal!(m -> (m.pixels = !m.pixels;
        _push_app_log!(m, !m.pixels ? "[INFO] la grille du cycle en caractères" :
                          TK.graphics_protocol() == TK.gfx_kitty ? "[INFO] la grille du cycle en pixels, derrière le texte" :
                          "[INFO] la grille en pixels est demandée, mais ce terminal ne parle pas le protocole graphique de kitty : elle reste en caractères")),
    "pixels")
_register_literal!(m -> (m.inline = !m.inline;
        _push_app_log!(m, m.inline ? "[INFO] les réglages et les visuels s'ouvrent sous leur slot" :
                                     "[INFO] plus de rangées sous les slots : le texte reste serré")),
    "rangées", "rangees", "rows")
# Patterns rangés — verbes distincts de :save / :load, qui appartiennent
# déjà aux sessions (un workspace entier, pas un bloc).
_register_literal!(m -> _save_under_cursor!(m), "save", "keep")
_register_regex!(r"^(?:save|keep)\s+(.+)$", (m, mt) -> _save_under_cursor!(m, mt.captures[1]))
_register_literal!(m -> _push_app_log!(m,
        "[INFO] :recall <nom> [slot] — recharge un pattern rangé (Espace P pour la liste)"),
    "recall")
_register_regex!(r"^recall\s+([\w-]+)$", (m, mt) -> _load_pattern_cmd!(m, mt.captures[1]))
_register_regex!(r"^recall\s+([\w-]+)\s+d?(\d+)$",
    (m, mt) -> _load_pattern_cmd!(m, mt.captures[1], parse(Int, mt.captures[2])))
_register_literal!(m -> _open_sccode!(m),            "sccode", "sc")
_register_regex!(r"^(?:sccode|sc)\s+(\S+)$",
    (m, mt) -> _direct_load_sccode!(m, mt.captures[1]))

# ── Synth alias management ─────────────────────────────────────────
# Aliases are short, user-typed names that resolve to SC SynthDef
# names. See _SYNTH_ALIASES + register_synth_alias! in plugin_registry.jl.
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
_register_literal!(m -> _open_outputs!(m),           "sorties", "outputs", "audio")
_register_literal!(m -> _casque_toggle!(m),          "casque")
_register_literal!(m -> _export_current_synth!(m),   "export", "export-synth")
_register_regex!(r"^export(?:-synth)?\s+(\S+)$",
    (m, mt) -> begin
        d = tryparse(Float64, mt.captures[1])
        d === nothing ?
            _push_app_log!(m, "[ERROR] :export attend une durée en secondes (:export 4) — pour sauver le synth sous un nom, :w $(mt.captures[1])") :
            _export_current_synth!(m; duration = d)
    end)
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
_register_literal!(m -> _set_test_note!(m, ""),      "note")
_register_regex!(r"^note\s+(\S+)$", (m, mt) -> _set_test_note!(m, mt.captures[1]))
_register_literal!(m -> _piano_start!(m),            "piano")
_register_literal!(m -> _piano_start!(m; record = true),
                   "piano-rec", "piano-record")
_register_regex!(r"^piano\s+(\w+)$",
    (m, mt) -> _piano_start!(m; synth = String(mt.captures[1])))
_register_regex!(r"^piano-rec\s+(\w+)$",
    (m, mt) -> _piano_start!(m; synth = String(mt.captures[1]), record = true))

# ── Theme / config / safety ─────────────────────────────────────────
_register_literal!(m -> _show_listing!(m, "THÈMES",
        vcat("`:theme <nom>` applique", "", _columnise(sort!(String.(_available_themes()))))),
    "theme", "themes")
_register_regex!(r"^theme\s+(\w+)$",
    (m, mt) -> _theme_switch(m, mt))
_register_literal!(m -> _reload_config_action(m),    "reload-config", "reload-cfg")
# Le menu Espace : le voir, y ajouter une touche, en retirer une.
_register_literal!(m -> _show_listing!(m, "MENU ESPACE", _leader_listing()), "leader")
_register_regex!(r"^leader\s+(\S)\s+(.+)$", (m, mt) -> _leader_set_cmd!(m, mt.captures[1], mt.captures[2]))
_register_regex!(r"^leader-rm\s+(\S)$", (m, mt) -> _leader_rm_cmd!(m, mt.captures[1]))
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
# Les volets (app_volet.jl). `:wiki` et `:synth` ont leurs commandes plus
# haut ; `:back` / `:fiche` rendent la colonne de droite à la fiche.
_register_literal!(m -> _open_volet!(m, :son),      "son")
_register_literal!(m -> _open_volet!(m, :explorer), "explorer", "explore")
_register_literal!(m -> _reset_screen!(m), "reset")
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
    if isempty(nm) && _current_sound(m) !== nothing
        _design_doc_mode!(m, :explain)
        sdoc = _sound_doc(m)
        sdoc === nothing || _focus_pane!(m, sdoc)
        return
    end
    lines = if isempty(nm)
        ["(pose le curseur sur un son — un bloc @synth — ou donne un nom : :explain <nom>)"]
    else
        path = joinpath(_project_dir(), "plugins", "user-synths", "$nm.jl")
        g = isfile(path) ? genome_from_dsl(read(path, String)) : nothing
        g === nothing ? explain_synth_file(path) : vcat(explain_genome(g), prune_report_lines(g))
    end
    m.explain_lines = vcat(["EXPLAIN · $(isempty(nm) ? "?" : nm)", ""], lines)
    _open_modal!(m, :explain)
    return
end
_register_literal!(m -> _explain_command!(m, ""), "explain")
_register_literal!(m -> _prune_command!(m, ""), "prune")
_register_regex!(r"^prune\s+([0-9.]+)$", (m, mt) -> _prune_command!(m, mt.captures[1]))
_register_literal!(m -> _todsl_command!(m), "todsl", "to-dsl", "sc2dsl")
_register_regex!(r"^explain\s+([\w.-]+)$",
    (m, mt) -> _explain_command!(m, mt.captures[1]))

# ── Découverte des UGens SC ────────────────────────
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
    cache_dir = Main.ScDiscoverer._sc_cache_dir()
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    if isfile(meta_path)
        rm(meta_path)
        _push_app_log!(m, "[INFO] :sc-rediscover — cache vidé, redécouverte en cours")
    end
    plugin_dir = joinpath(_project_dir(), "plugins", "sc-discoverer")
    try
        Main.ScDiscoverer._handle_sc_discover(plugin_dir, Dict{String,Any}(), "sc-discoverer")
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
    cache_dir = Main.ScDiscoverer._sc_cache_dir()
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
# Les listes vont dans un modal défilable : le journal fait trois lignes.
_register_literal!(m -> _show_listing!(m, "GAMMES", _scales_listing()),
    "scale", "scales", "gammes")
_register_literal!(m -> _show_listing!(m, "GAMMES", _scales_listing()),
    "scale list")
_register_literal!(m -> _show_listing!(m, "SAMPLES",
        vcat("$(length(_SAMPLE_REGISTRY)) banque(s) — `:browse` pour écouter", "",
             _columnise(sort!(String.(collect(keys(_SAMPLE_REGISTRY))))))),
    "samples")
_register_literal!(m -> _show_listing!(m, "INSTRUMENTS",
        vcat("$(length(_INSTRUMENT_REGISTRY)) instrument(s) préréglé(s)", "",
             _columnise(sort!(String.(collect(keys(_INSTRUMENT_REGISTRY))))))),
    "instruments")
_register_literal!(m -> _show_listing!(m, "SYNTHS",
        vcat("$(length(_SYNTH_REGISTRY)) synth(s) chargé(s) — `:add <nom>` en installe un de la librairie", "",
             _columnise(sort!(String.(collect(keys(_SYNTH_REGISTRY))))))),
    "synths")
_register_literal!(m -> _show_listing!(m, "ACCORDS",
        vcat("Racine'nom dans la mini-notation : c'maj, 0'dom7, e'min7'ii", "",
             _columnise(sort!(String.(chord_names()))))),
    "chords", "accords")

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

# `:w` écrit la session — le texte entier, sons compris. Ranger un son dans
# la réserve (`plugins/user-synths`) est un autre geste : `:save`.
function _write_focused!(m::RessacApp, name::AbstractString)
    _session_write!(m, name)
    snd = _sound_under_cursor(m)
    snd === nothing || _push_app_log!(m, "[INFO] le son « $(snd.name) » est écrit avec la session — :save (Espace W) le range aussi dans la réserve des sons")
end
# `:e` / `:e!` — relire la session.
_reload_focused!(m::RessacApp; force::Bool = false) = _session_reload!(m; force)

# `:save` (et `:keep`) : ranger ce qui est sous le curseur. Sur un son, le
# son (sous son nom, ou sous celui qu'on donne) ; sur un bloc `@dN`, le
# pattern, sous le nom donné.
function _save_under_cursor!(m::RessacApp, arg::AbstractString = "")
    arg = strip(String(arg))
    snd = _sound_under_cursor(m)
    if snd !== nothing
        isempty(arg) ? _save_sound!(m, snd) : _save_sound!(m, snd; new_name = first(split(arg)))
    elseif isempty(arg)
        _push_app_log!(m, "[INFO] :save <nom> [étiquettes…] — range le bloc @dN sous le curseur (:recall le rappelle) ; sur un @synth, :save range le son")
    else
        _save_pattern_cmd!(m, arg)
    end
    return
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
    _leader_user_load!()
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
    _edit_text!(ed, snip.resolved_content)
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
    dest_dir = joinpath(_project_dir(), "plugins", "user-samples", name)
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
    register_sample!(SampleEntry(sym, "user-samples", dest_dir, variants,
        Dict{String,Any}("description" => "imported via :import")); update = true)
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


