# src/app_command_docs.jl
# Une ligne par commande `:` — ce que la palette (Ctrl-p) et la complétion de
# la ligne de commande affichent à côté du nom. Les synonymes partagent leur
# ligne. `test/test_command_docs.jl` échoue si une commande n'en a pas :
# une commande sans description est une commande qu'on ne retrouve pas.

const _COMMAND_DOC_TABLE = Pair{Tuple{Vararg{String}},String}[
    # ── Jouer ────────────────────────────────────────────────────────
    ("panic",)                          => "tout couper net : les notes, les effets, les drones",
    ("hush", "stop", "silence")         => "taire tous les slots",
    ("mute",)                           => "couper un slot — :mute d3",
    ("unmute", "unsolo")                => "remettre tous les slots — ou un seul : :unmute d3",
    ("solo",)                           => "n'entendre qu'un slot — :solo d3",
    ("cps",)                            => "le tempo en cycles par seconde — :cps 0.5",
    ("tap-tempo", "taptempo", "bpm")    => "taper le tempo à la main",
    ("now",)                            => "évaluer prend effet tout de suite",
    ("jump",)                           => "évaluer prend effet au prochain cycle — :jump 2 pour dans deux",
    ("xfade",)                          => "évaluer fond l'ancien vers le nouveau — :xfade 8 pour huit cycles",
    ("mixer", "mix")                    => "les slots en jeu : niveau, gain, mute, solo",
    ("clash", "clashes", "collisions")  => "les slots qui se marchent dessus (mêmes fréquences, mêmes temps)",
    # ── Écrire ───────────────────────────────────────────────────────
    ("tap",)                            => "frapper un motif au clavier — :tap bd",
    ("tap-strict", "tap-bar")           => "frapper un motif calé sur la mesure — :tap-strict bd",
    ("piano",)                          => "jouer des notes au clavier — :piano superpiano",
    ("piano-rec", "piano-record")       => "jouer des notes au clavier et les écrire en pattern",
    ("keyboard", "clavier")             => "la disposition du clavier de jeu — :clavier seul dit laquelle",
    ("snip", "snippets", "snippet")     => "les bouts de code prêts à poser",
    ("vary", "variations", "evolve")    => "des variations du bloc sous le curseur",
    ("starter",)                        => "charger un point de départ — :starter <genre>",
    ("leader",)                         => "le menu Espace : le voir — :leader x <texte> y met une touche à toi",
    ("leader-rm",)                      => "retirer une de tes touches du menu Espace — :leader-rm x",
    ("alias",)                          => "donner un nom court à un son — :alias k kick",
    ("alias-ls", "aliases")             => "la liste des alias",
    ("alias-rm",)                       => "retirer un alias — :alias-rm k",
    ("alias-rename",)                   => "renommer un alias — :alias-rename k kk",
    # ── Ranger et retrouver ──────────────────────────────────────────
    ("w", "save-synth")                 => "écrire : la session, ou le son ouvert — :w nom pour écrire sous un nom",
    ("e",)                              => "relire la session du disque — :e nom en ouvre une autre",
    ("e!",)                             => "relire ou ouvrir en laissant ce qui n'est pas écrit",
    ("enew",)                           => "une session neuve",
    ("enew!",)                          => "une session neuve, en laissant ce qui n'est pas écrit",
    ("sessions", "ls")                  => "les sessions rangées",
    ("réserve", "reserve")              => "ce que tu as rangé : sons, motifs, sessions, recettes",
    ("keep",)                           => "ranger le bloc @dN sous le curseur — :keep nom",
    ("recall",)                         => "reposer un motif rangé — :recall nom, ou :recall nom d3",
    ("pats", "patterns", "patlib")      => "tes motifs rangés",
    ("palette", "p")                    => "chercher par nom tout ce qui en a un",
    # ── Les sons ─────────────────────────────────────────────────────
    ("synth", "scratch", "sandbox")     => "ouvrir un son à droite — :synth nom l'ouvre ou le commence",
    ("son",)                            => "le son, à droite",
    ("close",)                          => "fermer l'onglet du son ouvert",
    ("tabs",)                           => "la liste des sons ouverts",
    ("tabnext", "tabn")                 => "le son ouvert suivant",
    ("tabprev", "tabp")                 => "le son ouvert précédent",
    ("t", "test")                       => "faire entendre le son ouvert",
    ("test-raw",)                       => "faire entendre le son ouvert, variante brute",
    ("note",)                           => "la note de test — :note c3",
    ("format", "fmt")                   => "remettre en forme le texte du son",
    ("explain",)                        => "ce que fait le son, maillon par maillon",
    ("prune",)                          => "retirer du son ce qui ne s'entend pas",
    ("todsl", "to-dsl", "sc2dsl")       => "traduire un SynthDef SuperCollider dans le langage de Ressac",
    ("export", "export-synth")          => "écrire le SynthDef SuperCollider du son",
    ("import",)                         => "prendre un son d'un fichier — :import chemin as nom",
    ("explorer", "explore")             => "l'explorateur génétique de sons",
    ("browse", "b")                     => "tous les sons : samples, instruments, synths",
    ("samples",)                        => "la liste des samples",
    ("instruments",)                    => "la liste des instruments",
    ("synths",)                         => "la liste des synths",
    ("synthlib", "synth-library", "lib") => "les recettes de sons, à installer",
    ("add",)                            => "installer une recette — :add nom",
    ("sccode", "sc")                    => "chercher un son sur sccode.org",
    ("sccode-tag", "sctag")             => "sccode.org par étiquette — :sctag bass",
    ("sc-rediscover",)                  => "redemander à SuperCollider la liste de ses UGens",
    ("sc-cache-info",)                  => "ce que Ressac sait des UGens de SuperCollider",
    ("audio-in",)                       => "écouter l'entrée audio — :audio-in start / stop",
    # ── Notes et gammes ──────────────────────────────────────────────
    ("scale", "scale list", "scales", "gammes") => "les gammes",
    ("chords", "accords")               => "les accords",
    ("tuning", "tuning bp", "tuning golden") => "l'accordage — :tuning edo 19, :tuning golden, :tuning bp",
    ("notes", "roll", "piano-roll")     => "les notes en jeu, en rouleau de piano",
    # ── Écouter et enregistrer ───────────────────────────────────────
    ("sorties", "outputs", "audio")     => "la sortie principale et le casque",
    ("casque",)                         => "envoyer les essais dans le casque seul",
    ("rec", "record")                   => "enregistrer la sortie principale — de nouveau pour arrêter",
    ("safety",)                         => "le garde-fou audio — :safety on / off",
    # ── L'écran ──────────────────────────────────────────────────────
    ("back", "fiche")                   => "rendre la colonne de droite à la fiche",
    ("wiki", "docs", "doc-wiki")        => "le wiki, à droite — :wiki 5 pour une page",
    ("doc",)                            => "la fiche d'un mot — :doc gain",
    ("scope",)                          => "l'oscilloscope — :scope <vue> ; :scope seul l'éteint",
    ("log",)                            => "le journal du bas : 1, 3, 10 lignes, replié — :log 5",
    ("copylogs", "yanklogs")            => "copier tout le journal dans le presse-papiers",
    ("pistes", "lanes", "inline")       => "montrer ou cacher la grille du cycle",
    ("calme", "calm")                   => "plus rien ne clignote au coup",
    ("zoom",)                           => "la pane qui a le clavier en plein écran",
    ("reset",)                          => "remettre l'écran à plat : les patterns et la fiche",
    ("vsplit",)                         => "une pane à droite — :vsplit log",
    ("hsplit",)                         => "une pane dessous — :hsplit notes",
    ("pclose", "paneclose")             => "fermer la pane qui a le clavier",
    ("float",)                          => "détacher la pane en fenêtre flottante",
    ("tile",)                           => "remettre la fenêtre flottante dans la grille",
    ("layout", "layout save", "layout load") => "garder ou retrouver une disposition — :layout save nom",
    ("workspace",)                      => "un espace de travail de plus — :workspace new nom",
    ("theme", "themes")                 => "le thème de couleurs — :theme seul les liste",
    ("pause", "freeze")                 => "figer l'écran pour copier à la souris (une touche le rend)",
    # ── Aide et réglages ─────────────────────────────────────────────
    ("?", "help", "guide")              => "les touches de l'endroit où tu es",
    ("tutorial", "tour", "start")       => "le tutoriel, pas à pas",
    ("dsl", "dsl-guide", "synth-dsl")   => "le guide du langage des sons",
    ("synth-guide",)                    => "le guide : construire un son",
    ("reload-config", "reload-cfg")     => "relire le fichier de configuration",
    ("keydebug",)                       => "afficher chaque touche reçue (pour déboguer le clavier)",
    ("q", "quit")                       => "fermer le volet ; de nouveau, quitter",
    ("q!", "qa", "qa!")                 => "quitter",
]

const _COMMAND_DOCS = let d = Dict{String,String}()
    for (verbs, doc) in _COMMAND_DOC_TABLE, v in verbs
        d[v] = doc
    end
    d
end

"""
    _command_doc(verb) -> String

La description d'une ligne de la commande `verb` (avec ou sans son `:`),
vide si elle n'en a pas.
"""
_command_doc(verb::AbstractString) = get(_COMMAND_DOCS, String(lstrip(verb, ':')), "")
