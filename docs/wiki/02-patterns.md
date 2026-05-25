# Patterns & mini-notation

Patterns live in the patterns pane as `@dN "..."` lines. `"..."` is
the mini-notation parser — a compact DSL for rhythms.

## Tokens

```
~              rest (silence at this step)
_              extend the previous slot's duration by one step
bd             sample / synth name
bd:2           the second variant of bd
[bd hh]        a group: subdivide one step into multiple
<bd sn cp>     alternate: one token per cycle
bd*4           repeat in time (4 hits during one step)
bd!3           repeat in slot (3 copies side by side)
bd(3,8)        Euclidean: 3 beats spread evenly over 8 steps
bd(3,8,2)      Euclidean with rotation: 3-of-8 shifted by 2 steps
bd?            drop with 50% probability (deterministic by hash)
bd?0.3         drop with custom probability 0..1
```

Combine them freely:

```
@d1 "<[bd*2] sn> ~ bd ~"
@d2 "hh(7,16)" |> gain(0.4)
```

## Effect chain (pipe operator)

Each `@dN` line is Julia code. The `|>` operator chains combinators:

```
@d1 "bd hh sn hh" |> gain(0.8) |> lpf(2000) |> pan(0.3)
```

Available combinators:

**Pattern transforms** (re-shape time / value):
- `fast` `slow` `density` `rev` `every` `stack` `cat` `mask` `gate`
- `jux` `juxBy` `off` `degrade` `degradeBy`
- `sometimes` `often` `rarely` `sometimesBy`
- `palindrome` `iter` `chunk`
- `pure` `silence`

**Controls** (per-event params; `|>` chain):
- `gain` `speed` `pan` `n` `degree`
- `lpf` `hpf` `cutoff` `resonance` `bandq` `bandf`
- `room` `delay` `delaytime` `delayfeedback`
- `attack` `release` `hold` `sustain` `legato`
- `shape` `crush` `coarse` `vowel`
- `octave` `accelerate` `vibrato`
- `compress` `compressThreshold` `compressRatio`
- `pump(steps, depth)` — sidechain-style gain ducking

Numeric vs pattern values: `gain(0.8)` is a constant; `gain("0.5 1
0.5 1")` varies over the cycle.

## Combinator examples

```julia
@d1 "bd hh sn hh" |> jux(rev)           # stereo: left as-is, right reversed
@d1 "bd hh sn hh" |> sometimes(fast(2)) # 50% of cycles go double-time
@d1 "hh*8" |> degradeBy(0.3)            # drop 30% of hits (seeded)
@d1 "bd hh sn hh" |> iter(4)            # rotate by 1/4 each cycle
@d1 "bd hh sn hh" |> palindrome         # forward then reverse
@d1 "bd hh sn hh" |> chunk(4, fast(2))  # one chunk per cycle goes fast
@d1 :pad |> pump(8, 0.7)                 # 4-on-the-floor sidechain pump
```

## Slots

Every `@dN` registers a pattern in slot `dN`. Re-evaluating the same
slot replaces it. To stop a slot, comment it (`# @d1 ...`) and `:e`
re-evals (muted slots are skipped). Or `:mute d1` from anywhere.

## Snippets

`:snip` (or `Space I`) opens a picker. Categories cycle with Tab:
**rhythm** · **melody** · **fx** · **track** · **genre** · **reference**.

Genres available: jersey, footwork, garage, trap, dnb, techno, house,
breakcore, drill, dembow, boombap, lofi_hiphop, phonk, witch_house,
bossanova.

Reference snippets (insert commented cheat-sheets into the buffer):
cheat_combinators, cheat_controls, cheat_mini, cheat_commands,
cheat_pipes, helpers_tour.

## Space-leader templates

Press `Space` in normal mode, then a letter, to expand a template
at the cursor with placeholders. Tab navigates between fields.

| Trigger    | Expands to                                    |
|------------|-----------------------------------------------|
| `Space d`  | `@d$1 "$2"`                                  |
| `Space g`  | `\|> gain($1)`                                |
| `Space l`  | `\|> lpf($1)`                                 |
| `Space h`  | `\|> hpf($1)`                                 |
| `Space p`  | `\|> pan($1)`                                 |
| `Space f`  | `\|> fast($1)`                                |
| `Space s`  | `\|> slow($1)`                                |
| `Space r`  | `\|> room($1)`                                |
| `Space n`  | `\|> n("$1")`                                |
| `Space e`  | `\|> every($1, $2)`                           |
| `Space m`  | `\|> mask("$1")`                             |
| `Space D`  | `\|> delay($1) \|> delaytime($2) \|> ...`     |
| `Space c`  | `\|> cat(["$1", "$2"])`                     |
| `Space S`  | `\|> stack("$1", "$2")`                     |
| `Space v`  | `rev`                                         |
| `Space E`  | `$1($2,$3)` — Euclidean token                 |
| `Space R`  | `$1($2,$3,$4)` — Euclidean with rotation      |
| `Space J`  | `@d$1 "bd(3,8)" \|> gain($2)` — jersey       |

Picker actions (open modals):

| Trigger    | Opens                                         |
|------------|-----------------------------------------------|
| `Space b`  | `:browse` (all sounds picker)                 |
| `Space L`  | `:lib` (synth library)                        |
| `Space I`  | `:snip` (snippet picker)                      |
| `Space w`  | `:wiki`                                       |
| `Space ?`  | `:guide`                                      |

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
