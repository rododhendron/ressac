# Visual UX support: mode hints, help overlay lines, completion engine.
# Spec: docs/journal/20260522_visual_ux_design.md.

"""
    _fuzzy_score(query, candidate) -> Union{Nothing, Int}

Score how well `candidate` matches `query` as a case-insensitive
subsequence. Lower is tighter. Returns `nothing` if `query` has no
subsequence in `candidate`.

Score = sum of gaps (positions skipped) between consecutive matched
chars. Exact prefix → 0; one-letter gap → 1; etc.
"""
function _fuzzy_score(query::AbstractString, candidate::AbstractString)
    isempty(query) && return 0
    q = lowercase(String(query))
    c = lowercase(String(candidate))
    score = 0
    last_match_pos = 0
    qi = firstindex(q)
    q_end = lastindex(q)
    for (pos, ch) in pairs(c)
        if ch == q[qi]
            if last_match_pos != 0
                score += (pos - last_match_pos - 1)
            end
            last_match_pos = pos
            qi = nextind(q, qi)
            qi > q_end && return score
        end
    end
    return nothing
end

"""
    _fuzzy_rank(query, candidates) -> Vector{String}

Return the subset of `candidates` that fuzzy-match `query`, sorted by
`(score asc, length asc, lexico asc)`. Non-matches are dropped.
"""
function _fuzzy_rank(query::AbstractString, candidates::AbstractVector{<:AbstractString})
    scored = Tuple{Int,Int,String}[]
    for cand in candidates
        s = _fuzzy_score(query, cand)
        s === nothing && continue
        push!(scored, (s, length(cand), String(cand)))
    end
    sort!(scored, by = t -> (t[1], t[2], t[3]))
    return [t[3] for t in scored]
end

"""
    _is_word_char_simple(c) -> Bool

Word-char predicate for completion-target extraction. Does NOT include
`:` (so `bd:1` is two tokens, not one — we don't want to fuzzy-match
into variant indices).
"""
_is_word_char_simple(c::AbstractChar) =
    isletter(c) || isdigit(c) || c == '_' || c == '@'

"""
    _completion_context(line, cursor_col) -> Symbol

Walk `line` left-to-right up to `cursor_col`, tracking whether we are
currently inside a `p"..."` or `m"..."` string. Returns
`:mininotation` if such a string is still open at the cursor,
`:default` otherwise. A `"` not preceded by a recognised opener
toggles a plain-string flag that also blocks default until closed.
"""
function _completion_context(line::AbstractString, cursor_col::Integer)
    in_mn = false
    in_plain = false
    i = firstindex(line)
    last_byte = min(lastindex(line), cursor_col - 1)
    while i <= last_byte
        c = line[i]
        if !in_mn && !in_plain
            ni = nextind(line, i)
            is_opener = ni <= lastindex(line) &&
                        (c == 'p' || c == 'm') && line[ni] == '"' &&
                        (i == firstindex(line) ||
                         !_is_word_char_simple(line[prevind(line, i)]))
            if is_opener
                in_mn = true
                i = nextind(line, ni)
                continue
            end
            if c == '"'
                in_plain = true
            end
        elseif in_mn && c == '"'
            in_mn = false
        elseif in_plain && c == '"'
            in_plain = false
        end
        i = nextind(line, i)
    end
    return in_mn ? :mininotation : :default
end
