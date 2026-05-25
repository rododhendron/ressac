# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------

abstract type MNode end

struct AtomNode      <: MNode; sym::Symbol end
struct SilenceNode   <: MNode end
struct SeqNode       <: MNode; children::Vector{Tuple{MNode,Int}} end  # (child, weight)
struct AltNode       <: MNode; children::Vector{MNode} end             # weights pre-expanded
struct RepeatNode    <: MNode; child::MNode; n::Int end
struct EuclidNode    <: MNode; child::MNode; k::Int; n::Int; rot::Int end
struct DegradeNode   <: MNode; child::MNode; prob::Float64 end          # probabilistic drop

# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

# Tokens are simple tuples. The position field is the 1-based char index of
# the first character of the token, useful for error messages.
struct MToken
    kind::Symbol
    value::Any
    pos::Int
end

function _tokenize(s::String)
    tokens = MToken[]
    i = 1
    n = lastindex(s)
    while i <= n
        c = s[i]
        if isspace(c)
            i = nextind(s, i)
        elseif c == '~'
            push!(tokens, MToken(:silence, nothing, i)); i = nextind(s, i)
        elseif c == '['
            push!(tokens, MToken(:lbracket, nothing, i)); i = nextind(s, i)
        elseif c == ']'
            push!(tokens, MToken(:rbracket, nothing, i)); i = nextind(s, i)
        elseif c == '<'
            push!(tokens, MToken(:langle, nothing, i)); i = nextind(s, i)
        elseif c == '>'
            push!(tokens, MToken(:rangle, nothing, i)); i = nextind(s, i)
        elseif c == '*'
            push!(tokens, MToken(:star, nothing, i)); i = nextind(s, i)
        elseif c == '!'
            push!(tokens, MToken(:bang, nothing, i)); i = nextind(s, i)
        elseif c == '('
            push!(tokens, MToken(:lparen, nothing, i)); i = nextind(s, i)
        elseif c == ')'
            push!(tokens, MToken(:rparen, nothing, i)); i = nextind(s, i)
        elseif c == ','
            push!(tokens, MToken(:comma, nothing, i)); i = nextind(s, i)
        elseif c == '?'
            push!(tokens, MToken(:question, nothing, i)); i = nextind(s, i)
        elseif isdigit(c) || (c == '-' && nextind(s, i) <= n && isdigit(s[nextind(s, i)]))
            # Accept `-` as the start of a negative numeric literal (only
            # when immediately followed by a digit — `bd-sn` and similar
            # never appear in mini-notation, so the ambiguity is safe).
            j = c == '-' ? nextind(s, i) : i
            while j <= n && isdigit(s[j])
                j = nextind(s, j)
            end
            # If a decimal point + digit follows, this is a float literal.
            # Emit `:float` (Float64 value); else `:int`. Both flow through
            # the parser via `_parse_unit!`'s numeric-atom branch.
            if j <= n && s[j] == '.' && nextind(s, j) <= n && isdigit(s[nextind(s, j)])
                k = nextind(s, j)   # past the '.'
                while k <= n && isdigit(s[k])
                    k = nextind(s, k)
                end
                push!(tokens, MToken(:float, parse(Float64, s[i:prevind(s, k)]), i))
                i = k
            else
                push!(tokens, MToken(:int, parse(Int, s[i:prevind(s, j)]), i))
                i = j
            end
        elseif isletter(c) || c == '_'
            j = i
            while j <= n && (isletter(s[j]) || isdigit(s[j]) || s[j] == '_' || s[j] == ':')
                j = nextind(s, j)
            end
            word = s[i:prevind(s, j)]
            # A bare "_" is the Tidal "extend previous slot" marker, not
            # an identifier — promote to a dedicated token kind so the
            # parser handles it cleanly.
            push!(tokens, MToken(word == "_" ? :extend : :ident, word, i))
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

# Parse one unit (atom, group, or alt-group) plus any trailing modifiers.
# Returns (node, weight) — weight is the `!N` modifier, defaulting to 1.
function _parse_unit!(ps::ParseState)
    t = _peek(ps)
    t === nothing && throw(ArgumentError("Unexpected end of mini-notation"))

    if t.kind == :ident
        _advance!(ps)
        node = AtomNode(Symbol(t.value))
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
        children = _parse_seq_until!(ps, :rbracket)
        node = SeqNode(children)
    elseif t.kind == :langle
        _advance!(ps)
        raw = _parse_seq_until!(ps, :rangle)
        # `!N` inside `<>` replicates the child N times in the rotation.
        expanded = MNode[]
        for (c, w) in raw, _ in 1:w
            push!(expanded, c)
        end
        isempty(expanded) && throw(ArgumentError("Empty alternation group at position $(t.pos)"))
        node = AltNode(expanded)
    else
        throw(ArgumentError("Unexpected token $(t.kind) at position $(t.pos)"))
    end

    # Trailing modifiers (left-to-right, may chain).
    weight = 1
    while true
        nxt = _peek(ps)
        nxt === nothing && break
        if nxt.kind == :star
            _advance!(ps)
            n_tok = _expect!(ps, :int, "integer after '*'")
            n_tok.value > 0 || throw(ArgumentError("'*' requires positive count at position $(n_tok.pos)"))
            node = RepeatNode(node, n_tok.value)
        elseif nxt.kind == :bang
            _advance!(ps)
            n_tok = _expect!(ps, :int, "integer after '!'")
            n_tok.value > 0 || throw(ArgumentError("'!' requires positive count at position $(n_tok.pos)"))
            weight = n_tok.value
        elseif nxt.kind == :lparen
            _advance!(ps)
            k_tok = _expect!(ps, :int, "integer after '('")
            _expect!(ps, :comma, "',' in Euclidean rhythm")
            n_tok = _expect!(ps, :int, "integer after ','")
            # Optional 3rd arg: rotation (cyclic shift of the pulse vector).
            # `bd(3,8,2)` rotates 3-of-8 forward by 2 steps.
            rot = 0
            if (la = _peek(ps)) !== nothing && la.kind == :comma
                _advance!(ps)
                r_tok = _expect!(ps, :int, "integer after second ','")
                rot = r_tok.value
            end
            _expect!(ps, :rparen, "')' closing Euclidean rhythm")
            (k_tok.value >= 0 && n_tok.value > 0) ||
                throw(ArgumentError("Invalid Euclidean parameters ($(k_tok.value),$(n_tok.value)) at position $(k_tok.pos)"))
            node = EuclidNode(node, k_tok.value, n_tok.value, rot)
        elseif nxt.kind == :question
            _advance!(ps)
            # Optional probability literal: `bd?0.3` = drop with 30%.
            # Without a number, defaults to 50%.
            prob = 0.5
            la = _peek(ps)
            if la !== nothing && la.kind == :float
                _advance!(ps); prob = la.value
            elseif la !== nothing && la.kind == :int
                _advance!(ps); prob = float(la.value)
            end
            prob = clamp(prob, 0.0, 1.0)
            node = DegradeNode(node, prob)
        else
            break
        end
    end

    return (node, weight)
end

function _parse_seq_until!(ps::ParseState, end_kind::Symbol)
    children = Tuple{MNode,Int}[]
    while true
        t = _peek(ps)
        if t === nothing
            end_kind == :eof || throw(ArgumentError("Unclosed group: expected $end_kind"))
            break
        end
        if t.kind == end_kind
            _advance!(ps)
            break
        end
        # `_` extends the previous slot's duration by one — implemented
        # as a weight bump rather than a new node. At the start of a
        # sequence (no prev), behave as silence.
        if t.kind == :extend
            _advance!(ps)
            if isempty(children)
                push!(children, (SilenceNode(), 1))
            else
                last_node, last_w = children[end]
                children[end] = (last_node, last_w + 1)
            end
            continue
        end
        push!(children, _parse_unit!(ps))
    end
    return children
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

function _emit!(out::Vector{Event{Symbol}}, node::RepeatNode,
                a::Rational, b::Rational, cycle::Int)
    n = node.n
    width = b - a
    for i in 0:(n-1)
        sub_a = a + width * i // n
        sub_b = i == n - 1 ? b : a + width * (i + 1) // n
        _emit!(out, node.child, sub_a, sub_b, cycle)
    end
end

function _emit!(out::Vector{Event{Symbol}}, node::EuclidNode,
                a::Rational, b::Rational, cycle::Int)
    pulses = _euclidean_pulses(node.k, node.n)
    # Apply rotation: shift the pulse vector forward by `rot` steps,
    # wrapping. `bd(3,8,2)` → pulses originally [1,0,0,1,0,0,1,0]
    # become [0,1,1,0,0,1,0,0] for rot=2. Negative rotates backward.
    if node.rot != 0
        r = mod(node.rot, node.n)
        pulses = vcat(pulses[end-r+1:end], pulses[1:end-r])
    end
    width = b - a
    for i in 0:(node.n - 1)
        pulses[i + 1] || continue
        sub_a = a + width * i // node.n
        sub_b = i == node.n - 1 ? b : a + width * (i + 1) // node.n
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
        clipped = Event{Symbol}[]
        for ev in events
            a = max(ev.start, s)
            b = min(ev.stop,  e)
            a < b && push!(clipped, Event{Symbol}(a, b, ev.value))
        end
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
| `"x!n"`      | Weight: `x` takes `n` slots inside its parent sequence.   |

Sample notation like `"bd:1"` is preserved verbatim in the symbol (i.e. the
parsed value is `Symbol("bd:1")`).

Parse errors throw `ArgumentError` with the offending position.
"""
function parse_minino(s::String)
    tokens = _tokenize(s)
    state = ParseState(tokens, 1)
    children = _parse_seq_until!(state, :eof)
    if isempty(children)
        return silence(Symbol)
    end
    root = (length(children) == 1 && children[1][2] == 1) ?
        children[1][1] : SeqNode(children)
    return _build_pattern(root)
end

"""
    @p_str(s)

String macro: `p"bd hh sn hh"` is equivalent to `parse_minino("bd hh sn hh")`.
"""
macro p_str(s)
    return :(parse_minino($s))
end
