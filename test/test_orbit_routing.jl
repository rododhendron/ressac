# Tests for orbit-routing: every `@dN` pattern slot is auto-mapped to
# SuperDirt orbit N-1 via the `_inject_orbit!` helper that mutates each
# outgoing /dirt/play OSC message. This is what powers per-slot RMS in
# `:mixer` — without it every event lands on orbit 0 and the meter sees
# one fat sum instead of 12 distinct lanes.

@testset "orbit routing" begin
    @testset "_orbit_for_slot — d1..d12 → 0..11" begin
        for n in 1:12
            @test Ressac._orbit_for_slot(Symbol("d$n")) == n - 1
        end
    end

    @testset "_orbit_for_slot — slots beyond 12 wrap mod 12" begin
        # @d13 reuses orbit 0, @d14 → 1, …. Keeps things playing even
        # though metering can't disambiguate them.
        @test Ressac._orbit_for_slot(:d13) == 0
        @test Ressac._orbit_for_slot(:d24) == 11
        @test Ressac._orbit_for_slot(:d25) == 0
    end

    @testset "_orbit_for_slot — non-d names return nothing" begin
        @test Ressac._orbit_for_slot(:foo)     === nothing
        @test Ressac._orbit_for_slot(:d)       === nothing  # no number
        @test Ressac._orbit_for_slot(:dxxx)    === nothing  # non-numeric
        @test Ressac._orbit_for_slot(Symbol("")) === nothing
        @test Ressac._orbit_for_slot(:d0)      === nothing  # 0 isn't a slot
        @test Ressac._orbit_for_slot(:dminus1) === nothing
    end

    @testset "_inject_orbit! — /dirt/play gets orbit appended" begin
        msg = Ressac.OSCMessage("/dirt/play", Any["s", "bd"])
        Ressac._inject_orbit!(msg, :d3)
        # Last two args should be ("orbit", Int32(2)).
        @test length(msg.args) == 4
        @test msg.args[3] == "orbit"
        @test msg.args[4] === Int32(2)
    end

    @testset "_inject_orbit! — /ressac/play is left untouched" begin
        # User synths bypass SuperDirt; orbit doesn't apply.
        msg = Ressac.OSCMessage("/ressac/play", Any["wob", "n", 0])
        Ressac._inject_orbit!(msg, :d2)
        @test length(msg.args) == 3
        @test !any(==("orbit"), msg.args)
    end

    @testset "_inject_orbit! — non-d slot is left untouched" begin
        msg = Ressac.OSCMessage("/dirt/play", Any["s", "bd"])
        Ressac._inject_orbit!(msg, :foo)
        @test length(msg.args) == 2
    end

    @testset "_inject_orbit! — won't double-inject if orbit already set" begin
        # Defensive: if a future feature ever sets orbit explicitly,
        # the auto-injection must not override it.
        msg = Ressac.OSCMessage("/dirt/play",
                                Any["s", "bd", "orbit", Int32(5)])
        Ressac._inject_orbit!(msg, :d3)
        @test length(msg.args) == 4
        @test msg.args[4] === Int32(5)   # preserved, not 2
    end

    @testset "_inject_orbit! returns the message (chain-friendly)" begin
        msg = Ressac.OSCMessage("/dirt/play", Any["s", "bd"])
        @test Ressac._inject_orbit!(msg, :d1) === msg
    end
end
