# Noms de notes, accords c'maj, arp, snippets en mode normal.
using Test
using Ressac
import Tachikoma

evs_vals(p, s = 0//1, e = 1//1) = [ev.value for ev in p(s, e)]

@testset "notes — noms Tidal → demi-tons" begin
    @test Ressac._note_number("c") == 0
    @test Ressac._note_number("e") == 4
    @test Ressac._note_number("cs") == 1 && Ressac._note_number("c#") == 1
    @test Ressac._note_number("df") == 1 && Ressac._note_number("db") == 1
    @test Ressac._note_number("a4") == -3
    @test Ressac._note_number("c6") == 12
    @test Ressac._note_number("bd") === nothing
    @test Ressac._note_number("7") === nothing
    p = (pure(:pad) |> n("c e g a4"))(0//1, 1//1)
    @test [ev.value[:n] for ev in p] == [0, 4, 7, -3]
    q = (pure(:pad) |> note("cs5 0 e"))(0//1, 1//1)
    @test [ev.value[:note] for ev in q] == [1, 0, 4]
    # un nom de sample n'est pas une note : s reste bd
    r = (p"bd" |> n("0"))(0//1, 1//1)[1]
    @test r.value[:s] == :bd && r.value[:n] == 0
end

@testset "accords — c'maj est un empilement de notes jouées ensemble" begin
    p = p"c'maj"
    evs = p(0//1, 1//1)
    @test sort(Int.(Ressac._resolve_value.(evs_vals(p)))) == [0, 4, 7]
    @test all(ev.start == 0//1 && ev.stop == 1//1 for ev in evs)
    @test sort(Int.(Ressac._resolve_value.(evs_vals(p"e'min7")))) == [4, 7, 11, 14]
    @test sort(Int.(Ressac._resolve_value.(evs_vals(p"0'dom7")))) == [0, 4, 7, 10]
    @test sort(Int.(Ressac._resolve_value.(evs_vals(p"a4'min")))) == [-3, 0, 4]
    # renversement et nombre de notes
    @test sort(Int.(Ressac._resolve_value.(evs_vals(p"c'maj'i")))) == [4, 7, 12]
    @test sort(Int.(Ressac._resolve_value.(evs_vals(p"c'maj'5")))) == [0, 4, 7, 12, 16]
    # dans une séquence, chaque accord garde son créneau
    q = p"c'maj e'min"
    @test length(q(0//1, 1//1)) == 6
    @test all(ev.stop - ev.start == 1//2 for ev in q(0//1, 1//1))
    @test_throws ArgumentError parse_minino("c'zorglub")
    @test "maj7" in chord_names()
    # n("c'maj") : trois événements portant n
    r = (pure(:pad) |> n("c'maj"))(0//1, 1//1)
    @test sort([ev.value[:n] for ev in r]) == [0, 4, 7]
end

@testset "arp — modes, pattern de modes, sur pattern brut et ControlMap" begin
    up = (p"c'maj" |> arp(:up))(0//1, 1//1)
    @test [Ressac._resolve_value(ev.value) for ev in up] == [0, 4, 7]
    @test [ev.start for ev in up] == [0//1, 1//3, 2//3]
    @test [Ressac._resolve_value(ev.value) for ev in (p"c'maj" |> arp("down"))(0//1, 1//1)] == [7, 4, 0]
    @test [Ressac._resolve_value(ev.value) for ev in (p"c'maj" |> arp("updown"))(0//1, 1//1)] == [0, 4, 7, 4]
    @test [Ressac._resolve_value(ev.value) for ev in (p"c'maj7" |> arp("converge"))(0//1, 1//1)] == [0, 11, 4, 7]
    @test [Ressac._resolve_value(ev.value) for ev in (p"c'maj" |> arp("thumbup"))(0//1, 1//1)] == [0, 4, 0, 7]
    # pattern de modes : up au cycle 0, down au cycle 1
    pm = p"c'maj" |> arp("<up down>")
    @test [Ressac._resolve_value(ev.value) for ev in pm(0//1, 1//1)] == [0, 4, 7]
    @test [Ressac._resolve_value(ev.value) for ev in pm(1//1, 2//1)] == [7, 4, 0]
    # une note seule est inchangée ; deux accords dans le cycle gardent leurs créneaux
    @test length((p"c" |> arp(:up))(0//1, 1//1)) == 1
    two = (p"c'maj e'min" |> arp(:up))(0//1, 1//1)
    @test length(two) == 6 && two[4].start == 1//2
    # après n() : les ControlMap sont arpégés sur :n
    cm = (pure(:pad) |> n("c'maj") |> arp(:down))(0//1, 1//1)
    @test [ev.value[:n] for ev in cm] == [7, 4, 0]
    @test_throws ArgumentError (p"c'maj" |> arp(:zigzag))(0//1, 1//1)
end
