# Redimensionner les panes : mode pane (< > - + = r), glisser une bordure
# à la souris, bornes, surbrillance, proportions sauvées.
using Test
using Ressac
using Tachikoma

if !@isdefined(_PRMock)
    mutable struct _PRMock
        sent::Vector{Vector{UInt8}}
    end
    _PRMock() = _PRMock(Vector{UInt8}[])
    Ressac.send_osc(c::_PRMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _pr_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_PRMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(140, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    return app, tb, frame
end
_prkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_prkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_prex(app, cmd) = (_prkey(app, ':'); foreach(c -> _prkey(app, c), cmd); _prkey(app, :enter))
function _prscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
_prmouse(app, x, y, btn, act) = Tachikoma.update!(app, Tachikoma.MouseEvent(x, y, btn, act, false, false, false))
_prpane(app) = (Ressac._PANE_MODE.active = false; Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')))

@testset "redimensionner — mode pane < > - + = r" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0], 44100); Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _pr_app()
        _prex(app, "design")
        _prscreen(app, tb, frame)
        ws = Ressac.current_workspace(app.workspaces)
        root = ws.tree
        @test root isa Ressac.Container && root.direction === :h && root.ratios == [0.5, 0.5]
        side = root.children[2]
        @test side isa Ressac.Container && side.direction === :v
        # le texte est focalisé : > l'élargit, < le rétrécit
        _prpane(app); _prkey(app, '>')
        @test root.ratios ≈ [0.55, 0.45]
        @test Ressac._PANE_MODE.active                       # le mode pane reste actif
        _prkey(app, '<'); _prkey(app, '<')
        @test root.ratios ≈ [0.45, 0.55]
        # la hauteur ne concerne pas le texte (pas d'ancêtre vertical) : rien ne bouge
        _prkey(app, '+')
        @test root.ratios ≈ [0.45, 0.55] && side.ratios ≈ [0.55, 0.45]
        _prkey(app, :escape)
        # le studio (en haut à droite) : + le grandit, - le réduit ; > joue sur la colonne de droite
        (_, studio, _) = Ressac._synth_workspace_parts(app)
        Ressac._focus_pane!(app, studio)
        _prpane(app); _prkey(app, '+')
        @test side.ratios ≈ [0.6, 0.4]
        _prkey(app, '-'); _prkey(app, '-')
        @test side.ratios ≈ [0.5, 0.5]
        _prkey(app, '>')
        @test root.ratios ≈ [0.4, 0.6]
        # bornes : jamais moins de 10 %
        for _ in 1:30; _prkey(app, '+'); end
        @test side.ratios ≈ [0.9, 0.1]
        # = égalise tous les containers au-dessus
        _prkey(app, '=')
        @test root.ratios ≈ [0.5, 0.5] && side.ratios ≈ [0.5, 0.5]
        # r tourne la coupe la plus proche
        _prkey(app, 'r')
        @test side.direction === :h
        _prkey(app, 'r')
        @test side.direction === :v
        _prkey(app, :escape)
        # les proportions sont sauvées avec la disposition
        _prpane(app); _prkey(app, '+'); _prkey(app, :escape)
        path = joinpath(mktempdir(), "layout.toml")
        Ressac.save_layout(app.workspaces, path)
        wm = Ressac.WorkspaceManager()
        Ressac.load_layout!(wm, path)
        d = wm.workspaces[findfirst(w -> w.name == "DESIGN", wm.workspaces)]
        @test d.tree.children[2].ratios ≈ [0.55, 0.45]
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "redimensionner — glisser une bordure à la souris" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0], 44100); Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _pr_app()
        _prex(app, "design")
        _prscreen(app, tb, frame)
        ws = Ressac.current_workspace(app.workspaces)
        root = ws.tree
        bs = Ressac._boundaries(root, app._last_ws_area)
        @test length(bs) == 2
        b = only(x for x in bs if x.cont === root)
        @test b.dir === :h && b.i == 1 && b.size == app._last_ws_area.w
        # la bordure est la dernière colonne de la pane de gauche
        rects = Ressac._workspace_rects(app, ws, app._last_ws_area)
        left = rects[Ressac._all_leaves(root.children[1])[1].id]
        @test b.pos == left.x + left.w - 1
        y = b.lo + 3
        @test Ressac._boundary_at(app, b.pos, y) !== nothing && Ressac._boundary_at(app, b.pos + 1, y) !== nothing
        @test Ressac._boundary_at(app, b.pos + 5, y) === nothing
        # clic sur la bordure, glisser de 14 colonnes (10 % de 140), relâcher
        _prmouse(app, b.pos, y, Tachikoma.mouse_left, Tachikoma.mouse_press)
        @test app.resize_drag !== nothing
        scr = _prscreen(app, tb, frame)
        @test collect(Tachikoma.row_text(tb, y))[b.pos] == '┃'            # la bordure s'allume
        _prmouse(app, b.pos + 7, y, Tachikoma.mouse_left, Tachikoma.mouse_drag)
        _prmouse(app, b.pos + 14, y, Tachikoma.mouse_left, Tachikoma.mouse_drag)
        @test root.ratios ≈ [0.6, 0.4]
        _prmouse(app, b.pos + 14, y, Tachikoma.mouse_left, Tachikoma.mouse_release)
        @test app.resize_drag === nothing
        _prscreen(app, tb, frame)
        @test collect(Tachikoma.row_text(tb, y))[b.pos] != '┃'
        # la frontière verticale entre studio et doc
        bv = only(x for x in bs if x.dir === :v)
        x = bv.lo + 3
        _prmouse(app, x, bv.pos, Tachikoma.mouse_left, Tachikoma.mouse_press)
        _prmouse(app, x, bv.pos + 4, Tachikoma.mouse_left, Tachikoma.mouse_drag)
        side = root.children[2]
        @test side.ratios[1] > 0.5
        _prmouse(app, x, bv.pos + 4, Tachikoma.mouse_left, Tachikoma.mouse_release)
        # ailleurs, un clic gauche ne saisit rien
        _prmouse(app, 10, 10, Tachikoma.mouse_left, Tachikoma.mouse_press)
        @test app.resize_drag === nothing
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end
