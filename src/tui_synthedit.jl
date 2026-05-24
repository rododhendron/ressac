# Live SynthDef editor inside the TUI.
#
# `:synth <name>` swaps the main pattern buffer with the SCD source for
# <name> (loaded from plugins/user-synths/<name>.scd if it exists, else
# a starter template). All vim editing keys work normally. `:reload`
# ships the current buffer to SuperCollider via /dirt/evalSC so the new
# SynthDef is registered immediately. `:save-synth` writes to disk and
# adds a [synths.<name>] entry to plugins/user-synths/plugin.toml.
# `:back` restores the main buffer (synth source is kept in the stash
# in case `:synth <name>` is reopened).

const _SYNTH_PLUGIN_DIR = "plugins/user-synths"

"""
    _STARTER_SYNTHDEF(name)

Template returned when the user `:synth <name>` for an unknown name.
Already valid SCD — saw oscillator → resonant LPF modulated by an
LFO → ADSR amp envelope → DirtPan. A solid blank canvas for a wobble
bass, swap the UGens to taste.
"""
_STARTER_SYNTHDEF(name) = [
    "// T = test  ·  :w <name> = save as  ·  :snip = templates",
    "",
    "SynthDef(\\$(name), { |out, pan = 0, sustain = 0.5, gain = 0.5|",
    "    var sig, amp;",
    "    sig = SinOsc.ar(440, mul: 0.1);",
    "    amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);",
    "    OffsetOut.ar(out, DirtPan.ar(sig * amp, ~dirt.numChannels, pan));",
    "}).add;",
]

"""
    _enter_synth_edit!(m, name)

Stash the main buffer + cursor into `m.synth_stash_*` and load the
SynthDef source for `name` into `m.buffer`. Loads from disk if the
plugin file exists; otherwise inserts the starter template.
"""
function _enter_synth_edit!(m::LiveModel, name::AbstractString)
    name = String(name)
    if !isempty(m.synth_editing)
        # Already in synth-edit. Switch to that tab if it exists, else
        # open a new one.
        existing_idx = findfirst(t -> t.name == name, m.synth_tabs)
        if existing_idx !== nothing
            _switch_synth_tab!(m, existing_idx)
            _push_log!(m, "[INFO] switched to tab '$name'")
            return
        end
        # Save current tab's state, then push a new tab.
        _stash_current_synth_tab!(m)
        push!(m.synth_tabs, _load_synth_tab(name))
        m.synth_tab_idx = length(m.synth_tabs)
        _activate_synth_tab!(m)
        _push_log!(m, "[INFO] new tab '$name' (tab $(m.synth_tab_idx)/$(length(m.synth_tabs))) — :close to drop it")
        return
    end
    # First synth — stash patterns + open.
    m.synth_stash_buffer = m.buffer
    m.synth_stash_row    = m.cursor_row
    m.synth_stash_col    = m.cursor_col
    m.synth_editing      = name
    m.focus              = :synth
    empty!(m.synth_tabs)
    push!(m.synth_tabs, _load_synth_tab(name))
    m.synth_tab_idx = 1
    _activate_synth_tab!(m)
    _push_log!(m, "[INFO] editing synth '$name' — :w save, :w <name> save-as, :close drop tab, :back exit")
end

"""
    _load_synth_tab(name) -> tab

Load the SCD source for `name` from disk if it exists, otherwise the
starter template. Returns a (name, buffer, row, col) named tuple.
"""
function _load_synth_tab(name::AbstractString)
    path = _synth_source_path(name)
    lines = if isfile(path)
        text = read(path, String)
        parsed = String.(split(text, '\n'; keepempty=true))
        while !isempty(parsed) && isempty(parsed[end])
            pop!(parsed)
        end
        parsed
    else
        _STARTER_SYNTHDEF(name)
    end
    return (name=String(name), buffer=lines, row=1, col=1)
end

"""
    _stash_current_synth_tab!(m)

Copy m.buffer / cursor into m.synth_tabs[m.synth_tab_idx] before we
swap to a different tab. Works whether focus is on the synth pane
(state lives in m.buffer) or on patterns (state lives in
m.synth_stash_buffer).
"""
function _stash_current_synth_tab!(m::LiveModel)
    m.synth_tab_idx == 0 && return
    if m.focus === :synth
        m.synth_tabs[m.synth_tab_idx] =
            (name=m.synth_editing, buffer=m.buffer,
             row=m.cursor_row, col=m.cursor_col)
    else
        m.synth_tabs[m.synth_tab_idx] =
            (name=m.synth_editing, buffer=m.synth_stash_buffer,
             row=m.synth_stash_row, col=m.synth_stash_col)
    end
end

"""
    _activate_synth_tab!(m)

Load m.synth_tabs[m.synth_tab_idx] into the focused-or-stash slot
(opposite of `_stash_current_synth_tab!`). Updates `m.synth_editing`.
"""
function _activate_synth_tab!(m::LiveModel)
    tab = m.synth_tabs[m.synth_tab_idx]
    m.synth_editing = tab.name
    if m.focus === :synth
        m.buffer     = tab.buffer
        m.cursor_row = tab.row
        m.cursor_col = tab.col
    else
        m.synth_stash_buffer = tab.buffer
        m.synth_stash_row    = tab.row
        m.synth_stash_col    = tab.col
    end
    _clear_completions!(m)
    empty!(m.history)
    empty!(m.redo_stack)
end

"""
    _switch_synth_tab!(m, new_idx)

Switch the active tab to `new_idx` (1-based). Stashes current tab
state first.
"""
function _switch_synth_tab!(m::LiveModel, new_idx::Integer)
    1 <= new_idx <= length(m.synth_tabs) || return
    _stash_current_synth_tab!(m)
    m.synth_tab_idx = new_idx
    _activate_synth_tab!(m)
end

"""
    _close_synth_tab!(m)

Drop the active tab. If it was the last tab, this exits synth-edit
entirely (same as `:back`). Otherwise switches to the previous tab.
"""
function _close_synth_tab!(m::LiveModel)
    isempty(m.synth_tabs) && return
    closed_name = m.synth_editing
    deleteat!(m.synth_tabs, m.synth_tab_idx)
    if isempty(m.synth_tabs)
        _exit_synth_edit!(m)
    else
        m.synth_tab_idx = clamp(m.synth_tab_idx - 1, 1, length(m.synth_tabs))
        _activate_synth_tab!(m)
        _push_log!(m, "[INFO] closed '$closed_name' — now on '$(m.synth_editing)' ($(m.synth_tab_idx)/$(length(m.synth_tabs)))")
    end
end

function _cycle_synth_tab!(m::LiveModel; dir::Int = +1)
    n = length(m.synth_tabs)
    n <= 1 && return
    new_idx = mod(m.synth_tab_idx + dir - 1, n) + 1
    _switch_synth_tab!(m, new_idx)
end

function _list_synth_tabs!(m::LiveModel)
    if isempty(m.synth_tabs)
        _push_log!(m, "[INFO] no synth tabs open")
        return
    end
    for (i, tab) in enumerate(m.synth_tabs)
        marker = i == m.synth_tab_idx ? "▶" : " "
        _push_log!(m, "  $marker $i. $(tab.name)")
    end
end

"""
    _exit_synth_edit!(m)

Swap the stashed main buffer back. Synth source stays in memory only
if the user pressed `:save-synth` before exiting.
"""
function _exit_synth_edit!(m::LiveModel)
    if isempty(m.synth_editing)
        _push_log!(m, "[WARN] :back — not editing a synth")
        return
    end
    name = m.synth_editing
    # Make sure main state ends up in m.buffer regardless of which pane
    # was focused last.
    if m.focus === :synth
        m.buffer     = m.synth_stash_buffer
        m.cursor_row = m.synth_stash_row
        m.cursor_col = m.synth_stash_col
    end
    m.synth_editing      = ""
    m.synth_stash_buffer = String[]
    m.focus              = :main
    empty!(m.synth_tabs)
    m.synth_tab_idx      = 0
    m.mode = :normal
    _clear_completions!(m)
    empty!(m.history)
    empty!(m.redo_stack)
    _push_log!(m, "[INFO] closed synth pane, back to patterns")
end

"""
    _swap_focus!(m)

Swap the live (`m.buffer` / `m.cursor_*`) and stashed
(`m.synth_stash_*`) editing states so the user can move focus
between the patterns pane and the synth pane while both remain
on screen.
"""
function _swap_focus!(m::LiveModel)
    isempty(m.synth_editing) && return
    m.buffer,     m.synth_stash_buffer = m.synth_stash_buffer, m.buffer
    m.cursor_row, m.synth_stash_row    = m.synth_stash_row,    m.cursor_row
    m.cursor_col, m.synth_stash_col    = m.synth_stash_col,    m.cursor_col
    m.focus = m.focus === :main ? :synth : :main
    _clear_completions!(m)
end

"""
    _synth_buffer_view(m), _main_buffer_view(m)

Helpers that return the synth or main editing state regardless of
which side currently holds focus. Used by `_save_synth!` and the
rendering helpers so they don't have to branch on `m.focus`.
"""
function _synth_buffer_view(m::LiveModel)
    if m.focus === :synth
        return (m.buffer, m.cursor_row, m.cursor_col)
    end
    return (m.synth_stash_buffer, m.synth_stash_row, m.synth_stash_col)
end

function _main_buffer_view(m::LiveModel)
    if m.focus === :main
        return (m.buffer, m.cursor_row, m.cursor_col)
    end
    return (m.synth_stash_buffer, m.synth_stash_row, m.synth_stash_col)
end

"""
    _reload_synth!(m)

Ship the current buffer text to SuperCollider via /dirt/evalSC. The
SCD source is interpreted on the audio side (`source.interpret`),
which (re)installs the SynthDef. Don't persist — that's `:save-synth`.
"""
function _reload_synth!(m::LiveModel)
    if isempty(m.synth_editing)
        _push_log!(m, "[ERROR] :reload — not editing a synth")
        return
    end
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] :reload — no live session")
        return
    end
    synth_lines, _, _ = _synth_buffer_view(m)
    src = join(synth_lines, "\n")
    send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[src])))
    _push_log!(m, "[INFO] :reload sent $(length(src)) chars to SuperCollider — check audio logs if it errors")
end

"""
    _save_synth!(m)

Write the current buffer to plugins/user-synths/<name>.scd, append a
`[synths.<name>]` metadata entry if missing, register a SynthEntry in
memory, and reload it to SuperCollider.
"""
function _save_synth!(m::LiveModel)
    if isempty(m.synth_editing)
        _push_log!(m, "[ERROR] :save-synth — not editing a synth")
        return
    end
    name = m.synth_editing
    dir = joinpath(pwd(), _SYNTH_PLUGIN_DIR)
    isdir(dir) || mkpath(dir)
    scd_path = _synth_source_path(name)
    synth_lines, _, _ = _synth_buffer_view(m)
    try
        open(scd_path, "w") do io
            for line in synth_lines
                write(io, line, "\n")
            end
        end
    catch err
        _push_log!(m, "[ERROR] :save-synth — write failed: $(sprint(showerror, err))")
        return
    end
    _ensure_synth_plugin_manifest!(name)
    register_synth!(SynthEntry(Symbol(name), "user-synths", Dict{String,Any}(
        "description" => "live-edited synth",
        "tags" => ["user"],
    )))
    _reload_synth!(m)
    _push_log!(m, "[INFO] :save-synth → $scd_path + manifest + reloaded in audio")
end

_synth_source_path(name::AbstractString) =
    joinpath(pwd(), _SYNTH_PLUGIN_DIR, String(name) * ".scd")

"""
    _test_synth!(m)

`T` / `:test` — eval + fire the synth with its OWN defaults. This is
the same routing that pattern events use when targeting a
user-defined synth (`@d1 p"mywob"` with no extra params plays
EXACTLY what T plays). No SuperDirt auto-injection of freq/sustain/
gain — your defaults are the sound.

Server-side `s.sync` guarantees the SynthDef is registered before the
play fires.
"""
function _test_synth!(m::LiveModel)
    if isempty(m.synth_editing)
        _push_log!(m, "[ERROR] :test — not editing a synth")
        return
    end
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] :test — no live session")
        return
    end
    synth_lines, _, _ = _synth_buffer_view(m)
    src = join(synth_lines, "\n")
    send_osc(sched.osc,
             encode(OSCMessage("/ressac/evalAndPlay",
                                Any[String(m.synth_editing), src])))
    _push_log!(m, "[INFO] :test — $(m.synth_editing) (synth defaults active)")
end

"""
    _save_synth_as!(m, new_name)

Like `:save-synth`, but writes to `<new_name>.scd` and registers a
SynthDef of that new name. Lets the user fork a design under a
different name without losing the original. The buffer is rewritten
so the `SynthDef(\\old, …)` declaration becomes `SynthDef(\\new, …)`,
then everything proceeds as `:save-synth`.
"""
function _save_synth_as!(m::LiveModel, new_name::AbstractString)
    if isempty(m.synth_editing)
        _push_log!(m, "[ERROR] :save-synth-as — not editing a synth")
        return
    end
    old_name = m.synth_editing
    new_name = String(new_name)
    # Rewrite `SynthDef(\old_name` → `SynthDef(\new_name` line by line.
    # Use plain-string (not Regex) replace so backslash escapes don't
    # double-up — the regex/SubstitutionString machinery treats `\` in
    # the replacement as a capture reference and was outputting `\\`.
    synth_lines, _, _ = _synth_buffer_view(m)
    needle  = "SynthDef(\\$(old_name)"
    rebuild = "SynthDef(\\$(new_name)"
    rewritten = [replace(line, needle => rebuild) for line in synth_lines]
    # Write the rewritten source into the focused buffer + rename
    # m.synth_editing so :save-synth machinery targets the new name.
    if m.focus === :synth
        m.buffer = rewritten
    else
        m.synth_stash_buffer = rewritten
    end
    m.synth_editing = new_name
    _save_synth!(m)
end

"""
    _ensure_synth_plugin_manifest!(name)

Create or update plugins/user-synths/plugin.toml so SynthDef files in
this directory are loaded at next Ressac startup. Adds an entry for
`[synthdefs] files = […]` referencing every .scd in the dir, and a
`[synths.<name>]` metadata block for browser/autocomplete.
"""
function _ensure_synth_plugin_manifest!(name::AbstractString)
    dir = joinpath(pwd(), _SYNTH_PLUGIN_DIR)
    path = joinpath(dir, "plugin.toml")
    scd_files = ["./" * f for f in readdir(dir) if endswith(f, ".scd")]
    sort!(scd_files)
    header = """
    name        = "user-synths"
    version     = "0.1.0"
    description = "synthdefs authored live via :synth"

    [synthdefs]
    files = $(_toml_serialize(scd_files))
    """
    # Preserve any existing [synths.*] blocks; rewrite the header + synthdefs
    # block. Append a [synths.<name>] block if it isn't already there.
    body = isfile(path) ? read(path, String) : ""
    synth_blocks = _extract_synth_blocks(body)
    out = IOBuffer()
    write(out, header)
    for block in values(synth_blocks)
        write(out, "\n", block, "\n")
    end
    if !haskey(synth_blocks, name)
        write(out, """

        [synths.$name]
        description = "user synth"
        tags = ["user"]
        """)
    end
    write(path, take!(out))
end

function _extract_synth_blocks(toml_text::AbstractString)
    blocks = Dict{String,String}()
    for m in eachmatch(r"(?ms)^\[synths\.(\w+)\].*?(?=^\[|\z)", toml_text)
        name = m.captures[1]
        blocks[name] = strip(m.match)
    end
    return blocks
end
