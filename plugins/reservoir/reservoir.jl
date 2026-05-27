# Reservoir plugin — multiple reservoir kinds (AdEx spiking, RECA cellular
# automaton, future contributions) sharing one interface so the routes
# (Route I spike→burst, Route II IFFT, Route III modulator) work
# generically on any kind.
#
# ╭─ Interface contract (all reservoir kinds must implement) ─────╮
# │   step!(r, input::AbstractVector{<:Real}) -> nothing           │
# │   spikes(r) -> AbstractVector{Bool}                            │
# │   Base.length(r) -> Int                                        │
# │   steps_per_cycle(r) -> Int                                    │
# │   read_state(r, kind::Symbol, neuron::Int) -> Float64          │
# ╰────────────────────────────────────────────────────────────────╯
#
# A new reservoir type (e.g. Echo State Network, FORCE network) only
# has to satisfy these four functions to plug into the existing routes.

module Reservoir

using Random
import Ressac
using Ressac: Pattern, Event, ControlMap

export step!, spikes, steps_per_cycle, read_state,
       adex, reca, meanfield, spike_burst, modulator, spectral_cloud, pool_burst,
       rate_voice,
       couple, connect!, CoupledReservoirs, record_history!,
       register_reservoir!, list_reservoirs,
       register_layout!, list_layouts, compute_layout,
       AdExParams, ADEX_REGULAR, ADEX_BURSTING, ADEX_FAST,
       ADEX_TONIC, ADEX_ADAPTING, ADEX_INITIAL_BURST, ADEX_REGULAR_BURST,
       ADEX_DELAYED_ACCEL, ADEX_DELAYED_BURST, ADEX_TRANSIENT, ADEX_IRREGULAR,
       adex_presets,
       drive_const, drive_sin, drive_square, drive_ramp, drive_tri,
       drive_burst, drive_sum

# --------------------------------------------------------------------
# Generic methods — concrete reservoir types overload these.
# --------------------------------------------------------------------

"""
    step!(r, input::AbstractVector{<:Real}) -> nothing

Advance the reservoir by one internal step, optionally driven by an
input vector of size `length(r)`. Must update `spikes(r)` to reflect
this step's activity.
"""
function step! end

"""
    spikes(r) -> AbstractVector{Bool}

Return a vector (one bool per neuron / cell) indicating which units
fired during the most recent `step!`.
"""
function spikes end

"""
    steps_per_cycle(r) -> Int

Number of `step!` calls that map to one Ressac cycle. Tighter values
mean higher temporal resolution at the cost of more compute per query.
"""
function steps_per_cycle end

"""
    read_state(r, kind::Symbol, neuron::Int) -> Float64

Read a scalar from the reservoir for the modulator route (Route III).
The set of valid `kind` values is per-type — AdEx exposes `:V`, `:w`,
`:spike`, `:density`; RECA exposes `:bit`, `:spike`, `:density`.
"""
function read_state end

"""
    default_modulator_kind(r) -> Symbol

The `kind` to use when the user doesn't specify one. AdEx → `:V`,
RECA → `:bit`. New reservoir types should define this so `modulator(r)`
works with no args.
"""
function default_modulator_kind end

# --------------------------------------------------------------------
# Extension registries
# --------------------------------------------------------------------

const _RESERVOIR_REGISTRY = Dict{Symbol, Function}()
const _LAYOUT_REGISTRY    = Dict{Symbol, Function}()

"""
    register_reservoir!(name, constructor) -> Symbol

Register a reservoir constructor under `name`. The constructor is any
callable that returns a value satisfying the interface contract.
"""
function register_reservoir!(name::Symbol, constructor)
    _RESERVOIR_REGISTRY[name] = constructor
    return name
end

list_reservoirs() = sort!(collect(keys(_RESERVOIR_REGISTRY)))

"""
    register_layout!(name, f) -> Symbol

Register a frequency-layout function under `name`. The function must
accept `(N::Int, lo::Real, hi::Real; kwargs...) -> Vector{Float64}` and
return an `N`-element frequency vector.
"""
function register_layout!(name::Symbol, f)
    _LAYOUT_REGISTRY[name] = f
    return name
end

list_layouts() = sort!(collect(keys(_LAYOUT_REGISTRY)))

# --------------------------------------------------------------------
# Load the sub-files (each file registers itself into the appropriate
# registry, so adding a new file = adding a new line here OR shipping
# a separate plugin that calls `register_*!`).
# --------------------------------------------------------------------

include("adex.jl")
include("reca.jl")
include("meanfield.jl")
include("layouts.jl")
include("coupling.jl")
include("drive_sources.jl")
include("route_spike.jl")
include("route_modulator.jl")
include("route_spectral.jl")
include("route_pool.jl")
include("route_rate.jl")

end # module Reservoir

# JS-style namespace alias so `reservoir.adex(...)` works at top level.
const reservoir = Reservoir

# Auto-import exported names so users don't have to type
# `Reservoir.spike_burst(...)` or `using Main.Reservoir: drive_*` in
# every starter / live buffer. After this line, `adex`, `spike_burst`,
# `modulator`, `spectral_cloud`, `drive_const`, `drive_sin`, … are all
# callable bare from Main.
using .Reservoir
