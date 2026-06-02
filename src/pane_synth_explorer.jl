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
