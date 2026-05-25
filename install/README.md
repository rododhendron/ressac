# Install scripts

One-shot installers that get you from "fresh OS" to "Ressac TUI
running" in a single command. Pick the one for your platform.

| Script                  | Platform                                          |
|-------------------------|---------------------------------------------------|
| `install-debian.sh`     | Debian / Ubuntu / Mint / Pop!_OS / Elementary    |
| `install-fedora.sh`     | Fedora / RHEL / CentOS Stream / Alma / Rocky     |
| `install-arch.sh`       | Arch / Manjaro / EndeavourOS                     |
| `install-macos.sh`      | macOS (Apple Silicon + Intel, via Homebrew)      |
| `install-windows.ps1`   | Windows 10 / 11 (PowerShell + winget)            |
| `install-nixos.md`      | NixOS or any Nix-enabled system (flake-based)    |

Each script installs:

1. **Julia ≥ 1.10** via [juliaup](https://github.com/JuliaLang/juliaup)
   (or your distro's package, depending on the OS)
2. **SuperCollider** + `sc3-plugins` (audio engine)
3. **SuperDirt** + **Dirt-Samples** + **Vowel** Quarks (sample playback +
   ~300 MB of TidalCycles drum/perc samples)
4. **Ressac Julia deps** via `Pkg.instantiate()`
5. **Smoke-test** that everything loaded

All scripts are **idempotent** — re-running is safe and short-circuits
already-installed steps.

## Manual install (any OS)

If the scripts don't fit your setup, the four manual steps are:

```bash
# 1. Julia
curl -fsSL https://install.julialang.org | sh

# 2. SuperCollider — use your distro's package manager.
#    Debian/Ubuntu: apt install supercollider supercollider-sc3-plugins
#    macOS:         brew install --cask supercollider
#    Windows:       winget install supercollider.supercollider

# 3. SuperDirt — inside SuperCollider:
#    Quarks.install("SuperDirt"); Quarks.install("Dirt-Samples");
#    thisProcess.recompile;
#    …or run `sclang install/sc-setup.scd` from this folder.

# 4. Ressac
cd ressac
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -t auto scripts/live.jl
```

## After install

```bash
just audio    # boot SuperDirt (one terminal)
just live     # start the TUI (another terminal)
```

Inside the TUI, type `:tutorial` for the 5-minute interactive tour.

If something doesn't work, see [docs/wiki/12-troubleshooting.md](../docs/wiki/12-troubleshooting.md).
