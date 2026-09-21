# Touches

Page générée depuis le registre de bindings (`src/keymap.jl`, `src/app_keymap.jl` et les scopes des panes/modaux) par `scripts/gen_keys_wiki.jl` — ne pas éditer à la main. Dans l'app, `?` ouvre la même chose pour le contexte courant.

Notation : `Space d` = Space puis d · `Ctrl-w s` = Ctrl-w puis s · `g t` = g puis t. Les touches séparées par ` / ` sont des synonymes.

## Partout

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `!` | panic (coupe tout) |
| `,` | hush (laisse finir les queues) |

**Divers**

| Touche | Action |
|---|---|
| `Esc` | sur la dernière pane : quitter (deux fois) |
| `:` | commande |
| `/` | rechercher |

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
| `Ctrl-1 / Ctrl-2 / Ctrl-3 / Ctrl-4 / Ctrl-5 / Ctrl-6 / Ctrl-7 / Ctrl-8 / Ctrl-9` | workspace 1…9 |
| `Ctrl-f` | montrer/cacher les floats |
| `Ctrl-1 / :play · Ctrl-2 / :design · Ctrl-3 / :explore` | workspaces PLAY (patterns) · DESIGN (synth) · EXPLORE (GA) |

## Éditeur (patterns et synth)

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | basculer patterns ⟷ synth |
| `PgDn` | page suivante |
| `PgUp` | page précédente |
| `Ctrl-d` | demi-page suivante |
| `Ctrl-u` | demi-page précédente |
| `h / j / k / l` | déplacer le curseur (ou flèches) |
| `w / b / e` | mot suivant / précédent / fin de mot |
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
| `dd / yy / p` | supprimer / copier / coller la ligne |
| `cw / dw / yw` | opérateur + motion (aussi b, e, W, B, E, $, 0) |
| `x` | supprimer le caractère |
| `u` | annuler |

**Sélection**

| Touche | Action |
|---|---|
| `v` | sélection visuelle (caractères) |
| `V` | sélection visuelle (lignes) |

## Pane patterns

**Évaluer**

| Touche | Action |
|---|---|
| `e` | évaluer la ligne |
| `E` | tout évaluer |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `m` | mute / unmute le slot |
| `K` | écouter le mot sous le curseur |

**Éditer**

| Touche | Action |
|---|---|
| `Space` | snippet… |
| `>` | pattern : zoom ×2 |
| `<` | pattern : zoom ÷2 |
| `L` | pattern : décaler le token → |
| `H` | pattern : décaler le token ← |
| `X` | pattern : silence le token (~) |

**Naviguer**

| Touche | Action |
|---|---|
| `g s` | ouvrir le synth sous le curseur (DESIGN) |

## Space + …

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

**Aide**

| Touche | Action |
|---|---|
| `Space b` | ▸ sons (samples, instruments, synths) |
| `Space L` | ▸ librairie synths |
| `Space I` | ▸ snippets |
| `Space w` | ▸ wiki |
| `Space ?` | ▸ aide |

## Pane synth

**Jouer / écouter**

| Touche | Action |
|---|---|
| `t / T / Space` | tester le synth (maintenir = rafale) |

**Fichiers**

| Touche | Action |
|---|---|
| `U` | utiliser dans un pattern (sauve + @dN dans PLAY) |

**Naviguer**

| Touche | Action |
|---|---|
| `g t` | synth suivant |
| `g T` | synth précédent |

## Sélection visuelle (v / V)

**Sélection**

| Touche | Action |
|---|---|
| `j / k / h / l` | étendre la sélection |
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
| `e` | évaluer le bloc |

## Mode insertion

**Éditer**

| Touche | Action |
|---|---|
| `Esc` | retour au mode normal |
| `Tab` | compléter (ghost, identifiants) · placeholder suivant |
| `S-Tab` | placeholder précédent |

## Mode pane (Ctrl-w, reste actif)

**Panes & workspaces**

| Touche | Action |
|---|---|
| `Ctrl-w s` | split horizontal |
| `Ctrl-w v` | split vertical |
| `Ctrl-w c` | fermer la pane |
| `Ctrl-w z` | zoom / dézoom (la pane seule à l'écran) |
| `Ctrl-w Esc / Ctrl-w Enter / Ctrl-w Ctrl-w` | quitter le mode pane |

**Naviguer**

| Touche | Action |
|---|---|
| `Ctrl-w h / Ctrl-w j / Ctrl-w k / Ctrl-w l` | focus ← ↓ ↑ → (ou flèches) |

## Explorateur de synths (GA)

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space` | jouer le candidat |
| `t` | drone on/off |
| `m` | mini-clavier (z x c v…) |

**Structure**

| Touche | Action |
|---|---|
| `n` | génération suivante |
| `T` | tune (réglage fin) ⟷ brew (rebrassage) |
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

## Vue d'onde

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

## Sculpt (l'onde et ses knobs)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | knob suivant |
| `k / ↑` | knob précédent |
| `Tab` | nœud suivant |
| `S-Tab` | nœud précédent |

**Éditer**

| Touche | Action |
|---|---|
| `l / →` | tirer + |
| `h / ←` | tirer − |
| `=` | saisir une valeur |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space / Enter` | jouer |

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
| `U` | utiliser dans un pattern (sauve + @dN dans PLAY) |

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

## Journal

**Naviguer**

| Touche | Action |
|---|---|
| `k / ↑` | remonter |
| `j / ↓` | descendre |

## Documentation

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | descendre |
| `k / ↑` | remonter |

## Gamme (tuning)

**Vues**

| Touche | Action |
|---|---|
| `r` | étiquettes : cents ⟷ ratios |

## Tap (:tap / :bpm)

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space` | frapper |
| `Enter` | valider |
| `Esc` | annuler |

## Piano (:piano)

**Jouer / écouter**

| Touche | Action |
|---|---|
| `z x c v b n m ,` | notes (rangée du bas = naturelles) |
| `s d g h j` | dièses |
| `[ / ]` | octave − / + |
| `Enter` | valider l'enregistrement |
| `Esc` | quitter |

## Aide

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | défiler |
| `k / ↑` | remonter |
| `PgDn / Ctrl-d` | page suivante |
| `PgUp / Ctrl-u` | page précédente |
| `g / G` | début / fin |

**Aide**

| Touche | Action |
|---|---|
| `Tab` | toutes les sections ⟷ contexte |
| `? / Esc / q` | fermer l'aide |

## Texte (guide, tutoriel, explication)

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | défiler |
| `k / ↑` | remonter |
| `G` | fin |
| `g` | début |
| `Esc / q` | fermer |

## Sons (samples, instruments, synths)

**Éditer**

| Touche | Action |
|---|---|
| `Enter` | insérer dans le pattern |
| `Bksp` | effacer le filtre |
| `a-z` | filtrer en tapant |

**Jouer / écouter**

| Touche | Action |
|---|---|
| `K / Space` | écouter |

**Naviguer**

| Touche | Action |
|---|---|
| `Tab` | catégorie suivante |
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

## Librairie de synths

**Jouer / écouter**

| Touche | Action |
|---|---|
| `Space` | écouter |

**Fichiers**

| Touche | Action |
|---|---|
| `Enter` | ouvrir dans une pane synth |

**Naviguer**

| Touche | Action |
|---|---|
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

## Snippets

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
| `Tab / l / →` | catégorie suivante |
| `h / ←` | catégorie précédente |
| `Esc / q` | effacer la recherche → la catégorie → fermer |
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

## Wiki

**Naviguer**

| Touche | Action |
|---|---|
| `j / ↓` | défiler |
| `k / ↑` | remonter |
| `n / ] / →` | page suivante |
| `p / [ / ←` | page précédente |
| `d` | 10 lignes plus bas |
| `u` | 10 lignes plus haut |
| `g / G` | début / fin de page |
| `1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9` | aller à la page N |
| `Esc / q` | fermer |

## Mixer

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
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |

## sccode.org

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
| `j / k / ↓ / ↑` | naviguer |
| `Esc / q` | fermer |

**Éditer**

| Touche | Action |
|---|---|
| `/` | rechercher |

**Aide**

| Touche | Action |
|---|---|
| `?` | aide |
