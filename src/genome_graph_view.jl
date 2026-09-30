# src/genome_graph_view.jl
# Le graphe d'un synth en cellules de texte : la chaîne principale de la
# matière vers la sortie, en boîtes reliées par des flèches, et sous
# chaque boîte ce qui la module, avec le nom du slot sur l'arête. Une
# couleur par rôle, le nœud focalisé en trait épais, ✂ sur ce qui ne
# s'entend pas. Tout est pur : un génome entre, des lignes de spans sortent.

struct GraphBox
    id::Int
    label::String          # nom de l'UGen (+ ✂)
    sub::String            # ses arguments scalaires, en abrégé
    role::Symbol
    col::Int               # colonne (nœud principal) sous laquelle il est dessiné
    depth::Int             # 0 = chaîne principale, 1 = modulateur, 2 = modulateur de modulateur…
    edge::String           # nom du slot qu'il alimente (vide pour la chaîne)
end

_graph_role_style(role::Symbol) =
    role === :matière   ? TK.tstyle(:primary) :
    role === :corps     ? TK.tstyle(:accent) :
    role === :mouvement ? TK.tstyle(:success) :
    role === :grain     ? TK.tstyle(:warning) :
    role === :enveloppe ? TK.tstyle(:text_bright) :
    role === :espace    ? TK.tstyle(:primary) :
    role === :chaos     ? TK.tstyle(:error) : TK.tstyle(:text)

_graph_role_label(role::Symbol) = role === :matière ? "matière" : role === :corps ? "corps" :
    role === :mouvement ? "mouvement" : role === :grain ? "grain" : role === :enveloppe ? "enveloppe" :
    role === :espace ? "espace" : role === :chaos ? "chaos" : role === :mélange ? "mélange" :
    role === :feedback ? "feedback" : ""

function _graph_fmt(v::Float64)
    isinteger(v) && abs(v) < 1e6 && return string(Int(v))
    s = string(round(v; sigdigits = 4))
    return length(s) > 7 ? string(round(v; sigdigits = 2)) : s
end

# Le sous-titre d'une boîte : les arguments qui ne sont pas des nœuds.
function _graph_sub(g::Genome, n::UGenNode, skip::Int)
    parts = String[]
    for (i, a) in enumerate(n.args)
        i == skip && continue
        a isa ConstArg && push!(parts, _graph_fmt(a.value))
        a isa ControlRef && push!(parts, ":" * String(a.name))
        length(parts) >= 3 && break
    end
    s = join(parts, " ")
    return length(s) > 14 ? first(s, 13) * "…" : s
end

# L'entrée principale (audio) d'un nœud, ou nothing pour une source.
function _graph_main_input(g::Genome, n::UGenNode)
    si = _bypass_input_slot(n)
    (si === nothing || si > length(n.args)) && return nothing
    a = n.args[si]
    a isa NodeRef && haskey(g.nodes, a.id) || return nothing
    return si
end

"""
    graph_boxes(g; hints, impacts) -> Vector{GraphBox}

Les boîtes du graphe, colonne par colonne (chaîne principale de gauche à
droite), les modulateurs après leur cible avec une profondeur.
"""
function graph_boxes(g::Genome; hints = Dict{Int,String}(), impacts = Dict{Int,Float64}())
    boxes = GraphBox[]
    (g.output_id == 0 || !haskey(g.nodes, g.output_id)) && return boxes
    # La chaîne : de la sortie vers la source par l'entrée principale.
    chain = Int[]
    id = g.output_id; seen = Set{Int}()
    while id != 0 && haskey(g.nodes, id) && !(id in seen)
        push!(seen, id); push!(chain, id)
        n = g.nodes[id]
        si = _graph_main_input(g, n)
        id = si === nothing ? 0 : n.args[si].id
    end
    reverse!(chain)
    mark(id) = haskey(hints, id) || (haskey(impacts, id) && impacts[id] < 0.02) ? " ✂" : ""
    function add!(id::Int, col::Int, depth::Int, edge::String, visited::Set{Int})
        n = g.nodes[id]
        si = depth == 0 ? _graph_main_input(g, n) : nothing
        push!(boxes, GraphBox(id, String(n.ugen) * mark(id), _graph_sub(g, n, something(si, 0)),
                              _func_role(n.ugen), col, depth, edge))
        push!(visited, id)
        spec = ugen_spec(n.ugen)
        for (i, a) in enumerate(n.args)
            i == si && continue
            a isa NodeRef && haskey(g.nodes, a.id) || continue
            a.id in visited && continue
            depth >= 3 && continue
            slot = spec !== nothing && i <= length(spec.slots) ? String(spec.slots[i].name) :
                   n.ugen === :Mix ? "+" : n.ugen === :MulAdd ? (i == 2 ? "×" : "+") : "in$i"
            add!(a.id, col, depth + 1, slot, visited)
        end
    end
    visited = Set{Int}()
    for (col, id) in enumerate(chain)
        add!(id, col, 0, "", visited)
    end
    return boxes
end

# ── Dessin ───────────────────────────────────────────────────────────
mutable struct _Canvas
    cells::Vector{Vector{Char}}
    styles::Vector{Vector{TK.Style}}
end
_Canvas(w::Int, h::Int) = _Canvas([fill(' ', w) for _ in 1:h], [fill(TK.tstyle(:text), w) for _ in 1:h])

function _put!(c::_Canvas, x::Int, y::Int, s::AbstractString, st::TK.Style)
    (1 <= y <= length(c.cells)) || return
    for (k, ch) in enumerate(collect(s))
        xx = x + k - 1
        1 <= xx <= length(c.cells[y]) || continue
        c.cells[y][xx] = ch; c.styles[y][xx] = st
    end
end

function _box!(c::_Canvas, x::Int, y::Int, w::Int, label::String, sub::String, st::TK.Style, heavy::Bool)
    (tl, tr, bl, br, hz, vt) = heavy ? ('┏', '┓', '┗', '┛', '━', '┃') : ('┌', '┐', '└', '┘', '─', '│')
    bst = heavy ? TK.Style(fg = st.fg, bold = true) : st
    _put!(c, x, y, string(tl, hz^(w - 2), tr), bst)
    _put!(c, x, y + 1, string(vt, rpad(" " * label, w - 2), vt), bst)
    _put!(c, x + 1, y + 1, " " * label, TK.Style(fg = st.fg, bold = true))
    _put!(c, x, y + 2, string(vt, rpad(" " * sub, w - 2), vt), bst)
    _put!(c, x + 1, y + 2, " " * sub, TK.tstyle(:text_dim))
    _put!(c, x, y + 3, string(bl, hz^(w - 2), br), bst)
end

_box_w(b::GraphBox) = max(length(b.label), length(b.sub), 4) + 2 + 2

"""
    graph_lines(g; focus, hints, impacts) -> (lines, ids)

Les lignes (spans) du graphe et, pour la navigation, les ids des boîtes
dans l'ordre du dessin.
"""
function graph_lines(g::Genome; focus::Int = 0, hints = Dict{Int,String}(), impacts = Dict{Int,Float64}())
    boxes = graph_boxes(g; hints = hints, impacts = impacts)
    isempty(boxes) && return ([_span_line("(graphe vide)", TK.tstyle(:text_dim))], Int[])
    ncol = maximum(b.col for b in boxes)
    colw = [maximum(_box_w(b) + 2 * b.depth for b in boxes if b.col == c; init = 8) for c in 1:ncol]
    gap = 5                                  # "  ──▶  " entre deux colonnes
    xs = cumsum(vcat(1, colw[1:end-1] .+ gap))
    # Hauteur : chaque boîte 4 lignes + 1 ligne d'arête au-dessus des modulateurs.
    rows = Int[]                             # y de chaque boîte, dans l'ordre
    colh = zeros(Int, ncol)
    for b in boxes
        y = b.depth == 0 ? 2 : colh[b.col] + 2
        push!(rows, y)
        colh[b.col] = y + 4
    end
    W = xs[end] + colw[end] + gap + 12
    H = maximum(colh) + 1
    c = _Canvas(W, H)
    # Rôles en tête de colonne.
    for col in 1:ncol
        b = boxes[findfirst(x -> x.col == col && x.depth == 0, boxes)]
        _put!(c, xs[col] + 1, 1, _graph_role_label(b.role), TK.Style(fg = _graph_role_style(b.role).fg, dim = true))
    end
    _put!(c, xs[end] + colw[end] + gap - 1, 1, "sortie", TK.tstyle(:text_dim))
    for (k, b) in enumerate(boxes)
        x = xs[b.col] + 2 * b.depth
        y = rows[k]
        st = _graph_role_style(b.role)
        _box!(c, x, y, _box_w(b), b.label, b.sub, st, b.id == focus)
        if b.depth == 0
            # la flèche vers la colonne suivante, ou la sortie
            ax = x + _box_w(b)
            if b.col < ncol
                _put!(c, ax, y + 1, "─"^(xs[b.col + 1] - ax - 1) * "▶", TK.tstyle(:text_dim))
            else
                _put!(c, ax, y + 1, "──▶ ◉ out", TK.tstyle(:text_bright))
            end
        else
            # l'arête vers la boîte du dessus : ┃ + nom du slot
            _put!(c, x + 2, y - 1, "┃ " * b.edge, TK.Style(fg = st.fg, dim = true))
        end
    end
    # Conversion en spans (une ligne par rangée, styles fusionnés).
    lines = Vector{TK.Span}[]
    for y in 1:H
        row = c.cells[y]; sts = c.styles[y]
        last = findlast(!=(' '), row)
        last === nothing && (push!(lines, TK.Span[]); continue)
        spans = TK.Span[]; i = 1
        while i <= last
            j = i
            while j + 1 <= last && sts[j + 1] == sts[i]; j += 1; end
            push!(spans, TK.Span(String(row[i:j]), sts[i]))
            i = j + 1
        end
        push!(lines, spans)
    end
    return lines, Int[b.id for b in boxes]
end
