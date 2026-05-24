# Scope visualisations

`S` cycles through scope types; `:scope <type>` picks one directly.
Off = no scope panel (saves screen space).

## Types

```
amp           VU-style amplitude meter + dB readout
wave          Edge-triggered oscilloscope (32ms window)
spectrum      48 log-spaced bands, vertical bars
xy            Lissajous: stereo L vs R scatter + connecting lines
goni          Goniometer (XY rotated 45° — mono = vertical line)
spectrogram   Waterfall of recent FFT frames
peak          Peak meter with hold marker + clip flag
pitch         Fundamental tracker → Hz + note name
onset         Flash bar on each transient
hist          Sample-value distribution histogram
corr          Stereo L-R correlation: -1 phase, 0 stereo, +1 mono
```

## Wave zoom

When scope is `:wave`, the keys take dual meaning depending on
whether the cursor is on a number:

```
+ / -         Y zoom (amplitude scale)
> / <         X zoom (time-window width)
=             reset both axes
```

## Triggered display

The wave scope triggers on **rising zero-crossings**, so a sustained
note appears locked in place instead of scrolling. If silence is
detected, a 4Hz fallback impulse keeps the panel updating.

## How the data flows

1. SC's master bus is tapped by a small scope synth (per type) that
   runs `SendReply` once per frame.
2. `OSCFunc` forwarders relay the data to Ressac's UDP listener on
   port 57121.
3. The Julia listener writes into `_APP_SCOPE_DATA` (and the
   spectrogram listener also pushes to a ring buffer).
4. The render function for the active type reads from those globals.

So adding a new scope = one SC `SynthDef`, one `OSCFunc` forwarder,
one Julia renderer.
