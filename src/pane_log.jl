# src/pane_log.jl
# :log pane — renders the global _APP_LOG ring buffer.
# State is global, so serialize returns {}.

mutable struct LogPane <: PaneImpl
    scroll::Int
end

LogPane() = LogPane(0)
_log_pane_ctor(::AbstractDict) = LogPane()

render!(::LogPane, area, buf) = nothing        # wired in Task 8
handle_key!(::LogPane, evt) = false            # wired in Task 8
title(::LogPane) = "log"

register_pane_kind!(:log, _log_pane_ctor)
