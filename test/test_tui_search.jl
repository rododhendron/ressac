using Test
using Ressac

@testset "tui_search" begin
    function _new_model()
        sched = Scheduler(MockOSCClient(); cps=1.0)
        Ressac.LiveModel(; scheduler=sched,
            buffer=["@d1 pure(:bd)",
                    "# @d1 old",
                    "@d2 pure(:sn)",
                    "@d1 pure(:cp)"])
    end

    @testset "_run_search! forward finds first match below cursor" begin
        m = _new_model()
        m.cursor_row = 1; m.cursor_col = 1
        Ressac._run_search!(m, r"@d1\b"; dir=:forward)
        @test m.cursor_row == 4  # row 1 is exactly at cursor; forward starts after
    end

    @testset "_run_search! backward finds last match above cursor" begin
        m = _new_model()
        m.cursor_row = 4; m.cursor_col = 1
        Ressac._run_search!(m, r"@d1\b"; dir=:backward)
        @test m.cursor_row == 1
    end

    @testset "_run_search! wraps when nothing in original direction" begin
        m = _new_model()
        m.cursor_row = 4; m.cursor_col = 1
        Ressac._run_search!(m, r"@d2\b"; dir=:forward)
        @test m.cursor_row == 3
    end

    @testset "_run_search! ignores commented matches" begin
        m = _new_model()
        m.cursor_row = 1; m.cursor_col = 1
        Ressac._run_search!(m, r"@d1\b"; dir=:forward)
        @test m.cursor_row == 4  # not row 2 (commented)
    end

    @testset "_repeat_search! n/N use stored direction" begin
        m = _new_model()
        m.cursor_row = 1; m.cursor_col = 1
        m.last_search = r"@d1\b"; m.last_search_dir = :forward
        Ressac._repeat_search!(m; reverse=false)  # n
        @test m.cursor_row == 4
        Ressac._repeat_search!(m; reverse=true)   # N
        @test m.cursor_row == 1
    end

    @testset "_run_search! logs and returns when no match anywhere" begin
        m = _new_model()
        Ressac._run_search!(m, r"@d99\b"; dir=:forward)
        @test any(l -> occursin("no match", l), m.logs)
    end
end
