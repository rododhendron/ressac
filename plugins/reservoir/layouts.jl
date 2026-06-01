# Layouts — map neuron index 1..N to a frequency. Used by route_spike
# to decide which note a given neuron's spike produces.
#
# A layout is just a function `(N, lo, hi; kwargs...) -> Vector{Float64}`.
# Built-ins below; plugins add more with `register_layout!`.

# The reservoir's layout :scale reuses Ressac's core scale registry
# so any registered scale (built-in, plugin-contributed, or user-
# defined) works here. Scales are `Scale` values with `cents` and
# `period_cents`, so we stack periods (not octaves) for xenharmonic
# correctness.

"Logarithmic spread between `lo` and `hi` — perceptually even pitches."
function _layout_logfreq(N::Int, lo::Real, hi::Real; kwargs...)
    N == 1 && return [Float64(lo)]
    [Float64(lo) * (Float64(hi) / Float64(lo))^((i - 1) / (N - 1)) for i in 1:N]
end

"Quantised to a musical scale, repeating across periods above `root`."
function _layout_scale(N::Int, lo::Real, hi::Real;
                       scale::Symbol = :minor_pentatonic,
                       root::Real = 220.0, kwargs...)
    s = Ressac.lookup_scale(scale)
    s === nothing &&
        throw(ArgumentError("unknown scale $scale — known: $(Ressac.list_scales())"))
    k = length(s.cents)
    root_f = Float64(root)
    period_octaves = s.period_cents / 1200.0
    [root_f * 2.0^(((i - 1) ÷ k) * period_octaves +
                   s.cents[((i - 1) % k) + 1] / 1200.0) for i in 1:N]
end

"Harmonic series above `fund` (i·fund). `lo`/`hi` ignored."
function _layout_harmonic(N::Int, lo::Real, hi::Real;
                          fund::Real = 110.0, kwargs...)
    fund_f = Float64(fund)
    [fund_f * i for i in 1:N]
end

"""
Dense cluster around `center` with relative half-width `spread`
(fraction of `center`). `lo`/`hi` ignored. Linear spacing.
"""
function _layout_cluster(N::Int, lo::Real, hi::Real;
                         center::Real = 880.0, spread::Real = 0.2, kwargs...)
    cf = Float64(center); sf = Float64(spread)
    N == 1 && return [cf]
    [cf * (1.0 + sf * (2.0 * (i - 1) / (N - 1) - 1.0)) for i in 1:N]
end

register_layout!(:logfreq,  _layout_logfreq)
register_layout!(:scale,    _layout_scale)
register_layout!(:harmonic, _layout_harmonic)
register_layout!(:cluster,  _layout_cluster)

"""
    compute_layout(name::Symbol, N::Int, lo::Real, hi::Real; kwargs...)

Resolve a layout name to a frequency vector. Looks up in the layout
registry — built-ins are `:logfreq`, `:scale`, `:harmonic`, `:cluster`.
Pass layout-specific keyword args via `kwargs`.
"""
function compute_layout(name::Symbol, N::Int, lo::Real, hi::Real; kwargs...)
    haskey(_LAYOUT_REGISTRY, name) ||
        throw(ArgumentError("unknown layout '$name' — known: $(list_layouts())"))
    _LAYOUT_REGISTRY[name](N, lo, hi; kwargs...)
end
