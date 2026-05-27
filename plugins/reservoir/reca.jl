# Reservoir Computing with Elementary Cellular Automata (RECA) —
# Yilmaz 2014, Margem & Yilmaz 2016. The reservoir is a 1D binary
# array evolving under a Wolfram rule (rule 30 / 90 / 110 / 184 …).
# Input perturbs cells by XOR; cells that turn 1 are "spikes" for the
# routes downstream.
#
# Implements the same interface as AdExReservoir, so route_spike.jl
# can map either to bursting voices without specialisation.

"""
    RECAReservoir

State container for an elementary CA reservoir.

- `state`     current N-cell bit array
- `rule`      Wolfram rule number (0..255)
- `boundary`  `:wrap` (toroidal) or `:zero` (cells outside grid = 0)
- `spc`       steps per Ressac cycle
"""
mutable struct RECAReservoir
    N::Int
    state::Vector{Bool}
    rule::UInt8
    boundary::Symbol
    spike_buf::Vector{Bool}
    spc::Int
    # Same history hook as AdExReservoir — captures generations into a
    # rolling buffer when `record_capacity > 0`. Enables the RECA grid
    # visualisation in the scope pane.
    history::Vector{Vector{Bool}}
    record_capacity::Int
end

"""
    reca(; N=64, rule=30, steps_per_cycle=16,
           boundary=:wrap, init=:single, seed=nothing) -> RECAReservoir

Build a RECA reservoir.

- `rule` ∈ 0..255: any Wolfram elementary rule. Defaults to 30 (chaotic).
  Other interesting choices: 90 (Sierpinski), 110 (Turing-complete,
  edge-of-chaos), 184 (traffic), 54 (complex).
- `init` ∈ `:single` (one cell = 1 at center), `:rand` (random bits),
  `:zero` (all off — needs input to do anything).
"""
function reca(; N::Int = 64,
                rule::Integer = 30,
                steps_per_cycle::Int = 16,
                boundary::Symbol = :wrap,
                init::Symbol = :single,
                seed::Union{Nothing,Integer} = nothing)
    N > 0 || throw(ArgumentError("reca N must be > 0"))
    0 <= rule <= 255 || throw(ArgumentError("reca rule must be in 0..255"))
    boundary in (:wrap, :zero) || throw(ArgumentError("reca boundary must be :wrap or :zero"))
    steps_per_cycle > 0 || throw(ArgumentError("reca steps_per_cycle must be > 0"))

    rng = seed === nothing ? Random.default_rng() : Random.MersenneTwister(seed)

    state = if init === :single
        s = falses(N); s[N ÷ 2 + 1] = true; s
    elseif init === :rand
        rand(rng, Bool, N)
    elseif init === :zero
        falses(N)
    else
        throw(ArgumentError("reca init must be :single, :rand, or :zero"))
    end
    state_vec = collect(state)  # Vector{Bool}, mutable storage
    spk = copy(state_vec)
    RECAReservoir(N, state_vec, UInt8(rule), boundary, spk,
                  Int(steps_per_cycle), Vector{Vector{Bool}}(), 0)
end

"Enable history recording for the visual scope. See AdEx `record_history!`."
function record_history!(r::RECAReservoir, capacity::Int)
    r.record_capacity = max(0, capacity)
    if r.record_capacity == 0
        empty!(r.history)
    end
    return r
end

# --------------------------------------------------------------------
# Interface implementations
# --------------------------------------------------------------------

Base.length(r::RECAReservoir) = r.N
steps_per_cycle(r::RECAReservoir) = r.spc
spikes(r::RECAReservoir) = r.spike_buf

default_modulator_kind(::RECAReservoir) = :bit

function read_state(r::RECAReservoir, kind::Symbol, neuron::Int)
    1 <= neuron <= r.N ||
        throw(BoundsError("neuron $neuron out of 1..$(r.N)"))
    kind === :bit     && return Float64(r.state[neuron])
    kind === :spike   && return Float64(r.spike_buf[neuron])
    kind === :density && return count(r.state) / r.N
    throw(ArgumentError(
        "RECA read_state kind must be :bit, :spike, or :density (got $kind)"))
end

"""
    step!(r::RECAReservoir, input::AbstractVector{<:Real}) -> nothing

XOR `input` (threshold 0.5) into the state, then apply one CA step.
The new state is also reported as `spikes(r)` so routes can treat
"this cell just turned 1" as a spike-like event. Any `Real` element
type works — values are compared to `0.5` directly.
"""
function step!(r::RECAReservoir, input::AbstractVector{<:Real})
    length(input) == r.N ||
        throw(DimensionMismatch("input length $(length(input)) ≠ N=$(r.N)"))
    # XOR input bits (threshold 0.5).
    @inbounds for i in 1:r.N
        if input[i] > 0.5
            r.state[i] = !r.state[i]
        end
    end
    new_state = Vector{Bool}(undef, r.N)
    @inbounds for i in 1:r.N
        if r.boundary === :wrap
            l = i == 1 ? r.N : i - 1
            rr = i == r.N ? 1 : i + 1
        else
            l = i - 1
            rr = i + 1
        end
        bl = (l >= 1 && l <= r.N) ? r.state[l] : false
        bc = r.state[i]
        br = (rr >= 1 && rr <= r.N) ? r.state[rr] : false
        triple = (bl ? 4 : 0) | (bc ? 2 : 0) | (br ? 1 : 0)
        new_state[i] = ((r.rule >> triple) & 0x01) != 0
    end
    r.state = new_state
    r.spike_buf = new_state
    if r.record_capacity > 0
        push!(r.history, copy(new_state))
        while length(r.history) > r.record_capacity
            popfirst!(r.history)
        end
    end
    return nothing
end

register_reservoir!(:reca, reca)
