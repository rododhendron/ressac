# src/app_son.jl
# Le volet d'un son : son texte, et dessous sa DOC. Un seul son derrière les
# deux — la DOC relit le texte dès qu'il change (hors frappe) et en tire
# l'explication et le graphe. Ouvrir un autre son ajoute un onglet au texte.

"""
    _synth_workspace_parts(m) -> (editor, doc) | nothing

La pane qui porte les textes de sons et sa DOC, dans l'écran courant.
`nothing` quand aucun son n'est ouvert ; `doc` peut manquer (`nothing`).
"""
function _synth_workspace_parts(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    ep = nothing; sdoc = nothing
    for leaf in _all_leaves(ws.tree), tab in leaf.tabs
        if tab isa EditorPane && ep === nothing && any(b -> b.role === :synth, tab.tabs)
            ep = tab
        elseif tab isa SynthDocPane && sdoc === nothing
            sdoc = tab
        end
    end
    ep === nothing && return nothing
    return (ep, sdoc)
end

# Le son courant de la pane texte (onglet courant).
function _synth_workspace_tab(ep::EditorPane)
    1 <= ep.current_tab <= length(ep.tabs) || return nothing
    tab = ep.tabs[ep.current_tab]
    tab.role === :synth ? tab : nothing
end

# La pane texte des sons, pour y ajouter un onglet.
function _synth_workspace_editor(m::RessacApp)
    parts = _synth_workspace_parts(m)
    parts === nothing ? nothing : parts[1]
end

"""
    _synth_workspace_sync!(m)

À chaque image : la DOC relit le texte du son quand il a changé et qu'on
n'est pas en train de taper.
"""
function _synth_workspace_sync!(m::RessacApp)
    parts = _synth_workspace_parts(m)
    parts === nothing && return
    (ep, sdoc) = parts
    sdoc === nothing && return
    tab = _synth_workspace_tab(ep)
    tab === nothing && return
    ed = tab.code_editor
    ed.mode === :normal || return
    text = TK.text(ed)
    h = hash(text)
    (h == sdoc.synced_hash && tab.name == sdoc.synced_name) && return
    _synthdoc_set_genome!(sdoc, _genome_from_any(text))
    sdoc.synced_hash = h
    sdoc.synced_name = tab.name
    return
end

# `M` dans l'explorateur : le candidat s'écrit dans le texte principal.
function _drain_explorer_sculpt!(m::RessacApp)
    req = _EXPLORER_SCULPT_REQUEST[]
    req === nothing && return false
    _EXPLORER_SCULPT_REQUEST[] = nothing
    gser, label = req
    name = replace(strip(replace(label, r"\s*#\s*" => "_")), r"[^\w]" => "_")
    g = deserialize_genome(gser)
    _insert_sound_block!(m, name, _explorer_export_text(g, name)) &&
        _push_app_log!(m, "[INFO] $(label) est dans le texte, sous le nom « $name » — e le fait entendre, s(\"$name\") le joue, :keep le range")
    return true
end

# ── Les gestes du son, depuis son texte ou sa DOC ────────────────────

_design_use_in_pattern!(m::RessacApp) = _use_current_synth_in_pattern!(m)

# `P` : mesurer ce que chaque étape du son change — l'explication le dit.
function _design_measure_impacts!(m::RessacApp)
    _synth_workspace_sync!(m)
    parts = _synth_workspace_parts(m)
    sdoc = parts === nothing ? nothing : parts[2]
    if sdoc === nothing || sdoc.genome === nothing
        _push_app_log!(m, "[INFO] élagage : il faut un @synth qui se relit")
        return
    end
    _synthdoc_measure_impacts!(sdoc)
    sdoc.mode = :explain
    _push_app_log!(m, "[INFO] mesure de l'impact de chaque étape… (l'explication la donnera ; :prune retire ce qui ne s'entend pas)")
    return
end

# K / X / Y : la DOC sur la fiche du mot, l'explication, le graphe — et
# devant, si une autre pane (la MODULATION) la cachait.
function _design_doc_mode!(m::RessacApp, mode::Symbol)
    parts = _synth_workspace_parts(m)
    if parts === nothing || parts[2] === nothing
        _push_app_log!(m, "[INFO] pas de DOC à l'écran — :son la remet")
        return
    end
    _synth_workspace_sync!(m)
    parts[2].mode = mode
    ws = current_workspace(m.workspaces)
    for leaf in _all_leaves(ws.tree)
        i = findfirst(t -> t === parts[2], leaf.tabs)
        i === nothing || (leaf.current_tab = i)
    end
    return
end

function _design_doc_tab!(m::RessacApp)
    _design_doc_mode!(m, :doc)
    _doc_under_cursor!(m)
end

# Les gestes de l'explorateur (T entendre, D drone) visent l'explorateur de
# l'écran, que le clavier soit dessus ou sur une pane voisine.
function _explore_pane(m::RessacApp)
    p = _focused_pane_impl(m)
    p isa SynthExplorerPane && return p
    return _find_pane(m, SynthExplorerPane)
end
function _explore_play!(m::RessacApp)
    p = _explore_pane(m)
    p === nothing && (_push_app_log!(m, "[INFO] pas d'explorateur ici — gx"); return)
    _explorer_play_focus!(p)
end
function _explore_drone!(m::RessacApp)
    p = _explore_pane(m)
    p === nothing && (_push_app_log!(m, "[INFO] pas d'explorateur ici — gx"); return)
    _explorer_toggle_drone!(p)
end

# ── Relire un son, l'élaguer, le convertir ───────────────────────────

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

# `:prune [seuil]` — retire du son ce qui ne s'y entend pas (0.02 par défaut).
function _prune_command!(m::RessacApp, arg::AbstractString)
    thr = isempty(strip(arg)) ? 0.02 : something(tryparse(Float64, strip(arg)), 0.02)
    _current_synth_tab(m) === nothing &&
        (_push_app_log!(m, "[WARN] :prune — ouvre d'abord un son (gs sur son nom, :synth <nom>)"); return)
    return _prune_synth_buffer!(m, thr)
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
    # Élaguer réécrit le texte depuis son graphe, qui ne sait pas dire
    # « le même signal » : un `shared` y redeviendrait deux signaux.
    occursin(r"\bshared\(", text) &&
        (_push_app_log!(m, "[WARN] :prune — ce son lit un signal partagé (shared) : le réécrire en ferait deux signaux, rien n'est touché"); return)
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
    if !_is_raw_synthdef(text)
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
    _push_app_log!(m, "[INFO] :todsl — « $(tab.name) » en DSL : T teste, :w sauve en .jl (u annule)")
    return
end
