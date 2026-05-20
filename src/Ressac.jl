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
include("live_api.jl")

# Module includes added by upcoming milestones:
#   M6: include("reservoir.jl")

export Event, Pattern, query
export pure, silence, fast, slow, density, rev, every
export mask
export parse_minino, @p_str
export OSCMessage, OSCBundle, OSCClient, encode, send_osc
export Scheduler, start!, stop!, set_pattern!, unset_pattern!, set_cps!, hush!, schedule_pattern!
export live, start_live!, stop_live!, restart_live!, d!, unset!, hush_all!, cps!
# Export every @d1..@d64 macro. Doing it here keeps the macro generator
# in live_api.jl tidy.
for n in 1:64
    @eval export $(Symbol("@d", n))
end
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

    # Combinator stack + new curried forms via pipe.
    layered  = pure(:cp) |> fast(2)
    looped   = p1 |> every(3, rev)
    mask_gate = Pattern{Bool}((s::Rational, e::Rational) -> begin
        evs = Event{Bool}[]
        push!(evs, Event{Bool}(0//1, 1//2, true))
        push!(evs, Event{Bool}(1//2, 1//1, false))
        filter!(ev -> ev.start < e && ev.stop > s, evs)
        evs
    end)
    masked   = p1 |> mask(mask_gate)
    stacked  = pure(:bd) |> stack(pure(:sn))

    # Numeric algebra path.
    np1 = pure(0) + 12

    # Full scheduler hot loop incl. pending drain.
    sched = Scheduler(_PrecompileSink(); cps=0.5, lookahead=0.05)
    sched.t_start = 0.0
    set_pattern!(sched, :d1, p1)
    set_pattern!(sched, :d2, layered)
    schedule_pattern!(sched, :d3, looped, 1 // 1)
    _step!(sched, 0.0)
    _step!(sched, 1.5)
    unset_pattern!(sched, :d1)
    hush!(sched)

    # OSC encoder/decoder.
    msg = OSCMessage("/dirt/play", Any["s", "bd"])
    bytes = encode(msg)
    decode_message(bytes)
    encode(OSCBundle(0.0, [msg]))

    # Live API: exercise _route_to_slot! both modes via the public macros.
    _LIVE_SCHEDULER[] = sched
    try
        _EVAL_MODE[] = (:immediate, 0)
        _route_to_slot!(:d4, p2)
        _EVAL_MODE[] = (:deferred, 1)
        _route_to_slot!(:d5, p3)
    finally
        _LIVE_SCHEDULER[] = nothing
        _EVAL_MODE[] = (:immediate, 0)
    end
end

end # module Ressac
