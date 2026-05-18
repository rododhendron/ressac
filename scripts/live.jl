# scripts/live.jl — TUI entry point.
#
#     julia --project=. scripts/live.jl
#
# Starts a `Scheduler` aimed at SuperDirt on 127.0.0.1:57120 and drops you
# into the Ressac TUI. Type patterns at the `>` prompt, hit Enter to eval.
# Available helpers in the live scope: `d!(:slot, pattern)`, `hush_all!()`,
# `cps!(x)`. Press Ctrl+H to silence everything without quitting; Ctrl+Q to
# exit.

using Ressac

Ressac.live()
