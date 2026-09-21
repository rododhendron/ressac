# core_tidal.jl — le reste du vocabulaire TidalCycles.
#
# Conventions (les mêmes que core_combinators.jl) :
#   * chaque fonction existe en forme directe `f(args..., p)` et en forme
#     curried `f(args...)` à mettre dans un pipe `|>` ;
#   * l'entrée passe par `_as_pattern` (String / Symbol / Pattern) ;
#   * un pattern émet les événements qui DÉMARRENT dans la fenêtre demandée.

# ---------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------

# Nombre à partir d'une valeur de pattern (Symbol de mini-notation ou Real).
_num(v) = (r = _resolve_value(v); r isa Real ? r :
           throw(ArgumentError("valeur non numérique « $v »")))
_int(v) = (r = _num(v); r isa Integer ? Int(r) : floor(Int, r))

# Pattern numérique à partir d'un scalaire, d'une chaîne ou d'un pattern.
_num_pattern(x::Real) = pure(x)
_num_pattern(x::AbstractString) = parse_minino(String(x))
_num_pattern(x::Pattern) = x

# Liste de patterns homogène : même T, sinon tout le monde monte en ControlMap.
function _same_patterns(xs)
    ps = Any[_as_pattern(x) for x in xs]
    isempty(ps) && throw(ArgumentError("il faut au moins un pattern"))
    T = typeof(ps[1]).parameters[1]
    all(p -> p isa Pattern{T}, ps) && return Pattern{T}[p for p in ps]
    return ControlPattern[_lift_to_control(p) for p in ps]
end

# Déplace le cycle `cyc` (temps [cyc, cyc+1)) de `p` dans la fenêtre [a, b).
function _squeeze_cycle!(out::Vector{Event{T}}, p::Pattern{T}, cyc::Int,
                         a::Rational, b::Rational, s::Rational, e::Rational) where {T}
    c = Rational{Int64}(cyc)
    w = b - a
    for ev in p(c, c + 1)
        na = a + (ev.start - c) * w
        nb = a + (ev.stop - c) * w
        na >= s && na < e && push!(out, Event{T}(na, nb, ev.value))
    end
    return out
end

# Déplace la tranche [ts, te) de `p` (temps absolu) dans la fenêtre [a, b).
function _squeeze_slice!(out::Vector{Event{T}}, p::Pattern{T}, ts::Rational, te::Rational,
                         a::Rational, b::Rational, s::Rational, e::Rational) where {T}
    scale = (b - a) / (te - ts)
    for ev in p(ts, te)
        ev.start >= ts && ev.start < te || continue
        na = a + (ev.start - ts) * scale
        nb = a + (ev.stop - ts) * scale
        na >= s && na < e && push!(out, Event{T}(na, nb, ev.value))
    end
    return out
end

# Applique `f` sur les cycles où `test(cycle)` est vrai.
function _when_cycle(test, f, p0::Pattern)
    p, fp = _same_patterns((p0, f(p0)))
    T = typeof(p).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            append!(out, (test(cyc) ? fp : p)(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

# Pattern{Bool} à partir d'une chaîne, d'un Pattern{Symbol} ou d'un Pattern{Bool}.
function _as_bool_pattern(p::Pattern{Symbol})
    Pattern{Bool}((s::Rational, e::Rational) ->
        Event{Bool}[Event{Bool}(ev.start, ev.stop, _truthy(ev.value)) for ev in p(s, e)])
end
_as_bool_pattern(x) = _as_bool_pattern(_as_pattern(x))

# ---------------------------------------------------------------------------
# Concaténation / composition
# ---------------------------------------------------------------------------

"""
    fastcat(ps...) / slowcat(ps...)

`fastcat` enchaîne les patterns dans UN cycle (= `seq`), `slowcat` un par
cycle (= `cat`). Les chaînes sont acceptées : `fastcat("bd*2", "hh sn")`.
"""
fastcat(xs...) = seq(_same_patterns(xs))
fastcat(xs::AbstractVector) = seq(_same_patterns(xs))
slowcat(xs...) = cat(_same_patterns(xs))
slowcat(xs::AbstractVector) = cat(_same_patterns(xs))

"""
    append(a, b) / slowAppend(a, b) / fastAppend(a, b) / overlay(a, b)

`append` alterne a et b un cycle sur deux, `fastAppend` les met dans le
même cycle, `overlay` les superpose (= `stack`).
"""
append(a, b) = slowcat(a, b)
slowAppend(a, b) = slowcat(a, b)
fastAppend(a, b) = fastcat(a, b)
overlay(a, b) = stack(_same_patterns((a, b))...)

"""
    timeCat([(poids, pattern), ...])

Concatène dans un cycle en donnant à chaque pattern une part
proportionnelle à son poids : `timeCat([(1, "bd*4"), (1, "hh27*8"), (2, "sn")])`.
"""
function timeCat(pairs::AbstractVector)
    isempty(pairs) && throw(ArgumentError("timeCat : liste vide"))
    ps = _same_patterns([last(pr) for pr in pairs])
    ws = [_to_rat(first(pr)) for pr in pairs]
    total = sum(ws)
    total > 0 || throw(ArgumentError("timeCat : poids nuls"))
    pos = zero(total)
    parts = similar(ps, 0)
    for (w, p) in zip(ws, ps)
        push!(parts, compress(pos / total, (pos + w) / total, p))
        pos += w
    end
    return stack(parts...)
end

"""
    ncat([(cycles, pattern), ...])

Joue chaque pattern pendant `cycles` cycles, puis passe au suivant :
`ncat([(1, "bd*2"), (2, "hh*4")])` fait bd, hh, hh, bd, hh, hh…
"""
function ncat(pairs::AbstractVector)
    ps = _same_patterns([last(pr) for pr in pairs])
    ns = [max(1, _int(first(pr))) for pr in pairs]
    total = sum(ns)
    T = eltype(ps).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            pos = mod(cyc, total); k = 1
            while pos >= ns[k]; pos -= ns[k]; k += 1; end
            append!(out, ps[k](a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    randcat(ps...) / wrandcat([(pattern, poids), ...])

À chaque cycle, joue un des patterns tiré au sort (déterministe par cycle).
`wrandcat` pondère le tirage.
"""
randcat(xs...) = wrandcat([(x, 1) for x in xs])
randcat(xs::AbstractVector) = wrandcat([(x, 1) for x in xs])
function wrandcat(pairs::AbstractVector)
    ps = _same_patterns([first(pr) for pr in pairs])
    ws = [float(last(pr)) for pr in pairs]
    T = eltype(ps).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            append!(out, ps[_weighted_index(ws, _cycle_rand(cyc))](a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

_cycle_rand(cyc::Int, salt::Integer = 0) =
    (hash(cyc, UInt(0x9e3779b97f4a7c15) ⊻ UInt(salt)) % UInt32) / Float64(typemax(UInt32))
function _weighted_index(ws::Vector{Float64}, r::Float64)
    total = sum(ws)
    acc = 0.0
    for (i, w) in enumerate(ws)
        acc += w
        r * total < acc && return i
    end
    return length(ws)
end

"""
    wedge(t, a, b)

Compresse `a` dans la première fraction `t` du cycle et `b` dans le reste.
"""
function wedge(t::Real, a, b)
    tr = _to_rat(t)
    0 < tr < 1 || throw(ArgumentError("wedge : t doit être entre 0 et 1 exclus"))
    pa, pb = _same_patterns((a, b))
    return stack(compress(0, tr, pa), compress(tr, 1, pb))
end

"""
    spaceOut([facteurs...], p)

Joue `p` successivement à chaque vitesse : `spaceOut([1, 0.5, 2], p)`
dure 3,5 cycles (1 + 0,5 + 2) puis recommence.
"""
function spaceOut(xs::AbstractVector, p)
    pp = _as_pattern(p)
    total = sum(_to_rat(x) for x in xs)
    return slow(total, timeCat([(x, pp) for x in xs]))
end
spaceOut(xs::AbstractVector) = p -> spaceOut(xs, p)

# ---------------------------------------------------------------------------
# Structure booléenne
# ---------------------------------------------------------------------------

"""
    inv(bools)

Inverse un pattern booléen : `mask(inv(p"1 0 1 1"))`.
"""
function Base.inv(p::Pattern{Bool})
    Pattern{Bool}((s::Rational, e::Rational) ->
        Event{Bool}[Event{Bool}(ev.start, ev.stop, !ev.value) for ev in p(s, e)])
end
Base.inv(p::Pattern{Symbol}) = inv(_as_bool_pattern(p))

"""
    sew(bools, a, b)

Prend les événements de `a` là où `bools` est vrai, ceux de `b` ailleurs.
"""
function sew(bools, a, b)
    bp = _as_bool_pattern(bools)
    pa, pb = _same_patterns((a, b))
    return stack(mask(pa, bp), mask(pb, inv(bp)))
end
sew(bools, a) = b -> sew(bools, a, b)

"""
    stitch(bools, a, b)

Structure de `bools` : chaque pas vrai prend la valeur de `a` à cet instant,
chaque pas faux celle de `b`.
"""
function stitch(bools, a, b)
    bp = _as_bool_pattern(bools)
    pa, pb = _same_patterns((a, b))
    T = typeof(pa).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for be in bp(s, e)
            v = _value_at(be.value ? pa : pb, be.start)
            v === nothing || push!(out, Event{T}(be.start, be.stop, v))
        end
        out
    end)
end

"""
    euclidFull(k, n, p, p2)

Rythme euclidien : `p` sur les coups, `p2` sur les pas vides.
"""
function euclidFull(k::Int, n::Int, p, p2)
    pa, pb = _same_patterns((p, p2))
    return stack(euclid(k, n, pa), euclidInv(k, n, pb))
end

"""
    binaryN(bits, n) / binary(n)

Pattern booléen des bits de `n` (poids fort en premier) : `binaryN(4, 5)`
donne `t f t f`. `binary` utilise 8 bits.
"""
function binaryN(bits::Int, n::Int)
    bits > 0 || throw(ArgumentError("binaryN : bits > 0"))
    vals = [((n >> (bits - 1 - i)) & 1) == 1 for i in 0:(bits - 1)]
    return _bool_steps(vals)
end
binary(n::Int) = binaryN(8, n)

"""
    asciip(texte)

Pattern booléen des bits ASCII du texte, 8 pas par caractère (`ascii` de
Tidal ; renommé pour ne pas masquer `Base.ascii`).
"""
asciip(txt::AbstractString) =
    _bool_steps(vcat([[((Int(c) >> (7 - i)) & 1) == 1 for i in 0:7] for c in txt]...))

"""
    necklace(longueur, [écarts...])

Un pas vrai, puis `écarts[1]` pas plus loin un autre, etc. : `necklace(12, [4, 2])`.
"""
function necklace(len::Int, gaps::AbstractVector{<:Integer})
    vals = falses(len)
    pos = 0; i = 1
    while pos < len
        vals[pos + 1] = true
        pos += gaps[mod1(i, length(gaps))]; i += 1
    end
    return _bool_steps(collect(vals))
end

function _bool_steps(vals::Vector{Bool})
    n = length(vals)
    Pattern{Bool}((s::Rational, e::Rational) -> begin
        out = Event{Bool}[]
        for cyc in _cycles(s, e), i in 0:(n - 1)
            a = Rational{Int64}(cyc) + Rational{Int64}(i, n)
            (a >= s && a < e) || continue
            push!(out, Event{Bool}(a, a + Rational{Int64}(1, n), vals[i + 1]))
        end
        out
    end)
end

"""
    mono(p)

Monophonique : un événement qui démarre pendant qu'un autre sonne est ignoré.
"""
function mono(p::Pattern{T}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        evs = sort(p(s, e); by = ev -> ev.start)
        out = Event{T}[]
        last_stop = -Inf
        for ev in evs
            ev.start >= last_stop || continue
            push!(out, ev); last_stop = ev.stop
        end
        out
    end)
end
mono(p) = mono(_as_pattern(p))

# ---------------------------------------------------------------------------
# Conditionnel
# ---------------------------------------------------------------------------

"""
    every(n, décalage, f, p)

Comme `every(n, f)` mais sur les cycles où `cycle mod n == décalage`
(le `every'` de Tidal).
"""
every(n::Int, o::Int, f, p::Pattern) = _when_cycle(c -> mod(c, n) == mod(o, n), f, p)
every(n::Int, o::Int, f) = p -> every(n, o, f, _as_pattern(p))

"""
    when(test, f, p)

Applique `f` sur les cycles pour lesquels `test(numéro_de_cycle)` est vrai :
`when(c -> c % 3 == 0, rev)`.
"""
when(test, f, p::Pattern) = _when_cycle(test, f, p)
when(test, f) = p -> when(test, f, _as_pattern(p))

"""
    whenT(test, f, p)

Applique `f` aux événements dont le DÉBUT (en cycles, rationnel) vérifie `test`.
"""
function whenT(test, f, p0::Pattern)
    p, fp = _same_patterns((p0, f(p0)))
    T = typeof(p).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[ev for ev in fp(s, e) if test(ev.start)]
        append!(out, Event{T}[ev for ev in p(s, e) if !test(ev.start)])
        sort!(out, by = ev -> ev.start)
        out
    end)
end
whenT(test, f) = p -> whenT(test, f, _as_pattern(p))

"""
    within(début, fin, f, p) / within((début, fin), f, p)

Applique `f` seulement à la portion `[début, fin)` de chaque cycle.
"""
within(b::Real, e_::Real, f, p::Pattern) = whenT(t -> b <= (t - floor(t)) < e_, f, p)
within(b::Real, e_::Real, f) = p -> within(b, e_, f, _as_pattern(p))
within(r::Tuple, f, p::Pattern) = within(r[1], r[2], f, p)
within(r::Tuple, f) = p -> within(r, f, _as_pattern(p))

"""
    ifp(test, f1, f2, p)

Sur les cycles où `test(cycle)` est vrai applique `f1`, sinon `f2`.
"""
function ifp(test, f1, f2, p::Pattern)
    fp, gp = _same_patterns((f1(p), f2(p)))
    T = typeof(fp).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            append!(out, (test(cyc) ? fp : gp)(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
ifp(test, f1, f2) = p -> ifp(test, f1, f2, _as_pattern(p))

"""
    always(f) / never(f) / almostAlways(f) / almostNever(f)

Variantes de `sometimesBy` : 1, 0, 0,9 et 0,1.
"""
always(f, p::Pattern) = f(p)
always(f) = p -> always(f, _as_pattern(p))
never(f, p::Pattern) = p
never(f) = p -> never(f, _as_pattern(p))
almostAlways(f, p::Pattern) = sometimesBy(0.9, f, p)
almostAlways(f) = p -> almostAlways(f, _as_pattern(p))
almostNever(f, p::Pattern) = sometimesBy(0.1, f, p)
almostNever(f) = p -> almostNever(f, _as_pattern(p))
const somecycles = someCycles
const somecyclesBy = someCyclesBy

"""
    fix(f, ctrls, p) / unfix(f, ctrls, p) / contrast(f, g, ctrls, p)

`fix` applique `f` aux seuls événements dont les contrôles correspondent
(`fix(fast(2), :s => :bd)`, `fix(rev, Dict(:s => :hh, :n => 2))`),
`unfix` aux autres, `contrast` `f` aux uns et `g` aux autres.
"""
function contrast(f, g, ctrls, p)
    cp = _lift_to_control(_as_pattern(p))
    want = _ctrl_dict(ctrls)
    matched   = _filter_events(ev -> _ctrl_matches(ev.value, want), cp)
    unmatched = _filter_events(ev -> !_ctrl_matches(ev.value, want), cp)
    return stack(f(matched), g(unmatched))
end
contrast(f, g, ctrls) = p -> contrast(f, g, ctrls, p)
fix(f, ctrls, p) = contrast(f, identity, ctrls, p)
fix(f, ctrls) = p -> fix(f, ctrls, p)
unfix(f, ctrls, p) = contrast(identity, f, ctrls, p)
unfix(f, ctrls) = p -> unfix(f, ctrls, p)

_ctrl_dict(d::AbstractDict) = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in d)
_ctrl_dict(pr::Pair) = Dict{Symbol,Any}(Symbol(first(pr)) => last(pr))
_ctrl_dict(prs::AbstractVector) = Dict{Symbol,Any}(Symbol(first(pr)) => last(pr) for pr in prs)
function _ctrl_matches(cm::ControlMap, want::Dict{Symbol,Any})
    for (k, v) in want
        haskey(cm, k) || return false
        _ctrl_eq(cm[k], v) || return false
    end
    return true
end
function _ctrl_eq(a, b)
    ra = _resolve_value(a isa AbstractString ? Symbol(a) : a)
    rb = _resolve_value(b isa AbstractString ? Symbol(b) : b)
    ra isa Real && rb isa Real && return isapprox(ra, rb)
    return string(ra) == string(rb)
end
function _filter_events(keep, p::Pattern{T}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> Event{T}[ev for ev in p(s, e) if keep(ev)])
end

# ---------------------------------------------------------------------------
# Aléatoire
# ---------------------------------------------------------------------------

"""
    irand(n)

Entier aléatoire dans `0:n-1`, continu comme `rand_pat` : `n(irand(8) |> segment(4))`.
"""
irand(n::Int) = _mapvals(v -> min(n - 1, floor(Int, v * n)), rand_pat(), Int)

"""
    brand() / brandBy(prob)

Pattern booléen aléatoire (continu) : vrai avec probabilité `prob` (0,5 par défaut).
"""
brandBy(prob::Real) = _mapvals(v -> v < prob, rand_pat(), Bool)
brand() = brandBy(0.5)

"""
    chooseBy(rp, xs) / wchoose([(x, poids), ...]) / wchooseBy(rp, pairs) / cycleChoose(xs)

`chooseBy` choisit dans `xs` avec un pattern aléatoire `rp` (0..1) ;
`wchoose` tire pondéré, un choix par cycle ; `cycleChoose` = `choose`.
"""
function chooseBy(rp::Pattern{Float64}, xs::AbstractVector{T}) where {T}
    n = length(xs)
    n > 0 || throw(ArgumentError("chooseBy : liste vide"))
    _mapvals(v -> xs[clamp(floor(Int, v * n) + 1, 1, n)], rp, T)
end
function wchooseBy(rp::Pattern{Float64}, pairs::AbstractVector)
    xs = [first(pr) for pr in pairs]; ws = [float(last(pr)) for pr in pairs]
    T = eltype(xs)
    _mapvals(v -> xs[_weighted_index(ws, clamp(v, 0.0, 0.999999))], rp, T)
end
function wchoose(pairs::AbstractVector)
    xs = [first(pr) for pr in pairs]; ws = [float(last(pr)) for pr in pairs]
    T = eltype(xs)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b && push!(out, Event{T}(a, b, xs[_weighted_index(ws, _cycle_rand(cyc, 7))]))
        end
        out
    end)
end
const cycleChoose = choose

"""
    unDegradeBy(prob, p)

Complément de `degradeBy` : garde exactement les événements que
`degradeBy(prob)` aurait laissés tomber.
"""
function unDegradeBy(prob::Real, p::Pattern{T}) where {T}
    pr = clamp(float(prob), 0.0, 1.0)
    Pattern{T}((s::Rational, e::Rational) -> begin
        [ev for ev in p(s, e) if
         (hash(ev.start) % UInt32(1_000_000)) / 1_000_000.0 < pr]
    end)
end
unDegradeBy(prob::Real) = p -> unDegradeBy(prob, _as_pattern(p))

"""
    randslice(n, p)

Joue à chaque cycle une tranche aléatoire (sur `n`) de chaque sample.
"""
function randslice(n::Int, p)
    cp = _lift_to_control(_as_pattern(p))
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        out = Event{ControlMap}[]
        for ev in cp(s, e)
            i = floor(Int, _cycle_rand(floor(Int, ev.start), 3) * n)
            cm = copy(ev.value)
            cm[:begin] = Float32(i) / Float32(n); cm[:end] = Float32(i + 1) / Float32(n)
            push!(out, Event{ControlMap}(ev.start, ev.stop, cm))
        end
        out
    end)
end
randslice(n::Int) = p -> randslice(n, p)

"""
    select(fpat, [patterns...]) / selectF(fpat, [fonctions...], p) / pickF(ipat, [fonctions...], p)

`select` choisit un pattern avec une valeur 0..1 (nombre, chaîne ou signal :
`select(slow(4, saw()), ["bd*4", "hh*8"])`), `selectF` une fonction à
appliquer, `pickF` pareil avec un index entier (`pickF("0 1", [rev, fast(2)])`).
"""
function select(fpat, xs::AbstractVector)
    ps = _same_patterns(xs)
    fp = _num_pattern(fpat)
    n = length(ps)
    T = eltype(ps).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for fe in fp(s, e)
            i = clamp(floor(Int, _num(fe.value) * n) + 1, 1, n)
            a = max(fe.start, s); b = min(fe.stop, e)
            a < b && append!(out, ps[i](a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
selectF(fpat, fs::AbstractVector, p) = (pp = _as_pattern(p); select(fpat, [f(pp) for f in fs]))
selectF(fpat, fs::AbstractVector) = p -> selectF(fpat, fs, p)
function pickF(ipat, fs::AbstractVector, p)
    pp = _as_pattern(p)
    n = length(fs)
    ip = _num_pattern(ipat)
    fpat = _mapvals(v -> (mod(_int(v), n) + 0.5) / n, ip, Float64)
    return select(fpat, [f(pp) for f in fs])
end
pickF(ipat, fs::AbstractVector) = p -> pickF(ipat, fs, p)

# ---------------------------------------------------------------------------
# Découpage / tranches
# ---------------------------------------------------------------------------

"""
    squeeze(ipat, [patterns...])

Chaque événement de `ipat` (index entier) joue le pattern correspondant
compressé dans son créneau : `squeeze("0 1*2", ["bd sn", "hh*3"])`.
"""
function squeeze(ipat, xs::AbstractVector)
    ps = _same_patterns(xs)
    ip = _num_pattern(ipat)
    n = length(ps)
    T = eltype(ps).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for ie in ip(floor(Int, s) // 1, ceil(Int, e) // 1)
            i = mod(_int(ie.value), n) + 1
            _squeeze_cycle!(out, ps[i], floor(Int, ie.start), ie.start, ie.stop, s, e)
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    bite(n, ipat, p) / chew(n, ipat, p)

Découpe chaque cycle de `p` en `n` tranches et les rejoue selon `ipat` :
`bite(4, "0 2*2", "bd hh sn cp")`. `chew` ajuste aussi la vitesse de
lecture quand la tranche est étirée ou compressée.
"""
bite(n::Int, ipat, p) = _bite(n, ipat, _as_pattern(p), false)
bite(n::Int, ipat) = p -> bite(n, ipat, p)
chew(n::Int, ipat, p) = _bite(n, ipat, _lift_to_control(_as_pattern(p)), true)
chew(n::Int, ipat) = p -> chew(n, ipat, p)
function _bite(n::Int, ipat, p::Pattern{T}, adjust::Bool) where {T}
    n > 0 || throw(ArgumentError("bite : n > 0"))
    ip = _num_pattern(ipat)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for ie in ip(floor(Int, s) // 1, ceil(Int, e) // 1)
            cyc = Rational{Int64}(floor(Int, ie.start))
            i = mod(_int(ie.value), n)
            ts = cyc + Rational{Int64}(i, n); te = ts + Rational{Int64}(1, n)
            evs = Event{T}[]
            _squeeze_slice!(evs, p, ts, te, ie.start, ie.stop, s, e)
            if adjust
                factor = Float64(Rational{Int64}(1, n) / (ie.stop - ie.start))
                evs = Event{T}[Event{T}(ev.start, ev.stop, _mul_speed(ev.value, factor)) for ev in evs]
            end
            append!(out, evs)
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
_mul_speed(cm::ControlMap, f::Float64) = (c = copy(cm); c[:speed] = get(c, :speed, 1.0) * f; c)
_mul_speed(v, f) = v

"""
    striate(n, p) / striateBy(n, fraction, p)

Tidal : le cycle joue `p` `n` fois plus vite, la i-ème répétition ne
lisant que la i-ème tranche du sample. `striateBy` fixe la longueur des
tranches (fraction 0..1). Pour découper CHAQUE événement en n, voir `chopp`.
"""
function striate(n::Int, p)
    n > 0 || throw(ArgumentError("striate needs n > 0"))
    cp = _lift_to_control(_as_pattern(p))
    return seq([cp |> begin_(Float32(i) / n) |> end_(Float32(i + 1) / n) for i in 0:(n - 1)])
end
striate(n::Int) = p -> striate(n, p)
function striateBy(n::Int, f::Real, p)
    n > 0 || throw(ArgumentError("striateBy needs n > 0"))
    cp = _lift_to_control(_as_pattern(p))
    slot = n == 1 ? 0.0 : (1 - f) / (n - 1)
    return seq([cp |> begin_(Float32(slot * i)) |> end_(Float32(slot * i + f)) for i in 0:(n - 1)])
end
striateBy(n::Int, f::Real) = p -> striateBy(n, f, p)

"""
    slice(n, ipat, p) / splice(n, ipat, p)

`slice` joue la tranche `ipat` (sur `n`) du sample, structure de `ipat` :
`slice(8, "7 6 5 4", :amen)`. `splice` ajuste la vitesse pour que la
tranche remplisse exactement son créneau.
"""
function slice(n::Int, ipat, p)
    n > 0 || throw(ArgumentError("slice : n > 0"))
    cp = _lift_to_control(_as_pattern(p))
    ip = _num_pattern(ipat)
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        out = Event{ControlMap}[]
        for ie in ip(s, e)
            v = _value_at(cp, ie.start)
            v === nothing && continue
            i = mod(_int(ie.value), n)
            cm = copy(v)
            cm[:begin] = Float32(i) / Float32(n); cm[:end] = Float32(i + 1) / Float32(n)
            push!(out, Event{ControlMap}(ie.start, ie.stop, cm))
        end
        out
    end)
end
slice(n::Int, ipat) = p -> slice(n, ipat, p)
function splice(n::Int, ipat, p)
    base = slice(n, ipat, p)
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        out = Event{ControlMap}[]
        for ev in base(s, e)
            cm = copy(ev.value)
            d = (1 / n) / Float64(ev.stop - ev.start)
            cm[:speed] = get(cm, :speed, 1.0) * d
            cm[:unit] = :c
            push!(out, Event{ControlMap}(ev.start, ev.stop, cm))
        end
        out
    end)
end
splice(n::Int, ipat) = p -> splice(n, ipat, p)

"""
    loopAt(n, p)

Étire un sample sur `n` cycles (vitesse et durée ajustées) : `loopAt(2, :breaks125)`.
"""
loopAt(n::Real, p) = slow(n, _lift_to_control(_as_pattern(p))) |> speed(1 / n) |> unit("c")
loopAt(n::Real) = p -> loopAt(n, p)

"""
    smash(n, [facteurs...], p)

`striate(n)` puis chaque facteur ralentit le résultat, enchaînés cycle par cycle.
"""
smash(n::Int, xs::AbstractVector, p) = (st = striate(n, p); cat([slow(x, st) for x in xs]))
smash(n::Int, xs::AbstractVector) = p -> smash(n, xs, p)

"""
    fit(pas, [valeurs...], ipat)

Prend les valeurs par index dans `ipat`, l'index avançant de `pas` à chaque
cycle : `n(fit(1, [0, 3, 7], "0 1 2 1"))`.
"""
function fit(step::Int, xs::AbstractVector{T}, ipat) where {T}
    n = length(xs)
    ip = _num_pattern(ipat)
    Pattern{T}((s::Rational, e::Rational) ->
        Event{T}[Event{T}(ev.start, ev.stop, xs[mod(_int(ev.value) + step * floor(Int, ev.start), n) + 1])
                 for ev in ip(s, e)])
end

# ---------------------------------------------------------------------------
# Accumulation
# ---------------------------------------------------------------------------

"""
    echo(n, temps, feedback, p) / echoWith(n, temps, f, p) / stutter(n, temps, p)

`echo` = `stut` avec l'ordre d'arguments de Tidal (nombre, temps, feedback).
`echoWith` applique `f` cumulativement à chaque répétition,
`stutter` répète sans modification.
"""
echo(n::Int, time::Real, feedback::Real, p) = stut(n, feedback, time, p)
echo(n::Int, time::Real, feedback::Real) = p -> echo(n, time, feedback, p)
function echoWith(n::Int, time::Real, f, p)
    pp = _as_pattern(p)
    layers = Any[pp]
    cur = pp
    for _ in 2:n
        cur = f(late(time, cur))
        push!(layers, cur)
    end
    return stack(_same_patterns(layers)...)
end
echoWith(n::Int, time::Real, f) = p -> echoWith(n, time, f, p)
const stutWith = echoWith
stutter(n::Int, time::Real, p) = echoWith(n, time, identity, p)
stutter(n::Int, time::Real) = p -> stutter(n, time, p)

"""
    plyWith(n, f, p)

Comme `ply(n)` mais la i-ème copie reçoit `f` i fois : `plyWith(3, gain(0.8))`.
"""
function plyWith(n::Int, f, p)
    pp = _as_pattern(p)
    layers = Any[pp]
    cur = pp
    for _ in 2:n
        cur = f(cur); push!(layers, cur)
    end
    return arpeggiate(stack(_same_patterns(layers)...))
end
plyWith(n::Int, f) = p -> plyWith(n, f, p)

"""
    arpeggiate(p) / arpg(p)

Les événements qui partagent le même créneau sont joués l'un après l'autre,
dans l'ordre où ils sont empilés (sans tri par hauteur, contrairement à `arp`).
"""
function arpeggiate(p::Pattern{T}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        spans = Tuple{Rational{Int64},Rational{Int64}}[]
        groups = Dict{Tuple{Rational{Int64},Rational{Int64}},Vector{Event{T}}}()
        for ev in p(s, e)
            k = (ev.start, ev.stop)
            haskey(groups, k) || (push!(spans, k); groups[k] = Event{T}[])
            push!(groups[k], ev)
        end
        sort!(spans, by = first)
        out = Event{T}[]
        for (a, b) in spans
            g = groups[(a, b)]
            w = (b - a) / length(g)
            for (k, ev) in enumerate(g)
                push!(out, Event{T}(a + w * (k - 1), k == length(g) ? b : a + w * k, ev.value))
            end
        end
        out
    end)
end
arpeggiate(p) = arpeggiate(_as_pattern(p))
const arpg = arpeggiate

"""
    spread(f, [valeurs...], p) / fastspread(f, [valeurs...], p)
    spreadf([fonctions...], p) / spreadChoose(f, [valeurs...], p)

`spread(fast, [1, 2], p)` joue `fast(1)` un cycle, `fast(2)` le suivant ;
`fastspread` fait tout dans un cycle ; `spreadf` enchaîne des fonctions ;
`spreadChoose` (alias `spreadr`) tire au sort chaque cycle.
"""
spread(f, xs::AbstractVector, p) = (pp = _as_pattern(p); cat(_same_patterns([f(x)(pp) for x in xs])))
spread(f, xs::AbstractVector) = p -> spread(f, xs, p)
fastspread(f, xs::AbstractVector, p) = (pp = _as_pattern(p); seq(_same_patterns([f(x)(pp) for x in xs])))
fastspread(f, xs::AbstractVector) = p -> fastspread(f, xs, p)
spreadf(fs::AbstractVector, p) = (pp = _as_pattern(p); cat(_same_patterns([f(pp) for f in fs])))
spreadf(fs::AbstractVector) = p -> spreadf(fs, p)
spreadChoose(f, xs::AbstractVector, p) = (pp = _as_pattern(p); randcat([f(x)(pp) for x in xs]))
spreadChoose(f, xs::AbstractVector) = p -> spreadChoose(f, xs, p)
const spreadr = spreadChoose

"""
    chunkBack(n, f, p)

Comme `chunk` mais les morceaux défilent à l'envers (le `chunk'` de Tidal).
"""
function chunkBack(n::Int, f, p0::Pattern)
    n >= 1 || throw(ArgumentError("chunkBack : n ≥ 1"))
    p, fp = _same_patterns((p0, f(p0)))
    T = typeof(p).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            base = Rational{Int64}(cyc)
            active = mod(-cyc - 1, n)
            for k in 0:(n - 1)
                a = max(base + Rational{Int64}(k, n), s); b = min(base + Rational{Int64}(k + 1, n), e)
                a < b || continue
                append!(out, (k == active ? fp : p)(a, b))
            end
        end
        out
    end)
end
chunkBack(n::Int, f) = p -> chunkBack(n, f, _as_pattern(p))

"""
    ghost(p) / ghostWith(temps, f, p)

Ajoute des notes fantômes : deux copies décalées (1,5× et 2,5× `temps`),
plus douces, plus courtes et un peu plus aiguës. `ghostWith` choisit la
transformation appliquée aux copies.
"""
function ghostWith(a::Real, f, p)
    pp = _as_pattern(p)
    inner = superimpose(x -> late(1.5 * a, f(x)), pp)
    return superimpose(x -> late(2.5 * a, f(x)), inner)
end
ghostWith(a::Real, f) = p -> ghostWith(a, f, p)
ghost(p) = ghostWith(1 // 8, x -> x |> gain(0.7) |> end_(0.2) |> speed(1.25), _lift_to_control(_as_pattern(p)))

"""
    press(p) / pressBy(r, p)

Décale chaque événement dans la seconde moitié (`pressBy(r)` : la
fraction `r`) de son créneau : `press("bd sn")` sonne « en l'air ».
"""
function pressBy(r::Real, p::Pattern{T}) where {T}
    rr = _to_rat(r)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for ev in p(floor(Int, s) // 1, e)
            a = ev.start + (ev.stop - ev.start) * rr
            a >= s && a < e && push!(out, Event{T}(a, ev.stop, ev.value))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
pressBy(r::Real) = p -> pressBy(r, _as_pattern(p))
press(p) = pressBy(1 // 2, _as_pattern(p))

"""
    truncp(t, p)

Ne joue que la première fraction `t` de chaque cycle (`trunc` de Tidal ;
renommé pour ne pas masquer `Base.trunc`).
"""
function truncp(t::Real, p::Pattern{T}) where {T}
    tr = _to_rat(t)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for ev in p(s, e)
            pos = ev.start - floor(ev.start)
            pos < tr || continue
            push!(out, Event{T}(ev.start, min(ev.stop, floor(ev.start) + tr), ev.value))
        end
        out
    end)
end
truncp(t::Real) = p -> truncp(t, _as_pattern(p))

"""
    weave(t, contrôle, signal, [patterns...]) / weaveWith(t, p, [fonctions...])

`weave(4, pan, sine(), ["bd sn", "hh*4"])` applique le signal étiré sur
`t` cycles à chaque pattern, avec un décalage différent pour chacun.
`weaveWith(3, "bd sn", [fast(2), rev])` applique chaque fonction sur
une fenêtre glissante décalée.
"""
function weave(t::Real, ctrl, sig::Pattern, xs::AbstractVector)
    ps = _same_patterns(xs)
    l = length(ps)
    tr = _to_rat(t)
    layers = [ps[i] |> ctrl(late(tr * (i - 1) / l, slow(tr, sig))) for i in 1:l]
    return stack(layers...)
end
function weaveWith(t::Real, p, fs::AbstractVector)
    pp = _as_pattern(p)
    l = length(fs)
    tr = _to_rat(t)
    layers = [late(Rational{Int64}(i - 1) // l, inside(tr, fs[i], fast(tr, pp))) for i in 1:l]
    return slow(tr, stack(_same_patterns(layers)...))
end

"""
    ur(cycles, plan, Dict(nom => pattern), Dict(nom => fonction))

Arrange des patterns nommés sur `cycles` cycles selon `plan` :
`ur(4, "a b:x", Dict("a" => pa, "b" => pb), Dict("x" => fast(2)))`. Les
patterns jouent à leur vitesse normale, fenêtrés dans leur créneau.
"""
function ur(t::Real, plan, pats::AbstractDict, fxs::AbstractDict = Dict())
    tr = _to_rat(t)
    outer = slow(tr, parse_minino(String(plan)))
    names = Dict{String,Any}(string(k) => _lift_to_control(_as_pattern(v)) for (k, v) in pats)
    fxd = Dict{String,Any}(string(k) => v for (k, v) in fxs)
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        out = Event{ControlMap}[]
        for oe in outer(floor(Int, s) // 1, e)
            parts = split(String(oe.value), ':')
            pat = get(names, String(parts[1]), nothing)
            pat === nothing && continue
            for fname in parts[2:end]
                f = get(fxd, String(fname), nothing)
                f === nothing || (pat = f(pat))
            end
            a = max(oe.start, s); b = min(oe.stop, e)
            a < b || continue
            append!(out, Event{ControlMap}[ev for ev in pat(a, b) if ev.start >= oe.start])
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

# ---------------------------------------------------------------------------
# Valeurs
# ---------------------------------------------------------------------------

"""
    quantise(p)

Arrondit chaque valeur numérique à l'entier le plus proche.
"""
quantise(p::Pattern{T}) where {T} =
    _mapvals(v -> (r = _num(v); r isa Integer ? r : round(Int, r)), p, Int)
quantise(p) = quantise(_as_pattern(p))

"""
    smooth(p)

Signal continu qui interpole linéairement entre les valeurs successives de `p`.
"""
function smooth(p::Pattern)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        mid = (s + e) / 2
        c = Rational{Int64}(floor(Int, mid))
        evs = sort(p(c, c + 2); by = ev -> ev.start)
        cur = findlast(ev -> ev.start <= mid, evs)
        cur === nothing && return Event{Float64}[]
        v0 = Float64(_num(evs[cur].value))
        v = if cur < length(evs)
            nxt = evs[cur + 1]
            v1 = Float64(_num(nxt.value))
            span = nxt.start - evs[cur].start
            span > 0 ? v0 + (v1 - v0) * Float64((mid - evs[cur].start) / span) : v0
        else
            v0
        end
        [Event{Float64}(s, e, v)]
    end)
end
smooth(p) = smooth(_as_pattern(p))

"""
    rangex(lo, hi, p)

Comme `range_pat` mais en échelle exponentielle (fréquences) :
`lpf(sine() |> rangex(200, 8000))`.
"""
function rangex(lo::Real, hi::Real, p::Pattern{Float64})
    llo = log(lo); lhi = log(hi)
    _mapvals(v -> exp(llo + (lhi - llo) * ((v + 1) / 2)), p, Float64)
end
rangex(lo::Real, hi::Real) = p -> rangex(lo, hi, _as_pattern(p))

"""
    toScale([degrés...], p)

Convertit des degrés en demi-tons dans une gamme donnée par ses intervalles :
`n(toScale([0, 2, 4, 5, 7, 9, 11], "0 1 2 3 7 8"))` — 7 → octave supérieure.
"""
function toScale(xs::AbstractVector{<:Real}, p)
    pp = _num_pattern(p)
    n = length(xs)
    n > 0 || throw(ArgumentError("toScale : gamme vide"))
    _mapvals(v -> (i = _int(v); xs[mod(i, n) + 1] + 12 * fld(i, n)), pp, Float64)
end
toScale(xs::AbstractVector{<:Real}) = p -> toScale(xs, p)

"""
    scan(n)

Enchaîne `run(1)`, `run(2)`, … `run(n)` un cycle après l'autre.
"""
scan(n::Int) = cat([run(i) for i in 1:n])

"""
    discretise(n, p)

Alias de `segment`.
"""
const discretise = segment

# ---------------------------------------------------------------------------
# Arithmétique de contrôles en pipe : add / sub / mul
# ---------------------------------------------------------------------------

"""
    add(clé, x) / sub(clé, x) / mul(clé, x)

Le `|+ n 12`, `|- …`, `|* gain 0.5` de Tidal, en pipe :
`:bd |> n("0 3") |> add(:n, "<0 12>")`. `x` : nombre, chaîne ou pattern.
Si la clé est absente de l'événement, elle est simplement posée.
"""
add(key::Symbol, x) = _control_op(key, +, x)
sub(key::Symbol, x) = _control_op(key, -, x)
mul(key::Symbol, x) = _control_op(key, *, x)

# ---------------------------------------------------------------------------
# Arithmétique Tidal générale : |+| |-| |*| |/| |%|
# ---------------------------------------------------------------------------
#
# Les méthodes de core_algebra.jl couvrent Pattern{<:Number}. Celles-ci étendent aux
# patterns de mini-notation (valeurs Symbol), aux ControlPattern et aux
# chaînes. Structure des DEUX côtés (intersection des créneaux), comme les
# opérateurs `|op|` de Tidal. Pour ne garder que la structure de gauche,
# passer par le pipe : `|> add(:n, "<0 12>")`.

_arith(op, a, b) = op(_arith_num(a), _arith_num(b))
_arith_num(v) = (r = _resolve_value(v isa AbstractString ? Symbol(v) : v);
                 r isa Real ? r : throw(ArgumentError("valeur non numérique « $v »")))

# ControlMap ⊕ ControlMap : clés communes numériques → op ; `:s` sous `+`
# se concatène (`s("bd") + s(":3")` → bd:3) ; sinon la droite gagne.
function _arith(op, a::ControlMap, b::ControlMap)
    out = copy(a)
    for (k, v) in b
        if haskey(out, k)
            ra = _resolve_value(out[k]); rb = _resolve_value(v)
            if ra isa Real && rb isa Real
                out[k] = op(ra, rb)
            elseif op === (+) && (k === :s || !(ra isa Real))
                out[k] = Symbol(string(out[k], v))
            else
                out[k] = v
            end
        else
            out[k] = v
        end
    end
    return out
end
# ControlMap ⊕ nombre : toutes les valeurs numériques.
function _arith(op, a::ControlMap, x::Real)
    out = copy(a)
    for (k, v) in a
        r = _resolve_value(v)
        r isa Real && k !== :s && (out[k] = op(r, x))
    end
    return out
end
_arith(op, x::Real, a::ControlMap) = _arith((u, v) -> op(v, u), a, x)

for op in (:+, :-, :*, :/, :%, :mod)
    @eval begin
        Base.$op(p::Pattern, q::Pattern) = _combine((a, b) -> _arith($op, a, b), p, q, Any)
        Base.$op(p::ControlPattern, q::ControlPattern) =
            _combine((a, b) -> _arith($op, a, b), p, q, ControlMap)
        Base.$op(p::Pattern, x::Number) = _mapvals(v -> _arith($op, v, x), p, Any)
        Base.$op(x::Number, p::Pattern) = _mapvals(v -> _arith($op, x, v), p, Any)
        Base.$op(p::ControlPattern, x::Number) = _mapvals(v -> _arith($op, v, x), p, ControlMap)
        Base.$op(x::Number, p::ControlPattern) = _mapvals(v -> _arith($op, x, v), p, ControlMap)
        Base.$op(p::Pattern, q::AbstractString) = $op(p, parse_minino(String(q)))
        Base.$op(q::AbstractString, p::Pattern) = $op(parse_minino(String(q)), p)
    end
end
