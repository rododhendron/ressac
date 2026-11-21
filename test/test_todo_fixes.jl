include(joinpath(@__DIR__, "helpers.jl"))
# Ce que l'usage a fait remonter (TODO.txt du 2026-11-20) : Tab et les touches
# maintenues en insertion, Échap, l'étendue des blocs, `:format` et l'atelier
# sur une chaîne en une ligne, `:e!` le curseur dans un son, les fiches du langage des
# sons, les sources à état et l'interface, le drone et son enveloppe.
using Test
using Ressac
import Tachikoma
const _TF_TK = Tachikoma

_tf_key(app, c) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_tf_ex(app, cmd) = (_tf_key(app, ':'); foreach(c -> _tf_key(app, c), cmd); _tf_key(app, :enter))
# Dans la zone de l'image, les cellules sans texte n'ont pas de fond.
function tb_bg_free(app, sc)
    tb = Tachikoma.TestBackend(180, 46)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 180, 46), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    cell = tb.buf.content[Tachikoma.buf_index(tb.buf, sc.x + sc.w - 1, sc.y + sc.h - 1)]
    outside = tb.buf.content[Tachikoma.buf_index(tb.buf, sc.x - 8, sc.y + sc.h - 1)]
    return cell.style.bg isa Tachikoma.NoColor && !(outside.style.bg isa Tachikoma.NoColor) && length(frame.gfx_regions) == 1
end

# Combien de cellules de la zone de l'image sont sans fond (l'image s'y voit).
function tb_hole_open_cells(app)
    tb = Tachikoma.TestBackend(180, 46)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 180, 46), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    isempty(Ressac._PIXEL_HOLES) && return -1
    hole = Ressac._PIXEL_HOLES[1]
    return count(tb.buf.content[Tachikoma.buf_index(tb.buf, x, y)].style.bg isa Tachikoma.NoColor
                 for y in hole.y:(hole.y + hole.height - 1), x in hole.x:(hole.x + hole.width - 1))
end

function _tf_app(w = 180, h = 46)
    (app, _) = _new_app()
    tb = Tachikoma.TestBackend(w, h)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, w, h), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    draw() = (Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame);
              join((rstrip(Tachikoma.row_text(tb, y)) for y in 1:h), "\n"))
    draw()
    return (app, draw)
end

@testset "ce que l'usage a fait remonter" begin

@testset "insertion — Tab écrit des espaces, une touche maintenue se répète" begin
    (app, _) = _tf_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, "abc\n"); ed.cursor_row = 1; ed.cursor_col = 0
    _tf_key(app, 'i'); _tf_key(app, :tab)
    @test Tachikoma.text(ed) == "  abc\n"                       # jusqu'au taquet, en espaces
    @test !occursin('\t', Tachikoma.text(ed))
    ed.cursor_col = 1; _tf_key(app, :tab)
    @test Tachikoma.text(ed) == "   abc\n" && ed.cursor_col == 2  # un seul : le taquet suivant
    rep(k, c = '\0') = Tachikoma.update!(app, Tachikoma.KeyEvent(k, c, Tachikoma.key_repeat))
    ed.cursor_col = 6
    rep(:backspace); rep(:backspace)
    @test Tachikoma.text(ed) == "   a\n"
    rep(:char, 'z'); rep(:char, 'z'); rep(:left)
    @test Tachikoma.text(ed) == "   azz\n" && ed.cursor_col == 5
    rep(:enter); rep(:tab); rep(:escape)                        # ceux-là ne se répètent pas
    @test Tachikoma.text(ed) == "   azz\n" && ed.mode === :insert
    # `\sigma` + Tab : la lettre
    _tf_key(app, :escape)
    Tachikoma.set_text!(ed, ""); ed.cursor_row = 1; ed.cursor_col = 0
    _tf_key(app, 'i'); foreach(c -> _tf_key(app, c), "\\sigma"); _tf_key(app, :tab)
    foreach(c -> _tf_key(app, c), "_noise = \\tau"); _tf_key(app, :tab)
    @test Tachikoma.text(ed) == "σ_noise = τ"
end

@testset "Échap ne quitte jamais" begin
    (app, _) = _tf_app()
    for _ in 1:4; _tf_key(app, :escape); end
    @test !app.quit
    @test !any(b -> "Esc" in b.keys, Ressac.bindings(:global))
end

@testset "l'étendue d'un bloc — begin/end, mots entiers, |> en fin de ligne" begin
    L = ["@d1 n(\"0 3\") |>", "  s(\"blend\") |> legato(1)", "# the end", "x = begin", "  1", "end",
         "@d2 s(\"send\")", "f(a[end])", "@d3 s(\"bd\")",
         "@synth :x (freq=220) begin", "  saw(:freq)", "  |> rlpf(800, 0.3)", "end", "@d4 s(\"x\")"]
    r(i) = Ressac._logical_block_range(L, i)
    @test r(1) == (1, 2) && r(2) == (1, 2)          # la ligne d'avant finit par |>
    @test r(3) == (3, 3)                            # « end » dans un commentaire
    @test r(4) == r(5) == r(6) == (4, 6)            # begin … end
    @test r(7) == (7, 7) && r(8) == (8, 8) && r(9) == (9, 9)    # send, a[end] : rien d'ouvert
    @test r(10) == r(11) == r(12) == r(13) == (10, 13)
    @test r(14) == (14, 14)
    @test Ressac._delim_depth("s(\"blend\") |> legato(1)") == 0
    @test Ressac._delim_depth("feedback() do fb") == 1 && Ressac._delim_depth("end") == -1
    @test Ressac._delim_depth("x = [i for i in 1:3]") == 0 && Ressac._delim_depth("y = :end") == 0
    # Une faute plus haut (un `end` en trop) ne décale pas les slots d'après.
    M = ["end", "end", "@d1 s(\"bd\")", "  |> gain(1)", "@d2 s(\"hh\")"]
    @test Ressac._logical_block_range(M, 3) == (3, 4) && Ressac._logical_block_range(M, 5) == (5, 5)
end

@testset ":format — un maillon par ligne" begin
    f = Ressac.format_synth_text
    one = "@synth :essai (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)\n"
    want = "@synth :essai (freq=220, sustain=0.5) saw(:freq)\n  |> rlpf(800, 0.3)\n  |> tanh_drive(2)\n"
    @test f(one) == want
    @test f(want) == want                                          # idempotent
    blk = "@synth :e (freq=220) begin\n  saw(:freq) |> rlpf(800, 0.3) |>\n  env_perc(0.01, :sustain)\nend\n"
    @test f(blk) == "@synth :e (freq=220) begin\n  saw(:freq)\n  |> rlpf(800, 0.3)\n  |> env_perc(0.01, :sustain)\nend\n"
    # un |> dans un argument, ou sur une ligne nommée, ne bouge pas
    keep = "@synth :e (freq=220) begin\n  n1 = saw(:freq) |> rlpf(800, 0.3)\n  f(n1 |> amp(2), 3)\nend\n"
    @test f(keep) == keep
    # le son joue pareil : même SynthDef avant et après
    cap(t) = (c = Any[]; Ressac._DRONE_CAPTURE[] = c;
              try Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(t)) finally Ressac._DRONE_CAPTURE[] = nothing end; c[end][2])
    @test cap(one) == cap(f(one))
end

@testset "l'atelier s'ouvre sur une chaîne en une ligne, et sur la ligne @synth" begin
    old = pwd(); d = mktempdir(); mkpath(joinpath(d, "plugins", "user-synths")); cd(d)
    try
        (app, draw) = _tf_app()
        _tf_ex(app, "synth essai"); draw()
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "@synth :essai (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)\n")
        ed.cursor_row = 1; ed.cursor_col = 53; draw()              # sur rlpf
        _tf_key(app, 'o'); draw()
        @test app.modal === :atelier
        @test Tachikoma.text(ed) == "@synth :essai (freq=220, sustain=0.5) saw(:freq)\n  |> rlpf(800, 0.3)\n  |> tanh_drive(2)\n"
        @test ed.cursor_row == 2                                   # le curseur a suivi son maillon
        _tf_key(app, :escape); draw()
        # sur la source, écrite sur la ligne @synth
        ed.cursor_row = 1; ed.cursor_col = 40; draw()
        _tf_key(app, 'o'); draw()
        @test app.modal === :atelier
        st = app.atelier
        (lines, row, _) = Ressac._atelier_text(st, st.items[1])
        @test row == 2 && startswith(lines[2], "  |> ")           # rangé un cran sous @synth
        _tf_key(app, :escape)
    finally
        cd(old)
    end
end

@testset ":e / :e! dans un son relisent la session, pas un fichier de son" begin
    old = pwd(); d = mktempdir(); mkpath(joinpath(d, "plugins", "user-synths")); cd(d)
    try
        (app, draw) = _tf_app()
        _tf_ex(app, "synth essai"); draw()
        ed = Ressac._active_editor(app)
        @test Ressac._focused_role(app) === :synth
        _tf_ex(app, "e!")
        @test occursin("n'a pas de nom", app.logs[end])            # rien à relire encore
        _tf_ex(app, "w brouillons"); draw()
        @test !isfile(joinpath(d, "plugins", "user-synths", "essai.jl"))   # :w écrit la session, pas le son
        saved = Tachikoma.text(ed)
        @test occursin("@synth :essai", saved) && read(Ressac._session_path("brouillons"), String) == saved
        snd = Ressac._current_sound(app)
        Ressac._sound_write!(snd, Ressac._sound_text(snd) * " |> tanh_drive(2)")
        @test Ressac._focused_role(app) === :synth
        _tf_ex(app, "e")
        @test occursin(":e!", app.logs[end]) && occursin("tanh_drive", Tachikoma.text(ed))   # refuse sans !
        _tf_ex(app, "e!")
        @test Tachikoma.text(Ressac._patterns_editor(app)) == saved
    finally
        cd(old)
    end
end

@testset "les fiches du langage des sons disent ce qu'on écrit" begin
    @test Ressac._dsl_signature("rlpf") == "… |> rlpf(cutoff, [q])"
    @test Ressac._dsl_signature("saw") == "saw(freq)"
    @test Ressac._dsl_signature("env_perc") == "… |> env_perc(attack, release; level, curve)"
    @test Ressac._dsl_signature("pas_une_fonction") === nothing
    d = Ressac._lookup_livedoc("rlpf")
    @test startswith(d, "`… |> rlpf(cutoff, [q])`") && occursin("RLPF.ar(in, freq, rq)", d) && occursin("not an argument", d)
    # `saw` : le signal dans un pattern, l'oscillateur dans un son
    @test occursin("0 to 1", Ressac._lookup_livedoc("saw"))
    @test occursin("saw(freq)", Ressac._lookup_livedoc("dsl:saw"))
    # Toute fonction du langage des sons qu'on propose a une fiche qui montre sa vraie signature.
    for (_, (fn, _)) in merge(Ressac._DSL_SOURCES, Ressac._DSL_STAGES)
        isdefined(Ressac.SynthDSL, Symbol(fn)) || continue
        @test Ressac._dsl_doc(fn) !== nothing
    end
    old = pwd(); dir = mktempdir(); mkpath(joinpath(dir, "plugins", "user-synths")); cd(dir)
    try
        (app, draw) = _tf_app(190, 30)
        _tf_ex(app, "synth essai"); draw()
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "@synth :essai (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)\n")
        ed.cursor_row = 1; ed.cursor_col = 39; draw()
        _tf_key(app, 'K'); scr = draw()
        @test occursin("saw(freq)", scr) && occursin("dans un son", scr) && !occursin("dsl:", scr)
    finally
        cd(old)
    end
end

@testset "aucune fiche ne documente une fonction qui n'existe pas" begin
    Ressac._handle_docs(joinpath(@__DIR__, "..", "plugins", "core"), Dict("dir" => "docs"), "core")
    concept = (:glossary, :param, Symbol("mini-notation"))
    ghosts = String[]
    for f in readdir(joinpath(@__DIR__, "..", "plugins", "core", "docs"))
        endswith(f, ".md") || continue
        txt = read(joinpath(@__DIR__, "..", "plugins", "core", "docs", f), String)
        mt = match(r"^name = \"([^\"]+)\"$"m, txt)
        mt === nothing && continue
        name = String(mt.captures[1])
        occursin(r"^[A-Za-z_]\w*!?$", name) || continue            # `<>`, `~`, `@dN` : de la notation
        e = Ressac.lookup_doc(name)
        e === nothing && continue
        defined = isdefined(Ressac, Symbol(name)) || isdefined(Ressac.SynthDSL, Symbol(name))
        if !defined
            # Un mot qui n'est pas une fonction doit le dire (étiquette), et ne
            # pas se montrer appelé : `rq(0.3)` n'existe pas.
            (any(t -> t in concept, e.tags) && !occursin(Regex("(?<![\\w:.])" * name * "\\("), e.body)) || push!(ghosts, name)
        end
    end
    isempty(ghosts) || println("Fiches d'une fonction qui n'existe pas : ", join(ghosts, ", "))
    @test isempty(ghosts)
end

@testset "une source à état : une question à la fois, et l'interface ne la fait pas avancer" begin
    steps = Ref(0); busy = Ref(0); clash = Ref(false)
    p = Ressac.stateful_pattern(Float64, (s, e, preview) -> begin
        busy[] += 1; busy[] > 1 && (clash[] = true)
        preview || (steps[] += 1; sleep(0.002))
        busy[] -= 1
        [Ressac.Event{Float64}(s, e, Float64(steps[]))]
    end)
    q = p |> Ressac.fast(1)                                        # enveloppée : la règle tient
    @test !Ressac.in_preview_query()
    Ressac.preview_query(q, 0, 1); Ressac.preview_query(q, 0, 1)
    @test steps[] == 0                                             # regarder ne fait rien avancer
    q(0 // 1, 1 // 1)
    @test steps[] == 1
    @test !Ressac.in_preview_query()                               # le drapeau ne déborde pas
    ts = [Threads.@spawn(for _ in 1:20; isodd(i) ? q(0 // 1, 1 // 1) : Ressac.preview_query(q, 0, 1); end) for i in 1:4]
    foreach(wait, ts)
    @test !clash[] && steps[] == 41
end

@testset "le drone tient le son : l'enveloppe de note est retirée, celle qui module reste" begin
    S = Ressac.SynthDSL
    held = Ressac.SynthDSL._hold_envelopes
    @test held("(Saw.ar(freq) * EnvGen.kr(Env.perc(0.01, sustain, 1, -4), doneAction: 2))") == "(Saw.ar(freq) * 1)"
    modul = "RLPF.ar(Saw.ar(freq), EnvGen.kr(Env.perc(0.01, 0.3), doneAction: 0) * 800, 0.3)"
    @test held(modul) == modul
    sig = S.saw(:freq) |> s -> S.env_perc(s, 0.01, :sustain)
    src = S.build_drone_synth(:essai, sig; params = (freq = 220, sustain = 0.5))
    @test !occursin("Env.perc", src) && occursin("Env.asr(0.01, 1, release), gate", src)
    @test occursin("Env.perc", S.build_synth(:essai, sig; params = (freq = 220, sustain = 0.5)))   # la note, elle, garde la sienne
end

@testset "la ligne de commande — les flèches se promènent dans les propositions" begin
    cl = Ressac.CommandLine()
    Ressac.enter!(cl, :command)
    fn = _ -> ["theme a", "theme b", "theme c", "theme d", "theme e"]
    k(key) = Ressac.handle_key!(cl, Tachikoma.KeyEvent(key); complete_fn = fn)
    k(:tab); @test String(cl.buffer) == "theme a"
    cl.completion_cols = 2                                         # ce que la grille affichée a mesuré
    k(:right); @test String(cl.buffer) == "theme b"
    k(:down);  @test String(cl.buffer) == "theme d"
    k(:up);    @test String(cl.buffer) == "theme b"
    k(:left);  @test String(cl.buffer) == "theme a"
    k(:left);  @test String(cl.buffer) == "theme a"                # au bord : on reste
    k(:backtab); @test String(cl.buffer) == "theme e"              # Maj-Tab boucle
    k('x'); @test !Ressac.completion_active(cl)
end

@testset "println / @show : ce que le code imprime arrive dans le journal" begin
    (app, _) = _tf_app()
    Ressac._OUTPUT_PENDING[] = ""
    Ressac._capture_output!(app, "x = 3\ndeux li")              # la pipe rend des morceaux, pas des lignes
    @test app.logs[end] == "› x = 3"
    Ressac._capture_output!(app, "gnes\r\n\n")
    @test app.logs[end] == "› deux lignes" && count(l -> startswith(l, "› "), app.logs) == 2
    spans = Ressac._log_spans(app.logs)
    @test spans[end][2].content == "› deux lignes"
end

@testset "la grille en pixels : une scène, une image, et rien en cellules dans la zone" begin
    (app, draw) = _tf_app()
    old = Ressac._PIXELS_FORCE[]
    prev = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        ed = Ressac._patterns_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"bd sn\"\n@d2 n(\"0 7\") |> s(\"superpiano\")")
        _tf_key(app, 'E')
        sched = app.scheduler
        sched.t_start = time() - 2.25 / sched.cps                 # un quart de cycle après le début
        ed.cursor_row = 2
        Ressac._PIXELS_FORCE[] = false
        draw()
        @test app.pixel_scene === nothing && isempty(Ressac._PIXEL_HOLES)    # sans protocole graphique : les caractères
        Ressac._PIXELS_FORCE[] = true
        scr = draw()
        sc = app.pixel_scene
        @test sc !== nothing && length(sc.lanes) == 2 && 0 <= sc.phase < 1
        @test Ressac._PIXEL_HOLES[1] == Tachikoma.Rect(sc.x, sc.y, sc.w, sc.h)
        l2 = sc.lanes[2]
        @test l2.cursor && length(l2.notes) == 2 && l2.notes[1][3] == 60.0 && l2.notes[2][3] == 67.0
        @test l2.notes[2][1] == 0.5 && l2.notes[2][2] == 1.0       # début et fin dans le cycle
        @test !any(l -> occursin("█", l), split(scr, "\n")[3:4])    # plus de piste en caractères sur les lignes des slots
        # la zone garde des cellules SANS fond : c'est par là que l'image se voit
        @test tb_bg_free(app, sc)
        # la peinture : pure, vérifiable au pixel
        c = Ressac._paint_scene(sc, 8, 16)
        @test (c.w, c.h) == (sc.w * 8, sc.h * 16)
        p = Ressac._ui()
        rgb(col) = (col.r, col.g, col.b)
        @test Ressac._px_at(c, c.w - 2, c.h - 1) == rgb(p.bg)      # dernier temps : le sol
        @test Ressac._px_at(c, 2, c.h - 1) == rgb(p.s1)            # premier temps : la bande
        hx = round(Int, sc.phase * c.w)
        head = Ressac._px_at(c, hx, c.h - 1)
        @test all(abs(Int(head[i]) - Int(rgb(p.o)[i])) < 45 for i in 1:3)   # la tête de lecture, de la couleur du « maintenant »
        # la note 7 du slot du curseur, en haut de sa ligne ; la note 0 en bas
        y = (l2.row - sc.y) * 16
        @test Ressac._px_at(c, c.w ÷ 2 + 6, y + 3) != Ressac._px_at(c, c.w ÷ 2 + 6, y + 9)
        # en grand : le rouleau du slot du curseur, sans rien demander
        @test [(pn.kind, pn.slot) for pn in sc.panels] == [(:pianoroll, :d2)]
        lay = Ressac._panel_layout(sc)
        @test length(lay) == 1 && lay[1][1] + lay[1][2] == sc.h && 4 <= lay[1][2] <= 8
        # un visuel demandé dans le pattern reste, où que soit le curseur — et ne change pas ce qui joue
        before = Ressac.pattern_get(sched, :d2)(0 // 1, 1 // 1)
        Tachikoma.set_text!(ed, "@d1 p\"bd sn\"\n@d2 n(\"0 7\") |> s(\"superpiano\") |> pitchwheel()")
        _tf_key(app, 'E'); ed.cursor_row = 1; draw()
        sc = app.pixel_scene
        @test isempty(sc.panels)                                   # plus de rouleau du curseur : d1 n'a pas de hauteurs
        @test [(pn.kind, pn.slot) for (pn, _) in sc.inline] == [(:pitchwheel, :d2)]
        r = sc.inline[1][2]
        after = Ressac.pattern_get(sched, :d2)(0 // 1, 1 // 1)
        @test [(e.start, e.stop) for e in after] == [(e.start, e.stop) for e in before]
        # le visuel s'ouvre SOUS son slot, sur la largeur du texte, et pousse la suite
        lines_scr = split(draw(), "\n")
        y2 = findfirst(l -> occursin("@d2", l), lines_scr)
        @test r.y == y2 + 1 && r.height == Ressac._VIEW_ROWS && r.x < sc.x && r.x + r.width == sc.x + sc.w
        @test r in Ressac._PIXEL_HOLES
        c = Ressac._paint_inline(sc.inline[1][1], r.width * 8, r.height * 16, 16, sc.phase, false)
        top = (c.w ÷ 2, 5)                                         # le do, en haut de la roue : une note du cycle
        @test Ressac._px_at(c, top...) != rgb(p.bg)
        for kind in (:pianoroll, :punchcard, :spiral, :scope)      # chaque visuel se peint
            cc = Ressac._paint_inline(Ressac.PixelPanel(kind, :d2, sc.inline[1][1].notes, false), 320, 96, 16, 0.3, false)
            @test (cc.w, cc.h) == (320, 96) && any(i -> Ressac._px_at(cc, i % 320, i ÷ 320) != rgb(p.bg), 0:(320 * 96 - 1))
        end
        # ce qui flotte cache l'image : sous une surface, les cellules de la zone reprennent un fond
        open_before = tb_hole_open_cells(app)
        _tf_key(app, ' '); draw()
        @test 0 <= tb_hole_open_cells(app) < open_before - 100     # le menu Espace prend sa place dans la zone
        _tf_key(app, :escape)
        # :pixels coupe
        _tf_ex(app, "pixels"); draw()
        @test app.pixel_scene === nothing
    finally
        Ressac._PIXELS_FORCE[] = old
        empty!(Ressac._PIXEL_HOLES)
        Ressac._LIVE_SCHEDULER[] = prev
    end
end

@testset "un drone tenu sur un son est relâché quand son bloc quitte le texte" begin
    (app, draw) = _tf_app()
    empty!(Ressac._DRONES)
    prev = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        ed = Ressac._patterns_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"bd\"\n\n@synth :tenu (freq=220) saw(:freq)")
        ed.cursor_row = 3
        _tf_key(app, 'D'); draw()
        @test Ressac.drone_get(:tenu) !== nothing
        ed.mode = :insert; Tachikoma.set_text!(ed, "@d1 p\"bd\""); draw()
        @test Ressac.drone_get(:tenu) !== nothing                  # en pleine frappe : on ne coupe pas
        ed.mode = :normal; draw()
        @test Ressac.drone_get(:tenu) === nothing
        @test any(l -> occursin("drone tenu relâché", l), app.logs)
    finally
        Ressac._LIVE_SCHEDULER[] = prev
        Ressac.drone_stop_all!()
    end
end

@testset "le graphe de calcul : pur, de haut en bas — e reprend tout ce qui dépend du bloc" begin
    _with_live_app() do app, frame
        ed = Ressac._patterns_editor(app)
        Tachikoma.set_text!(ed, join([
            "cg_a = 2",
            "cg_b = cg_a * 10",
            "cg_f(x) = x + cg_a",
            "cg_c = cg_f(cg_b)",
            "cg_k = 1",
            "cg_k = cg_k + cg_a",
            "cg_autre = 5",
            "@d1 p\"bd\" |> fast(cg_c)",
            "@d2 p\"hh\" |> fast(cg_autre)",
            "@d3 p\"cp\" |> fast(cg_k)",
            "cg_seul = cg_seul_avant + cg_a"], "\n"))
        Core.eval(Main, :(cg_seul_avant = 0; cg_seul = 0))
        _tf_key(app, 'E')
        @test Core.eval(Main, :cg_c) == 22 && Core.eval(Main, :cg_k) == 3
        d1 = Ressac.pattern_get(app.scheduler, :d1); d2 = Ressac.pattern_get(app.scheduler, :d2)
        set_a(v) = (Tachikoma.set_text!(ed, replace(Tachikoma.text(ed), r"cg_a = \d+" => "cg_a = $v"; count = 1));
                    ed.cursor_row = 1; empty!(app.logs); _tf_key(app, 'e'))
        set_a(3)
        @test Core.eval(Main, :cg_b) == 30                      # b = a * 10, repris
        @test Core.eval(Main, :cg_c) == 33                      # par b, et par la fonction qui lit a
        @test Core.eval(Main, :cg_k) == 4                       # k = k + a repart de k = 1 : 1 + 3, pas 3 + 3
        @test Ressac.pattern_get(app.scheduler, :d1) !== d1     # le slot qui lit c repart
        @test Ressac.pattern_get(app.scheduler, :d2) === d2     # celui qui n'en dépend pas ne bouge pas
        @test length(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1)) == 33
        @test length(Ressac.pattern_get(app.scheduler, :d3)(0 // 1, 1 // 1)) == 4
        @test any(l -> occursin("cascade :", l) && occursin("cg_f", l) && occursin("3 slot", l) == false && occursin("2 slots", l), app.logs)
        # pur : la même évaluation, autant de fois qu'on veut, donne le même résultat
        _tf_key(app, 'e'); _tf_key(app, 'e')
        @test Core.eval(Main, :cg_k) == 4
        # e sur la ligne qui se relit : elle aussi repart de sa première valeur
        ed.cursor_row = 6; _tf_key(app, 'e'); _tf_key(app, 'e')
        @test Core.eval(Main, :cg_k) == 4
        # l'ordre du résultat ne dépend pas de l'ordre où l'on a évalué
        set_a(5)
        @test Core.eval(Main, :cg_k) == 6 && Core.eval(Main, :cg_c) == 55
    end
    # un bloc qui se lit lui-même sans valeur de départ : pas rejoué, et c'est dit
    _with_live_app() do app, frame
        ed = Ressac._patterns_editor(app)
        Core.eval(Main, :(cg_z = 10))
        Tachikoma.set_text!(ed, "cg_y = 1\ncg_z = cg_z + cg_y")
        ed.cursor_row = 1
        _tf_key(app, 'e')
        @test Core.eval(Main, :cg_z) == 10
        @test any(l -> occursin("cg_z se lit lui-même sans valeur de départ", l), app.logs)
    end
    # le plan, à nu : la chaîne d'un nom est rejouée en entier, dans l'ordre
    (nodes, _) = Ressac._calc_nodes(["n = 0", "a = 1", "n = n + a", "m = n * 2", "n = 7", "q = n"], 2, 2)
    (order, bad) = Ressac._calc_plan(nodes)
    @test [nodes[i].row for i in order] == [1, 2, 3, 4, 5] && isempty(bad)     # q lit n = 7, qui ne change pas : pas repris
end

@testset "des rangées sous les slots : les réglages s'ouvrent sous le bloc qui joue" begin
    _with_live_app() do app, frame
        tb = Tachikoma.TestBackend(140, 30)
        fr = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 30), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        draw() = (Tachikoma.reset!(tb.buf); Tachikoma.view(app, fr); [rstrip(Tachikoma.row_text(tb, y)) for y in 1:30])
        ed = Ressac._patterns_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"bd sn\" |> gain(0.9) |> lpf(900)\n@d2 n(\"0 7\") |> s(\"superpiano\")\nx = 1")
        ed.cursor_row = 1; ed.cursor_col = 0
        rows = draw()
        y1 = findfirst(l -> occursin("@d1", l), rows)
        @test occursin("@d2", rows[y1 + 1])                        # rien ne joue : le texte est serré
        _tf_key(app, 'E'); rows = draw()
        y1 = findfirst(l -> occursin("@d1", l), rows)
        @test occursin("╰ gain ", rows[y1 + 1]) && occursin("lpf ", rows[y1 + 1]) && occursin("●", rows[y1 + 1])
        @test !occursin(r"\d", first(split(rows[y1 + 1], "╰")))       # la rangée n'a pas de numéro de ligne
        @test occursin("@d2", rows[y1 + 2]) && occursin("x = 1", rows[y1 + 3])   # d2 n'a pas de réglage : pas de rangée
        @test Ressac._gap_before(ed, 2) == 1 && Ressac._text_row_at(ed, 1) === nothing && Ressac._text_row_at(ed, 2) == 2
        # les notes d'une mini-notation ne sont pas des réglages
        @test isempty(Ressac._block_knobs(ed, 2, 2))
        # un clic sur la rangée ne tombe sur aucune ligne ; sur la ligne d'après, sur la bonne
        rect = Ressac._focused_editor_rect(app)
        @test Ressac._screen_to_editor_pos(ed, rect, rect.x + 8, y1 + 1) === nothing
        @test Ressac._screen_to_editor_pos(ed, rect, rect.x + 8, y1 + 2)[1] == 2
        # :rangées referme
        _tf_ex(app, "rangées"); rows = draw()
        @test occursin("@d2", rows[findfirst(l -> occursin("@d1", l), rows) + 1])
    end
end

end
