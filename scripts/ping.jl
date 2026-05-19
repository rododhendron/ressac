# scripts/ping.jl — minimal OSC ping to SuperDirt.
#
# Sends 4 immediate /dirt/play messages, one every half-second. No scheduler,
# no TUI, no patterns — purely exercises the encoder + UDP socket. If
# SuperDirt is up and audio routing works, you hear "bd hh sn cp".
#
#     julia --project=. scripts/ping.jl

using Ressac
using Sockets

client = OSCClient(ip"127.0.0.1", 57120)
samples = ["bd", "hh", "sn", "cp"]

println("Pinging SuperDirt at 127.0.0.1:57120 with $(length(samples)) samples…")
for s in samples
    send_osc(client, OSCMessage("/dirt/play", Any["s", s]))
    println("  → $s")
    sleep(0.5)
end
println("Done. If you heard nothing, SuperDirt likely isn't listening or audio routing is broken.")
