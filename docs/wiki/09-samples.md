# Ajouter tes propres samples

Ressac embarque toute la collection de samples de TidalCycles (bd, sn,
hh, cp, amen, …) plus un lot de départ d'instruments et de synths. Pour
utiliser TES enregistrements — un chop de voix, une texture trouvée, un
kick samplé sur un disque — il y a deux chemins.

## Le chemin rapide : `:import`

```
:import /chemin/vers/ton-sample.wav
:import /chemin/vers/ton-sample.wav as kickheavy
```

Ça :
1. Copie le fichier dans `plugins/user-samples/<nom>/<nom>_0.wav`
2. L'enregistre comme banque de samples `<nom>` (ou le nom du fichier
   si tu ne donnes pas `as ...`)
3. Demande au SuperCollider en cours de le charger — sans redémarrer

Utilise-le tout de suite :
```julia
@d1 "kickheavy ~ kickheavy ~"
```

Relancer `:import` avec le même nom sur un autre fichier **ajoute une
variante** au lieu d'écraser :
```
:import kick1.wav as mykick     # mykick:0
:import kick2.wav as mykick     # mykick:1  (tu en as 2)
:import kick3.wav as mykick     # mykick:2
```

Dans les patterns, tu choisis la variante avec `n(...)` :
```julia
@d1 :mykick |> n("0 1 2 1")    # tourne sur les trois
@d1 "mykick"                    # variante aléatoire
@d1 "mykick:1"                  # la variante 1 précisément
```

## Un son de la librairie de synths

`acid303`, `chaoglitch` et la cinquantaine d'autres recettes ne sont pas
chargées d'office : ce sont des modèles. `:add acid303` en installe une
dans `plugins/user-synths/` et la compile, `@d1 :acid303` la joue tout de
suite. `:synth acid303` fait pareil en ouvrant l'éditeur, `Espace L`
ouvre la librairie pour parcourir.

Quand `e` ou `:e` rencontre un nom inconnu qui correspond à une recette,
le journal propose directement la commande.

## Le chemin plugin

Pour une banque de dizaines de samples rangés par catégorie, écris un
descripteur de plugin au lieu d'importer fichier par fichier.

Crée `plugins/<nom-du-plugin>/plugin.toml` :

```toml
name = "my-pack"
version = "0.1.0"
description = "ma collection de sons trouvés"

[samples]
# Soit une liste de dossiers racines que Ressac parcourt, chaque
# sous-dossier devenant une banque nommée d'après le dossier :
roots = ["/chemin/absolu/vers/tes/dossiers/de/samples/"]

# OU des banques explicites :
[[samples.banks]]
name = "vibegtr"
path = "/chemin/absolu/vers/guitar-textures/"

[[samples.banks]]
name = "vinylhiss"
path = "/chemin/absolu/vers/vinyl-hiss/"
```

Redémarre Ressac (ou `:reload-config` s'il tourne déjà et que tu n'as
changé que le TOML — pour de nouveaux dossiers il faut relancer SC).
Les noms `vibegtr` et `vinylhiss` sont maintenant dans `:browse`, dans
la complétion et dans les patterns.

## Où vivent les choses

```
plugins/
  dirt/                       # les Dirt-Samples embarqués (bd, sn, hh, …)
  superdirt-synths/           # synthdefs SC (super808, supersaw, …)
  starter-instruments/        # chaînes préréglées comme :kicklourd, :sub
  user-synths/                # tes synthdefs sauvés par :w (.scd ou .jl)
  user-samples/               # ce que :import remplit
    mykick/
      mykick_0.wav
      mykick_1.wav
      mykick_2.wav
    voxchop/
      voxchop_0.wav
```

La disposition est celle de Dirt lui-même : tout ce que tu mets dans
`plugins/user-samples/<nom>/` marche — `:import` n'est que du sucre sur
la même convention.

## Formats de fichiers

Tout ce que SuperCollider lit : WAV, AIFF, FLAC. Stéréo ou mono. Pour
une lecture propre, normalise vers −3 dBFS pour laisser de la marge au
gain par événement de SuperDirt.

## Conseils

- **Nommage** : minuscules, sans espaces, ASCII. Les caractères
  interdits sont remplacés par `_` en silence par `:import`, avec
  parfois des surprises. `:import kick_heavy.wav as kickheavy` est plus
  propre que de laisser Ressac deviner.
- **Dossier ou fichier** : une banque est un dossier ; chaque `.wav`
  dedans est une variante. Même un sample seul vit dans un dossier.
- **Découverte** : après l'import, `:browse` le montre dans la catégorie
  « samples ». La complétion dans `:s nom` et `"nom"` le trouve aussi.
- **Suppression** : supprime le dossier sous `plugins/user-samples/` et
  redémarre. Pas de `:unimport` pour l'instant.
