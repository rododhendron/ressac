using Test
using Ressac
import Tachikoma

# Réenregistre le kind :waveform si test_pane_interface a vidé le registre.
Base.include(Ressac, joinpath(@__DIR__, "..", "src", "pane_waveform.jl"))

@testset "waveform pane — viewer + zoom-to-pointer" begin
    # buffer sinus synthétique (pas de sclang)
    mkpane() = begin
        n = 44100
        s = Float32[sin(2π * 220 * i / 44100) for i in 0:(n - 1)]
        Ressac.WaveformPane(s, 44100, 1, n, "test", nothing, (0, 0, 0, 0))
    end

    @testset "ctor sans génome → pane vide" begin
        p = Ressac._pane_new(:waveform, Dict{String,Any}())
        @test p isa Ressac.WaveformPane
        @test isempty(p.samples)
        @test occursin("wave", lowercase(Ressac.title(p)))
    end

    @testset "render! draws without crashing + sets the draw rect" begin
        p = mkpane()
        tb = Tachikoma.TestBackend(80, 20)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 20), tb.buf)
        @test occursin("WAVE", Tachikoma.row_text(tb, 1))
        @test p.last_rect[3] > 0                      # largeur de tracé mémorisée
    end

    @testset "zoom-to-pointer keeps the sample under the cursor fixed" begin
        p = mkpane()
        p.last_rect = (1, 1, 80, 18)                  # x=1, w=80
        # curseur à 25% de la largeur
        x = 1 + round(Int, 0.25 * (80 - 1))
        f = (x - 1) / (80 - 1)
        anchor_before = p.view_start + round(Int, f * p.view_len)
        Ressac.handle_mouse!(p, Tachikoma.MouseEvent(x, 5, Tachikoma.mouse_scroll_up,
                                                     Tachikoma.mouse_press, false, false, false))
        @test p.view_len < 44100                      # zoom avant
        anchor_after = p.view_start + round(Int, f * p.view_len)
        @test abs(anchor_after - anchor_before) <= 2  # l'échantillon sous le curseur reste fixe
    end

    @testset "scroll down zooms out, bounded to the buffer" begin
        p = mkpane()
        p.last_rect = (1, 1, 80, 18); p.view_start = 20000; p.view_len = 4000
        Ressac.handle_mouse!(p, Tachikoma.MouseEvent(40, 5, Tachikoma.mouse_scroll_down,
                                                     Tachikoma.mouse_press, false, false, false))
        @test p.view_len > 4000
        @test p.view_start >= 1
        @test p.view_start + p.view_len - 1 <= length(p.samples)
    end

    @testset "h/l pan and 0 reset" begin
        p = mkpane(); p.view_len = 8000; p.view_start = 10000
        Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
        @test p.view_start > 10000
        Ressac.handle_key!(p, Tachikoma.KeyEvent('h'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('h'))
        @test p.view_start < 10000
        Ressac.handle_key!(p, Tachikoma.KeyEvent('0'))
        @test p.view_start == 1 && p.view_len == length(p.samples)
    end

    @testset "zoom maxi bornée (_WAVE_MIN_LEN)" begin
        p = mkpane(); p.view_len = 100; p.view_start = 1; p.last_rect = (1, 1, 80, 18)
        for _ in 1:20
            Ressac.handle_mouse!(p, Tachikoma.MouseEvent(40, 5, Tachikoma.mouse_scroll_up,
                                                         Tachikoma.mouse_press, false, false, false))
        end
        @test p.view_len >= Ressac._WAVE_MIN_LEN
    end

    @testset "serialize carries the genome when present" begin
        g = Ressac.archetype(:pluck)
        p = Ressac.WaveformPane(Float32[0.0], 44100, 1, 1, "g", g, (0, 0, 0, 0))
        d = Ressac.serialize(p)
        @test haskey(d, "genome")
        @test d["label"] == "g"
    end

    @testset "sculpt mode" begin
        function _g()
            g = Ressac.Genome()
            s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
            f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                                 Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
            g.output_id = f
            return g
        end
        mkscu() = Ressac._pane_new(:waveform, Dict{String,Any}(
            "genome" => Ressac.serialize_genome(_g()),
            "label" => "scu", "sculpt" => true))

        @testset "ctor builds knobs + starts in sculpt" begin
            p = mkscu()
            @test p.sculpt
            @test !isempty(p.knobs)
            @test length(p.labels) == length(p.knobs)
            @test p.focus == 1
        end

        @testset "7-arg legacy ctor still works (no sculpt)" begin
            s = Float32[0.0f0, 1.0f0]
            p = Ressac.WaveformPane(s, 44100, 1, 2, "x", nothing, (0, 0, 0, 0))
            @test !p.sculpt && isempty(p.knobs)
        end

        @testset "s toggles sculpt on a plain viewer" begin
            s = Float32[sin(2π * 220 * i / 44100) for i in 0:1000]
            p = Ressac.WaveformPane(s, 44100, 1, length(s), "v", nothing, (0, 0, 0, 0))
            @test !p.sculpt
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('s')) == true
            @test p.sculpt
        end

        @testset "j/k move focus and clamp at the ends" begin
            p = mkscu()
            Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
            @test p.focus == 2
            for _ in 1:50; Ressac.handle_key!(p, Tachikoma.KeyEvent('j')); end
            @test p.focus == length(p.knobs)
            for _ in 1:50; Ressac.handle_key!(p, Tachikoma.KeyEvent('k')); end
            @test p.focus == 1
        end

        @testset "h/l tug the focused knob and bump the render request" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            before = Ressac.knob_value(p.genome, p.knobs[ni])
            v0 = p.req_version
            Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
            @test Ressac.knob_value(p.genome, p.knobs[ni]) > before
            @test p.req_version > v0
        end

        @testset "in view mode, h/l still pan (context-dependent)" begin
            s = Float32[sin(2π * 220 * i / 44100) for i in 0:20000]
            p = Ressac.WaveformPane(s, 44100, 1, length(s), "v", nothing, (0, 0, 0, 0))
            p.view_len = 8000; p.view_start = 10000
            Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
            @test p.view_start > 10000
        end

        @testset "render! draws the knob strip in sculpt" begin
            p = mkscu()
            tb = Tachikoma.TestBackend(80, 20)
            Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 20), tb.buf)
            joined = join((Tachikoma.row_text(tb, r) for r in 1:20), "\n")
            @test occursin("SCULPT", joined)
        end

        @testset "tug → re-render swaps samples and learns a signature" begin
            old = Ressac._WAVE_RENDER[]; oldsync = Ressac._WAVE_SYNC[]
            Ressac._WAVE_RENDER[] = function (g)
                cut = 800.0
                for n in values(g.nodes), a in n.args
                    a isa Ressac.ConstArg && a.value > 50 && (cut = a.value)
                end
                f = cut / 44100 * 4
                s = Float32[sin(2π * f * 1000 * i / 44100) for i in 0:2000]
                return s, 44100
            end
            Ressac._WAVE_SYNC[] = true
            try
                p = mkscu()
                ni = findfirst(k -> k.kind === :node, p.knobs)
                p.focus = ni
                samples0 = copy(p.samples)
                Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                Ressac._sculpt_pump!(p)
                @test p.rendered_version == p.req_version
                @test p.samples != samples0
                @test !isempty(p.last_descr)
                Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                Ressac._sculpt_pump!(p)
                @test Ressac.n_signatures(p.sigs) >= 1
            finally
                Ressac._WAVE_RENDER[] = old; Ressac._WAVE_SYNC[] = oldsync
            end
        end

        @testset "reclustering never moves a knob (positions stable)" begin
            old = Ressac._WAVE_RENDER[]; oldsync = Ressac._WAVE_SYNC[]
            Ressac._WAVE_RENDER[] = (g -> (Float32[sin(2π * 110 * i / 44100) for i in 0:2000], 44100))
            Ressac._WAVE_SYNC[] = true
            try
                p = mkscu()
                names0 = [k.name for k in p.knobs]
                for _ in 1:6
                    Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                    Ressac._sculpt_pump!(p)
                end
                @test [k.name for k in p.knobs] == names0
            finally
                Ressac._WAVE_RENDER[] = old; Ressac._WAVE_SYNC[] = oldsync
            end
        end

        @testset "⏎ plays via the live audition path; no-op without a session" begin
            p = mkscu()
            @test Ressac._explorer_osc() === nothing
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter)) == true
        end

        @testset "serialize carries the sculpt flag → restored in sculpt" begin
            p = mkscu()
            d = Ressac.serialize(p)
            @test d["sculpt"] == true
            @test haskey(d, "genome")
            p2 = Ressac._pane_new(:waveform, d)
            @test p2.sculpt
            @test !isempty(p2.knobs)
        end

        @testset "e posts an export request carrying the edited genome" begin
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('e')) == true
            req = Ressac._EXPLORER_EXPORT_REQUEST[]
            @test req !== nothing
            _, dsl = req
            @test occursin("ressac-genome:", dsl)
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        end

        @testset "Tab jumps to the next NODE group (coarse nav), wraps" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)   # 1er knob du nœud RLPF
            p.focus = 1                                       # sur un control global
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:tab))   # → 1er knob du nœud
            @test p.focus == ni
            @test p.knobs[p.focus].kind === :node
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:tab))   # un seul autre groupe → wrap aux controls
            @test p.knobs[p.focus].kind === :control
            @test p.focus == 1
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:backtab))  # recule → retour au nœud
            @test p.focus == ni
        end

        @testset "= enters an exact value (beyond nominal range)" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            v0 = p.req_version
            Ressac.handle_key!(p, Tachikoma.KeyEvent('='))    # ouvre la saisie
            @test p.value_edit
            for c in "2500"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter)) # valide
            @test !p.value_edit
            @test Ressac.knob_value(p.genome, p.knobs[ni]) == 2500.0
            @test p.req_version > v0
        end

        @testset "Esc cancels value entry without changing the knob" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            before = Ressac.knob_value(p.genome, p.knobs[ni])
            Ressac.handle_key!(p, Tachikoma.KeyEvent('='))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('9'))
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
            @test !p.value_edit
            @test Ressac.knob_value(p.genome, p.knobs[ni]) == before
        end

        @testset "Space plays (alias of ⏎), no crash without a session" begin
            p = mkscu()
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent(' ')) == true
        end

        @testset "o swaps the focused node's UGen and re-enumerates" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            nid = p.knobs[ni].node_id
            before = p.genome.nodes[nid].ugen
            @test before === :RLPF
            v0 = p.req_version
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('o')) == true
            @test p.genome.nodes[nid].ugen !== before     # UGen changé
            @test Ressac.ugen_spec(p.genome.nodes[nid].ugen).role === :filter
            @test p.structure_dirty                       # explainer à rafraîchir
            @test p.req_version > v0                       # re-render demandé
            @test !isempty(p.knobs)                        # ré-énumérés
        end

        @testset "o on a global control knob is a no-op" begin
            p = mkscu()
            p.focus = 1                                    # 1er knob = control :freq
            @test p.knobs[1].kind === :control
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('o')) == true
            @test !p.structure_dirty                       # rien n'a changé
        end

        @testset "O swaps the UGen in reverse (opposite of o)" begin
            ni = findfirst(k -> k.kind === :node, mkscu().knobs)
            po = mkscu(); po.focus = ni; nido = po.knobs[ni].node_id
            Ressac.handle_key!(po, Tachikoma.KeyEvent('o'))
            after_o = po.genome.nodes[nido].ugen
            pO = mkscu(); pO.focus = ni; nidO = pO.knobs[ni].node_id
            @test Ressac.handle_key!(pO, Tachikoma.KeyEvent('O')) == true
            after_O = pO.genome.nodes[nidO].ugen
            @test after_o !== :RLPF && after_O !== :RLPF   # tous deux ont bougé
            @test pO.structure_dirty                        # explainer à rafraîchir
            @test after_o !== after_O                       # sens de cycle opposés
        end

        @testset "on_close! sets closed under lock + blocks pending writes" begin
            p = mkscu()
            Ressac.on_close!(p)
            @test p.closed
            # ce que fait le worker de rendu sous verrou : la garde `closed`
            # doit supprimer l'écriture dans `pending` (anti-zombie).
            lock(p.lock) do
                p.closed || (p.pending = (Float32[0.0f0], 44100, zeros(5), 99))
            end
            @test p.pending === nothing
            # un closed pane ne relance jamais de rendu, même en retard.
            p.req_version += 1
            Ressac._sculpt_pump!(p)
            @test !p.rendering
        end

        @testset "render failure resets the rendering flag so the pump retries" begin
            old = Ressac._WAVE_RENDER[]; oldsync = Ressac._WAVE_SYNC[]
            Ressac._WAVE_RENDER[] = (_ -> error("boom NRT"))
            Ressac._WAVE_SYNC[] = true
            try
                p = mkscu()
                p.req_version += 1
                Ressac._sculpt_pump!(p)
                @test !p.rendering                          # remis à false malgré l'erreur
                @test p.rendered_version < p.req_version     # pas marqué comme rendu
                @test p.pending === nothing                  # rien de déposé
            finally
                Ressac._WAVE_RENDER[] = old; Ressac._WAVE_SYNC[] = oldsync
            end
        end

        @testset "n inserts a filter wrapping the focused node's output" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            src = p.knobs[ni].node_id
            n0 = length(p.genome.nodes)
            v0 = p.req_version
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('n')) == true
            @test length(p.genome.nodes) == n0 + 1        # un nœud ajouté
            @test p.structure_dirty                        # explainer à rafraîchir
            @test p.req_version > v0                        # re-render demandé
            # le nouveau nœud enveloppe la source (la référence en entrée)
            wrappers = [id for (id, nd) in p.genome.nodes if id != src &&
                        any(a -> a isa Ressac.NodeRef && a.id == src, nd.args)]
            @test length(wrappers) == 1
            @test Ressac.ugen_spec(p.genome.nodes[wrappers[1]].ugen).role === :filter
        end

        @testset "n on a global control knob is a no-op" begin
            p = mkscu()
            p.focus = 1                                    # control :freq
            n0 = length(p.genome.nodes)
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('n')) == true
            @test length(p.genome.nodes) == n0             # rien ajouté
            @test !p.structure_dirty
        end

        @testset "d deletes the focused node (bypass)" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            n0 = length(p.genome.nodes)
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('d')) == true
            @test length(p.genome.nodes) == n0 - 1         # un nœud retiré
            @test p.structure_dirty
        end

        @testset "x duplicates the focused node's subgraph in parallel" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            n0 = length(p.genome.nodes)
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('x')) == true
            @test length(p.genome.nodes) > n0              # clones + Mix
            @test any(nd -> nd.ugen === :Mix, values(p.genome.nodes))
            @test p.structure_dirty
        end

        @testset "r cycles the focused node's rate (or no-ops if single-rate)" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('r')) == true   # touche consommée
        end

        @testset "m grafts an LFO onto the focused ConstArg slot (if mods exist)" begin
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)   # knob-nœud = un ConstArg
            p.focus = ni
            n0 = length(p.genome.nodes)
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('m')) == true
            if !isempty(Ressac.catalog_by_role(:mod))
                @test length(p.genome.nodes) == n0 + 1       # modulateur ajouté
                @test p.structure_dirty
            end
        end

        @testset "structural edits are no-ops on a global control knob" begin
            for key in ('d', 'x', 'm', 'i', 'r')
                p = mkscu()
                p.focus = 1                                  # control :freq
                n0 = length(p.genome.nodes)
                @test Ressac.handle_key!(p, Tachikoma.KeyEvent(key)) == true
                @test length(p.genome.nodes) == n0
                @test !p.structure_dirty
            end
        end

        @testset "ambiguous attribution (two different knobs) learns no NEW signature" begin
            old = Ressac._WAVE_RENDER[]; oldsync = Ressac._WAVE_SYNC[]
            # brillance dépend de cutoff → un tug produit un delta descripteur mesurable
            Ressac._WAVE_RENDER[] = function (g)
                cut = 800.0
                for nd in values(g.nodes), a in nd.args
                    a isa Ressac.ConstArg && a.value > 50 && (cut = a.value)
                end
                f = cut / 44100 * 4
                return Float32[sin(2π * f * 1000 * i / 44100) for i in 0:2000], 44100
            end
            Ressac._WAVE_SYNC[] = true
            try
                p = mkscu()
                ni = findfirst(k -> k.kind === :node, p.knobs)
                # 1er tug + rendu → amorce last_descr et apprend la signature de A
                p.focus = ni; Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                Ressac._sculpt_pump!(p)
                sigs0 = Ressac.n_signatures(p.sigs)
                # puis DEUX knobs différents avant le prochain rendu → attribution ambiguë
                p.focus = ni;     Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                p.focus = ni + 1; Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                @test p.last_tugged == -1
                Ressac._sculpt_pump!(p)
                @test p.rendered_version == p.req_version
                @test Ressac.n_signatures(p.sigs) == sigs0   # aucune NOUVELLE signature
            finally
                Ressac._WAVE_RENDER[] = old; Ressac._WAVE_SYNC[] = oldsync
            end
        end

        @testset "apply_pending drops a stale (older-version) render" begin
            p = mkscu()
            p.rendered_version = 5
            lock(p.lock) do
                p.pending = (Float32[0.1f0, 0.2f0], 44100, zeros(5), 3)  # ver 3 < 5
            end
            samples0 = copy(p.samples)
            @test Ressac._sculpt_apply_pending!(p) == false   # périmé → rejeté
            @test p.samples == samples0                        # onde inchangée
            @test p.rendered_version == 5
        end
    end
end
