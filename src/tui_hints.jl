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
