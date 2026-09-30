# Tests par propriétés (Supposition.jl) : des invariants vérifiés sur des
# entrées générées, pour couvrir les angles morts qu'un exemple choisi à
# la main ne voit pas. Chaque contre-exemple trouvé est rétréci et rejoué.
using Test
using Ressac
using Supposition, Supposition.Data
using Tachikoma

# ── Générateurs ───────────────────────────────────────────────────────
const _PROP_SOUNDS = ["bd", "sn", "hh", "cp", "~"]
_step = Data.SampledFrom(_PROP_SOUNDS) | map(s -> s * "*" * string(rand(2:3)), Data.SampledFrom(["bd", "hh"])) |
        map(v -> "[" * join(v, " ") * "]", Data.Vectors(Data.SampledFrom(_PROP_SOUNDS); min_size = 1, max_size = 3)) |
        map(v -> "<" * join(v, " ") * ">", Data.Vectors(Data.SampledFrom(_PROP_SOUNDS); min_size = 1, max_size = 3))
_mini = map(v -> join(v, " "), Data.Vectors(_step; min_size = 1, max_size = 6))

_evs(p, c = 0) = sort(p(c // 1, (c + 1) // 1); by = e -> e.start)

@testset "propriétés — mini-notation" begin
    @check max_examples = 300 function events_inside_cycle(s = _mini)
        p = Ressac.parse_minino(s)
        all(e -> 0 <= e.start < e.stop <= 1, _evs(p)) && all(c -> all(e -> c <= e.start < e.stop <= c + 1, _evs(p, c)), 0:3)
    end
    @check max_examples = 200 function fast_doubles(s = _mini)
        length(_evs(Ressac.fast(2, Ressac.parse_minino(s)))) == length(_evs(Ressac.parse_minino(s), 0)) + length(_evs(Ressac.parse_minino(s), 1))
    end
    @check max_examples = 200 function rev_twice_is_identity(s = _mini)
        p = Ressac.parse_minino(s)
        [(e.start, e.stop, e.value) for e in _evs(Ressac.rev(Ressac.rev(p)))] == [(e.start, e.stop, e.value) for e in _evs(p)]
    end
    @check max_examples = 200 function no_silence_event(s = _mini)
        all(e -> e.value !== :~, _evs(Ressac.parse_minino(s)))
    end
end

@testset "propriétés — structure d'un contrôle" begin
    # n = 1 : un seul événement d'un cycle entier, un son sans rythme — il
    # prend celui du contrôle (m coups). Sinon la gauche garde ses n coups.
    @check max_examples = 200 function left_keeps_count(n = Data.Integers(1, 8), m = Data.Integers(1, 8))
        p = "bd*$n" |> Ressac.n(join(0:m-1, " "))
        length(_evs(p)) == (n == 1 ? m : n)
    end
    @check max_examples = 200 function sampled_is_strict(n = Data.Integers(1, 8), m = Data.Integers(1, 8))
        length(_evs("bd*$n" |> Ressac.sampled(Ressac.n(join(0:m-1, " "))))) == n
    end
    @check max_examples = 200 function both_never_fewer(n = Data.Integers(1, 8), m = Data.Integers(1, 8))
        length(_evs("bd*$n" |> Ressac.both(Ressac.n(join(0:m-1, " "))))) >= max(n, m)
    end
end

@testset "propriétés — le |> d'Elixir" begin
    S = Ressac.SynthDSL
    _sym = Data.SampledFrom([:x, :y, :f, :g, :h])
    _leaf = _sym | map(Symbol ∘ string, Data.Integers(0, 9))
    _call = map((f, args) -> Expr(:call, f, args...), _sym, Data.Vectors(_leaf; max_size = 3))
    _expr = map((l, r) -> Expr(:call, :|>, l, r), _leaf | _call, _sym | _call)
    _chain = map((a, b) -> Expr(:call, :|>, a, b), _expr, _sym | _call)
    @check max_examples = 300 function no_pipe_left(ex = _expr | _chain)
        out = S._elixir_pipes(ex)
        !occursin("|>", string(out))
    end
    @check max_examples = 300 function idempotent(ex = _expr | _chain)
        out = S._elixir_pipes(ex)
        S._elixir_pipes(out) == out
    end
    @check max_examples = 300 function arity_grows_by_one(f = _sym, args = Data.Vectors(_leaf; max_size = 3), x = _leaf)
        out = S._elixir_pipes(Expr(:call, :|>, x, Expr(:call, f, args...)))
        out.head === :call && out.args[1] === f && length(out.args) == length(args) + 2 && out.args[2] === x
    end
end

@testset "propriétés — export DSL ⟷ génome" begin
    _stage = Data.SampledFrom(["rlpf(800, 0.3)", "low_pass(1200)", "tanh_drive(2)", "soft_clip", "fold2(0.7)",
                               "free_verb(0.3, 0.8)", "delay_l(0.25)", "stereo_pan(0.2)", "clip(-0.5, 0.5)",
                               "env_perc(0.01, 0.4)", "leak_dc", "high_pass(300)"])
    _src = Data.SampledFrom(["saw(:freq)", "sin_osc(:freq)", "pulse(:freq, 0.3)", "white()", "tri(:freq * 2)"])
    _body = map((s, st) -> s * (isempty(st) ? "" : " |> " * join(st, " |> ")), _src, Data.Vectors(_stage; max_size = 4))
    @check max_examples = 150 function roundtrip_same_sc(body = _body)
        src = "@synth :p (freq=220, sustain=0.5) " * body
        g = Ressac.genome_from_dsl(src)
        g === nothing && return false
        dsl = Ressac.render_dsl(g, :p)
        g2 = Ressac.genome_from_dsl(dsl)
        g2 !== nothing && Ressac.render_synthdef(g2, :p) == Ressac.render_synthdef(g, :p)
    end
    @check max_examples = 150 function export_is_pipes_not_ugen(body = _body)
        g = Ressac.genome_from_dsl("@synth :p (freq=220, sustain=0.5) " * body)
        g === nothing && return false
        dsl = Ressac.render_dsl(g, :p)
        occursin("|> safe()", dsl) && !occursin("ugen(:Saw", dsl) && !occursin("ugen(:RLPF", dsl)
    end
end

@testset "propriétés — rendu markdown" begin
    _word = Data.Text(Data.AsciiCharacters(); min_len = 1, max_len = 12)
    _line = map(v -> join(v, " "), Data.Vectors(_word; max_size = 12))
    @check max_examples = 300 function wrap_never_wider(line = _line, w = Data.Integers(4, 60))
        all(l -> sum(sp -> textwidth(sp.content), l; init = 0) <= w, Ressac._md_wrap(Ressac._md_inline(line), w))
    end
    @check max_examples = 300 function wrap_keeps_letters(line = _line, w = Data.Integers(4, 60))
        keep(s) = filter(!isspace, s)
        joined = join(join(sp.content for sp in l) for l in Ressac._md_wrap(Ressac._md_inline(line), w))
        keep(joined) == keep(join(sp.content for sp in Ressac._md_inline(line)))
    end
    @check max_examples = 200 function render_never_wider(lines = Data.Vectors(_line; max_size = 8), w = Data.Integers(8, 60))
        all(l -> sum(sp -> textwidth(sp.content), l; init = 0) <= w, Ressac._md_render(lines, w))
    end
end

@testset "propriétés — divers" begin
    @check max_examples = 300 function xkb_layout_is_known(s = Data.Text(Data.AsciiCharacters(); max_len = 8))
        Ressac._layout_from_xkb(s) in (:azerty, :qwerty, nothing)
    end
    @check max_examples = 200 function synth_block_replacement_keeps_context(pre = Data.Text(Data.AsciiCharacters(); max_len = 20),
                                                                              post = Data.Text(Data.AsciiCharacters(); max_len = 20))
        head = "# " * replace(pre, "\n" => " ") * "\n"; tail = "\n# " * replace(post, "\n" => " ") * "\n"
        text = head * "@synth :a (freq=220) saw(:freq)" * tail
        out = Ressac.replace_synth_block(text, "@synth :a (freq=220) sin_osc(:freq)")
        startswith(out, head) && endswith(out, tail) && occursin("sin_osc", out) && !occursin("saw(", out)
    end
    @check max_examples = 300 function numpad_normalises_to_plain(k = Data.SampledFrom(collect(keys(Ressac._NUMPAD_TO_CHAR))))
        ev = Ressac._normalise_event(Tachikoma.KeyEvent(k))
        ev.key === :char && ev.char == Ressac._NUMPAD_TO_CHAR[k]
    end
end
