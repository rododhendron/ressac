# Synth DSL — Julia → SuperCollider

The DSL lets you describe a SynthDef as a pipe-chained Julia
expression and compile it to SC at load time. Auto-loaded into Main,
no `using` needed.

## Minimal — 3 tokens

```julia
@synth :bare saw(:freq)
```

Auto-fills `freq=220, sustain=0.5, gain=0.5`, appends an
`Env.linen(0.01, sustain, 0.1)` envelope, multiplies by `:gain`, and
routes through DirtPan. The compiled SC ships to SuperCollider on
the same OSC path that `T` uses.

## Explicit params

```julia
@synth :acid (freq=80, cutoff=2000, q=0.3)
    saw(:freq) |> rlpf(:cutoff, :q) |> tanh_drive(1.5)
```

Symbol references (`:freq`, `:cutoff`) become SC arg names, so the
caller can drive them live from patterns: `@d1 :acid |> n("0 3 5")`.

## Drones — disable auto-env

```julia
@synth :pad (freq=110, sustain=999) (auto_env=false,)
    saw(:freq) |> low_pass(800) |> stereo_pan(0)
```

## UGen surface

| Category   | Examples                                                          |
| ---------- | ----------------------------------------------------------------- |
| Osc        | `saw sin_osc pulse tri square var_saw blip formant`               |
| Noise      | `white pink brown gray dust crackle lf_noise0/1/2`                |
| LFOs       | `lfo lfo_saw lfo_tri lfo_pulse lf_cub lf_par`                     |
| Lines      | `line x_line ramp_kr lag_kr/2/3`                                  |
| Filters    | `low_pass high_pass band_pass band_reject rlpf rhpf moog_ff`      |
| Reverb     | `free_verb g_verb decay decay2`                                   |
| Delays     | `delay_n/l/c comb_n/l/c allpass_n/l/c`                            |
| Modulation | `chorus flanger phaser`                                           |
| Granular   | `grain_buf warp1`                                                 |
| Stereo     | `stereo_pan stereo_balance stereo_rotate splay mix_sigs`          |
| Shaping    | `tanh_drive soft_clip cubic clip fold wrap decimator`             |
| Envelopes  | `env_perc env_linen env_adsr env_asr env_cutoff env_sine`         |
| Triggers   | `trig_kr t_delay pitch_shift freq_shift vibrato_sig`              |
| Buffers    | `play_buf buf_rd`                                                 |
| Demand     | `demand_seq demand_white t_rand`                                  |

## Arithmetic on Sig

`+ - * /` are overloaded for `Sig × Sig`, `Sig × Real`, `Sig × Symbol`,
`Symbol × Real` (Symbols stand in for SynthDef args). So `:freq * 2`
inside an expression compiles to `(freq * 2)` in SC.

## Cookbook

```julia
# Kick
@synth :kick (sustain=0.4)
    sin_osc(line(120, 40, 0.05)) |> env_perc(0.001, :sustain)

# FM bell
@synth :fmbell (freq=440, sustain=1.5)
    sin_osc(:freq + sin_osc(:freq * 1.41) * line(800, 50, 0.5))
    |> env_perc(0, :sustain)

# Acid bass with env on cutoff
@synth :acid (freq=60, sustain=0.3)
    saw(:freq) |> rlpf(line(3000, 500, :sustain), 0.18)
    |> tanh_drive(2)

# Karplus-Strong pluck
@synth :pluck (freq=220, sustain=1.5)
    white() |> env_perc(0, 0.005)
    |> comb_l(1 / :freq, :sustain, 0.05)
    |> low_pass(:freq * 4)

# Lush detuned pad
@synth :pad (freq=220, sustain=4) (auto_env=false,)
    (saw(:freq) + saw(:freq * 1.007) + saw(:freq * 0.993))
    |> low_pass(2000) |> free_verb(0.5, 0.9, 0.5)

# Wobble with chorus
@synth :wob (freq=80) (auto_env=false,)
    saw(:freq) |> rlpf(lfo(4; low=400, high=2000), 0.3)
    |> chorus(0.4, 0.003, 0.6)

# Metallic flange
@synth :metal (freq=220, sustain=0.5)
    pulse(:freq, 0.4) |> flanger(0.15, 0.008, 0.6)
    |> env_perc(0.001, :sustain)

# Classic 70s phaser sweep
@synth :sweepy (freq=220, sustain=2)
    saw(:freq) |> phaser(0.3, 800) |> env_linen(0.01, :sustain, 0.2)
```

## Built-in library

`:lib` (or `Space L`) shows every synth ready to play, including a
909-style drum kit you can grab with `@d1 "k909 ~ s909 ~"`:

- **perc**: `kick hihat snare clap glitchhat kickbrut`
- **tr909**: `k909 s909 hh909 oh909 cp909 rim909 ride909 tom909`
- **bass**: `subdrop acid303 rezzbass growlbass chompy`
- **lead**: `fmbell bellsynth plucky`
- **pad**: `softpad airpad glasspad ghostpad`
- **darksynth**: `kickbrut darklead arpdriver darkpad`
- **witch**: `dustbass screwlead ghostpad`
- **lofi**: `lofibass lofikey mellowfm chordstab vinylcrackle`
- **fx**: `lazerzap darkriser`

`Space` previews a synth in the picker; `Enter` opens it as a tab
for editing (the source is a DSL recipe — change and `T` to hear).

## Inspect without playing

```julia
synth_source(:foo, saw(:freq); params=(freq=440,))
# → returns the SC SynthDef string without sending it
```
