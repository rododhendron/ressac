# src/pane_tutorial.jl
# Le tutoriel — une pane à côté des patterns, qui regarde ce que tu fais
# et avance toute seule : chaque étape dit quoi faire et attend que ce
# soit fait (le mode a changé, un slot joue, un slot est coupé…). On
# lit, on agit dans l'éditeur, la pane passe à la suite. `n` saute une
# étape, `p` revient, `r` recommence, `:q` ferme.

struct _TutoStep
    title::String
    body::String                  # markdown, rendu par content_markdown.jl
    check::Function               # (m, p) -> Bool : l'étape est faite
    enter::Function               # (m, p) -> nothing : à l'entrée dans l'étape
    workspace::String             # où l'étape se joue ("" = n'importe où) : la pane s'y ouvre
end
_TutoStep(title, body, check) = _TutoStep(title, body, check, (m, p) -> nothing, "")
_TutoStep(title, body, check, enter) = _TutoStep(title, body, check, enter, "")

mutable struct TutorialPane <: PaneImpl
    step::Int
    finished::Bool
    snapshot::Dict{Symbol,Any}    # les patterns au moment d'entrer dans une étape (pour « change en jouant »)
    view::TK.ScrollPane
    rendered::Tuple{Int,Int,Bool}  # (étape, largeur, fini) du contenu posé dans `view`
end
TutorialPane(step::Int = 1) = TutorialPane(step, false, Dict{Symbol,Any}(), _scrollpane(), (0, 0, false))
_tutorial_pane_ctor(args::AbstractDict) = TutorialPane(clamp(Int(get(args, "step", 1)), 1, 99))

# ── Ce qu'on regarde ─────────────────────────────────────────────────
_tuto_editor(m) = _active_editor(m)
_tuto_text(m) = (ed = _tuto_editor(m); ed === nothing ? "" : TK.text(ed))
_tuto_mode(m) = (ed = _tuto_editor(m); ed === nothing ? :none : ed.mode)
_tuto_has_slot_line(m) = occursin(r"(?m)^\s*@d\d+\s+\S", _tuto_text(m))
_tuto_has_pipe_line(m) = occursin(r"(?m)^\s*@d\d+.*\|>", _tuto_text(m))
_tuto_playing(m) = length(m.scheduler.patterns)
# Coupé : par `m` (la ligne @dN est commentée et le slot retiré) ou par
# le bandeau / le mixer (le pattern est mis de côté).
_tuto_muted(m) = length(_APP_MUTED_PATTERNS) + length(collect(eachmatch(r"(?m)^\s*#\s*@d\d+", _tuto_text(m))))
# « Changer en jouant » : le texte a changé ET un slot a été réévalué
# (un nouvel objet pattern) depuis l'entrée dans l'étape.
# Où le joueur travaille : le contexte de la pane focalisée (app_modes.jl).
_tuto_ws(m) = (mode = _workspace_mode(m); mode === :design ? "DESIGN" : mode === :explore ? "EXPLORE" : "PLAY")
_tuto_design_parts(m) = _synth_workspace_parts(m)
_tuto_doc_mode(m) = (parts = _tuto_design_parts(m); (parts === nothing || parts[2] === nothing) ? :none : parts[2].mode)
_tuto_synth_name(m) = (t = _current_synth_tab(m); t === nothing ? "" : t.name)

function _tuto_snapshot!(m, p::TutorialPane)
    p.snapshot = Dict{Symbol,Any}(k => v for (k, v) in m.scheduler.patterns)
    p.snapshot[:__text] = _tuto_text(m)
    return
end
function _tuto_changed(m, p::TutorialPane)
    _tuto_playing(m) > 0 || return false
    if _tuto_text(m) == get(p.snapshot, :__text, "")
        # Réévaluer sans rien changer ne compte pas : on repart de ces objets-là.
        for (k, v) in m.scheduler.patterns; p.snapshot[k] = v; end
        return false
    end
    return any(get(p.snapshot, k, nothing) !== v for (k, v) in m.scheduler.patterns)
end

const _TUTO_STEPS = _TutoStep[
    _TutoStep("Deux modes, comme vim",
        """
        Tu démarres en mode **NORMAL** : les touches sont des commandes. Le
        mode est écrit dans la ligne du haut.

        Appuie sur `i` pour passer en **INSERTION**, le mode où l'on tape du
        texte.
        """,
        (m, p) -> _tuto_mode(m) === :insert),
    _TutoStep("Revenir en normal",
        """
        Tu es en insertion. Tout ce que tu tapes va dans le buffer.

        Appuie sur `Esc` pour revenir en **NORMAL**. C'est le va-et-vient de
        base : `i` pour écrire, `Esc` pour commander.
        """,
        (m, p) -> _tuto_mode(m) === :normal),
    _TutoStep("Écrire un pattern",
        """
        Un pattern, c'est une ligne `@dN` suivie d'un rythme en
        mini-notation. Le buffer en contient déjà ; ajoute le tien.

        `i`, puis tape sur une ligne vide :

        ```julia
        @d1 "bd sn hh sn"
        ```

        puis `Esc`. Les mots sont des sons (`bd` grosse caisse, `sn` caisse
        claire, `hh` charleston), l'espace les répartit dans le cycle.
        """,
        (m, p) -> _tuto_has_slot_line(m) && _tuto_mode(m) === :normal),
    _TutoStep("Jouer",
        """
        Le curseur sur ta ligne `@d1`, appuie sur `e` : la ligne s'évalue
        et joue. `E` évalue **tous** les blocs `@dN` du buffer.

        La ligne clignote en vert, et le bandeau des slots au-dessus montre
        ce qui tourne : le motif, le pas qui sonne, le gain.
        """,
        (m, p) -> _tuto_playing(m) > 0),
    _TutoStep("Changer en jouant",
        """
        C'est ça, le live-coding : modifie la ligne pendant qu'elle joue.
        Par exemple `"bd*2 sn hh*3 sn"` (`*` répète dans le pas), ou
        `"bd sn . hh hh hh"` (`.` sépare des groupes).

        Puis `e` à nouveau. Le son change au cycle suivant, sans trou.
        """,
        (m, p) -> _tuto_changed(m, p),
        (m, p) -> _tuto_snapshot!(m, p)),
    _TutoStep("Couper une voix",
        """
        Le curseur sur la ligne `@d1`, appuie sur `m` : le slot est
        **coupé** (muet), le bandeau le montre en gris avec ⏸.

        Un clic sur sa ligne dans le bandeau fait la même chose.
        """,
        (m, p) -> _tuto_muted(m) > 0),
    _TutoStep("La remettre",
        """
        `m` encore, sur la même ligne : la voix revient là où elle en
        était. Couper et remettre, c'est le geste le plus courant en jeu.
        """,
        (m, p) -> _tuto_muted(m) == 0 && _tuto_playing(m) > 0),
    _TutoStep("Un contrôle",
        """
        Après le rythme, on enchaîne des contrôles avec `|>` :

        ```julia
        @d1 "bd sn hh sn" |> gain(0.7) |> lpf(1200)
        ```

        `gain` le volume, `lpf` un filtre passe-bas. Pose le curseur sur
        un mot comme `lpf` : la pane **DOC** en bas à droite montre sa
        fiche. Puis `e`.
        """,
        (m, p) -> _tuto_has_pipe_line(m) && _tuto_playing(m) > 0),
    _TutoStep("Une deuxième voix",
        """
        Chaque slot est une voix. Ajoute une ligne `@d2` avec autre
        chose, par exemple :

        ```julia
        @d2 "~ cp ~ cp" |> gain(0.6)
        ```

        `~` est un silence. `e` sur cette ligne (ou `E` pour tout) : deux
        voix jouent ensemble.
        """,
        (m, p) -> _tuto_playing(m) >= 2),
    _TutoStep("Tout arrêter",
        """
        `,` (virgule) arrête tout en douceur : les sons finissent leur
        enveloppe. `!` coupe tout net, c'est le bouton panique.

        Appuie sur `,`.
        """,
        (m, p) -> _tuto_playing(m) == 0 && _tuto_muted(m) == 0),
    _TutoStep("Tout retrouver",
        """
        `Ctrl-p` ouvre la **palette** : on tape, elle filtre commandes,
        sons, fonctions, patterns rangés, recettes de synths et pages du
        wiki. `Entrée` fait ce qu'il faut selon l'entrée choisie.

        Ouvre-la, regarde, `Esc` la ferme.
        """,
        (m, p) -> m.modal === :palette),
    _TutoStep("L'aide du contexte",
        """
        `?` ouvre l'aide de l'endroit où tu es : les touches de la pane
        focalisée, puis les globales. `Tab` y montre toutes les sections.

        Appuie sur `?`, puis `Esc`.
        """,
        (m, p) -> m.modal === :help),
    _TutoStep("Concevoir un son",
        """
        Tu sais écrire, jouer, changer, couper, contrôler et arrêter.
        Deuxième chapitre : **fabriquer un son**.

        Tape `:son`. Le texte d'un son s'ouvre à droite ; les patterns
        restent à gauche et continuent de jouer.
        """,
        (m, p) -> _tuto_ws(m) == "DESIGN"),
    _TutoStep("Le son, à côté des patterns",
        """
        À droite, le **texte** du synth : c'est le son lui-même, il n'y a
        rien d'autre à régler ailleurs. Dessous, sa **DOC**.

        Appuie sur `T` : tu l'entends. `T` marche depuis le texte comme
        depuis la DOC.
        """,
        (m, p) -> m.last_t_fire > get(p.snapshot, :t_fire, 0.0),
        (m, p) -> (p.snapshot[:t_fire] = m.last_t_fire),
        "DESIGN"),
    _TutoStep("Changer le son dans le texte",
        """
        Le son est une chaîne : une source, puis des étapes reliées par
        `|>`. Remplace la ligne `@synth` par :

        ```julia
        @synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)
        ```

        `saw` une dent de scie, `rlpf` un passe-bas résonnant. `Esc`, puis
        `T` : plus brillant, plus filtré.
        """,
        (m, p) -> occursin("rlpf(", _tuto_text(m)) && _tuto_mode(m) === :normal,
        (m, p) -> nothing, "DESIGN"),
    _TutoStep("L'atelier : travailler le son dans son texte",
        """
        Un nombre se tire sur place : le curseur dessus, `+` / `-` le
        bougent d'un pas, `*` / `/` de dix (la molette aussi). Le son est redéfini aussitôt.

        Une étape de la chaîne est un **maillon**. Sur un maillon, `o` en
        propose un nouveau après lui — il s'entend avant d'être gardé —,
        `cim` le remplace, `dam` le retire. `&` ouvre le reste de l'atelier.

        Tire un nombre, puis `T` pour écouter la différence. `u` annule.
        """,
        (m, p) -> _tuto_mode(m) === :normal && _tuto_text(m) != get(p.snapshot, :text, ""),
        (m, p) -> (p.snapshot[:text] = _tuto_text(m)), "DESIGN"),
    _TutoStep("La DOC raconte le son",
        """
        La DOC a trois vues. `K` la met sur la **fiche** du mot
        sous le curseur, `X` sur l'**explication** du son (ce que fait chaque
        étape, ce qui ne s'entend pas), `Y` sur son **graphe** câblé.

        Appuie sur `Y`.
        """,
        (m, p) -> _tuto_doc_mode(m) === :graph,
        (m, p) -> nothing, "DESIGN"),
    _TutoStep("Tenir le son",
        """
        `D` tient le son en **drone** : il ne s'arrête plus, et la
        **MODULATION** passe devant, sous le texte, avec ses arguments. `j` / `k` en choisissent
        un, `l` / `h` le modulent pendant que ça sonne.

        Appuie sur `D`, joue avec, puis `D` à nouveau pour relâcher.
        """,
        (m, p) -> get(p.snapshot, :droned, false) && !drone_running(Symbol(_tuto_synth_name(m))),
        (m, p) -> (p.snapshot[:droned] = false), "DESIGN"),
    _TutoStep("Vers les patterns",
        """
        `U` sauve ce son sous son nom et pose une ligne `@dN p"sketch*4"`
        dans les patterns, à gauche, prête à jouer : on fabrique à droite,
        on joue à gauche.

        Appuie sur `U`.
        """,
        (m, p) -> _tuto_ws(m) == "PLAY" && occursin(r"@d\d+ p\"\w+\*4\"", _tuto_text(m)),
        (m, p) -> nothing, "DESIGN"),
    _TutoStep("Et ensuite",
        """
        Tu sais jouer, et fabriquer un son. La suite se trouve dans le
        **wiki**, qui s'ouvre à droite (`:wiki`, `:q` le referme) :

        - `02-patterns` : toute la mini-notation et les combinateurs
        - `03-synth-dsl` : le DSL en entier, l'élagage, les drones
        - `16-explore` : l'explorateur génétique, `:explorer`
        - `05-cookbook` : des recettes par genre, `:starter house`
        - `:tap` : tape un rythme à l'Espace, Ressac écrit la ligne

        `:q` ferme cette pane. `:tutorial` la rouvre, `r` recommence.
        """,
        (m, p) -> false, (m, p) -> nothing, "PLAY"),
]

# ── La mécanique ─────────────────────────────────────────────────────
function _tuto_enter!(m, p::TutorialPane)
    1 <= p.step <= length(_TUTO_STEPS) || return
    try _TUTO_STEPS[p.step].enter(m, p) catch end
    _scroll_top!(p.view)
    return
end

"""
    _tutorial_tick!(m)

À chaque rendu : si la pane tutoriel est ouverte et que l'étape courante
est faite, on passe à la suivante. Une vérification qui échoue ne fait
jamais tomber l'application.
"""
# La pane tutoriel du workspace courant, sinon celle d'un autre (le
# tutoriel suit le joueur d'un mode à l'autre).
function _find_tutorial_any(m)
    p = _find_pane(m, TutorialPane)
    p === nothing || return p
    for ws in m.workspaces.workspaces, leaf in _all_leaves(ws.tree), tab in leaf.tabs
        tab isa TutorialPane && return tab
    end
    return nothing
end

function _tutorial_tick!(m)
    p = _find_tutorial_any(m)
    (p === nothing || p.finished) && return
    p.step > length(_TUTO_STEPS) && (p.finished = true; return)
    # D pendant l'étape « Tenir le son » : on note que le drone a tourné
    if _TUTO_STEPS[p.step].title == "Tenir le son" && drone_running(Symbol(_tuto_synth_name(m)))
        p.snapshot[:droned] = true
    end
    done = try _TUTO_STEPS[p.step].check(m, p) catch; false end
    if done
        if p.step == length(_TUTO_STEPS)
            p.finished = true
        else
            p.step += 1
            _tuto_enter!(m, p)
        end
    end
    return
end

function _tuto_goto!(m, p::TutorialPane, step::Int)
    p.step = clamp(step, 1, length(_TUTO_STEPS))
    p.finished = false
    _tuto_enter!(m, p)
    return
end

"""
    _open_tutorial!(m)

`:tutorial` — ouvre la pane (ou la retrouve) et rend le focus à
l'éditeur : on lit d'un côté, on agit de l'autre.
"""
function _open_tutorial!(m)
    p = _find_pane(m, TutorialPane)
    if p === nothing
        p = _place_pane!(m, :tutorial, Dict{String,Any}())
        p isa TutorialPane || return
        _push_app_log!(m, "[INFO] tutoriel ouvert — fais ce qu'il dit, il avance tout seul · n saute · :q ferme")
    else
        _tuto_goto!(m, p, 1)
        _push_app_log!(m, "[INFO] tutoriel repris du début")
    end
    ed_pane = _find_pane(m, EditorPane)
    ed_pane === nothing || _focus_pane!(m, ed_pane)
    ed = _active_editor(m)
    ed === nothing || (ed.mode = :normal)
    return
end

# ── Rendu ────────────────────────────────────────────────────────────
function _tuto_lines(p::TutorialPane, width::Int)
    n = length(_TUTO_STEPS)
    step = clamp(p.step, 1, n)
    st = _TUTO_STEPS[step]
    out = Vector{TK.Span}[]
    # Le fil des étapes : ✓ faites, ▶ courante, · à venir.
    marks = TK.Span[]
    for i in 1:n
        sty = i < step || p.finished ? TK.tstyle(:success) :
              i == step ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text_dim)
        push!(marks, TK.Span(i < step || p.finished ? "✓" : i == step ? "▶" : "·", sty))
    end
    push!(out, marks)
    head = p.finished ? "Terminé — $(st.title)" : "Étape $step/$n — $(st.title)"
    push!(out, _md_plain(head, TK.tstyle(:accent, bold = true)))
    push!(out, TK.Span[])
    src = [strip(l) for l in split(st.body, '\n')]
    append!(out, _md_render(src, width))
    if p.finished
        push!(out, TK.Span[])
        push!(out, _md_plain("✓ Bravo. r recommence, :q ferme.", TK.tstyle(:success, bold = true)))
    end
    return out
end

function render!(p::TutorialPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    n = length(_TUTO_STEPS)
    _render_pane_block_simple!(rect, "TUTORIEL · $(min(p.step, n))/$n", buf)
    inner = _inner_rect_simple(rect)
    (inner.height < 1 || inner.width < 12) && return nothing
    w = inner.width - 1
    key = (p.step, w, p.finished)
    if p.rendered != key
        TK.set_content!(p.view, _tuto_lines(p, w))
        p.rendered = key
    end
    TK.render(p.view, inner, buf)
    return nothing
end

handle_key!(p::TutorialPane, evt) = evt isa TK.KeyEvent && dispatch!(((:tutorial, p),), evt)
handle_mouse!(p::TutorialPane, evt::TK.MouseEvent) = TK.handle_mouse!(p.view, evt)
pane_scope(::TutorialPane) = :tutorial
title(p::TutorialPane) = "tutoriel"
serialize(p::TutorialPane) = Dict{String,Any}("step" => p.step)
register_pane_kind!(:tutorial, _tutorial_pane_ctor)

scope!(:tutorial, "Tutoriel")
mixin_scroll_nav!(:tutorial, p -> p.view; hint = true, labels = (down = "défiler", up = "remonter"))
bind!(:tutorial, "n", "sauter l'étape"; short = "sauter", group = :nav,
      action = p -> (p.finished || (p.step >= length(_TUTO_STEPS) ? (p.finished = true) : (p.step += 1; _scroll_top!(p.view)))))
bind!(:tutorial, "p", "étape précédente"; short = "précédente", group = :nav, when = p -> p.step > 1 || p.finished,
      action = p -> (p.finished ? (p.finished = false) : (p.step -= 1); _scroll_top!(p.view)))
bind!(:tutorial, "r", "recommencer"; group = :nav,
      action = p -> (p.step = 1; p.finished = false; _scroll_top!(p.view)))
