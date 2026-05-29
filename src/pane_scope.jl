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

render!(::ScopePane, area, buf) = nothing      # wired in Task 8
handle_key!(::ScopePane, evt) = false          # wired in Task 8
title(p::ScopePane) = "scope:$(p.subtype)"

serialize(p::ScopePane) = Dict{String,Any}("subtype" => String(p.subtype))

# on_close! placeholder — Task 8 wires in /ressac/scope cleanup.
on_close!(::ScopePane) = nothing

register_pane_kind!(:scope, _scope_pane_ctor)
