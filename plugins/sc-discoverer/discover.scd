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

// Parse a .schelp file's content into (short, body, category) where:
//   short    = first non-blank line of the description:: block, max 200 chars
//   body     = SCDoc reformatted to Markdown (## Description, ### .ar,
//              - **arg** — text, ```sclang …``` examples)
//   category = first segment after `UGens>` in `categories::`, lowercased
//
// Missing HelpFile → all three fields are empty strings; the caller
// still emits a signature-only frontmatter entry.
scDocToMd = { |helpPath|
    var src, lines, mdParts, descPara;
    var short = "", body = "", category = "";
    var currentBlock = "", currentArg = nil;
    var hadExamples = false;

    if (File.exists(helpPath).not) {
        // Return an IdentityDictionary with empty fields.
        IdentityDictionary[\short -> "", \body -> "", \category -> ""];
    } {
        src = File.readAllString(helpPath);
        lines = src.split($\n);
        mdParts = List.new;
        descPara = "";

        // First pass: extract `categories::` line if present.
        // SCDoc convention: `categories::UGens>Generators>Deterministic`.
        // We pick the second segment ("Generators") and lowercase it.
        lines.do { |ln|
            if (ln.beginsWith("categories::")) {
                var cats = ln.drop(12).trim.split($\>);
                if (cats.size >= 2) {
                    category = cats[1].trim.toLower;
                };
            };
        };

        // Second pass: walk blocks. SCDoc blocks are introduced by
        // `keyword::[arg]` and terminated by a `::` on its own line
        // OR by the next top-level keyword. We only track the blocks
        // we care about: description, classmethods.method::ar/kr/ir,
        // argument::name, examples.
        lines.do { |ln|
            var stripped = ln.trim;
            if (stripped == "::") {
                currentBlock = "";
                currentArg = nil;
            } {
                case
                { stripped.beginsWith("description::") } {
                    currentBlock = "description";
                    mdParts.add("## Description\n\n");
                }
                { stripped.beginsWith("argument::") } {
                    currentArg = stripped.drop(10).trim;
                    currentBlock = "argument";
                    mdParts.add("- **" ++ currentArg ++ "** — ");
                }
                { stripped.beginsWith("method::") } {
                    var name = stripped.drop(8).trim;
                    if (#[\ar, \kr, \ir].includes(name.asSymbol)) {
                        currentBlock = "method";
                        mdParts.add("### ." ++ name ++ "\n\n");
                    };
                }
                { stripped.beginsWith("examples::") } {
                    hadExamples = true;
                    currentBlock = "examples";
                    mdParts.add("## Examples\n\n```sclang\n");
                }
                // Block body line — anything not introducing a new block.
                // We test for ":" anywhere because SCDoc keywords always
                // contain "::".
                { stripped.contains("::").not } {
                    if (currentBlock == "description") {
                        mdParts.add(ln ++ "\n");
                        // First non-blank line goes into descPara for `short`.
                        if (descPara.isEmpty and: { stripped.notEmpty }) {
                            descPara = stripped;
                        };
                    };
                    if (currentBlock == "argument") {
                        mdParts.add(ln.trim ++ "\n");
                    };
                    if (currentBlock == "method") {
                        mdParts.add(ln ++ "\n");
                    };
                    if (currentBlock == "examples") {
                        mdParts.add(ln ++ "\n");
                    };
                };
            };
        };

        if (hadExamples) { mdParts.add("```\n") };

        body  = mdParts.join("");
        short = descPara.copyRange(0, min(descPara.size - 1, 199));

        IdentityDictionary[\short -> short, \body -> body, \category -> category];
    };
};

// Build the TOML frontmatter string (between +++ fences) plus the
// Signatures section + parsed body, write to docs/<ClassName>.md.
// `parsed` is the IdentityDictionary returned by scDocToMd.
writeUgenMd = { |class, sigs, parsed, outPath|
    var allKwargs, fm, kwargsToml, tagsToml;

    // Collect all distinct kwarg names across rates.
    allKwargs = Set.new;
    sigs.keysValuesDo { |rate, pairs|
        pairs.do { |p| allKwargs.add(p[\name]) };
    };

    kwargsToml = "["
        ++ allKwargs.asArray.collect { |n| "\"" ++ n.asString ++ "\"" }.join(", ")
        ++ "]";
    tagsToml = "[\"sc-ugen\"";
    if (parsed[\category].notNil and: { parsed[\category].notEmpty }) {
        tagsToml = tagsToml ++ ", \"" ++ parsed[\category] ++ "\"";
    };
    tagsToml = tagsToml ++ "]";

    fm = "+++\n";
    fm = fm ++ "name = \"" ++ class.name.asString ++ "\"\n";
    fm = fm ++ "short = \"" ++ parsed[\short].replace("\"", "'") ++ "\"\n";
    fm = fm ++ "tags = " ++ tagsToml ++ "\n";
    fm = fm ++ "kwargs = " ++ kwargsToml ++ "\n";
    fm = fm ++ "aliases = []\n";
    fm = fm ++ "examples = []\n";
    fm = fm ++ "+++\n\n";
    fm = fm ++ "# " ++ class.name.asString ++ "\n\n";

    // Signature section — one bullet per rate the UGen responds to.
    fm = fm ++ "## Signatures\n\n";
    sigs.keysValuesDo { |rate, pairs|
        var pieces = pairs.collect { |p|
            p[\name].asString ++ "=" ++ p[\default].asString
        };
        fm = fm ++ "- `" ++ class.name.asString ++ "." ++ rate.asString
                ++ "(" ++ pieces.join(", ") ++ ")`\n";
    };
    fm = fm ++ "\n";

    // Body from SCDoc (may be empty if no HelpFile was found).
    fm = fm ++ parsed[\body];

    File.use(outPath, "w", { |f| f.write(fm) });
};

// Clean stale MD files before regenerating. Keeps the docs dir
// in sync with the current UGen list (drops files for UGens that
// vanished after a sc3-plugins uninstall, etc.).
File.deleteAll(docsDir);
File.mkdir(docsDir);

count = 0;
ugens.do { |class|
    var sigs, helpPath, parsed, outPath;
    sigs     = signaturesFor.value(class);
    helpPath = SCDoc.helpTargetDir +/+ "Classes"
               +/+ class.name.asString ++ ".schelp";
    parsed   = scDocToMd.value(helpPath);
    outPath  = docsDir +/+ class.name.asString ++ ".md";
    writeUgenMd.value(class, sigs, parsed, outPath);
    count = count + 1;
};

NetAddr.localAddr.sendMsg("/ressac/sc-discovery-done", count);
"[sc-discover] done".postln;
)
