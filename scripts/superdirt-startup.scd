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
    ~ressacTrackSynth = IdentityDictionary.new;  // name → currently-playing Synth
    OSCdef(\ressacPlay, { |msg|
        var name = msg[1].asString.asSymbol;
        var args = List.new;
        var i = 2;
        var existing;
        while ({ i < msg.size }) {
            args.add(msg[i].asString.asSymbol);
            args.add(msg[i+1]);
            i = i + 2;
        };
        ("[ressac] play " ++ name).postln;
        existing = ~ressacTrackSynth.at(name);
        if(existing.notNil) { existing.free };
        ~ressacTrackSynth.put(name, Synth(name, args.asArray ++ [\out, 0]));
    }, '/ressac/play');

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
                var amp = Amplitude.kr(in, 0.01, 0.1);
                SendReply.kr(Impulse.kr(30), '/ressac/scope/amp', amp);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \wave } {
            ~ressacScopeSynth = {
                var in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                // 32 taps spaced ~0.5 ms apart → ~16 ms window of audio.
                var samples = Array.fill(32, { |i|
                    DelayN.ar(in, 0.020, i * 0.0005)
                });
                SendReply.kr(Impulse.kr(20), '/ressac/scope/wave', samples);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \spectrum } {
            ~ressacScopeSynth = {
                var in  = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                var mags = Array.fill(16, { |i|
                    var freq = 80 * (1.5 ** i);
                    Amplitude.kr(BPF.ar(in, freq, 0.5), 0.01, 0.1)
                });
                SendReply.kr(Impulse.kr(15), '/ressac/scope/spectrum', mags);
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
