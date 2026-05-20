# Pure buffer-mutation helpers. No TUI calls, no scheduler calls — every
# function takes a `LiveModel` and mutates `buffer` / `cursor_row` /
# `cursor_col`. Easy to unit-test without a TTY.

function _insert_char!(m::LiveModel, c::AbstractChar)
    line = m.buffer[m.cursor_row]
    col = m.cursor_col
    if col > lastindex(line) + 1
        col = lastindex(line) + 1
    end
    new_line = if col == 1
        string(c) * line
    elseif col > lastindex(line)
        line * string(c)
    else
        line[1:prevind(line, col)] * string(c) * line[col:end]
    end
    m.buffer[m.cursor_row] = new_line
    m.cursor_col = col + 1
    return nothing
end

function _split_line!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    col = m.cursor_col
    left  = col == 1 ? "" : line[1:prevind(line, col)]
    right = col > lastindex(line) ? "" : line[col:end]
    m.buffer[m.cursor_row] = left
    insert!(m.buffer, m.cursor_row + 1, right)
    m.cursor_row += 1
    m.cursor_col = 1
    return nothing
end

function _backspace!(m::LiveModel)
    if m.cursor_col > 1
        line = m.buffer[m.cursor_row]
        col = m.cursor_col
        new_line = line[1:prevind(line, col - 1)] * (col > lastindex(line) ? "" : line[col:end])
        m.buffer[m.cursor_row] = new_line
        m.cursor_col -= 1
    elseif m.cursor_row > 1
        prev = m.buffer[m.cursor_row - 1]
        cur  = m.buffer[m.cursor_row]
        m.buffer[m.cursor_row - 1] = prev * cur
        deleteat!(m.buffer, m.cursor_row)
        m.cursor_row -= 1
        m.cursor_col = lastindex(prev) + 1
    end
    return nothing
end

function _delete_line!(m::LiveModel)
    deleted = m.buffer[m.cursor_row]
    if length(m.buffer) == 1
        m.buffer[1] = ""
        m.cursor_col = 1
    else
        deleteat!(m.buffer, m.cursor_row)
        m.cursor_row = clamp(m.cursor_row, 1, length(m.buffer))
        m.cursor_col = 1
    end
    return deleted
end

"""
    _paragraph_bounds(m) -> (row_start, row_stop)

Range of contiguous non-blank rows around `cursor_row`. Returns
`(cursor_row, cursor_row - 1)` (empty range) if the cursor is on a
blank row.
"""
function _paragraph_bounds(m::LiveModel)
    is_blank(s) = isempty(strip(s))
    cur = m.cursor_row
    if is_blank(m.buffer[cur])
        return (cur, cur - 1)
    end
    start = cur
    while start > 1 && !is_blank(m.buffer[start - 1])
        start -= 1
    end
    stop = cur
    while stop < length(m.buffer) && !is_blank(m.buffer[stop + 1])
        stop += 1
    end
    return (start, stop)
end
