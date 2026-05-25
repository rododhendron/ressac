# Live input modes

Modes that take over the keyboard while active. All exit with `Esc`
and show their state in the status bar.

## Tap loop — `:tap [sample]`

The default: tap a rhythm, Ressac detects the loop period
automatically, sets `cps`, writes the `@dN "…"` line, and evals it.

```
:tap                → defaults to sample = bd
:tap kick           → sample = kick
```

Press `Space` on each beat. **Tap the rhythm at least 2 times** so
the detector can confirm the period (the more reps, the higher the
confidence indicator in the commit log). `Enter` commits:

1. Period detection picks the bar duration (with bias toward the
   current `cps` so tapping in-time with an existing beat snaps
   cleanly).
2. Step inference chooses the smallest musical grid (3, 4, 6, 8,
   12, 16, 24, 32) where every tap lands on an integer step.
3. Output: `cps!(<inferred>)` + `@d<next-free> "…"` lines, both
   evaluated immediately.
4. Confidence score in the log: `high`, `ok`, or `low — try more reps`.

If no clear loop is detected (confidence too low, or only one rep),
the command falls back to single-bar quantization: the bar = first
hit to last + one average interval, hits placed across 16 steps.

Status bar: `● TAP-LOOP <n> hits` while recording.

## Tap-strict — `:tap-strict [sample]`

Single-bar quantize, no loop detection. Use when you tap a one-shot
rhythm and want exactly what you played, not a detected loop.

## Tap-tempo — `:bpm` (alias `:tap-tempo`)

Tap 2+ beats with `Space`, `Enter` sets cps. 4 taps = 1 bar
convention (so 60 BPM = `cps!(0.25)`).

## Piano mode — `:piano [synth]`

Letter keys map to chromatic semitones, each press fires the
named synth at that pitch.

```
Bottom row (naturals):  z(w) x  c  v  b  n  m(,)  ;
                         C   D  E  F  G  A   B   C
Middle row (sharps):       s  d     g  h  j
                          C#  D#    F# G# A#
```

`[` and `]` shift octave (0..9, default 4 = A4 region). `Esc` exits.

## Piano-record — `:piano-rec [synth]`

Same as piano mode but every press is stashed with its timestamp.
`Enter` commits: notes get quantized across 16 steps, output is
`@d<next-free> :synth |> n("0 4 7 0 4 7 ...")` below the cursor.

Status bar shows `● PIANO REC oct=4 [n]`.

## Space-leader mode (transient)

Pressing `Space` in normal mode arms a one-shot trigger:

- next char = `d` → expands `@d$1 "$2"` with cursor on `$1`
- next char = `b` / `L` / `I` / `w` / `?` → opens browse / lib /
  snippets / wiki / guide
- next char = a letter in `_LEADER_SNIPPETS` → expands template
- any other char → cancels silently

While the trigger is pending, the footer shows the available
options. Once a snippet expands with placeholders, you're in
"placeholder mode": Tab next, Shift-Tab prev, Esc exit.

See [04-keys](04-keys.md) for the full leader table.

## Mixer mode — `:mixer` (alias `:mix`)

A modal showing all live + muted slots with their activity meter,
state, gain, and source. Per-slot controls:

- `j` / `k` — navigate slots
- `m`       — mute / unmute the slot under cursor
- `s`       — solo
- `u`       — unmute all
- `+` / `-` — nudge gain ±0.1 (modifies the buffer + re-evals)
- `*` / `/` — nudge gain ±0.5
- `!` / `.` — panic (kill all voices)
- `q` / Esc — close

## Pause mode — `:pause`

Freezes rendering so you can shift-drag-select text from the
terminal to copy. Any keypress resumes.

## Keydebug mode — `:keydebug`

Toggle. While ON, every key event logs to the pane as
`[KEY] <symbol> char='X' action=<press|repeat|release>`. Useful
when diagnosing keyboard / layout quirks.
