# Sous-projet — Ciblage par usage & descripteurs acoustiques (analyse NRT)

**Date :** 2026-06-03
**Statut :** design en revue
**Dépend de :** explorateur GA (20260602) + fondation énergie/diversité chaotique (commits cc4d2a1, b6ddd33)

## But

Pouvoir orienter l'exploration vers un **usage sonore** — une basse, un kick, une
harmonique, une nappe, une voix haute — en jugeant les candidats sur leur **son réel**
(descripteurs acoustiques), pas sur leur structure. Et, parce que l'évaluation devient
automatique et silencieuse, **générer beaucoup** de candidats par tour et n'**afficher
que les meilleurs** (top-k).

Principe : on travaille « au niveau de l'onde » comme un sound designer — on mesure le
timbre rendu, on s'en sert comme signal de sélection, sans jamais jouer le son.

## Décisions de cadrage

| Sujet | Décision | Raison |
|---|---|---|
| Moteur d'analyse | **NRT via `sclang` + `Score.recordNRT`, headless** (`QT_QPA_PLATFORM=minimal`). sclang compile les synthdefs et orchestre le rendu hors-ligne, plus vite que le temps réel, vers un wav ; **aucune sortie audio**. | Découple l'évaluation de la lecture ET du temps réel → des centaines de candidats par tour. **sclang = autodiscovery feature-complete** (FFT/Env/n'importe quel plugin compilés sans hardcoding). `minimal` = headless prouvé sans rebuild SC ni Qt à l'écran. |
| Source des descripteurs | Le **son rendu** (FFT/enveloppe/pitch en SC), pas une heuristique structurelle. **Jeu complet** (FFT platitude + attaque/enveloppe inclus) — sclang compile tout, pas de compromis. | C'est le sens de « bosser au niveau de l'onde ». |
| Modes | **B exploration (défaut) → A rôle préréglé → C affinage supervisé** ; on dérive de B vers A puis C à la volée. | L'envie se précise en explorant ; la supervision n'est jamais imposée. |
| Ciblage | **Re-pondération douce** : `score = note + λ·role_fit`, biaise la sélection sans rien écraser. | Compose avec bayésien (goût) × énergie × chaos ; préserve la diversité. |
| Boucle | **Grand pool évalué en NRT → classement → top-k affichés.** | L'évaluation silencieuse rend le coût de génération négligeable ; on illumine large. |
| Testabilité | Logique (store, rôles, ciblage, top-k) testée **hors-ligne avec vecteurs injectés** ; le rendu NRT réel est de l'intégration (gardée derrière SC dispo). | Même contrat que `_GA_SLOT_LEVEL` aujourd'hui. |

## Descripteurs (vecteur normalisé ~6 dims)

Mesurés en SC, moyennés sur la fenêtre d'analyse de chaque candidat, normalisés dans
`[0,1]` :

1. **centroïde spectral** — brillance (`SpecCentroid` via `FFT`).
2. **ratio d'énergie graves** — énergie <200 Hz / totale → basse-ité.
3. **platitude spectrale** — tonal (0) ↔ bruité (1) (`SpecFlatness`).
4. **vivacité d'attaque** — montée d'enveloppe (transitoire) → kick-ité.
5. **forme d'enveloppe** — percussif (decay court) ↔ tenu (sustain).
6. **stabilité de hauteur** — confiance/constance du `Pitch` → tonal défini vs diffus.

(Set ajustable ; les valeurs exactes des seuils se calent à l'implémentation.)

## Architecture & découpage en modules

Couches indépendantes, chacune testable seule :

1. **`render_analysis_synthdef(g)`** — variante de rendu : même chaîne de signal, mais
   la sortie n'est **pas** `Out.ar(0)` ; le signal alimente les UGens d'analyse, dont
   les résultats sont écrits sur des canaux de sortie dédiés (descripteurs comme
   signaux). Aucun son aux haut-parleurs.

2. **Moteur NRT** (`nrt_analysis.jl`) — pour un lot de génomes :
   - génère un **script sclang** : un `Score` qui `/d_recv` les analysis-synthdefs
     (compilés par sclang → feature-complete) puis `/s_new` chaque candidat sur une
     **fenêtre temporelle** `[i·dt, i·dt+win]`, descripteurs sur des canaux fixes ;
   - lance `sclang` **headless** (`QT_QPA_PLATFORM=minimal`) qui appelle
     `Score.recordNRT` → rendu offline > temps réel, **aucune sortie audio** ;
   - relit le wav (float, multicanal), **segmente par fenêtre**, moyenne → un vecteur
     descripteur par candidat. Renvoie `Vector{Vector{Float64}}` aligné sur le lot.
   - *Headless prouvé* : `minimal` évite le crash GLX de Qt sans rebuild SC ; un
     synthdef FFT+LocalBuf+Amplitude rend correctement hors-ligne dans le sandbox.

3. **Store + modèle de rôle** (`synth_roles.jl`) —
   - **templates de rôles** (points cibles dans l'espace descripteur) : basse, kick,
     lead/harmonique, nappe, voix-haute ;
   - **clustering** non-supervisé (mode B) de l'espace descripteur mesuré
     (réutilise `cluster_population` adapté aux vecteurs acoustiques) ;
   - **affinage supervisé** (mode C) : tags `+/−` déplacent la cible du rôle vers les
     descripteurs des exemples (même forme que le surrogate de goût bayésien, mais sur
     l'acoustique).

4. **Ciblage** (intégration `ga_engine`) — `role_fit(descr) = 1 − dist(descr, cible)` ;
   ajouté en terme de score de sélection `score = note + λ·role_fit`. Couche au-dessus
   des stratégies existantes (modifie le poids effectif des parents), pas une stratégie
   à part → compose avec tout.

5. **Boucle grand-pool / top-k** (`ga_engine` + pane) — un tour : générer N candidats
   (N ≫ gen_size), NRT-évaluer, classer (role_fit en A, représentants de clusters en B),
   exposer les **k meilleurs** dans la grille. Les autres restent dans l'archive.

6. **UI** (pane) — choisir/cycler le rôle, basculer mode B/A/C, montrer le **role-fit**
   de chaque carte (barre/pastille), touche tag-pour-affiner (mode C), réglage `λ` et `N`
   dans le panneau `g`.

## Flot de données (un tour)

```
génère N génomes (depuis archive/favoris + énergie + chaos)
        │
        ▼
render_analysis_synthdef ×N  ──►  Score sclang  ──►  recordNRT headless (minimal, > temps réel)
        │
        ▼
wav multicanal (descripteurs)  ──►  segmentation par fenêtre  ──►  N vecteurs descripteurs
        │
        ▼
mode B : cluster → représentants     mode A : role_fit = proximité au template
mode C : template affiné par tags
        │
        ▼
score = note + λ·role_fit  ──►  classer  ──►  top-k affichés ; reste en archive
```

## Modes (détail)

- **B — exploration (défaut)** : pas de cible. On cluste les descripteurs du pool, on
  présente un représentant par cluster (familles timbrales émergentes). Tu navigues sans
  rien nommer.
- **A — rôle préréglé** : tu choisis un rôle ; cible = template ; `role_fit` tire la
  sélection. Zéro tag.
- **C — affinage supervisé (opt-in)** : tu tagges des candidats comme bons/mauvais
  exemples du rôle ; la cible glisse vers tes exemples.

Transitions libres : B (explore) → A (une envie se précise) → C (tu affines le rôle).

## Testabilité & risques

- **Hors-ligne** : store, role_fit, clustering, top-k, affinage — testés avec des
  vecteurs descripteurs injectés (déterministe, pas de SC).
- **Intégration NRT** : un test gardé (skip si `sclang` indispo) qui rend 2-3 génomes
  connus headless (`QT_QPA_PLATFORM=minimal`) et vérifie que les descripteurs sont
  plausibles (un sinus grave → centroïde bas, graves haut ; un bruit → platitude haute).
- **Risque** : extraction descripteur depuis le wav (segmentation, normalisation,
  transitoire d'attaque). Calé à l'implémentation, isolé dans `nrt_analysis.jl`.
- **Risque** : coût NRT par tour. Atténué par faster-than-realtime + fenêtres courtes ;
  N réglable.

## Ordre de livraison (incréments testables)

1. `render_analysis_synthdef` + descripteurs SC (rendu de la sonde, pas encore NRT).
2. Moteur NRT : Score sclang → `recordNRT` headless → relecture wav → vecteurs (test gardé).
3. Store + `role_fit` + templates de rôles (tests hors-ligne).
4. Ciblage par re-pondération douce dans la sélection (compose avec l'existant).
5. Boucle grand-pool → top-k.
6. Clustering mode B + affinage mode C.
7. UI : rôles, modes, role-fit par carte, réglages.

Chaque incrément laisse l'explorateur fonctionnel ; le ciblage est inerte tant qu'aucun
rôle n'est actif (défaut = comportement actuel).
