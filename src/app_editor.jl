# src/app_editor.jl
# Édition de texte côté app : motions vim (w/b/e, opérateurs), défilement,
# nudge des nombres sous le curseur, raccourcis pattern (:sg0.9…), style
# du curseur. Ne dépend pas du scheduler.

"""
    _try_nudge_at!(m, ed, row, col, step) -> Bool

Find the numeric literal that COVERS the (row, col) coordinate and
nudge it by `step`. Returns true if a number was found and nudged.
Doesn't touch the keyboard cursor — useful for wheel-over-number
hover.
"""
function _try_nudge_at!(m::RessacApp, ed::TK.CodeEditor, row::Int, col::Int, step::Int)
    1 <= row <= length(ed.lines) || return false
    line = String(ed.lines[row])
    best = nothing
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        s - 1 <= col <= e && (best = mt; break)
    end
    best === nothing && return false
    txt = best.match
    s = best.offset
    e = s + length(txt) - 1
    is_float = occursin('.', txt)
    new_str = if is_float
        delta = abs(step) == 10 ? (step > 0 ? 0.1 : -0.1) : Float64(step)
        val = parse(Float64, txt) + delta
        dot = findfirst('.', txt)
        decimals = length(txt) - dot
        string(round(val; digits = decimals))
    else
        string(parse(Int, txt) + step)
    end
    new_line = (s > 1 ? line[1:s-1] : "") * new_str *
               (e >= lastindex(line) ? "" : line[e+1:end])
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    _push_app_log!(m, "[INFO] nudge $txt → $new_str  @ row $row")
    return true
end

"""
    _try_scale_at!(m, ed, row, col, factor) -> Bool

Multiplicative nudge of the number under (row, col) by `factor` (e.g.
`2.0` for `*`, `0.5` for `/`). Integer values round to int; floats
keep their decimal places. Returns true iff a number was found.
"""
function _try_scale_at!(m::RessacApp, ed::TK.CodeEditor,
                        row::Int, col::Int, factor::Float64)
    1 <= row <= length(ed.lines) || return false
    line = String(ed.lines[row])
    best = nothing
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        s - 1 <= col <= e && (best = mt; break)
    end
    best === nothing && return false
    txt = best.match
    s = best.offset
    e = s + length(txt) - 1
    is_float = occursin('.', txt)
    new_str = if is_float
        val = parse(Float64, txt) * factor
        dot = findfirst('.', txt)
        decimals = length(txt) - dot
        string(round(val; digits = decimals))
    else
        string(Int(round(parse(Int, txt) * factor)))
    end
    new_line = (s > 1 ? line[1:s-1] : "") * new_str *
               (e >= lastindex(line) ? "" : line[e+1:end])
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    _push_app_log!(m, "[INFO] scale $txt → $new_str  @ row $row")
    return true
end

"""
    _viewport_h(m, ed) -> Int

Visible-line height of the pane currently hosting `ed`. Falls back to
a conservative 20 if no layout has been recorded yet (first frame).
"""
function _viewport_h(m::RessacApp, ed::TK.CodeEditor)
    rect = _focused_editor_rect(m)
    rect === nothing && return 20
    return max(1, rect.height)
end

"""
    _word_motion!(ed, dir, kind)

Move the cursor by one word and keep its SCREEN row stable. `dir`=`+1`
forward (w/W), `-1` back (b/B). `kind`=`:small` uses letter+digit+`_`
as word chars (TK lowercase semantics, but always advances and wraps
lines); `:big` uses whitespace as the only separator (vim W/B).

Screen-row preservation: whatever the visible offset of the cursor
was before, it's the same after. The view follows the cursor, never
the other way around — no surprise re-centering when crossing a
buffer-page boundary.
"""
function _word_motion!(ed::TK.CodeEditor, dir::Int, kind::Symbol)
    n_rows = length(ed.lines)
    n_rows == 0 && return

    is_space(c) = c == ' ' || c == '\t'
    is_word(c) = kind === :big ? !is_space(c) :
                                 (isletter(c) || isdigit(c) || c == '_')
    # For :small motion we have THREE classes (word, punct, space).
    # For :big motion we have TWO (non-space, space).
    function classify(c)
        is_space(c) && return :sp
        is_word(c)  && return :wd
        return :pn
    end

    pre_screen_row = ed.cursor_row - ed.scroll_offset
    row = ed.cursor_row
    line = ed.lines[row]
    n = length(line)
    pos = ed.cursor_col + 1   # 1-based

    if dir > 0
        # Forward — skip current class run, then any whitespace, wrap
        # across lines until we land on a non-space char (or EOF).
        if 1 <= pos <= n
            cls = classify(line[pos])
            if cls === :wd
                while pos <= n && is_word(line[pos]); pos += 1; end
            elseif cls === :pn
                while pos <= n && !is_word(line[pos]) && !is_space(line[pos]); pos += 1; end
            end
        end
        while true
            while pos <= n && is_space(line[pos]); pos += 1; end
            if pos > n
                if row < n_rows
                    row += 1; line = ed.lines[row]; n = length(line); pos = 1
                else
                    pos = max(n, 1)
                    break
                end
            else
                break
            end
        end
    else
        # Backward — step back at least one char, skip whitespace
        # (wrapping lines), then back to the start of the current class.
        if pos > 1
            pos -= 1
        elseif row > 1
            row -= 1; line = ed.lines[row]; n = length(line); pos = max(n, 1)
        end
        while true
            while pos > 0 && is_space(line[pos])
                pos -= 1
            end
            if pos == 0
                if row > 1
                    row -= 1; line = ed.lines[row]; n = length(line); pos = n
                else
                    pos = 1; break
                end
            else
                break
            end
        end
        # Step back to start of the class run we just landed on.
        if pos > 0
            cls = classify(line[pos])
            if cls === :wd
                while pos > 1 && is_word(line[pos - 1]); pos -= 1; end
            elseif cls === :pn
                while pos > 1 && !is_word(line[pos - 1]) && !is_space(line[pos - 1])
                    pos -= 1
                end
            end
        end
    end

    line_len = length(ed.lines[row])
    ed.cursor_row = row
    ed.cursor_col = clamp(pos - 1, 0, max(line_len - 1, 0))
    # Re-anchor scroll_offset so cursor stays on the SAME screen row.
    ed.scroll_offset = max(0, ed.cursor_row - pre_screen_row)
    return
end

"""
    _word_end_motion!(ed, kind)

Land on the LAST char of the current word (or the next word if on
whitespace). `kind=:small` honours the word-class boundary (alnum +
`_` vs punctuation); `:big` treats whitespace as the only separator.
Used by `e` / `E` and by the `cw` / `cW` operator combos (vim quirk
where cw acts like ce).
"""
function _word_end_motion!(ed::TK.CodeEditor, kind::Symbol)
    n_rows = length(ed.lines)
    n_rows == 0 && return
    is_space(c) = c == ' ' || c == '\t'
    is_word(c) = kind === :big ? !is_space(c) :
                                 (isletter(c) || isdigit(c) || c == '_')

    row = ed.cursor_row
    line = ed.lines[row]
    n = length(line)
    pos = ed.cursor_col + 1   # 1-based

    # If on space (or past EOL), advance to next non-space — possibly
    # wrapping across lines.
    if pos > n || (pos >= 1 && is_space(line[pos]))
        while true
            while pos <= n && is_space(line[pos]); pos += 1; end
            if pos > n
                if row < n_rows
                    row += 1; line = ed.lines[row]; n = length(line); pos = 1
                else
                    pos = max(n, 1); break
                end
            else
                break
            end
        end
    end
    if pos < 1 || pos > n
        ed.cursor_row = row
        ed.cursor_col = max(n - 1, 0)
        return
    end

    # On a non-space char — extend forward through the current class run.
    cls_is_word = is_word(line[pos])
    if cls_is_word
        while pos < n && is_word(line[pos + 1]); pos += 1; end
    else
        while pos < n && !is_word(line[pos + 1]) && !is_space(line[pos + 1])
            pos += 1
        end
    end

    ed.cursor_row = row
    ed.cursor_col = clamp(pos - 1, 0, max(n - 1, 0))
    return
end

"""
    _big_word_motion!(ed, dir, target)

Legacy E (end-of-word) motion, kept for the `E` key wire-up. Forward-
only, lands on the last char of the current/next word.
"""
function _big_word_motion!(ed::TK.CodeEditor, dir::Int, target::Symbol)
    is_space(c) = c == ' ' || c == '\t'
    n_rows = length(ed.lines)
    n_rows == 0 && return
    row = ed.cursor_row
    col = ed.cursor_col  # 0-based
    line = ed.lines[row]

    # Convert to 1-based pos in current line; handle line wraps as we go.
    pos = col + 1
    line_len = length(line)

    if dir > 0
        # Forward: W → next word start ; E → next word end.
        if target === :start
            # Skip the current non-space run, then any whitespace.
            while pos <= line_len && !is_space(line[pos]); pos += 1; end
            while pos <= line_len && is_space(line[pos]); pos += 1; end
            while pos > line_len && row < n_rows
                row += 1; line = ed.lines[row]; line_len = length(line); pos = 1
                while pos <= line_len && is_space(line[pos]); pos += 1; end
            end
        else  # :end
            # If already at/past end of current word, advance into next.
            if pos > line_len || is_space(line[pos])
                while pos <= line_len && is_space(line[pos]); pos += 1; end
                while pos > line_len && row < n_rows
                    row += 1; line = ed.lines[row]; line_len = length(line); pos = 1
                    while pos <= line_len && is_space(line[pos]); pos += 1; end
                end
            elseif pos < line_len && is_space(line[pos + 1])
                # On last char of a word — jump to next.
                while pos <= line_len && !is_space(line[pos]); pos += 1; end
                while pos <= line_len && is_space(line[pos]); pos += 1; end
                while pos > line_len && row < n_rows
                    row += 1; line = ed.lines[row]; line_len = length(line); pos = 1
                    while pos <= line_len && is_space(line[pos]); pos += 1; end
                end
            end
            # Now pos is the first char of a word — advance to its end.
            while pos < line_len && !is_space(line[pos + 1]); pos += 1; end
        end
    else
        # Backward (B): move to previous word's start.
        if pos > 1
            pos -= 1
            while pos > 0 && is_space(line[pos]); pos -= 1; end
            while pos > 1 && !is_space(line[pos - 1]); pos -= 1; end
        elseif row > 1
            row -= 1; line = ed.lines[row]; line_len = length(line)
            pos = line_len
            while pos > 0 && is_space(line[pos]); pos -= 1; end
            while pos > 1 && !is_space(line[pos - 1]); pos -= 1; end
        end
    end

    pos = clamp(pos, 1, max(line_len, 1))
    ed.cursor_row = row
    ed.cursor_col = clamp(pos - 1, 0, max(line_len - 1, 0))
    return
end

"""
    _op_with_motion!(m, ed, op::Char, motion::Char)

Run a vim operator-motion combo (`cw`/`dw`/`yw`/`cW`/`dW`/`yW`/`ce`/
`de`/`ye`/`cE`/`dE`/`yE`). Computes the motion's target, deletes (or
yanks) the range from the cursor to that target, and — for `c` —
drops into insert mode. **Preserves `scroll_offset` end-to-end** so
the buffer view stays put even though the text mutated.

Notes:
  * `cw` follows vim convention and behaves like `ce` (deletes to the
    end of the word, NOT to the start of the next one — keeps the
    trailing whitespace alone).
  * `dw`/`yw` use the start-of-next-word target.
"""
function _op_with_motion!(m::RessacApp, ed::TK.CodeEditor,
                          op::Char, motion::Char)
    kind = (motion in ('W', 'B', 'E')) ? :big : :small
    dir  = (motion in ('w', 'W', 'e', 'E')) ? +1 : -1
    # Vim quirk: cw / cW target END of word, not start-of-next.
    use_end = (motion in ('e', 'E')) || (op == 'c' && motion in ('w', 'W'))

    saved_scroll = ed.scroll_offset
    src_row, src_col = ed.cursor_row, ed.cursor_col

    # Compute the target by running the motion on a tiny clone so the
    # real editor state is untouched until we apply the edit.
    probe = TK.CodeEditor()
    TK.set_text!(probe, TK.text(ed))
    probe.cursor_row = src_row
    probe.cursor_col = src_col
    if use_end
        _word_end_motion!(probe, kind)
        dst_row = probe.cursor_row
        dst_col = probe.cursor_col + 1   # +1 = exclusive end (include last word char)
    else
        _word_motion!(probe, dir, kind)
        dst_row = probe.cursor_row
        dst_col = probe.cursor_col
    end

    # Normalise so (src) <= (dst) — backward motions (b/B) flip.
    if (dst_row, dst_col) < (src_row, src_col)
        src_row, src_col, dst_row, dst_col = dst_row, dst_col, src_row, src_col
    end
    if src_row == dst_row && src_col == dst_col
        return
    end

    # Build the yanked text. Char-wise yank (yank_is_linewise=false).
    lines = collect(split(TK.text(ed), '\n'; keepempty = true))
    dst_col = clamp(dst_col, 0, length(lines[dst_row]))
    src_col = clamp(src_col, 0, length(lines[src_row]))
    yanked_str = if src_row == dst_row
        SubString(lines[src_row], src_col + 1, dst_col)
    else
        first_part = SubString(lines[src_row], src_col + 1, length(lines[src_row]))
        middle = src_row + 1 <= dst_row - 1 ?
                 lines[src_row + 1 : dst_row - 1] : SubString{String}[]
        last_part = SubString(lines[dst_row], 1, dst_col)
        join([first_part, middle..., last_part], '\n')
    end
    ed.yank_buffer = [collect(line) for line in split(yanked_str, '\n')]
    ed.yank_is_linewise = false

    if op == 'y'
        # Yank only — leave cursor at the original position (vim quirk
        # for character-wise yank).
        ed.cursor_row = src_row
        ed.cursor_col = src_col
        ed.scroll_offset = saved_scroll
        _push_app_log!(m, "[INFO] $op$motion — $(length(yanked_str)) caractère(s) copié(s)")
        return
    end

    # Delete the range. Rebuild affected lines, then collapse.
    if src_row == dst_row
        lines[src_row] = lines[src_row][1:src_col] *
                         lines[src_row][dst_col + 1 : end]
    else
        lines[src_row] = lines[src_row][1:src_col] *
                         lines[dst_row][dst_col + 1 : end]
        deleteat!(lines, src_row + 1 : dst_row)
    end
    isempty(lines) && push!(lines, "")

    # `set_text!` resets scroll_offset to 0 — save & restore.
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = clamp(src_row, 1, length(ed.lines))
    ed.cursor_col = clamp(src_col, 0,
                          max(length(ed.lines[ed.cursor_row]) - 1, 0))
    ed.scroll_offset = saved_scroll

    if op == 'c'
        ed.mode = :insert
    end
    _push_app_log!(m, "[INFO] $op$motion fait")
    return
end

"""
    _page_scroll!(m, ed, delta)

Move both cursor and `scroll_offset` by `delta` rows so the cursor
stays at the same screen position. Unlike vim's `j`-times-N which
auto-recenters on overshoot, this keeps the view stable when the
cursor hits buffer edges.
"""
function _page_scroll!(m::RessacApp, ed::TK.CodeEditor, delta::Int)
    n = length(ed.lines)
    n == 0 && return
    new_row = clamp(ed.cursor_row + delta, 1, n)
    actual = new_row - ed.cursor_row
    ed.cursor_row = new_row
    ed.scroll_offset = max(0, ed.scroll_offset + actual)
    ed.cursor_col = clamp(ed.cursor_col, 0,
                          max(0, length(ed.lines[ed.cursor_row])))
    return
end

# ---------------------------------------------------------------------
# Pattern shortcut DSL — `:s<verb><args>[N]` and `:sn<verb><args>[N]`
# ---------------------------------------------------------------------
#
# Compact ex-commands to append common combinators to the current line
# without leaving normal mode for long. Each call expands to
# " |> verb(args)" appended to the cursor's line. A leading `n`
# (`:sn…`) inserts a newline BEFORE the snippet so the appended call
# lands on its own line under the pattern; a trailing `N` (`:s…N`)
# adds a newline AFTER, leaving the cursor on a fresh line for the
# next thought.

const _SHORTCUT_VERBS = Dict{String,String}(
    "g"  => "gain",      "l" => "lpf",       "h"  => "hpf",
    "p"  => "pan",       "f" => "fast",      "w"  => "slow",
    "r"  => "room",      "d" => "delay",     "s"  => "shape",
    "t"  => "gate",      "o" => "octave",    "c"  => "cutoff",
    "q"  => "resonance", "rv" => "rev",      "sp" => "speed",
)

# Sorted so longer verbs match first (gt/rv/sp before single chars).
const _SHORTCUT_RX = let
    verbs = sort(collect(keys(_SHORTCUT_VERBS)); by=length, rev=true)
    Regex("^s(n?)(" * join(verbs, "|") * ")([0-9.\\s\\-]*)(N?)\$")
end

"""
    _apply_pattern_shortcut!(m, nl_before, verb, args, nl_after)

Translate a shortcut into ` |> <fn>(<args>)` and splice it into the
buffer at the cursor's row. The `t` verb interprets its args as a
bitstring (e.g. "010110") and expands to `gate(p"0 1 0 1 1 0")`.
"""
function _apply_pattern_shortcut!(m::RessacApp, nl_before::Bool,
                                  verb::String, args::AbstractString,
                                  nl_after::Bool)
    ed = _active_editor(m)
    full_verb = _SHORTCUT_VERBS[verb]
    snippet = if verb == "t"
        bits = filter(c -> c == '0' || c == '1', args)
        spaced = join(string.(collect(bits)), " ")
        isempty(spaced) ?
            " |> gate(p\"\")" :
            " |> gate(p\"$(spaced)\")"
    elseif isempty(args)
        " |> $(full_verb)()"
    else
        " |> $(full_verb)($(args))"
    end
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(lines))
    line = String(lines[row])
    if nl_before
        # Snippet lands on a NEW line under the current one. Source
        # indent + 4 extra spaces visually marks it as a continuation
        # of the pipeline started above.
        base_indent = length(line) - length(lstrip(line))
        indent = " " ^ (base_indent + 4)
        insert!(lines, row + 1, indent * lstrip(snippet))
        ed.cursor_row = row + 1
        ed.cursor_col = length(lines[row + 1])
    else
        lines[row] = line * snippet
        ed.cursor_col = length(lines[row])
    end
    if nl_after
        # Same indentation as the line we just wrote, so the next
        # snippet the user adds chains visually too.
        base_indent = ed.cursor_row <= length(lines) ?
            length(lines[ed.cursor_row]) - length(lstrip(lines[ed.cursor_row])) : 0
        next_indent = " " ^ (nl_before ? base_indent : base_indent + 4)
        insert!(lines, ed.cursor_row + 1, next_indent)
        ed.cursor_row += 1
        ed.cursor_col = length(next_indent)
    end
    TK.set_text!(ed, join(lines, '\n'))
    _push_app_log!(m, "[INFO] raccourci → $(strip(snippet))")
end


# Number-nudge regex: optional sign, digits, optional fractional part.
# Anchored at the START of the candidate span, not the line — we'll
# scan around the cursor for the nearest match.
const _NUMBER_RX = r"-?\d+(?:\.\d+)?"

"""
    _has_number_under_cursor(ed) -> Bool

True iff the cursor sits inside a numeric literal — used to decide
whether + / - in normal mode should nudge the value or fall through
to scope zoom. Cheap: a regex scan of one line.
"""
function _has_number_under_cursor(ed::TK.CodeEditor)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return false
    line = String(ed.lines[row])
    col = ed.cursor_col
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        s - 1 <= col <= e && return true
    end
    return false
end

"""
    _nudge_number_under_cursor!(m, ed, step)

Find a numeric literal touching the cursor and add `step` to it. Ints
get +/- step as-is; floats get scaled (step=±10 → ±0.1, step=±1 →
±1.0) so the nudge keys behave intuitively across both. Preserves the
number's decimal precision (1.20 stays two-decimal).
"""
function _nudge_number_under_cursor!(m::RessacApp, ed::TK.CodeEditor, step::Int)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return
    line = String(ed.lines[row])
    col = ed.cursor_col
    # Find the number-match whose span covers col, or the nearest one.
    best = nothing
    for mt in eachmatch(_NUMBER_RX, line)
        s = mt.offset
        e = s + length(mt.match) - 1
        if s - 1 <= col <= e   # 0-based col vs 1-based offsets
            best = mt
            break
        end
    end
    best === nothing && return
    txt = best.match
    s = best.offset
    e = s + length(txt) - 1
    is_float = occursin('.', txt)
    new_str = if is_float
        delta = abs(step) == 10 ? (step > 0 ? 0.1 : -0.1) : Float64(step)
        val = parse(Float64, txt) + delta
        # Preserve precision of the original (count decimals).
        dot = findfirst('.', txt)
        decimals = length(txt) - dot
        # Round to that many decimals to avoid 0.1+0.2 floating noise.
        rounded = round(val; digits = decimals)
        # Format with fixed decimals so "1.2 → 1.3" keeps one digit.
        string(rounded)
    else
        val = parse(Int, txt) + step
        string(val)
    end
    new_line = (s > 1 ? line[1:s-1] : "") * new_str *
               (e >= lastindex(line) ? "" : line[e+1:end])
    TK.set_text!(ed, _set_one_line(ed, row, new_line))
    ed.cursor_row = row
    # Keep cursor on the same logical position relative to the number's start.
    ed.cursor_col = clamp(col + (length(new_str) - length(txt)), 0,
                          length(ed.lines[row]))
    _push_app_log!(m, "[INFO] nudge $txt → $new_str")
end

"""
    _set_one_line(ed, row, new_line) -> joined text

Build the full buffer text with `row` replaced by `new_line`. Helper
for nudge so we don't have to expand split/join inline at the call
site.
"""
function _set_one_line(ed::TK.CodeEditor, row::Int, new_line::AbstractString)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    1 <= row <= length(lines) || return txt
    lines[row] = String(new_line)
    return join(lines, '\n')
end

"""
    _char_split(line, col) -> (prefix, suffix)

Split `line` at character position `col` (0-based, char count not
byte count). Safe with multi-byte UTF-8 — never indexes by byte.
The cursor model used by Tachikoma's CodeEditor is char-based, so
any string mutation derived from cursor positions must split here
rather than via `line[1:col]`.
"""
function _char_split(line::AbstractString, col::Int)
    col <= 0 && return ("", String(line))
    pre = IOBuffer(); n = 0; byte_idx = firstindex(line)
    for c in line
        n >= col && break
        print(pre, c); n += 1
        byte_idx = nextind(line, byte_idx)
    end
    suf = byte_idx > ncodeunits(line) ? "" :
          String(SubString(line, byte_idx))
    return (String(take!(pre)), suf)
end

"""
    _sync_cursor_style!(ed)

Vim-style caret: distinct colour per mode so the user can see at a
glance whether they're in `:normal`, `:insert`, `:command`, or visual.
Insert lights the accent in warning; normal stays default accent
block; command uses :title; visual uses :success.
"""
function _sync_cursor_style!(ed::TK.CodeEditor)
    th = TK.theme()
    ed.cursor_style = if ed.mode === :insert
        TK.Style(; fg = th.bg, bg = th.warning, bold = true)
    elseif ed.mode === :command
        TK.Style(; fg = th.bg, bg = th.title,   bold = true)
    elseif ed.mode === :search
        TK.Style(; fg = th.bg, bg = th.warning)
    else  # :normal (and visual modes — we paint the selection separately)
        TK.Style(; fg = th.bg, bg = th.accent,  bold = true)
    end
    return ed
end
