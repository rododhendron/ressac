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
        result = nothing
        prev_mode = _EVAL_MODE[]
        _EVAL_MODE[] = (mode, n)
        try
            result = Core.eval(Main, ex)
        finally
            _EVAL_MODE[] = prev_mode
        end
        slot === nothing || (m.last_eval_block[slot] = (start, stop))
        result_str = sprint(io -> show(IOContext(io, :limit => true, :displaysize => (1, 60)), result))
        _push_log!(m, mode === :immediate ?
            "[INFO] eval $(slot === nothing ? "block" : String(slot)) ⇒ $result_str" :
            "[INFO] queued $(slot === nothing ? "block" : String(slot)) → +$n cycles ⇒ $result_str")
    catch err
        _push_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end

const _ACTIVE_SLOT_RX   = r"^\s*@(d\d+)\b"
const _COMMENTED_SLOT_RX = r"^\s*#+\s*@(d\d+)\b"

"""
    _toggle_mute!(m)

If the current line is an uncommented `@dN ...` def → comment it and
call `unset_pattern!(:dN)`. If the line is a commented slot def →
uncomment it and re-eval the line through `_eval_block!`. Otherwise
log a warning.
"""
function _toggle_mute!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    if (mt = match(_ACTIVE_SLOT_RX, line)) !== nothing
        slot = Symbol(mt.captures[1])
        m.buffer[m.cursor_row] = "# " * line
        sched = _check_live()
        unset_pattern!(sched, slot)
        _push_log!(m, "[INFO] muted $slot")
    elseif match(_COMMENTED_SLOT_RX, line) !== nothing
        m.buffer[m.cursor_row] = replace(line, r"^\s*#+\s*" => ""; count=1)
        _eval_block!(m; mode=:immediate, n=0)
    else
        _push_log!(m, "[WARN] m: not a slot def, no-op")
    end
end
