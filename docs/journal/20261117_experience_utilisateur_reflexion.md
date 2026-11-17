# Repenser l'expérience de Ressac — réflexion

Date : 2026-11-17. État de départ : branche `audit-2026-11` (audit clos, suite verte).

Ce document n'est pas un plan. Il part de **ce qu'on reproche aux logiciels
existants**, le confronte à **ce que Ressac montre aujourd'hui** et à **ce
que le projet veut être**, et en tire des principes, une cible esquissée et
des décisions à prendre. Le plan viendra après ces décisions.

Sources de la partie 1 : 39 pages lues (forums Tidal, Sonic Pi, TOPLAP,
Renoise, Elektronauts ; fils Hacker News ; Sound on Sound ; pages de
Roberts, McLean, Magnusson). Les citations ont été extraites par un outil de
lecture, pas relues dans le texte : **à revérifier avant de les republier
mot pour mot**. Non couverts : le forum lines, Reddit, le texte intégral des
articles ICLC/NIME (résumés seulement). Rien de sérieux n'a été trouvé sur
FoxDot, Sardine, ChucK, Hydra, VCV Rack ou Bitwig.

---

## 1. Ce qu'on reproche aux outils existants

### 1.1 La chaîne casse en silence
Installer Tidal demande « un diplôme d'informatique » selon le titre d'un
fil de son propre forum : langage, éditeur, serveur audio, échantillons,
chaque maillon peut échouer avec un message qui ne nomme pas la vraie cause
(un Quark introuvable parce que Git manque). En concert, même défaut : Tidal
« hushes everything and then won't play anything until I reboot », sans
message, « at song climaxes ». À l'inverse, ixi lang revendique cinq
secondes avant le premier son, Glicol et Strudel zéro installation.
[uzu.lurk.org/t/3936](https://uzu.lurk.org/t/tidal-cycles-is-usable-even-by-non-coders-ok-so-why-do-i-need-a-cs-degree-to-install-it/3936) ·
[uzu.lurk.org/t/3561](https://uzu.lurk.org/t/unknown-tidal-error-during-live-performances-help/3561)

### 1.2 L'erreur musicale est acceptée, la panne ne l'est pas
La culture du live coding valorise l'erreur (« embracing error », Heavy
Lifting). Ce qui est reproché, c'est l'erreur qui coupe le son ou qui ne dit
rien. Glicol en fait un argument : « error reported in console, but previous
music will continue! ». SuperCollider admet que ses messages sont « very
ugly » et trop longs.
[Glicol](https://github.com/chaosprint/glicol/blob/main/README.md) ·
[SC, directions du projet](https://capital-g.github.io/supercollider-wiki/development/project-structure/Project-directions.html)

### 1.3 On ne sait pas ce qui joue
C'est la critique la plus constante. Tidal : la liste des patterns affiche
encore ceux qu'on a coupés ; on demande une vue d'état « façon top ». Sonic
Pi : « Why did the hihat loop just stop right now? ». McLean lui-même dit
que le code paraît « dead » sans surlignage une fois qu'on a goûté à
Strudel. Ce qui est loué chez Strudel : le surlignage **décore le code
existant** sans déplacer le texte. Réserve : certains le trouvent gênant, et
un commentaire signale le risque pour les personnes épileptiques.
[forum.toplap.org/t/423](https://forum.toplap.org/t/tidal-ui-ongoing-ideas-thread/423) ·
[uzu.lurk.org/t/5745](https://uzu.lurk.org/t/visual-feedback/5745)

### 1.4 Le vocabulaire déborde la mémoire
En concert, un joueur de Sonic Pi dit oublier « the simplest things » ;
taper de longs patterns est lent, répétitif et source d'erreurs. Sur
Strudel : « I lack vocabulary to describe what I want ». Les trackers et le
M8 montrent l'autre voie : un vocabulaire fermé, appris par les doigts
(« once the muscle memory kicks in, it's a surprisingly fast workflow »).
[in-thread 933](https://in-thread.sonic-pi.net/t/notes-and-ideas-about-the-challenge-of-live-coding/933) ·
[SOS, M8](https://www.soundonsound.com/reviews/dirtywave-m8-model02)

### 1.5 La page blanche est un mythe
Roberts tape tout mais n'improvise presque rien ; d'autres rappellent des
snippets comme des « jazz licks ». La pratique réelle repose sur des
fragments préparés retrouvés vite.
[forum.toplap.org/t/105](https://forum.toplap.org/t/what-aspects-of-your-live-coding-sets-do-you-prepare-in-advance-vs-code-on-the-fly/105)

### 1.6 Le pattern et le son vivent dans deux mondes
Tidal décrit des patterns, pas des sons ; Sonic Pi n'est « not really
intended for synth design ». On change d'outil, de langage et d'écran pour
façonner un timbre. Autre manque : passer de la boucle au morceau (Strudel,
grooveboxes — « patterns scattered all over the place »).

### 1.7 La session ne se souvient pas
Retrouver le code réellement joué dans Tidal : « That's not possible at the
moment ». Un musicien reclone son dossier avant chaque date pour ne pas
hériter de l'état de la veille.
[uzu.lurk.org/t/584](https://uzu.lurk.org/t/state-of-a-tidal-session/584)

### 1.8 L'accessibilité est un angle mort
Sonic Pi : impossible de donner le focus aux panneaux au clavier, pas de nom
du panneau actif ; les combinaisons Ctrl/Alt excluent des joueurs. La
recherche (ICLC 2023) constate qu'on sait peu de choses sur les lecteurs
d'écran et le live coding.

### Cadres qui aident à en parler
- **Dimensions cognitives** (Green & Petre) : viscosité, visibilité,
  dépendances cachées, évaluation progressive, engagement prématuré.
- **Niveaux de liveness** (Tanimoto) : du retour à la demande (2) au retour
  sur ce que le programme est en train de faire (4).
- **Contrainte = affordance** (Magnusson) : restreindre l'espace réduit la
  charge en temps réel.
- **Concision contre erreur** (McLean) : un langage plus bref est plus
  facile à changer et plus facile à casser. « There is no ideal language ».

---

## 2. Ce que Ressac montre aujourd'hui

Constat fait sur les 19 captures de `scripts/tui_shot.jl` (140×40).

| Critique | Où en est Ressac |
|---|---|
| 1.1 chaîne | Scripts d'installation par OS, deux terminaux (`just audio`, `just live`). L'écran ne montre pas si SuperCollider répond. |
| 1.2 erreur | **Acquis depuis l'audit** : un pattern qui lève est retiré seul, le reste joue. L'erreur arrive dans le journal, loin de la ligne fautive. |
| 1.3 ce qui joue | Tête de lecture dans les `"…"`, bandeau des slots, mixer. Mais l'écran de départ ne montre rien de tout ça : un tiers de la largeur est le wiki. |
| 1.4 vocabulaire | 400 noms exportés, 148 commandes, 883 lignes de touches. Palette `Ctrl-p`, complétion, which-key, doc vivante. L'aide `?` est rangée par pane et par couche, pas par intention. |
| 1.5 fragments | Snippets (leader), starters, patterns rangés, variations : quatre mécanismes, quatre entrées. |
| 1.6 pattern → son | **La singularité de Ressac** : DSL de synth, studio, sculpt, explorateur, ponts `gs` / `U`. Mais ce sont trois workspaces, donc trois écrans. |
| 1.7 session | `:save` / `:load`, disposition restaurée. Pas de trace de ce qui a été joué. |
| 1.8 accessibilité | Tout au clavier, pane focalisée nommée dans la status line. Pas de mode sans animation, touches non reconfigurables. |

Défauts propres aux écrans :

- **PLAY** : la première ligne dit « Esc puis E » alors que l'app démarre en
  mode normal. Le même conseil est écrit trois fois (commentaire, barre de
  touches, journal). Le journal prend cinq lignes pour un message d'accueil.
  La pane DOC est vide.
- **DESIGN** : le studio ouvre sur « rendu en cours / indisponible », la DOC
  sur une consigne. Deux panes sur trois ne montrent rien à l'arrivée.
- **EXPLORE** : neuf cartes dont sept identiques (`RLPF ← Saw`) ; un titre
  en jargon (`BREW · bayésien (Tab) · fam(u) · én 5.1↓8∿`).
- **Status line** : `◐ ░░░░░░░░░░░░` et `✧ 0` ne sont légendés nulle part
  sur l'écran.

---

## 3. Ce que Ressac veut être

Lecture tirée du plan d'origine, du README et du wiki — **à valider, c'est
mon interprétation** :

1. **Du texte et du son, rien d'autre.** Un terminal, un clavier ; pas de
   navigateur, pas de greffon d'éditeur, pas de souris obligatoire.
2. **Le motif et le timbre dans la même main.** On écrit le pattern et le
   synth dans le même langage, au même endroit.
3. **La machine propose.** Chaos, réservoir, explorateur génétique,
   variations : le joueur n'est pas seul devant la page, il choisit parmi
   ce qui lui est offert.
4. **Tout est du Julia.** Pas de sous-langage fermé : listes, fonctions,
   variables, plugins.
5. **Le son ne s'arrête pas par accident.** (Posé par l'audit.)

Le point 3 est ce qu'aucun des outils critiqués n'a. Le point 4 est en
tension directe avec la leçon du M8 et d'ixi lang (1.4) : un vocabulaire
ouvert ne s'apprend pas par les doigts.

---

## 4. Principes proposés

**P1 — L'écran montre la musique, pas le manuel.** Par défaut, tout ce qui
n'est pas le texte dit ce qui joue. La documentation vient quand on la
demande, et repart.

**P2 — Le texte est l'affichage.** L'état se lit sur la ligne elle-même, à
la manière de Strudel : joue, muet, en erreur, *modifié mais pas encore
évalué*. Ce dernier état manque partout ailleurs et répond à 1.7 : ce que tu
lis n'est pas forcément ce que tu entends.

**P3 — L'erreur se montre là où elle est, et dit ce qui continue.** Sous la
ligne fautive : la cause en une phrase, et « l'ancien `@d2` joue toujours ».
Le journal garde l'historique, il n'est plus le lieu du diagnostic.

**P4 — Une intention, un geste, un seul endroit où le trouver.** L'aide et
la palette parlent en intentions (« épaissir », « décaler », « faire de la
place »), pas en panes. Un petit noyau de gestes appris par les doigts ; le
reste derrière la palette.

**P5 — Les fragments sont des licks.** Snippets, starters, patterns rangés
et variations deviennent une seule réserve, rappelée d'un geste, écoutable
avant d'être posée.

**P6 — On ne change pas de monde pour changer de son.** Aller du pattern au
timbre et revenir sans perdre le texte des yeux.

**P7 — La chaîne est visible.** La status line dit en clair si
SuperCollider répond, si SuperDirt est chargé, si le dernier envoi est
parti. Quand un maillon manque, l'écran dit lequel et quoi taper.

**P8 — La profondeur se dévoile.** Chaque écran a une forme simple par
défaut ; le jargon (stratégies bayésiennes, énergie, clusters) est à un
geste, pas dans le titre.

**P9 — Calme par défaut.** Pas de clignotement, animations coupables d'une
commande, rien d'essentiel porté par la couleur seule.

---

## 5. Cible esquissée

### PLAY

```
 RESSAC  ● SC  120 bpm  cycle 12 ▮▮▮▯              NORMAL          PLAY  design  explore
╭─ PATTERNS ────────────────────────────────────────────╮╭─ CE QUI JOUE ───────────────╮
│▶ @d1 p"bd bd bd bd"                                   ││ d1 ▮▮▮▮▮▯▯  bd      kick    │
│▶ @d2 p"~ ~ cp ~"                                      ││ d2 ▮▮▯▯▯▯▯  cp              │
│✎ @d3 p"hh*8" |> gain(0.4)        ← pas encore évalué  ││ d3 ▮▮▮▯▯▯▯  hh  (ancien)    │
│✗ @d4 p"sketch*4" |> lpf("<400")                       ││ d4 ·        —               │
│    └ lpf : alternance non fermée · rien ne jouait     ││─────────────────────────────│
│                                                       ││ fiche : lpf(coupure)        │
│                                                       ││ filtre passe-bas…           │
╰───────────────────────────────────────────────────────╯╰─────────────────────────────╯
 e évaluer · m muet · Espace réserve · Ctrl-p tout                                ? aide
 ▎ d3 évalué il y a 2 cycles
```

- La colonne de droite est l'état des slots, avec la fiche du mot sous le
  curseur en dessous. Le wiki s'ouvre à la demande, par-dessus.
- La marge porte l'état de chaque ligne (P2). L'erreur est sous la ligne (P3).
- Le journal tient sur une ligne et se déplie.

### DESIGN, EXPLORE

Deux options, c'est la décision B plus bas : les garder comme écrans, ou
en faire des **volets** qui remplacent la colonne de droite pendant que le
texte des patterns reste visible et continue de jouer (P6).

Dans les deux cas : le studio n'affiche jamais « indisponible » (au pire la
dernière onde connue, grisée) ; l'explorateur ouvre sur des candidats
réellement différents et un titre réduit à « génération 0 · 9 sons ».

### Aide

`?` ouvre une page d'intentions pour le contexte courant, sur un écran,
sans défilement. `Tab` y donne la liste complète actuelle.

---

## 6. Décisions à prendre avant tout plan

**A. Pour qui ?** Toi en concert, quelqu'un qui vient de Tidal, ou
quelqu'un qui n'a jamais live-codé. Les trois ne veulent pas le même écran
de départ, et P4 (noyau fermé) pèse différemment.

**B. Trois écrans ou un seul ?** Garder PLAY / DESIGN / EXPLORE comme
workspaces, ou un écran unique dont la colonne de droite change. Le second
sert P6, mais le studio et l'explorateur perdent de la place.

**C. Le wiki quitte-t-il l'écran de départ ?** P1 dit oui. C'est un
changement visible dès la première seconde.

**D. Démarrer en jouant ?** Le buffer de départ est prêt ; il pourrait
jouer dès l'ouverture (cinq secondes avant le premier son), ou attendre `E`.

**E. Vim obligatoire ?** Le modal est une barrière d'entrée et une force
pour qui le connaît. Le garder comme seul mode, ou offrir une saisie
directe sans modes.

**F. Jusqu'où fermer le vocabulaire ?** « Tout est du Julia » contre « un
vocabulaire appris par les doigts ». Un noyau d'une trentaine de mots mis
en avant, le reste accessible mais en retrait ?

---

## 7. Décisions prises (2026-11-17)

- **A — Pour qui.** Rodolphe, chez lui, qui bricole en live. Usage
  exploratoire : il va souvent vers ce qu'il ne connaît pas encore. Ses
  fichiers le confirment à leur échelle : 45 synths sauvés contre 10
  sessions de 35 lignes en tout, 9 noms exportés utilisés sur 400.
- **B — Un seul écran.** Les patterns à gauche, toujours ; à droite un volet
  qui change (état + fiche, synth, wiki) ; l'explorateur par-dessus, ouvert
  *sur le slot sous le curseur*. On s'éloigne de la refonte de septembre,
  c'est assumé. Le studio est à réagencer **et à alléger**.
- **C — Le wiki** s'ouvre à côté du travail et se ferme d'un geste ; la
  fiche du mot sous le curseur accompagne en permanence.
- **D — Démarrage.** Jamais de son non demandé. On retrouve son dernier
  texte, en silence. Sauver, charger une autre session, repartir d'une
  session vierge : trois gestes courts.
- **E — Vim partout.** Peu de commandes suffisent à retrouver un éditeur ;
  les verbes de Ressac s'alignent dessus (`:w`, `:e`, `:enew`).
- **F — Vocabulaire.** Un noyau de départ, réordonné par l'usage réel
  (compté à l'évaluation), épinglable à la main ; et une invitation
  discrète vers ce qui n'a pas encore été essayé.
- **Nouveau — hors grille.** Lancer un slot à l'instant de la frappe, et
  une boucle enregistrée qui rejoue à sa fermeture. Voir les maquettes.
- **Nouveau — bibliothèque.** Sons, motifs (un slot entier compris) et
  sessions dans une seule réserve.

Maquettes : `20261117_maquettes.md`.

## 8. Décisions prises (2026-11-17, suite)

- **Langue** : on laisse comme c'est (interface, journal, wiki et erreurs en
  français ; fiches et doc de dépôt en anglais).
- **Écran** : direction D — le code comme affichage principal, la piste
  d'un cycle au bout de chaque ligne. À surveiller : la charge visuelle.
- **Marques** : solfège, sur ligne éclairée. La valeur de la note suit la
  densité du pattern (ronde → triple croche) ; le silence de même pour un
  slot muet ; `♯` modifié, `𝄐` tenu, `𝆔` (petite note barrée) hors grille.
  Repli sur une autre famille si la police ne les a pas.
- **Atelier** : vim d'abord. `+ - * /` et la molette pour les nombres,
  l'objet texte `m` (maillon), `o` / `O` pour insérer, `gcc` pour commenter
  un maillon (= le court-circuiter), `&` pour le reste. Plus de pane de
  knobs. Faire bouger un nombre écrit une ligne nommée au-dessus, pas une
  expression imbriquée.
- **Zéro SuperCollider brut** : tout son est en DSL. Les 18 `.scd` de
  `plugins/user-synths` passent tous le parseur strict (2026-11-17) ;
  l'égalité du son reste à vérifier par le test de corpus.
- **Nombres** : trois décimales, notation scientifique quand il le faut
  (`408.1107981565365` → `408.111`, `0.00507499` → `5.075e-3`).
- **Casque** : il reçoit la même chose que la sortie principale, sauf le son
  en cours d'atelier, qu'il entend dans sa nouvelle version. Un réglage dans
  l'app découvre les sorties PipeWire, avec rafraîchissement. Pas urgent.
- **Touche « maintenant »** : `Entrée`. Délai de 50 ms laissé tel quel pour
  l'instant.
