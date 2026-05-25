#!/usr/bin/env bash
# install/install-macos.sh — macOS, via Homebrew
#
#     bash install/install-macos.sh
#
# Apple Silicon and Intel both supported (brew handles the arch).
# Re-running is safe.

set -euo pipefail

say() { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m==> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m==> %s\033[0m\n" "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Not macOS — try install-debian.sh / install-arch.sh / etc."

if ! command -v brew >/dev/null; then
    say "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Make brew available in this script too (Apple Silicon path).
    [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
    [ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"
else
    say "Homebrew already installed."
fi

if ! command -v sclang >/dev/null; then
    say "Installing SuperCollider (~150 MB cask download)…"
    brew install --cask supercollider
else
    say "SuperCollider already installed."
fi

# sc3-plugins on macOS: the cask doesn't ship them by default. Most
# SuperDirt setups work without, but the user can install manually from
# https://supercollider.github.io/sc3-plugins/ if needed.

if ! command -v julia >/dev/null; then
    say "Installing Julia via juliaup…"
    curl -fsSL https://install.julialang.org | sh -s -- --yes
    export PATH="$HOME/.juliaup/bin:$PATH"
else
    say "Julia already installed: $(julia --version)"
fi

say "Installing SuperDirt Quark + Dirt-Samples (~250 MB)…"
# sclang on macOS lives inside the .app bundle.
if command -v sclang >/dev/null; then
    sclang "$(dirname "$0")/sc-setup.scd" || warn "sclang exited non-zero — re-run if needed."
elif [ -x "/Applications/SuperCollider.app/Contents/MacOS/sclang" ]; then
    "/Applications/SuperCollider.app/Contents/MacOS/sclang" "$(dirname "$0")/sc-setup.scd" || warn "sclang exited non-zero."
else
    warn "Could not find sclang. Open SuperCollider manually and run:"
    warn "    Quarks.install(\"SuperDirt\"); Quarks.install(\"Dirt-Samples\"); thisProcess.recompile;"
fi

say "Resolving Ressac Julia dependencies…"
julia --project=. -e 'using Pkg; Pkg.instantiate()'

say "Smoke-testing…"
julia --project=. -e 'using Ressac; println("✓ Ressac ", pkgversion(Ressac), " loaded.")'

cat <<EOF

\033[1;32m✓ Install complete.\033[0m

Next steps:
  1. Open SuperCollider.app, run:    SuperDirt.start
  2. In a terminal:                   julia --project=. -t auto scripts/live.jl

Or use just (recommended):
    brew install just
    just audio    # one terminal
    just live     # another

EOF
