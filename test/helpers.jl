# Socle commun de la suite. Inclus par runtests.jl et par l'en-tête de chaque
# test_*.jl, pour que n'importe quel fichier tourne seul :
#
#     julia --project=. -e 'include("test/test_scheduler.jl")'
#
# La garde le rend idempotent : une seule évaluation par session Julia.
if !isdefined(Main, :_RESSAC_TEST_HELPERS)
const _RESSAC_TEST_HELPERS = true

using Test
using Ressac
import Tachikoma

# ── Bac à sable disque ────────────────────────────────────────────────
# Rien de ce que fait la suite ne doit toucher aux données du joueur ni au
# dépôt. Les préférences (dispositions, usage de la complétion) partent dans
# un répertoire temporaire, et le « projet » (plugins/user-synths, sessions/,
# recordings/) est le répertoire courant : on s'y place une fois pour toutes.
const _TEST_SANDBOX = mktempdir()
ENV["RESSAC_CONFIG_DIR"] = joinpath(_TEST_SANDBOX, "config")
cd(mkpath(joinpath(_TEST_SANDBOX, "project")))

# Jamais de sclang dans la suite par défaut : tout rendu hors-ligne
# (récolte NRT de l'explorateur, onde d'une pane, sculpt) échoue vite et
# proprement. RESSAC_NRT_TESTS=1 pour les tests qui le veulent vraiment.
Ressac._NRT_ALLOWED[] = get(ENV, "RESSAC_NRT_TESTS", "") == "1"

# ── Registres ─────────────────────────────────────────────────────────
# Les fiches et les snippets viennent des plugins du dépôt : les tests qui
# interrogent `:doc <nom>` ou `:starter <nom>` en ont besoin.
const _REPO_PLUGINS = normpath(joinpath(@__DIR__, "..", "plugins"))
empty!(Ressac._DOCS)
empty!(Ressac._DOC_ALIASES)
empty!(Ressac._SNIPPETS)
empty!(Ressac._SNIPPET_RAW)
Ressac._load_plugins([_REPO_PLUGINS])

# ── État global : un fichier de test ne déteint pas sur le suivant ────
# Beaucoup de tests vident un registre pour y poser leurs fixtures. L'état
# de référence — celui d'après le chargement des plugins du dépôt — est
# photographié ici ; runtests.jl le remet avant chaque fichier
# (`_restore_globals!`), si bien que l'ordre des fichiers ne compte pas et
# qu'un fichier lancé seul part du même point.
const _GLOBAL_REGISTRIES = Any[
    Ressac._DOCS, Ressac._DOC_ALIASES, Ressac._SNIPPETS, Ressac._SNIPPET_RAW,
    Ressac._SAMPLE_REGISTRY, Ressac._INSTRUMENT_REGISTRY, Ressac._SYNTH_REGISTRY,
    Ressac._SYNTH_ALIASES, Ressac._PANE_KINDS, Ressac._SCALES,
    Ressac._SECTION_HANDLERS, Ressac._APP_MUTED_PATTERNS,
]
const _GLOBAL_SNAPSHOT = Any[copy(r) for r in _GLOBAL_REGISTRIES]

_refill!(r::AbstractDict, snap) = (empty!(r); merge!(r, snap))
_refill!(r, snap) = (empty!(r); union!(r, snap))

"Remet un registre global (ou tous) dans l'état de référence."
function _restore_globals!(only = nothing)
    for (r, snap) in zip(_GLOBAL_REGISTRIES, _GLOBAL_SNAPSHOT)
        (only === nothing || r === only) && _refill!(r, snap)
    end
    if only === nothing
        Ressac._LIVE_SCHEDULER[] = nothing
        empty!(Ressac._DRONES); empty!(Ressac._LIVE_OSC_SCOPE_PANES)
        Ressac._PANE_MODE.active = false
        Ressac._JOBS_INLINE[] = true
        Ressac._drain_notices!()
    end
    return nothing
end

"""
    with_clean_registries(f)

Lance `f()` puis remet tous les registres globaux dans l'état de référence,
même si `f` lève. Pour un testset qui vide ou pollue un registre.
"""
function with_clean_registries(f)
    try
        return f()
    finally
        _restore_globals!()
    end
end

# ── Réseau ────────────────────────────────────────────────────────────
# La suite ne sort jamais sur Internet. `_SCCODE_PAGES` sert de faux
# sccode.org : une URL qui n'y est pas répond comme un réseau coupé.
const _SCCODE_PAGES = Dict{String,String}()
Ressac._SCCODE_GET[] = url -> get(() -> error("réseau coupé (tests) : $url"), _SCCODE_PAGES, String(url))

# Les travaux de fond (requêtes, rendus hors-ligne) tournent sur place, dans
# l'ordre : la suite reste déterministe. test_jobs.jl les remet en fond.
Ressac._JOBS_INLINE[] = true

# ── Puits OSC ─────────────────────────────────────────────────────────
# Enregistre chaque paquet que le scheduler envoie : on vérifie comptes et
# contenus sans socket UDP.
mutable struct MockOSCClient
    sent::Vector{Vector{UInt8}}
end
MockOSCClient() = MockOSCClient(Vector{UInt8}[])
Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)

"""
    _with_test_scheduler(f; cps=0.5)

Lance `f(mock, sched)` avec un `MockOSCClient` + `Scheduler` neufs installés
comme session live, et remet `_LIVE_SCHEDULER[]` à `nothing` dans un
`finally`, même si `f` lève.
"""
function _with_test_scheduler(f; cps::Real = 0.5)
    mock = MockOSCClient()
    sched = Ressac.Scheduler(mock; cps = cps)
    Ressac._LIVE_SCHEDULER[] = sched
    try
        f(mock, sched)
    finally
        Ressac._LIVE_SCHEDULER[] = nothing
    end
end

# ── App de test ───────────────────────────────────────────────────────
# La disposition PLAY par défaut ouvre wiki + doc à droite (voir
# `_play_side_panes!`). Les tests de mécanique de panes (split, fermeture,
# zoom, comptage) veulent un point de départ à une seule pane : on replie
# l'arbre sur l'éditeur, explicitement, sans état global partagé.
function _only_patterns!(app)
    ws = Ressac.current_workspace(app.workspaces)
    ws === nothing && return app
    for leaf in Ressac._all_leaves(ws.tree)
        if any(t -> t isa Ressac.EditorPane, leaf.tabs)
            ws.tree = leaf
            ws.focused_pane = leaf.id
            break
        end
    end
    return app
end

# Une app neuve, une frame peinte : l'état côté vue (_last_ws_area, focus,
# rectangles des panes) est rempli, comme après le premier affichage.
function _new_app()
    mock = MockOSCClient()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[],
                            Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    _only_patterns!(app)
    Ressac._PANE_MODE.active = false
    return app, frame
end

# Type a String of plain characters as KeyEvents. Caller is
# responsible for the editor being in insert mode first.
function _type!(app::Ressac.RessacApp, s::AbstractString)
    for c in s
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
end

# Drive an ex command (`:foo bar`) end-to-end through the command bar.
function _exec_ex_command!(app::Ressac.RessacApp, cmd::AbstractString)
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    _type!(app, String(cmd))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:enter))
end

_key!(app, k...) = Tachikoma.update!(app, Tachikoma.KeyEvent(k...))

_mouse!(app, x, y, button = Tachikoma.mouse_left, action = Tachikoma.mouse_press) =
    Tachikoma.update!(app, Tachikoma.MouseEvent(x, y, button, action, false, false, false))

# Le texte du buffer actif, et de quoi le remplacer.
_buffer_text(app) = Tachikoma.text(Ressac._active_editor(app))
function _set_buffer!(app, text::AbstractString; row::Int = 1, col::Int = 0)
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, String(text))
    ed.cursor_row = row; ed.cursor_col = col
    ed.mode = :normal
    return ed
end

# Lance une commande et rend les lignes qu'elle a ajoutées au journal.
function _cmd_logs(app, cmd::AbstractString)
    n = length(app.logs)
    _exec_ex_command!(app, cmd)
    return app.logs[min(n + 1, end):end]
end

end # garde
