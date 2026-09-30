# src/content_glossary.jl
# Le glossaire : les fiches étiquetées `glossary` (plugins/core/docs/glossary
# et les contrôles qui portent un concept). Elles se reconnaissent dans
# tout texte rendu (fiches, wiki, explications, éditeur) : le mot est
# souligné, et une bulle s'ouvre au survol de la souris (app_hover.jl).

# ── Index des termes ────────────────────────────────────────────────
# lowercase(terme ou alias) → nom de la fiche. Recalculé quand le
# registre des fiches change (nombre d'entrées).
const _GLOSSARY_INDEX = Ref{Tuple{Int,Dict{String,String},Union{Nothing,Regex}}}((-1, Dict{String,String}(), nothing))

function _glossary_index()
    n = length(_DOCS)
    cached = _GLOSSARY_INDEX[]
    cached[1] == n && return cached[2], cached[3]
    idx = Dict{String,String}()
    for e in values(_DOCS)
        :glossary in e.tags || continue
        idx[lowercase(e.name)] = e.name
        for a in e.aliases
            idx[lowercase(a)] = e.name
        end
    end
    rx = if isempty(idx)
        nothing
    else
        # Les termes longs d'abord (« low-pass filter » avant « filter »).
        terms = sort!(collect(keys(idx)); by = length, rev = true)
        Regex("(?<![\\w-])(?:" * join((_glossary_escape(t) for t in terms), "|") * ")(?![\\w-])", "i")
    end
    _GLOSSARY_INDEX[] = (n, idx, rx)
    return idx, rx
end

_glossary_escape(t::AbstractString) = replace(t, r"([\\^$.|?*+()\[\]{}])" => s"\\\1")

# Le nom de fiche d'un terme (ou alias), sinon nothing.
function glossary_term(word::AbstractString)
    idx, _ = _glossary_index()
    return get(idx, lowercase(String(word)), nothing)
end

"""
    _glossary_term_at(text, col) -> Union{Nothing,String}

Le terme du glossaire sous la colonne `col` (1-based, en caractères)
de `text`, ou nothing.
"""
function _glossary_term_at(text::AbstractString, col::Int)
    idx, rx = _glossary_index()
    rx === nothing && return nothing
    s = String(text)
    col < 1 && return nothing
    for mt in eachmatch(rx, s)
        c0 = length(s[1:prevind(s, mt.offset)]) + 1
        c1 = c0 + length(mt.match) - 1
        c0 <= col <= c1 && return get(idx, lowercase(mt.match), nothing)
        c0 > col && break
    end
    return nothing
end

# ── Soulignement dans les spans ──────────────────────────────────────
_underlined(st::TK.Style) = TK.Style(fg = st.fg, bg = st.bg, bold = st.bold, dim = st.dim,
                                     italic = st.italic, underline = true,
                                     strikethrough = st.strikethrough, hyperlink = st.hyperlink)

"""
    _glossary_underline(spans; base) -> spans

Souligne les termes du glossaire dans les spans de style `base` (le
texte courant ; le code et les titres restent tels quels).
"""
function _glossary_underline(spans::Vector{TK.Span}; base::TK.Style = TK.tstyle(:text))
    _, rx = _glossary_index()
    rx === nothing && return spans
    out = TK.Span[]
    for sp in spans
        if sp.style != base || !occursin(rx, sp.content)
            push!(out, sp); continue
        end
        s = sp.content; pos = 1
        for mt in eachmatch(rx, s)
            mt.offset > pos && push!(out, TK.Span(s[pos:prevind(s, mt.offset)], base))
            push!(out, TK.Span(mt.match, _underlined(base)))
            pos = mt.offset + ncodeunits(mt.match)
        end
        pos <= lastindex(s) && push!(out, TK.Span(s[pos:end], base))
    end
    return out
end

# ── La bulle d'un terme ──────────────────────────────────────────────
"""
    _glossary_lines(name, width) -> Vector{Vector{Span}}

Le contenu d'une bulle : la phrase courte en gras, puis le corps replié.
"""
function _glossary_lines(name::AbstractString, width::Int)
    e = lookup_doc(String(name))
    e === nothing && return [_span_line("(no entry for « $name »)", TK.tstyle(:text_dim))]
    out = Vector{TK.Span}[]
    isempty(e.short) || append!(out, _md_wrap(TK.Span[TK.Span(e.short, TK.tstyle(:text_bright, bold = true))], width))
    body = strip(replace(e.body, r"^# .*\n" => ""))
    # le corps sans la phrase courte répétée en tête
    startswith(body, strip(e.short)) && (body = strip(body[nextind(body, lastindex(strip(e.short))):end]))
    for para in split(body, r"\n\s*\n")
        p = strip(replace(para, '\n' => ' '))
        isempty(p) && continue
        push!(out, TK.Span[])
        append!(out, _md_wrap(_glossary_underline(_md_inline(p)), width))
    end
    return out
end

# ── État du survol (défini ici pour le champ de RessacApp) ───────────
mutable struct HoverBox
    term::String
    x::Int; y::Int; w::Int; h::Int
    lines::Vector{Vector{TK.Span}}
end

mutable struct HoverState
    boxes::Vector{HoverBox}
    since::Float64      # ouverture de la bulle du dessus
    locked::Bool        # verrouillée : la souris peut y entrer et en sortir la ferme
end

const _HOVER_CLOCK = Ref{Function}(time)   # remplaçable dans les tests
