# src/mix_helpers.jl
# Éviter que les sons se marchent dessus — le travail de mixage, écrit
# comme des combinateurs plutôt que fait à la main sur des faders.
#
# Trois façons de se gêner, trois réponses :
#   * MÊME MOMENT — deux attaques pile ensemble s'additionnent et
#     saturent, ou s'annulent si les phases s'opposent. `duck` baisse
#     l'une quand l'autre frappe, `avoid` décale ou retire ce qui tombe
#     trop près.
#   * MÊME BANDE — deux sons dans les mêmes fréquences se masquent.
#     `band` donne une fenêtre, `slot_band` en découpe une par voix.
#   * MÊME ENDROIT — tout au centre fait une bouillie. `fan` répartit.
#
# `declash` applique les trois d'un coup à une liste de patterns, et
# `clashes` dit ce qui se cogne dans ce qui joue déjà.

# ── Même moment ────────────────────────────────────────────────────

"""
    duck(déclencheur; depth = 0.7, release = 1//8) -> (Pattern -> ControlPattern)

Compression parallèle façon sidechain, mais pilotée par un VRAI pattern :
chaque fois que `déclencheur` frappe, le gain plonge puis remonte en
`release` cycles. C'est ce qu'on fait à la main entre la grosse caisse
et la basse.

`pump` fait la même forme sur une grille fixe ; `duck` suit le pattern
qu'on lui donne, même syncopé.

```julia
@d1 "bd(3,8)"
@d2 :bass |> n("0 3") |> duck("bd(3,8)")       # la basse s'efface sous le kick
@d2 :bass |> duck("bd*4"; depth = 0.9, release = 1//16)
```
"""
function duck(trigger; depth::Real = 0.7, release = 1//8)
    tp = _as_pattern(trigger)
    floor_v = clamp(1.0 - float(depth), 0.0, 1.0)
    rel = _to_rat(release)
    rel > 0 || throw(ArgumentError("duck : release > 0"))
    return function (p)
        cp = _lift_to_control(_as_pattern(p))
        Pattern{ControlMap}((s::Rational, e::Rational) -> begin
            out = Event{ControlMap}[]
            for ev in cp(s, e)
                g = _duck_gain(tp, ev.start, floor_v, rel)
                cm = copy(ev.value)
                cm[:gain] = _num_or(get(cm, :gain, 1.0), 1.0) * g
                push!(out, Event{ControlMap}(ev.start, ev.stop, cm))
            end
            out
        end)
    end
end

_num_or(v, default) = (r = _resolve_value(v); r isa Real ? float(r) : default)

# Gain au temps `t` : plancher juste après un coup du déclencheur, retour
# linéaire à 1 au bout de `rel`. On regarde le cycle courant et le
# précédent, pour qu'un coup à cheval sur la barre compte encore.
function _duck_gain(tp::Pattern, t::Rational, floor_v::Float64, rel::Rational)
    c = floor(Int, t)
    last = nothing
    for cyc in (c - 1):c
        for ev in tp(Rational{Int64}(cyc), Rational{Int64}(cyc + 1))
            ev.start <= t && (last === nothing || ev.start > last) && (last = ev.start)
        end
    end
    last === nothing && return 1.0
    dt = t - last
    dt >= rel && return 1.0
    return floor_v + (1.0 - floor_v) * Float64(dt / rel)
end

"""
    avoid(autre; window = 1//32, mode = :drop) -> (Pattern -> Pattern)

Retire (`:drop`) ou décale (`:nudge`) les événements qui tombent à moins
de `window` cycle d'une attaque d'`autre`. De quoi garder deux voix
lisibles sans les mixer : ce qui aurait sonné en même temps s'écarte.

```julia
@d1 "bd(3,8)"
@d2 "hh*8" |> avoid("bd(3,8)")                    # le charleston laisse passer le kick
@d3 :perc |> avoid("bd*4"; mode = :nudge)         # décalé plutôt que supprimé
```
"""
function avoid(other; window = 1//32, mode::Symbol = :drop)
    mode in (:drop, :nudge) || throw(ArgumentError("avoid : mode :drop ou :nudge"))
    op = _as_pattern(other)
    w = _to_rat(window)
    w > 0 || throw(ArgumentError("avoid : window > 0"))
    return function (p)
        pp = _as_pattern(p)
        T = typeof(pp).parameters[1]
        Pattern{T}((s::Rational, e::Rational) -> begin
            onsets = _onsets_around(op, s, e)
            out = Event{T}[]
            for ev in pp(s, e)
                hit = _nearest_onset(onsets, ev.start, w)
                if hit === nothing
                    push!(out, ev)
                elseif mode === :nudge
                    shifted = hit + w
                    push!(out, Event{T}(shifted, shifted + (ev.stop - ev.start), ev.value))
                end
            end
            sort!(out, by = ev -> ev.start)
            out
        end)
    end
end

# Attaques d'un pattern sur la fenêtre, élargie d'un cycle de chaque côté.
function _onsets_around(p::Pattern, s::Rational, e::Rational)
    out = Rational{Int64}[]
    for cyc in (floor(Int, s) - 1):(ceil(Int, e))
        for ev in p(Rational{Int64}(cyc), Rational{Int64}(cyc + 1))
            push!(out, ev.start)
        end
    end
    sort!(out)
    return out
end

# L'attaque la plus proche de `t` à moins de `w`, ou rien.
function _nearest_onset(onsets::Vector{Rational{Int64}}, t::Rational, w::Rational)
    best = nothing
    for o in onsets
        d = abs(t - o)
        d < w && (best === nothing || d < abs(t - best)) && (best = o)
    end
    return best
end

# ── Même bande ─────────────────────────────────────────────────────

"""
    band(bas, haut) -> (Pattern -> ControlPattern)

Ne garde qu'une fenêtre de fréquences : passe-haut à `bas`, passe-bas à
`haut`. Donner une fenêtre à chaque voix est la façon la plus directe
d'empêcher deux sons de se masquer.

```julia
@d1 :bass |> band(40, 250)
@d2 :pad  |> band(250, 2000)
@d3 :lead |> band(2000, 12000)
```
"""
band(lo::Real, hi::Real) = p -> (_as_pattern(p) |> hpf(lo) |> lpf(hi))

"""
    slot_band(i, n; lo = 60, hi = 12000) -> (Pattern -> ControlPattern)

La `i`-ème fenêtre sur `n`, découpée géométriquement entre `lo` et `hi`
— géométriquement parce que l'oreille entend les fréquences ainsi. Les
fenêtres se touchent sans se recouvrir.

```julia
@d1 :bass |> slot_band(1, 3)
@d2 :pad  |> slot_band(2, 3)
@d3 :lead |> slot_band(3, 3)
```
"""
function slot_band(i::Integer, n::Integer; lo::Real = 60, hi::Real = 12000)
    (n >= 1 && 1 <= i <= n) || throw(ArgumentError("slot_band : 1 ≤ i ≤ n"))
    edges = geom(lo, hi, n + 1)
    return band(edges[i], edges[i + 1])
end

# ── Même endroit ───────────────────────────────────────────────────

"""
    fan(i, n; width = 0.8) -> (Pattern -> ControlPattern)

Place la `i`-ème voix sur `n` dans le champ stéréo, réparties
régulièrement autour du centre. `width = 0` remet tout au milieu, `1`
va d'un bord à l'autre.

```julia
@d1 "hh*8" |> fan(1, 3)
@d2 "cp*2" |> fan(2, 3)
@d3 :shaker |> fan(3, 3)
```
"""
function fan(i::Integer, n::Integer; width::Real = 0.8)
    (n >= 1 && 1 <= i <= n) || throw(ArgumentError("fan : 1 ≤ i ≤ n"))
    w = clamp(float(width), 0.0, 1.0)
    pos = n == 1 ? 0.5 : (0.5 - w / 2) + w * (i - 1) / (n - 1)
    return p -> (_as_pattern(p) |> pan(pos))
end

# ── Les trois d'un coup ────────────────────────────────────────────

"""
    declash(patterns; bands = true, panning = true, duck_first = 0)

Applique le dégagement à une liste de patterns, dans l'ordre donné : à
chacun sa fenêtre de fréquences (`slot_band`) et sa place dans le champ
stéréo (`fan`). `duck_first = k` fait en plus plonger toutes les voix
suivantes sous la `k`-ième — typiquement la grosse caisse.

Renvoie la liste des patterns modifiés, à poser sur les slots.

```julia
voix = declash([p"bd*4", :bass |> n("0 3"), :pad, "hh*8"]; duck_first = 1)
@d1 voix[1]
@d2 voix[2]
@d3 voix[3]
@d4 voix[4]
```
"""
function declash(patterns::AbstractVector;
                 bands::Bool = true, panning::Bool = true,
                 duck_first::Integer = 0,
                 depth::Real = 0.7, release = 1//8,
                 lo::Real = 60, hi::Real = 12000, width::Real = 0.8)
    n = length(patterns)
    n == 0 && return Any[]
    (0 <= duck_first <= n) || throw(ArgumentError("declash : duck_first entre 0 et $n"))
    trigger = duck_first == 0 ? nothing : _as_pattern(patterns[duck_first])
    out = Any[]
    for (i, p) in enumerate(patterns)
        q = _as_pattern(p)
        bands   && (q = slot_band(i, n; lo = lo, hi = hi)(q))
        panning && (q = fan(i, n; width = width)(q))
        if trigger !== nothing && i != duck_first
            q = duck(trigger; depth = depth, release = release)(q)
        end
        push!(out, q)
    end
    return out
end

# ── Diagnostic ─────────────────────────────────────────────────────

"""
    clashes(patterns::AbstractDict; cycles = 4, window = 1//64) -> Vector

Ce qui se cogne dans un jeu de patterns nommés : pour chaque paire, la
part d'attaques simultanées (à `window` près) et le recouvrement de
bandes quand les deux posent un filtre. Renvoie des tuples
`(a, b, part, note)` triés du plus gênant au moins gênant.

C'est ce qu'affiche `:clash` sur les slots qui jouent.
"""
function clashes(patterns::AbstractDict; cycles::Integer = 4, window = 1//64)
    w = _to_rat(window)
    names = sort!(collect(keys(patterns)); by = string)
    info = Dict{Any,Tuple{Vector{Rational{Int64}},Union{Nothing,Float64},Union{Nothing,Float64}}}()
    for nm in names
        evs = Event[]
        try
            for c in 0:(cycles - 1)
                append!(evs, patterns[nm](Rational{Int64}(c), Rational{Int64}(c + 1)))
            end
        catch
            continue
        end
        onsets = Rational{Int64}[ev.start for ev in evs]
        info[nm] = (onsets, _band_edge(evs, :hcutoff), _band_edge(evs, :cutoff))
    end
    out = Tuple{Any,Any,Float64,String}[]
    for i in 1:length(names), j in (i + 1):length(names)
        a, b = names[i], names[j]
        (haskey(info, a) && haskey(info, b)) || continue
        oa, ha, la = info[a]
        ob, hb, lb = info[b]
        (isempty(oa) || isempty(ob)) && continue
        # On retient le pire des deux points de vue : une petite voix
        # entièrement recouverte par une grosse se gêne autant que
        # l'inverse, même si la proportion diffère.
        t_ab = count(t -> any(u -> abs(t - u) < w, ob), oa)
        t_ba = count(t -> any(u -> abs(t - u) < w, oa), ob)
        share = max(t_ab / length(oa), t_ba / length(ob))
        share > 0 || continue
        known = (ha !== nothing || la !== nothing) && (hb !== nothing || lb !== nothing)
        overlap = _bands_overlap(ha, la, hb, lb)
        note = if known && overlap && share > 0.5
            "mêmes attaques et mêmes fréquences — duck ou slot_band"
        elseif known && overlap
            "bandes qui se recouvrent — band / slot_band"
        elseif known
            "attaques simultanées, bandes séparées — duck ou avoid"
        elseif (ha === nothing && la === nothing) && (hb === nothing && lb === nothing)
            "attaques simultanées — duck ou avoid, ou une fenêtre avec slot_band"
        else
            "attaques simultanées, une des deux voix n'a pas de fenêtre — slot_band"
        end
        push!(out, (a, b, share, note))
    end
    sort!(out; by = t -> -t[3])
    return out
end

# La valeur d'un filtre si tous les événements la partagent, sinon rien.
function _band_edge(evs::AbstractVector, key::Symbol)
    vals = Float64[]
    for ev in evs
        ev.value isa AbstractDict || continue
        haskey(ev.value, key) || return nothing
        v = _resolve_value(ev.value[key])
        v isa Real || return nothing
        push!(vals, float(v))
    end
    isempty(vals) && return nothing
    return sum(vals) / length(vals)
end

# Deux fenêtres se recouvrent-elles ? Une borne absente vaut « ouvert ».
function _bands_overlap(hi_a, lo_a, hi_b, lo_b)
    a1 = hi_a === nothing ? 0.0 : hi_a
    a2 = lo_a === nothing ? 22050.0 : lo_a
    b1 = hi_b === nothing ? 0.0 : hi_b
    b2 = lo_b === nothing ? 22050.0 : lo_b
    return max(a1, b1) < min(a2, b2)
end
