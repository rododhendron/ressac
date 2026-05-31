# src/command_line.jl
# Autonomous command + search bar — owns the ':cmd' / '/query' UI.
# Lives at the app level, completely independent of any TK.CodeEditor.
# Renders as a single chrome row at the bottom of the screen and,
# while a Tab cycle is active, an optional completion picker that
# replaces the log tail.
#
# Activated by '/' (search) or ':' (command) intercepted at the top
# of the key dispatcher, BEFORE any pane sees the key.

mutable struct CommandLine
    mode::Symbol                         # :idle | :command | :search
    buffer::Vector{Char}
    cursor::Int                          # 1-based insertion point; 1 = before first char
    history::Vector{String}              # most-recent last
    history_cap::Int
    history_idx::Int                     # 0 = inactive ; 1..N = walking back
    completion_candidates::Vector{String}
    completion_idx::Int                  # 0 = inactive ; 1..N = cycle position
    completion_label::String             # e.g. "verb" — used to inform render
    last_dispatched::String              # the last command that fired (empty otherwise)
    last_dispatched_mode::Symbol         # :command | :search | :none
end

CommandLine(; history_cap::Int = 200) =
    CommandLine(:idle, Char[], 1, String[], history_cap, 0,
                String[], 0, "", "", :none)

# ── Lifecycle ──────────────────────────────────────────────────────

is_active(cl::CommandLine) = cl.mode !== :idle

function enter!(cl::CommandLine, mode::Symbol)
    mode in (:command, :search) ||
        throw(ArgumentError("CommandLine.enter!: mode must be :command or :search, got :$mode"))
    cl.mode = mode
    empty!(cl.buffer)
    cl.cursor = 1
    cl.history_idx = 0
    empty!(cl.completion_candidates)
    cl.completion_idx = 0
    cl.completion_label = ""
    cl.last_dispatched = ""
    return nothing
end

function cancel!(cl::CommandLine)
    cl.mode = :idle
    empty!(cl.buffer)
    cl.cursor = 1
    cl.history_idx = 0
    empty!(cl.completion_candidates)
    cl.completion_idx = 0
    cl.last_dispatched = ""
    cl.last_dispatched_mode = :none
    return nothing
end

current_text(cl::CommandLine) = String(cl.buffer)

# ── Key dispatch ───────────────────────────────────────────────────
#
# `handle_key!` returns one of three symbols:
#   :consumed    — key was handled; nothing else to do
#   :dispatched  — Enter pressed; `cl.last_dispatched` holds the cmd string
#                  and CommandLine is back in :idle. Caller runs the command.
#   :ignored     — key was not recognized; CommandLine stayed in current mode
#                  but the caller may want to do something else (rare).
#
# `complete_fn` is called with the current buffer text and should return a
# Vector{String} of candidate completions. Called once per Tab cycle; the
# result is cached in cl.completion_candidates until a non-Tab edit resets.

function handle_key!(cl::CommandLine, evt::TK.KeyEvent;
                     complete_fn::Function = (_)-> String[])
    is_active(cl) || return :ignored
    evt.action === TK.key_release && return :consumed

    if evt.key === :escape
        cancel!(cl)
        return :consumed
    elseif evt.key === :enter
        cmd = String(cl.buffer)
        mode_before = cl.mode
        push_history!(cl, cmd)
        cancel!(cl)
        # cancel!() resets last_dispatched fields — re-set them after.
        cl.last_dispatched = cmd
        cl.last_dispatched_mode = mode_before
        return :dispatched
    elseif evt.key === :backspace
        if cl.cursor > 1
            deleteat!(cl.buffer, cl.cursor - 1)
            cl.cursor -= 1
        elseif isempty(cl.buffer)
            # Backspace on an empty buffer cancels.
            cancel!(cl)
        end
        _reset_completion!(cl)
        cl.history_idx = 0
        return :consumed
    elseif evt.key === :left
        cl.cursor = max(1, cl.cursor - 1)
        return :consumed
    elseif evt.key === :right
        cl.cursor = min(length(cl.buffer) + 1, cl.cursor + 1)
        return :consumed
    elseif evt.key === :home
        cl.cursor = 1
        return :consumed
    elseif evt.key === :end
        cl.cursor = length(cl.buffer) + 1
        return :consumed
    elseif evt.key === :up
        _history_back!(cl)
        return :consumed
    elseif evt.key === :down
        _history_forward!(cl)
        return :consumed
    elseif evt.key === :tab
        _completion_step!(cl, complete_fn)
        return :consumed
    elseif evt.key === :char && evt.char != '\0'
        # Any printable char inserts at the cursor and resets the
        # completion cycle (so the next Tab rebuilds candidates from
        # the updated prefix).
        insert!(cl.buffer, cl.cursor, evt.char)
        cl.cursor += 1
        _reset_completion!(cl)
        cl.history_idx = 0
        return :consumed
    end
    # Modifier-only events (e.g. Shift alone) or unknown keys — eat
    # them so they don't leak into editor input.
    return :consumed
end

# ── History ────────────────────────────────────────────────────────

function push_history!(cl::CommandLine, cmd::AbstractString)
    s = String(strip(cmd))
    isempty(s) && return
    if isempty(cl.history) || last(cl.history) != s
        push!(cl.history, s)
        while length(cl.history) > cl.history_cap
            popfirst!(cl.history)
        end
    end
end

function _history_back!(cl::CommandLine)
    n = length(cl.history)
    n == 0 && return
    cl.history_idx = clamp(cl.history_idx + 1, 1, n)
    _replace_buffer!(cl, cl.history[end - cl.history_idx + 1])
end

function _history_forward!(cl::CommandLine)
    if cl.history_idx <= 1
        cl.history_idx = 0
        _replace_buffer!(cl, "")
    else
        cl.history_idx -= 1
        cl.history_idx > 0 || return
        _replace_buffer!(cl, cl.history[end - cl.history_idx + 1])
    end
end

function _replace_buffer!(cl::CommandLine, s::AbstractString)
    empty!(cl.buffer)
    for c in s
        push!(cl.buffer, c)
    end
    cl.cursor = length(cl.buffer) + 1
    _reset_completion!(cl)
end

# ── Completion ─────────────────────────────────────────────────────

function _completion_step!(cl::CommandLine, complete_fn::Function)
    if isempty(cl.completion_candidates)
        candidates = complete_fn(String(cl.buffer))
        isempty(candidates) && return
        cl.completion_candidates = candidates
        cl.completion_idx = 1
    else
        cl.completion_idx = mod1(cl.completion_idx + 1,
                                  length(cl.completion_candidates))
    end
    _set_buffer_keep_completion!(cl, cl.completion_candidates[cl.completion_idx])
end

# Like _replace_buffer! but preserves completion state so successive
# Tab presses cycle through the same candidate list. _replace_buffer!
# resets completion (good for arrow keys / history nav, bad for Tab).
function _set_buffer_keep_completion!(cl::CommandLine, s::AbstractString)
    empty!(cl.buffer)
    for c in s
        push!(cl.buffer, c)
    end
    cl.cursor = length(cl.buffer) + 1
end

function _reset_completion!(cl::CommandLine)
    empty!(cl.completion_candidates)
    cl.completion_idx = 0
end

completion_active(cl::CommandLine) =
    cl.completion_idx > 0 && !isempty(cl.completion_candidates)

# ── Render ─────────────────────────────────────────────────────────

"""
    render_bar!(cl, area, buf)

Draw the one-line command/search bar into `area` (a single row).
Pattern: `:<text>▎` for command mode, `/<text>▎` for search, where
`▎` is the cursor block placed at `cl.cursor`. Idle mode renders
nothing — the caller decides whether to allocate a row at all.
"""
function render_bar!(cl::CommandLine, area::TK.Rect, buf::TK.Buffer)
    is_active(cl) || return
    area.width < 1 && return
    prefix = cl.mode === :search ? '/' : ':'
    bar_style    = TK.tstyle(:warning, bold = true)
    text_style   = TK.tstyle(:text)
    cursor_style = TK.tstyle(:accent, bold = true)
    # Clear the row to a known background — set_string! over-writes
    # in place but doesn't blank existing cells.
    TK.set_string!(buf, area.x, area.y, repeat(' ', area.width), text_style)
    TK.set_string!(buf, area.x, area.y, string(prefix), bar_style)
    text = String(cl.buffer)
    if !isempty(text)
        max_w = area.width - 2   # leave room for prefix + cursor
        shown = max_w >= length(text) ? text : last(text, max_w)
        TK.set_string!(buf, area.x + 1, area.y, shown, text_style)
    end
    # Cursor block — visible in the row after the prefix at the
    # insertion point (clipped to the bar width).
    cursor_x = min(area.x + 1 + (cl.cursor - 1), area.x + area.width - 1)
    TK.set_string!(buf, cursor_x, area.y, "▎", cursor_style)
end

"""
    render_picker!(cl, area, buf)

Render the completion picker into `area` (multi-row). Each candidate
gets its own row (truncated to width); the selected one is prefixed
with `▶ ` and styled with `:accent`. No-op if the picker is inactive.
"""
function render_picker!(cl::CommandLine, area::TK.Rect, buf::TK.Buffer)
    completion_active(cl) || return
    area.height < 1 && return
    sel_style = TK.tstyle(:accent, bold = true)
    rest_style = TK.tstyle(:text_dim)
    n = length(cl.completion_candidates)
    # Auto-scroll: keep selected within the visible window.
    visible = area.height
    first_i = max(1, min(cl.completion_idx - visible ÷ 2,
                          n - visible + 1))
    first_i = max(1, first_i)
    last_i = min(n, first_i + visible - 1)
    for (offset, i) in enumerate(first_i:last_i)
        y = area.y + offset - 1
        y >= area.y + area.height && break
        prefix = i == cl.completion_idx ? "▶ " : "  "
        text = prefix * cl.completion_candidates[i]
        chunk = first(text, area.width)
        style = i == cl.completion_idx ? sel_style : rest_style
        TK.set_string!(buf, area.x, y, rpad(chunk, area.width), style)
    end
end
