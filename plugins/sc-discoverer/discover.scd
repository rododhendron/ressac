// sc-discoverer / discover.scd
//
// Discovery script shipped by plugins/sc-discoverer/bootstrap.jl
// via /dirt/evalSC. Iterates UGen.allSubclasses, captures each
// UGen's signature + SCDoc body, writes <ClassName>.md files
// under the cache dir, sends /ressac/sc-discovery-done on completion.
//
// Receivers of OSC ack:
//   /ressac/sc-discovery-done <count:int>

(
var cacheDir, docsDir, manifestPath, ugens, count;
var writeUgenMd, scDocToMd, signaturesFor;

cacheDir     = (Platform.userHomeDir +/+ ".cache" +/+ "ressac"
                +/+ "plugins" +/+ "sc-autodiscover").asString;
docsDir      = cacheDir +/+ "docs";
manifestPath = cacheDir +/+ "plugin.toml";

// Ensure the cache layout exists.
File.mkdir(cacheDir);
File.mkdir(docsDir);

// Auto-generated plugin.toml so the loader treats the cache as a
// normal plugin and the [docs] handler from sub-project 7 scans
// docs/*.md without any custom handling.
File.use(manifestPath, "w", { |f|
    f.write("name        = \"sc-autodiscover\"\n");
    f.write("version     = \"0.1.0\"\n");
    f.write("description = \"Auto-generated SuperCollider UGen docs\"\n");
    f.write("\n[docs]\ndir = \"docs\"\n");
});

// Enumerate non-abstract UGen subclasses (must respond to .ar).
ugens = UGen.allSubclasses.select { |class|
    class.class.findRespondingMethodFor(\ar).notNil
};
("[sc-discover] " ++ ugens.size.asString ++ " UGen classes to process").postln;

// Per-rate signature extraction. Returns an IdentityDictionary keyed
// by rate symbol (\ar, \kr, \ir) whose values are arrays of
// (name: symbol, default: any) IdentityDictionaries. Drops the
// implicit `this` argument at index 0 of the method's argNames.
signaturesFor = { |class|
    var out = IdentityDictionary.new;
    [\ar, \kr, \ir].do { |rate|
        var m = class.class.findRespondingMethodFor(rate);
        if (m.notNil) {
            var argNames = m.argNames;
            var defaults = m.prototypeFrame;
            var pairs = (1 .. (argNames.size - 1)).collect { |i|
                IdentityDictionary[\name -> argNames[i], \default -> defaults[i]]
            };
            out[rate] = pairs;
        };
    };
    out
};

// scDocToMd and writeUgenMd are filled by Tasks 9-10.

count = 0;
ugens.do { |class|
    // Per-UGen processing wired in Task 11.
    count = count + 1;
};

NetAddr.localAddr.sendMsg("/ressac/sc-discovery-done", count);
"[sc-discover] done".postln;
)
