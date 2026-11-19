include(joinpath(@__DIR__, "helpers.jl"))
# Le menu Espace hors du code : sa table d'origine dans un fichier, celle du
# joueur par-dessus, et les commandes pour y toucher (roadmap F1).

@testset "menu Espace — la table est une donnée, le joueur a la sienne" begin
    base = Ressac._LEADER_BASE
    @test !isempty(base) && all(s -> !isempty(s.template) && !isempty(s.label) && !isempty(s.column), base)
    @test Ressac._LEADER_SNIPPETS['g'] == "|> gain(\$1)"
    # Chaque touche a une colonne connue : rien ne tombe dans « AUTRES ».
    @test all(c -> get(Ressac._LEADER_COLUMN_OF, string(c), "") in Ressac._LEADER_COLUMN_ORDER, first.(Ressac._LEADER_LABELS))
    # Un fichier mal formé ne coûte que ses mauvaises entrées.
    d = mktempdir()
    bad = joinpath(d, "leader.toml")
    write(bad, "[[snippet]]\nkey = \"xy\"\ntemplate = 'trop long'\n\n[[snippet]]\nkey = \"z\"\ntemplate = '|> crush(\$1)'\n")
    got = @test_logs (:warn, r"entrée ignorée") match_mode = :any Ressac._read_leader_file(bad; column = "À TOI")
    @test length(got) == 1 && got[1].key == 'z' && got[1].column == "À TOI" && got[1].label == "|> crush(\$1)"
    @test isempty(Ressac._read_leader_file(joinpath(d, "absent.toml")))

    _with_live_app() do app, frame
        try
            # Une touche nouvelle : écrite dans le fichier du joueur, liée tout de suite.
            _exec_ex_command!(app, "leader z |> crush(\$1)")
            @test Ressac._LEADER_SNIPPETS['z'] == "|> crush(\$1)"
            @test isfile(Ressac._leader_user_path())
            @test any(b -> b.keys == ["Space z"], Ressac.bindings(:leader))
            @test Ressac._LEADER_COLUMN_OF["z"] == "À TOI"
            _set_buffer!(app, "@d1 p\"bd\"")
            Ressac._patterns_editor(app).cursor_col = 10
            _key!(app, ' '); _key!(app, 'z')
            @test occursin("|> crush(", _buffer_text(app))
            # Reprendre une touche d'origine, puis la rendre.
            _exec_ex_command!(app, "leader g |> gain(0.8)")
            @test Ressac._LEADER_SNIPPETS['g'] == "|> gain(0.8)"
            @test count(b -> b.keys == ["Space g"], Ressac.bindings(:leader)) == 1
            _exec_ex_command!(app, "leader-rm g")
            @test Ressac._LEADER_SNIPPETS['g'] == "|> gain(\$1)"
            # Le fichier se relit tel quel (un redémarrage).
            empty!(Ressac._LEADER_USER); Ressac._leader_rebuild!()
            @test !haskey(Ressac._LEADER_SNIPPETS, 'z')
            @test Ressac._leader_user_load!() == 1 && Ressac._LEADER_SNIPPETS['z'] == "|> crush(\$1)"
            # :leader liste le menu, les touches du joueur marquées.
            @test any(l -> startswith(l, "● z"), Ressac._leader_listing())
            _exec_ex_command!(app, "leader-rm z")
            @test !haskey(Ressac._LEADER_SNIPPETS, 'z')
        finally
            rm(Ressac._leader_user_path(); force = true)
            empty!(Ressac._LEADER_USER); Ressac._leader_rebuild!()
        end
    end
end
