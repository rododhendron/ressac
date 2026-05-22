# v2 LiveModel — backing struct for the multi-line modal TUI.
# Spec: docs/journal/20260519_multiline_tui_design.md §4.1.

using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

const _MAX_LOGS = 200

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
    mode::Symbol                  = :insert   # :insert | :normal | :visual_line | :command | :guide
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
    # SP6 — visual UX:
    show_help::Bool               = false
    guide_scroll::Int             = 0
    guide_search_active::Bool     = false
    completions::Vector{String}   = String[]
    completion_cycle_idx::Int     = 0
    completion_target_range::Union{Nothing,NTuple{2,Int}} = nothing
    # SP7 — mouse wheel value tweaking: filled by `_EditorPane` at render
    # time so mouse events can map terminal cells back to buffer positions.
    editor_screen_top::Int        = 0
    editor_screen_left::Int       = 0
    editor_screen_height::Int     = 0
    # SP8 — browser modal: live picker over instruments + samples + synths
    # with fuzzy filter and preview-on-highlight.
    browser_query::String         = ""
    browser_cursor::Int           = 1
    browser_scroll::Int           = 0
    browser_filter::Symbol        = :all   # :all | :instruments | :samples | :synths
    browser_last_preview::Float64 = 0.0
end

function _push_log!(m::LiveModel, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > _MAX_LOGS && popfirst!(m.logs)
end
