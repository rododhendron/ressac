# Curated SynthDef starters covering a range of styles. Each `source`
# field is the full .scd as the user would see it inside the synth tab,
# with comments explaining what each UGen does and why the
# combination produces the sound — so the library doubles as a tutorial.
#
# SuperCollider grammar note: ALL `var` declarations have to come at
# the top of a block, before any expression statement. The templates
# below front-load them and put the explanatory comments next to the
# corresponding ASSIGNMENT lines.

struct _SynthLibEntry
    name::String          # the SynthDef name (and filename stem)
    category::String      # "lead", "bass", "perc", "fx", "pad", "dark", ...
    description::String   # one-line summary
    source::String        # the .scd body
end

# ── Helper used to keep each entry short to read ──
_syn(name, cat, desc, src) = _SynthLibEntry(name, cat, desc, src)

const _SYNTH_LIBRARY = _SynthLibEntry[
    # ═══════════════════════════════════════════════════════════════════
    # Originals (the first six — kept for backward compat with anything
    # the user already saved into plugins/user-synths/)
    # ═══════════════════════════════════════════════════════════════════
    _syn("plucky", "lead",
        "Karplus-Strong-ish plucked string. Noise → delay loop → filter.", raw"""
        // plucky.scd  —  Karplus-Strong plucked string
        SynthDef(\plucky, { |out, pan = 0, freq = 220, sustain = 0.8, gain = 0.5,
                            burst = 0.005, damp = 0.5|
            var burstEnv, excite, loop, amp, sig;
            burstEnv = EnvGen.kr(Env.perc(0, burst));
            excite   = WhiteNoise.ar * burstEnv;
            loop = CombL.ar(excite, 0.05, 1 / freq, sustain);
            loop = LPF.ar(loop, freq * (10 - (damp * 8)));
            amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);
            sig = loop * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("acid303", "bass",
        "TB-303-style acid line. Saw → RLPF with envelope on cutoff.", raw"""
        // acid303.scd  —  Roland TB-303 inspired acid bass
        SynthDef(\acid303, { |out, pan = 0, freq = 80, sustain = 0.3, gain = 0.5,
                             cutoff = 1500, resonance = 0.4, envmod = 4, decay = 0.2|
            var osc, cenv, dyncut, filtered, amp, sig;
            osc = Saw.ar(freq) + (SinOsc.ar(freq * 0.5) * 0.3);
            cenv = EnvGen.kr(Env.perc(0.001, decay, 1, -4)) * envmod;
            dyncut = cutoff * (1 + cenv);
            filtered = RLPF.ar(osc, dyncut.clip(20, 18000), resonance.clip(0.05, 1.0));
            amp = EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction: 2);
            sig = (filtered * amp * gain).tanh;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("fmbell", "lead",
        "Two-operator FM bell. Modulator frequency controls timbre.", raw"""
        // fmbell.scd  —  Classic 2-op FM bell
        SynthDef(\fmbell, { |out, pan = 0, freq = 440, sustain = 1.2, gain = 0.4,
                            mratio = 1.41, mindex = 5, decay = 0.8|
            var idxEnv, mod, car, amp, sig;
            idxEnv = EnvGen.kr(Env([mindex, mindex * 0.3, 0.2], [0.05, decay], \exp));
            mod = SinOsc.ar(freq * mratio) * idxEnv * freq;
            car = SinOsc.ar(freq + mod);
            amp = EnvGen.kr(Env.perc(0, sustain, 1, -4), doneAction: 2);
            sig = car * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("techkick", "perc",
        "Techno kick: sine with fast pitch drop + transient click.", raw"""
        // techkick.scd  —  Punchy techno kick drum
        SynthDef(\techkick, { |out, pan = 0, freq = 50, sustain = 0.4, gain = 0.8,
                              start_freq = 150, drop = 0.04, click = 0.6|
            var pitch, body, clk, amp, sig;
            pitch = EnvGen.kr(Env([start_freq, freq, freq], [drop, sustain - drop], \exp));
            body = SinOsc.ar(pitch);
            clk = (LPF.ar(WhiteNoise.ar, 4000)) * EnvGen.kr(Env.perc(0, 0.005)) * click;
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -8), doneAction: 2);
            sig = ((body + clk) * amp * gain).tanh;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("softpad", "pad",
        "Detuned saw stack + slow attack + chorus. Ambient pad.", raw"""
        // softpad.scd  —  Lush ambient pad
        SynthDef(\softpad, { |out, pan = 0, freq = 220, sustain = 2.5, gain = 0.35,
                             attack = 0.5, release = 1.5, detune = 0.01,
                             cutoff = 2500, q = 0.5|
            var saws, lfo, filt, ch_l, ch_r, amp, sig;
            saws = Mix.ar(Array.fill(5, { |i| Saw.ar(freq * (1 + ((i - 2) * detune))) * 0.2 }));
            lfo = SinOsc.kr(0.1).range(0.8, 1.2);
            filt = RLPF.ar(saws, cutoff * lfo, q);
            ch_l = DelayN.ar(filt, 0.05, 0.011);
            ch_r = DelayN.ar(filt, 0.05, 0.017);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [attack, sustain - attack, release], \sin),
                            doneAction: 2);
            sig = ((ch_l + ch_r) * 0.5) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("hihat", "perc",
        "Hi-hat: filtered noise with sharp envelope.", raw"""
        // hihat.scd
        SynthDef(\hihat, { |out, pan = 0, sustain = 0.08, gain = 0.4,
                           cutoff = 8000, q = 0.3, drive = 0.0|
            var src, filt, amp, sig;
            src = PinkNoise.ar;
            src = HPF.ar(src, 2000);
            src = HPF.ar(src, cutoff * 0.3);
            filt = BPF.ar(src, cutoff, q);
            filt = filt + (filt.tanh * drive);
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -8), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ═══════════════════════════════════════════════════════════════════
    # Darksynth / Carpenter Brut — heavy, gritty, cinematic, retro-horror
    # ═══════════════════════════════════════════════════════════════════
    _syn("darklead", "darksynth",
        "Dirty detuned saw lead. Gritty + slightly drifting.", raw"""
        // darklead.scd  —  Classic darksynth lead
        // Two saws detuned a few cents apart create slow beating; a
        // gentle RLPF + tanh saturation give it the analog grit.
        SynthDef(\darklead, { |out, pan = 0, freq = 220, sustain = 0.4, gain = 0.5,
                              detune = 7, cutoff = 3000, q = 0.4,
                              attack = 0.005, release = 0.2|
            var saws, filt, amp, sig;
            saws = Saw.ar(freq) + Saw.ar(freq + detune) + Saw.ar(freq - detune * 0.7);
            filt = RLPF.ar(saws * 0.3, cutoff, q);
            filt = filt.tanh;
            amp = EnvGen.kr(Env.linen(attack, sustain - attack - release, release),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("gatedbass", "darksynth",
        "Carpenter-style staccato bass. Hard envelope on sub + saw.", raw"""
        // gatedbass.scd  —  Hard-gated bass for Carpenter-style basslines
        SynthDef(\gatedbass, { |out, pan = 0, freq = 55, sustain = 0.18, gain = 0.7,
                               saturate = 0.5|
            var sub, mid, body, amp, sig;
            sub = SinOsc.ar(freq);
            mid = Saw.ar(freq * 2) * 0.4;
            body = sub + LPF.ar(mid, 800);
            body = (body * (1 + saturate)).tanh;
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.002, sustain - 0.05, 0.05], \lin),
                            doneAction: 2);
            sig = body * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("synthbrass", "darksynth",
        "Stacked-saw retro brass with formant bite.", raw"""
        // synthbrass.scd  —  John-Carpenter-flavoured synth brass
        SynthDef(\synthbrass, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5,
                                cutoff = 2200, q = 0.4|
            var saws, formant, filt, amp, sig;
            saws = Mix.ar([Saw.ar(freq), Saw.ar(freq * 1.005), Saw.ar(freq * 0.995)]);
            formant = BPF.ar(saws, freq * 4, 0.4) * 0.6;
            filt = RLPF.ar(saws * 0.4 + formant, cutoff, q);
            amp = EnvGen.kr(Env([0, 1, 0.7, 0], [0.02, 0.1, sustain - 0.1], \sin),
                            doneAction: 2);
            sig = (filt * amp * gain).tanh;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("arpdriver", "darksynth",
        "Fast plucky arpeggio voice with snappy filter pluck.", raw"""
        // arpdriver.scd  —  Sixteenth-note arp engine
        SynthDef(\arpdriver, { |out, pan = 0, freq = 220, sustain = 0.12, gain = 0.55,
                               cutoff = 2200, q = 0.3, envmod = 2|
            var osc, cenv, filt, amp, sig;
            osc = Pulse.ar(freq, 0.45);
            cenv = EnvGen.kr(Env.perc(0.001, sustain, 1, -3)) * envmod;
            filt = RLPF.ar(osc, cutoff * (1 + cenv), q);
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -6), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("kickbrut", "darksynth",
        "Big aggressive kick with click + tanh drive.", raw"""
        // kickbrut.scd  —  Heavy retro kick for Carpenter Brut vibes
        SynthDef(\kickbrut, { |out, pan = 0, freq = 50, sustain = 0.5, gain = 0.9,
                              start_freq = 220, drop = 0.06, drive = 0.4|
            var pitch, body, click, amp, sig;
            pitch = EnvGen.kr(Env([start_freq, freq, freq], [drop, sustain - drop], \exp));
            body = SinOsc.ar(pitch) + (Saw.ar(pitch) * 0.2);
            click = HPF.ar(WhiteNoise.ar, 2000) * EnvGen.kr(Env.perc(0, 0.004)) * 0.6;
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -6), doneAction: 2);
            sig = ((body + click) * (1 + drive)).tanh * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("snareclap", "darksynth",
        "Snare with FM body + noise tail. Snappy and 80s.", raw"""
        // snareclap.scd  —  Layered snare / clap
        SynthDef(\snareclap, { |out, pan = 0, sustain = 0.18, gain = 0.6,
                               body_freq = 180, noise_q = 0.3|
            var body, mod, noise, amp, sig;
            mod = SinOsc.ar(body_freq * 1.5) * body_freq * 4;
            body = SinOsc.ar(body_freq + mod) * EnvGen.kr(Env.perc(0, 0.06)) * 0.5;
            noise = BPF.ar(WhiteNoise.ar, 4500, noise_q) *
                    EnvGen.kr(Env.perc(0.001, sustain));
            amp = EnvGen.kr(Env.perc(0, sustain * 1.2), doneAction: 2);
            sig = (body + noise) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("darkpad", "darksynth",
        "Wide ominous pad. Detuned saws + slow filter.", raw"""
        // darkpad.scd  —  Cinematic dark pad
        SynthDef(\darkpad, { |out, pan = 0, freq = 110, sustain = 4.0, gain = 0.4,
                             attack = 0.8, release = 1.5, cutoff = 800, q = 0.4|
            var saws, lfo, filt, amp, sig;
            saws = Mix.ar(Array.fill(6, { |i|
                Saw.ar(freq * (1 + ((i - 2.5) * 0.012)))
            })) * 0.18;
            lfo = SinOsc.kr(0.08).range(0.6, 1.2);
            filt = RLPF.ar(saws, cutoff * lfo, q);
            amp = EnvGen.kr(Env([0, 1, 1, 0],
                                [attack, sustain - attack - release, release], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("chasebass", "darksynth",
        "Driving 8th-note bassline with subtle slide.", raw"""
        // chasebass.scd  —  Forward-motion bassline
        SynthDef(\chasebass, { |out, pan = 0, freq = 80, sustain = 0.22, gain = 0.6,
                               slide = 0.02, cutoff = 1400, q = 0.5|
            var pitch, osc, filt, amp, sig;
            pitch = EnvGen.kr(Env([freq * 0.97, freq], [slide], \exp));
            osc = Saw.ar(pitch) + (Pulse.ar(pitch, 0.4) * 0.3);
            filt = RLPF.ar(osc, cutoff, q);
            amp = EnvGen.kr(Env.perc(0.003, sustain, 1, -4), doneAction: 2);
            sig = (filt * amp * gain).tanh;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("darkriser", "darksynth",
        "Tension-building riser. Noise + filter sweep up.", raw"""
        // darkriser.scd  —  Whoosh / build-up FX
        SynthDef(\darkriser, { |out, pan = 0, sustain = 2.0, gain = 0.5,
                               start = 200, peak = 8000|
            var sweep, noise, filt, amp, sig;
            sweep = EnvGen.kr(Env([start, peak], [sustain], \exp));
            noise = WhiteNoise.ar + (BrownNoise.ar * 0.4);
            filt = RLPF.ar(noise, sweep, 0.3);
            amp = EnvGen.kr(Env([0, 0.4, 1, 0], [sustain * 0.3, sustain * 0.6, 0.1], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("gargle", "darksynth",
        "Heavily distorted mid-bass. Punchy and gnarly.", raw"""
        // gargle.scd  —  Distortion-driven bass
        SynthDef(\gargle, { |out, pan = 0, freq = 70, sustain = 0.25, gain = 0.5,
                            drive = 3, cutoff = 1100, q = 0.45|
            var osc, dist, filt, amp, sig;
            osc = Pulse.ar(freq, 0.35) + (Saw.ar(freq * 1.01) * 0.5);
            dist = (osc * drive).tanh;
            filt = RLPF.ar(dist, cutoff, q);
            amp = EnvGen.kr(Env.perc(0.004, sustain, 1, -3), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ═══════════════════════════════════════════════════════════════════
    # Rezz / Heavy Bass — wobbles, growls, space mom territory
    # ═══════════════════════════════════════════════════════════════════
    _syn("rezzbass", "bass",
        "Wide wobble bass. Deep LFO on filter, modern dubstep.", raw"""
        // rezzbass.scd  —  Wobble bass à la Rezz
        // LFO on the filter cutoff at a sync-friendly rate produces the
        // wobble. The rate param is in Hz — try 4 for 8th notes at 120bpm.
        SynthDef(\rezzbass, { |out, pan = 0, freq = 50, sustain = 1.0, gain = 0.6,
                              rate = 4, depth = 2000, base = 500, q = 0.25, drive = 0.6|
            var osc, lfo, cutoff, filt, amp, sig;
            osc = Saw.ar(freq) + (Saw.ar(freq * 0.5) * 0.6);
            lfo = SinOsc.kr(rate).range(base, base + depth);
            filt = RLPF.ar(osc, lfo, q);
            filt = ((filt * (1 + drive))).tanh;
            amp = EnvGen.kr(Env.linen(0.005, sustain - 0.02, 0.015), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("growlbass", "bass",
        "Formant-shifted growl bass.", raw"""
        // growlbass.scd  —  Mouth-vowel-like growling bass
        SynthDef(\growlbass, { |out, pan = 0, freq = 65, sustain = 0.6, gain = 0.55,
                               vow_rate = 3, q = 0.18|
            var osc, vow, filt, amp, sig;
            osc = Saw.ar(freq);
            vow = SinOsc.kr(vow_rate).range(400, 1800);
            filt = BPF.ar(osc, vow, q) + (LPF.ar(osc, 600) * 0.4);
            amp = EnvGen.kr(Env.linen(0.01, sustain, 0.05), doneAction: 2);
            sig = (filt * 1.4).tanh * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("meatbass", "bass",
        "Thick mid-range bass with EQ punch.", raw"""
        // meatbass.scd  —  Chunky saw bass with mid emphasis
        SynthDef(\meatbass, { |out, pan = 0, freq = 80, sustain = 0.3, gain = 0.6,
                              punch = 1.5|
            var osc, body, mid, sig, amp;
            osc = Saw.ar(freq) + Saw.ar(freq * 1.01);
            body = LPF.ar(osc, 1500);
            mid = BPF.ar(osc, 1200, 0.4) * punch;
            sig = (body + mid) * 0.4;
            sig = sig.tanh;
            amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -3), doneAction: 2);
            sig = sig * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("screwbass", "bass",
        "Pitch-bent slow bass. Vinyl-warp feel.", raw"""
        // screwbass.scd  —  Slowed/screwed bass
        SynthDef(\screwbass, { |out, pan = 0, freq = 55, sustain = 0.8, gain = 0.5,
                               bend = 1.5|
            var pitch, osc, filt, amp, sig;
            pitch = EnvGen.kr(Env([freq * 1.05, freq, freq * 0.97],
                                  [bend * 0.4, bend * 0.6], \exp));
            osc = SinOsc.ar(pitch) + (Saw.ar(pitch * 2) * 0.25);
            filt = LPF.ar(osc, 700);
            amp = EnvGen.kr(Env.linen(0.04, sustain, 0.2), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("chompy", "bass",
        "Hard-syncing osc bass. Aggressive and bright.", raw"""
        // chompy.scd  —  Sync-bass with sharp character
        SynthDef(\chompy, { |out, pan = 0, freq = 70, sustain = 0.3, gain = 0.55,
                            sync_ratio = 3, cutoff = 1800, q = 0.3|
            var master, slave, filt, amp, sig;
            master = LFSaw.ar(freq);
            slave = SyncSaw.ar(freq, freq * sync_ratio);
            filt = RLPF.ar(master * 0.4 + slave * 0.6, cutoff, q);
            amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -4), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("subdrop", "bass",
        "Pure sub-bass drop. Pitch envelope only.", raw"""
        // subdrop.scd  —  Sub-bass with pitch drop
        SynthDef(\subdrop, { |out, pan = 0, freq = 40, sustain = 0.9, gain = 0.85,
                             start_freq = 90, drop = 0.4|
            var pitch, body, amp, sig;
            pitch = EnvGen.kr(Env([start_freq, freq], [drop], \exp));
            body = SinOsc.ar(pitch);
            amp = EnvGen.kr(Env.linen(0.005, sustain, 0.1), doneAction: 2);
            sig = body * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("metalbass", "bass",
        "Square-wave bass with ring modulation.", raw"""
        // metalbass.scd  —  Metallic ring-mod bass
        SynthDef(\metalbass, { |out, pan = 0, freq = 70, sustain = 0.3, gain = 0.55,
                               ring = 220, q = 0.4|
            var osc, ringmod, filt, amp, sig;
            osc = Pulse.ar(freq, 0.4);
            ringmod = osc * SinOsc.ar(ring);
            filt = RLPF.ar(osc * 0.7 + ringmod * 0.3, 1800, q);
            amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -3), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("lazerbass", "bass",
        "Quick-formant bass with vowel sweep.", raw"""
        // lazerbass.scd  —  Formant bass with rapid sweep
        SynthDef(\lazerbass, { |out, pan = 0, freq = 80, sustain = 0.2, gain = 0.55|
            var osc, vow, filt, amp, sig;
            osc = Saw.ar(freq);
            vow = EnvGen.kr(Env([300, 2500, 600], [0.05, sustain - 0.05], \exp));
            filt = BPF.ar(osc, vow, 0.25) + LPF.ar(osc, 500);
            amp = EnvGen.kr(Env.perc(0.003, sustain, 1, -4), doneAction: 2);
            sig = (filt * 1.2).tanh * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ═══════════════════════════════════════════════════════════════════
    # Witch House — slow, dark, pitched-down, eerie
    # ═══════════════════════════════════════════════════════════════════
    _syn("screwlead", "witch",
        "Pitched-down detuned lead. Slow and woozy.", raw"""
        // screwlead.scd  —  Chopped & screwed style lead
        SynthDef(\screwlead, { |out, pan = 0, freq = 165, sustain = 1.2, gain = 0.5,
                               vibrate = 5, vib_depth = 4|
            var lfo, pitch, osc, filt, amp, sig;
            lfo = SinOsc.kr(vibrate) * vib_depth;
            pitch = freq + lfo;
            osc = Saw.ar(pitch) + Saw.ar(pitch * 1.005);
            filt = LPF.ar(osc * 0.45, 1500);
            amp = EnvGen.kr(Env([0, 1, 0.7, 0], [0.1, sustain * 0.5, sustain * 0.5], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("chopvox", "witch",
        "Choppy vocal-like pad via amplitude modulation.", raw"""
        // chopvox.scd  —  AM-chopped airy vox
        SynthDef(\chopvox, { |out, pan = 0, freq = 220, sustain = 1.5, gain = 0.4,
                             chop = 8|
            var carrier, mod, filt, amp, sig;
            carrier = Mix.ar([SinOsc.ar(freq), SinOsc.ar(freq * 2) * 0.4,
                              SinOsc.ar(freq * 3) * 0.2]);
            mod = LFPulse.kr(chop).range(0.2, 1);
            filt = BPF.ar(carrier, 1200, 0.6) * mod;
            amp = EnvGen.kr(Env([0, 1, 0], [0.3, sustain - 0.3], \sin), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("slowtom", "witch",
        "Slow tom with long pitch slide.", raw"""
        // slowtom.scd  —  Sub-tom with long descent
        SynthDef(\slowtom, { |out, pan = 0, sustain = 0.9, gain = 0.7,
                             start = 220, end_freq = 50|
            var pitch, body, amp, sig;
            pitch = EnvGen.kr(Env([start, end_freq], [sustain * 0.7], \exp));
            body = SinOsc.ar(pitch) + (LFTri.ar(pitch * 0.5) * 0.3);
            amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -5), doneAction: 2);
            sig = body * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("crystalhall", "witch",
        "Sparse FM bell with metallic ratios — gives a haunted-hall feel.", raw"""
        // crystalhall.scd  —  Inharmonic FM bell
        SynthDef(\crystalhall, { |out, pan = 0, freq = 440, sustain = 2.5, gain = 0.4,
                                 mratio = 2.71, mindex = 3|
            var idx, mod, car, amp, sig;
            idx = EnvGen.kr(Env([mindex, 0.1], [sustain], \exp));
            mod = SinOsc.ar(freq * mratio) * idx * freq;
            car = SinOsc.ar(freq + mod);
            amp = EnvGen.kr(Env.perc(0, sustain, 1, -5), doneAction: 2);
            sig = car * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("slowstrings", "witch",
        "Detuned saws, very slow attack — eerie strings.", raw"""
        // slowstrings.scd  —  Slow-attack string-like pad
        SynthDef(\slowstrings, { |out, pan = 0, freq = 165, sustain = 3.0, gain = 0.4,
                                 attack = 1.5, release = 1.5|
            var saws, filt, amp, sig;
            saws = Mix.ar(Array.fill(4, { |i|
                Saw.ar(freq * (1 + ((i - 1.5) * 0.005)))
            })) * 0.25;
            filt = RLPF.ar(saws, 1800, 0.5);
            amp = EnvGen.kr(Env([0, 1, 1, 0],
                                [attack, sustain - attack - release, release], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("dustbass", "witch",
        "Lo-fi bass with bit reduction. Crusty.", raw"""
        // dustbass.scd  —  Bit-crushed bass
        SynthDef(\dustbass, { |out, pan = 0, freq = 70, sustain = 0.4, gain = 0.55,
                              bits = 4|
            var osc, crushed, filt, amp, sig;
            osc = Saw.ar(freq);
            crushed = (osc * (2 ** bits)).round / (2 ** bits);
            filt = LPF.ar(crushed, 1200);
            amp = EnvGen.kr(Env.perc(0.01, sustain, 1, -3), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("melancholo", "witch",
        "Quiet minor-key lead. Reflective, breathy.", raw"""
        // melancholo.scd  —  Breathy minor lead
        SynthDef(\melancholo, { |out, pan = 0, freq = 330, sustain = 1.0, gain = 0.35|
            var osc, breath, mixed, filt, amp, sig;
            osc = SinOsc.ar(freq) + (Saw.ar(freq) * 0.15);
            breath = WhiteNoise.ar * 0.05;
            mixed = osc + breath;
            filt = LPF.ar(mixed, 2400);
            amp = EnvGen.kr(Env([0, 1, 0.6, 0], [0.1, 0.2, sustain - 0.3], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("ghostpad", "witch",
        "Amplitude-tremolo airy pad. Comes and goes like a ghost.", raw"""
        // ghostpad.scd  —  Tremolo-driven airy pad
        SynthDef(\ghostpad, { |out, pan = 0, freq = 220, sustain = 3.0, gain = 0.35,
                              trem_rate = 1.5|
            var carrier, trem, filt, amp, sig;
            carrier = Mix.ar([SinOsc.ar(freq), SinOsc.ar(freq * 1.005),
                              SinOsc.ar(freq * 2) * 0.3]);
            trem = SinOsc.kr(trem_rate).range(0.2, 1);
            filt = BPF.ar(carrier * 0.6, 1800, 0.6) * trem;
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.6, sustain - 1.6, 1.0], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ═══════════════════════════════════════════════════════════════════
    # Angelcore / Ethereal — bright, airy, ascending, dreamy
    # ═══════════════════════════════════════════════════════════════════
    _syn("chimerise", "angel",
        "Ascending bell-like chimes with shimmer.", raw"""
        // chimerise.scd  —  Glittering rising bells
        SynthDef(\chimerise, { |out, pan = 0, freq = 660, sustain = 1.5, gain = 0.45,
                               mratio = 3.5|
            var idx, mod, car, shimmer, amp, sig;
            idx = EnvGen.kr(Env([4, 0.4], [sustain], \exp));
            mod = SinOsc.ar(freq * mratio) * idx * freq;
            car = SinOsc.ar(freq + mod);
            shimmer = SinOsc.ar(freq * 2.01) * EnvGen.kr(Env.perc(0.05, sustain * 0.5)) * 0.2;
            amp = EnvGen.kr(Env.perc(0.01, sustain, 1, -5), doneAction: 2);
            sig = (car + shimmer) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("airpad", "angel",
        "Airy sine pad with slow chorus.", raw"""
        // airpad.scd  —  Soft sine pad
        SynthDef(\airpad, { |out, pan = 0, freq = 440, sustain = 3.0, gain = 0.4,
                            attack = 0.8, release = 1.5|
            var sines, ch_l, ch_r, amp, sig;
            sines = Mix.ar(Array.fill(4, { |i|
                SinOsc.ar(freq * (1 + ((i - 1.5) * 0.003)))
            })) * 0.25;
            ch_l = DelayN.ar(sines, 0.04, 0.011);
            ch_r = DelayN.ar(sines, 0.04, 0.019);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [attack, sustain - attack - release, release], \sin),
                            doneAction: 2);
            sig = ((ch_l + ch_r) * 0.5) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("glasspad", "angel",
        "Glass-like FM pad. Crystalline and slow.", raw"""
        // glasspad.scd  —  Glassy FM pad
        SynthDef(\glasspad, { |out, pan = 0, freq = 440, sustain = 3.0, gain = 0.4,
                              mratio = 4.0|
            var idx, mod, car, amp, sig;
            idx = EnvGen.kr(Env([0.5, 2, 0.5], [1.0, sustain - 1], \sin));
            mod = SinOsc.ar(freq * mratio) * idx * freq;
            car = SinOsc.ar(freq + mod);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [1.0, sustain - 2, 1.0], \sin),
                            doneAction: 2);
            sig = car * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("harppluck", "angel",
        "Harp-style pluck with long sparkly decay.", raw"""
        // harppluck.scd  —  Harp-flavoured pluck
        SynthDef(\harppluck, { |out, pan = 0, freq = 440, sustain = 1.8, gain = 0.5|
            var exc, loop, amp, sig;
            exc = WhiteNoise.ar * EnvGen.kr(Env.perc(0, 0.003));
            loop = CombL.ar(exc, 0.1, 1 / freq, sustain);
            loop = LPF.ar(loop, freq * 4);
            amp = EnvGen.kr(Env.linen(0.001, sustain, 0.2), doneAction: 2);
            sig = loop * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("breezelead", "angel",
        "Soft breathy sine lead with portamento.", raw"""
        // breezelead.scd  —  Whisper sine lead
        SynthDef(\breezelead, { |out, pan = 0, freq = 660, sustain = 0.8, gain = 0.4|
            var glide, osc, breath, amp, sig;
            glide = Line.kr(freq * 0.92, freq, 0.08);
            osc = SinOsc.ar(glide);
            breath = HPF.ar(WhiteNoise.ar, 5000) * 0.04;
            amp = EnvGen.kr(Env([0, 1, 0.7, 0], [0.04, 0.2, sustain - 0.24], \sin),
                            doneAction: 2);
            sig = (osc + breath) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("cherub", "angel",
        "Octave-stacked sine. Crystalline child-choir feel.", raw"""
        // cherub.scd  —  Stacked-octave sine choir
        SynthDef(\cherub, { |out, pan = 0, freq = 440, sustain = 1.5, gain = 0.4|
            var stack, filt, amp, sig;
            stack = Mix.ar([SinOsc.ar(freq), SinOsc.ar(freq * 2) * 0.5,
                            SinOsc.ar(freq * 3) * 0.25, SinOsc.ar(freq * 4) * 0.125]);
            filt = LPF.ar(stack * 0.5, 5000);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.3, sustain - 0.6, 0.3], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("aurora", "angel",
        "Slow filter sweep on saw pad. Aurora-like motion.", raw"""
        // aurora.scd  —  Sweeping pad
        SynthDef(\aurora, { |out, pan = 0, freq = 220, sustain = 4.0, gain = 0.4,
                            sweep = 3.0|
            var saws, env_sweep, filt, amp, sig;
            saws = Mix.ar(Array.fill(5, { |i|
                Saw.ar(freq * (1 + ((i - 2) * 0.008)))
            })) * 0.18;
            env_sweep = EnvGen.kr(Env([400, 4000, 400], [sweep * 0.5, sweep * 0.5], \sin));
            filt = RLPF.ar(saws, env_sweep, 0.4);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [1.0, sustain - 2.0, 1.0], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("silkstring", "angel",
        "Bowed string-like saw with vibrato.", raw"""
        // silkstring.scd  —  Bowed-saw string
        SynthDef(\silkstring, { |out, pan = 0, freq = 440, sustain = 1.2, gain = 0.4,
                                vibrato = 5, vib_depth = 3|
            var lfo, osc, filt, amp, sig;
            lfo = SinOsc.kr(vibrato) * vib_depth;
            osc = Saw.ar(freq + lfo) + Saw.ar(freq + lfo + 0.7);
            filt = RLPF.ar(osc * 0.3, 3000, 0.5);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.15, sustain * 0.6, sustain * 0.3], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("seraphpad", "angel",
        "Multi-octave detuned sine — wide and angelic.", raw"""
        // seraphpad.scd  —  Wide multi-octave sine pad
        SynthDef(\seraphpad, { |out, pan = 0, freq = 440, sustain = 3.5, gain = 0.4|
            var stack, filt, amp, sig;
            stack = SinOsc.ar(freq) + (SinOsc.ar(freq * 2.005) * 0.5) +
                    (SinOsc.ar(freq * 0.5) * 0.4) +
                    (SinOsc.ar(freq * 4.01) * 0.2);
            filt = LPF.ar(stack * 0.4, 6000);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.9, sustain - 1.8, 0.9], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ═══════════════════════════════════════════════════════════════════
    # Lofi — tape warm, dusty, gentle
    # ═══════════════════════════════════════════════════════════════════
    _syn("lofikey", "lofi",
        "Detuned-saw piano-ish key. Slightly out of tune.", raw"""
        // lofikey.scd  —  Lofi electric-piano-ish key
        SynthDef(\lofikey, { |out, pan = 0, freq = 330, sustain = 0.8, gain = 0.45,
                             detune = 4|
            var osc, filt, amp, sig;
            osc = SinOsc.ar(freq) + (Saw.ar(freq + detune) * 0.2) +
                  (SinOsc.ar(freq * 2) * 0.15);
            filt = LPF.ar(osc, 2200);
            amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -3), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("tapewarm", "lofi",
        "Pad with audio-rate wow/flutter (tape-style pitch wobble).", raw"""
        // tapewarm.scd  —  Warm-tape pad with wobble
        SynthDef(\tapewarm, { |out, pan = 0, freq = 220, sustain = 2.0, gain = 0.4,
                              flutter = 0.5|
            var wow, pitch, saws, filt, amp, sig;
            wow = SinOsc.kr(4.7) * flutter;
            pitch = freq + wow;
            saws = Mix.ar([Saw.ar(pitch), Saw.ar(pitch * 1.005)]) * 0.3;
            filt = LPF.ar(saws, 1800);
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.3, sustain - 0.6, 0.3], \sin),
                            doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("lofikick", "lofi",
        "Soft sub kick with subtle vinyl click.", raw"""
        // lofikick.scd  —  Lofi sub kick
        SynthDef(\lofikick, { |out, pan = 0, freq = 50, sustain = 0.35, gain = 0.7,
                              click = 0.3|
            var pitch, body, snap, amp, sig;
            pitch = EnvGen.kr(Env([110, freq], [0.05], \exp));
            body = SinOsc.ar(pitch);
            snap = LPF.ar(WhiteNoise.ar, 1500) *
                   EnvGen.kr(Env.perc(0, 0.005)) * click;
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -4), doneAction: 2);
            sig = (body + snap) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("lofihat", "lofi",
        "Filtered noise hi-hat with bit reduction.", raw"""
        // lofihat.scd  —  Bit-crushed hi-hat
        SynthDef(\lofihat, { |out, pan = 0, sustain = 0.1, gain = 0.4, bits = 6|
            var src, crushed, filt, amp, sig;
            src = PinkNoise.ar;
            crushed = (src * (2 ** bits)).round / (2 ** bits);
            filt = HPF.ar(crushed, 5000);
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -6), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("lofibass", "lofi",
        "Round sine bass with subtle warmth.", raw"""
        // lofibass.scd  —  Soft round bass
        SynthDef(\lofibass, { |out, pan = 0, freq = 80, sustain = 0.4, gain = 0.55|
            var osc, body, amp, sig;
            osc = SinOsc.ar(freq);
            body = osc + (osc * osc * 0.2);
            amp = EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction: 2);
            sig = body * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("mellowfm", "lofi",
        "Soft 2-op FM with low modulation index. Mellow keys.", raw"""
        // mellowfm.scd  —  Calm 2-op FM
        SynthDef(\mellowfm, { |out, pan = 0, freq = 330, sustain = 0.8, gain = 0.45,
                              mratio = 2, mindex = 1.5|
            var idx, mod, car, amp, sig;
            idx = EnvGen.kr(Env([mindex, 0.1], [sustain * 0.7], \exp));
            mod = SinOsc.ar(freq * mratio) * idx * freq;
            car = SinOsc.ar(freq + mod);
            amp = EnvGen.kr(Env.perc(0.01, sustain, 1, -3), doneAction: 2);
            sig = car * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("vinylcrackle", "lofi",
        "Pink-noise crackle texture. Use to layer under any beat.", raw"""
        // vinylcrackle.scd  —  Vinyl crackle ambience
        SynthDef(\vinylcrackle, { |out, pan = 0, sustain = 1.0, gain = 0.25, density = 8|
            var pops, hiss, sig, amp;
            pops = Dust.ar(density) * 0.7;
            hiss = PinkNoise.ar * 0.04;
            sig = (pops + hiss);
            amp = EnvGen.kr(Env.linen(0.01, sustain, 0.2), doneAction: 2);
            sig = sig * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("chordstab", "lofi",
        "Quick-decay lofi chord stab via a fixed minor-triad.", raw"""
        // chordstab.scd  —  Lofi chord stab (root + min3 + 5)
        // Plays a small minor triad at `freq`. Use `:degree` patterning
        // to move the root around.
        SynthDef(\chordstab, { |out, pan = 0, freq = 220, sustain = 0.4, gain = 0.45|
            var stack, filt, amp, sig;
            stack = Mix.ar([Saw.ar(freq), Saw.ar(freq * 1.189), Saw.ar(freq * 1.498)]) * 0.25;
            filt = LPF.ar(stack, 2200);
            amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -3), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ═══════════════════════════════════════════════════════════════════
    # FX / extras — risers, zaps, atmospheric layers
    # ═══════════════════════════════════════════════════════════════════
    _syn("lazerzap", "fx",
        "Sci-fi zap. Pitch-fall sine + noise crackle.", raw"""
        // lazerzap.scd  —  Quick sci-fi zap
        SynthDef(\lazerzap, { |out, pan = 0, sustain = 0.2, gain = 0.6|
            var pitch, beam, crack, amp, sig;
            pitch = EnvGen.kr(Env([3000, 200], [sustain], \exp));
            beam = SinOsc.ar(pitch);
            crack = WhiteNoise.ar * EnvGen.kr(Env.perc(0, 0.03)) * 0.5;
            amp = EnvGen.kr(Env.perc(0, sustain, 1, -4), doneAction: 2);
            sig = (beam + crack) * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("rainpad", "fx",
        "Pad with audio-rate noise modulation. Rainy texture.", raw"""
        // rainpad.scd  —  Pad with rain ambience
        SynthDef(\rainpad, { |out, pan = 0, freq = 220, sustain = 3.0, gain = 0.35|
            var pad, rain, mixed, amp, sig;
            pad = Mix.ar([SinOsc.ar(freq), SinOsc.ar(freq * 2) * 0.3,
                          SinOsc.ar(freq * 3) * 0.15]) * 0.3;
            rain = HPF.ar(PinkNoise.ar, 3000) * 0.15;
            mixed = pad + rain;
            amp = EnvGen.kr(Env([0, 1, 1, 0], [0.6, sustain - 1.6, 1.0], \sin),
                            doneAction: 2);
            sig = mixed * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("bellsynth", "lead",
        "Additive bell — sum of sines at modal partials.", raw"""
        // bellsynth.scd  —  Additive bell with inharmonic partials
        SynthDef(\bellsynth, { |out, pan = 0, freq = 440, sustain = 2.5, gain = 0.4|
            var partials, amp, sig;
            partials = Mix.ar([
                SinOsc.ar(freq * 1.00) * EnvGen.kr(Env.perc(0, sustain, 1, -4)),
                SinOsc.ar(freq * 2.76) * EnvGen.kr(Env.perc(0, sustain * 0.7, 1, -5)) * 0.5,
                SinOsc.ar(freq * 5.40) * EnvGen.kr(Env.perc(0, sustain * 0.5, 1, -6)) * 0.3,
                SinOsc.ar(freq * 8.93) * EnvGen.kr(Env.perc(0, sustain * 0.3, 1, -7)) * 0.15,
            ]) * 0.3;
            amp = EnvGen.kr(Env.linen(0.001, sustain, 0.1), doneAction: 2);
            sig = partials * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("wobpunk", "bass",
        "Punky wobble bass with formant modulation.", raw"""
        // wobpunk.scd  —  Wobble with vowel formants
        SynthDef(\wobpunk, { |out, pan = 0, freq = 60, sustain = 0.6, gain = 0.55,
                             rate = 6|
            var osc, form_freq, filt, amp, sig;
            osc = Saw.ar(freq);
            form_freq = SinOsc.kr(rate).range(400, 1600);
            filt = BPF.ar(osc, form_freq, 0.25) + LPF.ar(osc, 500) * 0.6;
            amp = EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction: 2);
            sig = (filt * 1.3).tanh * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("glitchhat", "perc",
        "Stuttering noise hat — Dust + filtered burst.", raw"""
        // glitchhat.scd  —  Glitchy stuttering hat
        SynthDef(\glitchhat, { |out, pan = 0, sustain = 0.15, gain = 0.4, density = 80|
            var src, stutter, filt, amp, sig;
            src = WhiteNoise.ar;
            stutter = Dust.kr(density);
            filt = HPF.ar(src, 6000) * Trig.kr(stutter, 0.01);
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -5), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    _syn("industrial", "perc",
        "Heavy industrial hit. FM noise + tanh distortion.", raw"""
        // industrial.scd  —  Metallic industrial hit
        SynthDef(\industrial, { |out, pan = 0, sustain = 0.4, gain = 0.6,
                                body_freq = 120|
            var mod, body, noise, mixed, amp, sig;
            mod = SinOsc.ar(body_freq * 3.7) * body_freq * 6;
            body = SinOsc.ar(body_freq + mod);
            noise = HPF.ar(WhiteNoise.ar, 2000) * EnvGen.kr(Env.perc(0, 0.06)) * 0.5;
            mixed = (body + noise) * 0.8;
            mixed = mixed.tanh;
            amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -4), doneAction: 2);
            sig = mixed * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),
]
