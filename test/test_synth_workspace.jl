# Workspace synth (DESIGN) : forme fixe texte | studio / doc, onglets de
# synths, synchronisation texte ⟷ studio, doc à onglets, persistance.
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

@testset "workspace synth — nombres sur place (_patch_literal)" begin
    @test Ressac._patch_literal("freq=220, cut=800", 220.0, 226.443) == "freq=226.443, cut=800"
    @test Ressac._patch_literal("rlpf(800.0, 0.3)", 800.0, 900.0) == "rlpf(900, 0.3)"
    @test Ressac._patch_literal("a=0.5 b=0.5", 0.5, 0.6) === nothing          # ambigu
    @test Ressac._patch_literal("a=1200 b=200", 200.0, 210.0) == "a=1200 b=210"  # pas dans 1200
    @test Ressac._patch_literal("pan=-0.5", -0.5, 0.25) == "pan=0.25"
    @test Ressac._patch_literal("x=3", 4.0, 5.0) === nothing
    @test Ressac._fmt_literal(64.0) == "64" && Ressac._fmt_literal(63.5) == "63.5"
end

@testset "workspace synth — DESIGN ouvre texte | studio / doc, un synth = un onglet" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
    mktempdir() do dir
        mkpath(joinpath(dir, "plugins", "user-synths"))
        cd(dir) do
            try
                app, tb, frame = _sw_app()
                _swex(app, "design")
                leaves = _swleaves(app)
                @test length(leaves) == 3
                parts = Ressac._synth_workspace_parts(app)
                @test parts !== nothing
                (ep, studio, sdoc) = parts
                @test studio.linked && sdoc.mode === :doc
                @test Ressac._focused_role(app) === :synth
                scr = _swscreen(app, tb, frame)
                @test occursin("SYNTH · sketch", scr)
                @test occursin("STUDIO ┄ sketch ┄ synchronisé", scr)
                @test occursin("DOC ✦ ◂ [doc] · explication · graphe ▸", scr)
                @test studio.genome !== nothing && !isempty(studio.knobs)    # le starter est analysable
                @test studio.synced_name == "sketch"

                # un autre synth : un onglet de plus, toujours 3 panes, le studio suit
                _swex(app, "synth zorglub")
                @test length(_swleaves(app)) == 3
                @test length(ep.tabs) == 2 && ep.tabs[ep.current_tab].name == "zorglub"
                _swscreen(app, tb, frame)
                @test studio.label == "zorglub" && studio.synced_name == "zorglub"
                # le rouvrir focalise l'onglet, sans en créer un autre
                ep.current_tab = 1
                Ressac._open_synth_tab!(app, "zorglub")
                @test length(ep.tabs) == 2 && ep.current_tab == 2
                # g t tourne dans les onglets
                Ressac._cycle_synth_tab!(app)
                @test ep.current_tab == 1
                _swscreen(app, tb, frame)
                @test studio.label == "sketch"

                # fermer l'onglet courant garde la pane ; le dernier laisse un sketch neuf
                Ressac._close_active_synth_tab!(app)
                @test length(ep.tabs) == 1 && ep.tabs[1].name == "zorglub" && length(_swleaves(app)) == 3
                Ressac._close_active_synth_tab!(app)
                @test length(ep.tabs) == 1 && ep.tabs[1].name == "sketch" && length(_swleaves(app)) == 3
                @test occursin("@synth :sketch", Tachikoma.text(ep.tabs[1].code_editor))
            finally
                Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
            end
        end
    end
end

@testset "workspace synth — texte → studio → texte" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _sw_app()
        _swex(app, "design")
        (ep, studio, sdoc) = Ressac._synth_workspace_parts(app)
        tab = ep.tabs[1]; ed = tab.code_editor
        Tachikoma.set_text!(ed, _SW_SRC); ed.mode = :normal
        _swscreen(app, tb, frame)
        @test studio.genome !== nothing
        @test any(k -> k.name === :freq && k.kind === :control, studio.knobs)
        @test !isempty(sdoc.explain_lines)
        @test studio.synced_hash == hash(_SW_SRC)

        # taper en insertion ne réévalue pas le texte ; Esc le fait
        _swkey(app, 'G'); _swkey(app, 'o')
        @test ed.mode === :insert
        foreach(c -> _swkey(app, c), "# note")
        _swscreen(app, tb, frame)
        @test studio.synced_hash == hash(_SW_SRC)
        _swkey(app, :escape)
        _swscreen(app, tb, frame)
        @test studio.synced_hash == hash(Tachikoma.text(ed)) && studio.synced_hash != hash(_SW_SRC)

        # tirer le knob freq dans le studio : le nombre change sur place dans le texte
        Ressac._focus_pane!(app, studio)
        i = findfirst(k -> k.name === :freq && k.kind === :control, studio.knobs)
        studio.focus = i
        _swkey(app, 'l')
        v = Ressac.knob_value(studio.genome, studio.knobs[i])
        @test v > 220
        _swscreen(app, tb, frame)
        txt = Tachikoma.text(ed)
        @test occursin("freq=$(Ressac._fmt_literal(v))", txt)
        @test occursin("saw(:freq) |> rlpf(800, 0.3)", txt)         # rien d'autre n'a bougé
        @test !any(l -> occursin("forme canonique", l), app.logs)
        @test studio.synced_hash == hash(txt)                        # pas de re-parse du texte réécrit
        # u dans le texte annule
        Ressac._focus_pane!(app, ep); ed.mode = :normal
        _swkey(app, 'u')
        @test occursin("freq=220", Tachikoma.text(ed))

        # un édit structurel réécrit le bloc en forme canonique
        _swscreen(app, tb, frame)                                    # resynchronise depuis le texte annulé
        Ressac._focus_pane!(app, studio)
        j = findfirst(k -> k.kind === :node, studio.knobs)
        studio.focus = j
        _swkey(app, 'd')                                             # supprime le nœud (bypass)
        _swscreen(app, tb, frame)
        @test any(l -> occursin("forme canonique", l), app.logs)
        txt2 = Tachikoma.text(ed)
        @test occursin("@synth :sketch", txt2) && occursin("|> safe()", txt2)

        # :explain bascule la doc sur l'explication ; ← → tournent ; :sculpt focalise le studio
        _swex(app, "explain")
        @test sdoc.mode === :explain && Ressac._focused_pane_impl(app) === sdoc
        scr = _swscreen(app, tb, frame)
        @test occursin("DOC ✦ ◂ doc · [explication] · graphe ▸", scr) && occursin("source", scr)
        _swkey(app, :right)
        @test sdoc.mode === :graph
        _swkey(app, :right)
        @test sdoc.mode === :doc
        _swkey(app, :left); _swkey(app, :left)
        @test sdoc.mode === :explain
        _swex(app, "sculpt")
        @test Ressac._focused_pane_impl(app) === studio

        # la doc vivante suit le curseur du texte, dans l'onglet doc
        sdoc.mode = :doc
        Ressac._focus_pane!(app, ep); ed.mode = :normal
        Tachikoma.set_text!(ed, _SW_SRC)
        ed.cursor_row = 1; ed.cursor_col = length("@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rl")
        scr = _swscreen(app, tb, frame)
        @test sdoc.doc.name == "rlpf" && occursin("· rlpf", scr)
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "workspace synth — persistance de la forme" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0], 44100); Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _sw_app()
        _swex(app, "design")
        _swscreen(app, tb, frame)
        path = joinpath(mktempdir(), "layout.toml")
        Ressac.save_layout(app.workspaces, path)
        wm = Ressac.WorkspaceManager()
        Ressac.load_layout!(wm, path)
        design = wm.workspaces[findfirst(w -> w.name == "DESIGN", wm.workspaces)]
        kinds = sort([Ressac._kind_for(t) for leaf in Ressac._all_leaves(design.tree) for t in leaf.tabs])
        @test kinds == ["editor", "synthdoc", "waveform"]
        studio = [t for leaf in Ressac._all_leaves(design.tree) for t in leaf.tabs if t isa Ressac.WaveformPane][1]
        @test studio.linked
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
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

@testset "graphe — l'onglet de la DOC, navigation, Enter, d, G" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _sw_app()
        _swex(app, "design")
        (ep, studio, sdoc) = Ressac._synth_workspace_parts(app)
        ed = ep.tabs[1].code_editor
        Tachikoma.set_text!(ed, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)\n"); ed.mode = :normal
        _swscreen(app, tb, frame)
        @test sdoc.studio === studio
        # → → : l'onglet graphe
        Ressac._focus_pane!(app, sdoc)
        _swkey(app, :right); _swkey(app, :right)
        @test sdoc.mode === :graph
        scr = _swscreen(app, tb, frame)
        @test occursin("DOC ✦ ◂ doc · explication · [graphe] ▸", scr)
        @test occursin("◉ out", scr) && occursin("RLPF", scr)
        @test !isempty(sdoc.graph_ids)
        # l avance d'une boîte et le studio suit sur le knob du nœud
        first_id = sdoc.graph_ids[1]
        @test sdoc.graph_focus == first_id || sdoc.graph_focus in sdoc.graph_ids
        sdoc.graph_focus = first_id
        _swkey(app, 'l')
        @test sdoc.graph_focus == sdoc.graph_ids[2]
        kb = studio.knobs[studio.focus]
        @test kb.kind === :node && kb.node_id == sdoc.graph_focus
        # Enter : le focus passe au studio
        _swkey(app, :enter)
        @test Ressac._focused_pane_impl(app) === studio
        # G dans le studio ramène sur l'onglet graphe
        sdoc.mode = :doc
        _swkey(app, 'G')
        @test sdoc.mode === :graph && Ressac._focused_pane_impl(app) === sdoc
        # d retire le nœud focalisé (bypass) : le graphe et le texte suivent
        n0 = length(studio.genome.nodes)
        rl = findfirst(i -> studio.genome.nodes[i].ugen === :RLPF, sdoc.graph_ids)
        sdoc.graph_focus = sdoc.graph_ids[rl]
        _swkey(app, 'd')
        @test length(studio.genome.nodes) == n0 - 1
        scr = _swscreen(app, tb, frame)
        @test !occursin("RLPF", Tachikoma.text(ed)) && !occursin("rlpf", Tachikoma.text(ed))
        @test !occursin("│ RLPF", scr)
        # [ ] défilent
        _swkey(app, ']'); @test sdoc.graph_x == 8
        _swkey(app, '['); @test sdoc.graph_x == 0
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end
