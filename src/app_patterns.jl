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
    _guard_patterns_only!(m, "m (mute)") || return
    ed = _patterns_editor(m)
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
        _edit_text!(ed, join(lines, '\n'))
        ed.cursor_row = row
        ed.cursor_col = col + 2
        unset_pattern!(m.scheduler, slot)
        # Best-effort voice kill: free any drones on the SC side that
        # would otherwise hang now that the pattern stopped scheduling.
        _kill_voices_for_line!(m, join(lines[root_row:end_row], "\n"))
        _push_app_log!(m, "[INFO] $slot mute")
    elseif (mt = match(_COMMENTED_SLOT_RX_APP, root_line)) !== nothing
        slot = Symbol(mt.captures[1])
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
        _edit_text!(ed, join(lines, '\n'))
        ed.cursor_row = row
        ed.cursor_col = max(0, col - 2)
        # Re-eval so the slot comes back live — `_eval_current_line!`
        # uses the same block detection, so multi-line blocks evaluate
        # correctly from any cursor row inside them. Un slot lancé par
        # `Entrée` (hors de la grille) revient là où il était : son cycle 0
        # reste à la frappe d'origine, pas à celle du démute — il retombe
        # en place avec ce qui a continué de jouer.
        origin = get(m.slot_offgrid, slot, nothing)
        sched = _LIVE_SCHEDULER[]
        if origin === nothing || sched === nothing
            _eval_current_line!(m)
        else
            _eval_current_line!(m; phase = (origin, Float64(_phase_at(sched))))
        end
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
    # s("mywob") / sound("a b") / @d1 "bd hh" — tout nom de synth ou
    # d'instrument écrit dans une chaîne : sans ça, couper un slot qui joue
    # un synth à longue tenue laissait ses notes sonner jusqu'au bout.
    for mq in eachmatch(r"\"((?:[^\"\\]|\\.)*)\"", line), tok in eachmatch(r"[A-Za-z_]\w*", String(mq.captures[1]))
        name = Symbol(tok.match)
        (synth_info(name) !== nothing || instrument_info(name) !== nothing) && push!(names, name)
    end
    # gate(:name, …)  /  pure(:name)  /  :name |> …
    for mn in eachmatch(r":(\w+)", line)
        push!(names, Symbol(mn.captures[1]))
    end
    for ms in eachmatch(r"@(d\d+)", line)
        _drone_slot_release!(Symbol(ms.captures[1]))
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

function _insert_line_after_cursor!(ed::TK.CodeEditor, line::AbstractString)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(lines))
    insert!(lines, row + 1, String(line))
    _edit_text!(ed, join(lines, '\n'))
    ed.cursor_row = row + 1
    ed.cursor_col = length(line)
end

# ---------------------------------------------------------------------
# Panic
# ---------------------------------------------------------------------

"""
    _humanize_eval_error(e, src) -> String

Une exception d'évaluation dite en une phrase, pour qui joue et ne débogue
pas : ce qui cloche et où chercher. Courte — elle s'écrit au bout de la
ligne fautive. Ce qu'on ne reconnaît pas garde le texte de Julia, sur une
ligne.
"""
function _humanize_eval_error(e, src::AbstractString)
    e isa LoadError && return _humanize_eval_error(e.error, src)
    if e isa UndefVarError
        return "« $(e.var) » n'existe pas — :browse pour les sons, :doc pour les fonctions"
    end
    if e isa Base.Meta.ParseError
        return "syntaxe : une parenthèse ou un guillemet n'est pas fermé · " *
               first(replace(sprint(showerror, e), r"\s*\n\s*" => " "), 70)
    end
    if e isa MethodError
        fname = string(e.f)
        if any(a -> a isa Symbol, e.args)
            return "$fname a reçu un nom nu là où il attend un pattern — écris p\"nom\" ou pure(:nom)"
        end
        return "$fname ne s'applique pas à ces arguments — vérifie la chaîne de |>"
    end
    e isa ArgumentError && return "argument refusé : $(e.msg)"
    if e isa BoundsError
        return "indice hors limites — la source de n() / note() / scale() est trop courte"
    end
    return first(replace(sprint(showerror, e), r"\s*\n\s*" => " · "), 160)
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
    _guard_patterns_only!(m, "E (tout évaluer)") || return
    txt = TK.text(_patterns_editor(m))
    lines = collect(split(txt, '\n'; keepempty=true))
    (scanned, prelude) = _scan_slot_blocks(lines)
    live = _live_blocks(scanned)
    blocks = Dict{Symbol,String}(slot => b.src for (slot, b) in live)
    head_rx = _SLOT_HEAD_RX
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
        if _eval_slot_block!(m, slot, src)
            ok += 1
            push!(ok_slots, slot)
        else
            err += 1
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

# Return true when the focused workspace pane is an EditorPane with
# role `:patterns` — Julia eval is safe. Return false + log a hint
# when called from any other context (synth pane, doc/log/scope
# pane, no workspace). Prevents Meta.parse from being handed
# SuperCollider source it can't read.
function _guard_patterns_only!(m::RessacApp, action::AbstractString)
    # La cible est le texte des patterns du workspace, quelle que soit la
    # pane focalisée (voir `_patterns_editor`) : `e` depuis le wiki évalue
    # la ligne du curseur des patterns, comme la barre de touches l'annonce.
    _patterns_editor(m) === nothing || return true
    _push_app_log!(m, "[WARN] $action : pas de texte de patterns à l'écran — :reset le remet")
    return false
end

function _eval_current_line!(m::RessacApp; phase = nothing)
    _guard_patterns_only!(m, "e (évaluer la ligne)") || return
    ce = _patterns_editor(m)
    txt = TK.text(ce)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ce.cursor_row
    1 <= row <= length(lines) || return
    isempty(strip(lines[row])) && return
    (start_row, end_row) = _logical_block_range(lines, row)
    block = _join_logical_block(lines[start_row:end_row])
    slot = _slot_of_src(block)
    try
        ex = Meta.parse(block)
        result = _with_slot_phase(() -> Core.eval(Main, ex), slot === nothing ? nothing : phase)
        slot === nothing || _slot_evaluated!(m, slot, block; phase = phase)
        rstr = sprint(io -> show(IOContext(io, :limit=>true, :displaysize=>(1, 60)), result))
        _push_app_log!(m, (slot !== nothing && phase !== nothing) ?
            "[INFO] $slot lancé maintenant, hors de la grille — e le recale" : "[INFO] éval ⇒ $rstr")
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
        hint = _humanize_eval_error(err, block)
        slot === nothing || _slot_failed!(m, slot, block, hint)
        _push_app_log!(m, "[ERROR] éval$(slot === nothing ? "" : " $slot") : $hint")
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
    n_cascade = 0
    for (slot, b) in _live_blocks(_scan_slot_blocks(lines)[1])
        # Le bloc qu'on vient d'évaluer ne rejoue pas une seconde fois.
        (b.last_row < skip_first || b.row > skip_last) || continue
        ex = Meta.parse(b.src; raise = false)
        (ex isa Expr && ex.head in (:error, :incomplete)) && continue
        _refs_any(ex, rebound) || continue
        _eval_slot_block!(m, slot, b.src) && (n_cascade += 1)
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
    joinpath(_project_dir(), "plugins", "user-synths",
             String(name) * (mode === :dsl ? ".jl" : ".scd"))
