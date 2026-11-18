# Touches

Page générée depuis le registre de bindings (`src/keymap.jl`, `src/app_keymap.jl` et les scopes des panes/modaux) par `scripts/gen_keys_wiki.jl` — ne pas éditer à la main. Dans l'app, `?` ouvre la même chose pour le contexte courant, `Tab` tout le mode.

Notation : `Space d` = Space puis d · `Ctrl-w s` = Ctrl-w puis s · `g t` = g puis t. Les touches séparées par ` / ` sont des synonymes.

Une touche descend les couches actives — transitoire (saisie, leader, mode pane…), modale, pane focalisée, **mode** (PLAY · DESIGN · EXPLORE), partout — jusqu'à la première qui la connaît. Les gestes d'un mode valent quelle que soit la pane.

## PATTERNS

### PATTERNS — d'où qu'on soit (fiche, wiki, journal)

**Évaluer**

| Touche | Action |
|---|---|
| `e` | évaluer la ligne |
| `E` | tout évaluer |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `m` | mute / unmute le slot |

**Aide**

| Touche | Action |
|---|---|
| `K` | la fiche du mot sous le curseur (DOC) |

**Éditer**

| Touche | Action |
|---|---|
| `Space` | snippet… |

### Gamme (tuning)

**Vues**

| Touche | Action |
|---|---|
| `r` | étiquettes : cents ⟷ ratios |

### Visualiseur de notes

**Naviguer**

| Touche | Action |
|---|---|
| `+ / l / →` | fenêtre plus large |
| `- / h / ←` | fenêtre plus étroite |
| `j / ↓` | moins de couloirs de percussion |
| `k / ↑` | plus de couloirs de percussion |

### Modulation (drones)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | argument suivant |
| `k / ↑` | argument précédent |
| `Tab` | drone suivant |
| `S-Tab` | précédent (groupe) |

**Éditer**

| Touche | Action |
|---|---|
| `l / →` | moduler + |
| `h / ←` | moduler − |
| `L` | moduler + (grand pas) |
| `H` | moduler − (grand pas) |
| `=` | saisir une valeur |
| `0` | revenir au défaut |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `x` | relâcher ce drone |
| `Ctrl-x` | relâcher tous les drones |

**Sous-modes (touches une fois dedans)**

| Touche | Action |
|---|---|
| `Enter / Esc / Bksp` | saisie de valeur : valider / annuler / effacer |

### Pane patterns

**Jouer / écouter**

| Touche | Action |
|---|---|
| `g K` | écouter le mot sous le curseur |

**Éditer**

| Touche | Action |
|---|---|
| `>` | pattern : zoom ×2 |
| `<` | pattern : zoom ÷2 |
| `L` | pattern : décaler le token → |
| `H` | pattern : décaler le token ← |
| `X` | pattern : silence le token (~) |

**Naviguer**

| Touche | Action |
|---|---|
| `g s` | ouvrir le son sous le curseur, à droite |
| `g w` | ouvrir le wiki, à droite |
| `g x` | ouvrir l'explorateur de sons |

### Space + …

**Éditer**

| Touche | Action |
|---|---|
| `Space d` | slot @dN |
| `Space g` | gain |
| `Space l` | lpf |
| `Space h` | hpf |
| `Space p` | pan |
| `Space f` | fast |
| `Space s` | slow |
| `Space r` | room |
| `Space n` | n() |
| `Space e` | every |
| `Space m` | mask |
| `Space D` | chaîne delay |
| `Space c` | cat |
| `Space S` | stack |
| `Space v` | rev |
| `Space E` | euclidien |
| `Space R` | euclidien tourné |
| `Space J` | jersey (bd(3,8)) |
| `Space a` | chaîne d'effets (gain, lpf, room) |

**Aide**

| Touche | Action |
|---|---|
| `Space b` | ▸ sons (samples, instruments, synths) |
| `Space L` | ▸ sons rangés (réserve) |
| `Space I` | ▸ recettes (réserve) |
| `Space P` | ▸ motifs rangés (réserve) |
| `Space V` | ▸ variations du bloc |
| `Space w` | ▸ wiki |
| `Space ?` | ▸ aide |
| `Space k` | ranger la ligne @dN dans la réserve |

### Snippet avec des trous (après Space + lettre)

**Éditer**

| Touche | Action |
|---|---|
| `Tab` | trou suivant |
| `S-Tab` | trou précédent |
| `Esc` | sortir des trous |
| `i` | remplir le trou (insertion) |
| `u` | annuler le snippet |

### Tap (:tap / :bpm)

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space` | frapper |
| `Enter` | valider |
| `Esc` | annuler |

### Piano (:piano)

**Jouer / écouter**

| Touche | Action |
|---|---|
| `, / . / ; / b / c / m / n / v / w / x / z` | notes (rangée du bas = naturelles) |
| `d / g / h / j / s` | dièses |
| `[ / ]` | octave − / + |
| `Enter` | valider l'enregistrement |
| `Esc` | quitter |

### Sons (samples, instruments, synths)

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | insérer dans le pattern |
| `Bksp` | effacer le filtre |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `K / Space` | écouter |

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | catégorie suivante |
| `/` | chercher |
| `h / ←` | précédent |
| `l / →` | suivant |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### Mixer

**Jouer / écouter**

| Touche | Action |
|---|---|
| `m` | mute / unmute |
| `s` | solo |
| `u` | tout démuter |
| `! / .` | panic |

**Éditer**

| Touche | Action |
|---|---|
| `+ / -` | gain ±0.1 |
| `* / /` | gain ±0.5 |

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### Snippets

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | insérer |
| `/` | rechercher |

**Vues**

| Touche | Action |
|---|---|
| `Space` | aperçu |

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | onglet suivant de la réserve |
| `S-Tab` | onglet précédent |
| `l / →` | catégorie suivante |
| `h / ←` | catégorie précédente |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `Esc / q` | effacer la recherche → la catégorie → fermer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### Patterns rangés

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | charger |
| `1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9` | charger sur le slot N |
| `x` | supprimer |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space` | écouter par-dessus ce qui joue |

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | onglet suivant de la réserve |
| `S-Tab` | onglet précédent |
| `/` | chercher |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### Variations de pattern

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space / K` | écouter |
| `x` | couper l'écoute |

**Éditer**

| Touche | Action |
|---|---|
| `l` | verrouiller / relâcher |
| `r` | relancer depuis les verrouillées |
| `Enter` | remplacer le bloc |

**Fichiers**

| Touche | Action |
|---|---|
| `s` | ranger dans la bibliothèque |

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

## SON

### SON — depuis le texte, la DOC ou le studio

**Jouer / écouter**

| Touche | Action |
|---|---|
| `T / t` | entendre le son (maintenir = rafale) |
| `D` | drone : tenir le son / le relâcher |

**Éditer**

| Touche | Action |
|---|---|
| `Space` | maillon DSL… |

**Fichiers**

| Touche | Action |
|---|---|
| `U` | utiliser dans un pattern (sauve + @dN à gauche) |

**Structure**

| Touche | Action |
|---|---|
| `P` | élagage : mesurer l'impact de chaque nœud |

**Aide**

| Touche | Action |
|---|---|
| `K` | la fiche du mot sous le curseur (DOC) |
| `X` | l'explication du son (DOC) |
| `Y` | le graphe du son (DOC) |

### Vue d'onde

**Structure**

| Touche | Action |
|---|---|
| `s` | sculpter |

**Naviguer**

| Touche | Action |
|---|---|
| `l / →` | défiler → |
| `h / ←` | défiler ← |

**Vues**

| Touche | Action |
|---|---|
| `+ / i` | zoom + |
| `- / o` | zoom − |
| `0` | toute l'onde |

### Sculpt (l'onde et ses knobs)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | knob suivant |
| `k / ↑` | knob précédent |
| `Tab` | nœud suivant |
| `S-Tab` | précédent (groupe) |

**Éditer**

| Touche | Action |
|---|---|
| `l / →` | tirer + |
| `h / ←` | tirer − |
| `=` | saisir une valeur |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Enter` | jouer |

**Structure**

| Touche | Action |
|---|---|
| `o` | UGen suivant (même rôle) |
| `O` | UGen précédent |
| `n` | insérer un filtre après |
| `d` | supprimer le nœud (bypass) |
| `i` | recâbler l'entrée → |
| `I` | recâbler l'entrée ← |
| `r` | taux ar/kr suivant |
| `R` | taux précédent |
| `x` | dupliquer en parallèle |
| `m` | greffer un LFO sur le slot |

**Fichiers**

| Touche | Action |
|---|---|
| `e` | exporter dans l'éditeur |

**Vues**

| Touche | Action |
|---|---|
| `L` | défiler l'onde → |
| `H` | défiler l'onde ← |
| `0` | toute l'onde |
| `s` | revenir à la vue d'onde |
| `> / <` | défiler l'explication |

**Sous-modes (touches une fois dedans)**

| Touche | Action |
|---|---|
| `Enter / Esc / Bksp` | saisie de valeur : valider / annuler / effacer |

### Modulation (drones)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | argument suivant |
| `k / ↑` | argument précédent |
| `Tab` | drone suivant |
| `S-Tab` | précédent (groupe) |

**Éditer**

| Touche | Action |
|---|---|
| `l / →` | moduler + |
| `h / ←` | moduler − |
| `L` | moduler + (grand pas) |
| `H` | moduler − (grand pas) |
| `=` | saisir une valeur |
| `0` | revenir au défaut |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `x` | relâcher ce drone |
| `Ctrl-x` | relâcher tous les drones |

**Sous-modes (touches une fois dedans)**

| Touche | Action |
|---|---|
| `Enter / Esc / Bksp` | saisie de valeur : valider / annuler / effacer |

### Doc du synth (doc · explication · graphe)

**Naviguer**

| Touche | Action |
|---|---|
| `→` | onglet suivant (doc · explication · graphe) |
| `←` | onglet précédent |
| `l` | onglet suivant |
| `h` | onglet précédent |
| `l` | graphe : nœud suivant |
| `h` | graphe : nœud précédent |
| `Enter` | graphe : le knob de ce nœud dans le studio |
| `j / ↓` | défiler |
| `k / ↑` | remonter |
| `PgDn / Ctrl-d` | descendre d'un écran |
| `PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |

**Structure**

| Touche | Action |
|---|---|
| `d` | graphe : retirer le nœud (bypass) |

**Vues**

| Touche | Action |
|---|---|
| `]` | graphe : défiler → |
| `[` | graphe : défiler ← |

### Pane synth (texte)

**Structure**

| Touche | Action |
|---|---|
| `o` | atelier : un maillon après (il s'entend avant d'être gardé) |
| `O` | atelier : un maillon avant |
| `&` | atelier : faire bouger un nombre, en faire un argument, écouter jusqu'ici, bifurquer… |
| `d a m / y a m / c i m` | maillon : retirer · copier · remplacer (objet texte m) |

**Naviguer**

| Touche | Action |
|---|---|
| `g t` | synth suivant |
| `g T` | synth précédent |

### & + … (atelier, dans un son)

**Structure**

| Touche | Action |
|---|---|
| `& o` | un maillon après celui du curseur |
| `& O` | un maillon avant |
| `& r` | remplacer le maillon (cim) |
| `& d` | retirer le maillon (dam) |

**Éditer**

| Touche | Action |
|---|---|
| `& m` | faire bouger le nombre sous le curseur (un LFO, sur une ligne nommée) |
| `& k` | faire du nombre un argument du son |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `& s` | écouter le son jusqu'à ce maillon |

**Fichiers**

| Touche | Action |
|---|---|
| `& b` | bifurquer : une copie du son, à part |

**Aide**

| Touche | Action |
|---|---|
| `& ?` | à quoi sert ce maillon |

### Space + … (synth)

**Éditer**

| Touche | Action |
|---|---|
| `Space s` | source saw |
| `Space o` | source sin_osc |
| `Space p` | source pulse |
| `Space w` | bruit blanc |
| `Space l` | passe-bas résonnant |
| `Space h` | passe-haut |
| `Space b` | passe-bande |
| `Space m` | filtre Moog |
| `Space e` | enveloppe percussive |
| `Space a` | enveloppe ADSR |
| `Space t` | saturation |
| `Space f` | repliement |
| `Space c` | écrêtage |
| `Space r` | réverb |
| `Space d` | comb / delay |
| `Space L` | LFO |
| `Space n` | LFO (brut) |
| `Space g` | amplitude |
| `Space S` | sécurité |
| `Space u` | UGen sans wrapper |

**Aide**

| Touche | Action |
|---|---|
| `Space ?` | ▸ aide |

### Snippet avec des trous (après Space + lettre)

**Éditer**

| Touche | Action |
|---|---|
| `Tab` | trou suivant |
| `S-Tab` | trou précédent |
| `Esc` | sortir des trous |
| `i` | remplir le trou (insertion) |
| `u` | annuler le snippet |

### Atelier (o · O · cim dans un son)

**Jouer / écouter**

| Touche | Action |
|---|---|
| `↓ / ↑` | essayer la proposition suivante / précédente — elle s'entend |
| `Space` | réécouter (quand la recherche est vide) |

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | garder |

**Naviguer**

| Touche | Action |
|---|---|
| `Esc` | fermer : rien n'a changé |

### Sons (samples, instruments, synths)

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | insérer dans le pattern |
| `Bksp` | effacer le filtre |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `K / Space` | écouter |

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | catégorie suivante |
| `/` | chercher |
| `h / ←` | précédent |
| `l / →` | suivant |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### Librairie de synths

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space` | écouter |

**Naviguer**

| Touche | Action |
|---|---|
| `/` | chercher |
| `Tab` | onglet suivant de la réserve |
| `S-Tab` | onglet précédent |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `Esc / q` | fermer |

**Fichiers**

| Touche | Action |
|---|---|
| `Enter` | ouvrir dans une pane synth |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### sccode.org

**Fichiers**

| Touche | Action |
|---|---|
| `Enter` | charger dans une pane synth |

**Vues**

| Touche | Action |
|---|---|
| `Space` | aperçu |

**Naviguer**

| Touche | Action |
|---|---|
| `n / p` | page suivante / précédente |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `Esc / q` | fermer |

**Éditer**

| Touche | Action |
|---|---|
| `/` | rechercher |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

## EXPLORATEUR

### EXPLORATEUR

**Jouer / écouter**

| Touche | Action |
|---|---|
| `T / t` | entendre le candidat |
| `D` | drone du candidat on/off |

### Explorateur de synths (GA)

**Structure**

| Touche | Action |
|---|---|
| `n` | génération suivante |
| `B` | tune (réglage fin) ⟷ brew (rebrassage) |
| `g` | réglages GA |
| `R` | re-diverger (vieux parents + bruit) |
| `C` | diversité chaotique on/off |
| `G` | greffer un bon coup (filtre/satu/reverb…) |
| `>` | guidance perceptive suivante |
| `<` | guidance précédente |
| `Tab` | stratégie GA suivante |
| `S` | régénérer les candidats muets |
| `0` | population fraîche depuis la graine |
| `]` | rayon de divergence + |
| `[` | rayon de divergence − |

**Sélection**

| Touche | Action |
|---|---|
| `f` | favoriser |
| `d` | dévaluer |
| `u` | rôle d'usage suivant |
| `H` | récolte NRT (top-k du rôle) |
| `+` | tag : bon exemple du rôle |
| `-` | tag : mauvais exemple du rôle |

**Fichiers**

| Touche | Action |
|---|---|
| `M` | sculpter le candidat |
| `e` | exporter dans l'éditeur… |
| `w` | sauver comme synth… |
| `s` | sauver comme graine… |
| `y` | copier le DSL |

**Vues**

| Touche | Action |
|---|---|
| `x` | expliquer le son |
| `i` | détails (DSL) |
| `V` | vue d'onde |
| `L` | lignée |

**Éditer**

| Touche | Action |
|---|---|
| `p` | params du candidat |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `m` | mini-clavier (z x c v…) |

**Naviguer**

| Touche | Action |
|---|---|
| `h / j / k / l` | candidat ← ↓ ↑ → (ou flèches, ou clic) |
| `→ / ← / ↓ / ↑` | candidat voisin |
| `1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9` | sauter au candidat N |

**Sous-modes (touches une fois dedans)**

| Touche | Action |
|---|---|
| `Enter / Esc` | nommage (s, w, e) : valider / annuler |
| `y · Esc` | détails (i) : copier · fermer |
| `j/k · Space · V · Esc` | explication (x) : composante · solo · onde · fermer |
| `j/k · h/l · Esc` | réglages GA (g) : ligne · valeur · fermer |
| `j/k · h/l · r · Esc` | params (p) : ligne · valeur · reset · fermer |
| `z x c v… · Esc` | mini-clavier (m) : notes · quitter |
| `Esc` | lignée (L) : fermer |

```
Lecture d'une carte :
  ●A          cluster (sons génétiquement proches = même lettre)
  Saw→RLPF→…  chaîne de signal source→…→sortie
  freq 220 …  paramètres clés (constantes du génome)
  5 nœuds…    taille du DAG + origine (graine/muté/croisé)
  ♪NN         adéquation mesurée au rôle (%) · ⚠ MUET = mesuré silencieux
```

### Vue d'onde

**Structure**

| Touche | Action |
|---|---|
| `s` | sculpter |

**Naviguer**

| Touche | Action |
|---|---|
| `l / →` | défiler → |
| `h / ←` | défiler ← |

**Vues**

| Touche | Action |
|---|---|
| `+ / i` | zoom + |
| `- / o` | zoom − |
| `0` | toute l'onde |

### Sculpt (l'onde et ses knobs)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | knob suivant |
| `k / ↑` | knob précédent |
| `Tab` | nœud suivant |
| `S-Tab` | précédent (groupe) |

**Éditer**

| Touche | Action |
|---|---|
| `l / →` | tirer + |
| `h / ←` | tirer − |
| `=` | saisir une valeur |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Enter` | jouer |

**Structure**

| Touche | Action |
|---|---|
| `o` | UGen suivant (même rôle) |
| `O` | UGen précédent |
| `n` | insérer un filtre après |
| `d` | supprimer le nœud (bypass) |
| `i` | recâbler l'entrée → |
| `I` | recâbler l'entrée ← |
| `r` | taux ar/kr suivant |
| `R` | taux précédent |
| `x` | dupliquer en parallèle |
| `m` | greffer un LFO sur le slot |

**Fichiers**

| Touche | Action |
|---|---|
| `e` | exporter dans l'éditeur |

**Vues**

| Touche | Action |
|---|---|
| `L` | défiler l'onde → |
| `H` | défiler l'onde ← |
| `0` | toute l'onde |
| `s` | revenir à la vue d'onde |
| `> / <` | défiler l'explication |

**Sous-modes (touches une fois dedans)**

| Touche | Action |
|---|---|
| `Enter / Esc / Bksp` | saisie de valeur : valider / annuler / effacer |

## Partout

### Partout

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |
| `Ctrl-p` | palette : commandes, sons, fonctions, patterns |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `!` | panic (coupe tout) |
| `,` | hush (laisse finir les queues) |

**Divers**

| Touche | Action |
|---|---|
| `Esc` | quitter Ressac (Échap deux fois) |
| `:` | commande |
| `/` | chercher dans le texte (n / N : occurrence suivante / précédente) |

**Vues**

| Touche | Action |
|---|---|
| `S` | scope suivant |
| `+` | scope : zoom Y + |
| `-` | scope : zoom Y − |
| `>` | scope : zoom X + |
| `<` | scope : zoom X − |
| `=` | scope : zoom reset |
| `+` | réservoir : plus rapide |
| `-` | réservoir : plus lent |

**Panes & workspaces**

| Touche | Action |
|---|---|
| `Ctrl-w` | mode pane |
| `Ctrl-f` | montrer/cacher les floats |
| `:son · :wiki · :explorer · :back` | le volet à droite des patterns : un son, le wiki, l'explorateur — :back (ou :q) le referme |

### Journal

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | descendre |
| `k / ↑` | remonter |
| `PgDn / Ctrl-d` | descendre d'un écran |
| `PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |

### Documentation

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | descendre |
| `k / ↑` | remonter |
| `d / PgDn / Ctrl-d` | descendre d'un écran |
| `u / PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |
| `f` | suivre le curseur ou figer |

### Wiki (pane)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | défiler |
| `k / ↑` | remonter |
| `d / PgDn / Ctrl-d` | descendre d'un écran |
| `u / PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |
| `n / ] / →` | page du wiki suivante |
| `p / [ / ←` | page du wiki précédente |
| `1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9` | aller à la page N |

### Tutoriel

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | défiler |
| `k / ↑` | remonter |
| `PgDn / Ctrl-d` | descendre d'un écran |
| `PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |
| `n` | sauter l'étape |
| `p` | étape précédente |
| `r` | recommencer |

### Éditeur (patterns et synth)

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | basculer patterns ⟷ synth |
| `PgDn` | page suivante |
| `PgUp` | page précédente |
| `Ctrl-d / PgDn` | demi-page suivante |
| `Ctrl-u / PgUp` | demi-page précédente |
| `h / j / k / l` | déplacer le curseur (ou flèches) |
| `w / b / e` | mot suivant / précédent / fin de mot |
| `f / F / t / T` | aller au caractère (f dessus, t avant, majuscule = à gauche) |
| `;` | refaire la recherche de caractère |
| `,` | refaire la recherche de caractère, à l'envers |
| `W / B / E` | MOT (séparé par des espaces) |
| `0 / $` | début / fin de ligne |
| `g g / G` | début / fin du buffer |

**Éditer**

| Touche | Action |
|---|---|
| `.` | répéter la dernière édition |
| `+` | nombre +1 (maintenir = scrub) |
| `-` | nombre −1 |
| `*` | nombre +10 |
| `/` | nombre −10 |
| `i / a / o / O` | insérer (avant / après / ligne dessous / dessus) |
| `Esc` | retour au mode normal |
| `g c` | commenter / décommenter : gcc la ligne, gcj gck avec la voisine, gcap le paragraphe |
| `dd / yy / p` | supprimer / copier / coller la ligne |
| `cw / dw / yw` | opérateur + motion (aussi b, e, W, B, E, $, 0) |
| `x` | supprimer le caractère |
| `u` | annuler |

**Sélection**

| Touche | Action |
|---|---|
| `v` | sélection visuelle (caractères) |
| `V` | sélection visuelle (lignes) |

### Mode pane (Ctrl-w, reste actif)

**Panes & workspaces**

| Touche | Action |
|---|---|
| `Ctrl-w s` | split horizontal |
| `Ctrl-w v` | split vertical |
| `Ctrl-w c` | fermer la pane |
| `Ctrl-w z` | zoom / dézoom (la pane seule à l'écran) |
| `Ctrl-w < / Ctrl-w >` | moins / plus large (5 %) — ou glisser une bordure à la souris |
| `Ctrl-w - / Ctrl-w +` | moins / plus haut (5 %) |
| `Ctrl-w =` | des parts égales |
| `Ctrl-w r` | tourner la coupe (horizontal ⟷ vertical) |
| `Ctrl-w Esc / Ctrl-w Enter / Ctrl-w Ctrl-w` | quitter le mode pane |

**Naviguer**

| Touche | Action |
|---|---|
| `Ctrl-w h / Ctrl-w j / Ctrl-w k / Ctrl-w l / Ctrl-w ← / Ctrl-w ↓ / Ctrl-w ↑ / Ctrl-w →` | focus ← ↓ ↑ → (ou flèches) |

### Sélection visuelle (v / V)

**Sélection**

| Touche | Action |
|---|---|
| `j / k / ↓ / ↑` | étendre la sélection (lignes) |
| `h / l / ← / →` | étendre la sélection (caractères, en v) |
| `0 / $` | jusqu'au début / à la fin de la ligne (en v) |
| `Esc` | annuler |

**Éditer**

| Touche | Action |
|---|---|
| `d / y / c` | supprimer / copier / changer |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `m` | mute les slots sélectionnés |

**Évaluer**

| Touche | Action |
|---|---|
| `e` | évaluer les blocs sélectionnés |

### Mode insertion

**Éditer**

| Touche | Action |
|---|---|
| `Esc` | retour au mode normal |
| `Tab` | compléter (ghost, identifiants) · placeholder suivant |
| `S-Tab` | placeholder précédent |

### Texte (guide, tutoriel, explication)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | descendre |
| `k / ↑` | remonter |
| `PgDn / Ctrl-d` | descendre d'un écran |
| `PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |
| `Esc / q` | fermer |

### Aide

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | descendre |
| `k / ↑` | remonter |
| `PgDn / Ctrl-d` | descendre d'un écran |
| `PgUp / Ctrl-u` | remonter d'un écran |
| `g` | haut |
| `G` | bas |

**Aide**

| Touche | Action |
|---|---|
| `Tab` | toutes les sections ⟷ contexte |
| `? / Esc / q` | fermer l'aide |

### Sessions

**Fichiers**

| Touche | Action |
|---|---|
| `Enter` | ouvrir |
| `!` | ouvrir en laissant ce qui n'est pas sauvé |

**Naviguer**

| Touche | Action |
|---|---|
| `/` | chercher |
| `j / ↓` | suivant |
| `k / ↑` | précédent |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g` | premier |
| `G` | dernier |
| `Tab` | onglet suivant de la réserve |
| `S-Tab` | onglet précédent |
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Éditer**

| Touche | Action |
|---|---|
| `x` | supprimer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

### Palette (Ctrl-p)

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | ouvrir / insérer / lancer |
| `a-z` | filtrer en tapant |

**Naviguer**

| Touche | Action |
|---|---|
| `↓ / Ctrl-n` | suivant |
| `↑ / Ctrl-p` | précédent |
| `PgDn` | page suivante |
| `PgUp` | page précédente |
| `Esc` | fermer |
