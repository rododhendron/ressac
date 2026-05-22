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
    # SP10-A — undo/redo history. Each entry is a (buffer, row, col) snapshot.
    history::Vector{Tuple{Vector{String},Int,Int}}       = []
    redo_stack::Vector{Tuple{Vector{String},Int,Int}}    = []
    # SP10-C — live mute / solo: stash unset patterns so :unmute can
    # restore them; track solo set so :unsolo knows what to bring back.
    muted_patterns::Dict{Symbol,Pattern}                 = Dict{Symbol,Pattern}()
    solo_active::Set{Symbol}                             = Set{Symbol}()
end

const _UNDO_HISTORY_LIMIT = 200

"""
    _snapshot!(m)

Push the current buffer + cursor onto the undo stack and clear the
redo stack (any pending redo becomes invalid once a new mutation
happens). Coalesces identical consecutive snapshots so simple cursor
moves don't pollute the stack.
"""
function _snapshot!(m::LiveModel)
    snap = (copy(m.buffer), m.cursor_row, m.cursor_col)
    if isempty(m.history) || m.history[end] != snap
        push!(m.history, snap)
        length(m.history) > _UNDO_HISTORY_LIMIT && popfirst!(m.history)
        empty!(m.redo_stack)
    end
end

"""
    _undo!(m)

Pop the most recent snapshot off the undo stack and restore the
buffer/cursor. The state being replaced lands on the redo stack so
`Ctrl-r` can put it back.
"""
function _undo!(m::LiveModel)
    isempty(m.history) && return false
    snap = pop!(m.history)
    push!(m.redo_stack, (copy(m.buffer), m.cursor_row, m.cursor_col))
    m.buffer     = snap[1]
    m.cursor_row = clamp(snap[2], 1, length(snap[1]))
    m.cursor_col = clamp(snap[3], 1, lastindex(snap[1][m.cursor_row]) + 1)
    return true
end

function _redo!(m::LiveModel)
    isempty(m.redo_stack) && return false
    snap = pop!(m.redo_stack)
    push!(m.history, (copy(m.buffer), m.cursor_row, m.cursor_col))
    m.buffer     = snap[1]
    m.cursor_row = clamp(snap[2], 1, length(snap[1]))
    m.cursor_col = clamp(snap[3], 1, lastindex(snap[1][m.cursor_row]) + 1)
    return true
end

function _push_log!(m::LiveModel, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > _MAX_LOGS && popfirst!(m.logs)
end
