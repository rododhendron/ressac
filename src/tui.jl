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
    unset!(slot::Symbol)

Remove the pattern at `slot` in the active live scheduler. The other slots
keep playing.
"""
unset!(slot::Symbol) = unset_pattern!(_check_live(), slot)

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

@kwdef mutable struct LiveModelV1 <: TUI.Model
    scheduler::Scheduler
    input::String = ""
    history::Vector{String} = String[]   # rolling list of "> expr ⇒ result"
    logs::Vector{String} = String[]      # rolling list of log lines
    quit::Bool = false
end

const _MAX_HISTORY = 200
const _MAX_LOGS    = 200

function _push_history!(m::LiveModelV1, line::AbstractString)
    push!(m.history, String(line))
    length(m.history) > _MAX_HISTORY && popfirst!(m.history)
end

function _push_log!(m::LiveModelV1, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > _MAX_LOGS && popfirst!(m.logs)
end

# ---------------------------------------------------------------------------
# Eval
# ---------------------------------------------------------------------------

function _eval_input!(m::LiveModelV1)
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

function TUI.init!(m::LiveModelV1, ::TUI.TerminalBackend)
    _push_log!(m, "[INFO] Ressac live — Ctrl+H hush, Ctrl+Q quit")
end

function TUI.update!(m::LiveModelV1, evt::TUI.KeyEvent)
    # We only act on Press events; ignore Release/Repeat.
    evt.data.kind == "Press" || return

    code  = TUI.keycode(evt)
    mods  = TUI.keymodifier(evt)
    ctrl  = _has_ctrl(mods)

    # Debug trail so we can see what actually arrives — useful while ironing
    # out the Crossterm modifier conventions on a given terminal. Remove once
    # bindings feel stable.
    _push_log!(m, "[KEY] code=$(repr(code)) mods=$(mods) ctrl=$(ctrl)")

    if code == "Esc"
        m.quit = true
    elseif ctrl && (code == "c" || code == "C" || code == "q" || code == "Q")
        m.quit = true
    elseif ctrl && (code == "h" || code == "H")
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

# Crossterm's serialised modifier names vary by version/platform — be
# permissive: accept any string whose lowercase form contains "ctrl" or
# "control".
function _has_ctrl(mods)
    for m in mods
        s = lowercase(String(m))
        (occursin("ctrl", s) || occursin("control", s)) && return true
    end
    return false
end

# ---------------------------------------------------------------------------
# View
# ---------------------------------------------------------------------------

function TUI.view(m::LiveModelV1)
    status_text  = _status_line(m)
    history_text = isempty(m.history) ? "(no evaluations yet)" : join(last(m.history, 30), "\n")
    logs_text    = isempty(m.logs)    ? "(no logs yet)"        : join(last(m.logs, 10),     "\n")
    prompt_text  = "> " * m.input * "▌"

    status  = _zone("Ressac",  status_text,  TUI.Crayon(; bold = true))
    history = _zone("History", history_text, TUI.Crayon())
    prompt  = _zone("Input",   prompt_text,  TUI.Crayon(; foreground = :green))
    logs    = _zone("Logs",    logs_text,    TUI.Crayon(; foreground = :blue))

    TUI.Layout(;
        widgets = [status, history, prompt, logs],
        constraints = [TUI.Min(3), TUI.Percent(50), TUI.Min(3), TUI.Min(8)],
        orientation = :vertical,
    )
end

# Build a titled Paragraph from free-form text. `TUI.Paragraph` requires the
# `words` vector to align 1-to-1 with whitespace-split tokens of the joined
# text (it re-splits internally and indexes into `words` per token), so we
# pre-split via `make_words`. An empty zone gets a single blank word so the
# renderer has at least one element to index.
function _zone(title::AbstractString, text::AbstractString, style)
    words = TUI.make_words(text, style)
    isempty(words) && push!(words, TUI.Word(" ", style))
    return TUI.Paragraph(TUI.Block(; title = String(title)), words, 1, Ref{Int}(0))
end

function _status_line(m::LiveModelV1)
    s = m.scheduler
    slots = isempty(s.patterns) ? "—" : join(string.(keys(s.patterns)), ",")
    cycle_now = s.t_start == 0.0 ? 0.0 : (time() - s.t_start) * s.cps
    return "cps:$(round(s.cps; digits=3))  cycle:$(round(cycle_now; digits=2))  slots:$slots"
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

"""
    start_live!(; host="127.0.0.1", port=57120, cps=0.5, lookahead=0.05) -> Scheduler

Start a live scheduler without a TUI: build a `Scheduler`, install it as the
active scheduler for [`d!`](@ref) / [`hush_all!`](@ref) / [`cps!`](@ref), start
its background loop, and return it. Call [`stop_live!`](@ref) to tear down.

Use this from a plain Julia REPL to drive Ressac without the TUI in the way —
useful for debugging and exploration.
"""
function start_live!(; host::AbstractString = "127.0.0.1",
                       port::Integer = 57120,
                       cps::Real = 0.5,
                       lookahead::Real = 0.05)
    if _LIVE_SCHEDULER[] !== nothing
        @warn "A live session is already running — returning the existing scheduler. \
               Call stop_live!() first if you want a fresh one."
        return _LIVE_SCHEDULER[]
    end
    client = OSCClient(host, port)
    sched = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    return sched
end

"""
    stop_live!()

Stop the active live scheduler started by [`start_live!`](@ref) (or [`live`](@ref)):
halt the loop, hush all patterns, and clear the module-level reference.
"""
function stop_live!()
    s = _LIVE_SCHEDULER[]
    if s !== nothing
        stop!(s)
        hush!(s)
        _LIVE_SCHEDULER[] = nothing
    end
    return nothing
end

"""
    restart_live!(; host="127.0.0.1", port=57120, cps=0.5, lookahead=0.05) -> Scheduler

Tear down the current live session (if any) and start a fresh one with the
given options. Equivalent to `stop_live!(); start_live!(; ...)`.
"""
function restart_live!(; kwargs...)
    stop_live!()
    return start_live!(; kwargs...)
end

"""
    live(; host="127.0.0.1", port=57120, cps=0.5, lookahead=0.05)

Start a live coding session: build a `Scheduler` (via [`start_live!`](@ref))
and launch the TUI on top of it. Returns after the user quits (Esc, Ctrl+Q,
or Ctrl+C in the TUI).

If a scheduler is already running (e.g. via [`start_live!`](@ref)), the TUI
attaches to it and leaves it running on exit. Otherwise the scheduler is
created here and torn down when the TUI closes.
"""
function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    existed = _LIVE_SCHEDULER[] !== nothing
    sched = existed ? _LIVE_SCHEDULER[] : start_live!(; host, port, cps, lookahead)
    try
        TUI.app(LiveModelV1(; scheduler = sched))
    finally
        existed || stop_live!()
    end
    return nothing
end
