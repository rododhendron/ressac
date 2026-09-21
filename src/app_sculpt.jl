# src/app_sculpt.jl
# Sculpt côté app : ouvrir une pane :waveform en mode sculpt (zoomée),
# drainer les requêtes de l'explorer (`M`) et de la pane (`U`), les
# commandes :sculpt / :w. Le studio lui-même (onde, knobs groupés,
# explication) est rendu PAR la pane (pane_waveform.jl) : c'est une pane
# comme les autres — Ctrl-w z la zoome/dézoome, Ctrl-w c la ferme.

"""
    _open_sculpt_pane!(m, gser, label) -> Bool

Ouvre le studio sculpt : une WaveformPane en mode sculpt (`gser` =
génome sérialisé) dans le workspace courant, zoomée plein écran.
"""
function _open_sculpt_pane!(m::RessacApp, gser, label::AbstractString)
    p = _place_pane!(m, :waveform,
                     Dict{String,Any}("genome" => gser, "label" => label, "sculpt" => true))
    p isa WaveformPane || return false
    ws = current_workspace(m.workspaces)
    ws === nothing || (m.zoom_leaf = ws.focused_pane)
    return true
end

"""
    _drain_explorer_sculpt!(m) -> Bool

Open the sculpt pane for a genome posted by the explorer (`M`).
"""
function _drain_explorer_sculpt!(m::RessacApp)
    req = _EXPLORER_SCULPT_REQUEST[]
    req === nothing && return false
    _EXPLORER_SCULPT_REQUEST[] = nothing
    gser, label = req
    _open_sculpt_pane!(m, gser, label)
    return true
end

# U dans une pane sculpt : la pane poste sa requête (elle ne connaît pas
# l'app) ; on sauve sous son label et on l'utilise dans un pattern (PLAY).
function _drain_sculpt_use!(m::RessacApp)
    p = _SCULPT_USE_REQUEST[]
    p === nothing && return false
    _SCULPT_USE_REQUEST[] = nothing
    p.genome === nothing && return true
    nm = replace(p.label, r"[^\w]" => "_")
    _save_sculpt!(m, nm; pane = p)
    _use_synth_in_pattern!(m, nm)
    return true
end

# ── Sculpt : :sculpt [nom] ──────────────────────────────────────────
# Ouvre un synth en mode sculpt. `:sculpt <nom>` lit
# plugins/user-synths/<nom>.jl ; `:sculpt` seul prend le buffer focalisé.
function _sculpt_command!(m::RessacApp, name::AbstractString)
    nm = strip(String(name))
    txt_for_msg = ""
    g = if isempty(nm)
        ed = _active_editor(m)
        txt_for_msg = ed === nothing ? "" : TK.text(ed)
        ed === nothing ? nothing : _genome_from_any(txt_for_msg)
    else
        path = joinpath(pwd(), "plugins", "user-synths", "$nm.jl")
        if isfile(path)
            txt_for_msg = read(path, String)
            _genome_from_any(txt_for_msg)
        else
            txt_for_msg = ""
            nothing
        end
    end
    if g === nothing
        _push_app_log!(m, "[ERROR] :sculpt — " * _sculpt_refusal(nm, txt_for_msg))
        return
    end
    # Label : le nom demandé, sinon celui du synth focalisé (→ :w et U
    # sauvent sous ce nom), sinon « buffer ».
    label = if !isempty(nm)
        nm
    else
        tab = _current_synth_tab(m)
        tab === nothing ? "buffer" : tab.name
    end
    _open_sculpt_pane!(m, serialize_genome(g), label)
    return
end
_register_literal!(m -> _sculpt_command!(m, ""), "sculpt")
_register_regex!(r"^sculpt\s+([\w.-]+)$",
    (m, mt) -> _sculpt_command!(m, mt.captures[1]))

# Génome depuis un texte : génome embarqué (exports récents) sinon DSL
# parsé ; jamais d'exception (un DSL exotique donne `nothing`).
function _genome_from_any(txt::AbstractString)
    try
        gg = genome_from_text(txt)
        gg === nothing || return gg
        # SC brut (Sig / SynthDef) : pas de graphe DSL à sculpter.
        (occursin("Sig(", txt) || occursin("SynthDef(", txt)) && return nothing
        return genome_from_dsl(txt)
    catch
        return nothing
    end
end

# Pourquoi :sculpt refuse — pour un message actionnable.
function _sculpt_refusal(nm::AbstractString, txt::AbstractString)
    isempty(nm) && isempty(txt) && return "aucun buffer à sculpter (:sculpt <nom> ou ouvre un synth DSL)"
    isempty(txt) && return "« $nm » introuvable dans plugins/user-synths (.jl)"
    occursin("Sig(", txt) && return "« $nm » est un synth SC brut (Sig) — pas sculptable ; :synth $nm pour l'éditer"
    occursin("SynthDef(", txt) && return "« $nm » est du SuperCollider brut — pas sculptable ; :synth $nm pour l'éditer"
    return "« $nm » n'est pas un DSL @synth parsable"
end

# Sauve le génome sculpté (pane focalisée, ou `pane`) en synth DSL (.jl)
# avec génome embarqué → rejouable (:synth) et re-sculptable (:sculpt).
# `name` vide = label courant.
function _save_sculpt!(m::RessacApp, name::AbstractString; pane = nothing)
    p = pane === nothing ? _focused_sculpt_pane(m) : pane
    (p === nothing || p.genome === nothing) &&
        (_push_app_log!(m, "[ERROR] :w — pas de sculpt actif"); return)
    nm = strip(String(name))
    isempty(nm) && (nm = replace(p.label, r"[^\w]" => "_"))
    sym = Symbol(nm)
    dsl = render_dsl(p.genome, sym) * "\n" * genome_comment(p.genome) * "\n"
    path = _app_synth_path(nm; mode = :dsl)
    isdir(dirname(path)) || mkpath(dirname(path))
    write(path, dsl)
    register_synth!(SynthEntry(sym, "user-synths",
        Dict{String,Any}("description" => "sculpted synth",
                         "tags" => ["user", "dsl", "sculpt"],
                         "params" => Dict{String,Any}(String(k) => v for (k, v) in p.genome.controls))))
    p.label = nm
    _push_app_log!(m, "[INFO] sculpt sauvé → $path")
    return
end
