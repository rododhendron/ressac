# src/app_editor.jl
# Édition de texte côté app : motions vim (w/b/e, opérateurs), défilement,
# nudge des nombres sous le curseur, raccourcis pattern (:sg0.9…), style
# du curseur. Ne dépend pas du scheduler.

# ── Les nombres sous le curseur ──────────────────────────────────────
# Number-nudge regex: optional sign, digits, optional fractional part.
const _NUMBER_RX = r"-?\d+(?:\.\d+)?"

"""
    _number_at(ed, row, col) -> (first, last, text) | nothing

Le littéral numérique de la ligne `row` qui couvre la colonne `col` (ou
dont elle touche le bord gauche). `first` et `last` sont des colonnes de
caractères 0-based, `last` exclu — les mêmes unités que le curseur, quels
que soient les accents à gauche.
"""
function _number_at(ed::TK.CodeEditor, row::Int, col::Int)
    1 <= row <= length(ed.lines) || return nothing
    line = String(ed.lines[row])
    for mt in eachmatch(_NUMBER_RX, line)
        (first, last) = _char_span(line, mt)
        # dedans, ou juste après son dernier chiffre
        first <= col <= last && return (first, last, String(mt.match))
    end
    return nothing
end

# Le nombre après un pas de `step` : un entier bouge de `step` ; un flottant
# garde sa précision d'écriture (±10 → ±0.1, ±1 → ±1.0).
function _nudged_number(txt::AbstractString, step::Int)
    occursin('.', txt) || return string(parse(Int, txt) + step)
    delta = abs(step) == 10 ? (step > 0 ? 0.1 : -0.1) : Float64(step)
    decimals = length(txt) - findfirst('.', txt)
    return string(round(parse(Float64, txt) + delta; digits = decimals))
end

# Remplace le nombre trouvé par `_number_at` ; rend la nouvelle écriture.
function _replace_number!(ed::TK.CodeEditor, row::Int, found, step::Int; col::Union{Nothing,Int} = nothing)
    (first, last, txt) = found
    new_str = _nudged_number(txt, step)
    lines = _buffer_lines(ed)
    splice!(lines[row], (first + 1):last, collect(new_str))
    _edit_lines!(ed, lines; row = col === nothing ? nothing : row, col = col)
    return new_str
end

"""
    _try_nudge_at!(m, ed, row, col, step) -> Bool

Find the numeric literal that COVERS the (row, col) coordinate and
nudge it by `step`. Returns true if a number was found and nudged.
Doesn't touch the keyboard cursor — useful for wheel-over-number
hover.
"""
function _try_nudge_at!(m::RessacApp, ed::TK.CodeEditor, row::Int, col::Int, step::Int)
    found = _number_at(ed, row, col)
    found === nothing && return false
    playing = _slot_playing_at(m, ed, row)
    new_str = _replace_number!(ed, row, found, step)
    _after_nudge!(m, ed, row, playing)
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
    _op_with_motion!(m, ed, op::Char, motion::Char)

Run a vim operator-motion combo (`cw`/`dw`/`yw`/`cW`/`dW`/`yW`/`ce`/
`de`/`ye`/`cE`/`dE`/`yE`, and the end / start of line forms `d\$`, `c\$`, `y\$`, `d0`, `c0`, `y0`). Computes the motion's target, deletes (or
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
    _load_text!(probe, TK.text(ed))
    probe.cursor_row = src_row
    probe.cursor_col = src_col
    if motion == '$'            # jusqu'à la fin de la ligne
        dst_row = src_row
        dst_col = length(ed.lines[src_row])
    elseif motion == '0'        # jusqu'au début de la ligne
        dst_row = src_row
        dst_col = 0
    elseif use_end
        _word_end_motion!(probe, kind)
        dst_row = probe.cursor_row
        dst_col = probe.cursor_col + 1   # +1 = exclusive end (include last word char)
    else
        _word_motion!(probe, dir, kind)
        dst_row = probe.cursor_row
        dst_col = probe.cursor_col
        if dir > 0
            # Comme vim, sur le dernier mot d'une ligne `dw` s'arrête à la
            # fin de la ligne : il ne recolle pas la suivante, et il ne
            # laisse pas le dernier caractère (le mouvement `w`, faute de
            # mot suivant, s'était posé dessus).
            line = ed.lines[src_row]
            cls(c) = isspace(c) ? 0 : (kind === :big || isletter(c) || isdigit(c) || c == '_') ? 1 : 2
            stuck = dst_row == src_row && dst_col == length(line) - 1 && src_col < length(line) &&
                    all(c -> cls(c) == cls(line[src_col + 1]), @view line[(src_col + 1):(dst_col + 1)])
            if dst_row > src_row || stuck
                dst_row = src_row
                dst_col = length(line)
            end
        end
    end

    # Normalise so (src) <= (dst) — backward motions (b/B) flip.
    if (dst_row, dst_col) < (src_row, src_col)
        src_row, src_col, dst_row, dst_col = dst_row, dst_col, src_row, src_col
    end
    if src_row == dst_row && src_col == dst_col
        return
    end

    # Le texte visé, en caractères (les colonnes du curseur en sont).
    lines = _buffer_lines(ed)
    dst_col = clamp(dst_col, 0, length(lines[dst_row]))
    src_col = clamp(src_col, 0, length(lines[src_row]))
    yanked = if src_row == dst_row
        Vector{Char}[lines[src_row][(src_col + 1):dst_col]]
    else
        vcat(Vector{Char}[lines[src_row][(src_col + 1):end]],
             lines[(src_row + 1):(dst_row - 1)],
             Vector{Char}[lines[dst_row][1:dst_col]])
    end
    ed.yank_buffer = yanked
    ed.yank_is_linewise = false
    n_chars = sum(length, yanked) + length(yanked) - 1

    if op == 'y'
        # Yank only — leave cursor at the original position (vim quirk
        # for character-wise yank).
        ed.cursor_row = src_row
        ed.cursor_col = src_col
        ed.scroll_offset = saved_scroll
        _push_app_log!(m, "[INFO] $op$motion — $(n_chars) caractère(s) copié(s)")
        return
    end

    # Delete the range: the head of the first line joins the tail of the last.
    lines[src_row] = vcat(lines[src_row][1:src_col], lines[dst_row][(dst_col + 1):end])
    src_row == dst_row || deleteat!(lines, (src_row + 1):dst_row)
    # En mode normal le curseur ne dépasse pas le dernier caractère ; pour
    # `c` (on passe en insertion) il peut se poser juste après.
    last_col = op == 'c' ? length(lines[src_row]) : max(length(lines[src_row]) - 1, 0)
    _edit_lines!(ed, lines; row = src_row, col = min(src_col, last_col))

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
    _edit_text!(ed, join(lines, '\n'))
    _push_app_log!(m, "[INFO] raccourci → $(strip(snippet))")
end


"""
    _has_number_under_cursor(ed) -> Bool

True iff the cursor sits inside a numeric literal — used to decide
whether + / - in normal mode should nudge the value or fall through
to scope zoom.
"""
_has_number_under_cursor(ed::TK.CodeEditor) = _number_at(ed, ed.cursor_row, ed.cursor_col) !== nothing

"""
    _nudge_number_under_cursor!(m, ed, step)

Find a numeric literal touching the cursor and add `step` to it. Ints
get +/- step as-is; floats get scaled (step=±10 → ±0.1, step=±1 →
±1.0) so the nudge keys behave intuitively across both. Preserves the
number's decimal precision (1.20 stays two-decimal).
"""
function _nudge_number_under_cursor!(m::RessacApp, ed::TK.CodeEditor, step::Int)
    row, col = ed.cursor_row, ed.cursor_col
    found = _number_at(ed, row, col)
    found === nothing && return
    txt = found[3]
    # Le curseur garde sa place par rapport au début du nombre.
    new_str = _nudged_number(txt, step)
    playing = _slot_playing_at(m, ed, row)
    _replace_number!(ed, row, found, step; col = max(0, col + (length(new_str) - length(txt))))
    _after_nudge!(m, ed, row, playing)
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
