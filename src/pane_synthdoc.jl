# src/pane_synthdoc.jl
# La DOC d'un son, sous son texte : trois vues que ← → font tourner.
#   doc          la fiche du mot sous le curseur (doc vivante)
#   explication  pourquoi le son sonne comme ça, étape par étape, et ce
#                qui ne s'y entend pas (élagage)
#   graphe       le son tel qu'il est câblé
# La pane porte le graphe du son (son « génome »), relu du texte à chaque
# fois qu'il change : explication et graphe en découlent.

mutable struct SynthDocPane <: PaneImpl
    mode::Symbol                  # :doc | :explain | :graph
    doc::DocPane                  # la fiche (suit le curseur)
    explain::TK.ScrollPane        # l'explication repliée, défilable
    explain_lines::Vector{String}
    explain_w::Int                # largeur pour laquelle `explain` est construit (0 = à refaire)
    graph::TK.ScrollPane          # le graphe (genome_graph_view.jl)
    graph_key::Any                # ce dont dépend le graphe posé dans `graph`
    graph_ids::Vector{Int}        # ids des boîtes dans l'ordre du dessin (h / l)
    graph_focus::Int              # nœud focalisé dans le graphe (0 = aucun)
    graph_x::Int                  # défilement horizontal du graphe
    # ── le son expliqué ────────────────────────────────────────────
    genome::Union{Nothing,Genome} # relu du texte (`nothing` : il ne se relit pas)
    version::Int                  # change à chaque relecture
    synced_hash::UInt             # le texte dont `genome` vient
    synced_name::String
    # ── élagage ────────────────────────────────────────────────────
    hints::Dict{Int,String}       # ce que la structure désigne, par nœud
    impacts::Dict{Int,Float64}    # l'impact mesuré par nœud (`P`), vidé quand le son change
    measuring::Bool               # une mesure est en vol
    prune_note::String            # pourquoi elle n'a pas abouti ("" sinon)
    lock::ReentrantLock
    closed::Bool
end

const _SYNTHDOC_MODES = (:doc, :explain, :graph)
_synthdoc_label(mode::Symbol) = mode === :doc ? "doc" : mode === :explain ? "explication" : "graphe"

function _synthdoc_pane_ctor(args::AbstractDict)
    # Un son s'ouvre sur son explication : ce qu'il fait, et sa chaîne.
    mode = Symbol(String(get(args, "mode", "explain")))
    mode in _SYNTHDOC_MODES || (mode = :explain)
    return SynthDocPane(mode, DocPane(String(get(args, "name", "")), 0, true),
                        _scrollpane(), String[], 0,
                        _scrollpane(), nothing, Int[], 0, 0,
                        nothing, 0, UInt(0), "",
                        Dict{Int,String}(), Dict{Int,Float64}(), false, "", ReentrantLock(), false)
end

on_close!(p::SynthDocPane) = (lock(() -> (p.closed = true), p.lock); nothing)

"""
    _synthdoc_set_genome!(p, g)

Le son a changé : nouveau graphe, les mesures d'impact d'avant ne valent
plus, l'explication est refaite.
"""
function _synthdoc_set_genome!(p::SynthDocPane, g::Union{Nothing,Genome})
    p.genome = g
    p.version += 1
    empty!(p.impacts); p.prune_note = ""
    _synthdoc_refresh_explain!(p)
    return
end

# L'explication du son courant, avec sa section « ÉLAGAGE ».
function _synthdoc_refresh_explain!(p::SynthDocPane)
    empty!(p.hints)
    if p.genome === nothing
        lines = String[]
    else
        for h in static_prune_hints(p.genome); p.hints[h.id] = "$(h.ugen) — $(h.reason)"; end
        lines = vcat(explain_genome(p.genome),
                     prune_report_lines(p.genome; impacts = p.impacts, measuring = p.measuring, note = p.prune_note))
    end
    lines == p.explain_lines && return
    p.explain_lines = lines
    p.explain_w = 0
    return
end

"""
    _synthdoc_measure_impacts!(p) -> Bool

`P` — rend le son sans chaque nœud, en un lot, et range ce que chacun
change. En fond (sclang hors-ligne prend des secondes) ; sur place en test.
"""
function _synthdoc_measure_impacts!(p::SynthDocPane)
    (p.genome === nothing || p.measuring) && return false
    p.measuring = true
    empty!(p.impacts); p.prune_note = ""
    _synthdoc_refresh_explain!(p)
    g = _copy_genome(p.genome)
    version = p.version
    work = () -> begin
        res = try measure_impacts(g) catch err; err end
        lock(p.lock) do
            (p.closed || p.version != version) && (p.measuring = false; return)   # le son a changé entre-temps
            p.measuring = false
            if res isa Exception
                p.prune_note = first(sprint(showerror, res), 60)
            else
                for r in res; p.impacts[r.id] = r.impact; end
            end
            _synthdoc_refresh_explain!(p)
        end
        return
    end
    _WAVE_SYNC[] ? work() : Threads.@spawn work()
    return true
end

"""
    _explain_spans(lines, width) -> Vector{Vector{Span}}

La prose de l'explainer mise en forme pour `width` colonnes : titres de
section en évidence, puces et flèches en accent avec retrait suspendu,
tout replié plutôt que rogné.
"""
function _explain_spans(lines::Vector{String}, width::Int)
    out = Vector{TK.Span}[]
    for line in lines
        t = rstrip(line)
        if isempty(t)
            push!(out, TK.Span[])
        elseif !startswith(t, " ") && !any(islowercase, t)
            append!(out, _md_wrap(TK.Span[TK.Span(t, TK.tstyle(:title, bold = true))], width))
        elseif (m = match(r"^(\s*)(•|←|→|↳)\s*(.*)$", t)) !== nothing
            pre = m.captures[1] * m.captures[2] * " "
            body = String(m.captures[3])
            spans = TK.Span[TK.Span(pre, TK.tstyle(:accent, bold = true))]
            # « [rôle] Nom — description » : le rôle et le nom ressortent
            if (r = match(r"^(\[[^\]]+\])\s*([^—]+?)(\s+—\s+.*)?$", body)) !== nothing
                push!(spans, TK.Span(r.captures[1] * " ", TK.tstyle(:secondary, bold = true)))
                push!(spans, TK.Span(r.captures[2], TK.tstyle(:text_bright, bold = true)))
                r.captures[3] === nothing || push!(spans, TK.Span(r.captures[3], TK.tstyle(:text)))
            else
                push!(spans, TK.Span(body, TK.tstyle(:text)))
            end
            append!(out, _md_wrap(spans, width; indent = textwidth(pre)))
        elseif startswith(t, "  ") && occursin("→", t)
            append!(out, _md_wrap(TK.Span[TK.Span(t, TK.tstyle(:text_bright))], width; indent = 2))
        else
            ind = length(t) - length(lstrip(t))
            append!(out, _md_wrap(TK.Span[TK.Span(t, TK.tstyle(:text))], width; indent = ind))
        end
    end
    return out
end

"""
    chain_table_spans(g, width; hints, impacts) -> Vector{Vector{Span}}

La chaîne du son en tableau, un maillon par ligne dans l'ordre du signal :
son numéro, son nom (un modulateur est en retrait, avec le réglage qu'il
anime), ses réglages, et — une fois mesuré (`P`) — une jauge de ce qu'il
change à l'oreille. `✂` marque ce qui ne s'entend pas.
"""
function chain_table_spans(g::Genome, width::Int; hints = Dict{Int,String}(), impacts = Dict{Int,Float64}())
    ui = _ui()
    boxes = graph_boxes(g; hints = hints, impacts = impacts)
    out = Vector{TK.Span}[]
    measured = !isempty(impacts)
    push!(out, _md_band("CHAÎNE", "$(length(boxes)) maillon$(length(boxes) == 1 ? "" : "s")" *
                                  (measured ? " · mesurée" : " · P mesure"), width))
    push!(out, TK.Span[])
    isempty(boxes) && return out
    namew = clamp(maximum(textwidth(replace(b.label, " ✂" => "")) + 2 * b.depth + (isempty(b.edge) ? 0 : textwidth(b.edge) + 2) for b in boxes), 8, 26)
    subw = clamp(maximum(textwidth(b.sub) for b in boxes), 8, 16)
    push!(out, TK.Span[TK.Span("    #  " * rpad("MAILLON", namew + 2) * rpad("RÉGLAGE", subw + 2) * (measured ? "CE QU'IL CHANGE" : ""),
                               TK.Style(fg = ui.n))])
    for b in boxes
        imp = get(impacts, b.id, nothing)
        dead = haskey(hints, b.id) || (imp !== nothing && imp < 0.02)
        name = replace(b.label, " ✂" => "")
        label = "  "^b.depth * (b.depth > 0 ? "└ " : "") * name * (isempty(b.edge) ? "" : " →" * b.edge)
        label = textwidth(label) > namew + 2 ? first(label, namew + 1) * "…" : label
        line = TK.Span[TK.Span(dead ? "  ✂ " : "    ", TK.Style(fg = ui.r)),
                       TK.Span(rpad(string(b.id), 3), TK.Style(fg = ui.n)),
                       TK.Span(rpad(label, namew + 2), TK.Style(fg = dead ? ui.n : b.depth == 0 ? ui.tx : ui.d, bold = b.depth == 0 && !dead)),
                       TK.Span(rpad(b.sub, subw + 2), TK.Style(fg = ui.y))]
        if imp !== nothing
            k = clamp(round(Int, imp * 10), 0, 10)
            (k == 0 && imp >= 0.02) && (k = 1)
            push!(line, TK.Span("▮"^k, TK.Style(fg = dead ? ui.n : ui.d)))
            push!(line, TK.Span("▮"^(10 - k), TK.Style(fg = ui.x)))
            push!(line, TK.Span("  " * string(round(imp; digits = 3)), TK.Style(fg = dead ? ui.r : ui.tx)))
            dead && push!(line, TK.Span("  inaudible", TK.Style(fg = ui.r)))
        elseif haskey(hints, b.id)
            push!(line, TK.Span(last(split(hints[b.id], " — "; limit = 2)), TK.Style(fg = ui.r)))
        end
        push!(out, line)
    end
    push!(out, TK.Span[])
    return out
end

# ── Le graphe ────────────────────────────────────────────────────────
_synthdoc_graph(p::SynthDocPane) = p.mode === :graph
_synthdoc_not_graph(p::SynthDocPane) = p.mode !== :graph

# Rebâtit le graphe si le son, les mesures ou le focus ont changé.
function _synthdoc_graph_sync!(p::SynthDocPane)
    if p.genome === nothing
        key = (nothing,)
        p.graph_key == key && return
        TK.set_content!(p.graph, [_span_line("(pas de graphe : le texte ne se relit pas en @synth)", TK.tstyle(:text_dim))])
        p.graph_key = key; p.graph_ids = Int[]
        return
    end
    key = (p.version, p.graph_focus, length(p.hints), length(p.impacts), p.graph_x)
    p.graph_key == key && return
    lines, ids = graph_lines(p.genome; focus = p.graph_focus, hints = p.hints, impacts = p.impacts)
    p.graph_ids = ids
    (p.graph_focus == 0 || !(p.graph_focus in ids)) && !isempty(ids) && (p.graph_focus = ids[1])
    if p.graph_x > 0
        lines = [_graph_shift(l, p.graph_x) for l in lines]
    end
    push!(lines, TK.Span[])
    push!(lines, _span_line("h / l nœud · [ ] défiler · ✂ = ne s'entend pas", TK.tstyle(:text_dim)))
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

# h / l : la boîte suivante / précédente.
function _synthdoc_graph_move!(p::SynthDocPane, dir::Int)
    isempty(p.graph_ids) && return
    i = something(findfirst(==(p.graph_focus), p.graph_ids), 1)
    p.graph_focus = p.graph_ids[mod1(i + dir, length(p.graph_ids))]
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
    # La bande de titre porte les trois vues en onglets : celle qu'on
    # regarde en orange souligné (← → pour en changer).
    _render_pane_block_simple!(rect, "DOC", buf)
    ui = _ui()
    x = rect.x + 6
    for mode in _SYNTHDOC_MODES
        lab = _synthdoc_label(mode)
        x + textwidth(lab) >= rect.x + rect.width && break
        on = mode === p.mode
        TK.set_string!(buf, x, rect.y, lab, TK.Style(fg = on ? ui.o : ui.d, bg = ui.s2, bold = on, underline = on))
        x += textwidth(lab) + 3
    end
    if p.mode === :doc && !isempty(p.doc.name) && x + textwidth(p.doc.name) + 3 < rect.x + rect.width
        TK.set_string!(buf, x, rect.y, "· " * p.doc.name, TK.Style(fg = ui.b, bg = ui.s2))
    end
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
                ["(pas d'explication : le texte ne se relit pas en @synth)"] : p.explain_lines
            table = p.genome === nothing ? Vector{TK.Span}[] :
                    chain_table_spans(p.genome, w; hints = p.hints, impacts = p.impacts)
            TK.set_content!(p.explain, vcat(table, _explain_spans(lines, w)))
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

scope!(:synthdoc, "Doc du synth (doc · explication · graphe)"; layer = :pane, modes = (:design,))
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
bind!(:synthdoc, "]", "graphe : défiler →"; group = :view, hint = false, when = _synthdoc_graph, repeat = true,
      action = p -> (p.graph_x += 8))
bind!(:synthdoc, "[", "graphe : défiler ←"; group = :view, hint = false, when = _synthdoc_graph, repeat = true,
      action = p -> (p.graph_x = max(0, p.graph_x - 8)))
mixin_scroll_nav!(:synthdoc, _synthdoc_view; hint = true, labels = (down = "défiler", up = "remonter"),
                  up_when = _always, end_action = p -> _scroll_end!(_synthdoc_view(p)))
