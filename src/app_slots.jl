# src/app_slots.jl
# L'état des lignes @dN, lu sur l'app : ce que le scheduler joue, ce qui a
# été évalué, ce qui a échoué. Les règles elles-mêmes sont dans
# slot_state.jl (pures) ; ici on ne fait que rassembler leurs entrées.

"""
    _slot_blocks(m) -> Vector{SlotBlock}

Les blocs `@dN` du texte des patterns. Recalculés seulement quand le texte
change (clé : le hash des lignes de l'éditeur, sans rien allouer).
"""
function _slot_blocks(m::RessacApp)
    ed = _patterns_editor(m)
    ed === nothing && return SlotBlock[]
    h = hash(ed.lines)
    m.slot_scan[1] == h && return m.slot_scan[2]
    (blocks, _) = _scan_slot_blocks([String(l) for l in ed.lines])
    m.slot_scan = (h, blocks)
    return blocks
end

"""
    _slot_lines(m) -> Vector{SlotLine}

Un `SlotLine` par bloc `@dN` du texte, dans l'ordre des lignes.
"""
function _slot_lines(m::RessacApp)
    blocks = _slot_blocks(m)
    isempty(blocks) && return SlotLine[]
    _absorb_faults!(m)
    live = _live_blocks(blocks)
    playing = Dict{Symbol,Pattern}(pattern_snapshot(m.scheduler))
    cyc = _cycle_index(m.scheduler)
    out = SlotLine[]
    for b in blocks
        is_live = get(live, b.slot, nothing) === b
        pat = get(playing, b.slot, nothing)
        err = get(m.slot_errors, b.slot, nothing)
        st = _slot_state(b, is_live; playing = pat !== nothing,
                         cut = haskey(_APP_MUTED_PATTERNS, b.slot),
                         evaluated = get(m.slot_evaluated, b.slot, nothing), error = err)
        sounding = st === :playing || st === :modified
        push!(out, SlotLine(b.slot, b.row, b.last_row, st,
                            sounding && _slot_held(b.slot),
                            sounding && b.slot in m.slot_offgrid,
                            sounding ? _slot_onsets(m, b.slot, pat, cyc) : 0,
                            st === :error ? err : nothing))
    end
    return out
end

# L'état d'un slot donné (le bloc qui compte pour lui), ou `nothing`.
function _slot_line(m::RessacApp, slot::Symbol)
    found = nothing
    for l in _slot_lines(m)
        l.slot === slot && l.state !== :idle && return l
        l.slot === slot && (found = l)
    end
    return found
end

# Le cycle en cours, entier ; 0 tant que l'horloge n'a pas démarré.
_cycle_index(s::Scheduler) = s.t_start > 0 ? floor(Int, _current_cycle(s)) : 0

# Un drone tient la note de ce slot.
function _slot_held(slot::Symbol)
    d = drone_get(slot)
    return d !== nothing && d.origin === :slot
end

"""
    _slot_onsets(m, slot, pattern, cycle) -> Int

Le nombre de coups du cycle. Mémorisé par (cycle, pattern) : une requête
par slot et par cycle, pas par image.
"""
function _slot_onsets(m::RessacApp, slot::Symbol, pat, cyc::Int)
    pat === nothing && return 0
    key = objectid(pat)
    c = get(m.slot_density, slot, nothing)
    (c !== nothing && c[1] == cyc && c[2] == key) && return c[3]
    n = try
        length(Base.invokelatest(pat, Rational{Int64}(cyc), Rational{Int64}(cyc + 1)))
    catch
        0
    end
    m.slot_density[slot] = (cyc, key, n)
    return n
end

# ── Ce que l'évaluation consigne ─────────────────────────────────────

# Le bloc a été évalué : c'est lui qui joue désormais.
function _slot_evaluated!(m::RessacApp, slot::Symbol, src::AbstractString)
    m.slot_evaluated[slot] = String(src)
    delete!(m.slot_errors, slot)
    return nothing
end

# Le bloc a échoué. Ce qui jouait avant continue (`kept`), ou rien ne jouait.
function _slot_failed!(m::RessacApp, slot::Symbol, src::AbstractString, message::AbstractString)
    kept = pattern_get(m.scheduler, slot) !== nothing
    m.slot_errors[slot] = SlotError(String(src), String(message), kept)
    return nothing
end

# Les patterns que le scheduler a retirés parce qu'ils levaient en jouant :
# l'erreur porte sur le texte qui jouait.
function _absorb_faults!(m::RessacApp)
    for (slot, why) in _drain_faults!()
        src = get(m.slot_evaluated, slot, nothing)
        src === nothing && continue
        m.slot_errors[slot] = SlotError(src, why, false)
    end
    return nothing
end

"""
    _eval_slot_block!(m, slot, src) -> Bool

Évalue le source d'un bloc `@dN` et consigne ce qui s'est passé : réussi,
c'est ce texte qui joue ; raté, l'erreur est gardée pour être écrite sous
la ligne — et ce qui jouait avant continue.
"""
function _eval_slot_block!(m::RessacApp, slot::Symbol, src::AbstractString)
    try
        Core.eval(Main, Meta.parse(src))
        _slot_evaluated!(m, slot, src)
        return true
    catch e
        hint = _humanize_eval_error(e, src)
        _slot_failed!(m, slot, src, hint)
        _push_app_log!(m, "[ERROR] éval $slot : $hint")
        return false
    end
end

# Le slot d'un source de bloc (`@d3 …`), ou `nothing`.
function _slot_of_src(src::AbstractString)
    mt = match(r"^\s*@d(\d+)\b", src)
    return mt === nothing ? nothing : Symbol("d", mt.captures[1])
end
