const _IS_COMMENTED_RX = r"^\s*#"

_is_commented(line) = match(_IS_COMMENTED_RX, line) !== nothing

"""
    _run_search!(m, rx::Regex; dir=:forward)

Move the cursor to the next/previous row matching `rx` (skipping
commented lines). On success, set `m.last_search` and
`m.last_search_dir`. Wraps if nothing found in the primary direction.
On total miss, logs `[INFO] no match` and leaves the cursor put.
"""
function _run_search!(m::LiveModel, rx::Regex; dir::Symbol = :forward)
    n = length(m.buffer)
    n == 0 && return

    matches(row) = !_is_commented(m.buffer[row]) && match(rx, m.buffer[row]) !== nothing

    if dir === :forward
        # Search from (cursor_row + 1) … n, then wrap 1 … cursor_row.
        for row in (m.cursor_row + 1):n
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
        for row in 1:m.cursor_row
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
    else  # :backward
        for row in (m.cursor_row - 1):-1:1
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
        for row in n:-1:m.cursor_row
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
    end
    _push_log!(m, "[INFO] no match for /$(rx.pattern)/")
end

"""
    _repeat_search!(m; reverse=false)

Re-run `m.last_search` in the stored direction (or reversed). No-op if
`last_search` is `nothing`.
"""
function _repeat_search!(m::LiveModel; reverse::Bool = false)
    m.last_search === nothing && return
    dir = m.last_search_dir
    if reverse
        dir = dir === :forward ? :backward : :forward
    end
    _run_search!(m, m.last_search; dir=dir)
end

"""
    _goto_slot!(m, n::Int)

Build the slot regex for `dN` and run a backward search (we want the
latest def). On failure, log and bail.
"""
function _goto_slot!(m::LiveModel, n::Int)
    1 <= n <= 64 || (_push_log!(m, "[ERROR] slot d$n out of range (1..64)"); return)
    rx = Regex("^\\s*@d$n\\b")
    if !any(row -> !_is_commented(m.buffer[row]) && match(rx, m.buffer[row]) !== nothing,
            1:length(m.buffer))
        _push_log!(m, "[INFO] no def for d$n")
        return
    end
    _run_search!(m, rx; dir=:backward)
end
