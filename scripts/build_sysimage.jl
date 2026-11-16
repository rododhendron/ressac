# scripts/build_sysimage.jl
#
# Build a precompiled sysimage that contains Ressac + every dependency
# AOT-compiled. After one `just sysimage` (~2-4 min on a modern laptop)
# `julia --sysimage=ressac.so --project=. -t auto scripts/live.jl` starts
# in <1s instead of ~12s.
#
# We use PackageCompiler.jl. The precompile execution file replays a
# representative workload (load Ressac, parse some patterns, query the
# scheduler) so the JIT traces all the hot paths into the sysimage.
#
# Output: ./ressac.so on Linux, ./ressac.dylib on macOS, ./ressac.dll on
# Windows. The `just live-fast` recipe picks the right one automatically.

using Pkg

const ROOT = normpath(joinpath(@__DIR__, ".."))

# PackageCompiler n'est PAS une dépendance de Ressac : il ne sert qu'ici. Il
# vit dans un environnement partagé à part (`@ressac-sysimage`), pour que ce
# script ne l'ajoute jamais au Project.toml du projet. Le projet lui-même
# est désigné à `create_sysimage` par `project = ROOT`.
Pkg.activate("ressac-sysimage"; shared = true, io = devnull)
if !haskey(Pkg.project().dependencies, "PackageCompiler")
    @info "Installing PackageCompiler.jl in the shared env @ressac-sysimage (one-time, ~30s)…"
    Pkg.add("PackageCompiler")
end
using PackageCompiler

const OUT = if Sys.iswindows()
    "ressac.dll"
elseif Sys.isapple()
    "ressac.dylib"
else
    "ressac.so"
end

precompile_file = joinpath(@__DIR__, "precompile_workload.jl")
out_path = joinpath(ROOT, OUT)

@info "Building sysimage → $OUT (this takes 2-4 minutes)…"
@info "Precompile workload: $precompile_file"

# RESSAC_SYSIMAGE_DRYRUN=1 s'arrête ici : de quoi vérifier que le script
# trouve PackageCompiler et le projet, sans trois minutes de compilation.
if get(ENV, "RESSAC_SYSIMAGE_DRYRUN", "") == "1"
    @info "Dry run: PackageCompiler $(pkgversion(PackageCompiler)) ready, project = $ROOT — nothing built."
    exit(0)
end

create_sysimage(
    [:Ressac];
    project = ROOT,
    sysimage_path = out_path,
    precompile_execution_file = precompile_file,
    include_transitive_dependencies = true,
)

@info "Done. Use it via:"
@info "  julia --sysimage=$OUT --project=. -t auto scripts/live.jl"
@info "or: just live-fast"
