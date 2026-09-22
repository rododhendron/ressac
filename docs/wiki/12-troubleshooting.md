# Dépannage

Quand quelque chose ne va pas, parcours ceci de haut en bas.

## « Je n'entends rien »

1. **SuperCollider tourne ?** Vérifie que `sclang` tourne avec SuperDirt
   chargé. Test rapide :
   ```
   julia> using Ressac; live()
   ```
   …puis dans Ressac, `E` évalue le buffer de démarrage. Si le journal
   dit `[INFO] :e — 3 blocs évalués` et que tu n'entends rien, étape 2.

2. **SC écoute le bon port ?** Ressac envoie l'OSC sur UDP 57120. Dans le
   log de SC, des lignes `("[ressac] " ++ msg).postln` doivent apparaître
   quand tu évalues. Sinon, ton SC est sur un autre port : édite
   `superdirt-startup.scd` pour 57120.

3. **SuperDirt est vraiment instancié ?** Dans SC :
   ```supercollider
   ~dirt.notNil  // doit renvoyer true
   ```
   Sinon, lance le script de démarrage : `scripts/superdirt-startup.scd`.

4. **Le limiteur master l'a tué ?** `:safety on` engage LeakDC + HPF
   10 Hz + limiteur à 0.95. `:safety off` retire la chaîne. Si tes
   patterns additionnent beaucoup d'amplitude, le limiteur les étouffe.
   Essaie `gain(0.5)`.

5. **`:hush` a laissé des voix en release ?** Un synth à long release
   peut mettre quelques secondes à mourir après `:hush`. Attends, ou `!`
   (panic) libère tous les nœuds SC tout de suite.

## « J'ai un `[ERROR] éval d1 : …` »

Les cas les plus fréquents :

| Erreur                                          | Cause                                                                  | Remède                                                               |
|-------------------------------------------------|------------------------------------------------------------------------|----------------------------------------------------------------------|
| `unknown name `foo``                            | faute de frappe, ou sample/synth non enregistré                        | `:browse` pour les noms enregistrés · `:lib` pour les synths         |
| `a Symbol slipped into a Pattern slot`          | tu as écrit `:bd \|> n("0 3")` — un Symbol n'accepte pas de Pattern    | `pure(:bd)` ou la mini-notation : `"bd" \|> n("0 3")`               |
| `parse error — check matching brackets`         | `(`, `[`, `<`, `"` déséquilibrés                                       | relis la ligne, compte les ouvrants et les fermants                  |
| `bad arg: invalid base 10 digit`                | un nombre là où on attendait un nom, ou l'inverse                      | vérifie ce que le helper attend : `:doc gain`, etc.                  |
| `out-of-range index`                            | `degree()` ou `n()` a reçu un pattern plus long que prévu              | vérifie que les indices tiennent dans la source                      |

La stacktrace brute reste visible sur le stderr de Ressac — mais le
journal donne l'essentiel.

## « Mon pattern ne joue pas, sans erreur »

1. **Le slot est mute.** Regarde le préfixe `# @d1`, ou `:mixer` (colonne
   État : MUTED).

2. **Le slot a été écrasé.** Avec deux lignes `@d1` dans le buffer, la
   DERNIÈRE non mutée gagne au prochain `E`.

3. **Le tempo est trop lent / trop rapide.** `cps!(0.001)` fait durer le
   cycle 16 minutes. La status line montre cps + BPM.

4. **Le pattern est vide.** `"~"` ne produit aucun événement. Vérifie
   que la mini-notation ne s'est pas réduite à du silence.

5. **Un drone `auto_env=false` ne part jamais.** Un drone se déclenche
   une fois par cycle. Sans enveloppe ET avec un cps très lent, tu
   attends peut-être simplement. Accélère le cps, ou mets une enveloppe.

## « La TUI rame / saute »

1. **Monte le fps.** Par défaut 120 ; si ton terminal est rapide,
   `[ui] fps = 240` dans `ressac.toml` puis `:reload-cfg`. S'il est
   lent, descends à 60.

2. **Le buffer de patterns est énorme.** Au-delà de ~500 lignes,
   l'éditeur peut hoqueter. Découpe en sessions plus petites avec
   `:save` / `:load`.

3. **Un pattern est très lent à interroger.** Des chaînes profondes
   `every(N, every(M, every(...) ...))` coûtent O(profondeur) par cycle.
   Le découpage du scheduler (snapshot + query, voir l'architecture)
   évite le bégaiement de l'UI, mais le CPU par cycle reste
   proportionnel à la profondeur.

## « La librairie ne charge pas mon fichier »

1. **Le fichier est dans `plugins/user-synths/` ?** C'est là que `:w`
   écrit et que `:lib` lit.

2. **L'extension correspond au mode ?** `.jl` = DSL, `.scd` = SC brut.

3. **Nouveau fichier `.scd` ?** Il apparaît au prochain `live()`. La
   librairie rescanne à chaque `:lib`, donc le synth y apparaît avant —
   mais un pattern ne peut le nommer qu'après rechargement des
   métadonnées du plugin.

## « La sélection à la souris ne copie pas »

Ressac capture la souris pour router les clics. Deux options :
- `:pause` fige le rendu — le shift-glisser natif de ton terminal marche.
  Une touche dans Ressac reprend.
- `:copylogs` envoie tout le journal dans le presse-papier via
  `wl-copy` / `xclip` / `xsel`.

## « J'ai tout cassé, je veux repartir »

```
:starter house     # remplace le buffer par le pack house
```

Ou pour un buffer vraiment vide :
```
Esc → gg → V → G → d → i
```

Si Ressac lui-même est dans un état bizarre, `:q` puis `live()` est un
redémarrage propre. Le scheduler (et ton SC) survivent : les voix d'avant
continuent jusqu'à `:hush` / `:panic`.

## Toujours bloqué ?

Ouvre une issue avec :
- Les lignes de journal exactes
- Le pattern qui pose problème
- Tes versions de Julia, Ressac et SuperCollider

`:copylogs` copie le journal dans le presse-papier.

## Une voix continue après un `:mute`

Un synth garde sa voix tant que son enveloppe n'est pas finie : couper
le slot arrête les nouveaux événements, pas celui qui sonne encore.

Trois niveaux, du plus doux au plus brutal :

- `:hush` (ou `,`) arrête tous les patterns et laisse les queues finir.
- `:panic` arrête tout et libère les voix côté SuperCollider.
- Si une voix ne s'arrête jamais toute seule, c'est que son SynthDef n'a
  pas de paramètre `sustain` : le titre de sa pane l'indique
  (`sans hauteur`, ou pas de `durée sustain`). Un `@synth` du DSL en a
  toujours un ; un `.scd` écrit à la main doit le déclarer, ou fixer sa
  propre enveloppe avec `doneAction: 2`.
