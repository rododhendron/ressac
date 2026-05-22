# Ressac cheatsheet

Quick reference for the v2 multi-line TUI. For the full design rationale see
`docs/journal/20260519_multiline_tui_design.md`.

## Shell / Nix

```bash
nix develop                  # enter dev shell (auto via direnv on cd)
just                         # list all just recipes
just audio                   # boot scsynth + SuperDirt on UDP 57120
just live                    # start the TUI
just repl                    # plain Julia REPL with Ressac loaded
just demo                    # offline smoke test (no audio)
just ping                    # send 4 raw /dirt/play to confirm SuperDirt is alive
just test                    # run the test suite (264+ tests)
```

## TUI modes

| Mode | Enter | Leave |
|---|---|---|
| Insert | `i` (cursor), `a` (after), `o` (new line below), `O` (above) | `Esc` |
| Normal | `Esc` | `i/a/o/O`, `V`, `:/?/`/`/` |
| Visual-line | `V` | `Esc`, `y`, `d`, `e` |
| Command | `:`, `/`, `?` | `Esc`, `Enter` |

Mode indicator is shown at the right of the top bar.

## Normal-mode bindings

```
Navigation        Editing           Eval                    Live
─────────         ─────────         ─────────               ─────────
h j k l    ←↓↑→   x      delete    e      eval at cursor   m       mute toggle
0  $      line   yy     yank      [N]e   eval at +N cyc   gd<N>   goto def d<N>
gg G    buf top  [N]yy  yank N    n / N  next / prev      n       repeat search
                 dd     delete    /<rx>  forward search
                 [N]dd  del N     ?<rx>  backward search
                 p / P  paste     :q     quit
                                  :cps x set tempo
                                  :goto d<N>
                                  Ctrl+C quit (safety)
```

The `[N]` prefix is a vim-style count: type digits then the command. `2e` =
eval at +2 cycles. `3yy` = yank 3 lines. `gd1`, `gd64<Enter>`, `gd42m`
(replay non-digit) all work.

## DSL — slot macros + pipe

```julia
@d1 p"bd hh sn hh"                                 # set slot d1
@d1 p"bd hh sn hh" |> fast(2)                      # with combinator
@d1                                                # unset slot d1
@d2 p"cp ~ cp cp"            |> every(4, rev)
@d3 p"<bd cp>"               |> mask(p"1 ~ 1 ~")
@d4 pure(:bd)                |> stack(p"~ cp ~")
@d5 (pure(0) + 12)                                  # numeric algebra
@d6 p"arpy:0 arpy:1 arpy:2 arpy:3"
```

64 slots available (`@d1` … `@d64`). Sample notation `bd:N` selects sample
variant N within the SuperDirt bank.

## Mini-notation reference

| Syntax | Meaning |
|---|---|
| `"bd hh sn hh"` | Four events evenly over the cycle |
| `"bd ~ sn ~"` | `~` is silence |
| `"bd [hh hh] sn"` | Brackets subdivide a slot |
| `"<bd sn cp>"` | Angle brackets alternate per cycle |
| `"bd*4"` | Repeat 4× inside the slot |
| `"bd(3,8)"` | Euclidean: 3 hits over 8 steps |
| `"bd!2 sn"` | `!N` gives the unit N weight |
| `"bd:1 bd:2"` | Sample-bank index |

## Combinators

```julia
# Two-arg forms (work everywhere)
fast(2, p)        # compress time ×2
slow(2, p)        # dilate ×2
rev(p)            # reverse within each cycle
every(4, rev, p)  # apply rev every 4 cycles
stack(p, q)       # play in parallel
cat([p, q, r])    # rotate per cycle
mask(p, q::Pattern{Bool})

# Pipe-friendly curried single-arg forms
p |> fast(2)
p |> slow(2)
p |> every(4, rev)
p |> stack(other)
p |> mask(q)

# Algebra (numeric patterns only)
pure(0) + 12              # transpose by 12 semitones
pure(0.5) * 2             # multiply
pure(60) + pure(12)       # arc-intersect + sum
```

## REPL workflow (no TUI)

```julia
julia> using Ressac
julia> sched = start_live!()                       # spawn scheduler on 127.0.0.1:57120
julia> set_pattern!(sched, :d1, p"bd hh sn hh" |> fast(2))
julia> d!(:d1, p"<bd cp>")                          # via implicit-active-scheduler
julia> sched.patterns                               # inspect
julia> schedule_pattern!(sched, :d1, p"bd*4", 8//1) # queue for cycle 8
julia> hush_all!()                                  # cut everything
julia> stop_live!()                                 # teardown
```

If you want the TUI on top of an already-running scheduler:

```julia
julia> start_live!()
julia> live()                                       # attaches without restarting
```

## Eval timing

The `e` key uses immediate `set_pattern!`. `[N]e` queues the change via
`schedule_pattern!` to apply at cycle `ceil(current_cycle) + N`. The
swap happens exactly at the cycle boundary — no half-cycle audio mix.

```
e            now
1e           at the next musical cycle (no glitch)
4e           at +4 cycles (e.g. when bar 4 starts)
```

Same code in the buffer for both — the keybinding decides. The buffer line
`@d1 p"bd hh sn hh" |> fast(2)` evaluates identically; only the timing
differs.

## Mute / unmute

Cursor on a `@dN ...` line:

- `m` toggles a `# ` prefix. Active → commented + `unset_pattern!(:dN)`.
  Commented → uncommented + re-eval (so the slot returns).
- Buffer is the truth: what's not commented is what's playing.

## Goto

```
gd1              goto last @d1 def (latest in buffer, search backward)
gd64<Enter>      goto @d64 (multi-digit, Enter explicit)
gd1j             goto @d1 then move down one line (key replay)
gd<Esc>          cancel the chord
n / N            cycle through other defs of the same slot
:goto d12        equivalent ex-command form
```

## Search

```
/@d1             forward regex search
?@d2             backward
n                next match (in stored direction)
N                previous (reversed)
```

Search skips commented lines.

## Activity widget

Top bar shows in real time:

```
ressac  0.5cps  ▹▹▸▹  │  d1•◦◦◦  d2◦•◦•  d3 ⏱→cyc7  │ NORMAL
        │       │        │                  │
        cps     cycle    per-slot grid:     pending swap
                pos      • = recent hit
                         ◦ = nothing in
                           this quarter
```

The grid lights up for 200 ms after each fire.

## Plugins

Ressac looks for plugins on this path at session start (first hit wins
per plugin name):

```
./plugins/<name>/                       # cwd, commit alongside your set
~/.config/ressac/plugins/<name>/        # personal global toolkit
$RESSAC_PLUGIN_PATH (colon-separated)   # escape hatch / Nix store
```

A plugin is a directory with a `plugin.toml`:

```toml
name        = "funkit"
version     = "0.1.0"
description = "personal kicks + snares + a bassline synth"

[samples]
roots = ["./samples"]              # default: subdir name → bank name

[samples.bank]                      # explicit aliases + multi-bank
kicky  = "./curated/heavy_v3.wav"   # file → kicky:0
snares = "./curated/snares"          # dir  → snares:0,:1,:2…

[samples.metadata.kicky]
bpm  = 120
tags = ["heavy", "subby"]

[synthdefs]
files = ["./synths/bassline.scd"]

# Optional Julia hook — included into Main BEFORE the plugin's other
# sections run. Can call `Ressac.register_section_handler!` to add
# entirely new sections that downstream plugins can use.
[julia]
files = ["./hook.jl"]

# Optional load-order hint.
depends_on = ["some-other-plugin"]
```

To skip plugin loading for a session:

```julia
julia> start_live!(plugins=false)
```

Extending Ressac with a new section type is one call:

```julia
# in your plugin's hook.jl
Ressac.register_section_handler!(:midi, function (plugin_dir, data, name)
    # data is the [midi] table from the manifest
    # do your thing — install OSCdefs, MIDI bridges, etc.
end)
```

Plugins later in the load order that have `[midi]` in their manifest
will now have it processed by your handler.

### Sample bank workflow

```
:samples                  # list all loaded banks, grouped by plugin
:samples bd*              # glob filter
:samples kicky            # full metadata of one bank
```

Position the cursor on any sample-like word (`kicky`, `snares:1`) in
normal mode and press `K` to play it once via `/dirt/play`, without
touching your slots. The variant suffix (`:N`) is honoured.

Inspect from the REPL:

```julia
julia> sample_info(:kicky)
julia> list_samples(r"^bd")
```

## Instruments & synths

Instruments are named bundles of `/dirt/play` params declared by a plugin.
Using one is as simple as using a sample — the scheduler expands the bundle
on dispatch.

```toml
[instruments.kicklourd]
s     = "bd"               # required: the sample or synth to play
n     = 3                  # any non-reserved key is an OSC param
gain  = 1.2
lpf   = 200
tags  = ["heavy", "subby"] # reserved → metadata, not OSC
description = "the kick that hurts"

[synths.bassline]           # synthdef lives in [synthdefs]; this is metadata
tags = ["bass", "low"]
description = "warm sub bass"
```

Reserved keys for metadata: `tags`, `description`, `comment`. Everything
else is shipped as an OSC param in the order it appears in the TOML.

```julia
@d1 p"kicklourd ~ kicklourd ~"
@d2 p"bassy*4" |> fast(2)
```

In the TUI:

```
:instruments              # list all loaded presets, grouped by plugin
:instruments kick*        # glob filter
:instruments kicklourd    # show the full preset (params + metadata)
:synths                   # same trio for synths
:synths bassline
:guide                    # full in-app cheatsheet (alias :help, :?)
```

`K` resolves instrument → sample → synth. A `:N` suffix on an instrument
name (`kicklourd:7`) overrides any `n` the preset declared, which is
useful for previewing variants without editing the manifest.

REPL:

```julia
julia> instrument_info(:kicklourd)
julia> list_instruments(r"^kick")
julia> synth_info(:bassline)
julia> list_synths()
```

## Effects & overrides

Chain OSC params onto a pattern with the pipe form. Helpers accept either
a scalar or another `Pattern`:

```julia
@d1 p"bd hh sn hh" |> gain(0.8) |> lpf(2000)
@d2 p"bd*4"        |> gain(p"1 0.7 0.5 1")  # gain varies over the cycle
@d3 p"kicklourd"   |> room(0.4) |> delay(0.2)
```

### Helper table

| Helper | Compose op | Identity-ish |
|---|---|---|
| `gain(x)`   | × (multiplicative) | 1.0 |
| `speed(x)`  | × | 1.0 |
| `lpf(x)`    | `min` (the more restrictive cutoff wins) | +∞ |
| `hpf(x)`    | `max` | 0 |
| `pan(x)`    | overwrite (last write wins) | — |
| `n(x)`      | overwrite | — |
| `room(x)`   | overwrite | — |
| `delay(x)`  | overwrite | — |
| `shape(x)`  | overwrite | — |
| `set(:k, v)`| overwrite (escape hatch for any OSC key) | — |

### Composition rules (read carefully)

- **Within the pipe**, each helper composes with whatever the previous
  helper put in the event. `gain(0.8) |> gain(1.2)` is `gain ≈ 0.96`;
  `lpf(2000) |> lpf(500)` is `lpf = 500`.
- **Preset vs pipe**: an instrument preset's value is a **default**.
  If the pipe touches a key, the **pipe wins entirely** for that key,
  even if the pipe value would naively "compose" with the preset.

### Gotchas

- **`gain(1.0)` is not a no-op when there's an instrument preset.** If
  `kicklourd` declares `gain=1.2`, then `kicklourd |> gain(1.0)` ships
  `gain=1.0` to OSC, not 1.2. The pipe touched `:gain`, the preset's
  value got dropped. To inspect what an instrument actually declares:
  ```
  :instruments kicklourd
  ```
- **`set(:gain, 0.5) |> gain(2.0)` is `gain = 1.0`.** `set` writes 0.5
  unconditionally; `gain(2.0)` then sees `:gain=0.5` already there and
  composes × → 1.0. Mixing `set` and named helpers on the same key
  works, but it's worth being explicit in your head about which
  operator wins where.
- **`pan(0.5) |> pan(0.3)` is `pan = 0.3`, not 0.15.** Pan is overwrite
  by design — averaging two pans gives a meaningless result.
- **First-write is not composed.** The very first `gain(x)` in a chain
  (with no preset providing a `:gain` already) is a plain set: it does
  not multiply against an implicit 1.0.

### Escape hatch

For any OSC param Ressac doesn't sugar, use `set`:

```julia
@d1 p"bd"   |> set(:cut, 1) |> set(:orbit, 2)
@d2 p"arpy" |> set(:vowel, p"a e i o u")  # pattern-valued too
```

`set` is always overwrite.

### REPL introspection

There's no built-in "list of helpers" query — they're a fixed Julia
namespace. `gain`, `pan`, `n`, `speed`, `lpf`, `hpf`, `room`, `delay`,
`shape`, and `set` are all exported by the `Ressac` module. `:guide`
shows the same helper table.

## Visual UX (TUI)

### Mode hint line

A 1-row strip just below the command line shows the current mode plus
the 4-5 most relevant key bindings. The mode you think you're in is
written there in caps.

### `?` overlay

Press `?` in normal mode to pop a mode-specific cheat overlay (every
binding in the current mode, terse). Press `?` again to dismiss. The
overlay does NOT auto-dismiss on other keys — it's a stable surface
for reading.

Note: `?` used to be the backward-search shortcut. Backward search is
dropped in favour of the help overlay — forward `/` covers the common
needs.

### Autocomplete (Tab)

- **`:`-mode** — Tab on a partial command verb completes (fuzzy).
  Tab on `:samples <partial>`, `:instruments <partial>`, or
  `:synths <partial>` completes the argument against the matching
  registry. A magenta hint line below the command line shows the
  candidate list with the cycled one in `[brackets]`.
- **Insert mode** — Tab extracts the partial identifier under the
  cursor and completes against the registries + 20 combinator names
  + 64 `@dN` slot macros. Inside `p"..."` or `m"..."` mini-notation,
  only registry names are offered (combinators would be garbage
  inside a mini-notation string).

Fuzzy match is a subsequence scorer ("sa" → "samples", "snares",
"savings"). Subsequent Tabs cycle. Any edit or cursor motion clears
the cycle.

### `:guide` modal

`:guide` (or `:help` / `:?`) opens a centered scrollable overlay
containing the full guide. Navigate with `j`/`k`/`gg`/`G`,
half-page with `Ctrl-d`/`Ctrl-u`, search with `/<rx>`
(case-insensitive). `q` or `Esc` closes.

## Common gotchas

- **First eval is slower** (~80 ms) than subsequent (~µs). Precompile
  workload covers most paths but not all. Expected.
- **`Ctrl+Enter` is not a binding** — terminals don't transmit it
  reliably. Use `Esc` then `e` (or `[N]e`).
- **`slow(0)` throws** at construction. Use `slow(0.5)` etc. — values < 1
  speed *up* via the `slow(n) = fast(1/n)` identity.
- **Buffer is in-memory only** — no file I/O yet. Quitting via `:q`
  loses the session unless you copied it elsewhere.
