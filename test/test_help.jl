# Aide `?` générée depuis le registre — bout en bout via TK.update!.
using Test
using Ressac
import Tachikoma

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

# Sandbox : :synth / U écrivent dans plugins/user-synths → on travaille
# dans un répertoire temporaire pour ne rien laisser dans le dépôt.
const _HELP_SANDBOX = mktempdir()
mkpath(joinpath(_HELP_SANDBOX, "plugins", "user-synths"))
const _HELP_OLD_PWD = pwd()
cd(_HELP_SANDBOX)

function _help_app()
    sched = Ressac.Scheduler(MockOSCClient(); cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_hkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_hkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_hex(app, cmd) = (_hkey(app, ':'); foreach(c -> _hkey(app, c), cmd); _hkey(app, :enter))
function _screen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end

@testset "help — ? depuis la pane patterns : contexte, toggle, Esc" begin
    app, tb, frame = _help_app()
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :patterns
    @test :leader in app.help_scopes && :global in app.help_scopes
    scr = _screen(app, tb, frame)
    @test occursin("AIDE", scr)
    @test occursin("Pane patterns", scr)
    @test occursin("évaluer la ligne", scr)
    _hkey(app, '?')                                  # toggle
    @test app.modal === :none
    _hkey(app, '?'); _hkey(app, :escape)
    @test app.modal === :none
    _hkey(app, '?'); _hkey(app, 'q')
    @test app.modal === :none
end

@testset "help — :help / :guide / Space ? ouvrent l'aide" begin
    app, tb, frame = _help_app()
    _hex(app, "help");  @test app.modal === :help; _hkey(app, :escape)
    _hex(app, "guide"); @test app.modal === :help; _hkey(app, :escape)
    _hkey(app, ' '); _hkey(app, '?')
    @test app.modal === :help
end

@testset "help — depuis une pane synth, la section synth vient en premier" begin
    app, tb, frame = _help_app()
    _hex(app, "synth kick")
    @test Ressac._focused_role(app) === :synth
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :synth
    @test occursin("tester le synth", _screen(app, tb, frame))
end

@testset "help — depuis une pane non-éditeur (log, explorer) : ? fonctionne" begin
    app, tb, frame = _help_app()
    _hex(app, "vsplit log")
    @test Ressac._focused_role(app) === :other
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :log
    _hkey(app, :escape)
    app2, tb2, frame2 = _help_app()
    _hex(app2, "vsplit explorer")
    _hkey(app2, '?')
    @test app2.modal === :help
    @test app2.help_scopes[1] === :explorer
    scr = _screen(app2, tb2, frame2)
    @test occursin("Explorateur", scr)
    @test occursin("Lecture d'une carte", scr) || app2.modal_scroll == 0   # note de scope présente dans les lignes
    @test any(occursin("Lecture d'une carte", l) for (l, _) in Ressac._help_lines(app2))
end

@testset "help — par-dessus un modal, et retour au modal à la fermeture" begin
    app, tb, frame = _help_app()
    _hex(app, "lib")
    @test app.modal === :synth_library
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :modal_lib
    @test occursin("Librairie de synths", _screen(app, tb, frame))
    _hkey(app, :escape)
    @test app.modal === :synth_library                # restauré
    _hkey(app, :escape)
    @test app.modal === :none
    # browse : ? n'est pas avalé par le filtre texte
    _hex(app, "browse")
    _hkey(app, '?')
    @test app.modal === :help
    @test isempty(app.browser_query)
    _hkey(app, 'q'); @test app.modal === :browse
end

@testset "help — Tab montre toutes les sections, défilement borné" begin
    app, tb, frame = _help_app()
    _hkey(app, '?')
    n_ctx = length(app.help_scopes)
    _hkey(app, :tab)
    @test app.help_expanded
    @test length(app.help_scopes) > n_ctx
    @test :explorer in app.help_scopes && :modal_mixer in app.help_scopes
    last = Ressac._help_last(app)
    _hkey(app, 'G'); @test app.modal_scroll == last
    _hkey(app, 'j'); @test app.modal_scroll == last
    _hkey(app, 'g'); @test app.modal_scroll == 0
    _hkey(app, 'k'); @test app.modal_scroll == 0
    # la référence statique est en queue
    @test any(occursin("MINI-NOTATION", l) for (l, _) in Ressac._help_lines(app))
end

@testset "help — aucun conflit de touches dans le registre" begin
    @test Ressac.keymap_conflicts() == String[]
end

# ── Barre de touches générée ────────────────────────────────────────
function _bottom_bar(app, tb, frame)
    scr = _screen(app, tb, frame)
    rows = split(scr, "\n")
    # la barre est la ligne juste au-dessus de la boîte JOURNAL
    i = findfirst(r -> startswith(r, "╭ JOURNAL"), rows)
    i === nothing ? "" : rows[i - 1]
end

@testset "keybar — suit le focus : patterns, synth, explorer, log" begin
    app, tb, frame = _help_app()
    bar = _bottom_bar(app, tb, frame)
    @test occursin("? aide", bar)
    @test occursin("e évaluer", bar)
    @test occursin("Space snippet", bar)
    _hex(app, "synth kick")
    bar = _bottom_bar(app, tb, frame)
    @test occursin("t tester", bar)
    @test occursin("Tab patterns⟷synth", bar)
    @test !occursin("e évaluer", bar)
    app2, tb2, frame2 = _help_app()
    _hex(app2, "vsplit explorer")
    bar = _bottom_bar(app2, tb2, frame2)
    @test occursin("Space jouer", bar)
    @test occursin("n génération", bar)
    @test occursin("? aide", bar)
end

@testset "keybar — leader Space liste les snippets, mode pane ses touches, insertion" begin
    app, tb, frame = _help_app()
    _hkey(app, ' ')
    @test app.pending_leader
    bar = _bottom_bar(app, tb, frame)
    @test occursin("d slot", bar) && occursin("g gain", bar)
    _hkey(app, :escape)
    @test !app.pending_leader
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    @test Ressac._PANE_MODE.active
    bar = _bottom_bar(app, tb, frame)
    @test occursin("v split vertical", bar)
    _hkey(app, :escape)
    Ressac._PANE_MODE.active = false
    _hkey(app, 'i')
    bar = _bottom_bar(app, tb, frame)
    @test occursin("Esc retour", bar)
    _hkey(app, :escape)
end

@testset "keybar — modal : title_right généré depuis son scope" begin
    app, tb, frame = _help_app()
    _hex(app, "lib")
    scr = _screen(app, tb, frame)
    @test occursin("Space écouter", scr)
    @test occursin("Enter ouvrir", scr)
    @test occursin("? aide", scr)
    _hkey(app, :escape)
    _hex(app, "mixer")
    scr = _screen(app, tb, frame)
    @test occursin("u tout démuter", scr)      # (m mute demande un slot actif)
end

# ── Which-key ─────────────────────────────────────────────────────────
@testset "whichkey — Space : popup immédiat avec les snippets ; Esc le ferme" begin
    app, tb, frame = _help_app()
    scr = _screen(app, tb, frame)
    @test !occursin("Space + …", scr)
    _hkey(app, ' ')
    scr = _screen(app, tb, frame)
    @test occursin("Space + …", scr)
    @test occursin("slot @dN", scr) && occursin("▸ wiki", scr)
    @test app.prefix_kind === :leader
    _hkey(app, :escape)
    scr = _screen(app, tb, frame)
    @test !occursin("Space + …", scr)
    @test app.prefix_kind === :none
end

@testset "whichkey — g et Ctrl-w : après le délai seulement" begin
    app, tb, frame = _help_app()
    _hex(app, "synth kick"); _hex(app, "synth snare")           # deux synths → g t disponible
    _hkey(app, 'g')
    @test Ressac._active_editor(app).pending_key == 'g'
    scr = _screen(app, tb, frame)
    @test !occursin("g + …", scr)                               # trop tôt
    app.prefix_since = time() - 1.0
    scr = _screen(app, tb, frame)
    @test occursin("g + …", scr)
    @test occursin("synth suivant", scr)
    @test occursin("début / fin du buffer", scr)
    _hkey(app, 't')                                             # g t : consomme le préfixe
    @test Ressac._active_editor(app).pending_key === nothing
    @test !occursin("g + …", _screen(app, tb, frame))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    @test !occursin("Ctrl-w + …", _screen(app, tb, frame))
    app.prefix_since = time() - 1.0
    scr = _screen(app, tb, frame)
    @test occursin("Ctrl-w + …", scr) && occursin("split vertical", scr)
    _hkey(app, :escape)
    Ressac._PANE_MODE.active = false
end

@testset "wiki — docs/wiki/04-keys.md est à jour avec le registre" begin
    path = joinpath(@__DIR__, "..", "docs", "wiki", "04-keys.md")
    md = Ressac.keys_wiki_markdown()
    @test startswith(md, "# Touches")
    @test occursin("## Pane patterns", md) && occursin("| `e` | évaluer la ligne |", md)
    @test occursin("## Explorateur de synths (GA)", md)
    if read(path, String) != md
        @test false   # → julia --project=. scripts/gen_keys_wiki.jl
        println("docs/wiki/04-keys.md diverge du registre : lance scripts/gen_keys_wiki.jl")
    else
        @test true
    end
end

# ── Géométrie du chrome ─────────────────────────────────────────────
@testset "chrome — 3 lignes en haut/bas : status, barre de touches, journal 3 lignes" begin
    app, tb, frame = _help_app()
    scr = _screen(app, tb, frame)
    rows = split(scr, "\n")
    @test occursin("RESSAC", rows[1]) && occursin("NORMAL", rows[1]) && occursin("PATTERNS", rows[1])
    @test startswith(rows[40], "╰")                       # dernière ligne = bas du journal
    i = findfirst(r -> startswith(r, "╭ JOURNAL"), rows)
    @test i == 40 - 4                                     # boîte de 5 lignes (3 + bordures)
    @test occursin("? aide", rows[i - 1])                 # barre juste au-dessus
    @test !any(occursin("insert · visual", r) for r in rows)   # plus de mode strip
    # workspaces à droite de la status line
    @test occursin("[1 PLAY]", rows[1])
    # :log replie / déplie
    _hex(app, "log"); rows = split(_screen(app, tb, frame), "\n")
    @test findfirst(r -> startswith(r, "╭ JOURNAL"), rows) == 40 - 11
    _hex(app, "log"); rows = split(_screen(app, tb, frame), "\n")
    @test findfirst(r -> startswith(r, "╭ JOURNAL"), rows) === nothing
    @test occursin("? aide", rows[40])                    # la barre est alors tout en bas
    _hex(app, "log 3")
    @test app.log_tail_rows == 3
end

@testset "chrome — un modal ne recouvre ni la barre de touches ni le journal" begin
    app, tb, frame = _help_app()
    _hex(app, "lib")
    rows = split(_screen(app, tb, frame), "\n")
    i = findfirst(r -> startswith(r, "╭ JOURNAL"), rows)
    @test i == 36
    @test occursin("? aide", rows[35]) && occursin(": commande", rows[35])
    @test startswith(rows[40], "╰")
    @test !any(occursin(": commande─", r) for r in rows)       # plus d'artefact sur la bordure
    @test occursin("LIBRAIRIE", rows[1])                        # surface = modal
    # la barre de commande prend la place de la barre de touches
    _hkey(app, ':')
    rows = split(_screen(app, tb, frame), "\n")
    @test occursin(":", rows[35]) && !occursin("? aide", rows[35])
    _hkey(app, :escape)
end

@testset "chrome — livedoc du mot sous le curseur à droite de la barre" begin
    app, tb, frame = _help_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, "SinOsc.ar(440)")
    ed.cursor_row = 1; ed.cursor_col = 2                       # sur « SinOsc »
    rows = split(_screen(app, tb, frame), "\n")
    i = findfirst(r -> startswith(r, "╭ JOURNAL"), rows)
    @test occursin("✎ SinOsc", rows[i - 1])
    @test occursin("? aide", rows[i - 1])
end

cd(_HELP_OLD_PWD)   # fin du sandbox
