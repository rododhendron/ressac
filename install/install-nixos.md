# Install on NixOS (or any system with Nix + flakes)

NixOS users get the cleanest install: the project's `flake.nix` pins
SuperCollider, SuperDirt, Dirt-Samples, Vowel, sc3-plugins, AND the
right Julia, all to known-good versions. No system-wide package
management needed.

## One-time setup

Enable flakes if you haven't already:

```
# in /etc/nixos/configuration.nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

…or temporarily:

```bash
nix --experimental-features "nix-command flakes" develop
```

## Build & run

```bash
git clone https://github.com/<you>/ressac
cd ressac
nix develop                       # enters the dev shell
just instantiate                  # resolve Julia deps (first time)
just audio                        # in one terminal — boots SC + SuperDirt
just live                         # in another — starts the Ressac TUI
```

The first `nix develop` builds ~1 GB of derivations (SuperCollider +
sc3-plugins + ~300 MB Dirt-Samples). Cached after that.

## What the flake gives you

- `supercollider-with-sc3-plugins` (FFT helpers needed by SuperDirt's
  scope features and a couple of UGens used by the user-synth library)
- `SuperDirt` Quark, pinned to v1.7.3
- `Vowel` Quark (formant filter)
- The full TidalCycles `Dirt-Samples` collection
- `start-superdirt` — a helper script that boots SC with the right
  classpath. `just audio` calls it.

## Updating

```bash
just update                       # updates both flake inputs AND Julia deps
```

Pinned Quark hashes are in `flake.nix`; bump them when the upstream
ships a new version you want.

## Standalone (Nix without NixOS — Linux or macOS)

The flake works anywhere Nix is installed. Same recipe — `nix develop`
just builds inside `/nix/store/` instead of being part of the system.

## Without Nix

See the per-OS scripts:

- `install-debian.sh`  — Debian, Ubuntu, Mint, Pop!_OS
- `install-fedora.sh`  — Fedora, RHEL, CentOS Stream
- `install-arch.sh`    — Arch, Manjaro, EndeavourOS
- `install-macos.sh`   — macOS (Homebrew)
- `install-windows.ps1` — Windows 10/11 (winget)
