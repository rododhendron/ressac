# La disposition du clavier : table Maj AZERTY, détection, commande.
using Test
using Ressac
using Tachikoma

ev(cp, shift = true) = Tachikoma._kitty_keycode_to_event(cp, shift, false, false, Tachikoma.key_press)

@testset "clavier — la table AZERTY donne ? % . / et les chiffres" begin
    old = Ressac._KEYBOARD[]
    try
        Ressac.apply_keyboard_layout!(:azerty)
        @test ev(Int(',')).char == '?'
        @test ev(Int(';')).char == '.'
        @test ev(Int(':')).char == '/'
        @test ev(Int('!')).char == '§'
        @test ev(Int('&')).char == '1' && ev(Int('à')).char == '0'
        @test ev(Int('ù')).char == '%' && ev(Int('<')).char == '>'
        @test ev(Int('a')).char == 'A'
        # retour en QWERTY : la table d'origine de Tachikoma, plus les accents
        Ressac.apply_keyboard_layout!(:qwerty)
        @test ev(Int(',')).char == '<' && ev(Int('/')).char == '?' && ev(Int('1')).char == '!'
        @test ev(Int('ù')).char == '%' && ev(Int('é')).char == '2'
        @test_throws ArgumentError Ressac.apply_keyboard_layout!(:dvorak)
    finally
        Ressac.apply_keyboard_layout!(old)
    end
end

@testset "clavier — détection : variable, config, XKB, localectl, setxkbmap, LANG" begin
    @test Ressac._layout_from_xkb("fr") === :azerty
    @test Ressac._layout_from_xkb("fr,us") === :azerty && Ressac._layout_from_xkb("fr(oss)") === :azerty
    @test Ressac._layout_from_xkb("be") === :azerty && Ressac._layout_from_xkb("us") === :qwerty
    @test Ressac._layout_from_xkb("de") === :qwerty && Ressac._layout_from_xkb("") === nothing
    @test Ressac._parse_localectl("   System Locale: LANG=fr_FR.UTF-8\n    VC Keymap: (unset)\n   X11 Layout: fr\n") === :azerty
    @test Ressac._parse_localectl("rien") === nothing
    @test Ressac._parse_setxkbmap("rules:      evdev\nmodel:      pc105\nlayout:     us\n") === :qwerty
    env(; kw...) = Dict{String,String}(String(k) => v for (k, v) in kw)
    @test Ressac.detect_keyboard_layout(; env = env(RESSAC_KEYBOARD = "azerty")) == (:azerty, "RESSAC_KEYBOARD")
    @test Ressac.detect_keyboard_layout(; env = env(RESSAC_KEYBOARD = "us")) == (:qwerty, "RESSAC_KEYBOARD")
    @test Ressac.detect_keyboard_layout(; env = env(), cfg = :azerty) == (:azerty, "ressac.toml")
    @test Ressac.detect_keyboard_layout(; env = env(XKB_DEFAULT_LAYOUT = "fr")) == (:azerty, "XKB_DEFAULT_LAYOUT")
    # sans commande système ni indice : LANG, puis le défaut
    r = Ressac.detect_keyboard_layout(; env = env(LANG = "fr_FR.UTF-8"))
    @test r[1] === :azerty && r[2] in ("localectl", "LANG")
    r = Ressac.detect_keyboard_layout(; env = env(LANG = "C"))
    @test r[2] in ("localectl", "défaut")
    @test Ressac._cmd_output(["commande-qui-nexiste-pas-xyz"]) == ""
    @test Ressac._cmd_output(["sleep", "5"]; timeout = 0.2) == ""       # borné
end

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

@testset "clavier — :keyboard change la table en session" begin
    old = Ressac._KEYBOARD[]
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame); Ressac._PANE_MODE.active = false; Ressac._active_editor(app).mode = :normal
    ex(cmd) = (Tachikoma.update!(app, Tachikoma.KeyEvent(':')); foreach(c -> Tachikoma.update!(app, Tachikoma.KeyEvent(c)), cmd); Tachikoma.update!(app, Tachikoma.KeyEvent(:enter)))
    try
        ex("keyboard azerty")
        @test Ressac._KEYBOARD[] === :azerty && occursin("azerty", app.logs[end])
        # Maj+, envoyé par un terminal sans touches alternatives ouvre l'aide
        Tachikoma.update!(app, ev(Int(',')))
        @test app.modal === :help
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
        ex("keyboard qwerty"); @test Ressac._KEYBOARD[] === :qwerty
        ex("keyboard"); @test occursin("qwerty", app.logs[end])
        ex("keyboard colemak"); @test occursin("WARN", app.logs[end])
        ex("clavier auto"); @test Ressac._KEYBOARD[] in (:azerty, :qwerty) && occursin("clavier :", app.logs[end])
    finally
        Ressac.apply_keyboard_layout!(old)
    end
end
