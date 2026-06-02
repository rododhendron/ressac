# Live audio scope inside the synth pane. SC sends analysis frames
# (amplitude, waveform samples, spectrum bands) to Ressac via OSC on
# UDP port 57121; this file owns the listener, decodes frames into
# m.scope_data, and renders ASCII viz inside the synth pane.

const _SCOPE_LISTEN_PORT = 57121
const _SCOPE_CYCLE_ORDER = (:off, :amp, :wave, :spectrum,
                            :xy, :goni, :spectrogram, :peak,
                            :pitch, :onset, :hist, :corr,
                            :reservoir, Symbol("reservoir-graph"))
# Audio-in shared state — fed from the SC `\ressac_audio_in` SynthDef
# (see plugins/reservoir/audio_in.scd) via /ressac/audio_in packets at
# ~50 Hz. `_AUDIO_IN_VALUE` is a single mono amplitude (RMS); the
# values vector is for the optional N-band split.
const _AUDIO_IN_VALUE  = Ref{Float64}(0.0)
const _AUDIO_IN_BANDS  = Ref{Vector{Float64}}(Float64[])
const _AUDIO_IN_TS     = Ref{Float64}(0.0)

"""
    _handle_audio_in!(args)

OSC handler for `/ressac/audio_in <rms> [band1, band2, …]`. First arg
is the broadband RMS, subsequent args are optional per-band magnitudes.
Both are clamped to `[0, 1]` so the reservoir input scaling stays
predictable across input levels.
"""
function _handle_audio_in!(args)
    isempty(args) && return
    floats = Float64[]
    for v in args
        v isa Number && push!(floats, Float64(v))
    end
    isempty(floats) && return
    _AUDIO_IN_VALUE[] = clamp(floats[1], 0.0, 1.0)
    if length(floats) > 1
        bands = Float64[clamp(x, 0.0, 1.0) for x in floats[2:end]]
        _AUDIO_IN_BANDS[] = bands
    end
    _AUDIO_IN_TS[] = time()
    return
end

# Force-directed positions for the reservoir-graph view, cached on
# scope-mode switch. Tuple{Float64,Float64} in unit-square coords; the
# renderer scales to area.width × area.height.
const _APP_GRAPH_LAYOUT = Ref{Vector{Tuple{Float64,Float64}}}(Tuple{Float64,Float64}[])

"""
    _force_directed_layout(W, N; iterations=120) -> Vector{Tuple{Float64,Float64}}

Fruchterman-Reingold layout: nodes repel each other globally; edges
(weighted by |W|) pull connected pairs together. Result is a vector
of `N` (x, y) positions in `[0, 1]²`, where strongly-coupled units
cluster and weakly-connected units spread out.
"""
function _force_directed_layout(W::AbstractMatrix{Float64}, N::Int;
                                iterations::Int = 120,
                                edge_threshold_frac::Real = 0.15)
    pos = Vector{Tuple{Float64,Float64}}(undef, N)
    for i in 1:N
        θ = 2π * (i - 1) / N
        pos[i] = (0.5 + 0.35 * cos(θ), 0.5 + 0.35 * sin(θ))
    end
    k = sqrt(1.0 / N)
    max_w = maximum(abs, W) + 1e-12
    thr = edge_threshold_frac * max_w

    for iter in 1:iterations
        disp = fill((0.0, 0.0), N)
        # Repulsion — every pair.
        @inbounds for i in 1:N, j in (i+1):N
            dx = pos[i][1] - pos[j][1]
            dy = pos[i][2] - pos[j][2]
            d  = sqrt(dx * dx + dy * dy) + 1e-9
            f  = (k * k) / d
            ux, uy = dx / d, dy / d
            disp[i] = (disp[i][1] + f * ux, disp[i][2] + f * uy)
            disp[j] = (disp[j][1] - f * ux, disp[j][2] - f * uy)
        end
        # Attraction — symmetrised over W (undirected for layout purposes).
        @inbounds for i in 1:N, j in (i+1):N
            w = (abs(W[i, j]) + abs(W[j, i])) / 2
            w < thr && continue
            wnorm = w / max_w
            dx = pos[i][1] - pos[j][1]
            dy = pos[i][2] - pos[j][2]
            d  = sqrt(dx * dx + dy * dy) + 1e-9
            f  = wnorm * (d * d) / k
            ux, uy = dx / d, dy / d
            disp[i] = (disp[i][1] - f * ux, disp[i][2] - f * uy)
            disp[j] = (disp[j][1] + f * ux, disp[j][2] + f * uy)
        end
        # Cool-down + step limit (simulated annealing).
        temp = 0.08 * (1.0 - iter / iterations)
        @inbounds for i in 1:N
            dx, dy = disp[i]
            d = sqrt(dx * dx + dy * dy)
            if d > 1e-9
                lim = min(d, temp)
                px = pos[i][1] + (dx / d) * lim
                py = pos[i][2] + (dy / d) * lim
                pos[i] = (clamp(px, 0.0, 1.0), clamp(py, 0.0, 1.0))
            end
        end
    end
    pos
end

# Currently-attached reservoir for the `:reservoir` scope. Set by
# `:scope reservoir <varname>` which resolves the name in `Main` and
# turns on history recording. `nothing` when no reservoir is bound.
const _APP_SCOPE_RESERVOIR = Ref{Any}(nothing)
const _APP_SCOPE_RESERVOIR_NAME = Ref{Symbol}(:none)
# Wall-clock seconds of reservoir history that fit across the scope
# width. Part of the singleton scope state (one attached reservoir →
# one span), so it lives here alongside its siblings rather than on
# RessacApp — that lets the workspace ScopePane render without an app
# handle. The +/- keys adjust it; the legacy chrome reads it too.
const _APP_SCOPE_RESERVOIR_SPAN = Ref{Float64}(1.5)
# History ring size — large enough to cover a few seconds of activity
# at typical step rates (1000 Hz → 4 s @ 4000 entries). Memory cost is
# ~N bytes per snapshot ; for N=64 neurons that's ~256 KB total.
const _SCOPE_RESERVOIR_CAPACITY = 4000
# Rolling history for the waterfall spectrogram. Each entry is a
# 32-band magnitude snapshot; oldest at front, newest at back.
const _APP_SPECTROGRAM_HISTORY = Ref{Vector{Vector{Float32}}}(Vector{Float32}[])

"""
    _OSC_AD_HOC_HANDLERS

Ephemeral OSC address → callback table. Installed by callers who
need a one-off response (e.g. `_sc_meta_roundtrip` waiting for
`/ressac/sc-meta-reply`, or `_handle_sc_discover` waiting for
`/ressac/sc-discovery-done`). The callback receives the message
args and is typically expected to put a value into a caller-owned
Channel. Caller is responsible for installing the entry before
sending and removing it after (use a `finally`).
"""
const _OSC_AD_HOC_HANDLERS = Dict{String,Function}()

const _SCOPE_LISTENER_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SCOPE_LISTENER_SOCKET = Ref{Union{UDPSocket,Nothing}}(nothing)
const _SCOPE_LISTENER_RUNNING = Threads.Atomic{Bool}(false)
# Model-agnostic scope state — populated by the listener, read by
# the RessacApp at render time.
const _APP_SCOPE_DATA  = Ref{Vector{Float32}}(Float32[])
const _APP_SCOPE_TYPE  = Ref{Symbol}(:off)
const _APP_SCOPE_TS    = Ref{Float64}(0.0)
# Per-orbit RMS — updated from /ressac/rms packets emitted by SC's
# per-orbit Amplitude.kr taps. 12 slots, one per SuperDirt orbit
# (mapped from @d1..@d12). Indexed 1..12 (orbit 0 → slot [1]).
const _APP_ORBIT_RMS    = Ref{Vector{Float32}}(zeros(Float32, 12))
const _APP_ORBIT_RMS_TS = Ref{Vector{Float64}}(zeros(Float64, 12))
# Per-orbit peak hold — slowest-decay envelope of the RMS. Visual
# memory of the loudest recent moment (classic VU "peak" indicator).
# Peak rises instantly to a new max, then decays over `_PEAK_HOLD_SEC`.
const _APP_ORBIT_PEAK    = Ref{Vector{Float32}}(zeros(Float32, 12))
const _APP_ORBIT_PEAK_TS = Ref{Vector{Float64}}(zeros(Float64, 12))
const _PEAK_HOLD_SEC     = 1.5

# LiveModel scope dispatch / listener / packet decoder removed in
# phase-3 cleanup. The new path lives below: `_app_scope_set!`,
# `_app_scope_listener_loop`, the rendering helpers, and the external
# OSC trigger / RMS receivers.

"""
    _app_scope_set!(type)

Set the scope type for the new Tachikoma app. Doesn't need a model
reference; the listener writes to globals and the app reads from
them at render time. `type ∈ (:off, :amp, :wave, :spectrum)`.
"""
function _app_scope_set!(type::Symbol)
    type in _SCOPE_CYCLE_ORDER ||
        return false
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return false
    if type !== :off
        _ensure_app_scope_listener!()
    end
    _APP_SCOPE_TYPE[] = type
    empty!(_APP_SCOPE_DATA[])
    send_osc(sched.osc, encode(OSCMessage("/ressac/scope", Any[String(type)])))
    return true
end

function _ensure_app_scope_listener!()
    _SCOPE_LISTENER_SOCKET[] !== nothing && return
    try
        sock = UDPSocket()
        bind(sock, ip"127.0.0.1", _SCOPE_LISTEN_PORT)
        _SCOPE_LISTENER_SOCKET[] = sock
        _SCOPE_LISTENER_RUNNING[] = true
        _SCOPE_LISTENER_TASK[] = Threads.@spawn _app_scope_listener_loop()
    catch
    end
end

function _app_scope_listener_loop()
    sock = _SCOPE_LISTENER_SOCKET[]
    sock === nothing && return
    while _SCOPE_LISTENER_RUNNING[]
        try
            data = recv(sock)
            msg = try
                decode_message(data)
            catch
                continue
            end
            addr = String(msg.address)
            # External-trigger paths: /ressac/trigger fires a sample,
            # /ressac/set tweaks live state (cps, etc.). Useful for
            # MIDI controllers, hardware sequencers, TouchOSC layouts —
            # anything that can send OSC.
            if addr == "/ressac/trigger"
                _handle_external_trigger!(msg.args)
                continue
            elseif addr == "/ressac/set"
                _handle_external_set!(msg.args)
                continue
            elseif addr == "/ressac/rms"
                _handle_orbit_rms!(msg.args)
                continue
            elseif addr == "/ressac/audio_in"
                _handle_audio_in!(msg.args)
                continue
            elseif addr == "/ressac/synthError"
                _handle_synth_error!(msg.args)
                continue
            elseif addr == "/ressac/level"
                _handle_synth_level!(msg.args)
                continue
            elseif haskey(_OSC_AD_HOC_HANDLERS, addr)
                # Ephemeral handler installed by short-lived callers
                # (sc-discoverer waiting on /ressac/sc-meta-reply or
                # /ressac/sc-discovery-done, etc.). Last in the chain
                # so it can never override a built-in handler.
                try
                    _OSC_AD_HOC_HANDLERS[addr](msg.args)
                catch err
                    @warn "OSC ad-hoc handler '$addr' threw: $(sprint(showerror, err))"
                end
                continue
            end
            # Otherwise: scope data frame.
            floats = Float32[]
            skipped = 0
            for v in msg.args
                if v isa Number
                    if skipped < 2 && v isa Integer
                        skipped += 1
                        continue
                    end
                    push!(floats, Float32(v))
                end
            end
            if !isempty(floats)
                _APP_SCOPE_DATA[] = floats
                _APP_SCOPE_TS[]   = time()
                # Spectrogram waterfall: keep a rolling history so the
                # renderer can stack frames vertically. We append every
                # frame regardless of current scope type — the renderer
                # only reads it when type == :spectrogram, and the cost
                # of keeping ~60 small Vector{Float32} alive is trivial.
                if endswith(addr, "/spectrogram")
                    hist = _APP_SPECTROGRAM_HISTORY[]
                    push!(hist, copy(floats))
                    while length(hist) > 60
                        popfirst!(hist)
                    end
                end
            end
        catch err
            err isa InterruptException && break
        end
    end
end

# ---------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------

# `_scope_panel_height` + `_ScopePanel` widget (LiveModel-bound)
# removed in phase-3 cleanup. RessacApp has its own scope renderers
# (`_app_render_amp`, `_app_render_wave`, `_app_render_spectrum` in
# app.jl) which use Tachikoma's buffer API directly.

# ---------------------------------------------------------------------
# External OSC trigger / set — shared with the scope listener socket.
# Lets MIDI controllers, hardware sequencers, TouchOSC layouts, or
# any OSC-speaking tool drive Ressac without a Julia MIDI dep.
# Wire-up doc: docs/wiki/13-external-midi.md
# ---------------------------------------------------------------------

"""
    _handle_external_trigger!(args)

`/ressac/trigger s:<name> [key value ...]` — forward to SuperDirt
as a one-shot `/dirt/play`. Args after the name are passed through
unchanged so the sender can include `freq`, `gain`, `n`, `cut`, etc.
"""
function _handle_external_trigger!(args::Vector)
    isempty(args) && return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    # First arg is the sample/synth name.
    name = args[1] isa AbstractString ? String(args[1]) :
           args[1] isa Symbol ? String(args[1]) : return
    out = Any["s", name]
    # Pass through the rest verbatim. SuperDirt's /dirt/play accepts
    # alternating key/value pairs; we trust the caller to obey that.
    append!(out, args[2:end])
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", out)))
end

"""
    _handle_synth_error!(args)

`/ressac/synthError <name> <message>` — SC failed to build a SynthDef
and reported it back instead of silently replaying the previous synth.
Push the failure into the shared app log (`_APP_LOG[]` is rebound to
`m.logs`) so it's visible in the LOGS pane + chrome row.
"""
function _handle_synth_error!(args::Vector)
    name = length(args) >= 1 ? string(args[1]) : "?"
    emsg = length(args) >= 2 ? string(args[2]) : "build failed"
    log = _APP_LOG[]
    push!(log, "[SC ERROR] synth $name: $emsg")
    length(log) > 200 && popfirst!(log)
    return nothing
end

"""
    _handle_external_set!(args)

`/ressac/set s:<key> v:<value>` — mutate a global. Supported keys:
  "cps"  → set_cps!(value)
others are logged but ignored. The bridge is intentionally narrow:
arbitrary state mutation from outside would be hard to debug.
"""
function _handle_external_set!(args::Vector)
    length(args) >= 2 || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    key = args[1] isa AbstractString ? String(args[1]) :
          args[1] isa Symbol ? String(args[1]) : return
    val = args[2]
    if key == "cps" && val isa Number
        set_cps!(sched, Float64(val))
    end
end

"""
    _handle_orbit_rms!(args)

`/ressac/rms <nodeID:Int> <replyID:Int> <orbitIdx:Int> <amp:Float>`
SC SendReply prepends two ints (node + reply id); we skip them.
Stores the latest amp per orbit + timestamp so the `:mixer` renderer
can show real per-slot levels.
"""
function _handle_orbit_rms!(args::Vector)
    length(args) >= 4 || return
    orbit_raw = args[3]
    amp_raw   = args[4]
    orbit = orbit_raw isa Integer ? Int(orbit_raw) :
            orbit_raw isa Number  ? Int(round(orbit_raw)) : return
    (0 <= orbit < 12) || return
    amp = amp_raw isa Number ? Float32(amp_raw) : return
    now = time()
    _APP_ORBIT_RMS[][orbit + 1]    = amp
    _APP_ORBIT_RMS_TS[][orbit + 1] = now
    # Peak hold: rise instantly on a new max, decay only after
    # _PEAK_HOLD_SEC of silence below the current peak. Lets the eye
    # catch a transient that would otherwise be a one-frame flash.
    current_peak = _APP_ORBIT_PEAK[][orbit + 1]
    peak_ts      = _APP_ORBIT_PEAK_TS[][orbit + 1]
    if amp > current_peak || (now - peak_ts) > _PEAK_HOLD_SEC
        _APP_ORBIT_PEAK[][orbit + 1]    = amp
        _APP_ORBIT_PEAK_TS[][orbit + 1] = now
    end
end

"""
    _orbit_rms(slot::Symbol) -> Float32

Look up the most recent RMS reading for `slot` (`:d1` → orbit 0, etc).
Returns 0.0 if the slot isn't a `d<N>` form, the orbit is out of
range, or no reading has arrived in the last 1.5 s (so the bar drops
to zero when SC stops sending, instead of getting stuck on the last
value forever).
"""
function _orbit_rms(slot::Symbol)
    orbit = _orbit_for_slot(slot)
    orbit === nothing && return 0.0f0
    (0 <= orbit < 12) || return 0.0f0
    ts = _APP_ORBIT_RMS_TS[][orbit + 1]
    (time() - ts > 1.5) && return 0.0f0
    return _APP_ORBIT_RMS[][orbit + 1]
end

"""
    _orbit_peak(slot::Symbol) -> Float32

Peak-hold reading for `slot`. Same staleness rules as `_orbit_rms`
but the freshness window is `_PEAK_HOLD_SEC` — the peak indicator
naturally fades away if the slot stops producing audio.
"""
function _orbit_peak(slot::Symbol)
    orbit = _orbit_for_slot(slot)
    orbit === nothing && return 0.0f0
    (0 <= orbit < 12) || return 0.0f0
    ts = _APP_ORBIT_PEAK_TS[][orbit + 1]
    (time() - ts > _PEAK_HOLD_SEC) && return 0.0f0
    return _APP_ORBIT_PEAK[][orbit + 1]
end
