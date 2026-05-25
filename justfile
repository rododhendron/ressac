set shell := ["bash", "-c"]

# Show available recipes
default:
    @just --list

# Run the full test suite (130+ tests)
test:
    julia --project=. -e 'using Pkg; Pkg.test()'

# Open a Julia REPL with the project activated.
# `-t auto` so the scheduler thread (Threads.@spawn) actually runs in
# parallel with `Core.eval` / TUI / IO blocks.
repl:
    julia --project=. -t auto

# Offline smoke-test of the M3 pipeline (no audio, no TUI)
demo:
    julia --project=. scripts/repl_demo.jl

# Send 4 raw /dirt/play OSC messages — confirms SuperDirt is reachable
ping:
    julia --project=. scripts/ping.jl

# Run the scheduler in the same setup as `live` but without the TUI, to
# diagnose whether the scheduler thread is actually shipping events.
diag:
    julia --project=. -t auto scripts/diag.jl

# Launch the Ressac TUI (needs `just audio` running elsewhere for sound).
# `-t auto` is REQUIRED — without real threads, Threads.@spawn falls back
# to @async, and the scheduler task can never run while Crossterm.poll
# blocks the main thread (no UDP shipped → no sound).
live:
    julia --project=. -t auto scripts/live.jl

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

# Build a precompiled sysimage (Ressac + all deps AOT-compiled).
# One-time ~2-4 min build, then `just live-fast` starts in ~1s vs ~12s.
# Output: ressac.so (Linux) / ressac.dylib (macOS) / ressac.dll (Win).
sysimage:
    julia --project=. -t auto scripts/build_sysimage.jl

# Same as `live` but uses the prebuilt sysimage if present. Falls
# back to a fresh load if the sysimage doesn't exist yet.
live-fast:
    #!/usr/bin/env bash
    set -e
    img=""
    for f in ressac.so ressac.dylib ressac.dll; do
        if [ -f "$f" ]; then img="$f"; break; fi
    done
    if [ -z "$img" ]; then
        echo "No sysimage found. Run 'just sysimage' first (one-time ~3 min)."
        echo "Falling back to standard 'just live'..."
        exec julia --project=. -t auto scripts/live.jl
    fi
    echo "Using sysimage: $img"
    exec julia --sysimage="$img" --project=. -t auto scripts/live.jl
