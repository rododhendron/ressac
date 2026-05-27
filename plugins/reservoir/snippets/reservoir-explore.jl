# ╭─ reservoir — every knob exposed, eval lines selectively ─╮
# │  AdEx neurons + RECA cellular automaton, three routes.
# │  Hit `e` on the line / block you want. Change params live,
# │  hit `e` again — cascade re-eval rewires @dN automatically.
# ╰────────────────────────────────────────────────────────────╯
cps!(0.5)

# ── AdEx reservoir construction ────────────────────────────
# N                    = number of neurons (8..256 reasonable)
# params               = AdExParams. Built-in regimes (Brette & Gerstner 2005):
#                        ADEX_TONIC          steady rate, no adaptation
#                        ADEX_ADAPTING       fast burst, slows down
#                        ADEX_INITIAL_BURST  onset burst then quiet
#                        ADEX_REGULAR_BURST  periodic bursts
#                        ADEX_DELAYED_ACCEL  pause then ramp up
#                        ADEX_DELAYED_BURST  pause then bursts
#                        ADEX_TRANSIENT      brief onset then stops
#                        ADEX_IRREGULAR      chaotic dynamics
#                        ADEX_REGULAR / ADEX_BURSTING / ADEX_FAST  (originals)
# dt                   = simulator timestep in ms (0.5..2.0)
# steps_per_cycle      = events per cycle (200..2000 — denser = more notes)
# p_connect            = synaptic connectivity (0..1, default 0.1)
# W_gain               = synapse weight scale in pA per spike (100..500)
# V_init               = :rest (uniform) or :scattered (less synchronous)
# σ_noise              = OU baseline noise volatility (pA, 0=silent, 500+ lively)
# τ_noise              = OU correlation time (ms, 20 cortical-typical)
# inhibitory_fraction  = 0..1, fraction whose outgoing synapses
#                        are forced negative (Dale's, 0.2 cortical)
# seed                 = reproducible random connectivity
r_lead = Reservoir.adex(N=24, params=Reservoir.ADEX_FAST,
                        dt=1.0, steps_per_cycle=500,
                        p_connect=0.1, W_gain=180.0,
                        V_init=:scattered,
                        σ_noise=400.0, τ_noise=20.0,
                        inhibitory_fraction=0.2,
                        seed=42)

# ── Route I — spike → sineburst ────────────────────────────
# Each spike on neuron i fires a percussive sine at freqs[i].
# drive       = ANY of:
#                 Real           — constant current (0 silent, 400+ active)
#                 Vector         — static per-neuron drive (length=N)
#                 Function       — (cycle, step) → Real or Vector
#                 Pattern{Sym}   — p"bd ~ sn ~" pulses neurons on events
#                 Pattern{Flt}   — continuous signal broadcast per-cycle
#                 String         — auto-parses to Pattern{Sym}
# Helper functions (step units; multiply by spc for cycle units):
#   drive_const(amp)                            — same as bare Real
#   drive_sin(amp, period; offset, phase)       — sine wave
#   drive_square(amp, period; duty, offset)     — on/off pulse train
#   drive_tri(amp, period; offset)              — triangle
#   drive_ramp(low, high, period)               — sawtooth
#   drive_burst(amp, on_steps, every_steps)     — periodic bursts
#   drive_sum(d1, d2, ...)                      — additive layering
# Ex: drive = drive_sum(drive_const(400), drive_sin(200, 500))
@d1 Reservoir.spike_burst(r_lead;
    drive=500.0,
    layout=:scale,
    layout_args=(scale=:minor_pentatonic, root=220),
    burst_dur=1//16,
    gain=0.3,
    synth=:sineburst) |> gain(0.4)

# layout cheat-sheet:
#   :logfreq  → log-uniform between lo, hi   (layout_args = (;))
#   :scale    → musical scale degrees       (layout_args = (scale=:dorian, root=110))
#                scales: :minor_pentatonic :major_pentatonic :dorian :phrygian
#                        :lydian :mixolydian :natural_minor :harmonic_minor
#                        :whole_tone :chromatic  (+ many more in Ressac._SCALES)
#   :harmonic → i · fund                    (layout_args = (fund=110,))
#   :cluster  → dense around center         (layout_args = (center=880, spread=0.2))

# ── RECA reservoir (cellular automaton) ────────────────────
# rule  = Wolfram rule 0..255 :  30 chaos · 90 Sierpinski · 110 edge
#                                184 traffic · 54 class-IV complex
# N     = cells (16..256)
# init  = :single (one cell on), :rand (50%), :zero (need input)
r_reca = Reservoir.reca(N=24, rule=110, init=:rand,
                        boundary=:wrap, steps_per_cycle=8, seed=7)

@d2 Reservoir.spike_burst(r_reca;
    layout=:harmonic, layout_args=(fund=110,),
    burst_dur=1//32, gain=0.25) |> gain(0.4)

# ── Route II — spectral cloud (additive resynthesis) ───────
# Instead of one sine per spike, fire one CHORD of 16 partials
# per frame, with each partial's amplitude driven by a neuron.
# Result: an evolving pad / drone whose spectrum tracks the
# reservoir state. Great for textures, not for rhythm.
#
# bins              = partial count (must match SynthDef — 16 ships built-in)
# frames_per_cycle  = chord refresh rate per cycle (4..16, 8 default)
# layout            = same as Route I — applied to the 16 bins
# amplitude_kind    = which state drives amps: :auto (V for AdEx, bit for RECA)
#                     :V :w :spike :density :bit
# amplitude_scale   = post-transform fn; :auto clip-normalises into [0,1]
# overlap           = envelope sustain ×  (1.0=abut, 2.0=50% xfade)
# drive             = same as Route I (any form)
r_spec = Reservoir.reca(N=16, rule=30, init=:rand, steps_per_cycle=16)
@d3 Reservoir.spectral_cloud(r_spec;
    bins=16,
    frames_per_cycle=8,
    layout=:harmonic, layout_args=(fund=110,),
    amplitude_kind=:auto, amplitude_scale=:auto,
    overlap=2.0, gain=0.3) |> gain(0.3)

# ── Route III — scalar modulator ───────────────────────────
# Read ONE neuron's state as a continuous control signal.
# Plugs into `set(:any_param, …)` like sine() or perlin() —
# you're using neural dynamics to modulate any synth param.
#
# neuron  = which to read (1..N)
# kind    = :auto (V for AdEx, bit for RECA) · :V :w :spike :density :bit
# scale   = post-transform fn (identity by default, e.g. abs, x->x/70)
# drive   = same as Route I (any form) — keeps neurons active
r_mod = Reservoir.adex(N=8, σ_noise=400.0, seed=99)
@d4 :supersaw |> n(p"0 ~ 5 ~ 7 ~ 3 ~") |> set(:cutoff,
    Reservoir.modulator(r_mod, neuron=3, kind=:V,
                         scale=identity, drive=500.0)
    |> range_pat(400, 4000)) |> gain(0.5)

# ── Anchor ──────────────────────────────────────────────────
@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.3)
@d10 p"hh*8" |> gain(0.2) |> hpf(4000)