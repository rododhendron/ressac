+++
examples = ["@d1 :bd |> frappes(0, 0.41, 1.03; cycles = 1.87)", "@d2 p\"bd sn\" |> frappes(0, 0.5, 0.75; cycles = 1)"]
name = "frappes"
short = "Plays a sound at exact instants, looping over a free length."
tags = ["ressac", "rhythm", "offgrid"]
+++

# frappes

Plays a sound at exact instants, looping over a free length.

`frappes(instants...; cycles = 1)` strikes the piped sound at each instant (in cycles since the start of the loop) and repeats every `cycles` cycles. The length is free: `cycles = 1.87` drifts against the grid on purpose. Each strike lasts until the next one. When the piped pattern plays several values in a cycle, the strikes take them in turn: `p"bd sn" |> frappes(0, 0.4, 1.1; cycles = 1.5)` plays bd, sn, bd.

This is what the loop writes: `Space o` opens it, `Space` strikes, `o` closes it. The line then replays what you played, anchored on the instant you opened it.

See also: late, euclid, structPat
