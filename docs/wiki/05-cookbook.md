# Cookbook

Copy-paste recipes for common live-coding moves. Drop them into the
patterns pane, eval with `e` (current line) or `E` (everything).

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

Or use Space-leader to write it faster — `Space d` expands `@d$1 p"$2"`
with placeholder navigation: type slot, Tab, type body, Esc.

## Add variation with one keystroke

The Tidal-style combinators let you mutate any pattern in place:

```julia
@d1 p"bd hh sn hh" |> jux(rev)              # stereo: L original, R reversed
@d1 p"bd hh sn hh" |> sometimes(fast(2))    # 50% of cycles double-time
@d1 p"hh*8" |> degradeBy(0.3)               # drop 30% of hits (seeded)
@d1 p"bd hh sn hh" |> iter(4)               # rotate by 1/4 each cycle
@d1 p"bd hh sn hh" |> palindrome            # forward then reverse
@d1 p"bd hh sn hh" |> chunk(4, fast(2))     # one chunk per cycle goes fast
@d1 p"bd hh sn hh" |> off(1//8, fast(2))    # overlay shifted copy
```

Or directly in mini-notation:

```julia
@d1 p"bd? hh? sn hh?"           # ?  = drop with 50% probability
@d1 p"bd?0.3 hh sn hh"           # ?N = drop with custom probability
@d1 p"bd _ _ sn"                 # _  = extend the previous slot
@d1 p"bd(3,8,2) cp(1,8,4)"       # 3rd arg = Euclidean rotation
```

## Genre starters

```
:starter house       :starter dnb        :starter jersey
:starter trap        :starter lofi       :starter dubstep
:starter idm         :starter jungle     :starter amapiano
:starter hardcore    :starter witchhouse :starter ambient
```

…and the `:snip` picker offers more under the `genre` category
(Tab to cycle): jersey, footwork, garage, breakcore, drill, dembow,
boombap, lofi_hiphop, phonk, witch_house, bossanova.

## Sidechain pumping

Without real audio sidechain (which needs SC plumbing), the recognisable
pumping sound is just a cycle-locked gain curve:

```julia
@d1 :super808 |> n(p"0 ~ ~ 0") |> gain(1.2)    # kick on 1+3
@d2 :supersaw |> n(p"-7 -5 -3 -7") |> pump(8, 0.7) |> gain(0.6)
#                                       └── 8 ducks per cycle, depth 0.7
```

The pad audibly ducks on every kick beat — what most users want
when they say "sidechain".

## Filter sweeps and LFO motion

Time-pattern values (`p"<...>"`) advance one slot per cycle:

```julia
@d1 :acid303 |> n(p"0 3 5 7") |> set(:cutoff, p"<400 800 1600 3200>")
```

`<>` rotates each cycle; combine with cycle-multipliers for slow sweeps:

```julia
@d1 :supersaw |> set(:cutoff, p"<400 800 1200 2000 1200 800>" |> slow(2))
```

## Modulation effects (DSL synth design)

```julia
:synth wob
@synth :wob (freq=80) (auto_env=false,)
    saw(:freq) |> rlpf(lfo(4; low=300, high=2400), 0.3)
    |> chorus(0.4, 0.003, 0.5)

# Then in patterns:
@d1 :wob |> n(p"-12 -7 -12 -10") |> gain(0.7)
```

Three modulated-delay effects exposed as DSL helpers:

```julia
saw(:freq) |> chorus(rate=0.5, depth=0.002, mix=0.5)
saw(:freq) |> flanger(rate=0.2, depth=0.005, feedback=0.3)
saw(:freq) |> phaser(rate=0.3, depth=800)
```

## 909-style drum kit (built-in synth library)

The `tr909` synth library category gives you editable 909 voices:

```julia
@d1 p"k909 ~ s909 ~"                          # kick + snare on 2/4
@d2 p"hh909*8" |> gain(0.4)                   # closed hats
@d3 p"~ ~ ~ ~ ~ ~ oh909 ~" |> gain(0.5)       # open hat fill
@d4 p"~ ~ cp909 ~" |> room(0.3)               # clap with verb
@d5 p"tom909(3,8)" |> n(p"<-5 0 5 12>")       # tom fill cycling pitch
```

Open them in tabs (`:lib`, find e.g. `k909`, Enter) to edit the
underlying DSL recipe.

## Polyrhythmic textures

```julia
@d1 p"bd*3"          # 3 hits per bar
@d2 p"sn*4" |> gain(0.5)
@d3 p"hh*5" |> gain(0.3)
```

Or Euclidean for the rolling-pulse feel:

```julia
@d1 p"bd(3,8)"
@d2 p"sn(5,16)" |> gain(0.6)
@d3 p"hh(7,16)" |> gain(0.4)
```

Add rotation to offset each layer:

```julia
@d1 p"bd(3,8,0)"
@d2 p"cp(1,8,4)"     # clap on beat 3
@d3 p"hh(11,16,2)"
```

## Dub-style FX chain

```julia
@d1 p"bd ~ sn ~" |> delay(0.5) |> delaytime(0.375) |>
    delayfeedback(0.6) |> room(0.7)
```

`Space D` expands the whole delay-chain template at once.

## Tap a rhythm with your hands

```
:tap                                    # start tap recording
Space Space Space ...                   # tap the rhythm twice (loop detection)
Enter                                   # commits as cps!() + @dN p"..."
                                        # and evals immediately
```

The status bar shows your hit count live. Output is what you played —
period auto-detected, cps adjusted, written + eval'd in one keystroke.

For a one-shot rhythm without loop detection: `:tap-strict`.
For just tempo: `:bpm` (4 taps = 1 bar).

## Play a melody on the keyboard

```
:piano-rec fmbell
```

Then letter keys play notes (z/x/c/v/b/n/m = naturals,
s/d/g/h/j = sharps), `[` `]` shift octave, Enter commits the
recorded notes as `@dN :fmbell |> n(p"…")`.

## Mix live with `:mixer`

Open `:mixer` (or `Space b L` for browse / library). Inside:

- `j` / `k` — navigate slots
- `+` / `-` — bump gain ±0.1 (writes to buffer + re-evals slot)
- `*` / `/` — bump gain ±0.5
- `m`       — mute / unmute
- `s`       — solo (mute everything else)
- `u`       — unmute all
- `!`       — panic (kill all voices)
- `q`       — close

The activity bar shows recent fires (decays over 0.6 s from
last-fired-at — not true RMS but enough to see what's playing).

## Save / load a session

```
:save trackidea     → sessions/trackidea.txt
:load trackidea     → reloads the buffer (press E to eval)
:sessions           → list all saved sessions
:load <Tab>         → autocomplete on session names
```

## Add your own sample

```
:import ~/Downloads/mykick.wav as fatkick
@d1 p"fatkick ~ fatkick ~"
```

Re-importing the same name appends a variant (so `fatkick:1`,
`fatkick:2` become available for `n()`). See
[09-samples](09-samples.md) for the longer story.

## Export a sound to WAV

```
:export 6           → records the current synth tab for 6s,
                      writes to ./recordings/<name>_<timestamp>.wav
```

Or record a longer take from the master:

```
:rec start mytrack
... play ...
:rec stop           → ./recordings/mytrack.wav
```

## Drive Ressac from a MIDI keyboard

Paste 6 lines of SC into your SuperCollider session and any
note-on becomes a Ressac trigger:

```supercollider
MIDIClient.init; MIDIIn.connectAll;
~ressacOSC = NetAddr.new("127.0.0.1", 57121);
MIDIFunc.noteOn({ |vel, num, chan|
    ~ressacOSC.sendMsg("/ressac/trigger", "supersaw",
        "n", (num - 60).asInteger,
        "gain", (vel / 127).asFloat);
});
```

Full walkthrough in [13-external-midi](13-external-midi.md).
