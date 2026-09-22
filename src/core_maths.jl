# src/core_maths.jl
# Mathématiques musicales — courbes, lois de probabilité, suites de
# nombres, conversions hauteur/fréquence.
#
# Deux familles, toutes deux utilisables partout où un pattern est
# attendu :
#   * les SIGNAUX (`Pattern{Float64}` continus, comme `sine`) : on les
#     échantillonne avec `segment(n)` ou on les passe à un contrôle ;
#   * les SUITES (`Vector`) : elles deviennent une séquence d'un cycle,
#     ou une alternance avec `slowcat`.
#
# Tout tirage est déterministe : la valeur dépend du temps de
# l'événement, pas d'un état caché. Deux rendus du même cycle donnent le
# même son, ce qui rend une session reproductible.

# Uniforme [0, 1) déterministe à partir d'une graine quelconque.
_u01(seed) = (hash(seed) % UInt32) / Float64(typemax(UInt32))
_u01(seed, salt::Integer) = _u01((seed, salt))

# Construit un signal continu dont la valeur est tirée à chaque fenêtre
# de requête, à partir du milieu de la fenêtre (comme `rand_pat`).
function _stochastic(f, salt::Integer)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        mid = (s + e) / 2
        u = _u01((Float64(mid), floor(Int, s)), salt)
        [Event{Float64}(s, e, f(u, (Float64(mid), salt)))]
    end)
end

"""
    uniform(a, b) -> Pattern{Float64}

Tirage uniforme entre `a` et `b`. `|> segment(n)` pour n valeurs par
cycle.
"""
uniform(a::Real = 0.0, b::Real = 1.0) = _stochastic((u, _) -> a + (b - a) * u, 1)

"""
    normal(μ = 0, σ = 1) -> Pattern{Float64}

Loi normale (Box-Muller sur deux tirages déterministes). Les valeurs se
massent autour de `μ` : une vélocité humaine plutôt qu'un hasard plat.
"""
normal(mu::Real = 0.0, sigma::Real = 1.0) =
    _stochastic((u, seed) -> begin
        u1 = max(u, 1e-12)
        u2 = _u01(seed, 2)
        mu + sigma * sqrt(-2 * log(u1)) * cos(2π * u2)
    end, 3)

"""
    expo(λ = 1) -> Pattern{Float64}

Loi exponentielle de paramètre `λ` : beaucoup de petites valeurs, peu de
grandes. L'allure des intervalles entre événements rares.
"""
expo(lambda::Real = 1.0) = _stochastic((u, _) -> -log(max(u, 1e-12)) / lambda, 5)

"""
    cauchy(x0 = 0, γ = 1) -> Pattern{Float64}

Loi de Cauchy : comme une normale mais avec des valeurs extrêmes
fréquentes. Utile pour des accidents qui ressortent.
"""
cauchy(x0::Real = 0.0, gamma::Real = 1.0) =
    _stochastic((u, _) -> x0 + gamma * tan(π * (clamp(u, 1e-9, 1 - 1e-9) - 0.5)), 7)

"""
    bernoulli(p = 0.5) -> Pattern{Bool}

Vrai avec la probabilité `p`. Se branche sur `mask` ou `structPat`.
"""
bernoulli(p::Real = 0.5) = _mapvals(v -> v < p, uniform(), Bool)

"""
    poisson(λ = 1) -> Pattern{Int}

Nombre d'événements d'une loi de Poisson de moyenne `λ` — par exemple
combien de coups mettre dans un pas.
"""
function poisson(lambda::Real = 1.0)
    _mapvals(uniform(), Int) do u
        L = exp(-lambda); k = 0; p = 1.0; x = u
        # Inversion : on tire tant que le produit reste au-dessus de L.
        while p > L && k < 64
            k += 1
            p *= max(_u01((x, k), 11), 1e-12)
        end
        max(0, k - 1)
    end
end

"""
    walk(pas = 0.1; lo = 0, hi = 1) -> Pattern{Float64}

Marche aléatoire : la valeur d'un cycle part de celle du précédent, à un
`pas` près, et reste entre `lo` et `hi`. Une dérive lente, là où
`uniform` saute partout.
"""
function walk(step::Real = 0.1; lo::Real = 0.0, hi::Real = 1.0)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        cyc = floor(Int, s)
        # Somme des pas depuis le cycle 0, repliée dans [lo, hi].
        v = 0.5
        for c in 0:cyc
            v += step * (2 * _u01(c, 13) - 1)
            v = v < 0 ? -v : v > 1 ? 2 - v : v      # rebond aux bords
        end
        [Event{Float64}(s, e, lo + (hi - lo) * clamp(v, 0.0, 1.0))]
    end)
end

"""
    markov(transitions, états) -> Pattern

Chaîne de Markov : `transitions[i]` donne les poids de passage de
l'état `i` vers chacun des autres, un pas par cycle.

```julia
@d1 markov([[0.5, 0.5, 0], [0, 0.5, 0.5], [0.5, 0, 0.5]], [:bd, :sn, :hh])
```
"""
function markov(transitions::AbstractVector, states::AbstractVector{T}) where {T}
    n = length(states)
    n == length(transitions) || throw(ArgumentError("markov : autant de lignes que d'états"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            i = 1
            for c in 0:(cyc - 1)                       # rejoue la chaîne depuis 0
                w = Float64.(collect(transitions[i]))
                i = _weighted_index(w, _u01(c, 17))
            end
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b && push!(out, Event{T}(a, b, states[i]))
        end
        out
    end)
end

# ── Courbes ────────────────────────────────────────────────────────

"""
    ramp(a, b) -> Pattern{Float64}

Rampe linéaire de `a` à `b` sur un cycle. `ramp(b, a)` descend.
"""
ramp(a::Real = 0.0, b::Real = 1.0) = _continuous(t -> a + (b - a) * mod(t, 1.0))

"""
    expramp(a, b) -> Pattern{Float64}

Rampe géométrique de `a` à `b` sur un cycle — l'échelle des fréquences
et des durées perçues.
"""
function expramp(a::Real, b::Real)
    (a > 0 && b > 0) || throw(ArgumentError("expramp : bornes strictement positives"))
    la = log(a); lb = log(b)
    _continuous(t -> exp(la + (lb - la) * mod(t, 1.0)))
end

"""
    curve(f) -> Pattern{Float64}

N'importe quelle fonction du temps devient un signal : `f` reçoit la
position dans le cycle (0 à 1) et renvoie la valeur.

```julia
@d1 "hh*8" |> pan(curve(t -> sin(2π * t)^3) |> segment(8))
```
"""
curve(f) = _continuous(t -> float(f(mod(t, 1.0))))

# ── Suites de nombres ──────────────────────────────────────────────

"""
    fib(n; from = 1) -> Vector{Int}

Les `n` premiers nombres de Fibonacci à partir du `from`-ième. Des
durées et des hauteurs qui ne se répètent jamais tout à fait.
"""
function fib(n::Integer; from::Integer = 1)
    n > 0 || throw(ArgumentError("fib : n > 0"))
    a, b = 1, 1
    for _ in 1:(from - 1); a, b = b, a + b; end
    out = Int[]
    for _ in 1:n; push!(out, a); a, b = b, a + b; end
    return out
end

"""
    primes_n(n) -> Vector{Int}

Les `n` premiers nombres premiers — des cycles qui ne se recroisent
qu'au bout de leur produit, d'où les polyrythmies qui tournent longtemps.
"""
function primes_n(n::Integer)
    n > 0 || throw(ArgumentError("primes_n : n > 0"))
    out = Int[]; c = 2
    while length(out) < n
        isprime = true
        for p in out
            p * p > c && break
            c % p == 0 && (isprime = false; break)
        end
        isprime && push!(out, c)
        c += 1
    end
    return out
end

"""
    harmonics(n; fondamentale = 1) -> Vector{Float64}

La série harmonique : `f`, `2f`, `3f`… C'est de là que vient la
consonance, et `harmonics(8) ./ 1` donne les partiels d'un son.
"""
harmonics(n::Integer; fundamental::Real = 1.0) =
    [float(fundamental) * k for k in 1:n]

"""
    logistic_map(r, n; x0 = 0.5) -> Vector{Float64}

`n` itérations de la suite logistique `x → r·x·(1 − x)`. Sage jusqu'à
`r ≈ 3`, doublements de période ensuite, chaos vers 3,57 et au-delà.
"""
function logistic_map(r::Real, n::Integer; x0::Real = 0.5)
    n > 0 || throw(ArgumentError("logistic_map : n > 0"))
    out = Float64[]; x = float(x0)
    for _ in 1:n
        x = r * x * (1 - x)
        push!(out, x)
    end
    return out
end

"""
    euclid_steps(k, n) -> Vector{Bool}

Le vecteur euclidien brut : `k` coups répartis au mieux sur `n` pas.
C'est ce que calcule `bd(3,8)`, exposé pour le regarder ou le
transformer.
"""
euclid_steps(k::Integer, n::Integer) = collect(_euclidean_pulses(Int(k), Int(n)))

# ── Hauteurs et fréquences ─────────────────────────────────────────

"""
    ratio_to_cents(r) -> Float64

Un rapport de fréquences en cents : `3//2` (la quinte juste) vaut
701,96 ¢, la quinte tempérée 700 ¢. L'écart s'entend.
"""
ratio_to_cents(r::Real) = 1200 * log2(float(r))

"""
    cents_to_ratio(c) -> Float64

L'inverse : 1200 ¢ font une octave, donc un rapport de 2.
"""
cents_to_ratio(c::Real) = 2.0^(float(c) / 1200)

"""
    midi_to_hz(m) -> Float64

Note MIDI vers fréquence (69 = la 440).
"""
midi_to_hz(m::Real) = 440.0 * 2.0^((float(m) - 69) / 12)

"""
    hz_to_midi(f) -> Float64

Fréquence vers note MIDI, décimales comprises : un quart de ton vaut 0,5.
"""
hz_to_midi(f::Real) = 69 + 12 * log2(float(f) / 440)

"""
    semitones(r) -> Float64

Un rapport de fréquences en demi-tons : `semitones(3//2)` vaut 7,02.
Pratique pour poser une intonation juste sur `note`.
"""
semitones(r::Real) = 12 * log2(float(r))

# ---------------------------------------------------------------------------
# Interopérabilité Julia ⟷ mini-notation
# ---------------------------------------------------------------------------
#
# Deux directions :
#   * un argument numérique de combinateur accepte un pattern ou une
#     chaîne de mini-notation (`ply("<2 3>")`), comme `fast` ;
#   * un pattern se relit en valeurs Julia (`patvals`) et une collection
#     Julia s'écrit en mini-notation (`tomini`).

# Applique `f(valeur, p)` cycle par cycle, la valeur venant d'un pattern.
function _per_cycle_num(f, np::Pattern, p::Pattern)
    T = typeof(f(1, p)).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            v = _value_at(np, Rational{Int64}(cyc))
            v === nothing && continue
            r = _resolve_value(v)
            r isa Real || continue
            append!(out, f(r, p)(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

# Les combinateurs dont l'argument numérique accepte aussi un pattern.
# `p |> ply("<2 3>")` double puis triple, un cycle sur deux.
for (fn, conv) in ((:ply, :int), (:iter, :int), (:iterBack, :int), (:rot, :int),
                   (:segment, :int), (:degradeBy, :float), (:linger, :float),
                   (:early, :float), (:late, :float), (:striate, :int), (:chopp, :int))
    @eval begin
        $fn(np::Pattern, p::Pattern) = _per_cycle_num(
            (v, q) -> $fn($(conv === :int ? :(round(Int, v)) : :(float(v))), q), np, p)
        $fn(np::Pattern) = p -> $fn(np, _as_pattern(p))
        $fn(np::AbstractString) = p -> $fn(parse_minino(String(np)), _as_pattern(p))
    end
end

"""
    every(n, f, p)  — `n` peut être un pattern

`every("<2 4>", rev)` alterne « un cycle sur deux » et « un sur quatre ».
Même chose pour `chunk` et `swingBy`.
"""
every(np::Pattern, f, p::Pattern) = _per_cycle_num((v, q) -> every(max(1, round(Int, v)), f, q), np, p)
every(np::Pattern, f) = p -> every(np, f, _as_pattern(p))
every(np::AbstractString, f) = p -> every(parse_minino(String(np)), f, _as_pattern(p))
chunk(np::Pattern, f, p::Pattern) = _per_cycle_num((v, q) -> chunk(max(1, round(Int, v)), f, q), np, p)
chunk(np::Pattern, f) = p -> chunk(np, f, _as_pattern(p))
chunk(np::AbstractString, f) = p -> chunk(parse_minino(String(np)), f, _as_pattern(p))
swingBy(xp::Pattern, n::Int, p::Pattern) = _per_cycle_num((v, q) -> swingBy(float(v), n, q), xp, p)
swingBy(xp::Pattern, n::Int) = p -> swingBy(xp, n, _as_pattern(p))
swingBy(xp::AbstractString, n::Int) = p -> swingBy(parse_minino(String(xp)), n, _as_pattern(p))

"""
    patvals(p, de = 0, à = 1) -> Vector

Les valeurs d'un pattern sur un intervalle de cycles, en types Julia :
les nombres reviennent en `Int` ou `Float64`, le reste en `Symbol`. De
quoi relire un pattern pour le transformer en Julia.

```julia
patvals(p"0 3 7")            # [0, 3, 7]
sum(patvals(p"1 2 3"))       # 6
```
"""
patvals(p, a::Real = 0, b::Real = 1) =
    [_resolve_value(ev.value) for ev in
     sort(_as_pattern(p)(Rational{Int64}(a), Rational{Int64}(b)); by = ev -> ev.start)]

"""
    tomini(xs) -> String

Écrit une collection Julia en mini-notation : les listes imbriquées
deviennent des groupes, `nothing` un silence. Le pendant de `patvals`.

```julia
tomini([0, 3, 7])            # "0 3 7"
tomini([[0, 3], 7, nothing]) # "[0 3] 7 ~"
p(tomini(fib(5)))            # un pattern depuis une suite
```
"""
tomini(xs::AbstractVector) = join((_tomini_one(x) for x in xs), " ")
tomini(x) = _tomini_one(x)
_tomini_one(::Nothing) = "~"
_tomini_one(x::AbstractVector) = "[" * tomini(x) * "]"
_tomini_one(x::Real) = x isa Integer ? string(x) : string(round(float(x); digits = 4))
_tomini_one(x::Symbol) = String(x)
_tomini_one(x::AbstractString) = String(x)

"""
    pat(x) -> Pattern

Convertit n'importe quoi en pattern : chaîne de mini-notation, symbole,
nombre, liste, range, ou pattern déjà construit. La porte d'entrée
unique quand on ne sait pas ce qu'on a sous la main. (`p` reste le
littéral `p"…"`.)

```julia
pat("bd sn")      pat(:bd)      pat(0:7)      pat([0, 3, 7])
```
"""
pat(x) = _as_pattern(x)
