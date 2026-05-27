# Route III — reservoir as scalar modulator.
#
# Returns a `Pattern{Float64}` that, on query, advances the reservoir
# to the END of the query window and emits a single event over the arc
# carrying a scalar read out of one of its state variables. Compose
# with `range_pat(lo, hi)` to remap and with `set(:param, …)` (or any
# of the SuperDirt control combinators) to modulate a synth parameter
# at note-on time.
#
# This is the same "continuous signal" pattern shape as `sine()`,
# `perlin()`, `chaos.lorenz()`, so it slots into existing pipelines
# with no special handling at the scheduler level.

"Default bipolar normaliser per reservoir kind + readout. Used when
`modulator(scale=:auto)` so the output sits in [-1, 1] and composes
with `range_pat(lo, hi)` out of the box."
_default_modulator_scale(::AdExReservoir, kind::Symbol) =
    # AdEx :V swings ~[-70, +20] mV. Centre at -25 mV (mid-range),
    # half-width 45 mV, then clamp to [-1, +1] so spike upswings don't
    # punch past the target range.
    kind === :V       ? v -> clamp((v + 25.0) / 45.0, -1.0, 1.0) :
    kind === :w       ? v -> clamp(v / 200.0, -1.0, 1.0) :
    kind === :spike   ? v -> 2v - 1.0 :
    kind === :density ? v -> 2v - 1.0 :
                         identity

_default_modulator_scale(::RECAReservoir, kind::Symbol) =
    # RECA always emits 0/1 ; map to -1/+1.
    kind === :bit     ? v -> 2v - 1.0 :
    kind === :spike   ? v -> 2v - 1.0 :
    kind === :density ? v -> 2v - 1.0 :
                         identity

"""
    modulator(r; neuron=1, kind=:auto, scale=:auto,
              drive=0.0) -> Pattern{Float64}

Build a scalar modulator from reservoir `r`.

- `neuron`  which neuron / cell to read (1..length(r))
- `kind`    which scalar to read. `:auto` picks each type's default
            (AdEx → `:V`, RECA → `:bit`). Other kinds depend on type:
            see `read_state` docstring for each.
- `scale`   `:auto` (default) normalises the raw reading into `[-1, 1]`
            so `|> range_pat(lo, hi)` remaps cleanly. Pass `identity` to
            get the raw value (mV for AdEx :V, 0/1 for RECA :bit, …),
            or any `Float64 -> Float64` for custom mapping.
- `drive`   constant input current / perturbation pushed into every
            neuron each step (pA for AdEx; >0.5 = XOR for RECA).

Typical use:

```julia
r = reservoir.adex(N=8, σ_noise=400)
mod = reservoir.modulator(r, neuron=3, drive=600.0) |> range_pat(400, 4000)
@d1 p"bd*4" |> set(:cutoff, mod)
```
"""
function modulator(r;
                   neuron::Int = 1,
                   kind::Symbol = :auto,
                   scale = :auto,
                   drive = 0.0)
    N = length(r)
    1 <= neuron <= N ||
        throw(BoundsError("neuron $neuron out of 1..$N"))
    actual_kind = kind === :auto ? default_modulator_kind(r) : kind
    actual_scale = scale === :auto ?
        _default_modulator_scale(r, actual_kind) : scale
    # Probe once so the caller gets an ArgumentError up front rather than
    # a deferred crash inside the first scheduler query.
    read_state(r, actual_kind, neuron)
    spc = steps_per_cycle(r)
    drive_source = _make_drive_source(drive, N, spc)
    input = Vector{Float64}(undef, N)
    last_step = Ref(0)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        target = ceil(Int, Float64(e) * spc)
        while last_step[] < target
            cycle_idx = last_step[] ÷ spc
            step_in_cycle = (last_step[] % spc) + 1
            drive_source(cycle_idx, step_in_cycle, input)
            step!(r, input)
            last_step[] += 1
        end
        v = Float64(actual_scale(read_state(r, actual_kind, neuron)))
        [Event{Float64}(s, e, v)]
    end)
end
