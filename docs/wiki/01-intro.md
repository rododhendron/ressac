# Welcome to Ressac

Ressac is a Julia-based live-coding environment for SuperCollider /
SuperDirt. You write **patterns** (TidalCycles-style mini-notation),
**synths** (Julia DSL that compiles to SC), and the running session
makes sound through SuperDirt.

## Quick start

1. Start SuperCollider with the Ressac startup script
   (`just audio` or equivalent — see the project README).
2. Launch the TUI: `julia --project=. scripts/live.jl`
3. **First time?** Type `:tutorial` for the 5-minute interactive tour.
   Otherwise:
   - `i` enters insert mode, type a line
   - `Esc` then `e` evaluates the current line, OR `E` evaluates everything
   - `m` mutes the slot under cursor, `,` hushes everything, `!` panic-stops

The boot buffer is pre-filled with `cps!(0.5)` + a kick/clap/hat pattern
so you can hit `Esc` then `E` immediately and hear something.

## The two panes

- **Patterns pane** (always open) — Julia code with `@dN` slot definitions.
  Each slot fires events into SuperDirt; `e` evals the current line,
  `E` evals all `@dN` blocks. The playhead highlight moves through the
  active token in each `"…"` so you see what's playing right now.

- **Synth pane** (opens on `:synth <name>` or `:lib`) — Julia DSL by
  default (`.jl`), or raw SuperCollider (`.scd`). `t` / `T` / `Space`
  fires the synth, hold to auto-repeat with acceleration.

## Discoverability — keys to remember

| Key      | What it does                                           |
|----------|--------------------------------------------------------|
| `?`      | open the keybinding cheat-sheet (`:guide`)             |
| `Space`  | leader — followed by a letter, expands a snippet       |
| `:`      | command line (`:tap`, `:browse`, `:synth wob`, …)      |
| `Esc`    | exit insert mode                                       |
| `e`      | eval current line                                      |
| `E`      | eval ALL `@dN` blocks                                  |
| `m`      | mute / unmute slot under cursor                        |
| `,`      | hush (soft stop, voices fade)                          |
| `!`      | PANIC — kill every SC voice immediately                |
| `:q`     | quit                                                   |

The footer at the bottom of the screen always shows the relevant keys
for your current context (different in insert mode, after a Space
leader, while filling a snippet placeholder, etc).

## Featured commands

- `:tutorial` — interactive onboarding tour
- `:tap` — tap a rhythm with Space; Ressac auto-detects period, sets
  cps, writes the `@dN "…"` line for you
- `:browse` — searchable picker over every sample / instrument / synth
- `:lib` — synth library: preview + instantiate sounds (built-in or
  user-saved). Includes the 909 kit.
- `:snip` — context-aware snippet picker (rhythm / melody / fx /
  cheat-sheet templates). Tab cycles categories.
- `:starter <genre>` — load a starter pack: house, trap, lofi,
  dubstep, jungle, idm, hardcore, amapiano, witchhouse, ambient
- `:import path/to/sample.wav` — add your own audio to the registry
- `:mixer` — per-slot meters, mute / solo / gain editing
- `:save name` / `:load name` — session snapshots in `sessions/`
- `:wiki` — this documentation

## Where to go next

- `02-patterns` — mini-notation cheat sheet (now with `?`, `_`, rotation)
- `03-synth-dsl` — the DSL cookbook (now with chorus / flanger /
  phaser / granular)
- `04-keys` — every keystroke including leader / placeholder nav
- `05-cookbook` — recipes for common sounds + genre snippets
- `09-samples` — adding your own audio
- `10-architecture` — internals + data flow + file responsibilities
- `11-tidal-migration` — if you're coming from TidalCycles
- `12-troubleshooting` — when something doesn't work
- `13-external-midi` — MIDI + OSC control from anything that speaks OSC
