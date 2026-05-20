# v2 LiveModel — backing struct for the multi-line modal TUI.
# Spec: docs/journal/20260519_multiline_tui_design.md §4.1.
#
# This file is intentionally NOT included by src/Ressac.jl yet — the v1
# `LiveModel` in src/tui.jl is still active. Task F1 will swap things
# over and at that point this file will be included.

"""
    LiveModel

Backing model for the multi-line TUI. See
`docs/journal/20260519_multiline_tui_design.md` §4.1.
"""
@kwdef mutable struct LiveModel <: TUI.Model
    scheduler::Scheduler
    buffer::Vector{String}        = [""]
    cursor_row::Int               = 1
    cursor_col::Int               = 1
    mode::Symbol                  = :insert   # :insert | :normal | :visual_line | :command
    count_prefix::Int             = 0
    pending_chord::Symbol         = :none     # :g | :gd | :d | :y
    chord_digits::String          = ""
    last_eval_block::Dict{Symbol,NTuple{2,Int}} = Dict{Symbol,NTuple{2,Int}}()
    last_search::Union{Nothing,Regex}            = nothing
    last_search_dir::Symbol       = :forward
    yank::Vector{String}          = String[]
    visual_anchor::Union{Nothing,NTuple{2,Int}}   = nothing
    command_prefix::Char          = ' '
    command_buffer::String        = ""
    logs::Vector{String}          = String[]
    quit::Bool                    = false
end

const _MAX_LOGS = 200

function _push_log!(m::LiveModel, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > _MAX_LOGS && popfirst!(m.logs)
end
