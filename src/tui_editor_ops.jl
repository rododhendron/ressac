# Editor ops — vim word motions + visual modes (line + char) +
# `.` repeat. Plus the small `_slots_in_text` / `_unschedule_removed_slots!`
# helpers used by the visual-delete path to keep the scheduler in
# sync with buffer deletions.
#
# Block A (word motions / operator combos):  _word_bounds,
#   _vim_word_motion!, _vim_op_motion! — used when the user types
#   cw / dw / yw / c$ / d0 / etc. in the patterns/synth pane.
#
# Block B (visual modes + . repeat):  _visual_handle!,
#   _visual_apply! (line + char variants), _slots_in_text,
#   _unschedule_removed_slots! (mutes the audio when a @dN line is
#   deleted), _vim_record_keystroke!, _vim_post_normal!, _vim_replay!.
#
# Extracted from app.jl; depends on RessacApp, _push_app_log!,
# _set_one_line, _char_split — all defined earlier in app.jl by the
# time this file is included.

# ---------------------------------------------------------------------
# Vim word motions + operator combos (cw / dw / yw / c$ / d0 / …)
# ---------------------------------------------------------------------

"""
    _word_bounds(line, col, big=false) -> (start, stop)

Return the half-open [start, stop) range of the word at/after `col`
(0-based). `big` selects WORD (whitespace-delimited) vs word
(alphanumeric-delimited). Matches vim's `w` motion: jumps to the
next word's first char, deleting up through but not including the
following whitespace.
"""
function _word_bounds(line::AbstractString, col::Int; big::Bool=false)
    n = length(line)
    is_word = if big
        c -> !isspace(c)
    else
        c -> isletter(c) || isdigit(c) || c == '_'
    end
    col = clamp(col, 0, n)
    # Skip current word
    i = col + 1
    while i <= n && is_word(line[i]); i += 1; end
    # Skip whitespace
    while i <= n && isspace(line[i]); i += 1; end
    stop = i - 1
    return (col, stop)
end

"""
    _word_back_bounds(line, col, big=false) -> col

Position of the previous word's first char.
"""
function _word_back_bounds(line::AbstractString, col::Int; big::Bool=false)
    n = length(line)
    is_word = big ? (c -> !isspace(c)) :
                    (c -> isletter(c) || isdigit(c) || c == '_')
    col = clamp(col, 0, n)
    col == 0 && return 0
    i = col
    # Step back past whitespace
    while i > 0 && i <= n && isspace(line[i]); i -= 1; end
    # Step back to the start of the current word
    while i > 0 && i <= n && is_word(line[i]); i -= 1; end
    return i
end

function _vim_word_motion!(ed::TK.CodeEditor, ch::Char)
    # Forward to the multi-line-aware implementation in tui_app.jl.
    # The original single-line version stopped at EOL — `w` could get
    # stuck on the last char of a line rather than wrapping.
    kind = (ch == 'W' || ch == 'B') ? :big : :small
    dir  = (ch == 'w' || ch == 'W') ? +1 : -1
    _word_motion!(ed, dir, kind)
end

"""
    _vim_op_motion!(m, ed, op, motion)

Execute one of cw / cb / c\$ / c0 (and their d/y variants). `op`
is the operator char; `motion` is one of the supported motion
chars. Word boundaries reuse the same helpers as the standalone
motions so behaviour stays consistent.
"""
function _vim_op_motion!(m::RessacApp, ed::TK.CodeEditor, op::Char, motion::Char)
    # `$` (end of line) and `0` (start of line) are single-line-only,
    # cheap operations — handle them inline.
    if motion == '$'
        row = ed.cursor_row
        1 <= row <= length(ed.lines) || return
        line = String(ed.lines[row])
        n = length(line)
        col = ed.cursor_col
        captured = col < n ? line[col + 1 : n] : ""
        ed.yank_buffer = [collect(captured)]; ed.yank_is_linewise = false
        if op == 'y'; return; end
        saved_scroll = ed.scroll_offset
        new_line = col > 0 ? line[1:col] : ""
        TK.set_text!(ed, _set_one_line(ed, row, new_line))
        ed.scroll_offset = saved_scroll
        ed.cursor_row = row; ed.cursor_col = col
        op == 'c' && (ed.mode = :insert)
        return
    elseif motion == '0'
        row = ed.cursor_row
        1 <= row <= length(ed.lines) || return
        line = String(ed.lines[row])
        col = ed.cursor_col
        captured = col > 0 ? line[1:col] : ""
        ed.yank_buffer = [collect(captured)]; ed.yank_is_linewise = false
        if op == 'y'; return; end
        saved_scroll = ed.scroll_offset
        new_line = col < length(line) ? line[col + 1 : end] : ""
        TK.set_text!(ed, _set_one_line(ed, row, new_line))
        ed.scroll_offset = saved_scroll
        ed.cursor_row = row; ed.cursor_col = 0
        op == 'c' && (ed.mode = :insert)
        return
    end
    # Word motions (w/b/W/B/e/E) — delegate to the multi-line-aware,
    # scroll-preserving impl in tui_app.jl.
    if motion in ('w', 'b', 'W', 'B', 'e', 'E')
        _op_with_motion!(m, ed, op, motion)
    end
end
# ---------------------------------------------------------------------
# Vim visual-line mode (V)
# ---------------------------------------------------------------------

"""
    _visual_handle!(m, ed, evt) -> Bool

Dispatch keys while in visual-line mode. Returns true if the event
was consumed; false to let the rest of `update!` handle it (e.g. a
key we don't know about — Tachikoma will own it).

  • j / k / arrows → extend the selection
  • d              → delete the selected lines (yank first)
  • y              → yank lines, return to normal
  • c              → delete + enter insert
  • Esc            → exit without action
"""
function _visual_handle!(m::RessacApp, ed::TK.CodeEditor, evt::TK.KeyEvent)
    if evt.key === :escape
        m.visual_active = false
        _push_app_log!(m, "[INFO] visual cancelled")
        return true
    end
    # Both kinds share vertical motion (j/k); :char additionally tracks
    # horizontal (h/l, arrows, w/b/0/$).
    if evt.char == 'j' || evt.key === :down
        ed.cursor_row = min(ed.cursor_row + 1, length(ed.lines))
        if m.visual_kind === :char
            ed.cursor_col = clamp(ed.cursor_col, 0, length(ed.lines[ed.cursor_row]))
        end
        return true
    end
    if evt.char == 'k' || evt.key === :up
        ed.cursor_row = max(1, ed.cursor_row - 1)
        if m.visual_kind === :char
            ed.cursor_col = clamp(ed.cursor_col, 0, length(ed.lines[ed.cursor_row]))
        end
        return true
    end
    if m.visual_kind === :char
        if evt.char == 'h' || evt.key === :left
            ed.cursor_col = max(0, ed.cursor_col - 1); return true
        end
        if evt.char == 'l' || evt.key === :right
            row_len = length(ed.lines[ed.cursor_row])
            ed.cursor_col = min(row_len, ed.cursor_col + 1); return true
        end
        if evt.char == '0'
            ed.cursor_col = 0; return true
        end
        if evt.char == '\$'
            ed.cursor_col = length(ed.lines[ed.cursor_row]); return true
        end
    end
    if evt.char == 'd' || evt.char == 'y' || evt.char == 'c'
        _visual_apply!(m, ed, evt.char)
        return true
    end
    m.visual_active = false
    return false
end

"""
    _visual_apply!(m, ed, op)

Run an operator (`'d'` / `'y'` / `'c'`) on the line range
between visual_anchor_row and cursor_row, then exit visual mode.
"""
function _visual_apply!(m::RessacApp, ed::TK.CodeEditor, op::Char)
    if m.visual_kind === :char
        _visual_apply_char!(m, ed, op)
    else
        _visual_apply_line!(m, ed, op)
    end
    m.visual_active = false
end

function _visual_apply_line!(m::RessacApp, ed::TK.CodeEditor, op::Char)
    r1 = min(m.visual_anchor_row, ed.cursor_row)
    r2 = max(m.visual_anchor_row, ed.cursor_row)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    r1 = clamp(r1, 1, length(lines))
    r2 = clamp(r2, 1, length(lines))
    selected = lines[r1:r2]
    if op == 'y'
        ed.yank_buffer = [collect(line) for line in selected]
        ed.yank_is_linewise = true
        _push_app_log!(m, "[INFO] V — yanked $(length(selected)) line(s)")
    elseif op == 'd' || op == 'c'
        ed.yank_buffer = [collect(line) for line in selected]
        ed.yank_is_linewise = true
        deleteat!(lines, r1:r2)
        isempty(lines) && push!(lines, "")
        new_txt = join(lines, '\n')
        TK.set_text!(ed, new_txt)
        ed.cursor_row = clamp(r1, 1, length(ed.lines))
        ed.cursor_col = 0
        if op == 'c'
            insert!(ed.lines, ed.cursor_row, Char[])
            ed.cursor_col = 0
            ed.mode = :insert
        end
        _push_app_log!(m, "[INFO] V — $(op == 'c' ? "changed" : "deleted") $(length(selected)) line(s)")
        ed === _active_editor(m) && _unschedule_removed_slots!(m, txt, new_txt)
    end
end

"""
    _visual_apply_char!(m, ed, op)

Char-wise visual: collect chars from (anchor_row, anchor_col) to
(cursor_row, cursor_col) inclusive (normalised so start <= end), then
yank / delete / change. Single-line ranges stay on the same row;
multi-line ranges keep the prefix of the start row, the suffix of
the end row, and drop everything in between.
"""
function _visual_apply_char!(m::RessacApp, ed::TK.CodeEditor, op::Char)
    a_r, a_c = m.visual_anchor_row, m.visual_anchor_col
    c_r, c_c = ed.cursor_row,         ed.cursor_col
    # Normalise: (r1, c1) is the visually-earlier point.
    if (c_r, c_c) < (a_r, a_c)
        r1, c1, r2, c2 = c_r, c_c, a_r, a_c
    else
        r1, c1, r2, c2 = a_r, a_c, c_r, c_c
    end
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    r1 = clamp(r1, 1, length(lines))
    r2 = clamp(r2, 1, length(lines))
    c1 = clamp(c1, 0, length(lines[r1]))
    c2 = clamp(c2 + 1, c1, length(lines[r2]))  # +1 = inclusive on end
    # Build the yanked text. char-wise so yank_is_linewise = false.
    yanked = if r1 == r2
        lines[r1][c1+1 : c2]
    else
        join([lines[r1][c1+1 : end],
              lines[r1+1 : r2-1]...,
              lines[r2][1 : c2]], '\n')
    end
    ed.yank_buffer = [collect(line) for line in split(yanked, '\n')]
    ed.yank_is_linewise = false
    if op == 'y'
        _push_app_log!(m, "[INFO] v — yanked $(length(yanked)) char(s)")
        return
    end
    # Delete the range. Rebuild affected lines, then collapse.
    if r1 == r2
        lines[r1] = lines[r1][1 : c1] * lines[r1][c2+1 : end]
    else
        lines[r1] = lines[r1][1 : c1] * lines[r2][c2+1 : end]
        deleteat!(lines, (r1+1) : r2)
    end
    isempty(lines) && push!(lines, "")
    new_txt = join(lines, '\n')
    TK.set_text!(ed, new_txt)
    ed.cursor_row = clamp(r1, 1, length(ed.lines))
    ed.cursor_col = clamp(c1, 0, length(ed.lines[ed.cursor_row]))
    if op == 'c'
        ed.mode = :insert
    end
    _push_app_log!(m, "[INFO] v — $(op == 'c' ? "changed" : "deleted") $(length(yanked)) char(s)")
    ed === _active_editor(m) && _unschedule_removed_slots!(m, txt, new_txt)
end

# ---------------------------------------------------------------------
# Vim `.` repeat — minimal: replay last insert-mode session
# ---------------------------------------------------------------------

"""
    _vim_record_keystroke!(m, ed, evt, is_press)

Track whether we just entered insert mode (i / a / o / O / I / A)
or left it (Esc), and accumulate the typed characters in between.
On the next `.` press, `_vim_replay!` re-types those characters.
"""
function _vim_record_keystroke!(m::RessacApp, ed::TK.CodeEditor,
                                evt::TK.KeyEvent, is_press::Bool)
    is_press || return
    if !m.vim_in_insert && ed.mode === :normal &&
       evt.key === :char && evt.char in ('i', 'a', 'o', 'O', 'I', 'A')
        # We're about to enter insert via this key (Tachikoma will
        # process it just after we return). Start a fresh buffer.
        m.vim_in_insert = true
        m.vim_insert_buf = ""
        return
    end
    if m.vim_in_insert && ed.mode === :insert
        if evt.key === :char && evt.char != '\0'
            m.vim_insert_buf *= string(evt.char)
        elseif evt.key === :enter
            m.vim_insert_buf *= "\n"
        end
    end
    if m.vim_in_insert && evt.key === :escape
        # Insert session ended — freeze it as the last-replay target.
        m.vim_last_insert = m.vim_insert_buf
        m.vim_in_insert = false
        m.vim_last_kind  = :insert
    end
end

"""
    _slots_in_text(txt) -> Set{Symbol}

Return the set of `@dN` slot symbols present as ACTIVE (uncommented)
slot definitions in `txt`. A line starting with `#` is treated as
muted and contributes nothing. Used to detect which slots disappear
across a buffer mutation so the scheduler can stop them.
"""
const _SLOT_PRESENT_RX = r"^\s*@(d\d+)\b"
function _slots_in_text(txt::AbstractString)
    out = Set{Symbol}()
    for line in eachline(IOBuffer(String(txt)))
        mt = match(_SLOT_PRESENT_RX, line)
        mt !== nothing && push!(out, Symbol(mt.captures[1]))
    end
    return out
end

"""
    _unschedule_removed_slots!(m, pre_text, post_text)

Compare active slot sets between two snapshots; for each slot that
was present before, isn't present after, AND is still scheduled,
call `unset_pattern!` so the audio stops with the text. Mirrors
what users expect from `dd` on a live `@dN` line.
"""
function _unschedule_removed_slots!(m::RessacApp,
                                    pre_text::AbstractString,
                                    post_text::AbstractString)
    pre  = _slots_in_text(pre_text)
    post = _slots_in_text(post_text)
    removed = setdiff(pre, post)
    isempty(removed) && return
    sched = m.scheduler
    actually = Symbol[]
    for slot in removed
        haskey(sched.patterns, slot) || continue
        unset_pattern!(sched, slot)
        push!(actually, slot)
    end
    isempty(actually) && return
    names = join(("@" * String(s) for s in sort!(actually; by = String)), " ")
    _push_app_log!(m, "[INFO] unscheduled $(names) (line deleted)")
end

"""
    _vim_post_normal!(m, ed, evt, pre_text)

Called AFTER Tachikoma has processed a keystroke that began in
:normal mode. Detects whether that keystroke (or the sequence of
recent keystrokes) modified the buffer — if so, captures the
sequence as the new `.`-target.

Two-key commands like `dd` work because the first `d` produces no
buffer change (still pending), so we accumulate it; the second `d`
triggers the change and we record both.
"""
function _vim_post_normal!(m::RessacApp, ed::TK.CodeEditor,
                            evt::TK.KeyEvent, pre_text::String)
    # The `.` key itself must never enter the recording — it's a
    # meta-command, not part of any sequence.
    evt.key === :char && evt.char == '.' && return
    # Entering insert mode hands recording to _vim_record_keystroke!;
    # discard whatever was pending in normal-mode buffer.
    if ed.mode === :insert
        empty!(m.vim_pending_normal); return
    end
    # Esc, arrows, scroll keys, etc — not part of an edit sequence
    # but they shouldn't poison pending either, so just ignore.
    if evt.key !== :char
        return
    end
    push!(m.vim_pending_normal, evt)
    # Cap pending length so a runaway sequence (typos in normal mode)
    # doesn't grow forever.
    length(m.vim_pending_normal) > 8 && popfirst!(m.vim_pending_normal)
    post_text = TK.text(ed)
    if post_text != pre_text
        m.vim_last_normal = copy(m.vim_pending_normal)
        m.vim_last_kind   = :normal
        empty!(m.vim_pending_normal)
        # Pattern lines that just vanished from the buffer should
        # stop playing. Only meaningful in the patterns pane —
        # synth-pane edits don't drive the scheduler directly.
        ed === _active_editor(m) &&
            _unschedule_removed_slots!(m, pre_text, post_text)
    end
end

"""
    _vim_replay!(m, ed)

Replay `vim_last_insert` at the current cursor by synthesising
char-event handle_key! calls into the editor. The editor must be in
:normal mode when `.` is pressed; we enter insert (via 'i'), type
the characters, then Esc back to normal.
"""
function _vim_replay!(m::RessacApp, ed::TK.CodeEditor)
    if m.vim_last_kind === :normal && !isempty(m.vim_last_normal)
        for k in m.vim_last_normal
            TK.handle_key!(ed, k)
        end
        seq = join(string(k.char) for k in m.vim_last_normal)
        _push_app_log!(m, "[INFO] . — repeated `$(seq)`")
        return
    end
    if m.vim_last_kind === :insert
        text = m.vim_last_insert
        isempty(text) &&
            (_push_app_log!(m, "[INFO] . — nothing to repeat"); return)
        TK.handle_key!(ed, TK.KeyEvent(:char, 'i', TK.key_press))
        for c in text
            if c == '\n'
                TK.handle_key!(ed, TK.KeyEvent(:enter, '\0', TK.key_press))
            else
                TK.handle_key!(ed, TK.KeyEvent(:char, c, TK.key_press))
            end
        end
        TK.handle_key!(ed, TK.KeyEvent(:escape, '\0', TK.key_press))
        _push_app_log!(m, "[INFO] . — repeated last insert ($(length(text)) chars)")
        return
    end
    _push_app_log!(m, "[INFO] . — nothing to repeat")
end
