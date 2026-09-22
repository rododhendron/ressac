# src/pattern_evolve.jl
# Exploration de patterns par variation — le pendant, côté rythme, de
# l'exploration génétique des synths. On part d'un bloc qui existe, on
# en tire des variantes, on garde celles qui sonnent, on recroise.
#
# Les mutations travaillent sur le TEXTE du bloc (mini-notation + chaîne
# d'effets) plutôt que sur l'AST : ce qu'on obtient est du code que
# l'utilisateur peut lire, éditer et ranger tel quel. Chaque candidat est
# validé (analyse + requête d'un cycle) avant d'être proposé.

"""
    _split_block(code) -> (head, body, links)

Découpe un bloc en trois : `head` = `@dN `, `body` = la source du
pattern (`p"…"`, `"…"`, `:nom`), `links` = les maillons `|> …`.
"""
function _split_block(code::AbstractString)
    src = strip(String(code))
    head = ""
    mt = match(r"^(\s*@d\d+\s+)", src)
    if mt !== nothing
        head = mt.captures[1]
        src = src[nextind(src, lastindex(mt.captures[1])):end]
    end
    parts = _split_top_pipes(src)
    isempty(parts) && return (head, src, String[])
    return (head, strip(parts[1]), String[strip(p) for p in parts[2:end]])
end

# Découpe sur les `|>` de premier niveau (hors parenthèses, crochets,
# accolades et chaînes).
function _split_top_pipes(src::AbstractString)
    out = String[]
    depth = 0
    in_str = false
    chars = collect(src)
    start = 1
    i = 1
    while i <= length(chars)
        c = chars[i]
        if in_str
            c == '"' && (in_str = false)
        elseif c == '"'
            in_str = true
        elseif c in ('(', '[', '{')
            depth += 1
        elseif c in (')', ']', '}')
            depth -= 1
        elseif depth == 0 && c == '|' && i < length(chars) && chars[i + 1] == '>'
            push!(out, String(chars[start:i - 1]))
            i += 2
            start = i
            continue
        end
        i += 1
    end
    push!(out, String(chars[start:end]))
    return out
end

_rejoin_block(head, body, links) =
    isempty(links) ? head * body : head * body * " |> " * join(links, " |> ")

# La mini-notation dans le corps, si c'en est une : (préfixe, contenu, suffixe).
function _body_minino(body::AbstractString)
    mt = match(r"^(p?\")(.*)(\")$", strip(String(body)))
    mt === nothing && return nothing
    return (mt.captures[1], mt.captures[2], mt.captures[3])
end

# Découpe une mini-notation en pas de premier niveau.
function _minino_steps(s::AbstractString)
    out = String[]
    depth = 0
    cur = IOBuffer()
    for c in s
        if c in ('[', '<', '{')
            depth += 1; print(cur, c)
        elseif c in (']', '>', '}')
            depth -= 1; print(cur, c)
        elseif isspace(c) && depth == 0
            t = String(take!(cur))
            isempty(strip(t)) || push!(out, t)
        else
            print(cur, c)
        end
    end
    t = String(take!(cur))
    isempty(strip(t)) || push!(out, t)
    return out
end

# Maillons proposés à l'ajout — volontairement courts et musicaux.
const _EVOLVE_LINKS = String[
    "gain(0.8)", "gain(1.1)", "lpf(800)", "lpf(2000)", "hpf(200)",
    "fast(2)", "slow(2)", "rev", "palindrome", "jux(rev)", "ply(2)",
    "degradeBy(0.3)", "sometimes(fast(2))", "every(4, rev)", "off(1//8, gain(0.6))",
    "room(0.3)", "pan(\"0 1\")", "chopp(4)", "hurry(2)", "linger(1//2)",
    "iter(4)", "swingBy(1//8, 4)", "stut(3, 0.5, 1//16)", "arp(\"up\")",
]

"""
    mutate_pattern(code; rng) -> String

Une variation du bloc : un pas de la mini-notation change, ou un maillon
de la chaîne d'effets. Renvoie le code tel quel si rien ne s'applique.
"""
function mutate_pattern(code::AbstractString; rng = Random.default_rng())
    head, body, links = _split_block(code)
    mn = _body_minino(body)
    choices = Symbol[:link_add, :link_drop, :link_tweak]
    mn === nothing || append!(choices, Symbol[:step_swap, :step_silence, :step_fast,
                                              :step_repeat, :step_maybe, :step_euclid,
                                              :step_rotate, :step_group])
    isempty(links) && filter!(c -> c !== :link_drop && c !== :link_tweak, choices)
    kind = rand(rng, choices)
    if kind === :link_add
        links = vcat(links, rand(rng, _EVOLVE_LINKS))
    elseif kind === :link_drop
        links = deleteat!(copy(links), rand(rng, 1:length(links)))
    elseif kind === :link_tweak
        i = rand(rng, 1:length(links))
        links = copy(links); links[i] = _tweak_numbers(links[i], rng)
    else
        pre, inner, post = mn
        steps = _minino_steps(inner)
        isempty(steps) && return String(code)
        i = rand(rng, 1:length(steps))
        if kind === :step_swap && length(steps) > 1
            j = mod1(i + rand(rng, 1:(length(steps) - 1)), length(steps))
            steps[i], steps[j] = steps[j], steps[i]
        elseif kind === :step_silence
            steps[i] = steps[i] == "~" ? rand(rng, [s for s in steps if s != "~"]; ) : "~"
        elseif kind === :step_fast
            steps[i] = _strip_mods(steps[i]) * "*" * string(rand(rng, 2:4))
        elseif kind === :step_repeat
            steps[i] = _strip_mods(steps[i]) * "!" * string(rand(rng, 2:3))
        elseif kind === :step_maybe
            steps[i] = _strip_mods(steps[i]) * "?"
        elseif kind === :step_euclid
            n = rand(rng, [8, 8, 16, 12])
            k = rand(rng, 2:max(3, n ÷ 2))
            steps[i] = _strip_mods(steps[i]) * "($k,$n)"
        elseif kind === :step_rotate
            steps = circshift(steps, rand(rng, [-1, 1]))
        elseif kind === :step_group
            other = rand(rng, steps)
            steps[i] = "[" * _strip_mods(steps[i]) * " " * _strip_mods(other) * "]"
        end
        body = pre * join(steps, " ") * post
    end
    return _rejoin_block(head, body, links)
end

# Enlève les modificateurs déjà posés sur un pas (`bd*2?` → `bd`).
_strip_mods(step::AbstractString) =
    replace(String(step), r"(\*[\d.<>\[\] ]+|![\d]*|\?[\d.]*|@[\d.]+|\([^)]*\)|/[\d.]+)+$" => "")

# Décale un nombre du maillon (0.8 → 0.6, 800 → 1200…).
function _tweak_numbers(link::AbstractString, rng)
    return replace(String(link), r"\d+\.?\d*" => s -> begin
        v = tryparse(Float64, s)
        v === nothing && return s
        f = rand(rng, [0.5, 0.75, 1.5, 2.0])
        nv = v * f
        occursin('.', s) ? string(round(nv; digits = 2)) : string(max(1, round(Int, nv)))
    end; count = 1)
end

"""
    crossover_patterns(a, b) -> String

Croise deux blocs : la mini-notation de l'un, la chaîne d'effets de
l'autre. Le slot vient du premier.
"""
function crossover_patterns(a::AbstractString, b::AbstractString)
    head_a, body_a, _ = _split_block(a)
    _, _, links_b = _split_block(b)
    return _rejoin_block(head_a, body_a, links_b)
end

"""
    valid_pattern_code(code) -> Bool

Le bloc s'analyse et produit un pattern jouable (un cycle interrogé sans
erreur). Filtre les variations que la mutation aurait cassées.
"""
function valid_pattern_code(code::AbstractString)
    src = strip(String(code))
    isempty(src) && return false
    try
        ex = Meta.parse(replace(src, r"^\s*@d\d+\s+" => ""))
        p = Core.eval(Main, ex)
        p isa Pattern || return false
        Base.invokelatest(p, Rational{Int64}(0), Rational{Int64}(1))
        return true
    catch
        return false
    end
end

"""
    evolve_patterns(seeds, n; rng) -> Vector{String}

`n` variations valides tirées des `seeds` : mutation d'une graine, ou
croisement de deux quand il y en a plusieurs. Les doublons et les
copies conformes des graines sont écartés.
"""
function evolve_patterns(seeds::AbstractVector{<:AbstractString}, n::Integer;
                         rng = Random.default_rng())
    isempty(seeds) && return String[]
    out = String[]
    seen = Set{String}(strip.(String.(seeds)))
    tries = 0
    while length(out) < n && tries < 40 * n
        tries += 1
        base = rand(rng, seeds)
        cand = if length(seeds) > 1 && rand(rng) < 0.3
            crossover_patterns(base, rand(rng, seeds))
        else
            mutate_pattern(base; rng = rng)
        end
        cand = strip(cand)
        (isempty(cand) || cand in seen) && continue
        valid_pattern_code(cand) || continue
        push!(seen, cand); push!(out, String(cand))
    end
    return out
end
