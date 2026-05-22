# scripts/diag.jl — diagnose scheduler in the same setup as live() but without
# the TUI. Run with `just diag`. Reproduces the bug-hunt scenario where
# `live()` shows ev:0 even after setting a pattern.

using Ressac

println("=== Ressac scheduler diagnostic ===")
println("Threads.nthreads(): $(Threads.nthreads())")
println()

println("Calling start_live!() (same as live() does internally)…")
sched = start_live!()
sleep(0.1)  # let the thread spawn
println("  running           : $(sched.running[])")
println("  t_start           : $(sched.t_start)")
println("  cps               : $(sched.cps)")
println("  lookahead         : $(sched.lookahead)")
println("  patterns          : $(sched.patterns)")
println("  events_shipped    : $(sched.events_shipped[])")
println("  last_end_cycles   : $(sched.last_end_cycles)")
println()

println("Installing :d1 via set_pattern!…")
set_pattern!(sched, :d1, parse_minino("bd hh sn hh"))
println("  patterns          : $(keys(sched.patterns))")
println()

println("Waiting 6 seconds (should hear bd-hh-sn-hh repeating if SuperDirt is up)…")
sleep(6.0)
println()

println("After 6s:")
println("  events_shipped    : $(sched.events_shipped[])")
println("  last_fired_at     : $(sched.last_fired_at)")
println("  last_end_cycles   : $(sched.last_end_cycles)")
println("  running           : $(sched.running[])")
println()

if sched.events_shipped[] == 0
    println("⚠️  events_shipped is STILL ZERO — the scheduler thread isn't shipping.")
    println("   Possible causes: thread crashed silently, _step! returns early,")
    println("   or send_osc fails.")
else
    println("✓  Scheduler shipped $(sched.events_shipped[]) events. If you didn't")
    println("   hear sound, the issue is downstream (SuperDirt routing, etc.)")
end

stop_live!()
println()
println("stop_live!() done.")
