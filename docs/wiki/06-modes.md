# Modes de saisie live

Des modes qui prennent le clavier tant qu'ils sont actifs. Tous se
quittent avec `Esc` et s'affichent dans la status line ; la barre de
touches montre leurs touches.

## Tap loop — `:tap [sample]`

Le mode par défaut : tape un rythme, Ressac détecte la période de la
boucle, règle `cps`, écrit la ligne `@dN "…"` et l'évalue.

```
:tap                → sample = bd
:tap kick           → sample = kick
```

`Espace` sur chaque temps. **Tape le rythme au moins 2 fois** pour que
le détecteur confirme la période (plus de répétitions = plus de
confiance dans le journal). `Entrée` valide :

1. La détection de période choisit la durée de la mesure (avec un biais
   vers le `cps` courant : taper en place sur un beat existant se cale
   proprement).
2. L'inférence de pas choisit la plus petite grille musicale (3, 4, 6, 8,
   12, 16, 24, 32) où chaque coup tombe sur un pas entier.
3. Sortie : `cps!(<déduit>)` + `@d<libre> "…"`, évalués tout de suite.
4. Score de confiance dans le journal : `high`, `ok`, ou `low — try more
   reps`.

Sans boucle claire (confiance trop basse, une seule répétition), la
commande retombe sur une quantification à une mesure : du premier coup au
dernier + un intervalle moyen, coups placés sur 16 pas.

Status line : `● TAP-LOOP <n> hits` pendant l'enregistrement.

## Tap-strict — `:tap-strict [sample]`

Quantification à une mesure, sans détection de boucle. Quand tu tapes un
rythme une fois et que tu veux exactement ce que tu as joué.

## Tap-tempo — `:bpm` (alias `:tap-tempo`)

Tape 2+ temps avec `Espace`, `Entrée` règle le cps. Convention 4 taps =
1 mesure (60 BPM = `cps!(0.25)`).

## Mode piano — `:piano [synth]`

Les lettres deviennent des demi-tons chromatiques ; chaque appui joue le
synth nommé à cette hauteur.

```
Rangée du bas (naturelles) :  z(w) x  c  v  b  n  m(,)  ;
                               C   D  E  F  G  A   B   C
Rangée du milieu (dièses) :      s  d     g  h  j
                                C#  D#    F# G# A#
```

`[` et `]` changent d'octave (0..9, 4 par défaut = région de A4). `Esc`
quitte.

## Piano-record — `:piano-rec [synth]`

Comme le mode piano, mais chaque appui est mémorisé avec son instant.
`Entrée` valide : les notes sont quantifiées sur 16 pas, la sortie est
`@d<libre> :synth |> n("0 4 7 0 4 7 ...")` sous le curseur.

Status line : `● PIANO REC oct=4 [n]`.

## Espace-leader (transitoire)

`Espace` en mode normal arme un déclencheur unique ; le popup which-key
liste les suites possibles :

- lettre suivante = `d` → insère `@d$1 "$2"` avec le curseur sur `$1`
- `b` / `L` / `I` / `w` / `?` → ouvre sons / librairie / snippets /
  wiki / aide
- une lettre de la table des snippets → insère le modèle
- autre chose → annule silencieusement

Une fois un snippet inséré avec des trous, tu es en « mode placeholder » :
Tab suivant, Maj-Tab précédent, Esc sortir.

Voir [04-keys](04-keys.md) pour la table complète.

## Mixer — `:mixer` (alias `:mix`)

Un modal avec tous les slots actifs + mutes, leur vu-mètre, leur état,
leur gain et leur source. Par slot :

- `j` / `k` — naviguer
- `m`       — mute / démute
- `s`       — solo
- `u`       — tout démuter
- `+` / `-` — gain ±0.1 (modifie le buffer + ré-évalue)
- `*` / `/` — gain ±0.5
- `!` / `.` — panic
- `q` / Esc — fermer

## Pause — `:pause`

Fige le rendu pour sélectionner du texte à la souris (shift-glisser)
et le copier. Une touche reprend.

## Keydebug — `:keydebug`

Bascule. Tant que c'est ON, chaque événement clavier est journalisé :
`[KEY] <symbole> char='X' action=<press|repeat|release>`. Utile pour
diagnostiquer une disposition de clavier.

## Aller à un caractère

`f<c>` place le curseur sur la prochaine occurrence de `c` sur la ligne,
`t<c>` juste avant, `F<c>` et `T<c>` font la même chose vers la gauche.
`;` refait la recherche, `,` la refait à l'envers.

`r<c>` remplace le caractère sous le curseur. Tous les caractères sont
acceptés, y compris ceux qui déclenchent autre chose seuls : `r!` écrit
un point d'exclamation au lieu de couper le son, `r` suivi d'une espace
écrit une espace au lieu d'ouvrir le menu.
