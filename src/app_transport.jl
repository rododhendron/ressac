# src/app_transport.jl
# Transport : enregistrement (rec/stop), export du synth courant, panic
# (!) et hush (,).

"""
    _start_recording!(m, name=nothing)

Open a WAV file under `./recordings/` and tell SC to start
streaming the master mix into it. `name` defaults to a
timestamped filename so successive recordings don't clobber.
"""
function _start_recording!(m::RessacApp, name=nothing)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && (_push_app_log!(m, "[ERROR] rec : pas de session live"); return)
    if m.recording
        _push_app_log!(m, "[WARN] rec : déjà en enregistrement → $(m.recording_path)")
        return
    end
    dir = joinpath(pwd(), "recordings")
    isdir(dir) || mkpath(dir)
    fname = if name === nothing
        ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
        "ressac_$(ts).wav"
    else
        endswith(String(name), ".wav") ? String(name) : String(name) * ".wav"
    end
    path = joinpath(dir, fname)
    send_osc(sched.osc, encode(OSCMessage("/ressac/recStart", Any[path])))
    m.recording = true
    m.recording_path = path
    m.recording_start_ts = time()
    _push_app_log!(m, "[INFO] rec ● → $(path)")
end

"""
    _stop_recording!(m)

Send /ressac/recStop to SC and clear local state. SC closes the
WAV file cleanly; the user can immediately play it back from disk.
"""
function _stop_recording!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    if !m.recording
        _push_app_log!(m, "[WARN] rec stop : pas d'enregistrement en cours")
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/recStop", Any[])))
    secs = round(time() - m.recording_start_ts; digits=1)
    _push_app_log!(m, "[INFO] rec ■ $(secs)s → $(m.recording_path)")
    m.recording = false
    m.recording_path = ""
end

_toggle_recording!(m::RessacApp) =
    m.recording ? _stop_recording!(m) : _start_recording!(m)

"""
    _export_current_synth!(m; duration = 4.0)

One-shot WAV export of the currently-open synth. Sequence:

  1. Pull all patterns (`hush!`) so nothing else lands in the take.
  2. Write to `./recordings/<synthname>_<ts>.wav`, sample the SC
     master out for `duration` seconds.
  3. While the recording is live, fire the synth once via the same
     /ressac/evalAndPlay path that T uses (so we capture exactly
     what the user hears when they hit T).
  4. After `duration` seconds, stop the recording.

Runs the timing on an `@async` Task so the UI stays interactive.
"""
function _export_current_synth!(m::RessacApp; duration::Float64 = 4.0)
    _synth_pane_open(m) ||
        (_push_app_log!(m, "[ERROR] export : ouvre d'abord un synth (:synth <nom>)"); return)
    sched = _LIVE_SCHEDULER[]
    sched === nothing &&
        (_push_app_log!(m, "[ERROR] export : pas de session live"); return)
    m.recording &&
        (_push_app_log!(m, "[WARN] export : arrête d'abord le :rec en cours"); return)
    tab = _current_synth_tab(m)
    src = TK.text(tab.code_editor)
    dir = joinpath(pwd(), "recordings")
    isdir(dir) || mkpath(dir)
    ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    fname = "$(tab.name)_$(ts).wav"
    path = joinpath(dir, fname)
    # 1. quiet the scheduler so the take is just this synth.
    hush!(sched)
    # 2. open the WAV.
    send_osc(sched.osc, encode(OSCMessage("/ressac/recStart", Any[path])))
    m.recording = true
    m.recording_path = path
    m.recording_start_ts = time()
    _push_app_log!(m, "[INFO] export ● $(fname) ($(duration)s)")
    # 3+4. fire the synth then schedule the stop. @async keeps the UI
    # responsive while we sleep the take's duration.
    @async begin
        try
            # SC's prepareForRecord allocates a disk buffer and isn't
            # instantaneous — wait long enough for the Routine in the
            # OSCdef to actually engage record before we fire the note.
            # A side-effect of the wait: the WAV has a fade-in margin of
            # silence which is convenient for downstream editing.
            sleep(0.3)
            send_osc(sched.osc,
                     encode(OSCMessage("/ressac/evalAndPlay",
                                        Any[tab.name, src])))
            sleep(duration)
            send_osc(sched.osc, encode(OSCMessage("/ressac/recStop", Any[])))
            m.recording = false
            m.recording_path = ""
            _push_app_log!(m, "[INFO] export ■ → $(path)")
        catch err
            _push_app_log!(m, "[ERROR] export : $(sprint(showerror, err))")
            m.recording = false
        end
    end
end

"""
    _panic!(m)

Single-key emergency stop. Pulls every active pattern from the
scheduler (so no fresh OSC events ship) AND sends `/ressac/panic` to
SuperCollider which calls `s.freeAll` — every running synth dies. The
scheduler stays up so the next pattern eval starts cleanly.
"""
function _panic!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing || hush!(sched)
    if sched !== nothing
        send_osc(sched.osc, encode(OSCMessage("/ressac/panic", Any[])))
    end
    _push_app_log!(m, "[INFO] PANIC — tout le son est coupé")
end

"""
    _hush!(m)

Softer counterpart to `_panic!`: clears every pattern from the
scheduler so no new events fire, but does NOT free running synths
on the SC server. Notes already in the air play out their
envelopes naturally — reverb tails, drone fade-outs, release
phases all complete cleanly. Bound to `,` and the :hush / :stop /
:silence ex-commands.
"""
function _hush!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    hush!(sched)
    _push_app_log!(m, "[INFO] hush — patterns arrêtés, les queues finissent · :panic coupe aussi les voix")
end

