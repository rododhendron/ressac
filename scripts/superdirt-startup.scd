// scripts/superdirt-startup.scd
//
// Loaded by `start-superdirt` (defined in flake.nix). Boots scsynth,
// instantiates SuperDirt with 12 orbits listening on UDP 57120, and
// loads the sample library from $DIRT_SAMPLES_PATH (set by the
// launcher). In addition, installs two OSC responders used by Ressac's
// plugin handlers:
//
//   /dirt/loadSampleFolder <abspath:String>
//     Calls ~dirt.loadSoundFiles("<abspath>/*"). Used by the
//     [samples] section handler.
//
//   /dirt/evalSC <source:String>
//     Calls interpret(source) so the plugin's SCD code is evaluated in
//     the running sclang. Used by [synthdefs].
//
// Stay attached: Ctrl+C in the parent shell stops everything.

s.options.memSize    = 2**18;
s.options.numBuffers = 1024 * 64;
s.options.maxNodes   = 1024 * 32;

s.waitForBoot({
    var samplesPath = "DIRT_SAMPLES_PATH".getenv;

    ~dirt = SuperDirt(2, s);

    if (samplesPath.notNil and: { samplesPath.size > 0 }) {
        ("Loading samples from " ++ samplesPath).postln;
        ~dirt.loadSoundFiles(samplesPath ++ "/*");
    } {
        "DIRT_SAMPLES_PATH not set — running without samples".warn;
    };

    s.sync;
    // SuperDirt's init method (called by `SuperDirt(2, s)` above) already
    // calls `this.loadSynthDefs` which reads ../synths/*.scd relative to
    // the SuperDirt class file. The extras (super808/supersaw/superpiano/
    // …) only load if sc3-plugins is present — the flake uses
    // `supercollider-with-sc3-plugins`, so they should be there.
    //
    // Log what landed so the user can sanity-check.
    s.sync;
    ("[boot] SynthDescLib has " ++ SynthDescLib.global.synthDescs.size.asString ++ " synthdefs").postln;
    [\super808, \supersaw, \superpiano, \superhammond, \psin].do { |name|
        if(SynthDescLib.global.synthDescs.includesKey(name)) {
            ("[boot] ✓ " ++ name.asString).postln;
        } {
            ("[boot] ✗ " ++ name.asString ++ " missing").postln;
        };
    };
    ~dirt.start(57120, 0 ! 12);

    // OSCdefs added for Ressac plugin handlers.
    OSCdef(\ressacLoadSampleFolder, { |msg|
        var path = msg[1].asString;
        ("[ressac] loadSampleFolder " ++ path).postln;
        ~dirt.loadSoundFiles(path ++ "/*");
    }, '/dirt/loadSampleFolder');

    OSCdef(\ressacEvalSC, { |msg|
        var src = msg[1].asString;
        ("[ressac] evalSC (" ++ src.size.asString ++ " chars)").postln;
        src.interpret;
    }, '/dirt/evalSC');

    // Bypass SuperDirt for live SynthDef previewing — fires a Synth
    // directly so the SynthDef's parameter DEFAULTS take effect.
    // SuperDirt's /dirt/play overrides freq/gain/sustain with computed
    // values from n + cycle duration; we want the user's `freq = 220`
    // etc. to be what they hear when iterating with `T` / `:test`.
    ~ressacTestSynth = nil;
    OSCdef(\ressacTestSynth, { |msg|
        var name = msg[1].asString.asSymbol;
        ("[ressac] testSynth " ++ name).postln;
        if(~ressacTestSynth.notNil) { ~ressacTestSynth.free };
        ~ressacTestSynth = Synth(name, [\out, 0]);
    }, '/ressac/testSynth');

    // One-shot eval + RAW play, bypassing SuperDirt. Bound to :test-raw.
    // Uses the SynthDef's parameter defaults as-is — what you write is
    // what you hear. Good for verifying that an edit to a default in
    // the synth's param list took effect.
    OSCdef(\ressacEvalAndPlay, { |msg|
        var name = msg[1].asString.asSymbol;
        var src  = msg[2].asString;
        ("[ressac] evalAndPlay (raw) " ++ name ++ " (" ++ src.size.asString ++ " chars)").postln;
        Routine {
            src.interpret;
            s.sync;
            if(~ressacTestSynth.notNil) { ~ressacTestSynth.free };
            ~ressacTestSynth = Synth(name, [\out, 0]);
        }.play(AppClock);
    }, '/ressac/evalAndPlay');

    // Direct synth-fire used by both T (in synth-edit mode) and pattern
    // events that target a user-defined synth. Bypasses SuperDirt's
    // auto-injection of freq/sustain/gain so the SynthDef's own param
    // defaults are the baseline. msg arrives as
    // [\s, name, key1, val1, key2, val2, ...] — explicit pairs only.
    // No previous-instance tracking: each pattern hit spawns a fresh
    // Synth and the SynthDef's own doneAction (typically `2` via
    // Env.linen / Env.adsr) frees it once the envelope completes. Cutting
    // the previous note chopped off the release tail the user designed
    // into their SynthDef — letting notes overlap is how the release is
    // actually heard, and the natural polyphony matches Tidal/SuperDirt
    // semantics for user synths.
    OSCdef(\ressacPlay, { |msg|
        var name = msg[1].asString.asSymbol;
        var args = List.new;
        var i = 2;
        while ({ i < msg.size }) {
            args.add(msg[i].asString.asSymbol);
            args.add(msg[i+1]);
            i = i + 2;
        };
        Synth(name, args.asArray ++ [\out, 0]);
    }, '/ressac/play');

    // Panic — kill every synth on the server immediately. Bound to `.`
    // (and :panic / :hush) in Ressac. Stops out-of-control test fires,
    // stuck notes, infinite tails. After this the scheduler keeps
    // running so freshly-evaluated patterns still play.
    OSCdef(\ressacPanic, { |msg|
        "[ressac] panic — freeing all nodes".postln;
        s.freeAll;
        ~ressacTestSynth = nil;
        if(~ressacTrackSynth.notNil) { ~ressacTrackSynth.clear };
    }, '/ressac/panic');

    // ── Live scope: tap audio bus 0 + push analysis frames to Ressac ──
    // SendReply emits OSC to sclang's local port; OSCFunc forwarders
    // relay each frame to our Ressac listener on UDP 57121.
    ~ressacScopeAddr  = NetAddr.new("127.0.0.1", 57121);
    ~ressacScopeSynth = nil;

    OSCFunc({ |msg|
        // msg = ['/ressac/scope/amp', nodeID, replyID, val]
        ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]);
    }, '/ressac/scope/amp');
    OSCFunc({ |msg|
        // Once-per-second heartbeat (60Hz → mod 60) so the user can see
        // in the SC log whether wave packets are actually being produced.
        if((msg[2] ? 0) % 60 == 0) {
            ("[ressac] scope/wave forwarding " ++ (msg.size - 3).asString ++ " samples").postln;
        };
        ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]);
    }, '/ressac/scope/wave');
    OSCFunc({ |msg|
        ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]);
    }, '/ressac/scope/spectrum');

    OSCdef(\ressacScope, { |msg|
        var type = msg[1].asString.asSymbol;
        ("[ressac] scope " ++ type).postln;
        if(~ressacScopeSynth.notNil) { ~ressacScopeSynth.free; ~ressacScopeSynth = nil };
        case
        { type == \off } { /* synth already freed */ }
        { type == \amp } {
            ~ressacScopeSynth = {
                var in  = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                var amp = Amplitude.kr(in, 0.005, 0.05);
                SendReply.kr(Impulse.kr(60), '/ressac/scope/amp', amp);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \wave } {
            ~ressacScopeSynth = {
                var in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                // 64 taps spaced 0.5 ms apart → 32 ms window. Wrapping ar
                // through A2K.kr is the explicit-conversion form
                // SendReply.kr expects; passing raw ar arrays has been
                // unreliable across SC versions (the trigger samples
                // each value but the multichannel expansion of an ar
                // array inside a kr SendReply silently drops on some
                // builds).
                var samples = Array.fill(64, { |i|
                    A2K.kr(DelayN.ar(in, 0.04, i * 0.0005))
                });
                SendReply.kr(Impulse.kr(60), '/ressac/scope/wave', samples);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \spectrum } {
            ~ressacScopeSynth = {
                var in  = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                // 48 log-spaced bandpass tracks from ~50 Hz to ~16 kHz.
                var mags = Array.fill(48, { |i|
                    var freq = 50 * (1.13 ** i);
                    Amplitude.kr(BPF.ar(in, freq, 0.7), 0.005, 0.05)
                });
                SendReply.kr(Impulse.kr(45), '/ressac/scope/spectrum', mags);
                Silent.ar(1)
            }.play(addToTail: true);
        };
    }, '/ressac/scope');

    OSCdef(\ressacRegisterSample, { |msg|
        var name = msg[1].asString.asSymbol;
        var path = msg[2].asString;
        ("[ressac] registerSample " ++ name ++ " ← " ++ path).postln;
        if(File.exists(path)) {
            if(PathName(path).isFolder) {
                // Directory: defer to SuperDirt's loader (indexes by
                // parent dir name).
                ~dirt.loadSoundFiles(path ++ "/*");
            } {
                // Single-file bank: build one Buffer under `name`.
                var buf = Buffer.read(~dirt.server, path);
                ~dirt.soundLibrary.addBuffer(name, buf);
            };
        } {
            ("[ressac] registerSample: missing path " ++ path).warn;
        };
    }, '/dirt/registerSample');

    "".postln;
    "================================================".postln;
    "SuperDirt listening on UDP 57120 (12 orbits).".postln;
    ("Sample sets: " ++ ~dirt.soundLibrary.buffers.size.asString).postln;
    "Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC, /dirt/registerSample".postln;
    "================================================".postln;
});
