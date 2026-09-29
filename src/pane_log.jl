# src/pane_log.jl
# :log pane — renders the rolling app log.
#
# `_APP_LOG[]` is a module-level Ref pointing at the live log vector.
# `_ensure_default_workspace!` rebinds it to `m.logs` so the LogPane
# and the global chrome log row share the same underlying storage.
#
# Les deux vues (pane et bandeau du bas) passent par `_log_spans` pour la
# couleur des niveaux et par un `ScrollPane` qui suit le bas tant qu'on
# n'a pas remonté dans l'historique.

const _APP_LOG = Ref{Vector{String}}(String[])

mutable struct LogPane <: PaneImpl
    pane::TK.ScrollPane
end

LogPane() = LogPane(_scrollpane(; following = true))
_log_pane_ctor(::AbstractDict) = LogPane()

"""
    _log_spans(logs) -> Vector{Vector{Span}}

Les lignes du journal, colorées par niveau : ERROR en rouge, WARN en
jaune, KEY en accent, INFO en texte normal. Une bande `▎` à gauche
donne le niveau d'un coup d'œil sans lire le préfixe.
"""
function _log_spans(logs::AbstractVector{<:AbstractString})
    out = Vector{TK.Span}[]
    for line in logs
        stripe, text, body = if startswith(line, "[ERROR]")
            (TK.tstyle(:error, bold = true), TK.tstyle(:error), SubString(line, 8))
        elseif startswith(line, "[WARN]")
            (TK.tstyle(:warning, bold = true), TK.tstyle(:warning), SubString(line, 7))
        elseif startswith(line, "[KEY]")
            (TK.tstyle(:accent, dim = true), TK.tstyle(:accent, dim = true), SubString(line, 6))
        elseif startswith(line, "[INFO]")
            (TK.tstyle(:text_dim), TK.tstyle(:text), SubString(line, 7))
        else
            (TK.tstyle(:text_dim), TK.tstyle(:text_dim), SubString(line, 1))
        end
        push!(out, TK.Span[TK.Span("▎ ", stripe), TK.Span(String(strip(body)), text)])
    end
    return out
end

# Pose le journal courant dans le ScrollPane (avant un rendu ou une touche).
_log_sync!(p::LogPane) = TK.set_content!(p.pane, _log_spans(_APP_LOG[]))

function render!(p::LogPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    _render_pane_block_simple!(rect, "JOURNAL" * (p.pane.following ? "" : " · ↑"), buf)
    inner = _inner_rect_simple(rect)
    (inner.height < 1 || inner.width < 3) && return
    _log_sync!(p)
    TK.render(p.pane, inner, buf)
    return nothing
end

handle_key!(p::LogPane, evt) = evt isa TK.KeyEvent && dispatch!(((:log, p),), evt)
handle_mouse!(p::LogPane, evt::TK.MouseEvent) = (_log_sync!(p); TK.handle_mouse!(p.pane, evt))
pane_scope(::LogPane) = :log
scope!(:log, "Journal")
bind!(:log, ["k", "↑"], "remonter"; group = :nav, repeat = true, when = p -> p.pane.offset > 0,
      action = p -> (_log_sync!(p); _scroll!(p.pane, :up)))
bind!(:log, "PgUp", "remonter d'un écran"; group = :nav, hint = false, repeat = true, when = p -> p.pane.offset > 0,
      action = p -> (_log_sync!(p); _scroll!(p.pane, :pageup)))
bind!(:log, "PgDn", "redescendre d'un écran"; group = :nav, hint = false, repeat = true,
      when = p -> !p.pane.following, action = p -> (_log_sync!(p); _scroll!(p.pane, :pagedown)))
bind!(:log, ["j", "↓"], "descendre"; group = :nav, when = p -> !p.pane.following, repeat = true,
      action = p -> (_log_sync!(p); _scroll!(p.pane, :down)))
bind!(:log, "G", "recoller au bas"; group = :nav, hint = false, when = p -> !p.pane.following,
      action = p -> _scroll_end!(p.pane))

title(::LogPane) = "log"

register_pane_kind!(:log, _log_pane_ctor)
