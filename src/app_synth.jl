# src/app_synth.jl
# Les gestes d'un son : l'amener dans le texte (librairie, fichier, point de
# départ), l'entendre (T avec accélération), sa note d'audition, et les
# ponts son ⟷ patterns.

"""
    _STARTER_DSL(name)

Le point de départ d'un son neuf.
"""
_STARTER_DSL(name) = "@synth :$(name) (freq=220, sustain=0.5) sin_osc(:freq)"

"""
    _open_sandbox_synth!(m)

Un son neuf dans le texte, sous un nom de brouillon (`sketch_<id>`) ;
`:save <nom>` lui en donne un vrai.
"""
function _open_sandbox_synth!(m::RessacApp)
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    id = String([chars[rand(1:length(chars))] for _ in 1:3])
    name = "sketch_$(id)"
    _open_sound!(m, name)
    _push_app_log!(m, "[INFO] son brouillon « $name » — :save <nom> le range sous un vrai nom")
end

"""
    _open_sound!(m, name)

Amène le son `name` dans le texte principal et pose le curseur dessus. S'il
y est déjà, on y va. Sinon son texte vient du fichier `.jl` de la réserve,
d'un `.scd` laissé là (converti), d'une recette de la librairie (copiée),
ou du point de départ — et se pose sous le bloc du curseur.
"""
function _open_sound!(m::RessacApp, name::AbstractString)
    name = String(name)
    ed = _patterns_editor!(m)
    ed === nothing && return
    _focus_patterns!(m)
    here = _sound_block_named(ed.lines, name)
    if here !== nothing
        ed.cursor_row = here.row; ed.cursor_col = 0; ed.mode = :normal
        _push_app_log!(m, "[INFO] son « $name » : il est dans le texte, le curseur y est")
        return
    end
    dsl_path = _app_synth_path(name; mode = :dsl)
    sc_path  = _app_synth_path(name; mode = :sc)
    if !isfile(dsl_path) && !isfile(sc_path)
        entry = _synthlib_builtin_entry(name)
        entry === nothing || return _instantiate_synth_entry!(m, entry)
    end
    origin = "ouvert"
    src = if isfile(dsl_path)
        read(dsl_path, String)
    elseif isfile(sc_path)
        (dsl, why) = as_dsl(read(sc_path, String))
        if dsl === nothing
            _push_app_log!(m, "[ERROR] « $name » est en SuperCollider et ne se convertit pas en entier : $why")
            return
        end
        origin = "converti depuis $(name).scd (:save le range en .jl)"
        _align_dsl_synth_name(dsl, name)
    else
        origin = "neuf"
        _STARTER_DSL(name)
    end
    if !occursin(r"(?m)^\s*@synth\s+:\w+", src)
        _push_app_log!(m, "[ERROR] « $name » : son fichier n'a pas de bloc `@synth :nom …` à écrire dans le texte")
        return
    end
    _insert_sound_block!(m, name, src)
    _push_app_log!(m, "[INFO] son « $name » $origin — T l'entend, o / & le travaillent, :save le range")
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
    # Un drone vivant : T l'a réévalué, la rafale n'a pas de sens.
    _editor_drone(m) === nothing || return
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
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    tab = _current_sound(m)
    tab === nothing && return
    # Le son tourne en drone : T le réévalue (nouveau nœud, mêmes réglages).
    if _editor_drone(m) !== nothing
        _drone_launch!(m, tab)
        return
    end
    _audition_synth_text!(m, tab, _sound_text(tab))
    return
end

"""
    _audition_synth_text!(m, tab, src; what = "T — test de") -> Bool

Fait entendre le texte `src` comme le son `tab` : c'est `T`, et
c'est aussi l'essai d'un maillon dans l'atelier (le texte essayé n'est pas
encore dans le buffer). Vrai si le son est parti.

Le nom du @synth est celui du son ; le texte s'évalue dans SynthDSL
(saw, sin_osc, rlpf… y sont des UGens, pas les signaux de patterns du même
nom), en entier. Le @synth compile en SC et envoie lui-même à
/ressac/evalAndPlay.
"""
function _audition_synth_text!(m::RessacApp, tab::Sound, src::AbstractString;
                               what::AbstractString = "T — test de")
    _LIVE_SCHEDULER[] === nothing && return false
    if _is_raw_synthdef(src)
        _push_app_log!(m, "[INFO] ce texte est du SuperCollider : un son s'écrit en DSL (@synth …)")
        return false
    end
    extra = _audition_args(m, tab, src)
    src = _align_dsl_synth_name(src, tab.name)
    try
        _AUDITION_ARGS[] = extra
        try
            Core.eval(SynthDSL, SynthDSL._dsl_parse_all(src))
        finally
            _AUDITION_ARGS[] = Any[]
        end
        _note_played!(src)
        _push_app_log!(m, "[INFO] $what $(tab.name)$(_audition_note_suffix(m, extra))")
        return true
    catch err
        _push_app_log!(m, "[ERROR] éval DSL : $(first(replace(sprint(showerror, err), r"\s*\n\s*" => " · "), 200))")
        return false
    end
end

# ── Hauteur d'un synth (pane + note d'audition) ─────────────────────

"""
    _synth_pitch_info(tab) -> (pitch, sustain, params)

Ce que le SynthDef du buffer sait faire : `pitch` est la clé qui reçoit
la hauteur (`:freq`, `:midinote`, une clé déclarée par `pitch = …` dans
les métadonnées) ou `nothing` ; `sustain` dit si la durée est pilotable.
Lu dans le texte du buffer (pas besoin d'avoir sauvé), complété par le
registre pour `pitch`.
"""
function _synth_pitch_info(tab::Sound)
    src = _sound_text(tab)
    params = _dsl_params_from_text(src)
    entry = synth_info(Symbol(tab.name))
    explicit = entry === nothing ? nothing : get(entry.metadata, "pitch", nothing)
    pitch = explicit isa AbstractString && !isempty(explicit) ? Symbol(explicit) :
            haskey(params, "freq") ? :freq : nothing
    return (pitch = pitch, sustain = haskey(params, "sustain"), params = params)
end

# Suffixe du titre de la pane : « hauteur freq · durée sustain » / « sans hauteur ».
function _synth_title_suffix(tab::Sound)
    info = _synth_pitch_info(tab)
    h = info.pitch === nothing ? "sans hauteur" : "hauteur $(info.pitch)"
    d = info.sustain ? " · durée sustain" : ""
    return h * d
end

const _NOTE_NAMES = ("c", "cs", "d", "ds", "e", "f", "fs", "g", "gs", "a", "as", "b")
# Nom Tidal d'une note en demi-tons (0 = c5) : -12 → c4, 7 → g5.
_note_name(n::Int) = _NOTE_NAMES[mod(n, 12) + 1] * string(5 + fld(n, 12))

# Paires clé/valeur pour jouer le synth du buffer à la note d'audition.
function _audition_args(m::RessacApp, tab::Sound, src::AbstractString)
    m.test_note === nothing && return Any[]
    info = _synth_pitch_info(tab)
    info.pitch === nothing && return Any[]
    note = m.test_note
    midi = note + 60
    val = info.pitch === :midinote ? Float64(midi) :
          info.pitch === :note     ? Float64(note) :
          440.0 * 2.0^((midi - 69) / 12)
    return Any[String(info.pitch), Float32(val)]
end

function _audition_note_suffix(m::RessacApp, extra::Vector{Any})
    m.test_note === nothing && return ""
    isempty(extra) && return " — sans hauteur connue, note $(_note_name(m.test_note)) ignorée"
    return " — note $(_note_name(m.test_note)) ($(extra[1]) = $(round(extra[2]; digits = 2)))"
end

"""
    _set_test_note!(m, arg)

`:note` — note d'audition de T. `:note c4`, `:note 7`, `:note off`,
`:note` seul affiche la note courante.
"""
function _set_test_note!(m::RessacApp, arg::AbstractString)
    a = strip(arg)
    if isempty(a)
        _push_app_log!(m, m.test_note === nothing ?
            "[INFO] T joue les défauts du SynthDef — :note c4 / :note 7 pour fixer une note" :
            "[INFO] note d'audition : $(_note_name(m.test_note)) ($(m.test_note)) — :note off pour revenir aux défauts")
        return
    end
    if a in ("off", "none", "défaut", "default")
        m.test_note = nothing
        _push_app_log!(m, "[INFO] T joue à nouveau les défauts du SynthDef")
        return
    end
    v = tryparse(Int, a)
    v === nothing && (v = _note_number(a))
    if v === nothing
        _push_app_log!(m, "[ERROR] :note — attendu un nombre de demi-tons (0 = do 5) ou un nom (c4, fs5, a3)")
        return
    end
    m.test_note = Int(v)
    _push_app_log!(m, "[INFO] note d'audition : $(_note_name(m.test_note)) ($(m.test_note)) — T la joue")
    return
end

"""
    _align_dsl_synth_name(src, target)

Rewrite the FIRST `@synth :<old>` token in a DSL buffer to match
`target`. Idempotent when they already match; no-op if no @synth
declaration is found.
"""
function _align_dsl_synth_name(src::AbstractString, target::AbstractString)
    mt = match(r"@synth\s+:(\w+)", src)
    mt === nothing && return src
    current = mt.captures[1]
    current == target && return src
    return replace(src, r"@synth\s+:(\w+)" =>
                   SubstitutionString("@synth :$(target)"); count = 1)
end


# ── Sub-project 9 — WorkspaceManager bootstrap ─────────────────────

# Défauts numériques de `@synth :x (freq=220, sustain=0.5) …` dans un texte
# DSL (pour le routage SuperDirt d'un synth utilisateur). Vide sinon.
function _dsl_params_from_text(text::AbstractString)
    out = Dict{String,Any}()
    occursin(r"@synth\b", text) || return out
    # `build_synth` ajoute freq / sustain / gain à tout SynthDef du DSL :
    # ils comptent même si l'utilisateur ne les a pas écrits.
    for (k, v) in pairs(SynthDSL._DEFAULT_PARAMS)
        out[String(k)] = v
    end
    mt = match(r"@synth\s+:\w+\s*\(([^)]*)\)", text)
    mt === nothing && return out
    for kv in split(mt.captures[1], ',')
        m2 = match(r"^\s*(\w+)\s*=\s*([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)\s*$", kv)
        m2 === nothing && continue
        v = tryparse(Int, m2.captures[2]); v === nothing && (v = tryparse(Float64, m2.captures[2]))
        v === nothing || (out[m2.captures[1]] = v)
    end
    return out
end

# ── Ponts son ⟷ patterns ────────────────────────────────────────────
# Recette de librairie intégrée (pas les fichiers utilisateur) par nom.
function _synthlib_builtin_entry(name::AbstractString)
    for e in _synthlib_all_entries()
        e.name == name && e.category != "user" && return e
    end
    return nothing
end

# Le mot sous le curseur, sans le `:` d'un symbole (`s(:kick)` → kick).
function _word_under_cursor_plain(m::RessacApp)
    ed = _active_editor(m)
    ed === nothing && return ""
    1 <= ed.cursor_row <= length(ed.lines) || return ""
    chars = ed.lines[ed.cursor_row]
    isempty(chars) && return ""
    w = _word_under_cursor_chars(chars, clamp(ed.cursor_col + 1, 1, length(chars)))
    return String(lstrip(String(w), ':'))
end

_is_known_synth(name::AbstractString) =
    isfile(_app_synth_path(name; mode = :dsl)) || isfile(_app_synth_path(name; mode = :sc)) ||
    _synthlib_builtin_entry(name) !== nothing || haskey(_SYNTH_REGISTRY, Symbol(name))

"""
    _goto_synth_under_cursor!(m)

`gs` dans la pane patterns : ouvre le synth sous le curseur (fichier
utilisateur, recette de librairie ou synth enregistré) dans DESIGN.
"""
function _goto_synth_under_cursor!(m::RessacApp)
    w = _word_under_cursor_plain(m)
    if isempty(w) || !_is_known_synth(w)
        _push_app_log!(m, "[WARN] gs — « $w » n'est pas un synth connu (fichier user-synths, librairie ou synth enregistré)")
        return
    end
    _open_sound!(m, w)
    return
end

# L'éditeur patterns du workspace courant (le crée si besoin).
function _patterns_editor!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        for leaf in _all_leaves(ws.tree), (ti, tab) in enumerate(leaf.tabs)
            tab isa EditorPane || continue
            1 <= tab.current_tab <= length(tab.tabs) || continue
            if tab.tabs[tab.current_tab].role === :patterns
                ws.focused_pane = leaf.id; leaf.current_tab = ti
                return tab.tabs[tab.current_tab].code_editor
            end
        end
    end
    return _open_or_reuse_editable_pane!(m; role = "patterns", name = "main")
end

# Ajoute une ligne après la dernière ligne non vide, curseur dessus.
function _append_pattern_line!(ed::TK.CodeEditor, line::AbstractString)
    lines = collect(split(TK.text(ed), '\n'; keepempty = true))
    last = something(findlast(l -> !isempty(strip(l)), lines), 0)
    insert!(lines, last + 1, String(line))
    _edit_text!(ed, join(lines, '\n'))
    ed.cursor_row = last + 1
    ed.cursor_col = 0
    return
end

"""
    _use_synth_in_pattern!(m, name)

Pont « utiliser ce son » : bascule dans PLAY, ajoute
`@dN p"name*4"` à la fin du buffer patterns (N = premier slot libre),
focalise la ligne. L'appelant a sauvé/enregistré le synth avant.
"""
function _use_synth_in_pattern!(m::RessacApp, name::AbstractString)
    _focus_patterns!(m)
    ed = _patterns_editor!(m)
    ed === nothing && (_push_app_log!(m, "[ERROR] U — pas d'éditeur patterns"); return)
    slot = _next_free_slot(ed)
    line = "@d$slot p\"$(name)*4\""
    _append_pattern_line!(ed, line)
    ed.mode = :normal
    ed.focused = true
    _push_app_log!(m, "[INFO] $line ajouté — e pour jouer, m pour mute")
    return
end

# U sur un son : il est rangé (:save), puis un slot le joue.
function _use_current_synth_in_pattern!(m::RessacApp)
    tab = _current_sound(m)
    tab === nothing && (_push_app_log!(m, "[ERROR] U — le curseur n'est pas sur un son"); return)
    _save_sound!(m, tab) || return
    _use_synth_in_pattern!(m, tab.name)
    return
end
