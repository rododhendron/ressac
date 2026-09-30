# src/pane_drone.jl
# Pane MODULATION : les drones vivants (registre de synth_drone.jl), un
# argument par ligne, à moduler au clavier ou à la molette. La pane ne
# connaît pas l'app : elle lit `drone_list()` et parle à SC via
# `drone_set!` / `drone_stop!`. Le lancement se fait depuis l'éditeur de
# synth (`D`) ou depuis PLAY (`drone()` sur un slot).

mutable struct DronePane <: PaneImpl
    current::Int          # index dans drone_list()
    focus::Int            # argument focalisé
    value_edit::Bool
    value_buf::String
    rows::Vector{Tuple{Int,Int,Int}}   # (y, x, largeur) des lignes d'arguments au dernier rendu
end

_drone_pane_ctor(::AbstractDict) = DronePane(1, 1, false, "", Tuple{Int,Int,Int}[])

_dr_has(p::DronePane) = !isempty(drone_list())

function _dr_current(p::DronePane)
    lst = drone_list()
    isempty(lst) && return nothing
    p.current = clamp(p.current, 1, length(lst))
    return lst[p.current]
end

function _dr_arg(p::DronePane)
    d = _dr_current(p)
    (d === nothing || isempty(d.names)) && return nothing, nothing
    p.focus = clamp(p.focus, 1, length(d.names))
    return d, d.names[p.focus]
end

function _dr_move!(p::DronePane, delta::Int)
    d = _dr_current(p)
    d === nothing && return
    n = length(d.names); n == 0 && return
    p.focus = mod1(p.focus + delta, n)
end

function _dr_cycle!(p::DronePane, delta::Int)
    n = length(drone_list()); n == 0 && return
    p.current = mod1(p.current + delta, n)
    p.focus = 1
end

function _dr_nudge!(p::DronePane, steps::Int)
    d, k = _dr_arg(p)
    d === nothing && return
    drone_set!(d, k, drone_step(d.values[k], d.defaults[k], steps))
end

function _dr_reset!(p::DronePane)
    d, k = _dr_arg(p)
    d === nothing && return
    drone_set!(d, k, d.defaults[k])
end

function _dr_begin_value!(p::DronePane)
    _dr_arg(p)[1] === nothing && return
    p.value_edit = true; p.value_buf = ""
end

function _dr_commit_value!(p::DronePane)
    d, k = _dr_arg(p)
    v = tryparse(Float64, strip(p.value_buf))
    (d !== nothing && v !== nothing) && drone_set!(d, k, v)
    p.value_edit = false; p.value_buf = ""
end

function _dr_stop!(p::DronePane)
    d = _dr_current(p)
    d === nothing && return
    drone_stop!(d.id)
    p.current = clamp(p.current, 1, max(1, length(drone_list())))
end

_dr_stop_all!(::DronePane) = drone_stop_all!()

# T : réévaluer le drone courant depuis son texte (l'éditeur s'en charge).
function _dr_reeval!(p::DronePane)
    d = _dr_current(p)
    d === nothing && return
    _DRONE_PANE_REQUEST[] = (:reeval, d.id)
end

# ── Rendu ────────────────────────────────────────────────────────────
_dr_fmt(v::Float64) = (isinteger(v) && abs(v) < 1e7) ? string(Int(v)) : string(round(v; sigdigits = 5))

# Jauge : la position de la valeur par rapport au défaut (┼). Trois
# octaves de part et d'autre en log pour les grandeurs positives, ±3× le
# défaut en linéaire sinon.
function _dr_gauge(cur::Float64, default::Float64, width::Int)
    width < 5 && return ""
    r = if cur > 0 && default > 0
        clamp(log2(cur / default) / 3, -1.0, 1.0)
    else
        clamp((cur - default) / (3 * max(abs(default), 1.0)), -1.0, 1.0)
    end
    mid = (width + 1) ÷ 2
    pos = clamp(mid + round(Int, r * (mid - 1)), 1, width)
    cells = fill('─', width); cells[mid] = '┼'; cells[pos] = '●'
    return String(cells)
end

function render!(p::DronePane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    lst = drone_list()
    d = _dr_current(p)
    head = d === nothing ? "MODULATION" :
           "MODULATION · $(d.id) ▶ $(d.synth)" * (length(lst) > 1 ? "  ($(p.current)/$(length(lst)) ⇥)" : "")
    _render_pane_block_simple!(rect, head, buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 4 || inner.height < 1) && return
    empty!(p.rows)
    if d === nothing
        TK.set_string!(buf, inner.x, inner.y, first("  (aucun drone)", inner.width), TK.tstyle(:text_dim))
        inner.height >= 3 && TK.set_string!(buf, inner.x, inner.y + 2,
            first("  D dans l'éditeur de synth lance le synth en drone,", inner.width), TK.tstyle(:text_dim))
        inner.height >= 4 && TK.set_string!(buf, inner.x, inner.y + 3,
            first("  drone() sur un slot PLAY le tient depuis un pattern.", inner.width), TK.tstyle(:text_dim))
        return
    end
    p.focus = clamp(p.focus, 1, max(1, length(d.names)))
    namew = maximum(length(String(k)) for k in d.names; init = 4)
    valw = 9
    for (i, k) in enumerate(d.names)
        y = inner.y + i - 1
        y >= inner.y + inner.height && break
        focused = i == p.focus
        cur = d.values[k]; def = d.defaults[k]
        mark = focused ? "▸ " : "  "
        val = if focused && p.value_edit
            "= $(p.value_buf)▏"
        else
            rpad(_dr_fmt(cur), valw)
        end
        line = mark * rpad(String(k), namew) * "  " * val
        gw = inner.width - length(line) - 2
        gauge = (focused && p.value_edit) ? "" : _dr_gauge(cur, def, min(gw, 31))
        text = first(line * "  " * gauge, inner.width)
        st = focused ? TK.tstyle(:accent) : (cur == def ? TK.tstyle(:text_dim) : TK.tstyle(:text))
        TK.set_string!(buf, inner.x, y, text, st)
        push!(p.rows, (y, inner.x, inner.width))
    end
    return
end

function handle_key!(p::DronePane, evt)
    evt isa TK.KeyEvent || return false
    ch = evt.char; k = evt.key
    if p.value_edit
        if k === :enter || ch == '\r'
            _dr_commit_value!(p); return true
        elseif k === :escape
            p.value_edit = false; p.value_buf = ""; return true
        elseif k === :backspace || ch == '\b' || ch == '\x7f'
            isempty(p.value_buf) || (p.value_buf = p.value_buf[1:prevind(p.value_buf, lastindex(p.value_buf))])
            return true
        elseif ch isa Char && (isdigit(ch) || ch == '.' || ch == '-' || ch == 'e' || ch == 'E')
            p.value_buf *= ch; return true
        end
        return true
    end
    return dispatch!(((pane_scope(p), p),), evt)
end

# Clic : focalise l'argument sous la souris. Molette : module l'argument
# survolé (ou le focalisé), un pas par cran.
function handle_mouse!(p::DronePane, evt)
    evt isa TK.MouseEvent || return false
    row = findfirst(r -> r[1] == evt.y && r[2] <= evt.x < r[2] + r[3], p.rows)
    if evt.button === TK.mouse_scroll_up || evt.button === TK.mouse_scroll_down
        _dr_has(p) || return false
        row === nothing || (p.focus = row)
        _dr_nudge!(p, evt.button === TK.mouse_scroll_up ? +1 : -1)
        return true
    end
    if row !== nothing && evt.button === TK.mouse_left && evt.action === TK.mouse_press
        p.focus = row
        return true
    end
    return false
end

pane_scope(::DronePane) = :drone
title(p::DronePane) = "modulation"
register_pane_kind!(:drone, _drone_pane_ctor)

scope!(:drone, "Modulation (drones)")
bind!(:drone, ["j", "↓"], "argument suivant"; group = :nav, when = _dr_has, repeat = true,
      action = p -> _dr_move!(p, +1))
bind!(:drone, ["k", "↑"], "argument précédent"; group = :nav, when = _dr_has, repeat = true,
      action = p -> _dr_move!(p, -1))
bind!(:drone, "Tab", "drone suivant"; short = "drone", group = :nav, when = _dr_has,
      action = p -> _dr_cycle!(p, +1))
bind!(:drone, "S-Tab", "drone précédent"; group = :nav, hint = false, when = _dr_has,
      action = p -> _dr_cycle!(p, -1))
bind!(:drone, ["l", "→"], "moduler +"; group = :edit, when = _dr_has, repeat = true,
      action = p -> _dr_nudge!(p, +1))
bind!(:drone, ["h", "←"], "moduler −"; group = :edit, when = _dr_has, repeat = true,
      action = p -> _dr_nudge!(p, -1))
bind!(:drone, "L", "moduler + (grand pas)"; group = :edit, hint = false, when = _dr_has, repeat = true,
      action = p -> _dr_nudge!(p, +6))
bind!(:drone, "H", "moduler − (grand pas)"; group = :edit, hint = false, when = _dr_has, repeat = true,
      action = p -> _dr_nudge!(p, -6))
bind!(:drone, "=", "saisir une valeur"; short = "valeur", group = :edit, when = _dr_has,
      action = p -> _dr_begin_value!(p))
bind!(:drone, "0", "revenir au défaut"; short = "défaut", group = :edit, when = _dr_has,
      action = p -> _dr_reset!(p))
bind!(:drone, ["T", "t"], "réévaluer le drone depuis son texte"; short = "réévaluer", group = :audio, when = _dr_has,
      action = p -> _dr_reeval!(p))
bind!(:drone, ["D", "x"], "relâcher ce drone"; short = "relâcher", group = :audio, when = _dr_has,
      action = p -> _dr_stop!(p))
bind!(:drone, "X", "relâcher tous les drones"; group = :audio, hint = false, when = _dr_has,
      action = p -> _dr_stop_all!(p))
bind!(:drone, ["Enter", "Esc", "Bksp"], "saisie de valeur : valider / annuler / effacer";
      group = :submode, hint = false)
