# Chaos & Reservoir

Ressac ships two plugins that turn dynamical systems into musical
material: **chaos** (chaotic generators as patterns) and **reservoir**
(spiking neural / cellular-automaton reservoirs that drive synth
events). Both follow the standard plugin architecture, so the same
patterns can be extended by community plugins.

> **Just want to hear it?** Type one of these in the TUI:
> `:starter chaos` · `:starter reservoir-spike` ·
> `:starter reservoir-spectral` · `:starter reservoir-mix`.
> Each loads a 4-8 line demo ready to eval with `E`.

There's also a parallel **audio-rate** chaos surface inside the synth
DSL (see [03-synth-dsl](03-synth-dsl.md) §Chaotic / nonlinear sources)
— that one is for chaos *inside* SynthDefs, computed by SuperCollider.
This page is about the **Julia-side** chaos and reservoir generators,
which emit patterns the scheduler ships to SC over OSC.

```
                  control-rate (Julia)          audio-rate (SC)
                  ─────────────────────         ────────────────
chaos plugin      Pattern{Float64} sources      ─
                  modulate pattern params
synth DSL         ─                             lorenz(), henon(), …
                  use inside @synth as you would white() / saw()
reservoir plugin  Pattern{ControlMap} sources   (none yet — Routes II
                  fire SC events from spikes    + III synthesise via
                                                regular SynthDefs)
```

## chaos plugin

Five built-in chaotic systems, each returning a `Pattern{Float64}`:

| Name          | Type                      | Output                  |
| ------------- | ------------------------- | ----------------------- |
| `lorenz`      | 3D continuous attractor   | `:x`, `:y`, or `:z` axis |
| `henon`       | 2D discrete map           | `:x` or `:y`            |
| `logistic`    | 1D discrete map           | scalar                  |
| `rossler`     | 3D continuous attractor   | `:x`, `:y`, or `:z`     |
| `standard`    | Chirikov standard map     | `:p` (momentum) or `:θ` |

```julia
# Direct use
p = Chaos.lorenz(σ=10, ρ=28, β=8/3, axis=:x)
p(0//1, 1//1)   # => [Event{Float64}(...)]

# Sweep a filter cutoff
@d1 :acid303 |> set(:cutoff, Chaos.lorenz() |> range_pat(400, 4000))

# Discretise to N steps per cycle
@d2 :pad |> set(:room, Chaos.henon() |> segment(8) |> range_pat(0.1, 0.7))
```

### Discretising / scaling

A continuous chaos pattern emits one event per query covering the
whole arc. Combine with:

- `segment(N)` — N discrete samples per cycle
- `range_pat(lo, hi)` — linearly remap into `[lo, hi]`
- `slow(N)` / `fast(N)` — rescale chaos time vs. musical time

### State semantics

Each call to `Chaos.lorenz(...)` builds a fresh, independent state.
Queries are stateful (forward integration) — re-querying the same
window returns the same value; querying further advances the system.

### Extending — registering a new chaos system

Plugins (or live code) can add new generators:

```julia
function mychaos(; r=3.9, init=0.5)
    state = Ref(init)
    Ressac.Pattern{Float64}((s, e) -> begin
        state[] = r * state[] * (1 - state[])
        [Ressac.Event{Float64}(s, e, state[])]
    end)
end

Chaos.register_chaos!(:mychaos, mychaos)
@test :mychaos in Chaos.list_chaos()
```

## reservoir plugin

Two reservoir kinds and three routes, all composable.

### Reservoir kinds

**AdEx** — adaptive exponential integrate-and-fire spiking neurons
(Brette & Gerstner 2005). Rich firing patterns depending on params:

```julia
r = Reservoir.adex(
    N=64,                         # number of neurons
    params=ADEX_BURSTING,         # also ADEX_REGULAR (default), ADEX_FAST
    dt=1.0,                       # ms per simulation step
    steps_per_cycle=1000,         # → ~1 sec of neural time per Ressac cycle
    p_connect=0.1,                # sparse recurrent connectivity
    W_gain=180.0,                 # synaptic weight scale (pA per spike)
    V_init=:scattered,            # uniform-random V at boot (less synchronous)
    σ_noise=400.0,                # OU baseline noise volatility (pA)
    τ_noise=20.0,                 # OU correlation time (ms)
    inhibitory_fraction=0.2,      # Dale's principle: 20% inhibitory units
    seed=42,
)
```

**OU baseline noise** (`σ_noise`, `τ_noise`) injects coloured noise as
extra current each step. With `σ_noise = 0` neurons sit silent at rest;
with `σ_noise ≈ 400-600` V hovers near threshold — any external drive
arriving on top synchronises the population. Mimics the in-vivo
"high-conductance state" where cortical neurons are constantly noisy
and become rhythmically active under thalamic drive.

**Dale's principle** (`inhibitory_fraction`) marks a fraction of neurons
as inhibitory — their outgoing weights are forced negative. `0.0`
(default) keeps random-signed weights; `0.2` is cortical-typical (80% E,
20% I).

### Flexible drive sources

The `drive` kwarg on every route accepts any of these forms:

| Form | Example | Effect |
| ---- | ------- | ------ |
| `Real` | `drive=500.0` | constant pA current to all neurons |
| `Vector` | `drive=[100,200,...]` | static per-neuron (length N) |
| `Function` | `drive=(c,s) -> 400+200*sin(2π*s/500)` | called per step, returns Real or Vector |
| `Pattern{Symbol}` | `drive=p"bd ~ sn ~"` | each event pulses neuron `hash(value) % N + 1` for 10 steps |
| `Pattern{Float64}` | `drive=sine() \|> range_pat(0,600)` | continuous signal sampled per cycle, broadcast |

**RECA** — Reservoir Computing with Elementary Cellular Automata
(Yilmaz 2014). 1D bit array evolving under a Wolfram rule:

```julia
r = Reservoir.reca(
    N=128,
    rule=110,                     # any of 0..255 — see notes below
    init=:single,                 # :rand or :zero
    boundary=:wrap,               # :zero for non-toroidal
    steps_per_cycle=16,
    seed=42,
)
```

Interesting rules to try:
- `30` — fully chaotic, the canonical RC reservoir
- `90` — Sierpinski triangle from a single cell
- `110` — Turing-complete, edge of chaos
- `184` — traffic flow, very ordered
- `54` — complex (class IV) behaviour

### Route I — spike → sineburst

Each spike on neuron `i` fires a percussive sine at the frequency
assigned to `i` by the chosen layout. Layouts: `:logfreq`, `:scale`,
`:harmonic`, `:cluster`.

```julia
r = Reservoir.adex(N=64, params=ADEX_BURSTING, seed=42)
@d1 Reservoir.spike_burst(r;
    drive=600.0,                    # constant input current (pA)
    layout=:scale,
    layout_args=(scale=:minor_pentatonic, root=220),
    burst_dur=1//16,                # event sustain (cycles)
    gain=0.5,
)
```

Available scales for `layout=:scale`:
`minor_pentatonic major_pentatonic dorian phrygian lydian
mixolydian natural_minor harmonic_minor whole_tone chromatic`

### Route II — spectral cloud (additive resynthesis)

Fires `frames_per_cycle` events per cycle, each carrying 16 partial
amplitudes sampled from the reservoir state. Cross-fade smooths
frame transitions.

```julia
r = Reservoir.reca(N=16, rule=110, init=:single)
@d2 Reservoir.spectral_cloud(r;
    bins=16,                        # matches the specloud16 SynthDef
    frames_per_cycle=8,
    layout=:harmonic,
    layout_args=(fund=110,),
    overlap=2.0,                    # 1.0 = abutting, 2.0 = 50% cross-fade
    gain=0.3,
)
```

For AdEx, the amplitude is read from `:V` (membrane potential) with a
default clip-and-normalise into `[0, 1]`. For RECA it's the bit state
(0 or 1). Customise via `amplitude_kind` and `amplitude_scale`.

### Route III — scalar modulator

Read one neuron's state as a continuous control signal — drop it
into any `set(:param, …)` call.

```julia
r = Reservoir.adex(N=16, seed=1)
mod = Reservoir.modulator(r,
    neuron=5,
    kind=:V,                        # or :w, :spike, :density
    drive=500.0,
    scale=identity,                 # post-transform Float64 → Float64
) |> range_pat(400, 4000)

@d3 p"bd*4" |> set(:cutoff, mod)
```

Per-type `kind` cheatsheet:
- **AdEx**: `:V` membrane potential · `:w` adaptation · `:spike` last-step bool · `:density` fraction active
- **RECA**: `:bit` cell state · `:spike` last-step bool · `:density` fraction active

### The interface contract

A "reservoir kind" is any value implementing:

```julia
step!(r, input::AbstractVector{Float64})        # advance one step
spikes(r) -> AbstractVector{Bool}               # who fired this step
Base.length(r) -> Int                           # number of units
steps_per_cycle(r) -> Int                       # cycle ↔ step resolution
read_state(r, kind::Symbol, neuron::Int) -> Float64
default_modulator_kind(r) -> Symbol             # what `:auto` resolves to
```

Implement these and call `Reservoir.register_reservoir!(:mykind, ctor)` —
your reservoir inherits Routes I/II/III with zero extra code.

### Layouts (frequency mapping)

Layouts decide which note each neuron / cell maps to in Routes I & II.
Built-ins:

| Name        | Behavior                                  | Extra kwargs                |
| ----------- | ----------------------------------------- | --------------------------- |
| `:logfreq`  | Log-uniform between `lo` and `hi`         | —                           |
| `:scale`    | Quantised to a musical scale across octaves | `scale=`, `root=`         |
| `:harmonic` | i · fund (1f, 2f, 3f, …)                  | `fund=`                     |
| `:cluster`  | Dense linear cluster around `center`      | `center=`, `spread=`        |

Add your own:

```julia
Reservoir.register_layout!(:my_layout, (N, lo, hi; kwargs...) -> begin
    # … return Vector{Float64} of length N
end)
```

## Combining the two worlds

Audio-rate chaos UGen as voice + control-rate reservoir as modulator:

```julia
# A custom chaos-driven bass synth …
@synth :chaobass (freq=55, sustain=0.45, drive=1.4) begin
  logistic(:freq * 8, 3.9, 0.5) |> low_pass(:freq * 8) |>
  tanh_drive(:drive) |> env_perc(0.005, :sustain)
end

# … whose `drive` param is modulated by a slow Lorenz, with notes
# triggered by AdEx spikes mapped to a minor pentatonic.
r = Reservoir.adex(N=16, params=ADEX_BURSTING, seed=42)
@d1 Reservoir.spike_burst(r; drive=600.0, layout=:scale,
                          layout_args=(scale=:minor_pentatonic, root=110),
                          synth=:chaobass) |>
   set(:drive, Chaos.lorenz() |> range_pat(0.8, 2.4))
```

## Reference: where things live

```
plugins/chaos/                    Julia-side chaos generators
├── chaos.jl                      module Chaos + 5 systems
└── plugin.toml

plugins/reservoir/                Reservoir + 3 routes
├── reservoir.jl                  module Reservoir + interface contract
├── adex.jl                       AdEx neurons + AdExReservoir
├── reca.jl                       Elementary CA reservoir
├── layouts.jl                    Frequency layouts (logfreq/scale/...)
├── route_spike.jl                Route I — spike → burst
├── route_modulator.jl            Route III — scalar readout
├── route_spectral.jl             Route II — additive resynthesis
├── sineburst.scd                 Route I voice
├── specloud16.scd                Route II voice (16 additive partials)
└── plugin.toml

src/synth_dsl.jl                  Audio-rate chaos UGens (in DSL)
└── lorenz/henon/.../cusp         sc3-plugins wrappers
```
