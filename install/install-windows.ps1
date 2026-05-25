# install/install-windows.ps1
#
# Windows installer (PowerShell). Uses winget for system packages and
# juliaup for Julia. Run from PowerShell with execution enabled:
#
#     Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#     .\install\install-windows.ps1
#
# winget is bundled on Windows 11 and recent Win10 updates. If yours
# doesn't have it, install "App Installer" from the Microsoft Store first.

$ErrorActionPreference = "Stop"

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "==> $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "==> $msg" -ForegroundColor Red; exit 1 }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Die "winget not found. Install 'App Installer' from the Microsoft Store and retry."
}

# 1. SuperCollider
if (-not (Get-Command sclang -ErrorAction SilentlyContinue)) {
    Say "Installing SuperCollider via winget…"
    winget install --id supercollider.supercollider --silent --accept-package-agreements --accept-source-agreements
    Warn "You may need to open a NEW PowerShell window so sclang is on PATH."
} else {
    Say "SuperCollider already installed."
}

# 2. Julia (juliaup)
if (-not (Get-Command julia -ErrorAction SilentlyContinue)) {
    Say "Installing Julia via juliaup…"
    winget install --id julialang.juliaup --silent --accept-package-agreements --accept-source-agreements
} else {
    Say "Julia already installed: $(julia --version)"
}

# 3. SuperDirt + Dirt-Samples (sclang script)
Say "Installing SuperDirt Quark + Dirt-Samples (~250 MB)…"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupScript = Join-Path $scriptDir "sc-setup.scd"
if (Get-Command sclang -ErrorAction SilentlyContinue) {
    & sclang $setupScript
    if ($LASTEXITCODE -ne 0) { Warn "sclang exited non-zero — re-run if needed." }
} else {
    Warn "sclang not on PATH yet. Open SuperCollider manually and run:"
    Warn "    Quarks.install(`"SuperDirt`"); Quarks.install(`"Dirt-Samples`"); thisProcess.recompile;"
}

# 4. Julia project deps
Say "Resolving Ressac Julia dependencies…"
julia --project=. -e 'using Pkg; Pkg.instantiate()'

Say "Smoke-testing…"
julia --project=. -e 'using Ressac; println("✓ Ressac ", pkgversion(Ressac), " loaded.")'

Write-Host ""
Write-Host "✓ Install complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open SuperCollider, run:   SuperDirt.start"
Write-Host "  2. In a NEW PowerShell:        julia --project=. -t auto scripts/live.jl"
Write-Host ""
