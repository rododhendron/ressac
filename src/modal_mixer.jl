# Mixer modal — per-slot level + mute/solo + gain edit.
# Level bar reads real per-orbit RMS from SC's Amplitude.kr taps
# (forwarded via /ressac/rms, indexed by orbit = slot - 1). When SC
# isn't connected or hasn't sent yet, falls back to a 600 ms decay
# from `sched.last_fired_at[slot]` so the bar still shows life.

function _open_mixer!(m::RessacApp)
    m.modal = :mixer
    m.mixer_cursor = 1
end

"""
    _mixer_slots(m) -> Vector{Symbol}

All slots Ressac currently tracks: active patterns plus muted ones
(so the user can unmute from the mixer). Sorted by slot number.
"""
function _mixer_slots(m::RessacApp)
    slots = Set{Symbol}()
    union!(slots, keys(m.scheduler.patterns))
    union!(slots, keys(_APP_MUTED_PATTERNS))
    return sort!(collect(slots);
                 by = s -> try parse(Int, String(s)[2:end]) catch; 999 end)
end

function _handle_mixer_key!(m::RessacApp, evt::TK.KeyEvent)
    slots = _mixer_slots(m)
    n = length(slots)
    if evt.key === :escape || evt.char == 'q'
        m.modal = :none; return
    elseif evt.char == 'j' || evt.key === :down
        m.mixer_cursor = min(m.mixer_cursor + 1, max(n, 1))
    elseif evt.char == 'k' || evt.key === :up
        m.mixer_cursor = max(m.mixer_cursor - 1, 1)
    elseif evt.char == 'm' && 1 <= m.mixer_cursor <= n
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
    _mixer_nudge_gain!(m, slot, delta)

Adjust the gain of `slot`'s @dN line in the patterns buffer by
`delta`, then re-eval. Finds an existing `|> gain(N)` in the line
and bumps N (clamped to [0, 5]); if absent, appends a fresh
`|> gain(1.0 + delta)` to the end. The mixer keeps the audio in
sync because the re-eval calls `set_pattern!` on the scheduler.
"""
function _mixer_nudge_gain!(m::RessacApp, slot::Symbol, delta::Real)
    txt = TK.text(m.editor)
    lines = collect(split(txt, '\n'; keepempty = true))
    slot_id = String(slot)
    row = findfirst(line -> occursin(Regex("^\\s*@$(slot_id)\\b"), String(line)), lines)
    row === nothing && return _push_app_log!(m, "[WARN] mixer +/-: no @$(slot_id) line in buffer")
    line = String(lines[row])
    # Find an existing |> gain(N) — capture the numeric literal.
    mt = match(r"\|>\s*gain\(([0-9.+\-]+)\)", line)
    new_line = if mt === nothing
        # No gain in the chain — append one with neutral 1.0 + delta.
        rstrip(line) * " |> gain($(round(1.0 + float(delta); digits = 2)))"
    else
        cur = parse(Float64, mt.captures[1])
        new_v = clamp(cur + float(delta), 0.0, 5.0)
        replace(line, mt.match => "|> gain($(round(new_v; digits = 2)))"; count = 1)
    end
    lines[row] = new_line
    TK.set_text!(m.editor, join(lines, '\n'))
    # Re-eval just that slot so the audio reflects the change.
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
        # Level bar — prefer real SC RMS feed (per-orbit Amplitude.kr
        # tap), fall back to event-fire decay if SC isn't sending.
        rms = Float64(_orbit_rms(slot))
        if rms > 0
            # Compress to [0,1] with a soft knee — typical SuperDirt
            # event amps land in 0.05..0.4, so √-scale gives visible
            # motion across the full bar without clipping.
            intensity = clamp(sqrt(min(rms, 1.0) / 0.5), 0.0, 1.0)
        else
            last_ts = get(m.scheduler.last_fired_at, slot, 0.0)
            age = now - last_ts
            intensity = age < 0.6 ? clamp(1.0 - age / 0.6, 0.0, 1.0) : 0.0
        end
        filled = clamp(floor(Int, intensity * bar_w), 0, bar_w)
        bar = "█" ^ filled * "░" ^ (bar_w - filled)
        state = muted ? "MUTED" : "PLAY "
        # Gain estimate: query the pattern at cycle 0, peek the first
        # event's :gain key. Falls back to 1.0 / "?" if not a ControlMap.
        pat = muted ? get(_APP_MUTED_PATTERNS, slot, nothing) :
                      get(m.scheduler.patterns, slot, nothing)
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
        bar_style = muted ? TK.tstyle(:text_dim) :
                    intensity > 0 ? TK.tstyle(:accent, bold = true) :
                                    TK.tstyle(:text_dim)
        state_style = muted ? TK.tstyle(:warning) : TK.tstyle(:success)
        # Render piece by piece so we can colour the bar separately.
        TK.set_string!(buf, inner.x, row_y, marker,
                       is_cur ? TK.tstyle(:accent, bold = true) :
                                TK.tstyle(:text))
        TK.set_string!(buf, inner.x + 2, row_y, rpad("@" * String(slot), 6),
                       is_cur ? TK.tstyle(:accent, bold = true) :
                                TK.tstyle(:title))
        TK.set_string!(buf, inner.x + 8, row_y, bar, bar_style)
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
