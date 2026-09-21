# MIDI et contrôle OSC externe

Ressac n'embarque pas de driver MIDI. Il expose deux points d'entrée OSC
que tout ce qui parle OSC peut piloter : contrôleurs MIDI, séquenceurs
matériels, layouts TouchOSC, patches Max, ou un autre processus Julia. Le
pont MIDI, ce sont 6 lignes de SuperCollider à coller une fois.

## Points d'entrée

Écoute : UDP `127.0.0.1:57121` (le socket du scope — partagé).

```
/ressac/trigger  s:<nom>  [clé valeur ...]
    → un tir de <nom> via SuperDirt. Les arguments supplémentaires
      passent tels quels : freq, gain, n, cut, etc.

/ressac/set      s:<clé>   v:<valeur>
    → modifie l'état live. Pour l'instant :
        clé = "cps"  → set_cps!(valeur)
```

Les deux s'activent dès que quelque chose ouvre l'écouteur du scope (un
`:scope` quelconque). `:scope amp` puis `:scope off` au démarrage ouvre le
socket sans scope visible.

## Pont MIDI — à coller dans SuperCollider

Un `MIDIFunc` de 6 lignes qui traduit chaque note-on MIDI en
/ressac/trigger vers un sample, le numéro de note mappé sur `n`
(demi-tons depuis le do du milieu) :

```supercollider
// Dans l'éditeur de SuperCollider, une fois par démarrage de SC :
MIDIClient.init;
MIDIIn.connectAll;
~ressacOSC = NetAddr.new("127.0.0.1", 57121);
MIDIFunc.noteOn({ |vel, num, chan|
    ~ressacOSC.sendMsg("/ressac/trigger", "supersaw",
        "n", (num - 60).asInteger,
        "gain", (vel / 127).asFloat);
});
```

…et tu poses un clavier MIDI sur un synth `:supersaw` sans quitter la
pane patterns.

Routage par canal (canal 1 → batterie, canal 2 → basse) :

```supercollider
MIDIFunc.noteOn({ |vel, num, chan|
    var sound = if(chan == 0) { "kick" } { "bass" };
    ~ressacOSC.sendMsg("/ressac/trigger", sound,
        "n", (num - 36).asInteger,
        "gain", (vel / 127).asFloat);
});
```

CC → cps :

```supercollider
MIDIFunc.cc({ |val, num, chan|
    // CC 7 (volume) → cps de 0.1 à 1.5
    if(num == 7) { ~ressacOSC.sendMsg("/ressac/set", "cps", (0.1 + (val/127) * 1.4)) };
});
```

## Depuis un REPL Julia

```julia
using Sockets
sock = UDPSocket()
send(sock, ip"127.0.0.1", 57121,
     encode(Ressac.OSCMessage("/ressac/trigger", Any["bd"])))
```

## Depuis un shell

`oscchief` ou `sendosc` font l'affaire :

```bash
oscchief send 127.0.0.1 57121 /ressac/trigger s bd
oscchief send 127.0.0.1 57121 /ressac/set s cps f 0.75
```

## TouchOSC / Lemur

Pointe-les sur `127.0.0.1` UDP `57121` avec les mêmes chemins. Un pad =
un /ressac/trigger avec un nom de sample en dur ; un fader pilote
/ressac/set s:cps v:0..1.5.

## Pourquoi pas de MIDI natif ?

Deux raisons :

1. **Le coût de la dépendance** — PortMidi.jl force chaque utilisateur à
   compiler une bibliothèque native à l'installation. La route OSC
   n'ajoute rien et réutilise le socket que Ressac possède déjà.

2. **Plus souple** — une fois MIDI → OSC câblé dans SC, tu peux le
   brancher ailleurs (Tidal, Pd, Max) de la même façon. Un driver côté
   Julia ferait de Ressac le seul consommateur.

Si un jour tu veux une vraie dépendance MIDI (découverte automatique,
branchement à chaud, sans pont SC), ouvre une issue : le socket d'écoute
existe déjà, seule la source changerait.
