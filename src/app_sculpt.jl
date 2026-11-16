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
    # Le candidat se travaille dans DESIGN : son texte en onglet, le studio
    # (focalisé) et l'explication le suivent.
    name = replace(strip(replace(label, r"\s*#\s*" => "_")), r"[^\w]" => "_")
    g = deserialize_genome(gser)
    _open_synth_text_in_design!(m, name, _explorer_export_text(g, name); focus_studio = true)
    _push_app_log!(m, "[INFO] $(label) dans DESIGN — le studio suit le texte, :w sauve, U l'utilise dans un pattern")
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
    parts = _synth_workspace_parts(m)
    if parts !== nothing
        # Workspace synth : le studio suit déjà le texte — on l'y amène.
        isempty(nm) || _open_synth_tab!(m, nm)
        _synth_workspace_sync!(m)
        _focus_pane!(m, parts[2])
        _push_app_log!(m, "[INFO] studio : h/l tirent un knob et le texte suit · Ctrl-w h revient au texte")
        return
    end
    txt_for_msg = ""
    g = if isempty(nm)
        ed = _active_editor(m)
        txt_for_msg = ed === nothing ? "" : TK.text(ed)
        ed === nothing ? nothing : _genome_from_any(txt_for_msg)
    else
        path = joinpath(_project_dir(), "plugins", "user-synths", "$nm.jl")
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

# `:prune [seuil]` — dans le studio sculpt, retire les nœuds dont l'impact
# mesuré (P) est sous le seuil (0.02 par défaut).
function _prune_command!(m::RessacApp, arg::AbstractString)
    thr = isempty(strip(arg)) ? 0.02 : something(tryparse(Float64, strip(arg)), 0.02)
    p = _focused_sculpt_pane(m)
    if p === nothing
        _focused_role(m) === :synth && return _prune_synth_buffer!(m, thr)
        _push_app_log!(m, "[WARN] :prune — dans un studio sculpt (:sculpt, M) ou une pane synth DSL")
        return
    end
    if isempty(p.impacts)
        _push_app_log!(m, p.measuring ? "[INFO] :prune — la mesure est en cours, réessaie dans un instant" :
                                        "[WARN] :prune — mesure d'abord l'impact des nœuds avec P")
        return
    end
    n = _sculpt_prune!(p; threshold = thr)
    _push_app_log!(m, n == 0 ? "[INFO] :prune — rien sous $thr, tout s'entend" :
                              "[INFO] :prune — $n nœud$(n > 1 ? "s" : "") retiré$(n > 1 ? "s" : "") (impact < $thr) · P pour remesurer")
    return
end
_register_literal!(m -> _prune_command!(m, ""), "prune")
_register_regex!(r"^prune\s+([0-9.]+)$", (m, mt) -> _prune_command!(m, mt.captures[1]))
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
    # Un DSL qui ne se relit pas entièrement : on dit ce qui a manqué plutôt
    # que de sculpter un son amputé.
    (_, why) = parse_dsl_synth(txt)
    return "« $nm » ne se relit pas en entier — $why"
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
                         "params" => Dict{String,Any}(String(k) => v for (k, v) in p.genome.controls)));
                    update = true)
    p.label = nm
    _push_app_log!(m, "[INFO] sculpt sauvé → $path")
    return
end

"""
    _prune_synth_buffer!(m, thr)

`:prune` dans une pane synth DSL : le génome du texte, les nœuds que la
structure désigne, puis — si sclang répond — ceux dont l'impact mesuré
est sous `thr` ; le bloc `@synth` est réécrit (forme canonique, le reste
du fichier intact). Le journal dit ce qui est parti.
"""
function _prune_synth_buffer!(m::RessacApp, thr::Real)
    tab = _current_synth_tab(m)
    tab === nothing && return
    ed = tab.code_editor
    text = TK.text(ed)
    (g, why) = parse_dsl_synth(text)
    g === nothing && (_push_app_log!(m, "[WARN] :prune — le buffer ne se relit pas en entier, rien n'est touché : $why"); return)
    plural(n) = n > 1 ? "s" : ""
    # 1. Ce que la structure désigne : immédiat.
    removed = static_prune!(g)
    if !isempty(removed)
        _edit_text!(ed, replace_synth_block(text, render_dsl(g, Symbol(tab.name))); col = 0)
        _push_app_log!(m, "[INFO] :prune — $(length(removed)) nœud$(plural(length(removed))) retiré$(plural(length(removed))) d'après la structure ($(join(("#$id" for id in removed), " "))) · mesure en cours…")
    else
        _push_app_log!(m, "[INFO] :prune — rien de suspect dans la structure · mesure en cours…")
    end
    # 2. Ce que la mesure désigne : un rendu sclang hors-ligne, en fond (il
    #    prend des secondes — on continue à jouer). Le résultat n'est
    #    appliqué que si le texte est encore celui qu'on a mesuré.
    after_static = TK.text(ed)
    measured_g = _copy_genome(g)
    _background!(() -> measure_impacts(measured_g)) do imps, err
        if err !== nothing
            _push_app_log!(m, "[INFO] :prune — mesure indisponible : $(first(sprint(showerror, err), 80))" *
                              (isempty(removed) ? "" : " — T pour écouter, :w pour sauver"))
            return
        end
        if TK.text(ed) != after_static
            _push_app_log!(m, "[WARN] :prune — le texte a changé pendant la mesure : rien de plus n'est retiré, relance :prune")
            return
        end
        measured = prune!(g, imps; threshold = thr)
        if isempty(measured)
            _push_app_log!(m, isempty(removed) ? "[INFO] :prune — rien sous $thr, tout s'entend" :
                                                 "[INFO] :prune — rien de plus sous $thr — T pour écouter, :w pour sauver")
            return
        end
        _edit_text!(ed, replace_synth_block(after_static, render_dsl(g, Symbol(tab.name))); col = 0)
        _push_app_log!(m, "[INFO] :prune — $(length(measured)) nœud$(plural(length(measured))) inaudible$(plural(length(measured))) retiré$(plural(length(measured))) ($(join(("#$id" for id in measured), " "))) — T pour écouter, :w pour sauver")
    end
    return
end

# ── :todsl — un SynthDef SC brut devient du DSL ──────────────────────
function _todsl_command!(m::RessacApp)
    tab = _current_synth_tab(m)
    tab === nothing && (_push_app_log!(m, "[ERROR] :todsl — ouvre d'abord un synth (:synth <nom>)"); return)
    ed = tab.code_editor
    text = TK.text(ed)
    if tab.synth_mode === :dsl && !occursin("SynthDef(", text)
        _push_app_log!(m, "[INFO] :todsl — « $(tab.name) » est déjà en DSL")
        return
    end
    (r, why) = synthdef_to_dsl_reason(text)
    if r === nothing
        _push_app_log!(m, "[ERROR] :todsl — « $(tab.name) » n'est pas converti, le texte reste tel quel : $why")
        return
    end
    (_, dsl) = r
    header = "# converti depuis SuperCollider par :todsl — T teste, :w sauve en .jl, u annule\n\n"
    _edit_text!(ed, header * _align_dsl_synth_name(dsl, tab.name); row = 3, col = 0)
    tab.synth_mode = :dsl
    _push_app_log!(m, "[INFO] :todsl — « $(tab.name) » en DSL : le studio suit, T teste, :w sauve en .jl (u annule)")
    return
end
