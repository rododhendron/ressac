# Chaotic dynamical systems as Pattern{Float64} generators.
#
# Each generator returns a Pattern{Float64} that, on query, advances
# its internal state to the END of the query window and emits a single
# event over the arc carrying the current state value on the selected
# axis. Combine with `segment(N)` to discretise, `range_pat(lo, hi)` to
# remap, and `slow(N) / fast(N)` to scale the chaos rate in cycle time.
#
# State is held in closure-local `Ref`s — each constructor call
# (`chaos.lorenz(...)`) builds a fresh independent oscillator. Queries
# are expected to advance forward in cycle time (which the scheduler
# always does); a backward query returns the most recent state without
# re-integration.

module Chaos

using Ressac: Pattern, Event

export lorenz, henon, logistic, rossler, standard,
       register_chaos!, list_chaos

# --------------------------------------------------------------------
# Extensibility registry
# --------------------------------------------------------------------
# Community plugins can call `register_chaos!(:name, constructor)` to
# expose a new chaotic system under `chaos.<name>(...)` semantics.
# `constructor` is any callable returning a `Pattern{Float64}`.

const _REGISTRY = Dict{Symbol, Function}()

"""
    register_chaos!(name::Symbol, constructor)

Register a chaos-pattern constructor under `name`. The constructor is
any callable that returns a `Pattern{Float64}`. Overwrites silently.
"""
function register_chaos!(name::Symbol, constructor)
    _REGISTRY[name] = constructor
    return name
end

"""
    list_chaos() -> Vector{Symbol}

Names currently registered. Useful for introspection / the TUI.
"""
list_chaos() = sort!(collect(keys(_REGISTRY)))

# --------------------------------------------------------------------
# Internal: build a continuous-style Pattern that advances `step!`
# steps_per_cycle times per cycle and reports `read()` on each query.
# --------------------------------------------------------------------

function _chaos_pattern(step!::Function, read::Function, steps_per_cycle::Int)
    steps_per_cycle > 0 ||
        throw(ArgumentError("steps_per_cycle must be > 0"))
    step_count = Ref(0)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        target = ceil(Int, Float64(e) * steps_per_cycle)
        while step_count[] < target
            step!()
            step_count[] += 1
        end
        [Event{Float64}(s, e, read())]
    end)
end

# --------------------------------------------------------------------
# Lorenz (3D continuous) — Euler integration of the classic attractor
# --------------------------------------------------------------------

"""
    lorenz(; σ=10, ρ=28, β=8/3, dt=0.01, axis=:x,
             steps_per_cycle=100, init=(0.1, 0.0, 0.0)) -> Pattern{Float64}

Lorenz attractor. Returns the selected axis (`:x`, `:y`, or `:z`).
Canonical chaos parameters (σ=10, ρ=28, β=8/3). Typical ranges with
defaults: x ∈ [-25, 25], y ∈ [-30, 30], z ∈ [0, 60].
"""
function lorenz(; σ::Real = 10.0, ρ::Real = 28.0, β::Real = 8/3,
                  dt::Real = 0.01, axis::Symbol = :x,
                  steps_per_cycle::Int = 100,
                  init::Tuple{<:Real,<:Real,<:Real} = (0.1, 0.0, 0.0))
    axis in (:x, :y, :z) || throw(ArgumentError("lorenz axis must be :x, :y, or :z"))
    x = Ref(Float64(init[1])); y = Ref(Float64(init[2])); z = Ref(Float64(init[3]))
    σf = Float64(σ); ρf = Float64(ρ); βf = Float64(β); dtf = Float64(dt)
    step! = () -> begin
        xv, yv, zv = x[], y[], z[]
        x[] = xv + dtf * (σf * (yv - xv))
        y[] = yv + dtf * (xv * (ρf - zv) - yv)
        z[] = zv + dtf * (xv * yv - βf * zv)
        nothing
    end
    read = axis === :x ? () -> x[] :
           axis === :y ? () -> y[] :
                         () -> z[]
    _chaos_pattern(step!, read, steps_per_cycle)
end

# --------------------------------------------------------------------
# Hénon (2D discrete map)
# --------------------------------------------------------------------

"""
    henon(; a=1.4, b=0.3, axis=:x,
            steps_per_cycle=64, init=(0.1, 0.0)) -> Pattern{Float64}

Hénon map. Defaults are the canonical chaotic parameters. x ∈ ~[-1.5, 1.5].
"""
function henon(; a::Real = 1.4, b::Real = 0.3, axis::Symbol = :x,
                 steps_per_cycle::Int = 64,
                 init::Tuple{<:Real,<:Real} = (0.1, 0.0))
    axis in (:x, :y) || throw(ArgumentError("henon axis must be :x or :y"))
    x = Ref(Float64(init[1])); y = Ref(Float64(init[2]))
    af = Float64(a); bf = Float64(b)
    step! = () -> begin
        xv, yv = x[], y[]
        x[] = 1.0 - af * xv * xv + yv
        y[] = bf * xv
        nothing
    end
    read = axis === :x ? () -> x[] : () -> y[]
    _chaos_pattern(step!, read, steps_per_cycle)
end

# --------------------------------------------------------------------
# Logistic (1D discrete map)
# --------------------------------------------------------------------

"""
    logistic(; r=3.9, steps_per_cycle=64, init=0.5) -> Pattern{Float64}

Logistic map x ↦ r·x·(1-x). r ∈ [3.57, 4] is chaotic. x ∈ (0, 1).
"""
function logistic(; r::Real = 3.9, steps_per_cycle::Int = 64,
                    init::Real = 0.5)
    0.0 < Float64(init) < 1.0 ||
        throw(ArgumentError("logistic init must be in (0, 1)"))
    x = Ref(Float64(init))
    rf = Float64(r)
    step! = () -> begin
        x[] = rf * x[] * (1.0 - x[])
        nothing
    end
    read = () -> x[]
    _chaos_pattern(step!, read, steps_per_cycle)
end

# --------------------------------------------------------------------
# Rössler (3D continuous)
# --------------------------------------------------------------------

"""
    rossler(; a=0.2, b=0.2, c=5.7, dt=0.05, axis=:x,
              steps_per_cycle=100, init=(0.1, 0.0, 0.0)) -> Pattern{Float64}

Rössler attractor. Single chaotic loop; smoother than Lorenz.
"""
function rossler(; a::Real = 0.2, b::Real = 0.2, c::Real = 5.7,
                   dt::Real = 0.05, axis::Symbol = :x,
                   steps_per_cycle::Int = 100,
                   init::Tuple{<:Real,<:Real,<:Real} = (0.1, 0.0, 0.0))
    axis in (:x, :y, :z) || throw(ArgumentError("rossler axis must be :x, :y, or :z"))
    x = Ref(Float64(init[1])); y = Ref(Float64(init[2])); z = Ref(Float64(init[3]))
    af = Float64(a); bf = Float64(b); cf = Float64(c); dtf = Float64(dt)
    step! = () -> begin
        xv, yv, zv = x[], y[], z[]
        x[] = xv + dtf * (-yv - zv)
        y[] = yv + dtf * (xv + af * yv)
        z[] = zv + dtf * (bf + zv * (xv - cf))
        nothing
    end
    read = axis === :x ? () -> x[] :
           axis === :y ? () -> y[] :
                         () -> z[]
    _chaos_pattern(step!, read, steps_per_cycle)
end

# --------------------------------------------------------------------
# Standard map (2D area-preserving discrete)
# --------------------------------------------------------------------

"""
    standard(; K=0.971635, axis=:p,
               steps_per_cycle=64, init=(0.1, 0.1)) -> Pattern{Float64}

Chirikov standard map. K ≈ 0.971635 is the critical chaos threshold.
`axis=:p` returns momentum (unbounded), `axis=:θ` returns angle [0, 2π).
"""
function standard(; K::Real = 0.971635, axis::Symbol = :p,
                    steps_per_cycle::Int = 64,
                    init::Tuple{<:Real,<:Real} = (0.1, 0.1))
    axis in (:p, :θ, :theta) || throw(ArgumentError("standard axis must be :p, :θ, or :theta"))
    p = Ref(Float64(init[1])); θ = Ref(Float64(init[2]))
    Kf = Float64(K); twoπ = 2π
    step! = () -> begin
        p[] = p[] + Kf * sin(θ[])
        θ[] = mod(θ[] + p[], twoπ)
        nothing
    end
    read = axis === :p ? () -> p[] : () -> θ[]
    _chaos_pattern(step!, read, steps_per_cycle)
end

# --------------------------------------------------------------------
# Self-register the built-ins so `list_chaos()` reports them.
# --------------------------------------------------------------------
register_chaos!(:lorenz,   lorenz)
register_chaos!(:henon,    henon)
register_chaos!(:logistic, logistic)
register_chaos!(:rossler,  rossler)
register_chaos!(:standard, standard)

end # module Chaos

# `chaos.lorenz()` JS-style namespace alias for the lowercase preference.
const chaos = Chaos
