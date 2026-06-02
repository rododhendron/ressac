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
    inspect::Bool
    naming::Symbol                 # :none | :seed | :synth
    name_buf::String
    seed_dir_override::Union{String,Nothing}
    user_synth_dir_override::Union{String,Nothing}
end

function _synth_explorer_pane_ctor(args::AbstractDict)
    seed = Symbol(String(get(args, "kind_seed", get(args, "seed", "drone_grave"))))
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
    seeds = all_seeds()
    base = haskey(seeds, seed) ? seeds[seed] : archetype(:drone_grave)
    rng = MersenneTwister(Int(get(args, "rng", rand(UInt32))))
    radius = Float64(get(args, "radius", 0.5))
    pop = init_population(base, _GA_GEN_SIZE, rng; radius = radius)
    aud = AuditionState(_GA_GEN_SIZE)
    return SynthExplorerPane(pop, aud, 1, radius, rng, false, seed, false,
                             :none, "", nothing, nothing)
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
    help = "n:suiv f:fav d:dév i:détails [ ]:div m:clavier s w e:commit"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(help, inner.width), TK.tstyle(:text_dim))
    if p.naming !== :none
        prompt = (p.naming === :seed ? "nom graine: " : "nom synth: ") *
                 p.name_buf * "_"
        TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                       first(prompt, inner.width), TK.tstyle(:warning, bold = true))
    end
    p.inspect && _render_inspect_overlay!(p, inner, buf)
    return nothing
end

function _genome_depth(g::Genome, id::Int = g.output_id, seen = Set{Int}())
    (id == 0 || !haskey(g.nodes, id) || id in seen) && return 0
    push!(seen, id)
    child = 0
    for a in g.nodes[id].args
        a isa NodeRef && (child = max(child, _genome_depth(g, a.id, seen)))
    end
    return 1 + child
end

function _wrap_text(s::AbstractString, w::Int)
    w <= 0 && return String[s]
    out = String[]
    for i in 1:w:lastindex(s)
        push!(out, s[i:min(i + w - 1, lastindex(s))])
    end
    return out
end

function _render_inspect_overlay!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    c = p.pop.candidates[p.focus]
    g = c.genome
    dsl = render_dsl(g, p.seed_name)
    ugens = join(unique(String(n.ugen) for n in values(g.nodes)), ", ")
    stats = "nœuds: $(length(g.nodes)) · profondeur: $(_genome_depth(g)) · UGens: $ugens"
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y,
                   first("DÉTAILS · candidat $(p.focus)", inner.width),
                   TK.tstyle(:accent, bold = true))
    TK.set_string!(buf, inner.x, inner.y + 1, first(stats, inner.width),
                   TK.tstyle(:text_dim))
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
    if p.naming !== :none
        return _explorer_naming_key!(p, evt)
    end
    if p.inspect
        (evt.key === :escape || evt.char == 'i' || evt.char == 'q') &&
            (p.inspect = false)
        return true
    end
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
    ch == 'm' && (p.keyboard_mode = true; return true)
    ch == 't' && return _explorer_toggle_drone!(p)
    ch == 'i' && (p.inspect = true; return true)
    ch == 's' && (p.naming = :seed;  p.name_buf = ""; return true)
    ch == 'w' && (p.naming = :synth; p.name_buf = ""; return true)
    return false
end

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

function on_close!(p::SynthExplorerPane)
    osc = _explorer_osc()
    osc === nothing || (p.audition.held_active && audition_stop!(p.audition, osc))
    return nothing
end

register_pane_kind!(:explorer, _synth_explorer_pane_ctor)
