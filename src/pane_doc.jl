# src/pane_doc.jl
# :doc pane — renders a DocEntry from the extension registry.

mutable struct DocPane <: PaneImpl
    name::String              # the DocEntry name (registry key)
    pane::TK.ScrollPane       # la fiche rendue, son défilement, sa barre
    follow::Bool              # suit le mot sous le curseur (doc vivante)
    rendered::Tuple{String,Int,UInt64}   # (nom, largeur, en-tête) du contenu posé dans `pane`
    # Ce que la ligne @dN du curseur est en train de faire (app_slots.jl :
    # `_slot_summary`) — sous la fiche, dans sa bande LIGNE. Vide hors d'une ligne @dN.
    header::Vector{Tuple{String,Symbol}}
    # Tous les slots du texte et leur état (bande EN JEU) : (slot, état, coups par cycle).
    slots::Vector{Tuple{Symbol,Symbol,Int}}
end

DocPane(name::AbstractString, offset::Int = 0, follow::Bool = false) =
    DocPane(String(name), _scrollpane(; offset), follow, ("\0", 0, UInt64(0)), Tuple{String,Symbol}[],
            Tuple{Symbol,Symbol,Int}[])

function _doc_pane_ctor(args::AbstractDict)
    return DocPane(String(get(args, "ref", "")), Int(get(args, "scroll", 0)), get(args, "follow", false) == true)
end

# Une bande de titre à l'intérieur d'un texte défilant : une ligne pleine
# largeur sur le fond des bandes.
function _md_band(title::AbstractString, sub::AbstractString, width::Int)
    p = _ui()
    t = " " * String(title)
    st = isempty(sub) ? "" : "  " * String(sub)
    fill = max(0, width - textwidth(t) - textwidth(st))
    return TK.Span[TK.Span(t, TK.Style(fg = p.tx, bg = p.s2, bold = true)),
                   TK.Span(st * " "^fill, TK.Style(fg = p.d, bg = p.s2))]
end

# Pose dans le ScrollPane la fiche courante rendue à `width` colonnes,
# une fois par (nom, largeur) ; changer de fiche remonte en haut. Sous la
# fiche : la bande LIGNE (ce que fait la ligne @dN du curseur) puis la bande
# EN JEU (tous les slots, d'un coup d'œil).
function _doc_sync!(p::DocPane, width::Int)
    key = (p.name, width, hash((p.header, p.slots, _PLAYED_EPOCH[], TK.theme().name)))
    p.rendered == key && return
    p.rendered[1] == p.name || (p.pane.offset = 0)
    ui = _ui()
    lines = _MdLine[TK.Span[]]
    append!(lines, _doc_pane_lines(p.name, width))
    if !isempty(p.header)
        push!(lines, TK.Span[])
        push!(lines, _md_band("LIGNE", "", width))
        push!(lines, TK.Span[])
        for (text, sty) in p.header, l in _wrap_text(text, width - 1)
            push!(lines, _md_plain(" " * l, TK.tstyle(sty, bold = sty !== :text_dim)))
        end
    end
    if !isempty(p.slots)
        n = count(s -> s[2] === :playing, p.slots)
        push!(lines, TK.Span[])
        push!(lines, _md_band("EN JEU", "$n sur $(length(p.slots))", width))
        push!(lines, TK.Span[])
        set = _mark_set()
        for (slot, state, onsets) in p.slots
            color = state === :error ? ui.r : state === :muted ? ui.n : state === :playing ? ui.g :
                    state === :modified ? ui.g : ui.n
            mark = state === :error ? set.error : state === :muted ? set.rests[3] :
                   state === :modified ? set.modified : state === :playing ? set.notes[3] : ' '
            phrase = String(first(split(get(_STATE_PHRASES, state, String(state)), r" — | · ")))
            cadence = (state === :playing && onsets > 0) ? "$(onsets) coup$(onsets == 1 ? "" : "s")" : ""
            push!(lines, TK.Span[TK.Span(" " * string(mark) * " ", TK.Style(fg = color, bold = true)),
                                 TK.Span(rpad(String(slot), 5), TK.Style(fg = state === :playing ? ui.tx : color)),
                                 TK.Span(rpad(phrase, 22), TK.Style(fg = state === :playing ? ui.d : color)),
                                 TK.Span(cadence, TK.Style(fg = ui.n))])
        end
    end
    TK.set_content!(p.pane, lines)
    p.rendered = key
    return
end

function render!(p::DocPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    title_str = "FICHE" * (isempty(p.name) ? "" : " · $(p.name)") * (p.follow ? "" : " · figée")
    _render_pane_block_simple!(rect, title_str, buf)
    inner = _inner_rect_simple(rect)
    (inner.height < 1 || inner.width < 4) && return
    _doc_sync!(p, max(8, inner.width - 1))        # une colonne pour la barre
    TK.render(p.pane, inner, buf)
    return nothing
end

# Lignes écran de la fiche (segments stylés), repliées à `width`. Le
# corps est du markdown, les exemples sont colorés comme dans l'éditeur.
function _doc_pane_lines(name::String, width::Int)
    out = _MdLine[]
    # Un nom de son passe avant une fiche de fonction : dans un buffer de
    # patterns, `bd` est un son, pas un mot du vocabulaire.
    card = isempty(name) ? nothing : _sound_card(name, width)
    card === nothing || return [_md_plain(l, sty) for (l, sty) in card]
    entry = isempty(name) ? nothing : lookup_doc(name)
    if entry === nothing
        desc = isempty(name) ? nothing : _lookup_livedoc(name)
        if desc === nothing
            for l in _wrap_text(isempty(name) ? "K sur un mot, ou :doc <nom>, affiche sa fiche ici." :
                                "(aucune entrée pour « $name »)", width)
                push!(out, _md_plain(l, TK.tstyle(:text_dim)))
            end
        else
            push!(out, _md_plain(name, TK.tstyle(:accent, bold = true)))
            append!(out, _md_wrap(_md_inline(String(desc)), width))
        end
        return out
    end
    push!(out, _md_plain(entry.name, TK.tstyle(:accent, bold = true)))
    append!(out, _md_wrap(_md_inline(entry.short), width))
    isempty(entry.kwargs) || push!(out, _md_plain("kwargs : " * join(entry.kwargs, ", "), TK.tstyle(:text_dim)))
    if !isempty(entry.examples)
        push!(out, TK.Span[])
        push!(out, _md_plain("exemples", TK.tstyle(:title, bold = true)))
        for ex in entry.examples
            push!(out, vcat(_md_plain("  "), _md_code_line(ex, width - 2)))
        end
    end
    body = strip(entry.body)
    if !isempty(body) && body != strip(entry.short) && !endswith(body, strip(entry.short))
        push!(out, TK.Span[])
        body_lines = [String(l) for l in split(body, '\n') if !startswith(l, "# ")]   # le titre est déjà affiché
        append!(out, _md_render(body_lines, width))
    end
    # Les voisines, et parmi elles la première qu'on n'a jamais jouée.
    near = _doc_neighbours(entry)
    if !isempty(near)
        push!(out, TK.Span[])
        append!(out, _md_wrap([TK.Span("voisines  ", TK.tstyle(:text_dim)),
                               TK.Span(join(near, " · "), TK.tstyle(:accent))], width))
        fresh = _untried(near)
        fresh === nothing || push!(out, _md_plain("○ pas encore essayé : $fresh", TK.tstyle(:success)))
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
handle_mouse!(p::DocPane, evt::TK.MouseEvent) = TK.handle_mouse!(p.pane, evt)   # molette, barre
pane_scope(::DocPane) = :doc
scope!(:doc, "Documentation")
mixin_scroll_nav!(:doc, p -> p.pane; page_synonyms = true, hint = true)
bind!(:doc, "f", "suivre le curseur ou figer"; short = "suivre", group = :nav,
      action = p -> (p.follow = !p.follow))

title(p::DocPane) = isempty(p.name) ? "doc" : "doc:$(p.name)"

serialize(p::DocPane) = Dict{String,Any}("name" => p.name, "scroll" => p.pane.offset,
                                          "follow" => p.follow, "ref" => p.name)

register_pane_kind!(:doc, _doc_pane_ctor)
