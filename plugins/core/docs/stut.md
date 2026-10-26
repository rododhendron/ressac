+++
examples = ["@d1 \"bd sn\" |> stut(3, 0.5, 1//8)"]
name = "stut"
short = "Echo: n copies, each one time cycle later and gain × feedback every time."
tags = ["tidal"]
+++

# stut

Echo: n copies, each one time cycle later and gain × feedback every time.

An echo built from events, not audio: `stut(3, 0.5, 1//8)` adds two copies, each an eighth later and half as loud. Unlike `delay` the copies are events, so they can be transformed afterwards.

See also: delay, off, echo
