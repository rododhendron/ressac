"""
    Ressac

Live coding musical environment in Julia. TidalCycles-inspired DSL with a
real-time scheduler that drives SuperCollider/SuperDirt over OSC.

The full design is in `docs/journal/20260518_plan_dev.md`.
"""
module Ressac

include("core.jl")
include("combinators.jl")
include("algebra.jl")
include("mininotation.jl")
include("osc.jl")
include("scheduler.jl")
include("tui.jl")

# Module includes added by upcoming milestones:
#   M6: include("reservoir.jl")

export Event, Pattern, query
export pure, silence, fast, slow, density, rev, every
export mask
export parse_minino, @p_str
export OSCMessage, OSCBundle, OSCClient, encode, send_osc
export Scheduler, start!, stop!, set_pattern!, unset_pattern!, set_cps!, hush!
export live, start_live!, stop_live!, restart_live!, d!, unset!, hush_all!, cps!
# `stack`, `cat`, and arithmetic operators extend Base; no re-export needed.

# ---------------------------------------------------------------------------
# Precompile workload
# ---------------------------------------------------------------------------
#
# Exercise the hot paths once at package precompile time so the first live
# evaluation doesn't pay the JIT cost. The `_PrecompileSink` is a no-op
# replacement for `OSCClient`: it lets us run `_step!` without actually
# touching a UDP socket during precompilation.

using PrecompileTools

struct _PrecompileSink end
send_osc(::_PrecompileSink, ::Vector{UInt8}) = nothing

@compile_workload begin
    # Mini-notation: cover the parser's main branches.
    p1 = parse_minino("bd hh sn hh")
    p2 = parse_minino("<bd sn cp>")
    p3 = parse_minino("bd(3,8)")
    p4 = parse_minino("bd*4")
    p5 = parse_minino("bd!2 sn")
    p6 = parse_minino("[bd hh] sn")

    # Combinator stack on a Pattern{Symbol}.
    layered = fast(2, rev(stack(pure(:cp), p1)))
    everyp  = every(3, x -> fast(2, x), p2)
    catp    = cat([pure(:a), pure(:b)])

    # Numeric algebra path.
    np1 = pure(0) + 12
    np2 = pure(1) * 2
    np3 = pure(0.5) + pure(0.25)

    # Full scheduler hot loop.
    sched = Scheduler(_PrecompileSink(); cps=0.5, lookahead=0.05)
    sched.t_start = 0.0
    set_pattern!(sched, :d1, p1)
    set_pattern!(sched, :d2, layered)
    _step!(sched, 0.0)
    _step!(sched, 0.1)
    unset_pattern!(sched, :d1)
    hush!(sched)

    # OSC encoder/decoder.
    msg = OSCMessage("/dirt/play", Any["s", "bd"])
    bytes = encode(msg)
    decode_message(bytes)
    encode(OSCBundle(0.0, [msg]))
end

end # module Ressac
