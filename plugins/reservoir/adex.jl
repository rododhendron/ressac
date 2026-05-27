# Adaptive Exponential Integrate-and-Fire (AdEx) neuron — Brette &
# Gerstner 2005. Richer than LIF: the exponential term reproduces the
# real spike upswing, the adaptation current `w` produces accommodation
# and bursting. Different param sets give qualitatively different
# firing patterns (regular, bursting, fast spiking, …).
#
# Units throughout: mV / ms / pA / pF / nS. With these, the AdEx
# equations are unit-consistent (nS · mV = pA).

"""
    AdExParams

AdEx parameter bundle. All quantities in mV / ms / pA / pF / nS.

- `C`      membrane capacitance (pF)
- `gL`     leak conductance (nS)
- `EL`     leak reversal / rest (mV)
- `VT`     spike threshold (mV)
- `ΔT`     spike-slope factor (mV)
- `τw`     adaptation time constant (ms)
- `a`      subthreshold coupling to V (nS)
- `b`      spike-triggered increment of w (pA)
- `Vr`     reset potential after spike (mV)
- `V_peak` cutoff for spike detection (mV)
"""
struct AdExParams
    C::Float64
    gL::Float64
    EL::Float64
    VT::Float64
    ΔT::Float64
    τw::Float64
    a::Float64
    b::Float64
    Vr::Float64
    V_peak::Float64
end

"Regular-spiking pyramidal — accommodation but no burst."
const ADEX_REGULAR  = AdExParams(281.0, 30.0, -70.6, -50.4, 2.0, 144.0,  4.0,   80.5, -70.6, 0.0)
"Bursting — phasic bursts on sustained input."
const ADEX_BURSTING = AdExParams(200.0, 12.0, -70.0, -50.0, 2.0,  120.0, 2.0,  100.0, -50.0, 0.0)
"Fast-spiking interneuron — tonic, little adaptation."
const ADEX_FAST     = AdExParams(200.0, 10.0, -65.0, -50.0, 2.0,  10.0,  2.0,    0.0, -65.0, 0.0)

# ── Brette & Gerstner 2005 firing regimes ────────────────────────────
# 8 canonical params sets from Brette & Gerstner, "Adaptive Exponential
# Integrate-and-Fire Model as an Effective Description of Neuronal
# Activity" (J Neurophysiol 94:3637-3642, 2005), reproducing the firing
# patterns observed in cortical neurons under sustained DC injection.
# Pick `params=ADEX_<NAME>` to get a population with that signature.

"Tonic spiking — regular firing, no adaptation. Constant rate output."
const ADEX_TONIC          = AdExParams(200.0, 10.0, -70.0, -50.0, 2.0, 30.0,    2.0,   0.0, -58.0, 0.0)
"Adapting — initial rapid spikes that slow as adaptation builds up."
const ADEX_ADAPTING       = AdExParams(200.0, 12.0, -70.0, -50.0, 2.0, 300.0,   2.0,  60.0, -58.0, 0.0)
"Initial burst — short burst at onset, then silent / sparse."
const ADEX_INITIAL_BURST  = AdExParams(130.0, 18.0, -58.0, -50.0, 2.0, 150.0,   4.0, 120.0, -50.0, 0.0)
"Regular bursting — repeating bursts on sustained input."
const ADEX_REGULAR_BURST  = AdExParams(200.0, 10.0, -58.0, -50.0, 2.0, 120.0,   2.0, 100.0, -46.0, 0.0)
"Delayed accelerating — pause before first spike, then rate ramps up."
const ADEX_DELAYED_ACCEL  = AdExParams(200.0, 12.0, -70.0, -50.0, 2.0, 300.0, -10.0,   0.0, -58.0, 0.0)
"Delayed bursting — pause then regular bursts."
const ADEX_DELAYED_BURST  = AdExParams(100.0, 10.0, -65.0, -50.0, 2.0,  90.0, -10.0,  30.0, -47.0, 0.0)
"Transient — fires briefly at onset then stops despite ongoing input."
const ADEX_TRANSIENT      = AdExParams(100.0, 12.0, -65.0, -50.0, 2.0,  90.0,  10.0, 100.0, -47.0, 0.0)
"Irregular — chaotic dynamics near bifurcation."
const ADEX_IRREGULAR      = AdExParams(100.0, 12.0, -65.0, -50.0, 2.0,  90.0, -11.0,  30.0, -48.0, 0.0)

"""
    adex_presets

Lookup of named B&G 2005 firing regimes for `adex(params=…)`. Keys
match the suffix of the matching `ADEX_*` constant (lowercased).
"""
const adex_presets = Dict{Symbol,AdExParams}(
    :tonic          => ADEX_TONIC,
    :adapting       => ADEX_ADAPTING,
    :initial_burst  => ADEX_INITIAL_BURST,
    :regular_burst  => ADEX_REGULAR_BURST,
    :delayed_accel  => ADEX_DELAYED_ACCEL,
    :delayed_burst  => ADEX_DELAYED_BURST,
    :transient      => ADEX_TRANSIENT,
    :irregular      => ADEX_IRREGULAR,
    :regular        => ADEX_REGULAR,
    :bursting       => ADEX_BURSTING,
    :fast           => ADEX_FAST,
)

# --------------------------------------------------------------------
# Reservoir of AdEx neurons coupled by a sparse random matrix.
# --------------------------------------------------------------------

"""
    AdExReservoir

State container: per-neuron V/w plus a static recurrent weight matrix
`W`. `W[i,j]` is the synaptic current (pA) injected into neuron i
when neuron j fires this step.
"""
mutable struct AdExReservoir
    N::Int
    V::Vector{Float64}
    w::Vector{Float64}
    W::Matrix{Float64}
    params::AdExParams
    spike_buf::Vector{Bool}
    dt::Float64
    spc::Int
    # OU baseline noise — per-neuron coloured noise that hovers V near
    # threshold without ever crossing on its own. When an external
    # drive arrives, the noisy population spikes synchronously because
    # everyone is already close to the edge.
    noise::Vector{Float64}           # current OU sample per neuron (pA)
    σ_noise::Float64                 # noise volatility (pA scale)
    τ_noise::Float64                 # OU correlation time (ms)
    # Optional inhibitory subset (Dale's principle). A unit in `inhib`
    # contributes only negative current via its W column.
    inhib::Vector{Bool}
    rng::Random.AbstractRNG          # noise RNG (so seed reproduces)
    # Winner-takes-all: if true, at most one neuron is reported as
    # spiking per step (the one whose V would have been highest just
    # before reset). Useful for "selecting a single note from the
    # population" — gives mono-rhythmic / sequence-y output instead of
    # the dense chordal spray of the default population dynamics.
    wta::Bool
    # Optional spike history for the visual scope. `record_capacity > 0`
    # turns recording on; each `step!` appends a copy of `spike_buf` and
    # drops the oldest when the ring is full. Off by default (0 entries,
    # no overhead). Enable via `record_history!(r, capacity)`.
    history::Vector{Vector{Bool}}
    record_capacity::Int
end

"""
    adex(; N=64, dt=1.0, steps_per_cycle=1000,
           params=ADEX_REGULAR, p_connect=0.1, W_gain=180.0,
           V_init=:rest,
           σ_noise=0.0, τ_noise=20.0,
           inhibitory_fraction=0.0,
           seed=nothing) -> AdExReservoir

Build an AdEx reservoir of `N` neurons with sparse random recurrent
connectivity. Connection probability `p_connect`, weights scaled by
`W_gain` (pA per spike). `dt` is the simulator timestep in ms; one
Ressac cycle corresponds to `steps_per_cycle` calls of `step!`.

`V_init` ∈ `:rest` (uniform at EL) or `:scattered` (uniform in
[EL, VT-1]) for a less synchronous start.

**Baseline noise** — `σ_noise` (pA scale) and `τ_noise` (ms
correlation time) configure an Ornstein-Uhlenbeck process injected as
extra current at every step. Cortical-like values: `σ_noise=80`,
`τ_noise=20`. With `σ_noise=0` (default) the neurons sit perfectly
silent at rest; with noise, V hovers near threshold so any extra
drive synchronises spikes across the population.

**Inhibition (Dale's principle)** — `inhibitory_fraction` ∈ [0, 1] sets
the proportion of neurons whose outgoing weights are forced negative
(inhibitory units). `0.0` keeps the original random-signed connectivity;
typical cortical setups use `0.2`.
"""
function adex(; N::Int = 64,
                dt::Real = 1.0,
                steps_per_cycle::Int = 1000,
                params::AdExParams = ADEX_REGULAR,
                p_connect::Real = 0.1,
                W_gain::Real = 180.0,
                V_init::Symbol = :rest,
                σ_noise::Real = 0.0,
                τ_noise::Real = 20.0,
                inhibitory_fraction::Real = 0.0,
                wta::Bool = false,
                seed::Union{Nothing,Integer} = nothing)
    N > 0 || throw(ArgumentError("adex N must be > 0"))
    dt > 0 || throw(ArgumentError("adex dt must be > 0"))
    steps_per_cycle > 0 || throw(ArgumentError("adex steps_per_cycle must be > 0"))
    0 <= p_connect <= 1 || throw(ArgumentError("adex p_connect must be in [0, 1]"))
    σ_noise >= 0 || throw(ArgumentError("adex σ_noise must be ≥ 0"))
    τ_noise > 0 || throw(ArgumentError("adex τ_noise must be > 0"))
    0 <= inhibitory_fraction <= 1 ||
        throw(ArgumentError("adex inhibitory_fraction must be in [0, 1]"))

    rng = seed === nothing ? Random.default_rng() : Random.MersenneTwister(seed)

    # Dale's principle: pick a contiguous block as inhibitory. Random
    # selection would also work; block keeps the matrix block-structured
    # and easier to reason about during debugging.
    n_inhib = round(Int, N * inhibitory_fraction)
    inhib = falses(N)
    inhib[(N - n_inhib + 1):N] .= true

    W = zeros(Float64, N, N)
    for i in 1:N, j in 1:N
        i == j && continue
        if rand(rng) < p_connect
            w_val = randn(rng) * W_gain
            # If j is an inhibitory unit, flip sign to negative if not
            # already; if j is excitatory under Dale's, force positive.
            # When inhibitory_fraction == 0 (no Dale), leave random sign.
            if n_inhib > 0
                w_val = inhib[j] ? -abs(w_val) : abs(w_val)
            end
            W[i, j] = w_val
        end
    end

    V = if V_init === :rest
        fill(params.EL, N)
    elseif V_init === :scattered
        params.EL .+ (params.VT - 1 - params.EL) .* rand(rng, N)
    else
        throw(ArgumentError("adex V_init must be :rest or :scattered"))
    end
    w = zeros(Float64, N)
    spk = falses(N)
    noise = zeros(Float64, N)

    AdExReservoir(N, V, w, W, params, spk,
                  Float64(dt), Int(steps_per_cycle),
                  noise, Float64(σ_noise), Float64(τ_noise),
                  inhib, rng, wta,
                  Vector{Vector{Bool}}(), 0)
end

"""
    record_history!(r, capacity::Int)

Enable spike-history recording on `r`. Each subsequent `step!` will
push a copy of `spike_buf` into a rolling buffer capped at `capacity`
snapshots. Set `capacity=0` to stop recording and free the buffer.
"""
function record_history!(r::AdExReservoir, capacity::Int)
    r.record_capacity = max(0, capacity)
    if r.record_capacity == 0
        empty!(r.history)
    end
    return r
end

# --------------------------------------------------------------------
# Interface implementations
# --------------------------------------------------------------------

Base.length(r::AdExReservoir) = r.N
steps_per_cycle(r::AdExReservoir) = r.spc

function spikes(r::AdExReservoir)
    return r.spike_buf
end

default_modulator_kind(::AdExReservoir) = :V

function read_state(r::AdExReservoir, kind::Symbol, neuron::Int)
    1 <= neuron <= r.N ||
        throw(BoundsError("neuron $neuron out of 1..$(r.N)"))
    kind === :V       && return r.V[neuron]
    kind === :w       && return r.w[neuron]
    kind === :spike   && return Float64(r.spike_buf[neuron])
    kind === :density && return count(r.spike_buf) / r.N
    throw(ArgumentError(
        "AdEx read_state kind must be :V, :w, :spike, or :density (got $kind)"))
end

# Exp-arg cap stops the term from blowing up if a numerical glitch lets
# V drift past V_peak between checks. AdEx without a cap can overflow
# Float64 when dt is large or input is extreme.
const _ADEX_EXP_CAP = 50.0

"""
    step!(r::AdExReservoir, input::AbstractVector{<:Real}) -> nothing

Advance the reservoir by one Euler step. `input[i]` is the external
current (pA) injected into neuron i this step; recurrent input is
added on top from W · spikes_previous. Any `Real` element type works
— values are promoted to `Float64` inside the loop.
"""
function step!(r::AdExReservoir, input::AbstractVector{<:Real})
    length(input) == r.N ||
        throw(DimensionMismatch("input length $(length(input)) ≠ N=$(r.N)"))
    p = r.params
    dt = r.dt

    # Recurrent input: W · spike_buf (last step's spikes drive this step).
    rec = r.W * r.spike_buf

    # Advance the per-neuron OU noise one step (skipped when σ_noise=0).
    # Discrete OU: x_{n+1} = (1 − dt/τ) x_n + σ √(2 dt/τ) · ξ
    if r.σ_noise > 0.0
        decay = 1.0 - dt / r.τ_noise
        scale = r.σ_noise * sqrt(2.0 * dt / r.τ_noise)
        @inbounds for i in 1:r.N
            r.noise[i] = decay * r.noise[i] + scale * randn(r.rng)
        end
    end

    new_spk = falses(r.N)
    # Tracks the pre-reset V_new for any neuron that would have spiked
    # — used as the "intent" score under WTA arbitration. Unused when
    # `r.wta == false` (the typical path).
    candidate_strength = r.wta ? fill(-Inf, r.N) : Float64[]
    @inbounds for i in 1:r.N
        V = r.V[i]; w = r.w[i]
        Iext = input[i] + rec[i] + r.noise[i]
        arg = (V - p.VT) / p.ΔT
        arg = arg > _ADEX_EXP_CAP ? _ADEX_EXP_CAP : arg
        dV = (-p.gL * (V - p.EL) + p.gL * p.ΔT * exp(arg) - w + Iext) / p.C
        dw = (p.a * (V - p.EL) - w) / p.τw
        V_new = V + dt * dV
        w_new = w + dt * dw
        if V_new > p.V_peak
            r.wta && (candidate_strength[i] = V_new)
            V_new = p.Vr
            w_new += p.b
            new_spk[i] = true
        end
        r.V[i] = V_new
        r.w[i] = w_new
    end
    # WTA: keep only the strongest spike in this step. The internal
    # state updates still apply to everyone who fired (b adaptation
    # kicks, V resets), so the dynamics still feel competitive — only
    # the OUTPUT visible to routes is the single winner.
    if r.wta && count(new_spk) > 1
        winner = argmax(candidate_strength)
        fill!(new_spk, false)
        new_spk[winner] = true
    end
    r.spike_buf = new_spk
    # Visual-scope history (no-op when capacity=0).
    if r.record_capacity > 0
        push!(r.history, copy(new_spk))
        while length(r.history) > r.record_capacity
            popfirst!(r.history)
        end
    end
    return nothing
end

register_reservoir!(:adex, adex)
