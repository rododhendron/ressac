using Test
using Ressac

mutable struct _OverlayMockClient
    sent::Vector{Vector{UInt8}}
end
_OverlayMockClient() = _OverlayMockClient(Vector{UInt8}[])
Ressac.send_osc(c::_OverlayMockClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)

_fake_overlay_key(code::AbstractString; modifiers=String[], kind="Press") =
    (; code = String(code), modifiers = String.(modifiers), kind = String(kind))

@testset "tui_overlay" begin
    @testset "_overlay_rect centers within area" begin
        out = Ressac._overlay_rect(80, 24, 30, 6)
        @test out == (25, 9, 30, 6)
    end

    @testset "_overlay_rect caps at 80% of area" begin
        out = Ressac._overlay_rect(100, 50, 200, 200)
        @test out[3] == 80
        @test out[4] == 40
    end

    @testset "_clip_lines truncates each line to width" begin
        lines = ["hello world", "tiny", "exactly10!"]
        out = Ressac._clip_lines(lines, 5)
        @test out == ["hello", "tiny", "exact"]
    end

    @testset "_clip_lines empty input" begin
        @test Ressac._clip_lines(String[], 10) == String[]
    end

    # ("? toggles m.show_help" testset removed in phase-1 cleanup
    # along with the LiveModel `_dispatch_key!` dispatcher. The new
    # RessacApp path handles ? via Tachikoma.KeyEvent in update!.)
end
