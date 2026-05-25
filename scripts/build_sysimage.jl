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
Pkg.activate(joinpath(@__DIR__, ".."))

# Lazy-install PackageCompiler if missing. Keeps the dep out of the
# project's runtime deps (it's only needed for this build step).
try
    using PackageCompiler
catch
    @info "Installing PackageCompiler.jl (one-time, ~30s)…"
    Pkg.add("PackageCompiler")
    using PackageCompiler
end

const OUT = if Sys.iswindows()
    "ressac.dll"
elseif Sys.isapple()
    "ressac.dylib"
else
    "ressac.so"
end

precompile_file = joinpath(@__DIR__, "precompile_workload.jl")
out_path = joinpath(@__DIR__, "..", OUT)

@info "Building sysimage → $OUT (this takes 2-4 minutes)…"
@info "Precompile workload: $precompile_file"

create_sysimage(
    [:Ressac];
    sysimage_path = out_path,
    precompile_execution_file = precompile_file,
    include_transitive_dependencies = true,
)

@info "Done. Use it via:"
@info "  julia --sysimage=$OUT --project=. -t auto scripts/live.jl"
@info "or: just live-fast"
