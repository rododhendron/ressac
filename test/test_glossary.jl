# Glossaire : fiches en anglais étiquetées glossary, index des termes,
# soulignement dans le markdown, bulle de survol (ouverture, suivi,
# verrou par le temps ou l'entrée de la souris, bulles en chaîne, sortie
# de la souris, Esc / touche).
using Test
using Ressac
using Tachikoma

if !@isdefined(_GLMock)
    mutable struct _GLMock
        sent::Vector{Vector{UInt8}}
    end
    _GLMock() = _GLMock(Vector{UInt8}[])
    Ressac.send_osc(c::_GLMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

# Les fiches du plugin core (la suite les charge dans runtests ; seul, on le fait ici).
isempty([e for e in values(Ressac._DOCS) if :glossary in e.tags]) &&
    Ressac._handle_docs(joinpath(@__DIR__, "..", "plugins", "core"), Dict("dir" => "docs"), "core")

function _gl_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_GLMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(140, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    return app, tb, frame
end
function _gl_screen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
_gl_move(app, x, y) = Tachikoma.update!(app, Tachikoma.MouseEvent(x, y, Tachikoma.mouse_none, Tachikoma.mouse_move, false, false, false))
_gl_click(app, x, y) = Tachikoma.update!(app, Tachikoma.MouseEvent(x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))

@testset "glossaire — fiches, index, termes" begin
    names = [e.name for e in values(Ressac._DOCS) if :glossary in e.tags]
    @test length(names) >= 80
    @test "distortion" in names && "envelope" in names && "cutoff" in names
    for e in values(Ressac._DOCS)
        :glossary in e.tags || continue
        @test !isempty(e.short)
        # tout en anglais : pas d'accents ni de mots-outils français dans la phrase courte
        @test !occursin(r"[àâçéèêëîïôûùü]", e.short)
        @test !occursin(r"\b(le|la|les|une|des|est|pour)\b", e.short)
    end
    @test Ressac.glossary_term("Distortion") == "distortion"
    @test Ressac.glossary_term("LPF") == "low-pass filter"
    @test Ressac.glossary_term("overtones") == "harmonic"
    @test Ressac.glossary_term("cutoff") == "cutoff"                     # fusionné dans la fiche du contrôle
    @test Ressac.lookup_doc("cutoff").short == "Frequency of the synth's internal filter (Hz). Lower = darker."
    @test occursin("Sweep it with an LFO", Ressac.lookup_doc("cutoff").body)
    @test Ressac.glossary_term("banana") === nothing

    t = "a low-pass filter tames the distortion"
    @test Ressac._glossary_term_at(t, 5) == "low-pass filter"
    @test Ressac._glossary_term_at(t, 16) == "low-pass filter"           # « filter » dans le terme long
    @test Ressac._glossary_term_at(t, 33) == "distortion"
    @test Ressac._glossary_term_at(t, 25) === nothing                    # « tames »
    @test Ressac._glossary_term_at("filters", 3) == "filter"             # alias au pluriel
    @test Ressac._glossary_term_at("prefilter", 5) === nothing           # pas au milieu d'un mot
end

@testset "glossaire — soulignement dans le markdown" begin
    spans = Ressac._md_inline("Some distortion and `code envelope` here")
    ul = [sp.content for sp in spans if sp.style.underline]
    @test ul == ["distortion"]
    @test join(sp.content for sp in spans) == "Some distortion and code envelope here"
    lines = Ressac._glossary_lines("distortion", 40)
    @test !isempty(lines) && lines[1][1].style.bold
    @test any(l -> any(sp -> sp.style.underline && sp.content == "saturation", l), lines)   # « See also »
end

@testset "glossaire — bulle au survol" begin
    app, tb, frame = _gl_app()
    now = Ref(100.0)
    old_clock = Ressac._HOVER_CLOCK[]
    Ressac._HOVER_CLOCK[] = () -> now[]
    try
        # une pane DOC à droite dans PLAY montre la fiche « distortion »
        doc = Ressac._find_pane(app, Ressac.DocPane)
        @test doc !== nothing
        doc.name = "distortion"; doc.follow = false
        scr = _gl_screen(app, tb, frame)
        a = doc.pane.last_area
        @test a.width > 10
        # la ligne « See also: saturation, clipping… » de la fiche, défilée à l'écran
        row = findfirst(l -> occursin("saturation", join(sp.content for sp in l)), doc.pane.content)
        @test row !== nothing
        row > a.height && (doc.pane.offset = row - a.height; scr = _gl_screen(app, tb, frame))
        txt = join(sp.content for sp in doc.pane.content[row])
        col = findfirst("saturation", txt)[1]
        x = a.x + col - 1; y = a.y + (row - doc.pane.offset) - 1

        # survol : la bulle s'ouvre, non verrouillée
        _gl_move(app, x, y)
        @test app.hover !== nothing && length(app.hover.boxes) == 1
        @test app.hover.boxes[1].term == "saturation" && !app.hover.locked
        scr = _gl_screen(app, tb, frame)
        @test occursin("saturation", scr) && occursin("Gentle distortion that rounds off the peaks", scr)
        # rester sur le terme ne change rien ; en sortir (sans entrer dans la bulle) ferme
        _gl_move(app, x + 1, y)
        @test app.hover !== nothing
        b = app.hover.boxes[1]
        far = (b.y > y ? b.y - 1 : b.y + b.h)      # une ligne hors de la bulle et du terme
        _gl_move(app, 2, 3)
        @test app.hover === nothing

        # verrou par le temps : après 3 s, sortir du terme ne ferme plus
        _gl_move(app, x, y)
        now[] += 3.5
        _gl_move(app, x + 1, y)
        @test app.hover !== nothing && app.hover.locked
        # entrer dans la bulle, survoler « clipping » : une seconde bulle à côté
        b = app.hover.boxes[1]
        r2 = findfirst(l -> occursin("clipping", join(sp.content for sp in l)), b.lines)
        @test r2 !== nothing
        t2 = join(sp.content for sp in b.lines[r2])
        c2 = findfirst("clipping", t2)[1]
        _gl_move(app, b.x + c2, b.y + r2)
        @test length(app.hover.boxes) == 2 && app.hover.boxes[2].term == "clipping"
        scr = _gl_screen(app, tb, frame)
        @test occursin("Cutting the waveform flat", scr)
        # revenir dans la première bulle garde la chaîne ; en sortir de toutes ferme
        _gl_move(app, b.x + 1, b.y + 1)
        @test length(app.hover.boxes) == 2
        _gl_move(app, 2, 3)
        @test app.hover === nothing

        # verrou par l'entrée de la souris avant 3 s
        _gl_move(app, x, y)
        b = app.hover.boxes[1]
        _gl_move(app, b.x + 2, b.y + 1)
        @test app.hover.locked
        # Esc ferme et est consommé ; une autre touche ferme et passe
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
        @test app.hover === nothing
        _gl_move(app, x, y)
        @test app.hover !== nothing
        Tachikoma.update!(app, Tachikoma.KeyEvent('j'))
        @test app.hover === nothing
        # un clic dans la bulle verrouille ; un clic dehors ferme
        _gl_move(app, x, y)
        b = app.hover.boxes[1]
        _gl_click(app, b.x + 2, b.y + 1)
        @test app.hover !== nothing && app.hover.locked
        _gl_click(app, 2, 3)
        @test app.hover === nothing

        # désactivé par la config : rien ne s'ouvre
        cfg = Ressac.ressac_config()
        old = cfg.hover; cfg.hover = false
        _gl_move(app, x, y)
        @test app.hover === nothing
        cfg.hover = old
    finally
        Ressac._HOVER_CLOCK[] = old_clock
    end
end

@testset "glossaire — survol dans l'éditeur focalisé" begin
    app, tb, frame = _gl_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, "# a resonance sweep\n@d1 \"bd*4\"\n"); ed.mode = :normal
    _gl_screen(app, tb, frame)
    rect = Ressac._focused_editor_rect(app)
    @test rect !== nothing
    # la colonne de « resonance » sur la ligne 1 : on cherche la cellule qui la rend
    y = rect.y
    xs = [x for x in rect.x:(rect.x + rect.width - 1) if (rc = Ressac._screen_to_editor_pos(ed, rect, x, y)) !== nothing && rc[1] == 1 && 5 <= rc[2] <= 12]
    @test !isempty(xs)
    _gl_move(app, xs[1], y)
    @test app.hover !== nothing && app.hover.boxes[1].term == "resonance"
end
