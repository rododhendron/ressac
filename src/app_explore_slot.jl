# src/app_explore_slot.jl
# Explorer SUR un slot : « trouve-moi un autre son pour cette ligne ».
#
# `gx` sur une ligne `@dN` qui joue ouvre l'explorateur ; le candidat du
# curseur joue alors DANS le pattern, à la place du son de la ligne — on
# choisit un son dans son contexte, pas dans le vide. `Entrée` l'adopte (le
# son est rangé et la ligne réécrite) ; sortir autrement rend le son
# d'origine.

# Pour le titre de l'explorateur (la pane ne connaît pas l'app).
const _EXPLORER_SLOT_LABEL = Ref("")

"""
    _with_sound(p, to) -> Pattern

Le même pattern, dont chaque événement joue le son `to` : le rythme, les
notes et les effets restent, seul le son change.
"""
function _with_sound(p::Pattern, to::Symbol)
    swap(v) = v isa AbstractDict ? (d = Dict{Symbol,Any}(v); d[:s] = to; d) :
              (v isa Symbol || v isa AbstractString) ? to : v
    remap(evs) = Event{Any}[Event{Any}(ev.start, ev.stop, swap(ev.value)) for ev in evs]
    held = p.held === nothing ? nothing : ((s, e) -> remap(p.held(s, e)))
    return Pattern{Any}((s, e) -> remap(p(s, e)), held)
end

# Les sons que joue un pattern sur un cycle (pour les réécrire dans le texte).
function _sounds_of(p::Pattern, cyc::Int = 0)
    out = String[]
    evs = try Base.invokelatest(p, Rational{Int64}(cyc), Rational{Int64}(cyc + 1)) catch; return out end
    for ev in evs
        v = ev.value
        s = v isa AbstractDict ? get(v, :s, nothing) : (v isa Symbol || v isa AbstractString) ? v : nothing
        s === nothing && continue
        name = String(first(_split_variant(Symbol(String(s)))))
        name in out || push!(out, name)
    end
    return out
end

"""
    _explore_slot_open!(m) -> Bool

`gx` : sur une ligne `@dN` qui joue, l'explorateur s'ouvre sur ce slot ;
ailleurs, il s'ouvre tout court.
"""
function _explore_slot_open!(m::RessacApp)
    _explore_slot_close!(m)
    ed = _patterns_editor(m)
    target = nothing
    if ed !== nothing && _workspace_mode(m) === :play
        for l in _slot_lines(m)
            (l.row <= ed.cursor_row <= l.last_row && (l.state === :playing || l.state === :modified)) || continue
            pat = pattern_get(m.scheduler, l.slot)
            pat === nothing || (target = (l.slot, pat))
        end
    end
    _open_volet!(m, :explorer) || return false
    if target === nothing
        _push_app_log!(m, "[INFO] explorateur — gx sur une ligne @dN qui joue fait entendre les candidats dans ce pattern")
        return true
    end
    m.explore_slot = target
    m.explore_heard = (0, -1)
    _EXPLORER_SLOT_LABEL[] = "un autre son pour $(target[1])"
    _push_app_log!(m, "[INFO] le candidat du curseur joue dans $(target[1]) — Entrée l'adopte, :q rend le son d'origine")
    return true
end

# Rend au slot son pattern d'origine (s'il n'a pas été remplacé entre-temps
# par autre chose que nos essais).
function _explore_slot_close!(m::RessacApp)
    st = m.explore_slot
    m.explore_slot = nothing
    _EXPLORER_SLOT_LABEL[] = ""
    st === nothing && return
    (slot, original) = st
    cur = pattern_get(m.scheduler, slot)
    (cur === nothing || cur === m.explore_trial) && set_pattern!(m.scheduler, slot, original)
    m.explore_trial = nothing
    return
end

"""
    _explore_slot_tick!(m)

À chaque image : le slot joue le candidat du curseur de l'explorateur. Dès
qu'on quitte l'explorateur, le son d'origine revient.
"""
function _explore_slot_tick!(m::RessacApp)
    m.explore_slot === nothing && return
    p = _find_pane(m, SynthExplorerPane)
    if p === nothing || m.volet !== :explorer
        _explore_slot_close!(m)
        return
    end
    key = (p.focus, p.pop.generation)
    key == m.explore_heard && return
    osc = _explorer_osc()
    osc === nothing && return
    _explorer_ensure_defined!(p, osc)
    1 <= p.focus <= length(p.audition.slot_names) || return
    (slot, original) = m.explore_slot
    trial = _with_sound(original, p.audition.slot_names[p.focus])
    set_pattern!(m.scheduler, slot, trial)
    m.explore_trial = trial
    m.explore_heard = key
    return
end

# Un nom de son libre : `trouve`, `trouve2`…
function _free_synth_name(base::AbstractString = "trouve")
    taken(n) = isfile(_app_synth_path(n; mode = :dsl)) || synth_info(Symbol(n)) !== nothing
    taken(base) || return String(base)
    k = 2
    while taken("$base$k"); k += 1; end
    return "$base$k"
end

"""
    _explore_slot_adopt!(m)

`Entrée` dans l'explorateur ouvert sur un slot : le candidat est rangé comme
un son (`plugins/user-synths/<nom>.jl`), la ligne du slot est réécrite pour
le jouer, et elle est réévaluée.
"""
function _explore_slot_adopt!(m::RessacApp)
    st = m.explore_slot
    p = _find_pane(m, SynthExplorerPane)
    (st === nothing || p === nothing) && return
    (slot, original) = st
    g = p.pop.candidates[p.focus].genome
    name = _free_synth_name()
    text = render_dsl(g, Symbol(name))
    path = _app_synth_path(name; mode = :dsl)
    mkpath(dirname(path))
    write(path, "# trouvé dans l'explorateur pour $slot\n\n" * text)
    # Le son existe pour SuperCollider avant que la ligne ne le demande.
    was = _INSTALLING_SYNTH[]
    _INSTALLING_SYNTH[] = true
    try
        Core.eval(SynthDSL, SynthDSL._dsl_parse_all(text))
    catch err
        _push_app_log!(m, "[ERROR] le candidat ne se définit pas : $(first(sprint(showerror, err), 160))")
        return
    finally
        _INSTALLING_SYNTH[] = was
    end
    register_synth!(SynthEntry(Symbol(name), "user-synths",
        Dict{String,Any}("description" => "trouvé dans l'explorateur", "tags" => ["user", "dsl"],
                         "params" => _dsl_params_from_text(text))); update = true)
    # La ligne : chaque son qu'elle jouait devient le nouveau.
    old_names = _sounds_of(original, _cycle_index(m.scheduler))
    m.explore_slot = nothing; m.explore_trial = nothing; _EXPLORER_SLOT_LABEL[] = ""
    set_pattern!(m.scheduler, slot, original)            # le temps de réécrire ; l'évaluation suit
    _close_volet!(m)
    ed = _patterns_editor(m)
    ed === nothing && return
    lines = [String(l) for l in ed.lines]
    block = nothing
    for b in _slot_blocks(m)
        (b.slot === slot && !b.commented) && (block = b)
    end
    block === nothing && (_push_app_log!(m, "[INFO] « $name » rangé — la ligne de $slot a disparu, le son reste dans la réserve"); return)
    changed = false
    for r in block.row:block.last_row, old in old_names
        new = replace(lines[r], Regex("(?<![\\w])" * old * "(?![\\w])") => name)
        new == lines[r] || (lines[r] = new; changed = true)
    end
    if !changed
        _push_app_log!(m, "[INFO] « $name » rangé — je n'ai pas trouvé le nom du son dans la ligne de $slot : écris-le à la main")
        return
    end
    _edit_text!(ed, join(lines, '\n'); row = block.row, col = 0)
    for b in _slot_blocks(m)
        (b.slot === slot && !b.commented) && _eval_slot_block!(m, slot, b.src)
    end
    _push_app_log!(m, "[INFO] $slot joue « $name » — gs l'ouvre pour le travailler, u dans les patterns revient à l'ancien son")
    return
end
