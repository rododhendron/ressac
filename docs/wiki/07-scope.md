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
