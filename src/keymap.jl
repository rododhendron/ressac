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
    scope!(scope, title)

Déclare (ou renomme) un scope avec son titre affiché dans l'aide.
"""
scope!(scope::Symbol, title::AbstractString) = (_SCOPE_TITLES[scope] = String(title); scope)
scope_title(scope::Symbol) = get(_SCOPE_TITLES, scope, String(scope))
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
    out = Tuple{String,String}[]
    seen = Set{String}()
    for (scope, target) in layers
        if isempty(prefix)
            for b in bindings(scope)
                (b.hint && b.when(target)) || continue
                any(occursin(' ', k) for k in b.keys) && continue
                k = first(b.keys)
                k in seen && continue
                push!(seen, k); push!(out, (k, hint_label(b)))
            end
        else
            for (suffix, b) in prefix_bindings(scope, prefix; target = target)
                b.hint || continue
                suffix in seen && continue
                push!(seen, suffix); push!(out, (suffix, hint_label(b)))
            end
        end
    end
    return out
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
