# Multi-line TUI smoke test

Run inside `nix develop`:

```
just audio       # terminal 1 — wait for "SuperDirt listening on UDP 57120"
just live        # terminal 2 — TUI opens
```

In the TUI:

1. `i` to enter insert mode.
2. Type `@d1 p"bd hh sn hh" |> fast(2)`.
3. `Esc` then `e`. Expect immediate audio (bd-hh-sn-hh at double speed).
4. `i`, edit to `@d1 p"bd*4 sn"`. `Esc`, then `2e`. Expect audio swap at the next musical boundary +2 cycles.
5. `m` on the line. Expect silence and `# @d1 ...` in the buffer.
6. `m` again. Expect audio returns.
7. New line: `o`, `@d2 p"cp ~ cp cp"`, `Esc`, `e`. Both d1 and d2 play.
8. `gd1<Enter>` jumps to the d1 def.
9. `V`, `j`, `j`, `y`. Yanked 3 lines.
10. `p` pastes them below.
11. `:cps 0.75<Enter>` changes tempo.
12. `:q` quits.

If anything misbehaves, look at the Logs pane for `[INFO]` / `[ERROR]` lines.
