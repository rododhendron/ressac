include(joinpath(@__DIR__, "helpers.jl"))
# Les sorties audio et le casque — étape E7. Rien ici n'appelle PipeWire ni
# SuperCollider : `pw-dump` est une capture, `pw-link` un témoin.

const _AO_JSON = read(joinpath(@__DIR__, "fixtures", "pipewire", "pw-dump.json"), String)
const _AO_SPK = "alsa_output.usb-Generic_USB_Audio-00.HiFi__Speaker__sink"
const _AO_HP  = "alsa_output.usb-Generic_USB_Audio-00.HiFi__Headphones__sink"
const _AO_BT  = "bluez_output.AA_BB_CC_DD_EE_FF.1"
_ao_has(osc, addr) = any(b -> occursin(addr, String(copy(b))), osc.sent)

@testset "sorties audio" begin

    @testset "lire pw-dump : les sorties, les ports de SuperCollider, les liens" begin
        g = Ressac.parse_pw_dump(_AO_JSON)
        @test [s.label for s in g.sinks] == ["Enceinte mono", "USB Audio Front Headphones", "USB Audio Speakers", "Casque Bluetooth"]   # le Bluetooth en dernier
        spk = g.sinks[3]
        @test spk.name == _AO_SPK && spk.ports == ["$(_AO_SPK):playback_FL", "$(_AO_SPK):playback_FR"]   # gauche avant droite, pas de moniteurs
        @test !spk.bluetooth && !spk.default
        @test g.sinks[4].bluetooth && g.sinks[4].default
        @test g.sc_outs == ["SuperCollider:out_$k" for k in 1:4]
        @test ("SuperCollider:out_1" => "$(_AO_SPK):playback_FL") in g.links
        @test ("LibreWolf:output_FL" => "$(_AO_BT):playback_FL") in g.links
        # Ce qu'elle ne reconnaît pas ne la fait pas lever.
        @test isempty(Ressac.parse_pw_dump("[]").sinks)
        @test isempty(Ressac.parse_pw_dump("{}").sinks)
        @test isempty(Ressac.parse_pw_dump("[{\"type\":\"PipeWire:Interface:Node\"},{\"id\":3},42]").sinks)
    end

    @testset "le plan de routage : 1-2 vers la sortie, 3-4 vers le casque" begin
        g = Ressac.parse_pw_dump(_AO_JSON)
        # La sortie principale sur le casque filaire, le casque sur le Bluetooth.
        (add, remove, problems) = Ressac.routing_plan(g, _AO_HP, _AO_BT)
        @test isempty(problems)
        @test add == ["SuperCollider:out_1" => "$(_AO_HP):playback_FL", "SuperCollider:out_2" => "$(_AO_HP):playback_FR",
                      "SuperCollider:out_3" => "$(_AO_BT):playback_FL", "SuperCollider:out_4" => "$(_AO_BT):playback_FR"]
        @test remove == ["SuperCollider:out_1" => "$(_AO_SPK):playback_FL", "SuperCollider:out_2" => "$(_AO_SPK):playback_FR"]
        # Déjà branché comme voulu : rien à faire.
        (add, remove, problems) = Ressac.routing_plan(g, _AO_SPK, "")
        @test isempty(add) && isempty(remove) && isempty(problems)
        # Sans sortie choisie, on ne touche pas à 1-2.
        (add, remove, _) = Ressac.routing_plan(g, "", _AO_HP)
        @test all(p -> first(p) in ("SuperCollider:out_3", "SuperCollider:out_4"), add) && isempty(remove)
        # Une sortie mono reçoit la gauche et la droite.
        (add, _, _) = Ressac.routing_plan(g, "alsa_output.mono-fallback", "")
        @test last.(add) == ["alsa_output.mono-fallback:playback_MONO", "alsa_output.mono-fallback:playback_MONO"]
        # Retirer le casque défait ses liens ; un lien vers autre chose qu'une sortie (un enregistreur) reste.
        g2 = Ressac.AudioGraph(g.sinks, g.sc_outs, vcat(g.links, ["SuperCollider:out_3" => "$(_AO_BT):playback_FL",
                                                               "SuperCollider:out_1" => "Enregistreur:input_FL"]))
        (add, remove, _) = Ressac.routing_plan(g2, _AO_SPK, "")
        @test isempty(add) && remove == ["SuperCollider:out_3" => "$(_AO_BT):playback_FL"]
        # Ce qui empêche de router est dit.
        @test occursin("n'est plus là", only(Ressac.routing_plan(g, _AO_SPK, "bluez_output.eteint")[3]))
        nosc = Ressac.AudioGraph(g.sinks, String[], g.links)
        (add, remove, problems) = Ressac.routing_plan(nosc, _AO_SPK, _AO_BT)
        @test isempty(add) && isempty(remove) && occursin("SuperCollider n'est pas lancé", only(problems))
        two = Ressac.AudioGraph(g.sinks, g.sc_outs[1:2], g.links)
        @test occursin("il en faut 4", only(Ressac.routing_plan(two, _AO_SPK, _AO_BT)[3]))
    end

    @testset "apply_routing! : pw-link, et ce qui échoue est rapporté" begin
        old = Ressac._PW_LINK[]
        calls = Vector{String}[]
        try
            g = Ressac.parse_pw_dump(_AO_JSON)
            Ressac._PW_LINK[] = args -> (push!(calls, args); true)
            (done, problems) = Ressac.apply_routing!(g, _AO_HP, _AO_BT)
            @test done == 6 && isempty(problems)
            @test calls[1] == ["-d", "SuperCollider:out_1", "$(_AO_SPK):playback_FL"]      # défaire d'abord
            @test ["SuperCollider:out_3", "$(_AO_BT):playback_FL"] in calls
            Ressac._PW_LINK[] = args -> error("pw-link introuvable")
            (done, problems) = Ressac.apply_routing!(g, _AO_HP, "")
            @test done == 0 && any(p -> occursin("lien refusé", p), problems)
            # pw-dump qui manque : un graphe vide et la raison
            oldd = Ressac._PW_DUMP[]
            Ressac._PW_DUMP[] = () -> error("boom")
            (g0, note) = Ressac.audio_graph()
            @test isempty(g0.sinks) && occursin("pw-dump", note)
            Ressac._PW_DUMP[] = oldd
        finally
            Ressac._PW_LINK[] = old
        end
    end

    @testset ":sorties — choisir la sortie et le casque, les essais au casque" begin
        oldd = Ressac._PW_DUMP[]; oldl = Ressac._PW_LINK[]; olds = Ressac._AUDIO_SETTINGS[]
        calls = Vector{String}[]
        Ressac._PW_DUMP[] = () -> _AO_JSON
        Ressac._PW_LINK[] = args -> (push!(calls, args); true)
        Ressac._AUDIO_SETTINGS[] = nothing
        rm(Ressac._audio_settings_path(); force = true)
        try
            _with_live_app() do app, frame
                osc = app.scheduler.osc
                # sans casque, :casque dit quoi faire
                _exec_ex_command!(app, "casque")
                @test occursin("pas de casque choisi", app.logs[end]) && !Ressac._audio_settings().preview
                _exec_ex_command!(app, "sorties")
                @test app.modal === :outputs && length(app.audio_graph.sinks) == 4
                Tachikoma.view(app, frame)
                buf = frame.buffer
                screen() = (Tachikoma.view(app, frame); join((join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:buf.area.height), "\n"))
                scr = screen()
                @test occursin("SORTIES", scr) && occursin("USB Audio Speakers", scr) && occursin("Bluetooth : le son arrive en retard", scr)
                @test occursin("Pas de casque", scr)
                # Entrée sur la 2e ligne : le casque filaire devient la sortie principale
                _key!(app, 'j'); _key!(app, :enter)
                s = Ressac._audio_settings()
                @test s.main == _AO_HP && s.casque == ""
                @test ["SuperCollider:out_1", "$(_AO_HP):playback_FL"] in calls
                @test ["-d", "SuperCollider:out_1", "$(_AO_SPK):playback_FL"] in calls
                @test occursin("◉ sortie USB Audio Front Headphones", screen())
                # c sur le Bluetooth : le casque ; SuperCollider est prévenu
                _key!(app, 'G'); _key!(app, 'c')
                @test s.casque == _AO_BT
                @test ["SuperCollider:out_3", "$(_AO_BT):playback_FL"] in calls
                @test _ao_has(osc, "/ressac/casque") && _ao_has(osc, "/ressac/previewOut")
                @test occursin("◎ casque Casque Bluetooth", screen())
                # c sur la sortie principale : refusé, elle ne peut pas être les deux
                _key!(app, 'g'); _key!(app, 'j'); _key!(app, 'c')
                @test s.casque == _AO_BT && occursin("déjà la sortie principale", app.logs[end])
                # p : les essais au casque seulement
                n0 = length(osc.sent)
                _key!(app, 'p')
                @test s.preview && length(osc.sent) > n0 && occursin("que lui seul entend", screen())
                # le réglage est gardé
                Ressac._AUDIO_SETTINGS[] = nothing
                s2 = Ressac._audio_settings()
                @test s2.main == _AO_HP && s2.casque == _AO_BT && s2.preview
                # la barre d'état le rappelle, modale fermée
                _key!(app, :escape)
                @test app.modal === :none && occursin("casque · essais", screen())
                _exec_ex_command!(app, "casque")
                @test !Ressac._audio_settings().preview && occursin("de nouveau partout", app.logs[end])
                # c de nouveau sur le casque : plus de casque, ses liens sont défaits
                _exec_ex_command!(app, "sorties"); _key!(app, 'G'); _key!(app, 'c')
                @test Ressac._audio_settings().casque == ""
            end
        finally
            Ressac._PW_DUMP[] = oldd; Ressac._PW_LINK[] = oldl; Ressac._AUDIO_SETTINGS[] = olds
            rm(Ressac._audio_settings_path(); force = true)
        end
    end

    @testset "un candidat de l'explorateur s'écoute par la voie des écoutes" begin
        osc = MockOSCClient()
        st = Ressac.AuditionState(2)
        Ressac.audition_play!(st, osc, 1, 220.0, 0.5)
        @test _ao_has(osc, "/ressac/preview") && !_ao_has(osc, "/ressac/play")
    end
end
