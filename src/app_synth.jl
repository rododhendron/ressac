# src/app_synth.jl
# Panes synth : ouvrir (librairie/user/starter), fermer, cycler, sauver,
# tester (T avec accélération), aligner le nom du synthdef ; bascule de
# focus patterns ⟷ synth.

"""
    _swap_focus!(m)

Toggle workspace focus between the patterns pane and a synth pane.
From patterns → focus the first synth pane (if any). From a synth
pane → focus the patterns pane. Bound to Tab in normal mode.
"""
function _swap_focus!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    if _focused_role(m) === :synth
        # Back to the patterns pane.
        for leaf in _all_leaves(ws.tree)
            for tab in leaf.tabs
                if tab isa EditorPane && !isempty(tab.tabs) &&
                   tab.tabs[tab.current_tab].role === :patterns
                    ws.focused_pane = leaf.id
                    return
                end
            end
        end
    else
        # Into the first synth pane.
        syn = _all_synth_buffers(m)
        isempty(syn) || (ws.focused_pane = syn[1][1].id)
    end
end

"""
    _STARTER_DSL(name)

Default body for a fresh sandbox / unnamed synth tab in DSL mode.
"""
_STARTER_DSL(name) = """
# T = tester  ·  D = drone (moduler en direct)  ·  :w <nom> = sauver sous  ·  U = utiliser dans un pattern  ·  :dsl = guide du DSL

@synth :$(name) (freq=220, sustain=0.5) sin_osc(:freq)
"""

"""
    _open_sandbox_synth!(m)

Open a fresh synth tab with a randomised name (`sketch_<id>`) and
the starter template — no manual naming needed. The user iterates
in the tab; `:w realname` later renames it onto disk via the
existing save-as path.
"""
function _open_sandbox_synth!(m::RessacApp)
    # 3-char base36 id, e.g. "sketch_a7p". Cheap, collision-resistant
    # enough for interactive use; if it ever does collide
    # _open_synth_tab! switches to the existing tab which is also fine.
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    id = String([chars[rand(1:length(chars))] for _ in 1:3])
    name = "sketch_$(id)"
    _open_synth_tab!(m, name)
    _push_app_log!(m, "[INFO] synth bac à sable « $name » — :w <nom> pour le sauver sous un vrai nom")
end

"""
    _open_synth_tab!(m, name)

If a synth pane for `name` is already open in the workspace, focus
it. Otherwise vsplit a new synth-role EditorPane, load the source
(DSL `.jl` preferred, else raw `.scd`, else starter template), and
focus it. Synths are plain workspace panes now — no separate tab
list.
"""
function _open_synth_tab!(m::RessacApp, name::AbstractString)
    name = String(name)
    _open_volet!(m, :son)
    ws = current_workspace(m.workspaces)
    # Already open → focus its leaf.
    if ws !== nothing
        for leaf in _all_leaves(ws.tree), pane in leaf.tabs
            pane isa EditorPane || continue
            i = findfirst(b -> b.role === :synth && b.name == name, pane.tabs)
            i === nothing && continue
            pane.current_tab = i
            ws.focused_pane = leaf.id
            _push_app_log!(m, "[INFO] synth « $name » focalisé")
            return
        end
    end
    # Le texte : le `.jl` s'il existe ; sinon un `.scd` laissé là, converti en
    # DSL à l'ouverture (tout son s'édite en DSL) ; sinon une recette de la
    # librairie, copiée ; sinon le point de départ.
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
        origin = "converti depuis $(name).scd (:w le range en .jl)"
        "# converti depuis $(name).scd\n\n" * _align_dsl_synth_name(dsl, name)
    else
        _STARTER_DSL(name)
    end
    wsed = _synth_workspace_editor(m)
    if wsed !== nothing
        # Un onglet de plus dans le texte du volet ; la DOC et le studio
        # suivent (synchronisation au rendu).
        eb = EditorBuffer(; role = :synth, name = name, content = src)
        push!(wsed.tabs, eb)
        wsed.current_tab = length(wsed.tabs)
        _focus_pane!(m, wsed)
    else
        pane = _place_pane!(m, :editor, Dict{String,Any}(
            "buffer_role" => "synth",
            "name"        => name,
        ))
        pane isa EditorPane || return
        eb = pane.tabs[1]
        _load_text!(eb.code_editor, src)
    end
    eb.code_editor.mode = :normal
    eb.code_editor.focused = true
    _push_app_log!(m, "[INFO] synth « $name » $origin — T teste, :w sauve, U l'utilise dans un pattern")
end


"""
    _close_active_synth_tab!(m)

Close the focused synth pane (or the first synth pane if focus
drifted off one). No-op when no synth pane is open.
"""
function _close_active_synth_tab!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    buf = _focused_buffer(m)
    leaf_id = if buf !== nothing && buf.role === :synth
        # Focused leaf is a synth — close it.
        ws.focused_pane
    else
        syn = _all_synth_buffers(m)
        isempty(syn) && return
        syn[1][1].id
    end
    leaf = _find_leaf_by_id(ws.tree, leaf_id)
    pane = (leaf isa PaneLeaf && !isempty(leaf.tabs)) ? leaf.tabs[leaf.current_tab] : nothing
    if pane isa EditorPane && 1 <= pane.current_tab <= length(pane.tabs) &&
       (length(pane.tabs) > 1 || _synth_workspace_editor(m) === pane)
        # Plusieurs onglets : on ferme le courant, la pane reste. Dans le
        # workspace synth, le dernier onglet laisse place à un sketch neuf
        # pour que la forme du workspace tienne.
        cur = pane.tabs[pane.current_tab]
        name = cur.name
        deleteat!(pane.tabs, pane.current_tab)
        if isempty(pane.tabs)
            fresh = EditorBuffer(; role = :synth, name = "sketch", content = _STARTER_DSL("sketch"))
            fresh.code_editor.mode = :normal
            push!(pane.tabs, fresh)
        end
        pane.current_tab = clamp(pane.current_tab, 1, length(pane.tabs))
        pane.tabs[pane.current_tab].code_editor.focused = true
        _drone_release_buffer!(m, name)
        _push_app_log!(m, "[INFO] synth « $name » fermé")
        return
    end
    name = (b = _leaf_synth_name(m, leaf_id)) === nothing ? "?" : b
    ws.focused_pane = leaf_id
    cmd_close!(m.workspaces)
    _drone_release_buffer!(m, name)
    _push_app_log!(m, "[INFO] synth « $name » fermé")
end

_leaf_synth_name(m::RessacApp, leaf_id::Int) = begin
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    leaf = _find_leaf_by_id(ws.tree, leaf_id)
    (leaf isa PaneLeaf && !isempty(leaf.tabs)) || return nothing
    pane = leaf.tabs[1]
    (pane isa EditorPane && !isempty(pane.tabs)) || return nothing
    pane.tabs[1].name
end

"""
    _cycle_synth_tab!(m; dir=+1)

Focus the next (`dir=+1`) / previous (`dir=-1`) synth pane in the
workspace. No-op when fewer than two synth panes are open.
"""
function _cycle_synth_tab!(m::RessacApp; dir::Int = +1)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    # Des onglets dans une même pane : on tourne dedans.
    wsed = _synth_workspace_editor(m)
    if wsed !== nothing && length(wsed.tabs) > 1
        wsed.current_tab = mod1(wsed.current_tab + dir, length(wsed.tabs))
        wsed.tabs[wsed.current_tab].code_editor.focused = true
        _focus_pane!(m, wsed)
        return
    end
    syn = _all_synth_buffers(m)
    length(syn) <= 1 && return
    cur = findfirst(((leaf, _),) -> leaf.id == ws.focused_pane, syn)
    cur = cur === nothing ? 1 : cur
    nxt = mod(cur + dir - 1, length(syn)) + 1
    ws.focused_pane = syn[nxt][1].id
end

function _list_synth_tabs!(m::RessacApp)
    syn = _all_synth_buffers(m)
    if isempty(syn)
        _push_app_log!(m, "[INFO] aucune pane synth ouverte")
        return
    end
    ws = current_workspace(m.workspaces)
    for (leaf, buf) in syn
        marker = (ws !== nothing && leaf.id == ws.focused_pane) ? "▶" : " "
        _push_app_log!(m, "  $marker $(buf.name)")
    end
end

"""
    _save_current_synth!(m; new_name=nothing)

Range le texte du son dans `plugins/user-synths/<nom>.jl`. Avec
`new_name`, sous ce nom-là, et l'éditeur passe sur la nouvelle identité
(le `@synth :ancien` est réécrit). Un texte resté en SuperCollider n'est
pas rangé : `:todsl` d'abord.
"""
function _save_current_synth!(m::RessacApp; new_name::Union{Nothing,AbstractString}=nothing)
    _synth_pane_open(m) || (_push_app_log!(m, "[ERROR] :w — aucun synth ouvert"); return)
    tab = _current_synth_tab(m)
    text = TK.text(tab.code_editor)
    if _is_raw_synthdef(text)
        _push_app_log!(m, "[ERROR] :w — ce texte est du SuperCollider ; :todsl le convertit, puis :w le range")
        return
    end
    name = new_name === nothing ? tab.name : String(new_name)
    dir = joinpath(_project_dir(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    text = _align_dsl_synth_name(text, name)
    new_name === nothing && _edit_text!(tab.code_editor, text)
    path = _app_synth_path(name; mode = :dsl)
    write(path, text)
    register_synth!(SynthEntry(Symbol(name), "user-synths",
        Dict{String,Any}("description" => "live-edited synth",
                         "tags" => ["user", "dsl"],
                         "params" => _dsl_params_from_text(text))); update = true)
    _push_app_log!(m, "[INFO] synth sauvé → $path")
    new_name === nothing || _open_synth_tab!(m, name)
    return
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
    _synth_pane_open(m) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    tab = _current_synth_tab(m)
    # Le synth tourne en drone : T le réévalue (nouveau nœud, mêmes réglages).
    if _editor_drone(m) !== nothing
        _drone_launch!(m, tab)
        return
    end
    _audition_synth_text!(m, tab, TK.text(tab.code_editor))
    return
end

"""
    _audition_synth_text!(m, tab, src; what = "T — test de") -> Bool

Fait entendre le texte `src` comme le son de l'onglet `tab` : c'est `T`, et
c'est aussi l'essai d'un maillon dans l'atelier (le texte essayé n'est pas
encore dans le buffer). Vrai si le son est parti.

Le nom du @synth est celui de l'onglet ; le texte s'évalue dans SynthDSL
(saw, sin_osc, rlpf… y sont des UGens, pas les signaux de patterns du même
nom), en entier. Le @synth compile en SC et envoie lui-même à
/ressac/evalAndPlay.
"""
function _audition_synth_text!(m::RessacApp, tab::EditorBuffer, src::AbstractString;
                               what::AbstractString = "T — test de")
    _LIVE_SCHEDULER[] === nothing && return false
    if _is_raw_synthdef(src)
        _push_app_log!(m, "[INFO] ce texte est du SuperCollider — :todsl le convertit en DSL, puis T le joue")
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
function _synth_pitch_info(tab::EditorBuffer)
    src = TK.text(tab.code_editor)
    params = _dsl_params_from_text(src)
    entry = synth_info(Symbol(tab.name))
    explicit = entry === nothing ? nothing : get(entry.metadata, "pitch", nothing)
    pitch = explicit isa AbstractString && !isempty(explicit) ? Symbol(explicit) :
            haskey(params, "freq") ? :freq : nothing
    return (pitch = pitch, sustain = haskey(params, "sustain"), params = params)
end

# Suffixe du titre de la pane : « hauteur freq · durée sustain » / « sans hauteur ».
function _synth_title_suffix(tab::EditorBuffer)
    info = _synth_pitch_info(tab)
    h = info.pitch === nothing ? "sans hauteur" : "hauteur $(info.pitch)"
    d = info.sustain ? " · durée sustain" : ""
    return h * d
end

const _NOTE_NAMES = ("c", "cs", "d", "ds", "e", "f", "fs", "g", "gs", "a", "as", "b")
# Nom Tidal d'une note en demi-tons (0 = c5) : -12 → c4, 7 → g5.
_note_name(n::Int) = _NOTE_NAMES[mod(n, 12) + 1] * string(5 + fld(n, 12))

# Paires clé/valeur pour jouer le synth du buffer à la note d'audition.
function _audition_args(m::RessacApp, tab::EditorBuffer, src::AbstractString)
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
    _open_volet!(m, :son)
    _open_synth_tab!(m, w)
    return
end

# Y a-t-il une pane patterns dans le workspace courant ?
function _patterns_pane_present(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    for leaf in _all_leaves(ws.tree), tab in leaf.tabs
        tab isa EditorPane && 1 <= tab.current_tab <= length(tab.tabs) &&
            tab.tabs[tab.current_tab].role === :patterns && return true
    end
    return false
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

# U depuis une pane synth : sauve (:w) puis utilise.
function _use_current_synth_in_pattern!(m::RessacApp)
    tab = _current_synth_tab(m)
    tab === nothing && (_push_app_log!(m, "[ERROR] U — pas de synth ouvert"); return)
    _save_current_synth!(m)
    _use_synth_in_pattern!(m, tab.name)
    return
end
