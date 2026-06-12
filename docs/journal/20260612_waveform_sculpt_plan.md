# Waveform Sculpt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manipulate a synth's parameters directly in the waveform view — tug every `ConstArg` + global control, re-render the wave live (NRT, async), group the knobs into soft graph×acoustic neighborhoods that reform as you sculpt, play on demand.

**Architecture:** A new pure-logic module `wave_sculpt.jl` (knob model, spine order, graph proximity, time-domain descriptors, soft clustering — all testable headless) drives a new **sculpt mode** added to the existing `WaveformPane`. The wave re-renders on a `Threads.@spawn` background task (app runs `-t auto`) with a coalescing, bounded handoff. Entry points: a key in the explorer and a `:sculpt <name>` command.

**Tech Stack:** Julia 1.12, module `Ressac`, Tachikoma TUI. Tests via per-file `julia --project=. test/<file>.jl` during iteration, full `just test` before finishing. The default suite stays fast: the NRT render is injected through a seam and mocked; no test calls `sclang`.

**Spec:** `docs/journal/20260612_waveform_sculpt_design.md`.

---

## Conventions for this plan

- **Run one test file (fast):** `julia --project=. test/<file>.jl`
- **Run the full suite:** `just test` (NRT integration stays gated behind `RESSAC_NRT_TESTS=1`).
- **Commit** on `main` after each task (project convention; `git push` only when the user asks). End commit messages with the `Co-Authored-By` trailer.
- Every test that needs audio uses **injected samples** or the **mock render seam** — never `sclang`.

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `src/wave_sculpt.jl` | Pure logic: `Knob`, enumeration, ranges/tug, graph adjacency + hop distance, time-domain descriptors, `KnobSignatures`, soft quartiers, mixed distance. No TUI, no SC. | **Create** |
| `src/pane_waveform.jl` | Add sculpt-mode fields + 7-arg compat ctor, knob-strip render, navigation/tug keys, async render handoff, on-demand play, serialize. | **Modify** |
| `src/pane_synth_explorer.jl` | `_EXPLORER_SCULPT_REQUEST` seam + `M` key to open the focused candidate in sculpt. | **Modify** |
| `src/tui_app.jl` | `_drain_explorer_sculpt!`, run drains for `WaveformPane` too, guard the `Tab` focus-swap, `:sculpt` command. | **Modify** |
| `src/Ressac.jl` | `include("wave_sculpt.jl")` before `pane_waveform.jl`; sculpt slice in `@compile_workload`. | **Modify** |
| `test/test_wave_sculpt.jl` | Pure-logic tests (Tasks 1–3). | **Create** |
| `test/test_pane_waveform.jl` | Sculpt-mode pane tests (Tasks 4–6, 8). | **Modify** |
| `test/test_ui_integration.jl` | Entry-point tests (Task 7). | **Modify** |
| `test/runtests.jl` | Register `test_wave_sculpt.jl`. | **Modify** |

### Shared API (defined in Task 1–3, referenced everywhere)

```julia
struct Knob
    kind::Symbol        # :control | :node
    node_id::Int        # :node → owning node id ; :control → 0
    arg_index::Int      # :node → position in node.args ; :control → 0
    name::Symbol        # slot name (:freq) or control name (:freq)
    lo::Float64
    hi::Float64
    logscale::Bool      # multiplicative sweep when true
end

enumerate_knobs(g)::Vector{Knob}          # controls first, then node knobs in spine order
knob_value(g, kb)::Float64
set_knob!(g, kb, v)                        # mutate ConstArg or g.controls
knob_tug(kb, cur, steps)::Float64          # ± notches, log/linear, clamped
build_adjacency(g)::Dict{Int,Set{Int}}
hop_distance(adj, a, b)::Int
knob_graph_distances(g, knobs)::Matrix{Float64}   # normalized [0,1]
descriptors_from_samples(samples, sr)::Vector{Float64}   # 5 dims, FFT-free
mutable struct KnobSignatures ... end
update_signature!(sigs, idx, delta)
n_signatures(sigs)::Int
soft_quartiers(D; threshold)::Tuple{Vector{Int},Vector{Float64}}  # labels, strength
mixed_distances(dgraph, sigs, knobs)::Matrix{Float64}
```

---

## Task 1: Knob core — enumerate, ranges, value, tug

**Files:**
- Create: `src/wave_sculpt.jl`
- Modify: `src/Ressac.jl` (add include)
- Create: `test/test_wave_sculpt.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Register the new module include**

In `src/Ressac.jl`, add the include immediately before `pane_waveform.jl` (line 70). `wave_sculpt.jl` must load after `genome.jl`/`genome_operators.jl`/`genome_render.jl` (it uses `_const_slots`, `ugen_spec`, `_topo_order`) and before `pane_waveform.jl` (which will use it):

```julia
include("synth_audition.jl")     # GA explorer — audition harness (OSC)
include("pane_synth_explorer.jl")# GA explorer — :explorer PaneImpl
include("wave_sculpt.jl")        # :waveform sculpt — knobs + soft quartiers (pure)
include("pane_waveform.jl")      # :waveform — zoomable sound-wave viewer + sculpt
```

- [ ] **Step 2: Register the new test file**

In `test/runtests.jl`, add after the `test_pane_waveform.jl` line (line 59):

```julia
    include("test_pane_waveform.jl")
    include("test_wave_sculpt.jl")
```

- [ ] **Step 3: Write the failing test**

Create `test/test_wave_sculpt.jl`:

```julia
using Test
using Ressac

# Saw(freq ctrl) → RLPF(in, cutoff=800, rq=0.3). The two RLPF ConstArgs
# are knobs; Saw's freq is a ControlRef (not a ConstArg) → not a node knob.
function _sculpt_genome()
    g = Ressac.Genome()
    s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
    f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                         Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
    g.output_id = f
    return g, s, f
end

@testset "wave_sculpt — knob core" begin
    @testset "enumerate: globals first, then node knobs in spine order" begin
        g, s, f = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        # the 4 globals come first, in CONTROL_EDIT_ORDER
        @test [k.name for k in ks[1:4]] == [:freq, :sustain, :gain, :release]
        @test all(k.kind === :control for k in ks[1:4])
        # then the RLPF ConstArgs (cutoff then rq), as :node knobs on node f
        node_knobs = [k for k in ks if k.kind === :node]
        @test length(node_knobs) == 2
        @test all(k.node_id == f for k in node_knobs)
        @test Set(k.arg_index for k in node_knobs) == Set([2, 3])
    end

    @testset "log inference: freq-like slots & :freq control are log" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        freqctl = ks[findfirst(k -> k.name === :freq && k.kind === :control, ks)]
        @test freqctl.logscale
        gain = ks[findfirst(k -> k.name === :gain, ks)]
        @test !gain.logscale
        # RLPF cutoff slot is named :freq in the catalog → log
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        @test cutoff.logscale
    end

    @testset "value read + write round-trips" begin
        g, _, f = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        @test Ressac.knob_value(g, cutoff) == 800.0
        Ressac.set_knob!(g, cutoff, 1200.0)
        @test Ressac.knob_value(g, cutoff) == 1200.0
        @test g.nodes[f].args[2] isa Ressac.ConstArg
        # control knob writes into g.controls
        freqctl = ks[findfirst(k -> k.name === :freq && k.kind === :control, ks)]
        Ressac.set_knob!(g, freqctl, 110.0)
        @test Ressac.control(g, :freq) == 110.0
    end

    @testset "tug: log moves multiplicatively, clamps to range" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        up = Ressac.knob_tug(cutoff, 800.0, 4)
        @test up > 800.0
        down = Ressac.knob_tug(cutoff, 800.0, -4)
        @test down < 800.0
        # clamps at the slot ceiling/floor
        @test Ressac.knob_tug(cutoff, cutoff.hi, 10) <= cutoff.hi
        @test Ressac.knob_tug(cutoff, cutoff.lo, -10) >= cutoff.lo
    end

    @testset "linear tug for non-log knob" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        rq = ks[findfirst(k -> k.kind === :node && k.arg_index == 3, ks)]
        @test !rq.logscale
        @test Ressac.knob_tug(rq, 0.3, 2) > 0.3
        @test Ressac.knob_tug(rq, 0.3, -2) < 0.3
    end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `julia --project=. test/test_wave_sculpt.jl`
Expected: FAIL — `UndefVarError: enumerate_knobs not defined` (or similar).

- [ ] **Step 5: Write the implementation**

Create `src/wave_sculpt.jl`:

```julia
# src/wave_sculpt.jl
# Sculpt de l'onde — logique PURE (aucun TUI, aucun SC).
# Un « knob » = un nombre réglable du génome : un ConstArg d'un nœud, ou
# un control global. La disposition suit le flux du signal (épine stable) ;
# le groupement « quartiers mous » émerge de la proximité graphe × acoustique.
# Cf. docs/journal/20260612_waveform_sculpt_design.md.

# ── Modèle de knob ─────────────────────────────────────────────────
struct Knob
    kind::Symbol        # :control | :node
    node_id::Int        # :node → id du nœud ; :control → 0
    arg_index::Int      # :node → position dans node.args ; :control → 0
    name::Symbol        # nom du slot (:freq) ou du control (:freq)
    lo::Float64
    hi::Float64
    logscale::Bool      # balayage multiplicatif quand true
end

# Ranges explicites des controls globaux (pas de SlotSpec) : (lo, hi, log).
const _CONTROL_RANGES = Dict{Symbol,Tuple{Float64,Float64,Bool}}(
    :freq    => (20.0, 8000.0, true),
    :sustain => (0.01, 6.0, false),
    :gain    => (0.0, 1.0, false),
    :release => (0.01, 4.0, false),
)

const _KNOB_STEPS = 40   # nb de crans sur toute l'étendue d'un knob

# Un slot dont le nom évoque une fréquence → balayage logarithmique.
_is_logscale(name::Symbol) = occursin("freq", lowercase(String(name))) ||
                             occursin("cutoff", lowercase(String(name)))

# Énumère tous les knobs : globaux d'abord (CONTROL_EDIT_ORDER), puis les
# ConstArgs ordonnés par flux du signal (_topo_order = sources→sortie).
function enumerate_knobs(g::Genome)
    ks = Knob[]
    for name in CONTROL_EDIT_ORDER
        (lo, hi, log) = get(_CONTROL_RANGES, name, (0.0, 1.0, false))
        push!(ks, Knob(:control, 0, 0, name, lo, hi, log))
    end
    order = _topo_order(g)
    pos = Dict(id => i for (i, id) in enumerate(order))
    consts = _const_slots(g)                 # (node_id, arg_index)
    # tri : par position dans l'épine, puis par index d'argument
    sort!(consts; by = ((nid, i),) -> (get(pos, nid, typemax(Int)), i))
    for (nid, i) in consts
        n = g.nodes[nid]
        spec = ugen_spec(n.ugen)
        if spec !== nothing && i <= length(spec.slots)
            sp = spec.slots[i]
            push!(ks, Knob(:node, nid, i, sp.name, sp.lo, sp.hi, _is_logscale(sp.name)))
        else
            # arité transitoire / slot inconnu → balayage log relatif autour
            # de la valeur courante (jamais d'indexation hors-bornes).
            cur = n.args[i].value
            mag = abs(cur) < 1e-9 ? 1.0 : abs(cur)
            push!(ks, Knob(:node, nid, i, :param, cur - 4mag, cur + 4mag, true))
        end
    end
    return ks
end

knob_value(g::Genome, kb::Knob) =
    kb.kind === :control ? control(g, kb.name) : g.nodes[kb.node_id].args[kb.arg_index].value

function set_knob!(g::Genome, kb::Knob, v::Float64)
    if kb.kind === :control
        g.controls[kb.name] = v
    else
        g.nodes[kb.node_id].args[kb.arg_index] = ConstArg(v)
    end
    return g
end

# Tire le knob de `steps` crans (± entiers). Log = multiplicatif, sinon
# linéaire. Toujours clampé dans [lo, hi].
function knob_tug(kb::Knob, cur::Float64, steps::Int)
    if kb.logscale && kb.lo > 0 && kb.hi > 0
        ratio = (kb.hi / kb.lo)^(steps / _KNOB_STEPS)
        return clamp(cur * ratio, kb.lo, kb.hi)
    else
        return clamp(cur + steps * (kb.hi - kb.lo) / _KNOB_STEPS, kb.lo, kb.hi)
    end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `julia --project=. test/test_wave_sculpt.jl`
Expected: PASS — all `wave_sculpt — knob core` subtests green.

- [ ] **Step 7: Commit**

```bash
git add src/wave_sculpt.jl src/Ressac.jl test/test_wave_sculpt.jl test/runtests.jl
git commit -m "feat(sculpt): knob core — enumerate, ranges, value, tug

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Graph proximity — adjacency, hop distance, knob distance matrix

**Files:**
- Modify: `src/wave_sculpt.jl`
- Modify: `test/test_wave_sculpt.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_wave_sculpt.jl` (inside the same file, after the existing `@testset`):

```julia
@testset "wave_sculpt — graph proximity" begin
    # Saw → RLPF → FreeVerb(mix,room,damp). RLPF & FreeVerb knobs are 1 hop apart.
    function _chain()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        r = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        v = Ressac.add_node!(g, :FreeVerb, :ar, Ressac.Arg[Ressac.NodeRef(r),
                             Ressac.ConstArg(0.3), Ressac.ConstArg(0.5), Ressac.ConstArg(0.5)])
        g.output_id = v
        return g, s, r, v
    end

    @testset "adjacency is undirected and covers edges" begin
        g, s, r, v = _chain()
        adj = Ressac.build_adjacency(g)
        @test r in adj[s] && s in adj[r]       # Saw↔RLPF
        @test v in adj[r] && r in adj[v]       # RLPF↔FreeVerb
    end

    @testset "hop distance via BFS" begin
        g, s, r, v = _chain()
        adj = Ressac.build_adjacency(g)
        @test Ressac.hop_distance(adj, r, r) == 0
        @test Ressac.hop_distance(adj, s, r) == 1
        @test Ressac.hop_distance(adj, s, v) == 2
    end

    @testset "knob distance: same node = 0, neighbours small, normalized [0,1]" begin
        g, s, r, v = _chain()
        ks = Ressac.enumerate_knobs(g)
        D = Ressac.knob_graph_distances(g, ks)
        n = length(ks)
        @test size(D) == (n, n)
        @test all(0.0 <= D[i, j] <= 1.0 for i in 1:n, j in 1:n)
        @test all(D[i, i] == 0.0 for i in 1:n)
        # the two RLPF knobs (same node) are at distance 0
        rlpf = findall(k -> k.kind === :node && k.node_id == r, ks)
        @test length(rlpf) == 2
        @test D[rlpf[1], rlpf[2]] == 0.0
        # an RLPF knob is closer to another RLPF knob than to a FreeVerb knob
        verb = findfirst(k -> k.kind === :node && k.node_id == v, ks)
        @test D[rlpf[1], rlpf[2]] < D[rlpf[1], verb]
    end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. test/test_wave_sculpt.jl`
Expected: FAIL — `UndefVarError: build_adjacency not defined`.

- [ ] **Step 3: Write the implementation**

Append to `src/wave_sculpt.jl`:

```julia
# ── Proximité de graphe (épine + quartiers) ────────────────────────
# Adjacence NON ORIENTÉE : les NodeRef de node.args sont les arêtes ;
# pas d'index inverse stocké → on le construit en scannant une fois.
function build_adjacency(g::Genome)
    adj = Dict{Int,Set{Int}}(id => Set{Int}() for id in keys(g.nodes))
    for (id, n) in g.nodes
        for a in n.args
            if a isa NodeRef && haskey(adj, a.id)
                push!(adj[id], a.id)
                push!(adj[a.id], id)
            end
        end
    end
    return adj
end

# Distance en hops (BFS). typemax(Int) si non atteignable.
function hop_distance(adj::Dict{Int,Set{Int}}, a::Int, b::Int)
    a == b && return 0
    haskey(adj, a) || return typemax(Int)
    seen = Set{Int}((a,)); frontier = Int[a]; d = 0
    while !isempty(frontier)
        d += 1
        nxt = Int[]
        for u in frontier, w in adj[u]
            w == b && return d
            if !(w in seen)
                push!(seen, w); push!(nxt, w)
            end
        end
        frontier = nxt
    end
    return typemax(Int)
end

# Le « nœud » d'un knob : un knob global affecte tout le son → on l'ancre
# à la sortie (extrémité « espace » du graphe).
_knob_node(g::Genome, kb::Knob) = kb.kind === :control ? g.output_id : kb.node_id

# Matrice de distances knob-à-knob (hops), normalisée dans [0,1].
function knob_graph_distances(g::Genome, knobs::Vector{Knob})
    adj = build_adjacency(g)
    n = length(knobs)
    raw = fill(0.0, n, n)
    maxfinite = 0.0
    for i in 1:n, j in (i + 1):n
        d = hop_distance(adj, _knob_node(g, knobs[i]), _knob_node(g, knobs[j]))
        h = d == typemax(Int) ? Inf : Float64(d)
        raw[i, j] = h; raw[j, i] = h
        isfinite(h) && h > maxfinite && (maxfinite = h)
    end
    scale = maxfinite < 1e-9 ? 1.0 : maxfinite
    D = fill(0.0, n, n)
    for i in 1:n, j in 1:n
        D[i, j] = isfinite(raw[i, j]) ? raw[i, j] / scale : 1.0
    end
    return D
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. test/test_wave_sculpt.jl`
Expected: PASS — `wave_sculpt — graph proximity` green.

- [ ] **Step 5: Commit**

```bash
git add src/wave_sculpt.jl test/test_wave_sculpt.jl
git commit -m "feat(sculpt): graph proximity — adjacency, hop distance, knob distance matrix

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Descriptors, signatures, soft quartiers, mixed distance

**Files:**
- Modify: `src/wave_sculpt.jl`
- Modify: `test/test_wave_sculpt.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_wave_sculpt.jl`:

```julia
@testset "wave_sculpt — descriptors, signatures, quartiers" begin
    @testset "descriptors_from_samples: sine is dark/tonal, noise is bright/noisy" begin
        sr = 44100
        sine = Float32[sin(2π * 110 * i / sr) for i in 0:(sr ÷ 2)]
        rng = Ressac.Random.MersenneTwister(1)
        noise = Float32[2f0 * rand(rng, Float32) - 1f0 for _ in 0:(sr ÷ 2)]
        ds = Ressac.descriptors_from_samples(sine, sr)
        dn = Ressac.descriptors_from_samples(noise, sr)
        @test length(ds) == 5
        @test all(0.0 .<= ds .<= 1.0)
        # brightness (dim 1) & noisiness (dim 3) higher for noise than sine
        @test dn[1] > ds[1]
        @test dn[3] > ds[3]
    end

    @testset "empty samples → zero vector, no crash" begin
        @test Ressac.descriptors_from_samples(Float32[], 44100) == zeros(5)
    end

    @testset "signatures accumulate a direction; cosine close for parallel" begin
        sigs = Ressac.KnobSignatures()
        Ressac.update_signature!(sigs, 1, [1.0, 0.0, 0.0, 0.0, 0.0])
        Ressac.update_signature!(sigs, 2, [2.0, 0.0, 0.0, 0.0, 0.0])  # same direction
        Ressac.update_signature!(sigs, 3, [0.0, 0.0, 1.0, 0.0, 0.0])  # orthogonal
        @test Ressac.n_signatures(sigs) == 3
        @test Ressac._ac_dist(sigs, 1, 2) < Ressac._ac_dist(sigs, 1, 3)
    end

    @testset "soft_quartiers: tight clusters, boundary knobs lose strength" begin
        # 3 groups along a line: {1,2} close, {3,4} close, {5} alone
        D = [0.0 0.1 0.8 0.9 0.5;
             0.1 0.0 0.7 0.8 0.5;
             0.8 0.7 0.0 0.1 0.6;
             0.9 0.8 0.1 0.0 0.6;
             0.5 0.5 0.6 0.6 0.0]
        labels, strength = Ressac.soft_quartiers(D; threshold = 0.34)
        @test labels[1] == labels[2]          # {1,2} same quartier
        @test labels[3] == labels[4]          # {3,4} same quartier
        @test labels[1] != labels[3]          # different quartiers
        @test length(strength) == 5
        @test all(0.0 .<= strength .<= 1.0)
        # knob 5 sits between groups → weaker membership than a core knob
        @test strength[5] <= strength[1]
    end

    @testset "mixed_distances: α=0 → pure graph; signatures pull α up" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        ks = Ressac.enumerate_knobs(g)
        empty_sigs = Ressac.KnobSignatures()
        Dg = Ressac.knob_graph_distances(g, ks)
        Dm = Ressac.mixed_distances(Dg, empty_sigs, ks)
        @test Dm == Dg                        # no signatures → α=0 → pure graph
    end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. test/test_wave_sculpt.jl`
Expected: FAIL — `UndefVarError: descriptors_from_samples not defined`.

- [ ] **Step 3: Write the implementation**

Append to `src/wave_sculpt.jl`:

```julia
# ── Descripteurs temps-domaine (dérivés des samples, sans FFT) ──────
# 5 proxies bon marché : brillance, énergie-grave, bruité, attaque, tenu.
function descriptors_from_samples(s::AbstractVector{<:Real}, sr::Int)
    n = length(s)
    n == 0 && return zeros(Float64, 5)
    pk = 0.0
    @inbounds for v in s
        a = abs(Float64(v)); a > pk && (pk = a)
    end
    pk = pk < 1e-9 ? 1.0 : pk
    # 1. brillance ≈ taux de passage par zéro
    zc = 0
    @inbounds for i in 2:n
        ((Float64(s[i - 1]) < 0) != (Float64(s[i]) < 0)) && (zc += 1)
    end
    brightness = clamp(zc / n * 4, 0.0, 1.0)
    # 2. énergie grave ≈ part captée par un lisseur un-pôle
    lp = 0.0; lo_e = 0.0; tot_e = 0.0
    @inbounds for k in 1:n
        x = Float64(s[k]) / pk
        lp += 0.05 * (x - lp)
        lo_e += lp^2; tot_e += x^2
    end
    lowratio = clamp(tot_e < 1e-12 ? 0.0 : lo_e / tot_e, 0.0, 1.0)
    # 3. bruité ≈ moyenne des |différences premières|
    d1 = 0.0
    @inbounds for i in 2:n
        d1 += abs(Float64(s[i]) - Float64(s[i - 1])) / pk
    end
    noisiness = clamp(d1 / n * 2, 0.0, 1.0)
    # enveloppe RMS par fenêtres ~10 ms
    w = max(1, sr ÷ 100)
    env = Float64[]
    i = 1
    while i <= n
        j = min(n, i + w - 1)
        acc = 0.0
        @inbounds for k in i:j; acc += (Float64(s[k]) / pk)^2; end
        push!(env, sqrt(acc / (j - i + 1)))
        i = j + 1
    end
    penv = 0.0
    for e in env; e > penv && (penv = e); end
    penv = penv < 1e-9 ? 1.0 : penv
    # 4. attaque ≈ 1 − (temps pour atteindre 90% du pic) / durée
    thr = 0.9 * penv; tpk = length(env)
    for (idx, e) in enumerate(env)
        if e >= thr; tpk = idx; break; end
    end
    attack = clamp(1.0 - tpk / max(length(env), 1), 0.0, 1.0)
    # 5. tenu ≈ moyenne/pic de l'enveloppe
    sustainness = clamp((sum(env) / length(env)) / penv, 0.0, 1.0)
    return [brightness, lowratio, noisiness, attack, sustainness]
end

# ── Signatures acoustiques par knob (ce qu'il déplace dans le son) ──
mutable struct KnobSignatures
    vecs::Dict{Int,Vector{Float64}}   # index knob → direction moyenne
    cnt::Dict{Int,Int}
end
KnobSignatures() = KnobSignatures(Dict{Int,Vector{Float64}}(), Dict{Int,Int}())

n_signatures(sigs::KnobSignatures) = length(sigs.cnt)

# Moyenne mobile (EMA) de la DIRECTION du déplacement descripteur.
function update_signature!(sigs::KnobSignatures, idx::Int, delta::Vector{Float64}; β::Float64 = 0.4)
    nrm = sqrt(sum(abs2, delta))
    nrm < 1e-9 && return sigs
    dir = delta ./ nrm
    cur = get(sigs.vecs, idx, zeros(Float64, length(delta)))
    length(cur) == length(dir) || (cur = zeros(Float64, length(dir)))
    sigs.vecs[idx] = (1 - β) .* cur .+ β .* dir
    sigs.cnt[idx] = get(sigs.cnt, idx, 0) + 1
    return sigs
end

# Distance acoustique ∈ [0,1] (cosinus). Knob sans signature → 1 (neutre).
function _ac_dist(sigs::KnobSignatures, i::Int, j::Int)
    a = get(sigs.vecs, i, nothing); b = get(sigs.vecs, j, nothing)
    (a === nothing || b === nothing) && return 1.0
    na = sqrt(sum(abs2, a)); nb = sqrt(sum(abs2, b))
    (na < 1e-9 || nb < 1e-9) && return 1.0
    dotp = sum(a[k] * b[k] for k in 1:min(length(a), length(b)))
    return clamp((1 - dotp / (na * nb)) / 2, 0.0, 1.0)
end

# ── Distance mixte graphe × acoustique ─────────────────────────────
# α monte de 0 vers 0.7 à mesure que les signatures se remplissent.
function mixed_distances(dgraph::Matrix{Float64}, sigs::KnobSignatures, knobs::Vector{Knob})
    n = length(knobs)
    α = clamp(0.7 * n_signatures(sigs) / max(n, 1), 0.0, 0.7)
    α < 1e-9 && return dgraph
    D = fill(0.0, n, n)
    for i in 1:n, j in 1:n
        i == j && continue
        D[i, j] = (1 - α) * dgraph[i, j] + α * _ac_dist(sigs, i, j)
    end
    return D
end

# ── Quartiers mous (clustering glouton par seuil sur la matrice) ───
# Renvoie (labels, force) : force ∈ [0,1] = à quel point le knob est au
# cœur de son quartier (loin du quartier voisin) → la bordure est « molle ».
function soft_quartiers(D::AbstractMatrix; threshold::Float64 = 0.34)
    n = size(D, 1)
    seeds = Int[]; labels = zeros(Int, n)
    for i in 1:n
        best = 0; bd = Inf
        for (ci, s) in enumerate(seeds)
            D[i, s] < bd && (bd = D[i, s]; best = ci)
        end
        if best == 0 || bd > threshold
            push!(seeds, i); labels[i] = length(seeds)
        else
            labels[i] = best
        end
    end
    strength = ones(Float64, n)
    if length(seeds) > 1
        for i in 1:n
            own = seeds[labels[i]]
            do_ = D[i, own]
            no = Inf
            for (ci, s) in enumerate(seeds)
                ci == labels[i] && continue
                D[i, s] < no && (no = D[i, s])
            end
            strength[i] = clamp((no - do_) / (no + do_ + 1e-9), 0.0, 1.0)
        end
    end
    return labels, strength
end
```

> Note: `wave_sculpt.jl` uses `Random` (for nothing yet) but the test references `Ressac.Random`. `Random` is already imported by `genome_operators.jl` (`using Random`) into the `Ressac` module, so `Ressac.Random` resolves. No extra import needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. test/test_wave_sculpt.jl`
Expected: PASS — `wave_sculpt — descriptors, signatures, quartiers` green.

- [ ] **Step 5: Commit**

```bash
git add src/wave_sculpt.jl test/test_wave_sculpt.jl
git commit -m "feat(sculpt): descriptors, signatures, soft quartiers, mixed distance

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: WaveformPane sculpt mode — fields, knob strip, navigation, tug

**Files:**
- Modify: `src/pane_waveform.jl`
- Modify: `test/test_pane_waveform.jl`

This task adds sculpt state + the knob strip render + navigation/tug keys. Tugging mutates the genome and marks a render request; the **actual re-render is Task 5** (here we only assert the value changed and the request counter bumped).

- [ ] **Step 1: Write the failing test**

Append to `test/test_pane_waveform.jl`, before the final `end` of the outer `@testset`:

```julia
    @testset "sculpt mode" begin
        # Saw → RLPF genome; build a sculpt pane straight from it.
        function _g()
            g = Ressac.Genome()
            s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
            f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                                 Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
            g.output_id = f
            return g
        end
        mkscu() = Ressac._pane_new(:waveform, Dict{String,Any}(
            "genome" => Ressac.serialize_genome(_g()),
            "label" => "scu", "sculpt" => true))

        @testset "ctor builds knobs + starts in sculpt" begin
            p = mkscu()
            @test p.sculpt
            @test !isempty(p.knobs)
            @test length(p.labels) == length(p.knobs)   # a quartier per knob
            @test p.focus == 1
        end

        @testset "7-arg legacy ctor still works (no sculpt)" begin
            s = Float32[0.0f0, 1.0f0]
            p = Ressac.WaveformPane(s, 44100, 1, 2, "x", nothing, (0, 0, 0, 0))
            @test !p.sculpt && isempty(p.knobs)
        end

        @testset "s toggles sculpt on a plain viewer" begin
            s = Float32[sin(2π * 220 * i / 44100) for i in 0:1000]
            p = Ressac.WaveformPane(s, 44100, 1, length(s), "v", nothing, (0, 0, 0, 0))
            @test !p.sculpt
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('s')) == true
            @test p.sculpt
        end

        @testset "j/k move focus and clamp at the ends" begin
            p = mkscu()
            Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
            @test p.focus == 2
            for _ in 1:50; Ressac.handle_key!(p, Tachikoma.KeyEvent('j')); end
            @test p.focus == length(p.knobs)            # clamped, no wrap
            for _ in 1:50; Ressac.handle_key!(p, Tachikoma.KeyEvent('k')); end
            @test p.focus == 1
        end

        @testset "h/l tug the focused knob and bump the render request" begin
            p = mkscu()
            # focus the cutoff knob (first :node knob)
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            before = Ressac.knob_value(p.genome, p.knobs[ni])
            v0 = p.req_version
            Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
            @test Ressac.knob_value(p.genome, p.knobs[ni]) > before   # tugged up
            @test p.req_version > v0                                  # re-render requested
            Ressac.handle_key!(p, Tachikoma.KeyEvent('h'))
            @test Ressac.knob_value(p.genome, p.knobs[ni]) < Ressac.knob_value(p.genome, p.knobs[ni]) + 1
        end

        @testset "in view mode, h/l still pan (context-dependent)" begin
            s = Float32[sin(2π * 220 * i / 44100) for i in 0:20000]
            p = Ressac.WaveformPane(s, 44100, 1, length(s), "v", nothing, (0, 0, 0, 0))
            p.view_len = 8000; p.view_start = 10000
            Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))   # view mode → pan
            @test p.view_start > 10000
        end

        @testset "render! draws the knob strip in sculpt" begin
            p = mkscu()
            tb = Tachikoma.TestBackend(80, 20)
            Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 20), tb.buf)
            joined = join((Tachikoma.row_text(tb, r) for r in 1:20), "\n")
            @test occursin("SCULPT", joined)
        end
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: FAIL — `type WaveformPane has no field sculpt` (struct not extended yet).

- [ ] **Step 3: Extend the struct + ctor**

In `src/pane_waveform.jl`, replace the struct definition (lines 7–15) and constructor (lines 17–30) with:

```julia
mutable struct WaveformPane <: PaneImpl
    samples::Vector{Float32}
    sr::Int
    view_start::Int                 # 1er échantillon visible (1-based)
    view_len::Int                   # nb d'échantillons visibles
    label::String
    genome::Union{Nothing,Genome}   # source (re-rendu / persistance)
    last_rect::NTuple{4,Int}        # (x,y,w,h) de la zone de tracé (souris)
    # ── mode sculpt ────────────────────────────────────────────────
    sculpt::Bool
    knobs::Vector{Knob}
    focus::Int                      # index du knob focalisé
    labels::Vector{Int}             # quartier par knob
    strength::Vector{Float64}       # vivacité d'appartenance par knob
    dgraph::Matrix{Float64}         # distances de graphe (cache par structure)
    sigs::KnobSignatures            # signatures acoustiques apprises
    last_descr::Vector{Float64}     # descripteurs du dernier rendu
    last_tugged::Int                # knob changé depuis le dernier rendu (0 = aucun/ambigu)
    req_version::Int                # incrémenté à chaque tir (coalescing)
    rendered_version::Int
    rendering::Bool
    closed::Bool
    pending::Union{Nothing,Tuple{Vector{Float32},Int,Vector{Float64},Int}}  # (samples,sr,descr,version)
    audition::AuditionState
    lock::ReentrantLock
end

# Constructeur de compatibilité 7-args (anciens appels + tests viewer).
WaveformPane(samples, sr, vs, vl, label, genome, last_rect) =
    WaveformPane(samples, sr, vs, vl, label, genome, last_rect,
                 false, Knob[], 1, Int[], Float64[], zeros(0, 0),
                 KnobSignatures(), Float64[], 0, 0, 0, false, false,
                 nothing, AuditionState(1), ReentrantLock())

function _waveform_pane_ctor(args::AbstractDict)
    label = String(get(args, "label", "waveform"))
    sculpt = Bool(get(args, "sculpt", false))
    samples = Float32[]; sr = 44100; g = nothing
    if haskey(args, "genome")
        try
            g = deserialize_genome(args["genome"])
            samples, sr = _WAVE_RENDER[](g)
        catch
            samples = Float32[]
        end
    end
    n = length(samples)
    p = WaveformPane(samples, sr, 1, max(n, 1), label, g, (0, 0, 0, 0))
    if sculpt && g !== nothing
        _sculpt_init!(p)
    end
    return p
end

# Seam de rendu : par défaut le rendu NRT, surchargeable en test (sync, mock).
const _WAVE_RENDER = Ref{Function}(render_genome_audio)
# En test on rend SYNCHRONE (pas de thread → pas de course).
const _WAVE_SYNC = Ref{Bool}(false)
```

> The seam pattern mirrors `_EXPLORER_ANALYZE`: call `_WAVE_RENDER[](g)`. Tests set `_WAVE_RENDER[]` to a fake and `_WAVE_SYNC[] = true`. (Both consts must be a `Ref` only — never also a function of the same name, or the binding collides.)

- [ ] **Step 4: Add sculpt init + navigation/tug, wire keys**

Still in `src/pane_waveform.jl`, add these helpers (place them after `_wave_pan!`, around line 46) :

```julia
# Initialise l'état sculpt : knobs, distances de graphe, quartiers (α=0).
function _sculpt_init!(p::WaveformPane)
    p.sculpt = true
    p.genome === nothing && return p
    p.knobs = enumerate_knobs(p.genome)
    p.focus = 1
    p.dgraph = knob_graph_distances(p.genome, p.knobs)
    _sculpt_recluster!(p)
    return p
end

# Recalcule quartiers + force depuis (graphe × signatures). NE déplace rien.
function _sculpt_recluster!(p::WaveformPane)
    isempty(p.knobs) && (p.labels = Int[]; p.strength = Float64[]; return p)
    D = mixed_distances(p.dgraph, p.sigs, p.knobs)
    p.labels, p.strength = soft_quartiers(D)
    return p
end

# Tire le knob focalisé de `steps` crans, marque un re-render.
function _sculpt_tug!(p::WaveformPane, steps::Int)
    (isempty(p.knobs) || p.genome === nothing) && return
    kb = p.knobs[clamp(p.focus, 1, length(p.knobs))]
    cur = knob_value(p.genome, kb)
    set_knob!(p.genome, kb, knob_tug(kb, cur, steps))
    # un seul knob changé depuis le dernier rendu → attribuable
    p.last_tugged = (p.last_tugged == 0 || p.last_tugged == p.focus) ? p.focus : -1
    p.req_version += 1
    return
end
```

Then replace `handle_key!` (lines 106–116) with a sculpt-aware version:

```julia
function handle_key!(p::WaveformPane, evt)
    evt isa TK.KeyEvent || return false
    ch = evt.char; k = evt.key
    ch == 's' && (p.sculpt ? (p.sculpt = false) : _sculpt_init!(p); return true)
    if p.sculpt && !isempty(p.knobs)
        (ch == 'j' || k === :down) && (p.focus = clamp(p.focus + 1, 1, length(p.knobs)); return true)
        (ch == 'k' || k === :up)   && (p.focus = clamp(p.focus - 1, 1, length(p.knobs)); return true)
        (k === :tab)               && (_sculpt_focus_neighbour!(p, +1); return true)
        (k === :backtab)           && (_sculpt_focus_neighbour!(p, -1); return true)
        (ch == 'l' || k === :right) && (_sculpt_tug!(p, +1); return true)
        (ch == 'h' || k === :left)  && (_sculpt_tug!(p, -1); return true)
        ch == 'L' && (_wave_pan!(p, p.view_len ÷ 8); return true)   # pan reste accessible
        ch == 'H' && (_wave_pan!(p, -(p.view_len ÷ 8)); return true)
        (ch == '\r' || k === :enter) && return _wave_play!(p)
        ch == '0' && (p.view_start = 1; p.view_len = max(length(p.samples), 1); return true)
        return false
    end
    n = length(p.samples); n == 0 && return false
    (ch == 'l' || k === :right) && (_wave_pan!(p, p.view_len ÷ 8); return true)
    (ch == 'h' || k === :left)  && (_wave_pan!(p, -(p.view_len ÷ 8)); return true)
    (ch == '+' || ch == 'i')    && (_wave_zoom!(p, 0.5, 0.8); return true)
    (ch == '-' || ch == 'o')    && (_wave_zoom!(p, 0.5, 1.25); return true)
    ch == '0' && (p.view_start = 1; p.view_len = n; return true)
    return false
end

# Saute au knob dont le nœud est le plus proche dans le graphe (≠ position
# courante), dans la direction `dir` (avant/arrière de l'épine en cas d'égalité).
function _sculpt_focus_neighbour!(p::WaveformPane, dir::Int)
    n = length(p.knobs); n <= 1 && return
    i = clamp(p.focus, 1, n)
    cand = dir > 0 ? (i+1:n) : (i-1:-1:1)
    best = i; bd = Inf
    for j in cand
        d = p.dgraph[i, j]
        if d < bd
            bd = d; best = j
        end
    end
    p.focus = best == i ? clamp(i + dir, 1, n) : best
    return
end

# Stubs remplacés en Tasks 5/6 (re-render + audio). Définis ici pour que
# les touches existent dès maintenant.
_wave_play!(p::WaveformPane) = true
```

- [ ] **Step 5: Render the knob strip**

Replace `render!` (lines 83–104) so it draws the strip in sculpt mode (and pumps the render — the pump is a no-op stub until Task 5):

```julia
function render!(p::WaveformPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    p.sculpt && _sculpt_pump!(p)              # consomme un rendu prêt (Task 5)
    n = length(p.samples)
    head = if p.sculpt
        "SCULPT · $(p.label) · s vue · j/k knob · Tab voisin · h/l tire · ⏎ joue"
    elseif n == 0
        "WAVE · $(p.label) · (pas d'audio)"
    else
        vm = round(p.view_len / p.sr * 1000; digits = 1)
        tm = round(n / p.sr * 1000; digits = 0)
        "WAVE · $(p.label) · $(vm)ms/$(tm)ms · molette zoom · h/l défile · 0 tout · s sculpt"
    end
    _render_pane_block_simple!(rect, head, buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 2 || inner.height < 1) && return
    if p.sculpt
        striph = min(2, inner.height)
        waveh = inner.height - striph
        if waveh >= 1 && n > 0
            warea = TK.Rect(inner.x, inner.y, inner.width, waveh)
            p.last_rect = (warea.x, warea.y, warea.width, waveh)
            _render_wave_buffer!(p, warea, buf)
        end
        _render_knob_strip!(p, TK.Rect(inner.x, inner.y + max(waveh, 0), inner.width, striph), buf)
        return
    end
    p.last_rect = (inner.x, inner.y, inner.width, inner.height)
    if n == 0
        TK.set_string!(buf, inner.x, inner.y,
                       "  (pas d'audio — rendu NRT indisponible)", TK.tstyle(:text_dim))
        return
    end
    _render_wave_buffer!(p, inner, buf)
    return
end

# Bande de knobs : nom + valeur du focalisé ; les autres en pastille teintée
# par quartier, vivacité = force d'appartenance (bordure = terne).
function _render_knob_strip!(p::WaveformPane, area::TK.Rect, buf::TK.Buffer)
    isempty(p.knobs) && return
    kb = p.knobs[clamp(p.focus, 1, length(p.knobs))]
    val = knob_value(p.genome, kb)
    line = "[$(kb.name)] $(round(val; sigdigits = 4))   "
    for (i, k) in enumerate(p.knobs)
        mark = i == p.focus ? "◉" : (get(p.strength, i, 1.0) > 0.5 ? "●" : "·")
        line *= mark
    end
    TK.set_string!(buf, area.x, area.y, first(line, area.width), TK.tstyle(:text))
    return
end

# Stub remplacé en Task 5.
_sculpt_pump!(p::WaveformPane) = nothing
```

> `TK.tstyle(:text)` is already used in `pane_interface.jl`; quartier colouring can be refined later — the strength→`●`/`·` distinction already conveys the soft boundary.

- [ ] **Step 6: Run the test to verify it passes**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: PASS — the existing viewer tests AND the new `sculpt mode` subtests green.

- [ ] **Step 7: Commit**

```bash
git add src/pane_waveform.jl test/test_pane_waveform.jl
git commit -m "feat(sculpt): WaveformPane sculpt mode — strip, navigation, tug

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Async re-render handoff + acoustic signature feed + reclustering

**Files:**
- Modify: `src/pane_waveform.jl`
- Modify: `test/test_pane_waveform.jl`

Replace the `_sculpt_pump!` stub with the coalescing background-render machinery. Tests inject a synchronous mock render (no `sclang`).

- [ ] **Step 1: Write the failing test**

Append inside the `sculpt mode` `@testset` in `test/test_pane_waveform.jl`:

```julia
        @testset "tug → re-render swaps samples and learns a signature" begin
            # mock render: brightness depends on the cutoff value (so a tug
            # produces a measurable descriptor delta). Synchronous.
            old = Ressac._WAVE_RENDER[]; oldsync = Ressac._WAVE_SYNC[]
            Ressac._WAVE_RENDER[] = function (g)
                cut = 800.0
                for n in values(g.nodes), a in n.args
                    a isa Ressac.ConstArg && a.value > 50 && (cut = a.value)
                end
                f = cut / 44100 * 4          # higher cutoff → higher pitch test tone
                s = Float32[sin(2π * f * 1000 * i / 44100) for i in 0:2000]
                return s, 44100
            end
            Ressac._WAVE_SYNC[] = true
            try
                p = mkscu()
                ni = findfirst(k -> k.kind === :node, p.knobs)
                p.focus = ni
                samples0 = copy(p.samples)
                Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))   # tug → req_version++
                Ressac._sculpt_pump!(p)                          # sync render + apply
                @test p.rendered_version == p.req_version
                @test p.samples != samples0                      # wave changed
                @test !isempty(p.last_descr)
                # tug the SAME knob again → its signature accumulates
                Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                Ressac._sculpt_pump!(p)
                @test Ressac.n_signatures(p.sigs) >= 1
            finally
                Ressac._WAVE_RENDER[] = old; Ressac._WAVE_SYNC[] = oldsync
            end
        end

        @testset "reclustering never moves a knob (positions stable)" begin
            old = Ressac._WAVE_RENDER[]; oldsync = Ressac._WAVE_SYNC[]
            Ressac._WAVE_RENDER[] = (g -> (Float32[sin(2π * 110 * i / 44100) for i in 0:2000], 44100))
            Ressac._WAVE_SYNC[] = true
            try
                p = mkscu()
                names0 = [k.name for k in p.knobs]
                for _ in 1:6
                    Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))
                    Ressac._sculpt_pump!(p)
                end
                @test [k.name for k in p.knobs] == names0   # spine order unchanged
            finally
                Ressac._WAVE_RENDER[] = old; Ressac._WAVE_SYNC[] = oldsync
            end
        end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: FAIL — `rendered_version` never catches up (pump is a no-op stub).

- [ ] **Step 3: Implement the pump**

In `src/pane_waveform.jl`, replace the `_sculpt_pump!` stub with:

```julia
# Applique un résultat de rendu prêt (s'il y en a un) : swap des samples +
# descripteurs + signature (si UN seul knob a changé depuis le dernier rendu)
# + re-teinte des quartiers. NE déplace JAMAIS un knob (positions = structure).
function _sculpt_apply_pending!(p::WaveformPane)
    ready = lock(p.lock) do
        r = p.pending; p.pending = nothing; r
    end
    ready === nothing && return false
    samples, sr, descr, ver = ready
    ver <= p.rendered_version && return false
    prev = p.last_descr
    p.samples = samples; p.sr = sr
    p.view_start = 1; p.view_len = max(length(samples), 1)
    p.rendered_version = ver
    if p.last_tugged > 0 && !isempty(prev) && length(prev) == length(descr)
        update_signature!(p.sigs, p.last_tugged, descr .- prev)   # attribution
    end
    p.last_descr = descr
    p.last_tugged = 0
    _sculpt_recluster!(p)
    return true
end

# Boucle de rendu (appelée chaque frame par render!). Applique un résultat
# prêt ; si en retard et libre, lance UN rendu (thread worker en prod, ou
# synchrone en test). Borné : au plus 1 rendu en vol, coalescé sur la
# dernière version demandée.
function _sculpt_pump!(p::WaveformPane)
    p.genome === nothing && return
    _sculpt_apply_pending!(p)
    if !p.rendering && !p.closed && p.req_version > p.rendered_version
        p.rendering = true
        ver = p.req_version
        gcopy = _copy_genome(p.genome)
        if _WAVE_SYNC[]
            _sculpt_render_into!(p, gcopy, ver)   # remplit pending (synchrone)
            _sculpt_apply_pending!(p)             # …et applique dans le même tour
        else
            Threads.@spawn _sculpt_render_into!(p, gcopy, ver)
        end
    end
    return
end

# Rend `g` (NRT) puis dépose le résultat dans le slot sous verrou.
function _sculpt_render_into!(p::WaveformPane, g::Genome, ver::Int)
    local samples, sr, descr
    try
        samples, sr = _WAVE_RENDER[](g)
        descr = descriptors_from_samples(samples, sr)
    catch
        lock(p.lock) do; p.rendering = false; end
        return
    end
    lock(p.lock) do
        p.closed || (p.pending = (samples, sr, descr, ver))
        p.rendering = false
    end
    return
end
```

Also add the cleanup hook (near `serialize`, around line 134):

```julia
function on_close!(p::WaveformPane)
    lock(p.lock) do
        p.closed = true
    end
    return nothing
end
```

> In sync mode the spawned-render branch is skipped, so `_sculpt_render_into!` runs inline and a second `_sculpt_pump!` (called by the test, and by `render!` each frame in prod) applies the pending result. In async prod mode, the next frame's `render!` → `_sculpt_pump!` applies whatever the worker thread finished. Coalescing: while `rendering` is true no new task starts; when it finishes, if more tugs arrived, the next pump starts a fresh render for the latest `req_version`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: PASS — re-render + signature subtests green.

- [ ] **Step 5: Commit**

```bash
git add src/pane_waveform.jl test/test_pane_waveform.jl
git commit -m "feat(sculpt): async re-render handoff + acoustic signature feed

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Play on demand (⏎)

**Files:**
- Modify: `src/pane_waveform.jl`
- Modify: `test/test_pane_waveform.jl`

- [ ] **Step 1: Write the failing test**

Append inside the `sculpt mode` `@testset`:

```julia
        @testset "⏎ plays via the live audition path; no-op without a session" begin
            p = mkscu()
            # no live scheduler in tests → _explorer_osc() is nothing → safe no-op
            @test Ressac._explorer_osc() === nothing
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter)) == true   # consumed, no crash
        end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: PASS already for the no-op? No — `_wave_play!` is a stub returning `true`, so this passes trivially. To make the test meaningful, first make `_wave_play!` actually call the audition path; the test asserts it stays a safe no-op when there is no session. Treat Step 1 as the spec; implement Step 3 then confirm.

- [ ] **Step 3: Implement `_wave_play!`**

In `src/pane_waveform.jl`, replace the `_wave_play!` stub with:

```julia
# ⏎ : joue le son courant sur le serveur SC live (si une session tourne).
# Réutilise le chemin d'audition de l'explorer (audition_hold!). Sans
# scheduler live → no-op silencieux (mais touche consommée).
function _wave_play!(p::WaveformPane)
    p.genome === nothing && return true
    osc = _explorer_osc()
    osc === nothing && return true
    audition_hold!(p.audition, osc, p.genome,
                   control(p.genome, :freq), control(p.genome, :sustain))
    return true
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: PASS — ⏎ subtest green (safe no-op without a session).

- [ ] **Step 5: Commit**

```bash
git add src/pane_waveform.jl test/test_pane_waveform.jl
git commit -m "feat(sculpt): ⏎ plays the current sound via live audition

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Entry points — explorer `M` + `:sculpt <name>`

**Files:**
- Modify: `src/pane_synth_explorer.jl`
- Modify: `src/tui_app.jl`
- Modify: `test/test_ui_integration.jl`

- [ ] **Step 1: Add the sculpt seam + explorer key**

In `src/pane_synth_explorer.jl`, after the waveform request seam (line 16), add:

```julia
# Seam : ouvrir le candidat focalisé en mode SCULPT (pane :waveform sculpt).
const _EXPLORER_SCULPT_REQUEST = Ref{Union{Nothing,Tuple{Any,String}}}(nothing)
```

Add the helper next to `_explorer_open_waveform!` (after line 67):

```julia
# M : ouvre le candidat focalisé en mode SCULPT (manipuler les params).
function _explorer_sculpt_focus!(p)
    g = p.pop.candidates[p.focus].genome
    _EXPLORER_SCULPT_REQUEST[] = (serialize_genome(g), "candidat #$(p.focus)")
    _explorer_log!("[INFO] sculpt du candidat #$(p.focus)…")
    return true
end
```

Bind `M` in the explorer key handler, next to the `V` binding (line 745):

```julia
    ch == 'V' && return _explorer_open_waveform!(p)
    ch == 'M' && return _explorer_sculpt_focus!(p)
```

- [ ] **Step 2: Drain the sculpt seam (and run drains for WaveformPane too)**

In `src/tui_app.jl`, add the drain function after `_drain_explorer_waveform!` (after line 555):

```julia
"""
    _drain_explorer_sculpt!(m) -> Bool

Open a :waveform pane in SCULPT mode for a posted genome (explorer `M`).
"""
function _drain_explorer_sculpt!(m::RessacApp)
    req = _EXPLORER_SCULPT_REQUEST[]
    req === nothing && return false
    _EXPLORER_SCULPT_REQUEST[] = nothing
    gser, label = req
    cmd_split!(m.workspaces, "waveform",
               Dict{String,Any}("genome" => gser, "label" => label, "sculpt" => true))
    return true
end
```

Then broaden the drain block (lines 508–511) so seams drain regardless of the focused pane kind (each drain is a no-op when its Ref is empty):

```julia
    _drain_explorer_export!(m)
    _drain_explorer_waveform!(m)
    _drain_explorer_sculpt!(m)
    return true
end
```

(Remove the `if pane isa SynthExplorerPane` wrapper around these three calls; keep the earlier `pane isa EditorPane` command handling intact.)

- [ ] **Step 3: Guard the Tab focus-swap so sculpt panes get Tab**

In `src/tui_app.jl`, change the Tab intercept (line 1402) to skip the focus-swap when the focused pane is a `WaveformPane` in sculpt mode:

```julia
    if is_press && evt.key === :tab && ed.mode === :normal && _synth_pane_open(m) &&
       !_is_waveform_sculpt_focused(m)
        _swap_focus!(m)
        return
    end
```

Add the predicate near `_synth_pane_open` (after line 347):

```julia
# Le pane focalisé est-il un WaveformPane en mode sculpt ? (laisse passer Tab)
function _is_waveform_sculpt_focused(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    (leaf === nothing || isempty(leaf.tabs)) && return false
    pane = leaf.tabs[leaf.current_tab]
    return pane isa WaveformPane && pane.sculpt
end
```

- [ ] **Step 4: Add the `:sculpt` command**

In `src/tui_app.jl`, add after the `:explain` registration (after line 2631):

```julia
# ── Sculpt : :sculpt [nom] ──────────────────────────────────────────
# Ouvre un synth en mode sculpt. `:sculpt <nom>` lit
# plugins/user-synths/<nom>.jl ; `:sculpt` seul prend le buffer focalisé.
function _sculpt_command!(m::RessacApp, name::AbstractString)
    nm = strip(String(name))
    g = if isempty(nm)
        ed = _active_editor(m)
        ed === nothing ? nothing : genome_from_dsl(TK.text(ed))
    else
        path = joinpath(pwd(), "plugins", "user-synths", "$nm.jl")
        isfile(path) ? genome_from_text(read(path, String)) : nothing
    end
    g === nothing &&
        (_push_app_log!(m, "[ERROR] :sculpt — pas un synth DSL reconnu"); return)
    cmd_split!(m.workspaces, "waveform",
               Dict{String,Any}("genome" => serialize_genome(g),
                                "label" => isempty(nm) ? "buffer" : nm, "sculpt" => true))
    return
end
_register_literal!(m -> _sculpt_command!(m, ""), "sculpt")
_register_regex!(r"^sculpt\s+([\w.-]+)$",
    (m, mt) -> _sculpt_command!(m, mt.captures[1]))
```

> `genome_from_text` recovers the genome from an exported synth's embedded `ressac-genome:` comment; `genome_from_dsl` parses a plain DSL buffer. Both already exist (`synth_explainer.jl`).

- [ ] **Step 5: Write the entry-point test**

Append to `test/test_ui_integration.jl` (a new `@testset` near the other pane-opening tests; reuse the file's `_new_app` / `_exec_ex_command!` helpers):

```julia
@testset "sculpt entry points" begin
    @testset "explorer M posts a sculpt request" begin
        Ressac._EXPLORER_SCULPT_REQUEST[] = nothing
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 5))
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('M')) == true
        @test Ressac._EXPLORER_SCULPT_REQUEST[] !== nothing
        Ressac._EXPLORER_SCULPT_REQUEST[] = nothing
    end

    @testset ":sculpt <name> opens a sculpt waveform pane" begin
        # write a tiny exported synth (DSL only — no sclang needed to parse)
        dir = joinpath(pwd(), "plugins", "user-synths")
        mkpath(dir)
        path = joinpath(dir, "scutest.jl")
        write(path, "@synth :scutest (freq=120, sustain=0.5) begin\n" *
                    "  n1 = ugen(:Saw, :freq)\n" *
                    "  ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, " *
                    "ugen(:RLPF, n1, 800, 0.3))), 0.95)\nend\n")
        try
            # mock render so opening the pane does not call sclang
            old = Ressac._WAVE_RENDER[]
            Ressac._WAVE_RENDER[] = (g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100))
            app, _ = _new_app()
            try
                _exec_ex_command!(app, "sculpt scutest")
                # a :waveform pane in sculpt now exists in the current workspace
                ws = Ressac.current_workspace(app.workspaces)
                found = any(l -> any(t -> t isa Ressac.WaveformPane && t.sculpt, l.tabs),
                            collect(Ressac._all_leaves(ws.tree)))
                @test found
            finally
                Ressac._WAVE_RENDER[] = old
            end
        finally
            rm(path; force = true)
        end
    end
end
```

> If `_all_leaves` has a different name in the workspace manager, grep `src/workspace_manager.jl` for the tree-walk helper used by other tests in this file and use that; the assertion only needs to find a sculpt `WaveformPane` in the tree.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'` *(or `just test`)* — the UI integration test needs the full app context.
Expected: PASS — `sculpt entry points` green; no other test regressed.

- [ ] **Step 7: Commit**

```bash
git add src/pane_synth_explorer.jl src/tui_app.jl test/test_ui_integration.jl
git commit -m "feat(sculpt): entry points — explorer M + :sculpt command

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Persistence, export, precompile workload

**Files:**
- Modify: `src/pane_waveform.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/test_pane_waveform.jl`

- [ ] **Step 1: Write the failing test**

Append inside the `sculpt mode` `@testset`:

```julia
        @testset "serialize carries the sculpt flag → restored in sculpt" begin
            p = mkscu()
            d = Ressac.serialize(p)
            @test d["sculpt"] == true
            @test haskey(d, "genome")
            p2 = Ressac._pane_new(:waveform, d)
            @test p2.sculpt
            @test !isempty(p2.knobs)
        end

        @testset "e posts an export request carrying the edited genome" begin
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
            p = mkscu()
            ni = findfirst(k -> k.kind === :node, p.knobs)
            p.focus = ni
            Ressac.handle_key!(p, Tachikoma.KeyEvent('l'))   # edit a knob
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('e')) == true
            req = Ressac._EXPLORER_EXPORT_REQUEST[]
            @test req !== nothing
            _, dsl = req
            @test occursin("ressac-genome:", dsl)            # genome embedded
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: FAIL — `serialize` lacks the `sculpt` key; `e` is unhandled in sculpt mode.

- [ ] **Step 3: Implement serialize + export**

In `src/pane_waveform.jl`, replace `serialize` (lines 134–138) with:

```julia
function serialize(p::WaveformPane)
    d = Dict{String,Any}("label" => p.label, "sculpt" => p.sculpt)
    p.genome !== nothing && (d["genome"] = serialize_genome(p.genome))
    return d
end
```

Add an `e` binding inside the sculpt branch of `handle_key!` (next to the other sculpt keys, before the trailing `return false`):

```julia
        ch == 'e' && return _wave_export!(p)
```

And add the export helper (near `_wave_play!`):

```julia
# e : exporte le génome sculpté (DSL multi-ligne + génome embarqué) vers un
# éditeur, via le même seam que l'export de l'explorer.
function _wave_export!(p::WaveformPane)
    p.genome === nothing && return true
    sym = Symbol(replace(p.label, r"[^\w]" => "_"))
    dsl = render_dsl(p.genome, sym) * "\n" * genome_comment(p.genome) * "\n"
    _EXPLORER_EXPORT_REQUEST[] = (String(sym), dsl)
    return true
end
```

> `render_dsl` + `genome_comment` already produce the multi-line export with the embedded `ressac-genome:` comment (`genome_render.jl` / `synth_explainer.jl`). `_EXPLORER_EXPORT_REQUEST` is drained for any focused pane after Task 7 broadened the drain block.

- [ ] **Step 4: Add the precompile workload slice**

In `src/Ressac.jl`, inside `@compile_workload begin … end` (after the existing genome/GA exercises, before its `end`), add:

```julia
    # Sculpt de l'onde : exercise the pure knob/quartier path.
    _scg = Genome()
    _sc_s = add_node!(_scg, :Saw, :ar, Arg[ControlRef(:freq)])
    _sc_f = add_node!(_scg, :RLPF, :ar, Arg[NodeRef(_sc_s), ConstArg(800.0), ConstArg(0.3)])
    _scg.output_id = _sc_f
    _sck = enumerate_knobs(_scg)
    _scd = knob_graph_distances(_scg, _sck)
    soft_quartiers(mixed_distances(_scd, KnobSignatures(), _sck))
    descriptors_from_samples(Float32[sin(2π * 110 * i / 44100) for i in 0:1000], 44100)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `julia --project=. test/test_pane_waveform.jl`
Expected: PASS — serialize + export subtests green.

- [ ] **Step 6: Run the full suite**

Run: `just test`
Expected: the whole suite passes (sculpt tests included), no `sclang` invoked, no regression. Then optionally `RESSAC_NRT_TESTS=1 just test-nrt` to exercise the real NRT path.

- [ ] **Step 7: Commit**

```bash
git add src/pane_waveform.jl src/Ressac.jl test/test_pane_waveform.jl
git commit -m "feat(sculpt): persistence, export, precompile workload

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] `just test` is green (fast suite, no sclang).
- [ ] `RESSAC_NRT_TESTS=1 just test-nrt` exercises the real render once (optional, slow).
- [ ] Manual smoke (live session): open the explorer, press `M` on a candidate → a SCULPT pane opens; `j/k` move focus, `h/l` tug, the wave re-renders, `⏎` plays, `e` exports, `s` returns to the plain viewer; `:sculpt metalressone` opens an exported synth in sculpt.
