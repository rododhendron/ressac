# src/app_layers.jl
# Le clavier en couches. À chaque touche, `_active_layers(m)` rend la pile
# du moment — transitoires, modale, pane focalisée, mode, global — et
# `_resolve_key!` la descend jusqu'à la première couche qui connaît la
# touche. Une couche a un scope du registre (ses touches documentées,
# voir keymap.jl) et/ou un moteur (ce qui n'est pas une touche nommée :
# la frappe en insertion, la saisie d'une valeur, le moteur vim). La
# barre de touches, le which-key et l'aide `?` lisent la même pile.

"""
    Layer

- `scope`        : scope du registre (`:none` = pas de touches documentées ici)
- `target`       : la cible des actions (`m`, ou la pane)
- `engine`       : `(m, evt) -> Bool`, après le registre (ou avant avec `engine_first`)
- `exclusive`    : la touche s'arrête ici, consommée ou non
- `solo`         : la barre de touches et l'aide ne montrent rien au-dessous
- `prefix`       : préfixe d'accord (« Space », « g », « Ctrl-w »)
- `after_hit`    : `m -> …` après une touche du registre consommée
"""
struct Layer
    scope::Symbol
    target::Any
    engine::Union{Nothing,Function}
    exclusive::Bool
    solo::Bool
    engine_first::Bool
    prefix::String
    after_hit::Union{Nothing,Function}
end
Layer(scope::Symbol, target; engine = nothing, exclusive::Bool = false, solo::Bool = exclusive,
      engine_first::Bool = false, prefix::AbstractString = "", after_hit = nothing) =
    Layer(scope, target, engine, exclusive, solo, engine_first, String(prefix), after_hit)

# Le mode n'a pas encore de touches : la couche existe pour que la pile
# soit complète (voir app_modes.jl, qui la remplit).
_mode_scope(m::RessacApp) = Symbol("mode_", _workspace_mode(m))

"""
    _active_layers(m) -> Vector{Layer}

La pile du moment, de la plus prioritaire à la moins.
"""
function _active_layers(m::RessacApp)
    _validate_transients!(m)
    L = Layer[]
    m.hover === nothing || push!(L, Layer(:none, m; engine = _hover_engine!))
    if is_active(m.command_line)
        push!(L, Layer(:none, m; engine = _command_line_engine!, exclusive = true))
        return L
    end
    # Partout, avant tout : panic, Ctrl-1..9, Ctrl-F.
    push!(L, Layer(:none, m; engine = _pre_engine!))
    # États exclusifs de l'app — pause, piano, tap. Ils ne dépendent pas de
    # la pane focalisée : lancés depuis le wiki ou le journal, ils prennent
    # les touches tout pareil (sinon `:pause` gèle l'écran sans sortie).
    m.paused        && (push!(L, Layer(:none,  m; engine = _paused_engine!, exclusive = true)); return L)
    m.piano_active  && (push!(L, Layer(:piano, m; exclusive = true)); return L)
    m.tap_recording && (push!(L, Layer(:tap,   m; exclusive = true)); return L)
    if _PANE_MODE.active
        push!(L, Layer(:pane_mode, m; exclusive = true, prefix = "Ctrl-w"))
        return L
    end
    # Ouvrir le mode pane (Ctrl-w) ou la ligne « : » / « / ».
    push!(L, Layer(:none, m; engine = _open_transient_engine!))
    if m.modal !== :none
        push!(L, Layer(modal_scope(m), m; engine = _modal_engine!, exclusive = true, engine_first = true))
        return L
    end
    pane = _focused_pane_impl(m)
    ed = _active_editor(m)
    # Espace déjà pressé : le leader du mode, depuis n'importe quelle pane
    # (le snippet va dans le texte du workspace).
    if m.pending_leader && ed !== nothing && ed.mode === :normal
        push!(L, Layer(_leader_scope(m), m; engine = _leader_engine!, exclusive = true,
                       engine_first = true, prefix = "Space"))
        return L
    end
    if pane !== nothing && !_editor_pane_focused(m, pane, ed)
        # Une pane qui n'est pas l'éditeur : ses touches, puis le mode, puis
        # le global. Jamais l'éditeur.
        push!(L, Layer(pane_scope(pane), pane; engine = _pane_engine!, engine_first = true))
        push!(L, Layer(_mode_scope(m), m))
        push!(L, Layer(:global, m))
        return L
    end
    if ed === nothing
        push!(L, Layer(_mode_scope(m), m))
        push!(L, Layer(:global, m))
        return L
    end
    ed.focused = true
    if ed.mode === :normal
        # Le visuel : ses touches sur une pression ; une touche tenue
        # continue vers le moteur vim (la sélection suit le curseur).
        m.visual_active && push!(L, Layer(:visual, m; engine = _visual_engine!, solo = true))
        push!(L, Layer(:none, m; engine = _vim_record_engine!))
        m.placeholder_active && push!(L, Layer(:placeholder, m))
        if m.pending_find !== nothing
            push!(L, Layer(:none, m; engine = _pending_find_engine!, exclusive = true))
            return L
        end
        # Un opérateur en attente (`d`, `c`, `y`) : la touche suivante est son
        # mouvement, pas un geste de mode — `de` supprime jusqu'à la fin du
        # mot, il n'évalue pas la ligne.
        if !_awaiting_literal(m) && !(ed.pending_key in ('c', 'd', 'y'))
            prefix = ed.pending_key == 'g' ? "g" : ""
            # l'accord consommé lève le préfixe de CET éditeur (l'action a pu
            # changer de workspace, donc d'éditeur actif)
            hit = isempty(prefix) ? nothing : (_ -> (ed.pending_key = nothing))
            # le texte : ses touches propres (rôle), puis le mode, puis les
            # motions documentées de l'éditeur (f/t…), puis le global — un
            # geste de mode passe avant une motion vim, c'est voulu
            role = _focused_role(m) === :synth ? :synth : :patterns
            push!(L, Layer(role, m; prefix = prefix, after_hit = hit))
            push!(L, Layer(_mode_scope(m), m; prefix = prefix, after_hit = hit))
            push!(L, Layer(:editor, m; prefix = prefix, after_hit = hit))
            push!(L, Layer(:global, m; prefix = prefix, after_hit = hit))
        end
        push!(L, Layer(:none, m; engine = _editor_normal_engine!))
        push!(L, Layer(:none, m; engine = _editor_engine!, exclusive = true))
    elseif ed.mode === :insert
        push!(L, Layer(:insert, m; engine = _editor_insert_engine!, exclusive = true))
    else
        push!(L, Layer(:none, m; engine = _editor_engine!, exclusive = true))
    end
    return L
end

# La sélection visuelle et les trous d'un snippet appartiennent à un buffer
# (`m.transient_ed`) et à des lignes précises. Un changement de pane, de
# workspace ou d'onglet, ou une ligne supprimée entre-temps, les annule —
# sans quoi ils se réveillaient dans un autre texte, ou sur une ligne qui
# n'existe plus (BoundsError à chaque Tab).
function _validate_transients!(m::RessacApp)
    (m.visual_active || m.placeholder_active) || return
    ed = _active_editor(m)
    if ed === nothing || ed !== m.transient_ed
        m.visual_active = false; m.placeholder_active = false
        return
    end
    n = length(ed.lines)
    m.visual_active && !(1 <= m.visual_anchor_row <= n) && (m.visual_active = false)
    m.placeholder_active && !(1 <= m.placeholder_row <= n) && (m.placeholder_active = false)
    return
end

# La pane focalisée est-elle l'éditeur actif ? (patterns ou synth)
function _editor_pane_focused(m::RessacApp, pane, ed)
    pane isa EditorPane || return false
    1 <= pane.current_tab <= length(pane.tabs) || return false
    return pane.tabs[pane.current_tab].code_editor === ed
end

"""
    _resolve_key!(m, evt)

Descend la pile. Pour chaque couche : le registre (ses touches, avec le
préfixe), le moteur ; dans l'ordre inverse avec `engine_first`. Une
couche exclusive arrête la descente.
"""
function _resolve_key!(m::RessacApp, evt::TK.KeyEvent)
    for layer in _active_layers(m)
        if layer.engine_first
            (layer.engine !== nothing && layer.engine(m, evt)) && return true
            _layer_registry!(layer, evt) && return true
        else
            _layer_registry!(layer, evt) && return true
            (layer.engine !== nothing && layer.engine(m, evt)) && return true
        end
        layer.exclusive && return true
    end
    return false
end

function _layer_registry!(layer::Layer, evt::TK.KeyEvent)
    layer.scope === :none && return false
    dispatch!(((layer.scope, layer.target),), evt; prefix = layer.prefix) || return false
    layer.after_hit === nothing || layer.after_hit(layer.target isa RessacApp ? layer.target : nothing)
    return true
end

"""
    _visible_layers(m) -> (pairs, prefix)

Ce que la barre de touches, le which-key et l'aide montrent : les scopes
des couches actives, jusqu'à la première couche `solo` incluse.
"""
function _visible_layers(m::RessacApp)
    pairs = Tuple{Symbol,Any}[]
    prefix = ""
    for layer in _active_layers(m)
        if layer.scope !== :none
            push!(pairs, (layer.scope, layer.target))
            isempty(prefix) && (prefix = layer.prefix)
        end
        layer.solo && break
    end
    return pairs, prefix
end
