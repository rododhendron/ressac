# Live audio scope inside the synth pane. SC sends analysis frames
# (amplitude, waveform samples, spectrum bands) to Ressac via OSC on
# UDP port 57121; this file owns the listener, decodes frames into
# m.scope_data, and renders ASCII viz inside the synth pane.

const _SCOPE_LISTEN_PORT = 57121
const _SCOPE_CYCLE_ORDER = (:off, :amp, :wave, :spectrum,
                            :xy, :goni, :spectrogram, :peak,
                            :pitch, :onset, :hist, :corr)
# Rolling history for the waterfall spectrogram. Each entry is a
# 32-band magnitude snapshot; oldest at front, newest at back.
const _APP_SPECTROGRAM_HISTORY = Ref{Vector{Vector{Float32}}}(Vector{Float32}[])
const _SCOPE_LISTENER_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SCOPE_LISTENER_SOCKET = Ref{Union{UDPSocket,Nothing}}(nothing)
const _SCOPE_LISTENER_RUNNING = Threads.Atomic{Bool}(false)
const _SCOPE_LIVE_MODEL = Ref{Union{LiveModel,Nothing}}(nothing)
# Model-agnostic scope state — used by the new Tachikoma app (which
# doesn't have a LiveModel reference). Always populated by the
# listener; old LiveModel-based code keeps using m.scope_data via
# the existing path.
const _APP_SCOPE_DATA  = Ref{Vector{Float32}}(Float32[])
const _APP_SCOPE_TYPE  = Ref{Symbol}(:off)
const _APP_SCOPE_TS    = Ref{Float64}(0.0)

"""
    _scope_set!(m, type)

Switch scope to `:off`, `:amp`, `:wave`, or `:spectrum`. Sends the
control OSC to SuperCollider, opens the listener socket on first
non-off type, and updates model state.
"""
function _scope_set!(m::LiveModel, type::Symbol)
    type in _SCOPE_CYCLE_ORDER ||
        (_push_log!(m, "[ERROR] :scope — unknown type '$type'"); return)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] :scope — no live session")
        return
    end
    if type !== :off
        _ensure_scope_listener!(m)
    end
    m.scope_type = type
    empty!(m.scope_data)
    send_osc(sched.osc, encode(OSCMessage("/ressac/scope", Any[String(type)])))
    _push_log!(m, "[INFO] :scope $type")
end

"""
    _scope_cycle!(m)

`]` — cycle to the next scope type in `_SCOPE_CYCLE_ORDER`.
Wraps around past :spectrum back to :off.
"""
function _scope_cycle!(m::LiveModel)
    i = findfirst(==(m.scope_type), _SCOPE_CYCLE_ORDER)
    i === nothing && (i = 0)
    next = _SCOPE_CYCLE_ORDER[(i % length(_SCOPE_CYCLE_ORDER)) + 1]
    _scope_set!(m, next)
end

function _scope_cycle_back!(m::LiveModel)
    i = findfirst(==(m.scope_type), _SCOPE_CYCLE_ORDER)
    i === nothing && (i = 1)
    prev = _SCOPE_CYCLE_ORDER[i == 1 ? length(_SCOPE_CYCLE_ORDER) : i - 1]
    _scope_set!(m, prev)
end

"""
    _ensure_scope_listener!(m)

Bind the UDP listener once. Subsequent calls are no-ops. Spawns a
background task that pulls OSC frames out of the socket and updates
`m.scope_data` + `m.scope_last_update`. The task lives until the
process exits — cheap, just blocks on recv.
"""
function _ensure_scope_listener!(m::LiveModel)
    _SCOPE_LIVE_MODEL[] = m
    _SCOPE_LISTENER_SOCKET[] !== nothing && return
    try
        sock = UDPSocket()
        bind(sock, ip"127.0.0.1", _SCOPE_LISTEN_PORT)
        _SCOPE_LISTENER_SOCKET[] = sock
        _SCOPE_LISTENER_RUNNING[] = true
        _SCOPE_LISTENER_TASK[] = Threads.@spawn _scope_listener_loop()
        _push_log!(m, "[INFO] scope listener bound on 127.0.0.1:$(_SCOPE_LISTEN_PORT)")
    catch err
        _push_log!(m, "[ERROR] scope listener bind failed: $(sprint(showerror, err))")
    end
end

function _scope_listener_loop()
    sock = _SCOPE_LISTENER_SOCKET[]
    sock === nothing && return
    while _SCOPE_LISTENER_RUNNING[]
        try
            data = recv(sock)
            model = _SCOPE_LIVE_MODEL[]
            model === nothing && continue
            _handle_scope_packet!(model, data)
        catch err
            err isa InterruptException && break
            # Bad packet — drop and keep listening.
        end
    end
end

"""
    _handle_scope_packet!(m, bytes)

Decode an incoming OSC message and update the model's scope buffer.
SC's SendReply sends messages of the form:
  /ressac/scope/<type> <nodeID:Int32> <replyID:Int32> <val1:Float32> ...
"""
function _handle_scope_packet!(m::LiveModel, bytes::Vector{UInt8})
    msg = try
        decode_message(bytes)
    catch
        return
    end
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
    isempty(floats) && return
    # Update the model-agnostic globals (used by the new Tachikoma app)
    # AND the LiveModel fields (back-compat with the old TUI).
    _APP_SCOPE_DATA[] = floats
    _APP_SCOPE_TS[]   = time()
    m.scope_data = floats
    m.scope_last_update = time()
end

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

"""
    _scope_panel_height(m) -> Int

How many rows the scope panel takes. 0 when off, otherwise enough
for the chosen viz + a 1-row title.
"""
function _scope_panel_height(m::LiveModel)
    m.scope_type === :off && return 0
    return 22   # 1 title + 21 viz rows — readable vertical resolution
end

"""
    _ScopePanel(model)

Renders the active scope into the area assigned by the layout.
"""
struct _ScopePanel
    model::LiveModel
end

function TUI.render(p::_ScopePanel, area::TUI.Rect, buf::TUI.Buffer)
    m = p.model
    h = TUI.height(area)
    w = TUI.width(area)
    h < 1 && return
    style_title = TUI.Crayon(; foreground=:cyan, bold=true)
    style_viz   = TUI.Crayon(; foreground=:cyan)
    style_dim   = TUI.Crayon(; foreground=:dark_gray)
    # Title.
    title = "scope: $(m.scope_type)   (S to cycle, :scope off to hide)"
    TUI.set(buf, TUI.left(area), TUI.top(area),
            rpad(first(title, w), w), style_title)
    h < 2 && return
    body_h = h - 1
    body_top = TUI.top(area) + 1
    if isempty(m.scope_data)
        TUI.set(buf, TUI.left(area), body_top,
                "  (waiting for audio — press T to test)", style_dim)
        return
    end
    if m.scope_type === :amp
        _render_amp_meter(m.scope_data, TUI.left(area), body_top, w, body_h, buf, style_viz)
    elseif m.scope_type === :wave
        _render_waveform(m.scope_data, TUI.left(area), body_top, w, body_h, buf, style_viz)
    elseif m.scope_type === :spectrum
        _render_spectrum(m.scope_data, TUI.left(area), body_top, w, body_h, buf, style_viz)
    end
end

function _render_amp_meter(data, x, y, w, h, buf, style)
    amp = clamp(Float64(data[1]), 0.0, 1.0)
    bar_w = floor(Int, amp * w)
    bar = "▌" ^ bar_w
    db = amp > 0 ? round(20 * log10(amp); digits=1) : -Inf
    label = " amp $(round(amp; digits=3))  ($(db) dB)"
    TUI.set(buf, x, y, rpad(bar * label, w), style)
end

function _render_waveform(data, x, y, w, h, buf, style)
    n = length(data)
    n == 0 && return
    # Stride so we fit at most `w` columns, or interpolate if fewer
    # samples than columns (each sample spans floor(w / n) cells).
    if n >= w
        step = n / w
        samples = [data[clamp(round(Int, 1 + (i - 1) * step), 1, n)] for i in 1:w]
    else
        samples = data
    end
    # Find peak normalization (avoid clipping the display to ±1 — soft
    # signals would look like a flat line).
    peak = maximum(abs.(samples); init=0.001f0)
    scale = peak < 0.05 ? 1.0 : 1.0 / max(Float64(peak), 0.05)
    # Build rows by checking which row each sample maps to.
    rows = [fill(' ', length(samples)) for _ in 1:h]
    for (col, s) in enumerate(samples)
        target = clamp(Float64(s) * scale, -1.0, 1.0)
        r = clamp(round(Int, (1 - (target + 1) / 2) * (h - 1)) + 1, 1, h)
        rows[r][col] = '•'
    end
    # Centre zero line in dim grey.
    centre_row = clamp(round(Int, h / 2), 1, h)
    for col in 1:length(samples)
        rows[centre_row][col] == ' ' && (rows[centre_row][col] = '─')
    end
    for (i, line) in enumerate(rows)
        s = String(line)
        TUI.set(buf, x, y + i - 1, rpad(s, w), style)
    end
end

function _render_spectrum(data, x, y, w, h, buf, style)
    n = length(data)
    n == 0 && return
    # Each band gets 1 column. If we have more bands than columns,
    # group them; if fewer, leave whitespace on the right.
    bands = min(n, w)
    for band_idx in 1:bands
        # Pick the value for this column; with downsample if data has
        # more bands than columns we'd lose detail but our default
        # gives data ≤ w so 1:1 typically.
        val = data[band_idx]
        col = x + band_idx - 1
        mag = clamp(Float64(val), 0.0, 1.0)
        bar_h = clamp(round(Int, mag * h), 0, h)
        for r in 1:h
            row_y = y + h - r
            ch = r <= bar_h ? "█" : " "
            TUI.set(buf, col, row_y, ch, style)
        end
    end
end

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
