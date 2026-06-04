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
end
