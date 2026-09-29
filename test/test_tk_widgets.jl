# Les gabarits Tachikoma de Ressac : ScrollPane partagé (tk_scroll.jl) et
# picker saisie + liste (tk_picker.jl), puis la palette qui s'en sert.
using Test
using Ressac
using Tachikoma

_ev(c) = Tachikoma.KeyEvent(c)
_click(x, y) = Tachikoma.MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false)
_wheel(x, y, up) = Tachikoma.MouseEvent(x, y, up ? Tachikoma.mouse_scroll_up : Tachikoma.mouse_scroll_down,
                                        Tachikoma.mouse_press, false, false, false)

@testset "ScrollPane partagé — bornes, haut, bas, dernier" begin
    sp = Ressac._scrollpane()
    Tachikoma.set_content!(sp, [Ressac._span_line("l$i") for i in 1:30])
    tb = Tachikoma.TestBackend(20, 10)
    Tachikoma.render(sp, Tachikoma.Rect(1, 1, 20, 10), tb.buf)
    @test Ressac._scroll_last(sp) == 20
    Ressac._scroll!(sp, :end_key); @test sp.offset == 20
    Ressac._scroll!(sp, :down);    @test sp.offset == 20          # butée
    Ressac._scroll!(sp, :pageup);  @test sp.offset == 10
    Ressac._scroll_top!(sp);       @test sp.offset == 0
    Ressac._scroll!(sp, :up);      @test sp.offset == 0
    # un journal qui suit le bas : grossir recolle, remonter détache, _scroll_end! recolle
    log = Ressac._scrollpane(; following = true)
    Tachikoma.set_content!(log, [Ressac._span_line("l$i") for i in 1:30])
    Tachikoma.render(log, Tachikoma.Rect(1, 1, 20, 10), tb.buf)
    @test log.offset == 20 && log.following
    Ressac._scroll!(log, :up); @test log.offset == 19 && !log.following
    Tachikoma.set_content!(log, [Ressac._span_line("l$i") for i in 1:40])
    Tachikoma.render(log, Tachikoma.Rect(1, 1, 20, 10), tb.buf)
    @test log.offset == 19                                          # détaché : ne bouge pas
    Ressac._scroll_end!(log); Tachikoma.render(log, Tachikoma.Rect(1, 1, 20, 10), tb.buf)
    @test log.offset == 30 && log.following
    @test occursin("l40", Tachikoma.row_text(tb, 10))
end

@testset "picker — saisie, liste, sélection, souris" begin
    pk = Ressac._picker(; searching = true)
    words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
    sync!() = (q = Ressac._picker_query(pk); vis = filter(w -> occursin(q, w), words);
               Ressac._picker_set!(pk, [Tachikoma.ListItem(w) for w in vis], vis); vis)
    sync!()
    @test Ressac._picker_selected(pk) == "alpha"
    Ressac._picker_nav!(pk, :down); Ressac._picker_nav!(pk, :down)
    @test Ressac._picker_selected(pk) == "gamma"
    # taper filtre et remonte en tête
    @test Ressac._picker_type!(pk, _ev('e'))
    @test Ressac._picker_query(pk) == "e"
    vis = sync!()
    @test vis == ["beta", "delta", "epsilon", "zeta"] && Ressac._picker_selected(pk) == "beta"
    Ressac._picker_nav!(pk, :end_key); @test Ressac._picker_selected(pk) == "zeta"
    Ressac._picker_nav!(pk, :down);    @test Ressac._picker_selected(pk) == "beta"   # ↓ au bout revient en tête
    # retour arrière, une touche non typable est ignorée
    @test Ressac._picker_type!(pk, _ev(:backspace)) && isempty(Ressac._picker_query(pk))
    @test !Ressac._picker_type!(pk, _ev(:enter))
    @test !Ressac._picker_type!(pk, Tachikoma.KeyEvent(:char, '\0', Tachikoma.key_press))
    sync!(); @test length(pk.list.items) == 6
    # rendu : saisie en haut avec le compte à droite, liste dessous, clic et molette
    tb = Tachikoma.TestBackend(30, 5)
    Ressac._picker_render!(pk, Tachikoma.Rect(1, 1, 30, 5), tb.buf; right_text = "6")
    @test startswith(Tachikoma.row_text(tb, 1), "⌕ ") && endswith(rstrip(Tachikoma.row_text(tb, 1)), "6")
    @test occursin("alpha", Tachikoma.row_text(tb, 2)) && occursin("delta", Tachikoma.row_text(tb, 5))
    @test Ressac._picker_mouse!(pk, _click(5, 4)) && Ressac._picker_selected(pk) == "gamma"
    @test Ressac._picker_click_hits_selected(pk, _click(5, 4))
    @test !Ressac._picker_click_hits_selected(pk, _click(5, 3))
    @test Ressac._picker_mouse!(pk, _wheel(5, 3, false)) && pk.list.offset == 1
    Ressac._picker_reset!(pk)
    @test isempty(pk.list.items) && pk.list.selected == 1 && isempty(Ressac._picker_query(pk))
    # hors mode recherche, la frappe n'entre pas dans la saisie (elle va aux touches de la modale)
    Ressac._picker_search!(pk, false)
    @test !Ressac._picker_type!(pk, _ev('j')) && isempty(Ressac._picker_query(pk))
    Ressac._picker_search!(pk, true)
    @test Ressac._picker_type!(pk, _ev('j')) && Ressac._picker_query(pk) == "j"
    Ressac._picker_clear!(pk); @test isempty(Ressac._picker_query(pk)) && pk.searching
end

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

@testset "palette — flèches, Entrée, clic et molette passent par le picker" begin
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'p'))
    @test app.modal === :palette
    for c in "hu"; Tachikoma.update!(app, _ev(c)); end
    Tachikoma.view(app, frame)
    items = Ressac._palette_items(app)
    @test length(items) >= 2 && items[1].label == ":hush"
    @test Tachikoma.find_text(tb, "PALETTE") !== nothing && Tachikoma.find_text(tb, ":hush") !== nothing
    Tachikoma.update!(app, _ev(:down))
    @test Ressac._palette_cur(app) === items[2]
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'p'))         # Ctrl-p = précédent dans la palette
    @test Ressac._palette_cur(app) === items[1]
    # clic sur la troisième ligne de la liste (juste sous la saisie)
    area = app.palette.list.last_area
    @test area.height > 3
    Tachikoma.update!(app, _click(area.x + 3, area.y + 2))
    @test Ressac._palette_cur(app) === items[3]
    # molette : la liste défile (si elle déborde) sans changer la sélection
    Tachikoma.update!(app, _wheel(area.x + 3, area.y + 2, false))
    @test app.palette.list.offset == (length(items) > area.height ? 1 : 0)
    @test Ressac._palette_cur(app) === items[3]
    # un second clic sur la ligne sélectionnée valide (ferme la palette)
    Tachikoma.view(app, frame)
    sel_y = app.palette.list.last_area.y + (app.palette.list.selected - app.palette.list.offset) - 1
    Tachikoma.update!(app, _click(area.x + 3, sel_y))
    @test app.modal === :none
    # rouvrir : saisie vide, sélection en tête
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'p'))
    @test isempty(Ressac._picker_query(app.palette)) && app.palette.list.selected == 1
    Tachikoma.update!(app, _ev(:escape)); @test app.modal === :none
end
