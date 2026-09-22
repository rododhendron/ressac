# Bibliothèque de patterns : ranger, retrouver, recharger sur un slot.
using Test
using Ressac
using Tachikoma

if !@isdefined(_PlMock)
    mutable struct _PlMock
        sent::Vector{Vector{UInt8}}
    end
    _PlMock() = _PlMock(Vector{UInt8}[])
    Ressac.send_osc(c::_PlMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _pl_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_PlMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(140, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_plkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_plkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_plex(app, cmd) = (_plkey(app, ':'); foreach(c -> _plkey(app, c), cmd); _plkey(app, :enter))
function _plscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end

@testset "bibliothèque de patterns — stockage sur disque" begin
    mktempdir() do dir
        cd(dir) do
            @test isempty(list_patterns())
            @test load_pattern("rien") === nothing
            @test delete_pattern!("rien") == false
            e = save_pattern!("jersey", "@d1 p\"bd(3,8)\" |> gain(0.9)"; tags = ["jersey", "kick"])
            @test e.name == "jersey" && e.tags == ["jersey", "kick"]
            @test isfile(e.path)
            back = load_pattern("jersey")
            @test back !== nothing
            @test back.code == "@d1 p\"bd(3,8)\" |> gain(0.9)"
            @test back.tags == ["jersey", "kick"]
            # un bloc multi-lignes garde ses lignes
            save_pattern!("longue", "@d2 p\"hh*8\"\n  |> gain(0.4)\n  |> pan(0.3)")
            @test occursin("|> pan(0.3)", load_pattern("longue").code)
            @test [x.name for x in list_patterns()] == ["jersey", "longue"]
            # le nom de fichier est assaini, le nom affiché reste entier
            save_pattern!("mon rythme/2", "@d3 p\"cp\"")
            @test load_pattern("mon rythme/2") !== nothing
            @test load_pattern("mon rythme/2").name == "mon rythme/2"
            # écrasement
            save_pattern!("jersey", "@d1 p\"bd*4\"")
            @test load_pattern("jersey").code == "@d1 p\"bd*4\""
            @test length(list_patterns()) == 3
            @test delete_pattern!("jersey") && load_pattern("jersey") === nothing
            @test_throws ArgumentError save_pattern!("", "@d1 p\"bd\"")
            @test_throws ArgumentError save_pattern!("vide", "   ")
        end
    end
end

@testset "retarget_pattern / pattern_slot" begin
    @test pattern_slot("@d3 p\"bd\"") == 3
    @test pattern_slot("  @d12 p\"bd\"") == 12
    @test pattern_slot("basse = p\"bd\"") === nothing
    @test retarget_pattern("@d1 p\"bd\" |> gain(1)", 7) == "@d7 p\"bd\" |> gain(1)"
    @test retarget_pattern("  @d1 p\"bd\"", 2) == "  @d2 p\"bd\""
    @test retarget_pattern("basse = p\"bd\"", 2) == "basse = p\"bd\""   # pas un slot : inchangé
    @test retarget_pattern("@d1 p\"bd\"\n  |> gain(1)", 4) == "@d4 p\"bd\"\n  |> gain(1)"
    @test_throws ArgumentError retarget_pattern("@d1 p\"bd\"", 0)
end

@testset ":save / :load / Espace P dans la TUI" begin
    mktempdir() do dir
        cd(dir) do
            app, tb, frame = _pl_app()
            old = Ressac._LIVE_SCHEDULER[]
            Ressac._LIVE_SCHEDULER[] = app.scheduler
            try
                ed = Ressac._active_editor(app)
                Tachikoma.set_text!(ed, "@d1 p\"bd(3,8)\"\n  |> gain(0.9)\n\n@d2 p\"hh*8\"")
                ed.cursor_row = 1; ed.cursor_col = 0
                _plex(app, "keep jersey kick")
                e = load_pattern("jersey")
                @test e !== nothing
                @test e.code == "@d1 p\"bd(3,8)\"\n  |> gain(0.9)"    # le bloc entier
                @test e.tags == ["kick"]
                @test occursin("rangé", app.logs[end])
                # :save sans nom explique, ne range rien
                _plex(app, "keep")
                @test occursin(":keep <nom>", app.logs[end])
                # recharge sur un autre slot : le bloc est ajouté
                _plex(app, "recall jersey 5")
                txt = Tachikoma.text(ed)
                @test occursin("@d5 p\"bd(3,8)\"", txt) && occursin("@d1 p\"bd(3,8)\"", txt)
                @test haskey(app.scheduler.patterns, :d5)
                # recharger sur un slot déjà écrit remplace son bloc
                _plex(app, "recall jersey 2")
                txt = Tachikoma.text(ed)
                @test occursin("@d2 p\"bd(3,8)\"", txt) && !occursin("@d2 p\"hh*8\"", txt)
                @test count("bd(3,8)", txt) == 3
                _plex(app, "recall inconnu")
                @test occursin("pas de pattern", app.logs[end])

                # le sélecteur : Espace P, recherche, chargement au clavier
                save_pattern!("hats", "@d3 p\"hh*16\" |> gain(0.3)"; tags = ["hh"])
                _plkey(app, ' '); _plkey(app, 'P')
                @test app.modal === :patterns
                scr = _plscreen(app, tb, frame)
                @test occursin("PATTERNS RANGÉS", scr) && occursin("jersey", scr) && occursin("hats", scr)
                @test occursin("bd(3,8)", scr)                  # aperçu du code sélectionné
                @test length(Ressac._pattern_entries(app)) == 2
                _plkey(app, '/'); _plkey(app, 'h'); _plkey(app, 'a')
                @test app.pat_query == "ha"
                @test [x.name for x in Ressac._pattern_entries(app)] == ["hats"]
                _plkey(app, :enter)                              # valide la recherche
                @test !app.pat_search_mode
                _plkey(app, '7')                                 # charge sur d7
                @test app.modal === :none
                @test occursin("@d7 p\"hh*16\"", Tachikoma.text(ed))
                @test haskey(app.scheduler.patterns, :d7)
                # suppression depuis le sélecteur
                _plkey(app, ' '); _plkey(app, 'P')
                app.pat_cursor = 1
                _plkey(app, 'x')
                @test length(list_patterns()) == 1
                _plkey(app, :escape)
                @test app.modal === :none
            finally
                Ressac._LIVE_SCHEDULER[] = old
            end
        end
    end
end
