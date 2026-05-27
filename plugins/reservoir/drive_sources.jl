# Drive sources — what gets injected into the reservoir each step.
#
# A "drive source" is anything that, given the current `cycle` index +
# `step` index + neuron count `N`, writes `N` current values into a
# scratch buffer that `step!` will consume. Centralising the dispatch
# keeps the routes (spike_burst, modulator, spectral_cloud) ignorant
# of how the user specified the drive.
#
# Supported user-facing forms:
#
#   drive::Real                   → constant, broadcast to all neurons
#   drive::AbstractVector{<:Real} → static per-neuron (length N)
#   drive::Function               → (cycle::Int, step::Int) → Real
#                                   or Vector{<:Real} of length N
#   drive::Pattern{Symbol}        → each event injects a pulse into the
#                                   neuron `hash(event.value) % N + 1`
#                                   at the event's start step. Quiet
#                                   between events.
#   drive::Pattern{Float64}       → continuous signal sampled per cycle
#                                   (one event per arc), broadcast to all
#
# The constructor returns a callable `(cycle, step, buf::Vector{Float64})
# -> nothing` that mutates `buf` in place.

# Pulse defaults for a Pattern{Symbol} event. A 600 pA pulse held for
# 10 steps (≈10 ms at dt=1) bumps an AdEx neuron's V by ~21 mV, which
# is enough to cross threshold from rest. Held shorter or weaker → the
# pulse only nudges; held longer / stronger → forced bursting.
const _DRIVE_PULSE_PA = 600.0
const _DRIVE_PULSE_STEPS = 10

"""
    _make_drive_source(drive, N, spc) -> Function

Build a closure that materialises the per-step input vector. The
closure has signature `(cycle::Int, step::Int, buf::Vector{Float64})
-> nothing` and writes `buf[1:N]` in place.
"""
function _make_drive_source(drive::Real, N::Int, spc::Int)
    val = Float64(drive)
    function _const_drive!(cycle, step, buf)
        @inbounds for i in 1:N
            buf[i] = val
        end
        return nothing
    end
end

function _make_drive_source(drive::AbstractVector{<:Real}, N::Int, spc::Int)
    length(drive) == N || throw(DimensionMismatch(
        "drive vector length $(length(drive)) ≠ N=$N"))
    vec = Float64.(drive)
    function _vec_drive!(cycle, step, buf)
        @inbounds for i in 1:N
            buf[i] = vec[i]
        end
        return nothing
    end
end

function _make_drive_source(drive::Function, N::Int, spc::Int)
    function _fn_drive!(cycle, step, buf)
        val = drive(cycle, step)
        if val isa Real
            v = Float64(val)
            @inbounds for i in 1:N
                buf[i] = v
            end
        elseif val isa AbstractVector
            length(val) == N || throw(DimensionMismatch(
                "drive function returned length $(length(val)) ≠ N=$N"))
            @inbounds for i in 1:N
                buf[i] = Float64(val[i])
            end
        else
            throw(ArgumentError(
                "drive function must return Real or AbstractVector{<:Real}"))
        end
        return nothing
    end
end

"Convenience: bare mini-notation strings auto-parse, so `drive=\"bd ~ sn ~\"`
works without the `p\"...\"` prefix."
function _make_drive_source(drive::AbstractString, N::Int, spc::Int)
    return _make_drive_source(Ressac.parse_minino(String(drive)), N, spc)
end

# Conversion factor from normalised audio amplitude [0, 1] to pA of
# injected current. Tuned so a moderately-loud voice (RMS≈0.3) sits
# near AdEx threshold without saturating.
const _AUDIO_IN_GAIN_PA = 1500.0

"""
Symbol-form drive. `drive=:audio_in` pulls the latest RMS amplitude
from the live audio listener (fed by the `\\ressac_audio_in` SC SynthDef
via OSC) and broadcasts it to every neuron, scaled into pA. Requires
`:audio-in start` to have been run so SC is shipping packets.
"""
function _make_drive_source(drive::Symbol, N::Int, spc::Int)
    drive === :audio_in || throw(ArgumentError(
        "unknown drive symbol :$drive (only :audio_in supported)"))
    function _audio_in_drive!(cycle, step, buf)
        v = Ressac._AUDIO_IN_VALUE[] * _AUDIO_IN_GAIN_PA
        @inbounds for i in 1:N
            buf[i] = v
        end
        return nothing
    end
end

function _make_drive_source(drive::Pattern{Symbol}, N::Int, spc::Int)
    # Per-cycle, pre-compute a dense (spc, N) matrix of input currents.
    # Each event injects `_DRIVE_PULSE_PA` for `_DRIVE_PULSE_STEPS` on
    # the neuron picked by `hash(event.value) % N + 1`. Overlapping
    # pulses sum — drum hits stack into denser drives.
    cached_cycle = Ref(-1)
    cycle_input = Matrix{Float64}(undef, spc, N)
    fill!(cycle_input, 0.0)
    function _patsym_drive!(cycle, step, buf)
        if cached_cycle[] != cycle
            fill!(cycle_input, 0.0)
            evs = drive(Rational{Int64}(cycle), Rational{Int64}(cycle + 1))
            for ev in evs
                frac = Float64(ev.start - Rational{Int64}(cycle))
                start_s = clamp(floor(Int, frac * spc) + 1, 1, spc)
                stop_s  = min(spc, start_s + _DRIVE_PULSE_STEPS - 1)
                n_idx   = mod(hash(ev.value), N) + 1
                @inbounds for s in start_s:stop_s
                    cycle_input[s, n_idx] += _DRIVE_PULSE_PA
                end
            end
            cached_cycle[] = cycle
        end
        @inbounds for i in 1:N
            buf[i] = cycle_input[step, i]
        end
        return nothing
    end
end

# ════════════════════════════════════════════════════════════════════
# Helper functions — readable shorthand for common drive waveforms.
# ════════════════════════════════════════════════════════════════════
# Each returns a `(cycle::Int, step::Int) -> Float64` suitable as the
# `drive=` argument of any route. Units are in STEPS (the reservoir's
# internal time unit). Convert to cycle units by multiplying by spc:
# `drive_sin(200, 4 * spc; offset=400)` = 4-cycle sine.

"""
    drive_const(amp) -> Function

Constant current `amp` at every step. Equivalent to passing the bare
`Real` `amp` as `drive`, but reads explicitly when chained.
"""
drive_const(amp::Real) = (c, s) -> Float64(amp)

"""
    drive_sin(amp, period_steps; offset=0.0, phase=0.0) -> Function

Sine wave between `offset-amp` and `offset+amp`, one full cycle every
`period_steps` simulation steps. `phase ∈ [0, 1)` shifts the start.
"""
function drive_sin(amp::Real, period_steps::Real;
                   offset::Real = 0.0, phase::Real = 0.0)
    a = Float64(amp); off = Float64(offset); P = Float64(period_steps)
    ph = Float64(phase)
    (c, s) -> off + a * sin(2π * (s / P + ph))
end

"""
    drive_square(amp, period_steps; duty=0.5, offset=0.0) -> Function

On/off pulse train: `offset+amp` for `duty × period_steps`, then
`offset` for the rest. `duty ∈ (0, 1)`.
"""
function drive_square(amp::Real, period_steps::Real;
                      duty::Real = 0.5, offset::Real = 0.0)
    a = Float64(amp); off = Float64(offset); P = Float64(period_steps)
    d = Float64(duty)
    (c, s) -> begin
        phase = mod(s, P) / P
        phase < d ? off + a : off
    end
end

"""
    drive_ramp(low, high, period_steps) -> Function

Sawtooth: rises linearly from `low` to `high` over `period_steps`,
then snaps back. Use negative ramp by passing `low > high`.
"""
function drive_ramp(low::Real, high::Real, period_steps::Real)
    lo = Float64(low); hi = Float64(high); P = Float64(period_steps)
    (c, s) -> lo + (hi - lo) * (mod(s, P) / P)
end

"""
    drive_tri(amp, period_steps; offset=0.0) -> Function

Triangle wave between `offset-amp` and `offset+amp`, period
`period_steps`. Smoother than `drive_square`, sharper than `drive_sin`.
"""
function drive_tri(amp::Real, period_steps::Real; offset::Real = 0.0)
    a = Float64(amp); off = Float64(offset); P = Float64(period_steps)
    (c, s) -> begin
        u = mod(s, P) / P
        off + a * (u < 0.5 ? (4u - 1) : (3 - 4u))
    end
end

"""
    drive_burst(amp, on_steps, every_steps; offset=0.0) -> Function

Periodic burst: `offset+amp` during the first `on_steps` of each
`every_steps` window, `offset` the rest of the time. Useful for
single-shot drives that fire every N cycles.
"""
function drive_burst(amp::Real, on_steps::Real, every_steps::Real;
                     offset::Real = 0.0)
    a = Float64(amp); on = Float64(on_steps); every = Float64(every_steps)
    off = Float64(offset)
    (c, s) -> begin
        # `s` is per-cycle (resets each cycle), so we fold the cycle
        # index into a global step count first.
        global_s = c * every + s  # approx — assumes every == spc
        mod(global_s, every) < on ? off + a : off
    end
end

"""
    drive_sum(drives...) -> Function

Sum the outputs of several drive functions. Each must be a callable
`(c, s) -> Real`. Use to layer e.g. a slow sine over a constant floor.
"""
function drive_sum(drives...)
    fns = drives
    (c, s) -> sum(f(c, s) for f in fns)
end

function _make_drive_source(drive::Pattern{Float64}, N::Int, spc::Int)
    cached_cycle = Ref(-1)
    cached_val = Ref(0.0)
    function _patfloat_drive!(cycle, step, buf)
        if cached_cycle[] != cycle
            evs = drive(Rational{Int64}(cycle), Rational{Int64}(cycle + 1))
            cached_val[] = isempty(evs) ? 0.0 : Float64(evs[1].value)
            cached_cycle[] = cycle
        end
        v = cached_val[]
        @inbounds for i in 1:N
            buf[i] = v
        end
        return nothing
    end
end
