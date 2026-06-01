# src/pane_tuning.jl
# :tuning pane — circular "necklace" visualization of a Scale.
# 360° always maps to one period, regardless of period_cents — so
# octave-based scales and Bohlen-Pierce tritave scales look the same
# shape, only the tick labels differ (cents or ratios).
#
# Recently-played degrees pulse via `_LAST_NOTES`: the scheduler
# pushes :note values as events ship; the pane highlights ticks
# whose semitones match (within a few cents tolerance) for ~2 s.

"""
    _LAST_NOTES

Ref to a circular buffer of recently-played `:note` values with
timestamps. Pushed by the scheduler (or any event-shipping path),
read by TuningPane render to pulse-highlight matching degrees.

Format: `Vector{Tuple{Float64, Float64}}` of `(note_semitones, t)`
where `t` is `time()` at ship.
"""
const _LAST_NOTES = Ref(Tuple{Float64, Float64}[])
const _LAST_NOTES_TTL = 2.0   # seconds before a played-note fades

"""
    push_played_note!(note::Real)

Append a played note (in semitones) to the recently-played buffer.
Stale entries (older than `_LAST_NOTES_TTL`) are pruned in place
so the buffer stays bounded.
"""
function push_played_note!(note::Real)
    now = time()
    buf = _LAST_NOTES[]
    push!(buf, (Float64(note), now))
    filter!(p -> (now - p[2]) <= _LAST_NOTES_TTL, buf)
    return nothing
end

mutable struct TuningPane <: PaneImpl
    scale_ref::Symbol            # registry name; resolved each render
    label_mode::Symbol           # :cents | :ratio
end

function _tuning_pane_ctor(args::AbstractDict)
    name_str = String(get(args, "name", "chromatic"))
    return TuningPane(Symbol(name_str), :cents)
end

# ── Render ──────────────────────────────────────────────────────────

function render!(p::TuningPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    s = lookup_scale(p.scale_ref)
    title_str = s === nothing ?
        "TUNING · :$(p.scale_ref) (not found)" :
        "TUNING · :$(p.scale_ref)"
    _render_pane_block_simple!(rect, title_str, buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 6 || inner.height < 4) && return

    if s === nothing
        TK.set_string!(buf, inner.x + 1, inner.y + 1,
                       "(unknown scale — try :scale list)",
                       TK.tstyle(:text_dim))
        return
    end

    _render_tuning_circle!(p, s, inner, buf)
    _render_tuning_footer!(p, s, inner, buf)
    return nothing
end

# Place each degree on the necklace at angle 2π * cents/period,
# starting at 12 o'clock (-π/2). Cells are taller than they are
# wide so we use an x-radius ≈ 2× the y-radius to keep the figure
# round-looking in monospace.
function _render_tuning_circle!(p::TuningPane, s::Scale,
                                inner::TK.Rect, buf::TK.Buffer)
    # Reserve the last row for the footer (name + period).
    body_h = max(1, inner.height - 1)
    cx = inner.x + inner.width ÷ 2
    cy = inner.y + body_h ÷ 2
    # Padding for labels — leave 4 cells horizontal, 1 cell vertical
    # on each side so cent labels don't get clipped.
    rx = max(2, (inner.width  ÷ 2) - 4)
    ry = max(1, (body_h        ÷ 2) - 1)

    # Sample the recent-played buffer once per render so the same
    # degree fade matches everywhere on the screen.
    now = time()
    played = _LAST_NOTES[]

    for (i, c) in enumerate(s.cents)
        θ = 2π * c / s.period_cents - π / 2
        tx = cx + round(Int, rx * cos(θ))
        ty = cy + round(Int, ry * sin(θ))
        if !(inner.x <= tx < inner.x + inner.width &&
             inner.y <= ty < inner.y + body_h)
            continue
        end
        # Is this degree currently glowing from a recent :note?
        deg_semis = c / 100.0
        glow = _played_glow_intensity(deg_semis, s, played, now)
        tick = glow > 0.0 ? "●" : "○"
        style = glow > 0.5 ?
            TK.tstyle(:accent, bold = true) :
            glow > 0.0 ?
                TK.tstyle(:accent) :
                TK.tstyle(:text)
        TK.set_string!(buf, tx, ty, tick, style)
        # Label outside the tick, on the "outer" side of the circle.
        label = _tuning_tick_label(p, s, i)
        lx = cx + round(Int, (rx + 3) * cos(θ)) - (length(label) ÷ 2)
        ly = cy + round(Int, (ry + 1) * sin(θ))
        if inner.x <= lx && lx + length(label) <= inner.x + inner.width &&
           inner.y <= ly < inner.y + body_h
            label_style = glow > 0.0 ?
                TK.tstyle(:accent, bold = true) :
                TK.tstyle(:text_dim)
            TK.set_string!(buf, lx, ly, label, label_style)
        end
    end
end

# Match a played :note (semitones) against a scale degree. The note
# might be in ANY period above/below root — fold it into one period
# before comparing. Glow = 1.0 at exact match, decays linearly with
# (now - timestamp) over _LAST_NOTES_TTL.
function _played_glow_intensity(degree_semis::Float64, s::Scale,
                                played::Vector{Tuple{Float64,Float64}},
                                now::Float64)
    isempty(played) && return 0.0
    period_semis = s.period_cents / 100.0
    best = 0.0
    for (note, t) in played
        age = now - t
        age > _LAST_NOTES_TTL && continue
        # Fold note into one period (relative to the scale root).
        folded = mod(note, period_semis)
        diff = abs(folded - degree_semis)
        # Wrap-around distance (e.g. note 11.99 vs degree 0.0 → 0.01)
        diff = min(diff, period_semis - diff)
        if diff < 0.3   # ~30 cents tolerance
            glow = (1.0 - age / _LAST_NOTES_TTL) * (1.0 - diff / 0.3)
            best = max(best, glow)
        end
    end
    return clamp(best, 0.0, 1.0)
end

function _tuning_tick_label(p::TuningPane, s::Scale, i::Int)
    c = s.cents[i]
    if p.label_mode === :ratio
        # Ratio = 2^(cents/1200) (or 3^x for tritave) — show as
        # decimal with 2 digits.
        r = 2.0 ^ (c / 1200.0)
        return string(round(r; digits = 2))
    end
    # :cents default
    return string(round(Int, c))
end

function _render_tuning_footer!(p::TuningPane, s::Scale,
                                inner::TK.Rect, buf::TK.Buffer)
    fy = inner.y + inner.height - 1
    msg = "$(length(s.cents)) deg · period $(round(Int, s.period_cents))¢ · " *
          "label: $(p.label_mode) (press r to toggle)"
    chunk = first(msg, inner.width)
    TK.set_string!(buf, inner.x, fy, chunk, TK.tstyle(:text_dim))
end

# ── Key handling ────────────────────────────────────────────────────

function handle_key!(p::TuningPane, evt)
    if evt isa TK.KeyEvent && evt.key === :char && evt.char == 'r'
        p.label_mode = p.label_mode === :cents ? :ratio : :cents
        return true
    end
    return false
end

# ── Contract ────────────────────────────────────────────────────────

title(p::TuningPane) = "tuning:$(p.scale_ref)"

serialize(p::TuningPane) = Dict{String,Any}(
    "name"       => String(p.scale_ref),
    "label_mode" => String(p.label_mode),
)

on_close!(::TuningPane) = nothing

register_pane_kind!(:tuning, _tuning_pane_ctor)
