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

    "".postln;
    "================================================".postln;
    "SuperDirt listening on UDP 57120 (12 orbits).".postln;
    ("Sample sets: " ++ ~dirt.soundLibrary.buffers.size.asString).postln;
    "Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC".postln;
    "================================================".postln;
});
