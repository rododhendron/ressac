# Pattern editor — the "what you see and how you edit a pattern" half
# of the patterns pane. Owns:
#
#   • Playhead overlay (per-frame token highlight) + content-hash cache
#   • Eval flash overlay (post-:e green pulse, fades 0.6s)
#   • Mini-notation top-level token splitter
#   • Context-aware pattern ops inside p"…":
#       _pat_at_cursor, _pat_replace_body!,
#       _pat_zoom!, _pat_shift!, _pat_silence!, _pat_subdivide!
#
# All of these operate on _active_editor(m) + m.scheduler.patterns; they're
# pulled out of app.jl to make navigation easier without disturbing
# load order (everything they reference — RessacApp, _char_split,
# _push_app_log!, _LIVE_SCHEDULER — is already in scope by the time
# this file is included from app.jl).

# ---------------------------------------------------------------------
# Playhead — highlights the active token in active patterns
# ---------------------------------------------------------------------

# Match @dN at the start of a line, followed by a p"…" block somewhere
# after it. We capture the slot number and the byte offsets of the p"
# string contents (between the quotes) so we know which character to
# highlight when the phase lands inside.
const _PLAYHEAD_LINE_RX = r"@d(\d+).*?\bp\"([^\"]*)\""

"""
    _render_playhead!(m, rect, buf)

For every visible line in the patterns editor that maps to a slot
currently shipping events, overlay a highlight on the mininotation
token that's playing right now. Equal-time subdivision at top
level — `p"bd hh sn hh"` splits into 4 equal slots, the active
one gets the accent background.

Bracketed / Euclidean / `<…>` constructs are treated as one
top-level token; precise highlighting inside them is a follow-up.
"""
function _render_playhead!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    sched = m.scheduler
    sched.t_start > 0 || return
    isempty(sched.patterns) && return
    ed = _active_editor(m)
    ed === nothing && return        # no editor → nothing to overlay
    phase = ((time() - sched.t_start) * sched.cps) % 1.0
    phase = clamp(phase, 0.0, 0.9999)
    has_block = ed.block !== nothing
    inset_top = has_block ? 1 : 0
    inset_bot = has_block ? 1 : 0   # the block has a bottom border too
    inset_left = has_block ? 1 : 0
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    # Iterate only the visible window — bounded by scroll_offset above
    # and rect.height-borders below. Avoids both the "highlight bleeds
    # onto the bottom border" jump and the O(n) scan over hidden lines.
    body_h = rect.height - inset_top - inset_bot
    first_row = ed.scroll_offset + 1
    last_row  = min(length(ed.lines), first_row + body_h - 1)
    # Prune cache entries outside the visible window so it stays bounded
    # to ~rect.height rows even if the user scrolls a large buffer.
    for k in keys(m.playhead_cache)
        (k < first_row || k > last_row) && delete!(m.playhead_cache, k)
    end
    for i in first_row:last_row
        screen_row = rect.y + inset_top + (i - 1 - ed.scroll_offset)
        line_chars = ed.lines[i]
        # Cache key = hash(line content). Cheap to compute and avoids
        # the regex + body split when the line hasn't changed between
        # frames. nothing-valued cache entries are kept so we don't
        # re-parse lines that don't match the regex.
        line_hash = hash(line_chars)
        cached = get(m.playhead_cache, i, nothing)
        parsed = if cached !== nothing && cached[1] == line_hash
            cached[2]
        else
            p = _playhead_parse(line_chars)
            m.playhead_cache[i] = (line_hash, p)
            p
        end
        parsed === nothing && continue
        haskey(sched.patterns, parsed.slot) || continue
        # Re-paint the slot prefix (`@dN`) in :warning bold so the eye
        # can spot active lines instantly even before the playhead token
        # highlight kicks in. Inactive @dN lines (slot not in
        # sched.patterns) skip this branch entirely.
        slot_screen_x_start = rect.x + inset_left + gw +
                              parsed.slot_start_col - ed_h_scroll(ed)
        for k in 0:(parsed.slot_str_len - 1)
            sx = slot_screen_x_start + k
            sx < rect.x + inset_left + gw && continue
            sx >= rect.x + rect.width && break
            line_col = parsed.slot_start_col + k + 1
            line_col <= length(line_chars) || break
            TK.set_char!(buf, sx, screen_row, line_chars[line_col],
                         TK.tstyle(:warning, bold = true))
        end
        # Active token highlight.
        n = length(parsed.tokens)
        active = clamp(floor(Int, phase * n) + 1, 1, n)
        tok_start_in_body, tok_stop_in_body = parsed.tokens[active]
        for body_col in tok_start_in_body:tok_stop_in_body
            screen_x = rect.x + inset_left + gw + parsed.body_start_col +
                       body_col - ed_h_scroll(ed)
            screen_x < rect.x + inset_left + gw && continue
            screen_x >= rect.x + rect.width && break
            buf_col = parsed.body_start_col + body_col + 1
            ch = buf_col <= length(line_chars) ? line_chars[buf_col] : ' '
            TK.set_char!(buf, screen_x, screen_row, ch,
                         TK.tstyle(:accent, bold = true))
        end
    end
end

"""
    _playhead_parse(line_chars) -> Union{Nothing, NamedTuple}

Run the @dN regex + body token-split once per (changed) line. The
result is cached in `m.playhead_cache` keyed on the line hash so
unchanged rows skip this work. Returning `nothing` when no @dN
match keeps the cache shape consistent for both match and no-match.
"""
function _playhead_parse(line_chars::Vector{Char})
    line = String(line_chars)
    mt = match(_PLAYHEAD_LINE_RX, line)
    mt === nothing && return nothing
    body = String(mt.captures[2])
    isempty(body) && return nothing
    tokens = _split_minino_top(body)
    isempty(tokens) && return nothing
    return (slot           = Symbol("d", mt.captures[1]),
            slot_str_len   = 2 + length(mt.captures[1]),
            slot_start_col = mt.offsets[1] - 2,
            body_start_col = mt.offsets[2] - 1,
            tokens         = tokens)
end

ed_h_scroll(ed::TK.CodeEditor) = ed.h_scroll

"""
    _render_eval_flash!(m, rect, buf)

After `:e` (or `E`) evals a block, paint the corresponding @dN line
in :success bold so the user gets a visual "this just ran" pulse.
Fades over `_EVAL_FLASH_DURATION` seconds; after that nothing draws
until the next eval.
"""
const _EVAL_FLASH_DURATION = 0.6
function _render_eval_flash!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    isempty(m.eval_flash_rows) && return
    age = time() - m.eval_flash_ts
    age > _EVAL_FLASH_DURATION && (empty!(m.eval_flash_rows); return)
    # Fade: full strength at age=0, none at duration. We pick :success
    # for the first half, then :accent dim — gives a "green then settle"
    # feel without needing per-cell alpha.
    ed = _active_editor(m)
    ed === nothing && return        # no editor → nothing to flash
    style = age < _EVAL_FLASH_DURATION / 2 ?
        TK.tstyle(:success, bold = true) :
        TK.tstyle(:success)
    gw = ed.show_line_numbers ?
         ndigits(max(length(ed.lines), 1)) + 1 : 0
    first_row = ed.scroll_offset + 1
    last_row  = first_row + rect.height - 1
    for row in m.eval_flash_rows
        (row < first_row || row > last_row) && continue
        screen_y = rect.y + (row - first_row)
        row <= length(ed.lines) || continue
        line_chars = ed.lines[row]
        # Repaint each char on the row in the flash style, preserving
        # the source char. Skip the line-number gutter.
        for (col_in_line, ch) in enumerate(line_chars)
            screen_x = rect.x + gw + col_in_line - 1 - ed.h_scroll
            screen_x < rect.x + gw && continue
            screen_x >= rect.x + rect.width && break
            TK.set_char!(buf, screen_x, screen_y, ch, style)
        end
    end
end

"""
    _render_visual_selection!(m, rect, buf)

Paint the visual-mode selection (V or v) on top of the editor render.
:line highlights whole rows [anchor_row..cursor_row]; :char highlights
character-wise from anchor to cursor in reading order. Background-tinted
style so the underlying text stays readable.
"""
function _render_visual_selection!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    m.visual_active || return
    ed = _active_editor(m)
    th = TK.theme()
    sel_style = TK.Style(; fg = th.text_bright, bg = th.secondary, bold = true)

    gw = ed.show_line_numbers ?
         ndigits(max(length(ed.lines), 1)) + 1 : 0
    first_row = ed.scroll_offset + 1
    last_row  = first_row + rect.height - 1

    paint_cell = (row, col_in_line, ch) -> begin
        screen_x = rect.x + gw + col_in_line - 1 - ed.h_scroll
        screen_x < rect.x + gw && return
        screen_x >= rect.x + rect.width && return
        screen_y = rect.y + (row - first_row)
        TK.set_char!(buf, screen_x, screen_y, ch, sel_style)
    end

    if m.visual_kind === :line
        r1 = min(m.visual_anchor_row, ed.cursor_row)
        r2 = max(m.visual_anchor_row, ed.cursor_row)
        for row in r1:r2
            (row < first_row || row > last_row) && continue
            row <= length(ed.lines) || continue
            line_chars = ed.lines[row]
            # Paint every char of the row + trail spaces up to the rect
            # right edge so the highlight feels like a full-line block.
            line_w = max(length(line_chars), 1)
            visible_w = rect.width - gw + ed.h_scroll
            paint_w = max(line_w, visible_w)
            for col in 1:paint_w
                ch = col <= length(line_chars) ? line_chars[col] : ' '
                paint_cell(row, col, ch)
            end
        end
    else  # :char
        ar, ac = m.visual_anchor_row, m.visual_anchor_col
        cr, cc = ed.cursor_row, ed.cursor_col
        if (cr < ar) || (cr == ar && cc < ac)
            r1, c1, r2, c2 = cr, cc, ar, ac
        else
            r1, c1, r2, c2 = ar, ac, cr, cc
        end
        for row in r1:r2
            (row < first_row || row > last_row) && continue
            row <= length(ed.lines) || continue
            line_chars = ed.lines[row]
            col_lo = row == r1 ? c1 + 1 : 1
            col_hi = row == r2 ? c2 + 1 : length(line_chars)
            col_hi = min(col_hi, max(length(line_chars), 1))
            for col in col_lo:col_hi
                ch = col <= length(line_chars) ? line_chars[col] : ' '
                paint_cell(row, col, ch)
            end
        end
    end
end

"""
    _split_minino_top(body) -> Vector{Tuple{Int,Int}}

Split `body` (the inside of a `p"…"` string) into top-level
whitespace-separated tokens. Returns a vector of (start, stop)
columns relative to `body` (0-based, inclusive). Tokens inside
[…] / <…> / (…) are treated as a single unit.
"""
function _split_minino_top(body::AbstractString)
    out = Tuple{Int,Int}[]
    n = length(body)
    depth = 0
    tok_start = -1
    for (i, c) in enumerate(body)
        col = i - 1
        if c == '[' || c == '<' || c == '('
            depth += 1
            tok_start == -1 && (tok_start = col)
        elseif c == ']' || c == '>' || c == ')'
            depth = max(0, depth - 1)
        elseif isspace(c) && depth == 0
            if tok_start >= 0
                push!(out, (tok_start, col - 1))
                tok_start = -1
            end
        else
            tok_start == -1 && (tok_start = col)
        end
    end
    tok_start >= 0 && push!(out, (tok_start, n - 1))
    return out
end

# ---------------------------------------------------------------------
# Pattern editor — context-aware ops on the p"…" the cursor sits in
# ---------------------------------------------------------------------

"""
    _pat_at_cursor(ed) -> Union{Nothing, NamedTuple}

If the editor's cursor is inside a `p"…"` (or `n("…")` etc.) on the
current line, return a NamedTuple describing the pattern so callers
can mutate it:

  • `row`             — 1-based line index
  • `body`            — the string between the quotes
  • `body_start_col`  — column where `body[1]` lives (0-based)
  • `tokens`          — `Vector{Tuple{Int,Int}}` from `_split_minino_top`
  • `tok_idx`         — which token contains the cursor (or nearest)

Returns `nothing` when the cursor isn't inside a `p"…"` string.
"""
function _pat_at_cursor(ed::TK.CodeEditor)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return nothing
    line = String(ed.lines[row])
    # Find the p"…" enclosing the cursor. Scan for the last `p"` start
    # at or before the cursor that has its closing `"` after the cursor.
    cur = ed.cursor_col
    rx = r"\bp\"([^\"]*)\""
    for mt in eachmatch(rx, line)
        body_start = mt.offsets[1] - 1            # 0-based col of body[1]
        body_end   = body_start + length(mt.captures[1])  # exclusive
        if body_start - 2 <= cur <= body_end
            body = String(mt.captures[1])
            tokens = _split_minino_top(body)
            isempty(tokens) && return nothing
            # Which token contains the cursor? Cursor col is relative
            # to line; translate to body-relative.
            cur_in_body = clamp(cur - body_start, 0, length(body))
            idx = findlast(t -> t[1] <= cur_in_body <= t[2] + 1, tokens)
            idx === nothing && (idx = length(tokens))
            return (row = row, body = body,
                    body_start_col = body_start,
                    tokens = tokens, tok_idx = idx)
        end
    end
    return nothing
end

"""
    _pat_replace_body!(m, ed, info, new_body)

Rewrite the line `info.row` swapping the pattern body for `new_body`.
The `p"` quotes stay. Cursor is repositioned at the start of the new
body — callers can re-find their token afterwards if needed.
"""
function _pat_replace_body!(m::RessacApp, ed::TK.CodeEditor, info, new_body::AbstractString)
    line = String(ed.lines[info.row])
    # body_start_col / body length are char counts, never byte indices.
    before, rest    = _char_split(line, info.body_start_col)
    _, after        = _char_split(rest, length(info.body))
    new_line = before * String(new_body) * after
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty = true))
    lines[info.row] = new_line
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = info.row
    ed.cursor_col = clamp(info.body_start_col, 0, length(ed.lines[info.row]))
end

"""
    _pat_zoom!(m, ed, dir)

`dir = +1` doubles the resolution: every adjacent pair of tokens
gets a `~` inserted between them, so a `p"bd hh"` becomes
`p"bd ~ hh ~"` — the audio stays exactly the same, but each
original step is now two cells and the user has slots to fill.

`dir = -1` halves: keep every other token, drop the in-between
ones. Lossy if the dropped slots had hits — warns in the log.
"""
function _pat_zoom!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] zoom: cursor isn't in a p\"…\"")
    body = info.body
    tokens = info.tokens
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    if dir > 0
        # Interleave a rest after every token to double the grid.
        new_tokens = String[]
        for s in strs
            push!(new_tokens, s); push!(new_tokens, "~")
        end
        new_body = join(new_tokens, " ")
        _pat_replace_body!(m, ed, info, new_body)
        _push_app_log!(m, "[INFO] pattern zoom ×2 → $(length(new_tokens)) steps")
    else
        # Keep odd-indexed (1, 3, 5, …) tokens; warn if any dropped
        # token wasn't a silence.
        kept = String[]
        dropped_hits = 0
        for (i, s) in enumerate(strs)
            if isodd(i)
                push!(kept, s)
            elseif s != "~"
                dropped_hits += 1
            end
        end
        isempty(kept) && (kept = ["~"])
        new_body = join(kept, " ")
        _pat_replace_body!(m, ed, info, new_body)
        if dropped_hits > 0
            _push_app_log!(m,
                "[WARN] pattern zoom ÷2 → $(length(kept)) steps · " *
                "dropped $(dropped_hits) hit$(dropped_hits == 1 ? "" : "s")")
        else
            _push_app_log!(m, "[INFO] pattern zoom ÷2 → $(length(kept)) steps")
        end
    end
end

"""
    _pat_shift!(m, ed, dir)

Swap the token at cursor with its neighbour in `dir` (±1) within
the same `p"…"`. Cursor follows the moved token so successive
presses keep moving the same note.
"""
function _pat_shift!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] shift: cursor isn't in a p\"…\"")
    tokens = info.tokens
    i = info.tok_idx
    j = i + dir
    (1 <= j <= length(tokens)) || return _push_app_log!(m, "[INFO] shift: at edge of pattern")
    body = info.body
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    strs[i], strs[j] = strs[j], strs[i]
    new_body = join(strs, " ")
    _pat_replace_body!(m, ed, info, new_body)
    # Re-tokenise and place cursor inside the moved token at its new index.
    info2 = _pat_at_cursor(ed)
    if info2 !== nothing && j <= length(info2.tokens)
        ed.cursor_col = info.body_start_col + info2.tokens[j][1]
    end
end

"""
    _pat_silence!(m, ed)

Replace the token under cursor with `~`. Same shape as `x` in vim,
but operates at token granularity inside a pattern.
"""
function _pat_silence!(m::RessacApp, ed::TK.CodeEditor)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] silence: cursor isn't in a p\"…\"")
    body = info.body
    tokens = info.tokens
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    strs[info.tok_idx] = "~"
    new_body = join(strs, " ")
    _pat_replace_body!(m, ed, info, new_body)
end

"""
    _pat_subdivide!(m, ed, n)

Set the token under cursor to subdivide N times — `bd` → `bd*N` —
or strip the subdivision when `n == 1`. Maps musically:

    1 = noire (no subdivision, plain token)
    2 = croche
    3 = triolet
    4 = double croche
    6 = sextolet
    8 = triple croche

If the token already ends in `*K`, the K is replaced by N.
"""
function _pat_subdivide!(m::RessacApp, ed::TK.CodeEditor, n::Int)
    info = _pat_at_cursor(ed)
    info === nothing && return _push_app_log!(m, "[WARN] subdivide: cursor isn't in a p\"…\"")
    body = info.body
    tokens = info.tokens
    strs = [String(SubString(body, t[1] + 1, t[2] + 1)) for t in tokens]
    tok = strs[info.tok_idx]
    # Strip any existing *K suffix at the top level (skip if inside [] etc).
    base = replace(tok, r"\*\d+$" => "")
    new_tok = n <= 1 ? base : "$(base)*$(n)"
    strs[info.tok_idx] = new_tok
    new_body = join(strs, " ")
    _pat_replace_body!(m, ed, info, new_body)
    name = n == 1 ? "noire" :
           n == 2 ? "croche" :
           n == 3 ? "triolet" :
           n == 4 ? "double croche" :
           n == 6 ? "sextolet" :
           n == 8 ? "triple croche" : "×$n"
    _push_app_log!(m, "[INFO] subdivide: $tok → $new_tok ($name)")
end
