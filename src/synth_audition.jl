# src/synth_audition.jl
# Audition des candidats : noms SynthDef bornés (ga_slot1..N + ga_held),
# define en background via /dirt/evalSC, jeu via /ressac/evalAndPlay
# (1er, définit+joue) puis /ressac/play (instantané). L'OSC client est
# passé explicitement → testable avec un mock.

mutable struct AuditionState
    slot_names::Vector{Symbol}
    ready::Vector{Bool}
    held_active::Bool
    defined_gen::Int        # generation whose SynthDefs are loaded (-1 = none)
end

function AuditionState(n::Int)
    names = [Symbol("ga_slot$i") for i in 1:n]
    return AuditionState(names, falses(n), false, -1)
end

const _GA_HELD_NAME = :ga_held

function _send(osc, address::AbstractString, args::Vector)
    send_osc(osc, encode(OSCMessage(address, args)))
end

# Définit (sans jouer) tous les candidats de la génération. Borne : on
# réécrit les MÊMES noms → SC n'accumule jamais plus de N SynthDefs.
function enqueue_generation!(st::AuditionState, osc, genomes::Vector{Genome})
    n = min(length(genomes), length(st.slot_names))
    for i in 1:n
        src = render_synthdef(genomes[i], st.slot_names[i])
        _send(osc, "/dirt/evalSC", Any[src])
        st.ready[i] = true
    end
    return st
end

# Joue un candidat DÉJÀ DÉFINI (par enqueue) via /ressac/play : voix
# fraîche, auto-libérée par son enveloppe (doneAction). On NE passe plus
# par /ressac/evalAndPlay — qui redéfinit + force-free le synth précédent
# et provoquait des « /n_free Node not found » quand celui-ci s'était
# déjà terminé tout seul.
function audition_play!(st::AuditionState, osc, slot::Int,
                        freq::Float64, sustain::Float64)
    1 <= slot <= length(st.slot_names) || return st
    name = st.slot_names[slot]
    # OSC ne supporte pas Float64 → Float32 pour les args numériques.
    _send(osc, "/ressac/play",
          Any[String(name), "freq", Float32(freq), "sustain", Float32(sustain)])
    return st
end

function audition_hold!(st::AuditionState, osc, g::Genome,
                        freq::Float64, sustain::Float64)
    src = render_synthdef(g, _GA_HELD_NAME)
    _send(osc, "/ressac/evalAndPlay", Any[String(_GA_HELD_NAME), src])
    st.held_active = true
    return st
end

function audition_stop!(st::AuditionState, osc)
    _send(osc, "/ressac/free", Any[String(_GA_HELD_NAME)])
    st.held_active = false
    return st
end
