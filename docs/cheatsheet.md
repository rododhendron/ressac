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

## Common gotchas

- **First eval is slower** (~80 ms) than subsequent (~µs). Precompile
  workload covers most paths but not all. Expected.
- **`Ctrl+Enter` is not a binding** — terminals don't transmit it
  reliably. Use `Esc` then `e` (or `[N]e`).
- **`slow(0)` throws** at construction. Use `slow(0.5)` etc. — values < 1
  speed *up* via the `slow(n) = fast(1/n)` identity.
- **Buffer is in-memory only** — no file I/O yet. Quitting via `:q`
  loses the session unless you copied it elsewhere.
