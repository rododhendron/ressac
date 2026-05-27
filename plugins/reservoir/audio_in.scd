// ressac_audio_in — listens to SoundIn.ar(0) (system default mic /
// audio interface input 1) and ships the broadband RMS amplitude to
// Ressac at ~50 Hz on /ressac/audio_in.
//
// Use the `:audio-in start` ex-command in Ressac to (re-)deploy this
// SynthDef and instantiate a node; `:audio-in stop` frees it.
//
// Why a custom SynthDef rather than SuperDirt taps: SoundIn requires
// a server with audio inputs enabled (`s.options.numInputBusChannels`
// > 0). The default scsynth boot honours that. Loudest signal that
// reaches threshold ≈ 0.3 RMS, comfortably driving a noisy AdEx
// reservoir into synchronised firing.

SynthDef(\ressac_audio_in, { |in_bus = 0|
    var sig, rms;
    sig = SoundIn.ar(in_bus);
    // 10 ms attack, 50 ms release — fast enough to track transients,
    // slow enough that consonants don't dominate.
    rms = Amplitude.kr(sig, 0.01, 0.05);
    SendReply.kr(Impulse.kr(50), '/ressac/audio_in', [rms]);
}).add;
