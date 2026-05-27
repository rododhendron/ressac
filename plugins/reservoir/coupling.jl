# Reservoir↔reservoir coupling.
#
# Multiple reservoirs stepped in LOCKSTEP through a single `step!` call,
# with directional synaptic projections (src.spikes → dst.input) layered
# on top of each reservoir's internal recurrence. Lets you build
# E/I-balanced populations (excitatory pool + inhibitory pool) and any
# cross-population motif (mutual inhibition, feedforward chains, etc.).
#
# Architecturally `CoupledReservoirs` IS a reservoir in the sense that
# it implements the interface contract — so every route (spike_burst,
# pool_burst, spectral_cloud, modulator) accepts it as a drop-in.
# Internally it dispatches `length` / `spikes` / `read_state` to its
# designated `output_idx` member; `step!` advances every member with
# coupling current pulled from the others' previous-step spikes.

"""
    CoupledReservoirs

A group of `members` (each itself implementing the reservoir interface)
plus a list of directional `couplings` between them. One member is
the `output_idx` — that's the one whose state the routes read for
event emission.

`couplings` entries are `(src_idx, dst_idx, W)` where `W` is a
`length(dst) × length(src)` matrix: a spike on `src.neuron_j`
injects `W[i, j]` pA into `dst.neuron_i` on the next step.

Construct with `couple([r1, r2, ...]; output_idx = 1)` then add
projections with `connect!`.
"""
mutable struct CoupledReservoirs
    members::Vector{Any}
    couplings::Vector{Tuple{Int,Int,Matrix{Float64}}}
    output_idx::Int
end

"""
    couple(reservoirs::Vector; output_idx=1) -> CoupledReservoirs

Build an empty coupled group. Add projections with `connect!`. The
`output_idx` member is the one routes will see when called with the
group as their reservoir argument.
"""
function couple(reservoirs::AbstractVector; output_idx::Int = 1)
    isempty(reservoirs) && throw(ArgumentError("couple: at least one reservoir"))
    1 <= output_idx <= length(reservoirs) ||
        throw(ArgumentError("couple: output_idx must be in 1..$(length(reservoirs))"))
    CoupledReservoirs(collect(reservoirs),
                      Tuple{Int,Int,Matrix{Float64}}[],
                      Int(output_idx))
end

"""
    connect!(g, src, dst; gain=200.0, p_connect=0.1,
             sign=:positive, seed=nothing)

Add a directional projection from member `src` to member `dst`. Each
post-synaptic neuron has `p_connect` probability of receiving from any
pre-synaptic neuron; non-zero weights are `randn() * gain` magnitude,
signed per `sign`:

- `:positive` — all weights ≥ 0 (excitatory population, e.g. E → I)
- `:negative` — all weights ≤ 0 (inhibitory population, e.g. I → E)
- `:mixed`   — random sign (no Dale's principle)
"""
function connect!(g::CoupledReservoirs, src::Int, dst::Int;
                  gain::Real = 200.0,
                  p_connect::Real = 0.1,
                  sign::Symbol = :positive,
                  seed::Union{Nothing,Integer} = nothing)
    1 <= src <= length(g.members) ||
        throw(ArgumentError("connect!: src $src out of 1..$(length(g.members))"))
    1 <= dst <= length(g.members) ||
        throw(ArgumentError("connect!: dst $dst out of 1..$(length(g.members))"))
    0 <= p_connect <= 1 || throw(ArgumentError("connect!: p_connect must be in [0, 1]"))
    sign in (:positive, :negative, :mixed) ||
        throw(ArgumentError("connect!: sign must be :positive, :negative, or :mixed"))

    rng = seed === nothing ? Random.default_rng() : Random.MersenneTwister(seed)
    src_r = g.members[src]
    dst_r = g.members[dst]
    gain_f = Float64(gain)
    W = zeros(Float64, length(dst_r), length(src_r))
    @inbounds for i in 1:length(dst_r), j in 1:length(src_r)
        if rand(rng) < p_connect
            w = randn(rng) * gain_f
            W[i, j] = sign === :positive ? abs(w) :
                      sign === :negative ? -abs(w) :
                                            w
        end
    end
    push!(g.couplings, (src, dst, W))
    return g
end

# --------------------------------------------------------------------
# Interface implementations — delegate to the output member.
# --------------------------------------------------------------------

Base.length(g::CoupledReservoirs) = length(g.members[g.output_idx])
steps_per_cycle(g::CoupledReservoirs) = steps_per_cycle(g.members[g.output_idx])
spikes(g::CoupledReservoirs) = spikes(g.members[g.output_idx])
default_modulator_kind(g::CoupledReservoirs) =
    default_modulator_kind(g.members[g.output_idx])
read_state(g::CoupledReservoirs, kind::Symbol, neuron::Int) =
    read_state(g.members[g.output_idx], kind, neuron)

"""
    step!(g::CoupledReservoirs, input::AbstractVector{<:Real}) -> nothing

Advance every member by one step. `input` is the external drive for
the OUTPUT member only — other members get zero external drive plus
their incoming couplings. (For more granular control, future work
could accept a `Vector{Vector{Float64}}`.) Couplings read each
member's spike_buf BEFORE any step runs, so the temporal alignment is
"both populations spike based on the previous step's state".
"""
function step!(g::CoupledReservoirs, input::AbstractVector{<:Real})
    n_members = length(g.members)
    # Snapshot all spike buffers BEFORE any step — keeps the temporal
    # alignment symmetrical so neither member sees the OTHER's just-
    # produced spikes within the same step.
    snapshots = Vector{Vector{Bool}}(undef, n_members)
    @inbounds for i in 1:n_members
        snapshots[i] = copy(spikes(g.members[i]))
    end
    # Build per-member input vectors: only the output member gets the
    # external drive, all members accumulate incoming couplings.
    inputs = Vector{Vector{Float64}}(undef, n_members)
    @inbounds for i in 1:n_members
        m = g.members[i]
        v = zeros(Float64, length(m))
        if i == g.output_idx
            length(input) == length(m) ||
                throw(DimensionMismatch(
                    "step!(CoupledReservoirs): input length $(length(input)) ≠ N=$(length(m))"))
            for k in 1:length(m)
                v[k] = Float64(input[k])
            end
        end
        inputs[i] = v
    end
    @inbounds for (src, dst, W) in g.couplings
        # `W * snapshot` broadcasts the src's spikes into dst's input.
        inputs[dst] .+= W * snapshots[src]
    end
    @inbounds for i in 1:n_members
        step!(g.members[i], inputs[i])
    end
    return nothing
end
