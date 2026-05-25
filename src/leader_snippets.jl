# Space-leader snippet expansion + placeholder navigation.
#
# Workflow: in normal mode, Space → trigger char → template expands at
# cursor with the cursor on $1, editor auto-enters insert. Tab jumps
# to $2 / $3 / … (Shift-Tab goes back). Esc exits placeholder mode
# and falls back to standard insert→normal on the second press.
#
# Extracted from app.jl. The model fields driving this (pending_leader,
# placeholder_active, placeholder_row, placeholder_cols, placeholder_idx)
# stay on RessacApp.

"""
    _LEADER_SNIPPETS

Trigger char → template. `\$N` markers are tabstops. Single-line for
now; the placeholder tracker assumes everything fits on the row
where the snippet was inserted. Add multi-line templates only after
extending the tracker to (row, col) tuples.
"""
const _LEADER_SNIPPETS = Dict{Char,String}(
    'd' => "@d\$1 p\"\$2\"",
    'g' => "|> gain(\$1)",
    'l' => "|> lpf(\$1)",
    'h' => "|> hpf(\$1)",
    'p' => "|> pan(\$1)",
    'f' => "|> fast(\$1)",
    's' => "|> slow(\$1)",
    'r' => "|> room(\$1)",
    'n' => "|> n(p\"\$1\")",
    'e' => "|> every(\$1, \$2)",
    'm' => "|> mask(p\"\$1\")",
    'D' => "|> delay(\$1) |> delaytime(\$2) |> delayfeedback(\$3)",
    'c' => "|> cat([p\"\$1\", p\"\$2\"])",
    'S' => "|> stack(p\"\$1\", p\"\$2\")",
    'v' => "rev",     # no placeholder, just inserts as-is
    # ── Euclidean rhythms (Bjorklund k-of-n) ──
    # `E` = generic euclidean token: sample, k, n. Drop it inside a
    # p"…" or as the body of a fresh pattern.  Examples:
    #   Space E → bd Tab 3 Tab 8 → bd(3,8)         # jersey kick
    #   Space E → cp Tab 1 Tab 8 → cp(1,8)         # single clap
    'E' => "\$1(\$2,\$3)",
    # `R` for rotated euclidean — useful for off-beat snares / claps.
    # E.g. Space R → cp Tab 1 Tab 8 Tab 4 → cp(1,8,4)  # clap on beat 3
    'R' => "\$1(\$2,\$3,\$4)",
    # `J` = jersey starter — full @dN line with the iconic 3-against-8
    # kick, ready to eval. Two placeholders: slot id + gain.
    'J' => "@d\$1 p\"bd(3,8)\" |> gain(\$2)",
)

"""
    _LEADER_ACTIONS

Triggers that fire a callback instead of expanding text — useful
for opening pickers / modals. `Space b` → browser, `Space ?` →
guide, etc. Resolved before `_LEADER_SNIPPETS` so they take
priority on the same char.
"""
const _LEADER_ACTIONS = Dict{Char,Function}(
    'b' => m -> _open_browser!(m),       # all sounds (samples + insts + synths)
    'L' => m -> _open_synth_library!(m), # synth library
    '?' => m -> (m.modal = :guide;  m.modal_scroll = 0),
    'w' => m -> _open_wiki!(m),
    'I' => m -> _open_snippets!(m),      # I for "insert snippet" picker
)

"""
    _LEADER_LABELS

Short labels for the footer hint shown while a leader is pending.
Keep each label terse — the footer is one row.
"""
const _LEADER_LABELS = Pair{Char,String}[
    'd' => "slot",   'g' => "gain",   'l' => "lpf",
    'h' => "hpf",    'p' => "pan",    'f' => "fast",
    's' => "slow",   'r' => "room",   'n' => "n()",
    'e' => "every",  'm' => "mask",   'D' => "delay-chain",
    'c' => "cat",    'S' => "stack",  'v' => "rev",
    'E' => "eucl",   'R' => "eucl-rot", 'J' => "jersey",
    # ── pickers ──
    'b' => "▸browse-sounds", 'L' => "▸synth-lib", 'I' => "▸snippets",
    'w' => "▸wiki",  '?' => "▸guide",
]

"""
    _parse_snippet_template(tpl) -> (text::String, placeholder_cols::Vector{Int})

Strip `\$N` markers and return the bare text plus the column
positions (0-based, relative to text start) where each placeholder
ends up. Markers must be `\$` followed by a single digit.
"""
function _parse_snippet_template(tpl::AbstractString)
    out = IOBuffer()
    cols = Tuple{Int,Int}[]  # (placeholder_idx, col_in_text)
    i = firstindex(tpl)
    col = 0
    while i <= ncodeunits(tpl)
        c = tpl[i]
        if c == '$' && i < ncodeunits(tpl) && isdigit(tpl[i+1])
            n = parse(Int, string(tpl[i+1]))
            push!(cols, (n, col))
            i = nextind(tpl, i, 2)
        else
            print(out, c)
            col += 1
            i = nextind(tpl, i)
        end
    end
    sort!(cols; by = first)
    return (String(take!(out)), [c for (_, c) in cols])
end

"""
    _expand_snippet!(m, ed, template)

Insert `template`'s text at the cursor, record placeholder positions,
move the cursor onto the first one, and switch to insert mode with
placeholder tracking armed. Templates without placeholders just get
inserted and we stay in normal mode (no nav needed).
"""
function _expand_snippet!(m::RessacApp, ed::TK.CodeEditor, template::AbstractString)
    text, ph_offsets = _parse_snippet_template(template)
    # Insert text at cursor on the current row.
    row = ed.cursor_row
    col = ed.cursor_col
    1 <= row <= length(ed.lines) || return
    line = String(ed.lines[row])
    new_line = line[1:col] * text * line[col+1:end]
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    lines[row] = new_line
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row
    if isempty(ph_offsets)
        ed.cursor_col = col + length(text)
        return
    end
    # Absolute placeholder columns = insert column + relative offset.
    m.placeholder_row    = row
    m.placeholder_cols   = [col + off for off in ph_offsets]
    m.placeholder_idx    = 1
    m.placeholder_active = true
    ed.cursor_col = m.placeholder_cols[1]
    ed.mode = :insert
end

"""
    _placeholder_jump!(m, ed, dir)

Move to the next (`dir = +1`) or previous (`dir = -1`) placeholder.
Going past the last placeholder exits placeholder mode (stays in
insert so the user can keep typing).
"""
function _placeholder_jump!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    m.placeholder_active || return false
    new_idx = m.placeholder_idx + dir
    if new_idx < 1 || new_idx > length(m.placeholder_cols)
        m.placeholder_active = false
        return true
    end
    m.placeholder_idx = new_idx
    ed.cursor_row = m.placeholder_row
    ed.cursor_col = clamp(m.placeholder_cols[new_idx], 0, length(ed.lines[m.placeholder_row]))
    return true
end

"""
    _placeholder_track_change!(m, ed, pre_len)

Called after a buffer-modifying key in insert mode while
`placeholder_active`. Adjusts all placeholder columns after the
cursor by the delta `(post_len - pre_len)` so they stay aligned as
the user fills in text. Also deactivates if the user moved to a
different row.
"""
function _placeholder_track_change!(m::RessacApp, ed::TK.CodeEditor, pre_len::Int)
    m.placeholder_active || return
    if ed.cursor_row != m.placeholder_row
        m.placeholder_active = false; return
    end
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || (m.placeholder_active = false; return)
    post_len = length(ed.lines[row])
    delta = post_len - pre_len
    delta == 0 && return
    cur = ed.cursor_col
    # Shift placeholders that sit at or after the cursor by delta.
    # Don't move the placeholder the user is currently filling — only
    # the ones AHEAD so they don't slide under typed text.
    for i in eachindex(m.placeholder_cols)
        i == m.placeholder_idx && continue
        if m.placeholder_cols[i] >= cur
            m.placeholder_cols[i] += delta
        end
    end
end
