# Editor ops — visual modes (line + char) and `.` repeat, plus the small
# `_slots_in_text` / `_unschedule_removed_slots!` helpers used by the
# visual-delete path to keep the scheduler in sync with buffer deletions.
#
# (Les mouvements par mot et les opérateurs `cw` / `d$` / … vivent dans
# app_editor.jl : `_word_motion!`, `_op_with_motion!`.)

# ---------------------------------------------------------------------
# Vim visual-line mode (V)
# ---------------------------------------------------------------------

"""
    _visual_move!(m, dir)

Étend la sélection visuelle : `:down` / `:up` (les deux genres), et pour la
sélection par caractères `:left` / `:right` / `:home` / `:end`. Les touches
qui y mènent, comme `d` / `y` / `c`, `m`, `e` et Échap, sont au registre
(scope `:visual`, app_keymap.jl).
"""
function _visual_move!(m::RessacApp, dir::Symbol)
    ed = _active_editor(m)
    ed === nothing && return
    if dir === :down
        ed.cursor_row = min(ed.cursor_row + 1, length(ed.lines))
    elseif dir === :up
        ed.cursor_row = max(1, ed.cursor_row - 1)
    elseif dir === :left
        ed.cursor_col = max(0, ed.cursor_col - 1)
    elseif dir === :right
        ed.cursor_col = ed.cursor_col + 1
    elseif dir === :home
        ed.cursor_col = 0
    elseif dir === :end
        ed.cursor_col = length(ed.lines[ed.cursor_row])
    end
    m.visual_kind === :char && (ed.cursor_col = clamp(ed.cursor_col, 0, length(ed.lines[ed.cursor_row])))
    return
end

"""
    _visual_blocks!(m, ed, action)

`m` / `e` en mode visuel : l'action s'applique à chaque bloc (`@dN …` et ses
lignes de suite) que la sélection touche. `:mute` les coupe tous — ou, s'ils
le sont déjà tous, les remet tous ; `:eval` les évalue l'un après l'autre.
Un seul `u` annule le mute du groupe.
"""
function _visual_blocks!(m::RessacApp, ed::TK.CodeEditor, action::Symbol)
    lines = collect(split(TK.text(ed), '\n'; keepempty = true))
    r1 = clamp(min(m.visual_anchor_row, ed.cursor_row), 1, length(lines))
    r2 = clamp(max(m.visual_anchor_row, ed.cursor_row), 1, length(lines))
    # La première ligne de chaque bloc touché, sans doublon.
    roots = Int[]
    r = r1
    while r <= r2
        if isempty(strip(lines[r]))
            r += 1; continue
        end
        (a, b) = _logical_block_range(lines, r)
        a in roots || push!(roots, a)
        r = max(b, r) + 1
    end
    row0, col0 = ed.cursor_row, ed.cursor_col
    undo0 = length(ed.undo_stack)
    if action === :mute
        active(a) = match(_ACTIVE_SLOT_RX_APP, String(lines[a])) !== nothing
        muted(a)  = match(_COMMENTED_SLOT_RX_APP, String(lines[a])) !== nothing
        slots = [a for a in roots if active(a) || muted(a)]
        targets = any(active, slots) ? filter(active, slots) : slots      # tous déjà muets → on les remet
        isempty(targets) && (_push_app_log!(m, "[WARN] m — aucun slot @dN dans la sélection"); return)
        for a in targets
            ed.cursor_row = a; ed.cursor_col = 0
            _toggle_mute_current_line!(m)
        end
        # Les mutes du groupe : un seul pas d'annulation.
        length(ed.undo_stack) > undo0 + 1 && resize!(ed.undo_stack, undo0 + 1)
    else
        for a in roots
            startswith(lstrip(lines[a]), "#") && continue                  # un bloc muet ne s'évalue pas
            ed.cursor_row = a; ed.cursor_col = 0
            _eval_current_line!(m)
        end
    end
    ed.cursor_row = clamp(row0, 1, length(ed.lines))
    ed.cursor_col = clamp(col0, 0, length(ed.lines[ed.cursor_row]))
    return
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
        _push_app_log!(m, "[INFO] V — $(length(selected)) ligne(s) copiée(s)")
    elseif op == 'd' || op == 'c'
        ed.yank_buffer = [collect(line) for line in selected]
        ed.yank_is_linewise = true
        deleteat!(lines, r1:r2)
        # `c` laisse une ligne vide à la place du bloc ; on la met dans le
        # texte AVANT `set_text!` pour que le cache de tokens la connaisse.
        op == 'c' && insert!(lines, clamp(r1, 1, length(lines) + 1), "")
        isempty(lines) && push!(lines, "")
        new_txt = join(lines, '\n')
        _edit_text!(ed, new_txt)
        ed.cursor_row = clamp(r1, 1, length(ed.lines))
        ed.cursor_col = 0
        op == 'c' && (ed.mode = :insert)
        _push_app_log!(m, "[INFO] V — $(length(selected)) ligne(s) $(op == 'c' ? "changée(s)" : "supprimée(s)")")
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
    lines = _buffer_lines(ed)                    # en caractères, comme les colonnes
    r1 = clamp(r1, 1, length(lines))
    r2 = clamp(r2, 1, length(lines))
    c1 = clamp(c1, 0, length(lines[r1]))
    c2 = clamp(c2 + 1, r1 == r2 ? c1 : 0, length(lines[r2]))  # +1 = inclusive on end
    yanked = if r1 == r2
        Vector{Char}[lines[r1][(c1 + 1):c2]]
    else
        vcat(Vector{Char}[lines[r1][(c1 + 1):end]], lines[(r1 + 1):(r2 - 1)], Vector{Char}[lines[r2][1:c2]])
    end
    ed.yank_buffer = yanked
    ed.yank_is_linewise = false
    n_chars = sum(length, yanked) + length(yanked) - 1
    if op == 'y'
        _push_app_log!(m, "[INFO] v — $(n_chars) caractère(s) copié(s)")
        return
    end
    # Delete the range: the head of the first line joins the tail of the last.
    lines[r1] = vcat(lines[r1][1:c1], lines[r2][(c2 + 1):end])
    r1 == r2 || deleteat!(lines, (r1 + 1):r2)
    _edit_lines!(ed, lines; row = r1, col = c1)
    if op == 'c'
        ed.mode = :insert
    end
    _push_app_log!(m, "[INFO] v — $(n_chars) caractère(s) $(op == 'c' ? "changé(s)" : "supprimé(s)")")
    ed === _active_editor(m) && _unschedule_removed_slots!(m, txt, TK.text(ed))
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
    _push_app_log!(m, "[INFO] $(names) déprogrammé(s) (ligne supprimée)")
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
        _push_app_log!(m, "[INFO] . — `$(seq)` répété")
        return
    end
    if m.vim_last_kind === :insert
        text = m.vim_last_insert
        isempty(text) &&
            (_push_app_log!(m, "[INFO] . — rien à répéter"); return)
        TK.handle_key!(ed, TK.KeyEvent(:char, 'i', TK.key_press))
        for c in text
            if c == '\n'
                TK.handle_key!(ed, TK.KeyEvent(:enter, '\0', TK.key_press))
            else
                TK.handle_key!(ed, TK.KeyEvent(:char, c, TK.key_press))
            end
        end
        TK.handle_key!(ed, TK.KeyEvent(:escape, '\0', TK.key_press))
        _push_app_log!(m, "[INFO] . — dernière insertion répétée ($(length(text)) caractères)")
        return
    end
    _push_app_log!(m, "[INFO] . — rien à répéter")
end


# ── f / F / t / T : aller au caractère sur la ligne ────────────────

"""
    _find_char!(m, ed, motion, c) -> Bool

Déplace le curseur au caractère `c` de la ligne courante : `f` vers la
droite dessus, `t` juste avant, `F` vers la gauche dessus, `T` juste
après. Renvoie false et laisse le curseur tranquille si le caractère
n'est pas là.
"""
function _find_char!(m::RessacApp, ed::TK.CodeEditor, motion::Char, c::Char)
    1 <= ed.cursor_row <= length(ed.lines) || return false
    line = ed.lines[ed.cursor_row]
    col = ed.cursor_col + 1                      # 1-based, caractère sous le curseur
    forward = motion in ('f', 't')
    idx = if forward
        findnext(==(c), line, min(col + 1, length(line) + 1))
    else
        col > 1 ? findprev(==(c), line, col - 1) : nothing
    end
    idx === nothing && return false
    target = motion == 't' ? idx - 1 : motion == 'T' ? idx + 1 : idx
    ed.cursor_col = clamp(target - 1, 0, max(0, length(line) - 1))
    m.last_find = (motion, c)
    return true
end

"""
    _repeat_find!(m, ed, dir) -> Bool

`;` refait la dernière recherche de caractère, `,` la refait à l'envers.
"""
function _repeat_find!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    m.last_find === nothing && return false
    motion, c = m.last_find
    inverse = Dict('f' => 'F', 'F' => 'f', 't' => 'T', 'T' => 't')
    use = dir > 0 ? motion : inverse[motion]
    return _find_char!(m, ed, use, c)
end
