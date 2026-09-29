# Trous Tidal comblés et opérateurs de concaténation : substruct, sampled
# (structure de gauche), secs/msecs, [a b] / [a; b] / & / |, transitions.
using Test
using Ressac

mutable struct _TidalMock; sent::Vector{Vector{UInt8}}; end
_TidalMock() = _TidalMock(Vector{UInt8}[])
Ressac.send_osc(c::_TidalMock, b::Vector{UInt8}) = push!(c.sent, b)

_vals(p, a = 0, b = 1) = [(ev.start, ev.stop, ev.value) for ev in sort(p(a // 1, b // 1); by = e -> e.start)]

@testset "substruct — chaque pas vrai reçoit tout un cycle, tassé" begin
    v = _vals(substruct("t f t t", "bd sn"))
    @test [x[3] for x in v] == [:bd, :sn, :bd, :sn, :bd, :sn]
    @test v[1][1:2] == (0 // 1, 1 // 8) && v[3][1:2] == (1 // 2, 5 // 8)
    @test _vals("hh*8" |> substruct("1 0")) == _vals(substruct("1 0", "hh*8"))
    @test isempty(_vals(substruct("f f", "bd")))
    # un cycle sur deux différent : le cycle tassé est celui de l'attaque
    v2 = _vals(substruct("t", "<bd sn>"), 1, 2)
    @test [x[3] for x in v2] == [:sn]
end

@testset "structure d'un contrôle — gauche par défaut, both, sampled" begin
    left = ("bd*4" |> n("0 1 2"))(0 // 1, 1 // 1)                  # le défaut : le # de Tidal
    @test length(left) == 4
    @test [ev.value[:n] for ev in left] == [0, 0, 1, 2]
    @test all(ev -> ev.stop - ev.start == 1 // 4, left)
    @test length(("bd*4" |> both(n("0 1 2")))(0 // 1, 1 // 1)) == 6   # les intersections, explicitement
    # un son sans rythme prend le rythme du contrôle ; sampled l'interdit
    @test [ev.value[:n] for ev in (:bd |> n("0 1 2"))(0 // 1, 1 // 1)] == [0, 1, 2]
    @test [ev.value[:n] for ev in ("bd" |> n("0 1 2"))(0 // 1, 1 // 1)] == [0, 1, 2]
    @test length((:bd |> sampled(n("0 1 2")))(0 // 1, 1 // 1)) == 1
    # un événement de deux cycles n'est pas « sans rythme » : gauche
    @test length((slow(2, pure(:bd)) |> n("0 1"))(0 // 1, 2 // 1)) == 1
    # set(key, pattern) suit la même règle ; la composition (× du gain) aussi
    @test [ev.value[:room] for ev in ("bd*2" |> set(:room, "0.1 0.9 0.5"))(0 // 1, 1 // 1)] == [0.1, 0.9]
    @test [ev.value[:gain] for ev in ("bd*2" |> gain(0.5) |> gain("1 0.5 1 0.5"))(0 // 1, 1 // 1)] == [0.5, 0.5]
    # both est bien délimité : après lui, le défaut revient
    @test Ressac._CONTROL_STRUCT[] === :left
    # pump découpe encore (il demande both lui-même)
    @test length(("bd sn" |> pump())(0 // 1, 1 // 1)) == 4
    # un contrôle qui alterne par cycle, lu au bon cycle
    p = "bd sn" |> sampled(lpf("<400 800>"))
    @test [ev.value[:cutoff] for ev in p(1 // 1, 2 // 1)] == [800, 800]
    # une valeur qui a commencé avant l'attaque (contrôle plus lent) est tenue
    q = "hh*4" |> sampled(n(slow(2, p"0 7")))
    @test [ev.value[:n] for ev in q(0 // 1, 1 // 1)] == [0, 0, 0, 0]
    @test [ev.value[:n] for ev in q(1 // 1, 2 // 1)] == [7, 7, 7, 7]
end

@testset "secs / msecs — des secondes en cycles au tempo courant" begin
    old = Ressac._LIVE_SCHEDULER[]
    try
        Ressac._LIVE_SCHEDULER[] = nothing                          # cps par défaut 0.5
        @test _vals(secs(2))[1][3] == 1.0
        @test _vals(msecs(500))[1][3] == 0.25
        @test [x[3] for x in _vals(secs("1 2"))] == [0.5, 1.0]
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end

@testset "opérateurs — [a b] fastcat, [a; b] slowcat, & overlay, | randcat" begin
    @test [x[3] for x in _vals([p"bd*2" "hh sn"])] == [:bd, :bd, :hh, :sn]
    @test _vals([p"bd*2" "hh sn"]) == _vals(fastcat("bd*2", "hh sn"))
    @test [x[3] for x in _vals(["bd" p"sn"])] == [:bd, :sn]
    @test _vals([p"bd"; "sn"], 0, 2) == [(0 // 1, 1 // 1, :bd), (1 // 1, 2 // 1, :sn)]
    @test _vals([p"bd"; "sn"; :hh], 2, 3) == [(2 // 1, 3 // 1, :hh)]
    @test _vals(p"bd" & "hh*2") == _vals(overlay("bd", "hh*2"))
    @test [x[3] for x in _vals("bd" & p"sn")] == [:bd, :sn]
    picks = [_vals(p"bd" | "sn", c, c + 1)[1][3] for c in 0:15]
    @test Set(picks) == Set([:bd, :sn]) && picks == [_vals(randcat("bd", "sn"), c, c + 1)[1][3] for c in 0:15]
    # + reste l'arithmétique
    @test [x[3] for x in _vals(p"0 3" + "<0 12>", 1, 2)] == [12, 15]
    # les crochets marchent aussi comme corps de @dN via les chaînes mêlées
    @test length(_vals([p"bd" "sn" "hh"])) == 3
end

@testset "transitions — xfade fond l'ancien vers le nouveau, jump attend" begin
    xf = Ressac.xfade_pattern(pure(:bd), pure(:sn), 2 // 1, 2)
    evs = [(ev.start, ev.value[:s], Float64(ev.value[:gain])) for ev in xf(0 // 1, 5 // 1)]
    @test evs == [(0, :bd, 1.0), (1, :bd, 1.0), (2, :bd, 1.0), (3, :bd, 0.5), (3, :sn, 0.5), (4, :sn, 1.0)]
    # sans ancien pattern : le nouveau monte seul ; un gain existant est multiplié
    xf2 = Ressac.xfade_pattern(nothing, "bd" |> gain(0.5), 0 // 1, 2)
    @test [Float64(ev.value[:gain]) for ev in xf2(0 // 1, 3 // 1)] == [0.25, 0.5]     # cycle 0 : gain 0, retiré
    # via le routage des @dN
    sched = Ressac.Scheduler(_TidalMock(); cps = 1.0)
    sched.t_start = time() - 0.2                                    # cycle courant ≈ 0.2 → t0 = 1
    old_live = Ressac._LIVE_SCHEDULER[]; old_mode = Ressac._EVAL_MODE[]
    try
        Ressac._LIVE_SCHEDULER[] = sched
        Ressac._EVAL_MODE[] = (:immediate, 0)
        Ressac._route_to_slot!(:d1, pure(:bd))
        Ressac._EVAL_MODE[] = (:xfade, 2)
        Ressac._route_to_slot!(:d1, pure(:sn))
        p = Ressac.pattern_get(sched, :d1)
        @test [ev.value[:s] for ev in p(0 // 1, 1 // 1)] == [:bd]
        @test Set(ev.value[:s] for ev in p(2 // 1, 3 // 1)) == Set([:bd, :sn])
        @test [ev.value[:s] for ev in p(4 // 1, 5 // 1)] == [:sn]
        Ressac._EVAL_MODE[] = (:deferred, 2)
        Ressac._route_to_slot!(:d2, pure(:cp))
        @test !haskey(sched.patterns, :d2) && haskey(sched.pending, :d2)
        @test sched.pending[:d2][2] == 3 // 1                        # ceil(0.2) + 2
    finally
        Ressac._LIVE_SCHEDULER[] = old_live; Ressac._EVAL_MODE[] = old_mode
    end
end
