# scripts/precompile_workload.jl
#
# Replayed once during sysimage build so PackageCompiler captures
# every hot inference path into the binary. Goal: every code path
# touched on a typical `live()` startup + the first eval cycle gets
# specialised AOT, so the cold start is dominated by the OS file
# read rather than Julia's type inference.
#
# Add new workloads here as the user-facing surface grows. Keep them
# cheap (no audio, no SC server) — this runs as part of the build,
# not at runtime.

using Ressac
using Ressac.SynthDSL

# ── Mini-notation: cover every parser branch ──
patterns = String[
    "bd hh sn hh",
    "bd ~ ~ bd ~ ~ ~ ~",
    "bd(3,8) cp(1,8,4)",
    "bd? hh?0.3 sn _ hh",
    "[bd bd] <sn cp> bd*4",
    "bd:0 bd:1 bd:2",
    "hh*16",
    "bd!3 ~ sn",
]
parsed = [Ressac.parse_minino(p) for p in patterns]

# ── Combinators: one query each so the dispatch table specialises ──
p = pure(:bd)
queries = []
push!(queries, p(0//1, 4//1))
push!(queries, (p |> fast(2))(0//1, 1//1))
push!(queries, (p |> slow(2))(0//1, 4//1))
push!(queries, (p |> rev)(0//1, 1//1))
push!(queries, every(4, fast(2), p)(0//1, 8//1))
push!(queries, jux(rev, p)(0//1, 2//1))
push!(queries, off(1//4, fast(2), p)(0//1, 2//1))
push!(queries, degrade(p)(0//1, 4//1))
push!(queries, degradeBy(0.3, p)(0//1, 4//1))
push!(queries, sometimes(fast(2), p)(0//1, 8//1))
push!(queries, often(rev, p)(0//1, 4//1))
push!(queries, rarely(slow(2), p)(0//1, 4//1))
push!(queries, palindrome(p)(0//1, 4//1))
push!(queries, iter(4, p)(0//1, 8//1))
push!(queries, chunk(4, fast(2), p)(0//1, 4//1))
push!(queries, stack(pure(:bd), pure(:hh))(0//1, 1//1))
push!(queries, cat([pure(:bd), pure(:hh)])(0//1, 4//1))

# ── Controls: every chain helper through one query ──
for op in (gain(0.8), pan(0.5), lpf(2000), hpf(200), speed(0.5),
           room(0.5), delay(0.5), shape(0.3), n(p"0 3 5"),
           degree(p"0 2 4 7"), pump(8, 0.6))
    push!(queries, (pure(:bd) |> op)(0//1, 1//1))
end

# ── DSL synth compile (no OSC sent — just the codegen path) ──
sig = saw(:freq) |> rlpf(800, 0.3) |> env_perc(0.001, :sustain)
src = build_synth(:_warmup_synth, sig; params = (freq = 220, sustain = 0.3))

# ── Scheduler smoke (no OSC sink, just type inference) ──
struct _NullOSC end
Ressac.send_osc(::_NullOSC, ::Vector{UInt8}) = nothing
sched = Ressac.Scheduler(_NullOSC(); cps = 0.5)
sched.t_start = time()
sched.patterns[:d1] = pure(:bd) |> gain(0.8)
Ressac._step!(sched, 0.1)

@info "Precompile workload done — $(length(queries)) queries warmed up."
