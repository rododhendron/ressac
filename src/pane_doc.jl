# src/pane_doc.jl
# :doc pane — renders a DocEntry from the sub-project 7 registry.

mutable struct DocPane <: PaneImpl
    name::String              # the DocEntry name (registry key)
    scroll::Int
end

function _doc_pane_ctor(args::AbstractDict)
    return DocPane(String(get(args, "ref", "")), 0)
end

function render!(p::DocPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    title_str = isempty(p.name) ? "DOC" : "DOC · $(p.name)"
    _render_pane_block_simple!(rect, title_str, buf)
    inner = _inner_rect_simple(rect)
    inner.height < 1 && return
    lines = _doc_pane_lines(p.name, inner.width)
    first_idx = clamp(1 + p.scroll, 1, max(1, length(lines)))
    for (offset, (line, style)) in enumerate(@view lines[first_idx:end])
        screen_y = inner.y + offset - 1
        screen_y >= inner.y + inner.height && break
        TK.set_string!(buf, inner.x, screen_y, first(line, inner.width), style)
    end
    return nothing
end

# Lignes (texte, style) de la fiche, repliées à `width`.
function _doc_pane_lines(name::String, width::Int)
    out = Tuple{String,TK.Style}[]
    entry = isempty(name) ? nothing : lookup_doc(name)
    if entry === nothing
        desc = isempty(name) ? nothing : _lookup_livedoc(name)
        if desc === nothing
            for l in _wrap_text(isempty(name) ? "K sur un mot, ou :doc <nom>, affiche sa fiche ici." :
                                "(aucune entrée pour « $name »)", width)
                push!(out, (l, TK.tstyle(:text_dim)))
            end
        else
            push!(out, (name, TK.tstyle(:accent, bold = true)))
            for l in _wrap_text(String(desc), width); push!(out, (l, TK.tstyle(:text))); end
        end
        return out
    end
    push!(out, (entry.name, TK.tstyle(:accent, bold = true)))
    for l in _wrap_text(entry.short, width); push!(out, (l, TK.tstyle(:text))); end
    isempty(entry.kwargs) || push!(out, ("kwargs : " * join(entry.kwargs, ", "), TK.tstyle(:text_dim)))
    if !isempty(entry.examples)
        push!(out, ("", TK.tstyle(:text)))
        push!(out, ("exemples", TK.tstyle(:title, bold = true)))
        for ex in entry.examples
            for l in _wrap_text("  " * ex, width); push!(out, (l, TK.tstyle(:text_bright))); end
        end
    end
    body = strip(entry.body)
    if !isempty(body) && body != strip(entry.short) && !endswith(body, strip(entry.short))
        push!(out, ("", TK.tstyle(:text)))
        for raw in split(body, '\n')
            l = String(raw)
            startswith(l, "# ") && continue          # le titre est déjà affiché
            for w in _wrap_text(l, width); push!(out, (w, TK.tstyle(:text))); end
        end
    end
    return out
end

# Repli d'une ligne sur des mots, largeur `width` (≥ 1).
function _wrap_text(line::AbstractString, width::Int)
    width = max(1, width)
    words = split(line, ' '; keepempty = true)
    out = String[]
    cur = ""
    for w in words
        cand = isempty(cur) ? String(w) : cur * " " * w
        if textwidth(cand) <= width || isempty(cur)
            cur = cand
        else
            push!(out, cur); cur = String(w)
        end
    end
    push!(out, cur)
    return out
end

handle_key!(p::DocPane, evt) = evt isa TK.KeyEvent && dispatch!(((:doc, p),), evt)
pane_scope(::DocPane) = :doc
scope!(:doc, "Documentation")
bind!(:doc, ["j", "↓"], "descendre"; group = :nav, action = p -> (p.scroll += 1), repeat = true)
bind!(:doc, ["k", "↑"], "remonter"; group = :nav, when = p -> p.scroll > 0, repeat = true,
      action = p -> (p.scroll -= 1))

title(p::DocPane) = isempty(p.name) ? "doc" : "doc:$(p.name)"

serialize(p::DocPane) = Dict{String,Any}("name" => p.name, "scroll" => p.scroll)

register_pane_kind!(:doc, _doc_pane_ctor)
