import Base: +, -, *, /

"""
    _combine(op, p, q, ::Type{V}) -> Pattern{V}

Combine two patterns by intersecting every pair of overlapping arcs and
applying `op` to the values. The resulting events are clipped to the actual
intersection arc; non-overlapping events are dropped.

Used as the engine behind `+`, `-`, `*`, `/` on two patterns.
"""
function _combine(op, p::Pattern{T}, q::Pattern{U}, ::Type{V}) where {T,U,V}
    Pattern{V}((s::Rational, e::Rational) -> begin
        evs_p = p(s, e)
        evs_q = q(s, e)
        out = Event{V}[]
        for ev_p in evs_p, ev_q in evs_q
            a = max(ev_p.start, ev_q.start)
            b = min(ev_p.stop,  ev_q.stop)
            a < b && push!(out, Event{V}(a, b, op(ev_p.value, ev_q.value)))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    _mapvals(f, p, ::Type{V}) -> Pattern{V}

Map `f` over every event's value, preserving arcs. Used for `Pattern op scalar`.
"""
function _mapvals(f, p::Pattern{T}, ::Type{V}) where {T,V}
    Pattern{V}((s::Rational, e::Rational) -> begin
        [Event{V}(ev.start, ev.stop, f(ev.value)) for ev in p(s, e)]
    end)
end

# --- Pattern op Pattern ---------------------------------------------------

for op in (:+, :-, :*, :/)
    @eval begin
        function Base.$op(p::Pattern{T}, q::Pattern{U}) where {T<:Number,U<:Number}
            V = typeof($op(zero(T), zero(U)))
            _combine($op, p, q, V)
        end
    end
end

# --- Pattern op scalar (both sides) ---------------------------------------

for op in (:+, :-, :*, :/)
    @eval begin
        function Base.$op(p::Pattern{T}, x::Number) where {T<:Number}
            V = typeof($op(zero(T), x))
            _mapvals(v -> $op(v, x), p, V)
        end
        function Base.$op(x::Number, p::Pattern{T}) where {T<:Number}
            V = typeof($op(x, zero(T)))
            _mapvals(v -> $op(x, v), p, V)
        end
    end
end

# --- mask -----------------------------------------------------------------

"""
    mask(p::Pattern{T}, q::Pattern{Bool}) -> Pattern{T}

Gate `p` by `q`: emit a clipped event with `p`'s value wherever a `true` event
of `q` overlaps an event of `p`. Where `q` is `false` (or has no event), `p` is
silenced.

This is the non-numeric counterpart to `+`/`*`: it lets you combine a value
pattern with a rhythmic pattern of booleans without requiring `T <: Number`.
"""
function mask(p::Pattern{T}, q::Pattern{Bool}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        evs_p = p(s, e)
        evs_q = q(s, e)
        out = Event{T}[]
        for ev_q in evs_q
            ev_q.value || continue
            for ev_p in evs_p
                a = max(ev_p.start, ev_q.start)
                b = min(ev_p.stop,  ev_q.stop)
                a < b && push!(out, Event{T}(a, b, ev_p.value))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
