# src/pane_log.jl
# :log pane — renders the rolling app log.
#
# `_APP_LOG[]` is a module-level Ref pointing at the live log vector.
# `_ensure_default_workspace!` rebinds it to `m.logs` so the LogPane
# and the global chrome log row share the same underlying storage.

const _APP_LOG = Ref{Vector{String}}(String[])

mutable struct LogPane <: PaneImpl
    scroll::Int
end

LogPane() = LogPane(0)
_log_pane_ctor(::AbstractDict) = LogPane()

function render!(p::LogPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    _render_pane_block_simple!(rect, "LOGS", buf)
    inner = _inner_rect_simple(rect)
    inner.height < 1 && return
    log = _APP_LOG[]
    n = length(log)
    n == 0 && return
    end_i = max(1, n - p.scroll)
    start_i = max(1, end_i - inner.height + 1)
    for (offset, i) in enumerate(start_i:end_i)
        screen_y = inner.y + offset - 1
        screen_y >= inner.y + inner.height && break
        line = first(String(log[i]), inner.width)
        TK.set_string!(buf, inner.x, screen_y, line, TK.tstyle(:text))
    end
    return nothing
end

function handle_key!(p::LogPane, evt)
    if evt isa TK.KeyEvent && evt.key === :char
        if evt.char == 'k'
            p.scroll += 1; return true
        elseif evt.char == 'j' && p.scroll > 0
            p.scroll -= 1; return true
        end
    end
    return false
end

title(::LogPane) = "log"

register_pane_kind!(:log, _log_pane_ctor)
