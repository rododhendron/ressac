# Patterns & mini-notation

Patterns live in the patterns pane as `@dN p"..."` lines. `p"..."` is
the mini-notation parser — a compact DSL for rhythms.

## Tokens

```
~              rest (silence at this step)
bd             sample / synth name
bd:2           the second variant of bd
[bd hh]        a group: subdivide one step into multiple
<bd sn cp>     alternate: one token per cycle
bd*4           repeat in time (4 hits during one step)
bd!3           repeat in slot (3 copies side by side)
bd(3,8)        Euclidean: 3 beats spread evenly over 8 steps
```

Combine them freely:

```
@d1 p"<[bd*2] sn> ~ bd ~"
@d2 p"hh(7,16)" |> gain(0.4)
```

## Effect chain (pipe operator)

Each `@dN` line is Julia code. The `|>` operator chains combinators:

```
@d1 p"bd hh sn hh" |> gain(0.8) |> lpf(2000) |> pan(0.3)
```

Available combinators:

- `gain` `speed` `pan` `n` `degree`
- `lpf` `hpf` `cutoff` `resonance` `bandq` `bandf`
- `room` `delay` `delaytime` `delayfeedback`
- `attack` `release` `hold` `sustain` `legato`
- `shape` `crush` `coarse` `vowel`
- `octave` `accelerate` `vibrato`

Numeric vs pattern values: `gain(0.8)` is a constant; `gain(p"0.5 1
0.5 1")` varies over the cycle.

## Slots

Every `@dN` registers a pattern in slot `dN`. Re-evaluating the same
slot replaces it. To stop a slot, comment it (`# @d1 ...`) and `:e`
re-evals (muted slots are skipped). Or `:mute d1` from anywhere.

## Snippets

`:snip` opens a picker. Genres available: jersey, footwork, garage,
trap, dnb, techno, house, breakcore, drill, dembow, boombap,
lofi_hiphop, phonk, witch_house, bossanova. Plus rhythm helpers:
euclidean_layers, polyrhythm_3_4, polyrhythm_5_4, call_response,
ghost_notes.

## Shortcut DSL — `:s<verb>`

Quick command-line chains, appended to the current line:

```
:sg0.9      → " |> gain(0.9)"
:sl2000     → " |> lpf(2000)"
:sf2        → " |> fast(2)"
:sr0.5      → " |> room(0.5)"
:st010110   → " |> gate(p\"0 1 0 1 1 0\")"
```

Newline modifiers: `:sn<verb>...` puts the snippet on a new line
below (indented), `:s<verb>...N` adds a trailing newline.
