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
    "// $(name).scd  —  press T to test, :reload to push, :save-synth to persist.",
    "//",
    "// PARAMS = OSC keys drivable from Ressac: `p\"$name\" |> set(:rate, 8)` etc.",
    "// DEFAULTS below ARE used by T (the test trigger sends only `s` + `cut`,",
    "// so changing `rate = 4` to `rate = 1` is audible). When you use the",
    "// synth from a pattern (`@d1 p\"$name\"`), SuperDirt overrides `freq`,",
    "// `gain`, `sustain` from cycle + n — patterns shape the music, defaults",
    "// shape the timbre.",
    "",
    "SynthDef(\\$(name), { |out, pan = 0, freq = 220, sustain = 1, gain = 0.5, accelerate = 0,",
    "                    attack = 0.01, release = 0.4,",
    "                    rate = 4, depth = 2000, centre = 800, q = 0.3, shape = 0|",
    "    var lfo, osc, filt, env, sig;",
    "    lfo  = SinOsc.kr(rate).range(centre - depth, centre + depth).max(40);",
    "    osc  = Saw.ar(freq * Line.kr(1, 1 + accelerate, sustain));",
    "    filt = RLPF.ar(osc, lfo, q);",
    "    filt = (filt * (1 + (shape * 5))).tanh;",
    "    env  = EnvGen.kr(Env.linen(attack, sustain, release), doneAction: 2);",
    "    sig  = filt * env * gain;",
    "    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));",
    "}).add;",
]

"""
    _enter_synth_edit!(m, name)

Stash the main buffer + cursor into `m.synth_stash_*` and load the
SynthDef source for `name` into `m.buffer`. Loads from disk if the
plugin file exists; otherwise inserts the starter template.
"""
function _enter_synth_edit!(m::LiveModel, name::AbstractString)
    if !isempty(m.synth_editing)
        _push_log!(m, "[INFO] already editing synth '$(m.synth_editing)'. :back first.")
        return
    end
    # Stash main state. After this swap:
    #   m.buffer / m.cursor_*       = synth source (focused)
    #   m.synth_stash_*              = main pattern state (unfocused)
    m.synth_stash_buffer = m.buffer
    m.synth_stash_row    = m.cursor_row
    m.synth_stash_col    = m.cursor_col
    m.synth_editing      = String(name)
    m.focus              = :synth
    # Load source.
    path = _synth_source_path(name)
    if isfile(path)
        text = read(path, String)
        lines = String.(split(text, '\n'; keepempty=true))
        while !isempty(lines) && isempty(lines[end])
            pop!(lines)
        end
        m.buffer = lines
        _push_log!(m, "[INFO] editing synth '$name' ($(length(lines)) lines) — :reload to push, :save-synth to persist, :back to return")
    else
        m.buffer = _STARTER_SYNTHDEF(name)
        _push_log!(m, "[INFO] new synth '$name' — template loaded, edit then :reload + :save-synth")
    end
    m.cursor_row = 1
    m.cursor_col = 1
    m.mode = :normal
    _clear_completions!(m)
    empty!(m.history)
    empty!(m.redo_stack)
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
        # m.buffer = synth source, m.synth_stash_* = main → swap back.
        m.buffer     = m.synth_stash_buffer
        m.cursor_row = m.synth_stash_row
        m.cursor_col = m.synth_stash_col
    end
    # If focus was :main, m.buffer already holds main → nothing to do.
    m.synth_editing      = ""
    m.synth_stash_buffer = String[]
    m.focus              = :main
    m.mode = :normal
    _clear_completions!(m)
    empty!(m.history)
    empty!(m.redo_stack)
    _push_log!(m, "[INFO] closed synth '$name', back to patterns")
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
    _test_synth!(m; n=nothing)

Reload the synth source to SuperCollider and fire one preview note.

CRITICAL: we send `s` + `cut` only — **no `n`, `freq`, `gain`,
`release`, `sustain`**. The reason: when those keys are present in
`/dirt/play`, SuperDirt passes its own computed values to the synth
(freq derived from n, sustain from cycle duration, gain as a global
multiplier), which **OVERRIDES** the user's `freq = 220` etc.
defaults in the SynthDef parameter list. The user edits the
template, presses T, and hears no difference because SuperDirt
forced the params back.

By passing only `s` + `cut`, the SynthDef's own defaults take effect,
so editing `rate = 4` → `rate = 1` or `freq = 110` → `freq = 220`
actually changes the audio.

If the user wants to test with a specific note (because their synth
uses `freq` from SuperDirt), `:test -12` re-introduces `n` so
SuperDirt computes freq. That's the explicit opt-in.

Cut group is shared with K/browser previews so consecutive presses
truncate the previous voice — no overlapping reverb tails.
"""
function _test_synth!(m::LiveModel; n::Union{Int,Nothing} = nothing)
    if isempty(m.synth_editing)
        _push_log!(m, "[ERROR] :test — not editing a synth")
        return
    end
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] :test — no live session")
        return
    end
    # Step 1: ship the latest source. Immediate.
    _reload_synth!(m)
    # Step 2: trigger the synth directly via our custom /ressac/testSynth
    # OSCdef. Bypasses SuperDirt entirely so the SynthDef's own param
    # defaults (freq/gain/sustain/release/etc.) are what actually play.
    # Scheduled +200 ms via OSC bundle so the new SynthDef is fully
    # registered in scsynth before the play executes.
    fire_time = time() + 0.2
    bundle = OSCBundle(fire_time,
        [OSCMessage("/ressac/testSynth", Any[String(m.synth_editing)])])
    send_osc(sched.osc, encode(bundle))
    _push_log!(m, "[INFO] :test — $(m.synth_editing) via /ressac/testSynth (synth defaults are active; relaunch `just audio` if you see no sound, that ships the new OSCdef)")
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
