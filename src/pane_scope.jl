# src/pane_scope.jl
# :scope pane — visualizes a data stream coming from SC via
# /ressac/scope/*. Subtype is dynamic state (:wave, :amp, :spectrum,
# :reservoir-graph, etc.). on_close! unsubscribes from the OSC feed
# when no other scope pane is consuming the same subtype.

mutable struct ScopePane <: PaneImpl
    subtype::Symbol
end

function _scope_pane_ctor(args::AbstractDict)
    target = String(get(args, "target", "wave"))
    return ScopePane(Symbol(target))
end

function render!(p::ScopePane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    _render_pane_block_simple!(rect, "SCOPE · $(p.subtype)", buf)
    inner = _inner_rect_simple(rect)
    (inner.width < 1 || inner.height < 1) && return
    _render_scope_subtype!(p.subtype, inner, buf)
    return nothing
end

handle_key!(::ScopePane, evt) = false

title(p::ScopePane) = "scope:$(p.subtype)"

# Per-subtype dispatch — extracted from tui_app's legacy
# `_render_app_scope` body. The reservoir variants read the attached
# reservoir + span from the module-level `_APP_SCOPE_*` singletons, so
# they render here without an app handle just like the OSC-fed scopes.
function _render_scope_subtype!(subtype::Symbol, area::TK.Rect, buf::TK.Buffer)
    data = _APP_SCOPE_DATA[]
    if subtype === :reservoir
        _app_render_reservoir(area, buf)
        return
    elseif subtype === Symbol("reservoir-graph")
        _app_render_reservoir_graph(area, buf)
        return
    end
    if isempty(data)
        TK.set_string!(buf, area.x, area.y,
                       "  (waiting for audio — press T to test the synth)",
                       TK.tstyle(:text_dim))
        return
    end
    if subtype === :amp
        _app_render_amp(data, area, buf)
    elseif subtype === :wave
        _app_render_wave(data, area, buf)
    elseif subtype === :spectrum
        _app_render_spectrum(data, area, buf)
    elseif subtype === :xy
        _app_render_xy(data, area, buf; rotate45 = false)
    elseif subtype === :goni
        _app_render_xy(data, area, buf; rotate45 = true)
    elseif subtype === :spectrogram
        _app_render_spectrogram(area, buf)
    elseif subtype === :peak
        _app_render_peak(data, area, buf)
    elseif subtype === :pitch
        _app_render_pitch(data, area, buf)
    elseif subtype === :onset
        _app_render_onset(data, area, buf)
    elseif subtype === :hist
        _app_render_hist(data, area, buf)
    elseif subtype === :corr
        _app_render_corr(data, area, buf)
    end
    return nothing
end

serialize(p::ScopePane) = Dict{String,Any}("subtype" => String(p.subtype))

# on_close! placeholder — Task 8 wires in /ressac/scope cleanup.
on_close!(::ScopePane) = nothing

register_pane_kind!(:scope, _scope_pane_ctor)
