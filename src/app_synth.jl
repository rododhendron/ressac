# src/app_synth.jl
# Panes synth : ouvrir (librairie/user/starter), fermer, cycler, sauver,
# tester (T avec accélération), aligner le nom du synthdef ; bascule de
# focus patterns ⟷ synth.

"""
    _swap_focus!(m)

Toggle workspace focus between the patterns pane and a synth pane.
From patterns → focus the first synth pane (if any). From a synth
pane → focus the patterns pane. Bound to Tab in normal mode.
"""
function _swap_focus!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    if _focused_role(m) === :synth
        # Back to the patterns pane.
        for leaf in _all_leaves(ws.tree)
            for tab in leaf.tabs
                if tab isa EditorPane && !isempty(tab.tabs) &&
                   tab.tabs[tab.current_tab].role === :patterns
                    ws.focused_pane = leaf.id
                    return
                end
            end
        end
    else
        # Into the first synth pane.
        syn = _all_synth_buffers(m)
        isempty(syn) || (ws.focused_pane = syn[1][1].id)
    end
end

"""
    _STARTER_DSL(name)

Default body for a fresh sandbox / unnamed synth tab in DSL mode.
"""
_STARTER_DSL(name) = """
# T = test  ·  :w <name> = save as  ·  :dsl = DSL guide  ·  :snip = snippets

@synth :$(name) (freq=220, sustain=0.5) sin_osc(:freq)
"""

"""
    _open_sandbox_synth!(m)

Open a fresh synth tab with a randomised name (`sketch_<id>`) and
the starter template — no manual naming needed. The user iterates
in the tab; `:w realname` later renames it onto disk via the
existing save-as path.
"""
function _open_sandbox_synth!(m::RessacApp)
    # 3-char base36 id, e.g. "sketch_a7p". Cheap, collision-resistant
    # enough for interactive use; if it ever does collide
    # _open_synth_tab! switches to the existing tab which is also fine.
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    id = String([chars[rand(1:length(chars))] for _ in 1:3])
    name = "sketch_$(id)"
    _open_synth_tab!(m, name)
    _push_app_log!(m, "[INFO] sandbox synth '$name' — :w <realname> to save under a chosen name")
end

"""
    _open_synth_tab!(m, name)

If a synth pane for `name` is already open in the workspace, focus
it. Otherwise vsplit a new synth-role EditorPane, load the source
(DSL `.jl` preferred, else raw `.scd`, else starter template), and
focus it. Synths are plain workspace panes now — no separate tab
list.
"""
function _open_synth_tab!(m::RessacApp, name::AbstractString)
    name = String(name)
    ws = current_workspace(m.workspaces)
    # Already open → focus its leaf.
    if ws !== nothing
        for (leaf, buf) in _all_synth_buffers(m)
            if buf.name == name
                ws.focused_pane = leaf.id
                _push_app_log!(m, "[INFO] switched to synth '$name'")
                return
            end
        end
    end
    # Mode detection: prefer existing `.jl` (DSL); fall back to `.scd`
    # (raw SC); then a LIBRARY recipe (copied into user-synths, comme le
    # fait :lib) ; otherwise a fresh DSL starter.
    dsl_path = _app_synth_path(name; mode = :dsl)
    sc_path  = _app_synth_path(name; mode = :sc)
    if !isfile(dsl_path) && !isfile(sc_path)
        entry = _synthlib_builtin_entry(name)
        entry === nothing || return _instantiate_synth_entry!(m, entry)
    end
    src, mode = if isfile(dsl_path)
        (read(dsl_path, String), :dsl)
    elseif isfile(sc_path)
        (read(sc_path, String), :sc)
    else
        (_STARTER_DSL(name), :dsl)
    end
    pane = _place_pane!(m, :editor, Dict{String,Any}(
        "buffer_role" => "synth",
        "name"        => name,
    ))
    pane isa EditorPane || return
    eb = pane.tabs[1]
    eb.synth_mode = mode
    TK.set_text!(eb.code_editor, src)
    eb.code_editor.mode = :normal
    eb.code_editor.focused = true
    _push_app_log!(m, "[INFO] opened synth '$name' [$mode] — T test, :w save")
end

"""
    _close_synth_pane!(m)

Close every synth pane in the workspace. Triggered by `:back`. To
drop just the focused synth, see `_close_active_synth_tab!`.
"""
function _close_synth_pane!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    closed = 0
    # Re-fetch each iteration: cmd_close! mutates the tree.
    while true
        syn = _all_synth_buffers(m)
        isempty(syn) && break
        ws.focused_pane = syn[1][1].id
        cmd_close!(m.workspaces)
        closed += 1
        closed > 64 && break   # safety against a stuck close
    end
    closed == 0 || _push_app_log!(m, "[INFO] closed $closed synth pane(s)")
end

"""
    _close_active_synth_tab!(m)

Close the focused synth pane (or the first synth pane if focus
drifted off one). No-op when no synth pane is open.
"""
function _close_active_synth_tab!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    buf = _focused_buffer(m)
    leaf_id = if buf !== nothing && buf.role === :synth
        # Focused leaf is a synth — close it.
        ws.focused_pane
    else
        syn = _all_synth_buffers(m)
        isempty(syn) && return
        syn[1][1].id
    end
    name = (b = _leaf_synth_name(m, leaf_id)) === nothing ? "?" : b
    ws.focused_pane = leaf_id
    cmd_close!(m.workspaces)
    _push_app_log!(m, "[INFO] closed synth '$name'")
end

_leaf_synth_name(m::RessacApp, leaf_id::Int) = begin
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    leaf = _find_leaf_by_id(ws.tree, leaf_id)
    (leaf isa PaneLeaf && !isempty(leaf.tabs)) || return nothing
    pane = leaf.tabs[1]
    (pane isa EditorPane && !isempty(pane.tabs)) || return nothing
    pane.tabs[1].name
end

"""
    _cycle_synth_tab!(m; dir=+1)

Focus the next (`dir=+1`) / previous (`dir=-1`) synth pane in the
workspace. No-op when fewer than two synth panes are open.
"""
function _cycle_synth_tab!(m::RessacApp; dir::Int = +1)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    syn = _all_synth_buffers(m)
    length(syn) <= 1 && return
    cur = findfirst(((leaf, _),) -> leaf.id == ws.focused_pane, syn)
    cur = cur === nothing ? 1 : cur
    nxt = mod(cur + dir - 1, length(syn)) + 1
    ws.focused_pane = syn[nxt][1].id
end

function _list_synth_tabs!(m::RessacApp)
    syn = _all_synth_buffers(m)
    if isempty(syn)
        _push_app_log!(m, "[INFO] no synth panes open")
        return
    end
    ws = current_workspace(m.workspaces)
    for (leaf, buf) in syn
        marker = (ws !== nothing && leaf.id == ws.focused_pane) ? "▶" : " "
        _push_app_log!(m, "  $marker $(buf.name) [$(buf.synth_mode)]")
    end
end

"""
    _save_current_synth!(m; new_name=nothing)

Persist the synth source to `plugins/user-synths/<name>.scd`. If
`new_name` is given, save under that name AND switch the editor to
the new identity (rewriting the `SynthDef(\\old, ...)` declaration).
"""
function _save_current_synth!(m::RessacApp; new_name::Union{Nothing,AbstractString}=nothing)
    _synth_pane_open(m) || (_push_app_log!(m, "[ERROR] :w — no synth open"); return)
    tab = _current_synth_tab(m)
    old_name = tab.name
    text = TK.text(tab.code_editor)
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    align = tab.synth_mode === :dsl ? _align_dsl_synth_name : _align_synthdef_name
    if new_name === nothing
        # Plain :w — overwrite the current tab's backing file at the
        # extension that matches its mode (.jl for DSL, .scd for SC).
        text = align(text, old_name)
        TK.set_text!(tab.code_editor, text)
        write(_app_synth_path(old_name; mode = tab.synth_mode), text)
        register_synth!(SynthEntry(Symbol(old_name), "user-synths",
            Dict{String,Any}("description" => "live-edited synth",
                             "tags" => ["user", String(tab.synth_mode)])))
        _push_app_log!(m, "[INFO] saved synth → $(_app_synth_path(old_name; mode = tab.synth_mode))")
    else
        # :w newname — Save-As. Same mode as the originating tab; the
        # name token in the source gets rewritten to match.
        name = String(new_name)
        new_text = align(text, name)
        write(_app_synth_path(name; mode = tab.synth_mode), new_text)
        register_synth!(SynthEntry(Symbol(name), "user-synths",
            Dict{String,Any}("description" => "live-edited synth",
                             "tags" => ["user", String(tab.synth_mode)])))
        _push_app_log!(m, "[INFO] saved synth as → $(_app_synth_path(name; mode = tab.synth_mode))")
        _open_synth_tab!(m, name)
    end
end

"""
    _fire_t_with_accel!(m; held=false)

Drive a single T press, throttled by `config.t_hold_initial_ms` /
`t_hold_min_ms` / `t_hold_accel`. On a fresh press (`held=false`) we
reset the interval to its initial value and fire immediately. On
key_repeat we only fire if at least `t_hold_interval_ms` ms have
elapsed since the last fire — and on each successful fire the
interval shrinks toward the floor.
"""
function _fire_t_with_accel!(m::RessacApp; held::Bool=false)
    cfg = ressac_config()
    now = time() * 1000   # ms
    if !held
        # Fresh press → fire, reset interval clock.
        m.t_hold_interval_ms = Float64(cfg.t_hold_initial_ms)
        m.last_t_fire = now
        _test_current_synth!(m)
        return
    end
    # key_repeat path: gate by interval.
    if now - m.last_t_fire < m.t_hold_interval_ms
        return
    end
    m.t_hold_interval_ms = max(Float64(cfg.t_hold_min_ms),
                               m.t_hold_interval_ms * cfg.t_hold_accel)
    m.last_t_fire = now
    _test_current_synth!(m)
end

"""
    _test_current_synth!(m; raw=false)

Reload the synth source on the SC side and fire a preview note via
`/ressac/evalAndPlay`. Server-side `s.sync` ensures the new SynthDef
is registered before the play fires.
"""
function _test_current_synth!(m::RessacApp; raw::Bool = false)
    _synth_pane_open(m) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    tab = _current_synth_tab(m)
    src = TK.text(tab.code_editor)
    if tab.synth_mode === :dsl
        # DSL mode: realign the @synth name to the tab name (same
        # contract as SC mode's SynthDef name), then eval the buffer
        # as Julia. The @synth macro inside calls play_synth which
        # compiles to SC and ships to /ressac/evalAndPlay itself.
        src = _align_dsl_synth_name(src, tab.name)
        try
            # Eval in the SynthDSL submodule so unqualified UGen names
            # (saw, sin_osc, rlpf, …) resolve. Main only has the Pattern
            # signal variants of the colliding names (saw, tri, square).
            # _dsl_preprocess joins leading-`|>` continuation lines.
            Core.eval(SynthDSL, Meta.parse(SynthDSL._dsl_preprocess(src)))
            _push_app_log!(m, "[INFO] T — test $(tab.name) (DSL → compiled SC)")
        catch err
            _push_app_log!(m, "[ERROR] DSL eval: $(sprint(showerror, err))")
        end
    else
        # SC raw mode (legacy): ship the buffer verbatim.
        src = _align_synthdef_name(src, tab.name)
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay",
                                              Any[tab.name, src])))
        _push_app_log!(m, "[INFO] T — test $(tab.name) (raw SC)")
    end
end

"""
    _align_dsl_synth_name(src, target)

Rewrite the FIRST `@synth :<old>` token in a DSL buffer to match
`target`. Idempotent when they already match; no-op if no @synth
declaration is found.
"""
function _align_dsl_synth_name(src::AbstractString, target::AbstractString)
    mt = match(r"@synth\s+:(\w+)", src)
    mt === nothing && return src
    current = mt.captures[1]
    current == target && return src
    return replace(src, r"@synth\s+:(\w+)" =>
                   SubstitutionString("@synth :$(target)"); count = 1)
end

"""
    _align_synthdef_name(src, target)

Replace the FIRST `SynthDef(\\<anything>, …)` declaration in `src`
so its name matches `target`. Returns the rewritten source. If no
SynthDef declaration is found, `src` is returned unchanged — the
user might be experimenting with a non-SynthDef snippet and we
don't want to fight them.
"""
function _align_synthdef_name(src::AbstractString, target::AbstractString)
    m = match(r"(SynthDef\s*\(\s*\\)(\w+)", src)
    m === nothing && return src
    current = m.captures[2]
    current == target && return src
    return replace(src, r"(SynthDef\s*\(\s*\\)(\w+)" => SubstitutionString("\\1$(target)"); count=1)
end

# ── Sub-project 9 — WorkspaceManager bootstrap ─────────────────────

# ── Ponts son ⟷ patterns ────────────────────────────────────────────
# Recette de librairie intégrée (pas les fichiers utilisateur) par nom.
function _synthlib_builtin_entry(name::AbstractString)
    for e in _synthlib_all_entries()
        e.name == name && e.category != "user" && return e
    end
    return nothing
end

# Le mot sous le curseur, sans le `:` d'un symbole (`s(:kick)` → kick).
function _word_under_cursor_plain(m::RessacApp)
    ed = _active_editor(m)
    ed === nothing && return ""
    1 <= ed.cursor_row <= length(ed.lines) || return ""
    chars = ed.lines[ed.cursor_row]
    isempty(chars) && return ""
    w = _word_under_cursor_chars(chars, clamp(ed.cursor_col + 1, 1, length(chars)))
    return String(lstrip(String(w), ':'))
end

_is_known_synth(name::AbstractString) =
    isfile(_app_synth_path(name; mode = :dsl)) || isfile(_app_synth_path(name; mode = :sc)) ||
    _synthlib_builtin_entry(name) !== nothing || haskey(_SYNTH_REGISTRY, Symbol(name))

"""
    _goto_synth_under_cursor!(m)

`gs` dans la pane patterns : ouvre le synth sous le curseur (fichier
utilisateur, recette de librairie ou synth enregistré) dans DESIGN.
"""
function _goto_synth_under_cursor!(m::RessacApp)
    w = _word_under_cursor_plain(m)
    if isempty(w) || !_is_known_synth(w)
        _push_app_log!(m, "[WARN] gs — « $w » n'est pas un synth connu (fichier user-synths, librairie ou synth enregistré)")
        return
    end
    _switch_workspace_named!(m, "DESIGN")
    _open_synth_tab!(m, w)
    return
end

# L'éditeur patterns du workspace courant (le crée si besoin).
function _patterns_editor!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        for leaf in _all_leaves(ws.tree), (ti, tab) in enumerate(leaf.tabs)
            tab isa EditorPane || continue
            1 <= tab.current_tab <= length(tab.tabs) || continue
            if tab.tabs[tab.current_tab].role === :patterns
                ws.focused_pane = leaf.id; leaf.current_tab = ti
                return tab.tabs[tab.current_tab].code_editor
            end
        end
    end
    return _open_or_reuse_editable_pane!(m; role = "patterns", name = "main")
end

# Ajoute une ligne après la dernière ligne non vide, curseur dessus.
function _append_pattern_line!(ed::TK.CodeEditor, line::AbstractString)
    lines = collect(split(TK.text(ed), '\n'; keepempty = true))
    last = something(findlast(l -> !isempty(strip(l)), lines), 0)
    insert!(lines, last + 1, String(line))
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = last + 1
    ed.cursor_col = 0
    return
end

"""
    _use_synth_in_pattern!(m, name)

Pont « utiliser ce son » : bascule dans PLAY, ajoute
`@dN p"name*4"` à la fin du buffer patterns (N = premier slot libre),
focalise la ligne. L'appelant a sauvé/enregistré le synth avant.
"""
function _use_synth_in_pattern!(m::RessacApp, name::AbstractString)
    _switch_workspace_named!(m, "PLAY")
    ed = _patterns_editor!(m)
    ed === nothing && (_push_app_log!(m, "[ERROR] U — pas d'éditeur patterns"); return)
    slot = _next_free_d_slot(ed)
    line = "@d$slot p\"$(name)*4\""
    _append_pattern_line!(ed, line)
    ed.mode = :normal
    ed.focused = true
    _push_app_log!(m, "[INFO] $line ajouté — e pour jouer, m pour mute")
    return
end

# U depuis une pane synth : sauve (:w) puis utilise.
function _use_current_synth_in_pattern!(m::RessacApp)
    tab = _current_synth_tab(m)
    tab === nothing && (_push_app_log!(m, "[ERROR] U — pas de synth ouvert"); return)
    _save_current_synth!(m)
    _use_synth_in_pattern!(m, tab.name)
    return
end
