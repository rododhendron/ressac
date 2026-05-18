# scripts/repl_demo.jl — smoke check for the M3 pipeline.
#
# Run from the project root:
#     julia --project=. scripts/repl_demo.jl
#
# It builds a `Scheduler` that sends `/dirt/play` bundles to the default
# SuperDirt port (127.0.0.1:57120), installs a couple of patterns, starts the
# loop, and waits for ENTER before stopping. Without SuperCollider/SuperDirt
# listening, the UDP packets are simply dropped — you'll see the patterns
# being scheduled in the log but hear nothing.

using Ressac
using Sockets

const HOST = ip"127.0.0.1"
const PORT = 57120

function show_pattern_preview(label::AbstractString, p::Pattern)
    println("$label  →  $(p(0//1, 1//1))")
end

println("=== Ressac REPL demo ===")
println("Target: $HOST:$PORT (SuperDirt). Quiet output is expected if no synth is listening.\n")

# A few patterns rendered for inspection — no audio needed.
show_pattern_preview("p\"bd hh sn hh\"      ", p"bd hh sn hh")
show_pattern_preview("fast(2, p\"cp ~ cp cp\")", fast(2, p"cp ~ cp cp"))
show_pattern_preview("p\"bd(3,8)\"          ", p"bd(3,8)")
show_pattern_preview("p\"<bd sn cp>\" cyc 0 ", p"<bd sn cp>")
println()

client = OSCClient(HOST, PORT)
sched = Scheduler(client; cps = 0.5, lookahead = 0.05)

set_pattern!(sched, :d1, p"bd hh sn hh")
set_pattern!(sched, :d2, fast(2, p"cp ~ cp cp"))

println("Starting scheduler. Press ENTER to stop.")
start!(sched)
try
    readline()
finally
    stop!(sched)
    hush!(sched)
    println("Stopped.")
end
