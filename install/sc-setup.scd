// install/sc-setup.scd
//
// One-shot SuperCollider script that installs the two Quarks Ressac
// needs (SuperDirt + Dirt-Samples) and recompiles the class library.
// Run via:
//
//     sclang install/sc-setup.scd
//
// Idempotent: re-running is a no-op once the Quarks are present.

Quarks.install("SuperDirt");
Quarks.install("Dirt-Samples");
Quarks.install("Vowel");      // formant filter shapes used by some snippets
thisProcess.recompile;

"".postln;
"=== Ressac SuperCollider setup complete ===".postln;
"Next:".postln;
"  1. start the SC server + SuperDirt with: just audio".postln;
"  2. in another terminal: just live".postln;
0.exit;
