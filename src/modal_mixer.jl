# Mixer modal — per-slot level + mute/solo + gain edit.
# Level bar reads real per-orbit RMS from SC's Amplitude.kr taps
# (forwarded via /ressac/rms, indexed by orbit = slot - 1). When SC
# isn't connected or hasn't sent yet, falls back to a 600 ms decay
# from `sched.last_fired_at[slot]` so the bar still shows life.

function _open_mixer!(m::RessacApp)
    _open_modal!(m, :mixer)
    m.mixer_table.selected = 1; m.mixer_table.offset = 0
end

"""
    _mixer_slots(m) -> Vector{Symbol}

All slots Ressac currently tracks: active patterns plus muted ones
(so the user can unmute from the mixer). Sorted by slot number.
"""
function _mixer_slots(m::RessacApp)
    slots = Set{Symbol}()
    union!(slots, pattern_keys(m.scheduler))
    union!(slots, keys(_APP_MUTED_PATTERNS))
    return sort!(collect(slots);
                 by = s -> try parse(Int, String(s)[2:end]) catch; 999 end)
end

function _handle_mixer_key!(m::RessacApp, evt::TK.KeyEvent)
    (evt.key === :escape || evt.char == 'q') && (m.modal = :none; return)
    dispatch!(((:modal_mixer, m),), evt)
    return
end

const _MIXER_BAR_W = 18

"""
    _mixer_sync!(m) -> Vector{Symbol}

Remplit la table du mixer : une ligne par slot, colonnes SLOT, ACTIVITÉ
(remplie au rendu par le vumètre), ÉTAT, GAIN, SOURCE. Les slots coupés
sont en jaune.
"""
function _mixer_sync!(m::RessacApp)
    slots = _mixer_slots(m)
    states = String[]; gains = String[]; sources = String[]; styles = TK.Style[]
    for slot in slots
        muted = haskey(_APP_MUTED_PATTERNS, slot)
        push!(states, muted ? "MUTED" : "PLAY")
        push!(styles, muted ? TK.tstyle(:warning) : TK.tstyle(:text))
        # Le gain et la source : le premier événement du cycle 0, s'il en a.
        pat = muted ? get(_APP_MUTED_PATTERNS, slot, nothing) : pattern_get(m.scheduler, slot)
        gain_str = "-"; source_str = "—"
        if pat !== nothing
            try
                evs = pat(0//1, 1//1)
                if !isempty(evs)
                    v = evs[1].value
                    if v isa Dict
                        haskey(v, :gain) && (gain_str = string(round(Float64(v[:gain]); digits = 2)))
                        haskey(v, :s) && (source_str = String(v[:s]))
                    elseif v isa Symbol
                        source_str = String(v)
                    end
                end
            catch
            end
        end
        push!(gains, gain_str); push!(sources, source_str)
    end
    cols = TK.DataColumn[
        TK.DataColumn("SLOT", Any["@" * String(s) for s in slots]; width = 6),
        TK.DataColumn("ACTIVITÉ", Any[" " ^ (_MIXER_BAR_W + 1) for _ in slots]; width = _MIXER_BAR_W + 1),
        TK.DataColumn("ÉTAT", Any[states...]; width = 6),
        TK.DataColumn("GAIN", Any[gains...]; width = 5, align = TK.col_right),
        TK.DataColumn("SOURCE", Any[sources...]),
    ]
    _datatable_set!(m.mixer_table, cols, styles)
    return slots
end

"""
    _apply_gain_delta_to_line(line, delta) -> String

Pure: bump (or insert) a `|> gain(N)` on `line` by `delta`. If `line`
already has a gain in its pipe chain, parse N, add delta, clamp to
`[0, 5]`, replace in place. Otherwise append `|> gain(1.0 + delta)`
(neutral baseline). All values are rounded to 2 decimals so the
buffer stays readable.

Extracted from `_mixer_nudge_gain!` so the regex + clamp behaviour
can be unit-tested without standing up a full RessacApp.
"""
function _apply_gain_delta_to_line(line::AbstractString, delta::Real)
    mt = match(r"\|>\s*gain\(([0-9.+\-]+)\)", line)
    if mt === nothing
        return rstrip(line) * " |> gain($(round(1.0 + float(delta); digits = 2)))"
    end
    cur = parse(Float64, mt.captures[1])
    new_v = clamp(cur + float(delta), 0.0, 5.0)
    return replace(line, mt.match => "|> gain($(round(new_v; digits = 2)))"; count = 1)
end

"""
    _mixer_nudge_gain!(m, slot, delta)

Adjust the gain of `slot`'s @dN line in the patterns buffer by
`delta`, then re-eval. The line-edit math lives in the pure helper
`_apply_gain_delta_to_line`; this wrapper finds the slot's row,
applies it, and re-evals so audio reflects the change.
"""
function _mixer_nudge_gain!(m::RessacApp, slot::Symbol, delta::Real)
    ed = _active_editor(m)
    ed === nothing && return _push_app_log!(m, "[WARN] mixer +/- : aucun éditeur ouvert")
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    slot_id = String(slot)
    row = findfirst(line -> occursin(Regex("^\\s*@$(slot_id)\\b"), String(line)), lines)
    row === nothing && return _push_app_log!(m, "[WARN] mixer +/- : pas de ligne @$(slot_id) dans le buffer")
    lines[row] = _apply_gain_delta_to_line(String(lines[row]), delta)
    TK.set_text!(ed, join(lines, '\n'))
    _eval_pattern_blocks!(m, [slot])
end

function _render_mixer_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    slots = _mixer_sync!(m)
    inner = _render_modal_block!(buf, area;
        title = "MIXER",
        title_right = _modal_hint_text(m, :modal_mixer),
        w_max = 90,
        h_target = max(8, min(area.height - 4, length(slots) + 5)))
    inner.width < 20 && return
    if isempty(slots)
        TK.set_string!(buf, inner.x + 1, inner.y,
            "(aucun pattern actif — évalue d'abord des blocs @dN)",
            TK.tstyle(:text_dim))
        return
    end
    # La table (en-tête, filet, lignes, sélection, barre), puis les
    # vumètres par-dessus la colonne ACTIVITÉ : trois zones et crête,
    # ce qu'une cellule de texte ne sait pas dire.
    dt = m.mixer_table
    TK.render(dt, TK.Rect(inner.x, inner.y, inner.width, inner.height - 1), buf)
    now = time()
    for (i, slot) in enumerate(slots)
        xy = _datatable_cell_xy(dt, i, 2)
        xy === nothing && continue
        muted = haskey(_APP_MUTED_PATTERNS, slot)
        # Niveau et crête : le RMS de SC si on l'a, sinon une décroissance
        # depuis le dernier événement joué, pour que la barre vive quand même.
        rms  = Float64(_orbit_rms(slot))
        peak = Float64(_orbit_peak(slot))
        level, pk = if rms > 0
            (_amp_to_bar(rms), _amp_to_bar(peak))
        else
            age = now - get(m.scheduler.last_fired_at, slot, 0.0)
            fb = age < 0.6 ? clamp(1.0 - age / 0.6, 0.0, 1.0) : 0.0
            (fb, fb)
        end
        _render_vu_bar!(buf, xy[1], xy[2], _MIXER_BAR_W, level, pk; muted = muted)
        # Saturation : un `!` rouge après la barre quand la crête frôle 1.
        TK.set_string!(buf, xy[1] + _MIXER_BAR_W, xy[2], (pk >= 0.95 && !muted) ? "!" : " ",
                       TK.tstyle(:error, bold = true))
    end
    # Pied : d'où vient le signal.
    any_rms = any(_orbit_rms(s) > 0 for s in slots)
    feed_note = any_rms ? "RMS de SC à 20 Hz" : "pas de RMS de SC — décroissance sur les événements"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
        first(rpad("$(length(slots)) slot$(length(slots) == 1 ? "" : "s") · $(feed_note)", inner.width), inner.width),
        TK.tstyle(:text_dim))
end

"""
    _amp_to_bar(amp) -> Float64

Perceptual amplitude → bar-fill ratio in `[0, 1]`. Typical SuperDirt
event amps land in 0.05..0.4 (the RMS of an in-progress voice), so a
linear mapping would barely move the bar — we use a soft sqrt curve
that gives visible motion across the useful range while still
distinguishing a quiet hit from a loud one. Anything ≥ 1.0 saturates.
"""
_amp_to_bar(amp::Real) = clamp(sqrt(min(Float64(amp), 1.0) / 0.5), 0.0, 1.0)

"""
    _render_vu_bar!(buf, x, y, w, level, peak; muted=false)

Three-zone VU bar with a peak-hold marker. `level` and `peak` are
both in `[0, 1]` (post-perceptual scaling via `_amp_to_bar`). The
fill is split into green (≤70%), yellow (70-90%), red (>90%) zones.
The peak position is overlaid as a `▏` glyph in red if it's in the
hot zone, yellow otherwise.

Muted slots render the whole bar dim (no zones) and skip the peak
indicator — the user already knows there's no audio.
"""
function _render_vu_bar!(buf, x::Int, y::Int, w::Int,
                         level::Real, peak::Real; muted::Bool = false)
    w <= 0 && return
    filled = clamp(floor(Int, level * w), 0, w)
    if muted
        bar = "█" ^ filled * "░" ^ (w - filled)
        TK.set_string!(buf, x, y, bar, TK.tstyle(:text_dim))
        return
    end
    # Zone boundaries on the bar's cell scale.
    yellow_start = max(1, floor(Int, 0.70 * w))
    red_start    = max(1, floor(Int, 0.90 * w))
    for i in 1:w
        ch = i <= filled ? "█" : "░"
        sty = if i <= filled
            i >= red_start    ? TK.tstyle(:error,   bold = true) :
            i >= yellow_start ? TK.tstyle(:warning, bold = true) :
                                TK.tstyle(:success, bold = true)
        else
            TK.tstyle(:text_dim)
        end
        TK.set_string!(buf, x + i - 1, y, ch, sty)
    end
    # Peak indicator: a tall vertical bar at the peak position,
    # overlaying whichever cell it lands on. Yellow in the headroom
    # zone, red once it's in the danger zone.
    peak_pos = clamp(floor(Int, peak * w), 0, w)
    if peak_pos > 0
        peak_sty = peak_pos >= red_start ?
            TK.tstyle(:error,   bold = true) :
            TK.tstyle(:warning, bold = true)
        TK.set_string!(buf, x + peak_pos - 1, y, "▏", peak_sty)
    end
end

# ── Registre de touches (déclaré en fin de fichier : les actions nommées
#    doivent exister au moment du bind!) ──
_mixer_cur(m::RessacApp) = (s = _mixer_sync!(m); i = m.mixer_table.selected; 1 <= i <= length(s) ? s[i] : nothing)
_mixer_has_cur(m::RessacApp) = _mixer_cur(m) !== nothing
scope!(:modal_mixer, "Mixer")
bind!(:modal_mixer, "m", "mute / unmute"; short = "mute", group = :audio, when = _mixer_has_cur,
      action = m -> (slot = _mixer_cur(m);
                     haskey(_APP_MUTED_PATTERNS, slot) ? _unmute_pattern_slot!(m, slot) :
                                                          _mute_pattern_slot!(m, slot)))
bind!(:modal_mixer, "s", "solo"; group = :audio, when = _mixer_has_cur,
      action = m -> _solo_pattern_slot!(m, _mixer_cur(m)))
bind!(:modal_mixer, "u", "tout démuter"; group = :audio, action = _unmute_all_patterns!)
bind!(:modal_mixer, ["+", "-"], "gain ±0.1"; group = :edit, when = _mixer_has_cur,
      action = (m, evt) -> _mixer_nudge_gain!(m, _mixer_cur(m), evt.char == '+' ? 0.1 : -0.1))
bind!(:modal_mixer, ["*", "/"], "gain ±0.5"; group = :edit, hint = false, when = _mixer_has_cur,
      action = (m, evt) -> _mixer_nudge_gain!(m, _mixer_cur(m), evt.char == '*' ? 0.5 : -0.5))
bind!(:modal_mixer, ["!", "."], "panic"; group = :audio, hint = false, action = _panic!)
bind!(:modal_mixer, ["j", "↓"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (_mixer_sync!(m); _list_nav!(m.mixer_table, :down)))
bind!(:modal_mixer, ["k", "↑"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (_mixer_sync!(m); _list_nav!(m.mixer_table, :up)))
_bind_modal_common!(:modal_mixer; nav = false)
