include(joinpath(@__DIR__, "helpers.jl"))
# La DOC d'un son (fiche · explication · graphe) : elle s'ouvre à droite du
# texte et relit le bloc `@synth` du curseur ; persistance de l'écran.
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
const _SW_SRC = "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)"
_swed(app) = Ressac._patterns_editor(app)
_sweditors(app) = [t for l in _swleaves(app) for t in l.tabs if t isa Ressac.EditorPane]
# Le texte principal réduit à un son, le curseur dessus, le clavier dans le texte.
function _sw_sound!(app, text)
    Ressac._focus_patterns!(app)
    ed = _swed(app)
    Tachikoma.set_text!(ed, text); ed.cursor_row = 1; ed.cursor_col = 0; ed.mode = :normal
    return ed
end

@testset "volet du son — la DOC seule, à droite du texte ; elle suit le son du curseur" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "plugins", "user-synths"))
        cd(dir) do
            app, tb, frame = _sw_app()
            patterns = Tachikoma.text(_swed(app))
            _swex(app, "son")
            sdoc = Ressac._sound_doc(app)
            @test sdoc isa Ressac.SynthDocPane && app.volet === :son
            @test Ressac._focused_pane_impl(app) === sdoc
            @test sdoc.mode === :explain                 # un son s'ouvre sur son explication
            # Un seul texte à l'écran : celui des patterns. Le volet n'en a pas, et :son n'y écrit rien.
            @test length(_sweditors(app)) == 1 && all(b -> b.role === :patterns, only(_sweditors(app)).tabs)
            @test Tachikoma.text(_swed(app)) == patterns
            nleaves = length(_swleaves(app))
            scr = _swscreen(app, tb, frame)
            @test occursin("PATTERNS", scr)                                 # les patterns restent à gauche
            @test occursin("doc   explication   graphe", scr)
            @test !occursin("STUDIO", scr) && !occursin("SCULPT", scr)      # plus de studio : le texte est le son
            @test sdoc.genome === nothing                                   # le curseur n'est sur aucun son

            # un son arrive dans le texte : le clavier y va, la DOC le relit
            _swex(app, "synth zorglub")
            @test Ressac._focused_role(app) === :synth && Ressac._current_sound(app).name == "zorglub"
            scr = _swscreen(app, tb, frame)
            @test occursin("SON · zorglub", scr)
            @test sdoc.genome !== nothing && sdoc.synced_name == "zorglub"   # le starter se relit
            @test length(_swleaves(app)) == nleaves && length(_sweditors(app)) == 1
            # un autre son : toujours un seul texte, la DOC suit le curseur
            _swex(app, "synth sketch")
            @test length(_swleaves(app)) == nleaves && length(_sweditors(app)) == 1
            _swscreen(app, tb, frame)
            @test sdoc.synced_name == "sketch"
            ed = _swed(app)
            @test count(l -> occursin(r"^@synth :", String(l)), ed.lines) == 2
            # le rouvrir y ramène le curseur, sans écrire un bloc de plus
            Ressac._open_sound!(app, "zorglub")
            @test count(l -> occursin(r"^@synth :", String(l)), ed.lines) == 2
            @test ed.cursor_row == Ressac._sound_block_named(ed.lines, "zorglub").row
            _swscreen(app, tb, frame)
            @test sdoc.synced_name == "zorglub"
            # sur une ligne de pattern, la DOC garde le dernier son relu
            ed.cursor_row = findfirst(l -> startswith(String(l), "@d1"), ed.lines)
            @test Ressac._current_sound(app) === nothing
            scr = _swscreen(app, tb, frame)
            @test sdoc.synced_name == "zorglub" && occursin("PATTERNS", scr) && !occursin("SON · zorglub", scr)
            # :close (comme :back) rend la colonne à la fiche ; le texte, lui, garde ses sons
            _swex(app, "close")
            @test app.volet === :fiche && Ressac._sound_doc(app) === nothing
            @test count(l -> occursin(r"^@synth :", String(l)), ed.lines) == 2
        end
    end
end

@testset "volet du son — la DOC relit le texte" begin
    app, tb, frame = _sw_app()
    ed = _sw_sound!(app, _SW_SRC)
    _swex(app, "son")
    sdoc = Ressac._sound_doc(app)
    _swscreen(app, tb, frame)
    @test sdoc.genome !== nothing && any(n -> n.ugen === :RLPF, values(sdoc.genome.nodes))
    @test !isempty(sdoc.explain_lines)
    @test sdoc.synced_hash == hash(_SW_SRC) && sdoc.synced_name == "sketch"
    v0 = sdoc.version

    # taper en insertion ne relit pas le texte ; Esc le fait
    Ressac._focus_patterns!(app)
    _swkey(app, 'A')
    @test ed.mode === :insert
    foreach(c -> _swkey(app, c), " |> tanh_drive(2)")
    _swscreen(app, tb, frame)
    @test sdoc.synced_hash == hash(_SW_SRC) && sdoc.version == v0
    _swkey(app, :escape)
    _swscreen(app, tb, frame)
    @test Tachikoma.text(ed) == _SW_SRC * " |> tanh_drive(2)"
    @test sdoc.synced_hash == hash(Tachikoma.text(ed)) && sdoc.version == v0 + 1

    # seul le bloc du son compte : écrire ailleurs dans le texte ne fait rien relire
    v1 = sdoc.version
    Ressac._edit_text!(ed, Tachikoma.text(ed) * "\n\n@d1 p\"bd sn\""; row = 1, col = 0)
    _swscreen(app, tb, frame)
    @test sdoc.version == v1 && sdoc.synced_hash == hash(Ressac._sound_text(Ressac._current_sound(app)))

    # un texte qui ne se relit pas : la DOC le dit, sans rien casser
    _sw_sound!(app, "@synth :sketch (freq=220) saw(:freq) |> ")
    sdoc.mode = :explain
    scr = _swscreen(app, tb, frame)
    @test sdoc.genome === nothing && occursin("le texte ne se relit pas", scr)
    sdoc.mode = :graph
    @test occursin("pas de graphe", _swscreen(app, tb, frame))
    _sw_sound!(app, _SW_SRC)
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
    Ressac._focus_patterns!(app); ed.mode = :normal
    ed.cursor_row = 1; ed.cursor_col = length("@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rl")
    scr = _swscreen(app, tb, frame)
    @test sdoc.doc.name == "dsl:rlpf" && occursin("· rlpf", scr) && occursin("|> rlpf(cutoff, [q])", scr)
end

@testset "volet du son — K / X / Y ouvrent la DOC sans prendre le clavier" begin
    app, tb, frame = _sw_app()
    ed = _sw_sound!(app, _SW_SRC * "\n\n@d1 p\"bd sn\"")
    @test app.volet === :fiche && Ressac._sound_doc(app) === nothing
    ed.cursor_col = length("@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rl")
    _swkey(app, 'X')
    sdoc = Ressac._sound_doc(app)
    @test app.volet === :son && sdoc !== nothing && sdoc.mode === :explain
    @test Ressac._focused_role(app) === :synth                   # le clavier est resté dans le texte
    @test sdoc.genome !== nothing && sdoc.synced_name == "sketch"
    _swkey(app, 'Y'); @test sdoc.mode === :graph && Ressac._focused_role(app) === :synth
    _swkey(app, 'K'); @test sdoc.mode === :doc && Ressac._focused_role(app) === :synth
    scr = _swscreen(app, tb, frame)
    @test sdoc.doc.name == "dsl:rlpf" && occursin("· rlpf", scr)
    # hors d'un son, X ne l'ouvre pas : il n'y a pas de son à expliquer
    _swex(app, "back")
    ed.cursor_row = 3; ed.cursor_col = 0
    @test Ressac._focused_role(app) === :patterns
    _swkey(app, 'X')
    @test app.volet === :fiche && Ressac._sound_doc(app) === nothing
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
    @test kinds == ["editor", "synthdoc"]                                 # le texte, et la DOC du son
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
        ed = _sw_sound!(app, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)")
        _swscreen(app, tb, frame)
        # Y (depuis le texte) ouvre la DOC à droite, sur le graphe
        _swkey(app, 'Y')
        sdoc = Ressac._sound_doc(app)
        @test sdoc !== nothing && sdoc.mode === :graph
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
        Tachikoma.set_text!(ed, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(900, 0.3) |> tanh_drive(2)"); ed.cursor_row = 1
        _swscreen(app, tb, frame)
        @test isempty(sdoc.impacts)
        # une analyse qui échoue : l'explication dit pourquoi
        Ressac._PRUNE_ANALYZE[] = gs -> error("nrt: sclang introuvable")
        Ressac._focus_patterns!(app)
        _swkey(app, 'P')
        @test !sdoc.measuring && isempty(sdoc.impacts) && any(l -> occursin("indisponible", l), sdoc.explain_lines)
    finally
        Ressac._PRUNE_ANALYZE[] = old_an; Ressac._WAVE_SYNC[] = olds
    end
end
