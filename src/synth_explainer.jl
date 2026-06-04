# src/synth_explainer.jl
# Explique un son DÉTERMINISTIQUEMENT depuis son génome (+ descripteurs
# mesurés si dispo) : la chaîne de signal, le rôle de chaque variable, et
# « pourquoi ça sonne comme ça » (structure → perception + acoustique
# mesurée). Aucun LLM : tout dérive du catalogue d'UGens + du graphe.

# Phrase courte par UGen : ce qu'il fait + sa couleur sonore typique.
const _UGEN_DESC = Dict{Symbol,String}(
    :Saw => "oscillateur dent-de-scie, riche en harmoniques, mordant",
    :SinOsc => "oscillateur sinus, son pur et doux",
    :Pulse => "oscillateur carré/pulse, creux et nasal",
    :LFTri => "triangle, doux, peu d'harmoniques",
    :WhiteNoise => "bruit blanc, souffle plein spectre",
    :PinkNoise => "bruit rose, souffle plus sourd",
    :Dust => "impulsions aléatoires, crépitement",
    :VarSaw => "dent-de-scie à largeur variable",
    :Blip => "train d'harmoniques bande-limité, brillant",
    :Impulse => "clic périodique, sec",
    :LFSaw => "dent-de-scie (oscillo/modulateur)",
    :Formant => "synthèse à formants, voyelle/voix",
    :SyncSaw => "dent-de-scie synchronisée, agressive",
    :Crackle => "générateur chaotique, craquements",
    :Logistic => "carte logistique, chaos contrôlable",
    :RLPF => "passe-bas résonnant : enlève les aigus, peut siffler à la résonance",
    :LPF => "passe-bas : adoucit, enlève les aigus",
    :HPF => "passe-haut : éclaircit, enlève les graves",
    :BPF => "passe-bande : ne garde qu'une zone de fréquences",
    :Resonz => "résonateur : accentue une bande étroite",
    :MoogFF => "filtre Moog : passe-bas chaud et résonant",
    :Ringz => "résonateur sonnant, métallique (cloche)",
    :Formlet => "résonateur FOF, corps formantique",
    :OnePole => "passe-bas/haut doux (un pôle)",
    :FreeVerb => "réverbe : espace et queue",
    :CombC => "filtre peigne : écho court, métallique",
    :AllpassC => "passe-tout : diffusion, épaississement",
    :MulAdd => "mise à l'échelle (× puis +)",
    :Tanh => "saturation tanh : grain, distorsion douce",
    :Mix => "somme de deux signaux",
    :Fold2 => "repliement : distorsion riche, métallique",
    :Clip2 => "écrêtage dur : distorsion agressive",
    :Round => "quantification : effet bitcrush",
    :LFNoise1 => "bruit lissé (modulateur), mouvement aléatoire",
    :LFNoise0 => "bruit en escalier (modulateur), sauts",
    :SinOscKR => "LFO sinus, modulation douce",
    :LFPulseKR => "LFO carré, modulation rythmique",
    :FbIn => "retour (feedback) : auto-entretenu, peut larsener",
)
for nm in (:LorenzL, :HenonL, :LatoocarfianL, :CuspL, :QuadL, :GbmanL, :StandardL, :FBSineL)
    _UGEN_DESC[nm] = "générateur chaotique ($nm), instable, texture métallique/bruitée"
end

const _CHAOS_UGENS = Set{Symbol}((:LorenzL, :HenonL, :LatoocarfianL, :CuspL, :QuadL,
                                  :GbmanL, :StandardL, :FBSineL, :Logistic, :Crackle))

# Sens des slots fréquents (par nom de slot, cf. UGenSpec).
const _SLOT_DESC = Dict{Symbol,String}(
    :freq => "fréq", :rq => "résonance", :bwr => "bande", :width => "largeur",
    :phase => "phase", :mul => "gain", :add => "décalage", :amount => "intensité",
    :quant => "pas", :decaytime => "déclin", :room => "pièce", :mix => "dosage",
    :damp => "amorti", :gain => "drive", :density => "densité", :numharm => "harmo",
)

_explain_fmt(v::Float64) = isinteger(v) ? string(Int(v)) :
                           abs(v) >= 100 ? string(round(Int, v)) : string(round(v; digits = 2))

# Phrase d'un nœud : nom — description (params clés).
function _ugen_phrase(g::Genome, n::UGenNode)
    desc = get(_UGEN_DESC, n.ugen, "UGen $(n.ugen)")
    spec = ugen_spec(n.ugen)
    params = String[]
    for (i, a) in enumerate(n.args)
        nm = (spec !== nothing && i <= length(spec.slots)) ? spec.slots[i].name : Symbol("a$i")
        label = get(_SLOT_DESC, nm, String(nm))
        a isa ConstArg   && push!(params, "$label $(_explain_fmt(a.value))")
        a isa ControlRef && push!(params, "$label=$(a.name)")
    end
    return isempty(params) ? "$(n.ugen) — $desc" :
           "$(n.ugen) — $desc  [$(join(params, " · "))]"
end

_slot_const(n::UGenNode, i::Int) =
    (i <= length(n.args) && n.args[i] isa ConstArg) ? n.args[i].value : nothing

# Indices structure → perception (heuristiques sur le graphe).
function _structural_cues(g::Genome)
    cues = String[]
    names = Set(n.ugen for n in values(g.nodes))
    for n in values(g.nodes)
        if n.ugen in (:RLPF, :LPF, :MoogFF)
            c = _slot_const(n, 2)
            c !== nothing && c < 600 && push!(cues, "coupure basse (~$(round(Int, c)) Hz) → timbre sombre, feutré")
            c !== nothing && c > 4000 && push!(cues, "coupure haute → garde les aigus, plus brillant")
        end
        if n.ugen === :RLPF
            rq = _slot_const(n, 3)
            rq !== nothing && rq < 0.3 && push!(cues, "résonance forte → caractère sifflant/résonant")
        end
        if n.ugen === :HPF
            c = _slot_const(n, 2)
            c !== nothing && c > 1500 && push!(cues, "passe-haut élevé → son fin, sans graves")
        end
    end
    (:Tanh in names || :Clip2 in names || :Fold2 in names) &&
        push!(cues, "saturation/repliement → grain, distorsion")
    :Round in names && push!(cues, "quantification → grain numérique (bitcrush)")
    :FreeVerb in names && push!(cues, "réverbe → son spatial, avec une queue")
    any(x -> x in names, (:Ringz, :CombC, :AllpassC, :Formlet, :Resonz)) &&
        push!(cues, "résonateurs → caractère métallique/sonnant")
    any(x -> x in names, (:WhiteNoise, :PinkNoise, :Dust)) &&
        push!(cues, "source de bruit → texture soufflée")
    any(x -> x in _CHAOS_UGENS, names) &&
        push!(cues, "générateur chaotique → instable, imprévisible")
    _has_feedback(g) && push!(cues, "feedback → son auto-entretenu, peut diverger/larsener")
    return cues
end

# Indices acoustiques depuis les descripteurs MESURÉS (cf. DESCRIPTORS).
function _acoustic_cues(d::AbstractVector)
    length(d) < 6 && return String[]
    cues = String[]
    d[1] < 0.25 && push!(cues, "centroïde bas → timbre sombre")
    d[1] > 0.6  && push!(cues, "centroïde haut → timbre brillant")
    d[2] > 0.55 && push!(cues, "beaucoup d'énergie grave → caractère de basse")
    d[3] > 0.5  && push!(cues, "spectre plat → bruité")
    d[3] < 0.15 && push!(cues, "spectre tonal → hauteur nette")
    d[5] < 0.3  && push!(cues, "décroît vite → percussif")
    d[5] > 0.7  && push!(cues, "tenu → nappe/drone")
    d[6] > 0.7  && push!(cues, "hauteur définie")
    d[6] < 0.2  && push!(cues, "hauteur diffuse/inharmonique")
    return cues
end

_control_role(c::Symbol) =
    c === :freq    ? " — hauteur jouée (point de greffe interne libre)" :
    c === :sustain ? " — durée de la note" :
    c === :gain    ? " — volume" :
    c === :release ? " — temps de relâche" : ""

"""
    explain_genome(g; descriptors=nothing) -> Vector{String}

Explication lisible (lignes) d'un son : chaîne de signal, contrôles, et
pourquoi ça sonne comme ça. Si `descriptors` (vecteur mesuré, cf.
`DESCRIPTORS`) est fourni, ajoute la lecture acoustique. Déterministe.
"""
function explain_genome(g::Genome; descriptors = nothing)
    lines = String[]
    push!(lines, "CHAÎNE DE SIGNAL  (source → sortie)")
    order = _topo_order(g)
    if isempty(order)
        push!(lines, "  (vide)")
    else
        for id in order
            push!(lines, "  • " * _ugen_phrase(g, g.nodes[id]))
        end
    end
    push!(lines, "")
    push!(lines, "CONTRÔLES")
    for c in CONTROL_EDIT_ORDER
        push!(lines, "  • $c = $(_explain_fmt(control(g, c)))$(_control_role(c))")
    end
    push!(lines, "")
    push!(lines, "POURQUOI ÇA SONNE COMME ÇA")
    cues = _structural_cues(g)
    descriptors !== nothing && append!(cues, _acoustic_cues(descriptors))
    if isempty(cues)
        push!(lines, "  • son simple, sans couleur particulière marquée")
    else
        for c in cues
            push!(lines, "  • $c")
        end
    end
    return lines
end

# ── Persistance du génome dans les synths exportés ─────────────────
# Pour que l'explainer marche AUSSI dans :synth (après export depuis
# l'explorer), on embarque le génome sérialisé en commentaire Julia dans
# le .jl. Le loader SC l'ignore ; l'explainer le relit.
const _GENOME_COMMENT_PREFIX = "# ressac-genome: "

genome_comment(g::Genome) = _GENOME_COMMENT_PREFIX * JSON.json(serialize_genome(g))

# Récupère le génome embarqué dans un texte de synth, ou nothing.
function genome_from_text(text::AbstractString)
    for line in eachline(IOBuffer(text))
        if startswith(line, _GENOME_COMMENT_PREFIX)
            try
                return deserialize_genome(JSON.parse(chopprefix(line, _GENOME_COMMENT_PREFIX)))
            catch
                return nothing
            end
        end
    end
    return nothing
end

"""
    explain_synth_file(path; descriptors=nothing) -> Vector{String}

Explique un synth EXPORTÉ : si le .jl embarque son génome ressac (export
explorer), explication structurelle complète ; sinon, indique que seule
l'analyse acoustique pourrait le décrire.
"""
function explain_synth_file(path::AbstractString; descriptors = nothing)
    isfile(path) || return ["(fichier introuvable : $path)"]
    text = read(path, String)
    g = genome_from_text(text)            # génome embarqué (exports récents)
    g === nothing && (g = genome_from_dsl(text))   # sinon : parser le DSL
    g === nothing && return [
        "(impossible d'analyser ce synth : ni génome embarqué ni DSL reconnu).",
        "Seul un rendu acoustique NRT pourrait en décrire le timbre."]
    return explain_genome(g; descriptors = descriptors)
end

# ── Parser DSL → Genome (best-effort) ──────────────────────────────
# Reconnaît la sortie de render_dsl (begin-block ou `feedback() do fb …`)
# pour expliquer les synths exportés AVANT l'embarquement du génome (ou
# retouchés main). Tolérant : une expression inconnue devient une
# constante → l'explication reste utile même imparfaite.
_is_node_sym(s::Symbol) = occursin(r"^n\d+$", String(s))

function _synth_body(expr)
    expr isa Expr || return nothing
    if expr.head === :macrocall && !isempty(expr.args) &&
       string(expr.args[1]) == "@synth"
        body = expr.args[end]
        body isa Expr || return nothing
        body.head === :block && return body
        if body.head === :do && length(body.args) == 2 && body.args[2] isa Expr &&
           body.args[2].head === :-> && body.args[2].args[2] isa Expr
            return body.args[2].args[2]        # corps du do fb … end
        end
        return nothing
    end
    for a in expr.args
        b = _synth_body(a); b === nothing || return b
    end
    return nothing
end

function _dsl_arg(g::Genome, ex, nmap::Dict{Symbol,Int}, fbid::Base.RefValue{Int})
    ex isa Number && return ConstArg(Float64(ex))
    ex isa QuoteNode && ex.value isa Symbol && return ControlRef(ex.value)
    if ex isa Symbol
        _is_node_sym(ex) && haskey(nmap, ex) && return NodeRef(nmap[ex])
        if ex === :fb
            fbid[] == 0 && (fbid[] = add_node!(g, :FbIn, :ar, Arg[]))
            return NodeRef(fbid[])
        end
        return ConstArg(0.0)
    end
    if ex isa Expr
        # contrôle décalé (:freq + n) → on garde le contrôle (offset ignoré)
        if ex.head === :call && length(ex.args) == 3 && ex.args[1] in (:+, :-) &&
           ex.args[2] isa QuoteNode && ex.args[2].value isa Symbol && ex.args[3] isa Number
            return ControlRef(ex.args[2].value)
        end
        return NodeRef(_dsl_node!(g, ex, nmap, fbid))
    end
    return ConstArg(0.0)
end

function _kw_rate(params::Expr)
    for kw in params.args
        if kw isa Expr && kw.head === :kw && kw.args[1] === :rate && kw.args[2] isa QuoteNode
            return kw.args[2].value
        end
    end
    return :ar
end

function _dsl_node!(g::Genome, ex, nmap::Dict{Symbol,Int}, fbid::Base.RefValue{Int})
    ex isa Symbol && _is_node_sym(ex) && haskey(nmap, ex) && return nmap[ex]
    ex isa Expr || return add_node!(g, :Silent, :ar, Arg[])
    if ex.head === :call
        head = ex.args[1]
        if head === :ugen
            name = ex.args[2] isa QuoteNode ? ex.args[2].value : :Silent
            rate = :ar; args = Arg[]
            for a in ex.args[3:end]
                if a isa Expr && a.head === :parameters
                    rate = _kw_rate(a)
                else
                    push!(args, _dsl_arg(g, a, nmap, fbid))
                end
            end
            return add_node!(g, name, rate, args)
        elseif head === :+
            l = ex.args[2]
            if l isa Expr && l.head === :call && l.args[1] === :* && length(l.args) == 3
                return add_node!(g, :MulAdd, :ar, Arg[_dsl_arg(g, l.args[2], nmap, fbid),
                    _dsl_arg(g, l.args[3], nmap, fbid), _dsl_arg(g, ex.args[3], nmap, fbid)])
            end
            return add_node!(g, :Mix, :ar, Arg[_dsl_arg(g, ex.args[2], nmap, fbid),
                                               _dsl_arg(g, ex.args[3], nmap, fbid)])
        elseif head === :|>
            x = _dsl_arg(g, ex.args[2], nmap, fbid)
            sh = ex.args[3]
            ug = (sh isa Expr && sh.head === :call) ?
                 (sh.args[1] === :fold2 ? :Fold2 : sh.args[1] === :clip2 ? :Clip2 :
                  sh.args[1] === :round_q ? :Round : :Tanh) : :Tanh
            return add_node!(g, ug, :ar, Arg[x])
        end
    end
    return add_node!(g, :Silent, :ar, Arg[])
end

# Retire la chaîne de sécurité (Limiter→LeakDC→Sanitize) pour pointer la
# sortie sur le nœud signifiant.
function _unwrap_safety(g::Genome, id::Int)
    cur = id
    for nm in (:Limiter, :LeakDC, :Sanitize)
        (haskey(g.nodes, cur) && g.nodes[cur].ugen === nm) || break
        nxt = 0
        for a in g.nodes[cur].args
            a isa NodeRef && (nxt = a.id; break)
        end
        nxt == 0 && break
        cur = nxt
    end
    return cur
end

function _apply_synth_params!(g::Genome, expr)
    expr isa Expr || return
    if expr.head === :macrocall
        for a in expr.args
            a isa Expr && a.head === :tuple || continue
            for kw in a.args
                kw isa Expr && kw.head === :(=) && kw.args[1] isa Symbol &&
                    kw.args[2] isa Number && (g.controls[kw.args[1]] = Float64(kw.args[2]))
            end
        end
    else
        for a in expr.args
            _apply_synth_params!(g, a)
        end
    end
end

"Parse notre DSL @synth (begin/feedback) en Genome best-effort, ou nothing."
function genome_from_dsl(text::AbstractString)
    expr = try Meta.parse(text) catch; return nothing end
    body = _synth_body(expr)
    body === nothing && return nothing
    g = Genome(); nmap = Dict{Symbol,Int}(); fbid = Ref(0); last = 0
    for st in body.args
        st isa LineNumberNode && continue
        if st isa Expr && st.head === :(=) && st.args[1] isa Symbol
            nmap[st.args[1]] = _dsl_node!(g, st.args[2], nmap, fbid); last = nmap[st.args[1]]
        else
            last = _dsl_node!(g, st, nmap, fbid)
        end
    end
    last == 0 && return nothing
    g.output_id = _unwrap_safety(g, last)
    _apply_synth_params!(g, expr)
    return g
end
