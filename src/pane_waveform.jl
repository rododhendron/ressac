# src/pane_waveform.jl
# :waveform — l'onde COMPLÈTE d'un son (rendu hors-ligne par sclang),
# navigable : la molette zoome VERS LE POINTEUR, h / l défilent, 0 montre
# tout. Tracé min/max par colonne, fidèle à n'importe quel zoom. La source
# est un génome, re-rendu à la demande.
#
# (Le studio « sculpt » qui vivait ici — knobs, quartiers, édition du graphe
# — a laissé la place à l'atelier : le texte du son est son graphe, et on y
# travaille avec les gestes de vim. Voir atelier.jl.)

mutable struct WaveformPane <: PaneImpl
    samples::Vector{Float32}
    sr::Int
    view_start::Int                 # 1er échantillon visible (1-based)
    view_len::Int                   # nb d'échantillons visibles
    label::String
    genome::Union{Nothing,Genome}   # la source (re-rendu / persistance)
    last_rect::NTuple{4,Int}        # (x, y, w, h) de la zone de tracé, pour la souris
    audition::AuditionState
end

WaveformPane(samples, sr, vs, vl, label, genome, last_rect) =
    WaveformPane(samples, sr, vs, vl, label, genome, last_rect, AuditionState(1))

# Seam de rendu : par défaut le rendu hors-ligne, surchargeable en test.
const _WAVE_RENDER = Ref{Function}(render_genome_audio)
# En test, ce qui se mesure en fond (l'impact des nœuds) se fait sur place.
const _WAVE_SYNC = Ref{Bool}(false)

function _waveform_pane_ctor(args::AbstractDict)
    label = String(get(args, "label", "waveform"))
    samples = Float32[]; sr = 44100; g = nothing
    if haskey(args, "genome")
        try
            g = deserialize_genome(args["genome"])
            samples, sr = _WAVE_RENDER[](g)
        catch
            samples = Float32[]
        end
    end
    return WaveformPane(samples, sr, 1, max(length(samples), 1), label, g, (0, 0, 0, 0))
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

# p : joue le son courant sur le serveur SC live (si une session tourne).
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

function render!(p::WaveformPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    n = length(p.samples)
    head = if n == 0
        "ONDE · $(p.label) · (pas d'audio)"
    else
        vm = round(p.view_len / p.sr * 1000; digits = 1)
        tm = round(n / p.sr * 1000; digits = 0)
        "ONDE · $(p.label) · $(vm)ms/$(tm)ms"
    end
    _render_pane_block_simple!(rect, head, buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 2 || inner.height < 1) && return
    p.last_rect = (inner.x, inner.y, inner.width, inner.height)
    if n == 0
        TK.set_string!(buf, inner.x, inner.y, "  (pas d'audio — rendu hors-ligne indisponible)", TK.tstyle(:text_dim))
        return
    end
    _render_wave_buffer!(p, inner, buf)
    return
end

handle_key!(p::WaveformPane, evt) = evt isa TK.KeyEvent && dispatch!(((:waveform, p),), evt)

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
pane_scope(::WaveformPane) = :waveform

function serialize(p::WaveformPane)
    d = Dict{String,Any}("label" => p.label)
    p.genome !== nothing && (d["genome"] = serialize_genome(p.genome))
    return d
end

_kind_for(::WaveformPane) = "waveform"

register_pane_kind!(:waveform, _waveform_pane_ctor)

_wv_has(p::WaveformPane) = !isempty(p.samples)

scope!(:waveform, "Vue d'onde"; layer = :pane, modes = (:design, :explore))
bind!(:waveform, ["l", "→"], "défiler →"; group = :nav, when = _wv_has, repeat = true,
      action = p -> _wave_pan!(p, p.view_len ÷ 8))
bind!(:waveform, ["h", "←"], "défiler ←"; group = :nav, when = _wv_has, repeat = true,
      action = p -> _wave_pan!(p, -(p.view_len ÷ 8)))
bind!(:waveform, ["+", "i"], "zoom +"; group = :view, when = _wv_has, repeat = true,
      action = p -> _wave_zoom!(p, 0.5, 0.8))
bind!(:waveform, ["-", "o"], "zoom −"; group = :view, when = _wv_has, repeat = true,
      action = p -> _wave_zoom!(p, 0.5, 1.25))
bind!(:waveform, "0", "toute l'onde"; group = :view, when = _wv_has,
      action = p -> (p.view_start = 1; p.view_len = length(p.samples)))
bind!(:waveform, "p", "jouer ce son"; short = "jouer", group = :audio, repeat = true, action = p -> _wave_play!(p))
bind!(:waveform, "e", "ouvrir ce son dans l'éditeur"; short = "éditeur", group = :file, action = p -> _wave_export!(p))
