# src/app_offgrid.jl
# Hors de la grille : jouer à l'instant de la frappe, et la boucle libre.
#
#   Entrée     évalue la ligne MAINTENANT : son cycle 0 commence à la frappe,
#              pas à la prochaine barre. `e` la recale sur la grille.
#   Espace o   ouvre une boucle : on frappe (Espace), `o` la ferme. Ce qu'on
#              a joué est écrit — `|> frappes(…; cycles = …)` — et rejoue,
#              calé sur l'instant d'ouverture, de la longueur qu'on a tenue.

# L'heure de la boucle (injectée en test).
const _LOOP_CLOCK = Ref{Function}(time)

# La position dans les cycles, arrondie au millième AU-DESSUS : une phase
# posée « maintenant » ne tombe jamais dans le passé.
_phase_at(sched::Scheduler, t::Float64 = time()) =
    Rational{Int64}(ceil(Int, (t - sched.t_start) * sched.cps * 1000), 1000)

"""
    _eval_current_line_now!(m)

`Entrée` : comme `e`, mais le slot part de la frappe. Une ligne qui n'est
pas un `@dN` (une définition) s'évalue comme avec `e`.
"""
function _eval_current_line_now!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return _eval_current_line!(m)
    phase = _phase_at(sched)
    _eval_current_line!(m; phase = (phase, Float64(phase)))
end

# ── La boucle ────────────────────────────────────────────────────────

# Un nombre de cycles écrit court : trois décimales, sans zéros de trop.
function _fmt_cycles(x::Real)
    r = round(Float64(x); digits = 3)
    return isinteger(r) ? string(Int(r)) : string(r)
end

const _FRAPPES_TAIL_RX = r"\s*\|>\s*frappes\([^()]*\)\s*$"

# Les valeurs que joue une expression sur son premier cycle (ce que chaque
# frappe fait entendre, tour à tour).
function _loop_values(expr::AbstractString)
    v = Core.eval(Main, Meta.parse(expr))
    p = v isa AbstractString ? parse_minino(String(v)) : _as_pattern(v)
    evs = sort!(collect(Base.invokelatest(p, 0 // 1, 1 // 1)); by = ev -> ev.start)
    return Any[ev.value for ev in evs]
end

"""
    _loop_open!(m)

`Espace o` — sur une ligne `@dN`, ou sur le nom d'un son : la boucle
s'ouvre. Le temps court depuis cet instant.
"""
function _loop_open!(m::RessacApp)
    ed = _patterns_editor(m)
    sched = _LIVE_SCHEDULER[]
    (ed === nothing || sched === nothing) && (_push_app_log!(m, "[WARN] boucle — pas de session audio"); return)
    row = ed.cursor_row
    block = nothing
    for b in _slot_blocks(m)
        (!b.commented && b.row <= row <= b.last_row) && (block = b)
    end
    local slot, expr, rows
    if block !== nothing
        slot = block.slot
        lines = [String(l) for l in ed.lines[block.row:block.last_row]]
        # Une boucle déjà enregistrée sur cette ligne est remplacée.
        length(lines) > 1 && occursin(r"^\s*\|>\s*frappes\([^()]*\)\s*$", lines[end]) && pop!(lines)
        lines[end] = replace(lines[end], _FRAPPES_TAIL_RX => "")
        expr = strip(replace(_join_logical_block(lines), r"^\s*@d\d+\s*" => ""))
        rows = (block.row, block.last_row)
    else
        1 <= row <= length(ed.lines) || return
        word = _word_under_cursor_chars(ed.lines[row], ed.cursor_col + 1)
        if isempty(word) || !isempty(_unknown_sounds(["@d1 \"$word\""])) || !occursin(r"^[A-Za-z]\w*$", word)
            _push_app_log!(m, "[INFO] boucle — pose le curseur sur une ligne @dN, ou sur le nom d'un son")
            return
        end
        slot = Symbol("d", _next_free_slot(ed))
        expr = ":" * word
        rows = (0, row)                                   # une ligne neuve, sous celle du curseur
    end
    isempty(expr) && (_push_app_log!(m, "[INFO] boucle — la ligne ne dit pas quel son frapper"); return)
    values = try
        _loop_values(expr)
    catch err
        _push_app_log!(m, "[ERROR] boucle — $(_humanize_eval_error(err, expr))")
        return
    end
    isempty(values) && (_push_app_log!(m, "[INFO] boucle — cette ligne ne joue rien à frapper"); return)
    m.loop = LoopRec(slot, String(expr), rows, values, _LOOP_CLOCK[](), Float64[])
    _push_app_log!(m, "[INFO] boucle ouverte sur $slot — Espace frappe, o la ferme (sa longueur : le temps que tu la tiens), Échap annule")
    return
end

# Une frappe : on l'entend tout de suite, et on note l'instant.
function _loop_hit!(m::RessacApp)
    rec = m.loop
    rec === nothing && return
    push!(rec.hits, _LOOP_CLOCK[]())
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    v = rec.values[mod1(length(rec.hits), length(rec.values))]
    try
        msg = _inject_orbit!(event_to_osc(Event{typeof(v)}(0 // 1, 1 // 4, v); cps = sched.cps), rec.slot)
        send_osc(sched.osc, encode(OSCBundle(time(), [msg])))
    catch err
        _push_app_log!(m, "[ERROR] boucle — $(first(sprint(showerror, err), 120))")
    end
    return
end

function _loop_cancel!(m::RessacApp)
    m.loop === nothing && return
    m.loop = nothing
    _push_app_log!(m, "[INFO] boucle annulée — rien n'est écrit")
    return
end

"""
    _loop_close!(m)

`o` — la boucle se ferme : sa longueur est le temps écoulé depuis
l'ouverture, ses frappes sont écrites telles qu'elles ont été jouées, et
elle rejoue aussitôt, calée sur l'instant d'ouverture.
"""
function _loop_close!(m::RessacApp)
    rec = m.loop
    rec === nothing && return
    m.loop = nothing
    ed = _patterns_editor(m)
    sched = _LIVE_SCHEDULER[]
    (ed === nothing || sched === nothing) && return
    isempty(rec.hits) && (_push_app_log!(m, "[INFO] boucle fermée sans frappe — rien n'est écrit"); return)
    t_close = _LOOP_CLOCK[]()
    cps = sched.cps
    cycles = max(round((t_close - rec.t_open) * cps; digits = 3), 0.001)
    instants = unique!(sort!([min(round((h - rec.t_open) * cps; digits = 3), cycles - 0.001) for h in rec.hits]))
    link = "frappes(" * join((_fmt_cycles(max(t, 0.0)) for t in instants), ", ") * "; cycles = " * _fmt_cycles(cycles) * ")"
    lines = [String(l) for l in ed.lines]
    (first_row, last_row) = rec.rows
    if first_row == 0
        insert!(lines, last_row + 1, "@$(rec.slot) $(rec.expr) |> $link")
        target = last_row + 1
    else
        block = lines[first_row:last_row]
        length(block) > 1 && occursin(r"^\s*\|>\s*frappes\([^()]*\)\s*$", block[end]) && pop!(block)
        block[end] = replace(block[end], _FRAPPES_TAIL_RX => "")
        if length(block) == 1
            block[1] = rstrip(block[1]) * " |> " * link
        else
            indent = match(r"^\s*", block[end]).match
            push!(block, indent * "|> " * link)
        end
        splice!(lines, first_row:last_row, block)
        target = first_row
    end
    _edit_text!(ed, join(lines, '\n'); row = target, col = 0)
    # Calée sur l'instant d'ouverture : le deuxième tour commence maintenant.
    phase = (Rational{Int64}(round(Int, (rec.t_open - sched.t_start) * cps * 1000), 1000),
             (t_close - sched.t_start) * cps)
    for b in _slot_blocks(m)
        (b.slot === rec.slot && !b.commented && b.row <= target <= b.last_row) || continue
        _eval_slot_block!(m, rec.slot, b.src; phase = phase) &&
            _push_app_log!(m, "[INFO] boucle sur $(rec.slot) : $(length(instants)) frappe$(length(instants) > 1 ? "s" : "") sur $(_fmt_cycles(cycles)) cycle$(cycles > 1 ? "s" : "") — e la recale sur la grille, u l'efface")
    end
    return
end

scope!(:loop, "Boucle (Espace o)"; layer = :transient, modes = (:play,))
bind!(:loop, "Space", "frapper"; group = :audio, repeat = true, action = _loop_hit!)
bind!(:loop, ["o", "Enter"], "fermer la boucle : elle est écrite et rejoue"; short = "fermer", group = :audio, action = _loop_close!)
bind!(:loop, "Esc", "annuler"; group = :audio, action = _loop_cancel!)
