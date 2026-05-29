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

// Helper definitions go here (Tasks 8-10):
//   signaturesFor — per-rate (.ar/.kr/.ir) arg name + default extraction
//   scDocToMd     — SCDoc HelpFile → Markdown converter
//   writeUgenMd   — frontmatter + body + signatures section, write to disk

count = 0;
ugens.do { |class|
    // Per-UGen processing wired in Task 11.
    count = count + 1;
};

NetAddr.localAddr.sendMsg("/ressac/sc-discovery-done", count);
"[sc-discover] done".postln;
)
