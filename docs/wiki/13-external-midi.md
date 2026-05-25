# MIDI + external OSC control

Ressac doesn't ship its own MIDI driver. Instead it exposes two OSC
endpoints that anything OSC-capable can drive: MIDI controllers,
hardware sequencers, TouchOSC layouts, Max patches, even another
Julia process. The MIDI bridge is 6 lines of SuperCollider you paste
once.

## Endpoints

Bind: UDP `127.0.0.1:57121` (the scope listener — Ressac shares
the socket).

```
/ressac/trigger  s:<name>  [key value ...]
    → one-shot fire of <name> through SuperDirt. Extra args are
      passed verbatim, so you can include freq, gain, n, cut, etc.

/ressac/set      s:<key>   v:<value>
    → mutate live state. Currently supported:
        key = "cps"  → set_cps!(value)
```

Both endpoints become live the first time something binds the scope
listener (any `:scope` cycle), or you can run `:scope amp` then
`:scope off` once at boot to open the socket without a visible scope.

## MIDI bridge — paste into SuperCollider

A 6-line `MIDIFunc` that translates every MIDI note-on into a
/ressac/trigger pointing at one sample, with the MIDI note number
mapped to `n` (semitone offset from middle C):

```supercollider
// In SuperCollider's editor, run once per SC boot:
MIDIClient.init;
MIDIIn.connectAll;
~ressacOSC = NetAddr.new("127.0.0.1", 57121);
MIDIFunc.noteOn({ |vel, num, chan|
    ~ressacOSC.sendMsg("/ressac/trigger", "supersaw",
        "n", (num - 60).asInteger,
        "gain", (vel / 127).asFloat);
});
```

…and you can drop a MIDI keyboard on a `:supersaw` synth without
ever leaving the patterns pane.

Per-channel routing (e.g., ch 1 → drums, ch 2 → bass):

```supercollider
MIDIFunc.noteOn({ |vel, num, chan|
    var sound = if(chan == 0) { "kick" } { "bass" };
    ~ressacOSC.sendMsg("/ressac/trigger", sound,
        "n", (num - 36).asInteger,
        "gain", (vel / 127).asFloat);
});
```

CC → cps:

```supercollider
MIDIFunc.cc({ |val, num, chan|
    // CC 7 (volume) → cps from 0.1 to 1.5
    if(num == 7) { ~ressacOSC.sendMsg("/ressac/set", "cps", (0.1 + (val/127) * 1.4)) };
});
```

## From a Julia REPL

```julia
using Sockets
sock = UDPSocket()
send(sock, ip"127.0.0.1", 57121,
     encode(Ressac.OSCMessage("/ressac/trigger", Any["bd"])))
```

## From a shell

`oscchief` or `sendosc` will do:

```bash
oscchief send 127.0.0.1 57121 /ressac/trigger s bd
oscchief send 127.0.0.1 57121 /ressac/set s cps f 0.75
```

## TouchOSC / Lemur

Point them at `127.0.0.1` UDP `57121` and send the same paths. A
single pad can be a /ressac/trigger with a hard-coded sample name;
a fader can drive /ressac/set s:cps v:0..1.5.

## Why no native MIDI?

Two reasons:

1. **Dependency cost** — adding PortMidi.jl forces every user to
   build a native PortMIDI library at install time. The OSC route
   has zero new deps and reuses the socket Ressac already owns.

2. **More versatile** — once you've wired MIDI → OSC in SC, you
   can also wire it into anything else (Tidal, Pd, Max) the same
   way. Locking MIDI behind a Julia-side driver would make Ressac
   the only consumer.

If you want a hard MIDI dep one day (auto-discovery, hot-plug, no
SC bridge needed), open an issue — the listener socket is already
in place, just the input source would change.
