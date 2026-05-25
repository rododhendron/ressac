# Ressac

**A Julia-based live-coding environment for SuperCollider / SuperDirt.**
Terminal UI · TidalCycles-style mini-notation · synth design in a Julia
DSL that compiles to SC · 629 tests, 0 known regressions.

```julia
@d1 p"bd(3,8) cp(1,8,4)"           # jersey kick + offset clap
@d2 :supersaw |> n(p"0 7 5 12")    # ascending arp
@d2          |> pump(8, 0.7)       # sidechain pump
```

---

## Why

If you've tried TidalCycles, you know the feeling: write four lines,
hear a track. Ressac is the same idea, in Julia, with a polished TUI
and synth design built in. No browser tab, no Atom plugin, no compile
loop — just text and sound.

If you've never live-coded: it's how you'd use a DAW if the DAW were a
text file you could re-evaluate any time. Type `bd hh sn hh`, press a
key, hear a beat. Change the text, press the key again, hear the new
beat. Loop until you stop the loop.

## Install

### One-shot install scripts (recommended)

Each script handles Julia + SuperCollider + SuperDirt + Dirt-Samples
+ Julia deps + smoke-test. Idempotent — re-running is safe.

```bash
git clone https://github.com/<you>/ressac && cd ressac

# Pick your platform:
bash install/install-debian.sh        # Debian / Ubuntu / Mint / Pop
bash install/install-fedora.sh        # Fedora / RHEL / CentOS Stream
bash install/install-arch.sh          # Arch / Manjaro / EndeavourOS
bash install/install-macos.sh         # macOS (Apple Silicon + Intel)
./install/install-windows.ps1         # Windows 10 / 11 (PowerShell)
# NixOS / Nix: see install/install-nixos.md
```

Then:

```bash
just audio                            # one terminal: boots SC + SuperDirt
just live                             # another: starts the Ressac TUI
```

### Manual install

If the scripts don't fit your distro, see [install/README.md](install/README.md)
for the four manual steps (Julia, SuperCollider, Quarks, Julia deps).

The `julia ... -t auto` flag is **required** — Ressac's scheduler
needs real threads to ship OSC while the TUI renders.

## First five minutes

When `live()` starts you'll see a pre-filled buffer:

```julia
# Welcome to Ressac — press Esc, then E to play these patterns.
# Use m on a @dN line to mute · :tutorial for the 5-min tour · :q to quit.

cps!(0.5)
@d1 p"bd bd bd bd"
@d2 p"~ ~ cp ~"
@d3 p"hh hh hh hh" |> gain(0.4)
```

1. Press **Esc** to enter normal mode
2. Press **E** to evaluate every `@dN` block — you should hear a beat
3. Press **m** on a line to mute that slot, **m** again to unmute
4. Press **,** to soft-stop everything (voices fade naturally)
5. Press **!** to nuke all sound immediately

If you're new to vim, type `:tutorial` for a 5-card walkthrough. If
nothing plays, see [docs/wiki/12-troubleshooting.md](docs/wiki/12-troubleshooting.md).

## Try something

Tap a rhythm and Ressac writes the pattern for you:

```
:tap            # then Space on each beat, Enter to commit
```

Browse every sound, synth and instrument loaded:

```
:browse         # j/k navigate · Space preview · Enter insert
```

Load a genre starter:

```
:starter idm    # or: house · trap · lofi · dubstep · jungle · amapiano · hardcore · …
```

Design a synth:

```julia
:synth wob               # opens a synth tab
@synth :wob saw(:freq) |> rlpf(lfo(4; low=400, high=2000), 0.4)
T                        # fires the synth — hold to repeat-fire
```

## Featured commands

| Command            | What                                                          |
|--------------------|---------------------------------------------------------------|
| `:tutorial`        | Interactive 5-minute tour                                     |
| `:tap`             | Tap rhythm → auto pattern + cps detection + eval              |
| `:browse`          | Picker over every sample / instrument / synth                 |
| `:lib`             | Synth library (built-in 909 kit + your saved ones)            |
| `:snip`            | Multi-line snippet picker (rhythm / melody / fx / cheats)     |
| `:starter <genre>` | Drop a genre pack into the buffer                             |
| `:mixer`           | Per-slot meter, mute, solo, gain edit (+/- nudges)            |
| `:import <wav>`    | Add your own audio to the registry                            |
| `:save` / `:load`  | Snapshot the buffer to `sessions/`                            |
| `:wiki`            | Built-in 12-page documentation browser                        |
| `:guide` or `?`    | Keybinding cheat sheet                                        |

## Documentation

The wiki is browsable in-app with `:wiki` (the most convenient way),
or as Markdown in [docs/wiki/](docs/wiki/):

- [01-intro](docs/wiki/01-intro.md) — start here
- [02-patterns](docs/wiki/02-patterns.md) — mini-notation + combinators
- [03-synth-dsl](docs/wiki/03-synth-dsl.md) — designing synths
- [04-keys](docs/wiki/04-keys.md) — every keystroke
- [05-cookbook](docs/wiki/05-cookbook.md) — recipes
- [06-modes](docs/wiki/06-modes.md) — tap, piano, freeze
- [07-scope](docs/wiki/07-scope.md) — the analysis displays
- [08-config](docs/wiki/08-config.md) — `ressac.toml`, themes
- [09-samples](docs/wiki/09-samples.md) — adding your own audio
- [10-architecture](docs/wiki/10-architecture.md) — internals
- [11-tidal-migration](docs/wiki/11-tidal-migration.md) — for Tidal users
- [12-troubleshooting](docs/wiki/12-troubleshooting.md) — when things break
- [13-external-midi](docs/wiki/13-external-midi.md) — MIDI + OSC control from anything

## Development

```bash
just test          # 629 tests, ~10s
just instantiate   # resolve deps after Project.toml changes
just update        # update Julia deps + Nix flake inputs
just repl          # bare REPL with Ressac loaded
just diag          # scheduler smoke test, no TUI
just ping          # send 4 OSC messages to verify SuperDirt is reachable
just sysimage      # build a precompiled sysimage (one-time, ~3 min)
just live-fast     # `just live` using the prebuilt sysimage (~1s startup)
```

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Built on top of [SuperCollider](https://supercollider.github.io/),
[SuperDirt](https://github.com/musikinformatik/SuperDirt), and
inspired by [TidalCycles](https://tidalcycles.org/). The TUI runs on
[Tachikoma.jl](https://github.com/rododhendron/Tachikoma.jl).
