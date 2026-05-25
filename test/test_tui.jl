using Test
using Ressac

# The LiveModel-rendered TUI.view tests that lived here were removed
# in the phase-1 cleanup that deleted tui_view.jl. The kept test
# (live API helpers without an active session) is independent of any
# UI model and belongs in the live_api regression set.

@testset "live API errors without an active session" begin
    Ressac._LIVE_SCHEDULER[] = nothing
    @test_throws ErrorException d!(:d1, pure(:bd))
    @test_throws ErrorException unset!(:d1)
    @test_throws ErrorException hush_all!()
    @test_throws ErrorException cps!(0.5)
end
