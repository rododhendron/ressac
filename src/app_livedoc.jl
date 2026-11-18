# src/app_livedoc.jl
# La fiche d'un mot : `:doc <nom>`, K (la fiche du mot sous le curseur), la
# pane DOC qui suit le curseur à chaque rendu (`_update_live_doc!`).

function _doc_command!(m::RessacApp, name::AbstractString)
    entry = lookup_doc(String(name))
    if entry === nothing
        # Fall back to _lookup_livedoc (covers the _SC_UGEN_DOCS branch
        # for SC UGens that aren't in the plugin doc tree).
        desc = _lookup_livedoc(name)
        if desc === nothing
            _push_app_log!(m, "[WARN] :doc — aucune entrée pour « $name »")
            return false
        end
        _push_app_log!(m, "[doc] $name — $desc")
        _show_doc_pane!(m, String(name))
        return true
    end
    _push_app_log!(m, "[doc] $name — $(entry.short)")
    _show_doc_pane!(m, String(name))
    return true
end

"""
    _show_doc_pane!(m, name)

Affiche la fiche `name` dans la pane DOC du workspace courant (créée à
côté si besoin) sans voler le focus à l'éditeur.
"""
function _show_doc_pane!(m::RessacApp, name::String)
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    pane = _find_pane(m, DocPane)
    if pane === nothing
        keep = ws.focused_pane
        pane = _place_pane!(m, :doc, Dict{String,Any}("ref" => name))
        pane isa DocPane || return nothing
        ws.focused_pane = keep
    else
        pane.name = name          # le défilement repart du haut (voir _doc_sync!)
    end
    return pane
end

"""
    _doc_under_cursor!(m)

`K` — la fiche du mot sous le curseur (ou de l'appel qui l'englobe)
dans la pane DOC.
"""
function _doc_under_cursor!(m::RessacApp)
    word = _doc_target_under_cursor(m)
    if isempty(word)
        _push_app_log!(m, "[INFO] K — pose le curseur sur un mot (gain, every, bd…) ; :doc <nom> marche aussi")
        return
    end
    _doc_command!(m, word)
end

"""
    _doc_target_under_cursor(m) -> String

Ce que la doc doit montrer pour la position du curseur : le mot s'il est
documenté ou s'il nomme un son, sinon l'appel qui l'englobe. `""` quand
il n'y a rien à montrer.
"""
function _doc_target_under_cursor(m::RessacApp)
    ed = _active_editor(m)
    ed === nothing && return ""
    1 <= ed.cursor_row <= length(ed.lines) || return ""
    chars = ed.lines[ed.cursor_row]
    isempty(chars) && return ""
    col = clamp(ed.cursor_col + 1, 1, length(chars))
    word = _word_under_cursor_chars(chars, col)
    known(w) = !isempty(w) && (lookup_doc(String(w)) !== nothing ||
                               _lookup_livedoc(w) !== nothing ||
                               synth_info(Symbol(w)) !== nothing ||
                               sample_info(Symbol(w)) !== nothing ||
                               instrument_info(Symbol(w)) !== nothing)
    known(word) && return String(word)
    encl = _enclosing_call(chars, col)
    known(encl) && return String(encl)
    return ""
end

"""
    _update_live_doc!(m)

Met à jour les panes DOC en mode « suit le curseur ». On ne vide jamais
la fiche affichée : sans cible sous le curseur, la dernière reste, ce qui
évite le clignotement en se déplaçant dans une ligne.
"""
function _update_live_doc!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    target = ""
    header = Tuple{String,Symbol}[]
    found = false
    for leaf in _all_leaves(ws.tree), tab0 in leaf.tabs
        tab = tab0 isa SynthDocPane ? tab0.doc : tab0
        tab isa DocPane && tab.follow || continue
        if !found
            target = _doc_target_under_cursor(m)
            header = _cursor_slot_summary(m)
            found = true
        end
        # La fiche d'une doc de synth ne parle pas des slots.
        tab0 isa SynthDocPane || (tab.header = header)
        (isempty(target) || tab.name == target) && continue
        tab.name = target
    end
    return
end
