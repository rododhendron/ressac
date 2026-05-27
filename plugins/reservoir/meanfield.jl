# Mean-field reservoir — Wilson-Cowan dynamics.
#
# Instead of N individual neurons, the population is summarised by two
# scalars: `E` (excitatory firing rate, [0, 1]) and `I` (inhibitory
# firing rate, [0, 1]). Standard Wilson-Cowan ODE drives these:
#
#   τ_E · dE/dt = -E + σ(w_EE · E − w_EI · I + drive_E)
#   τ_I · dI/dt = -I + σ(w_IE · E − w_II · I + drive_I)
#
# where σ(x) = 1 / (1 + exp(−k (x − θ))) is the sigmoidal gain.
#
# To stay compatible with the existing reservoir interface (which
# expects `spikes(r) → Vector{Bool}` of length N), we keep N "virtual"
# neurons split into E and I tagged subsets, and SAMPLE each one's
# spike each step with probability = E (or I) of its population. The
# spike pattern is stochastic but its time-averaged statistics follow
# the Wilson-Cowan trajectory.

"""
    MeanFieldReservoir

Wilson-Cowan population reservoir. Two scalar firing rates + N
Bernoulli-sampled virtual neurons for compatibility with the routes.
"""
mutable struct MeanFieldReservoir
    N::Int
    E::Float64                         # excitatory rate [0, 1]
    I::Float64                         # inhibitory rate [0, 1]
    is_excitatory::Vector{Bool}
    spike_buf::Vector{Bool}
    # Wilson-Cowan params
    τE::Float64; τI::Float64
    wEE::Float64; wEI::Float64; wIE::Float64; wII::Float64
    θE::Float64; θI::Float64
    kE::Float64; kI::Float64
    drive_scale::Float64               # pA → 1.0 input map
    dt::Float64
    spc::Int
    rng::Random.AbstractRNG
    history::Vector{Vector{Bool}}
    record_capacity::Int
end

"""
    meanfield(; N=64, inhibitory_fraction=0.2, dt=1.0, steps_per_cycle=1000,
                τE=10.0, τI=20.0,
                wEE=12.0, wEI=10.0, wIE=12.0, wII=2.0,
                θE=0.2, θI=0.4, kE=10.0, kI=10.0,
                drive_scale=1000.0,
                E_init=0.1, I_init=0.05,
                seed=nothing) -> MeanFieldReservoir

Build a Wilson-Cowan-style mean-field reservoir. The default
parameters sit in the classical "limit cycle" regime where E and I
oscillate self-sustained; tweak `wEE` / `wEI` for stable / chaotic
regimes.

`drive_scale` converts the AdEx-style pA input vector into the unit
range Wilson-Cowan expects (1000 pA ≈ 1.0). `inhibitory_fraction`
splits the N virtual neurons into E and I subsets so spike sampling
respects population identity.
"""
function meanfield(; N::Int = 64,
                     inhibitory_fraction::Real = 0.2,
                     dt::Real = 1.0,
                     steps_per_cycle::Int = 1000,
                     τE::Real = 10.0, τI::Real = 20.0,
                     wEE::Real = 12.0, wEI::Real = 10.0,
                     wIE::Real = 12.0, wII::Real = 2.0,
                     θE::Real = 0.2, θI::Real = 0.4,
                     kE::Real = 10.0, kI::Real = 10.0,
                     drive_scale::Real = 1000.0,
                     E_init::Real = 0.1, I_init::Real = 0.05,
                     seed::Union{Nothing,Integer} = nothing)
    N > 0 || throw(ArgumentError("meanfield N must be > 0"))
    0 <= inhibitory_fraction <= 1 ||
        throw(ArgumentError("inhibitory_fraction must be in [0, 1]"))
    rng = seed === nothing ? Random.default_rng() : Random.MersenneTwister(seed)
    n_I = round(Int, N * inhibitory_fraction)
    is_exc = falses(N)
    is_exc[1:(N - n_I)] .= true
    MeanFieldReservoir(N, Float64(E_init), Float64(I_init),
                       is_exc, falses(N),
                       Float64(τE), Float64(τI),
                       Float64(wEE), Float64(wEI), Float64(wIE), Float64(wII),
                       Float64(θE), Float64(θI), Float64(kE), Float64(kI),
                       Float64(drive_scale),
                       Float64(dt), Int(steps_per_cycle), rng,
                       Vector{Vector{Bool}}(), 0)
end

_sigmoid(x::Float64, θ::Float64, k::Float64) = 1.0 / (1.0 + exp(-k * (x - θ)))

Base.length(r::MeanFieldReservoir) = r.N
steps_per_cycle(r::MeanFieldReservoir) = r.spc
spikes(r::MeanFieldReservoir) = r.spike_buf
default_modulator_kind(::MeanFieldReservoir) = :E

function read_state(r::MeanFieldReservoir, kind::Symbol, neuron::Int)
    1 <= neuron <= r.N ||
        throw(BoundsError("neuron $neuron out of 1..$(r.N)"))
    kind === :E       && return r.E
    kind === :I       && return r.I
    kind === :spike   && return Float64(r.spike_buf[neuron])
    kind === :density && return count(r.spike_buf) / r.N
    throw(ArgumentError(
        "MeanField read_state kind must be :E, :I, :spike, or :density"))
end

function step!(r::MeanFieldReservoir, input::AbstractVector{<:Real})
    length(input) == r.N ||
        throw(DimensionMismatch(
            "input length $(length(input)) ≠ N=$(r.N)"))
    # Average the input over the two subpopulations and scale into the
    # unit input range Wilson-Cowan expects.
    sum_E = 0.0; n_E = 0
    sum_I = 0.0; n_I = 0
    @inbounds for i in 1:r.N
        v = Float64(input[i])
        if r.is_excitatory[i]
            sum_E += v; n_E += 1
        else
            sum_I += v; n_I += 1
        end
    end
    drive_E = n_E > 0 ? (sum_E / n_E) / r.drive_scale : 0.0
    drive_I = n_I > 0 ? (sum_I / n_I) / r.drive_scale : 0.0

    # Wilson-Cowan Euler step.
    inputE = r.wEE * r.E - r.wEI * r.I + drive_E
    inputI = r.wIE * r.E - r.wII * r.I + drive_I
    dE = (-r.E + _sigmoid(inputE, r.θE, r.kE)) / r.τE
    dI = (-r.I + _sigmoid(inputI, r.θI, r.kI)) / r.τI
    r.E = clamp(r.E + r.dt * dE, 0.0, 1.0)
    r.I = clamp(r.I + r.dt * dI, 0.0, 1.0)

    # Bernoulli-sample each virtual neuron's spike from its
    # population's rate. Routes downstream see N booleans as usual.
    new_spk = falses(r.N)
    @inbounds for i in 1:r.N
        prob = r.is_excitatory[i] ? r.E : r.I
        new_spk[i] = rand(r.rng) < prob
    end
    r.spike_buf = new_spk

    if r.record_capacity > 0
        push!(r.history, copy(new_spk))
        while length(r.history) > r.record_capacity
            popfirst!(r.history)
        end
    end
    return nothing
end

"Enable history recording — same opt-in API as AdEx / RECA."
function record_history!(r::MeanFieldReservoir, capacity::Int)
    r.record_capacity = max(0, capacity)
    r.record_capacity == 0 && empty!(r.history)
    return r
end

register_reservoir!(:meanfield, meanfield)
