#!/usr/bin/env bash
# install/install-debian.sh
#
# One-shot installer for Debian / Ubuntu / Mint and derivatives.
# Installs Julia (juliaup), SuperCollider + sc3-plugins, then drives
# sclang to install SuperDirt + Dirt-Samples. Finally `Pkg.instantiate`
# this project. Run from the repo root:
#
#     bash install/install-debian.sh
#
# Re-running is safe — every step short-circuits if already done.

set -euo pipefail

say() { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m==> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m==> %s\033[0m\n" "$*" >&2; exit 1; }

# 0. Sanity — apt-get must exist and we need sudo for system packages.
command -v apt-get >/dev/null || die "apt-get not found. This script is for Debian / Ubuntu only."
[ "$(id -u)" -ne 0 ] && SUDO="sudo" || SUDO=""

say "Updating package lists…"
$SUDO apt-get update -y

say "Installing system dependencies (curl, git, build-essential)…"
$SUDO apt-get install -y curl git build-essential ca-certificates

# 1. Julia via juliaup (official multi-channel installer).
if ! command -v julia >/dev/null; then
    say "Installing Julia via juliaup…"
    curl -fsSL https://install.julialang.org | sh -s -- --yes
    # juliaup puts itself in ~/.juliaup/bin; export for this session.
    export PATH="$HOME/.juliaup/bin:$PATH"
else
    say "Julia already installed: $(julia --version)"
fi

# 2. SuperCollider + sc3-plugins from the distro packages.
if ! command -v sclang >/dev/null; then
    say "Installing SuperCollider + sc3-plugins…"
    $SUDO apt-get install -y supercollider supercollider-sc3-plugins || \
        warn "sc3-plugins might not be in your distro. SuperDirt will still work for most uses."
else
    say "SuperCollider already installed: $(sclang -v 2>&1 | head -1 || true)"
fi

# 3. SuperDirt + Dirt-Samples via sclang.
say "Installing SuperDirt Quark + Dirt-Samples (~250 MB, this is the slow part)…"
sclang "$(dirname "$0")/sc-setup.scd" || warn "sclang exited non-zero — re-run if needed."

# 4. Julia project dependencies.
say "Resolving Ressac Julia dependencies…"
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# 5. Smoke test — no audio yet, just verify Ressac loads.
say "Smoke-testing the install…"
julia --project=. -e 'using Ressac; println("✓ Ressac ", pkgversion(Ressac), " loaded.")'

cat <<EOF

\033[1;32m✓ Install complete.\033[0m

Next steps (in two separate terminals):

  Terminal 1:  sclang scripts/superdirt-startup.scd     # boot SuperDirt
  Terminal 2:  julia --project=. -t auto scripts/live.jl

Or if you have \`just\` installed:

  just audio    # in one terminal
  just live     # in another

EOF
