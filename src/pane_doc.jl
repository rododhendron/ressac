# src/pane_doc.jl
# :doc pane — renders a DocEntry from the sub-project 7 registry.

mutable struct DocPane <: PaneImpl
    name::String              # the DocEntry name (registry key)
    scroll::Int
    follow::Bool              # suit le mot sous le curseur (doc vivante)
end

function _doc_pane_ctor(args::AbstractDict)
    return DocPane(String(get(args, "ref", "")), 0, get(args, "follow", false) == true)
end

function render!(p::DocPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    title_str = (p.follow ? "DOC ✦" : "DOC") * (isempty(p.name) ? "" : " · $(p.name)")
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
    # Un nom de son passe avant une fiche de fonction : dans un buffer de
    # patterns, `bd` est un son, pas un mot du vocabulaire.
    card = isempty(name) ? nothing : _sound_card(name, width)
    card === nothing || return card
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

"""
    _sound_card(name, width) -> Union{Nothing,Vector}

La fiche d'un son : ce qu'il est, ses paramètres, et sa source quand on
l'a (le DSL de préférence). `nothing` si le nom n'est pas un son connu.
"""
function _sound_card(name::AbstractString, width::Int)
    sym = Symbol(name)
    inst = instrument_info(sym)
    smp  = sample_info(sym)
    syn  = synth_info(sym)
    (inst === nothing && smp === nothing && syn === nothing) && return nothing
    out = Tuple{String,TK.Style}[]
    kind = inst !== nothing ? "instrument" : smp !== nothing ? "sample" : "synth"
    push!(out, (String(name) * "   [" * kind * "]", TK.tstyle(:accent, bold = true)))
    meta = inst !== nothing ? inst.metadata : smp !== nothing ? smp.metadata : syn.metadata
    desc = String(get(meta, "description", ""))
    isempty(desc) || for l in _wrap_text(desc, width); push!(out, (l, TK.tstyle(:text))); end
    tags = get(meta, "tags", String[])
    isempty(tags) || push!(out, ("[" * join(String.(tags), ", ") * "]", TK.tstyle(:text_dim)))
    if smp !== nothing
        push!(out, ("$(length(smp.variants)) variante$(length(smp.variants) == 1 ? "" : "s") · $(smp.plugin)",
                    TK.tstyle(:text_dim)))
        push!(out, ("", TK.tstyle(:text)))
        push!(out, ("@d1 \"$(name)*4\"", TK.tstyle(:text_bright)))
        length(smp.variants) > 1 &&
            push!(out, ("@d1 :$(name) |> n(\"0 .. $(length(smp.variants) - 1)\")", TK.tstyle(:text_bright)))
    elseif inst !== nothing
        push!(out, ("préréglage · $(inst.plugin)", TK.tstyle(:text_dim)))
        for (k, v) in inst.params
            push!(out, ("  $k = $v", TK.tstyle(:text)))
        end
        push!(out, ("", TK.tstyle(:text)))
        push!(out, ("@d1 :$(name)", TK.tstyle(:text_bright)))
    else
        params = _user_synth_params(sym)
        isempty(params) ||
            push!(out, ("params : " * join(("$k=$v" for (k, v) in sort!(collect(params); by = first)), " · "),
                        TK.tstyle(:text_dim)))
        push!(out, ("", TK.tstyle(:text)))
        push!(out, ("@d1 :$(name) |> n(\"0 3 7\")", TK.tstyle(:text_bright)))
        src = _sound_source(name)
        if src !== nothing
            push!(out, ("", TK.tstyle(:text)))
            push!(out, ("source", TK.tstyle(:title, bold = true)))
            for l in split(src, '\n')
                startswith(strip(l), "#") && continue
                isempty(strip(l)) && continue
                for w in _wrap_text(String(l), width); push!(out, (w, TK.tstyle(:text))); end
            end
        end
    end
    return out
end

# La source d'un synth : le fichier de l'utilisateur d'abord (c'est ce
# qu'il a sous la main), sinon la recette de la librairie. Pas de
# parcours de répertoire : on vise les deux chemins possibles.
function _sound_source(name::AbstractString)
    for mode in (:dsl, :sc)
        path = _app_synth_path(name; mode = mode)
        isfile(path) && return try read(path, String) catch; nothing end
    end
    for e in _SYNTH_LIBRARY
        e.name == String(name) && return e.source
    end
    return nothing
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
bind!(:doc, ["d", "PgDn"], "page suivante"; group = :nav, hint = false, repeat = true,
      action = p -> (p.scroll += 15))
bind!(:doc, ["u", "PgUp"], "page précédente"; group = :nav, hint = false, repeat = true,
      when = p -> p.scroll > 0, action = p -> (p.scroll = max(0, p.scroll - 15)))
bind!(:doc, "g", "début"; group = :nav, hint = false, action = p -> (p.scroll = 0))
bind!(:doc, "f", "suivre le curseur ou figer"; short = "suivre", group = :nav,
      action = p -> (p.follow = !p.follow))

title(p::DocPane) = isempty(p.name) ? "doc" : "doc:$(p.name)"

serialize(p::DocPane) = Dict{String,Any}("name" => p.name, "scroll" => p.scroll,
                                          "follow" => p.follow, "ref" => p.name)

register_pane_kind!(:doc, _doc_pane_ctor)
