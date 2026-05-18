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
export Scheduler, start!, stop!, set_pattern!, set_cps!, hush!
export live, d!, hush_all!, cps!
# `stack`, `cat`, and arithmetic operators extend Base; no re-export needed.

end # module Ressac
