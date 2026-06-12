# src/pane_waveform.jl
# :waveform pane — onde sonore COMPLÈTE d'un son (rendu NRT hors-ligne),
# navigable : zoom molette VERS LE POINTEUR, défilement h/l, 0 = tout voir.
# Rendu min/max par colonne (style DAW) → fidèle à n'importe quel zoom.
# La source est un génome (re-rendu à la demande).
#
# Mode SCULPT (s) : manipulation des params dans la vue d'onde. Colonne
# vertébrale stable (flux du signal) + quartiers mous (graphe×acoustique).
# Cf. docs/journal/20260612_waveform_sculpt_design.md.

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

# Seam de rendu : par défaut le rendu NRT, surchargeable en test (sync, mock).
const _WAVE_RENDER = Ref{Function}(render_genome_audio)
# En test on rend SYNCHRONE (pas de thread → pas de course).
const _WAVE_SYNC = Ref{Bool}(false)

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

const _WAVE_MIN_LEN = 64        # zoom maxi : 64 échantillons en travers

# Ancre l'échantillon sous la fraction `f` de la largeur et change la fenêtre
# par `factor` (<1 zoom avant, >1 arrière). C'est le « zoom vers le pointeur ».
function _wave_zoom!(p::WaveformPane, f::Float64, factor::Float64)
    n = length(p.samples); n == 0 && return
    anchor = p.view_start + round(Int, f * p.view_len)
    newlen = clamp(round(Int, p.view_len * factor), _WAVE_MIN_LEN, n)
    p.view_start = clamp(anchor - round(Int, f * newlen), 1, max(1, n - newlen + 1))
    p.view_len = newlen
    return
end

_wave_pan!(p::WaveformPane, d::Int) =
    (n = length(p.samples); p.view_start = clamp(p.view_start + d, 1, max(1, n - p.view_len + 1)))

# ── Mode sculpt : init, quartiers, tir ─────────────────────────────
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

# ── Boucle de rendu async (coalescée, bornée, thread-safe) ─────────
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

# e : exporte le génome sculpté (DSL multi-ligne + génome embarqué) vers un
# éditeur, via le même seam que l'export de l'explorer.
function _wave_export!(p::WaveformPane)
    p.genome === nothing && return true
    sym = Symbol(replace(p.label, r"[^\w]" => "_"))
    dsl = render_dsl(p.genome, sym) * "\n" * genome_comment(p.genome) * "\n"
    _EXPLORER_EXPORT_REQUEST[] = (String(sym), dsl)
    return true
end

# Tracé min/max par colonne sur la tranche visible (braille via Canvas).
function _render_wave_buffer!(p::WaveformPane, area::TK.Rect, buf::TK.Buffer)
    canvas = TK.Canvas(area.width, area.height; style = TK.tstyle(:primary))
    n = length(p.samples)
    vs = clamp(p.view_start, 1, n)
    ve = clamp(p.view_start + p.view_len - 1, vs, n)
    wdots = area.width * 2
    hdots = area.height * 4
    # normalisation crête sur la tranche visible
    peak = 0.0001
    @inbounds for i in vs:ve
        a = abs(Float64(p.samples[i])); a > peak && (peak = a)
    end
    scale = 1.0 / max(peak, 0.01)
    vl = ve - vs + 1
    for dx in 0:(wdots - 1)
        s0 = vs + (dx * vl) ÷ wdots
        s1 = vs + ((dx + 1) * vl) ÷ wdots - 1
        s1 = clamp(s1, s0, ve)
        lo = 1.0; hi = -1.0
        @inbounds for i in s0:s1
            v = clamp(Float64(p.samples[i]) * scale, -1.0, 1.0)
            v < lo && (lo = v); v > hi && (hi = v)
        end
        s0 > s1 && (lo = 0.0; hi = 0.0)
        dy_hi = clamp(round(Int, (1 - (hi + 1) / 2) * (hdots - 1)), 0, hdots - 1)
        dy_lo = clamp(round(Int, (1 - (lo + 1) / 2) * (hdots - 1)), 0, hdots - 1)
        for dy in min(dy_hi, dy_lo):max(dy_hi, dy_lo)
            TK.set_point!(canvas, dx, dy)
        end
    end
    TK.render(canvas, area, buf)
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

function render!(p::WaveformPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    p.sculpt && _sculpt_pump!(p)              # consomme un rendu prêt
    n = length(p.samples)
    head = if p.sculpt
        "SCULPT · $(p.label) · s vue · j/k knob · Tab voisin · h/l tire · ⏎ joue"
    elseif n == 0
        "WAVE · $(p.label) · (pas d'audio)"
    else
        vm = round(p.view_len / p.sr * 1000; digits = 1)
        tm = round(n / p.sr * 1000; digits = 0)
        "WAVE · $(p.label) · $(vm)ms/$(tm)ms · molette zoom · h/l défile · 0 tout"
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
        ch == 'e' && return _wave_export!(p)
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

# Molette = zoom VERS LE POINTEUR (l'échantillon sous le curseur reste fixe).
function handle_mouse!(p::WaveformPane, evt)
    evt isa TK.MouseEvent || return false
    (x, _, w, _) = p.last_rect
    length(p.samples) == 0 && return false
    f = w <= 1 ? 0.5 : clamp((evt.x - x) / (w - 1), 0.0, 1.0)
    if evt.button === TK.mouse_scroll_up
        _wave_zoom!(p, f, 0.8); return true
    elseif evt.button === TK.mouse_scroll_down
        _wave_zoom!(p, f, 1.25); return true
    end
    return false
end

title(p::WaveformPane) = "wave:$(p.label)"

function on_close!(p::WaveformPane)
    lock(p.lock) do
        p.closed = true
    end
    return nothing
end

function serialize(p::WaveformPane)
    d = Dict{String,Any}("label" => p.label, "sculpt" => p.sculpt)
    p.genome !== nothing && (d["genome"] = serialize_genome(p.genome))
    return d
end

_kind_for(::WaveformPane) = "waveform"

register_pane_kind!(:waveform, _waveform_pane_ctor)
