set shell := ["bash", "-c"]

# Show available recipes
default:
    @just --list

# Run the full test suite (130+ tests)
test:
    julia --project=. -e 'using Pkg; Pkg.test()'

# Open a Julia REPL with the project activated
repl:
    julia --project=.

# Offline smoke-test of the M3 pipeline (no audio, no TUI)
demo:
    julia --project=. scripts/repl_demo.jl

# Send 4 raw /dirt/play OSC messages — confirms SuperDirt is reachable
ping:
    julia --project=. scripts/ping.jl

# Launch the Ressac TUI (needs `just audio` running elsewhere for sound)
live:
    julia --project=. scripts/live.jl

# Boot scsynth + SuperDirt on UDP 57120 (call inside `nix develop`)
audio:
    start-superdirt

# Resolve + install Julia dependencies from Project.toml / Manifest.toml
instantiate:
    julia --project=. -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'

# Update both Nix flake inputs and Julia deps
update:
    nix flake update
    julia --project=. -e 'using Pkg; Pkg.update()'
