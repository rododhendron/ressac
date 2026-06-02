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

    // Ressac listener address. Declared HERE (not in the scope block
    // further down) because the per-orbit RMS meters installed right
    // below start emitting OSC immediately on play() — if the OSCFunc
    // forwarder fires with ~ressacScopeAddr still nil, every meter
    // packet throws DoesNotUnderstand and the boot log gets buried.
    ~ressacScopeAddr = NetAddr.new("127.0.0.1", 57121);

    // ── Per-orbit RMS meters ──
    // Tap each orbit's dryBus (where its play synths write before
    // global effects). 20 Hz updates × 12 orbits = ~240 OSC msg/s,
    // negligible. Ressac listens on /ressac/rms <idx> <amp> and
    // renders per-slot bars in :mixer (matches @dN → orbit N-1).
    OSCFunc({ |msg|
        // msg = ['/ressac/rms', nodeID, replyID, idx, amp]
        ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]);
    }, '/ressac/rms');

    // GA explorer — per-candidate audibility level. The audition
    // SynthDefs (ga_slotN) SendReply their amplitude; forward to Ressac
    // so it can flag semantically-silent candidates.
    OSCFunc({ |msg|
        // msg = ['/ressac/level', nodeID, replyID, slot, amp]
        ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]);
    }, '/ressac/level');

    ~ressacOrbitMeters = nil;
    ~ressacInstallOrbitMeters = {
        if(~ressacOrbitMeters.notNil) {
            ~ressacOrbitMeters.do { |syn| syn.free };
        };
        ~ressacOrbitMeters = ~dirt.orbits.collect { |o, i|
            { |bus = 0, idx = 0|
                var sig = In.ar(bus, 2);
                var amp = Amplitude.kr(sig.sum * 0.5, 0.01, 0.15);
                SendReply.kr(Impulse.kr(20), '/ressac/rms', [idx, amp]);
                Silent.ar(2);
            }.play(target: o.group,
                   addAction: \addToTail,
                   args: [\bus, o.dryBus.index, \idx, i]);
        };
        ("[ressac] " ++ ~ressacOrbitMeters.size.asString
            ++ " per-orbit meters installed").postln;
    };
    s.sync;
    ~ressacInstallOrbitMeters.value;

    // ── Master safety chain ──
    // Tree of "intercept master out, run it through:
    //   1. LeakDC.ar  — strip DC offset (a stuck-low oscillator can
    //      destroy speakers and isn't audible anyway)
    //   2. HPF.ar(10) — kills infrasonic rumble. 10 Hz is well below
    //      human hearing but leaves room for deep sub kicks / drones
    //      that have content in the 15-25 Hz range. The Limiter
    //      already caps peak amplitude, so DC + true infrasonic is
    //      enough protection here.
    //   3. Limiter.ar(0.95, 0.01) — true-peak safe ceiling (~-0.45dBFS)
    //      with a 10ms lookahead window. Stops runaway feedback or
    //      stacked oscillators from blasting eardrums.
    //   4. A short 80ms Line.kr fade-in on every boot so even if the
    //      patterns kick in instantly, the first frame ramps up
    //      smoothly instead of producing a thump.
    // Controlled by ~ressacSafetyOn — set false to bypass.
    ~ressacSafetyOn = true;
    if(~ressacSafetyOn) {
        ~ressacSafetyGroup = Group.after(s);
        SynthDef(\ressacSafetyChain, { |in = 0, out = 0|
            var sig, fade;
            sig = In.ar(in, 2);
            sig = LeakDC.ar(sig);
            sig = HPF.ar(sig, 10);
            sig = Limiter.ar(sig, 0.95, 0.01);
            fade = EnvGen.kr(Env([0, 1], [0.08]));
            ReplaceOut.ar(out, sig * fade);
        }).add;
        s.sync;
        ~ressacSafetyChainSynth = Synth.tail(~ressacSafetyGroup, \ressacSafetyChain);
        "[ressac] safety chain engaged — Limiter @ -0.45dBFS · DC blocker · 10Hz HPF · 80ms fade-in".postln;
    };

    // Toggle from Ressac via :safety on / off.
    OSCdef(\ressacSafety, { |msg|
        var on = msg[1].asInteger > 0;
        if(on and: { ~ressacSafetyChainSynth.isNil or: { ~ressacSafetyChainSynth.isPlaying.not } }) {
            ~ressacSafetyChainSynth = Synth.tail(~ressacSafetyGroup, \ressacSafetyChain);
            "[ressac] safety ON".postln;
        };
        if(on.not and: { ~ressacSafetyChainSynth.notNil }) {
            ~ressacSafetyChainSynth.free;
            ~ressacSafetyChainSynth = nil;
            "[ressac] safety OFF".postln;
        };
    }, '/ressac/safety');

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

    // Roundtrip used by sc-autodiscover (sub-project 8) to decide
    // whether the on-disk cache is still in sync with the live SC.
    // Reply via ~ressacScopeAddr (127.0.0.1:57121) — Ressac's actual
    // listen port. The `addr` argument here is the SENDER's ephemeral
    // outbound port, not where Ressac is listening, so replying to
    // it drops the packet on a closed socket.
    OSCdef(\ressacScMeta, { |msg, time, addr|
        ("[ressac] sc-meta requested").postln;
        ~ressacScopeAddr.sendMsg("/ressac/sc-meta-reply",
                                 Main.version.asString,
                                 UGen.allSubclasses.size);
    }, '/ressac/sc-meta');

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
            var ok = true;
            // Build the SynthDef inside a try so a bad def is REPORTED to
            // Ressac (which logs it) instead of failing silently and
            // leaving the previous synth playing.
            try {
                src.interpret;
                s.sync;
            } { |err|
                ok = false;
                NetAddr("127.0.0.1", 57121).sendMsg(
                    '/ressac/synthError', name.asString, err.errorString);
                ("[ressac] build failed " ++ name ++ ": " ++ err.errorString).postln;
            };
            if(ok) {
                if(~ressacTestSynth.notNil) { ~ressacTestSynth.free };
                ~ressacTestSynth = Synth(name, [\out, 0]);
            };
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

    // Recorder — driven by `:rec start [name]` / `:rec stop` in Ressac.
    // s.record uses the current default output bus, so SuperDirt's mix
    // (the same thing that hits the speakers) is what lands in the
    // WAV. Path is absolute on the Ressac side; SC just opens it.
    ~ressacRecording = false;
    OSCdef(\ressacRecStart, { |msg|
        var path = msg[1].asString;
        if(~ressacRecording.not) {
            ("[ressac] rec start → " ++ path).postln;
            // s.sync must run inside a Routine — outside, it doesn't
            // actually yield, so s.record would fire before
            // prepareForRecord finished allocating the disk buffer
            // and the resulting WAV would be just the header.
            ~ressacRecording = true;
            Routine {
                s.prepareForRecord(path);
                s.sync;
                s.record;
            }.play(AppClock);
        };
    }, '/ressac/recStart');
    OSCdef(\ressacRecStop, { |msg|
        if(~ressacRecording) {
            "[ressac] rec stop".postln;
            Routine {
                s.stopRecording;
                s.sync;
            }.play(AppClock);
            ~ressacRecording = false;
        };
    }, '/ressac/recStop');

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

    // Free every running Synth whose defName matches the symbol arg.
    // Used by Ressac on slot mute (`m`) when the slot is driving a
    // synth (drone or otherwise) — without this, an auto_env=false
    // voice would keep playing after the pattern stops scheduling.
    // Uses /g_queryTree on the default group; the reply handler at
    // the bottom of this file walks the response and frees matches.
    ~ressacFreePending = IdentitySet.new;
    OSCdef(\ressacFreeByName, { |msg|
        var name = msg[1].asSymbol;
        ~ressacFreePending.add(name);
        s.sendMsg('/g_queryTree', 0, 0);  // root group, no ctl info
    }, '/ressac/freeByName');

    OSCFunc({ |msg|
        // /g_queryTree.reply payload (no ctls):
        //   [ctl_flag(0), root_id, root_nchildren, then for each child:
        //     nodeID, nchildren_or_-1, [defName if Synth] ]
        // nchildren == -1 means leaf (Synth). We free any whose defName
        // is in the pending set, then clear it.
        var i = 3, nid, nch, name;
        if(~ressacFreePending.isEmpty) { ^nil };
        while { i < msg.size } {
            nid = msg[i];
            nch = msg[i+1];
            if(nch < 0) {
                name = msg[i+2].asSymbol;
                if(~ressacFreePending.includes(name)) {
                    s.sendMsg('/n_free', nid);
                };
                i = i + 3;
            } {
                i = i + 2;
            };
        };
        ~ressacFreePending.clear;
    }, '/g_queryTree.reply');

    // ── Live scope: tap audio bus 0 + push analysis frames to Ressac ──
    // SendReply emits OSC to sclang's local port; OSCFunc forwarders
    // relay each frame to our Ressac listener on UDP 57121.
    // ~ressacScopeAddr is already declared above (before the orbit
    // meters that share the same NetAddr).
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
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/xy');
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/spectrogram');
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/peak');
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/pitch');
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/onset');
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/hist');
    OSCFunc({ |msg| ~ressacScopeAddr.sendMsg(msg[0], *msg[1..]) },
            '/ressac/scope/corr');

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
                // Edge-triggered scope. Each frame is captured at a
                // RISING zero-crossing of the input signal, so the wave
                // displayed on each frame starts at the same phase —
                // the trace appears locked in place instead of drifting.
                // For silence, an Impulse fallback keeps the scope
                // visible without making it freeze.
                var in, prev, rising, trig_ar, trig_extended, trig_kr;
                var fallback, fire, samples;
                in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                prev = Delay1.ar(in);
                rising = (in > 0) * (prev <= 0);             // 1 on rising 0X
                // Extend the impulse for one kr period so A2K doesn't miss
                // it between control-rate samples.
                trig_extended = Trig.ar(rising, ControlDur.ir);
                trig_kr = A2K.kr(trig_extended) > 0.5;
                // Throttle to ~60 Hz max — every zero-crossing at high
                // freqs would saturate OSC. PulseDivider passes 1/N
                // triggers; we use a Schmitt-style gate on a min interval.
                fallback = Impulse.kr(4);                    // silence safety net
                fire = trig_kr + fallback;                   // boolean OR
                // 64 taps spaced 0.5 ms apart — 32 ms window. The LEFT of
                // the display (sample[1] in Julia) is the TRIGGER moment
                // (delay 0), the right is 32 ms in the past. So the
                // user reads "trigger anchor on the left, waveform
                // unfolding into the past to the right".
                samples = Array.fill(64, { |i|
                    A2K.kr(DelayN.ar(in, 0.04, i * 0.0005))
                });
                SendReply.kr(fire, '/ressac/scope/wave', samples);
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
        }
        { (type == \xy) or: { type == \goni } } {
            ~ressacScopeSynth = {
                // Stereo XY / goniometer: capture 48 L,R pairs each
                // frame. Goniometer just renders the same data rotated
                // 45° client-side, so we share the synth.
                var l, r, samples, idx;
                l = InFeedback.ar(0, 1);
                r = InFeedback.ar(1, 1);
                samples = Array.new(96);
                48.do { |i|
                    samples = samples.add(A2K.kr(DelayN.ar(l, 0.02, i * 0.0004)));
                    samples = samples.add(A2K.kr(DelayN.ar(r, 0.02, i * 0.0004)));
                };
                SendReply.kr(Impulse.kr(45), '/ressac/scope/xy', samples);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \spectrogram } {
            ~ressacScopeSynth = {
                // 32 log-spaced bands at ~30 Hz — Ressac scrolls the
                // history client-side to build the waterfall.
                var in, mags;
                in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                mags = Array.fill(32, { |i|
                    var freq = 60 * (1.18 ** i);
                    Amplitude.kr(BPF.ar(in, freq, 0.5), 0.01, 0.1)
                });
                SendReply.kr(Impulse.kr(30), '/ressac/scope/spectrogram', mags);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \peak } {
            ~ressacScopeSynth = {
                // Instantaneous peak + slow-decay hold + clip flag.
                var in, peak, hold, clip;
                in = InFeedback.ar(0, 1).abs.max(InFeedback.ar(1, 1).abs);
                peak = Amplitude.kr(in, 0.001, 0.05);
                hold = RunningMax.kr(peak, Impulse.kr(0.5));   // 2s hold
                clip = K2A.kr(peak > 0.99);
                SendReply.kr(Impulse.kr(60), '/ressac/scope/peak',
                             [peak, hold, A2K.kr(clip)]);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \pitch } {
            ~ressacScopeSynth = {
                // Track fundamental + confidence so Ressac can show
                // both the Hz reading AND a "locked?" indicator.
                var in, pitch, freq, hasFreq;
                in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                # freq, hasFreq = Pitch.kr(in, initFreq: 220, ampThreshold: 0.01);
                SendReply.kr(Impulse.kr(30), '/ressac/scope/pitch',
                             [freq, hasFreq]);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \onset } {
            ~ressacScopeSynth = {
                // Onset detector via FFT-based energy gradient. Each
                // detected onset latches an envelope so Ressac sees a
                // sustained "1" for a frame or two.
                var in, fft, onsets, latch;
                in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                fft = FFT(LocalBuf(512), in);
                onsets = Onsets.kr(fft, 0.3, \rcomplex);
                latch = EnvGen.kr(Env.perc(0, 0.08), onsets);
                SendReply.kr(Impulse.kr(60), '/ressac/scope/onset', [latch]);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \hist } {
            ~ressacScopeSynth = {
                // Sample-value distribution: count which of 32 bins
                // each sample falls into per kr block. Sent as a
                // smoothed average so the display doesn't jitter.
                var in, bin, counts;
                in = InFeedback.ar(0, 1) + InFeedback.ar(1, 1);
                bin = ((in.clip(-1, 1) + 1) * 0.5 * 31).floor.asInteger;
                counts = Array.fill(32, { |i|
                    Lag.kr(A2K.kr(BinaryOpUGen('==', K2A.kr(i), bin)), 0.05)
                });
                SendReply.kr(Impulse.kr(30), '/ressac/scope/hist', counts);
                Silent.ar(1)
            }.play(addToTail: true);
        }
        { type == \corr } {
            ~ressacScopeSynth = {
                // Stereo correlation coefficient. -1 = out of phase,
                // 0 = uncorrelated, +1 = mono. Standard mixing aid.
                var l, r, sl, sr, slr, varl, varr, coef;
                l = InFeedback.ar(0, 1); r = InFeedback.ar(1, 1);
                sl = Integrator.ar(l * 0.001);
                sr = Integrator.ar(r * 0.001);
                slr = Integrator.ar(l * r * 0.001);
                varl = Integrator.ar(l * l * 0.001);
                varr = Integrator.ar(r * r * 0.001);
                coef = (slr - sl * sr) / (((varl - sl * sl) * (varr - sr * sr)).sqrt + 0.0001);
                SendReply.kr(Impulse.kr(30), '/ressac/scope/corr', [A2K.kr(coef)]);
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
    "Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC, /dirt/registerSample, /ressac/sc-meta".postln;
    "================================================".postln;
});
