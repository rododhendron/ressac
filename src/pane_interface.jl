# src/pane_interface.jl
# Abstract pane type + plugin-extensible registry. Every UI surface
# in the new split-pane system is a PaneImpl. See
# docs/journal/20260529_split_pane_design.md for the design.

"""
    PaneImpl

Abstract supertype for every kind of pane (editor, log, scope, doc,
plugin-contributed kinds). A concrete kind must implement 4
mandatory methods (`render!`, `handle_key!`, `title`,
plus a constructor registered via `register_pane_kind!`) and may
override 8 defaulted ones.
"""
abstract type PaneImpl end

# ── Mandatory contract ─────────────────────────────────────────────
"""
    render!(p, area, buf)

Draw the pane inside `area` into the Tachikoma render `buf`.
"""
function render! end

"""
    handle_key!(p, evt) -> Bool

Process a key event. Return `true` if the pane consumed the event
(stops further dispatch). Return `false` for the workspace manager
to keep routing.
"""
function handle_key! end

"""
    title(p) -> String

Short label shown in tab strips, borders, status hints.
"""
function title end

# ── Defaulted contract ─────────────────────────────────────────────
"""
    default_mode(p) -> Symbol

`:tile` or `:float`. Override only for kinds that should float by
default (e.g. transient pickers).
"""
default_mode(::PaneImpl) = :tile

"""
    serialize(p) -> Dict{String,Any}

State captured for the layout persistence file. Empty by default;
override for kinds that should restore their state on next boot
(e.g. scope subtype, doc ref, editor tab list).
"""
serialize(::PaneImpl) = Dict{String,Any}()

on_focus!(::PaneImpl)  = nothing
on_blur!(::PaneImpl)   = nothing
on_close!(::PaneImpl)  = nothing

handle_mouse!(::PaneImpl, ::Any) = false
preferred_size(::PaneImpl) = nothing
can_split(::PaneImpl) = true
sidebar(::PaneImpl) = String[]

# ── Registry ───────────────────────────────────────────────────────
"""
    _PANE_KINDS

Symbol → constructor (`Dict -> PaneImpl`). Populated by
`register_pane_kind!`. Ressac core registers its 4 kinds at boot;
plugins register theirs from their `[julia]` init code.
"""
const _PANE_KINDS = Dict{Symbol,Function}()

"""
    register_pane_kind!(name, ctor)

Register `ctor(args::Dict)::PaneImpl` under `name`. Shadowing an
existing entry emits a warning but is allowed (so plugins can
override core deliberately, like docs and snippets).
"""
function register_pane_kind!(name::Symbol, ctor::Function)
    if haskey(_PANE_KINDS, name)
        @warn "pane kind '$name' shadowed by new registration"
    end
    _PANE_KINDS[name] = ctor
    return name
end

"""
    _pane_new(kind, args) -> PaneImpl

Instantiate a pane via the registered constructor. Throws
`ArgumentError` when the kind isn't registered.
"""
function _pane_new(kind::Symbol, args::AbstractDict)
    ctor = get(_PANE_KINDS, kind, nothing)
    ctor === nothing &&
        throw(ArgumentError("pane kind '$kind' is not registered"))
    return ctor(args)
end


# ── Shared chrome helpers for PaneImpl render! ─────────────────────
# `_render_pane_block!` in app_view.jl wants an `m::RessacApp` to read
# theme/focus state. PaneImpl render! receives only (pane, area, buf)
# — no app reference. These simpler variants draw a neutral border so
# every pane kind looks consistent inside a workspace tile.

# Couleur de focus posée par le rendu de l'arbre autour du render! de la
# pane focalisée (une pane ne connaît pas l'app). nothing = non focalisée.
const _PANE_FOCUS_COLOR = Ref{Any}(nothing)

# Pastille : texte de la couleur du fond du thème sur `color`.
_pill_style(color) = TK.Style(fg = TK.theme().bg, bg = color, bold = true)
_pill_style(field::Symbol) = _pill_style(getfield(TK.theme(), field))

"""
    _render_pane_block_simple!(rect, title, buf)

L'habillage d'une pane : une bande de titre sur sa première ligne et, si
elle n'est pas au bord gauche de l'écran, un filet vertical qui la sépare de
sa voisine. Pas de cadre. « NOM · précision » : le nom en gras (dans la
couleur du mode quand la pane a le clavier), la précision en secondaire.
Le contenu se dessine dans `_inner_rect_simple(rect)`.
"""
function _render_pane_block_simple!(rect::TK.Rect, title::AbstractString,
                                    buf::TK.Buffer)
    (rect.width < 2 || rect.height < 2) && return
    fc = _PANE_FOCUS_COLOR[]
    parts = split(String(title), " · "; limit = 2)
    _band!(buf, rect.x, rect.y, rect.width, String(parts[1]);
           sub = length(parts) > 1 ? String(parts[2]) : "", sep = " · ", focus = fc)
    rect.x > buf.area.x && _vrule!(buf, rect.x, rect.y, rect.height)
    return nothing
end

function _inner_rect_simple(rect::TK.Rect)
    TK.Rect(rect.x + 1, rect.y + 1,
            max(0, rect.width - 2), max(0, rect.height - 2))
end
