# scripts/precompile_workload.jl
#
# Le parcours rejoué pendant la construction de la sysimage (just
# sysimage) : le même que la précompilation du paquet
# (`Ressac._precompile_tour!`), plus un tour du DSL et des patterns, pour
# que tout ce qu'un joueur touche dans ses premières minutes soit déjà
# compilé. Aucun sous-processus, aucun socket : un faux client OSC.

using Ressac
using Ressac.SynthDSL
Ressac._NRT_ALLOWED[] = false       # jamais de sclang pendant une compilation

# ── Patterns + scheduler ─────────────────────────────────────────────
sched = Ressac.Scheduler(Ressac._PrecompileSink(); cps = 0.5)
sched.t_start = 0.0
for src in ("bd hh sn hh", "<bd sn cp>", "bd(3,8)", "bd*4 [hh hh] ~", "bd!2 sn")
    p = Ressac.parse_minino(src)
    Ressac.set_pattern!(sched, :d1, p |> Ressac.fast(2) |> Ressac.gain(0.8) |> Ressac.lpf("<400 800>"))
    Ressac._step!(sched, 0.0); Ressac._step!(sched, 0.5)
end
Ressac.hush!(sched)

# ── DSL : wrappers, pipe Elixir, compilation, génome, export ─────────
Ressac._LIVE_SCHEDULER[] = nothing
for text in ("@synth :pc_a (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)",
             "@synth :pc_b (freq=110) begin\n  sin_osc(:freq) |> env_perc(0.01, :sustain) |> free_verb(0.3, 0.6)\nend",
             "@synth :pc_c (freq=440) [sin_osc(:freq), sin_osc(:freq + 1)] .|> env_linen(0.01, :sustain, 0.1)")
    try
        Core.eval(SynthDSL, SynthDSL._dsl_parse_all(text))
        g = Ressac.genome_from_dsl(text)
        g === nothing && continue
        Ressac.render_dsl(g, :pc)
        Ressac.render_synthdef(g, :pc)
        Ressac.explain_genome(g)
        Ressac.graph_lines(g)
        Ressac.static_prune_hints(g)
    catch
    end
end
try
    Ressac.synthdef_to_dsl("SynthDef(\\pc_d, { |out, freq = 50, sustain = 1| var sig = Saw.ar(freq); Out.ar(out, Pan2.ar(sig, 0)) }).add;")
catch
end
empty!(Ressac._SYNTH_REGISTRY); empty!(Ressac._SYNTH_ALIASES)

# ── La TUI entière ───────────────────────────────────────────────────
Ressac._precompile_tour!(sched)
