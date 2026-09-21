# Synth library picker — preview + instantiate from the built-in
# library (src/synth_library.jl) and any user-saved synths in
# plugins/user-synths/. Extracted from app.jl.

function _open_synth_library!(m::RessacApp)
    _open_modal!(m, :synth_library, :synthlib_cursor)
end

"""
    _synthlib_all_entries() -> Vector{_SynthLibEntry}

Built-in starter pack + every `plugins/user-synths/*.scd` the user has
saved, exposed as the same `_SynthLibEntry` shape. User entries get
category "user" and an excerpt of their first comment line as the
description, so the modal renders them alongside the built-ins.
"""
function _synthlib_all_entries()
    entries = copy(_SYNTH_LIBRARY)
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || return entries
    for f in sort!(readdir(dir))
        name, ext = splitext(f)
        mode = ext == ".jl"  ? :dsl :
               ext == ".scd" ? :sc  : continue
        # Don't double-list a user file that shadows a built-in name —
        # the user's edits are what they want to revisit.
        existing = findfirst(e -> e.name == String(name), entries)
        path = joinpath(dir, f)
        src = try read(path, String) catch; "" end
        desc = _first_comment_line(src)
        new_entry = _SynthLibEntry(String(name), "user", desc, src, mode)
        if existing !== nothing
            entries[existing] = new_entry
        else
            push!(entries, new_entry)
        end
    end
    return entries
end

function _first_comment_line(src::AbstractString)
    # Recognise both Julia-style `#` (DSL files) and SC-style `//`
    # so user-saved entries either way get a sensible description.
    for line in split(src, '\n'; limit=20)
        s = strip(line)
        (startswith(s, "//") || startswith(s, "#")) || continue
        body = strip(replace(String(s), r"^(//+|#+)\s*" => ""))
        isempty(body) && continue
        return first(body, 60)
    end
    return "user synth"
end

function _handle_synthlib_key!(m::RessacApp, evt::TK.KeyEvent)
    n = length(_synthlib_all_entries())
    _modal_close_key!(m, evt)        && return
    _modal_cursor_nav!(m, evt, :synthlib_cursor, n) && return
    dispatch!(((:modal_lib, m),), evt)
    return
end

"""
    _preview_synth_from_library!(m)

Fire the synth at the cursor with its own defaults — same OSC path
T uses for the editor's T-test (`/ressac/evalAndPlay`: SC interprets
the source, syncs, then `Synth(name, [\\out, 0])`). Lets the user
audition library entries before deciding to instantiate one.
"""
function _preview_synth_from_library!(m::RessacApp)
    entries = _synthlib_all_entries()
    1 <= m.synthlib_cursor <= length(entries) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    entry = entries[m.synthlib_cursor]
    if entry.mode === :dsl
        try
            # Evaluate in SynthDSL scope so the UGen wrappers (saw,
            # sin_osc, rlpf, …) resolve. Evaluating in Main produces
            # `saw not defined in Main` for any unqualified usage.
            Core.eval(SynthDSL, Meta.parse(SynthDSL._dsl_preprocess(entry.source)))
            _push_app_log!(m, "[INFO] écoute de $(entry.name) (DSL)")
        catch err
            _push_app_log!(m, "[ERROR] écoute DSL : $(sprint(showerror, err))")
        end
    else
        send_osc(sched.osc,
                 encode(OSCMessage("/ressac/evalAndPlay",
                                    Any[entry.name, entry.source])))
        _push_app_log!(m, "[INFO] écoute de $(entry.name) (SC)")
    end
end

"""
    _instantiate_synth_from_library!(m)

Selected library entry → write the source to plugins/user-synths/
<name>.scd (renaming if the file already exists so we don't clobber the
user's edits) and open it as a new synth tab. The user can iterate on
the copy without affecting the canonical template.
"""
function _instantiate_synth_from_library!(m::RessacApp)
    entries = _synthlib_all_entries()
    1 <= m.synthlib_cursor <= length(entries) || return
    m.modal = :none
    _instantiate_synth_entry!(m, entries[m.synthlib_cursor])
end

"""
    _instantiate_synth_entry!(m, entry)

Ouvre une entrée de librairie : un synth utilisateur s'ouvre tel quel ;
une recette intégrée est COPIÉE dans plugins/user-synths (nom
désambiguïsé si le fichier existe) puis ouverte — :w y écrit ensuite.
Partagé par le modal :lib et par `:synth <nom>` / `gs`.
"""
function _instantiate_synth_entry!(m::RessacApp, entry::_SynthLibEntry)
    # User-saved synths: don't deep-copy, just open the existing file.
    if entry.category == "user"
        _open_synth_tab!(m, entry.name)
        return
    end
    name = entry.name
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    # Disambiguate the destination filename (with the mode's extension)
    # so an existing edit isn't clobbered.
    ext = entry.mode === :dsl ? ".jl" : ".scd"
    target = joinpath(dir, "$name$ext")
    n = 1
    while isfile(target)
        n += 1
        target = joinpath(dir, "$name-$n$ext")
    end
    final_name = n == 1 ? name : "$name-$n"
    # Rewrite the in-source name to match the final filename. DSL uses
    # `@synth :name`, SC uses `SynthDef(\name`.
    src = if entry.mode === :dsl
        _align_dsl_synth_name(entry.source, final_name)
    else
        replace(entry.source, "SynthDef(\\$(entry.name)" => "SynthDef(\\$(final_name)")
    end
    write(target, src)
    _open_synth_tab!(m, final_name)
    _push_app_log!(m, "[INFO] librairie : $final_name créé depuis « $(entry.name) » [$( entry.mode )]")
end

function _render_synth_library_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    entries = _synthlib_all_entries()
    n = length(entries)
    inner = _render_modal_block!(buf, area;
        title = "LIBRAIRIE DE SYNTHS",
        title_right = "$n synths · " * _modal_hint_text(m, :modal_lib),
        w_max = 100,
        h_target = max(10, min(area.height - 4, n + 4)))
    inner.width < 20 && return
    empty!(m.modal_rows)
    body_h = inner.height
    # Auto-scroll so the cursor follows j/k past the viewport.
    m.modal_scroll = _scroll_to_show(m.synthlib_cursor, n, body_h, m.modal_scroll)
    first_idx = m.modal_scroll + 1
    last_idx  = min(n, m.modal_scroll + body_h)
    for (slot, i) in enumerate(first_idx:last_idx)
        entry = entries[i]
        is_cur = i == m.synthlib_cursor
        marker = is_cur ? "▶ " : "  "
        tag = entry.category == "user" ? "[user]  ★" : "[$(rpad(entry.category, 5))]"
        text = "$marker$(rpad(entry.name, 14)) $tag  $(entry.description)"
        base_style = entry.category == "user" ?
            TK.tstyle(:success) : TK.tstyle(:text)
        style = is_cur ? TK.tstyle(:accent, bold = true) : base_style
        screen_y = inner.y + slot - 1
        TK.set_string!(buf, inner.x, screen_y,
                       first(rpad(text, inner.width), inner.width), style)
        push!(m.modal_rows, (screen_y, i))
    end
end

# ── Registre de touches (déclaré en fin de fichier : les actions nommées
#    doivent exister au moment du bind!) ──
scope!(:modal_lib, "Librairie de synths")
bind!(:modal_lib, "Space", "écouter"; group = :audio, action = _preview_synth_from_library!)
bind!(:modal_lib, "Enter", "ouvrir dans une pane synth"; short = "ouvrir", group = :file,
      action = _instantiate_synth_from_library!)
_bind_modal_common!(:modal_lib)
