# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------

abstract type MNode end

# Poids d'un pas dans une séquence : `bd@3`, `bd _ _`. Rationnel pour
# accepter `bd@1.5`.
const MWeight = Rational{Int64}

struct AtomNode      <: MNode; sym::Symbol end
struct SilenceNode   <: MNode end
struct SeqNode       <: MNode; children::Vector{Tuple{MNode,MWeight}} end
struct AltNode       <: MNode; children::Vector{MNode} end             # `<a b>` : un par cycle
struct RepeatNode    <: MNode; child::MNode; n::Any end                # `a*n` (n : nombre ou pattern)
struct SlowNode      <: MNode; child::MNode; n::Any end                # `a/n` (n : nombre ou pattern)
struct EuclidNode    <: MNode; child::MNode; k::Any; n::Any; rot::Any end
struct DegradeNode   <: MNode; child::MNode; prob::Float64 end          # `a?` / `a?0.3`
struct ChordNode     <: MNode; children::Vector{MNode} end              # `[a b, c d]` : voix parallèles
struct RandomAltNode <: MNode; children::Vector{MNode} end              # `a | b | c`
# `{a b, c d e}%n` : chaque voix garde son nombre de pas, `n` pas par cycle.
struct PolyNode      <: MNode; voices::Vector{Vector{MNode}}; steps::Any end

# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

# Tokens are simple tuples. The position field is the 1-based char index of
# the first character of the token, useful for error messages.
struct MToken
    kind::Symbol
    value::Any
    pos::Int
    spaced::Bool     # précédé d'une espace ? (`bd !` ≠ `bd!`)
end
MToken(kind, value, pos) = MToken(kind, value, pos, false)

const _MN_PUNCT = Dict{Char,Symbol}(
    '~' => :silence, '[' => :lbracket, ']' => :rbracket,
    '<' => :langle,  '>' => :rangle,   '{' => :lbrace,  '}' => :rbrace,
    '*' => :star,    '!' => :bang,     '/' => :slash,   '@' => :at,
    '(' => :lparen,  ')' => :rparen,   ',' => :comma,   '|' => :pipe,
    '?' => :question, '%' => :percent,
)

function _tokenize(s::String)
    tokens = MToken[]
    i = 1
    n = lastindex(s)
    spaced = true
    push_tok!(t::MToken) = (push!(tokens, MToken(t.kind, t.value, t.pos, spaced)); spaced = false)
    while i <= n
        c = s[i]
        if isspace(c)
            spaced = true
            i = nextind(s, i)
        elseif c == '.' && nextind(s, i) <= n && s[nextind(s, i)] == '.'
            # `0 .. 7` : intervalle. `.` seul : groupement (`bd . hh hh`).
            push_tok!(MToken(:range, nothing, i)); i = nextind(s, i, 2)
        elseif c == '.'
            push_tok!(MToken(:dot, nothing, i)); i = nextind(s, i)
        elseif haskey(_MN_PUNCT, c)
            push_tok!(MToken(_MN_PUNCT[c], nothing, i)); i = nextind(s, i)
        elseif isdigit(c) || (c == '-' && nextind(s, i) <= n && isdigit(s[nextind(s, i)]))
            # Accept `-` as the start of a negative numeric literal (only
            # when immediately followed by a digit — `bd-sn` and similar
            # never appear in mini-notation, so the ambiguity is safe).
            j = c == '-' ? nextind(s, i) : i
            while j <= n && isdigit(s[j])
                j = nextind(s, j)
            end
            # Un `.` suivi d'un chiffre fait un flottant ; `0 .. 3` et
            # `bd . hh` gardent leur sens (le `.` n'est pas collé à un
            # chiffre, ou il est doublé).
            if j <= n && s[j] == '.' && nextind(s, j) <= n && isdigit(s[nextind(s, j)])
                k = nextind(s, j)   # past the '.'
                while k <= n && isdigit(s[k])
                    k = nextind(s, k)
                end
                push_tok!(MToken(:float, parse(Float64, s[i:prevind(s, k)]), i))
                i = k
            elseif j <= n && s[j] == '\''
                # Accord à racine numérique : `0'maj` — on lit le mot entier.
                while j <= n && (isletter(s[j]) || isdigit(s[j]) || s[j] == '\'')
                    j = nextind(s, j)
                end
                push_tok!(MToken(:ident, s[i:prevind(s, j)], i))
                i = j
            else
                push_tok!(MToken(:int, parse(Int, s[i:prevind(s, j)]), i))
                i = j
            end
        elseif isletter(c) || c == '_' || c == '#'
            j = i
            while j <= n && (isletter(s[j]) || isdigit(s[j]) || s[j] == '_' ||
                             s[j] == ':' || s[j] == '\'' || s[j] == '#' || s[j] == '-')
                j = nextind(s, j)
            end
            word = s[i:prevind(s, j)]
            # A bare "_" is the Tidal "extend previous slot" marker, not
            # an identifier — promote to a dedicated token kind so the
            # parser handles it cleanly.
            push_tok!(MToken(word == "_" ? :extend : :ident, word, i))
            i = j
        else
            throw(ArgumentError("Unexpected character '$(c)' at position $i in mini-notation"))
        end
    end
    return tokens
end

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

mutable struct ParseState
    tokens::Vector{MToken}
    pos::Int
end

_peek(ps::ParseState) = ps.pos <= length(ps.tokens) ? ps.tokens[ps.pos] : nothing
function _advance!(ps::ParseState)
    ps.pos > length(ps.tokens) && throw(ArgumentError("Unexpected end of mini-notation"))
    t = ps.tokens[ps.pos]; ps.pos += 1; t
end
function _expect!(ps::ParseState, kind::Symbol, ctx::AbstractString)
    t = _peek(ps)
    t === nothing && throw(ArgumentError("Expected $ctx, got end of input"))
    t.kind == kind || throw(ArgumentError("Expected $ctx at position $(t.pos), got $(t.kind)"))
    return _advance!(ps)
end

"""
    _parse_arg!(ps, ctx) -> Union{Real,MNode}

Argument numérique d'un modificateur : un littéral (`bd*2`, `bd@1.5`) ou
un pattern échantillonné à chaque cycle (`bd*<2 3>`, `bd(<3 5>,8)`).
"""
function _parse_arg!(ps::ParseState, ctx::AbstractString)
    t = _peek(ps)
    t === nothing && throw(ArgumentError("Expected $ctx, got end of input"))
    if t.kind == :int || t.kind == :float
        _advance!(ps); return t.value
    elseif t.kind == :langle || t.kind == :lbracket
        node, _, _ = _parse_unit!(ps)
        return node
    end
    throw(ArgumentError("Expected $ctx at position $(t.pos), got $(t.kind)"))
end

# Parse one unit (atom, group, or alt-group) plus any trailing modifiers.
# Retourne (node, weight, reps) — `weight` est le `@N` (ou `_`), `reps` le
# `!N` (réplication du pas).
function _parse_unit!(ps::ParseState)
    t = _peek(ps)
    t === nothing && throw(ArgumentError("Unexpected end of mini-notation"))

    if t.kind == :ident
        _advance!(ps)
        # `c'maj`, `e5'min7`, `0'dom7` : un accord = un empilement de notes
        # (demi-tons) jouées ensemble, comme `[0,4,7]`.
        node = occursin('\'', t.value) ? _chord_node(String(t.value)) : AtomNode(Symbol(t.value))
    elseif t.kind == :silence
        _advance!(ps)
        node = SilenceNode()
    elseif t.kind == :int || t.kind == :float
        # Numeric atom: e.g. `p"3 2 2 1"` or `p"0.5 1.0 0.5 1.0"`. Stored
        # as Symbol so it flows through the existing Pattern{Symbol}
        # pipeline; helpers like `n` / `gain` parse the symbol back to
        # an Int/Float via `_resolve_value` at dispatch time.
        _advance!(ps)
        node = AtomNode(Symbol(string(t.value)))
    elseif t.kind == :lbracket
        _advance!(ps)
        node = _parse_seq_or_chord!(ps, :rbracket)
    elseif t.kind == :langle
        _advance!(ps)
        raw = _parse_seq_until!(ps, :rangle)
        expanded = MNode[c for (c, _) in raw]
        isempty(expanded) && throw(ArgumentError("Empty alternation group at position $(t.pos)"))
        node = AltNode(expanded)
    elseif t.kind == :lbrace
        _advance!(ps)
        node = _parse_poly!(ps, t.pos)
    else
        throw(ArgumentError("Unexpected token $(t.kind) at position $(t.pos)"))
    end

    # Trailing modifiers (left-to-right, may chain).
    weight = MWeight(1)
    reps = 1
    while true
        nxt = _peek(ps)
        nxt === nothing && break
        if nxt.kind == :star
            _advance!(ps)
            node = RepeatNode(node, _parse_arg!(ps, "nombre ou pattern après '*'"))
        elseif nxt.kind == :slash
            _advance!(ps)
            node = SlowNode(node, _parse_arg!(ps, "nombre ou pattern après '/'"))
        elseif nxt.kind == :bang
            # Un `!` détaché (`bd ! !`) réplique le pas précédent : il est
            # traité au niveau de la séquence, pas ici.
            nxt.spaced && break
            _advance!(ps)
            la = _peek(ps)
            if la !== nothing && la.kind == :int
                _advance!(ps)
                la.value > 0 || throw(ArgumentError("'!' requires positive count at position $(la.pos)"))
                reps *= la.value
            else
                reps *= 2       # `bd!` seul = deux copies, comme Tidal
            end
        elseif nxt.kind == :at
            _advance!(ps)
            w = _parse_arg!(ps, "nombre après '@'")
            w isa Real || throw(ArgumentError("'@' n'accepte pas de pattern (position $(nxt.pos))"))
            w > 0 || throw(ArgumentError("'@' requires a positive weight at position $(nxt.pos)"))
            weight = _to_weight(w)
        elseif nxt.kind == :lparen
            _advance!(ps)
            k = _parse_arg!(ps, "nombre ou pattern après '('")
            _expect!(ps, :comma, "',' in Euclidean rhythm")
            nn = _parse_arg!(ps, "nombre ou pattern après ','")
            # Optional 3rd arg: rotation (cyclic shift of the pulse vector).
            # `bd(3,8,2)` rotates 3-of-8 forward by 2 steps.
            rot = 0
            if (la = _peek(ps)) !== nothing && la.kind == :comma
                _advance!(ps)
                rot = _parse_arg!(ps, "nombre ou pattern après la seconde ','")
            end
            _expect!(ps, :rparen, "')' closing Euclidean rhythm")
            node = EuclidNode(node, k, nn, rot)
        elseif nxt.kind == :question
            _advance!(ps)
            # Optional probability literal: `bd?0.3` = drop with 30%.
            # Without a number, defaults to 50%.
            prob = 0.5
            la = _peek(ps)
            if la !== nothing && (la.kind == :float || la.kind == :int)
                _advance!(ps); prob = float(la.value)
            end
            prob = clamp(prob, 0.0, 1.0)
            node = DegradeNode(node, prob)
        else
            break
        end
    end

    return (node, weight, reps)
end

_to_weight(x::Integer) = MWeight(x)
_to_weight(x::Real) = rationalize(Int64, float(x); tol = 1e-6)

# `{a b, c d e}` / `{a b}%4` — polymètre.
function _parse_poly!(ps::ParseState, pos::Int)
    voices = Vector{Vector{MNode}}()
    current = MNode[]
    while true
        t = _peek(ps)
        t === nothing && throw(ArgumentError("Unclosed polymeter group at position $pos"))
        if t.kind == :rbrace
            _advance!(ps); break
        elseif t.kind == :comma
            _advance!(ps); push!(voices, current); current = MNode[]; continue
        end
        node, _, reps = _parse_unit!(ps)
        for _ in 1:reps; push!(current, node); end
    end
    push!(voices, current)
    all(isempty, voices) && throw(ArgumentError("Empty polymeter group at position $pos"))
    steps = length(first(v for v in voices if !isempty(v)))
    if (la = _peek(ps)) !== nothing && la.kind == :percent
        _advance!(ps)
        steps = _parse_arg!(ps, "nombre ou pattern après '%'")
    end
    return PolyNode(voices, steps)
end

# Une suite de pas (utilisée par `<…>`), avec `!` `@` `_` et `..`.
function _parse_seq_until!(ps::ParseState, end_kind::Symbol)
    children = Tuple{MNode,MWeight}[]
    while true
        t = _peek(ps)
        if t === nothing
            end_kind == :eof || throw(ArgumentError("Unclosed group: expected $end_kind"))
            break
        end
        if t.kind == end_kind
            _advance!(ps); break
        end
        _push_step!(ps, children, t) || break
    end
    return children
end

# Un pas dans une liste : gère `_`, `!` isolé, `..`, sinon une unité.
# Retourne false quand le token ne fait pas partie d'une séquence.
function _push_step!(ps::ParseState, children::Vector{Tuple{MNode,MWeight}}, t::MToken)
    if t.kind == :extend
        _advance!(ps)
        if isempty(children)
            push!(children, (SilenceNode(), MWeight(1)))
        else
            node, w = children[end]
            children[end] = (node, w + 1)
        end
        return true
    elseif t.kind == :bang
        # `bd ! !` : réplique le pas précédent.
        _advance!(ps)
        la = _peek(ps)
        reps = 1
        if la !== nothing && la.kind == :int
            _advance!(ps); reps = max(1, la.value - 1)
        end
        isempty(children) && throw(ArgumentError("'!' sans pas précédent, position $(t.pos)"))
        node, w = children[end]
        for _ in 1:reps; push!(children, (node, w)); end
        return true
    elseif t.kind == :range
        _advance!(ps)
        isempty(children) && throw(ArgumentError("'..' sans borne de départ, position $(t.pos)"))
        from_node, _ = children[end]
        node, _, _ = _parse_unit!(ps)
        a = _atom_int(from_node); b = _atom_int(node)
        (a === nothing || b === nothing) &&
            throw(ArgumentError("'..' attend deux nombres entiers, position $(t.pos)"))
        step = a <= b ? 1 : -1
        for v in (a + step):step:b
            push!(children, (AtomNode(Symbol(string(v))), MWeight(1)))
        end
        return true
    end
    node, w, reps = _parse_unit!(ps)
    for _ in 1:reps; push!(children, (node, w)); end
    return true
end

_atom_int(n::AtomNode) = tryparse(Int, String(n.sym))
_atom_int(::MNode) = nothing

"""
    _parse_seq_or_chord!(ps, end_kind) -> MNode

Parse a group with four levels of separation:

  `,`  voix parallèles              →  ChordNode
  `|`  alternatives aléatoires      →  RandomAltNode
  `.`  groupes de pas               →  SeqNode de SeqNode
  ` `  juxtaposition                →  SeqNode

  `[bd hh sn]`         → SeqNode([bd, hh, sn])
  `[bd hh, sn cp]`     → ChordNode([SeqNode([bd, hh]), SeqNode([sn, cp])])
  `[bd | hh | sn]`     → RandomAltNode (one pick per cycle)
  `bd . hh hh . sn`    → SeqNode([bd, [hh hh], sn])
"""
function _parse_seq_or_chord!(ps::ParseState, end_kind::Symbol)
    voices = Vector{Vector{MNode}}()          # voix (`,`) → alternatives (`|`)
    alts   = MNode[]                          # alternatives de la voix courante
    groups = Vector{Vector{Tuple{MNode,MWeight}}}()   # groupes `.` de l'alt courante
    steps  = Tuple{MNode,MWeight}[]           # pas du groupe courant
    close_group!() = (push!(groups, steps); steps = Tuple{MNode,MWeight}[])
    close_alt!()   = (close_group!(); push!(alts, _alt_node(groups));
                      groups = Vector{Vector{Tuple{MNode,MWeight}}}())
    close_voice!() = (close_alt!(); push!(voices, alts); alts = MNode[])
    while true
        t = _peek(ps)
        if t === nothing
            end_kind == :eof || throw(ArgumentError("Unclosed group: expected $end_kind"))
            break
        end
        if t.kind == end_kind
            _advance!(ps); break
        end
        if t.kind == :comma
            _advance!(ps); close_voice!(); continue
        end
        if t.kind == :pipe
            _advance!(ps); close_alt!(); continue
        end
        if t.kind == :dot
            _advance!(ps); close_group!(); continue
        end
        _push_step!(ps, steps, t)
    end
    close_voice!()

    voice_nodes = MNode[length(a) == 1 ? a[1] : RandomAltNode(a) for a in voices]
    return length(voice_nodes) == 1 ? voice_nodes[1] : ChordNode(voice_nodes)
end

# Un « alt » est une suite de groupes séparés par des `.`. Un seul groupe →
# la séquence elle-même ; plusieurs → une séquence de sous-séquences.
_seq_node(steps::Vector{Tuple{MNode,MWeight}}) =
    isempty(steps) ? SilenceNode() :
    (length(steps) == 1 && steps[1][2] == 1 ? steps[1][1] : SeqNode(steps))
function _alt_node(groups::Vector{Vector{Tuple{MNode,MWeight}}})
    used = [g for g in groups if !isempty(g)]
    isempty(used) && return SilenceNode()
    length(used) == 1 && return _seq_node(used[1])
    return SeqNode(Tuple{MNode,MWeight}[(_seq_node(g), MWeight(1)) for g in used])
end

# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

# Euclidean distribution: returns a Bool vector of length n with k hits.
# Simple closed-form distribution (i*k mod n < k); deterministic and stable.
function _euclidean_pulses(k::Int, n::Int)
    n > 0 || throw(ArgumentError("Euclidean needs n > 0"))
    k <= 0 && return falses(n)
    k >= n && return trues(n)
    return [((i * k) % n) < k for i in 0:(n-1)]
end

function _emit!(out::Vector{Event{Symbol}}, node::AtomNode,
                a::Rational, b::Rational, cycle::Int)
    push!(out, Event{Symbol}(a, b, node.sym))
end

# Chord: each sub-sequence plays in parallel over the FULL [a, b)
# slot. The renderer emits overlapping events with the same arc but
# different values — the scheduler ships them all at the same time,
# producing a true musical chord (or a layered rhythm).
function _emit!(out::Vector{Event{Symbol}}, node::ChordNode,
                a::Rational, b::Rational, cycle::Int)
    for child in node.children
        _emit!(out, child, a, b, cycle)
    end
end

# Random alternative: pick ONE child per cycle, deterministic via
# hash so the same cycle always picks the same option (groove is
# reproducible across renders).
function _emit!(out::Vector{Event{Symbol}}, node::RandomAltNode,
                a::Rational, b::Rational, cycle::Int)
    n = length(node.children)
    n == 0 && return
    # Hash mixed with a fixed salt so different RandomAltNodes in
    # the same cycle don't lockstep to the same choice.
    salt = UInt(0x9e3779b97f4a7c15)
    idx = mod(hash(cycle, salt) % UInt32, UInt32(n)) + 1
    _emit!(out, node.children[idx], a, b, cycle)
end

function _emit!(::Vector{Event{Symbol}}, ::SilenceNode,
                ::Rational, ::Rational, ::Int)
    return  # silent: emit nothing
end

function _emit!(out::Vector{Event{Symbol}}, node::SeqNode,
                a::Rational, b::Rational, cycle::Int)
    isempty(node.children) && return
    total = sum(c[2] for c in node.children)
    width = b - a
    cursor = a
    last_i = length(node.children)
    for (i, (child, weight)) in enumerate(node.children)
        sub_b = i == last_i ? b : cursor + width * weight // total
        _emit!(out, child, cursor, sub_b, cycle)
        cursor = sub_b
    end
end

function _emit!(out::Vector{Event{Symbol}}, node::AltNode,
                a::Rational, b::Rational, cycle::Int)
    chosen = node.children[mod(cycle, length(node.children)) + 1]
    _emit!(out, chosen, a, b, cycle)
end

# Valeur numérique d'un argument de modificateur : littéral, ou pattern
# échantillonné au cycle courant (`bd*<2 3>`, `bd(<3 5>,8)`).
_arg_num(x::Real, ::Int) = x
function _arg_num(node::MNode, cycle::Int)
    tmp = Event{Symbol}[]
    _emit!(tmp, node, Rational{Int64}(0), Rational{Int64}(1), cycle)
    isempty(tmp) && return 0
    v = _sym_num(tmp[1].value)
    return v === nothing ? 0 : v
end
function _sym_num(v::Symbol)
    str = String(v)
    x = tryparse(Int, str); x === nothing || return x
    y = tryparse(Float64, str); y === nothing || return y
    return nothing
end
_arg_rat(x, cycle::Int) = (v = _arg_num(x, cycle);
                           v isa Integer ? Rational{Int64}(v) :
                           rationalize(Int64, float(v); tol = 1e-6))
_arg_int(x, cycle::Int) = (v = _arg_num(x, cycle); v isa Integer ? Int(v) : round(Int, v))

# `a*n` : le contenu se répète avec une période `slot / n`. Seuls les
# départs qui tombent dans le slot sont émis (n peut être fractionnaire).
function _emit!(out::Vector{Event{Symbol}}, node::RepeatNode,
                a::Rational, b::Rational, cycle::Int)
    n = _arg_rat(node.n, cycle)
    n > 0 || return
    width = b - a
    step = width / n
    i = 0
    while true
        sub_a = a + step * i
        sub_a < b || break
        sub_b = sub_a + step
        _emit!(out, node.child, sub_a, sub_b, cycle)
        i += 1
        i > 10_000 && break
    end
end

# `a/n` : le contenu est étiré sur `n` slots consécutifs ; on ne garde
# que ce qui démarre dans le slot du cycle courant.
function _emit!(out::Vector{Event{Symbol}}, node::SlowNode,
                a::Rational, b::Rational, cycle::Int)
    n = _arg_rat(node.n, cycle)
    n > 0 || return
    width = b - a
    k = mod(Rational{Int64}(cycle), n)          # position dans la période
    span_a = a - k * width
    span_b = span_a + n * width
    tmp = Event{Symbol}[]
    _emit!(tmp, node.child, span_a, span_b, fld(cycle, n isa Integer ? n : max(1, floor(Int, n))))
    for ev in tmp
        a <= ev.start < b && push!(out, ev)
    end
end

# `{a b, c d e}%n` : chaque voix défile à son propre pas, `n` pas par cycle.
function _emit!(out::Vector{Event{Symbol}}, node::PolyNode,
                a::Rational, b::Rational, cycle::Int)
    steps = _arg_int(node.steps, cycle)
    steps > 0 || return
    width = b - a
    for voice in node.voices
        len = length(voice)
        len == 0 && continue
        for j in 0:(steps - 1)
            idx = mod(cycle * steps + j, len) + 1
            sub_a = a + width * j // steps
            sub_b = j == steps - 1 ? b : a + width * (j + 1) // steps
            _emit!(out, voice[idx], sub_a, sub_b, cycle)
        end
    end
end

function _emit!(out::Vector{Event{Symbol}}, node::EuclidNode,
                a::Rational, b::Rational, cycle::Int)
    k = _arg_int(node.k, cycle); n = _arg_int(node.n, cycle); rot = _arg_int(node.rot, cycle)
    (k >= 0 && n > 0) || throw(ArgumentError("Invalid Euclidean parameters ($k,$n)"))
    pulses = _euclidean_pulses(k, n)
    # Rotation comme Tidal : `bd(3,8,2)` tourne les pas de 2 vers la
    # GAUCHE — [1,0,0,1,0,0,1,0] devient [0,1,0,0,1,0,1,0].
    if rot != 0
        pulses = circshift(collect(pulses), -rot)
    end
    width = b - a
    for i in 0:(n - 1)
        pulses[i + 1] || continue
        sub_a = a + width * i // n
        sub_b = i == n - 1 ? b : a + width * (i + 1) // n
        _emit!(out, node.child, sub_a, sub_b, cycle)
    end
end

function _emit!(out::Vector{Event{Symbol}}, node::DegradeNode,
                a::Rational, b::Rational, cycle::Int)
    # Deterministic per-event drop based on hash(start). Same start
    # across renders ⇒ same drop decision ⇒ groove is stable.
    r = (hash((a, cycle)) % UInt32(1_000_000)) / 1_000_000.0
    r < node.prob && return
    _emit!(out, node.child, a, b, cycle)
end

function _build_pattern(root::MNode)
    Pattern{Symbol}((s::Rational, e::Rational) -> begin
        events = Event{Symbol}[]
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        for cyc in n_start:(n_stop - 1)
            _emit!(events, root,
                   Rational{Int64}(cyc), Rational{Int64}(cyc + 1), cyc)
        end
        # Sémantique « onset » comme `pure` : un événement est émis entier
        # si et seulement s'il DÉMARRE dans [s, e). Couper des fragments
        # faisait rejouer un coup à cheval sur deux fenêtres (late, off,
        # stut… doublaient des coups).
        clipped = Event{Symbol}[ev for ev in events if s <= ev.start < e]
        sort!(clipped, by = ev -> ev.start)
        clipped
    end)
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    parse_minino(s::String) -> Pattern{Symbol}

Parse a TidalCycles-style mini-notation string into a `Pattern{Symbol}`.

Supported syntax (Phase 1):

| Form         | Meaning                                                   |
|--------------|-----------------------------------------------------------|
| `"bd hh sn"` | Sequence: each token gets an equal share of the cycle.    |
| `"~"`        | Silence (no event in that slot).                          |
| `"[a b]"`    | Subdivision: contents share the parent slot.              |
| `"<a b c>"`  | Alternation: one element per cycle, rotating.             |
| `"x*n"`      | Repeat `x` `n` times inside its slot.                     |
| `"x(k,n)"`   | Euclidean rhythm: `k` hits over `n` even steps.           |
| `"x!n"`      | Réplication : `x` occupe `n` pas (`bd ! !` = 3 fois bd).  |
| `"x@n"`      | Poids : `x` occupe `n` pas d'un seul tenant (`_` = +1).   |
| `"x/n"`      | Étirement : `x` est joué sur `n` cycles.                  |
| `"a . b c"`  | Groupement : équivaut à `[a] [b c]`.                      |
| `"0 .. 7"`   | Intervalle : `0 1 2 3 4 5 6 7`.                           |
| `"{a b,c d e}%n"` | Polymètre : chaque voix garde son pas, `n` par cycle. |
| `"a | b"`    | Alternative tirée au sort à chaque cycle.                 |

Sample notation like `"bd:1"` is preserved verbatim in the symbol (i.e. the
parsed value is `Symbol("bd:1")`).

Parse errors throw `ArgumentError` with the offending position.
"""
function parse_minino(s::String)
    tokens = _tokenize(s)
    state = ParseState(tokens, 1)
    root = _parse_seq_or_chord!(state, :eof)
    if root isa SilenceNode
        return silence(Symbol)
    end
    # Unwrap a trivial SeqNode wrapping a single weight-1 atom so the
    # simplest case `"bd"` returns the bare AtomNode at the top.
    if root isa SeqNode && length(root.children) == 1 && root.children[1][2] == 1
        root = root.children[1][1]
    end
    return _build_pattern(root)
end

"""
    @p_str(s)

String macro: `p"bd hh sn hh"` is equivalent to `parse_minino("bd hh sn hh")`.
"""
macro p_str(s)
    return :(parse_minino($s))
end

# ── Noms de notes et accords (comme Tidal) ─────────────────────────
# `c` = 0, `e` = 4, `a4` = -3 : octave 5 par défaut, s/# dièse, f/b bémol.
const _NOTE_BASE = Dict('c' => 0, 'd' => 2, 'e' => 4, 'f' => 5, 'g' => 7, 'a' => 9, 'b' => 11)

"""
    _note_number(str) -> Union{Nothing,Int}

Demi-tons d'un nom de note Tidal (`c`, `cs`, `ef5`, `a4`) ; `nothing` si
ce n'est pas un nom de note. Octave 5 = 0.
"""
function _note_number(str::AbstractString)
    m = match(r"^([a-gA-G])(ss|ff|s|f|#|b)?(-?\d+)?$", str)
    m === nothing && return nothing
    v = _NOTE_BASE[lowercase(m.captures[1][1])]
    acc = m.captures[2]
    acc === nothing || (v += acc in ("s", "#") ? 1 : acc == "ss" ? 2 : acc == "ff" ? -2 : -1)
    oct = m.captures[3] === nothing ? 5 : parse(Int, m.captures[3])
    return v + (oct - 5) * 12
end

# Table d'accords (intervalles en demi-tons), noms Tidal.
const _CHORD_TABLE = Dict{String,Vector{Int}}(
    "major" => [0, 4, 7], "maj" => [0, 4, 7], "M" => [0, 4, 7],
    "aug" => [0, 4, 8], "plus" => [0, 4, 8], "sharp5" => [0, 4, 8],
    "six" => [0, 4, 7, 9], "6" => [0, 4, 7, 9], "sixNine" => [0, 4, 7, 9, 14], "six9" => [0, 4, 7, 9, 14],
    "major7" => [0, 4, 7, 11], "maj7" => [0, 4, 7, 11],
    "major9" => [0, 4, 7, 11, 14], "maj9" => [0, 4, 7, 11, 14],
    "add9" => [0, 4, 7, 14], "major11" => [0, 4, 7, 11, 14, 17], "maj11" => [0, 4, 7, 11, 14, 17],
    "add11" => [0, 4, 7, 17], "major13" => [0, 4, 7, 11, 14, 21], "maj13" => [0, 4, 7, 11, 14, 21],
    "add13" => [0, 4, 7, 21],
    "dom7" => [0, 4, 7, 10], "dom9" => [0, 4, 7, 14], "dom11" => [0, 4, 7, 17], "dom13" => [0, 4, 7, 21],
    "sevenFlat5" => [0, 4, 6, 10], "7f5" => [0, 4, 6, 10], "sevenSharp5" => [0, 4, 8, 10], "7s5" => [0, 4, 8, 10],
    "sevenFlat9" => [0, 4, 7, 10, 13], "7f9" => [0, 4, 7, 10, 13], "nine" => [0, 4, 7, 10, 14],
    "eleven" => [0, 4, 7, 10, 14, 17], "11" => [0, 4, 7, 10, 14, 17],
    "thirteen" => [0, 4, 7, 10, 14, 17, 21], "13" => [0, 4, 7, 10, 14, 17, 21],
    "minor" => [0, 3, 7], "min" => [0, 3, 7], "m" => [0, 3, 7],
    "diminished" => [0, 3, 6], "dim" => [0, 3, 6],
    "minorSharp5" => [0, 3, 8], "msharp5" => [0, 3, 8], "mS5" => [0, 3, 8],
    "minor6" => [0, 3, 7, 9], "min6" => [0, 3, 7, 9], "m6" => [0, 3, 7, 9],
    "minorSixNine" => [0, 3, 9, 7, 14], "minor69" => [0, 3, 9, 7, 14], "min69" => [0, 3, 9, 7, 14], "m69" => [0, 3, 9, 7, 14],
    "minor7flat5" => [0, 3, 6, 10], "min7flat5" => [0, 3, 6, 10], "m7flat5" => [0, 3, 6, 10], "m7f5" => [0, 3, 6, 10],
    "minorMajor7" => [0, 3, 7, 11], "minMaj7" => [0, 3, 7, 11], "mmaj7" => [0, 3, 7, 11],
    "minor7sharp5" => [0, 3, 8, 10], "min7sharp5" => [0, 3, 8, 10], "m7sharp5" => [0, 3, 8, 10], "m7s5" => [0, 3, 8, 10],
    "diminished7" => [0, 3, 6, 9], "dim7" => [0, 3, 6, 9],
    "minor7" => [0, 3, 7, 10], "min7" => [0, 3, 7, 10], "m7" => [0, 3, 7, 10],
    "minor7flat9" => [0, 3, 7, 10, 13], "min7flat9" => [0, 3, 7, 10, 13], "m7flat9" => [0, 3, 7, 10, 13], "m7f9" => [0, 3, 7, 10, 13],
    "minor7sharp9" => [0, 3, 7, 10, 14], "min7sharp9" => [0, 3, 7, 10, 14], "m7sharp9" => [0, 3, 7, 10, 14], "m7s9" => [0, 3, 7, 10, 14],
    "minor9" => [0, 3, 7, 10, 14], "min9" => [0, 3, 7, 10, 14], "m9" => [0, 3, 7, 10, 14],
    "minor11" => [0, 3, 7, 10, 14, 17], "min11" => [0, 3, 7, 10, 14, 17], "m11" => [0, 3, 7, 10, 14, 17],
    "minor13" => [0, 3, 7, 10, 14, 17, 21], "min13" => [0, 3, 7, 10, 14, 17, 21], "m13" => [0, 3, 7, 10, 14, 17, 21],
    "one" => [0], "1" => [0], "five" => [0, 7], "5" => [0, 7],
    "sus2" => [0, 2, 7], "sus4" => [0, 5, 7],
    "sevenSus2" => [0, 2, 7, 10], "7sus2" => [0, 2, 7, 10], "sevenSus4" => [0, 5, 7, 10], "7sus4" => [0, 5, 7, 10],
    "nineSus4" => [0, 5, 7, 10, 14], "ninesus4" => [0, 5, 7, 10, 14], "9sus4" => [0, 5, 7, 10, 14],
    "sevenFlat10" => [0, 4, 7, 10, 15], "7f10" => [0, 4, 7, 10, 15],
    "nineSharp5" => [0, 1, 13], "9sharp5" => [0, 1, 13], "9s5" => [0, 1, 13],
    "minor9sharp5" => [0, 1, 14], "minor9s5" => [0, 1, 14], "min9sharp5" => [0, 1, 14], "min9s5" => [0, 1, 14], "m9sharp5" => [0, 1, 14], "m9s5" => [0, 1, 14],
    "sevenSharp5flat9" => [0, 4, 8, 10, 13], "7s5f9" => [0, 4, 8, 10, 13],
    "minor7sharp5flat9" => [0, 3, 8, 10, 13], "m7s5f9" => [0, 3, 8, 10, 13],
    "elevenSharp" => [0, 4, 7, 10, 14, 18], "11s" => [0, 4, 7, 10, 14, 18],
    "minor11sharp" => [0, 3, 7, 10, 14, 18], "m11sharp" => [0, 3, 7, 10, 14, 18], "m11s" => [0, 3, 7, 10, 14, 18],
)
chord_names() = sort!(collect(keys(_CHORD_TABLE)))

# `c'maj`, `e5'min7`, `0'dom7`, `c'maj'i` (renversement) → ChordNode.
function _chord_node(word::String)
    parts = split(word, '\'')
    root_s = String(parts[1]); name = length(parts) >= 2 ? String(parts[2]) : "major"
    root = _note_number(root_s)
    root === nothing && (root = tryparse(Int, root_s))
    root === nothing && throw(ArgumentError("racine d'accord inconnue « $root_s » dans « $word »"))
    ivs = get(_CHORD_TABLE, name, nothing)
    ivs === nothing && throw(ArgumentError("accord inconnu « $name » dans « $word » (voir chord_names())"))
    notes = [root + iv for iv in ivs]
    # modificateurs Tidal : 'i / 'ii / 'iii = renversements, 'o = ouvert,
    # 'N (entier) = nombre de notes (répète l'accord à l'octave).
    for mod in parts[3:end]
        if all(==('i'), mod) && !isempty(mod)
            for _ in 1:length(mod)
                push!(notes, popfirst!(notes) + 12)
            end
        elseif mod == "o" && length(notes) >= 3
            notes = vcat([notes[1] - 12, notes[3] - 12], notes[2:2], notes[4:end])
        elseif (k = tryparse(Int, mod)) !== nothing && k > 0
            base = copy(notes); notes = Int[]
            for i in 0:(k - 1)
                push!(notes, base[mod1(i + 1, length(base))] + 12 * (i ÷ length(base)))
            end
        end
    end
    return ChordNode(MNode[AtomNode(Symbol(string(v))) for v in notes])
end
