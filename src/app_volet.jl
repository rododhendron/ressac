# src/app_volet.jl
# L'écran unique. Les patterns sont à gauche et y restent ; à droite, un
# VOLET qu'on échange :
#
#   :fiche     la doc vivante, qui suit le curseur (par défaut)
#   :wiki      le wiki, à côté du travail
#   :son       la DOC du son du curseur (fiche · explication · graphe)
#   :explorer  l'explorateur génétique, par-dessus (zoomé)
#
# Un volet déjà ouvert est gardé quand on en ouvre un autre : passer au wiki
# ne perd pas l'endroit où on lisait. L'arbre de panes
# (scissions, tailles, zoom) reste celui du gestionnaire de workspaces — on
# n'en utilise qu'un.

const _VOLET_KINDS = (:fiche, :wiki, :son, :explorer)

# La part de la largeur que prend chaque volet.
const _VOLET_SHARE = Dict{Symbol,Float64}(:fiche => 0.42, :wiki => 0.40, :son => 0.42, :explorer => 0.50)

# À partir de cette largeur, le son s'ouvre ENTRE les patterns et la fiche
# au lieu de la remplacer.
const _VOLET_WIDE_COLS = 200

_new_leaf!(wm::WorkspaceManager, panes::PaneImpl...) =
    (l = PaneLeaf(wm.next_pane_id, PaneImpl[panes...], 1); wm.next_pane_id += 1; l)

# Le contenu d'un volet, construit à sa première ouverture.
function _build_volet(m::RessacApp, kind::Symbol)
    wm = m.workspaces
    if kind === :wiki
        return _new_leaf!(wm, _pane_new(:wiki, Dict{String,Any}()))
    elseif kind === :explorer
        return _new_leaf!(wm, _pane_new(:explorer, Dict{String,Any}()))
    elseif kind === :son
        # La DOC du son (fiche · explication · graphe) ; la MODULATION d'un
        # drone s'y range en onglet quand on tient le son. Le texte du son,
        # lui, est dans le texte principal.
        return _new_leaf!(wm, _pane_new(:synthdoc, Dict{String,Any}()))
    end
    return _new_leaf!(wm, _pane_new(:doc, Dict{String,Any}("follow" => true)))
end

_volet_node(m::RessacApp, kind::Symbol) = get!(() -> _build_volet(m, kind), m.volets, kind)

"""
    _drain_wiki_pose!(m) -> Bool

Un exemple du wiki (`Entrée` dessus) est posé au bout des patterns, sur le
premier slot libre. Il n'est pas lancé : `e` le fait, d'où qu'on soit.
"""
function _drain_wiki_pose!(m::RessacApp)
    ex = _WIKI_POSE_REQUEST[]
    ex === nothing && return false
    _WIKI_POSE_REQUEST[] = nothing
    ed = _patterns_editor(m)
    ed === nothing && return true
    slot = "d$(_next_free_slot(ed))"
    text = replace(ex, r"^(\s*)@d\d+" => SubstitutionString("\\1@" * slot); count = 1)
    lines = [String(l) for l in ed.lines]
    while !isempty(lines) && isempty(strip(lines[end])); pop!(lines); end
    isempty(lines) || push!(lines, "")
    row = length(lines) + 1
    append!(lines, split(text, '\n'))
    _edit_text!(ed, join(lines, '\n'); row = row, col = 0)
    _push_app_log!(m, "[INFO] exemple posé sur $slot, au bout des patterns — e le lance (u dans les patterns l'enlève)")
    return true
end

# La feuille qui porte le texte des patterns.
function _patterns_leaf(ws::Workspace)
    for leaf in _all_leaves(ws.tree), tab in leaf.tabs
        tab isa EditorPane && any(b -> b.role === :patterns, tab.tabs) && return leaf
    end
    return nothing
end

_screen_is_wide(m::RessacApp) = m._last_ws_area !== nothing && m._last_ws_area.w >= _VOLET_WIDE_COLS

# Remplace `old` par `new` dans l'arbre ; rend la nouvelle racine, ou
# `nothing` si `old` n'y est pas.
function _swap_node(root::LayoutNode, old::LayoutNode, new::LayoutNode)
    root === old && return new
    root isa Container || return nothing
    for (i, child) in enumerate(root.children)
        r = _swap_node(child, old, new)
        r === nothing && continue
        root.children[i] = r
        return root
    end
    return nothing
end

"""
    _open_volet!(m, kind; focus = true) -> Bool

Met le volet `kind` à droite des patterns. `focus` y amène le clavier (la
fiche, elle, ne le prend pas : elle accompagne). Le reste de l'arbre — une
pane que le joueur a scindée à côté — n'est pas touché.
"""
function _open_volet!(m::RessacApp, kind::Symbol; focus::Bool = true)
    kind in _VOLET_KINDS || return false
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    pl = _patterns_leaf(ws)
    pl === nothing && return false
    node = _volet_node(m, kind)
    shown = node
    share = _VOLET_SHARE[kind]
    if kind === :son && _screen_is_wide(m)
        shown = Container(:h, LayoutNode[node, _volet_node(m, :fiche)], [0.58, 0.42])
        share = 0.64
    end
    swapped = m.volet_shown === nothing ? nothing : _swap_node(ws.tree, m.volet_shown, shown)
    if swapped === nothing
        ws.tree = Container(:h, LayoutNode[pl, shown], [1 - share, share])
    else
        ws.tree = swapped
        root = ws.tree
        (root isa Container && length(root.children) == 2 && root.children[2] === shown) &&
            (root.ratios = [1 - share, share])
    end
    m.volet = kind
    m.volet_shown = shown
    main = _first_leaf_id(node)
    m.zoom_leaf = kind === :explorer ? main : 0
    ws.focused_pane = (focus && kind !== :fiche) ? main : pl.id
    return true
end

"""
    _close_volet!(m)

Rend la colonne de droite à la fiche et le clavier aux patterns.
"""
_close_volet!(m::RessacApp) = _open_volet!(m, :fiche; focus = false)

# Le clavier aux patterns, sans rien changer à l'écran.
function _focus_patterns!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    pl = _patterns_leaf(ws)
    pl === nothing && return false
    ws.focused_pane = pl.id
    m.zoom_leaf == 0 || (m.zoom_leaf = 0)
    return true
end

# Le focus est-il dans le volet (et pas dans les patterns) ?
function _focus_in_volet(m::RessacApp)
    ws = current_workspace(m.workspaces)
    (ws === nothing || m.volet_shown === nothing) && return false
    return any(l -> l.id == ws.focused_pane, _all_leaves(m.volet_shown))
end

# La fiche n'a pas besoin d'un tiers de l'écran : elle prend la largeur d'une
# colonne de lecture, et laisse le reste au texte et à la grille du cycle.
# Sans effet dès que le joueur a redimensionné lui-même.
const _FICHE_COLS = 62
const _FICHE_AUTO = Ref(0.0)

function _fiche_fit_width!(m::RessacApp)
    (m.volet === :fiche && m._last_ws_area !== nothing) || return
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    root = ws.tree
    (root isa Container && length(root.children) == 2 && root.children[2] === m.volet_shown) || return
    cur = root.ratios[2]
    (isapprox(cur, _VOLET_SHARE[:fiche]; atol = 1e-6) || isapprox(cur, _FICHE_AUTO[]; atol = 1e-6)) || return
    want = clamp(_FICHE_COLS / max(m._last_ws_area.w, 1), 0.2, _VOLET_SHARE[:fiche])
    root.ratios = [1 - want, want]
    _FICHE_AUTO[] = want
    return
end

# Quand la fenêtre passe la largeur seuil, le son gagne ou perd sa colonne.
function _volet_follow_width!(m::RessacApp)
    m.volet === :son || return
    wide_now = m.volet_shown !== get(m.volets, :son, nothing)
    wide_now == _screen_is_wide(m) && return
    ws = current_workspace(m.workspaces)
    keep = ws === nothing ? 0 : ws.focused_pane
    _open_volet!(m, :son; focus = false)
    (ws !== nothing && _leaf_by_id(ws.tree, keep) !== nothing) && (ws.focused_pane = keep)
    return
end

# ── L'écran de départ ────────────────────────────────────────────────

"""
    _build_screen!(m; patterns = _STARTER_BUFFER)

L'écran à neuf : le texte des patterns à gauche, la fiche à droite.
"""
function _build_screen!(m::RessacApp; patterns::AbstractString = _STARTER_BUFFER)
    wm = m.workspaces
    empty!(wm.workspaces)
    create_workspace!(wm, "")
    wm.current_idx = 1
    ws = current_workspace(wm)
    ep = _pane_new(:editor, Dict{String,Any}())
    _load_text!(ep.tabs[1].code_editor, patterns)
    leaf = ws.tree
    push!(leaf.tabs, ep)
    leaf.current_tab = 1
    ws.focused_pane = leaf.id
    empty!(ws.floats)
    empty!(m.volets)
    m.volet_shown = nothing
    m.zoom_leaf = 0
    _open_volet!(m, :fiche; focus = false)
    _session_mark_saved!(m)          # un écran neuf n'a rien à sauver
    return ws
end

"""
    _ensure_default_workspace!(m)

Fait en sorte que l'écran existe et ait sa forme : un seul workspace, les
patterns, un volet. Une disposition d'avant l'écran unique (plusieurs
workspaces, une pane d'édition de son) est reprise pour ce qu'elle
contient — le texte des patterns — pas pour sa forme. Idempotent.
"""
function _ensure_default_workspace!(m::RessacApp)
    _APP_LOG[] = m.logs
    wm = m.workspaces
    ws = current_workspace(wm)
    if ws !== nothing && length(wm.workspaces) == 1 && _patterns_leaf(ws) !== nothing && !_has_legacy_sound_pane(ws)
        m.volet_shown === nothing && _adopt_volet!(m, ws)
        return
    end
    # Rien encore, ou une forme qu'on ne reconnaît pas : on rebâtit, en
    # gardant ce qui a été écrit.
    patterns = nothing
    for w in wm.workspaces, leaf in _all_leaves(w.tree), tab in leaf.tabs
        tab isa EditorPane || continue
        for b in tab.tabs
            (b.role === :patterns && patterns === nothing) && (patterns = TK.text(b.code_editor))
        end
    end
    _build_screen!(m; patterns = something(patterns, _STARTER_BUFFER))
    return
end

# Une disposition d'avant « un son vit dans le texte » : une pane d'édition
# de son à côté des patterns. On ne la reprend pas (l'écran est rebâti).
_has_legacy_sound_pane(ws::Workspace) =
    any(tab isa EditorPane && any(b -> b.role !== :patterns, tab.tabs)
        for leaf in _all_leaves(ws.tree) for tab in leaf.tabs)

# Un écran restauré depuis un fichier a déjà son volet dans l'arbre : on le
# reconnaît à ce qu'il contient, pour pouvoir l'échanger ensuite.
function _adopt_volet!(m::RessacApp, ws::Workspace)
    root = ws.tree
    if root isa Container && length(root.children) == 2 && _patterns_leaf(ws) === root.children[1]
        node = root.children[2]
        kind = _volet_kind_of(node)
        if kind !== nothing
            m.volets[kind] = node
            m.volet = kind
            m.volet_shown = node
            return
        end
    end
    _open_volet!(m, :fiche; focus = false)
    return
end

function _volet_kind_of(node::LayoutNode)
    panes = PaneImpl[t for l in _all_leaves(node) for t in l.tabs]
    any(p -> p isa SynthExplorerPane, panes) && return :explorer
    any(p -> p isa SynthDocPane, panes) && return :son
    any(p -> p isa WikiPane, panes) && return :wiki
    any(p -> p isa DocPane, panes) && return :fiche
    return nothing
end

"""
    _reset_screen!(m)

`:reset` — l'écran refait à neuf autour du texte des patterns, qui est
gardé. Les sons ouverts et les panes scindées à côté sont fermés.
"""
function _reset_screen!(m::RessacApp)
    ed = _patterns_editor(m)
    text = ed === nothing ? _STARTER_BUFFER : TK.text(ed)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        for leaf in _all_leaves(ws.tree), tab in leaf.tabs
            tab isa EditorPane && any(b -> b.role === :patterns, tab.tabs) && continue
            try; on_close!(tab); catch; end
        end
    end
    _build_screen!(m; patterns = text)
    _push_app_log!(m, "[INFO] écran remis à neuf")
    return true
end

"""
    _close_focused_pane!(m) -> Bool

Ferme la pane qui a le clavier — sauf les patterns, qui ne se ferment pas :
c'est l'instrument. Dans un volet, c'est le volet qui se ferme (la fiche
revient). Une pane scindée à côté par le joueur se ferme comme avant.
"""
function _close_focused_pane!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    pl = _patterns_leaf(ws)
    if pl !== nothing && ws.focused_pane == pl.id
        _push_app_log!(m, "[INFO] les patterns restent à l'écran — :qa quitte Ressac")
        return false
    end
    if _focus_in_volet(m)
        m.volet === :fiche ? _focus_patterns!(m) : _close_volet!(m)
        return true
    end
    cmd_close!(m.workspaces)
    m.zoom_leaf = 0
    return true
end
