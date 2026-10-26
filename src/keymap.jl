# src/keymap.jl
# Registre de bindings — PUR : aucune dépendance sur RessacApp ni les
# panes. Une seule table par scope ; la barre de touches, l'aide `?`, le
# popup which-key et le wiki des touches en dérivent. Le dispatch passe
# par `dispatch!` pour toutes les actions ; ce qui n'a pas d'action
# (`action === nothing`) est documenté mais géré ailleurs (moteur vim de
# l'éditeur Tachikoma).
#
# Nom canonique d'une touche (`keyname`) : un caractère tel quel ("e",
# "?"), sauf "Space" ; les spéciales "Tab" "S-Tab" "Esc" "Enter" "Bksp"
# "PgUp" "PgDn" "Home" "End" "↑" "↓" "←" "→" ; "Ctrl-x" pour Ctrl+x.
# Un accord = préfixe + touche séparés par un espace : "Space d",
# "g t", "Ctrl-w s".

"""
    Binding

Une touche (ou plusieurs synonymes) → une action, dans un scope.

- `keys`   : noms canoniques ; plusieurs = synonymes ("j", "↓").
- `label`  : ce que fait la touche, court, en français.
- `scope`  : `:global`, `:patterns`, `:explorer`, `:modal_lib`…
- `action` : `cible -> …` (la cible est `m::RessacApp` ou la pane) ;
             `nothing` = documentée ici, exécutée par l'éditeur.
- `when`   : `cible -> Bool`, disponibilité (mode normal, pane ouverte…).
- `group`  : regroupement dans l'aide (`:nav`, `:edit`, `:audio`…).
- `hint`   : apparaît dans la barre de touches.
- `short`  : label court pour la barre ("" = `label`).
- `repeat` : se déclenche aussi sur une touche maintenue (key_repeat).
"""
struct Binding
    keys::Vector{String}
    label::String
    scope::Symbol
    action::Union{Nothing,Function}
    when::Function
    group::Symbol
    hint::Bool
    repeat::Bool
    short::String
end
hint_label(b::Binding) = isempty(b.short) ? b.label : b.short

const _KEYMAP = Dict{Symbol,Vector{Binding}}()
const _SCOPE_TITLES = Dict{Symbol,String}()
# La couche d'un scope. Une touche descend les couches actives jusqu'à
# la première qui la connaît :
#   :transient  exclusif, le temps d'un geste (saisie, leader, mode pane, visuel…)
#   :modal      la modale ouverte
#   :pane       ce qui n'a de sens que dans la pane focalisée
#   :mode       PLAY / DESIGN / EXPLORE, quelle que soit la pane
#   :global     partout
const _SCOPE_LAYER = Dict{Symbol,Symbol}()
const _LAYER_KINDS = (:transient, :modal, :pane, :mode, :global)
const _SCOPE_NOTES = Dict{Symbol,Vector{String}}()   # texte libre en fin de section d'aide
const _GROUP_TITLES = Dict{Symbol,String}(
    :nav => "Naviguer", :edit => "Éditer", :audio => "Jouer / écouter",
    :eval => "Évaluer", :view => "Vues", :layout => "Panes & workspaces",
    :help => "Aide", :file => "Fichiers", :misc => "Divers",
    :structure => "Structure", :select => "Sélection",
    :submode => "Sous-modes (touches une fois dedans)",
)

_always(_) = true

"""
    scope!(scope, title; layer = :pane)

Déclare (ou renomme) un scope avec son titre affiché dans l'aide, et sa
couche (voir `_SCOPE_LAYER`).
"""
function scope!(scope::Symbol, title::AbstractString; layer::Symbol = :pane)
    layer in _LAYER_KINDS || throw(ArgumentError("scope!: couche inconnue $layer"))
    _SCOPE_TITLES[scope] = String(title)
    _SCOPE_LAYER[scope] = layer
    return scope
end
scope_title(scope::Symbol) = get(_SCOPE_TITLES, scope, String(scope))
scope_layer(scope::Symbol) = get(_SCOPE_LAYER, scope, :pane)
scope_notes!(scope::Symbol, lines) = (_SCOPE_NOTES[scope] = String[String(l) for l in lines]; scope)
scope_notes(scope::Symbol) = get(_SCOPE_NOTES, scope, String[])

"""
    pane_scope(pane) -> Symbol

Scope du registre d'une pane (`:explorer`, `:sculpt`…) ; `:none` par
défaut. Chaque PaneImpl surcharge. Sert au dispatch de ses touches, à
la barre de touches et à l'aide `?`.
"""
pane_scope(::Any) = :none

"""
    bind!(scope, keys, label; action=nothing, when=_always, group=:misc,
          hint=true, repeat=false, short="") -> Binding

Enregistre un binding. `keys` : une `String` ou un vecteur de synonymes.
Un même accord déjà ACTIF (avec action) dans ce scope est remplacé, pour
qu'un re-`include` en dev n'accumule pas de doublons.
"""
function bind!(scope::Symbol, keys, label::AbstractString;
               action = nothing, when::Function = _always, group::Symbol = :misc,
               hint::Bool = true, repeat::Bool = false, short::AbstractString = "")
    ks = keys isa AbstractString ? [String(keys)] : String[String(k) for k in keys]
    isempty(ks) && throw(ArgumentError("bind!: au moins une touche"))
    b = Binding(ks, String(label), scope, action, when, group, hint, repeat, String(short))
    lst = get!(_KEYMAP, scope, Binding[])
    filter!(o -> !(o.label == b.label && o.keys == b.keys), lst)
    push!(lst, b)
    return b
end

bindings(scope::Symbol) = get(_KEYMAP, scope, Binding[])
clear_scope!(scope::Symbol) = (delete!(_KEYMAP, scope); nothing)

# ── Nom canonique d'une touche ─────────────────────────────────────
const _SPECIAL_KEYNAMES = Dict{Symbol,String}(
    :tab => "Tab", :backtab => "S-Tab", :escape => "Esc", :enter => "Enter",
    :backspace => "Bksp", :pageup => "PgUp", :pagedown => "PgDn",
    :home => "Home", :end => "End", :delete => "Del", :insert => "Ins",
    :up => "↑", :down => "↓", :left => "←", :right => "→",
)

"""
    keyname(evt::TK.KeyEvent) -> String

Nom canonique de la touche d'un événement, "" si non nommable
(modificateur seul, char nul).
"""
function keyname(evt::TK.KeyEvent)
    k = evt.key
    if k === :ctrl
        c = evt.char
        (c isa Char && c != '\0') || return ""
        return "Ctrl-" * string(lowercase(c))
    end
    haskey(_SPECIAL_KEYNAMES, k) && return _SPECIAL_KEYNAMES[k]
    c = evt.char
    (c isa Char && c != '\0') || return ""
    c == ' '  && return "Space"
    c == '\r' && return "Enter"
    c == '\t' && return "Tab"
    (c == '\b' || c == '\x7f') && return "Bksp"
    return string(c)
end

# Accord complet d'une touche dans un contexte de préfixe : "" + "d" →
# "d" ; "Space" + "d" → "Space d".
_chord(prefix::AbstractString, name::AbstractString) =
    isempty(prefix) ? String(name) : String(prefix) * " " * String(name)

_matches(b::Binding, chord::AbstractString) = any(==(chord), b.keys)

"""
    lookup(scope, chord; target=nothing) -> Union{Nothing,Binding}

Premier binding du scope dont une touche vaut `chord` et dont `when`
accepte `target` (si fourni).
"""
function lookup(scope::Symbol, chord::AbstractString; target = nothing)
    for b in bindings(scope)
        _matches(b, chord) || continue
        (target === nothing || b.when(target)) && return b
    end
    return nothing
end

# Une action prend la cible seule, ou (cible, evt) si elle a besoin de
# l'événement (touche maintenue, caractère tapé…).
_run_action(f::Function, target, evt) =
    applicable(f, target, evt) ? f(target, evt) : f(target)

"""
    dispatch!(layers, evt; prefix="") -> Bool

`layers` = liste ordonnée de `(scope, cible)`. Trouve le premier binding
AVEC action dont l'accord (`prefix` + touche) correspond et dont `when`
accepte la cible, l'exécute, renvoie true. Les répétitions (touche
maintenue) ne déclenchent que les bindings `repeat`. Les bindings sans
action ne consomment jamais la touche. Une action à deux arguments
reçoit `(cible, evt)`.
"""
function dispatch!(layers, evt::TK.KeyEvent; prefix::AbstractString = "")
    name = keyname(evt)
    isempty(name) && return false
    is_press  = evt.action === TK.key_press
    is_repeat = evt.action === TK.key_repeat
    (is_press || is_repeat) || return false
    chord = _chord(prefix, name)
    for (scope, target) in layers
        for b in bindings(scope)
            b.action === nothing && continue
            _matches(b, chord) || continue
            (is_press || b.repeat) || continue
            b.when(target) || continue
            _run_action(b.action, target, evt)
            return true
        end
    end
    return false
end

"""
    prefix_bindings(scope, prefix; target=nothing) -> Vector{Tuple{String,Binding}}

Pour le which-key : les (touche-suite, binding) du scope dont un accord
commence par `prefix * " "`, disponibles pour `target` si fourni.
"""
function prefix_bindings(scope::Symbol, prefix::AbstractString; target = nothing)
    out = Tuple{String,Binding}[]
    pre = String(prefix) * " "
    for b in bindings(scope)
        target === nothing || b.when(target) || continue
        for k in b.keys
            startswith(k, pre) && push!(out, (k[nextind(k, lastindex(pre)):end], b))
        end
    end
    return out
end

"""
    available(scope, target; hint_only=true) -> Vector{Binding}

Bindings du scope disponibles pour `target`, dans l'ordre de déclaration
(= ordre d'importance pour la barre de touches).
"""
available(scope::Symbol, target; hint_only::Bool = true) =
    Binding[b for b in bindings(scope) if (!hint_only || b.hint) && b.when(target)]

"""
    help_sections(scopes; targets=Dict()) -> Vector{NamedTuple}

Pour l'aide `?` : une section par scope (titre, puis groupes de
(touches, label)). Les bindings indisponibles pour la cible fournie
sont gardés mais marqués `dim=true`.
"""
function help_sections(scopes; targets = Dict{Symbol,Any}())
    out = NamedTuple[]
    for s in scopes
        bs = bindings(s)
        isempty(bs) && continue
        groups = NamedTuple[]
        for g in unique(b.group for b in bs)
            rows = NamedTuple[]
            for b in bs
                b.group === g || continue
                dim = haskey(targets, s) && !b.when(targets[s])
                push!(rows, (keys = join(b.keys, " / "), label = b.label, dim = dim))
            end
            push!(groups, (title = get(_GROUP_TITLES, g, String(g)), rows = rows))
        end
        push!(out, (scope = s, title = scope_title(s), groups = groups,
                    notes = scope_notes(s)))
    end
    return out
end

"""
    keymap_conflicts() -> Vector{String}

Deux bindings AVEC action sur le même accord dans le même scope, sans
prédicat distinct, se masqueraient : listés ici pour un test.
"""
function keymap_conflicts()
    out = String[]
    for (scope, bs) in _KEYMAP
        seen = Dict{String,Binding}()
        for b in bs
            b.action === nothing && continue
            for k in b.keys
                if haskey(seen, k) && seen[k].when === _always && b.when === _always
                    push!(out, "$scope: « $k » — « $(seen[k].label) » masque « $(b.label) »")
                end
                haskey(seen, k) || (seen[k] = b)
            end
        end
    end
    return sort!(out)
end

"""
    hints(layers; prefix="") -> Vector{Tuple{String,String}}

Pour la barre de touches : (touche affichée, label) des bindings `hint`
disponibles, dans l'ordre des couches puis de déclaration. Une touche
déjà proposée par une couche prioritaire n'est pas répétée. Les accords
(« g t ») ne sont listés qu'avec leur `prefix`, affichés sans lui.
"""
function hints(layers; prefix::AbstractString = "")
    return Tuple{String,String}[(e.key, e.label) for e in hint_entries(layers; prefix = prefix)]
end

"""
    hint_entries(layers; prefix="") -> Vector{NamedTuple}

Comme `hints`, avec le binding et sa cible : (key, label, binding,
target) — la barre de touches en fait des boutons cliquables.
"""
function hint_entries(layers; prefix::AbstractString = "")
    out = NamedTuple[]
    seen = Set{String}()
    for (scope, target) in layers
        if isempty(prefix)
            for b in bindings(scope)
                (b.hint && b.when(target)) || continue
                any(occursin(' ', k) for k in b.keys) && continue
                k = first(b.keys)
                k in seen && continue
                push!(seen, k); push!(out, (key = k, label = hint_label(b), binding = b, target = target))
            end
        else
            for (suffix, b) in prefix_bindings(scope, prefix; target = target)
                b.hint || continue
                suffix in seen && continue
                push!(seen, suffix); push!(out, (key = suffix, label = hint_label(b), binding = b, target = target))
            end
        end
    end
    return out
end

"""
    click_binding!(b, target)

Déclenche un binding « comme si » sa touche avait été pressée (bouton
de la barre de touches). Sans effet pour une entrée documentaire.
"""
function click_binding!(b::Binding, target)
    b.action === nothing && return false
    k = first(b.keys)
    evt = length(k) == 1 ? TK.KeyEvent(k[1]) : TK.KeyEvent(:char, '\0', TK.key_press)
    _run_action(b.action, target, evt)
    return true
end

"""
    hint_text(layers; prefix="", max_width=0, sep=" · ") -> String

`hints` rendus en une ligne « k label · k label … », coupée sur un
séparateur pour tenir dans `max_width` (0 = illimité).
"""
function hint_text(layers; prefix::AbstractString = "", max_width::Int = 0, sep::AbstractString = " · ")
    parts = String[k * " " * l for (k, l) in hints(layers; prefix = prefix)]
    out = ""
    for p in parts
        cand = isempty(out) ? p : out * sep * p
        max_width > 0 && textwidth(cand) > max_width && break
        out = cand
    end
    return out
end

# ── Mixins : les vocabulaires partagés, déclarés une fois ─────────────
# Treize panes et modales redéfinissaient chacune j/k/PgUp/PgDn/g/G avec
# de petites variantes. Un mixin attache ce vocabulaire à un scope ; la
# pane ne déclare plus que ce qui lui est propre.

"""
    mixin_scroll_nav!(scope, view; before, down_when, up_when, end_action,
                      page_synonyms = false, hint = false)

Défiler un `TK.ScrollPane` (`view(cible)`) : j/↓ k/↑ par ligne, PgDn/Ctrl-d
PgUp/Ctrl-u par écran (plus d/u avec `page_synonyms`), g/G haut/bas.
`before(cible)` court avant chaque geste (une synchronisation) ;
`end_action` remplace le G par défaut (le journal recolle au bas).
"""
function mixin_scroll_nav!(scope::Symbol, view::Function;
                           before::Function = _ -> nothing,
                           down_when::Function = _always,
                           up_when::Function = t -> view(t).offset > 0,
                           end_action::Union{Nothing,Function} = nothing,
                           page_synonyms::Bool = false, hint::Bool = false,
                           labels = (down = "descendre", up = "remonter"))
    go(key) = t -> (before(t); _scroll!(view(t), key))
    pd = page_synonyms ? ["d", "PgDn", "Ctrl-d"] : ["PgDn", "Ctrl-d"]
    pu = page_synonyms ? ["u", "PgUp", "Ctrl-u"] : ["PgUp", "Ctrl-u"]
    bind!(scope, ["j", "↓"], labels.down; group = :nav, hint = hint, repeat = true, when = down_when, action = go(:down))
    bind!(scope, ["k", "↑"], labels.up; group = :nav, hint = hint, repeat = true, when = up_when, action = go(:up))
    bind!(scope, pd, "descendre d'un écran"; group = :nav, hint = false, repeat = true, when = down_when, action = go(:pagedown))
    bind!(scope, pu, "remonter d'un écran"; group = :nav, hint = false, repeat = true, when = up_when, action = go(:pageup))
    bind!(scope, "g", "haut"; group = :nav, hint = false, action = go(:home))
    bind!(scope, "G", "bas"; group = :nav, hint = false, when = down_when,
          action = end_action === nothing ? go(:end_key) : end_action)
    return scope
end

"""
    mixin_list_nav!(scope, nav; before, home_end = true, page = true)

Parcourir une liste : j/↓ k/↑, PgDn/Ctrl-d PgUp/Ctrl-u, g/G. `nav(cible,
key)` déplace la sélection (`_picker_nav!`, `_list_nav!`…) ; `before`
court avant (une synchronisation).
"""
function mixin_list_nav!(scope::Symbol, nav::Function;
                         before::Function = _ -> nothing,
                         home_end::Bool = true, page::Bool = true)
    go(key) = t -> (before(t); nav(t, key))
    bind!(scope, ["j", "↓"], "suivant"; group = :nav, hint = false, repeat = true, action = go(:down))
    bind!(scope, ["k", "↑"], "précédent"; group = :nav, hint = false, repeat = true, action = go(:up))
    if page
        bind!(scope, ["PgDn", "Ctrl-d"], "page suivante"; group = :nav, hint = false, repeat = true, action = go(:pagedown))
        bind!(scope, ["PgUp", "Ctrl-u"], "page précédente"; group = :nav, hint = false, repeat = true, action = go(:pageup))
    end
    if home_end
        bind!(scope, "g", "premier"; group = :nav, hint = false, action = go(:home))
        bind!(scope, "G", "dernier"; group = :nav, hint = false, action = go(:end_key))
    end
    return scope
end

"""
    mixin_knob_nav!(scope; has, next, prev, more, less, big_more, big_less,
                    value, reset, tab_next, tab_prev, labels)

Un knob parmi d'autres : j/↓ k/↑ le suivant / le précédent, l/→ h/←
plus / moins (L/H grands pas), = saisir une valeur, 0 le défaut, Tab /
S-Tab le groupe suivant / précédent. Chaque geste est une fonction de
la cible ; `nothing` = pas de touche.
"""
function mixin_knob_nav!(scope::Symbol; has::Function = _always,
                         next, prev, more, less,
                         big_more = nothing, big_less = nothing,
                         value = nothing, reset = nothing,
                         tab_next = nothing, tab_prev = nothing,
                         labels = (next = "suivant", prev = "précédent", more = "plus", less = "moins",
                                   tab = "groupe suivant", tab_short = "groupe", value = "saisir une valeur",
                                   reset = "revenir au défaut", reset_short = "défaut"))
    bind!(scope, ["j", "↓"], labels.next; group = :nav, when = has, repeat = true, action = next)
    bind!(scope, ["k", "↑"], labels.prev; group = :nav, when = has, repeat = true, action = prev)
    if tab_next !== nothing
        bind!(scope, "Tab", labels.tab; short = labels.tab_short, group = :nav, when = has, action = tab_next)
        bind!(scope, "S-Tab", "précédent (groupe)"; group = :nav, hint = false, when = has, action = tab_prev)
    end
    bind!(scope, ["l", "→"], labels.more; group = :edit, when = has, repeat = true, action = more)
    bind!(scope, ["h", "←"], labels.less; group = :edit, when = has, repeat = true, action = less)
    big_more === nothing || bind!(scope, "L", labels.more * " (grand pas)"; group = :edit, hint = false, when = has, repeat = true, action = big_more)
    big_less === nothing || bind!(scope, "H", labels.less * " (grand pas)"; group = :edit, hint = false, when = has, repeat = true, action = big_less)
    value === nothing || bind!(scope, "=", labels.value; short = "valeur", group = :edit, when = has, action = value)
    reset === nothing || bind!(scope, "0", labels.reset; short = labels.reset_short, group = :edit, when = has, action = reset)
    return scope
end
