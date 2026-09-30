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
end
_TutoStep(title, body, check) = _TutoStep(title, body, check, (m, p) -> nothing)

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
    _TutoStep("Et ensuite",
        """
        Tu sais écrire, jouer, changer, couper, contrôler et arrêter.
        La suite se trouve dans la pane **WIKI** à droite (`:wiki`) :

        - `02-patterns` : toute la mini-notation et les combinateurs
        - `05-cookbook` : des recettes par genre, `:starter house`
        - `03-synth-dsl` : concevoir un son, `:design`, puis `U` pour
          l'utiliser dans un pattern
        - `:tap` : tape un rythme à l'Espace, Ressac écrit la ligne

        `:q` ferme cette pane. `:tutorial` la rouvre, `r` recommence.
        """,
        (m, p) -> false),
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
function _tutorial_tick!(m)
    p = _find_pane(m, TutorialPane)
    (p === nothing || p.finished) && return
    p.step > length(_TUTO_STEPS) && (p.finished = true; return)
    done = try _TUTO_STEPS[p.step].check(m, p) catch; false end
    done || return
    if p.step == length(_TUTO_STEPS)
        p.finished = true
    else
        p.step += 1
        _tuto_enter!(m, p)
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
bind!(:tutorial, ["j", "↓"], "défiler"; group = :nav, repeat = true, action = p -> _scroll!(p.view, :down))
bind!(:tutorial, ["k", "↑"], "remonter"; group = :nav, repeat = true, when = p -> p.view.offset > 0,
      action = p -> _scroll!(p.view, :up))
bind!(:tutorial, "n", "sauter l'étape"; short = "sauter", group = :nav,
      action = p -> (p.finished || (p.step >= length(_TUTO_STEPS) ? (p.finished = true) : (p.step += 1; _scroll_top!(p.view)))))
bind!(:tutorial, "p", "étape précédente"; short = "précédente", group = :nav, when = p -> p.step > 1 || p.finished,
      action = p -> (p.finished ? (p.finished = false) : (p.step -= 1); _scroll_top!(p.view)))
bind!(:tutorial, "r", "recommencer"; group = :nav,
      action = p -> (p.step = 1; p.finished = false; _scroll_top!(p.view)))
