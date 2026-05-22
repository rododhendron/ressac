using Test
using Ressac

@testset "tui_buffer" begin
    @testset "_insert_char! inserts at cursor and advances col" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]
        m.cursor_row = 1
        m.cursor_col = 2  # before 'b'
        Ressac._insert_char!(m, 'X')
        @test m.buffer == ["aXbc"]
        @test m.cursor_col == 3
    end

    @testset "_insert_char! at end of line extends the line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]
        m.cursor_row = 1
        m.cursor_col = 4
        Ressac._insert_char!(m, 'd')
        @test m.buffer == ["abcd"]
        @test m.cursor_col == 5
    end

    @testset "_split_line! creates a new row at the cursor" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abcdef"]
        m.cursor_row = 1
        m.cursor_col = 4
        Ressac._split_line!(m)
        @test m.buffer == ["abc", "def"]
        @test (m.cursor_row, m.cursor_col) == (2, 1)
    end

    @testset "_backspace! deletes prev char or joins lines" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc", "def"]
        m.cursor_row = 1
        m.cursor_col = 3
        Ressac._backspace!(m)
        @test m.buffer == ["ac", "def"]
        @test (m.cursor_row, m.cursor_col) == (1, 2)

        m.cursor_row = 2
        m.cursor_col = 1
        Ressac._backspace!(m)
        @test m.buffer == ["acdef"]
        @test (m.cursor_row, m.cursor_col) == (1, 3)
    end

    @testset "_backspace! at (1,1) is a no-op" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]
        m.cursor_row = 1
        m.cursor_col = 1
        Ressac._backspace!(m)
        @test m.buffer == ["abc"]
        @test (m.cursor_row, m.cursor_col) == (1, 1)
    end

    @testset "_delete_line! removes the current row" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c"]
        m.cursor_row = 2
        m.cursor_col = 1
        deleted = Ressac._delete_line!(m)
        @test deleted == "b"
        @test m.buffer == ["a", "c"]
        @test m.cursor_row == 2

        m.buffer = ["solo"]
        m.cursor_row = 1
        deleted = Ressac._delete_line!(m)
        @test deleted == "solo"
        @test m.buffer == [""]
        @test m.cursor_row == 1
    end

    @testset "_paragraph_bounds finds non-blank line ranges" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "", "c", "d", "e", "", "f"]
        m.cursor_row = 1
        @test Ressac._paragraph_bounds(m) == (1, 2)
        m.cursor_row = 2
        @test Ressac._paragraph_bounds(m) == (1, 2)
        m.cursor_row = 5
        @test Ressac._paragraph_bounds(m) == (4, 6)
        m.cursor_row = 3
        @test Ressac._paragraph_bounds(m) == (3, 2)
    end

    @testset "_move_cursor! clamps to buffer bounds" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc", "de", "fghij"]
        m.cursor_row = 1; m.cursor_col = 1
        # Down off the end clamps col to line length+1.
        Ressac._move_cursor!(m, 0, +1)
        @test (m.cursor_row, m.cursor_col) == (2, 1)
        # Right past end of "de" clamps.
        m.cursor_col = 10
        Ressac._move_cursor!(m, +1, 0)
        @test m.cursor_col == 3  # one past 'e'
        # Up wraps col within the longer line above.
        m.cursor_row = 2; m.cursor_col = 2
        Ressac._move_cursor!(m, 0, -1)
        @test m.cursor_row == 1
        @test m.cursor_col == 2
    end

    @testset "_line_start! / _line_end! / _buffer_start! / _buffer_end!" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["foo bar", "baz", "  quux"]
        m.cursor_row = 1; m.cursor_col = 5
        Ressac._line_start!(m)
        @test m.cursor_col == 1
        Ressac._line_end!(m)
        @test m.cursor_col == lastindex("foo bar") + 1
        Ressac._buffer_end!(m)
        @test m.cursor_row == 3
        @test m.cursor_col == 1
        Ressac._buffer_start!(m)
        @test m.cursor_row == 1
        @test m.cursor_col == 1
    end
end
