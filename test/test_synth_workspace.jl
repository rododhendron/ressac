include(joinpath(@__DIR__, "helpers.jl"))
# Le volet d'un son : son texte et, dessous, sa DOC (fiche · explication ·
# graphe) qui relit le texte ; onglets de synths, persistance.
using Test
using Ressac
using Tachikoma

if !@isdefined(_SWMock)
    mutable struct _SWMock
        sent::Vector{Vector{UInt8}}
    end
    _SWMock() = _SWMock(Vector{UInt8}[])
    Ressac.send_osc(c::_SWMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _sw_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_SWMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(160, 44)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 160, 44),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    return app, tb, frame
end
_swkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_swkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_swex(app, cmd) = (_swkey(app, ':'); foreach(c -> _swkey(app, c), cmd); _swkey(app, :enter))
function _swscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:44), "\n")
end
_swleaves(app) = Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)
const _SW_SRC = "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)\n"

@testset "volet du son — le texte, et dessous sa DOC ; un synth = un onglet" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "plugins", "user-synths"))
        cd(dir) do
            app, tb, frame = _sw_app()
            _swex(app, "son")
            @test length(_swleaves(app)) == 3                               # patterns, texte du son, DOC
            parts = Ressac._synth_workspace_parts(app)
            @test parts !== nothing
            (ep, sdoc) = parts
            @test sdoc.mode === :explain                 # un son s'ouvre sur son explication
            @test Ressac._focused_role(app) === :synth
            scr = _swscreen(app, tb, frame)
            @test occursin("SYNTH · sketch", scr)
            @test occursin("PATTERNS", scr)                                 # les patterns restent à gauche
            @test occursin("doc   explication   graphe", scr)
            @test !occursin("STUDIO", scr) && !occursin("SCULPT", scr)      # plus de studio : le texte est le son
            @test sdoc.genome !== nothing && sdoc.synced_name == "sketch"   # le starter se relit

            # un autre synth : un onglet de plus, toujours 3 panes, la DOC suit
            _swex(app, "synth zorglub")
            @test length(_swleaves(app)) == 3
            @test length(ep.tabs) == 2 && ep.tabs[ep.current_tab].name == "zorglub"
            _swscreen(app, tb, frame)
            @test sdoc.synced_name == "zorglub"
            # le rouvrir focalise l'onglet, sans en créer un autre
            ep.current_tab = 1
            Ressac._open_synth_tab!(app, "zorglub")
            @test length(ep.tabs) == 2 && ep.current_tab == 2
            # g t tourne dans les onglets
            Ressac._cycle_synth_tab!(app)
            @test ep.current_tab == 1
            _swscreen(app, tb, frame)
            @test sdoc.synced_name == "sketch"

            # fermer l'onglet courant garde la pane ; le dernier laisse un sketch neuf
            Ressac._close_active_synth_tab!(app)
            @test length(ep.tabs) == 1 && ep.tabs[1].name == "zorglub" && length(_swleaves(app)) == 3
            Ressac._close_active_synth_tab!(app)
            @test length(ep.tabs) == 1 && ep.tabs[1].name == "sketch" && length(_swleaves(app)) == 3
            @test occursin("@synth :sketch", Tachikoma.text(ep.tabs[1].code_editor))
        end
    end
end

@testset "volet du son — la DOC relit le texte" begin
    app, tb, frame = _sw_app()
    _swex(app, "son")
    (ep, sdoc) = Ressac._synth_workspace_parts(app)
    tab = ep.tabs[1]; ed = tab.code_editor
    Tachikoma.set_text!(ed, _SW_SRC); ed.mode = :normal
    _swscreen(app, tb, frame)
    @test sdoc.genome !== nothing && any(n -> n.ugen === :RLPF, values(sdoc.genome.nodes))
    @test !isempty(sdoc.explain_lines)
    @test sdoc.synced_hash == hash(_SW_SRC)
    v0 = sdoc.version

    # taper en insertion ne relit pas le texte ; Esc le fait
    _swkey(app, 'G'); _swkey(app, 'o')
    @test ed.mode === :insert
    foreach(c -> _swkey(app, c), "# note")
    _swscreen(app, tb, frame)
    @test sdoc.synced_hash == hash(_SW_SRC) && sdoc.version == v0
    _swkey(app, :escape)
    _swscreen(app, tb, frame)
    @test sdoc.synced_hash == hash(Tachikoma.text(ed)) && sdoc.version == v0 + 1

    # un texte qui ne se relit pas : la DOC le dit, sans rien casser
    Tachikoma.set_text!(ed, "@synth :sketch (freq=220) saw(:freq) |> ")
    sdoc.mode = :explain
    scr = _swscreen(app, tb, frame)
    @test sdoc.genome === nothing && occursin("le texte ne se relit pas", scr)
    sdoc.mode = :graph
    @test occursin("pas de graphe", _swscreen(app, tb, frame))
    Tachikoma.set_text!(ed, _SW_SRC)
    _swscreen(app, tb, frame)
    @test sdoc.genome !== nothing

    # :explain bascule la DOC sur l'explication et y amène le clavier ; ← → tournent
    sdoc.mode = :doc
    _swex(app, "explain")
    @test sdoc.mode === :explain && Ressac._focused_pane_impl(app) === sdoc
    scr = _swscreen(app, tb, frame)
    @test occursin("doc   explication   graphe", scr) && occursin("source", scr)
    _swkey(app, :right)
    @test sdoc.mode === :graph
    _swkey(app, :right)
    @test sdoc.mode === :doc
    _swkey(app, :left); _swkey(app, :left)
    @test sdoc.mode === :explain
    # :sculpt n'existe plus
    _swex(app, "sculpt")
    @test occursin("commande inconnue", app.logs[end])

    # la doc vivante suit le curseur du texte, dans la vue doc
    sdoc.mode = :doc
    Ressac._focus_pane!(app, ep); ed.mode = :normal
    ed.cursor_row = 1; ed.cursor_col = length("@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rl")
    scr = _swscreen(app, tb, frame)
    @test sdoc.doc.name == "rlpf" && occursin("· rlpf", scr)
end

@testset "volet du son — sauvé avec la disposition" begin
    app, tb, frame = _sw_app()
    _swex(app, "son")
    _swscreen(app, tb, frame)
    path = joinpath(mktempdir(), "layout.toml")
    Ressac.save_layout(app.workspaces, path)
    wm = Ressac.WorkspaceManager()
    Ressac.load_layout!(wm, path)
    design = only(wm.workspaces)
    kinds = sort([Ressac._kind_for(t) for leaf in Ressac._all_leaves(design.tree) for t in leaf.tabs])
    @test kinds == ["editor", "editor", "synthdoc"]                       # patterns, texte du son, DOC
    # Une disposition d'avant (avec un studio) se recharge : il redevient une simple onde.
    old = Ressac._pane_new(:waveform, Dict{String,Any}("label" => "sketch", "sculpt" => true, "linked" => true))
    @test old isa Ressac.WaveformPane && old.label == "sketch"
end

@testset "DSL — le pipe diffusé .|> entre en premier argument" begin
    S = Ressac.SynthDSL
    @test S._elixir_pipes(:([a, b] .|> env_linen(0.01, :sustain, 0.1))) == :(env_linen.([a, b], 0.01, :sustain, 0.1))
    @test S._elixir_pipes(:(xs .|> sin_osc)) == :(sin_osc.(xs))
    @test S._elixir_pipes(:(xs .|> amp(_, 0.5))) == :(amp.(xs, 0.5))
    v = Core.eval(S, S._elixir_pipes(:([sin_osc(:freq), sin_osc(:freq + 1)] .|> env_linen(0.01, :sustain, 0.1))))
    @test v isa Vector{S.Sig} && length(v) == 2 && occursin("Env.linen", v[1].code)
end

@testset "graphe — boîtes, lignes, marques" begin
    g = Ressac.genome_from_dsl("@synth :acid (freq=60, sustain=0.3) saw(:freq) |> rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)")
    boxes = Ressac.graph_boxes(g)
    chain = [b for b in boxes if b.depth == 0]
    @test [b.label for b in chain] == ["Saw", "RLPF", "MulAdd", "Tanh"]
    @test [b.role for b in chain] == [:matière, :corps, :mélange, :grain]
    @test [b.col for b in chain] == [1, 2, 3, 4]
    line = only(b for b in boxes if b.label == "Line")
    @test line.depth == 1 && line.col == 2 && line.edge == "freq" && line.role in (:mouvement, :enveloppe)
    @test line.sub == "3000 500 :sus…"
    saw = chain[1]
    @test saw.sub == ":freq"
    lines, ids = Ressac.graph_lines(g; focus = chain[2].id)
    txt = [join(sp.content for sp in l) for l in lines]
    @test any(l -> occursin("──▶ ◉ out", l), txt)
    @test any(l -> occursin("┃ freq", l), txt)
    @test any(l -> occursin("┏", l) && occursin("┓", l), txt)          # le nœud focalisé en trait épais
    @test any(l -> occursin("│ Saw", l), txt) && any(l -> occursin("┃ RLPF", l), txt)
    @test occursin("matière", txt[1]) && occursin("sortie", txt[1])
    @test ids[1] == saw.id && length(ids) == 5
    # ✂ sur un nœud signalé par l'élagage
    lines2, _ = Ressac.graph_lines(g; hints = Dict(chain[3].id => "×1"))
    @test any(l -> occursin("MulAdd ✂", join(sp.content for sp in l)), lines2)
    # défilement horizontal : la ligne perd ses premières colonnes
    shifted = Ressac._graph_shift(lines[2], 5)
    @test join(sp.content for sp in shifted) == String(collect(join(sp.content for sp in lines[2]))[6:end])
end

@testset "graphe — la vue de la DOC, navigation, P et les ✂" begin
    old_an = Ressac._PRUNE_ANALYZE[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _sw_app()
        _swex(app, "son")
        (ep, sdoc) = Ressac._synth_workspace_parts(app)
        ed = ep.tabs[1].code_editor
        Tachikoma.set_text!(ed, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)\n"); ed.mode = :normal
        _swscreen(app, tb, frame)
        # Y (depuis le texte) met la DOC sur le graphe
        _swkey(app, 'Y')
        @test sdoc.mode === :graph
        scr = _swscreen(app, tb, frame)
        @test occursin("doc   explication   graphe", scr)
        @test occursin("◉ out", scr) && occursin("RLPF", scr)
        @test !isempty(sdoc.graph_ids)
        # dans la DOC, h / l passent d'une boîte à l'autre
        Ressac._focus_pane!(app, sdoc)
        sdoc.graph_focus = sdoc.graph_ids[1]
        _swkey(app, 'l')
        @test sdoc.graph_focus == sdoc.graph_ids[2]
        _swkey(app, 'h')
        @test sdoc.graph_focus == sdoc.graph_ids[1]
        # [ ] défilent
        _swkey(app, ']'); @test sdoc.graph_x == 8
        _swkey(app, '['); @test sdoc.graph_x == 0
        # P mesure ce que chaque étape change : l'explication le dit
        Ressac._PRUNE_ANALYZE[] = gs -> [fill(i == 1 ? 1.0 : 0.5, 8) for i in eachindex(gs)]
        _swkey(app, 'P')
        @test sdoc.mode === :explain && !sdoc.measuring
        @test !isempty(sdoc.impacts) && any(l -> occursin("impact", l), sdoc.explain_lines)
        # changer le texte périme la mesure
        Tachikoma.set_text!(ed, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(900, 0.3) |> tanh_drive(2)\n")
        _swscreen(app, tb, frame)
        @test isempty(sdoc.impacts)
        # une analyse qui échoue : l'explication dit pourquoi
        Ressac._PRUNE_ANALYZE[] = gs -> error("nrt: sclang introuvable")
        Ressac._focus_pane!(app, ep)
        _swkey(app, 'P')
        @test !sdoc.measuring && isempty(sdoc.impacts) && any(l -> occursin("indisponible", l), sdoc.explain_lines)
    finally
        Ressac._PRUNE_ANALYZE[] = old_an; Ressac._WAVE_SYNC[] = olds
    end
end
