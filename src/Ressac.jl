"""
    Ressac

Live coding musical environment in Julia. TidalCycles-inspired DSL with a
real-time scheduler that drives SuperCollider/SuperDirt over OSC.

The full design is in `docs/journal/20260518_plan_dev.md`.
"""
module Ressac

# Module-wide Tachikoma alias — hoisted here so pane impls loaded
# before tui_app.jl can reference TK.CodeEditor / TK.Rect.
using Tachikoma
const TK = Tachikoma

# ─── Core domain — pure pattern types + algebra, no I/O ───────────
include("core_patterns.jl")      # Pattern{T}, Event{T}, query
include("core_mininotation.jl")  # the p"…" / "…" parser
include("core_combinators.jl")   # fast/slow/jux/every/sometimes/…
include("core_algebra.jl")       # stack/cat/mask
include("core_tuning.jl")        # Scale, scale_to_semitones, registry
include("core_controls.jl")      # gain/lpf/hpf/pan/n/set/pump/…

# ─── I/O primitives ───────────────────────────────────────────────
include("io_osc.jl")             # OSC wire format (encode/decode)
include("io_scheduler.jl")       # real-time loop + locked snapshots

# ─── Shared TUI helpers (used by autocomplete + modals + app) ─────
include("tui_hints.jl")          # _fuzzy_score, _COMMAND_NAMES, _MODE_HINTS

# ─── Live session lifecycle ───────────────────────────────────────
include("live_boot.jl")          # _LIVE_SCHEDULER, start_live!, live()
include("live_api.jl")           # @d1..@d64 macros, _route_to_slot!

# ─── Plugin registry + state flag ─────────────────────────────────
include("plugin_registry.jl")    # _SAMPLE/INSTRUMENT/SYNTH_REGISTRY,
                                 # _SYNTH_ALIASES, _INSTALLING_SYNTH

# ─── Synth DSL submodule (uses _LIVE_SCHEDULER + registry helpers) ─
include("synth_dsl.jl")          # SynthDSL: @synth, Sig, every ugen wrapper
include("synth_library.jl")      # _SYNTH_LIBRARY entries (uses SynthDSL)

# ─── GA synth explorer — modules purs (génome + GA, aucun SC/UI) ───
include("genome.jl")             # Genome DAG + UGenSpec catalog
include("genome_validity.jl")    # validate + repair!
include("genome_render.jl")      # render_synthdef + render_dsl
include("genome_archetypes.jl")  # serialization + seed archetypes
include("genome_operators.jl")   # mutation + crossover operators
include("ga_engine.jl")          # Population + breeding-pool next_generation
include("ga_analysis.jl")        # genetic distance, clustering, gene distribution

# ─── Extension registry — plugin-contributed docs + snippets ──────
include("extension_registry.jl")

# ─── Pane interface — sub-project 9 foundation ─────────────────────
include("pane_interface.jl")
include("workspace_manager.jl")
include("pane_editor.jl")
include("pane_log.jl")
include("pane_doc.jl")
include("pane_scope.jl")
include("pane_tuning.jl")
include("synth_audition.jl")     # GA explorer — audition harness (OSC)
include("pane_synth_explorer.jl")# GA explorer — :explorer PaneImpl
include("workspace_commands.jl")
include("workspace_keymap.jl")
include("workspace_persistence.jl")
include("snippet_panes.jl")
include("command_line.jl")       # CommandLine widget — ':' / '/' chrome

# ─── Static docs / starter packs / scope state ────────────────────
include("tui_docs.jl")           # stub — content now lives in plugins/{core,…}/
include("tui_livedoc.jl")        # _GUIDE_LINES, _SYNTH_GUIDE_LINES,
                                 # livedoc lookups
include("tui_scope.jl")          # scope listener + _APP_ORBIT_RMS/PEAK,
                                 # external OSC triggers

# ─── Content / configuration / theming ────────────────────────────
include("session_config.jl")     # RessacConfig, _load_ressac_config!
include("session_themes.jl")     # _apply_theme!, palette switching
include("content_sccode.jl")     # sccode.org HTTP client
include("content_wiki.jl")       # docs/wiki/*.md loader

# ─── RessacApp TUI (transitively includes the modal_*.jl + key
#     handlers + autocomplete + editor_ops + input_modes
#     + pattern_editor + leader_snippets) ─────────────────────────
include("tui_app.jl")

# ─── Plugin section handlers (last — uses SynthDSL.@synth via
#     Base.include for .jl orphan auto-discovery) ─────────────────
include("plugin_handlers.jl")

export Event, Pattern, query
export pure, silence, fast, slow, density, rev, every, gate
export mask
export jux, juxBy, off, degrade, degradeBy
export sometimes, sometimesBy, often, rarely
export palindrome, iter, iterBack, chunk
# `run` collides with Base.run (shell-spawn); export as `runp` instead.
# Users can still use `Ressac.run(8)` directly in scripts.
export lastOf, firstOf, early, late, ply, runp, choose, seq, structPat
# `chop` collides with Base.chop (string trim); export as `chopp`.
# `Ressac.chop` still works for copy-pasted Tidal code.
export striate, chopp, nrun
# Continuous signals. `range_pat` / `rand_pat` keep `_pat` to avoid
# clashing with Base.range / Base.rand respectively.
export sine, cosine, tri, saw, square, perlin, segment
export range_pat, rand_pat
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
export pan, n, room, delay, shape, pump, note, scale
export transpose_cents, scale_stretch, bend
# Tunings — Scale type + registry + constructors.
export Scale, scale_to_semitones, register_scale!, lookup_scale, list_scales
export edo, from_ratios, from_cents, bohlen_pierce, golden_meantone,
       fibonacci_scale, continued_fraction_scale, stern_brocot
# Compressor params (auto-generated in controls.jl):
export compress, compressThreshold, compressRatio
# SuperDirt param helpers (auto-generated in controls.jl):
export freq
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

    # (LiveModel dispatcher + TUI.view warmup removed in the phase-1
    # cleanup that deleted tui_view.jl / tui_bindings.jl / tui_browser.jl.
    # RessacApp coverage is below — exhaustive enough that first-keystroke
    # JIT cost is comparable.)

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

    # Warm the new Tachikoma TUI: build RessacApp, dispatch the
    # keystrokes that typically arrive in the first few seconds (arrows,
    # i, Esc, :, e, quit chord), render through a TestBackend. Cold-JIT
    # compile of these paths used to make the first arrow press lag
    # visibly — now they're precompiled.
    try
        ressac_app = RessacApp(; scheduler=sched)
        tb = Tachikoma.TestBackend(80, 24)
        frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 80, 24),
                                Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(ressac_app, frame)
        # Arrow keys
        for k in (:left, :right, :up, :down)
            Tachikoma.update!(ressac_app, Tachikoma.KeyEvent(k, '\0', Tachikoma.key_press))
        end
        # Mode toggles
        Tachikoma.update!(ressac_app, Tachikoma.KeyEvent(:i, 'i', Tachikoma.key_press))
        Tachikoma.update!(ressac_app, Tachikoma.KeyEvent(:escape, '\0', Tachikoma.key_press))
        # Eval trigger
        Tachikoma.update!(ressac_app, Tachikoma.KeyEvent(:e, 'e', Tachikoma.key_press))
        # Render once more after some state changes
        Tachikoma.view(ressac_app, frame)
    catch
        # Best-effort: precompile failures only cost first-call latency.
    end

    # Fuzzy-match + completion engine warmup (callable from RessacApp;
    # LiveModel-rendered overlays + dispatcher exercise that lived here
    # removed in phase-1 cleanup).
    try
        _fuzzy_score("sa", "samples")
        _fuzzy_score("xy", "samples")
        _fuzzy_rank("sa", ["samples", "snares", "savings"])
        _completion_context("p\"kic", 6)
        _completion_context("@d1 fast", 9)
        _buffer_candidates(:default)
        _buffer_candidates(:mininotation)
    catch
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

    # Module-level hot paths still worth warming (no LiveModel needed):
    # mouse-wheel literal bump + gate combinator. Scale-degree
    # warming lands in Step C once `scale()` / `note()` exist.
    try
        _find_number_at("@d1 p\"bd\" |> gain(0.8)", 22)
        _bump_literal("0.8", 0.1, true)
        _bump_literal("3", 1.0, false)
        gate(:super808, parse_minino("1 0 0 1 0 0 1 0"))(0//1, 1//1)
    catch
    end

    # ── Synth DSL precompile ────────────────────────────────────────
    # Build a representative SynthDef so the DSL's Sig + operator +
    # build_synth paths are JIT-cached before the user hits T on a
    # DSL-flavoured library entry.
    try
        sig = SynthDSL.saw(:freq) |>
              SynthDSL.rlpf(SynthDSL.lfo(6; low = 300, high = 2000), 0.25) |>
              SynthDSL.tanh_drive(1.5) |>
              SynthDSL.env_linen(0.01, :sustain, 0.1)
        SynthDSL.build_synth(:_pc_dsl, sig;
                             params = (freq = 220, sustain = 0.5))
        # Symbol arithmetic and Sig × Symbol mixed forms.
        SynthDSL.build_synth(:_pc_arith,
            SynthDSL.sin_osc(:freq * 2 + :freq) * 0.5)
    catch
    end

    # ── Exhaustive Tachikoma RessacApp paths ───────────────────────
    # Cover every update!/view branch we ship today so the first
    # keystroke / modal / theme switch is JIT-cached.
    try
        _init_custom_themes!()
        cfg = RessacConfig()
        _RESSAC_CONFIG[] = cfg
        _apply_theme!(:cyberpunk)
        _apply_theme!(:solarpunk)
        _apply_theme!(:kokaku)

        app = RessacApp(; scheduler=sched)
        _LIVE_SCHEDULER[] = sched
        tb = Tachikoma.TestBackend(120, 32)
        frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 32),
                                Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])

        # Press / repeat / release for every key shape we care about.
        for (key, ch) in ((:char, 'i'), (:char, 'e'), (:char, 'T'),
                          (:char, 'K'), (:char, 'S'), (:char, 'm'),
                          (:char, 'j'), (:char, 'k'), (:char, '+'),
                          (:char, '-'), (:char, '*'), (:char, '/'),
                          (:char, '<'), (:char, '>'), (:char, '='),
                          (:char, '.'), (:char, ' '),
                          (:tab, '\0'), (:escape, '\0'),
                          (:enter, '\0'), (:backspace, '\0'),
                          (:left, '\0'), (:right, '\0'),
                          (:up, '\0'), (:down, '\0'))
            Tachikoma.update!(app, Tachikoma.KeyEvent(key, ch, Tachikoma.key_press))
        end
        # Numpad symbol normalisation.
        for k in (:kp_0, :kp_5, :kp_add, :kp_subtract, :kp_decimal)
            Tachikoma.update!(app, Tachikoma.KeyEvent(k, '\0', Tachikoma.key_press))
        end
        # Held T (key_repeat path).
        Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'T', Tachikoma.key_repeat))
        # Held nudge.
        Tachikoma.update!(app, Tachikoma.KeyEvent(:char, '+', Tachikoma.key_repeat))

        # Modal dispatch.
        for verb in ("synth pluck", "lib", "back", "guide", "synth-guide",
                     "browse", "doc gain", "scale minor", "starter techno",
                     "panic", "hush", "theme outrun", "theme nonexistent",
                     "reload-config")
            try _handle_ex_command!(app, verb) catch end
        end
        # Close modals back to none.
        app.modal = :none

        # Render twice with config + theme.
        Tachikoma.view(app, frame)
        Tachikoma.view(app, frame)
        # Render with scope active.
        _APP_SCOPE_TYPE[] = :wave
        _APP_SCOPE_DATA[] = Float32[sin(2π * i / 32) for i in 0:63]
        Tachikoma.view(app, frame)
        _APP_SCOPE_TYPE[] = :amp
        _APP_SCOPE_DATA[] = Float32[0.5]
        Tachikoma.view(app, frame)
        _APP_SCOPE_TYPE[] = :spectrum
        _APP_SCOPE_DATA[] = Float32[0.3 for _ in 1:48]
        Tachikoma.view(app, frame)
        _APP_SCOPE_TYPE[] = :off

        # Synth pane open + render with split.
        _open_synth_tab!(app, "warm_synth")
        Tachikoma.view(app, frame)
        # Tab cycle.
        app.completion_idx = 0
        ed = _active_editor(app)
        ed.mode = :insert
        Tachikoma.set_text!(ed, "@d1 p\"bd\" |> gai")
        ed.cursor_row = 1
        ed.cursor_col = lastindex(Tachikoma.text(ed)) - 1
        _try_autocomplete!(app, ed)
        _try_autocomplete!(app, ed)
        _reset_completion!(app)

        # Ex-command autocomplete.
        ed.mode = :command
        empty!(ed.command_buffer); append!(ed.command_buffer, collect("syn"))
        _try_ex_autocomplete!(ed)
        empty!(ed.command_buffer); append!(ed.command_buffer, collect("scope wav"))
        _try_ex_autocomplete!(ed)
        ed.mode = :normal

        # Nudge on int + float.
        Tachikoma.set_text!(_active_editor(app), "rate = 4.5\ncount = 200")
        _active_editor(app).cursor_row = 1
        _active_editor(app).cursor_col = 8
        _nudge_number_under_cursor!(app, _active_editor(app), 1)
        _nudge_number_under_cursor!(app, _active_editor(app), 10)
        _active_editor(app).cursor_row = 2
        _active_editor(app).cursor_col = 10
        _nudge_number_under_cursor!(app, _active_editor(app), -1)

        # Synth library: list, preview, instantiate paths.
        _open_synth_library!(app)
        _synthlib_all_entries()
        _preview_synth_from_library!(app)
        # don't actually instantiate (writes to disk); just touch the picker.
        app.modal = :none

        # Sccode in-memory paths (no network): seed entries, drive nav + filter.
        app.modal = :sccode
        app.sccode_entries = [_SccodeEntry("1-aaa", "Warm Synth"),
                              _SccodeEntry("1-bbb", "Warm Bass"),
                              _SccodeEntry("1-ccc", "Cold Pad")]
        app.sccode_cursor = 1
        Tachikoma.update!(app, Tachikoma.KeyEvent(:char, '/', Tachikoma.key_press))
        for c in "warm"
            Tachikoma.update!(app, Tachikoma.KeyEvent(:char, c, Tachikoma.key_press))
        end
        Tachikoma.update!(app, Tachikoma.KeyEvent(:enter, '\0', Tachikoma.key_press))
        _sccode_filtered(app)
        Tachikoma.view(app, frame)
        app.modal = :none

        # Log dedup + multi-line flatten + level styling.
        _push_app_log!(app, "[INFO] warm")
        _push_app_log!(app, "[INFO] warm")
        _push_app_log!(app, "[INFO] warm")
        _push_app_log!(app, "[ERROR] line1\nline2")
        _push_app_log!(app, "[WARN] watchout")
        _push_app_log!(app, "[KEY] something")

        # Panic.
        _panic!(app)

        # Pause + resume render path.
        app.paused = true
        Tachikoma.view(app, frame)
        Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'x', Tachikoma.key_press))
        Tachikoma.view(app, frame)

        _LIVE_SCHEDULER[] = nothing
    catch
        _LIVE_SCHEDULER[] = nothing
    end
end

function __init__()
    # Patch Tachikoma's US-keyboard shift-symbol fallback to cover the
    # `<`→`>` pair that's common outside US layouts (azerty has `<` as
    # the base char of the key left of Z and `>` as its shifted form).
    # On terminals that don't speak the Kitty keyboard protocol (no
    # shifted_keycode in CSI u events), pressing Shift+`<` falls through
    # this map; without the patch the user would see `<` again instead
    # of `>`. Safe to set unconditionally — US layouts produce `>` from
    # Shift+`.` (already mapped) and never hit `<` with shift.
    try
        Tachikoma._SHIFT_SYMBOL_MAP['<'] = '>'
    catch
    end
    # Register custom themes and load config (best-effort — neither is
    # critical to start, but both shape the look of the live() UI).
    try
        _init_custom_themes!()
    catch
    end
    # Tachikoma's KITTY_FUNCTIONAL_KEYS stops at 57452 (right_meta).
    # Codepoints 57453+ (the ISO_Level{3,5}_Shift modifiers, which is
    # what AltGr on azerty/qwertz layouts actually IS at the X11/wayland
    # level, plus a couple of locale-specific kp_keys past kp_begin)
    # fall through to the "printable character" branch and get inserted
    # into the buffer as U+E06D etc. Register them as modifier-only
    # symbols so the editor ignores them.
    try
        kf = Tachikoma.KITTY_FUNCTIONAL_KEYS
        kf[57453] = :iso_level3_shift   # AltGr on azerty
        kf[57454] = :iso_level5_shift
    catch
    end
    # Patch read_event so non-ASCII / multi-byte UTF-8 input (à, é, €,
    # any AltGr-produced char on azerty) is decoded into one KeyEvent
    # carrying the real codepoint. The stock implementation reads ONE
    # byte and emits Char(byte) — for a 2-byte sequence like é
    # (0xC3 0xA9) that produces an invalid Char(0xC3) plus a stranded
    # continuation byte interpreted as its own keypress, hence the
    # "strange character" the user saw.
    _patch_tachikoma_utf8!()
end

function _patch_tachikoma_utf8!()
    # Redefining a top-level function in another module is supported but
    # produces a method-overwrite warning. Wrapping in a try makes it
    # idempotent on Revise reloads and survives any future signature
    # change in Tachikoma (we just leave the original intact then).
    try
        @eval Tachikoma function read_event()
            io = _input_io()
            bytesavailable(io) == 0 && return KeyEvent(:unknown)
            byte = read(io, UInt8)
            byte == 0x1b && return read_escape()
            byte == 0x0d && return KeyEvent(:enter)
            byte == 0x7f && return KeyEvent(:backspace)
            byte == 0x08 && return KeyEvent(:backspace)
            byte == 0x09 && return KeyEvent(:tab)
            byte == 0x03 && return KeyEvent(:ctrl_c)
            byte < 0x20  && return KeyEvent(:ctrl, Char(byte + 0x60))
            # UTF-8 lead byte: ONLY consume continuation bytes if they're
            # in the valid 0x80-0xBF range — otherwise we'd swallow a
            # subsequent keystroke when the high byte is actually
            # something else (a Latin-1 char emitted by a terminal not
            # in UTF-8 mode, etc.).
            if byte >= 0xC2
                ncont = byte >= 0xF0 ? 3 : byte >= 0xE0 ? 2 : 1
                bytes = UInt8[byte]
                for _ in 1:ncont
                    bytesavailable(io) == 0 && break
                    peek_b = read(io, UInt8)
                    if peek_b >= 0x80 && peek_b <= 0xBF
                        push!(bytes, peek_b)
                    else
                        # Not a continuation byte — the lead was bogus.
                        # Return :unknown for the lead and re-queue the
                        # non-continuation byte for the next read by
                        # wrapping it in a 1-element IOBuffer chained
                        # before the original IO. Cheaper alternative:
                        # just drop it (rare path; non-UTF-8 high bytes
                        # in 2026 are basically only AltGr-stripped
                        # bytes that the user shouldn't be sending).
                        return KeyEvent(:unknown)
                    end
                end
                try
                    s = String(bytes)
                    isempty(s) || return KeyEvent(:char, first(s), key_press)
                catch
                end
                return KeyEvent(:unknown)
            end
            return KeyEvent(Char(byte))
        end
        # Numpad keys in DECNKM "application keypad" mode arrive as
        # SS3 sequences (ESC O p/q/r/s/...) which the stock read_ss3
        # only knows for arrow keys + F1-F4 — every digit falls through
        # to :unknown. Patch to add the full numpad table.
        @eval Tachikoma function read_ss3()
            b = read_byte(0.05)
            b === nothing && return KeyEvent(:unknown)
            c = Char(b)
            c == 'A' && return KeyEvent(:up)
            c == 'B' && return KeyEvent(:down)
            c == 'C' && return KeyEvent(:right)
            c == 'D' && return KeyEvent(:left)
            c == 'P' && return KeyEvent(:f1)
            c == 'Q' && return KeyEvent(:f2)
            c == 'R' && return KeyEvent(:f3)
            c == 'S' && return KeyEvent(:f4)
            # Application-keypad mode (DECPAM): each numpad key sends
            # ESC O <letter>. Map back to the literal character so the
            # editor inserts it like a regular keypress.
            c == 'p' && return KeyEvent(:char, '0')
            c == 'q' && return KeyEvent(:char, '1')
            c == 'r' && return KeyEvent(:char, '2')
            c == 's' && return KeyEvent(:char, '3')
            c == 't' && return KeyEvent(:char, '4')
            c == 'u' && return KeyEvent(:char, '5')
            c == 'v' && return KeyEvent(:char, '6')
            c == 'w' && return KeyEvent(:char, '7')
            c == 'x' && return KeyEvent(:char, '8')
            c == 'y' && return KeyEvent(:char, '9')
            c == 'k' && return KeyEvent(:char, '+')
            c == 'l' && return KeyEvent(:char, ',')
            c == 'm' && return KeyEvent(:char, '-')
            c == 'n' && return KeyEvent(:char, '.')
            c == 'o' && return KeyEvent(:char, '/')
            c == 'j' && return KeyEvent(:char, '*')
            c == 'M' && return KeyEvent(:enter)
            c == 'X' && return KeyEvent(:char, '=')
            return KeyEvent(:unknown)
        end
    catch
    end
end

end # module Ressac
