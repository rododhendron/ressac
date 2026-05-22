# Visual UX — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Ressac's TUI more discoverable and faster to type in — permanent mode hint + `?` overlay, fuzzy Tab autocomplete in `:`-mode and insert mode with context detection, modal scrollable `:guide`.

**Architecture:** Two new files (`tui_overlay.jl` for the overlay widget, `tui_hints.jl` for hints + fuzzy match + completions). LiveModel grows fields for completion state and overlay visibility. The top-level view wraps the existing layout in an `_AppView` that renders overlays on top after the main layout draws.

**Tech Stack:** Julia 1.10+, TerminalUserInterfaces.jl, `Test.jl`. No new deps.

**Spec:** `docs/journal/20260522_visual_ux_design.md`

---

## File layout

```
src/
├── tui_overlay.jl    NEW  — _Overlay widget + _overlay_rect + _clip_lines + _AppView
├── tui_hints.jl      NEW  — _MODE_HINTS, _HELP_OVERLAY_LINES, _COMMAND_NAMES,
                              _COMBINATOR_NAMES, _fuzzy_score, _fuzzy_rank,
                              _completion_context, _buffer_candidates,
                              _compute_completions
├── tui_model.jl      MOD  — +show_help, +guide_scroll, +completions,
                              +completion_cycle_idx, +completion_target_range
├── tui_view.jl       MOD  — replace TUI.view with _AppView; add hint+completion lines
├── tui_bindings.jl   MOD  — ? toggle, Tab in :-mode, Tab in insert,
                              :guide mode shift, _handle_guide! handler
└── Ressac.jl         MOD  — include the two new files + precompile workload
test/
├── test_tui_hints.jl     NEW
├── test_tui_overlay.jl   NEW
├── test_tui_bindings.jl  MOD  — extend with ?, Tab, :guide-mode tests
└── runtests.jl           MOD  — wire the new files
docs/
└── cheatsheet.md         MOD  — "Visual UX" section
```

---

### Task 1: LiveModel fields + fuzzy score

**Files:**
- Modify: `src/tui_model.jl`
- Create: `src/tui_hints.jl`
- Create: `test/test_tui_hints.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Wire the new test file**

Edit `test/runtests.jl`, append after the last `include`:

```julia
    include("test_controls.jl")
    include("test_tui_hints.jl")
end
```

- [ ] **Step 2: Write the failing tests for fuzzy score**

Create `test/test_tui_hints.jl`:

```julia
using Test
using Ressac

@testset "tui_hints" begin
    @testset "_fuzzy_score exact prefix is tight" begin
        @test Ressac._fuzzy_score("sa", "samples") == 0
    end

    @testset "_fuzzy_score gap counts" begin
        # 's' at 1, 'a' at 3 in "snares" → 1 gap between them
        @test Ressac._fuzzy_score("sa", "snares") == 1
    end

    @testset "_fuzzy_score no match → nothing" begin
        @test Ressac._fuzzy_score("xy", "samples") === nothing
    end

    @testset "_fuzzy_score empty query → 0" begin
        @test Ressac._fuzzy_score("", "anything") == 0
    end

    @testset "_fuzzy_score case-insensitive" begin
        @test Ressac._fuzzy_score("BD", "bd_kick") == 0
    end
end
```

- [ ] **Step 3: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with `UndefVarError: _fuzzy_score`.

- [ ] **Step 4: Implement the model fields + fuzzy score**

Edit `src/tui_model.jl`. Replace the `@kwdef mutable struct LiveModel` block with the extended version:

```julia
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
    completions::Vector{String}   = String[]
    completion_cycle_idx::Int     = 0
    completion_target_range::Union{Nothing,NTuple{2,Int}} = nothing
end
```

Create `src/tui_hints.jl`:

```julia
# Visual UX support: mode hints, help overlay lines, completion engine.
# Spec: docs/journal/20260522_visual_ux_design.md.

"""
    _fuzzy_score(query, candidate) -> Union{Nothing, Int}

Score how well `candidate` matches `query` as a case-insensitive
subsequence. Lower is tighter. Returns `nothing` if `query` has no
subsequence in `candidate`.

Score = sum of gaps (positions skipped) between consecutive matched
chars. Exact prefix → 0; one-letter gap → 1; etc.
"""
function _fuzzy_score(query::AbstractString, candidate::AbstractString)
    isempty(query) && return 0
    q = lowercase(String(query))
    c = lowercase(String(candidate))
    score = 0
    last_match_pos = 0
    qi = firstindex(q)
    q_end = lastindex(q)
    for (pos, ch) in pairs(c)
        if ch == q[qi]
            if last_match_pos != 0
                # `pos` and `last_match_pos` are byte indices; for ASCII
                # candidates (the common case) they coincide with char
                # positions, which is what we want for "gap" semantics.
                score += (pos - last_match_pos - 1)
            end
            last_match_pos = pos
            qi = nextind(q, qi)
            qi > q_end && return score
        end
    end
    return nothing
end
```

Edit `src/Ressac.jl`, add `include("tui_hints.jl")` between `tui_search.jl` and `tui_bindings.jl`:

```julia
include("tui_search.jl")
include("tui_hints.jl")
include("tui_bindings.jl")
```

- [ ] **Step 5: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (518+ tests).

- [ ] **Step 6: Commit**

```bash
git add src/tui_model.jl src/tui_hints.jl src/Ressac.jl test/test_tui_hints.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
tui_hints: LiveModel fields + _fuzzy_score

Foundations for sub-project 6. LiveModel grows fields for completion
state, help overlay visibility, and guide-mode scroll. _fuzzy_score
is a case-insensitive subsequence scorer used by both :-mode and
insert-mode autocomplete.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `_fuzzy_rank` + completion contexts

**Files:**
- Modify: `src/tui_hints.jl`
- Modify: `test/test_tui_hints.jl`

- [ ] **Step 1: Write failing tests**

Append to `test/test_tui_hints.jl` inside `@testset "tui_hints"`:

```julia
    @testset "_fuzzy_rank sorts by (score, length, lexico)" begin
        out = Ressac._fuzzy_rank("sa", ["samples", "snares", "savings"])
        # "samples" (score 0, len 7), "savings" (score 0, len 7) → lexico
        # "snares" (score 1) → last
        @test out == ["samples", "savings", "snares"]
    end

    @testset "_fuzzy_rank skips non-matches" begin
        @test Ressac._fuzzy_rank("xy", ["foo", "bar"]) == String[]
    end

    @testset "_fuzzy_rank stable with empty query" begin
        out = Ressac._fuzzy_rank("", ["b", "a", "c"])
        # score 0 for all; ties broken by length (all 1) then lexico
        @test out == ["a", "b", "c"]
    end

    @testset "_completion_context inside p\" returns :mininotation" begin
        @test Ressac._completion_context("p\"kic", 6) === :mininotation
    end

    @testset "_completion_context after closed p\" returns :default" begin
        @test Ressac._completion_context("p\"bd\" |> fast", 14) === :default
    end

    @testset "_completion_context mid-buffer mini-notation" begin
        @test Ressac._completion_context("@d1 p\"bd hh", 11) === :mininotation
    end

    @testset "_completion_context amp\" is not an opener" begin
        @test Ressac._completion_context("amp\"junk", 8) === :default
    end

    @testset "_completion_context m\" (mininotation macro)" begin
        @test Ressac._completion_context("m\"kick", 7) === :mininotation
    end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with `UndefVarError: _fuzzy_rank` and `_completion_context`.

- [ ] **Step 3: Implement**

Append to `src/tui_hints.jl`:

```julia
"""
    _fuzzy_rank(query, candidates) -> Vector{String}

Return the subset of `candidates` that fuzzy-match `query`, sorted by
`(score asc, length asc, lexico asc)`. Non-matches are dropped.
"""
function _fuzzy_rank(query::AbstractString, candidates::AbstractVector{<:AbstractString})
    scored = Tuple{Int,Int,String}[]
    for cand in candidates
        s = _fuzzy_score(query, cand)
        s === nothing && continue
        push!(scored, (s, length(cand), String(cand)))
    end
    sort!(scored, by = t -> (t[1], t[2], t[3]))
    return [t[3] for t in scored]
end

"""
    _is_word_char_simple(c) -> Bool

Word-char predicate for completion-target extraction. Same as the one
in tui_bindings.jl but without the `:` (we don't want to glue `bd:1`
into one completion candidate).
"""
_is_word_char_simple(c::AbstractChar) =
    isletter(c) || isdigit(c) || c == '_' || c == '@'

"""
    _completion_context(line, cursor_col) -> Symbol

Walk `line` left-to-right up to `cursor_col`, tracking whether we are
currently inside a `p"..."` or `m"..."` string. Returns
`:mininotation` if such a string is still open at the cursor,
`:default` otherwise.

Only `p` and `m` immediately followed by `"`, and not preceded by a
word char, are recognised as mini-notation openers. Any other `"`
opens a plain (non-mininotation) string that still blocks Tab from
treating it as code; on close, we're back in default.
"""
function _completion_context(line::AbstractString, cursor_col::Integer)
    in_mn = false
    in_plain = false
    i = firstindex(line)
    last_byte = min(lastindex(line), cursor_col - 1)
    while i <= last_byte
        c = line[i]
        if !in_mn && !in_plain
            ni = nextind(line, i)
            is_opener = ni <= lastindex(line) &&
                        (c == 'p' || c == 'm') && line[ni] == '"' &&
                        (i == firstindex(line) ||
                         !_is_word_char_simple(line[prevind(line, i)]))
            if is_opener
                in_mn = true
                i = nextind(line, ni)
                continue
            end
            if c == '"'
                in_plain = true
            end
        elseif in_mn && c == '"'
            in_mn = false
        elseif in_plain && c == '"'
            in_plain = false
        end
        i = nextind(line, i)
    end
    return in_mn ? :mininotation : :default
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (526+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/tui_hints.jl test/test_tui_hints.jl
git commit -m "$(cat <<'EOF'
tui_hints: _fuzzy_rank + _completion_context

_fuzzy_rank sorts candidates by (score, length, lexico) and drops
non-matches. _completion_context walks the line tracking p"..." and
m"..." string macros so Tab inside a mini-notation string can
narrow the candidate set to registry names only.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Candidate lookup + `:`-mode completions

**Files:**
- Modify: `src/tui_hints.jl`
- Modify: `test/test_tui_hints.jl`

- [ ] **Step 1: Write failing tests**

Append to the `@testset "tui_hints"`:

```julia
    @testset "_buffer_candidates(:default) includes combinators and macros" begin
        cands = Ressac._buffer_candidates(:default)
        @test "fast" in cands
        @test "gain" in cands
        @test "@d1" in cands
        @test "@d64" in cands
    end

    @testset "_buffer_candidates(:mininotation) excludes combinators and macros" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        empty!(Ressac._INSTRUMENT_REGISTRY)
        empty!(Ressac._SYNTH_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            cands = Ressac._buffer_candidates(:mininotation)
            @test "kicky" in cands
            @test !("fast" in cands)
            @test !("@d1" in cands)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "_compute_completions empty buffer → all command names" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.command_buffer = ""
        out = Ressac._compute_completions(m)
        @test "samples" in out
        @test "quit" in out
        @test "guide" in out
    end

    @testset "_compute_completions verb prefix narrows" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.command_buffer = "sa"
        out = Ressac._compute_completions(m)
        @test "samples" in out
        @test !("quit" in out)
    end

    @testset "_compute_completions :samples arg matches registry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:snares, "p",
                "/y", ["/y"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.command_buffer = "samples ki"
            out = Ressac._compute_completions(m)
            @test "kicky" in out
            @test !("snares" in out)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
```

The tests reference `MockOSCClient`. The other test files already define it; add a local shadow at the top of `test/test_tui_hints.jl` if needed:

```julia
mutable struct MockOSCClient
    sent::Vector{Vector{UInt8}}
end
MockOSCClient() = MockOSCClient(Vector{UInt8}[])
Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
```

(Place it after `using Ressac` and before `@testset "tui_hints"`.)

- [ ] **Step 2: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with `UndefVarError: _buffer_candidates`, `_compute_completions`.

- [ ] **Step 3: Implement**

Append to `src/tui_hints.jl`:

```julia
const _COMMAND_NAMES = [
    "q", "quit", "cps", "goto",
    "samples", "instruments", "synths",
    "guide", "help",
]

const _COMBINATOR_NAMES = [
    "pure", "silence", "fast", "slow", "density", "rev", "every",
    "stack", "cat", "mask",
    "gain", "speed", "lpf", "hpf", "pan", "n", "room", "delay",
    "shape", "set",
]

"""
    _buffer_candidates(ctx::Symbol) -> Vector{String}

Compute the candidate list for in-buffer autocomplete. `ctx` is either
`:mininotation` (cursor inside `p"..."` or `m"..."`) — registries only
— or `:default`, which adds combinators and `@d1..@d64` slot macros.
"""
function _buffer_candidates(ctx::Symbol)::Vector{String}
    out = String[]
    append!(out, String.(keys(_SAMPLE_REGISTRY)))
    append!(out, String.(keys(_INSTRUMENT_REGISTRY)))
    append!(out, String.(keys(_SYNTH_REGISTRY)))
    if ctx === :default
        append!(out, _COMBINATOR_NAMES)
        append!(out, ["@d$i" for i in 1:64])
    end
    unique!(out)
    return out
end

function _command_arg_candidates(verb::AbstractString)
    verb == "samples"     && return String.(keys(_SAMPLE_REGISTRY))
    verb == "instruments" && return String.(keys(_INSTRUMENT_REGISTRY))
    verb == "synths"      && return String.(keys(_SYNTH_REGISTRY))
    return nothing
end

"""
    _compute_completions(m::LiveModel) -> Vector{String}

Compute the current candidate list for `:`-mode autocomplete based on
`m.command_buffer`. Empty buffer → all command names. Verb-only prefix
→ matching command names. Verb + space + partial → matching argument
candidates for that verb (registry lookup), or empty if the verb has
no argument completion.
"""
function _compute_completions(m::LiveModel)::Vector{String}
    buf = m.command_buffer
    if !occursin(' ', buf)
        return _fuzzy_rank(buf, _COMMAND_NAMES)
    end
    verb, rest = split(buf, ' '; limit=2)
    cands = _command_arg_candidates(verb)
    cands === nothing && return String[]
    return _fuzzy_rank(strip(String(rest)), cands)
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (531+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/tui_hints.jl test/test_tui_hints.jl
git commit -m "$(cat <<'EOF'
tui_hints: _buffer_candidates + _compute_completions

Candidate lookup for both insert-mode and :-mode autocomplete.
Insert-mode candidates depend on context (:mininotation excludes
combinators and macros). :-mode candidates start from a fixed command
list, then switch to registry-keyed argument candidates for
:samples/:instruments/:synths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `_MODE_HINTS` + permanent hint line in view

**Files:**
- Modify: `src/tui_hints.jl`
- Modify: `src/tui_view.jl`

- [ ] **Step 1: Add the mode hints const**

Append to `src/tui_hints.jl`:

```julia
"""
    _MODE_HINTS

Short, terse one-line hint per mode, shown permanently above the logs.
Tells the user the 4-5 most useful next actions for the current mode.
"""
const _MODE_HINTS = Dict{Symbol,String}(
    :normal      => "i|V|:|K|e  |  ? = full help",
    :insert      => "Esc back to normal  |  Tab autocomplete",
    :visual_line => "y/d/m/e on selection  |  Esc cancel",
    :command     => "Enter run  |  Tab cycle  |  Esc cancel",
    :guide       => "j/k scroll  |  /search  |  q close",
)

_mode_hint(mode::Symbol) = get(_MODE_HINTS, mode, "")
```

- [ ] **Step 2: Add the hint line widget to the view**

Edit `src/tui_view.jl`. Replace the existing `TUI.view(m::LiveModel)` function with:

```julia
function TUI.view(m::LiveModel)
    status = _activity_widget(m)
    editor = _editor_pane(m)
    hint   = _mode_hint_line(m)
    cmd    = _command_line(m)
    logs   = _logs_pane(m)
    TUI.Layout(;
        widgets     = [status, editor, hint, cmd, logs],
        constraints = [TUI.Min(1), TUI.Percent(70), TUI.Min(1), TUI.Min(1), TUI.Min(8)],
        orientation = :vertical,
    )
end

function _mode_hint_line(m::LiveModel)
    text = "[" * uppercase(String(m.mode)) * "] " * _mode_hint(m.mode)
    _TextLines([text], TUI.Crayon(; foreground=:cyan))
end
```

- [ ] **Step 3: Verify with the full test suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (no regressions). The hint line is rendered but no
test asserts on it yet — that's covered in Task 9.

- [ ] **Step 4: Commit**

```bash
git add src/tui_hints.jl src/tui_view.jl
git commit -m "$(cat <<'EOF'
tui_hints + view: permanent mode hint line

A 1-row hint pulled from _MODE_HINTS sits between the command line
and the log pane, showing the current mode (NORMAL/INSERT/...) plus
its terse cheatsheet. Free help for muscle-memory learners and
sanity check that the mode you think you're in matches reality.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Tab autocomplete in `:`-mode

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write failing tests**

Find an existing `:`-mode test in `test/test_tui_bindings.jl` (look for `_fake_key(":")`) and append new test sets at the end of the same outer `@testset`:

```julia
    @testset "Tab in :-mode cycles command-name matches" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        Ressac._dispatch_key!(m, _fake_key("s"))
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.command_buffer == "sa"
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.command_buffer == "samples"
        @test m.completions == ["samples", "synths"] ||
              m.completions == ["samples"]   # fuzzy may also keep just one
        # Second Tab cycles
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.command_buffer in ("synths", "samples")
    end

    @testset "Tab in :-mode with no matches is silent no-op" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        Ressac._dispatch_key!(m, _fake_key("z"))
        Ressac._dispatch_key!(m, _fake_key("z"))
        @test m.command_buffer == "zz"
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.command_buffer == "zz"
        @test isempty(m.completions)
    end

    @testset "Editing the command buffer clears Tab cycle" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        Ressac._dispatch_key!(m, _fake_key("s"))
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        # After Tab, completions populated
        @test !isempty(m.completions)
        Ressac._dispatch_key!(m, _fake_key("a"))
        # Editing should reset the cycle (next Tab recomputes)
        @test m.completion_cycle_idx == 0
    end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL — currently Tab in `:`-mode does nothing useful.

- [ ] **Step 3: Implement Tab handling in command mode**

Edit `src/tui_bindings.jl`. Replace the existing `_handle_command!` function with:

```julia
function _handle_command!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        m.command_buffer = ""
        _clear_completions!(m)
    elseif code == "Enter"
        _execute_command!(m)
        m.mode = :normal
        m.command_buffer = ""
        _clear_completions!(m)
    elseif code == "Backspace"
        isempty(m.command_buffer) && return
        m.command_buffer = m.command_buffer[1:prevind(m.command_buffer, end)]
        _clear_completions!(m)
    elseif code == "Tab"
        _handle_command_tab!(m)
    elseif length(code) == 1
        c = first(code)
        if _is_typable_ascii(c)
            m.command_buffer *= code
            _clear_completions!(m)
        end
    end
end

function _clear_completions!(m::LiveModel)
    empty!(m.completions)
    m.completion_cycle_idx = 0
    m.completion_target_range = nothing
end

function _handle_command_tab!(m::LiveModel)
    if isempty(m.completions)
        # First Tab: compute candidates from the current buffer.
        candidates = _compute_completions(m)
        isempty(candidates) && return
        m.completions = candidates
        m.completion_cycle_idx = 1
        # If the buffer is "verb arg", replace only the arg part; else
        # replace the entire buffer.
        if occursin(' ', m.command_buffer)
            verb, _ = split(m.command_buffer, ' '; limit=2)
            m.command_buffer = String(verb) * " " * candidates[1]
        else
            m.command_buffer = candidates[1]
        end
    else
        # Subsequent Tab: cycle.
        m.completion_cycle_idx = (m.completion_cycle_idx % length(m.completions)) + 1
        next = m.completions[m.completion_cycle_idx]
        if occursin(' ', m.command_buffer)
            verb, _ = split(m.command_buffer, ' '; limit=2)
            m.command_buffer = String(verb) * " " * next
        else
            m.command_buffer = next
        end
    end
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (534+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "$(cat <<'EOF'
tui_bindings: Tab autocomplete in :-mode

Tab in command mode populates m.completions from
_compute_completions, inserts the best match, and cycles on
subsequent Tabs. Editing the buffer (typing, backspace) clears the
cycle so the next Tab recomputes from scratch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Tab autocomplete in insert mode

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write failing tests**

Append to the same outer `@testset` in `test/test_tui_bindings.jl`:

```julia
    @testset "Tab in insert mode completes against registry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["kic"]
            m.cursor_row = 1
            m.cursor_col = 4   # after the "c"
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            @test m.buffer[1] == "kicky"
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "Tab in insert mode cycles multiple matches" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:kicks, "p",
                "/y", ["/y"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["kic"]
            m.cursor_row = 1
            m.cursor_col = 4
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            first_completion = m.buffer[1]
            @test first_completion in ("kicks", "kicky")
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            second_completion = m.buffer[1]
            @test second_completion != first_completion
            @test second_completion in ("kicks", "kicky")
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "Tab in insert mode inside mini-notation excludes combinators" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:fastdrum, "p",
                "/x", ["/x"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["p\"fas"]
            m.cursor_row = 1
            m.cursor_col = 6   # after 's' in "fas"
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            # Should complete to "fastdrum" (registry), NOT to "fast" (combinator)
            @test m.buffer[1] == "p\"fastdrum"
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "Tab in insert mode default context includes combinators" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :insert
        m.buffer = ["@d1 fas"]
        m.cursor_row = 1
        m.cursor_col = 8   # after 's' in "fas"
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.buffer[1] == "@d1 fast"
    end

    @testset "Movement clears insert-mode completion cycle" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:kicks, "p",
                "/y", ["/y"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["kic"]
            m.cursor_row = 1
            m.cursor_col = 4
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            @test !isempty(m.completions)
            Ressac._dispatch_key!(m, _fake_key("Left"))
            @test isempty(m.completions)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL — Tab in insert mode currently does nothing useful.

- [ ] **Step 3: Implement insert-mode Tab + clear-on-edit hooks**

Edit `src/tui_bindings.jl`. Replace `_handle_insert!` with:

```julia
function _handle_insert!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        line = m.buffer[m.cursor_row]
        m.cursor_col = clamp(m.cursor_col, 1, max(1, lastindex(line)))
        _clear_completions!(m)
    elseif code == "Enter"
        _split_line!(m)
        _clear_completions!(m)
    elseif code == "Backspace"
        _backspace!(m)
        _clear_completions!(m)
    elseif code == "Left"
        _move_cursor!(m, -1, 0)
        _clear_completions!(m)
    elseif code == "Right"
        _move_cursor!(m, +1, 0)
        _clear_completions!(m)
    elseif code == "Up"
        _move_cursor!(m, 0, -1)
        _clear_completions!(m)
    elseif code == "Down"
        _move_cursor!(m, 0, +1)
        _clear_completions!(m)
    elseif code == "Tab"
        _handle_insert_tab!(m)
    elseif length(code) == 1
        c = first(code)
        if _is_typable_ascii(c)
            _insert_char!(m, c)
            _clear_completions!(m)
        else
            _push_log!(m, "[WARN] ignored non-ASCII key: $(repr(c))")
        end
    end
end

"""
    _extract_partial_word(line, cursor_col) -> (start_col, end_col, word)

Find the partial identifier under the cursor. Walks backward from
`cursor_col - 1` while the char is a word-char, then forward from
`cursor_col` while the char is a word-char. Empty result if no word.

Word chars: letters, digits, `_`, `@` (so `@d1` is one identifier).
"""
function _extract_partial_word(line::AbstractString, cursor_col::Integer)
    n = lastindex(line)
    n == 0 && return (1, 0, "")
    # Walk backward.
    start_col = cursor_col
    while start_col > 1
        prev = prevind(line, start_col)
        prev >= 1 && _is_word_char_simple(line[prev]) || break
        start_col = prev
    end
    # Walk forward.
    end_col = cursor_col - 1
    j = cursor_col
    while j <= n && _is_word_char_simple(line[j])
        end_col = j
        j = nextind(line, j)
    end
    if end_col < start_col
        return (cursor_col, cursor_col - 1, "")
    end
    return (start_col, end_col, line[start_col:end_col])
end

function _handle_insert_tab!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    if isempty(m.completions)
        start_col, end_col, partial = _extract_partial_word(line, m.cursor_col)
        isempty(partial) && return
        ctx = _completion_context(line, m.cursor_col)
        cands = _fuzzy_rank(partial, _buffer_candidates(ctx))
        isempty(cands) && return
        m.completions = cands
        m.completion_cycle_idx = 1
        m.completion_target_range = (start_col, end_col)
        _replace_range_in_line!(m, start_col, end_col, cands[1])
    else
        m.completion_cycle_idx = (m.completion_cycle_idx % length(m.completions)) + 1
        next = m.completions[m.completion_cycle_idx]
        sc, ec = m.completion_target_range
        _replace_range_in_line!(m, sc, ec, next)
    end
end

function _replace_range_in_line!(m::LiveModel, start_col::Int, end_col::Int, replacement::AbstractString)
    line = m.buffer[m.cursor_row]
    prefix = start_col > 1 ? line[1:prevind(line, start_col)] : ""
    suffix = end_col >= lastindex(line) ? "" : line[nextind(line, end_col):end]
    new_line = prefix * replacement * suffix
    m.buffer[m.cursor_row] = new_line
    new_end = lastindex(prefix) + lastindex(replacement)
    m.cursor_col = new_end + 1
    m.completion_target_range = (start_col, new_end)
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (539+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "$(cat <<'EOF'
tui_bindings: Tab autocomplete in insert mode

Tab extracts the partial word under the cursor, detects the
completion context (mini-notation vs default), fuzzy-ranks the
appropriate candidate set, and replaces the partial with the best
match. Subsequent Tabs cycle through the candidate list. Any edit
or cursor motion clears the cycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Completion hint line in view

**Files:**
- Modify: `src/tui_view.jl`

- [ ] **Step 1: Add the completion hint line widget**

Edit `src/tui_view.jl`. Replace the `TUI.view(m::LiveModel)` function with the version that includes the conditional completion line:

```julia
function TUI.view(m::LiveModel)
    status = _activity_widget(m)
    editor = _editor_pane(m)
    hint   = _mode_hint_line(m)
    cmd    = _command_line(m)
    compl  = _completion_hint_line(m)
    logs   = _logs_pane(m)
    TUI.Layout(;
        widgets     = [status, editor, hint, cmd, compl, logs],
        constraints = [TUI.Min(1), TUI.Percent(70), TUI.Min(1),
                       TUI.Min(1), TUI.Min(1), TUI.Min(8)],
        orientation = :vertical,
    )
end

function _completion_hint_line(m::LiveModel)
    if isempty(m.completions)
        return _TextLines([""], TUI.Crayon())
    end
    parts = String[]
    for (i, cand) in enumerate(m.completions)
        if i == m.completion_cycle_idx
            push!(parts, "[" * cand * "]")
        else
            push!(parts, cand)
        end
    end
    text = join(parts, "  ")
    _TextLines([text], TUI.Crayon(; foreground=:magenta))
end
```

- [ ] **Step 2: Run the suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (no regressions).

- [ ] **Step 3: Commit**

```bash
git add src/tui_view.jl
git commit -m "$(cat <<'EOF'
tui_view: completion hint line

A 1-row magenta strip below the command line lists the current
completion candidates, with the cycled one bracketed. Empty when
m.completions is empty (most of the time). The hint persists across
Tab cycles in both :-mode and insert mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `_Overlay` widget + `?` toggle

**Files:**
- Create: `src/tui_overlay.jl`
- Create: `test/test_tui_overlay.jl`
- Modify: `src/Ressac.jl`
- Modify: `src/tui_bindings.jl`
- Modify: `src/tui_view.jl`
- Modify: `src/tui_hints.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Wire the new test file**

Edit `test/runtests.jl`:

```julia
    include("test_tui_hints.jl")
    include("test_tui_overlay.jl")
end
```

- [ ] **Step 2: Write failing tests for the overlay helpers**

Create `test/test_tui_overlay.jl`:

```julia
using Test
using Ressac

@testset "tui_overlay" begin
    @testset "_overlay_rect centers within area" begin
        # area 80x24, content needs ~6 rows × ~30 cols.
        # We expect the rect to be centered.
        area_w, area_h = 80, 24
        rect_w, rect_h = Ressac._overlay_rect(area_w, area_h, 30, 6)
        # Returns (left, top, width, height) relative to area
        @test rect_w == (25, 9, 30, 6)
    end

    @testset "_overlay_rect caps at 80% of area" begin
        # Request something huge; should clamp to 80% × 80%.
        out = Ressac._overlay_rect(100, 50, 200, 200)
        # Width 200 > 100 * 0.8 = 80 → clamped to 80
        # Height 200 > 50 * 0.8 = 40 → clamped to 40
        @test out[3] == 80
        @test out[4] == 40
    end

    @testset "_clip_lines truncates each line to width" begin
        lines = ["hello world", "tiny", "exactly10!"]
        out = Ressac._clip_lines(lines, 5)
        @test out == ["hello", "tiny", "exact"]
    end

    @testset "_clip_lines empty input" begin
        @test Ressac._clip_lines(String[], 10) == String[]
    end

    @testset "? toggles m.show_help in normal mode" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        @test m.show_help == false
        Ressac._dispatch_key!(m, _fake_key("?"))
        @test m.show_help == true
        Ressac._dispatch_key!(m, _fake_key("?"))
        @test m.show_help == false
    end
end
```

Note: `_fake_key` and `MockOSCClient` are defined in other test files; add local copies at the top of `test_tui_overlay.jl`:

```julia
mutable struct MockOSCClient
    sent::Vector{Vector{UInt8}}
end
MockOSCClient() = MockOSCClient(Vector{UInt8}[])
Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)

_fake_key(code::AbstractString; modifiers=String[], kind="Press") =
    (; code = String(code), modifiers = String.(modifiers), kind = String(kind))
```

- [ ] **Step 3: Run to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with `UndefVarError: _overlay_rect`.

- [ ] **Step 4: Implement the overlay primitives**

Create `src/tui_overlay.jl`:

```julia
# Overlay widget for help popups and modal :guide. Renders a centered
# bordered box on top of whatever's already in the buffer.
# Spec: docs/journal/20260522_visual_ux_design.md.

"""
    _overlay_rect(area_w, area_h, want_w, want_h)
        -> (left::Int, top::Int, width::Int, height::Int)

Compute the centered rectangle for an overlay of desired dimensions
`(want_w, want_h)` inside an area of size `(area_w, area_h)`. Both
dimensions are capped to 80% of their respective area.
"""
function _overlay_rect(area_w::Int, area_h::Int, want_w::Int, want_h::Int)
    max_w = max(1, floor(Int, area_w * 0.8))
    max_h = max(1, floor(Int, area_h * 0.8))
    w = min(want_w, max_w)
    h = min(want_h, max_h)
    left = max(0, (area_w - w) ÷ 2)
    top  = max(0, (area_h - h) ÷ 2)
    return (left, top, w, h)
end

"""
    _clip_lines(lines, width) -> Vector{String}

Truncate each line to at most `width` characters. Used to keep
overlay content from overflowing the rendered box.
"""
function _clip_lines(lines::AbstractVector{<:AbstractString}, width::Int)
    out = String[]
    for line in lines
        push!(out, String(first(line, width)))
    end
    return out
end

"""
    _Overlay(lines, title, style; scroll=0)

Custom widget: draws a bordered box centered in its render area,
containing `lines` (clipped + scrolled). The `title` appears in the
top border. `scroll` is the number of lines hidden above the
viewport (used by the :guide modal).
"""
struct _Overlay
    lines::Vector{String}
    title::String
    style::TUI.Crayon
    scroll::Int
end

_Overlay(lines, title; style=TUI.Crayon(), scroll=0) =
    _Overlay(collect(lines), String(title), style, scroll)

function TUI.render(o::_Overlay, area::TUI.Rect, buf::TUI.Buffer)
    area_w = TUI.width(area)
    area_h = TUI.height(area)
    area_w >= 4 && area_h >= 3 || return
    want_h = length(o.lines) + 2   # +2 for top/bottom borders
    want_w = 2 + (isempty(o.lines) ? 0 : maximum(length, o.lines))
    want_w = max(want_w, length(o.title) + 4)
    left, top, w, h = _overlay_rect(area_w, area_h, want_w, want_h)
    abs_left = TUI.left(area) + left
    abs_top  = TUI.top(area) + top
    # Top border with title.
    top_border = "┌─ " * o.title * " " * "─"^max(0, w - 4 - length(o.title))
    TUI.set(buf, abs_left, abs_top, first(top_border, w - 1) * "┐", o.style)
    # Body.
    inner_w = w - 2
    inner_h = h - 2
    visible = o.lines[(o.scroll + 1):min(end, o.scroll + inner_h)]
    clipped = _clip_lines(visible, inner_w)
    for (i, line) in enumerate(clipped)
        padded = line * " "^max(0, inner_w - length(line))
        TUI.set(buf, abs_left, abs_top + i, "│" * padded * "│", o.style)
    end
    # Fill remaining inner rows with blanks.
    for i in (length(clipped) + 1):inner_h
        TUI.set(buf, abs_left, abs_top + i, "│" * " "^inner_w * "│", o.style)
    end
    # Bottom border.
    bot = "└" * "─"^inner_w * "┘"
    TUI.set(buf, abs_left, abs_top + h - 1, bot, o.style)
end

"""
    _AppView(model)

Top-level composite widget: renders the normal layout, then overlays
the `?` help popup or `:guide` modal on top when their visibility
flags are set.
"""
struct _AppView
    model::LiveModel
end

function TUI.render(v::_AppView, area::TUI.Rect, buf::TUI.Buffer)
    layout = _build_main_layout(v.model)
    TUI.render(layout, area, buf)
    if v.model.show_help
        TUI.render(_help_overlay(v.model), area, buf)
    elseif v.model.mode === :guide
        TUI.render(_guide_overlay(v.model), area, buf)
    end
end

function _help_overlay(m::LiveModel)
    lines = get(_HELP_OVERLAY_LINES, m.mode, String["(no help for this mode)"])
    _Overlay(lines, "? help — press ? to close")
end

function _guide_overlay(m::LiveModel)
    _Overlay(_GUIDE_LINES, ":guide — j/k scroll, q close"; scroll = m.guide_scroll)
end
```

Add `_HELP_OVERLAY_LINES` to `src/tui_hints.jl`:

```julia
"""
    _HELP_OVERLAY_LINES

Per-mode help body shown by the `?` overlay. Longer than `_MODE_HINTS`
but still terse — one screen, no scroll.
"""
const _HELP_OVERLAY_LINES = Dict{Symbol,Vector{String}}(
    :normal => [
        "NORMAL mode",
        "",
        "  i / a / o / O — enter insert",
        "  hjkl / arrows — move",
        "  0  \$         — line start / end",
        "  gg / G       — buffer start / end",
        "  gdN          — goto slot dN",
        "  dd / yy / p  — delete / yank / paste",
        "  V            — visual line",
        "  : / / / ?    — cmd / search forward / backward",
        "  K            — preview under cursor",
        "  e            — eval block ([N]e = defer N cycles)",
        "  n / N        — repeat search",
        "  ?            — toggle this overlay",
    ],
    :insert => [
        "INSERT mode",
        "",
        "  type        — insert chars",
        "  Tab         — autocomplete identifier under cursor",
        "  arrows      — move",
        "  Backspace   — delete previous char",
        "  Enter       — newline",
        "  Esc         — back to normal",
    ],
    :visual_line => [
        "VISUAL-LINE mode",
        "",
        "  j / k       — extend selection",
        "  y / d       — yank / delete",
        "  m           — toggle mute on each selected line",
        "  e           — eval the selected block",
        "  Esc         — cancel",
    ],
    :command => [
        "COMMAND mode",
        "",
        "  type        — compose command",
        "  Tab         — autocomplete (cycles)",
        "  Enter       — run",
        "  Esc         — cancel",
    ],
    :guide => [
        "GUIDE mode",
        "",
        "  j / k       — scroll",
        "  gg / G      — top / bottom",
        "  /<rx>       — search forward (jumps to first match)",
        "  n / N       — repeat search",
        "  q / Esc     — close",
    ],
)
```

Edit `src/tui_view.jl`. Rename the function that builds the layout, and add `_build_main_layout`:

```julia
function TUI.view(m::LiveModel)
    return _AppView(m)
end

function _build_main_layout(m::LiveModel)
    status = _activity_widget(m)
    editor = _editor_pane(m)
    hint   = _mode_hint_line(m)
    cmd    = _command_line(m)
    compl  = _completion_hint_line(m)
    logs   = _logs_pane(m)
    TUI.Layout(;
        widgets     = [status, editor, hint, cmd, compl, logs],
        constraints = [TUI.Min(1), TUI.Percent(70), TUI.Min(1),
                       TUI.Min(1), TUI.Min(1), TUI.Min(8)],
        orientation = :vertical,
    )
end
```

Edit `src/tui_bindings.jl`. Find `_handle_normal!` and add the `?` case before the `Esc` case:

```julia
    elseif code == "?"
        m.show_help = !m.show_help
    elseif code == "Esc"
```

Edit `src/Ressac.jl`, add `include("tui_overlay.jl")` *after* `include("tui_view.jl")` (since _AppView references _build_main_layout):

```julia
include("tui_view.jl")
include("tui_overlay.jl")
```

- [ ] **Step 5: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (544+ tests).

- [ ] **Step 6: Commit**

```bash
git add src/tui_overlay.jl src/tui_hints.jl src/tui_view.jl src/tui_bindings.jl src/Ressac.jl test/test_tui_overlay.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
tui_overlay: _Overlay widget + ? help toggle

_Overlay draws a centered bordered box with a title; capped to 80%
of the render area, with line clipping + optional scroll. _AppView
wraps the existing layout and overlays the popup/modal on top.
_HELP_OVERLAY_LINES holds the per-mode help body; ? in normal mode
toggles m.show_help.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `:guide` modal mode shift + navigation handler

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write failing tests**

Append to the same outer `@testset` in `test/test_tui_bindings.jl`:

```julia
    @testset ":guide switches m.mode to :guide" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "guide"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
        @test m.guide_scroll == 0
    end

    @testset "guide-mode j scrolls down, k scrolls up" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 0
        Ressac._dispatch_key!(m, _fake_key("j"))
        @test m.guide_scroll == 1
        Ressac._dispatch_key!(m, _fake_key("j"))
        @test m.guide_scroll == 2
        Ressac._dispatch_key!(m, _fake_key("k"))
        @test m.guide_scroll == 1
    end

    @testset "guide-mode k clamps to 0" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 0
        Ressac._dispatch_key!(m, _fake_key("k"))
        @test m.guide_scroll == 0
    end

    @testset "guide-mode gg jumps to top, G to bottom" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 5
        Ressac._dispatch_key!(m, _fake_key("g"))
        Ressac._dispatch_key!(m, _fake_key("g"))
        @test m.guide_scroll == 0
        Ressac._dispatch_key!(m, _fake_key("G"))
        # G clamps to max(0, len-1)
        @test m.guide_scroll == max(0, length(Ressac._GUIDE_LINES) - 1)
    end

    @testset "guide-mode q returns to normal" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        Ressac._dispatch_key!(m, _fake_key("q"))
        @test m.mode === :normal
    end

    @testset "guide-mode Esc returns to normal" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        Ressac._dispatch_key!(m, _fake_key("Esc"))
        @test m.mode === :normal
    end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL — `:guide` currently dumps to logs and there's no `:guide` mode handler.

- [ ] **Step 3: Implement**

Edit `src/tui_bindings.jl`. Find the `:guide` branch in `_execute_ex_command!` (currently dumps `_GUIDE_LINES` to logs) and replace it with a mode shift:

```julia
    elseif body == "guide" || body == "help" || body == "?"
        m.mode = :guide
        m.guide_scroll = 0
        m.pending_chord = :none
```

In `_dispatch_key!`, add the `:guide` mode branch. Find the function (top of the file) and update it:

```julia
function _dispatch_key!(m::LiveModel, evt)
    evt.kind == "Press" || evt.kind == "Repeat" || return
    if m.mode === :insert
        _handle_insert!(m, evt)
    elseif m.mode === :normal
        _handle_normal!(m, evt)
    elseif m.mode === :visual_line
        _handle_visual!(m, evt)
    elseif m.mode === :command
        _handle_command!(m, evt)
    elseif m.mode === :guide
        _handle_guide!(m, evt)
    end
end
```

Append the new handler at the bottom of `src/tui_bindings.jl`:

```julia
# ---------------------------------------------------------------------
# Guide mode
# ---------------------------------------------------------------------

"""
    _handle_guide!(m, evt)

Keystrokes for the modal :guide overlay. j/k scroll, gg/G jump,
q/Esc closes. /<rx> searches forward and jumps scroll to the first
matching line.
"""
function _handle_guide!(m::LiveModel, evt)
    code = evt.code
    if code == "q" || code == "Esc"
        m.mode = :normal
        m.guide_scroll = 0
        m.pending_chord = :none
    elseif code == "j" || code == "Down"
        m.guide_scroll = min(m.guide_scroll + 1, max(0, length(_GUIDE_LINES) - 1))
    elseif code == "k" || code == "Up"
        m.guide_scroll = max(0, m.guide_scroll - 1)
    elseif code == "g"
        if m.pending_chord === :g
            m.guide_scroll = 0
            m.pending_chord = :none
        else
            m.pending_chord = :g
        end
    elseif code == "G"
        m.guide_scroll = max(0, length(_GUIDE_LINES) - 1)
        m.pending_chord = :none
    elseif code == "d" && _has_modifier(evt, "Ctrl")
        m.guide_scroll = min(m.guide_scroll + 10, max(0, length(_GUIDE_LINES) - 1))
    elseif code == "u" && _has_modifier(evt, "Ctrl")
        m.guide_scroll = max(0, m.guide_scroll - 10)
    elseif code == "/"
        m.mode = :command
        m.command_prefix = '/'
        m.command_buffer = ""
    else
        m.pending_chord = :none
    end
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (550+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "$(cat <<'EOF'
tui_bindings: :guide as modal mode + _handle_guide!

:guide now sets m.mode = :guide instead of dumping the guide into
the log pane. _handle_guide! covers j/k scroll, gg/G jump, Ctrl-d/u
half-page, q/Esc to close, / to search via the existing command-mode
machinery (results land back in :guide via the search handler).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: `/`-search inside `:guide` modal

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write failing tests**

Append:

```julia
    @testset "guide-mode / search jumps to first match" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 0
        Ressac._dispatch_key!(m, _fake_key("/"))
        @test m.mode === :command
        @test m.command_prefix == '/'
        for c in "guide"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        # Back to :guide, scroll positioned at the first line containing "guide"
        @test m.mode === :guide
        # The pattern appears in _GUIDE_LINES somewhere; scroll should not
        # remain at 0 unless the very first line is the match.
        idx = findfirst(l -> occursin("guide", lowercase(l)), Ressac._GUIDE_LINES)
        @test idx !== nothing
        @test m.guide_scroll == idx - 1
    end

    @testset "guide-mode / search no match leaves scroll alone" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 3
        Ressac._dispatch_key!(m, _fake_key("/"))
        for c in "zzznosuchstring"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
        @test m.guide_scroll == 3   # unchanged
    end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL — `/` in guide mode currently shifts to :command but the search-on-Enter logic doesn't know about guide-mode targets.

- [ ] **Step 3: Implement guide-aware search**

Edit `src/tui_bindings.jl`. Find `_execute_command!` and add a guard at the top of the `/` branch:

```julia
    elseif prefix == '/'
        rx_str = body
        rx = try
            Regex(rx_str, "i")   # case-insensitive
        catch err
            _push_log!(m, "[ERROR] bad regex: $(sprint(showerror, err))")
            return
        end
        # If we were invoked from guide mode (m.mode is currently :command
        # because of the / prefix shift; we need a different signal).
        # The existing handler routes back to the buffer search; we add a
        # branch keyed on the prior mode, which we stash on entry.
        if m.guide_search_active
            idx = findfirst(l -> occursin(rx, l), _GUIDE_LINES)
            if idx !== nothing
                m.guide_scroll = idx - 1
            end
            m.mode = :guide
            m.guide_search_active = false
        else
            _run_search!(m, rx; dir=:forward)
        end
    elseif prefix == '?'
```

This requires the model to carry a `guide_search_active` flag. Edit
`src/tui_model.jl`:

```julia
    show_help::Bool               = false
    guide_scroll::Int             = 0
    guide_search_active::Bool     = false
    completions::Vector{String}   = String[]
```

In `_handle_guide!`, set the flag when entering search:

```julia
    elseif code == "/"
        m.mode = :command
        m.command_prefix = '/'
        m.command_buffer = ""
        m.guide_search_active = true
```

Also handle Esc-from-/-during-guide-search: edit `_handle_command!` Esc branch to restore guide mode if the flag was set:

```julia
    if code == "Esc"
        if m.guide_search_active
            m.mode = :guide
            m.guide_search_active = false
        else
            m.mode = :normal
        end
        m.command_buffer = ""
        _clear_completions!(m)
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (552+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl src/tui_model.jl test/test_tui_bindings.jl
git commit -m "$(cat <<'EOF'
tui_bindings: / search inside :guide modal

m.guide_search_active flag routes / from guide-mode through the
existing command/Enter machinery without touching the editor buffer.
On Enter the first matching _GUIDE_LINES index becomes the new
guide_scroll. No match leaves the scroll position alone. Esc from
search returns to :guide rather than :normal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Cheatsheet update + precompile

**Files:**
- Modify: `docs/cheatsheet.md`
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Update the cheatsheet**

Edit `docs/cheatsheet.md`. Insert a new section right before `## Common gotchas`:

```markdown
## Visual UX (TUI)

### Mode hint line

A 1-row strip just below the command line shows the current mode plus
the 4-5 most relevant key bindings. The mode you think you're in is
written there in caps.

### `?` overlay

Press `?` in normal mode to pop a mode-specific cheat overlay (every
binding in the current mode, terse). Press `?` again to dismiss. The
overlay does NOT auto-dismiss on other keys — it's a stable surface
for reading.

### Autocomplete (Tab)

- **`:`-mode** — Tab on a partial command verb completes (fuzzy).
  Tab on `:samples <partial>`, `:instruments <partial>`, or
  `:synths <partial>` completes the argument against the matching
  registry. A magenta hint line below the command line shows the
  candidate list with the cycled one in `[brackets]`.
- **Insert mode** — Tab extracts the partial identifier under the
  cursor and completes against the registries + 20 combinator names
  + 64 `@dN` slot macros. Inside `p"..."` or `m"..."` mini-notation,
  only registry names are offered (combinators would be garbage
  inside a mini-notation string).

Fuzzy match is a subsequence scorer ("sa" → "samples", "snares",
"savings"). Subsequent Tabs cycle. Any edit or cursor motion clears
the cycle.

### `:guide` modal

`:guide` (or `:help` / `:?`) opens a centered scrollable overlay
containing the full guide. Navigate with `j`/`k`/`gg`/`G`, search
with `/<rx>` (case-insensitive). `q` or `Esc` closes.

## Common gotchas
```

- [ ] **Step 2: Extend the precompile workload**

Edit `src/Ressac.jl`. Inside `@compile_workload`, append a block that
exercises the new code paths. Find the existing "Warm the TUI ex-command
paths" block and add after it:

```julia
    # SP6 visual UX: warm fuzzy match, completion engine, overlay rendering
    # paths, guide-mode handler.
    try
        _fuzzy_score("sa", "samples")
        _fuzzy_score("xy", "samples")
        _fuzzy_rank("sa", ["samples", "snares", "savings"])
        _completion_context("p\"kic", 6)
        _completion_context("@d1 fast", 9)
        _buffer_candidates(:default)
        _buffer_candidates(:mininotation)

        m3 = LiveModel(; scheduler=sched)
        m3.command_buffer = "sa"
        _compute_completions(m3)
        m3.command_buffer = "samples kic"
        _compute_completions(m3)

        # Toggle ? + render help overlay + render guide overlay.
        m3.show_help = true
        TUI.view(m3)
        m3.show_help = false
        m3.mode = :guide
        TUI.view(m3)
        m3.mode = :normal

        # Insert-mode Tab + cycle.
        m4 = LiveModel(; scheduler=sched)
        m4.mode = :insert
        m4.buffer = ["fas"]
        m4.cursor_col = 4
        _dispatch_key!(m4, (; code="Tab", modifiers=String[], kind="Press"))
        _dispatch_key!(m4, (; code="Tab", modifiers=String[], kind="Press"))
    catch
        # Best-effort.
    end
```

- [ ] **Step 3: Run the full suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (552+ tests, no regressions).

- [ ] **Step 4: Commit**

```bash
git add docs/cheatsheet.md src/Ressac.jl
git commit -m "$(cat <<'EOF'
docs(cheatsheet) + precompile: visual UX section

Cheatsheet section explains mode hint line, ? overlay, fuzzy Tab
autocomplete (with mini-notation context detection), and the :guide
modal. Precompile workload warms the new hot paths so first session
use is instant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review summary

**Spec coverage:**
- LiveModel fields (show_help, guide_scroll, completions, etc.) — Task 1
- `_fuzzy_score` — Task 1
- `_fuzzy_rank` — Task 2
- `_completion_context` — Task 2
- `_buffer_candidates` — Task 3
- `_compute_completions` — Task 3
- `_COMMAND_NAMES`, `_COMBINATOR_NAMES` — Task 3
- `_MODE_HINTS` const + permanent hint line — Task 4
- Tab in `:`-mode — Task 5
- Tab in insert mode + context — Task 6
- Completion hint line — Task 7
- `_Overlay` widget — Task 8
- `_HELP_OVERLAY_LINES` + `?` toggle — Task 8
- `_AppView` (overlay-on-top) — Task 8
- `:guide` as mode + `_handle_guide!` — Task 9
- `/` search inside `:guide` — Task 10
- Cheatsheet section — Task 11
- Precompile — Task 11

**Out-of-scope (deferred):**
- Mouse / click
- Symbol-literal context detection
- Snippet expansion
- Cross-line context tracking

**Placeholder scan:** none.

**Type consistency:** `_fuzzy_score`, `_fuzzy_rank`, `_completion_context`, `_buffer_candidates`, `_compute_completions`, `_handle_guide!`, `_AppView`, `_Overlay`, `_overlay_rect`, `_clip_lines`, `_MODE_HINTS`, `_HELP_OVERLAY_LINES`, `_COMMAND_NAMES`, `_COMBINATOR_NAMES` — all defined once, referenced consistently.
