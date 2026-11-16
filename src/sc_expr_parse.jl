# src/sc_expr_parse.jl
# Expression SuperCollider → Genome. C'est l'inverse de genome_render.jl :
# le DSL évalué produit une expression SC (`Saw.ar(freq)`,
# `(x * 2).tanh`, `SinOsc.kr(0.2).range(300, 800)`…), on la remonte en
# DAG d'UGens pour la sculpter et l'expliquer. Grammaire couverte : celle
# que produisent les wrappers du DSL et `render_dsl` — appels
# `Nom.ar(...)` / `Nom.kr(...)`, arithmétique, méthodes postfixes,
# tableaux, références, arguments nommés, blocs `{ … }` opaques. Lecture
# stricte : voir `ScParseError`.

mutable struct _ScParser
    s::Vector{Char}
    i::Int
    g::Genome
    controls::Set{Symbol}          # identifiants qui sont des contrôles (freq, sustain…)
    fbid::Int                      # nœud FbIn déjà créé (0 = pas encore)
end

# Le parseur ne devine pas. Ce qu'il ne sait pas lire — un identifiant
# inconnu, un mot-clé qu'il ne sait pas placer, un caractère inattendu, du
# texte après l'expression — lève cette erreur, et `genome_from_sc` rend
# `nothing`. Avant, tout cela devenait un `0` silencieux, que `:sculpt`,
# `:prune` et `:todsl` réécrivaient ensuite dans le synth du joueur.
struct ScParseError <: Exception
    msg::String
    pos::Int
end
Base.showerror(io::IO, e::ScParseError) = print(io, e.msg, " (caractère ", e.pos, ")")
_sc_fail(p::_ScParser, msg::AbstractString) = throw(ScParseError(String(msg), p.i))

_sc_peek(p::_ScParser, k::Int = 0) = (j = p.i + k; j <= length(p.s) ? p.s[j] : '\0')
# Espaces et commentaires (`// …` jusqu'à la fin de ligne, `/* … */`).
function _sc_skip_ws!(p::_ScParser)
    while true
        c = _sc_peek(p)
        if isspace(c)
            p.i += 1
        elseif c == '/' && _sc_peek(p, 1) == '/'
            while p.i <= length(p.s) && p.s[p.i] != '\n'; p.i += 1; end
        elseif c == '/' && _sc_peek(p, 1) == '*'
            p.i += 2
            while p.i <= length(p.s) && !(p.s[p.i] == '*' && _sc_peek(p, 1) == '/'); p.i += 1; end
            p.i <= length(p.s) || _sc_fail(p, "commentaire /* non fermé")
            p.i += 2
        else
            break
        end
    end
    return nothing
end
_sc_eat!(p::_ScParser, c::Char) = (_sc_skip_ws!(p); _sc_peek(p) == c ? (p.i += 1; true) : false)
_sc_expect!(p::_ScParser, c::Char) = _sc_eat!(p, c) || _sc_fail(p, "« $c » attendu")
_sc_ident_char(c::Char) = isletter(c) || isdigit(c) || c == '_'

function _sc_ident!(p::_ScParser)
    _sc_skip_ws!(p)
    j = p.i
    while _sc_ident_char(_sc_peek(p)); p.i += 1; end
    return String(p.s[j:p.i-1])
end

function _sc_number!(p::_ScParser)
    j = p.i
    while isdigit(_sc_peek(p)); p.i += 1; end
    # Un point n'appartient au nombre que suivi d'un chiffre : `1.5`, mais
    # pas `1.neg` ni `0..3`.
    if _sc_peek(p) == '.' && isdigit(_sc_peek(p, 1))
        p.i += 1
        while isdigit(_sc_peek(p)); p.i += 1; end
    end
    if _sc_peek(p) in ('e', 'E') && (isdigit(_sc_peek(p, 1)) || (_sc_peek(p, 1) in ('-', '+') && isdigit(_sc_peek(p, 2))))
        p.i += 2
        while isdigit(_sc_peek(p)); p.i += 1; end
    end
    v = tryparse(Float64, String(p.s[j:p.i-1]))
    v === nothing && _sc_fail(p, "nombre illisible « $(String(p.s[j:p.i-1])) »")
    return ConstArg(v)
end

_sc_const(a::Arg) = a isa ConstArg ? a.value : nothing

# Les arguments d'un appel `( … )` : positionnels, puis nommés (`mul: 0.1`).
function _sc_args!(p::_ScParser)
    pos = Arg[]; kws = Pair{Symbol,Arg}[]
    _sc_eat!(p, '(') || return (pos, kws)
    _sc_eat!(p, ')') && return (pos, kws)
    while true
        _sc_skip_ws!(p)
        # mot-clé ?  ident ':' …
        j = p.i
        while _sc_ident_char(_sc_peek(p)); p.i += 1; end
        if p.i > j && _sc_peek(p) == ':' && _sc_peek(p, 1) != ':'
            key = Symbol(String(p.s[j:p.i-1]))
            p.i += 1
            push!(kws, key => _sc_expr!(p))
        else
            p.i = j
            isempty(kws) || _sc_fail(p, "argument positionnel après un argument nommé")
            push!(pos, _sc_expr!(p))
        end
        _sc_eat!(p, ',') || break
    end
    _sc_expect!(p, ')')
    return (pos, kws)
end

# Nom de génome d'un UGen selon sa rate : les variantes .kr connues du
# catalogue portent leur propre nom (SinOscKR, LFPulseKR).
function _sc_ugen_name(name::String, rate::Symbol)
    rate === :kr && name == "SinOsc" && return :SinOscKR
    rate === :kr && name == "LFPulse" && return :LFPulseKR
    return Symbol(name)
end

# Un nœud à partir d'un appel `Nom.rate(args…, mot: valeur)`. Les arguments
# nommés sont posés à leur place quand le catalogue connaît le slot ;
# `mul:` et `add:` — que tout UGen accepte — deviennent le `* mul + add`
# qu'ils sont ; `doneAction:` ne change pas le son décrit. Tout autre
# mot-clé qu'on ne sait pas placer est une erreur, pas un oubli.
function _sc_call_node(p::_ScParser, ugen::Symbol, rate::Symbol, pos::Vector{Arg}, kws::Vector{Pair{Symbol,Arg}})
    mul = nothing; add = nothing
    spec = ugen_spec(ugen)
    named = Dict{Int,Arg}()                # place → valeur, dans n'importe quel ordre
    for (key, val) in kws
        key === :doneAction && continue
        key === :mul && (mul = val; continue)
        key === :add && (add = val; continue)
        idx = spec === nothing ? nothing : findfirst(sl -> sl.name === key, spec.slots)
        idx === nothing && _sc_fail(p, "argument nommé « $key: » de $ugen : place inconnue")
        (idx <= length(pos) || haskey(named, idx)) && _sc_fail(p, "« $key: » de $ugen est donné deux fois")
        named[idx] = val
    end
    args = copy(pos)
    for idx in (length(pos) + 1):maximum(keys(named); init = 0)
        # un slot sauté entre deux arguments nommés prend son défaut
        push!(args, get(named, idx, ConstArg(spec.slots[idx].default)))
    end
    a::Arg = NodeRef(add_node!(p.g, ugen, rate, args))
    mul === nothing || (a = _sc_binary(p, a, "*", mul))
    add === nothing || (a = _sc_binary(p, a, "+", add))
    return a
end

# `[a, b, …]`. Un seul élément : c'est lui. Sinon un nœud :Chan — les voies
# d'une expansion multicanal, jamais réduites à la première.
function _sc_array!(p::_ScParser)
    elems = Arg[]
    if !_sc_eat!(p, ']')
        while true
            push!(elems, _sc_expr!(p))
            _sc_eat!(p, ',') || break
        end
        _sc_expect!(p, ']')
    end
    return NodeRef(add_node!(p.g, :Chan, _sc_rate_of(p, elems), elems))
end

# La rate d'un nœud de structure : audio dès qu'un de ses arguments l'est.
_sc_rate_of(p::_ScParser, args::Vector{Arg}) =
    any(a -> a isa NodeRef && haskey(p.g.nodes, a.id) && p.g.nodes[a.id].rate === :ar, args) ? :ar : :kr

const _SC_LITERALS = ("nil", "true", "false")

function _sc_primary!(p::_ScParser)
    _sc_skip_ws!(p)
    c = _sc_peek(p)
    if isdigit(c) || (c == '.' && isdigit(_sc_peek(p, 1)))
        return _sc_number!(p)
    elseif c == '('
        p.i += 1
        a = _sc_expr!(p)
        _sc_expect!(p, ')')
        return a
    elseif c == '['
        p.i += 1
        return _sc_array!(p)
    elseif c == '`'
        p.i += 1
        a = _sc_primary!(p)
        return NodeRef(add_node!(p.g, :Ref, :kr, Arg[a]))
    elseif c == '{'
        # Bloc SC opaque : on saute jusqu'à l'accolade fermante.
        depth = 0; closed = false
        while p.i <= length(p.s)
            ch = p.s[p.i]; p.i += 1
            ch == '{' && (depth += 1)
            ch == '}' && (depth -= 1; depth == 0 && (closed = true; break))
        end
        closed || _sc_fail(p, "bloc { … } non fermé")
        return NodeRef(add_node!(p.g, :Raw, :ar, Arg[]))
    elseif c == '\\'
        p.i += 1
        return LitArg("\\" * _sc_ident!(p))                         # symbole SC (\lin, \sin…)
    elseif c == '"' || c == '\''
        j = p.i; p.i += 1
        while p.i <= length(p.s) && p.s[p.i] != c
            p.s[p.i] == '\\' && (p.i += 1)
            p.i += 1
        end
        p.i <= length(p.s) || _sc_fail(p, "chaîne non fermée")
        p.i += 1
        return LitArg(String(p.s[j:p.i-1]))
    elseif _sc_ident_char(c)
        name = _sc_ident!(p)
        isuppercase(first(name)) && return _sc_class!(p, name)
        name == "fb" && (p.fbid == 0 && (p.fbid = add_node!(p.g, :FbIn, :ar, Arg[])); return NodeRef(p.fbid))
        name == "pi" && return ConstArg(Float64(pi))
        name == "inf" && return ConstArg(Inf)
        name in _SC_LITERALS && return LitArg(name)
        sym = Symbol(name)
        sym in p.controls && return ControlRef(sym)
        # `abs(x)`, `max(a, b)` : la forme fonction d'une méthode, `x.abs`.
        if _sc_peek(p) == '('
            (pos, kws) = _sc_args!(p)
            (isempty(pos) || !isempty(kws)) && _sc_fail(p, "appel « $name(…) » illisible")
            return _sc_method(p, pos[1], name, pos[2:end])
        end
        _sc_fail(p, "identifiant inconnu « $name » (ni un contrôle déclaré, ni une variable)")
    end
    _sc_fail(p, c == '\0' ? "fin inattendue de l'expression" : "caractère inattendu « $c »")
end

# `Nom.ar(…)`, `Nom.kr(…)`, `Nom.ar`, `Nom(…)`, `Nom.méthode(…)` (Env.perc), `Nom`.
function _sc_class!(p::_ScParser, name::String)
    if _sc_peek(p) == '(' || !(_sc_peek(p) == '.' && _sc_ident_char(_sc_peek(p, 1)))
        # `Nom(…)` est `Nom.new(…)` ; `Nom` seul, la classe (un UGen sans argument).
        (pos, kws) = _sc_peek(p) == '(' ? _sc_args!(p) : (Arg[], Pair{Symbol,Arg}[])
        name == "Mix" && isempty(kws) && length(pos) == 1 && return _sc_mixdown(p, pos[1])
        return _sc_call_node(p, Symbol(name), :ar, pos, kws)
    end
    p.i += 1
    meth = _sc_ident!(p)
    (pos, kws) = _sc_peek(p) == '(' ? _sc_args!(p) : (Arg[], Pair{Symbol,Arg}[])
    if meth in ("ar", "kr", "ir")
        rate = Symbol(meth)
        name == "Mix" && isempty(kws) && length(pos) == 1 && return _sc_mixdown(p, pos[1])
        return _sc_call_node(p, _sc_ugen_name(name, rate), rate, pos, kws)
    end
    # Une méthode de classe. Les constructeurs d'enveloppe du catalogue ont
    # leur nom (EnvPerc…) ; les autres gardent le leur, `Env.triangle`.
    known = Symbol(name * uppercasefirst(meth))
    ugen_spec(known) !== nothing && return _sc_call_node(p, known, :kr, pos, kws)
    isempty(kws) || _sc_fail(p, "argument nommé dans $name.$meth(…) : place inconnue")
    return NodeRef(add_node!(p.g, Symbol(name, ".", meth), :kr, pos))
end

# `Mix.ar([a, b, c])` est la somme de ses voies : `a + b + c`, que le génome
# sait écrire et sculpter. (Le nœud :Mix du génome est l'addition binaire.)
function _sc_mixdown(p::_ScParser, a::Arg)
    (a isa NodeRef && haskey(p.g.nodes, a.id) && p.g.nodes[a.id].ugen === :Chan) || return a
    elems = p.g.nodes[a.id].args
    isempty(elems) && return ConstArg(0.0)
    delete!(p.g.nodes, a.id)
    acc = elems[1]
    for e in elems[2:end]
        acc = _sc_binary(p, acc, "+", e)
    end
    return acc
end

# Méthodes postfixes : `.tanh`, `.softclip`, `.range(lo, hi)`, `.fold2(q)`…
function _sc_postfix!(p::_ScParser)
    a = _sc_primary!(p)
    while true
        _sc_skip_ws!(p)
        (_sc_peek(p) == '.' && _sc_ident_char(_sc_peek(p, 1)) && !isdigit(_sc_peek(p, 1))) || break
        p.i += 1
        meth = _sc_ident!(p)
        (pos, kws) = _sc_peek(p) == '(' ? _sc_args!(p) : (Arg[], Pair{Symbol,Arg}[])
        isempty(kws) || _sc_fail(p, "argument nommé dans .$meth(…) : place inconnue")
        a = _sc_method(p, a, meth, pos)
    end
    return a
end

# Les UGens dont la sortie va de 0 à 1 (`signalRange = \unipolar` en SC) :
# leur `.range(lo, hi)` est `x * (hi - lo) + lo`, pas la formule bipolaire.
const _SC_UNIPOLAR = Set{Symbol}((:LFPulse, :LFPulseKR, :Impulse, :Dust, :Trig, :Trig1, :ToggleFF, :SetResetFF))
_sc_is_unipolar(p::_ScParser, a::Arg) =
    a isa NodeRef && haskey(p.g.nodes, a.id) && p.g.nodes[a.id].ugen in _SC_UNIPOLAR

# Méthode SC → nom au catalogue (`softclip` → :Softclip), d'après la table
# des formes méthode du DSL.
const _SC_METHOD_UGENS = Dict{String,Symbol}(v => k for (k, v) in SynthDSL._UGEN_METHOD_FORMS)

function _sc_method(p::_ScParser, a::Arg, meth::String, args::Vector{Arg})
    g = p.g
    node(u, as) = NodeRef(add_node!(g, u, :ar, as))
    if meth == "fold2" || meth == "clip2" || meth == "round"
        return node(_SC_METHOD_UGENS[meth], Arg[a, get(args, 1, ConstArg(1.0))])
    elseif meth == "neg" && isempty(args)
        return _sc_negate(p, a)
    elseif meth == "value" && isempty(args)
        return a                                                     # `{ … }.value` : le bloc opaque
    elseif meth == "range" && length(args) == 2
        return _sc_range(p, a, args[1], args[2])
    elseif haskey(_SC_METHOD_UGENS, meth)
        return node(_SC_METHOD_UGENS[meth], vcat(Arg[a], args))
    end
    # Une méthode sans fiche : gardée sous son nom, rendue `(x).meth(args…)`.
    all_args = vcat(Arg[a], args)
    return NodeRef(add_node!(g, Symbol(".", meth), _sc_rate_of(p, all_args), all_args))
end

function _sc_negate(p::_ScParser, a::Arg)
    v = _sc_const(a)
    v === nothing || return ConstArg(-v)
    return NodeRef(add_node!(p.g, :MulAdd, :ar, Arg[a, ConstArg(-1.0), ConstArg(0.0)]))
end

# `x.range(lo, hi)` en nœuds : un `* mul + add`, selon que `x` vit dans
# [-1, 1] (la plupart des UGens) ou dans [0, 1] (`_SC_UNIPOLAR`).
function _sc_range(p::_ScParser, a::Arg, lo::Arg, hi::Arg)
    g = p.g
    uni = _sc_is_unipolar(p, a)
    vlo, vhi = _sc_const(lo), _sc_const(hi)
    if vlo !== nothing && vhi !== nothing
        (vlo, vhi) == (uni ? (0.0, 1.0) : (-1.0, 1.0)) && return a   # la plage naturelle : rien
        uni && return NodeRef(add_node!(g, :MulAdd, :kr, Arg[a, ConstArg(vhi - vlo), ConstArg(vlo)]))
        return NodeRef(add_node!(g, :MulAdd, :kr, Arg[a, ConstArg((vhi - vlo) / 2), ConstArg((vhi + vlo) / 2)]))
    end
    # bornes calculées (`.range(base, base + depth)`) : la même formule, en
    # nœuds, dans la forme que le parseur redonne lui-même (constantes
    # repliées, « / 2 » écrit « × 0.5 ») pour que l'export se relise à l'identique
    neg_lo = vlo !== nothing ? ConstArg(-vlo) :
             NodeRef(add_node!(g, :MulAdd, :kr, Arg[lo, ConstArg(-1.0), ConstArg(0.0)]))
    span = NodeRef(add_node!(g, :Mix, :kr, Arg[hi, neg_lo]))
    uni && return NodeRef(add_node!(g, :MulAdd, :kr, Arg[a, span, lo]))
    half(x) = NodeRef(add_node!(g, :MulAdd, :kr, Arg[x, ConstArg(0.5), ConstArg(0.0)]))
    return NodeRef(add_node!(g, :MulAdd, :kr, Arg[a, half(span), half(NodeRef(add_node!(g, :Mix, :kr, Arg[hi, lo])))]))
end

function _sc_unary!(p::_ScParser)
    _sc_skip_ws!(p)
    if _sc_peek(p) == '-'
        p.i += 1
        return _sc_negate(p, _sc_unary!(p))
    end
    return _sc_postfix!(p)
end

# L'opérateur binaire qui commence ici, ou "" : deux caractères d'abord.
function _sc_binop_at(p::_ScParser)
    c, d = _sc_peek(p), _sc_peek(p, 1)
    two = string(c, d)
    two in ("**", ">=", "<=", "==", "!=") && return two
    (c == '/' && (d == '/' || d == '*')) && return ""               # un commentaire, pas une division
    c in ('+', '-', '*', '/', '%', '>', '<') && return string(c)
    return ""
end

# Une expression : des opérandes reliés par des opérateurs binaires,
# évalués **de gauche à droite, sans priorité** — la règle de
# SuperCollider. `a + b * c` y vaut `(a + b) * c` : c'est ce que le serveur
# jouera, donc ce que le génome doit dire.
function _sc_expr!(p::_ScParser)
    a = _sc_unary!(p)
    while true
        _sc_skip_ws!(p)
        op = _sc_binop_at(p)
        isempty(op) && break
        p.i += length(op)
        a = _sc_binary(p, a, op, _sc_unary!(p))
    end
    return a
end

# `a op b` en nœuds, avec les replis qui gardent le génome lisible :
# constantes calculées, `x * 1` et `x + 0` effacés, `(x * k) + c` en un
# seul MulAdd (la forme que render_synthdef écrit).
function _sc_binary(p::_ScParser, a::Arg, op::String, b::Arg)
    g = p.g
    va, vb = _sc_const(a), _sc_const(b)
    if op == "*" || op == "/"
        if va !== nothing && vb !== nothing
            return ConstArg(op == "*" ? va * vb : (vb == 0 ? 0.0 : va / vb))
        elseif op == "*" && vb == 1.0
            return a                                                 # `x * 1` (ce que tanh_drive(1) écrit)
        elseif op == "*" && va == 1.0
            return b
        elseif op == "*"
            # le signal d'abord, le facteur ensuite (comme MulAdd le lit)
            (va !== nothing) && ((a, b) = (b, a))
            return NodeRef(add_node!(g, :MulAdd, :ar, Arg[a, b, ConstArg(0.0)]))
        elseif vb !== nothing && vb != 0
            return NodeRef(add_node!(g, :MulAdd, :ar, Arg[a, ConstArg(1 / vb), ConstArg(0.0)]))
        end
        return NodeRef(add_node!(g, :Div, :ar, Arg[a, b]))
    elseif op == "+" || op == "-"
        va !== nothing && vb !== nothing && return ConstArg(op == "+" ? va + vb : va - vb)
        vb == 0.0 && return a                                        # `x + 0`, `x - 0` : rien
        (va == 0.0 && op == "+") && return b
        op == "-" && (b = _sc_negate(p, b))
        # `(x * k) + c` : le MulAdd reprend son terme additif
        if a isa NodeRef && haskey(g.nodes, a.id) && (n = g.nodes[a.id]; n.ugen === :MulAdd &&
           length(n.args) == 3 && _sc_const(n.args[3]) == 0.0)
            n.args[3] = b
            return a
        end
        return NodeRef(add_node!(g, :Mix, :ar, Arg[a, b]))
    end
    # Les autres opérateurs (`**`, `%`, comparaisons) : repliés entre
    # constantes quand c'est une puissance, sinon gardés tels quels.
    op == "**" && va !== nothing && vb !== nothing && return ConstArg(va^vb)
    args = Arg[a, b]
    return NodeRef(add_node!(g, Symbol(op), _sc_rate_of(p, args), args))
end

"""
    parse_sc_expr(code, controls; g = Genome()) -> (genome | nothing, raison::String)

Remonte une expression SC en génome : la sortie est le nœud racine
(chaîne de sécurité retirée). `controls` : les identifiants à lire comme
contrôles. Quand l'expression ne se lit pas entièrement, ou ne donne pas un
nœud, le génome est `nothing` et `raison` dit pourquoi — pour le dire au
joueur plutôt que de lui rendre un son amputé.
"""
function parse_sc_expr(code::AbstractString, controls; g::Genome = Genome())
    p = _ScParser(collect(String(code)), 1, g, Set{Symbol}(controls), 0)
    root = try
        r = _sc_expr!(p)
        _sc_skip_ws!(p)
        p.i <= length(p.s) && _sc_fail(p, "texte non lu après l'expression : « $(first(String(p.s[p.i:end]), 24)) »")
        r
    catch err
        err isa ScParseError || rethrow()
        return (nothing, sprint(showerror, err))
    end
    root isa NodeRef || return (nothing, "l'expression est une constante ou un contrôle, pas un signal")
    g.output_id = _unwrap_safety(g, root.id)
    _merge_identical_nodes!(g)
    _prune_unreachable!(g)
    return (g, "")
end

"""
    genome_from_sc(code, controls; g = Genome()) -> Union{Nothing,Genome}

Le génome de [`parse_sc_expr`](@ref), sans la raison.
"""
genome_from_sc(code::AbstractString, controls; g::Genome = Genome()) =
    first(parse_sc_expr(code, controls; g = g))

# Les UGens dont deux instances ne donnent pas le même signal : jamais fusionnées.
const _STOCHASTIC = Set{Symbol}((:WhiteNoise, :PinkNoise, :BrownNoise, :GrayNoise, :ClipNoise, :Dust, :Dust2,
    :LFNoise0, :LFNoise1, :LFNoise2, :Crackle, :Logistic, :LorenzL, :HenonL, :LatoocarfianL, :CuspL, :QuadL,
    :GbmanL, :StandardL, :FBSineL, :Raw, :FbIn, :LFDNoise0, :LFDNoise1, :LFDNoise3, :LFClipNoise,
    :Rand, :TRand, :ExpRand, :TExpRand, :IRand, :TIRand, :Dwhite, :Dbrown, :CoinGate))

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
