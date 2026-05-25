# Tests for the pure helpers inside the modal_*.jl files. These are
# the functions that can be exercised without standing up a full
# RessacApp — string parsers, regex line-mutators, template parsers.
# The interactive `_handle_*_key!` / `_render_*_modal!` halves of
# each modal stay tested via the TUI bindings suite.

@testset "modal helpers" begin

    # ── modal_synth_library.jl ──
    @testset "_first_comment_line — Julia + SC comment forms" begin
        # Julia comment with leading '#'.
        @test Ressac._first_comment_line("# my wobble bass\n@synth :wob ...") ==
              "my wobble bass"

        # SC comment with leading '//'.
        @test Ressac._first_comment_line("// dark drone, slow attack\nSynthDef(\\drone, ...)") ==
              "dark drone, slow attack"

        # Skips a leading blank line, picks the first comment row.
        @test Ressac._first_comment_line("\n\n# soft pad\n# (second comment ignored)\n") ==
              "soft pad"

        # Strips repeated hash / slash markers ("## " and "//// ").
        @test Ressac._first_comment_line("## TITLE: kick variant\n") == "TITLE: kick variant"
        @test Ressac._first_comment_line("//// pluck — short envelope\n") ==
              "pluck — short envelope"

        # No comment in first 20 lines → fallback string.
        @test Ressac._first_comment_line("SynthDef(\\x, {...}).add;") == "user synth"

        # Empty source → fallback (the for-loop just doesn't fire).
        @test Ressac._first_comment_line("") == "user synth"

        # Truncates long descriptions to 60 chars.
        long = "# " * "a" ^ 200
        @test length(Ressac._first_comment_line(long)) == 60
    end

    # ── modal_mixer.jl (extracted pure helper) ──
    @testset "_apply_gain_delta_to_line — bumps existing gain" begin
        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd\" |> gain(0.5)", 0.1) ==
              "@d1 p\"bd\" |> gain(0.6)"

        # Negative delta works.
        @test Ressac._apply_gain_delta_to_line("@d2 p\"hh\" |> gain(1.0)", -0.3) ==
              "@d2 p\"hh\" |> gain(0.7)"

        # Whitespace around the pipe is tolerated by the regex.
        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd\" |>  gain(1.0)", 0.5) ==
              "@d1 p\"bd\" |> gain(1.5)"
    end

    @testset "_apply_gain_delta_to_line — clamps to [0, 5]" begin
        # Over-bumping at the top.
        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd\" |> gain(4.8)", 0.5) ==
              "@d1 p\"bd\" |> gain(5.0)"

        # Negative result clamps to 0.
        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd\" |> gain(0.2)", -1.0) ==
              "@d1 p\"bd\" |> gain(0.0)"
    end

    @testset "_apply_gain_delta_to_line — appends if no gain present" begin
        # No gain in the pipe → append a neutral 1.0 + delta gain.
        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd hh sn hh\"", 0.0) ==
              "@d1 p\"bd hh sn hh\" |> gain(1.0)"

        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd\"", -0.5) ==
              "@d1 p\"bd\" |> gain(0.5)"
    end

    @testset "_apply_gain_delta_to_line — rounds to 2 decimals" begin
        # 0.13 + 0.1 = 0.23 — should serialise without float garbage.
        @test Ressac._apply_gain_delta_to_line("@d1 p\"bd\" |> gain(0.13)", 0.1) ==
              "@d1 p\"bd\" |> gain(0.23)"
    end

    @testset "_apply_gain_delta_to_line — preserves chain context" begin
        # Other pipe ops before and after the gain should survive.
        src = "@d1 p\"bd\" |> fast(2) |> gain(0.5) |> room(0.3)"
        @test Ressac._apply_gain_delta_to_line(src, 0.1) ==
              "@d1 p\"bd\" |> fast(2) |> gain(0.6) |> room(0.3)"
    end

    # ── leader_snippets.jl ──
    @testset "_parse_snippet_template — no placeholders" begin
        (text, cols) = Ressac._parse_snippet_template("rev")
        @test text == "rev"
        @test cols == Int[]
    end

    @testset "_parse_snippet_template — single placeholder" begin
        (text, cols) = Ressac._parse_snippet_template("|> gain(\$1)")
        @test text == "|> gain()"
        # Cursor target: between the parens, i.e. col 8 (after "|> gain(").
        @test cols == [8]
    end

    @testset "_parse_snippet_template — multiple placeholders" begin
        # Template: @d$1 p"$2" → text = @d p"" with placeholders at col 2 and 6.
        (text, cols) = Ressac._parse_snippet_template("@d\$1 p\"\$2\"")
        @test text == "@d p\"\""
        # Sorted by placeholder number, so $1 first then $2.
        @test cols == [2, 5]
    end

    @testset "_parse_snippet_template — placeholders sorted by number" begin
        # Template lists $2 before $1 — output positions stay correct
        # in placeholder-number order so Tab navigation makes sense.
        (text, cols) = Ressac._parse_snippet_template("\$2 then \$1")
        @test text == " then "
        # $1 ends up at col 6, $2 at col 0 — sorted [col(1), col(2)] = [6, 0].
        @test cols == [6, 0]
    end

    @testset "_parse_snippet_template — Euclidean rotation template" begin
        # The actual `R` template from _LEADER_SNIPPETS — regression
        # test on a real shape.
        (text, cols) = Ressac._parse_snippet_template("\$1(\$2,\$3,\$4)")
        @test text == "(,,)"
        @test cols == [0, 1, 2, 3]
    end

    @testset "_LEADER_SNIPPETS — every template parses cleanly" begin
        # Sanity sweep: all registered templates parse without errors
        # and their placeholder count is ≤ 9 (single-digit limit).
        for (ch, tpl) in Ressac._LEADER_SNIPPETS
            (text, cols) = Ressac._parse_snippet_template(tpl)
            @test text isa String
            @test length(cols) <= 9
        end
    end

    @testset "_LEADER_SNIPPETS — every trigger has a label" begin
        # The footer reads from _LEADER_LABELS — every key in
        # _LEADER_SNIPPETS / _LEADER_ACTIONS must have one or the
        # footer will show a confusing blank.
        labels = Dict(Ressac._LEADER_LABELS)
        for ch in keys(Ressac._LEADER_SNIPPETS)
            @test haskey(labels, ch)
        end
        for ch in keys(Ressac._LEADER_ACTIONS)
            @test haskey(labels, ch)
        end
    end
end
