# Troubleshooting

When something goes wrong, work through these from top to bottom.

## "I don't hear anything"

1. **Is SuperCollider running?** Open a terminal and check `sclang` is
   running, with SuperDirt loaded. Quick test:
   ```
   julia> using Ressac; live()
   ```
   …then in Ressac press `E` to eval the starter buffer. If the log
   says `[INFO] :e — ran 3 blocks` but you hear nothing, see step 2.

2. **Is SC bound to the right port?** Ressac sends OSC to UDP 57120.
   Open SC's own log: `("[ressac] " ++ msg).postln` lines should
   appear when you eval. If they don't, your SC is on a different
   port. Edit your `superdirt-startup.scd` to use 57120.

3. **Is SuperDirt actually instantiated?** In SC:
   ```supercollider
   ~dirt.notNil  // should return true
   ```
   If false, run the startup script. The shipped one is
   `scripts/superdirt-startup.scd`.

4. **Master limiter killed it?** `:safety on` engages a LeakDC + HPF
   10Hz + Limiter @ 0.95. `:safety off` removes the chain. If your
   patterns sum to high amplitude, the limiter chokes them. Try
   `gain(0.5)` and check if it comes back.

5. **`:hush` left voices in release?** Long-release synths can take
   a few seconds to die after `:hush`. Wait, or use `!` (panic) to
   free all SC nodes immediately.

## "I get a `[ERROR] eval d1: …`"

The most common cases and what they mean:

| Error                                           | Cause                                                                  | Fix                                                                  |
|-------------------------------------------------|------------------------------------------------------------------------|----------------------------------------------------------------------|
| `unknown name `foo``                            | typo, or sample/synth not registered                                   | `:browse` to see registered names · `:lib` for synths                |
| `a Symbol slipped into a Pattern slot`          | wrote `:bd \|> n(p"0 3")` — Symbol can't accept Pattern                | Wrap with `pure(:bd)` or use mini-notation: `p"bd" \|> n(p"0 3")`    |
| `parse error — check matching brackets`        | unbalanced `(`, `[`, `<`, `"`                                          | scan the line, count opens and closes                                |
| `bad arg: invalid base 10 digit`               | wrote a number where a name was expected, or vice versa                | check what the helper expects: `:doc gain` etc.                      |
| `out-of-range index`                            | `degree()` or `n()` got a pattern longer than expected                 | check the indices fit the source                                     |

The raw stacktrace is still visible if you enable `:keydebug` and look
at the OS-level Ressac stderr — but the modal log gives you the gist.

## "My pattern silently doesn't play"

1. **Slot is muted.** Look at the `# @d1` comment (the `#` prefix), or
   open `:mixer` to see MUTED in the State column.

2. **Slot got overwritten.** When two `@d1` lines exist in the buffer,
   the LATEST non-muted one wins on the next `E` eval. Earlier
   declarations are ignored.

3. **Tempo is too slow / too fast.** `cps!(0.001)` makes the cycle take
   16 minutes. The status bar shows current cps + BPM — verify.

4. **The pattern matched but the value is :silence.** `p"~"` produces
   no events. Check the mini-notation didn't reduce to silence.

5. **`auto_env=false` drone never fires.** A drone synth fires once
   per cycle. If you defined it with no envelope AND your cps is very
   slow, you might just be waiting. Speed up cps, or use a normal
   envelope.

## "The TUI is laggy / glitching"

1. **Bump fps.** Default is 120; if your terminal is fast, try `:reload-cfg`
   after setting `[ui] fps = 240` in `ressac.toml`. If your terminal is
   slow, drop to 60.

2. **The patterns buffer is huge.** Past ~500 lines the playhead cache
   is fine but the editor itself can hiccup. Split into smaller sessions
   via `:save` / `:load`.

3. **A pattern is querying very slowly.** Deep `every(N, every(M,
   every(...) ...))` chains can hit O(depth) cost per cycle. The
   scheduler split (snapshot phase + query phase, see architecture
   page) prevents UI stutter but per-cycle CPU is still proportional
   to chain depth.

## "Synth library doesn't load my saved file"

1. **The file is in `plugins/user-synths/`?** That's where `:w` writes
   and where `:lib` reads.

2. **Extension matches mode?** `.jl` is DSL, `.scd` is raw SC. Mixing
   them confuses the library picker.

3. **Plugin reload after adding files?** New `.scd` files appear after
   the next `live()` call. The library picker DOES rescan on each
   `:lib` open though, so the synth WILL appear there even before you
   restart — you just can't reference it from a pattern by name until
   plugin metadata reloads.

## "Mouse selection in the terminal doesn't copy text"

Ressac captures the mouse for click-routing. Two options:
- `:pause` freezes the render — now your terminal's native shift-drag
  works. Press any key in Ressac to resume.
- `:copylogs` sends the entire log buffer to your system clipboard via
  `wl-copy` / `xclip` / `xsel` (whichever is installed).

## "I broke something and want to start over"

```
:starter house     # replaces the buffer with the house pack
```

Or if you want literally an empty buffer:
```
Esc → gg → V → G → d → i
```

If Ressac itself is in a weird state, `:q` then `live()` again is a
clean restart. The scheduler (and your SC) survive across restarts —
voices from before will keep playing until `:hush` / `:panic`.

## Still stuck?

Open an issue with:
- The exact log line(s) you see
- The pattern that produces the issue
- Your Julia + Ressac + SuperCollider versions

You can copy the log buffer to clipboard with `:copylogs`.
