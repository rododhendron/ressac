# src/pane_synthdoc.jl
# Pane DOC du workspace synth : deux onglets, `doc` (la fiche du mot sous
# le curseur, doc vivante) et `explication` (pourquoi le synth sonne
# comme ça, posée par la synchronisation du studio). ← → les font tourner.

mutable struct SynthDocPane <: PaneImpl
    mode::Symbol                  # :doc | :explain
    doc::DocPane                  # la fiche (suit le curseur)
    explain::TK.ScrollPane        # l'explication repliée, défilable
    explain_lines::Vector{String}
    explain_w::Int                # largeur pour laquelle `explain` est construit (0 = à refaire)
end

const _SYNTHDOC_MODES = (:doc, :explain)
_synthdoc_label(mode::Symbol) = mode === :doc ? "doc" : "explication"

function _synthdoc_pane_ctor(args::AbstractDict)
    mode = Symbol(String(get(args, "mode", "doc")))
    mode in _SYNTHDOC_MODES || (mode = :doc)
    return SynthDocPane(mode, DocPane(String(get(args, "name", "")), 0, true),
                        _scrollpane(), String[], 0)
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

_synthdoc_view(p::SynthDocPane) = p.mode === :doc ? p.doc.pane : p.explain

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

scope!(:synthdoc, "Doc du synth (doc · explication)")
bind!(:synthdoc, ["→", "l"], "onglet suivant (doc · explication)"; short = "onglet", group = :nav,
      action = p -> _synthdoc_cycle!(p, +1))
bind!(:synthdoc, ["←", "h"], "onglet précédent"; group = :nav, hint = false,
      action = p -> _synthdoc_cycle!(p, -1))
bind!(:synthdoc, ["j", "↓"], "défiler"; group = :nav, repeat = true,
      action = p -> _scroll!(_synthdoc_view(p), :down))
bind!(:synthdoc, ["k", "↑"], "remonter"; group = :nav, repeat = true,
      action = p -> _scroll!(_synthdoc_view(p), :up))
bind!(:synthdoc, "g", "haut"; group = :nav, hint = false, action = p -> _scroll_top!(_synthdoc_view(p)))
bind!(:synthdoc, "G", "bas"; group = :nav, hint = false, action = p -> _scroll_end!(_synthdoc_view(p)))
