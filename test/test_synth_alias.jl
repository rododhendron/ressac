# Tests for the synth alias system: a user-facing short name (the
# alias) that resolves to a SC SynthDef name (typically derived from
# the source filename). Lets users type `:wob` in patterns while SC
# actually knows the synth as `\wob1`.

@testset "synth alias" begin

    @testset "register_synth_alias! — fresh binding" begin
        empty!(Ressac._SYNTH_ALIASES)
        @test Ressac.register_synth_alias!(:wob, :wob1) == true
        @test Ressac._SYNTH_ALIASES[:wob] === :wob1
    end

    @testset "register_synth_alias! — idempotent on same target" begin
        empty!(Ressac._SYNTH_ALIASES)
        Ressac.register_synth_alias!(:wob, :wob1)
        @test Ressac.register_synth_alias!(:wob, :wob1) == true   # noop
        @test Ressac._SYNTH_ALIASES[:wob] === :wob1
    end

    @testset "register_synth_alias! — identity (alias == sc_name) is noop" begin
        # No point storing `wob → wob` in the alias table; passes
        # through `resolve_synth_name` unchanged anyway.
        empty!(Ressac._SYNTH_ALIASES)
        @test Ressac.register_synth_alias!(:wob, :wob) == true
        @test !haskey(Ressac._SYNTH_ALIASES, :wob)
    end

    @testset "register_synth_alias! — collision refused, existing preserved" begin
        # Most important invariant: don't silently rebind. If `wob`
        # already points to `wob1`, attempting `wob → wob2` must fail
        # AND leave the existing mapping intact.
        empty!(Ressac._SYNTH_ALIASES)
        Ressac.register_synth_alias!(:wob, :wob1)
        @test_logs (:error, r"already points") match_mode=:any begin
            @test Ressac.register_synth_alias!(:wob, :wob2) == false
        end
        @test Ressac._SYNTH_ALIASES[:wob] === :wob1
    end

    @testset "unregister_synth_alias!" begin
        empty!(Ressac._SYNTH_ALIASES)
        Ressac.register_synth_alias!(:wob, :wob1)
        @test Ressac.unregister_synth_alias!(:wob) == true
        @test !haskey(Ressac._SYNTH_ALIASES, :wob)
        # Second call: returns false (already gone), doesn't throw.
        @test Ressac.unregister_synth_alias!(:wob) == false
    end

    @testset "resolve_synth_name — alias → sc_name, passthrough otherwise" begin
        empty!(Ressac._SYNTH_ALIASES)
        Ressac.register_synth_alias!(:wob, :wob1)
        @test Ressac.resolve_synth_name(:wob)         === :wob1
        @test Ressac.resolve_synth_name(:not_alias)   === :not_alias  # passthrough
    end

    @testset "synth_alias_for — reverse lookup" begin
        empty!(Ressac._SYNTH_ALIASES)
        Ressac.register_synth_alias!(:w,  :wob1)
        Ressac.register_synth_alias!(:k,  :kick42)
        @test Ressac.synth_alias_for(:wob1)   === :w
        @test Ressac.synth_alias_for(:kick42) === :k
        @test Ressac.synth_alias_for(:unbound) === nothing
    end

    # ── Scheduler: aliases resolve before shipping OSC ────────────
    @testset "event_to_osc{Symbol}: alias routes to /ressac/play with sc_name" begin
        empty!(Ressac._SYNTH_REGISTRY)
        empty!(Ressac._SYNTH_ALIASES)
        try
            # `wob1` is the registered user synth; `wob` is its alias.
            Ressac.register_synth!(Ressac.SynthEntry(:wob1, "user-dsl", Dict{String,Any}()))
            Ressac.register_synth_alias!(:wob, :wob1)
            ev = Ressac.Event(0//1, 1//1, :wob)
            msg = Ressac.event_to_osc(ev)
            @test msg.address == "/ressac/play"
            # First arg is the SC name (resolved), not the alias.
            @test msg.args[1] == "wob1"
        finally
            empty!(Ressac._SYNTH_REGISTRY)
            empty!(Ressac._SYNTH_ALIASES)
        end
    end

    @testset "event_to_osc{ControlMap}: alias in :s resolves to sc_name" begin
        empty!(Ressac._SYNTH_REGISTRY)
        empty!(Ressac._SYNTH_ALIASES)
        try
            Ressac.register_synth!(Ressac.SynthEntry(:wob1, "user-dsl", Dict{String,Any}()))
            Ressac.register_synth_alias!(:wob, :wob1)
            cm = Ressac.ControlMap(:s => :wob, :gain => 0.7)
            ev = Ressac.Event(0//1, 1//1, cm)
            msg = Ressac.event_to_osc(ev)
            @test msg.address == "/ressac/play"
            @test msg.args[1] == "wob1"   # SC name shipped
            # Any extra params are still serialised (alphabetical).
            @test "gain" in msg.args
        finally
            empty!(Ressac._SYNTH_REGISTRY)
            empty!(Ressac._SYNTH_ALIASES)
        end
    end

    @testset "event_to_osc{Symbol}: non-aliased non-user name unchanged" begin
        # A pattern firing `:bd` (a sample) should not be affected by
        # the alias system at all — passes through to /dirt/play.
        empty!(Ressac._SYNTH_ALIASES)
        ev = Ressac.Event(0//1, 1//1, :bd)
        msg = Ressac.event_to_osc(ev)
        @test msg.address == "/dirt/play"
        @test msg.args[1] == "s" && msg.args[2] == "bd"
    end

    # ── @synth macro: end-to-end via Base.include(SynthDSL, file) ─
    # The previous testset stubbed everything around the macro
    # (called `register_synth!` + `register_synth_alias!` directly).
    # That missed a real bug: the macro's expansion referenced
    # `__source__` as a symbol, which is only bound inside the macro
    # body — `UndefVarError: __source__` at every plugin load.
    # These tests load a real file via the path actual users hit.
    @testset "@synth via Base.include — alias-less, sc_name from filename" begin
        mock = MockOSCClient()
        Ressac._LIVE_SCHEDULER[] = Ressac.Scheduler(mock; cps=0.5)
        empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)
        try
            mktempdir() do d
                path = joinpath(d, "wobtest1.jl")
                write(path, "@synth saw(:freq) |> rlpf(1200, 0.3)")
                Base.include(Ressac.SynthDSL, path)
                @test Ressac.synth_info(:wobtest1) !== nothing
                @test isempty(Ressac._SYNTH_ALIASES)
            end
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)
        end
    end

    @testset "@synth via Base.include — aliased, sc_name still from filename" begin
        mock = MockOSCClient()
        Ressac._LIVE_SCHEDULER[] = Ressac.Scheduler(mock; cps=0.5)
        empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)
        try
            mktempdir() do d
                path = joinpath(d, "wobtest2.jl")
                write(path, "@synth :wt saw(:freq) |> rlpf(1200, 0.3)")
                Base.include(Ressac.SynthDSL, path)
                @test Ressac.synth_info(:wobtest2) !== nothing
                @test Ressac._SYNTH_ALIASES[:wt] === :wobtest2
            end
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)
        end
    end

    @testset "@synth at REPL (no file) — alias required" begin
        # In a REPL / Meta.parse context, __source__.file isn't a
        # real path, so the alias-less form must error cleanly
        # rather than mysteriously register under a Symbol("none").
        mock = MockOSCClient()
        Ressac._LIVE_SCHEDULER[] = Ressac.Scheduler(mock; cps=0.5)
        empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)
        try
            @test_throws ErrorException Core.eval(
                Ressac.SynthDSL,
                Meta.parse("@synth saw(:freq)"))
            # With an alias, REPL works — the alias is the SC name.
            Core.eval(Ressac.SynthDSL, Meta.parse("@synth :replbar sin_osc(:freq)"))
            @test Ressac.synth_info(:replbar) !== nothing
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)
        end
    end
end
