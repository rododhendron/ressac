# Layouts — map neuron index 1..N to a frequency. Used by route_spike
# to decide which note a given neuron's spike produces.
#
# A layout is just a function `(N, lo, hi; kwargs...) -> Vector{Float64}`.
# Built-ins below; plugins add more with `register_layout!`.

# The reservoir's layout :scale reuses Ressac's core `_SCALES` dict so
# both `:scale <name>` (mini-notation) and `layout=:scale` see the same
# library. Adding a scale in core_controls.jl makes it available here
# without changing this file.
const SCALES = Ressac._SCALES

"Logarithmic spread between `lo` and `hi` — perceptually even pitches."
function _layout_logfreq(N::Int, lo::Real, hi::Real; kwargs...)
    N == 1 && return [Float64(lo)]
    [Float64(lo) * (Float64(hi) / Float64(lo))^((i - 1) / (N - 1)) for i in 1:N]
end

"Quantised to a musical scale, repeating across octaves above `root`."
function _layout_scale(N::Int, lo::Real, hi::Real;
                       scale::Symbol = :minor_pentatonic,
                       root::Real = 220.0, kwargs...)
    intervals = get(SCALES, scale) do
        throw(ArgumentError("unknown scale $scale — known: $(sort!(collect(keys(SCALES))))"))
    end
    k = length(intervals)
    root_f = Float64(root)
    [root_f * 2.0^(((i - 1) ÷ k) + intervals[((i - 1) % k) + 1] / 12.0) for i in 1:N]
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
