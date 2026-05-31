# Mixer modal — per-slot level + mute/solo + gain edit.
# Level bar reads real per-orbit RMS from SC's Amplitude.kr taps
# (forwarded via /ressac/rms, indexed by orbit = slot - 1). When SC
# isn't connected or hasn't sent yet, falls back to a 600 ms decay
# from `sched.last_fired_at[slot]` so the bar still shows life.

function _open_mixer!(m::RessacApp)
    _open_modal!(m, :mixer, :mixer_cursor)
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
    slots = _mixer_slots(m)
    n = length(slots)
    _modal_close_key!(m, evt) && return
    _modal_cursor_nav!(m, evt, :mixer_cursor, n) && return
    if evt.char == 'm' && 1 <= m.mixer_cursor <= n
        slot = slots[m.mixer_cursor]
        if haskey(_APP_MUTED_PATTERNS, slot)
            _unmute_pattern_slot!(m, slot)
        else
            _mute_pattern_slot!(m, slot)
        end
    elseif evt.char == 's' && 1 <= m.mixer_cursor <= n
        _solo_pattern_slot!(m, slots[m.mixer_cursor])
    elseif evt.char == 'u'
        _unmute_all_patterns!(m)
    elseif evt.char == '!' || evt.char == '.'
        _panic!(m)
    elseif (evt.char == '+' || evt.char == '-') && 1 <= m.mixer_cursor <= n
        _mixer_nudge_gain!(m, slots[m.mixer_cursor], evt.char == '+' ? 0.1 : -0.1)
    elseif (evt.char == '*' || evt.char == '/') && 1 <= m.mixer_cursor <= n
        _mixer_nudge_gain!(m, slots[m.mixer_cursor], evt.char == '*' ? 0.5 : -0.5)
    end
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
    txt = TK.text(_active_editor(m))
    lines = collect(split(txt, '\n'; keepempty = true))
    slot_id = String(slot)
    row = findfirst(line -> occursin(Regex("^\\s*@$(slot_id)\\b"), String(line)), lines)
    row === nothing && return _push_app_log!(m, "[WARN] mixer +/-: no @$(slot_id) line in buffer")
    lines[row] = _apply_gain_delta_to_line(String(lines[row]), delta)
    TK.set_text!(_active_editor(m), join(lines, '\n'))
    _eval_pattern_blocks!(m, [slot])
end

function _render_mixer_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    slots = _mixer_slots(m)
    inner = _render_modal_block!(buf, area;
        title = "MIXER",
        title_right = "j/k · +/- gain ±0.1 · */ gain ±0.5 · m mute · s solo · u unmute-all · ! panic · q close",
        w_max = 90,
        h_target = max(8, min(area.height - 4, length(slots) + 5)))
    inner.width < 20 && return
    if isempty(slots)
        TK.set_string!(buf, inner.x + 1, inner.y,
            "(no active patterns — eval some @dN blocks first)",
            TK.tstyle(:text_dim))
        return
    end
    # Header row.
    TK.set_string!(buf, inner.x, inner.y,
        first(rpad("  SLOT  ACTIVITY            STATE   GAIN  SOURCE",
                   inner.width), inner.width),
        TK.tstyle(:text_dim))
    # Underline.
    TK.set_string!(buf, inner.x, inner.y + 1,
                   "─" ^ inner.width, TK.tstyle(:text_dim))
    now = time()
    bar_w = 18
    for (i, slot) in enumerate(slots)
        row_y = inner.y + 2 + (i - 1)
        row_y >= inner.y + inner.height && break
        is_cur = i == m.mixer_cursor
        muted  = haskey(_APP_MUTED_PATTERNS, slot)
        # Level + peak — prefer real SC RMS, fall back to event-fire
        # decay if SC isn't sending. Both intensities run through the
        # same perceptual scaling so the peak indicator lines up with
        # the bar even when amplitudes are tiny.
        rms  = Float64(_orbit_rms(slot))
        peak = Float64(_orbit_peak(slot))
        intensity_rms, intensity_peak = if rms > 0
            (_amp_to_bar(rms), _amp_to_bar(peak))
        else
            last_ts = get(m.scheduler.last_fired_at, slot, 0.0)
            age = now - last_ts
            fb = age < 0.6 ? clamp(1.0 - age / 0.6, 0.0, 1.0) : 0.0
            (fb, fb)   # no peak distinct from level in fallback mode
        end
        state = muted ? "MUTED" : "PLAY "
        # Gain estimate: query the pattern at cycle 0, peek the first
        # event's :gain key. Falls back to 1.0 / "?" if not a ControlMap.
        pat = muted ? get(_APP_MUTED_PATTERNS, slot, nothing) :
                      pattern_get(m.scheduler, slot)
        gain_str = "  -  "
        source_str = "—"
        if pat !== nothing
            try
                evs = pat(0//1, 1//1)
                if !isempty(evs)
                    v = evs[1].value
                    if v isa Dict
                        if haskey(v, :gain); gain_str = lpad(string(round(Float64(v[:gain]); digits=2)), 5) end
                        if haskey(v, :s);    source_str = String(v[:s]) end
                    elseif v isa Symbol
                        source_str = String(v)
                    end
                end
            catch
            end
        end
        marker = is_cur ? "▶ " : "  "
        state_style = muted ? TK.tstyle(:warning) : TK.tstyle(:success)
        # Header row labels + slot id.
        TK.set_string!(buf, inner.x, row_y, marker,
                       is_cur ? TK.tstyle(:accent, bold = true) :
                                TK.tstyle(:text))
        TK.set_string!(buf, inner.x + 2, row_y, rpad("@" * String(slot), 6),
                       is_cur ? TK.tstyle(:accent, bold = true) :
                                TK.tstyle(:title))
        # Three-zone VU bar with peak marker. Pure helper does all the
        # colour + cell-painting in one place.
        _render_vu_bar!(buf, inner.x + 8, row_y, bar_w,
                       intensity_rms, intensity_peak; muted = muted)
        # Clip indicator (red `!`) after the bar when peak ≥ 0.95.
        clip_x = inner.x + 8 + bar_w
        clip_glyph = (intensity_peak >= 0.95 && !muted) ? "!" : " "
        TK.set_string!(buf, clip_x, row_y, clip_glyph,
                       TK.tstyle(:error, bold = true))
        TK.set_string!(buf, inner.x + 8 + bar_w + 2, row_y, state, state_style)
        TK.set_string!(buf, inner.x + 8 + bar_w + 8, row_y, gain_str,
                       TK.tstyle(:text))
        src_x = inner.x + 8 + bar_w + 14
        src_w = max(0, inner.x + inner.width - src_x)
        TK.set_string!(buf, src_x, row_y, first(source_str, src_w),
                       TK.tstyle(:text_dim))
    end
    # Footer hint.
    foot_y = inner.y + inner.height - 1
    any_rms = any(_orbit_rms(s) > 0 for s in slots)
    feed_note = any_rms ? "SC RMS @ 20 Hz" :
                          "no SC RMS feed — fire-decay fallback"
    TK.set_string!(buf, inner.x, foot_y,
        first(rpad("$(length(slots)) slot$(length(slots) == 1 ? "" : "s") · $(feed_note)",
                   inner.width), inner.width),
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
