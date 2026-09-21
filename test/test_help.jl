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
    @test occursin("Tab patterns⟷synth", bar)              # PLAY : patterns + synth présents
    _hex(app, "design")                                      # DESIGN : pas de pane patterns
    bar = _bottom_bar(app, tb, frame)
    @test occursin("t tester", bar)
    @test !occursin("Tab patterns", bar)
    _hex(app, "play")
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
    @test occursin("1 PLAY", rows[1])
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

# ── Look : bandeaux, pastilles, cadres arrondis colorés par le mode ──────
_cell(tb, x, y) = tb.buf.content[(y - 1) * tb.buf.area.width + x]
# Colonne (en caractères) d'une sous-chaîne dans une ligne rendue — findfirst
# renvoie des offsets en OCTETS, faux dès qu'il y a un ♪ ou un ─ avant.
_col(row, needle) = length(row[1:prevind(row, findfirst(needle, row).start)]) + 1

@testset "look — status line et barre de touches sont des bandeaux pleins avec pastilles" begin
    app, tb, frame = _help_app()
    _screen(app, tb, frame)
    th = Tachikoma.theme()
    @test _cell(tb, 60, 1).style.bg == th.border            # bandeau du haut
    @test _cell(tb, 2, 1).style.bg == th.accent             # pastille RESSAC
    rows = split(join((Tachikoma.row_text(tb, y) for y in 1:40), "\n"), "\n")
    ky = findfirst(r -> startswith(r, "╭ JOURNAL"), rows) - 1
    @test _cell(tb, 40, ky).style.bg == th.border           # bandeau du bas
    x_aide = _col(rows[ky], "? aide")
    @test _cell(tb, x_aide, ky).style.bg == th.accent       # pastille ? aide
    # badge de mode : NORMAL en pastille de la couleur du mode (primary)
    x_mode = _col(rows[1], "NORMAL")
    @test _cell(tb, x_mode, 1).style.bg == th.primary
    _hkey(app, 'i'); _screen(app, tb, frame)
    rows = split(join((Tachikoma.row_text(tb, y) for y in 1:40), "\n"), "\n")
    x_mode = _col(rows[1], "INSERTION")
    @test _cell(tb, x_mode, 1).style.bg == th.success
    _hkey(app, :escape)
end

@testset "look — pane focalisée : cadre arrondi couleur du mode, titre en pastille ; autres atténuées" begin
    app, tb, frame = _help_app()
    _screen(app, tb, frame)
    th = Tachikoma.theme()
    @test _cell(tb, 1, 2).char == '╭'
    @test _cell(tb, 1, 2).style.fg == th.primary            # bordure = couleur du mode normal
    @test _cell(tb, 4, 2).style.bg == th.primary            # titre PATTERNS en pastille
    _hex(app, "vsplit log")                                  # focus → JOURNAL
    _screen(app, tb, frame)
    @test _cell(tb, 4, 2).style.bg isa Tachikoma.NoColor    # PATTERNS n'est plus focalisée
    @test _cell(tb, 1, 2).style.fg == th.border
    rows = split(join((Tachikoma.row_text(tb, y) for y in 1:40), "\n"), "\n")
    xj = _col(rows[2], "JOURNAL")
    @test _cell(tb, xj, 2).style.bg == th.primary           # le journal focalisé a la pastille
end

# ── Boutons : barre de touches, status line, cadre des panes ────────────
_click(app, x, y) = Tachikoma.update!(app, Tachikoma.MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))

@testset "boutons — la barre de touches est cliquable (touche = action), ? aide aussi" begin
    app, tb, frame = _help_app()
    rows = split(_screen(app, tb, frame), "\n")
    ky = findfirst(r -> startswith(r, "╭ JOURNAL"), rows) - 1
    _click(app, _col(rows[ky], "Space snippet"), ky)
    @test app.pending_leader                                # « Space snippet… » = Space
    _hkey(app, :escape)
    _click(app, _col(rows[ky], "? aide"), ky)
    @test app.modal === :help
    # sous le modal, la barre montre ses raccourcis : « ? fermer » referme
    rows = split(_screen(app, tb, frame), "\n")
    _click(app, _col(rows[ky], ": commande"), ky)
    @test Ressac.is_active(app.command_line)
    _hkey(app, :escape)
    _hkey(app, :escape)
    @test app.modal === :none
end

@testset "boutons — pastilles de workspaces et RESSAC dans la status line" begin
    app, tb, frame = _help_app()
    rows = split(_screen(app, tb, frame), "\n")
    _click(app, _col(rows[1], "2 DESIGN"), 1)
    @test Ressac.current_workspace(app.workspaces).name == "DESIGN"
    @test Ressac._focused_role(app) === :synth               # rempli à la visite
    _click(app, _col(rows[1], "1 PLAY"), 1)
    @test Ressac.current_workspace(app.workspaces).name == "PLAY"
    _click(app, 3, 1)                                        # pastille RESSAC
    @test app.modal === :help
    _hkey(app, :escape)
end

@testset "boutons — ⊞ ⊟ ⤢ ✕ sur le cadre de la pane focalisée" begin
    app, tb, frame = _help_app()
    rows = split(_screen(app, tb, frame), "\n")
    @test occursin("⊞", rows[2]) && occursin("✕", rows[2])
    ws = Ressac.current_workspace(app.workspaces)
    n0 = length(collect(Ressac._all_leaves(ws.tree)))
    _click(app, _col(rows[2], "⊞"), 2)                      # split vertical
    @test length(collect(Ressac._all_leaves(ws.tree))) == n0 + 1
    rows = split(_screen(app, tb, frame), "\n")
    # la nouvelle pane (à droite) est focalisée : son ⤢ zoome
    xz = _col(rows[2], "⤢"); xz2 = findlast("⤢", rows[2])
    x_last = length(rows[2][1:prevind(rows[2], xz2.start)]) + 1
    _click(app, x_last, 2)
    @test app.zoom_leaf == ws.focused_pane
    _click(app, x_last, 2); @test app.zoom_leaf == 0        # re-clic dézoome
    rows = split(_screen(app, tb, frame), "\n")
    xc = findlast("✕", rows[2]); x_close = length(rows[2][1:prevind(rows[2], xc.start)]) + 1
    _click(app, x_close, 2)                                  # ferme la pane focalisée
    @test length(collect(Ressac._all_leaves(ws.tree))) == n0
end

# ── Wiki : le style « bloc de code » survit au défilement ; livedoc englobante ──
@testset "wiki — une ligne de bloc de code reste stylée quand la clôture est hors écran" begin
    app, tb, frame = _help_app()
    _hex(app, "wiki")
    # une page avec un bloc de code (l'intro n'en a plus)
    pi = findfirst(pg -> any(l -> startswith(strip(l), "```"), pg.lines), app.wiki_pages)
    @test pi !== nothing
    app.wiki_idx = pi
    page = app.wiki_pages[pi]
    fence = findfirst(l -> startswith(strip(l), "```"), page.lines)
    app.wiki_scroll = fence                                  # 1re ligne visible = dans le bloc
    _screen(app, tb, frame)
    rows = split(join((Tachikoma.row_text(tb, y) for y in 1:40), "\n"), "\n")
    y = findfirst(r -> occursin("WIKI ·", r), rows) + 1
    # colonnes des « │ » : bordure de pane, bord du modal, séparateur TOC, …
    bars = [i for i in 1:120 if _cell(tb, i, y).char == '│']
    @test length(bars) >= 3
    x = bars[3] + 2                                          # début de la colonne contenu
    xs = [i for i in x:min(bars[4] - 1, 120) if _cell(tb, i, y).char != ' ']
    @test !isempty(xs)
    @test _cell(tb, xs[1], y).style.fg == Tachikoma.tstyle(:primary).fg
    _hkey(app, :escape)
end

@testset "livedoc — dans les parenthèses d'un appel, la doc de l'appel reste affichée" begin
    app, tb, frame = _help_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, "SinOsc.ar(440, 0)")
    ed.cursor_row = 1; ed.cursor_col = 11                    # sur « 440 »
    ld = Ressac._livedoc_under_cursor(app)
    @test ld !== nothing && ld[1] == "SinOsc"
    ed.cursor_col = 15                                       # sur « 0 »
    @test Ressac._livedoc_under_cursor(app)[1] == "SinOsc"
    Tachikoma.set_text!(ed, "x = 42"); ed.cursor_col = 5
    @test Ressac._livedoc_under_cursor(app) === nothing
end

# ── Snippet Espace : on reste en mode normal, Tab saute entre les trous ──
@testset "snippet — Space d laisse en mode normal ; Tab / i / Esc" begin
    app, tb, frame = _help_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, ""); ed.cursor_row = 1; ed.cursor_col = 0
    _hkey(app, ' '); _hkey(app, 'd')
    @test ed.mode === :normal
    @test app.placeholder_active && app.placeholder_idx == 1
    @test occursin("@d", Tachikoma.text(ed))
    c1 = ed.cursor_col
    _hkey(app, :tab)                                   # trou suivant, toujours en normal
    @test app.placeholder_idx == 2 && ed.cursor_col > c1 && ed.mode === :normal
    _hkey(app, :backtab)
    @test app.placeholder_idx == 1
    _hkey(app, 'i')                                    # remplir
    @test ed.mode === :insert
    _hkey(app, '3')
    @test occursin("@d3", Tachikoma.text(ed))
    _hkey(app, :escape)
    @test ed.mode === :normal && app.placeholder_active
    _hkey(app, :escape)                                # sort des trous
    @test !app.placeholder_active
end
