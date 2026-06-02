# src/pane_synth_explorer.jl
# PaneImpl :explorer — exploration de synths par GA interactif.
# Orchestre ga_engine + synth_audition + genome_render ; ne contient
# aucune logique GA/génome propre.
using Random

const _GA_GEN_SIZE = 9
const _GA_GRID_COLS = 3

# Seam app-level : le pane n'a pas de handle WorkspaceManager. On poste
# (nom, dsl) ici ; le routeur de touches de l'app (tui_app.jl) draine.
const _EXPLORER_EXPORT_REQUEST = Ref{Union{Nothing,Tuple{String,String}}}(nothing)

mutable struct SynthExplorerPane <: PaneImpl
    pop::Population
    audition::AuditionState
    focus::Int
    radius::Float64
    rng::MersenneTwister
    keyboard_mode::Bool
    seed_name::Symbol
    inspect::Bool
    naming::Symbol                 # :none | :seed | :synth | :export
    name_buf::String
    seed_dir_override::Union{String,Nothing}
    user_synth_dir_override::Union{String,Nothing}
    # v2 UI state
    cell_rects::Vector{Tuple{Int,NTuple{4,Int}}}  # idx => (x,y,w,h), filled by render!
    ga_panel::Bool                 # `g` GA-settings sub-mode
    ga_cursor::Int                 # selected row in the GA panel
    show_lineage::Bool             # `L` lineage overlay
    show_help::Bool                # `?` help overlay
end

# Default-fill the v2 UI state so existing positional constructions stay
# short; callers pass the first 12 fields, the rest default.
function SynthExplorerPane(pop, aud, focus, radius, rng, kbd, seed, inspect,
                           naming, name_buf, seed_dir, synth_dir)
    return SynthExplorerPane(pop, aud, focus, radius, rng, kbd, seed, inspect,
                             naming, name_buf, seed_dir, synth_dir,
                             Tuple{Int,NTuple{4,Int}}[], false, 1, false, false)
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

# Mini-schéma : la chaîne de signal source→…→sortie (suit la 1re entrée
# NodeRef de chaque nœud depuis la sortie).
function _genome_mini_schema(g::Genome; max_len::Int = 4)
    g.output_id == 0 && return "(vide)"
    chain = String[]
    cur = g.output_id
    seen = Set{Int}()
    while haskey(g.nodes, cur) && !(cur in seen) && length(chain) < max_len
        push!(seen, cur)
        n = g.nodes[cur]
        pushfirst!(chain, String(n.ugen))
        nxt = 0
        for a in n.args
            a isa NodeRef && (nxt = a.id; break)
        end
        nxt == 0 && break
        cur = nxt
    end
    return join(chain, "→")
end

# Quelques paramètres clés (constantes), labellés court : f=freq source,
# c=cutoff filtre, q=rq, w=width.
function _genome_key_params(g::Genome; max_n::Int = 3)
    parts = String[]
    for id in sort(collect(keys(g.nodes)))
        n = g.nodes[id]
        spec = ugen_spec(n.ugen)
        spec === nothing && continue
        for (i, sp) in enumerate(spec.slots)
            i <= length(n.args) || continue
            a = n.args[i]
            a isa ConstArg || continue
            label = sp.name === :freq ? (spec.role === :source ? "f" : "c") :
                    sp.name === :rq    ? "q" :
                    sp.name === :width ? "w" : String(sp.name)[1:1]
            v = a.value
            vs = isinteger(v) ? string(Int(v)) :
                 abs(v) >= 100 ? string(round(Int, v)) : string(round(v; digits = 1))
            push!(parts, "$label$vs")
            length(parts) >= max_n && return join(parts, " ")
        end
    end
    return join(parts, " ")
end

# Palette de styles par cluster (cyclique).
const _CLUSTER_STYLES = (:primary, :success, :warning, :title, :error, :secondary, :accent)
_cluster_style(cid::Int; bold::Bool = false) =
    TK.tstyle(_CLUSTER_STYLES[mod1(cid, length(_CLUSTER_STYLES))]; bold = bold)
_cluster_letter(cid::Int) = string(Char('A' + (cid - 1) % 26))

function title(p::SynthExplorerPane)
    return "explorer:$(p.seed_name) g$(p.pop.generation)"
end

# Draw one candidate as a boxed card: header (n° + ♥/✗ + cluster dot),
# mini-schema, key params, ready state. Border + cluster dot tinted by
# cluster; the focused card uses a bold accent border.
function _render_candidate_card!(p::SynthExplorerPane, c::Candidate, idx::Int,
                                 cid::Int, focused::Bool, r::TK.Rect, buf::TK.Buffer)
    border = focused ? TK.tstyle(:accent, bold = true) : _cluster_style(cid)
    TK.set_string!(buf, r.x, r.y, "┌" * "─"^(r.width - 2) * "┐", border)
    for y in 1:(r.height - 2)
        TK.set_string!(buf, r.x, r.y + y, "│", border)
        TK.set_string!(buf, r.x + r.width - 1, r.y + y, "│", border)
    end
    TK.set_string!(buf, r.x, r.y + r.height - 1, "└" * "─"^(r.width - 2) * "┘", border)
    ix = r.x + 1
    iw = r.width - 2
    mark = c.weight > 0 ? "♥" : c.weight < 0 ? "✗" : " "
    foc  = focused ? "▸" : " "
    # header line: ▸2♥ ●A
    hdr = "$foc$idx$mark ●$(_cluster_letter(cid))"
    TK.set_string!(buf, ix, r.y, first(hdr, iw),
                   focused ? TK.tstyle(:accent, bold = true) :
                   c.weight > 0 ? TK.tstyle(:success) :
                   c.weight < 0 ? TK.tstyle(:text_dim) : _cluster_style(cid))
    if r.height >= 3
        TK.set_string!(buf, ix, r.y + 1, first(_genome_mini_schema(c.genome), iw),
                       TK.tstyle(:text))
    end
    if r.height >= 4
        TK.set_string!(buf, ix, r.y + 2, first(_genome_key_params(c.genome), iw),
                       TK.tstyle(:text_dim))
    end
    if r.height >= 5
        idxr = something(findfirst(==(idx), 1:length(p.audition.ready)), 0)
        state = (idxr >= 1 && idxr <= length(p.audition.ready) &&
                 p.audition.ready[idxr]) ? "·prêt" : "·compil."
        TK.set_string!(buf, ix, r.y + r.height - 2, state, TK.tstyle(:text_dim))
    end
    return nothing
end

function render!(p::SynthExplorerPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    bar = repeat("█", clamp(round(Int, p.radius * 5), 0, 5))
    header = "SYNTH EXPLORER · gén $(p.pop.generation) · div $(rpad(bar, 5, '░')) · pop $(length(p.pop.candidates))"
    _render_pane_block_simple!(rect, header, buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 12 || inner.height < 6) && return
    empty!(p.cell_rects)
    clusters = cluster_population(p.pop.candidates)
    cols = _GA_GRID_COLS
    rows = cld(length(p.pop.candidates), cols)
    # Reserve 2 bottom rows: gene/cluster strip + help/prompt.
    grid_h = max(rows * 2, inner.height - 3)
    cell_w = inner.width ÷ cols
    cell_h = max(3, grid_h ÷ rows)
    for (idx, c) in enumerate(p.pop.candidates)
        col = (idx - 1) % cols
        row = (idx - 1) ÷ cols
        cx = inner.x + col * cell_w
        cy = inner.y + row * cell_h
        cw = cell_w - 1
        ch = cell_h - 1
        (cw < 6 || ch < 2) && continue
        push!(p.cell_rects, (idx, (cx, cy, cw, ch)))
        cid = idx <= length(clusters) ? clusters[idx] : 1
        focused = idx == p.focus
        _render_candidate_card!(p, c, idx, cid, focused,
                                TK.Rect(cx, cy, cw, ch), buf)
    end
    # Gene distribution + cluster legend strip.
    strip_y = inner.y + inner.height - 2
    genes = gene_distribution(p.pop.candidates)
    gtxt = "gènes: " * join(("$(String(k))×$v" for (k, v) in first(genes, 5)), " ")
    nclusters = isempty(clusters) ? 0 : maximum(clusters)
    ctxt = "  clusters: " * join((_cluster_letter(i) for i in 1:nclusters), " ")
    TK.set_string!(buf, inner.x, strip_y,
                   first(gtxt * ctxt, inner.width), TK.tstyle(:text_dim))
    help = "n:gén f/d i:détails L:lignée g:réglages m:clavier s w e  ?:aide"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(help, inner.width), TK.tstyle(:text_dim))
    if p.naming !== :none
        prompt = (p.naming === :seed ? "nom graine: " :
                  p.naming === :synth ? "nom synth: " : "nom export: ") *
                 p.name_buf * "_"
        TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                       first(prompt, inner.width), TK.tstyle(:warning, bold = true))
    end
    p.inspect && _render_inspect_overlay!(p, inner, buf)
    p.ga_panel && _render_ga_panel!(p, inner, buf)
    p.show_lineage && _render_lineage_overlay!(p, inner, buf)
    p.show_help && _render_help_overlay!(p, inner, buf)
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

function _render_lineage_overlay!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    c = p.pop.candidates[p.focus]
    TK.set_string!(buf, inner.x, inner.y,
                   first("LIGNÉE · candidat $(p.focus) (id $(c.id))", inner.width),
                   TK.tstyle(:accent, bold = true))
    chain = lineage_chain(p.pop, c.id)
    y = inner.y + 2
    for (depth, e) in enumerate(chain)
        y > inner.y + inner.height - 2 && break
        indent = "  "^(depth - 1)
        genlbl = e.gen >= 0 ? "gén$(e.gen)" : "gén?"
        line = "$indent$genlbl #$(e.id)  $(e.origin)"
        TK.set_string!(buf, inner.x, y, first(line, inner.width),
                       depth == 1 ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
        y += 1
    end
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   "Esc/L/q : fermer", TK.tstyle(:text_dim))
    return nothing
end

const _EXPLORER_HELP_LINES = [
    "SYNTH EXPLORER — aide",
    "",
    "Navigation   hjkl / flèches · 1-9 saut · clic souris",
    "Écoute       Espace jouer · t drone · m mini-clavier (z x c v…)",
    "Sélection    f favoriser · d dévaluer · scroll souris",
    "Génération   n suivante · clic-droit suivant · R re-tirer",
    "Divergence   [ / ] · g réglages GA (taille/croisement/élitisme)",
    "Infos        i détails (DSL) · L lignée du candidat",
    "Garder       s graine · w synth · e éditeur",
    "Couleurs     cadre/pastille = cluster de proximité génétique",
    "",
    "Esc / ? / q : fermer",
]

function _render_help_overlay!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    for (i, line) in enumerate(_EXPLORER_HELP_LINES)
        y = inner.y + i - 1
        y > inner.y + inner.height - 1 && break
        TK.set_string!(buf, inner.x, y, first(line, inner.width),
                       i == 1 ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
    end
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
    if p.show_lineage
        (evt.key === :escape || evt.char == 'L' || evt.char == 'q') &&
            (p.show_lineage = false)
        return true
    end
    if p.show_help
        (evt.key === :escape || evt.char == '?' || evt.char == 'q') &&
            (p.show_help = false)
        return true
    end
    if p.ga_panel
        return _explorer_ga_panel_key!(p, evt)
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
    ch == 's' && (p.naming = :seed;   p.name_buf = ""; return true)
    ch == 'w' && (p.naming = :synth;  p.name_buf = ""; return true)
    ch == 'e' && (p.naming = :export; p.name_buf = ""; return true)
    # overlays / panels
    ch == 'L' && (p.show_lineage = true; return true)
    ch == '?' && (p.show_help = true;    return true)
    ch == 'g' && (p.ga_panel = true; p.ga_cursor = 1; return true)
    return false
end

# ── GA settings sub-mode (`g`) ─────────────────────────────────────
# Rows: 1 génération · 2 divergence · 3 croisement · 4 élitisme.
const _GA_PANEL_ROWS = 4

function _explorer_ga_panel_key!(p::SynthExplorerPane, evt::TK.KeyEvent)
    ch = evt.char; k = evt.key
    if k === :escape || ch == 'g'
        p.ga_panel = false
        return true
    end
    (ch == 'j' || k === :down) && (p.ga_cursor = clamp(p.ga_cursor + 1, 1, _GA_PANEL_ROWS); return true)
    (ch == 'k' || k === :up)   && (p.ga_cursor = clamp(p.ga_cursor - 1, 1, _GA_PANEL_ROWS); return true)
    inc = (ch == 'l' || k === :right || ch == '+') ?  1 :
          (ch == 'h' || k === :left  || ch == '-') ? -1 : 0
    inc == 0 && return true
    _ga_panel_adjust!(p, p.ga_cursor, inc)
    return true
end

function _ga_panel_adjust!(p::SynthExplorerPane, row::Int, inc::Int)
    if row == 1            # taille génération (bornée au pool d'audition)
        p.pop.gen_size = clamp(p.pop.gen_size + inc, 2, _GA_GEN_SIZE)
        p.pop.elitism  = clamp(p.pop.elitism, 0, p.pop.gen_size - 1)
    elseif row == 2        # rayon de divergence
        p.radius = clamp(round(p.radius + inc * 0.1; digits = 2), 0.0, 1.0)
        p.pop.radius = p.radius
    elseif row == 3        # proba de croisement
        p.pop.crossover_prob = clamp(round(p.pop.crossover_prob + inc * 0.1; digits = 2), 0.0, 1.0)
    elseif row == 4        # élitisme
        p.pop.elitism = clamp(p.pop.elitism + inc, 0, p.pop.gen_size - 1)
    end
    return
end

function _render_ga_panel!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y, first("RÉGLAGES GA", inner.width),
                   TK.tstyle(:accent, bold = true))
    rows = [("taille génération", string(p.pop.gen_size)),
            ("rayon divergence",  string(round(p.radius; digits = 2))),
            ("proba croisement",  string(round(p.pop.crossover_prob; digits = 2))),
            ("élitisme (favoris)", string(p.pop.elitism))]
    for (i, (label, val)) in enumerate(rows)
        sel = i == p.ga_cursor
        cursor = sel ? "▸ " : "  "
        line = "$cursor$(rpad(label, 22)) $val"
        TK.set_string!(buf, inner.x, inner.y + 1 + i,
                       first(line, inner.width),
                       sel ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   "j/k choisir · ←/→ ajuster · Esc/g fermer", TK.tstyle(:text_dim))
    return nothing
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
    elseif p.naming === :export
        _EXPLORER_EXPORT_REQUEST[] = (p.name_buf, render_dsl(g, Symbol(p.name_buf)))
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

# Which candidate index sits under (x, y), from the last render's rects.
function _cell_at(p::SynthExplorerPane, x::Int, y::Int)
    for (idx, (cx, cy, cw, ch)) in p.cell_rects
        (cx <= x < cx + cw && cy <= y < cy + ch) && return idx
    end
    return nothing
end

# Souris : clic gauche = focus + jouer · scroll = favoriser/dévaluer ·
# clic droit = génération suivante.
function handle_mouse!(p::SynthExplorerPane, evt)
    evt isa TK.MouseEvent || return false
    if evt.button === TK.mouse_right && evt.action === TK.mouse_press
        _explorer_next_gen!(p)
        return true
    end
    idx = _cell_at(p, evt.x, evt.y)
    if evt.button === TK.mouse_scroll_up
        i = idx === nothing ? p.focus : idx
        favor!(p.pop, i); return true
    elseif evt.button === TK.mouse_scroll_down
        i = idx === nothing ? p.focus : idx
        devalue!(p.pop, i); return true
    elseif evt.button === TK.mouse_left && evt.action === TK.mouse_press
        idx === nothing && return false
        p.focus = idx
        _explorer_play_focus!(p)
        return true
    end
    return false
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
