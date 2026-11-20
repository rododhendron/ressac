# src/app_son.jl
# La DOC d'un son (fiche du mot · explication · graphe) : elle s'ouvre à
# droite, relit le bloc `@synth` du curseur dès qu'il change (hors frappe)
# et en tire l'explication et le graphe. Le texte, lui, reste à gauche.

# La DOC du son, si elle est à l'écran.
_sound_doc(m::RessacApp) = _find_pane(m, SynthDocPane)

"""
    _sound_doc_sync!(m)

À chaque image : la DOC relit le texte du son du curseur quand il a changé
et qu'on n'est pas en train de taper.
"""
function _sound_doc_sync!(m::RessacApp)
    sdoc = _sound_doc(m)
    sdoc === nothing && return
    snd = _current_sound(m)
    snd === nothing && return
    snd.code_editor.mode === :normal || return
    text = _sound_text(snd)
    h = hash(text)
    (h == sdoc.synced_hash && snd.name == sdoc.synced_name) && return
    _synthdoc_set_genome!(sdoc, _genome_from_any(text))
    sdoc.synced_hash = h
    sdoc.synced_name = snd.name
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
        _push_app_log!(m, "[INFO] $(label) est dans le texte, sous le nom « $name » — e le fait entendre, s(\"$name\") le joue, :save le range")
    return true
end

# ── Les gestes du son, depuis son texte ou sa DOC ────────────────────

_design_use_in_pattern!(m::RessacApp) = _use_current_synth_in_pattern!(m)

# `P` : mesurer ce que chaque étape du son change — l'explication le dit.
function _design_measure_impacts!(m::RessacApp)
    _current_sound(m) === nothing && (_push_app_log!(m, "[INFO] élagage : pose le curseur sur un son (@synth)"); return)
    _open_volet!(m, :son; focus = false)
    _sound_doc_sync!(m)
    sdoc = _sound_doc(m)
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
    _current_sound(m) === nothing && (_push_app_log!(m, "[INFO] la DOC d'un son : pose le curseur sur un bloc @synth"); return)
    # Elle s'ouvre à droite ; le clavier reste dans le texte.
    _sound_doc(m) === nothing && _open_volet!(m, :son; focus = false)
    sdoc = _sound_doc(m)
    sdoc === nothing && return
    _sound_doc_sync!(m)
    sdoc.mode = mode
    ws = current_workspace(m.workspaces)
    for leaf in _all_leaves(ws.tree)
        i = findfirst(t -> t === sdoc, leaf.tabs)
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
    _current_sound(m) === nothing &&
        (_push_app_log!(m, "[WARN] :prune — pose le curseur sur un son (gs sur son nom l'amène dans le texte)"); return)
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
    tab = _current_sound(m)
    tab === nothing && return
    ed = tab.code_editor
    text = _sound_text(tab)
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
        _sound_write!(tab, replace_synth_block(text, render_dsl(g, Symbol(tab.name))); col = 0)
        _push_app_log!(m, "[INFO] :prune — $(length(removed)) nœud$(plural(length(removed))) retiré$(plural(length(removed))) d'après la structure ($(join(("#$id" for id in removed), " "))) · mesure en cours…")
    else
        _push_app_log!(m, "[INFO] :prune — rien de suspect dans la structure · mesure en cours…")
    end
    # 2. Ce que la mesure désigne : un rendu sclang hors-ligne, en fond (il
    #    prend des secondes — on continue à jouer). Le résultat n'est
    #    appliqué que si le texte est encore celui qu'on a mesuré.
    after_static = _sound_text(tab)
    measured_g = _copy_genome(g)
    _background!(() -> measure_impacts(measured_g)) do imps, err
        if err !== nothing
            _push_app_log!(m, "[INFO] :prune — mesure indisponible : $(first(sprint(showerror, err), 80))" *
                              (isempty(removed) ? "" : " — T pour écouter, :save pour ranger"))
            return
        end
        if _sound_text(tab) != after_static
            _push_app_log!(m, "[WARN] :prune — le texte a changé pendant la mesure : rien de plus n'est retiré, relance :prune")
            return
        end
        measured = prune!(g, imps; threshold = thr)
        if isempty(measured)
            _push_app_log!(m, isempty(removed) ? "[INFO] :prune — rien sous $thr, tout s'entend" :
                                                 "[INFO] :prune — rien de plus sous $thr — T pour écouter, :save pour ranger")
            return
        end
        _sound_write!(tab, replace_synth_block(after_static, render_dsl(g, Symbol(tab.name))); col = 0)
        _push_app_log!(m, "[INFO] :prune — $(length(measured)) nœud$(plural(length(measured))) inaudible$(plural(length(measured))) retiré$(plural(length(measured))) ($(join(("#$id" for id in measured), " "))) — T pour écouter, :save pour ranger")
    end
    return
end

# ── :todsl ───────────────────────────────────────────────────────────
# Tout son s'écrit en DSL : un `.scd` laissé dans la réserve est converti
# quand on l'amène dans le texte (`gs`, `:synth nom`). `:todsl <nom>` le dit.
function _todsl_command!(m::RessacApp)
    _push_app_log!(m, "[INFO] :todsl — un son en SuperCollider est converti quand on l'ouvre : :synth <nom> (ou gs sur son nom)")
    return
end
