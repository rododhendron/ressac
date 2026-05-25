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
    # sc3-plugins is in the official repos.
    $SUDO pacman -S --needed --noconfirm supercollider supercollider-sc3-plugins || \
        warn "sc3-plugins might be in AUR depending on your repo set."
else
    say "SuperCollider already installed."
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
