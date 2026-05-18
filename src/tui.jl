using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

# ---------------------------------------------------------------------------
# Live API
# ---------------------------------------------------------------------------
#
# `d!`, `hush_all!`, `cps!` are the implicit-scheduler entry points users type
# from inside the TUI. They route through a module-level ref that `live()`
# sets up at start time. Calling them with no live session active errors out
# rather than corrupting some default.

const _LIVE_SCHEDULER = Ref{Union{Scheduler,Nothing}}(nothing)

function _check_live()
    s = _LIVE_SCHEDULER[]
    s === nothing && error("No live scheduler — call live() first.")
    return s
end

"""
    d!(slot::Symbol, p::Pattern)

Install `p` at `slot` in the currently active live scheduler.
"""
d!(slot::Symbol, p::Pattern) = set_pattern!(_check_live(), slot, p)

"""
    hush_all!()

Silence every slot in the active live scheduler.
"""
hush_all!() = hush!(_check_live())

"""
    cps!(x::Real)

Update the tempo of the active live scheduler.
"""
cps!(x::Real) = set_cps!(_check_live(), x)

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

@kwdef mutable struct LiveModel <: TUI.Model
    scheduler::Scheduler
    input::String = ""
    history::Vector{String} = String[]   # rolling list of "> expr ⇒ result"
    logs::Vector{String} = String[]      # rolling list of log lines
    quit::Bool = false
end

const _MAX_HISTORY = 200
const _MAX_LOGS    = 200

function _push_history!(m::LiveModel, line::AbstractString)
    push!(m.history, String(line))
    length(m.history) > _MAX_HISTORY && popfirst!(m.history)
end

function _push_log!(m::LiveModel, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > _MAX_LOGS && popfirst!(m.logs)
end

# ---------------------------------------------------------------------------
# Eval
# ---------------------------------------------------------------------------

function _eval_input!(m::LiveModel)
    expr_text = strip(m.input)
    isempty(expr_text) && return
    try
        ex = Meta.parse(expr_text)
        result = Core.eval(Main, ex)
        _push_history!(m, "> $expr_text  ⇒  $(_short(result))")
    catch err
        _push_history!(m, "> $expr_text")
        _push_log!(m, "[ERROR] $(_short(err))")
    end
    m.input = ""
end

_short(x) = sprint(io -> show(IOContext(io, :limit => true, :displaysize => (1, 80)), x))

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

function TUI.init!(m::LiveModel, ::TUI.TerminalBackend)
    _push_log!(m, "[INFO] Ressac live — Ctrl+H hush, Ctrl+Q quit")
end

function TUI.update!(m::LiveModel, evt::TUI.KeyEvent)
    # We only act on Press events; ignore Release/Repeat.
    evt.data.kind == "Press" || return

    code  = TUI.keycode(evt)
    mods  = TUI.keymodifier(evt)
    ctrl  = "Ctrl" ∈ mods

    if ctrl && (code == "c" || code == "q")
        m.quit = true
    elseif ctrl && code == "h"
        try
            hush!(m.scheduler)
            _push_log!(m, "[INFO] hush")
        catch err
            _push_log!(m, "[ERROR] $(_short(err))")
        end
    elseif code == "Enter"
        _eval_input!(m)
    elseif code == "Backspace"
        if !isempty(m.input)
            m.input = m.input[1:prevind(m.input, end)]
        end
    elseif length(code) == 1 && !ctrl
        # Single printable character — append.
        m.input *= code
    end
end

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------

function TUI.view(m::LiveModel)
    status_text  = _status_line(m)
    history_text = isempty(m.history) ? "(no evaluations yet)" : join(last(m.history, 30), "\n")
    logs_text    = isempty(m.logs)    ? "(no logs yet)"        : join(last(m.logs, 10),     "\n")
    prompt_text  = "> " * m.input * "▌"  # ▌ as a cheap cursor

    status_words  = [TUI.Word(status_text,  TUI.Crayon(; bold = true))]
    history_words = [TUI.Word(history_text, TUI.Crayon())]
    logs_words    = [TUI.Word(logs_text,    TUI.Crayon(; foreground = :blue))]
    prompt_words  = [TUI.Word(prompt_text,  TUI.Crayon(; foreground = :green))]

    status  = TUI.Paragraph(TUI.Block(; title = "Ressac"),  status_words,  1, Ref{Int}(0))
    history = TUI.Paragraph(TUI.Block(; title = "History"), history_words, 1, Ref{Int}(0))
    prompt  = TUI.Paragraph(TUI.Block(; title = "Input"),   prompt_words,  1, Ref{Int}(0))
    logs    = TUI.Paragraph(TUI.Block(; title = "Logs"),    logs_words,    1, Ref{Int}(0))

    TUI.Layout(;
        widgets = [status, history, prompt, logs],
        constraints = [TUI.Min(3), TUI.Percent(50), TUI.Min(3), TUI.Min(8)],
        orientation = :vertical,
    )
end

function _status_line(m::LiveModel)
    s = m.scheduler
    slots = isempty(s.patterns) ? "—" : join(string.(keys(s.patterns)), ",")
    cycle_now = s.t_start == 0.0 ? 0.0 : (time() - s.t_start) * s.cps
    return "cps:$(round(s.cps; digits=3))  cycle:$(round(cycle_now; digits=2))  slots:$slots"
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

"""
    live(; host="127.0.0.1", port=57120, cps=0.5, lookahead=0.05)

Start a live coding session: build a `Scheduler` aimed at `host:port`, install
it as the active scheduler for [`d!`](@ref) / [`hush_all!`](@ref) / [`cps!`](@ref),
and launch the TUI. Returns after the user quits (Ctrl+Q or Ctrl+C in the TUI).
"""
function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    client = OSCClient(host, port)
    sched = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    try
        TUI.app(LiveModel(; scheduler = sched))
    finally
        stop!(sched)
        hush!(sched)
        _LIVE_SCHEDULER[] = nothing
    end
    return nothing
end
