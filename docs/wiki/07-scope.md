# Le scope

`S` fait tourner les types de scope ; `:scope <type>` en choisit un
directement. Off = pas de scope (gagne de la place).

## Types

```
amp           vu-mètre d'amplitude + lecture en dB
wave          oscilloscope déclenché (fenêtre de 32 ms)
spectrum      48 bandes espacées en log, barres verticales
xy            Lissajous : nuage L contre R + lignes
goni          goniomètre (XY tourné de 45° — mono = ligne verticale)
spectrogram   cascade des dernières trames FFT
peak          crête avec marqueur de tenue + drapeau de clip
pitch         suivi de fondamentale → Hz + nom de note
onset         flash à chaque transitoire
hist          histogramme des valeurs d'échantillon
corr          corrélation stéréo L-R : -1 phase, 0 stéréo, +1 mono
```

## Zoom de l'onde

Quand le scope est `:wave`, ces touches agissent sur lui (sauf si le
curseur est sur un nombre, où elles le nudgent) :

```
+ / -         zoom Y (échelle d'amplitude)
> / <         zoom X (largeur de la fenêtre)
=             remet les deux axes à 1
```

## Affichage déclenché

Le scope d'onde se déclenche sur les **passages par zéro montants** : une
note tenue reste en place au lieu de défiler. En silence, une impulsion
de repli à 4 Hz garde le panneau vivant.

## Le chemin des données

1. Le bus master de SC est écouté par un petit synth de scope (un par
   type) qui fait un `SendReply` par trame.
2. Des `OSCFunc` relaient les données vers l'écouteur UDP de Ressac sur
   le port 57121.
3. L'écouteur Julia écrit dans `_APP_SCOPE_DATA` (celui du spectrogramme
   pousse aussi dans un tampon circulaire).
4. Le rendu du type actif lit ces globals.

Ajouter un scope = un `SynthDef` SC, un relais `OSCFunc`, un rendu Julia.

## La doc vivante

La fiche, à droite des patterns, suit le curseur : elle montre la fiche de
ce qui est dessous, comme les live docs de Pluto. Une fonction donne sa
description et ses exemples ; un son donne ce qu'il est, ses variantes ou
ses paramètres, une ligne d'usage, et sa source si c'est un synth.

Sur une ligne `@dN`, la fiche commence par ce que fait le slot : son état
(joue, modifié, muet, à l'arrêt), ses coups par cycle, les notes exactes
qu'il joue ce cycle, et l'erreur en entier s'il y en a une.

Un nom de son passe avant une fiche de fonction : dans un buffer de
patterns, `bd` est un son. `f` fige la pane, `f` de nouveau la remet à
suivre. `K` et `:doc <nom>` visent la même pane.

## Voir les notes défiler

`:notes` ouvre un visualiseur à côté des patterns : le temps va de
gauche à droite, la hauteur monte, une couleur par slot. La barre
verticale est l'instant courant — à gauche ce qui vient d'être joué, à
droite ce qui va l'être. Éditer un slot se voit immédiatement, y compris
dans le futur proche, puisque la pane interroge les patterns au lieu de
garder un historique.

Les sons sans hauteur (percussions) ont leurs propres couloirs en bas,
un par nom, avec le nom écrit à droite. Les notes viennent de `note`,
`n` ou `freq`.

```
+ / −     élargir ou resserrer la fenêtre de temps
k / j     plus ou moins de couloirs de percussion
Ctrl-w z  zoomer la pane
```

## L'éditeur montre ce qui joue

Chaque ligne `@dN` dit ce qu'elle fait, sur la ligne elle-même.

**Le signe dans la marge.** Une note quand le slot joue ce qui est écrit —
et sa valeur suit la vitesse du pattern : une ronde pour un coup par cycle,
une noire pour quatre, une double croche pour seize. Un soupir pour un slot
muet (ligne commentée, ou coupé au mixer). Un dièse quand le texte a changé
depuis la dernière évaluation : ce que tu lis n'est plus ce que tu entends.
Une croix quand l'évaluation a échoué. Un point d'orgue pour un drone. Rien
du tout pour une ligne qui n'a pas été lancée.

**Le fond de la ligne** s'allume au coup et retombe. `:calme` le fige.

**Le jeton en cours** est surligné dans la mini-notation.

**La piste, au bout de la ligne**, montre un cycle de ce que le slot joue
vraiment, pas ce qui est écrit — utile quand les notes viennent d'une
fonction. Un bloc par coup ; quand le pattern a des hauteurs, la taille du
bloc dit la hauteur (grave en bas). Une colonne plus claire traverse toutes
les pistes : c'est l'instant présent.

```
𝅘𝅥 @d1 p"bd bd bd bd"          █···········█···········█···········█···········
𝅘𝅥𝅮 @d2 :pad |> n("0 3 7 12")   ▁···········▃···········▅···········█···········
♯ @d3 p"hh*8" |> gain(0.6)    █·····█·····█·····█·····█·····█·····█·····█·····
```

La piste se raccourcit puis disparaît quand la ligne est longue ; `:pistes`
les cache toutes.

**Une erreur** s'écrit au bout de la ligne fautive, avec ce qui continue :
« l'ancien joue toujours » ou « rien ne jouait ». Elle disparaît dès que tu
touches à la ligne.

Les signes sont ceux du solfège si une police installée les a (Noto Music
par exemple), sinon ceux d'un lecteur (`▶ ‖ ✎`). `ui.marks` dans
`ressac.toml` force une famille : `solfege`, `transport` ou `formes`.
