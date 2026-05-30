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
    entry = lookup_doc(p.name)
    lines = if entry === nothing
        ["(no entry for '$(p.name)')"]
    else
        out = String[entry.name, "", entry.short, ""]
        isempty(entry.kwargs) || push!(out, "kwargs: " * join(entry.kwargs, ", "))
        if !isempty(entry.examples)
            push!(out, "", "examples:")
            for ex in entry.examples
                push!(out, "  " * ex)
            end
        end
        isempty(entry.body) || (push!(out, ""); append!(out, split(entry.body, '\n')))
        out
    end
    first_idx = clamp(1 + p.scroll, 1, max(1, length(lines)))
    for (offset, line) in enumerate(@view lines[first_idx:end])
        screen_y = inner.y + offset - 1
        screen_y >= inner.y + inner.height && break
        chunk = first(String(line), inner.width)
        TK.set_string!(buf, inner.x, screen_y, chunk, TK.tstyle(:text))
    end
    return nothing
end

function handle_key!(p::DocPane, evt)
    if evt isa TK.KeyEvent && evt.key === :char
        if evt.char == 'j'
            p.scroll += 1; return true
        elseif evt.char == 'k' && p.scroll > 0
            p.scroll -= 1; return true
        end
    end
    return false
end

title(p::DocPane) = isempty(p.name) ? "doc" : "doc:$(p.name)"

serialize(p::DocPane) = Dict{String,Any}("name" => p.name, "scroll" => p.scroll)

register_pane_kind!(:doc, _doc_pane_ctor)
