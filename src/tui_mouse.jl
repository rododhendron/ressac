# Mouse wheel value tweaking. Hover over a numeric literal in the buffer,
# scroll the wheel → increment/decrement and auto-re-eval the affected slot.
# Spec sketch: docs/journal/20260522_visual_ux_design.md (out-of-scope note
# elevated into its own mini-feature).

"""
    _handle_mouse!(m, evt)

Crossterm mouse event router. We act on `ScrollUp` / `ScrollDown` only,
and only when the event lands inside the editor pane in normal / insert
mode. Modifiers scale the step: Shift ×10, Alt ×0.1.
"""
function _handle_mouse!(m::LiveModel, evt)
    kind = evt.kind
    (kind == "ScrollUp" || kind == "ScrollDown") || return
    m.mode in (:normal, :insert) || return
    m.editor_screen_height > 0 || return

    # Crossterm gives 0-based (col, row); buffer is 1-based.
    buffer_row = evt.row - m.editor_screen_top + 1
    1 <= buffer_row <= length(m.buffer) || return
    1 <= buffer_row <= m.editor_screen_height || return

    line = m.buffer[buffer_row]
    isempty(line) && return
    buffer_col = evt.column - m.editor_screen_left + 1

    rng = _find_number_at(line, buffer_col)
    rng === nothing && return
    start_byte, end_byte, literal = rng

    is_float = occursin('.', literal)
    step = is_float ? 0.1 : 1
    if _mouse_has_modifier(evt, "SHIFT")
        step *= 10
    elseif _mouse_has_modifier(evt, "ALT")
        step *= 0.1
    end
    delta = kind == "ScrollUp" ? +step : -step

    new_literal = _bump_literal(literal, delta, is_float)
    m.buffer[buffer_row] = line[1:prevind(line, start_byte)] *
                           new_literal *
                           (end_byte >= lastindex(line) ? "" :
                            line[nextind(line, end_byte):end])

    # Auto re-eval: move the cursor to the affected row, eval the block,
    # restore cursor. _eval_block! uses m.cursor_row to find the paragraph.
    old_row = m.cursor_row
    old_col = m.cursor_col
    m.cursor_row = buffer_row
    try
        _eval_block!(m; mode=:immediate, n=0)
    finally
        m.cursor_row = old_row
        m.cursor_col = old_col
    end
end

"""
    _find_number_at(line, col) -> Union{Nothing, NTuple{3,Any}}

Scan `line` for a numeric literal (`-?\\d+(?:\\.\\d+)?`) overlapping
`col`. Returns `(start_byte, end_byte, literal::String)` or `nothing`.
"""
function _find_number_at(line::AbstractString, col::Integer)
    for m in eachmatch(r"-?\d+(?:\.\d+)?", line)
        s = m.offset
        e = m.offset + ncodeunits(m.match) - 1
        if s <= col <= e
            return (s, e, String(m.match))
        end
    end
    return nothing
end

"""
    _bump_literal(literal, delta, is_float) -> String

Add `delta` to the parsed value of `literal` and re-format. For floats,
preserve the decimal count of the original literal (`0.5` + 0.1 = `0.6`,
`0.50` + 0.1 = `0.60`). For integers, round to an integer and round
back when the increment is fractional (Alt-wheel on an int).
"""
function _bump_literal(literal::AbstractString, delta::Real, is_float::Bool)
    if is_float
        v = parse(Float64, literal)
        new = v + delta
        # Preserve decimal precision of the input.
        dot = findfirst('.', String(literal))
        decimals = dot === nothing ? 1 : ncodeunits(literal) - dot
        return string(round(new; digits=decimals))
    else
        v = parse(Int, literal)
        new = v + delta
        # Alt-wheel on an int gives a fractional delta; round and emit as
        # an integer to keep the literal int-shaped.
        return string(round(Int, new))
    end
end

function _mouse_has_modifier(evt, name::AbstractString)
    target = lowercase(name)
    for m in evt.modifiers
        lowercase(String(m)) == target && return true
    end
    return false
end
