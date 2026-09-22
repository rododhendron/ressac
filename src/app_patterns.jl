# src/app_patterns.jl
# Actions sur les patterns : mute/solo/unmute des slots @dN, écoute du mot
# sous le curseur, eval d'une ligne ou de tous les blocs, cascade des
# re-evals, humanisation des erreurs.

const _ACTIVE_SLOT_RX_APP   = r"^\s*@(d\d+)\b"
const _COMMENTED_SLOT_RX_APP = r"^\s*#+\s*@(d\d+)\b"

"""
    _toggle_mute_current_line!(m)

`m` key in patterns/normal mode. If the line under the cursor is an
uncommented `@dN ...` slot def → prefix it with `# ` and call
`unset_pattern!(scheduler, :dN)`. If it's commented → strip the `#`
and re-eval so the pattern comes back. Other lines log a warning.
"""
function _toggle_mute_current_line!(m::RessacApp)
    ed = _active_editor(m)
    ed === nothing && return
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ed.cursor_row
    col = ed.cursor_col
    1 <= row <= length(lines) || return
    # Detect the logical block the cursor is on, then mute/unmute its
    # ROOT line — the @dN call sits there. For multi-line blocks we
    # comment every line of the block so the parser doesn't trip on
    # orphan continuation arguments while the slot is muted.
    (root_row, end_row) = _logical_block_range(lines, row)
    root_line = String(lines[root_row])

    if (mt = match(_ACTIVE_SLOT_RX_APP, root_line)) !== nothing
        slot = Symbol(mt.captures[1])
        # Prepend "# " to every line of the block so indentation is
        # preserved exactly (and unmute can strip the same prefix).
        for r in root_row:end_row
            lines[r] = "# " * lines[r]
        end
        TK.set_text!(ed, join(lines, '\n'))
        ed.cursor_row = row
        ed.cursor_col = col + 2
        unset_pattern!(m.scheduler, slot)
        # Best-effort voice kill: free any drones on the SC side that
        # would otherwise hang now that the pattern stopped scheduling.
        _kill_voices_for_line!(m, join(lines[root_row:end_row], "\n"))
        _push_app_log!(m, "[INFO] $slot mute")
    elseif match(_COMMENTED_SLOT_RX_APP, root_line) !== nothing
        # Strip EXACTLY the "# " (or bare "#") we added at mute time.
        # The previous greedy `^\s*#+\s*` regex ate the line's natural
        # indentation on continuation rows like "#     drive=600.0".
        for r in root_row:end_row
            s = String(lines[r])
            if startswith(s, "# ")
                lines[r] = s[3:end]
            elseif startswith(s, "#")
                lines[r] = s[2:end]
            end
        end
        TK.set_text!(ed, join(lines, '\n'))
        ed.cursor_row = row
        ed.cursor_col = max(0, col - 2)
        # Re-eval so the slot comes back live — `_eval_current_line!`
        # uses the same block detection, so multi-line blocks evaluate
        # correctly from any cursor row inside them.
        _eval_current_line!(m)
    else
        _push_app_log!(m, "[WARN] m : le bloc sous le curseur n'est pas un slot @dN")
    end
end

"""
    _kill_voices_for_line!(m, line)

Scan `line` for sample / synth / instrument names and send a
`/ressac/freeByName` for each one to SC, freeing any running voice.
Without this, muting a drone (auto_env=false) doesn't silence it —
the pattern stops scheduling but the existing voice keeps running.

Names are pulled from:
  • the leading `:name`     (e.g. `@d1 :drone |> ...`)
  • the body of `p"…"`      (mini-notation tokens — bd, hh, sn, …)
  • the body of `gate(:n, …)` and `pure(:n)` calls
"""
function _kill_voices_for_line!(m::RessacApp, line::AbstractString)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    names = Set{Symbol}()
    # Leading :name after @dN.
    mt = match(r"@d\d+\s+:(\w+)", line)
    mt !== nothing && push!(names, Symbol(mt.captures[1]))
    # p"…" mini-notation: pull alphabetic tokens (skip ~ and numbers).
    for mp in eachmatch(r"\bp\"([^\"]*)\"", line)
        body = String(mp.captures[1])
        for tok_match in eachmatch(r"[A-Za-z_]\w*", body)
            push!(names, Symbol(tok_match.match))
        end
    end
    # gate(:name, …)  /  pure(:name)  /  :name |> …
    for mn in eachmatch(r":(\w+)", line)
        push!(names, Symbol(mn.captures[1]))
    end
    isempty(names) && return
    for name in names
        send_osc(sched.osc,
            encode(OSCMessage("/ressac/freeByName", Any[String(name)])))
    end
end

"""
    _preview_word_under_cursor!(m)

K in normal mode — find the identifier under the cursor and ship a
one-shot /dirt/play. Resolution order: instrument → sample → synth.
A trailing `:N` suffix overrides the n param.
"""
function _preview_word_under_cursor!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    ed = _active_editor(m)
    1 <= ed.cursor_row <= length(ed.lines) || return
    line_chars = ed.lines[ed.cursor_row]
    isempty(line_chars) && return
    col = clamp(ed.cursor_col + 1, 1, length(line_chars))
    # Word allows : suffix for variant indices.
    is_word = c -> isletter(c) || isdigit(c) || c == '_' || c == ':'
    start_col = col
    while start_col > 1 && is_word(line_chars[start_col - 1])
        start_col -= 1
    end
    end_col = col - 1
    while end_col + 1 <= length(line_chars) && is_word(line_chars[end_col + 1])
        end_col += 1
    end
    end_col < start_col && return
    word = String(line_chars[start_col:end_col])
    mt = match(r"^([A-Za-z_]\w*)(?::(\d+))?$", word)
    mt === nothing && (_push_app_log!(m, "[WARN] K — aucun nom sous le curseur"); return)
    name = Symbol(mt.captures[1])
    variant = mt.captures[2] === nothing ? 0 : parse(Int, mt.captures[2])

    args = Any[]
    kind = "?"
    if (instr = instrument_info(name)) !== nothing
        kind = "instrument"
        has_n = false
        for (k, v) in instr.params
            if k == "n"
                has_n = true
                if variant != 0
                    push!(args, "n"); push!(args, Int32(variant)); continue
                end
            end
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k); push!(args, converted)
        end
        variant != 0 && !has_n && (push!(args, "n"); push!(args, Int32(variant)))
    elseif sample_info(name) !== nothing
        kind = "sample"
        push!(args, "s"); push!(args, String(name))
        variant != 0 && (push!(args, "n"); push!(args, Int32(variant)))
    elseif synth_info(name) !== nothing
        kind = "synth"
        push!(args, "s"); push!(args, String(name))
    else
        _push_app_log!(m, "[WARN] K — aucun instrument/sample/synth « $(mt.captures[1]) »")
        return
    end
    push!(args, "cut"); push!(args, Int32(_PREVIEW_CUT_GROUP))
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
    _push_app_log!(m, "[INFO] K — écoute $kind $(mt.captures[1])")
end

const _APP_MUTED_PATTERNS = Dict{Symbol, Pattern}()

function _mute_pattern_slot!(m::RessacApp, slot::Symbol)
    pat = pattern_get(m.scheduler, slot)
    if pat === nothing
        _push_app_log!(m, "[WARN] :mute — le slot $slot n'a pas de pattern actif")
        return
    end
    _APP_MUTED_PATTERNS[slot] = pat
    unset_pattern!(m.scheduler, slot)
    _push_app_log!(m, "[INFO] $slot mute")
end

function _unmute_pattern_slot!(m::RessacApp, slot::Symbol)
    pat = get(_APP_MUTED_PATTERNS, slot, nothing)
    if pat === nothing
        _push_app_log!(m, "[WARN] :unmute — $slot n'était pas mute")
        return
    end
    set_pattern!(m.scheduler, slot, pat)
    delete!(_APP_MUTED_PATTERNS, slot)
    _push_app_log!(m, "[INFO] $slot démute")
end

function _unmute_all_patterns!(m::RessacApp)
    n = length(_APP_MUTED_PATTERNS)
    for (slot, pat) in _APP_MUTED_PATTERNS
        set_pattern!(m.scheduler, slot, pat)
    end
    empty!(_APP_MUTED_PATTERNS)
    _push_app_log!(m, "[INFO] $n slot(s) démuté(s)")
end

function _solo_pattern_slot!(m::RessacApp, solo_slot::Symbol)
    muted = 0
    for (other_slot, pat) in pattern_snapshot(m.scheduler)
        other_slot == solo_slot && continue
        _APP_MUTED_PATTERNS[other_slot] = pat
        unset_pattern!(m.scheduler, other_slot)
        muted += 1
    end
    _push_app_log!(m, "[INFO] solo $solo_slot ($muted autres mutés)")
end

function _next_free_d_slot(ed::TK.CodeEditor)
    used = Set{Int}()
    for mt in eachmatch(r"@d(\d+)", TK.text(ed))
        push!(used, parse(Int, mt.captures[1]))
    end
    n = 1
    while n in used; n += 1; end
    return n
end

function _insert_line_after_cursor!(ed::TK.CodeEditor, line::AbstractString)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(lines))
    insert!(lines, row + 1, String(line))
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row + 1
    ed.cursor_col = length(line)
end

# ---------------------------------------------------------------------
# Panic
# ---------------------------------------------------------------------

"""
    _humanize_eval_error(e, src) -> String

Map common Julia exceptions thrown during pattern eval into one-line
hints that point a non-dev user toward a fix. Falls back to the raw
`showerror` text when no recogniser matches.

  • UndefVarError(:foo)   → "le nom `foo` n'existe pas — :browse / :doc"
  • MethodError on |>      → "type mismatch in the pipe chain — check the |> args"
  • Meta.parse ParseError → "syntax error at position N — check brackets / quotes"
  • LoadError wrapper      → unwrap once and recurse
"""
function _humanize_eval_error(e, src::AbstractString)
    if e isa LoadError
        return _humanize_eval_error(e.error, src)
    end
    if e isa UndefVarError
        nm = String(e.var)
        return "unknown name `$nm` — :browse to see loaded sounds, or :doc $nm"
    end
    if e isa Base.Meta.ParseError
        # Pull out the position if present in the message.
        msg = sprint(showerror, e)
        return "parse error — check matching brackets / quotes in this line · $(first(msg, 90))"
    end
    if e isa MethodError
        fname = string(e.f)
        # Symbol-into-pipe-callback is the most common mistake — give
        # a targeted hint when the failed call ate a Symbol.
        if any(a -> a isa Symbol, e.args)
            return "type mismatch on `$fname` — a Symbol slipped into a Pattern slot. " *
                   "Wrap the name in `pure(:foo)` or use `p\"foo\"`."
        end
        return "no method `$fname` for these arguments — check the |> chain types"
    end
    if e isa ArgumentError
        return "bad arg: $(e.msg)"
    end
    if e isa BoundsError
        return "out-of-range index — pattern length doesn't match `n()` / `note()` / `scale()` source"
    end
    # Fallback: trim the raw error to one readable line.
    raw = sprint(showerror, e)
    return first(replace(raw, r"\s*\n\s*" => " · "), 160)
end

"""
    _eval_pattern_blocks!(m, target)

Walk the patterns buffer collecting `@dN ... [|> ... ]*` blocks,
ignoring lines whose `@dN` is preceded by `#` (muted). When the
same slot is defined multiple times the LATEST non-muted block
wins. Then eval each block whose slot is in `target` (or all of
them when `target === :all`). Logs a one-line summary.
"""
function _eval_pattern_blocks!(m::RessacApp, target)
    _guard_patterns_only!(m, "E (eval all blocks)") || return
    txt = TK.text(_active_editor(m))
    lines = collect(split(txt, '\n'; keepempty=true))
    blocks = Dict{Symbol,String}()
    prelude = String[]                  # tout ce qui n'est pas un slot, dans l'ordre
    i = 1
    head_rx = r"^\s*(#+\s*)?@d(\d+)\b"
    while i <= length(lines)
        line = lines[i]
        mt = match(head_rx, line)
        if mt === nothing
            # Une ligne hors slot : définition de variable, cps!, fonction…
            # Elle est évaluée avant les slots, pour qu'un `@d1 basse` voie
            # la `basse = p"…"` écrite plus haut.
            if isempty(strip(line)) || startswith(lstrip(line), "#")
                i += 1
                continue
            end
            (a, b) = _logical_block_range(lines, i)
            b = max(b, i)
            push!(prelude, _join_logical_block(lines[a:b]))
            i = b + 1
            continue
        end
        # Capture the whole block: this line + continuation lines.
        j = i + 1
        while j <= length(lines) && startswith(lstrip(lines[j]), "|>")
            j += 1
        end
        if mt.captures[1] === nothing
            slot = Symbol("d", mt.captures[2])
            blocks[slot] = _join_logical_block(lines[i:j-1])
        end
        i = j
    end
    targets = target === :all ?
        sort!(collect(keys(blocks)); by=s -> parse(Int, String(s)[2:end])) :
        target
    ok = 0; err = 0
    ok_slots = Symbol[]
    defs = 0
    if target === :all
        for src in prelude
            try
                Core.eval(Main, Meta.parse(src))
                defs += 1
            catch e
                err += 1
                _push_app_log!(m, "[ERROR] éval : $(_humanize_eval_error(e, src))")
            end
        end
    end
    for slot in targets
        src = get(blocks, slot, nothing)
        src === nothing && continue
        try
            ex = Meta.parse(src)
            Core.eval(Main, ex)
            ok += 1
            push!(ok_slots, slot)
        catch e
            err += 1
            # Try to render a human-readable hint based on common
            # Julia error classes. The raw stacktrace stays available
            # in :keydebug logs if the user needs it; the modal log
            # should be actionable, not technical.
            hint = _humanize_eval_error(e, src)
            _push_app_log!(m, "[ERROR] éval $slot : $hint")
        end
    end
    # Record the rows we just successfully evaluated so the view can
    # flash them green for a few frames — visual confirmation of "this
    # line is now live".
    flash = Int[]
    for (idx, line) in enumerate(lines)
        mt = match(head_rx, line)
        mt === nothing && continue
        mt.captures[1] === nothing || continue   # skip commented
        Symbol("d", mt.captures[2]) in ok_slots && push!(flash, idx)
    end
    m.eval_flash_rows = flash
    m.eval_flash_ts   = time()
    suffix = err > 0 ? " ($err failed)" : ""
    defs_txt = defs == 0 ? "" : " + $defs définition$(defs == 1 ? "" : "s")"
    _push_app_log!(m, "[INFO] :e — $ok bloc$(ok == 1 ? "" : "s") évalué$(ok == 1 ? "" : "s")$defs_txt$suffix")
    _warn_unknown_sounds!(m, [get(blocks, slot, "") for slot in ok_slots])
end

"""
    _unknown_sounds(srcs) -> Vector{String}

Noms de sons cités dans les blocs (`@dN "…"`, `s("…")`) qui ne sont ni
un sample, ni un instrument, ni un synth connu. Vide quand aucun
registre n'est chargé (pas de session).
"""
function _unknown_sounds(srcs::AbstractVector{<:AbstractString})
    known = Set{String}()
    for reg in (_SAMPLE_REGISTRY, _INSTRUMENT_REGISTRY, _SYNTH_REGISTRY)
        for k in keys(reg); push!(known, String(k)); end
    end
    isempty(known) && return String[]
    out = String[]
    for src in srcs
        for mt in eachmatch(r"(?:@d\d+\s+|\bs(?:ound)?\s*\(?\s*)p?\"([^\"]*)\"", src)
            for tok in eachmatch(r"[A-Za-z][A-Za-z0-9_]*", mt.captures[1])
                name = tok.match
                (name in known || resolve_synth_name(Symbol(name)) != Symbol(name)) && continue
                name in out || push!(out, name)
            end
        end
    end
    return out
end

function _warn_unknown_sounds!(m::RessacApp, srcs::AbstractVector{<:AbstractString})
    unknown = _unknown_sounds(srcs)
    isempty(unknown) && return
    # Un nom absent mais présent dans la librairie de synths s'installe
    # d'une commande : on le dit plutôt que de renvoyer au catalogue.
    inlib = [u for u in unknown if _synthlib_builtin_entry(u) !== nothing]
    rest  = [u for u in unknown if !(u in inlib)]
    isempty(inlib) || _push_app_log!(m, "[WARN] " * join(("« $u »" for u in inlib), ", ") *
        " : recette de la librairie, pas encore installée — :add " * first(inlib) * " l'installe")
    isempty(rest) || _push_app_log!(m, "[WARN] son inconnu : " * join(("« $u »" for u in rest), ", ") *
        " — :browse ou Espace b pour la liste, :samples pour les banques")
end

"""
    _join_logical_block(rows) -> String

Recolle les lignes d'un bloc en une expression Julia. Une ligne de
continuation qui commence par `|>` est accrochée à la précédente par
une espace : Julia lit `@d1 p"bd"` puis `|> gain(1)` comme deux
expressions et échoue, alors que `@d1 p"bd" |> gain(1)` est ce que l'on
veut. Les autres lignes (corps de fonction, tableau multi-ligne)
gardent leur saut de ligne.
"""
function _join_logical_block(rows)
    isempty(rows) && return ""
    out = IOBuffer()
    for (i, line) in enumerate(rows)
        if i == 1
            print(out, line)
        elseif startswith(lstrip(String(line)), "|>")
            print(out, " ", strip(String(line)))
        else
            print(out, "\n", line)
        end
    end
    return String(take!(out))
end

"""
    _delim_depth(s) -> Int

Net depth of unclosed `(`, `[`, `{` minus matching closers in `s`,
skipping string literals and `#` comments. Used by
`_logical_block_range` to detect multi-line expressions even when a
mid-block line on its own would parse as `:error` (which is what
happens for the tail of a multi-line array literal, e.g.
`     collect(37:48), collect(49:60)],`).
"""
function _delim_depth(s::AbstractString)
    depth = 0
    in_str = false
    str_char = ' '
    in_cmt = false
    i = firstindex(s)
    n = lastindex(s)
    while i <= n
        c = s[i]
        if in_cmt
            c == '\n' && (in_cmt = false)
        elseif in_str
            if c == '\\' && i < n
                i = nextind(s, i)  # skip escaped char
            elseif c == str_char
                in_str = false
            end
        else
            if c == '#'
                in_cmt = true
            elseif c == '"'
                in_str = true; str_char = '"'
            elseif c == '(' || c == '[' || c == '{'
                depth += 1
            elseif c == ')' || c == ']' || c == '}'
                depth -= 1
            end
        end
        i = nextind(s, i)
    end
    depth
end

"""
    _logical_block_range(lines, row) -> (start_row, end_row)

Find the range of lines that form a single logical Julia expression
containing `row`. Walks UP through `|>` continuations and any lines
that leave an open bracket / paren / brace; walks DOWN until those
brackets all close AND the gathered text parses (or we hit EOF).
Comment prefixes (`# ` / `#`) are stripped first so muted blocks have
the same range as their active twin.
"""
function _logical_block_range(lines::AbstractVector, row::Int)
    1 <= row <= length(lines) || return (row, row)
    _strip_cmt(s) = replace(String(s), r"^\s*#+\s*" => "")

    # depths[i] = net delim depth at the START of line i (1-based).
    # Walking up while depths[i] > 0 means "still inside an unclosed
    # bracket from a previous line" — i.e. line i is a continuation.
    stripped = _strip_cmt.(lines)
    depths = zeros(Int, length(lines) + 1)
    for i in 1:length(lines)
        depths[i + 1] = depths[i] + _delim_depth(stripped[i])
    end

    start_row = row
    while start_row > 1
        cur = stripped[start_row]
        if startswith(lstrip(cur), "|>") || depths[start_row] > 0
            start_row -= 1
        else
            break
        end
    end

    end_row = row
    # First close every still-open bracket from start_row's perspective.
    while end_row < length(lines) && depths[end_row + 1] > depths[start_row]
        end_row += 1
    end
    # Then keep extending while the joined block is still parse-incomplete
    # or the next line continues with `|>`.
    while end_row < length(lines)
        block = join(stripped[start_row:end_row], "\n")
        parsed = Meta.parse(block; raise = false)
        is_inc = parsed isa Expr && parsed.head === :incomplete
        next_cont = startswith(lstrip(stripped[end_row + 1]), "|>")
        if is_inc || next_cont
            end_row += 1
        else
            break
        end
    end
    return (start_row, end_row)
end

# Return true when the focused workspace pane is an EditorPane with
# role `:patterns` — Julia eval is safe. Return false + log a hint
# when called from any other context (synth pane, doc/log/scope
# pane, no workspace). Prevents Meta.parse from being handed
# SuperCollider source it can't read.
function _guard_patterns_only!(m::RessacApp, action::AbstractString)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
        if leaf isa PaneLeaf && 1 <= leaf.current_tab <= length(leaf.tabs)
            pane = leaf.tabs[leaf.current_tab]
            if pane isa EditorPane && !isempty(pane.tabs) &&
               pane.tabs[pane.current_tab].role === :patterns
                return true
            end
        end
    end
    _push_app_log!(m,
        "[WARN] $action ne marche que dans une pane patterns — Ctrl-w h/j/k/l pour la focaliser")
    return false
end

function _eval_current_line!(m::RessacApp)
    _guard_patterns_only!(m, "e (eval current line)") || return
    ce = _active_editor(m)
    txt = TK.text(ce)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ce.cursor_row
    1 <= row <= length(lines) || return
    isempty(strip(lines[row])) && return
    (start_row, end_row) = _logical_block_range(lines, row)
    block = _join_logical_block(lines[start_row:end_row])
    try
        ex = Meta.parse(block)
        result = Core.eval(Main, ex)
        rstr = sprint(io -> show(IOContext(io, :limit=>true, :displaysize=>(1, 60)), result))
        _push_app_log!(m, "[INFO] éval ⇒ $rstr")
        _warn_unknown_sounds!(m, [block])
        # Cascade: if this eval rebound any top-level names, sweep the
        # buffer for `@dN` blocks that reference them and re-eval, so the
        # slots pick up the new value. Single-level (no recursive cascade).
        rebound = _names_bound_by(ex)
        if !isempty(rebound)
            _cascade_dN_reeval!(m, lines, rebound, start_row, end_row)
            # If the scope is attached to a name we just rebound, re-
            # resolve the reference so the visualisation tracks the
            # fresh reservoir instead of the dead one. Pre-computes the
            # graph layout when applicable.
            if _APP_SCOPE_RESERVOIR_NAME[] in rebound
                _refresh_scope_reservoir!(m)
            end
        end
    catch err
        _push_app_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end

# Collect names bound by a top-level expression. Handles assignments,
# function definitions, and `const`. Used by the cascade re-eval to
# decide which dependent @dN blocks need refreshing.
function _names_bound_by(ex)
    names = Set{Symbol}()
    _collect_bound_names!(names, ex)
    names
end

_collect_bound_names!(::Set{Symbol}, ::Any) = nothing

function _collect_bound_names!(names::Set{Symbol}, ex::Expr)
    if ex.head === :(=)
        lhs = ex.args[1]
        if lhs isa Symbol
            push!(names, lhs)
        elseif lhs isa Expr && lhs.head === :call
            fname = lhs.args[1]
            fname isa Symbol && push!(names, fname)
        elseif lhs isa Expr && lhs.head === :tuple
            for s in lhs.args
                s isa Symbol && push!(names, s)
            end
        end
    elseif ex.head === :function
        sig = ex.args[1]
        if sig isa Expr && sig.head === :call
            fname = sig.args[1]
            fname isa Symbol && push!(names, fname)
        end
    elseif ex.head === :const || ex.head === :global
        for sub in ex.args
            _collect_bound_names!(names, sub)
        end
    elseif ex.head === :block
        for sub in ex.args
            _collect_bound_names!(names, sub)
        end
    end
    return
end

# Walk the buffer, find every `@dN ...` block (multi-line aware), and
# re-eval those whose AST references any of `rebound`. The block being
# eval'd (rows in `skip_first..skip_last`) is excluded.
function _cascade_dN_reeval!(m::RessacApp, lines::Vector,
                              rebound::Set{Symbol},
                              skip_first::Int, skip_last::Int)
    n = length(lines)
    i = 1
    n_cascade = 0
    while i <= n
        line = lines[i]
        if !occursin(r"^\s*@d\d+\b", line)
            i += 1
            continue
        end
        # Found a @dN line — extend down while incomplete.
        end_row = i
        block = String(line)
        while end_row < n
            parsed = Meta.parse(block; raise = false)
            if parsed isa Expr && parsed.head === :incomplete
                end_row += 1
                block = _join_logical_block(lines[i:end_row])
            else
                break
            end
        end
        # Skip the just-evaled block to avoid double-firing.
        if !(end_row < skip_first || i > skip_last)
            i = end_row + 1
            continue
        end
        # Parse + check for any reference to a rebound name.
        try
            ex = Meta.parse(block)
            if _refs_any(ex, rebound)
                Core.eval(Main, ex)
                n_cascade += 1
            end
        catch err
            _push_app_log!(m,
                "[WARN] cascade ligne $i : $(sprint(showerror, err))")
        end
        i = end_row + 1
    end
    n_cascade > 0 &&
        _push_app_log!(m, "[INFO] cascade : $n_cascade slot$(n_cascade == 1 ? "" : "s") ré-évalué$(n_cascade == 1 ? "" : "s")")
    return
end

# AST walk: returns true iff `ex` references any symbol in `names`.
_refs_any(ex::Symbol, names::Set{Symbol}) = ex in names
function _refs_any(ex::Expr, names::Set{Symbol})
    for arg in ex.args
        _refs_any(arg, names) && return true
    end
    return false
end
_refs_any(::Any, ::Set{Symbol}) = false

# ---------------------------------------------------------------------
# Synth pane management
# ---------------------------------------------------------------------

_app_synth_path(name::AbstractString; mode::Symbol = :dsl) =
    joinpath(pwd(), "plugins", "user-synths",
             String(name) * (mode === :dsl ? ".jl" : ".scd"))
