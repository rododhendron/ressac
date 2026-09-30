# Le tour du clavier : chaque pane reçoit chacune de ses touches, sans
# exception et en restant rendable ; et les priorités du pipeline
# (`_KEY_STAGES`) tiennent depuis n'importe quelle pane.
using Test
using Ressac
using Tachikoma

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _kt_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    for leaf in Ressac._all_leaves(ws.tree)          # repli sur la pane patterns seule
        if any(t -> t isa Ressac.EditorPane, leaf.tabs)
            ws.tree = leaf; ws.focused_pane = leaf.id; break
        end
    end
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_kt_key(app, k) = Tachikoma.update!(app, Tachikoma.KeyEvent(k))
function _kt_sandbox(f)
    dir = mktempdir(); mkpath(joinpath(dir, "plugins", "user-synths"))
    old = pwd(); cd(dir)
    try f() finally cd(old) end
end

"""
    _events_for_chord(chord) -> Vector{KeyEvent}

L'inverse de `Ressac.keyname` : « Ctrl-d » → Ctrl+d, « PgDn » → :pagedown,
« Space d » → Espace puis d. Les plages documentaires (« a-z », « 1-9 »)
donnent leur première touche.
"""
function _events_for_chord(chord::AbstractString)
    special = Dict(v => k for (k, v) in Ressac._SPECIAL_KEYNAMES)
    out = Tachikoma.KeyEvent[]
    for part in split(chord, ' ')
        if startswith(part, "Ctrl-") && length(part) == 6
            push!(out, Tachikoma.KeyEvent(:ctrl, part[end]))
        elseif haskey(special, part)
            push!(out, Tachikoma.KeyEvent(special[part]))
        elseif part == "Space"
            push!(out, Tachikoma.KeyEvent(' '))
        elseif length(part) == 1
            push!(out, Tachikoma.KeyEvent(part[1]))
        elseif occursin(r"^.-.$", part)                   # « a-z », « 1-9 » : plage documentaire
            push!(out, Tachikoma.KeyEvent(part[1]))
        else
            return Tachikoma.KeyEvent[]                    # « Esc / q », « Bksp »… déjà couverts ailleurs
        end
    end
    return out
end

@testset "pipeline — quinze étapes ordonnées" begin
    @test length(Ressac._KEY_STAGES) == 15
    @test Ressac._KEY_STAGES[1] === Ressac._stage_hover!            # la bulle de glossaire se ferme avant tout
    @test Ressac._KEY_STAGES[2] === Ressac._stage_command_line!
    @test Ressac._KEY_STAGES[end] === Ressac._stage_editor!
    @test _events_for_chord("Ctrl-d") == [Tachikoma.KeyEvent(:ctrl, 'd')]
    @test _events_for_chord("PgDn")[1].key === :pagedown
    @test _events_for_chord("Space d") == [Tachikoma.KeyEvent(' '), Tachikoma.KeyEvent('d')]
end

# Chaque pane : on l'ouvre, on lui envoie chacune de ses touches liées
# (une action, pas une entrée documentaire), on re-rend après chacune.
# Une modale ouverte par une touche est refermée pour que la suivante
# aille encore à la pane.
const _KT_PANES = [
    (:log, :log), (:doc, :doc), (:wiki, :wiki), (:notes, :notes),
    (:tuning, :tuning), (:waveform, :waveform), (:explorer, :explorer),
]
@testset "tour des panes — $(kind)" for (kind, scope) in _KT_PANES
    _kt_sandbox() do
        app, tb, frame = _kt_app()
        Ressac.cmd_vsplit!(app.workspaces, String(kind), Dict{String,Any}())
        Tachikoma.view(app, frame)
        p = Ressac._focused_pane_impl(app)
        @test p !== nothing && Ressac.pane_scope(p) === scope
        p === nothing && return
        tried = 0
        for b in Ressac.bindings(scope)
            b.action === nothing && continue
            for chord in b.keys
                evs = _events_for_chord(chord)
                isempty(evs) && continue
                tried += 1
                ok = try
                    foreach(e -> Tachikoma.update!(app, e), evs)
                    Tachikoma.view(app, frame)
                    true
                catch err
                    @error "touche « $chord » de $(scope) ($(b.label))" exception = (err, catch_backtrace())
                    false
                end
                @test ok
                # une modale ouverte par la touche ? on la referme
                app.modal === :none || (_kt_key(app, :escape); app.modal === :none || (app.modal = :none))
                Ressac._PANE_MODE.active = false
                # la pane a été fermée ou remplacée ? on la rouvre
                if Ressac._focused_pane_impl(app) !== p
                    Ressac.cmd_vsplit!(app.workspaces, String(kind), Dict{String,Any}())
                    Tachikoma.view(app, frame)
                    p = Ressac._focused_pane_impl(app)
                    p === nothing && break
                end
            end
        end
        @test tried > 0
    end
end

@testset "pane sans touches (scope) — tout va au scope global" begin
    app, tb, frame = _kt_app()
    Ressac.cmd_vsplit!(app.workspaces, "scope", Dict{String,Any}())
    Tachikoma.view(app, frame)
    @test Ressac._focused_pane_impl(app) isa Ressac.ScopePane
    _kt_key(app, 'j')                                  # ignorée, sans exception
    _kt_key(app, '?'); @test app.modal === :help       # le global répond
    _kt_key(app, :escape); @test app.modal === :none
    @test (Tachikoma.view(app, frame); true)
end

@testset "priorités depuis une pane latérale" begin
    app, tb, frame = _kt_app()
    Ressac.cmd_vsplit!(app.workspaces, "wiki", Dict{String,Any}())
    Tachikoma.view(app, frame)
    wp = Ressac._focused_pane_impl(app)
    @test wp isa Ressac.WikiPane
    # la pane reçoit ses touches, y compris depuis le pavé numérique
    _kt_key(app, 'j'); @test wp.pane.offset == 1
    _kt_key(app, :kp_down); @test wp.pane.offset == 2
    _kt_key(app, :kp_up); @test wp.pane.offset == 1
    # la barre de commande prend tout : « j » va dans la commande, pas au wiki
    _kt_key(app, ':'); @test Ressac.is_active(app.command_line)
    _kt_key(app, 'j'); @test wp.pane.offset == 1
    _kt_key(app, :escape); @test !Ressac.is_active(app.command_line)
    # `?` depuis la pane : le scope global ouvre l'aide
    _kt_key(app, '?'); @test app.modal === :help
    _kt_key(app, :escape); @test app.modal === :none
    # une modale possède les touches : « j » filtre la palette, le wiki ne bouge pas
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'p')); @test app.modal === :palette
    _kt_key(app, 'j'); @test Ressac._picker_query(app.palette) == "j" && wp.pane.offset == 1
    _kt_key(app, :escape); @test app.modal === :none
    # panic depuis la pane latérale : les patterns s'arrêtent (le panic vise le scheduler live)
    old_live = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        Ressac.set_pattern!(app.scheduler, :d1, Ressac.pat("bd"))
        _kt_key(app, '!'); @test isempty(app.scheduler.patterns)
    finally
        Ressac._LIVE_SCHEDULER[] = old_live
    end
    # Ctrl-w j/k/l… : le mode pane reste joignable depuis la pane
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')); @test Ressac._PANE_MODE.active
    _kt_key(app, :escape); @test !Ressac._PANE_MODE.active
end
