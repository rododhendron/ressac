set shell := ["bash", "-c"]

# Show available recipes
default:
    @just --list

# Run the full test suite (944+ tests)
test:
    julia --project=. -e 'using Pkg; Pkg.test()'

# Slow opt-in: NRT acoustic-analysis integration (spawns headless sclang).
# Excluded from `just test` because each sclang call compiles its classlib.
test-nrt:
    RESSAC_NRT_TESTS=1 QT_QPA_PLATFORM=minimal julia --project=. -e 'using Pkg; Pkg.test()'

# Run tests with line coverage tracking, then summarise per file.
# Drops .cov files next to every src/*.jl. Cleans stale ones first so the
# report doesn't double-count old + new runs.
coverage:
    find src -name "*.cov" -delete
    julia --project=. -e 'using Pkg; Pkg.test(coverage=true)'
    julia --project=. scripts/coverage.jl

# Remove the .cov files left by `just coverage`.
coverage-clean:
    find src -name "*.cov" -delete

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

# Boot scsynth + SuperDirt on UDP 57120.
# Works both inside `nix develop` (uses start-superdirt from PATH) and
# outside (falls back to `nix run .#start-superdirt`). Non-Nix users
# should run scripts/superdirt-startup.scd in their own sclang.
audio:
    #!/usr/bin/env bash
    if command -v start-superdirt >/dev/null 2>&1; then
        exec start-superdirt
    elif command -v nix >/dev/null 2>&1 && [ -f flake.nix ]; then
        echo "[just audio] start-superdirt not on PATH — using 'nix run .#start-superdirt'"
        exec nix run .#start-superdirt
    else
        echo "[just audio] No Nix available. Either:" >&2
        echo "  1. nix develop  (then 'just audio')" >&2
        echo "  2. sclang scripts/superdirt-startup.scd  (your own SC install)" >&2
        exit 127
    fi

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
