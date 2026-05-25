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

    # ── app.jl — ex-command verb derivation ──
    #
    # The point of deriving the autocomplete verb list from the dispatch
    # tables was to eliminate hand-maintained lists that drift. So these
    # tests test STRUCTURAL invariants — no hardcoded "I expect this
    # specific verb" list (which would just drift again). What we
    # actually want to guarantee:
    #
    #   1. Every literal-dispatch verb appears in `_all_ex_verbs()`.
    #   2. Every regex registered for dispatch produces ≥ 1 extracted
    #      verb (otherwise it's invisible to autocomplete forever).
    #   3. Every explicit special-dispatch verb appears.
    #   4. The extractor itself handles the three known shapes correctly
    #      — those tests document the contract, not the inventory.

    @testset "every _LITERAL_DISPATCH key is autocompleteable" begin
        v = Set(Ressac._all_ex_verbs())
        for k in keys(Ressac._LITERAL_DISPATCH)
            @test k in v
        end
    end

    @testset "every _REGEX_DISPATCH entry extracts ≥ 1 verb" begin
        # If someone adds a regex with a shape `_extract_regex_verbs`
        # doesn't recognise, this trips immediately — and they know to
        # extend the extractor (rather than discover later that Tab
        # silently dropped their new command).
        for (rx, _) in Ressac._REGEX_DISPATCH
            # _SHORTCUT_RX is intentionally not an ex-command — it's
            # inline pattern DSL syntax (`:sg0.5`, `:sn-3`) and would
            # only pollute Tab-completion. Skip exactly that one.
            rx === Ressac._SHORTCUT_RX && continue
            verbs = Ressac._extract_regex_verbs(rx)
            @test !isempty(verbs)
        end
    end

    @testset "every _SPECIAL_VERBS entry appears in autocomplete" begin
        v = Set(Ressac._all_ex_verbs())
        for verb in Ressac._SPECIAL_VERBS
            @test verb in v
        end
    end

    # ── autocomplete.jl — completion picker state ──
    @testset "ex-command Tab cycles + picks up via picker" begin
        # Regression: `:starter <Tab>` used to silently splice the
        # first match without showing alternatives. Now both modes
        # (:insert + :command) share the session API so the picker
        # lights up either way.
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        app = Ressac.RessacApp(; scheduler = sched)
        app.editor.mode = :command
        empty!(app.editor.command_buffer)
        append!(app.editor.command_buffer, collect("starter "))
        # First Tab: opens session, splices best candidate.
        @test Ressac._try_ex_autocomplete!(app, app.editor) == true
        @test Ressac._completion_picker_active(app) == true
        @test startswith(app.completion_label, "ex:")
        @test length(app.completion_candidates) > 1   # multiple starters
        first_buf = String(app.editor.command_buffer)
        @test startswith(first_buf, "starter ")
        # Second Tab: advances to next, buffer changes.
        Ressac._try_ex_autocomplete!(app, app.editor)
        @test app.completion_idx == 2
        @test String(app.editor.command_buffer) != first_buf
        @test startswith(String(app.editor.command_buffer), "starter ")
    end

    @testset "ex-command Tab on bare verb prefix (no space)" begin
        # `:sta<Tab>` → cycles verbs that fuzzy-match "sta" (e.g. starter, start).
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        app = Ressac.RessacApp(; scheduler = sched)
        app.editor.mode = :command
        empty!(app.editor.command_buffer)
        append!(app.editor.command_buffer, collect("sta"))
        @test Ressac._try_ex_autocomplete!(app, app.editor) == true
        @test app.completion_label == "ex:verb"
        @test !isempty(app.completion_candidates)
        # Buffer is just the chosen verb (no leading "sta " prefix).
        @test String(app.editor.command_buffer) == app.completion_candidates[1]
    end

    @testset "_completion_picker_active reflects Tab-cycle state" begin
        # Plain construction: defaults aren't a cycle.
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.RessacApp(; scheduler = sched)
        @test Ressac._completion_picker_active(m) == false

        # Fake a cycle in progress: idx>0 + non-empty candidates.
        m.completion_candidates = ["fast", "fastN", "fast_loop"]
        m.completion_idx = 2
        @test Ressac._completion_picker_active(m) == true

        # _reset_completion! clears it.
        Ressac._reset_completion!(m)
        @test Ressac._completion_picker_active(m) == false
        @test m.completion_idx == 0
        @test isempty(m.completion_candidates)
    end

    @testset "_extract_regex_verbs — the three contract shapes" begin
        # These document what shapes the extractor understands. Add a
        # new shape here when you teach `_extract_regex_verbs` to
        # handle one — that's the trigger for the rest of the suite
        # to start picking it up automatically.

        # Shape 1: plain verb.
        @test Ressac._extract_regex_verbs(r"^foo\s+(\w+)$") == ["foo"]

        # Shape 2: alternation of literal alternatives.
        @test sort(Ressac._extract_regex_verbs(r"^(?:foo|bar)\s+(\S+)$")) ==
              ["bar", "foo"]

        # Shape 3: prefix + optional literal suffix.
        @test sort(Ressac._extract_regex_verbs(r"^foo(?:-bar)?\s+(\S+)$")) ==
              ["foo", "foo-bar"]

        # Hyphenated verbs are valid in any shape.
        @test Ressac._extract_regex_verbs(r"^foo-bar\s+(\w+)$") == ["foo-bar"]

        # Whole-line literal — no \s after, just $.
        @test Ressac._extract_regex_verbs(r"^foo$") == ["foo"]

        # Patterns without a leading ^ aren't dispatchers — extractor
        # returns empty (so registering one would trip the
        # "extracts ≥ 1 verb" invariant above, surfacing the problem).
        @test Ressac._extract_regex_verbs(r"foo\s+bar") == String[]
    end

    # ── app.jl — _scroll_to_show ──
    @testset "_scroll_to_show — keep cursor visible in list modals" begin
        # Cursor inside window: scroll stays put (no jumpy recentering).
        @test Ressac._scroll_to_show(5,  100, 10, 0) == 0
        @test Ressac._scroll_to_show(3,  100, 10, 0) == 0
        @test Ressac._scroll_to_show(10, 100, 10, 0) == 0

        # Cursor past bottom: scroll moves down just enough.
        @test Ressac._scroll_to_show(11, 100, 10, 0) == 1
        @test Ressac._scroll_to_show(20, 100, 10, 0) == 10
        @test Ressac._scroll_to_show(50, 100, 10, 0) == 40

        # Cursor above the top after scroll: snaps so cursor is row 1.
        @test Ressac._scroll_to_show(5,  100, 10, 50) == 4
        @test Ressac._scroll_to_show(1,  100, 10, 50) == 0

        # End-of-list clamp: never reveal blank rows past the last entry.
        @test Ressac._scroll_to_show(100, 100, 10, 95) == 90
        @test Ressac._scroll_to_show(100, 100, 10,  0) == 90

        # Short list: scroll always 0 (everything fits).
        @test Ressac._scroll_to_show(5, 5,  10, 0)  == 0
        @test Ressac._scroll_to_show(1, 5,  10, 3)  == 0

        # Edge: body_h ≤ 0 → no scroll possible.
        @test Ressac._scroll_to_show(5, 100, 0, 0)  == 0
        @test Ressac._scroll_to_show(5, 100, -1, 0) == 0

        # Edge: empty list (total = 0) — scroll always 0.
        @test Ressac._scroll_to_show(0, 0, 10, 0) == 0
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
