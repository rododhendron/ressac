# src/app_scope.jl
# Scope côté app : commande :scope, réservoir/chaos, entrée audio, et le
# rendu des 12 vues (amp, wave, spectrum, xy, spectrogram, peak, pitch,
# onset, hist, corr, reservoir, reservoir-graph).

function _scope_cycle_key!(m::RessacApp; dir::Int = +1)
    # Use the shared cycle order so new scope types added in
    # tui_scope.jl automatically show up under S without a separate
    # edit here. `dir = -1` reverses (used by scroll-down on the
    # scope pane).
    order = _SCOPE_CYCLE_ORDER
    i = findfirst(==(_APP_SCOPE_TYPE[]), order)
    i === nothing && (i = 1)
    next_i = dir > 0 ? (i % length(order)) + 1 :
                       (i == 1 ? length(order) : i - 1)
    next = order[next_i]
    _app_scope_set!(next)
    _push_app_log!(m, "[INFO] scope → $next")
end

"""
    _safe_history_snapshot(hist) -> Vector{Vector{Bool}}

Snapshot the reservoir's history vector without racing the scheduler
thread's `push!` / `popfirst!`. Slots that aren't yet assigned (the
array is mid-grow) are silently skipped. Cost = a length read + N
isassigned checks ; OK at 30 FPS.
"""
function _safe_history_snapshot(hist::Vector{Vector{Bool}})
    snap = Vector{Vector{Bool}}()
    n = length(hist)
    sizehint!(snap, n)
    for i in 1:n
        @inbounds isassigned(hist, i) || continue
        try
            push!(snap, hist[i])
        catch
            # mid-mutation; bail rather than crash the renderer
            break
        end
    end
    snap
end

"""
    _refresh_scope_reservoir!(m)

Re-resolve the scope's attached reservoir from its variable name.
Called automatically after a cascade re-eval rebinds the underlying
variable — keeps the visualisation tracking the live reservoir
instead of the now-stale object. Preserves the current scope mode
(raster vs graph) and recomputes the graph layout on demand.
"""
function _refresh_scope_reservoir!(m::RessacApp)
    name = _APP_SCOPE_RESERVOIR_NAME[]
    name === :none && return
    isdefined(Main, name) || return
    obj = getfield(Main, name)
    target = if obj isa Main.Reservoir.CoupledReservoirs
        obj.members[obj.output_idx]
    else
        obj
    end
    try
        Main.Reservoir.record_history!(target, _SCOPE_RESERVOIR_CAPACITY)
    catch
        return
    end
    _APP_SCOPE_RESERVOIR[] = target
    if _APP_SCOPE_TYPE[] === Symbol("reservoir-graph") &&
       target isa Main.Reservoir.AdExReservoir
        _APP_GRAPH_LAYOUT[] = _force_directed_layout(target.W, target.N)
    end
    return
end

function _audio_in_start!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[ERROR] :audio-in start — no live session"); return)
    _ensure_app_scope_listener!()
    code = "if(~ressacAudioInNode.notNil) { ~ressacAudioInNode.free }; " *
           "~ressacAudioInNode = Synth(\\ressac_audio_in);"
    send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[code])))
    _push_app_log!(m, "[INFO] :audio-in started — speak / play into the input")
    return
end

function _audio_in_stop!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[ERROR] :audio-in stop — no live session"); return)
    code = "if(~ressacAudioInNode.notNil) { ~ressacAudioInNode.free; ~ressacAudioInNode = nil };"
    send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[code])))
    _AUDIO_IN_VALUE[] = 0.0
    empty!(_AUDIO_IN_BANDS[])
    _push_app_log!(m, "[INFO] :audio-in stopped")
    return
end

function _scope_command!(m::RessacApp, type::Symbol)
    if _app_scope_set!(type)
        _push_app_log!(m, "[INFO] :scope $type")
        # For the graph view, pre-compute the force-directed layout
        # ONCE so the renderer can just look up positions every frame.
        # Cost ≈ N² × iterations; ~30 ms for N=32, iterations=120.
        if type === Symbol("reservoir-graph")
            r = _APP_SCOPE_RESERVOIR[]
            if r !== nothing && isdefined(Main, :Reservoir) &&
               r isa Main.Reservoir.AdExReservoir
                _APP_GRAPH_LAYOUT[] = _force_directed_layout(r.W, r.N)
            end
        end
    else
        _push_app_log!(m, "[ERROR] :scope — unknown type or no live session")
    end
end

"""
    _scope_reservoir!(m, varname)

Attach the global variable `varname` (must hold a reservoir) to the
visual scope. Enables history recording on the reservoir and switches
the scope into `:reservoir` mode. Detaches by re-running with a
non-reservoir or with `:off`.
"""
function _scope_reservoir!(m::RessacApp, varname::Symbol)
    if !isdefined(Main, varname)
        _push_app_log!(m, "[ERROR] :scope reservoir — '$varname' not defined in Main")
        return
    end
    obj = getfield(Main, varname)
    # We rely on `record_history!` being callable on the object —
    # the AdEx and RECA implementations both expose it, as does
    # any CoupledReservoirs (it forwards to the output member).
    try
        if obj isa Main.Reservoir.CoupledReservoirs
            target = obj.members[obj.output_idx]
            Main.Reservoir.record_history!(target, _SCOPE_RESERVOIR_CAPACITY)
            _APP_SCOPE_RESERVOIR[] = target
        else
            Main.Reservoir.record_history!(obj, _SCOPE_RESERVOIR_CAPACITY)
            _APP_SCOPE_RESERVOIR[] = obj
        end
        _APP_SCOPE_RESERVOIR_NAME[] = varname
        _APP_SCOPE_TYPE[] = :reservoir
        _push_app_log!(m, "[INFO] :scope reservoir $varname")
    catch err
        _push_app_log!(m, "[ERROR] :scope reservoir '$varname': " *
                          sprint(showerror, err))
    end
    return
end

"""
    _render_app_scope(m, area, buf)

Draw the current scope frame into `area`. Pulls latest data from the
`_APP_SCOPE_DATA` global. amp = bouncing meter; wave = braille
waveform via Canvas (zoom from `m.scope_zoom`); spectrum = vertical
bars (1 column per band).
"""
function _render_app_scope(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    type = _APP_SCOPE_TYPE[]
    data = _APP_SCOPE_DATA[]
    h, w = area.height, area.width
    h < 2 && return
    # Title row — show the zoom for wave so the user sees the keys' effect.
    title = if type === :wave
        "scope: wave  Y×$(round(m.scope_zoom; digits=2)) X×$(round(m.scope_zoom_x; digits=2))   (+/-/= amp,  >/</= time)"
    elseif type === :reservoir
        rname = _APP_SCOPE_RESERVOIR_NAME[]
        sp = round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)
        "scope: reservoir · $rname   span=$(sp)s   (+/- adjust, rows = neurons, ◼ = spike)"
    elseif type === Symbol("reservoir-graph")
        rname = _APP_SCOPE_RESERVOIR_NAME[]
        "scope: reservoir-graph · $rname   (● = spike fires, edges = synapses from firing units)"
    else
        "scope: $type   (S cycles, :scope <type> picks: amp wave spectrum xy goni spectrogram peak pitch onset hist corr reservoir reservoir-graph)"
    end
    TK.set_string!(buf, area.x, area.y, rpad(first(title, w), w),
                   TK.tstyle(:accent, bold=true))
    body_y = area.y + 1
    body_h = h - 1
    body_area = TK.Rect(area.x, body_y, w, body_h)
    # Reservoir scope handles itself — it has no `data` from the OSC
    # listener, only reads from the attached reservoir's history field.
    if type === :reservoir
        _app_render_reservoir(body_area, buf, _APP_SCOPE_RESERVOIR_SPAN[])
        return
    end
    if type === Symbol("reservoir-graph")
        _app_render_reservoir_graph(body_area, buf, _APP_SCOPE_RESERVOIR_SPAN[])
        return
    end
    if isempty(data)
        TK.set_string!(buf, area.x, body_y,
                       "  (waiting for audio — press T to test the synth)",
                       TK.tstyle(:text_dim))
        return
    end
    if type === :amp
        _app_render_amp(data, body_area, buf)
    elseif type === :wave
        _app_render_wave(data, body_area, buf;
                         zoom = m.scope_zoom, zoom_x = m.scope_zoom_x)
    elseif type === :spectrum
        _app_render_spectrum(data, body_area, buf)
    elseif type === :xy
        _app_render_xy(data, body_area, buf; rotate45=false)
    elseif type === :goni
        _app_render_xy(data, body_area, buf; rotate45=true)
    elseif type === :spectrogram
        _app_render_spectrogram(body_area, buf)
    elseif type === :peak
        _app_render_peak(data, body_area, buf)
    elseif type === :pitch
        _app_render_pitch(data, body_area, buf)
    elseif type === :onset
        _app_render_onset(data, body_area, buf)
    elseif type === :hist
        _app_render_hist(data, body_area, buf)
    elseif type === :corr
        _app_render_corr(data, body_area, buf)
    end
end

"""
    _app_render_reservoir(area, buf)

Raster plot of the currently-attached reservoir's spike history. Rows
are neurons (downsampled if N > area.height); columns are recent steps
(oldest left, newest right). A solid block ◼ marks a spike at that
(neuron, step) cell. If the reservoir is RECA, the plot looks like a
classic cellular-automaton trail.
"""
function _app_render_reservoir(area::TK.Rect, buf::TK.Buffer,
                               span_seconds::Float64 = _APP_SCOPE_RESERVOIR_SPAN[])
    r = _APP_SCOPE_RESERVOIR[]
    if r === nothing
        TK.set_string!(buf, area.x, area.y,
                       "  (no reservoir attached — use :scope reservoir <var>)",
                       TK.tstyle(:text_dim))
        return
    end
    # Snapshot the history vector once so the scheduler thread can keep
    # pushing while we render. `r.history` is mutated by `step!` on the
    # scheduler task, so a live `hist[i]` would race with `push!` /
    # `popfirst!` (the array can be in a transient state with undef
    # backing slots during reallocation).
    hist = _safe_history_snapshot(r.history)
    if isempty(hist)
        TK.set_string!(buf, area.x, area.y,
                       "  (waiting for spikes — drive the reservoir to populate)",
                       TK.tstyle(:text_dim))
        return
    end
    N = length(r)
    H = area.height
    W = area.width
    H < 1 || W < 1 && return

    # Time-span view: `span_seconds` of recent wall-clock time fits
    # into the area. Estimate step rate from the live scheduler.
    sched = _LIVE_SCHEDULER[]
    cps = sched === nothing ? 0.5 : sched.cps
    steps_per_sec = r.spc * cps
    n_visible_steps = max(1,
        round(Int, span_seconds * steps_per_sec))
    first_hist_idx = max(1, length(hist) - n_visible_steps + 1)

    # Braille rendering: each terminal cell encodes a 2 cols × 4 rows
    # sub-grid → 8× density. "Now" sits on the right edge so newer
    # spikes always enter from the right and scroll leftward.
    sub_W = W * 2
    sub_H = H * 4
    steps_per_subcol = n_visible_steps / sub_W
    n_sub_rows = min(N, sub_H)
    sub_row_of_neuron = n_sub_rows == N ?
        collect(1:N) :
        [round(Int, 1 + (i - 1) * (N - 1) / (n_sub_rows - 1)) for i in 1:n_sub_rows]
    last_hist_idx = length(hist)

    # Pre-compute the (col, row) → bit mapping for Braille dots:
    #   col=0,row=0→dot1 (bit0)   col=1,row=0→dot4 (bit3)
    #   col=0,row=1→dot2 (bit1)   col=1,row=1→dot5 (bit4)
    #   col=0,row=2→dot3 (bit2)   col=1,row=2→dot6 (bit5)
    #   col=0,row=3→dot7 (bit6)   col=1,row=3→dot8 (bit7)
    bit_of(col0::Int, row0::Int) =
        col0 == 0 ? (row0 == 0 ? 0 : row0 == 1 ? 1 : row0 == 2 ? 2 : 6) :
                    (row0 == 0 ? 3 : row0 == 1 ? 4 : row0 == 2 ? 5 : 7)

    active_style = TK.tstyle(:accent, bold = true)
    medium_style = TK.tstyle(:accent)
    quiet_style  = TK.tstyle(:text_dim)

    for cell_col in 1:W
        for cell_row in 1:H
            # 4×2 sub-cells make up this Braille cell.
            bits = 0
            spike_count = 0
            for sub_col_off in 0:1, sub_row_off in 0:3
                sub_col = (cell_col - 1) * 2 + sub_col_off + 1   # 1-based
                sub_row = (cell_row - 1) * 4 + sub_row_off + 1
                sub_row > n_sub_rows && continue
                n_idx = sub_row_of_neuron[sub_row]
                # Right-align: rightmost sub_col = newest history entry.
                offset_from_right = sub_W - sub_col
                h_hi = last_hist_idx - floor(Int, offset_from_right * steps_per_subcol)
                h_lo = last_hist_idx - ceil(Int, (offset_from_right + 1) * steps_per_subcol) + 1
                h_lo > length(hist) && continue
                h_lo = clamp(h_lo, 1, length(hist))
                h_hi = clamp(h_hi, h_lo, length(hist))
                spiked = false
                @inbounds for h_idx in h_lo:h_hi
                    snap = hist[h_idx]
                    if n_idx <= length(snap) && snap[n_idx]
                        spiked = true
                        break
                    end
                end
                if spiked
                    bits |= 1 << bit_of(sub_col_off, sub_row_off)
                    spike_count += 1
                end
            end
            x = area.x + cell_col - 1
            y = area.y + cell_row - 1
            if bits == 0
                TK.set_char!(buf, x, y, '⠀', quiet_style)
            else
                ch = Char(0x2800 + bits)
                # Style by density — many sub-cells active = brighter.
                style = spike_count >= 5 ? active_style :
                        spike_count >= 2 ? medium_style :
                                            TK.tstyle(:accent)
                TK.set_char!(buf, x, y, ch, style)
            end
        end
    end
    return
end

"""
    _app_render_reservoir_graph(area, buf)

Spatial graph view of the attached reservoir. Neurons sit on a circle;
edges are drawn FROM currently-spiking neurons toward the neurons
they connect to. Edge character density (·, ▒, ▓) maps to absolute
weight; positive weights render in :success (excitatory), negative
in :error (inhibitory). Quiet neurons stay as `o`, spikers as `●` in
:accent bold so they "blink" each step they fire.

Only works on plain `AdExReservoir` (needs the W matrix). For RECA
or coupled groups, the raster scope is more meaningful.
"""
function _app_render_reservoir_graph(area::TK.Rect, buf::TK.Buffer,
                                     span_seconds::Float64 = _APP_SCOPE_RESERVOIR_SPAN[])
    r = _APP_SCOPE_RESERVOIR[]
    if r === nothing
        TK.set_string!(buf, area.x, area.y,
                       "  (no reservoir attached — use :scope reservoir <var>)",
                       TK.tstyle(:text_dim))
        return
    end
    if !isdefined(Main, :Reservoir) || !(r isa Main.Reservoir.AdExReservoir)
        TK.set_string!(buf, area.x, area.y,
                       "  (graph view needs an AdEx reservoir — try :scope reservoir for raster)",
                       TK.tstyle(:text_dim))
        return
    end
    N = r.N
    H, W = area.height, area.width
    H < 3 || W < 6 && return

    # Position layout: prefer the cached force-directed layout (set by
    # `:scope reservoir-graph`); fall back to a circle if absent.
    layout = _APP_GRAPH_LAYOUT[]
    positions = Vector{Tuple{Int,Int}}(undef, N)
    if length(layout) == N
        # layout coords are in [0, 1]² — map into the area with a small
        # inset so nodes don't sit right on the border.
        inset_x = 2
        inset_y = 1
        ux_w = max(1, W - 2 * inset_x)
        uy_h = max(1, H - 2 * inset_y)
        for i in 1:N
            ux, uy = layout[i]
            x = round(Int, area.x + inset_x + ux * ux_w)
            y = round(Int, area.y + inset_y + uy * uy_h)
            positions[i] = (clamp(x, area.x, area.x + W - 1),
                            clamp(y, area.y, area.y + H - 1))
        end
    else
        cx = area.x + W / 2
        cy = area.y + H / 2
        rx = max(2.0, (W - 4) / 2)
        ry = max(1.5, (H - 2) / 2)
        for i in 1:N
            θ = 2π * (i - 1) / N - π / 2
            x = round(Int, cx + rx * cos(θ))
            y = round(Int, cy + ry * sin(θ))
            positions[i] = (clamp(x, area.x, area.x + W - 1),
                            clamp(y, area.y, area.y + H - 1))
        end
    end

    # Edge weight threshold — only draw the meaningful synapses to keep
    # the picture readable. Use 30% of the max |W| as the floor.
    max_w = maximum(abs, r.W)
    threshold = max_w * 0.3

    # Snapshot history once — see _app_render_reservoir for the race
    # rationale (scheduler thread writes while we read).
    hist = _safe_history_snapshot(r.history)
    sched = _LIVE_SCHEDULER[]
    cps = sched === nothing ? 0.5 : sched.cps
    steps_per_sec = r.N == 0 ? 1.0 : r.spc * cps
    n_window = clamp(round(Int, span_seconds * steps_per_sec),
                     1, length(hist))
    recency = zeros(Float64, N)
    if !isempty(hist) && n_window > 0
        first_idx = max(1, length(hist) - n_window + 1)
        @inbounds for h_idx in first_idx:length(hist)
            snap = hist[h_idx]
            # Newer entries weighted higher (linear ramp).
            weight = (h_idx - first_idx + 1) / n_window
            for i in 1:min(N, length(snap))
                snap[i] && (recency[i] = max(recency[i], weight))
            end
        end
    end

    # Brightness tiers from recency.
    node_glyph(rec) = rec > 0.8 ? ('●', TK.tstyle(:accent, bold = true)) :
                      rec > 0.4 ? ('●', TK.tstyle(:accent)) :
                      rec > 0.1 ? ('◯', TK.tstyle(:text)) :
                                    ('o', TK.tstyle(:text_dim))
    edge_style(w, src_rec) = begin
        base = w > 0 ? TK.tstyle(:success) : TK.tstyle(:error)
        src_rec > 0.5 ? (w > 0 ? TK.tstyle(:success, bold = true) :
                                  TK.tstyle(:error,   bold = true)) :
                        base
    end

    # Draw edges from any RECENTLY active neuron (not just current step).
    @inbounds for src in 1:N
        src_rec = recency[src]
        src_rec < 0.1 && continue
        sx, sy = positions[src]
        for dst in 1:N
            dst == src && continue
            w = r.W[dst, src]
            absw = abs(w)
            absw < threshold && continue
            tx, ty = positions[dst]
            density = absw / max_w
            # Edge char picks up both weight magnitude AND src recency
            # so fresher spikes leave brighter edge trails.
            combined = density * (0.4 + 0.6 * src_rec)
            ch = combined > 0.55 ? '▓' :
                 combined > 0.25 ? '▒' : '·'
            style = edge_style(w, src_rec)
            for (x, y) in _bresenham_line(sx, sy, tx, ty)
                (x == sx && y == sy) && continue
                (x == tx && y == ty) && continue
                TK.set_char!(buf, x, y, ch, style)
            end
        end
    end

    # Draw nodes on top — brightness reflects recency.
    @inbounds for i in 1:N
        x, y = positions[i]
        ch, style = node_glyph(recency[i])
        TK.set_char!(buf, x, y, ch, style)
    end
    return
end

"Integer-only line walk between two points (Bresenham). Used by the
reservoir graph view to draw edges on the character grid."
function _bresenham_line(x0::Int, y0::Int, x1::Int, y1::Int)
    pts = Tuple{Int,Int}[]
    dx = abs(x1 - x0); dy = abs(y1 - y0)
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx - dy
    x, y = x0, y0
    while true
        push!(pts, (x, y))
        x == x1 && y == y1 && break
        e2 = 2 * err
        if e2 > -dy
            err -= dy; x += sx
        end
        if e2 < dx
            err += dx; y += sy
        end
    end
    pts
end

function _app_render_amp(data, area::TK.Rect, buf::TK.Buffer)
    amp = clamp(Float64(data[1]), 0.0, 1.0)
    bar_w = floor(Int, amp * area.width)
    bar = "▌" ^ bar_w
    db = amp > 0 ? round(20 * log10(amp); digits=1) : -Inf
    label = " amp $(round(amp; digits=3)) ($(db) dB)"
    TK.set_string!(buf, area.x, area.y,
                   rpad(bar * label, area.width),
                   TK.tstyle(:primary))
end

function _app_render_wave(data, area::TK.Rect, buf::TK.Buffer;
                          zoom::Float64 = 1.0, zoom_x::Float64 = 1.0)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # X-zoom: keep a slice of `data` centred around the midpoint. Larger
    # zoom_x → narrower visible slice → fewer samples stretched across
    # the same column count, so each cycle of the waveform appears
    # wider on screen. zoom_x<1 isn't very useful (only 64 samples
    # arrive — you'd just be padding) but we still clamp at >=2 samples
    # to keep the renderer's interpolation defined.
    n_visible = clamp(round(Int, n / max(zoom_x, 0.01)), 2, n)
    start_idx = max(1, (n - n_visible) ÷ 2 + 1)
    end_idx   = min(n, start_idx + n_visible - 1)
    sliced = @view data[start_idx:end_idx]
    nv = length(sliced)
    # Adaptive peak normalize so quiet signals fill the panel; user zoom
    # then multiplies on top of that. zoom=1.0 means "fill the panel";
    # zoom>1 pushes the wave off-screen on transients (deliberate — lets
    # the user see fine structure in quiet sections).
    peak = maximum(abs.(sliced); init=0.001f0)
    auto_scale = peak < 0.05 ? 1.0 : 1.0 / max(Float64(peak), 0.05)
    scale = auto_scale * zoom
    centre_dy = height_dots ÷ 2
    last_dy = centre_dy
    for dx in 0:(width_dots - 1)
        sample_idx = clamp(round(Int, dx / max(1, width_dots - 1) * (nv - 1)) + 1, 1, nv)
        val = clamp(Float64(sliced[sample_idx]) * scale, -1.0, 1.0)
        dy = clamp(round(Int, (1 - (val + 1) / 2) * (height_dots - 1)), 0, height_dots - 1)
        TK.set_point!(canvas, dx, dy)
        if dx > 0
            for fill_dy in min(dy, last_dy):max(dy, last_dy)
                TK.set_point!(canvas, dx, fill_dy)
            end
        end
        last_dy = dy
    end
    TK.render(canvas, area, buf)
end

function _app_render_spectrum(data, area::TK.Rect, buf::TK.Buffer)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # Map each x-column in dot-space to its corresponding band. This
    # produces filled bars instead of skinny one-dot spikes.
    for dx in 0:(width_dots - 1)
        band_idx = clamp(floor(Int, dx * n / width_dots) + 1, 1, n)
        val = clamp(Float64(data[band_idx]), 0.0, 1.0)
        bar_dy = clamp(round(Int, val * (height_dots - 1)), 0, height_dots - 1)
        for h in 0:bar_dy
            TK.set_point!(canvas, dx, height_dots - 1 - h)
        end
    end
    TK.render(canvas, area, buf)
end

"""
    _app_render_xy(data, area, buf; rotate45=false)

XY / Lissajous scatter of stereo samples. `data` is laid out as
[L0, R0, L1, R1, …] — we draw each (L, R) as a single dot in the
canvas, mapping `[-1, 1]` × `[-1, 1]` to the panel rect. When
`rotate45` is true we rotate to (L+R, L-R) for goniometer mode:
mono signals collapse to a vertical line, perfectly out-of-phase
ones collapse to horizontal — the standard mixing aid.
"""
function _app_render_xy(data, area::TK.Rect, buf::TK.Buffer; rotate45::Bool=false)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n < 4 && (TK.render(canvas, area, buf); return)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    peak = maximum(abs.(data); init=0.001f0)
    scale = peak < 0.1 ? 1.0 : 1.0 / max(Float64(peak), 0.1)
    cx = width_dots ÷ 2
    cy = height_dots ÷ 2
    # Cross-hairs (mid lines, very faint) — anchors the axes when the
    # signal is quiet. Only the centre column + centre row.
    for dx in 0:(width_dots - 1)
        TK.set_point!(canvas, dx, cy)
    end
    for dy in 0:(height_dots - 1)
        TK.set_point!(canvas, cx, dy)
    end
    # Lissajous: draw lines between consecutive points so the trace
    # forms a closed curve instead of a sparse scatter.
    last_dx = last_dy = -1
    for i in 1:2:(n-1)
        l = Float64(data[i]) * scale
        r = Float64(data[i+1]) * scale
        x, y = if rotate45
            ((l + r) / sqrt(2), (l - r) / sqrt(2))
        else
            (l, r)
        end
        dx = clamp(cx + round(Int, x * cx), 0, width_dots - 1)
        dy = clamp(cy - round(Int, y * cy), 0, height_dots - 1)
        if last_dx >= 0
            TK.line!(canvas, last_dx, last_dy, dx, dy)
        else
            TK.set_point!(canvas, dx, dy)
        end
        last_dx, last_dy = dx, dy
    end
    TK.render(canvas, area, buf)
end

"""
    _app_render_spectrogram(area, buf)

Waterfall display: vertical = time (most recent at the bottom),
horizontal = frequency. Pulls from `_APP_SPECTROGRAM_HISTORY` so
each call uses the buffered last ~60 frames. Shading via the
░▒▓█ ramp — no colour gradient needed.
"""
function _app_render_spectrogram(area::TK.Rect, buf::TK.Buffer)
    history = _APP_SPECTROGRAM_HISTORY[]
    isempty(history) && return
    rows = min(area.height, length(history))
    cols = area.width
    glyphs = (' ', '░', '▒', '▓', '█')
    # Latest frame at the bottom of the panel; older frames stack upward.
    for r in 0:(rows - 1)
        frame_idx = length(history) - r
        frame_idx < 1 && break
        frame = history[frame_idx]
        nb = length(frame)
        nb == 0 && continue
        for c in 0:(cols - 1)
            band = clamp(floor(Int, c * nb / cols) + 1, 1, nb)
            v = clamp(Float64(frame[band]), 0.0, 1.0)
            g = glyphs[clamp(1 + floor(Int, v * (length(glyphs) - 1)), 1, length(glyphs))]
            TK.set_string!(buf, area.x + c, area.y + (area.height - 1 - r),
                           string(g), TK.tstyle(:primary))
        end
    end
end

"""
    _app_render_peak(data, area, buf)

VU-style peak meter with a slow-decay hold marker and a clip
indicator. `data = [peak, hold, clipped]`.
"""
function _app_render_peak(data, area::TK.Rect, buf::TK.Buffer)
    length(data) >= 1 || return
    peak = clamp(Float64(data[1]), 0.0, 1.0)
    hold = length(data) >= 2 ? clamp(Float64(data[2]), 0.0, 1.0) : peak
    clipped = length(data) >= 3 && Float64(data[3]) > 0.5
    w = area.width
    bar_w = floor(Int, peak * w)
    hold_x = floor(Int, hold * w)
    bar = "█" ^ bar_w
    pad = " " ^ max(0, w - bar_w)
    style_bar = clipped ? TK.tstyle(:error, bold=true) : TK.tstyle(:primary)
    TK.set_string!(buf, area.x, area.y, bar * pad, style_bar)
    if 0 <= hold_x < w
        TK.set_string!(buf, area.x + hold_x, area.y, "│",
                       TK.tstyle(:warning, bold=true))
    end
    db = peak > 0 ? round(20 * log10(peak); digits=1) : -Inf
    label = "  peak $(round(peak; digits=3))  hold $(round(hold; digits=3))  ($(db) dB)" *
            (clipped ? "  CLIP" : "")
    TK.set_string!(buf, area.x, area.y + 1,
                   first(label, w), clipped ? TK.tstyle(:error) : TK.tstyle(:text_dim))
end

"""
    _app_render_pitch(data, area, buf)

Pitch tracker. `data = [freq, hasFreq]`. Shows Hz reading, derives
a note name from equal-temperament, dims the line when hasFreq <
0.5 (low confidence).
"""
function _app_render_pitch(data, area::TK.Rect, buf::TK.Buffer)
    length(data) >= 1 || return
    freq = Float64(data[1])
    conf = length(data) >= 2 ? Float64(data[2]) : 1.0
    if freq < 20 || freq > 20000
        TK.set_string!(buf, area.x, area.y,
                       "  pitch — no signal", TK.tstyle(:text_dim))
        return
    end
    midi = 69 + 12 * log2(freq / 440)
    note_idx = mod(round(Int, midi), 12) + 1
    octave = (round(Int, midi) ÷ 12) - 1
    notes = ("C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B")
    label = "  ♬  $(round(freq; digits=1)) Hz   →   $(notes[note_idx])$octave   (conf $(round(conf; digits=2)))"
    style = conf > 0.5 ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, area.x, area.y, first(label, area.width), style)
end

"""
    _app_render_onset(data, area, buf)

Onset detector flash. When a transient is detected SC sends a
sustained ~80 ms latch (1.0 → 0). We render a full-panel block
proportional to that latch value, so the panel "pulses" on each
hit.
"""
function _app_render_onset(data, area::TK.Rect, buf::TK.Buffer)
    v = length(data) >= 1 ? clamp(Float64(data[1]), 0.0, 1.0) : 0.0
    # Single-row pulse — width tracks the latch value so it visually
    # decays after each hit. A label underneath shows the live value
    # so the user knows the detector is alive even between hits.
    bar_w = floor(Int, v * area.width)
    bar = "█" ^ bar_w * "·" ^ (area.width - bar_w)
    style = v > 0.5 ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, area.x, area.y, first(bar, area.width), style)
    label = "  onset detector — flashes on each transient (latch $(round(v; digits=2)))"
    if area.height >= 2
        TK.set_string!(buf, area.x, area.y + 1,
                       first(label, area.width), TK.tstyle(:text_dim))
    end
end

"""
    _app_render_hist(data, area, buf)

Sample-value histogram. 32 vertical bars showing how often a
sample landed in each amplitude bin (-1 to +1). Useful for spotting
DC offset or asymmetric distortion.
"""
function _app_render_hist(data, area::TK.Rect, buf::TK.Buffer)
    canvas = TK.Canvas(area.width, area.height; style=TK.tstyle(:primary))
    n = length(data)
    n == 0 && (TK.render(canvas, area, buf); return)
    peak = maximum(data; init=0.001f0)
    norm = peak < 0.01 ? 1.0 : 1.0 / Float64(peak)
    width_dots  = area.width * 2
    height_dots = area.height * 4
    # Fill every dot column with the matching bin so bars look solid,
    # not skinny one-dot spikes (same fix as spectrum).
    for dx in 0:(width_dots - 1)
        band_idx = clamp(floor(Int, dx * n / width_dots) + 1, 1, n)
        v = clamp(Float64(data[band_idx]) * norm, 0.0, 1.0)
        bar_h = clamp(round(Int, v * (height_dots - 1)), 0, height_dots - 1)
        for h in 0:bar_h
            TK.set_point!(canvas, dx, height_dots - 1 - h)
        end
    end
    TK.render(canvas, area, buf)
end

"""
    _app_render_corr(data, area, buf)

Stereo correlation meter. -1 = out of phase, 0 = uncorrelated,
+1 = mono. Standard mixing aid — red zone below 0 warns about
mono-summing issues.
"""
function _app_render_corr(data, area::TK.Rect, buf::TK.Buffer)
    v = length(data) >= 1 ? clamp(Float64(data[1]), -1.0, 1.0) : 0.0
    w = area.width
    cx = w ÷ 2
    pos = clamp(cx + round(Int, v * cx), 0, w - 1)
    # Draw the axis line.
    line_chars = fill('─', w)
    line_chars[cx + 1] = '┼'
    line_chars[clamp(pos + 1, 1, w)] = '●'
    TK.set_string!(buf, area.x, area.y, String(line_chars),
                   v < 0 ? TK.tstyle(:error, bold=true) : TK.tstyle(:primary))
    label = "  L-R correlation: $(round(v; digits=3))   (-1 phase-inverted  ·  0 stereo  ·  +1 mono)"
    TK.set_string!(buf, area.x, area.y + 1,
                   first(label, w), TK.tstyle(:text_dim))
end
