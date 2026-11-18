include(joinpath(@__DIR__, "helpers.jl"))
# Poser un exemple du wiki dans ses patterns — étape E2.6b.

const _WX_PAGE = String[
    "# Une page", "", "Du texte, avec `@d1 en ligne` qui n'est pas un exemple.", "",
    "```julia", "@d1 p\"bd*4\"", "x = 3", "@d2 :wob", "  |> n(\"0 3 7\")", "# @d3 p\"coupé\"", "```", "",
    "Et encore.", "", "```", "@d1 p\"hh*8\" |> gain(0.6)", "```",
]

@testset "exemples du wiki" begin
    @testset "les exemples d'une page : les @dN des blocs de code, avec leurs suites" begin
        ex = Ressac._wiki_examples(_WX_PAGE)
        @test ex == ["@d1 p\"bd*4\"", "@d2 :wob\n  |> n(\"0 3 7\")", "@d1 p\"hh*8\" |> gain(0.6)"]
        @test isempty(Ressac._wiki_examples(["pas de code", "@d1 hors d'un bloc"]))
    end

    @testset "Tab désigne, Entrée pose sur un slot libre" begin
        _with_live_app() do app, frame
            _set_buffer!(app, "@d1 p\"bd\"\n@d2 p\"sn\"\n")
            _exec_ex_command!(app, "wiki")
            w = Ressac._find_pane(app, Ressac.WikiPane)
            w.pages = [Ressac._WikiPage("t.md", "Essai", _WX_PAGE)]; w.idx = 1; w.example = 0; w.rendered = (0, 0, 0)
            Ressac._focus_pane!(app, w)
            buf = frame.buffer
            screen() = (Tachikoma.view(app, frame); join((join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:buf.area.height), "\n"))
            @test occursin("Tab : 3 ex.", screen())
            _key!(app, :enter)                                   # rien de désigné : rien ne se pose
            @test _buffer_text(app) == "@d1 p\"bd\"\n@d2 p\"sn\"\n"
            _key!(app, :tab)
            @test w.example == 1 && occursin("ex. 1/3", screen())
            _key!(app, :tab)
            @test w.example == 2
            _key!(app, :enter)
            @test _buffer_text(app) == "@d1 p\"bd\"\n@d2 p\"sn\"\n\n@d3 :wob\n  |> n(\"0 3 7\")"   # le slot libre, les deux lignes
            @test occursin("exemple posé sur d3", app.logs[end])
            @test Ressac._patterns_editor(app).cursor_row == 4
            @test Ressac._focused_pane_impl(app) === w           # on reste dans le wiki
            @test Ressac.pattern_get(app.scheduler, :d3) === nothing   # posé, pas lancé
            _key!(app, 'e')                                      # e, depuis le wiki, lance la ligne posée
            @test Ressac.pattern_get(app.scheduler, :d3) !== nothing
            # S-Tab revient, et tourne ; changer de page oublie l'exemple
            _key!(app, :backtab); @test w.example == 1
            _key!(app, :backtab); @test w.example == 3
            _key!(app, :enter)
            @test endswith(_buffer_text(app), "\n\n@d4 p\"hh*8\" |> gain(0.6)")
            Ressac._wiki_show!(w, 1); @test w.example == 0
        end
    end
end
