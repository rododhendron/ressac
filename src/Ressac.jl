"""
    Ressac

Live coding musical environment in Julia. TidalCycles-inspired DSL with a
real-time scheduler that drives SuperCollider/SuperDirt over OSC.

The full design is in `docs/journal/20260518_plan_dev.md`.
"""
module Ressac

include("core.jl")
include("combinators.jl")
include("algebra.jl")
include("controls.jl")
include("mininotation.jl")
include("osc.jl")
include("scheduler.jl")
include("tui_model.jl")
include("tui_buffer.jl")
include("tui_eval.jl")
include("tui_search.jl")
include("tui_hints.jl")
include("tui_bindings.jl")
include("tui_view.jl")
include("tui_overlay.jl")
include("tui_mouse.jl")
include("tui.jl")
include("live_api.jl")
include("plugins.jl")
include("tui_browser.jl")
include("tui_docs.jl")
include("plugin_handlers.jl")

# Module includes added by upcoming milestones:
#   M6: include("reservoir.jl")

export Event, Pattern, query
export pure, silence, fast, slow, density, rev, every, gate
export mask
export parse_minino, @p_str
export OSCMessage, OSCBundle, OSCClient, encode, send_osc
export Scheduler, start!, stop!, set_pattern!, unset_pattern!, set_cps!, hush!, schedule_pattern!
export live, start_live!, stop_live!, restart_live!, d!, unset!, hush_all!, cps!
export register_section_handler!, unregister_section_handler!, get_section_handler
export load_plugin, parse_manifest, discover_plugins, default_plugin_path
export SampleEntry, sample_info, list_samples, register_sample!
export InstrumentEntry, instrument_info, list_instruments, register_instrument!
export SynthEntry, synth_info, list_synths, register_synth!
export ControlMap, ControlPattern, set, gain, lpf, hpf, speed
export pan, n, room, delay, shape, degree
# SuperDirt param helpers (auto-generated in controls.jl):
export attack, release, hold, sustain, legato
export cutoff, resonance, bandq, bandf, hcutoff, hresonance
export crush, coarse
export accelerate, vibrato, tremolorate, tremolodepth, phaserrate, phaserdepth
export delaytime, delayfeedback
export octave, slide, pitch1, pitch2, pitch3, detune
export sampleloop, speedup
export vowel, enhance, leslie, leslierate, lesliespeed
export pan2, panspan, panorbit, panwidth
# Export every @d1..@d64 macro. Doing it here keeps the macro generator
# in live_api.jl tidy.
for n in 1:64
    @eval export $(Symbol("@d", n))
end
# `stack`, `cat`, and arithmetic operators extend Base; no re-export needed.

# ---------------------------------------------------------------------------
# Precompile workload
# ---------------------------------------------------------------------------
#
# Exercise the hot paths once at package precompile time so the first live
# evaluation doesn't pay the JIT cost. The `_PrecompileSink` is a no-op
# replacement for `OSCClient`: it lets us run `_step!` without actually
# touching a UDP socket during precompilation.

using PrecompileTools

struct _PrecompileSink end
send_osc(::_PrecompileSink, ::Vector{UInt8}) = nothing

@compile_workload begin
    # Mini-notation: cover the parser's main branches.
    p1 = parse_minino("bd hh sn hh")
    p2 = parse_minino("<bd sn cp>")
    p3 = parse_minino("bd(3,8)")
    p4 = parse_minino("bd*4")
    p5 = parse_minino("bd!2 sn")
    p6 = parse_minino("[bd hh] sn")

    # Combinator stack + new curried forms via pipe.
    layered  = pure(:cp) |> fast(2)
    looped   = p1 |> every(3, rev)
    mask_gate = Pattern{Bool}((s::Rational, e::Rational) -> begin
        evs = Event{Bool}[]
        push!(evs, Event{Bool}(0//1, 1//2, true))
        push!(evs, Event{Bool}(1//2, 1//1, false))
        filter!(ev -> ev.start < e && ev.stop > s, evs)
        evs
    end)
    masked   = p1 |> mask(mask_gate)
    stacked  = pure(:bd) |> stack(pure(:sn))

    # Numeric algebra path.
    np1 = pure(0) + 12

    # Full scheduler hot loop incl. pending drain.
    sched = Scheduler(_PrecompileSink(); cps=0.5, lookahead=0.05)
    sched.t_start = 0.0
    set_pattern!(sched, :d1, p1)
    set_pattern!(sched, :d2, layered)
    schedule_pattern!(sched, :d3, looped, 1 // 1)
    _step!(sched, 0.0)
    _step!(sched, 1.5)
    unset_pattern!(sched, :d1)
    hush!(sched)

    # OSC encoder/decoder.
    msg = OSCMessage("/dirt/play", Any["s", "bd"])
    bytes = encode(msg)
    decode_message(bytes)
    encode(OSCBundle(0.0, [msg]))

    # Live API: exercise _route_to_slot! both modes via the public macros.
    _LIVE_SCHEDULER[] = sched
    try
        _EVAL_MODE[] = (:immediate, 0)
        _route_to_slot!(:d4, p2)
        _EVAL_MODE[] = (:deferred, 1)
        _route_to_slot!(:d5, p3)
    finally
        _LIVE_SCHEDULER[] = nothing
        _EVAL_MODE[] = (:immediate, 0)
    end

    # TUI dispatch paths — exercise the dispatcher in normal/insert
    # to lock in compile artefacts for editor keystrokes.
    m = LiveModel(; scheduler=sched)
    _LIVE_SCHEDULER[] = sched
    try
        m.mode = :insert
        _dispatch_key!(m, (; code="@", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="d", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="1", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="Esc", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="e", modifiers=String[], kind="Press"))
        # Goto / search.
        _dispatch_key!(m, (; code="g", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="d", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="1", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="Enter", modifiers=String[], kind="Press"))
        # View rendering.
        TUI.view(m)
    finally
        _LIVE_SCHEDULER[] = nothing
    end

    # Plugins: parse a fixture manifest if present and walk the loader
    # to warm up TOML parsing + the discover/topo_sort paths.
    fixture = joinpath(@__DIR__, "..", "test", "fixtures", "plugins", "foo")
    if isfile(joinpath(fixture, "plugin.toml"))
        try
            m_plugin = parse_manifest(fixture)
            discover_plugins([dirname(fixture)])
            topo_sort([m_plugin])
        catch
            # Fixtures may not be present in shipped packages; ignore.
        end
    end

    # Sample banks: warm the registry helpers so first-session preview /
    # listing is cheap.
    bank_fixture = joinpath(@__DIR__, "..", "test", "fixtures", "plugins", "withbanks")
    if isfile(joinpath(bank_fixture, "plugin.toml"))
        try
            empty!(_SAMPLE_REGISTRY)
            mb = parse_manifest(bank_fixture)
            register_sample!(SampleEntry(:_pc_kicky, "withbanks",
                joinpath(bank_fixture, "curated/kicks/heavy_v3.wav"),
                String[], Dict{String,Any}("bpm" => 120)))
            sample_info(:_pc_kicky)
            list_samples(r"_pc")
            empty!(_SAMPLE_REGISTRY)
        catch
            # Fixtures may not be present in shipped packages; ignore.
        end
    end

    # Instruments + synths: warm the new dispatch path so the first
    # instrument-backed event doesn't compile event_to_osc + _osc_value
    # under the scheduler's wall-clock.
    try
        empty!(_INSTRUMENT_REGISTRY)
        empty!(_SYNTH_REGISTRY)
        register_instrument!(InstrumentEntry(:_pc_kick, "pc",
            Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2, "lpf" => 200],
            Dict{String,Any}("tags" => ["pc"])))
        register_synth!(SynthEntry(:_pc_synth, "pc",
            Dict{String,Any}("description" => "pc")))
        instrument_info(:_pc_kick)
        synth_info(:_pc_synth)
        list_instruments(r"_pc")
        list_synths(r"_pc")
        # Exercise the new event_to_osc dispatch (registry hit + miss).
        event_to_osc(Event(0//1, 1//1, :_pc_kick))
        event_to_osc(Event(0//1, 1//1, :_pc_unmapped))
        # Plugin handler entry points for [instruments] and [synths].
        h_i = get_section_handler(:instruments)
        h_s = get_section_handler(:synths)
        h_i !== nothing && h_i("/tmp",
            Dict("_pc_warm" => Dict{String,Any}("s" => "bd", "gain" => 1.0)),
            "_pc")
        h_s !== nothing && h_s("/tmp",
            Dict("_pc_warm" => Dict{String,Any}("tags" => ["pc"])),
            "_pc")
        empty!(_INSTRUMENT_REGISTRY)
        empty!(_SYNTH_REGISTRY)
    catch
        empty!(_INSTRUMENT_REGISTRY)
        empty!(_SYNTH_REGISTRY)
    end

    # Warm the TUI ex-command paths for instruments/synths/guide so first
    # invocation in a live session is instant.
    try
        m2 = LiveModel(; scheduler=sched)
        _execute_ex_command!(m2, "guide")
        m2.mode = :normal  # :guide opens the modal now; reset for next exec
        _execute_ex_command!(m2, "instruments")
        _execute_ex_command!(m2, "synths")
    catch
        # Best-effort: any failure here just leaves first invocation slower.
    end

    # SP6 visual UX: warm fuzzy match, completion engine, overlay rendering
    # paths, guide-mode handler.
    try
        _fuzzy_score("sa", "samples")
        _fuzzy_score("xy", "samples")
        _fuzzy_rank("sa", ["samples", "snares", "savings"])
        _completion_context("p\"kic", 6)
        _completion_context("@d1 fast", 9)
        _buffer_candidates(:default)
        _buffer_candidates(:mininotation)

        m3 = LiveModel(; scheduler=sched)
        m3.command_buffer = "sa"
        _compute_completions(m3)
        m3.command_buffer = "samples kic"
        _compute_completions(m3)

        # Toggle ? and render help + guide overlays.
        m3.show_help = true
        TUI.view(m3)
        m3.show_help = false
        m3.mode = :guide
        TUI.view(m3)
        m3.mode = :normal

        # Insert-mode Tab + cycle.
        m4 = LiveModel(; scheduler=sched)
        m4.mode = :insert
        m4.buffer = ["fas"]
        m4.cursor_col = 4
        _dispatch_key!(m4, (; code="Tab", modifiers=String[], kind="Press"))
        _dispatch_key!(m4, (; code="Tab", modifiers=String[], kind="Press"))
    catch
        # Best-effort.
    end

    # Effect chain hot paths: lift, set, gain (compose ×), lpf (compose min),
    # overwrite helper, dispatch with and without preset.
    try
        ctrl_p = pure(:bd) |> gain(0.8) |> gain(1.2) |> lpf(2000) |> pan(0.3)
        ctrl_evs = ctrl_p(0//1, 1//1)
        if !isempty(ctrl_evs)
            event_to_osc(ctrl_evs[1])
        end

        gp = Pattern{Float64}((s, e) -> [Event{Float64}(0//1, 1//1, 0.7)])
        pat_p = pure(:bd) |> gain(gp)
        pat_evs = pat_p(0//1, 1//1)
        if !isempty(pat_evs)
            event_to_osc(pat_evs[1])
        end

        empty!(_INSTRUMENT_REGISTRY)
        register_instrument!(InstrumentEntry(:_pc_pre, "pc",
            Pair{String,Any}["s" => "bd", "gain" => 1.2],
            Dict{String,Any}()))
        preset_evs = (pure(:_pc_pre) |> gain(0.5))(0//1, 1//1)
        if !isempty(preset_evs)
            event_to_osc(preset_evs[1])
        end
        empty!(_INSTRUMENT_REGISTRY)
    catch
        empty!(_INSTRUMENT_REGISTRY)
    end
end

end # module Ressac
