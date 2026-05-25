# Coming from TidalCycles

If you've used Tidal Haskell, the mental model and most of the
vocabulary carry over. The big differences:

| Tidal (Haskell)            | Ressac (Julia)                |
|----------------------------|-------------------------------|
| `cps 0.5`                  | `cps!(0.5)`                   |
| `d1 $ s "bd"`              | `@d1 p"bd"`  or `@d1 :bd`     |
| `d1 silence`               | `@d1`        (no body unsets) |
| `hush`                     | `:hush` or `,`                |
| pipe `#`                   | pipe `\|>`                    |
| `s "bd" # gain 0.7`        | `p"bd" \|> gain(0.7)`         |
| `n "0 3 5"`                | `n(p"0 3 5")`                 |
| `every 4 rev`              | `every(4, rev)`               |
| `jux rev`                  | `jux(rev)`                    |
| `degradeBy 0.3`            | `degradeBy(0.3)`              |
| `(|+|) pat1 pat2`          | not yet — use `stack`         |

## What's the same

- The clock: cycles per second, lookahead, polyphonic per-event scheduling.
- The mini-notation grammar: `~`, `[…]`, `<…>`, `*`, `!`, `(k,n)`, `:`.
- Most combinators by name: `fast`, `slow`, `rev`, `every`, `stack`,
  `cat`, `mask`, `gate`, `degrade`, `sometimes`, `often`, `rarely`,
  `palindrome`, `iter`, `chunk`, `jux`, `juxBy`, `off`.
- Sample naming convention via Dirt-Samples (bd, sn, hh, amen, …).
- SuperCollider / SuperDirt as the audio engine (you can use the same
  setup you already have).

## What's different

### Pattern values

In Tidal, `s "bd hh sn"` is a `Pattern String`. In Ressac the equivalent
`p"bd hh sn"` is a `Pattern{Symbol}`. The string atom becomes a Julia
`Symbol`. Variant indices stay as part of the symbol: `p"bd:2"` →
`Symbol("bd:2")`.

The bare-symbol shorthand `@d1 :bd` lifts to `pure(:bd)` automatically
— useful for single-name patterns.

### The pipe operator is Julia's `|>`

```julia
@d1 p"bd hh sn hh" |> fast(2) |> gain(0.8) |> lpf(1500)
```

Composition rules (same as Tidal's `#`):
- `gain` × · `lpf` min · `hpf` max · `speed` × · `pan` / `n` / `room` /
  `delay` / `shape` last-write-wins.

### `set` for arbitrary params

If a SuperDirt param isn't auto-exposed as a helper, `set(:key, value)`
slots it in:
```julia
@d1 p"bd" |> set(:cut, 1) |> set(:vibrato, 4)
```

### Probabilistic mini-notation

```julia
p"bd? hh? sn? hh?"      # drop each with 50% probability
p"bd?0.3 hh sn hh"      # only bd drops, with 30% prob
p"bd _ _ sn"            # bd extended to occupy 3 slots
p"bd(3,8,2)"            # 3-of-8 Euclidean rotated by 2 steps
```

The drops are seeded by `hash(event_start)` — they're deterministic,
not random per render.

### Synth design lives in the same TUI

In Tidal you write SynthDefs in sclang (a separate editor). In Ressac
the synth pane is right next to the patterns pane — `:synth wob` opens
a tab. You can write raw SuperCollider OR use the embedded Julia DSL
(`@synth :wob saw(:freq) |> rlpf(800, 0.3)`). `T` plays your synth.

### What's missing vs Tidal (and what's planned)

- **`#` per-event arithmetic** like `(|+|)` between two patterns — use
  `stack(p1, p2)` for parallel; no native cross-pattern math yet.
- **`swingBy` / `whenmod`** — not yet (use `every`, `chunk`, `pump`).
- **MIDI input** — not yet (samples + synths only at the moment).
- **`weave` / `linger`** — not yet.

If you miss something specific, open an issue and we'll prioritize.

## Quick crib sheet

```haskell
-- Tidal                              -- Ressac
d1 $ s "bd hh sn hh"                  -- @d1 p"bd hh sn hh"
d1 $ s "bd*4" # gain 0.8              -- @d1 p"bd*4" |> gain(0.8)
d1 $ every 4 (fast 2) $ s "bd"        -- @d1 :bd |> every(4, fast(2))
d1 $ jux rev $ s "bd hh sn hh"        -- @d1 p"bd hh sn hh" |> jux(rev)
d1 $ s "bd" # n "0 3 5"               -- @d1 :bd |> n(p"0 3 5")
hush                                  -- :hush  or  ,
```

The Ressac `:tutorial` walks through the first beat → eval → mute
cycle for users without a Tidal background. Once you've done that
once, everything else is "translate the syntax in this table".
