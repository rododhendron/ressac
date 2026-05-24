# Cookbook

Recipes for common live-coding moves. Drop them into the patterns
pane, eval with `e` or `:e`.

## Build a beat from scratch

```julia
cps!(0.5)
@d1 p"bd ~ bd ~"               # kick on 1+3
@d2 p"~ cp ~ cp"               # clap on 2+4
@d3 p"hh*8" |> gain(0.4)       # hat 8ths
```

Layer a bass:

```julia
@d4 :subdrop |> n(p"0 ~ -2 ~ 0 ~ 5 ~") |> gain(0.6)
```

Add motion:

```julia
@d3 p"hh(7,16)" |> gain(0.4)   # replace plain 8ths with Euclidean
@d2 p"~ cp ~ [cp*2]"           # double the second clap
```

## Genre starters via snippet

```
:snip → jersey       Jersey club bounce
       → footwork    160 BPM fast hats
       → trap        rolling hi-hats + 808
       → boombap     classic hip-hop
       → drill       UK drill triplets
       → phonk       cowbell + 808 slides
       → witch_house slow + eerie
```

## Quick sound design

Sandbox synth:

```
:synth         → opens a fresh DSL tab with a starter
```

Edit, `t` to test, `:w mysynth` to save under a real name.

From the library:

```
:lib           → 30 starters in DSL + 1 raw SC reference
```

Direct via DSL:

```julia
@synth :wob (freq=80) saw(:freq) |>
    rlpf(lfo(6; low=300, high=2000), 0.25)
```

## Modulate live

Set/tweak a synth's parameter directly from a pattern:

```julia
@d1 :wob |> n(p"0 0 5 7") |> set(:rate, p"<4 6 8 12>")
```

Time-pattern values (`p"<...>"`) advance one slot per cycle, so the
LFO rate steps through 4 → 6 → 8 → 12 every bar.

## Polyrhythmic textures

```julia
@d1 p"bd*3"          # 3 hits per bar
@d2 p"sn*4" |> gain(0.5)
@d3 p"hh*5" |> gain(0.3)
```

Or Euclidean:

```julia
@d1 p"bd(3,8)"
@d2 p"sn(5,16)" |> gain(0.6)
@d3 p"hh(7,16)" |> gain(0.4)
```

## Filter sweeps

```julia
@d1 :acid303 |> n(p"0 3 5 7") |> set(:cutoff, p"<400 800 1600 3200>")
```

## Dub-style FX chain

```julia
@d1 p"bd ~ sn ~" |> delay(0.5) |> delaytime(0.375) |>
    delayfeedback(0.6) |> room(0.7)
```

## Tap a rhythm with your hands

```
:tap          → enter tap mode
Space Space Space ...     tap the rhythm
Enter         → commits as @d<next> p"..."
Esc           → cancel
```

## Play a melody on the keyboard

```
:piano-rec fmbell
```

Then letter keys play notes (z/x/c/v/b/n/m = naturals,
s/d/g/h/j = sharps), `[` `]` shift octave, Enter commits the
recorded notes as `@dN :fmbell |> n(p"…")`.

## Export a sound to WAV

```
:export 6     → records the current synth tab for 6s,
                writes to ./recordings/<name>_<timestamp>.wav
```

Or record a longer take from the master:

```
:rec start mytrack
... play ...
:rec stop     → ./recordings/mytrack.wav
```
