"""
    Ressac

Live coding musical environment in Julia. TidalCycles-inspired DSL with a
real-time scheduler that drives SuperCollider/SuperDirt over OSC.

The full design is in `docs/journal/20260518_plan_dev.md`.
"""
module Ressac

include("core.jl")
include("combinators.jl")

# Module includes added by upcoming milestones:
#   M2: include("algebra.jl"); include("mininotation.jl")
#   M3: include("osc.jl"); include("scheduler.jl")
#   M4: include("tui.jl")
#   M6: include("reservoir.jl")

export Event, Pattern, query
export pure, silence, fast, slow, density, rev, every
# `stack` and `cat` extend Base; no re-export needed (always in scope).

end # module Ressac
