# src/app_drone.jl
# Drone depuis l'éditeur de synth : D lance le synth du buffer en drone
# (variante à porte) et ouvre la pane MODULATION ; T réévalue le drone
# vivant ; D de nouveau le relâche. Les fermetures, hush et panic
# relâchent ce qu'il faut.

_drone_id(tab::EditorBuffer) = Symbol(tab.name)

# Le drone du buffer synth focalisé, s'il tourne (lancé par l'éditeur).
function _editor_drone(m::RessacApp)
    tab = _current_synth_tab(m)
    tab === nothing && return nothing
    d = drone_get(_drone_id(tab))
    (d !== nothing && d.origin === :editor) ? d : nothing
end

"""
    _drone_toggle!(m)

`D` dans une pane synth : lance le synth en drone, ou le relâche s'il
tourne déjà.
"""
function _drone_toggle!(m::RessacApp)
    tab = _current_synth_tab(m)
    tab === nothing && return
    d = drone_get(_drone_id(tab))
    if d !== nothing
        rel = get(d.values, :release, 0.1)
        drone_stop!(d.id)
        _push_app_log!(m, "[INFO] drone $(d.id) relâché (release $(round(rel; digits = 2)) s)")
        return
    end
    _drone_launch!(m, tab)
end

"""
    _drone_launch!(m, tab)

Évalue le buffer avec la capture drone (rien n'est joué), puis démarre
le nœud avec les valeurs déjà réglées si le drone tournait, ou les
défauts du synth. Ouvre la pane MODULATION si elle manque.
"""
function _drone_launch!(m::RessacApp, tab::EditorBuffer)
    if _LIVE_SCHEDULER[] === nothing
        _push_app_log!(m, "[ERROR] drone : pas de serveur SuperCollider")
        return
    end
    if tab.synth_mode !== :dsl
        _push_app_log!(m, "[INFO] le drone demande un synth DSL (@synth) — un SynthDef brut se teste avec T")
        return
    end
    src = _align_dsl_synth_name(TK.text(tab.code_editor), tab.name)
    cap = Any[]
    _DRONE_CAPTURE[] = cap
    try
        Core.eval(SynthDSL, SynthDSL._dsl_parse_all(src))
    catch err
        _push_app_log!(m, "[ERROR] éval DSL : $(sprint(showerror, err))")
        return
    finally
        _DRONE_CAPTURE[] = nothing
    end
    if isempty(cap)
        _push_app_log!(m, "[ERROR] drone : aucun @synth dans le buffer")
        return
    end
    (sc_name, dsrc, eff) = cap[end]
    names, defaults = drone_params(eff)
    id = _drone_id(tab)
    prev = drone_get(id)
    values = prev === nothing ? copy(defaults) : copy(prev.values)
    # La note d'audition (:note) fixe la hauteur de départ.
    extra = _audition_args(m, tab, src)
    if length(extra) == 2 && Symbol(extra[1]) in names && prev === nothing
        values[Symbol(extra[1])] = Float64(extra[2])
    end
    drone_start!(id, sc_name, SynthDSL.drone_def_name(sc_name), dsrc, names, defaults;
                 values = values, origin = :editor)
    p = _drone_pane!(m)
    p === nothing || (p.current = something(findfirst(d -> d.id === id, drone_list()), 1))
    if prev === nothing
        _push_app_log!(m, "[INFO] drone $(id) ▶ — MODULATION : j/k choisir, h/l moduler, = saisir · T réévalue · D relâche")
    else
        _push_app_log!(m, "[INFO] drone $(id) réévalué — les réglages sont gardés")
    end
    return
end

# La pane MODULATION, ouverte à côté si elle manque (le focus revient à
# l'éditeur : on module au clavier depuis la pane, on édite depuis le texte).
function _drone_pane!(m::RessacApp)
    p = _find_pane(m, DronePane)
    p !== nothing && return p
    ed_pane = _focused_pane_impl(m)
    p = _place_pane!(m, :drone, Dict{String,Any}())
    p isa DronePane || return nothing
    ed_pane isa PaneImpl && _focus_pane!(m, ed_pane)
    return p
end

# Relâche le drone d'un buffer synth qu'on ferme.
function _drone_release_buffer!(m::RessacApp, name::AbstractString)
    d = drone_get(Symbol(name))
    (d === nothing || d.origin !== :editor) && return
    drone_stop!(d.id)
    _push_app_log!(m, "[INFO] drone $(d.id) relâché avec sa pane")
end

# Draine la requête postée par la pane MODULATION (T = réévaluer).
function _drain_drone_request!(m::RessacApp)
    req = _DRONE_PANE_REQUEST[]
    req === nothing && return false
    _DRONE_PANE_REQUEST[] = nothing
    (what, id) = req
    what === :reeval || return true
    d = drone_get(id)
    d === nothing && return true
    if d.origin === :slot
        _push_app_log!(m, "[INFO] drone $(id) : tenu par PLAY — réévalue son pattern (@$(id)) pour le changer")
        return true
    end
    for (_, buf) in _all_synth_buffers(m)
        buf.name == String(id) || continue
        _drone_launch!(m, buf)
        return true
    end
    _push_app_log!(m, "[WARN] drone $(id) : son texte n'est plus ouvert — D dans l'éditeur le relance")
    return true
end
