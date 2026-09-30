# src/sc_expr_parse.jl
# Expression SuperCollider → Genome. C'est l'inverse de genome_render.jl :
# le DSL évalué produit une expression SC (`Saw.ar(freq)`,
# `(x * 2).tanh`, `SinOsc.kr(0.2).range(300, 800)`…), on la remonte en
# DAG d'UGens pour la sculpter et l'expliquer. Grammaire couverte : celle
# que produisent les wrappers du DSL et `render_dsl` — appels
# `Nom.ar(...)` / `Nom.kr(...)`, arithmétique, méthodes postfixes,
# tableaux (on garde la première voie), blocs `{ … }` opaques.

mutable struct _ScParser
    s::Vector{Char}
    i::Int
    g::Genome
    controls::Set{Symbol}          # identifiants qui sont des contrôles (freq, sustain…)
    fbid::Int                      # nœud FbIn déjà créé (0 = pas encore)
end

_sc_peek(p::_ScParser, k::Int = 0) = (j = p.i + k; j <= length(p.s) ? p.s[j] : '\0')
_sc_skip_ws!(p::_ScParser) = (while isspace(_sc_peek(p)); p.i += 1; end; nothing)
_sc_eat!(p::_ScParser, c::Char) = (_sc_skip_ws!(p); _sc_peek(p) == c ? (p.i += 1; true) : false)
_sc_ident_char(c::Char) = isletter(c) || isdigit(c) || c == '_'

function _sc_ident!(p::_ScParser)
    _sc_skip_ws!(p)
    j = p.i
    while _sc_ident_char(_sc_peek(p)); p.i += 1; end
    return String(p.s[j:p.i-1])
end

function _sc_number!(p::_ScParser)
    j = p.i
    while isdigit(_sc_peek(p)) || _sc_peek(p) == '.'; p.i += 1; end
    if _sc_peek(p) in ('e', 'E') && (isdigit(_sc_peek(p, 1)) || (_sc_peek(p, 1) in ('-', '+') && isdigit(_sc_peek(p, 2))))
        p.i += 2
        while isdigit(_sc_peek(p)); p.i += 1; end
    end
    v = tryparse(Float64, String(p.s[j:p.i-1]))
    return ConstArg(v === nothing ? 0.0 : v)
end

# Le nœud d'un argument : un ConstArg/ControlRef est enveloppé pour
# qu'une sortie soit toujours un nœud.
_sc_node_id(p::_ScParser, a::Arg) =
    a isa NodeRef ? a.id : add_node!(p.g, :MulAdd, :ar, Arg[a, ConstArg(1.0), ConstArg(0.0)])

_sc_const(a::Arg) = a isa ConstArg ? a.value : nothing

# Les arguments d'un appel `( … )` : les mots-clés SC (`doneAction: 2`)
# sont sautés, ils ne changent pas le son qu'on décrit.
function _sc_args!(p::_ScParser)
    out = Arg[]
    _sc_eat!(p, '(') || return out
    _sc_skip_ws!(p)
    if _sc_peek(p) == ')'; p.i += 1; return out; end
    while true
        _sc_skip_ws!(p)
        # mot-clé ?  ident ':' …
        j = p.i
        while _sc_ident_char(_sc_peek(p)); p.i += 1; end
        if p.i > j && _sc_peek(p) == ':' && _sc_peek(p, 1) != ':'
            p.i += 1
            _sc_expr!(p)                          # valeur du mot-clé, ignorée
        else
            p.i = j
            push!(out, _sc_expr!(p))
        end
        _sc_eat!(p, ',') || break
    end
    _sc_eat!(p, ')')
    return out
end

# Nom de génome d'un UGen selon sa rate : les variantes .kr connues du
# catalogue portent leur propre nom (SinOscKR, LFPulseKR).
function _sc_ugen_name(name::String, rate::Symbol)
    rate === :kr && name == "SinOsc" && return :SinOscKR
    rate === :kr && name == "LFPulse" && return :LFPulseKR
    return Symbol(name)
end

function _sc_primary!(p::_ScParser)
    _sc_skip_ws!(p)
    c = _sc_peek(p)
    if isdigit(c) || (c == '.' && isdigit(_sc_peek(p, 1)))
        return _sc_number!(p)
    elseif c == '('
        p.i += 1
        a = _sc_expr!(p)
        _sc_eat!(p, ')')
        return a
    elseif c == '['
        p.i += 1
        first_arg = nothing
        while true
            _sc_skip_ws!(p)
            _sc_peek(p) == ']' && break
            a = _sc_expr!(p)
            first_arg === nothing && (first_arg = a)
            _sc_eat!(p, ',') || break
        end
        _sc_eat!(p, ']')
        return first_arg === nothing ? ConstArg(0.0) : first_arg    # mono : la première voie
    elseif c == '{'
        # Bloc SC opaque : on saute jusqu'à l'accolade fermante.
        depth = 0
        while p.i <= length(p.s)
            ch = p.s[p.i]; p.i += 1
            ch == '{' && (depth += 1)
            ch == '}' && (depth -= 1; depth == 0 && break)
        end
        return NodeRef(add_node!(p.g, :Raw, :ar, Arg[]))
    elseif c == '\\'
        p.i += 1; _sc_ident!(p)
        return ConstArg(0.0)                                        # symbole SC (\lin…)
    elseif c == '"'
        p.i += 1
        while p.i <= length(p.s) && p.s[p.i] != '"'; p.i += 1; end
        p.i += 1
        return ConstArg(0.0)
    elseif _sc_ident_char(c)
        name = _sc_ident!(p)
        if isuppercase(first(name))
            # `Nom.ar(...)`, `Nom.kr(...)`, `Nom.ar`, ou `Nom.méthode(...)` (Env.perc)
            if _sc_peek(p) == '.'
                save = p.i
                p.i += 1
                meth = _sc_ident!(p)
                if meth in ("ar", "kr", "ir")
                    rate = Symbol(meth)
                    args = _sc_peek(p) == '(' ? _sc_args!(p) : Arg[]
                    return NodeRef(add_node!(p.g, _sc_ugen_name(name, rate), rate, args))
                elseif !isempty(meth) && _sc_peek(p) == '('
                    args = _sc_args!(p)
                    return NodeRef(add_node!(p.g, Symbol(name * uppercasefirst(meth)), :kr, args))
                end
                p.i = save
            end
            return NodeRef(add_node!(p.g, Symbol(name), :ar, Arg[]))
        end
        name == "fb" && (p.fbid == 0 && (p.fbid = add_node!(p.g, :FbIn, :ar, Arg[])); return NodeRef(p.fbid))
        name == "pi" && return ConstArg(Float64(pi))
        name == "inf" && return ConstArg(1.0e9)
        sym = Symbol(name)
        sym in p.controls && return ControlRef(sym)
        return ConstArg(0.0)
    end
    p.i += 1                                                        # caractère inconnu : on avance
    return ConstArg(0.0)
end

# Méthodes postfixes : `.tanh`, `.softclip`, `.range(lo, hi)`, `.fold2(q)`…
function _sc_postfix!(p::_ScParser)
    a = _sc_primary!(p)
    while true
        _sc_skip_ws!(p)
        (_sc_peek(p) == '.' && _sc_ident_char(_sc_peek(p, 1))) || break
        p.i += 1
        meth = _sc_ident!(p)
        args = _sc_peek(p) == '(' ? _sc_args!(p) : Arg[]
        a = _sc_method(p, a, meth, args)
    end
    return a
end

function _sc_method(p::_ScParser, a::Arg, meth::String, args::Vector{Arg})
    g = p.g
    if meth == "tanh"
        return NodeRef(add_node!(g, :Tanh, :ar, Arg[a]))
    elseif meth == "fold2" || meth == "clip2" || meth == "round"
        ug = meth == "fold2" ? :Fold2 : meth == "clip2" ? :Clip2 : :Round
        return NodeRef(add_node!(g, ug, :ar, Arg[a, get(args, 1, ConstArg(1.0))]))
    elseif meth == "range" && length(args) == 2 && _sc_const(args[1]) !== nothing && _sc_const(args[2]) !== nothing
        lo, hi = _sc_const(args[1]), _sc_const(args[2])
        (lo, hi) == (-1.0, 1.0) && return a                          # ce que lfo() écrit par défaut : rien
        # un LFO en [-1, 1] ramené à [lo, hi] : x * (hi - lo)/2 + (hi + lo)/2
        return NodeRef(add_node!(g, :MulAdd, :kr, Arg[a, ConstArg((hi - lo) / 2), ConstArg((hi + lo) / 2)]))
    elseif meth == "value"
        return a                                                     # `{ … }.value` : le bloc opaque
    end
    return NodeRef(add_node!(g, Symbol(uppercasefirst(meth)), :ar, vcat(Arg[a], args)))
end

function _sc_unary!(p::_ScParser)
    _sc_skip_ws!(p)
    if _sc_peek(p) == '-'
        p.i += 1
        a = _sc_unary!(p)
        v = _sc_const(a)
        v === nothing || return ConstArg(-v)
        return NodeRef(add_node!(p.g, :MulAdd, :ar, Arg[a, ConstArg(-1.0), ConstArg(0.0)]))
    end
    return _sc_postfix!(p)
end

function _sc_term!(p::_ScParser)
    a = _sc_unary!(p)
    while true
        _sc_skip_ws!(p)
        op = _sc_peek(p)
        op in ('*', '/') || break
        p.i += 1
        b = _sc_unary!(p)
        va, vb = _sc_const(a), _sc_const(b)
        if va !== nothing && vb !== nothing
            a = ConstArg(op == '*' ? va * vb : (vb == 0 ? 0.0 : va / vb))
        elseif op == '*' && vb == 1.0
            # `x * 1` (ce que tanh_drive(1) écrit) : rien à faire
        elseif op == '*' && va == 1.0
            a = b
        elseif op == '*'
            # le signal d'abord, le facteur ensuite (comme MulAdd le lit)
            (va !== nothing) && ((a, b) = (b, a))
            a = NodeRef(add_node!(p.g, :MulAdd, :ar, Arg[a, b, ConstArg(0.0)]))
        elseif vb !== nothing && vb != 0
            a = NodeRef(add_node!(p.g, :MulAdd, :ar, Arg[a, ConstArg(1 / vb), ConstArg(0.0)]))
        else
            a = NodeRef(add_node!(p.g, :Div, :ar, Arg[a, b]))
        end
    end
    return a
end

function _sc_expr!(p::_ScParser)
    a = _sc_term!(p)
    while true
        _sc_skip_ws!(p)
        op = _sc_peek(p)
        op in ('+', '-') || break
        p.i += 1
        b = _sc_term!(p)
        va, vb = _sc_const(a), _sc_const(b)
        if va !== nothing && vb !== nothing
            a = ConstArg(op == '+' ? va + vb : va - vb)
            continue
        end
        vb == 0.0 && continue                                            # `x + 0`, `x - 0` : rien
        if va == 0.0 && op == '+'
            a = b; continue
        end
        op == '-' && (b = vb !== nothing ? ConstArg(-vb) :
                          NodeRef(add_node!(p.g, :MulAdd, :ar, Arg[b, ConstArg(-1.0), ConstArg(0.0)])))
        # `(x * k) + c` : le MulAdd reprend son terme additif (forme de render_synthdef)
        if a isa NodeRef && haskey(p.g.nodes, a.id) && (n = p.g.nodes[a.id]; n.ugen === :MulAdd &&
           length(n.args) == 3 && _sc_const(n.args[3]) == 0.0)
            n.args[3] = b
        else
            a = NodeRef(add_node!(p.g, :Mix, :ar, Arg[a, b]))
        end
    end
    return a
end

"""
    genome_from_sc(code, controls; g = Genome()) -> Union{Nothing,Genome}

Remonte une expression SC en génome : la sortie est le nœud racine
(chaîne de sécurité retirée). `controls` : les identifiants à lire comme
contrôles. `nothing` si l'expression ne donne pas un nœud.
"""
function genome_from_sc(code::AbstractString, controls; g::Genome = Genome())
    p = _ScParser(collect(String(code)), 1, g, Set{Symbol}(controls), 0)
    root = try _sc_expr!(p) catch; return nothing end
    root isa NodeRef || return nothing
    g.output_id = _unwrap_safety(g, root.id)
    _merge_identical_nodes!(g)
    return g
end

# Les UGens dont deux instances ne donnent pas le même signal : jamais fusionnées.
const _STOCHASTIC = Set{Symbol}((:WhiteNoise, :PinkNoise, :BrownNoise, :GrayNoise, :ClipNoise, :Dust, :Dust2,
    :LFNoise0, :LFNoise1, :LFNoise2, :Crackle, :Logistic, :LorenzL, :HenonL, :LatoocarfianL, :CuspL, :QuadL,
    :GbmanL, :StandardL, :FBSineL, :Raw, :FbIn))

"""
    _merge_identical_nodes!(g)

Le texte SC n'a pas de variables : `x = saw(:freq) |> rlpf(…)` lu deux
fois donne deux sous-arbres identiques. On les fusionne (même UGen,
même taux, mêmes arguments), sauf les sources aléatoires, pour que
l'export retrouve la variable partagée.
"""
function _merge_identical_nodes!(g::Genome)
    seen = Dict{Tuple{Symbol,Symbol,Vector{Arg}},Int}()
    alias = Dict{Int,Int}()
    for id in _topo_order(g)
        n = g.nodes[id]
        args = Arg[a isa NodeRef ? NodeRef(get(alias, a.id, a.id)) : a for a in n.args]
        n.args = args
        n.ugen in _STOCHASTIC && continue
        key = (n.ugen, n.rate, args)
        if haskey(seen, key)
            alias[id] = seen[key]
            delete!(g.nodes, id)
        else
            seen[key] = id
        end
    end
    isempty(alias) && return g
    for n in values(g.nodes), j in eachindex(n.args)
        a = n.args[j]
        a isa NodeRef && haskey(alias, a.id) && (n.args[j] = NodeRef(alias[a.id]))
    end
    g.output_id = get(alias, g.output_id, g.output_id)
    return g
end
