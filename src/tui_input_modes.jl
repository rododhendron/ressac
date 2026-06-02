# Input modes — piano + tap.
#
# Both turn keystrokes into musical events: piano plays the current
# synth at semitone offsets keyed by `_PIANO_KEYMAP`; tap records
# Space presses and quantizes them into a `@dN p"…"` line.
#
# `_detect_tap_period` is the heuristic core of tap-loop detection
# (tested in test/test_tap_detection.jl). Constants tuned with
# hot_threshold = ⌈2·n_reps/3⌉, n_bins = 16, n_reps_best floor 1.25.
#
# Extracted from app.jl; load order assumes RessacApp, _push_app_log!,
# _LIVE_SCHEDULER, _eval_pattern_blocks!, set_cps!, _insert_line_after_cursor!,
# _next_free_d_slot, send_osc/encode/OSCMessage are all in scope by the
# time this file is included.

# ---------------------------------------------------------------------
# Piano mode — letter keys → semitones → fire current synth
# ---------------------------------------------------------------------
#
# Chromatic keyboard layout. Both qwerty (z = C) and azerty (w = C
# because azerty's bottom-left key is W in the same physical spot)
# point to the same notes — so the layout works on both without
# reconfiguring. Black keys (#) live on the row above naturals:
#
#     s d _ g h j _ s d _ g h …      ← black keys (sharps)
#     z x c v b n m , . / + …         ← naturals (qwerty)
#     w x c v b n , ; : ! § …         ← naturals (azerty)
#
# 13 keys give a chromatic octave + 1.
const _PIANO_KEYMAP = Dict{Char,Int}(
    # Bottom row naturals + middle row sharps. Covers one chromatic
    # octave + one note; `[` and `]` shift the octave for more range.
    # Both qwerty (z=C) and azerty (w=C, same physical spot) bindings
    # are defined so the layout works without per-layout config.
    'z' => 0,  'w' => 0,   # C
    's' => 1,              # C#
    'x' => 2,              # D
    'd' => 3,              # D#
    'c' => 4,              # E
    'v' => 5,              # F
    'g' => 6,              # F#
    'b' => 7,              # G
    'h' => 8,              # G#
    'n' => 9,              # A
    'j' => 10,             # A#
    ',' => 11, 'm' => 11,  # B
    ';' => 12, '.' => 12,  # C above
)

function _piano_start!(m::RessacApp;
                       synth::AbstractString = m.piano_synth,
                       record::Bool = false)
    m.piano_active = true
    m.piano_rec = record
    m.piano_synth = String(synth)
    empty!(m.piano_events)
    mode_label = record ? "RECORD" : "PLAY"
    _push_app_log!(m, "[INFO] piano $mode_label — synth=$(m.piano_synth) · " *
                   "[/] octave · Enter " *
                   (record ? "commit" : "exit") * " · Esc exit")
    _push_app_log!(m, "         keys: z=C s=C# x=D d=D# c=E v=F g=F# b=G h=G# n=A j=A# ,=B")
end

function _piano_stop!(m::RessacApp)
    m.piano_active = false
    m.piano_rec = false
    empty!(m.piano_events)
    _push_app_log!(m, "[INFO] piano off")
end

"""
    _piano_play!(m, semitone)

Fire the current synth at the pitch corresponding to `semitone` (0
= C in the current octave). Sends `/ressac/play <synth> freq <hz>`
which the SC OSCdef converts to a fresh Synth instance. If recording
is active, also stash the (timestamp, semitone) for later commit.
"""
function _piano_play!(m::RessacApp, semitone::Int)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    midi = m.piano_octave * 12 + semitone
    freq = 440.0 * 2.0 ^ ((midi - 69) / 12)
    args = Any[m.piano_synth, "freq", Float32(freq)]
    send_osc(sched.osc, encode(OSCMessage("/ressac/play", args)))
    if m.piano_rec
        push!(m.piano_events, (time(), semitone))
    end
    _push_app_log!(m, "[INFO] piano ♪ midi=$midi freq=$(round(Int, freq))Hz")
end

"""
    _piano_commit!(m)

Quantize the recorded note events into a `:synth |> n(p"...")`
pattern and insert it below the cursor. Same quantization scheme
as tap mode — bar = first→last interval over `piano_steps` cells.
"""
function _piano_commit!(m::RessacApp)
    m.piano_active = false
    n = length(m.piano_events)
    if n < 2
        _push_app_log!(m, "[WARN] piano: need at least 2 notes")
        empty!(m.piano_events)
        return
    end
    first_t = m.piano_events[1][1]
    last_t  = m.piano_events[end][1]
    bar = max(last_t - first_t, 1e-6)
    N = m.piano_steps
    cells = fill("~", N)
    for (t, semi) in m.piano_events
        idx = clamp(round(Int, (t - first_t) / bar * (N - 1)) + 1, 1, N)
        cells[idx] = string(semi)
    end
    ed = _active_editor(m)
    ed === nothing && return
    slot = _next_free_d_slot(ed)
    line = "@d$(slot) :$(m.piano_synth) |> n(p\"" * join(cells, " ") * "\")"
    _insert_line_after_cursor!(ed, line)
    empty!(m.piano_events)
    m.piano_rec = false
    _push_app_log!(m, "[INFO] piano committed → $(line)")
end

# ---------------------------------------------------------------------
# Tap-to-record rhythm
# ---------------------------------------------------------------------

"""
    _tap_start!(m; sample="bd", steps=16)

Enter tap-record mode. Status bar shows `● TAP …` while active.
Space records a hit at the current time, Enter quantizes the hits
to `steps` and inserts the resulting `@dN p"..."` below the cursor,
Esc cancels.
"""
function _tap_start!(m::RessacApp; sample::AbstractString = "bd",
                                    steps::Int = 16,
                                    bars::Int = 1,
                                    mode::Symbol = :loop)
    m.tap_recording = true
    empty!(m.tap_events)
    m.tap_sample = String(sample)
    m.tap_steps  = steps
    m.tap_bars   = max(1, bars)
    m.tap_mode   = mode
    if mode === :tempo
        _push_app_log!(m,
            "[INFO] tap-tempo — Space on each beat (≥2 taps), Enter to apply cps, Esc cancel · 4 taps = 1 bar")
    elseif mode === :loop
        _push_app_log!(m,
            "[INFO] tap-loop — repeat the rhythm a few times · Space on hits, Enter commit, Esc cancel · sample=$(sample)")
    elseif bars > 1
        _push_app_log!(m,
            "[INFO] tap — play the same pattern $(bars)× · Space on hits, Enter commit, Esc cancel · steps=$(steps)")
    else
        _push_app_log!(m,
            "[INFO] tap — Space ONLY on hits (no extra downbeat at end), Enter commit, Esc cancel · sample=$(sample), steps=$(steps)")
    end
end

function _tap_hit!(m::RessacApp)
    push!(m.tap_events, time())
    # Status bar already shows the live count; only log every 4 hits
    # (and always the very first) to keep the log panel readable.
    n = length(m.tap_events)
    if n == 1 || n % 4 == 0
        _push_app_log!(m, "[INFO] tap #$(n)")
    end
end

"""
    _tap_commit!(m)

Quantize the recorded hits over `m.tap_steps` divisions, build a
mini-notation string, and insert `@d<next-free-slot> p"..."` below
the cursor. The bar length is taken from the first→last tap
interval; both endpoints land on the first and last grid step
respectively.
"""
function _tap_commit!(m::RessacApp)
    m.tap_recording = false
    n = length(m.tap_events)
    if n < 2
        _push_app_log!(m, "[WARN] tap: need at least 2 hits")
        empty!(m.tap_events)
        return
    end
    if m.tap_mode === :tempo
        _tap_apply_tempo!(m); return
    end
    if m.tap_mode === :loop
        _tap_commit_auto!(m); return
    end
    if m.tap_bars > 1
        _tap_commit_fixed_bars!(m); return
    end
    # Default single-bar: same extend-by-one-interval quantization as
    # before, predictable and what most users expect.
    first_t = m.tap_events[1]; last_t = m.tap_events[end]
    avg_interval = (last_t - first_t) / (n - 1)
    bar = (last_t - first_t) + avg_interval
    N = m.tap_steps
    cells = fill("~", N)
    for t in m.tap_events
        idx = clamp(floor(Int, (t - first_t) / bar * N) + 1, 1, N)
        cells[idx] = m.tap_sample
    end
    _tap_emit_line!(m, cells, "")
end

# ── Fixed-bar averaging (explicit `:tap sample steps bars`) ─────────
function _tap_commit_fixed_bars!(m::RessacApp)
    n = length(m.tap_events)
    first_t = m.tap_events[1]; last_t = m.tap_events[end]
    avg_interval = (last_t - first_t) / (n - 1)
    total = (last_t - first_t) + avg_interval
    bar = total / m.tap_bars
    N = m.tap_steps
    votes = zeros(Int, N)
    for t in m.tap_events
        phase = mod(t - first_t, bar) / bar
        idx = clamp(floor(Int, phase * N) + 1, 1, N)
        votes[idx] += 1
    end
    threshold = max(1, ceil(Int, m.tap_bars / 2))
    cells = [v >= threshold ? m.tap_sample : "~" for v in votes]
    _tap_emit_line!(m, cells, "(averaged over $(m.tap_bars) bars)")
end

# ── Dynamic period & confidence detection ───────────────────────────
"""
    _detect_tap_period(events) -> (period, n_bars, steps, confidence, cells)

Estimate the loop period the user is tapping by scanning candidate
periods (cumulative IOI sums) and scoring each by how tightly the
folded tap positions cluster. The best-fit candidate becomes the
bar; the step count is inferred from the smallest inter-tap
interval relative to that bar. Confidence = max-bin / total taps,
in [0, 1] — higher means tighter alignment.
"""
function _detect_tap_period(events::Vector{Float64};
                            cps_hint::Union{Nothing,Real} = nothing)
    n = length(events)
    n < 4 && return nothing
    first_t = events[1]
    total = events[end] - first_t
    iois = diff(events)
    # Candidate periods = cumulative sums of the first k IOIs PLUS,
    # if the user has a tempo running, multiples of the bar length.
    # The latter handles the case where someone taps the rhythm in
    # time with the existing scheduler — the bar boundary is rarely
    # a tap onset so cumsum alone won't surface it.
    candidates = Float64[]
    s = 0.0
    for ioi in iois
        s += ioi
        0.2 <= s <= total && length(candidates) < 30 && push!(candidates, s)
    end
    if cps_hint !== nothing && cps_hint > 0
        bar = 1.0 / cps_hint
        for mult in (0.5, 1.0, 2.0, 4.0)
            p = bar * mult
            0.2 <= p <= total && push!(candidates, p)
        end
    end
    isempty(candidates) && return nothing
    unique!(sort!(candidates))

    best_period = total
    best_score  = -Inf
    # 16 bins instead of 32: each bin is ~1/16 of the period (≈ 62ms
    # for a 1s bar), which absorbs ±30ms of human tap jitter without
    # smearing taps across adjacent bins. With 32 bins, hits at the
    # same musical phase often split across two bins and look like
    # two distinct positions, killing the hot_count signal.
    n_bins = 16
    for p in candidates
        p <= 0.001 && continue
        n_reps = total / p
        bins = zeros(Int, n_bins)
        for t in events
            f = mod(t - first_t, p) / p
            bins[clamp(floor(Int, f * n_bins) + 1, 1, n_bins)] += 1
        end
        # A "hot bin" needs ≥ 2/3 of the reps' worth of taps AND ≥ 2.
        # The 2/3 (instead of 1/2) is crucial: it rejects sub-divisors
        # of the true period. For a jersey tap (hits at 0, 3, 6 of 8),
        # the candidate p = 3/8 of the bar looks "periodic" with bins
        # at phases 0 and 1/4 — but each of those bins only has half
        # the taps, since the rhythm doesn't actually repeat at p.
        # 2/3 threshold makes that fail; only the true bar survives.
        hot_threshold = max(2, ceil(Int, n_reps * 2 / 3))
        hot_count  = count(b -> b >= hot_threshold, bins)
        tight_taps = sum(b for b in bins if b >= hot_threshold; init = 0)

        score = tight_taps / n
        hot_count < 2 && (score *= 0.2)   # need ≥ 2 distinct hit positions
        # Softer n_reps penalty — 1.5 to 1.8 is still "two-ish bars",
        # which is the minimum useful loop and worth keeping in play.
        if     n_reps < 1.3;  score *= 0.4
        elseif n_reps < 1.8;  score *= 0.8
        end
        n_reps > 8.0 && (score *= 0.7)
        # Slight bias toward integer rep counts.
        frac = abs(n_reps - round(n_reps))
        score *= (1.0 - 0.3 * frac)
        # Bonus when the period sits at or near a bar boundary of the
        # current tempo — strong signal the user was tapping in time.
        if cps_hint !== nothing && cps_hint > 0
            bar = 1.0 / cps_hint
            ratio = p / bar
            cps_frac = abs(ratio - round(ratio))
            cps_frac < 0.1 && (score *= 1.3)
        end

        if score > best_score
            best_score = score; best_period = p
        end
    end

    # If no candidate looks like a real loop, defer to single-bar
    # quantization. The n_reps floor used to be 1.5, which rejected
    # the common "I tapped the pattern twice without the 3rd-bar
    # downbeat" case (n_reps ≈ 1.375 for a 2-hit-per-bar rhythm).
    # Drop to 1.25 — any candidate with n_reps below that is genuinely
    # under-evidence and the score-based fallback handles it.
    n_reps_best = total / best_period
    (best_score < 0.5 || n_reps_best < 1.25) && return nothing

    n_bars = max(1, round(Int, n_reps_best))

    # Step inference: smallest "musical" S where the folded tap
    # positions snap CLEANLY to integer step indices. Cleanly = avg
    # fractional-step error < 0.06. We also require the grid to be
    # at least as fine as the smallest inter-tap interval, else we
    # collapse two hits onto one step.
    musical_steps = (3, 4, 6, 8, 12, 16, 24, 32)
    min_ioi = minimum(iois)
    min_S = max(3, ceil(Int, best_period / max(min_ioi, 0.01)))
    # Pick the smallest S with the LOWEST average snap error. Iterating
    # from smallest upward and tracking the minimum lets equal-err
    # candidates be broken by "smaller is better" (more compact output).
    steps = 16
    best_err = Inf
    for S in musical_steps
        S < min_S && continue
        err = 0.0
        for t in events
            f = mod(t - first_t, best_period) / best_period * S
            err += abs(f - round(f))
        end
        avg = err / n
        # Strict improvement: 0.01 epsilon so float noise doesn't make
        # a finer S "tie" with a coarser one that's actually perfect.
        if avg + 0.01 < best_err
            steps = S
            best_err = avg
        end
    end

    votes = zeros(Int, steps)
    for t in events
        f = mod(t - first_t, best_period) / best_period
        idx = clamp(floor(Int, f * steps) + 1, 1, steps)
        votes[idx] += 1
    end
    threshold = max(1, ceil(Int, n_bars / 2))
    cells_idx = findall(v -> v >= threshold, votes)
    return (period = best_period, n_bars = n_bars, steps = steps,
            confidence = clamp(best_score, 0.0, 1.0),
            n_hits = length(cells_idx),
            votes = votes,
            threshold = threshold)
end

function _tap_commit_auto!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    cps_hint = sched === nothing ? nothing : sched.cps
    analysis = _detect_tap_period(m.tap_events; cps_hint = cps_hint)
    # In both branches we want to: pick a cps from the tap timing,
    # apply it immediately, insert the cps! line, then insert + eval
    # the pattern. The branches only differ in how the cells/period
    # are computed.
    bar_dur, cells, suffix = if analysis === nothing
        # No repetition detected — quantize the single pass over
        # m.tap_steps divisions. Use total + avg as the bar so the
        # last tap gets its own step.
        n = length(m.tap_events)
        first_t = m.tap_events[1]; last_t = m.tap_events[end]
        avg = (last_t - first_t) / (n - 1)
        bar = (last_t - first_t) + avg
        N = m.tap_steps
        cs = fill("~", N)
        for t in m.tap_events
            idx = clamp(floor(Int, (t - first_t) / bar * N) + 1, 1, N)
            cs[idx] = m.tap_sample
        end
        (bar, cs, "(no loop detected — single-bar fit)")
    else
        cs = [v >= analysis.threshold ? m.tap_sample : "~" for v in analysis.votes]
        pct = round(Int, analysis.confidence * 100)
        rating = analysis.confidence > 0.75 ? "high" :
                 analysis.confidence > 0.55 ? "ok"   : "low — try more reps"
        target_cps = round(1.0 / analysis.period; digits = 3)
        suf = "(period=$(round(analysis.period; digits=2))s · " *
              "$(analysis.n_bars) bar$(analysis.n_bars == 1 ? "" : "s") · " *
              "$(analysis.steps) steps · cps=$(target_cps) · " *
              "confidence $(pct)% [$rating])"
        # Density warning — likely a stream rather than a rhythm.
        density = analysis.n_hits / analysis.steps
        if density > 0.85
            _push_app_log!(m,
                "[WARN] tap result is $(round(Int, density*100))% filled — " *
                "looks like a steady stream. Tap only the accents, or use :tap-strict for raw quantization.")
        end
        (analysis.period, cs, suf)
    end
    target_cps = round(1.0 / bar_dur; digits = 3)
    # Always emit + apply. If the new cps equals the current, set_cps!
    # is a cheap no-op and the user still sees the value reflected.
    ced = _active_editor(m)
    ced === nothing || _insert_line_after_cursor!(ced, "cps!($(target_cps))")
    sched !== nothing && set_cps!(sched, target_cps)
    slot = _tap_emit_line!(m, cells, suffix)
    # Eval the inserted @dN block — the user shouldn't have to press e.
    _eval_pattern_blocks!(m, Symbol[Symbol("d", slot)])
end

function _tap_emit_line!(m::RessacApp, cells, suffix)
    ed = _active_editor(m)
    ed === nothing && return 0
    slot = _next_free_d_slot(ed)
    line = "@d$(slot) p\"" * join(cells, " ") * "\""
    _insert_line_after_cursor!(ed, line)
    empty!(m.tap_events)
    _push_app_log!(m, "[INFO] tap → $(line)   $(suffix)")
    return slot
end

"""
    _tap_apply_tempo!(m)

Compute cps from the recorded taps and apply via `set_cps!`.
Convention: 4 taps = 1 bar (cycle), so cps = 1 / (4 × avg_interval).
With 3+ taps the average is more stable; 2 taps just take the
single inter-tap interval.
"""
function _tap_apply_tempo!(m::RessacApp)
    n = length(m.tap_events)
    if n < 2
        _push_app_log!(m, "[WARN] tap-tempo: need at least 2 taps")
        empty!(m.tap_events)
        return
    end
    avg_interval = (m.tap_events[end] - m.tap_events[1]) / (n - 1)
    cps = 1.0 / (4.0 * avg_interval)   # 4 taps per cycle convention
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[WARN] tap-tempo: no live session"); return)
    set_cps!(sched, cps)
    bpm = cps * 4 * 60
    _push_app_log!(m, "[INFO] tap-tempo → cps=$(round(cps; digits=3))  (~$(round(Int, bpm)) BPM, $(n) taps)")
    empty!(m.tap_events)
end
