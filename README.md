# Ressac.jl

Live coding musical environment in Julia. TidalCycles-inspired pattern DSL
driving [SuperCollider](https://supercollider.github.io/) +
[SuperDirt](https://github.com/musikinformatik/SuperDirt) over OSC.

> **Status — early development.** See
> [`docs/journal/20260518_plan_dev.md`](docs/journal/20260518_plan_dev.md)
> for the full spec, architecture, and milestone tracker.

## Requirements

- Julia ≥ 1.10
- SuperCollider with SuperDirt loaded, listening on UDP `127.0.0.1:57120`
  (only required at runtime, not for the test suite)

## Quickstart

```bash
git clone <repo-url> ressac
cd ressac
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

Once the live coding entry point exists (milestone M4):

```bash
julia --project=. scripts/live.jl
```
