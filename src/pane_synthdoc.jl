# src/pane_synthdoc.jl
# Pane DOC du workspace synth : deux onglets, `doc` (la fiche du mot sous
# le curseur, doc vivante) et `explication` (pourquoi le synth sonne
# comme ça, posée par la synchronisation du studio). ← → les font tourner.

mutable struct SynthDocPane <: PaneImpl
    mode::Symbol                  # :doc | :explain | :graph
    doc::DocPane                  # la fiche (suit le curseur)
    explain::TK.ScrollPane        # l'explication repliée, défilable
    explain_lines::Vector{String}
    explain_w::Int                # largeur pour laquelle `explain` est construit (0 = à refaire)
    graph::TK.ScrollPane          # le graphe (genome_graph_view.jl)
    graph_key::Any                # (génome, version, focus) du graphe posé dans `graph`
    graph_ids::Vector{Int}        # ids des boîtes dans l'ordre du dessin (h / l)
    graph_focus::Int              # nœud focalisé dans le graphe (0 = aucun)
    graph_x::Int                  # défilement horizontal du graphe
    studio::Union{Nothing,WaveformPane}   # le studio lié (posé par la synchronisation)
end

const _SYNTHDOC_MODES = (:doc, :explain, :graph)
_synthdoc_label(mode::Symbol) = mode === :doc ? "doc" : mode === :explain ? "explication" : "graphe"

function _synthdoc_pane_ctor(args::AbstractDict)
    mode = Symbol(String(get(args, "mode", "doc")))
    mode in _SYNTHDOC_MODES || (mode = :doc)
    return SynthDocPane(mode, DocPane(String(get(args, "name", "")), 0, true),
                        _scrollpane(), String[], 0,
                        _scrollpane(), nothing, Int[], 0, 0, nothing)
end

# ── Le graphe ────────────────────────────────────────────────────────
# Requêtes de la pane vers l'app (elle ne connaît pas l'app) : `:focus_studio`
# après Enter dans le graphe. Drainée à chaque touche (app_input.jl).
const _SYNTHDOC_REQUEST = Ref{Union{Nothing,Symbol}}(nothing)

_synthdoc_graph(p::SynthDocPane) = p.mode === :graph
_synthdoc_not_graph(p::SynthDocPane) = p.mode !== :graph

# Le nœud du knob focalisé dans le studio (0 pour un contrôle global).
function _studio_focus_node(st::WaveformPane)
    isempty(st.knobs) && return 0
    kb = st.knobs[clamp(st.focus, 1, length(st.knobs))]
    return kb.kind === :node ? kb.node_id : 0
end

# Rebâtit le graphe si le génome, sa version ou le focus ont changé.
function _synthdoc_graph_sync!(p::SynthDocPane)
    st = p.studio
    if st === nothing || st.genome === nothing
        key = (nothing,)
        p.graph_key == key && return
        TK.set_content!(p.graph, [_span_line("(pas de graphe : le studio attend un @synth analysable)", TK.tstyle(:text_dim))])
        p.graph_key = key; p.graph_ids = Int[]
        return
    end
    # le focus du studio prime quand il désigne un nœud
    sf = _studio_focus_node(st)
    sf != 0 && (p.graph_focus = sf)
    key = (objectid(st.genome), st.req_version, p.graph_focus, length(st.hints), length(st.impacts), p.graph_x)
    p.graph_key == key && return
    lines, ids = graph_lines(st.genome; focus = p.graph_focus, hints = st.hints, impacts = st.impacts)
    p.graph_ids = ids
    (p.graph_focus == 0 || !(p.graph_focus in ids)) && !isempty(ids) && (p.graph_focus = ids[1])
    if p.graph_x > 0
        lines = [_graph_shift(l, p.graph_x) for l in lines]
    end
    push!(lines, TK.Span[])
    push!(lines, _span_line("h/l nœud · Enter : le knob dans le studio · d retirer · [ ] défiler · ✂ = inaudible", TK.tstyle(:text_dim)))
    TK.set_content!(p.graph, lines)
    p.graph_key = key
    return
end

# Coupe `dx` colonnes à gauche d'une ligne de spans.
function _graph_shift(line::Vector{TK.Span}, dx::Int)
    out = TK.Span[]; skip = dx
    for sp in line
        n = length(sp.content)
        if skip >= n
            skip -= n; continue
        end
        push!(out, TK.Span(skip > 0 ? sp.content[nextind(sp.content, 0, skip + 1):end] : sp.content, sp.style))
        skip = 0
    end
    return out
end

# h / l : la boîte suivante / précédente ; le studio suit quand le nœud a un knob.
function _synthdoc_graph_move!(p::SynthDocPane, dir::Int)
    isempty(p.graph_ids) && return
    i = something(findfirst(==(p.graph_focus), p.graph_ids), 1)
    p.graph_focus = p.graph_ids[mod1(i + dir, length(p.graph_ids))]
    _synthdoc_point_studio!(p)
    return
end

function _synthdoc_point_studio!(p::SynthDocPane)
    st = p.studio
    st === nothing && return false
    k = findfirst(kb -> kb.kind === :node && kb.node_id == p.graph_focus, st.knobs)
    k === nothing && return false
    st.focus = k
    return true
end

# d : retire le nœud focalisé (bypass), comme dans le studio.
function _synthdoc_graph_delete!(p::SynthDocPane)
    st = p.studio
    (st === nothing || st.genome === nothing) && return
    _synthdoc_point_studio!(p) || return
    _sculpt_structural!(st, :delete)
    return
end

# Pose l'explication d'un synth (le studio l'a calculée).
function _synthdoc_set_explain!(p::SynthDocPane, lines::Vector{String})
    lines == p.explain_lines && return
    p.explain_lines = copy(lines)
    p.explain_w = 0
    _scroll_top!(p.explain)
    return
end

function _synthdoc_cycle!(p::SynthDocPane, delta::Int)
    i = findfirst(==(p.mode), _SYNTHDOC_MODES)
    i === nothing && (i = 1)
    p.mode = _SYNTHDOC_MODES[mod1(i + delta, length(_SYNTHDOC_MODES))]
end

_synthdoc_view(p::SynthDocPane) = p.mode === :doc ? p.doc.pane : p.mode === :explain ? p.explain : p.graph

function render!(p::SynthDocPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    tabs = join((m === p.mode ? "[$(_synthdoc_label(m))]" : _synthdoc_label(m) for m in _SYNTHDOC_MODES), " · ")
    head = "DOC ✦ ◂ $tabs ▸" * (p.mode === :doc && !isempty(p.doc.name) ? " · $(p.doc.name)" : "")
    _render_pane_block_simple!(rect, head, buf)
    inner = _inner_rect_simple(rect)
    (inner.height < 1 || inner.width < 4) && return
    w = max(8, inner.width - 1)
    if p.mode === :doc
        _doc_sync!(p.doc, w)
        TK.render(p.doc.pane, inner, buf)
    elseif p.mode === :graph
        _synthdoc_graph_sync!(p)
        TK.render(p.graph, inner, buf)
    else
        if p.explain_w != w
            lines = isempty(p.explain_lines) ?
                ["(pas d'explication : le studio attend un @synth analysable)"] : p.explain_lines
            TK.set_content!(p.explain, _explain_spans(lines, w))
            p.explain_w = w
        end
        TK.render(p.explain, inner, buf)
    end
    return
end

handle_key!(p::SynthDocPane, evt) = evt isa TK.KeyEvent && dispatch!(((:synthdoc, p),), evt)
handle_mouse!(p::SynthDocPane, evt) = evt isa TK.MouseEvent && TK.handle_mouse!(_synthdoc_view(p), evt)
pane_scope(::SynthDocPane) = :synthdoc
title(p::SynthDocPane) = "doc:" * _synthdoc_label(p.mode)
serialize(p::SynthDocPane) = Dict{String,Any}("mode" => String(p.mode), "name" => p.doc.name)
register_pane_kind!(:synthdoc, _synthdoc_pane_ctor)

scope!(:synthdoc, "Doc du synth (doc · explication · graphe)")
bind!(:synthdoc, "→", "onglet suivant (doc · explication · graphe)"; short = "onglet", group = :nav,
      action = p -> _synthdoc_cycle!(p, +1))
bind!(:synthdoc, "←", "onglet précédent"; group = :nav, hint = false,
      action = p -> _synthdoc_cycle!(p, -1))
bind!(:synthdoc, "l", "onglet suivant"; group = :nav, hint = false, when = _synthdoc_not_graph,
      action = p -> _synthdoc_cycle!(p, +1))
bind!(:synthdoc, "h", "onglet précédent"; group = :nav, hint = false, when = _synthdoc_not_graph,
      action = p -> _synthdoc_cycle!(p, -1))
bind!(:synthdoc, "l", "graphe : nœud suivant"; short = "nœud", group = :nav, when = _synthdoc_graph, repeat = true,
      action = p -> _synthdoc_graph_move!(p, +1))
bind!(:synthdoc, "h", "graphe : nœud précédent"; group = :nav, hint = false, when = _synthdoc_graph, repeat = true,
      action = p -> _synthdoc_graph_move!(p, -1))
bind!(:synthdoc, "Enter", "graphe : le knob de ce nœud dans le studio"; short = "studio", group = :nav, when = _synthdoc_graph,
      action = p -> (_synthdoc_point_studio!(p); _SYNTHDOC_REQUEST[] = :focus_studio))
bind!(:synthdoc, "d", "graphe : retirer le nœud (bypass)"; short = "retirer", group = :structure, when = _synthdoc_graph,
      action = p -> _synthdoc_graph_delete!(p))
bind!(:synthdoc, "]", "graphe : défiler →"; group = :view, hint = false, when = _synthdoc_graph, repeat = true,
      action = p -> (p.graph_x += 8))
bind!(:synthdoc, "[", "graphe : défiler ←"; group = :view, hint = false, when = _synthdoc_graph, repeat = true,
      action = p -> (p.graph_x = max(0, p.graph_x - 8)))
bind!(:synthdoc, ["j", "↓"], "défiler"; group = :nav, repeat = true,
      action = p -> _scroll!(_synthdoc_view(p), :down))
bind!(:synthdoc, ["k", "↑"], "remonter"; group = :nav, repeat = true,
      action = p -> _scroll!(_synthdoc_view(p), :up))
bind!(:synthdoc, "g", "haut"; group = :nav, hint = false, action = p -> _scroll_top!(_synthdoc_view(p)))
bind!(:synthdoc, "G", "bas"; group = :nav, hint = false, action = p -> _scroll_end!(_synthdoc_view(p)))
