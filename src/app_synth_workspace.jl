# src/app_synth_workspace.jl
# Le workspace synth (DESIGN) a une forme fixe : le texte à gauche sur
# toute la hauteur, le STUDIO en haut à droite, la DOC (doc · explication)
# en bas à droite. Un seul son derrière les trois panes : le studio se
# reconstruit depuis le texte (dès qu'il change, hors frappe), et ce
# qu'on tire dans le studio revient dans le texte — le nombre sur place
# quand il s'y retrouve, la forme canonique sinon. Ouvrir un autre synth
# ajoute un onglet au texte, les deux autres panes suivent.

"""
    _synth_workspace_panes!(ws, wm)

Pose le studio et la doc à droite de la pane texte (racine = un leaf).
"""
function _synth_workspace_panes!(ws::Workspace, wm)
    wm === nothing && return
    root = ws.tree
    root isa PaneLeaf || return
    studio = PaneLeaf(wm.next_pane_id,
                      PaneImpl[_pane_new(:waveform, Dict{String,Any}("label" => "sketch", "sculpt" => true, "linked" => true))], 1)
    wm.next_pane_id += 1
    doc = PaneLeaf(wm.next_pane_id, PaneImpl[_pane_new(:synthdoc, Dict{String,Any}())], 1)
    wm.next_pane_id += 1
    side = Container(:v, LayoutNode[studio, doc], [0.55, 0.45])
    ws.tree = Container(:h, LayoutNode[root, side], [0.5, 0.5])
    ws.focused_pane = root.id
    return
end

"""
    _synth_workspace_parts(m) -> (editor, studio, doc) | nothing

Les trois panes du workspace synth courant : l'éditeur qui porte les
synths, le studio lié, la doc (peut manquer si fermée). `nothing` sans
éditeur de synth ou sans studio lié.
"""
function _synth_workspace_parts(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    ep = nothing; studio = nothing; sdoc = nothing
    for leaf in _all_leaves(ws.tree), tab in leaf.tabs
        if tab isa EditorPane && ep === nothing && any(b -> b.role === :synth, tab.tabs)
            ep = tab
        elseif tab isa WaveformPane && tab.linked && studio === nothing
            studio = tab
        elseif tab isa SynthDocPane && sdoc === nothing
            sdoc = tab
        end
    end
    (ep === nothing || studio === nothing) && return nothing
    return (ep, studio, sdoc)
end

# Le synth courant de la pane texte du workspace (onglet courant).
function _synth_workspace_tab(ep::EditorPane)
    1 <= ep.current_tab <= length(ep.tabs) || return nothing
    tab = ep.tabs[ep.current_tab]
    tab.role === :synth ? tab : nothing
end

"""
    _synth_workspace_sync!(m)

Appelée à chaque rendu : d'abord le studio vers le texte (un knob tiré,
une structure changée), puis le texte vers le studio quand il a changé
et qu'on n'est pas en train de taper.
"""
function _synth_workspace_sync!(m::RessacApp)
    parts = _synth_workspace_parts(m)
    parts === nothing && return
    (ep, studio, sdoc) = parts
    sdoc === nothing || (sdoc.studio = studio)
    tab = _synth_workspace_tab(ep)
    tab === nothing && return
    ed = tab.code_editor
    if studio.genome !== nothing && studio.req_version != studio.synced_req &&
       tab.name == studio.synced_name
        _studio_to_text!(m, studio, tab)
    end
    ed.mode === :normal || return
    text = TK.text(ed)
    h = hash(text)
    (h == studio.synced_hash && tab.name == studio.synced_name) && return
    _text_to_studio!(studio, sdoc, tab, text, h)
    return
end

function _text_to_studio!(studio::WaveformPane, sdoc, tab::EditorBuffer, text::AbstractString, h::UInt)
    g = tab.synth_mode === :dsl ? _genome_from_any(text) : nothing
    studio.label = tab.name
    studio.genome = g
    studio.sculpt = true
    if g === nothing
        studio.knobs = Knob[]; studio.samples = Float32[]; studio.view_start = 1; studio.view_len = 1
        studio.explain_lines = String[]
        empty!(studio.hints); empty!(studio.impacts)
    else
        _sculpt_init!(studio)
        studio.value_edit = false; studio.value_buf = ""
        studio.req_version += 1
    end
    studio.synced_hash = h
    studio.synced_name = tab.name
    _studio_mark_synced!(studio)
    sdoc === nothing || _synthdoc_set_explain!(sdoc, studio.explain_lines)
    return
end

# Mémorise l'état du studio tel qu'il est dans le texte.
function _studio_mark_synced!(studio::WaveformPane)
    studio.synced_req = studio.req_version
    g = studio.genome
    studio.last_values = g === nothing ? Float64[] : Float64[knob_value(g, kb) for kb in studio.knobs]
    studio.last_names = Symbol[kb.name for kb in studio.knobs]
    return
end

"""
    _studio_to_text!(m, studio, tab)

Reporte dans le texte ce qui a changé dans le studio. Un nombre qui se
retrouve tel quel (et une seule fois) dans le texte est remplacé sur
place ; sinon le bloc `@synth` est réécrit en forme canonique.
"""
function _studio_to_text!(m::RessacApp, studio::WaveformPane, tab::EditorBuffer)
    g = studio.genome
    ed = tab.code_editor
    text = TK.text(ed)
    vals = Float64[knob_value(g, kb) for kb in studio.knobs]
    names = Symbol[kb.name for kb in studio.knobs]
    newtext = nothing
    if names == studio.last_names
        t = text; ok = true
        for i in eachindex(vals)
            vals[i] == studio.last_values[i] && continue
            r = _patch_literal(t, studio.last_values[i], vals[i])
            r === nothing && (ok = false; break)
            t = r
        end
        ok && (newtext = t)
    end
    if newtext === nothing
        newtext = replace_synth_block(text, render_dsl(g, Symbol(tab.name)))
        _push_app_log!(m, "[INFO] studio → texte réécrit en forme canonique (u dans le texte annule)")
    end
    if newtext != text
        row = ed.cursor_row; col = ed.cursor_col
        TK._push_undo!(ed; force = true)
        TK.set_text!(ed, newtext)
        ed.cursor_row = clamp(row, 1, length(ed.lines))
        ed.cursor_col = clamp(col, 0, length(ed.lines[ed.cursor_row]))
    end
    studio.synced_hash = hash(newtext)
    _studio_mark_synced!(studio)
    sdoc = (p = _synth_workspace_parts(m); p === nothing ? nothing : p[3])
    sdoc === nothing || _synthdoc_set_explain!(sdoc, studio.explain_lines)
    return
end

# Formes qu'un nombre peut prendre dans le texte : 60, 60.0, 6.0e-2…
function _literal_forms(v::Float64)
    forms = String[]
    (isinteger(v) && abs(v) < 1e12) && push!(forms, string(Int(v)))
    push!(forms, string(v))
    s = string(round(v; sigdigits = 6)); s in forms || push!(forms, s)
    return forms
end
_fmt_literal(v::Float64) = (isinteger(v) && abs(v) < 1e12) ? string(Int(v)) : string(round(v; sigdigits = 6))

"""
    _patch_literal(text, old, new) -> String | nothing

Remplace le nombre `old` par `new` dans `text` s'il s'y trouve exactement
une fois (sous l'une de ses écritures) ; `nothing` sinon.
"""
function _patch_literal(text::AbstractString, old::Float64, new::Float64)
    alts = join((replace(f, "." => "\\.", "+" => "\\+") for f in _literal_forms(old)), "|")
    re = Regex("(?<![\\w.])(?:$alts)(?![\\w.])")
    ms = collect(eachmatch(re, text))
    length(ms) == 1 || return nothing
    mt = ms[1]
    stop = mt.offset + ncodeunits(mt.match)
    return text[1:prevind(text, mt.offset)] * _fmt_literal(new) * text[stop:end]
end

"""
    _ensure_synth_workspace!(m) -> Bool

Le workspace courant a la forme texte | studio / doc : si le studio lié ou
la DOC manquent (disposition d'avant, pane fermée), on les repose autour
de la pane texte — les onglets de synths sont gardés. Vrai si quelque
chose a été refait.
"""
function _ensure_synth_workspace!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    _synth_workspace_parts(m) === nothing || return false
    wm = m.workspaces
    # la pane texte : celle qui porte des synths, sinon la première pane éditeur
    leaf_ed = nothing
    for leaf in _all_leaves(ws.tree), tab in leaf.tabs
        tab isa EditorPane && any(b -> b.role === :synth, tab.tabs) && (leaf_ed = leaf; break)
    end
    if leaf_ed === nothing
        for leaf in _all_leaves(ws.tree), tab in leaf.tabs
            tab isa EditorPane && (leaf_ed = leaf; break)
        end
    end
    if leaf_ed === nothing
        ep = _pane_new(:editor, Dict{String,Any}("buffer_role" => "synth", "name" => "sketch"))
        eb = ep.tabs[1]; eb.synth_mode = :dsl
        TK.set_text!(eb.code_editor, _STARTER_DSL("sketch")); eb.code_editor.mode = :normal
        leaf_ed = PaneLeaf(wm.next_pane_id, PaneImpl[ep], 1); wm.next_pane_id += 1
    end
    for leaf in _all_leaves(ws.tree)
        leaf === leaf_ed && continue
        for tab in leaf.tabs; try; on_close!(tab); catch; end; end
    end
    ws.tree = leaf_ed
    ws.focused_pane = leaf_ed.id
    empty!(ws.floats)
    m.zoom_leaf = 0
    _synth_workspace_panes!(ws, wm)
    _push_app_log!(m, "[INFO] DESIGN remis en forme : texte | studio / doc")
    return true
end

# La pane texte du workspace synth, pour y ajouter un onglet.
function _synth_workspace_editor(m::RessacApp)
    parts = _synth_workspace_parts(m)
    parts === nothing ? nothing : parts[1]
end

# Enter dans le graphe : le focus passe au studio, sur le knob du nœud.
# G dans le studio : la DOC passe sur l'onglet graphe.
function _drain_synthdoc_request!(m::RessacApp)
    req = _SYNTHDOC_REQUEST[]
    req === nothing && return false
    _SYNTHDOC_REQUEST[] = nothing
    parts = _synth_workspace_parts(m)
    parts === nothing && return true
    (_, studio, sdoc) = parts
    if req === :focus_studio
        _focus_pane!(m, studio)
    elseif req === :graph && sdoc !== nothing
        sdoc.mode = :graph
        _focus_pane!(m, sdoc)
    end
    return true
end

"""
    _open_synth_text_in_design!(m, name, text; focus_studio = false) -> Bool

Ouvre `text` comme synth `name` dans DESIGN : un onglet de plus dans la
pane texte du workspace synth (le studio et la doc suivent), ou une pane
à part si DESIGN n'a pas cette forme. Les ponts de l'explorateur (e, M).
"""
function _open_synth_text_in_design!(m::RessacApp, name::AbstractString, text::AbstractString;
                                     focus_studio::Bool = false)
    _switch_workspace_named!(m, "DESIGN")
    wsed = _synth_workspace_editor(m)
    if wsed !== nothing
        i = findfirst(b -> b.role === :synth && b.name == name, wsed.tabs)
        if i === nothing
            push!(wsed.tabs, EditorBuffer(; role = :synth, name = name, content = text, synth_mode = :dsl))
            i = length(wsed.tabs)
        else
            TK.set_text!(wsed.tabs[i].code_editor, text)
        end
        wsed.current_tab = i
        wsed.tabs[i].code_editor.mode = :normal
        wsed.tabs[i].code_editor.focused = true
        _focus_pane!(m, wsed)
        _synth_workspace_sync!(m)
        if focus_studio
            parts = _synth_workspace_parts(m)
            parts === nothing || (_focus_pane!(m, parts[2]); parts[3] === nothing || (parts[3].mode = :explain))
        end
        return true
    end
    pane = _place_pane!(m, :editor, Dict{String,Any}("buffer_role" => "synth", "name" => name))
    if pane isa EditorPane && 1 <= pane.current_tab <= length(pane.tabs)
        eb = pane.tabs[pane.current_tab]
        eb.synth_mode = :dsl
        TK.set_text!(eb.code_editor, text)
        eb.code_editor.mode = :normal
    end
    return true
end

# ── Les gestes du mode DESIGN, depuis n'importe quelle pane ────────────
# Dans DESIGN le studio est lié au texte : « utiliser dans un pattern »
# et « mesurer l'élagage » parlent du synth courant, que le focus soit
# sur le texte, le studio ou la DOC. Un studio seul (hors DESIGN) garde
# son propre chemin.
function _design_use_in_pattern!(m::RessacApp)
    p = _focused_pane_impl(m)
    if p isa WaveformPane && p.sculpt && !p.linked
        _SCULPT_USE_REQUEST[] = p
        return
    end
    _use_current_synth_in_pattern!(m)
end

function _design_measure_impacts!(m::RessacApp)
    p = _focused_pane_impl(m)
    studio = (p isa WaveformPane && p.sculpt) ? p :
             (parts = _synth_workspace_parts(m); parts === nothing ? nothing : parts[2])
    if studio === nothing || studio.genome === nothing
        _push_app_log!(m, "[INFO] élagage : le studio attend un @synth analysable")
        return
    end
    _synth_workspace_sync!(m)
    _sculpt_measure_impacts!(studio)
end

# K / X / Y : la DOC sur la fiche du mot, l'explication, le graphe.
function _design_doc_mode!(m::RessacApp, mode::Symbol)
    parts = _synth_workspace_parts(m)
    if parts === nothing || parts[3] === nothing
        _push_app_log!(m, "[INFO] pas de pane DOC dans ce workspace — :design la remet")
        return
    end
    _synth_workspace_sync!(m)
    parts[3].mode = mode
    return
end

function _design_doc_tab!(m::RessacApp)
    _design_doc_mode!(m, :doc)
    _doc_under_cursor!(m)
end

# Les gestes du mode EXPLORE (T entendre, D drone) visent l'explorateur
# du workspace, que le focus soit dessus ou sur une pane voisine.
function _explore_pane(m::RessacApp)
    p = _focused_pane_impl(m)
    p isa SynthExplorerPane && return p
    return _find_pane(m, SynthExplorerPane)
end
function _explore_play!(m::RessacApp)
    p = _explore_pane(m)
    p === nothing && (_push_app_log!(m, "[INFO] pas d'explorateur ici — :explore"); return)
    _explorer_play_focus!(p)
end
function _explore_drone!(m::RessacApp)
    p = _explore_pane(m)
    p === nothing && (_push_app_log!(m, "[INFO] pas d'explorateur ici — :explore"); return)
    _explorer_toggle_drone!(p)
end
