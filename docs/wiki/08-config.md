# Config & themes

## `ressac.toml`

Project-root config file, loaded on `live()` and reloadable in-session
with `:reload-config`. All keys are optional; defaults below.

```toml
[ui]
theme = "cyberpunk"   # any built-in or custom
fps   = 60

[input]
t_hold_initial_ms = 250
t_hold_min_ms     = 60
t_hold_accel      = 0.85

nudge_int_small   = 1
nudge_int_big     = 10
nudge_float_small = 1.0
nudge_float_big   = 0.1

[scope]
scope_zoom_step = 1.5
scope_zoom_max  = 32.0
```

## Themes

Switch live: `:theme <name>`. List all: `:theme` alone.

**Ressac customs:**
- `cyberpunk` — hot magenta + electric cyan on black
- `solarpunk` — sage + gold + forest green on warm cream

**Tachikoma built-ins (dark):**
kokaku · esper · motoko · kaneda · neuromancer · catppuccin ·
solarized · dracula · outrun · zenburn · iceberg

**Tachikoma built-ins (light):**
paper · latte · solaris · sakura · ayu · gruvbox · frost ·
meadow · dune · lavender · horizon · overcast · dusk

Set the default in `ressac.toml` under `[ui] theme = ...`.

## T held-key acceleration

Holding `t` / `T` / `Space` on the synth pane re-fires the synth at
increasing speed. Initial interval = `t_hold_initial_ms` (250ms by
default), each fire multiplies by `t_hold_accel` (0.85) down to
`t_hold_min_ms` (60ms). So ~4 fires/sec ramps up to ~17 fires/sec
over a couple seconds.

Tune these in `ressac.toml` if you want slower / snappier ramp.

## Safety chain

Engaged by default on SC boot:

- **LeakDC** — strips DC offset (a stuck-low oscillator can damage
  speakers without producing audible sound).
- **HPF 10Hz** — cuts infrasonic rumble. Below human hearing, but
  leaves musical sub content (15-25Hz) intact.
- **Limiter @ 0.95** — true-peak safe ceiling. Stops runaway
  feedback / stacked oscillators from blasting eardrums.
- **80ms fade-in** at boot so initial frames don't thump.

Toggle with `:safety on|off`.
