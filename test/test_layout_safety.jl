include(joinpath(@__DIR__, "helpers.jl"))
# Dispositions — roadmap U3 (charger sans rien perdre) et U4 (proportions).

# Une pane qui compte ses fermetures.
struct _CountingPane <: Ressac.PaneImpl; closed::Base.RefValue{Int}; end
Ressac.render!(::_CountingPane, area, buf) = nothing
Ressac.handle_key!(::_CountingPane, evt) = false
Ressac.title(::_CountingPane) = "compteur"
Ressac.on_close!(p::_CountingPane) = (p.closed[] += 1; nothing)
Ressac.serialize(::_CountingPane) = Dict{String,Any}()
Ressac._kind_for(::_CountingPane) = "log"

_ls_leaf(id) = Ressac.PaneLeaf(id, Ressac.PaneImpl[], 0)
_ls_area(w, h) = (x = 1, y = 1, w = w, h = h)

@testset "dispositions — sûres" begin

    @testset "U3 — :layout load lit à côté, n'échange que si tout est bon" begin
        app, frame = _new_app()
        _set_buffer!(app, "@d1 \"mon texte\"")
        ws_before = Ressac.current_workspace(app.workspaces)
        for (name, content, why) in (("abime", "totally not = valid = toml [[[", "ne se lit pas"),
                                     ("vide", "current_idx = 1\n", "aucun workspace"),
                                     ("sansarbre", "[workspaces.0]\nname = \"x\"\n", "pas d'arbre"),
                                     ("inconnu", "[workspaces.0]\nname = \"x\"\n[workspaces.0.tree]\ntype = \"pane\"\nid = 1\nkind = \"nexistepas\"\ncurrent_tab = 1\n", "not registered"))
            path = Ressac._named_layout_path(name)
            mkpath(dirname(path)); write(path, content)
            logs = _cmd_logs(app, "layout load $name")
            @test any(l -> occursin("[ERROR] :layout load $name — rien n'est changé", l) && occursin(why, l), logs)
            @test !any(l -> occursin("chargé", l), logs)
            # Le workspace, la pane et le texte sont ceux d'avant.
            @test Ressac.current_workspace(app.workspaces) === ws_before
            @test _buffer_text(app) == "@d1 \"mon texte\""
        end
        @test any(l -> occursin("introuvable", l), _cmd_logs(app, "layout load jamaissauve"))

        # Un bon fichier remplace tout, et les panes qui partent sont fermées.
        closed = Ref(0)
        Ressac.cmd_split!(app.workspaces, "log", Dict{String,Any}())
        ws = Ressac.current_workspace(app.workspaces)
        leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
        leaf.tabs[leaf.current_tab] = _CountingPane(closed)
        _set_buffer!(app, "@d1 \"sauvé\"")
        Ressac.save_layout(app.workspaces, Ressac._named_layout_path("bon"))
        leaf.tabs[leaf.current_tab] = _CountingPane(closed)
        logs = _cmd_logs(app, "layout load bon")
        @test any(l -> occursin(":layout load bon — chargé", l), logs)
        @test closed[] == 1
        Tachikoma.view(app, frame)
        @test !any(l -> occursin("[ERROR]", l), app.logs[(end - 1):end])
    end

    @testset "U3 — read_layout ne rend jamais une disposition à moitié lue" begin
        @test_throws ErrorException Ressac.read_layout("/nexiste/pas.toml")
        mktempdir() do dir
            p = joinpath(dir, "l.toml")
            write(p, "[workspaces.0]\nname = \"a\"\n[workspaces.0.tree]\ntype = \"pane\"\nid = 3\nkind = \"log\"\ncurrent_tab = 1\n" *
                     "[workspaces.1]\nname = \"b\"\n")
            @test_throws ErrorException Ressac.read_layout(p)          # le second workspace est cassé
            wm = Ressac.WorkspaceManager(); push!(wm.workspaces, Ressac.Workspace(1, "garde", _ls_leaf(1), Ressac.FloatingPane[], 1))
            @test (@test_logs (:warn, r"pas d'arbre") Ressac.load_layout!(wm, p)) === false
            @test length(wm.workspaces) == 1 && wm.workspaces[1].name == "garde"
        end
    end

    @testset "U4 — fermer une pane garde les proportions des autres" begin
        C = Ressac.Container
        # PLAY : texte 2/3 | (wiki 0.6 / doc 0.4), plus une pane ouverte à droite.
        side = C(:v, Ressac.LayoutNode[_ls_leaf(2), _ls_leaf(3)], [0.6, 0.4])
        root = C(:h, Ressac.LayoutNode[_ls_leaf(1), side], [2 / 3, 1 / 3])
        Ressac._split_at!(root, 2, :h, _ls_leaf(4))
        @test root.ratios ≈ [2 / 3, 1 / 6, 1 / 6]              # la pane scindée partage SA place ; le texte garde la sienne
        @test side.ratios == [0.6, 0.4]
        back = Ressac._close_at(root, 4)
        @test back.ratios ≈ [2 / 3, 1 / 3]                     # comme avant d'ouvrir
        @test back.children[2].ratios == [0.6, 0.4]            # le reste de l'arbre n'a pas bougé
        # Fermer dans un sous-arbre ne touche pas au parent ; un conteneur à
        # un seul enfant se replie et prend la place du conteneur.
        r2 = Ressac._close_at(C(:h, Ressac.LayoutNode[_ls_leaf(1), C(:v, Ressac.LayoutNode[_ls_leaf(2), _ls_leaf(3)], [0.6, 0.4])], [0.7, 0.3]), 3)
        @test r2.ratios == [0.7, 0.3] && r2.children[2] isa Ressac.PaneLeaf && r2.children[2].id == 2
        # Trois panes 50/30/20 : la place de celle qu'on ferme va à sa voisine de gauche,
        # ou de droite pour la première.
        three() = C(:h, Ressac.LayoutNode[_ls_leaf(1), _ls_leaf(2), _ls_leaf(3)], [0.5, 0.3, 0.2])
        @test Ressac._close_at(three(), 2).ratios ≈ [0.8, 0.2]
        @test Ressac._close_at(three(), 3).ratios ≈ [0.5, 0.5]
        @test Ressac._close_at(three(), 1).ratios ≈ [0.8, 0.2]
        # Scinder puis fermer, à n'importe quel endroit, rend les proportions.
        for idx in 1:3
            t = three(); Ressac._split_at!(t, idx, :h, _ls_leaf(9))
            @test sum(t.ratios) ≈ 1 && Ressac._close_at(t, 9).ratios ≈ [0.5, 0.3, 0.2]
        end
        @test Ressac._close_at(_ls_leaf(1), 1) === nothing
        @test Ressac._close_at(_ls_leaf(1), 9).id == 1
    end

    @testset "U4 — dans l'app : ouvrir puis fermer une pane rend la disposition" begin
        app, frame = _new_app()
        Ressac.cmd_split!(app.workspaces, "log", Dict{String,Any}(); direction = :h)
        ws = Ressac.current_workspace(app.workspaces)
        ws.tree.ratios = [0.7, 0.3]
        Ressac.cmd_split!(app.workspaces, "log", Dict{String,Any}(); direction = :h)
        @test length(Ressac._all_leaves(ws.tree)) == 3
        Ressac.cmd_close!(app.workspaces)
        @test Ressac.current_workspace(app.workspaces).tree.ratios ≈ [0.7, 0.3]
    end

    @testset "U4 — les rectangles pavent l'aire exactement" begin
        C = Ressac.Container
        for (w, ratios) in ((119, [0.5, 0.5]), (100, [1 / 3, 1 / 3, 1 / 3]), (137, [0.21, 0.33, 0.46]),
                            (7, [0.1, 0.1, 0.8]), (3, [0.25, 0.25, 0.25, 0.25]), (80, [2.0, 1.0]))
            node = C(:h, Ressac.LayoutNode[_ls_leaf(i) for i in eachindex(ratios)], ratios)
            areas = Ressac._child_areas(node, _ls_area(w, 20))
            @test sum(a.w for a in areas) == w                               # ni colonne en trop, ni perdue
            @test areas[1].x == 1 && all(areas[i + 1].x == areas[i].x + areas[i].w for i in 1:(length(areas) - 1))
            @test all(a -> a.w >= 0 && a.h == 20, areas)
            v = Ressac._child_areas(C(:v, node.children, ratios), _ls_area(20, w))
            @test sum(a.h for a in v) == w
            # Les frontières de redimensionnement tombent sur les mêmes coupes que le rendu.
            bs = Ressac._boundaries(node, _ls_area(w, 20))
            @test [b.pos for b in bs] == [a.x + a.w - 1 for a in areas[1:(end - 1)]]
        end
        rects = Ressac._compute_rects(C(:h, Ressac.LayoutNode[_ls_leaf(1), C(:v, Ressac.LayoutNode[_ls_leaf(2), _ls_leaf(3)], [0.6, 0.4])], [2 / 3, 1 / 3]), _ls_area(119, 37))
        @test rects[1].w + rects[2].w == 119 && rects[2].h + rects[3].h == 37 && rects[2].x == rects[3].x
    end
end
