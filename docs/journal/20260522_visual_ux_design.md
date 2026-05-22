# Sub-project 6 — Visual UX: hints, autocomplete, interactive guide

Status: approved 2026-05-22.

## Goal

Make the TUI more discoverable and faster to type in:

1. **Hint widget (hybrid)** — short, mode-aware key reminders permanently visible above the log pane; press `?` to pop a richer overlay listing every binding for the current mode.
2. **Fuzzy autocomplete** — Tab completes identifiers in both `:`-mode (commands + their arguments) and insert mode (registries + combinators + slot macros).
3. **Modal `:guide`** — replace the current log dump with a centered, scrollable, searchable overlay.

## Architecture

Two new files, three orthogonal pieces glued through the existing
LiveModel.

- **`src/tui_overlay.jl`** — `_Overlay` widget primitive (centered box,
  bordered, takes `lines` + `title`), rendered *after* the main layout
  so it overwrites the buffer area. Also hosts the rendering helper
  used by both the `?` popup and the `:guide` modal.
- **`src/tui_hints.jl`** — `_MODE_HINTS` const dict (mode → terse hint
  string), `_HELP_OVERLAY_LINES` const dict (mode → fuller help body
  for the `?` overlay), `_fuzzy_score`, and `_compute_completions`.

Existing files extended:

- **`src/tui_model.jl`** — new fields: `show_help::Bool`,
  `guide_scroll::Int`, `completions::Vector{String}`,
  `completion_cycle_idx::Int`, `completion_target_range::Union{Nothing,
  NTuple{2,Int}}` (start-col, end-col in the line where the partial
  identifier sits).
- **`src/tui_view.jl`** — adds the permanent hint line widget, a
  conditional completion-hint line, and the overlay render pass.
- **`src/tui_bindings.jl`** — `?` toggle in normal mode, Tab handler
  in both `:`-mode and insert mode, `:guide` switches to a new
  `m.mode = :guide` instead of dumping to logs, plus a new
  `_handle_guide!` for in-modal navigation.

## Components

### `_Overlay` widget

```julia
struct _Overlay
    lines::Vector{String}
    title::String         # rendered in the top border
    style::TUI.Crayon
    scroll::Int           # number of lines hidden above the viewport
end

function TUI.render(o::_Overlay, area::TUI.Rect, buf::TUI.Buffer)
    # Compute centered rect inside `area`. Cap dimensions to 80% of area.
    # Draw box border (┌─┐ │ │ └─┘), title in top-left of border,
    # write lines[scroll+1 : scroll+max_lines] inside.
end
```

Used by both the `?` popup (small, mode-bound, no scroll) and the
`:guide` modal (full guide, scrollable via `m.guide_scroll`).

### `_MODE_HINTS` (permanent line)

```julia
const _MODE_HINTS = Dict{Symbol,String}(
    :normal      => "i|V|:|K|e  |  ? = full help",
    :insert      => "Esc back to normal  |  Tab autocomplete",
    :visual_line => "y/d/m/e on selection  |  Esc cancel",
    :command     => "Enter run  |  Tab cycle  |  Esc cancel",
    :guide       => "j/k scroll  |  /search  |  q close",
)
```

One short line. The view pulls `_MODE_HINTS[m.mode]` and renders it
between the editor and the logs (above the conditional completion
hint).

### `_HELP_OVERLAY_LINES` (`?` popup)

```julia
const _HELP_OVERLAY_LINES = Dict{Symbol,Vector{String}}(
    :normal => [
        "NORMAL mode",
        "  i / a / o / O — insert",
        "  hjkl / arrows — move",
        "  0 \$ — line start / end",
        "  gg / G — buffer start / end",
        "  gdN — goto slot dN",
        "  dd / yy / p / P — delete / yank / paste",
        "  V — visual line",
        "  : — command   K — preview",
        "  e — eval (prefix N → defer N cycles)",
        "  n / N — repeat search",
        "  ? — toggle this overlay",
    ],
    :insert => [
        "INSERT mode",
        "  type to insert",
        "  Tab — autocomplete identifier under cursor",
        "  Backspace / arrows — edit + move",
        "  Enter — newline",
        "  Esc — back to normal",
    ],
    # ... visual_line, command, guide
)
```

`?` in normal mode toggles `m.show_help`. View checks the flag; if set,
renders the overlay layer with the lines for the current mode.

Any non-`?` keystroke does NOT auto-dismiss — the overlay is a
deliberate help layer, the user closes it explicitly. (Less surprising
than auto-dismiss-on-anything.)

### `_fuzzy_score(query, candidate)`

Subsequence match with a tightness penalty.

```julia
"""
    _fuzzy_score(query, candidate) -> Union{Nothing, Int}

Score how well `candidate` matches `query` as a case-insensitive
subsequence. Lower is tighter. Returns `nothing` if no match.

Score = sum of gaps between consecutive matched positions, weighted
so that early matches are slightly favoured. For "sa" against
"samples" (positions 1,2): score = 0. For "snares" (positions 1,3):
score = 1. For "savings" (positions 1,2): score = 0.

Tie-break by candidate length then lexico — shorter candidates first
("sa" matches "sa" with score 0 and "samples" with score 0; "sa" wins).
"""
function _fuzzy_score(query::AbstractString, candidate::AbstractString)
    q = lowercase(query)
    c = lowercase(candidate)
    isempty(q) && return 0
    score = 0
    last_idx = 0
    qi = 1
    for (i, ch) in enumerate(c)
        if qi <= ncodeunits(q) && Char(codeunit(q, qi)) == ch
            qi == 1 || (score += (i - last_idx - 1))
            last_idx = i
            qi += 1
            qi > lastindex(q) && break
        end
    end
    qi <= lastindex(q) && return nothing   # query exhausted? no.
    return score
end
```

(Implementation detail can iterate the chars via `eachindex(q)` and
`for (i, ch) in pairs(c)` — final version sees fit at write time.)

### `_compute_completions(m)` — `:`-mode

```julia
function _compute_completions(m::LiveModel)::Vector{String}
    buf = m.command_buffer
    if !occursin(' ', buf)
        # Completing the command verb.
        return _fuzzy_rank(buf, _COMMAND_NAMES)
    end
    verb, rest = split(buf, ' '; limit=2)
    candidates = _command_arg_candidates(verb)
    candidates === nothing && return String[]
    return _fuzzy_rank(strip(rest), candidates)
end

const _COMMAND_NAMES = ["q", "quit", "cps", "goto",
                        "samples", "instruments", "synths",
                        "guide", "help"]

function _command_arg_candidates(verb::AbstractString)
    verb == "samples"     && return String.(keys(_SAMPLE_REGISTRY))
    verb == "instruments" && return String.(keys(_INSTRUMENT_REGISTRY))
    verb == "synths"      && return String.(keys(_SYNTH_REGISTRY))
    return nothing
end
```

`_fuzzy_rank(query, candidates)` returns matches sorted by
`(score, length, lexico)`.

### Insert-mode autocomplete

When the user presses Tab in insert mode:

1. Extract the partial identifier under the cursor. Identifier rule:
   walk backward from `cursor_col - 1` while `_is_word_char`, walk
   forward from `cursor_col` while `_is_word_char`. Result is the
   `(start_col, end_col)` range and the substring.
2. If empty, do nothing.
3. Compute candidates as `_buffer_candidates()` (defined below).
4. Rank via `_fuzzy_rank`.
5. If no matches, log `[INFO] no completion for '<word>'`, no-op
   otherwise.
6. Else: replace the partial range with `candidates[1]`. Store the
   new range, candidates list, and `cycle_idx = 1` on the model.
7. View renders the completion hint line listing all candidates with
   the cycled one highlighted.

Consecutive Tab presses (with no intervening edit) cycle to the next
candidate, replacing the previously-inserted text in the recorded range.

Any non-Tab keystroke (Esc, motion keys, edit) clears the completion
state.

```julia
function _buffer_candidates()::Vector{String}
    out = String[]
    append!(out, String.(keys(_SAMPLE_REGISTRY)))
    append!(out, String.(keys(_INSTRUMENT_REGISTRY)))
    append!(out, String.(keys(_SYNTH_REGISTRY)))
    append!(out, _COMBINATOR_NAMES)
    append!(out, ["@d$i" for i in 1:64])
    unique!(out)
    return out
end

const _COMBINATOR_NAMES = [
    "pure", "silence", "fast", "slow", "density", "rev", "every",
    "stack", "cat", "mask",
    "gain", "speed", "lpf", "hpf", "pan", "n", "room", "delay",
    "shape", "set",
]
```

Note: candidates are recomputed on every Tab — registry contents can
change live (a `:samples` `[bank]` addition mid-session is rare but
possible, and we don't want stale state).

### `:guide` modal

Today: `:guide` pushes `_GUIDE_LINES` into `m.logs`.

New: `:guide` sets `m.mode = :guide`, `m.guide_scroll = 0`. The view
checks `m.mode === :guide` and renders the overlay (with all of
`_GUIDE_LINES` available, viewport sized to ~70% screen).

`_handle_guide!(m, evt)` handles:

- `j` / `Down`               — `guide_scroll += 1` (clamped)
- `k` / `Up`                 — `guide_scroll -= 1` (clamped to 0)
- `gg`                       — `guide_scroll = 0`
- `G`                        — `guide_scroll = max_scroll`
- `Ctrl-d` / `Ctrl-u`        — half-page scroll
- `/`                        — enter command mode with `/` prefix; on Enter, jump scroll to first matching line; n/N repeat
- `q` / `Esc`                — `m.mode = :normal`
- everything else            — ignored

Search in `:guide` is a thin local variant: rather than re-using the
buffer search machinery (which mutates `cursor_row` on the editor
buffer), we walk `_GUIDE_LINES` and adjust `guide_scroll`.

`:help` and `:?` aliases still apply.

## View layout

```
┌── status bar ─────────────────────────────────────────────┐
│ ressac 0.5cps ▹▹▸▹ │ d1•◦◦◦ │ ev:42 │ NORMAL              │
├── editor pane (70%) ─────────────────────────────────────┤
│ @d1 p"bd hh sn hh" |> gain(0.8)                          │
│ @d2 p"<bd cp>"                                            │
│ █                                                         │
├── command line (1 row, conditional) ──────────────────────┤
│ :sa█                                                      │
├── completion hint (1 row, conditional) ───────────────────┤
│ samples  synths                                           │
├── mode hint (1 row, permanent) ───────────────────────────┤
│ [NORMAL] i|V|:|K|e  |  ? = full help                      │
├── logs (8 rows) ──────────────────────────────────────────┤
│ [INFO] ...                                                │
└───────────────────────────────────────────────────────────┘
```

Conditional rows collapse when not applicable (TUI Layout's `Min(0)`
or by emitting empty widgets).

Overlays (`?` popup or `:guide` modal) render *after* the main layout
in the same frame, drawing centered boxes on top of the editor area.

## Data flow

```
key press
  ↓
_dispatch_key!
  ↓
  if m.mode == :guide          → _handle_guide!  (j/k, q, ...)
  elif m.mode == :normal       → _handle_normal! (+ ? toggle)
  elif m.mode == :insert       → _handle_insert! (+ Tab autocomplete)
  elif m.mode == :command      → _handle_command! (+ Tab autocomplete)
  elif m.mode == :visual_line  → _handle_visual!

# Tab in insert/command mutates m.completions etc.
# ? in normal flips m.show_help.
# :guide in command mode sets m.mode = :guide.
```

## Tests

### `test_tui_hints.jl`

- `_fuzzy_score("sa", "samples") == 0`
- `_fuzzy_score("sa", "snares") == 1`
- `_fuzzy_score("xy", "samples") === nothing`
- `_fuzzy_score("", "anything") == 0`
- `_fuzzy_rank("sa", ["samples", "snares", "savings"])` returns them
  sorted by `(score, length, lexico)`
- `_compute_completions` on `m.command_buffer == ""` returns all
  command names
- `_compute_completions` on `m.command_buffer == "sa"` returns
  `["samples", "synths"]` (or in fuzzy-rank order)
- `_compute_completions` on `m.command_buffer == "samples kic"`
  returns matching sample-bank names

### `test_tui_overlay.jl`

- `_Overlay` rendered into a fixed buffer: lines appear at correct
  positions, border characters draw, title shown.
- Overlay larger than area is capped (no overflow).
- Scroll offset skips lines.

### `test_tui_bindings.jl` (extend)

- `?` in normal mode flips `m.show_help`; `?` again flips back.
- Tab in `:`-mode with `command_buffer == "sa"` and known names
  cycles through matches.
- Tab in `:`-mode with no matches is a no-op (no log spam).
- Tab in insert mode with `:kicky` registered + cursor on `kic`
  replaces "kic" with "kicky".
- Tab in insert mode with multiple candidates inserts the best
  fuzzy match, second Tab cycles.
- Movement after Tab clears `m.completions`.
- `:guide` switches `m.mode` to `:guide`; `q` returns to `:normal`.
- `j` in `:guide` mode increments `guide_scroll`.
- `Ctrl-d` advances scroll by half-page.

## Edge cases & gotchas

- **Tab in insert at start of line**: extracted partial is empty;
  no-op, no inserted tab character. (We never insert literal tab — the
  buffer doesn't support indented Julia.)
- **Backspace mid-completion**: the cleared completion state means
  the partial range is forgotten. If the user typed `kic` then Tab
  cycled to `kicky`, then Backspace, they delete the last char of
  `kicky` (now `kick`). Normal behaviour, no special handling.
- **`?` while `m.show_help` is on**: just toggles back off. Stable.
- **Overlay size > screen**: cap to 80% of area, clip lines. No
  scroll for the `?` popup (kept short); scroll for `:guide`.
- **Empty registries**: `_buffer_candidates` returns only combinators
  + macros. Completion still works for those.

## Out of scope

- Mouse / click
- Syntactic context detection (inside a `p"..."` string vs Julia
  code) — Tab just looks at the word under cursor everywhere
- Snippet expansion / parameterised templates
- Autocomplete for inline `bd:N` variants (variant N is dynamic data
  that doesn't enumerate cleanly)

## Risks

- **Completion noise in :-mode**: hint line updates on every
  keystroke. If recomputation is slow with large registries, perceived
  latency drops. Mitigation: `_fuzzy_rank` is O(candidates × |query|),
  fast for the expected scales (< 200 entries total). Profile if it
  ever shows.
- **Cycle index off-by-one**: classic. Tests cover this.
- **Overlay rendering clipping**: TUI.jl's `Buffer.set` clamps writes,
  but border characters at edges could split mid-codepoint. Stick to
  ASCII for the border.
