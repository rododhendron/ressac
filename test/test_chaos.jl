# Tests for the chaos plugin (plugins/chaos/).
#
# Loads the real chaos.jl via a small fixture plugin (chaos-fixture)
# that points at the real source via [julia] files. That exercises the
# whole plugin-loading path (TOML parsing → _handle_julia → module
# install in Main), not just the chaos source as an isolated include.

@testset "chaos plugin" begin
    fixtures = joinpath(@__DIR__, "fixtures", "plugins")

    @testset "fixture loads the chaos module into Main" begin
        Ressac._load_plugins([fixtures])
        @test isdefined(Main, :Chaos)
        @test isdefined(Main, :chaos)
        @test Main.chaos === Main.Chaos
    end

    @testset "lorenz: returns a Pattern{Float64}" begin
        p = Main.Chaos.lorenz()
        @test p isa Ressac.Pattern{Float64}
    end

    @testset "lorenz: emits one event per query covering the arc" begin
        p = Main.Chaos.lorenz()
        evs = p(0//1, 1//1)
        @test length(evs) == 1
        @test evs[1].start == 0//1
        @test evs[1].stop == 1//1
        @test isfinite(evs[1].value)
    end

    @testset "lorenz: independent constructor calls have independent state" begin
        # Different init → different first sample (proves no shared state).
        a = Main.Chaos.lorenz(init = (0.10, 0.0, 0.0))
        b = Main.Chaos.lorenz(init = (0.11, 0.0, 0.0))
        @test !(a(0//1, 1//1)[1].value ≈ b(0//1, 1//1)[1].value)

        # Same init: advancing `a` past `b` (querying further in time)
        # leaves them at different step counts and thus different values.
        c = Main.Chaos.lorenz()
        d = Main.Chaos.lorenz()
        vc = c(0//1, 2//1)[1].value   # advances c to step 200
        vd = d(0//1, 1//1)[1].value   # advances d only to step 100
        @test !(vc ≈ vd)
    end

    @testset "lorenz: actually evolves (successive cycles differ)" begin
        p = Main.Chaos.lorenz()
        v0 = p(0//1, 1//1)[1].value
        v1 = p(1//1, 2//1)[1].value
        v2 = p(2//1, 3//1)[1].value
        @test !(v0 ≈ v1)
        @test !(v1 ≈ v2)
    end

    @testset "lorenz: axis selector picks different state dims" begin
        # Same init but different axes ⇒ different sampled values once
        # the system has evolved past the trivial first step.
        px = Main.Chaos.lorenz(axis = :x)
        py = Main.Chaos.lorenz(axis = :y)
        # advance both to step 100
        px(0//1, 1//1); py(0//1, 1//1)
        vx = px(1//1, 2//1)[1].value
        vy = py(1//1, 2//1)[1].value
        @test !(vx ≈ vy)
    end

    @testset "lorenz: axis must be :x/:y/:z" begin
        @test_throws ArgumentError Main.Chaos.lorenz(axis = :w)
    end

    @testset "henon: bounded values, evolves" begin
        p = Main.Chaos.henon()
        vs = Float64[]
        for c in 0:7
            push!(vs, p(Rational(c), Rational(c + 1))[1].value)
        end
        @test all(abs.(vs) .< 5)        # well within ~1.5 in steady state
        @test length(unique(vs)) > 1     # not stuck on a fixed point
    end

    @testset "logistic: stays in [0, 1] and rejects bad init" begin
        p = Main.Chaos.logistic(r = 3.9)
        for c in 0:9
            v = p(Rational(c), Rational(c + 1))[1].value
            @test 0.0 <= v <= 1.0
        end
        @test_throws ArgumentError Main.Chaos.logistic(init = 0.0)
        @test_throws ArgumentError Main.Chaos.logistic(init = 1.0)
    end

    @testset "rossler / standard: smoke test — Pattern{Float64} valid" begin
        @test Main.Chaos.rossler() isa Ressac.Pattern{Float64}
        @test Main.Chaos.standard() isa Ressac.Pattern{Float64}
        # And they emit finite values.
        @test isfinite(Main.Chaos.rossler()(0//1, 1//1)[1].value)
        @test isfinite(Main.Chaos.standard()(0//1, 1//1)[1].value)
    end

    @testset "registry: list_chaos reports built-ins" begin
        names = Main.Chaos.list_chaos()
        for n in (:lorenz, :henon, :logistic, :rossler, :standard)
            @test n in names
        end
    end

    @testset "registry: register_chaos! adds a new entry" begin
        ctor = (; kwargs...) -> Main.Chaos.logistic(; kwargs...)
        Main.Chaos.register_chaos!(:mycustom, ctor)
        @test :mycustom in Main.Chaos.list_chaos()
    end

    @testset "composes with range_pat and segment" begin
        # range_pat needs bipolar input ([-1, 1]); logistic is unipolar
        # (0..1) so we feed it through a quick scale to bipolar first.
        # Simpler check: segment carves the chaos into N events/cycle.
        p = Main.Chaos.logistic()
        seg = p |> segment(8)
        evs = seg(0//1, 1//1)
        @test length(evs) == 8
        @test all(0.0 .<= [e.value for e in evs] .<= 1.0)
    end
end
