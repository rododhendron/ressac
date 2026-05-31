#!/usr/bin/env bash
# install/install-fedora.sh — Fedora / RHEL / CentOS Stream
#
#     bash install/install-fedora.sh
#
# Re-running is safe.

set -euo pipefail

say() { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m==> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m==> %s\033[0m\n" "$*" >&2; exit 1; }

command -v dnf >/dev/null || die "dnf not found. This script is for Fedora / RHEL only."
[ "$(id -u)" -ne 0 ] && SUDO="sudo" || SUDO=""

say "Installing system dependencies…"
$SUDO dnf install -y --skip-broken curl git gcc-c++ make

# RPM Fusion provides SuperCollider on Fedora.
if ! command -v sclang >/dev/null; then
    say "Enabling RPM Fusion (needed for supercollider)…"
    $SUDO dnf install -y \
      https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm \
      2>/dev/null || warn "RPM Fusion already enabled or not needed."

    say "Installing SuperCollider…"
    $SUDO dnf install -y supercollider
    # sc3-plugins is NOT packaged for Fedora (neither in Fedora nor
    # RPM Fusion as of 2026). Users who need MdaPiano / Vowel / etc.
    # must build it from source — see:
    #     https://github.com/supercollider/sc3-plugins
    # Stock SuperDirt patterns (`:bd`, `:cp`, `:hh`, etc.) don't need
    # sc3-plugins, so most users can skip this step entirely.
    warn "sc3-plugins is not packaged for Fedora; build from source if you need MdaPiano / Vowel / etc."
else
    say "SuperCollider already installed."
fi

if ! command -v julia >/dev/null; then
    say "Installing Julia via juliaup…"
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

Next: just audio  (one terminal)  +  just live  (another)
   or: sclang scripts/superdirt-startup.scd  +  julia --project=. -t auto scripts/live.jl

EOF
