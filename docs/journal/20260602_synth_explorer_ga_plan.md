# Plan d'implémentation — Explorateur de synths par algorithme génétique interactif

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** un pane Ressac qui fait évoluer des synths SuperCollider par sélection interactive (grille 6/9, favoriser/dévaluer, croisement/mutation), génome = DAG d'UGens typés rendu en SynthDef sécurisé.

**Architecture :** un type `Genome` pur (DAG de nœuds UGen), entouré de modules sans dépendance SC/UI (catalogue, validité, rendu, archétypes, opérateurs, moteur GA) et de deux modules « bords » (audition OSC, pane Tachikoma). Toute la logique difficile est testable sans son ni terminal.

**Tech Stack :** Julia 1.12, module `Ressac`, sous-module `SynthDSL`, TUI Tachikoma, OSC vers SuperCollider/SuperDirt, tests via `Pkg.test()`.

**Spec :** `docs/journal/20260602_synth_explorer_ga_design.md`

---

## Décisions de cadrage du plan

- **Feedback différé.** L'opérateur *feedback* (cycles via délai) exige un rendu à variables nommées + `LocalIn/LocalOut`. Hors périmètre de ce plan ; suivi séparé. Les 5 autres opérateurs structurels + le croisement couvrent la divergence.
- **Rendu inline (arbre).** Le rendu génome→source procède par expansion d'expression (comme le DSL existant). Pas de cycles → la validité interdit les cycles dans ce sous-projet. Un sous-graphe partagé est dupliqué dans la sortie (inoffensif).
- **Contrôles implicites.** `:freq`/`:sustain`/`:gain` ne sont pas des nœuds : ce sont des `ControlRef` utilisables comme arg n'importe où. Le contrat « ils existent » est garanti par le rendu (header de SynthDef fixe), pas par des nœuds.
- **Noms cohérents** (utilisés dans tout le plan) : types `ConstArg`/`NodeRef`/`ControlRef`/`Arg`/`UGenNode`/`Genome`/`SlotSpec`/`UGenSpec` ; catalogue `UGEN_CATALOG`/`register_ugen!`/`ugen_spec` ; render `render_synthdef`/`render_dsl` ; validité `validate`/`repair!` ; opérateurs `mutate`/`crossover` ; GA `Candidate`/`Population`/`next_generation` ; audition `AuditionState` ; pane `SynthExplorerPane`.

## Structure de fichiers

| Fichier | Responsabilité |
|---|---|
| `src/genome.jl` | type `Genome`, `UGenNode`, args, catalogue `UGenSpec`, helpers DAG, sérialisation |
| `src/genome_validity.jl` | `validate` + `repair!` (rates, arités, sortie unique, acyclique) |
| `src/genome_render.jl` | `render_synthdef` (→ source SC sécurisée) + `render_dsl` (→ string `@synth`) |
| `src/genome_archetypes.jl` | graines natives + load/save `plugins/synth-seeds/` |
| `src/genome_operators.jl` | mutations paramétriques + structurelles + croisement |
| `src/ga_engine.jl` | `Candidate`, `Population`, notation, `next_generation` |
| `src/synth_audition.jl` | file de compile bornée, jeu/drone via OSC |
| `src/pane_synth_explorer.jl` | `SynthExplorerPane` (grille, interactions, modal détails, commit) |
| `test/test_genome.jl` … `test/test_synth_explorer_pane.jl` | un fichier de test par module |

**Includes** dans `src/Ressac.jl` : les 6 modules purs (`genome.jl`→`ga_engine.jl`) juste **après** `include("synth_library.jl")` (ligne 41, ils dépendent de `SynthDSL.Sig`/`sc_arg`) ; `synth_audition.jl` et `pane_synth_explorer.jl` entre `pane_tuning.jl` (ligne 53) et `workspace_commands.jl` (ligne 54).

---

Le détail des tâches suit dans des sections séparées (ce plan est écrit en plusieurs passes ; chaque tâche est autonome et complètement codée).

---

### Task 1 : Génome, catalogue UGenSpec, helpers DAG

**Files:**
- Create: `src/genome.jl`
- Test: `test/test_genome.jl`
- Modify: `src/Ressac.jl` (ajouter include) ; `test/runtests.jl` (ajouter include)

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_genome.jl` :

```julia
using Test
using Ressac

@testset "genome — types + catalogue" begin
    @testset "Arg constructors" begin
        @test Ressac.ConstArg(2.0).value == 2.0
        @test Ressac.NodeRef(3).id == 3
        @test Ressac.ControlRef(:freq).name === :freq
    end

    @testset "empty genome has a fresh id counter" begin
        g = Ressac.Genome()
        @test isempty(g.nodes)
        @test g.next_id == 1
    end

    @testset "add_node! returns the id and stores the node" begin
        g = Ressac.Genome()
        id = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        @test id == 1
        @test g.nodes[id].ugen === :Saw
        @test g.nodes[id].rate === :ar
        @test g.next_id == 2
        id2 = Ressac.add_node!(g, :SinOsc, :ar, Ressac.Arg[Ressac.ConstArg(440.0)])
        @test id2 == 2
    end

    @testset "catalogue: builtin UGens are registered" begin
        spec = Ressac.ugen_spec(:Saw)
        @test spec !== nothing
        @test :ar in spec.rates
        @test spec.role === :source
        @test length(spec.slots) >= 1
        @test Ressac.ugen_spec(:NopeNotReal) === nothing
    end

    @testset "catalogue slot has range + default" begin
        rlpf = Ressac.ugen_spec(:RLPF)
        cut = rlpf.slots[2]   # signal in, cutoff, q
        @test cut.name === :freq
        @test cut.lo < cut.hi
    end
end
```

- [ ] **Step 2: Lancer le test → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: ConstArg` (module pas encore inclus).

- [ ] **Step 3: Créer `src/genome.jl`**

```julia
# src/genome.jl
# Genome = DAG d'UGens typés. Type de donnée pur : aucune dépendance
# SC/UI. Les contrôles (:freq/:sustain/:gain) sont des ControlRef
# utilisables comme arg n'importe où — pas des nœuds.

struct ConstArg;   value::Float64;  end
struct NodeRef;    id::Int;         end
struct ControlRef; name::Symbol;    end   # :freq | :sustain | :gain
const Arg = Union{ConstArg, NodeRef, ControlRef}

mutable struct UGenNode
    id::Int
    ugen::Symbol
    rate::Symbol            # :ar | :kr | :ir
    args::Vector{Arg}
end

mutable struct Genome
    nodes::Dict{Int,UGenNode}
    output_id::Int          # 0 = pas encore de sortie
    next_id::Int
end
Genome() = Genome(Dict{Int,UGenNode}(), 0, 1)

const CONTROL_NAMES = (:freq, :sustain, :gain)

function add_node!(g::Genome, ugen::Symbol, rate::Symbol, args::Vector{Arg})
    id = g.next_id
    g.nodes[id] = UGenNode(id, ugen, rate, args)
    g.next_id += 1
    return id
end

node(g::Genome, id::Int) = get(g.nodes, id, nothing)

# ── Catalogue UGenSpec ─────────────────────────────────────────────
# Décrit, pour chaque UGen connu, ses rates et ses slots d'argument.
# C'est ce qui rend la mutation type-safe et le rendu correct.

struct SlotSpec
    name::Symbol
    kind::Symbol        # :signal | :scalar | :choice
    default::Float64
    lo::Float64
    hi::Float64
    choices::Vector{Float64}
end
SlotSpec(name, kind, default, lo, hi) =
    SlotSpec(name, kind, default, lo, hi, Float64[])

struct UGenSpec
    name::Symbol
    rates::Vector{Symbol}
    slots::Vector{SlotSpec}
    role::Symbol        # :source | :filter | :math | :env | :mod
end

const UGEN_CATALOG = Dict{Symbol,UGenSpec}()
register_ugen!(s::UGenSpec) = (UGEN_CATALOG[s.name] = s)
ugen_spec(name::Symbol) = get(UGEN_CATALOG, name, nothing)
catalog_by_role(role::Symbol) =
    [s for s in values(UGEN_CATALOG) if s.role === role]

function _install_builtin_ugens!()
    sig(name, def, lo, hi) = SlotSpec(name, :signal, def, lo, hi)
    sca(name, def, lo, hi) = SlotSpec(name, :scalar, def, lo, hi)
    # sources
    register_ugen!(UGenSpec(:Saw,    [:ar, :kr], [sig(:freq, 220, 20, 8000)], :source))
    register_ugen!(UGenSpec(:SinOsc, [:ar, :kr], [sig(:freq, 220, 20, 8000),
                                                  sca(:phase, 0, 0, 6.283)], :source))
    register_ugen!(UGenSpec(:Pulse,  [:ar, :kr], [sig(:freq, 220, 20, 8000),
                                                  sca(:width, 0.5, 0.01, 0.99)], :source))
    register_ugen!(UGenSpec(:LFTri,  [:ar, :kr], [sig(:freq, 3, 0.01, 40)], :source))
    register_ugen!(UGenSpec(:WhiteNoise, [:ar], SlotSpec[], :source))
    # filters
    register_ugen!(UGenSpec(:RLPF, [:ar], [sig(:in, 0, -1, 1),
                                           sig(:freq, 1200, 40, 12000),
                                           sca(:rq, 0.5, 0.05, 1.5)], :filter))
    register_ugen!(UGenSpec(:LPF,  [:ar], [sig(:in, 0, -1, 1),
                                           sig(:freq, 1200, 40, 12000)], :filter))
    register_ugen!(UGenSpec(:HPF,  [:ar], [sig(:in, 0, -1, 1),
                                           sig(:freq, 400, 40, 12000)], :filter))
    # math / shaping
    register_ugen!(UGenSpec(:MulAdd, [:ar, :kr], [sig(:in, 0, -1, 1),
                                                  sca(:mul, 1, 0, 4),
                                                  sca(:add, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:Tanh,   [:ar, :kr], [sig(:in, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:Mix,    [:ar],      [sig(:a, 0, -1, 1),
                                                  sig(:b, 0, -1, 1)], :math))
    # modulation
    register_ugen!(UGenSpec(:LFNoise1, [:kr], [sig(:freq, 4, 0.05, 30)], :mod))
    register_ugen!(UGenSpec(:SinOscKR, [:kr], [sig(:freq, 4, 0.05, 30)], :mod))
    return nothing
end
_install_builtin_ugens!()
```

- [ ] **Step 4: Inclure le module**

Dans `src/Ressac.jl`, juste après la ligne `include("synth_library.jl")` (ligne 41), ajouter :

```julia
include("genome.jl")                      # GA synth explorer — coeur
```

Dans `test/runtests.jl`, après `include("test_synth_dsl.jl")`, ajouter :

```julia
    include("test_genome.jl")
```

- [ ] **Step 5: Lancer le test → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS, total en hausse.

- [ ] **Step 6: Commit**

```bash
git add src/genome.jl src/Ressac.jl test/test_genome.jl test/runtests.jl
git commit -m "feat(genome): DAG genome type + UGenSpec catalog"
```

---

### Task 2 : Validité + réparation du génome

Garantit qu'un génome (même produit par une mutation brutale) reste rendu-able : rates cohérents, arités complétées, sortie unique présente, acyclique.

**Files:**
- Create: `src/genome_validity.jl`
- Test: `test/test_genome_validity.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_genome_validity.jl` :

```julia
using Test
using Ressac

@testset "genome — validity + repair" begin
    function _saw_genome()
        g = Ressac.Genome()
        id = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        g.output_id = id
        return g
    end

    @testset "a well-formed genome validates clean" begin
        @test isempty(Ressac.validate(_saw_genome()))
    end

    @testset "missing output is reported" begin
        g = _saw_genome(); g.output_id = 0
        @test any(occursin("output", e) for e in Ressac.validate(g))
    end

    @testset "dangling NodeRef is reported" begin
        g = _saw_genome()
        push!(g.nodes[g.output_id].args, Ressac.NodeRef(999))
        @test any(occursin("dangling", e) for e in Ressac.validate(g))
    end

    @testset "repair! drops dangling refs + restores an output" begin
        g = _saw_genome()
        push!(g.nodes[g.output_id].args, Ressac.NodeRef(999))
        g.output_id = 0
        Ressac.repair!(g)
        @test isempty(Ressac.validate(g))
        @test g.output_id != 0
    end

    @testset "repair! pads missing args with slot defaults" begin
        g = Ressac.Genome()
        id = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        g.output_id = id
        Ressac.repair!(g)
        @test length(g.nodes[id].args) == 3          # in, freq, rq
        @test isempty(Ressac.validate(g))
    end

    @testset "repair! breaks a cycle" begin
        g = Ressac.Genome()
        a = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.ControlRef(:freq),
                             Ressac.ConstArg(1200.0), Ressac.ConstArg(0.5)])
        b = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(a),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.5)])
        g.nodes[a].args[1] = Ressac.NodeRef(b)        # a→b→a cycle
        g.output_id = b
        Ressac.repair!(g)
        @test isempty(Ressac.validate(g))
    end
end
```

- [ ] **Step 2: Lancer le test → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: validate`.

- [ ] **Step 3: Créer `src/genome_validity.jl`**

```julia
# src/genome_validity.jl
# validate(g) -> Vector{String} d'erreurs ("" si valide).
# repair!(g)  -> mute g en place pour le rendre valide (la mutation
# mute librement puis on normalise ici — un seul endroit testable).

function _arg_noderef_ids(node::UGenNode)
    [a.id for a in node.args if a isa NodeRef]
end

function validate(g::Genome)::Vector{String}
    errs = String[]
    if g.output_id == 0 || !haskey(g.nodes, g.output_id)
        push!(errs, "no valid output node")
    end
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        if spec === nothing
            push!(errs, "unknown ugen :$(n.ugen) at node $id")
            continue
        end
        if !(n.rate in spec.rates)
            push!(errs, "node $id rate :$(n.rate) not allowed for :$(n.ugen)")
        end
        if length(n.args) != length(spec.slots)
            push!(errs, "node $id arity $(length(n.args)) != $(length(spec.slots))")
        end
        for ref in _arg_noderef_ids(n)
            haskey(g.nodes, ref) || push!(errs, "dangling NodeRef $ref at node $id")
        end
    end
    _has_cycle(g) && push!(errs, "graph has a cycle")
    return errs
end

function _has_cycle(g::Genome)
    state = Dict{Int,Int}()   # 0 unseen, 1 in-stack, 2 done
    function visit(id)
        haskey(g.nodes, id) || return false
        st = get(state, id, 0)
        st == 1 && return true
        st == 2 && return false
        state[id] = 1
        for ref in _arg_noderef_ids(g.nodes[id])
            visit(ref) && return true
        end
        state[id] = 2
        return false
    end
    return any(visit(id) for id in keys(g.nodes))
end

function repair!(g::Genome)
    # 1. drop dangling refs + cycles by rewriting offending args to
    #    a slot-appropriate constant.
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        spec === nothing && continue
        # pad / trim arity to the spec
        while length(n.args) < length(spec.slots)
            slot = spec.slots[length(n.args) + 1]
            push!(n.args, ConstArg(slot.default))
        end
        length(n.args) > length(spec.slots) && resize!(n.args, length(spec.slots))
        # fix illegal rate
        n.rate in spec.rates || (n.rate = spec.rates[1])
        # drop dangling refs
        for i in eachindex(n.args)
            a = n.args[i]
            if a isa NodeRef && !haskey(g.nodes, a.id)
                n.args[i] = ConstArg(spec.slots[i].default)
            end
        end
    end
    # 2. break cycles: re-run detection, cutting the back-edge to a const.
    _break_cycles!(g)
    # 3. ensure an output
    if g.output_id == 0 || !haskey(g.nodes, g.output_id)
        g.output_id = isempty(g.nodes) ?
            add_node!(g, :Saw, :ar, Arg[ControlRef(:freq)]) :
            maximum(keys(g.nodes))
    end
    return g
end

function _break_cycles!(g::Genome)
    while _has_cycle(g)
        state = Dict{Int,Int}()
        cut = false
        function visit(id)
            cut && return
            haskey(g.nodes, id) || return
            state[id] = 1
            n = g.nodes[id]
            for i in eachindex(n.args)
                a = n.args[i]
                a isa NodeRef || continue
                if get(state, a.id, 0) == 1
                    spec = ugen_spec(n.ugen)
                    n.args[i] = ConstArg(spec.slots[i].default)
                    cut = true
                    return
                end
                visit(a.id)
                cut && return
            end
            state[id] = 2
        end
        for id in keys(g.nodes)
            visit(id); cut && break
        end
        cut || break
    end
    return g
end
```

- [ ] **Step 4: Inclure le module**

`src/Ressac.jl` après `include("genome.jl")` : `include("genome_validity.jl")`.
`test/runtests.jl` après `include("test_genome.jl")` : `    include("test_genome_validity.jl")`.

- [ ] **Step 5: Lancer le test → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/genome_validity.jl src/Ressac.jl test/test_genome_validity.jl test/runtests.jl
git commit -m "feat(genome): validate + repair (rates, arity, output, cycles)"
```

---

### Task 3 : Rendu — `render_synthdef` (audition) + `render_dsl` (export)

Deux sorties : (a) une source SynthDef autonome avec l'étage de sécurité, pour l'audition directe (`Out.ar`/`Pan2.ar`, out 0) ; (b) une string `@synth` pour l'export éditeur (laisse `build_synth` ajouter env/gain/routing SuperDirt).

**Files:**
- Create: `src/genome_render.jl`
- Test: `test/test_genome_render.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_genome_render.jl` :

```julia
using Test
using Ressac

@testset "genome — render" begin
    function _filtered()
        g = Ressac.Genome()
        src = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        flt = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(src),
                               Ressac.ConstArg(1200.0), Ressac.ConstArg(0.4)])
        g.output_id = flt
        return g
    end

    @testset "render_synthdef inlines the DAG + names the def" begin
        s = Ressac.render_synthdef(_filtered(), :ga_slot1)
        @test occursin("SynthDef(\\ga_slot1", s)
        @test occursin("RLPF.ar(Saw.ar(freq), 1200.0, 0.4)", s)
        @test endswith(strip(s), ".add;")
    end

    @testset "render_synthdef wraps the safety stage" begin
        s = Ressac.render_synthdef(_filtered(), :ga_slot1)
        @test occursin("Sanitize.ar", s) || occursin("CheckBadValues", s)
        @test occursin("LeakDC.ar", s)
        @test occursin("Limiter.ar", s)
        @test occursin("Out.ar", s)
    end

    @testset "render_synthdef exposes the control header" begin
        s = Ressac.render_synthdef(_filtered(), :ga_slot1)
        @test occursin("freq", s) && occursin("sustain", s) && occursin("gain", s)
    end

    @testset "special math ugens render their operator form" begin
        g = Ressac.Genome()
        src = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        t   = Ressac.add_node!(g, :Tanh, :ar, Ressac.Arg[Ressac.NodeRef(src)])
        g.output_id = t
        s = Ressac.render_synthdef(g, :x)
        @test occursin("(Saw.ar(freq)).tanh", s)
    end

    @testset "render_dsl emits a @synth string a Sig body" begin
        d = Ressac.render_dsl(_filtered(), :myseed)
        @test occursin("@synth :myseed", d)
        @test occursin("Sig(", d)
        @test occursin("RLPF.ar", d)
    end
end
```

- [ ] **Step 2: Lancer le test → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: render_synthdef`.

- [ ] **Step 3: Créer `src/genome_render.jl`**

```julia
# src/genome_render.jl
# render_synthdef : Genome -> source SynthDef autonome (audition).
# render_dsl       : Genome -> string @synth (export éditeur).
# Rendu inline (expansion d'expression) — pas de cycles (validité).

const _RATE_SUFFIX = Dict(:ar => "ar", :kr => "kr", :ir => "ir")

_fmt_const(v::Float64) = isinteger(v) ? string(Int(v)) * ".0" : string(v)

function _emit_arg(g::Genome, a::Arg)
    a isa ConstArg   && return _fmt_const(a.value)
    a isa ControlRef && return String(a.name)
    a isa NodeRef    && return _emit_node(g, a.id)
    return "0"
end

# Special operator-form renderers for math/synonym ugens.
function _emit_special(g::Genome, n::UGenNode)
    A(i) = _emit_arg(g, n.args[i])
    n.ugen === :Tanh     && return "($(A(1))).tanh"
    n.ugen === :MulAdd   && return "(($(A(1)) * $(A(2))) + $(A(3)))"
    n.ugen === :Mix      && return "($(A(1)) + $(A(2)))"
    n.ugen === :SinOscKR && return "SinOsc.kr($(A(1)))"
    return nothing
end

function _emit_node(g::Genome, id::Int)
    n = g.nodes[id]
    sp = _emit_special(g, n)
    sp === nothing || return sp
    suffix = get(_RATE_SUFFIX, n.rate, "ar")
    args = join((_emit_arg(g, a) for a in n.args), ", ")
    return "$(n.ugen).$(suffix)($args)"
end

# Signal expression + safety stage, shared by both renderers.
function _safe_signal_expr(g::Genome)
    body = g.output_id == 0 ? "Silent.ar" : _emit_node(g, g.output_id)
    return "Limiter.ar(LeakDC.ar(Sanitize.ar($body)), 0.95)"
end

function render_synthdef(g::Genome, name::Symbol)
    sig = _safe_signal_expr(g)
    return string(
        "SynthDef(\\", name, ", { |out = 0, pan = 0, ",
        "freq = 220, sustain = 0.5, gain = 0.5|\n",
        "    var sig = ", sig, ";\n",
        "    sig = sig * gain;\n",
        "    sig = sig * EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);\n",
        "    Out.ar(out, Pan2.ar(sig, pan));\n",
        "}).add;\n")
end

function render_dsl(g::Genome, name::Symbol)
    sig = _safe_signal_expr(g)
    # Le corps est un Sig brut SC ; build_synth ajoutera env/gain/DirtPan.
    return string("@synth :", name, " (freq=220, sustain=0.5) ",
                  "SynthDSL.Sig(\"", sig, "\")")
end
```

- [ ] **Step 4: Inclure le module**

`src/Ressac.jl` après `include("genome_validity.jl")` : `include("genome_render.jl")`.
`test/runtests.jl` après `include("test_genome_validity.jl")` : `    include("test_genome_render.jl")`.

- [ ] **Step 5: Lancer le test → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/genome_render.jl src/Ressac.jl test/test_genome_render.jl test/runtests.jl
git commit -m "feat(genome): render to safe SynthDef + to @synth DSL"
```

---

### Task 4 : Sérialisation native + archétypes-graines (`GenomeSource`)

Round-trip génome↔Dict (graines re-mutables sans parser A2), une biblio de graines natives, et load/save de `plugins/synth-seeds/*.json`. C'est le `GenomeSource` ; un futur parser DSL→DAG (A2) sera juste une autre source.

**Files:**
- Create: `src/genome_archetypes.jl`
- Test: `test/test_genome_archetypes.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_genome_archetypes.jl` :

```julia
using Test
using Ressac

@testset "genome — serialization + archetypes" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(900.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        return g
    end

    @testset "serialize → dict → deserialize round-trips" begin
        g = _g()
        d = Ressac.serialize_genome(g)
        @test d isa AbstractDict
        g2 = Ressac.deserialize_genome(d)
        @test g2.output_id == g.output_id
        @test Ressac.render_synthdef(g2, :x) == Ressac.render_synthdef(g, :x)
    end

    @testset "builtin archetypes exist and are valid + audible" begin
        names = Ressac.archetype_names()
        @test :drone_grave in names
        @test :pluck in names
        for nm in names
            g = Ressac.archetype(nm)
            @test isempty(Ressac.validate(g))
        end
    end

    @testset "save_seed writes JSON, load_seeds reads it back" begin
        mktempdir() do dir
            g = _g()
            Ressac.save_seed("mytest", g; dir = dir)
            @test isfile(joinpath(dir, "mytest.json"))
            loaded = Ressac.load_seeds(dir)
            @test haskey(loaded, :mytest)
            @test Ressac.render_synthdef(loaded[:mytest], :x) ==
                  Ressac.render_synthdef(g, :x)
        end
    end

    @testset "all_seeds merges builtins + user dir" begin
        mktempdir() do dir
            Ressac.save_seed("custom1", Ressac.archetype(:pluck); dir = dir)
            merged = Ressac.all_seeds(dir)
            @test haskey(merged, :drone_grave)   # builtin
            @test haskey(merged, :custom1)        # user
        end
    end
end
```

- [ ] **Step 2: Lancer le test → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: serialize_genome`.

- [ ] **Step 3: Créer `src/genome_archetypes.jl`**

```julia
# src/genome_archetypes.jl
# Sérialisation native (round-trip pour les graines, sans parser A2)
# + biblio d'archétypes natifs + load/save plugins/synth-seeds/.

import JSON

function _ser_arg(a::Arg)
    a isa ConstArg   && return Dict("t" => "const", "v" => a.value)
    a isa NodeRef    && return Dict("t" => "node",  "id" => a.id)
    return Dict("t" => "ctrl", "name" => String(a.name))   # ControlRef
end

function _deser_arg(d::AbstractDict)::Arg
    t = d["t"]
    t == "const" && return ConstArg(Float64(d["v"]))
    t == "node"  && return NodeRef(Int(d["id"]))
    return ControlRef(Symbol(d["name"]))
end

function serialize_genome(g::Genome)
    nodes = [Dict("id" => n.id, "ugen" => String(n.ugen),
                  "rate" => String(n.rate),
                  "args" => [_ser_arg(a) for a in n.args])
             for n in values(g.nodes)]
    return Dict("nodes" => nodes, "output" => g.output_id,
                "next_id" => g.next_id)
end

function deserialize_genome(d::AbstractDict)
    g = Genome()
    for nd in d["nodes"]
        id = Int(nd["id"])
        g.nodes[id] = UGenNode(id, Symbol(nd["ugen"]), Symbol(nd["rate"]),
                               Arg[_deser_arg(a) for a in nd["args"]])
    end
    g.output_id = Int(d["output"])
    g.next_id = Int(get(d, "next_id", maximum(keys(g.nodes); init = 0) + 1))
    return g
end

# ── Archétypes natifs ──────────────────────────────────────────────
const _ARCHETYPES = Dict{Symbol,Function}()

function _arch_drone_grave()
    g = Genome()
    osc = add_node!(g, :Saw, :ar, Arg[ControlRef(:freq)])
    flt = add_node!(g, :RLPF, :ar, Arg[NodeRef(osc), ConstArg(400.0), ConstArg(0.3)])
    g.output_id = flt
    return g
end

function _arch_pluck()
    g = Genome()
    osc = add_node!(g, :Pulse, :ar, Arg[ControlRef(:freq), ConstArg(0.5)])
    drv = add_node!(g, :Tanh, :ar, Arg[NodeRef(osc)])
    g.output_id = drv
    return g
end

function _arch_fm_bell()
    g = Genome()
    modu = add_node!(g, :SinOsc, :ar, Arg[ControlRef(:freq), ConstArg(0.0)])
    car  = add_node!(g, :SinOsc, :ar, Arg[NodeRef(modu), ConstArg(0.0)])
    g.output_id = car
    return g
end

function _arch_noise_perc()
    g = Genome()
    nz  = add_node!(g, :WhiteNoise, :ar, Arg[])
    flt = add_node!(g, :HPF, :ar, Arg[NodeRef(nz), ConstArg(2000.0)])
    g.output_id = flt
    return g
end

_ARCHETYPES[:drone_grave] = _arch_drone_grave
_ARCHETYPES[:pluck]       = _arch_pluck
_ARCHETYPES[:fm_bell]     = _arch_fm_bell
_ARCHETYPES[:noise_perc]  = _arch_noise_perc

archetype_names() = sort!(collect(keys(_ARCHETYPES)))
archetype(name::Symbol) = _ARCHETYPES[name]()

# ── Persistance disque ─────────────────────────────────────────────
seed_dir() = joinpath(pwd(), "plugins", "synth-seeds")

function save_seed(name::AbstractString, g::Genome; dir = seed_dir())
    isdir(dir) || mkpath(dir)
    path = joinpath(dir, "$name.json")
    open(path, "w") do io
        JSON.print(io, serialize_genome(g))
    end
    return path
end

function load_seeds(dir = seed_dir())
    out = Dict{Symbol,Genome}()
    isdir(dir) || return out
    for f in readdir(dir)
        endswith(f, ".json") || continue
        nm = Symbol(splitext(f)[1])
        try
            d = JSON.parsefile(joinpath(dir, f))
            out[nm] = deserialize_genome(d)
        catch
        end
    end
    return out
end

function all_seeds(dir = seed_dir())
    merged = Dict{Symbol,Genome}()
    for nm in archetype_names()
        merged[nm] = archetype(nm)
    end
    for (nm, g) in load_seeds(dir)     # user overrides win
        merged[nm] = g
    end
    return merged
end
```

- [ ] **Step 4: Vérifier que JSON est une dépendance**

Run: `julia --project=. -e 'import JSON; println("ok")'`
Expected: `ok`. Si erreur `ArgumentError: Package JSON not found`, l'ajouter :
`julia --project=. -e 'using Pkg; Pkg.add("JSON")'` puis vérifier que `JSON` apparaît dans `Project.toml` `[deps]`.

- [ ] **Step 5: Inclure le module**

`src/Ressac.jl` après `include("genome_render.jl")` : `include("genome_archetypes.jl")`.
`test/runtests.jl` après `include("test_genome_render.jl")` : `    include("test_genome_archetypes.jl")`.

- [ ] **Step 6: Lancer le test → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/genome_archetypes.jl src/Ressac.jl test/test_genome_archetypes.jl test/runtests.jl Project.toml
git commit -m "feat(genome): native serialization + seed archetypes + disk persistence"
```

---

### Task 5 : Opérateurs paramétriques + bouton de divergence

Mutations qui ne touchent pas la topologie : perturber une constante, basculer un choix, changer le rate. RNG injectée pour des tests déterministes. Toujours suivi de `repair!`.

**Files:**
- Create: `src/genome_operators.jl`
- Test: `test/test_genome_operators.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_genome_operators.jl` :

```julia
using Test
using Ressac
using Random

@testset "genome — parametric operators" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(1000.0), Ressac.ConstArg(0.5)])
        g.output_id = f
        return g
    end

    @testset "op_perturb_const moves a constant within slot range" begin
        rng = MersenneTwister(42)
        g = _g()
        before = g.nodes[2].args[2].value     # cutoff = 1000
        Ressac.op_perturb_const!(g, rng; radius = 1.0)
        # toujours valide après
        @test isempty(Ressac.validate(g))
        rlpf = Ressac.ugen_spec(:RLPF)
        cut = rlpf.slots[2]
        for (id, n) in g.nodes, (i, a) in enumerate(n.args)
            a isa Ressac.ConstArg || continue
            sp = Ressac.ugen_spec(n.ugen).slots[i]
            @test sp.lo <= a.value <= sp.hi
        end
    end

    @testset "op_change_rate keeps the rate legal" begin
        rng = MersenneTwister(7)
        g = _g()
        Ressac.op_change_rate!(g, rng)
        @test isempty(Ressac.validate(g))
    end

    @testset "mutate is deterministic under a fixed seed" begin
        a = Ressac.mutate(_g(), MersenneTwister(99); radius = 0.5)
        b = Ressac.mutate(_g(), MersenneTwister(99); radius = 0.5)
        @test Ressac.render_synthdef(a, :x) == Ressac.render_synthdef(b, :x)
    end

    @testset "mutate always yields a valid genome" begin
        rng = MersenneTwister(1)
        for _ in 1:50
            g = Ressac.mutate(_g(), rng; radius = rand(rng))
            @test isempty(Ressac.validate(g))
        end
    end

    @testset "low radius keeps structure (node count stable)" begin
        rng = MersenneTwister(3)
        g = Ressac.mutate(_g(), rng; radius = 0.0)
        @test length(g.nodes) == 2     # radius 0 = paramétrique seul
    end
end
```

- [ ] **Step 2: Lancer le test → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: op_perturb_const!`.

- [ ] **Step 3: Créer `src/genome_operators.jl` (partie paramétrique)**

```julia
# src/genome_operators.jl
# Opérateurs = fonctions (Genome[, rng]) -> mutent en place, puis repair!.
# Paramétrique (ce fichier, étape 1) + structurel/croisement (étape 2,
# Task 6 ajoute à ce même fichier).
using Random

_copy_genome(g::Genome) = deserialize_genome(serialize_genome(g))

function _const_slots(g::Genome)
    out = Tuple{Int,Int}[]   # (node_id, arg_index)
    for (id, n) in g.nodes
        for (i, a) in enumerate(n.args)
            a isa ConstArg && push!(out, (id, i))
        end
    end
    return out
end

function op_perturb_const!(g::Genome, rng::AbstractRNG; radius::Float64 = 0.5)
    slots = _const_slots(g)
    isempty(slots) && return g
    (nid, i) = rand(rng, slots)
    n = g.nodes[nid]
    spec = ugen_spec(n.ugen)
    sp = spec.slots[i]
    span = sp.hi - sp.lo
    cur = n.args[i].value
    new = cur + randn(rng) * span * 0.25 * radius
    n.args[i] = ConstArg(clamp(new, sp.lo, sp.hi))
    return g
end

function op_change_rate!(g::Genome, rng::AbstractRNG)
    ids = collect(keys(g.nodes))
    isempty(ids) && return g
    nid = rand(rng, ids)
    n = g.nodes[nid]
    spec = ugen_spec(n.ugen)
    length(spec.rates) > 1 && (n.rate = rand(rng, spec.rates))
    return g
end

# Mutation = applique 1..k opérateurs selon le rayon, puis répare.
# radius 0 → uniquement paramétrique (1 perturbation).
# radius>0 → mélange paramétrique + structurel (Task 6 enrichit _STRUCT_OPS).
const _PARAM_OPS = Function[op_perturb_const!, op_change_rate!]
const _STRUCT_OPS = Function[]   # rempli en Task 6

function mutate(g0::Genome, rng::AbstractRNG; radius::Float64 = 0.5)
    g = _copy_genome(g0)
    n_ops = 1 + floor(Int, radius * 3)
    for _ in 1:n_ops
        use_struct = !isempty(_STRUCT_OPS) && rand(rng) < radius
        op = rand(rng, use_struct ? _STRUCT_OPS : _PARAM_OPS)
        op(g, rng)
    end
    repair!(g)
    return g
end
```

Note : `op_perturb_const!`/`op_change_rate!` ont des arités différentes (l'un prend `radius`). Pour que `mutate` les appelle uniformément, on les enveloppe : remplacer la dernière ligne de boucle par un dispatch tolérant. Implémentation exacte de la boucle :

```julia
    for _ in 1:n_ops
        use_struct = !isempty(_STRUCT_OPS) && rand(rng) < radius
        op = rand(rng, use_struct ? _STRUCT_OPS : _PARAM_OPS)
        if op === op_perturb_const!
            op(g, rng; radius = radius)
        else
            op(g, rng)
        end
    end
```

- [ ] **Step 4: Inclure le module**

`src/Ressac.jl` après `include("genome_archetypes.jl")` : `include("genome_operators.jl")`.
`test/runtests.jl` après `include("test_genome_archetypes.jl")` : `    include("test_genome_operators.jl")`.

- [ ] **Step 5: Lancer le test → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/genome_operators.jl src/Ressac.jl test/test_genome_operators.jl test/runtests.jl
git commit -m "feat(genome): parametric mutation operators + divergence radius"
```

---

### Task 6 : Opérateurs structurels + croisement

Insérer/retirer/swap/recâbler/greffer-modulation, et croisement par swap de sous-graphe. Ajoutés au même fichier ; poussés dans `_STRUCT_OPS` pour que `mutate` les tire selon le rayon.

**Files:**
- Modify: `src/genome_operators.jl` (append)
- Test: `test/test_genome_operators.jl` (append un nouveau `@testset`)

- [ ] **Step 1: Ajouter les tests qui échouent**

Append à `test/test_genome_operators.jl` :

```julia
@testset "genome — structural operators + crossover" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(1000.0), Ressac.ConstArg(0.5)])
        g.output_id = f
        return g
    end

    @testset "op_insert_node! grows the graph and stays valid" begin
        rng = MersenneTwister(11)
        g = _g(); n0 = length(g.nodes)
        Ressac.op_insert_node!(g, rng)
        @test length(g.nodes) == n0 + 1
        @test isempty(Ressac.validate(g))
    end

    @testset "op_remove_node! shrinks or no-ops, always valid" begin
        rng = MersenneTwister(12)
        g = _g()
        Ressac.op_remove_node!(g, rng)
        @test isempty(Ressac.validate(g))
        @test length(g.nodes) >= 1
    end

    @testset "op_swap_ugen! keeps it valid" begin
        rng = MersenneTwister(13)
        g = _g()
        Ressac.op_swap_ugen!(g, rng)
        @test isempty(Ressac.validate(g))
    end

    @testset "op_rewire! keeps it valid (acyclic after repair)" begin
        rng = MersenneTwister(14)
        g = _g()
        Ressac.op_rewire!(g, rng)
        @test isempty(Ressac.validate(g))
    end

    @testset "op_graft_mod! keeps it valid" begin
        rng = MersenneTwister(15)
        g = _g()
        Ressac.op_graft_mod!(g, rng)
        @test isempty(Ressac.validate(g))
    end

    @testset "crossover yields a valid child blending both" begin
        rng = MersenneTwister(16)
        a = _g()
        b = Ressac.archetype(:fm_bell)
        child = Ressac.crossover(a, b, rng)
        @test isempty(Ressac.validate(child))
    end

    @testset "high-radius mutate can change structure" begin
        rng = MersenneTwister(123)
        changed = false
        for _ in 1:30
            g = Ressac.mutate(_g(), rng; radius = 1.0)
            length(g.nodes) != 2 && (changed = true)
        end
        @test changed
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: op_insert_node!`.

- [ ] **Step 3: Append à `src/genome_operators.jl`**

```julia
# ── Opérateurs structurels ─────────────────────────────────────────

function _signal_slot_edges(g::Genome)
    # (node_id, arg_index) où le slot est :signal.
    out = Tuple{Int,Int}[]
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        spec === nothing && continue
        for (i, sp) in enumerate(spec.slots)
            sp.kind === :signal && i <= length(n.args) && push!(out, (id, i))
        end
    end
    return out
end

function _new_node_from_spec!(g::Genome, spec::UGenSpec, first_input::Arg)
    args = Arg[]
    for (i, sp) in enumerate(spec.slots)
        push!(args, (i == 1 && sp.kind === :signal) ? first_input :
                    ConstArg(sp.default))
    end
    return add_node!(g, spec.name, spec.rates[1], args)
end

function op_insert_node!(g::Genome, rng::AbstractRNG)
    edges = _signal_slot_edges(g)
    isempty(edges) && return g
    (nid, i) = rand(rng, edges)
    cands = vcat(catalog_by_role(:filter), catalog_by_role(:math))
    isempty(cands) && return g
    spec = rand(rng, cands)
    cur = g.nodes[nid].args[i]
    new_id = _new_node_from_spec!(g, spec, cur)
    g.nodes[nid].args[i] = NodeRef(new_id)
    return g
end

function op_remove_node!(g::Genome, rng::AbstractRNG)
    length(g.nodes) <= 1 && return g
    nid = rand(rng, collect(keys(g.nodes)))
    n = g.nodes[nid]
    # le bypass = premier arg signal du nœud (ou un const par défaut)
    spec = ugen_spec(n.ugen)
    bypass = ConstArg(0.0)
    for (i, sp) in enumerate(spec.slots)
        if sp.kind === :signal && i <= length(n.args)
            bypass = n.args[i]; break
        end
    end
    delete!(g.nodes, nid)
    for other in values(g.nodes), j in eachindex(other.args)
        other.args[j] isa NodeRef && other.args[j].id == nid &&
            (other.args[j] = bypass)
    end
    g.output_id == nid &&
        (g.output_id = bypass isa NodeRef ? bypass.id : 0)
    return g
end

function op_swap_ugen!(g::Genome, rng::AbstractRNG)
    isempty(g.nodes) && return g
    nid = rand(rng, collect(keys(g.nodes)))
    n = g.nodes[nid]
    role = ugen_spec(n.ugen).role
    cands = [s for s in catalog_by_role(role) if s.name !== n.ugen]
    isempty(cands) && return g
    spec = rand(rng, cands)
    n.ugen = spec.name
    n.rate in spec.rates || (n.rate = spec.rates[1])
    return g   # repair! ajuste l'arité
end

function op_rewire!(g::Genome, rng::AbstractRNG)
    edges = _signal_slot_edges(g)
    ids = collect(keys(g.nodes))
    (isempty(edges) || isempty(ids)) && return g
    (nid, i) = rand(rng, edges)
    g.nodes[nid].args[i] = NodeRef(rand(rng, ids))
    return g   # repair! casse un éventuel cycle
end

function op_graft_mod!(g::Genome, rng::AbstractRNG)
    # remplace une constante scalaire par un nœud de modulation.
    slots = _const_slots(g)
    isempty(slots) && return g
    (nid, i) = rand(rng, slots)
    mods = catalog_by_role(:mod)
    isempty(mods) && return g
    spec = rand(rng, mods)
    mod_id = _new_node_from_spec!(g, spec, ConstArg(spec.slots[1].default))
    g.nodes[nid].args[i] = NodeRef(mod_id)
    return g
end

append!(_STRUCT_OPS, Function[op_insert_node!, op_remove_node!,
                              op_swap_ugen!, op_rewire!, op_graft_mod!])

# ── Croisement (swap de sous-graphe) ───────────────────────────────

function _subtree_ids(g::Genome, root::Int, acc = Set{Int}())
    (root in acc || !haskey(g.nodes, root)) && return acc
    push!(acc, root)
    for a in g.nodes[root].args
        a isa NodeRef && _subtree_ids(g, a.id, acc)
    end
    return acc
end

function crossover(a0::Genome, b0::Genome, rng::AbstractRNG)
    child = _copy_genome(b0)
    isempty(a0.nodes) && (repair!(child); return child)
    donor_root = rand(rng, collect(keys(a0.nodes)))
    ids = collect(_subtree_ids(a0, donor_root))
    # remap donor ids -> nouveaux ids dans child
    remap = Dict{Int,Int}()
    for old in ids
        remap[old] = child.next_id
        child.next_id += 1
    end
    for old in ids
        dn = a0.nodes[old]
        newargs = Arg[]
        for arg in dn.args
            push!(newargs, arg isa NodeRef && haskey(remap, arg.id) ?
                           NodeRef(remap[arg.id]) : arg)
        end
        child.nodes[remap[old]] = UGenNode(remap[old], dn.ugen, dn.rate, newargs)
    end
    # greffer la racine du donneur sur une edge signal de child
    edges = _signal_slot_edges(child)
    if !isempty(edges)
        (nid, i) = rand(rng, edges)
        child.nodes[nid].args[i] = NodeRef(remap[donor_root])
    end
    repair!(child)
    return child
end
```

- [ ] **Step 4: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/genome_operators.jl test/test_genome_operators.jl
git commit -m "feat(genome): structural mutation operators + subgraph crossover"
```

---

### Task 7 : Moteur GA — Population, notation, génération suivante

`Population` = candidats + poids (favoriser/dévaluer), un numéro de génération, le rayon courant, et la graine de base. `next_generation` applique élitisme + croisement + mutation. Poids stockés (pas un set de parents) → prêt pour le modèle (3).

**Files:**
- Create: `src/ga_engine.jl`
- Test: `test/test_ga_engine.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_ga_engine.jl` :

```julia
using Test
using Ressac
using Random

@testset "ga_engine" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "init_population fills N valid candidates" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(1); radius = 0.5)
        @test length(pop.candidates) == 9
        @test pop.generation == 0
        for c in pop.candidates
            @test isempty(Ressac.validate(c.genome))
            @test c.weight == 0.0
        end
    end

    @testset "favor!/devalue! write weights" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(2); radius = 0.5)
        Ressac.favor!(pop, 1)
        Ressac.devalue!(pop, 2)
        @test pop.candidates[1].weight > 0
        @test pop.candidates[2].weight < 0
        Ressac.favor!(pop, 1)              # re-presser annule
        @test pop.candidates[1].weight == 0.0
    end

    @testset "next_generation preserves a favored elite genome" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(3); radius = 0.5)
        Ressac.favor!(pop, 4)
        elite_src = Ressac.render_synthdef(pop.candidates[4].genome, :x)
        Ressac.next_generation!(pop, MersenneTwister(3))
        @test pop.generation == 1
        @test length(pop.candidates) == 9
        srcs = [Ressac.render_synthdef(c.genome, :x) for c in pop.candidates]
        @test elite_src in srcs                  # élitisme
        @test all(c -> c.weight == 0.0, pop.candidates)   # notes réinitialisées
    end

    @testset "mono-favori = divergence (all children valid)" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(4); radius = 0.3)
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(4))
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
    end

    @testset "no favorites → regenerate from base, still valid" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(5); radius = 0.5)
        Ressac.next_generation!(pop, MersenneTwister(5))
        @test pop.generation == 1
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
    end

    @testset "next_generation! is deterministic under fixed seed" begin
        p1 = Ressac.init_population(base(), 6, MersenneTwister(6); radius = 0.5)
        p2 = Ressac.init_population(base(), 6, MersenneTwister(6); radius = 0.5)
        Ressac.favor!(p1, 1); Ressac.favor!(p2, 1)
        Ressac.next_generation!(p1, MersenneTwister(77))
        Ressac.next_generation!(p2, MersenneTwister(77))
        s1 = [Ressac.render_synthdef(c.genome, :x) for c in p1.candidates]
        s2 = [Ressac.render_synthdef(c.genome, :x) for c in p2.candidates]
        @test s1 == s2
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: init_population`.

- [ ] **Step 3: Créer `src/ga_engine.jl`**

```julia
# src/ga_engine.jl
# Population de candidats + poids (favoriser/dévaluer). select→next_gen
# en mode breeding pool (modèle 2). Les poids vivent à travers les
# générations → brancher le modèle (3) ne changerait que next_generation!.
using Random

mutable struct Candidate
    genome::Genome
    weight::Float64        # >0 favori, <0 dévalué, 0 neutre
end

mutable struct Population
    candidates::Vector{Candidate}
    base::Genome           # graine de repli quand aucun favori
    generation::Int
    radius::Float64
end

function init_population(base::Genome, n::Int, rng::AbstractRNG;
                         radius::Float64 = 0.5)
    cands = [Candidate(mutate(base, rng; radius = radius), 0.0) for _ in 1:n]
    return Population(cands, _copy_genome(base), 0, radius)
end

function _toggle_weight!(pop::Population, i::Int, val::Float64)
    1 <= i <= length(pop.candidates) || return
    c = pop.candidates[i]
    c.weight = (c.weight == val) ? 0.0 : val
    return
end
favor!(pop::Population, i::Int)   = _toggle_weight!(pop, i, 1.0)
devalue!(pop::Population, i::Int) = _toggle_weight!(pop, i, -1.0)

function next_generation!(pop::Population, rng::AbstractRNG)
    n = length(pop.candidates)
    favored = [c for c in pop.candidates if c.weight > 0]
    sort!(favored; by = c -> -c.weight)
    parents = isempty(favored) ? [Candidate(pop.base, 0.0)] : favored
    out = Candidate[]
    # élitisme : 1 favori conservé tel quel (si présent)
    isempty(favored) || push!(out, Candidate(_copy_genome(favored[1].genome), 0.0))
    while length(out) < n
        if length(parents) >= 2 && rand(rng) < 0.5
            a = rand(rng, parents).genome
            b = rand(rng, parents).genome
            child = crossover(a, b, rng)
        else
            child = mutate(rand(rng, parents).genome, rng; radius = pop.radius)
        end
        push!(out, Candidate(child, 0.0))
    end
    pop.candidates = out[1:n]
    pop.generation += 1
    return pop
end

# regénère sans avancer la sélection (bouton R) : re-mute la base.
function reshuffle!(pop::Population, rng::AbstractRNG)
    n = length(pop.candidates)
    pop.candidates = [Candidate(mutate(pop.base, rng; radius = pop.radius), 0.0)
                      for _ in 1:n]
    return pop
end
```

- [ ] **Step 4: Inclure le module**

`src/Ressac.jl` après `include("genome_operators.jl")` : `include("ga_engine.jl")`.
`test/runtests.jl` après `include("test_genome_operators.jl")` : `    include("test_ga_engine.jl")`.

- [ ] **Step 5: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ga_engine.jl src/Ressac.jl test/test_ga_engine.jl test/runtests.jl
git commit -m "feat(ga): population, favor/devalue weights, breeding-pool next_generation"
```

---

### Task 8 : Harnais d'audition (OSC, noms bornés, jeu/drone)

File de compile bornée à N noms `ga_slotN`, jeu via `/ressac/evalAndPlay` (1er jeu, définit+joue) puis `/ressac/play` (instantané), drone via un nom dédié `ga_held`. Logique de décision testée en pur ; envoi OSC testé avec un mock.

**Files:**
- Create: `src/synth_audition.jl`
- Test: `test/test_synth_audition.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_synth_audition.jl` :

```julia
using Test
using Ressac

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

@testset "synth_audition" begin
    base() = Ressac.archetype(:pluck)

    @testset "state has a bounded slot-name pool" begin
        st = Ressac.AuditionState(9)
        @test length(st.slot_names) == 9
        @test st.slot_names[1] === Symbol("ga_slot1")
        @test all(!, st.played_once)
    end

    @testset "play address: first = evalAndPlay, then play" begin
        st = Ressac.AuditionState(9)
        @test Ressac._audition_play_address(st, 3) === :evalAndPlay
        st.played_once[3] = true
        @test Ressac._audition_play_address(st, 3) === :play
    end

    @testset "enqueue_generation! defines every candidate (N msgs)" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        genomes = [base(), base(), base()]
        Ressac.enqueue_generation!(st, osc, genomes)
        @test length(osc.sent) == 3
        @test all(!, st.played_once)         # nouvelle génération = rejouable
    end

    @testset "audition_play! sends one message + flips played_once" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        Ressac.audition_play!(st, osc, 2, base(), 220.0, 0.5)
        @test length(osc.sent) == 1
        @test st.played_once[2]
        Ressac.audition_play!(st, osc, 2, base(), 330.0, 0.5)
        @test length(osc.sent) == 2          # 2e jeu via /ressac/play
    end

    @testset "hold promotes to ga_held, stop clears it" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        Ressac.audition_hold!(st, osc, base(), 110.0, 8.0)
        @test st.held_active
        Ressac.audition_stop!(st, osc)
        @test !st.held_active
    end

    @testset "regenerating reuses the same 9 names (no leak)" begin
        st = Ressac.AuditionState(9)
        osc = MockOSCClient()
        for _ in 1:5
            Ressac.enqueue_generation!(st, osc, [base() for _ in 1:9])
        end
        @test length(st.slot_names) == 9
        @test length(unique(st.slot_names)) == 9
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: AuditionState`.

- [ ] **Step 3: Créer `src/synth_audition.jl`**

```julia
# src/synth_audition.jl
# Audition des candidats : noms SynthDef bornés (ga_slot1..N + ga_held),
# define en background via /dirt/evalSC, jeu via /ressac/evalAndPlay
# (1er, définit+joue) puis /ressac/play (instantané). L'OSC client est
# passé explicitement → testable avec un mock.

mutable struct AuditionState
    slot_names::Vector{Symbol}
    ready::Vector{Bool}
    played_once::Vector{Bool}
    held_active::Bool
end

function AuditionState(n::Int)
    names = [Symbol("ga_slot$i") for i in 1:n]
    return AuditionState(names, falses(n), falses(n), false)
end

const _GA_HELD_NAME = :ga_held

_audition_play_address(st::AuditionState, slot::Int) =
    st.played_once[slot] ? :play : :evalAndPlay

function _send(osc, address::AbstractString, args::Vector)
    send_osc(osc, encode(OSCMessage(address, args)))
end

# Définit (sans jouer) tous les candidats de la génération. Réinitialise
# played_once → tout est rejouable. Borne : on réécrit les MÊMES noms.
function enqueue_generation!(st::AuditionState, osc, genomes::Vector{Genome})
    n = min(length(genomes), length(st.slot_names))
    for i in 1:n
        src = render_synthdef(genomes[i], st.slot_names[i])
        _send(osc, "/dirt/evalSC", Any[src])
        st.ready[i] = true
        st.played_once[i] = false
    end
    return st
end

function audition_play!(st::AuditionState, osc, slot::Int, g::Genome,
                        freq::Float64, sustain::Float64)
    1 <= slot <= length(st.slot_names) || return st
    name = st.slot_names[slot]
    if _audition_play_address(st, slot) === :evalAndPlay
        src = render_synthdef(g, name)
        _send(osc, "/ressac/evalAndPlay", Any[String(name), src])
        st.played_once[slot] = true
    else
        _send(osc, "/ressac/play",
              Any[String(name), "freq", freq, "sustain", sustain])
    end
    return st
end

function audition_hold!(st::AuditionState, osc, g::Genome,
                        freq::Float64, sustain::Float64)
    src = render_synthdef(g, _GA_HELD_NAME)
    _send(osc, "/ressac/evalAndPlay", Any[String(_GA_HELD_NAME), src])
    st.held_active = true
    return st
end

function audition_stop!(st::AuditionState, osc)
    _send(osc, "/ressac/free", Any[String(_GA_HELD_NAME)])
    st.held_active = false
    return st
end
```

- [ ] **Step 4: Inclure le module**

`src/Ressac.jl` entre `include("pane_tuning.jl")` (ligne 53) et `include("workspace_commands.jl")` (ligne 54) : `include("synth_audition.jl")`.
`test/runtests.jl` après `include("test_ga_engine.jl")` : `    include("test_synth_audition.jl")`.

- [ ] **Step 5: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/synth_audition.jl src/Ressac.jl test/test_synth_audition.jl test/runtests.jl
git commit -m "feat(audition): bounded SynthDef pool, evalAndPlay/play, drone hold"
```

---

### Task 9 : Pane `SynthExplorerPane` — squelette + rendu grille

Le `PaneImpl` : struct, ctor (graine → population), `register_pane_kind!(:explorer, …)`, `render!` (grille 3×3 avec résumé structurel + marqueurs), `title`, `serialize` (Task 13 complète la reprise).

**Files:**
- Create: `src/pane_synth_explorer.jl`
- Test: `test/test_synth_explorer_pane.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Écrire le test qui échoue**

Créer `test/test_synth_explorer_pane.jl` :

```julia
using Test
using Ressac
import Tachikoma

@testset "synth explorer pane — render" begin
    @testset "ctor builds a 9-candidate population from a seed" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 42))
        @test p isa Ressac.SynthExplorerPane
        @test length(p.pop.candidates) == 9
        @test p.focus == 1
    end

    @testset "title mentions the explorer + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 1))
        @test occursin("explorer", lowercase(Ressac.title(p)))
    end

    @testset "render! draws the header + a structural summary" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 5))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        top = Tachikoma.row_text(tb, 1)
        @test occursin("EXPLORER", uppercase(top))
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("gén", whole) || occursin("gen", whole)
    end

    @testset "genome_summary names dominant ugens" begin
        g = Ressac.archetype(:drone_grave)
        s = Ressac._genome_summary(g)
        @test occursin("Saw", s) || occursin("RLPF", s)
    end

    @testset "serialize captures seed + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 9))
        d = Ressac.serialize(p)
        @test d["kind_seed"] == "pluck"
        @test haskey(d, "generation")
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `UndefVarError: SynthExplorerPane`.

- [ ] **Step 3: Créer `src/pane_synth_explorer.jl`**

```julia
# src/pane_synth_explorer.jl
# PaneImpl :explorer — exploration de synths par GA interactif.
# Orchestre ga_engine + synth_audition + genome_render ; ne contient
# aucune logique GA/génome propre.
using Random

const _GA_GEN_SIZE = 9
const _GA_GRID_COLS = 3

mutable struct SynthExplorerPane <: PaneImpl
    pop::Population
    audition::AuditionState
    focus::Int
    radius::Float64
    rng::MersenneTwister
    keyboard_mode::Bool
    seed_name::Symbol
end

function _synth_explorer_pane_ctor(args::AbstractDict)
    seed = Symbol(String(get(args, "seed", "drone_grave")))
    seeds = all_seeds()
    base = haskey(seeds, seed) ? seeds[seed] : archetype(:drone_grave)
    rng = MersenneTwister(Int(get(args, "rng", rand(UInt32))))
    radius = Float64(get(args, "radius", 0.5))
    pop = init_population(base, _GA_GEN_SIZE, rng; radius = radius)
    aud = AuditionState(_GA_GEN_SIZE)
    return SynthExplorerPane(pop, aud, 1, radius, rng, false, seed)
end

# Résumé structurel court : UGens distincts + nb de nœuds.
function _genome_summary(g::Genome)
    isempty(g.nodes) && return "(vide)"
    names = unique(String(n.ugen) for n in values(g.nodes))
    return string(join(first(names, 3), "→"), " (", length(g.nodes), ")")
end

function title(p::SynthExplorerPane)
    return "explorer:$(p.seed_name) g$(p.pop.generation)"
end

function render!(p::SynthExplorerPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    bar = repeat("█", clamp(round(Int, p.radius * 5), 0, 5))
    header = "SYNTH EXPLORER · gén $(p.pop.generation) · div $(rpad(bar, 5, '░'))"
    _render_pane_block_simple!(rect, header, buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 12 || inner.height < 6) && return
    cols = _GA_GRID_COLS
    rows = cld(length(p.pop.candidates), cols)
    cell_w = inner.width ÷ cols
    cell_h = max(2, (inner.height - 2) ÷ rows)
    for (idx, c) in enumerate(p.pop.candidates)
        col = (idx - 1) % cols
        row = (idx - 1) ÷ cols
        cx = inner.x + col * cell_w
        cy = inner.y + row * cell_h
        mark = c.weight > 0 ? "♥" : c.weight < 0 ? "✗" : " "
        focus = idx == p.focus ? "▸" : " "
        style = idx == p.focus ? TK.tstyle(:accent, bold = true) :
                c.weight > 0 ? TK.tstyle(:success) :
                c.weight < 0 ? TK.tstyle(:text_dim) : TK.tstyle(:text)
        label = "$focus$idx$mark $(_genome_summary(c.genome))"
        TK.set_string!(buf, cx, cy, first(label, cell_w - 1), style)
    end
    # pied : aide
    help = "n:suiv f:fav d:dév i:détails [ ]:div m:clavier s w e:commit"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(help, inner.width), TK.tstyle(:text_dim))
    return nothing
end

handle_key!(::SynthExplorerPane, evt) = false   # Task 10 remplit

function serialize(p::SynthExplorerPane)
    return Dict{String,Any}(
        "kind_seed"  => String(p.seed_name),
        "generation" => p.pop.generation,
        "radius"     => p.radius,
    )
end

on_close!(::SynthExplorerPane) = nothing          # Task 11 complète (drone)

register_pane_kind!(:explorer, _synth_explorer_pane_ctor)
```

- [ ] **Step 4: Inclure le module**

`src/Ressac.jl` après `include("synth_audition.jl")` : `include("pane_synth_explorer.jl")`.
`test/runtests.jl` après `include("test_synth_audition.jl")` : `    include("test_synth_explorer_pane.jl")`.

- [ ] **Step 5: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pane_synth_explorer.jl src/Ressac.jl test/test_synth_explorer_pane.jl test/runtests.jl
git commit -m "feat(explorer): :explorer pane skeleton + grid render"
```

---

### Task 10 : Interactions clavier (navigation, favoris, génération, jeu)

`handle_key!` : `hjkl`/flèches + `1`-`9` (focus), `f`/`d` (favori/dévalue), `n` (génération suivante), `R` (reshuffle), `[`/`]` (divergence), `Espace` (jouer). Le jeu utilise `_LIVE_SCHEDULER[].osc` (no-op si pas de session).

**Files:**
- Modify: `src/pane_synth_explorer.jl` (remplace le stub `handle_key!`)
- Test: `test/test_synth_explorer_pane.jl` (append testset)

- [ ] **Step 1: Ajouter les tests qui échouent**

Append à `test/test_synth_explorer_pane.jl` :

```julia
@testset "synth explorer pane — interactions" begin
    mk() = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 7))

    @testset "l / h move focus horizontally" begin
        p = mk()
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('l')) == true
        @test p.focus == 2
        Ressac.handle_key!(p, Tachikoma.KeyEvent('h'))
        @test p.focus == 1
    end

    @testset "j / k move focus by a row (3 cols)" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
        @test p.focus == 4
        Ressac.handle_key!(p, Tachikoma.KeyEvent('k'))
        @test p.focus == 1
    end

    @testset "digit keys jump focus" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('5'))
        @test p.focus == 5
    end

    @testset "f favors, d devalues the focused candidate" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        @test p.pop.candidates[1].weight > 0
        Ressac.handle_key!(p, Tachikoma.KeyEvent('5'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('d'))
        @test p.pop.candidates[5].weight < 0
    end

    @testset "n advances the generation" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('n'))
        @test p.pop.generation == 1
    end

    @testset "[ / ] adjust the divergence radius" begin
        p = mk()
        before = p.radius
        Ressac.handle_key!(p, Tachikoma.KeyEvent(']'))
        @test p.radius > before
        Ressac.handle_key!(p, Tachikoma.KeyEvent('['))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('['))
        @test p.radius < before
    end

    @testset "Space plays via the live scheduler (mock)" begin
        if !isdefined(Main, :MockOSCClient)
            mutable struct MockOSCClient; sent::Vector{Vector{UInt8}}; end
            MockOSCClient() = MockOSCClient(Vector{UInt8}[])
            Ressac.send_osc(c::MockOSCClient, b::Vector{UInt8}) = push!(c.sent, b)
        end
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            p = mk()
            Ressac.handle_key!(p, Tachikoma.KeyEvent(' '))
            @test length(mock.sent) >= 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "unhandled key returns false" begin
        p = mk()
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('Z')) == false
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — focus ne bouge pas (stub renvoie false).

- [ ] **Step 3: Remplacer le stub `handle_key!` dans `src/pane_synth_explorer.jl`**

Remplacer la ligne `handle_key!(::SynthExplorerPane, evt) = false   # Task 10 remplit` par :

```julia
_explorer_osc() = (s = _LIVE_SCHEDULER[]; s === nothing ? nothing : s.osc)

function _move_focus!(p::SynthExplorerPane, d::Int)
    n = length(p.pop.candidates)
    p.focus = clamp(p.focus + d, 1, n)
    return true
end

function _explorer_play_focus!(p::SynthExplorerPane)
    osc = _explorer_osc(); osc === nothing && return true
    c = p.pop.candidates[p.focus]
    audition_play!(p.audition, osc, p.focus, c.genome, 220.0, 0.6)
    return true
end

function _explorer_next_gen!(p::SynthExplorerPane)
    p.pop.radius = p.radius
    next_generation!(p.pop, p.rng)
    osc = _explorer_osc()
    osc === nothing ||
        enqueue_generation!(p.audition, osc,
                            [c.genome for c in p.pop.candidates])
    p.focus = 1
    return true
end

function handle_key!(p::SynthExplorerPane, evt)
    evt isa TK.KeyEvent || return false
    if p.keyboard_mode
        return _explorer_keyboard_key!(p, evt)    # Task 11
    end
    ch = evt.char
    k  = evt.key
    # navigation
    (ch == 'l' || k === :right) && return _move_focus!(p, 1)
    (ch == 'h' || k === :left)  && return _move_focus!(p, -1)
    (ch == 'j' || k === :down)  && return _move_focus!(p, _GA_GRID_COLS)
    (ch == 'k' || k === :up)    && return _move_focus!(p, -_GA_GRID_COLS)
    if ch isa Char && '1' <= ch <= '9'
        idx = Int(ch - '0')
        idx <= length(p.pop.candidates) && (p.focus = idx)
        return true
    end
    # notation
    ch == 'f' && (favor!(p.pop, p.focus);   return true)
    ch == 'd' && (devalue!(p.pop, p.focus); return true)
    # génération
    ch == 'n' && return _explorer_next_gen!(p)
    ch == 'R' && (p.pop.radius = p.radius; reshuffle!(p.pop, p.rng);
                  p.focus = 1; return true)
    # divergence
    ch == ']' && (p.radius = clamp(p.radius + 0.1, 0.0, 1.0); return true)
    ch == '[' && (p.radius = clamp(p.radius - 0.1, 0.0, 1.0); return true)
    # audition
    ch == ' ' && return _explorer_play_focus!(p)
    return false
end
```

- [ ] **Step 4: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/pane_synth_explorer.jl test/test_synth_explorer_pane.jl
git commit -m "feat(explorer): key interactions — nav, rate, generation, play, divergence"
```

---

### Task 11 : Mini-clavier (sous-mode `m`) + drone/hold (`t`) + `on_close!`

`m` entre dans un sous-mode où la rangée du bas joue le candidat focalisé à différentes hauteurs ; `Esc` en sort. `t` (re)tient le candidat en drone via `ga_held`. `on_close!` libère la voix drone.

**Files:**
- Modify: `src/pane_synth_explorer.jl`
- Test: `test/test_synth_explorer_pane.jl` (append testset)

- [ ] **Step 1: Ajouter les tests qui échouent**

Append à `test/test_synth_explorer_pane.jl` :

```julia
@testset "synth explorer pane — keyboard + drone" begin
    function _with_mock(f)
        if !isdefined(Main, :MockOSCClient)
            mutable struct MockOSCClient; sent::Vector{Vector{UInt8}}; end
            MockOSCClient() = MockOSCClient(Vector{UInt8}[])
            Ressac.send_osc(c::MockOSCClient, b::Vector{UInt8}) = push!(c.sent, b)
        end
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            f(mock)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "m toggles keyboard sub-mode, Esc leaves it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('m'))
        @test p.keyboard_mode == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.keyboard_mode == false
    end

    @testset "in keyboard mode a note key plays (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('m'))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('z'))
            @test length(mock.sent) >= 1
            @test p.keyboard_mode == true       # reste en mode clavier
        end
    end

    @testset "t toggles drone hold (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            @test p.audition.held_active == true
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            @test p.audition.held_active == false
        end
    end

    @testset "on_close! stops the drone (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            Ressac.on_close!(p)
            @test p.audition.held_active == false
        end
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `m` non géré (`keyboard_mode` reste false).

- [ ] **Step 3: Ajouter les branches `m`/`t` dans `handle_key!`**

Dans `src/pane_synth_explorer.jl`, dans `handle_key!`, juste avant `return false`, insérer :

```julia
    ch == 'm' && (p.keyboard_mode = true; return true)
    ch == 't' && return _explorer_toggle_drone!(p)
```

- [ ] **Step 4: Ajouter les helpers clavier + drone (avant `register_pane_kind!`)**

```julia
# Rangée de touches → décalage en demi-tons depuis la base (220 Hz).
const _KB_ROW = ('z','x','c','v','b','n','m',',','.')
const _KB_SEMITONES = Dict(c => i - 1 for (i, c) in enumerate(_KB_ROW))

function _explorer_keyboard_key!(p::SynthExplorerPane, evt::TK.KeyEvent)
    if evt.key === :escape
        p.keyboard_mode = false
        return true
    end
    ch = evt.char
    if ch isa Char && haskey(_KB_SEMITONES, ch)
        osc = _explorer_osc(); osc === nothing && return true
        freq = 220.0 * 2.0 ^ (_KB_SEMITONES[ch] / 12.0)
        c = p.pop.candidates[p.focus]
        audition_play!(p.audition, osc, p.focus, c.genome, freq, 0.6)
        return true
    end
    return true   # en sous-mode clavier on consomme tout
end

function _explorer_toggle_drone!(p::SynthExplorerPane)
    osc = _explorer_osc(); osc === nothing && return true
    if p.audition.held_active
        audition_stop!(p.audition, osc)
    else
        c = p.pop.candidates[p.focus]
        audition_hold!(p.audition, osc, c.genome, 110.0, 8.0)
    end
    return true
end
```

- [ ] **Step 5: Compléter `on_close!`**

Remplacer `on_close!(::SynthExplorerPane) = nothing          # Task 11 complète (drone)` par :

```julia
function on_close!(p::SynthExplorerPane)
    osc = _explorer_osc()
    osc === nothing || (p.audition.held_active && audition_stop!(p.audition, osc))
    return nothing
end
```

- [ ] **Step 6: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/pane_synth_explorer.jl test/test_synth_explorer_pane.jl
git commit -m "feat(explorer): mini-keyboard sub-mode + drone hold + on_close cleanup"
```

---

### Task 12 : Overlay détails (`i`) — DSL complet + stats

`i` ouvre un overlay pane-local affichant le DSL rendu du candidat focalisé + des stats (nb nœuds, UGens, profondeur). `Esc`/`i`/`q` ferment. Pane-local car un `PaneImpl` n'a pas accès à la modale `RessacApp`.

**Files:**
- Modify: `src/pane_synth_explorer.jl` (ajoute champ `inspect`, overlay, branche `i`)
- Test: `test/test_synth_explorer_pane.jl` (append testset)

- [ ] **Step 1: Ajouter les tests qui échouent**

Append à `test/test_synth_explorer_pane.jl` :

```julia
@testset "synth explorer pane — details overlay" begin
    @testset "genome_depth measures the longest signal path" begin
        g = Ressac.archetype(:drone_grave)   # Saw -> RLPF
        @test Ressac._genome_depth(g) >= 2
    end

    @testset "i opens the overlay, Esc closes it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 8))
        @test p.inspect == false
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        @test p.inspect == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.inspect == false
    end

    @testset "overlay renders the DSL + stats of the focused candidate" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 8))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("@synth", whole)
        @test occursin("nœuds", whole) || occursin("nodes", whole)
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `type SynthExplorerPane has no field inspect`.

- [ ] **Step 3: Ajouter le champ `inspect` au struct + au ctor**

Dans le `mutable struct SynthExplorerPane`, ajouter **en dernier champ**, après `seed_name::Symbol` (l'ordre des champs doit rester aligné sur l'ordre positionnel du constructeur — toujours ajouter les nouveaux champs à la fin) :

```julia
    inspect::Bool
```

Dans `_synth_explorer_pane_ctor`, changer la construction finale en :

```julia
    return SynthExplorerPane(pop, aud, 1, radius, rng, false, seed, false)
```

(le dernier `false` = `inspect`)

- [ ] **Step 4: Brancher `i` + fermeture dans `handle_key!`**

Tout en haut de `handle_key!` (après le guard `evt isa TK.KeyEvent || return false`, avant le bloc `keyboard_mode`), insérer :

```julia
    if p.inspect
        (evt.key === :escape || evt.char == 'i' || evt.char == 'q') &&
            (p.inspect = false)
        return true
    end
```

Et dans le corps principal, avant `return false`, ajouter :

```julia
    evt.char == 'i' && (p.inspect = true; return true)
```

- [ ] **Step 5: Ajouter `_genome_depth` + l'overlay, et l'appeler depuis `render!`**

Ajouter ces helpers (avant `register_pane_kind!`) :

```julia
function _genome_depth(g::Genome, id::Int = g.output_id, seen = Set{Int}())
    (id == 0 || !haskey(g.nodes, id) || id in seen) && return 0
    push!(seen, id)
    child = 0
    for a in g.nodes[id].args
        a isa NodeRef && (child = max(child, _genome_depth(g, a.id, seen)))
    end
    return 1 + child
end

function _render_inspect_overlay!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    c = p.pop.candidates[p.focus]
    g = c.genome
    dsl = render_dsl(g, p.seed_name)
    ugens = join(unique(String(n.ugen) for n in values(g.nodes)), ", ")
    stats = "nœuds: $(length(g.nodes)) · profondeur: $(_genome_depth(g)) · UGens: $ugens"
    # fond plein
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y, first("DÉTAILS · candidat $(p.focus)", inner.width),
                   TK.tstyle(:accent, bold = true))
    TK.set_string!(buf, inner.x, inner.y + 1, first(stats, inner.width),
                   TK.tstyle(:text_dim))
    # DSL wrap sur la largeur
    y = inner.y + 3
    for chunk in _wrap_text(dsl, inner.width)
        y > inner.y + inner.height - 2 && break
        TK.set_string!(buf, inner.x, y, chunk, TK.tstyle(:text))
        y += 1
    end
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   "Esc/i/q : fermer", TK.tstyle(:text_dim))
    return nothing
end

function _wrap_text(s::AbstractString, w::Int)
    w <= 0 && return String[s]
    out = String[]
    for i in 1:w:lastindex(s)
        push!(out, s[i:min(i + w - 1, lastindex(s))])
    end
    return out
end
```

Dans `render!`, juste avant `return nothing`, insérer :

```julia
    p.inspect && _render_inspect_overlay!(p, inner, buf)
```

- [ ] **Step 6: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/pane_synth_explorer.jl test/test_synth_explorer_pane.jl
git commit -m "feat(explorer): pane-local details overlay (full DSL + stats)"
```

---

### Task 13 : Commit `s` (graine) + `w` (user-synth) avec saisie de nom

`s`/`w` ouvrent une mini-saisie de nom (pane-local) ; `Enter` écrit, `Esc` annule. `s` → `save_seed` (JSON natif) ; `w` → `render_dsl` vers `plugins/user-synths/<nom>.jl`. (`e` export-éditeur = Task 14, nécessite l'app.)

**Files:**
- Modify: `src/pane_synth_explorer.jl`
- Test: `test/test_synth_explorer_pane.jl` (append testset)

- [ ] **Step 1: Ajouter les tests qui échouent**

Append à `test/test_synth_explorer_pane.jl` :

```julia
@testset "synth explorer pane — commit save" begin
    @testset "s enters seed-naming mode, typing builds the name" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 2))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('s'))
        @test p.naming === :seed
        Ressac.handle_key!(p, Tachikoma.KeyEvent('a'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('b'))
        @test p.name_buf == "ab"
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.naming === :none
        @test p.name_buf == ""
    end

    @testset "Enter in seed mode writes a JSON seed" begin
        mktempdir() do dir
            p = Ressac._pane_new(:explorer, Dict{String,Any}(
                "seed" => "pluck", "rng" => 2))
            p.seed_dir_override = dir
            Ressac.handle_key!(p, Tachikoma.KeyEvent('s'))
            for c in "myseed"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
            @test isfile(joinpath(dir, "myseed.json"))
            @test p.naming === :none
        end
    end

    @testset "Enter in synth mode writes a .jl DSL file" begin
        mktempdir() do dir
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 2))
            p.user_synth_dir_override = dir
            Ressac.handle_key!(p, Tachikoma.KeyEvent('w'))
            @test p.naming === :synth
            for c in "wobz"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
            path = joinpath(dir, "wobz.jl")
            @test isfile(path)
            @test occursin("@synth", read(path, String))
        end
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `has no field naming`.

- [ ] **Step 3: Étendre le struct + le ctor**

Ajouter au `mutable struct SynthExplorerPane`, après `inspect::Bool` :

```julia
    naming::Symbol                 # :none | :seed | :synth
    name_buf::String
    seed_dir_override::Union{String,Nothing}
    user_synth_dir_override::Union{String,Nothing}
```

Dans le ctor, changer la construction finale en :

```julia
    return SynthExplorerPane(pop, aud, 1, radius, rng, false, seed, false,
                             :none, "", nothing, nothing)
```

- [ ] **Step 4: Gérer le mode saisie dans `handle_key!`**

Tout en haut de `handle_key!`, après le guard `evt isa TK.KeyEvent || return false`, AVANT le bloc `if p.inspect`, insérer :

```julia
    if p.naming !== :none
        return _explorer_naming_key!(p, evt)
    end
```

Et dans le corps principal, avant `return false`, ajouter :

```julia
    evt.char == 's' && (p.naming = :seed;  p.name_buf = ""; return true)
    evt.char == 'w' && (p.naming = :synth; p.name_buf = ""; return true)
```

- [ ] **Step 5: Ajouter les helpers de saisie + écriture (avant `register_pane_kind!`)**

```julia
function _explorer_naming_key!(p::SynthExplorerPane, evt::TK.KeyEvent)
    if evt.key === :escape
        p.naming = :none; p.name_buf = ""
        return true
    elseif evt.key === :enter || evt.char == '\r'
        _explorer_commit_named!(p)
        p.naming = :none; p.name_buf = ""
        return true
    elseif evt.key === :backspace
        isempty(p.name_buf) || (p.name_buf = p.name_buf[1:end-1])
        return true
    elseif evt.char isa Char && (isletter(evt.char) || isdigit(evt.char) ||
                                 evt.char == '_' || evt.char == '-')
        p.name_buf *= evt.char
        return true
    end
    return true
end

function _explorer_commit_named!(p::SynthExplorerPane)
    isempty(p.name_buf) && return
    g = p.pop.candidates[p.focus].genome
    if p.naming === :seed
        dir = p.seed_dir_override === nothing ? seed_dir() : p.seed_dir_override
        save_seed(p.name_buf, g; dir = dir)
    elseif p.naming === :synth
        dir = p.user_synth_dir_override === nothing ?
              joinpath(pwd(), "plugins", "user-synths") : p.user_synth_dir_override
        isdir(dir) || mkpath(dir)
        write(joinpath(dir, "$(p.name_buf).jl"), render_dsl(g, Symbol(p.name_buf)))
    end
    return
end
```

- [ ] **Step 6: Afficher l'invite de saisie dans `render!`**

Dans `render!`, juste avant `p.inspect && _render_inspect_overlay!(...)`, insérer :

```julia
    if p.naming !== :none
        prompt = (p.naming === :seed ? "nom graine: " : "nom synth: ") *
                 p.name_buf * "_"
        TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                       first(prompt, inner.width), TK.tstyle(:warning, bold = true))
    end
```

- [ ] **Step 7: Lancer → succès**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/pane_synth_explorer.jl test/test_synth_explorer_pane.jl
git commit -m "feat(explorer): commit actions — save seed (JSON) + save user-synth (DSL)"
```

---

### Task 14 : Persistance de session (reprise) + intégration

`serialize` capture toute la `Population` (génomes + poids), la génération, le rayon, le focus ; le ctor restaure si présent. Test de round-trip + vérif d'enregistrement du kind. (`e` export-éditeur : voir « Suivi » — nécessite un handle workspace que le `PaneImpl` n'a pas.)

**Files:**
- Modify: `src/pane_synth_explorer.jl` (serialize complet + restauration ctor)
- Test: `test/test_synth_explorer_pane.jl` (append testset)

- [ ] **Step 1: Ajouter les tests qui échouent**

Append à `test/test_synth_explorer_pane.jl` :

```julia
@testset "synth explorer pane — session persistence" begin
    @testset ":explorer is a registered pane kind" begin
        @test haskey(Ressac._PANE_KINDS, :explorer)
    end

    @testset "serialize captures the full population" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 3))
        Ressac.favor!(p.pop, 2)
        d = Ressac.serialize(p)
        @test haskey(d, "population")
        @test length(d["population"]) == 9
    end

    @testset "round-trip restores candidates + weights + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 3))
        Ressac.favor!(p.pop, 2)
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))   # focus 1 favori
        gen_before = p.pop.generation
        d = Ressac.serialize(p)
        p2 = Ressac._pane_new(:explorer, d)
        @test length(p2.pop.candidates) == 9
        @test p2.pop.generation == gen_before
        @test p2.pop.candidates[2].weight > 0
        # génomes identiques (via rendu)
        s1 = Ressac.render_synthdef(p.pop.candidates[5].genome, :x)
        s2 = Ressac.render_synthdef(p2.pop.candidates[5].genome, :x)
        @test s1 == s2
    end
end
```

- [ ] **Step 2: Lancer → échec**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -20`
Expected: FAIL — `serialize` ne contient pas `"population"`.

- [ ] **Step 3: Remplacer `serialize` (population complète)**

Remplacer la fonction `serialize(p::SynthExplorerPane)` par :

```julia
function serialize(p::SynthExplorerPane)
    return Dict{String,Any}(
        "kind_seed"  => String(p.seed_name),
        "generation" => p.pop.generation,
        "radius"     => p.radius,
        "focus"      => p.focus,
        "population" => [Dict{String,Any}(
                            "genome" => serialize_genome(c.genome),
                            "weight" => c.weight)
                         for c in p.pop.candidates],
    )
end
```

- [ ] **Step 4: Restaurer dans le ctor**

Au début de `_synth_explorer_pane_ctor`, après la ligne `seed = Symbol(...)`, insérer le chemin de restauration :

```julia
    if haskey(args, "population")
        rng = MersenneTwister(rand(UInt32))
        radius = Float64(get(args, "radius", 0.5))
        cands = Candidate[]
        for entry in args["population"]
            g = deserialize_genome(entry["genome"])
            push!(cands, Candidate(g, Float64(entry["weight"])))
        end
        base = isempty(cands) ? archetype(:drone_grave) : _copy_genome(cands[1].genome)
        pop = Population(cands, base, Int(get(args, "generation", 0)), radius)
        aud = AuditionState(length(cands))
        focus = Int(get(args, "focus", 1))
        return SynthExplorerPane(pop, aud, focus, radius, rng, false, seed, false,
                                 :none, "", nothing, nothing)
    end
```

- [ ] **Step 5: Lancer → succès (suite complète)**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E 'Test Summary:|Ressac.jl|FAIL'`
Expected: PASS, total final en hausse.

- [ ] **Step 6: Vérification manuelle TUI (golden path)**

Dans une session SC live : `just live`, puis `:vsplit explorer`, choisir la graine, naviguer `hjkl`, `Espace` pour écouter, `f` pour favoriser, `n` pour la génération suivante, `i` pour le DSL, `s` pour sauver une graine. Vérifier : son joué, pas de saturation, grille mise à jour, reprise après `:layout save`/restart.

- [ ] **Step 7: Commit**

```bash
git add src/pane_synth_explorer.jl test/test_synth_explorer_pane.jl
git commit -m "feat(explorer): full session persistence (population round-trip)"
```

---

## Suivi (hors périmètre de ce plan)

- **Opérateur feedback** : cycles via délai (`LocalIn`/`LocalOut`) — demande un rendu à variables nommées plutôt qu'inline. Tâche dédiée.
- **`e` export vers onglet éditeur** : ouvrir un onglet synth dans le workspace depuis le pane demande un handle `WorkspaceManager` que le contrat `PaneImpl` ne porte pas. À câbler au niveau app (helper app-level invoqué via une commande, ou un signal de retour du pane). `w` (sauver vers `user-synths`) couvre déjà le besoin « rendre jouable ».
- **A2 — parser DSL→DAG** : importer un synth DSL écrit main comme génome (autre `GenomeSource`).
- **Modèle (3)** — population pondérée persistante : ne changerait que `next_generation!`.
- **Traduction DSL « jolie »** : `render_dsl` émet un `Sig(...)` brut SC ; une passe ultérieure pourrait ré-exprimer via les wrappers (`saw`, `rlpf`…).

## Self-review (couverture spec)

- Génome DAG + catalogue + contrat I/O + sécurité → Tasks 1-3. ✓
- Validité/réparation → Task 2. ✓
- Archétypes + sérialisation native + `plugins/synth-seeds/` → Task 4. ✓
- Mutation paramétrique + structurelle + croisement + rayon → Tasks 5-6. ✓ (feedback différé, noté)
- Moteur GA breeding-pool, poids prêts pour (3) → Task 7. ✓
- Audition file bornée + evalAndPlay/play + drone + mini-clavier → Tasks 8, 11. ✓
- Pane grille 6/9 + interactions + overlay détails + commit → Tasks 9-13. ✓ (`e` différé, noté)
- Persistance session + graines → Tasks 4, 14. ✓
- Tests purs (génome/opérateurs/GA) + mock OSC (audition) + render/handle_key (pane) → chaque task. ✓
