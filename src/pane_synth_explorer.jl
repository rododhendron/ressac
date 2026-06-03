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

# Copie `text` dans le presse-papier système (essaie les outils courants
# Wayland/X11/macOS). Renvoie true si l'un a réussi.
function _copy_to_clipboard(text::AbstractString)
    for cmd in (`wl-copy`, `xclip -selection clipboard`,
                `xsel --clipboard --input`, `pbcopy`)
        try
            open(pipeline(cmd; stderr = devnull), "w") do io
                write(io, text)
            end
            return true
        catch
        end
    end
    return false
end

# Le texte yanké d'un candidat : son DSL rendu (ce que montre `i`).
_explorer_yank_text(p) = render_dsl(p.pop.candidates[p.focus].genome, p.seed_name)

function _explorer_yank!(p)
    txt = _explorer_yank_text(p)
    ok = _copy_to_clipboard(txt)
    push!(_APP_LOG[], ok ?
        "[INFO] candidat #$(p.focus) copié dans le presse-papier ($(length(txt)) car.)" :
        "[WARN] presse-papier indisponible (installe wl-copy / xclip / xsel)")
    length(_APP_LOG[]) > 200 && popfirst!(_APP_LOG[])
    return true
end

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
    sustain::Float64               # default sustain used when auditioning
    param_edit::Bool               # `p` per-candidate param editor
    param_cursor::Int              # selected control row in the editor
    guidance_dir::Symbol           # direction perceptive active (∈ GUIDANCE_ORDER)
    mode::Symbol                   # :brew (rebrassage structurel) | :tune (réglage fin)
end

# Default-fill the v2 UI state so existing positional constructions stay
# short; callers pass the first 12 fields, the rest default.
function SynthExplorerPane(pop, aud, focus, radius, rng, kbd, seed, inspect,
                           naming, name_buf, seed_dir, synth_dir)
    return SynthExplorerPane(pop, aud, focus, radius, rng, kbd, seed, inspect,
                             naming, name_buf, seed_dir, synth_dir,
                             Tuple{Int,NTuple{4,Int}}[], false, 1, false, false,
                             0.6, false, 1, :none, :brew)
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
    mark = c.weight > 0 ? "♥"^Int(min(c.weight, 3)) :
           c.weight < 0 ? "✗"^Int(min(-c.weight, 3)) : " "
    foc  = focused ? "▸" : " "
    # header line: ▸2♥ ●A
    hdr = "$foc$idx$mark ●$(_cluster_letter(cid))"
    TK.set_string!(buf, ix, r.y, first(hdr, iw),
                   focused ? TK.tstyle(:accent, bold = true) :
                   c.weight > 0 ? TK.tstyle(:success) :
                   c.weight < 0 ? TK.tstyle(:text_dim) : _cluster_style(cid))
    # structure : le DAG des opérations (arbre), comme dans les détails.
    # Arbre complet s'il rentre ; sinon les premiers niveaux (cf.
    # _card_dag_lines). Replie sur le schéma linéaire si vraiment étroit.
    # On réserve la dernière ligne intérieure pour l'état (height-2).
    tree_avail = r.height - 3        # lignes entre l'en-tête et l'état
    if tree_avail >= 1
        lines = _card_dag_lines(c.genome, tree_avail, iw)
        if isempty(lines)
            TK.set_string!(buf, ix, r.y + 1,
                           first(_genome_mini_schema(c.genome; max_len = 6), iw),
                           TK.tstyle(:text))
        else
            for (li, line) in enumerate(lines)
                TK.set_string!(buf, ix, r.y + li, line,
                               li == 1 ? TK.tstyle(:text) : TK.tstyle(:text_dim))
            end
        end
    elseif r.height >= 3
        TK.set_string!(buf, ix, r.y + 1,
                       first(_genome_mini_schema(c.genome; max_len = 6), iw),
                       TK.tstyle(:text))
    end
    # état d'audition / silence sémantique mesuré par SC
    if r.height >= 6
        lv = _GA_SLOT_LEVEL[]; mk = _GA_SLOT_MEASURED[]
        silent = idx <= length(mk) && mk[idx] && lv[idx] < _GA_SILENCE_THRESHOLD
        state, st = silent ? ("⚠ MUET", TK.tstyle(:error, bold = true)) :
                    (idx <= length(p.audition.ready) && p.audition.ready[idx]) ?
                        ("·prêt", TK.tstyle(:text_dim)) : ("·en file", TK.tstyle(:text_dim))
        TK.set_string!(buf, ix, r.y + r.height - 2, first(state, iw), st)
    end
    return nothing
end

const _GA_SILENCE_THRESHOLD = 0.003f0

function render!(p::SynthExplorerPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    bar = repeat("█", clamp(round(Int, p.radius * 5), 0, 5))
    strat = get(_GA_STRATEGY_NAMES, p.pop.strategy, "?")
    guide = p.guidance_dir === :none ? "" : " · → $(p.guidance_dir)"
    # En mode tune la stratégie ne s'applique pas (orbite paramétrique).
    modebadge = p.mode === :tune ? "TUNE (T)" : "BREW · $strat (Tab)"
    # Jauge d'énergie : énergie moyenne de la génération → cible (ressort).
    en = isempty(p.pop.candidates) ? 0.0 :
         sum(genome_energy(c.genome) for c in p.pop.candidates) / length(p.pop.candidates)
    tgt = p.pop.energy_target
    arrow = en > tgt + 0.5 ? "↑" : en < tgt - 0.5 ? "↓" : "≈"
    engauge = "én $(round(en; digits = 1))$arrow$(round(Int, tgt))"
    header = "EXPLORER · gén $(p.pop.generation) · $modebadge$guide · $engauge · div $(rpad(bar, 5, '░')) · pop $(length(p.pop.candidates))"
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
    help = "n:gén T:tune/brew f/d p:params L:lignée g:réglages m:clavier  ?:aide"
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
    p.param_edit && _render_param_editor!(p, inner, buf)
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

# Arbre lisible du DAG depuis la sortie : chaque nœud = un UGen + ses
# constantes/contrôles inline ; les entrées-signal deviennent des
# enfants indentés. Bien plus clair que le code SC brut.
function _genome_tree_lines(g::Genome, id::Int = g.output_id;
                            prefix::String = "", is_last::Bool = true,
                            is_root::Bool = true, depth::Int = 0,
                            max_depth::Int = typemax(Int),
                            seen::Set{Int} = Set{Int}(), out::Vector{String} = String[])
    (id == 0 || !haskey(g.nodes, id) || id in seen) && return out
    push!(seen, id)
    n = g.nodes[id]
    spec = ugen_spec(n.ugen)
    inline = String[]
    children = Int[]
    for (i, a) in enumerate(n.args)
        nm = (spec !== nothing && i <= length(spec.slots)) ? String(spec.slots[i].name) : "a$i"
        if a isa ConstArg
            v = a.value
            push!(inline, "$nm $(isinteger(v) ? string(Int(v)) : string(round(v; digits = 2)))")
        elseif a isa ControlRef
            push!(inline, "$nm=$(a.name)")
        elseif a isa NodeRef
            push!(children, a.id)
        end
    end
    connector = is_root ? "" : (is_last ? "└─ " : "├─ ")
    label = isempty(inline) ? String(n.ugen) : "$(n.ugen)  $(join(inline, " · "))"
    push!(out, prefix * connector * label)
    child_prefix = is_root ? "" : prefix * (is_last ? "   " : "│  ")
    # Au-delà de max_depth, on coupe : un marqueur signale les enfants cachés.
    if depth >= max_depth
        isempty(children) || push!(out, child_prefix * "└─ …")
        return out
    end
    for (k, cid) in enumerate(children)
        _genome_tree_lines(g, cid; prefix = child_prefix,
                           is_last = (k == length(children)), is_root = false,
                           depth = depth + 1, max_depth = max_depth,
                           seen = seen, out = out)
    end
    return out
end

# Lignes d'arbre à afficher dans une CASE (hauteur/largeur limitées).
# Format demandé : l'arbre COMPLET s'il rentre ; sinon les premiers
# niveaux de profondeur qui tiennent dans `avail` lignes (un marqueur
# « … » indique les nœuds plus profonds). Largeur tronquée à `iw` avec
# un marqueur « › » en cas de débordement horizontal.
function _card_dag_lines(g::Genome, avail::Int, iw::Int)
    avail <= 0 && return String[]
    fit(s) = length(s) > iw ? string(first(s, max(iw - 1, 0)), "›") : s
    full = _genome_tree_lines(g)
    isempty(full) && return String[]
    if length(full) <= avail
        return [fit(l) for l in full]
    end
    # Cherche la plus grande profondeur dont le rendu tient dans avail.
    best = String[]
    for d in 1:_genome_depth(g)
        ls = _genome_tree_lines(g; max_depth = d)
        length(ls) <= avail ? (best = ls) : break
    end
    isempty(best) && (best = first(full, avail))   # garde-fou (arbre très large)
    return [fit(l) for l in best]
end

function _render_inspect_overlay!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    c = p.pop.candidates[p.focus]
    g = c.genome
    ctl = "freq $(round(Int, control(g, :freq))) · sustain $(round(control(g, :sustain); digits = 2)) · release $(round(control(g, :release); digits = 2))"
    stats = "nœuds: $(length(g.nodes)) · profondeur: $(_genome_depth(g)) · $(c.origin)"
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y,
                   first("DÉTAILS · candidat $(p.focus) — DAG des opérations", inner.width),
                   TK.tstyle(:accent, bold = true))
    TK.set_string!(buf, inner.x, inner.y + 1, first(stats, inner.width), TK.tstyle(:text_dim))
    TK.set_string!(buf, inner.x, inner.y + 2, first(ctl, inner.width), TK.tstyle(:text_dim))
    y = inner.y + 4
    for line in _genome_tree_lines(g)
        y > inner.y + inner.height - 2 && break
        TK.set_string!(buf, inner.x, y, first(line, inner.width), TK.tstyle(:text))
        y += 1
    end
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   "y copie le DSL · Esc/i/q ferme", TK.tstyle(:text_dim))
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
    "Génération   n suivante · clic-droit suivant",
    "             T bascule TUNE (réglage fin, structure gelée)",
    "               ↔ BREW (rebrassage structurel, stratégies GA)",
    "             R re-diverge (repêche de vieux parents + bruit)",
    "Stratégie    Tab change à la volée · g réglages détaillés",
    "Guidance     G greffe un bon coup (filtre/satu/reverb/détune…)",
    "             < > pousse vers une notion (grave/aigu/sombre/saturé…)",
    "Reset        0 nouvelle population depuis la graine",
    "Audibilité   ⚠ MUET = mesuré silencieux · S régénère les muets",
    "Divergence   [ / ] · g réglages GA (taille/croisement/élitisme)",
    "Infos        i détails (DSL) · L lignée · y copier le DSL",
    "Édition      p params du candidat (freq/sustain/release) · r reset",
    "Garder       s graine · w synth · e éditeur",
    "Couleurs     cadre/pastille = cluster de proximité génétique",
    "",
    "Lecture d'une carte :",
    "  ●A          cluster (sons génétiquement proches = même lettre)",
    "  Saw→RLPF→…  schéma : chaîne de signal source→…→sortie",
    "  freq 220 …  paramètres clés (constantes du génome)",
    "  5 nœuds…    taille du DAG + origine (graine/muté/croisé)",
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

# Make sure the current generation's SynthDefs are loaded in SC before
# we play one by name (gen 0 is never enqueued at ctor time — no osc).
function _explorer_ensure_defined!(p::SynthExplorerPane, osc)
    if p.audition.defined_gen != p.pop.generation
        enqueue_generation!(p.audition, osc, [c.genome for c in p.pop.candidates])
        p.audition.defined_gen = p.pop.generation
    end
    return nothing
end

function _explorer_play_focus!(p::SynthExplorerPane)
    osc = _explorer_osc(); osc === nothing && return true
    _explorer_ensure_defined!(p, osc)
    g = p.pop.candidates[p.focus].genome
    audition_play!(p.audition, osc, p.focus, control(g, :freq), control(g, :sustain))
    return true
end

# Pousse chaque candidat vers la notion perceptive active (si une
# direction est sélectionnée). Appelé après chaque génération.
function _explorer_apply_guidance!(p::SynthExplorerPane)
    p.guidance_dir === :none && return
    for c in p.pop.candidates
        apply_guidance!(c.genome, p.guidance_dir, p.rng)
    end
    return
end

function _explorer_next_gen!(p::SynthExplorerPane)
    p.pop.radius = p.radius
    if p.mode === :tune
        # Réglage fin : orbite paramétrique autour du candidat focalisé,
        # structure gelée. L'ancre revient en position 1.
        tune_generation!(p.pop, p.pop.candidates[p.focus].genome, p.rng)
    else
        next_generation!(p.pop, p.rng)
    end
    _explorer_apply_guidance!(p)
    _explorer_reenqueue!(p)
    p.focus = 1
    return true
end

# R : skip + re-diverge (échappe à la convergence en repêchant de vieux
# parents avec une divergence boostée).
function _explorer_diverge!(p::SynthExplorerPane)
    p.pop.radius = p.radius
    diverge!(p.pop, p.rng)
    _explorer_apply_guidance!(p)
    _explorer_reenqueue!(p)
    p.focus = 1
    return true
end

function _explorer_reenqueue!(p::SynthExplorerPane)
    osc = _explorer_osc()
    osc === nothing && return
    enqueue_generation!(p.audition, osc, [c.genome for c in p.pop.candidates])
    p.audition.defined_gen = p.pop.generation
    return
end

function handle_key!(p::SynthExplorerPane, evt)
    evt isa TK.KeyEvent || return false
    if p.naming !== :none
        return _explorer_naming_key!(p, evt)
    end
    if p.inspect
        evt.char == 'y' && return _explorer_yank!(p)   # copie le DSL affiché
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
    if p.param_edit
        return _explorer_param_key!(p, evt)
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
    # T = bascule réglage-fin (tune, structure gelée) ↔ rebrassage (brew).
    ch == 'T' && (p.mode = p.mode === :tune ? :brew : :tune; return true)
    # R = skip + re-diverge (repêche de vieux parents, divergence boostée).
    ch == 'R' && return _explorer_diverge!(p)
    # Tab = cycle de stratégie à la volée (sans ouvrir le panneau g).
    k === :tab && (i = something(findfirst(==(p.pop.strategy), GA_STRATEGIES), 1);
                   p.pop.strategy = GA_STRATEGIES[mod1(i + 1, length(GA_STRATEGIES))];
                   return true)
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
    ch == 'p' && (p.param_edit = true; p.param_cursor = 1; return true)
    ch == 'y' && return _explorer_yank!(p)   # copie le DSL du candidat focalisé
    ch == 'S' && return _explorer_regen_silent!(p)
    ch == '0' && return _explorer_reset!(p)  # repart d'une population fraîche
    # guidance : G = greffe un bon coup · < / > = direction perceptive
    ch == 'G' && return _explorer_good_move!(p)
    ch == '>' && (p.guidance_dir = _cycle_guidance(p.guidance_dir, 1);  return true)
    ch == '<' && (p.guidance_dir = _cycle_guidance(p.guidance_dir, -1); return true)
    return false
end

_cycle_guidance(cur::Symbol, d::Int) =
    GUIDANCE_ORDER[mod1(something(findfirst(==(cur), GUIDANCE_ORDER), 1) + d,
                        length(GUIDANCE_ORDER))]

# Greffe un bon coup (filtre/satu/reverb/détune/trémolo/sous-octave) sur
# le candidat focalisé.
function _explorer_good_move!(p::SynthExplorerPane)
    g = p.pop.candidates[p.focus].genome
    apply_good_move!(g, p.rng)
    osc = _explorer_osc()
    osc !== nothing && (enqueue_generation!(p.audition, osc, [c.genome for c in p.pop.candidates]);
                        p.audition.defined_gen = p.pop.generation)
    push!(_APP_LOG[], "[INFO] bon coup greffé sur le candidat #$(p.focus)")
    length(_APP_LOG[]) > 200 && popfirst!(_APP_LOG[])
    return true
end

# Reset complet : nouvelle population gén-0 depuis la graine courante.
function _explorer_reset!(p::SynthExplorerPane)
    seeds = all_seeds()
    base = haskey(seeds, p.seed_name) ? seeds[p.seed_name] : archetype(:drone_grave)
    p.pop = init_population(base, _GA_GEN_SIZE, p.rng; radius = p.radius)
    p.focus = 1
    _explorer_reenqueue!(p)
    push!(_APP_LOG[], "[INFO] explorer réinitialisé (graine $(p.seed_name))")
    length(_APP_LOG[]) > 200 && popfirst!(_APP_LOG[])
    return true
end

# Remplace les candidats mesurés MUETS par de fraîches mutations (le
# silence sémantique que l'analyse statique ne voit pas).
function _explorer_regen_silent!(p::SynthExplorerPane)
    lv = _GA_SLOT_LEVEL[]; mk = _GA_SLOT_MEASURED[]
    n = 0
    for i in 1:length(p.pop.candidates)
        (i <= length(mk) && mk[i] && lv[i] < _GA_SILENCE_THRESHOLD) || continue
        old = p.pop.candidates[i]
        child = mutate(old.genome, p.rng; radius = max(p.radius, 0.5))
        p.pop.candidates[i] = _spawn!(p.pop, child, "régénéré (muet)", [old.id])
        n += 1
    end
    if n > 0
        osc = _explorer_osc()
        if osc !== nothing
            enqueue_generation!(p.audition, osc, [c.genome for c in p.pop.candidates])
            p.audition.defined_gen = p.pop.generation
        end
        push!(_APP_LOG[], "[INFO] $n candidat(s) muet(s) régénéré(s)")
        length(_APP_LOG[]) > 200 && popfirst!(_APP_LOG[])
    end
    return true
end

# ── Per-candidate param editor (`p`) ───────────────────────────────
# Edit the focused candidate's controls (freq/sustain/gain/release).
# Edits live on the genome → they bake into render + export AND are
# inherited when the candidate is favored (re-enters the algorithm).
const _PARAM_STEP = Dict(:freq => 10.0, :sustain => 0.1, :gain => 0.05, :release => 0.05)
const _PARAM_RANGE = Dict(:freq => (20.0, 8000.0), :sustain => (0.05, 8.0),
                          :gain => (0.0, 1.0), :release => (0.0, 4.0))

function _explorer_param_key!(p::SynthExplorerPane, evt::TK.KeyEvent)
    ch = evt.char; k = evt.key
    n = length(CONTROL_EDIT_ORDER)
    if k === :escape || ch == 'p'
        p.param_edit = false
        return true
    elseif ch == 'r'                       # reset to defaults
        p.pop.candidates[p.focus].genome.controls = default_controls()
        return true
    end
    (ch == 'j' || k === :down) && (p.param_cursor = clamp(p.param_cursor + 1, 1, n); return true)
    (ch == 'k' || k === :up)   && (p.param_cursor = clamp(p.param_cursor - 1, 1, n); return true)
    inc = (ch == 'l' || k === :right || ch == '+') ?  1 :
          (ch == 'h' || k === :left  || ch == '-') ? -1 : 0
    inc == 0 && return true
    name = CONTROL_EDIT_ORDER[p.param_cursor]
    g = p.pop.candidates[p.focus].genome
    lo, hi = _PARAM_RANGE[name]
    g.controls[name] = clamp(round(control(g, name) + inc * _PARAM_STEP[name]; digits = 3), lo, hi)
    return true
end

function _render_param_editor!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    g = p.pop.candidates[p.focus].genome
    TK.set_string!(buf, inner.x, inner.y,
                   first("PARAMS · candidat $(p.focus)", inner.width),
                   TK.tstyle(:accent, bold = true))
    for (i, name) in enumerate(CONTROL_EDIT_ORDER)
        sel = i == p.param_cursor
        cursor = sel ? "▸ " : "  "
        v = control(g, name)
        vs = isinteger(v) ? string(Int(v)) : string(round(v; digits = 2))
        line = "$cursor$(rpad(String(name), 10)) $vs"
        TK.set_string!(buf, inner.x, inner.y + 1 + i, first(line, inner.width),
                       sel ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   "j/k choisir · ←/→ ajuster · r reset · Esc/p fermer",
                   TK.tstyle(:text_dim))
    return nothing
end

# ── GA settings sub-mode (`g`) ─────────────────────────────────────
# Rows: 1 génération · 2 divergence · 3 croisement · 4 élitisme ·
#       5 stratégie · 6 cible énergie · 7 raideur ressort.
# (le sustain est par-candidat dans l'éditeur de params `p`.)
const _GA_PANEL_ROWS = 7

_ga_strategy_long(s::Symbol) =
    s === :breeding   ? "pool : croise + mute tes favoris" :
    s === :champion   ? "champion : un seul favori, tout = ses mutations" :
    s === :tournament ? "tournoi : sélection douce par mini-duels" :
    s === :weighted   ? "population pondérée : garde de la diversité" :
    s === :novelty    ? "nouveauté : maximise la distance, surprends-moi" :
    s === :cooling    ? "refroidissement : divergence décroît toute seule" :
    s === :bayesian   ? "bayésien : un modèle de ton goût pré-trie un grand pool" :
    s === :quality_diversity ? "QD : archive du meilleur par niche, couvre l'espace" : "?"

# Noms COURTS affichés dans la colonne valeur (pour ne pas chevaucher
# la description).
const _GA_STRATEGY_NAMES = Dict(
    :breeding   => "pool",
    :champion   => "champion",
    :tournament => "tournoi",
    :weighted   => "pondéré",
    :novelty    => "nouveauté",
    :cooling    => "refroidi",
    :bayesian   => "bayésien",
    :quality_diversity => "QD")

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
    elseif row == 5        # stratégie (cycle dans GA_STRATEGIES)
        i = something(findfirst(==(p.pop.strategy), GA_STRATEGIES), 1)
        p.pop.strategy = GA_STRATEGIES[mod1(i + inc, length(GA_STRATEGIES))]
    elseif row == 6        # cible d'énergie (plus haut = sons plus riches)
        p.pop.energy_target = clamp(round(p.pop.energy_target + inc * 1.0; digits = 1), 2.0, 40.0)
    elseif row == 7        # raideur du ressort (bas = oscille/déborde plus)
        p.pop.stiffness = clamp(round(p.pop.stiffness + inc * 0.1; digits = 2), 0.05, 2.0)
    end
    return
end

const _GA_PANEL_DESC = (
    "nb de candidats par génération (2-9)",
    "ampleur des mutations : 0 = fin, 1 = sauvage/structurel",
    "chance de croiser 2 favoris plutôt que muter un seul",
    "favoris gardés INTACTS — ne perd jamais un bon son",
    "moteur de sélection (cf. ligne)",
    "cible de complexité : plus haut = sons plus riches",
    "raideur du ressort : bas = l'énergie oscille/déborde",
)

function _render_ga_panel!(p::SynthExplorerPane, inner::TK.Rect, buf::TK.Buffer)
    blank = " "^inner.width
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, TK.tstyle(:text))
    end
    TK.set_string!(buf, inner.x, inner.y, first("RÉGLAGES GA", inner.width),
                   TK.tstyle(:accent, bold = true))
    rows = [("taille génération",  string(p.pop.gen_size)),
            ("rayon divergence",   string(round(p.radius; digits = 2))),
            ("proba croisement",   string(round(p.pop.crossover_prob; digits = 2))),
            ("élitisme (favoris)", string(p.pop.elitism)),
            ("stratégie",          get(_GA_STRATEGY_NAMES, p.pop.strategy, "?")),
            ("cible énergie",      string(round(p.pop.energy_target; digits = 1))),
            ("raideur ressort",    string(round(p.pop.stiffness; digits = 2)))]
    # Per-row description; the strategy row shows its full meaning.
    descs = [_GA_PANEL_DESC[1], _GA_PANEL_DESC[2], _GA_PANEL_DESC[3],
             _GA_PANEL_DESC[4], _ga_strategy_long(p.pop.strategy),
             _GA_PANEL_DESC[6], _GA_PANEL_DESC[7]]
    desc_x = inner.x + 36                      # description column (past values)
    for (i, (label, val)) in enumerate(rows)
        sel = i == p.ga_cursor
        y = inner.y + 1 + i
        cursor = sel ? "▸ " : "  "
        line = "$cursor$(rpad(label, 20)) $(rpad(val, 11))"
        TK.set_string!(buf, inner.x, y, first(line, min(34, inner.width)),
                       sel ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
        if desc_x < inner.x + inner.width
            TK.set_string!(buf, desc_x, y,
                           first(descs[i], inner.x + inner.width - desc_x),
                           sel ? TK.tstyle(:text) : TK.tstyle(:text_dim))
        end
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
        _explorer_ensure_defined!(p, osc)
        g = p.pop.candidates[p.focus].genome
        freq = control(g, :freq) * 2.0 ^ (_KB_SEMITONES[ch] / 12.0)
        audition_play!(p.audition, osc, p.focus, freq, control(g, :sustain))
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

# Le kind enregistré est :explorer (le fallback _kind_for donnerait
# "synthexplorer" → la restauration de layout échouerait).
_kind_for(::SynthExplorerPane) = "explorer"

register_pane_kind!(:explorer, _synth_explorer_pane_ctor)
