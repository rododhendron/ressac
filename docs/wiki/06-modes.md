# Live input modes

Modes that take over the keyboard while active. All exit with `Esc`
and show their state in the status bar.

## Tap mode — `:tap [sample] [steps]`

Records a rhythm by tapping `Space` at the right times.

```
:tap                → defaults: sample = bd, steps = 16
:tap kick           → sample = kick, steps = 16
:tap hh 32          → sample = hh,   steps = 32
```

Press `Space` for each hit (at least 2 hits needed). `Enter`
commits: the bar = first-hit-to-last-hit, the hits get quantized
across `steps` divisions, and the result lands as
`@d<next-free> p"<sample> ~ ~ <sample> ..."` below the cursor.
`Esc` cancels.

Status bar shows `● TAP <n> hits`.

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
`@d<next-free> :synth |> n(p"0 4 7 0 4 7 ...")` below the cursor.

Status bar shows `● PIANO REC oct=4 [n]`.

## Pause mode — `:pause`

Freezes rendering so you can shift-drag-select text from the
terminal to copy. Any keypress resumes.

## Keydebug mode — `:keydebug`

Toggle. While ON, every key event logs to the pane as
`[KEY] <symbol> char='X' action=<press|repeat|release>`. Useful
when diagnosing keyboard / layout quirks.
