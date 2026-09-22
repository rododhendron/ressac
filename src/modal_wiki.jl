# Wiki — ouverture de la pane wiki (src/pane_wiki.jl). Les pages vivent
# dans docs/wiki/*.md et sont rechargées à chaque ouverture, pour qu'une
# édition d'un .md pendant que Ressac tourne se voie au prochain :wiki.

"""
    _open_wiki!(m; page = "")

Ouvre (ou focalise) la pane wiki du workspace courant, à côté des
patterns, et va à `page` (numéro ou morceau de titre) si donnée.
"""
function _open_wiki!(m::RessacApp; page::AbstractString = "")
    pane = _find_pane(m, WikiPane)
    created = pane === nothing
    if created
        pane = _place_pane!(m, :wiki, Dict{String,Any}())
        pane isa WikiPane || return
        _focus_pane!(m, pane)
    else
        _focus_pane!(m, pane)
        pane.pages = _load_wiki_pages()
        pane.idx = clamp(pane.idx, 1, max(1, length(pane.pages)))
    end
    if isempty(pane.pages)
        _push_app_log!(m, "[WARN] :wiki — aucune page dans docs/wiki/")
        return
    end
    created && _push_app_log!(m, "[INFO] wiki — n/p page suivante/précédente · j/k défiler · Ctrl-w z zoom · :q ferme la pane")
    if !isempty(page) && !_wiki_goto!(pane, page)
        _push_app_log!(m, "[WARN] :wiki — pas de page « $page » (numéro ou mot du titre)")
    end
end

"""
    _find_pane(m, T) -> Union{Nothing,T}

Première pane du type `T` dans le workspace courant.
"""
function _find_pane(m::RessacApp, ::Type{T}) where {T<:PaneImpl}
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    for leaf in _all_leaves(ws.tree), tab in leaf.tabs
        tab isa T && return tab
    end
    return nothing
end

# Focalise le leaf qui contient `pane` (et son onglet).
function _focus_pane!(m::RessacApp, pane::PaneImpl)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    for leaf in _all_leaves(ws.tree)
        i = findfirst(t -> t === pane, leaf.tabs)
        i === nothing && continue
        leaf.current_tab = i
        ws.focused_pane = leaf.id
        return true
    end
    return false
end
