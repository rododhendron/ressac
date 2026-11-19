include(joinpath(@__DIR__, "helpers.jl"))
# shared(x) : lire deux fois le MÊME signal (roadmap F5).

@testset "shared — une variable, déclarée une fois" begin
    D = Ressac.SynthDSL
    b = D.shared(D.white())
    sig = D.low_pass(b, 400) + D.high_pass(b, 4000)
    sc = D.build_synth(:pluie, sig)
    @test count("WhiteNoise.ar", sc) == 1                       # un seul bruit
    @test occursin(Regex("var $(b.code) = WhiteNoise\\.ar;"), sc)
    @test count(b.code, sc) == 3                                # sa déclaration et ses deux lectures
    # La déclaration précède la sortie (SuperCollider veut ses `var` en tête).
    @test findfirst("var $(b.code)", sc).start < findfirst("OffsetOut", sc).start
    # Sans shared : deux bruits, et pas de variable.
    plain = D.build_synth(:pluie2, D.low_pass(D.white(), 400) + D.high_pass(D.white(), 4000))
    @test count("WhiteNoise.ar", plain) == 2 && !occursin("var sh_", plain)
    # Le même texte partagé deux fois est le même signal ; un autre texte, un autre.
    @test D.shared(D.white()).code == b.code
    @test D.shared(D.pink()).code != b.code
    # Un signal partagé qui en lit un autre : les dépendances sont déclarées d'abord.
    c = D.shared(D.low_pass(b, 800))
    sc2 = D.build_synth(:pluie3, c + c)
    @test findfirst("var $(b.code)", sc2).start < findfirst("var $(c.code)", sc2).start
    @test count("WhiteNoise.ar", sc2) == 1 && count("LPF.ar", sc2) == 1
    # L'analyse lit la structure : le texte se relit en génome.
    src = "@synth :pluie (sustain=2) begin\n    b = shared(white())\n    (b |> low_pass(400)) + (b |> high_pass(4000))\nend\n"
    (g, why) = Ressac.parse_dsl_synth(src)
    @test g !== nothing
    @test count(n -> n.ugen === :WhiteNoise, values(g.nodes)) >= 1
    ex = D._shared_expand(sig.code)
    @test !occursin("sh_", ex) && count("WhiteNoise.ar", ex) == 2   # pour l'analyse : la structure, dépliée
end

@testset "shared — :prune ne réécrit pas un son qui en lit un" begin
    old = pwd(); d = mktempdir(); mkpath(joinpath(d, "plugins", "user-synths")); cd(d)
    try
        (app, _) = _new_app()
        _exec_ex_command!(app, "synth pluie")
        (ep, _) = Ressac._synth_workspace_parts(app)
        ed = ep.tabs[ep.current_tab].code_editor
        src = "@synth :pluie (sustain=2) begin\n    b = shared(white())\n    (b |> low_pass(400)) + (b |> high_pass(4000))\nend\n"
        Tachikoma.set_text!(ed, src)
        _exec_ex_command!(app, "prune")
        @test Tachikoma.text(ed) == src
        @test any(l -> occursin("signal partagé", l), app.logs)
    finally
        cd(old)
    end
end
