# Regression tests for the vim motion + operator-motion overrides that
# live in tui_app.jl / tui_editor_ops.jl. These hit the full TK.update!
# dispatch path so we catch interactions with TK's pending_key state,
# the cw/dw/yw intercepts, and the visual-mode wrappers.

@testset "vim motions + operators" begin
    sched = Ressac.Scheduler(Ressac.OSCClient("127.0.0.1", 57120))
    import Tachikoma
    TK = Tachikoma

    @testset "w traverses every char + wraps lines" begin
        m = Ressac.RessacApp(scheduler = sched)
        TK.set_text!(Ressac._active_editor(m), "Reservoir.adex(N=24)\n    dt=1.0")
        Ressac._active_editor(m).mode = :normal
        Ressac._active_editor(m).cursor_row = 1; Ressac._active_editor(m).cursor_col = 0
        cols_visited = Int[Ressac._active_editor(m).cursor_col]
        rows_visited = Set([Ressac._active_editor(m).cursor_row])
        w_evt = TK.KeyEvent(:char, 'w', TK.key_press)
        last = (Ressac._active_editor(m).cursor_row, Ressac._active_editor(m).cursor_col)
        for _ in 1:30
            TK.update!(m, w_evt)
            cur = (Ressac._active_editor(m).cursor_row, Ressac._active_editor(m).cursor_col)
            push!(rows_visited, cur[1])
            cur == last && break
            last = cur
        end
        # Must have crossed the line boundary at least once.
        @test 2 in rows_visited
    end

    @testset "cw preserves scroll_offset" begin
        m = Ressac.RessacApp(scheduler = sched)
        TK.set_text!(Ressac._active_editor(m),
            join(["line " * string(i) for i in 1:80], "\n"))
        Ressac._active_editor(m).mode = :normal
        Ressac._active_editor(m).cursor_row = 50
        Ressac._active_editor(m).cursor_col = 0
        Ressac._active_editor(m).scroll_offset = 45
        TK.update!(m, TK.KeyEvent(:char, 'c', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'w', TK.key_press))
        @test Ressac._active_editor(m).scroll_offset == 45
        @test Ressac._active_editor(m).mode === :insert
        @test String(Ressac._active_editor(m).lines[50]) == " 50"   # "line" deleted, " 50" left
    end

    @testset "dw preserves scroll + deletes word + trailing space" begin
        m = Ressac.RessacApp(scheduler = sched)
        TK.set_text!(Ressac._active_editor(m),
            join(["foo bar baz line $i" for i in 1:80], "\n"))
        Ressac._active_editor(m).mode = :normal
        Ressac._active_editor(m).cursor_row = 50
        Ressac._active_editor(m).cursor_col = 0
        Ressac._active_editor(m).scroll_offset = 45
        TK.update!(m, TK.KeyEvent(:char, 'd', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'w', TK.key_press))
        @test Ressac._active_editor(m).scroll_offset == 45
        @test startswith(String(Ressac._active_editor(m).lines[50]), "bar")
    end

    @testset "V multi-line yank captures all selected lines" begin
        m = Ressac.RessacApp(scheduler = sched)
        TK.set_text!(Ressac._active_editor(m), "line one\nline two\nline three\nline four")
        Ressac._active_editor(m).mode = :normal
        Ressac._active_editor(m).cursor_row = 1; Ressac._active_editor(m).cursor_col = 0
        TK.update!(m, TK.KeyEvent(:char, 'V', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'j', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'j', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'y', TK.key_press))
        @test length(Ressac._active_editor(m).yank_buffer) == 3
        @test String(Ressac._active_editor(m).yank_buffer[1]) == "line one"
        @test String(Ressac._active_editor(m).yank_buffer[3]) == "line three"
        @test Ressac._active_editor(m).yank_is_linewise
    end

    @testset "v char-wise multi-line yank stores the right text" begin
        m = Ressac.RessacApp(scheduler = sched)
        TK.set_text!(Ressac._active_editor(m), "hello world\nfoo bar baz")
        Ressac._active_editor(m).mode = :normal
        Ressac._active_editor(m).cursor_row = 1; Ressac._active_editor(m).cursor_col = 6
        TK.update!(m, TK.KeyEvent(:char, 'v', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'j', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'l', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'l', TK.key_press))
        TK.update!(m, TK.KeyEvent(:char, 'y', TK.key_press))
        @test length(Ressac._active_editor(m).yank_buffer) == 2
        @test String(Ressac._active_editor(m).yank_buffer[1]) == "world"
        @test !Ressac._active_editor(m).yank_is_linewise
    end
end
