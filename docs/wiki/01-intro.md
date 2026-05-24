# Welcome to Ressac

Ressac is a Julia-based live-coding environment for SuperCollider /
SuperDirt. You write **patterns** (TidalCycles-style mini-notation),
**synths** (Julia DSL that compiles to SC), and the running session
makes sound through SuperDirt.

## Quick start

1. Start SuperCollider with the Ressac startup script
   (`just audio` or equivalent — see the project README).
2. Launch the TUI: `julia --project=. scripts/live.jl`
3. Type `i` to enter insert mode, type something like:

```
@d1 p"bd hh sn hh"
```

4. Press `Esc` then `e` — the line evaluates and you hear the kick
   pattern.

## Two panes

- **Patterns pane** (always open) — Julia code: pattern definitions,
  `@dN` slots, evaluating lines with `e` or whole blocks with `:e`.
- **Synth pane** (opens on `:synth <name>` or `:lib`) — Julia DSL by
  default, or raw SuperCollider in `.scd` files. `t` / `T` / `Space`
  fires the synth.

## Where to go next

- `02-patterns` — the mini-notation cheat sheet
- `03-synth-dsl` — the DSL cookbook
- `04-keys` — every keystroke
- `05-cookbook` — recipes for common sounds
