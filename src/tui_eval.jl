"""
    _block_text(m) -> String

Join the paragraph at the cursor into one expression string, separated
by `\\n`. Returns empty if the cursor is on a blank row.
"""
function _block_text(m::LiveModel)
    start, stop = _paragraph_bounds(m)
    stop < start && return ""
    return join(m.buffer[start:stop], "\n")
end

"""
    _block_slot(text) -> Union{Symbol,Nothing}

Recognise a `@dN <body>` opener inside `text` and return `:dN`, or
`nothing` if no such macro is at the start.
"""
function _block_slot(text::AbstractString)
    m = match(r"^\s*@(d\d+)\b", text)
    m === nothing && return nothing
    return Symbol(m.captures[1])
end

"""
    _eval_block!(m; mode::Symbol = :immediate, n::Int = 0)

Evaluate the paragraph at the cursor. `mode` is one of `:immediate` or
`:deferred`; `n` is the +N cycle offset for deferred. Records the slot
target (if any) into `m.last_eval_block`. Errors are appended to
`m.logs`, never re-thrown.
"""
function _eval_block!(m::LiveModel; mode::Symbol = :immediate, n::Int = 0)
    text = _block_text(m)
    isempty(strip(text)) && return
    start, stop = _paragraph_bounds(m)
    slot = _block_slot(text)
    try
        ex = Meta.parse(text)
        prev_mode = _EVAL_MODE[]
        _EVAL_MODE[] = (mode, n)
        try
            Core.eval(Main, ex)
        finally
            _EVAL_MODE[] = prev_mode
        end
        slot === nothing || (m.last_eval_block[slot] = (start, stop))
        _push_log!(m, mode === :immediate ?
            "[INFO] eval $(slot === nothing ? "block" : String(slot))" :
            "[INFO] queued $(slot === nothing ? "block" : String(slot)) → +$n cycles")
    catch err
        _push_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end
