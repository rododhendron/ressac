#!/usr/bin/env bash
# install/install-arch.sh — Arch Linux / Manjaro
#
#     bash install/install-arch.sh
#
# Re-running is safe.

set -euo pipefail

say() { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m==> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m==> %s\033[0m\n" "$*" >&2; exit 1; }

command -v pacman >/dev/null || die "pacman not found. This script is for Arch / Manjaro only."
[ "$(id -u)" -ne 0 ] && SUDO="sudo" || SUDO=""

say "Refreshing pacman…"
$SUDO pacman -Sy --noconfirm

say "Installing system dependencies…"
$SUDO pacman -S --needed --noconfirm curl git base-devel

if ! command -v sclang >/dev/null; then
    say "Installing SuperCollider + sc3-plugins…"
    # Both packages live in the official `extra` repo. The plugin
    # package is `sc3-plugins`, NOT `supercollider-sc3-plugins`.
    $SUDO pacman -S --needed --noconfirm supercollider sc3-plugins || \
        warn "Failed to install sc3-plugins — SuperDirt still works for the base sample set."
else
    say "SuperCollider already installed."
    # Top up sc3-plugins separately in case the user installed
    # supercollider without it.
    if ! pacman -Qi sc3-plugins >/dev/null 2>&1; then
        say "Adding sc3-plugins…"
        $SUDO pacman -S --needed --noconfirm sc3-plugins || \
            warn "sc3-plugins install failed — continuing without."
    fi
fi

if ! command -v julia >/dev/null; then
    say "Installing Julia (juliaup — works alongside pacman julia)…"
    curl -fsSL https://install.julialang.org | sh -s -- --yes
    export PATH="$HOME/.juliaup/bin:$PATH"
else
    say "Julia already installed: $(julia --version)"
fi

say "Installing SuperDirt Quark + Dirt-Samples (~250 MB)…"
sclang "$(dirname "$0")/sc-setup.scd" || warn "sclang exited non-zero — re-run if needed."

say "Resolving Ressac Julia dependencies…"
julia --project=. -e 'using Pkg; Pkg.instantiate()'

say "Smoke-testing…"
julia --project=. -e 'using Ressac; println("✓ Ressac ", pkgversion(Ressac), " loaded.")'

cat <<EOF

\033[1;32m✓ Install complete.\033[0m

Next: just audio  +  just live   (or sclang + julia commands directly)

EOF
