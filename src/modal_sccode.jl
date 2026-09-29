# sccode.org browser modal — UI half of the sccode integration.
# The networking + parsing half lives in src/content_sccode.jl (struct
# _SccodeEntry, _sccode_fetch_list, _sccode_fetch_source,
# _sccode_extract_synthdef_name). This file owns:
#
#   _open_sccode!                 entry point (`:sccode`, `:sc`)
#   _direct_load_sccode!          single-shot import from id/URL
#   _sccode_import!               shared fetch→write→register helper
#   _sccode_filtered              search filter
#   _handle_sccode_key!           j/k/n/p/Space/Enter/q/'/' dispatch
#   _sccode_paginate!             ←/→ page navigation
#   _preview_sccode!              one-shot play through SC
#   _load_sccode!                 ↵ import the cursor entry
#   _render_sccode_modal!         the modal renderer
#
# Extracted from app.jl as part of the maintainability sprint
# (Sprint 3.4). The model fields it touches (sccode_*) live on
# RessacApp in app.jl.

"""
    _open_sccode!(m)

Open the sccode browser modal and synchronously fetch the first page
of entries. Sccode loads in 1-2s typically; if the user wants more
they hit `n`/`p` to paginate.
"""
function _open_sccode!(m::RessacApp; tag::AbstractString = "")
    _open_modal!(m, :sccode)
    _picker_reset!(m.sccode); _picker_search!(m.sccode, false)
    m.sccode_page = 1
    m.sccode_loading = true
    m.sccode_tag = String(tag)
    banner = isempty(tag) ? "page 1" : "tag=$(tag), page 1"
    _push_app_log!(m, "[INFO] sccode : chargement $(banner)…")
    try
        m.sccode_entries = _sccode_fetch_list(1; tag = m.sccode_tag)
        m.sccode_loading = false
        _push_app_log!(m, "[INFO] sccode : $(length(m.sccode_entries)) entrées chargées")
    catch err
        m.sccode_loading = false
        m.sccode_entries = _SccodeEntry[]
        _push_app_log!(m, "[ERROR] sccode liste : $(sprint(showerror, err))")
    end
end

"""
    _sccode_import!(m, id; title="") -> Union{Nothing, String}

Single source of truth for "fetch sccode/<id>, write a unique .scd
under `plugins/user-synths/`, register it, open it in a tab". Used
by `:sccode <id|url>`, by Enter on a row in the picker modal, and by
`_direct_load_sccode!` for URL-paste flows.

Returns the final filename (suffixed `-2`, `-3`, … if needed to
avoid clobbering an existing file), or `nothing` on failure.
"""
function _sccode_import!(m::RessacApp, id::AbstractString; title::AbstractString = "")
    id = String(id)
    src = try
        _sccode_fetch_source(id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(id): $(sprint(showerror, err))")
        return nothing
    end
    base = _sccode_extract_synthdef_name(src)
    base === nothing && (base = "sccode_" * replace(id, "-" => "_"))
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    final_name = base
    target = joinpath(dir, "$(final_name).scd")
    n = 1
    while isfile(target)
        n += 1
        final_name = "$base-$n"
        target = joinpath(dir, "$(final_name).scd")
    end
    header = isempty(title) ?
        "// Imported from sccode.org/$(id)\n//\n" :
        "// Imported from sccode.org/$(id) — \"$(title)\"\n//\n"
    write(target, header * src)
    register_synth!(SynthEntry(Symbol(final_name), "user-synths",
                               Dict{String,Any}("description" => "imported from sccode",
                                                "tags" => ["sccode"])))
    _open_synth_tab!(m, final_name)
    _push_app_log!(m, "[INFO] sccode/$(id) → plugins/user-synths/$(final_name).scd")
    return final_name
end

"""
    _direct_load_sccode!(m, ref)

`ref` is either a bare id ("1-5iP") or a full sccode.org URL. Thin
wrapper around `_sccode_import!` that strips a leading URL prefix.
"""
function _direct_load_sccode!(m::RessacApp, ref::AbstractString)
    id = ref
    mt = match(r"sccode\.org/([0-9][\w-]*)", String(ref))
    mt !== nothing && (id = String(mt.captures[1]))
    _sccode_import!(m, id)
end

"""
    _sccode_filtered(m) -> Vector{_SccodeEntry}

Apply the live query filter against title + id (case-insensitive
substring). When the query is empty just returns the raw list.
"""
function _sccode_filtered(m::RessacApp)
    q = lowercase(_picker_query(m.sccode))
    isempty(q) && return m.sccode_entries
    return [e for e in m.sccode_entries
            if occursin(q, lowercase(e.title)) || occursin(q, lowercase(e.id))]
end

# Pose les entrées filtrées dans le picker, formatées pour `width` colonnes.
function _sccode_sync!(m::RessacApp, width::Int = 80)
    filtered = _sccode_filtered(m)
    _picker_set!(m.sccode, [TK.ListItem(first("#$(rpad(e.id, 8)) $(e.title)", width)) for e in filtered], filtered)
    return filtered
end

_sccode_cur(m::RessacApp) = (_sccode_sync!(m); _picker_selected(m.sccode))

function _handle_sccode_key!(m::RessacApp, evt::TK.KeyEvent)
    pk = m.sccode
    # Mode recherche : Échap / Entrée en sortent (le filtre reste).
    if pk.searching
        (evt.key === :escape || evt.key === :enter) && (_picker_search!(pk, false); return)
        _picker_type!(pk, evt) && return
        return
    end
    # Échap pèle : le filtre d'abord, puis la modale.
    if evt.key === :escape || evt.char == 'q'
        isempty(_picker_query(pk)) ? (m.modal = :none) : _picker_clear!(pk)
        return
    end
    dispatch!(((:modal_sccode, m),), evt)
    return
end

# Les actions passent par la liste filtrée : ce que l'utilisateur voit.
_preview_sccode_filtered!(m::RessacApp) = _sccode_act!(m, _preview_sccode_by_entry!)
_load_sccode_filtered!(m::RessacApp)    = _sccode_act!(m, _load_sccode_by_entry!)

function _sccode_act!(m::RessacApp, f)
    e = _sccode_cur(m)
    e === nothing || f(m, e)
end

function _preview_sccode_by_entry!(m::RessacApp, entry::_SccodeEntry)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    src = try
        _sccode_fetch_source(entry.id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(entry.id): $(sprint(showerror, err))")
        return
    end
    name = _sccode_extract_synthdef_name(src)
    if name === nothing
        _push_app_log!(m, "[WARN] sccode $(entry.id) : pas de SynthDef, éval brute")
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[entry.id, src])))
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[name, src])))
    _push_app_log!(m, "[INFO] écoute sccode/$(entry.id) → $(name)")
end

function _load_sccode_by_entry!(m::RessacApp, entry::_SccodeEntry)
    _sccode_import!(m, entry.id; title = entry.title) === nothing && return
    m.modal = :none
end

function _sccode_paginate!(m::RessacApp, delta::Int)
    new_page = max(1, m.sccode_page + delta)
    new_page == m.sccode_page && return
    m.sccode_loading = true
    try
        m.sccode_entries = _sccode_fetch_list(new_page; tag = m.sccode_tag)
        m.sccode_page = new_page
        m.sccode.list.selected = 1; m.sccode.list.offset = 0
        _push_app_log!(m, "[INFO] sccode page $new_page — $(length(m.sccode_entries)) entrées")
    catch err
        _push_app_log!(m, "[ERROR] sccode page $new_page: $(sprint(showerror, err))")
    finally
        m.sccode_loading = false
    end
end

# L'entrée sélectionnée (dans la liste filtrée) : écoute, ou charge dans une pane.
_preview_sccode!(m::RessacApp) = _sccode_act!(m, _preview_sccode_by_entry!)
_load_sccode!(m::RessacApp)    = _sccode_act!(m, _load_sccode_by_entry!)

function _render_sccode_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    inner = _render_modal_block!(buf, area;
        title = "SCCODE.ORG",
        title_right = _modal_hint_text(m, :modal_sccode),
        w_max = 120,
        h_target = max(10, area.height - 4))
    inner.width < 20 && return
    if m.sccode_loading
        TK.set_string!(buf, inner.x + 1, inner.y, "fetching…", TK.tstyle(:warning))
        return
    end
    # Saisie (ligne 1), liste (2..fin-1), pied (dernière ligne).
    filtered = _sccode_sync!(m, inner.width - 3)
    n = length(filtered)
    _picker_render_input!(m.sccode, TK.Rect(inner.x, inner.y, inner.width, 1), buf;
                          hint = "/ pour chercher · n / p changent de page · Espace écoute · Entrée charge")
    body_h = inner.height - 2
    if n == 0
        q = _picker_query(m.sccode)
        msg = isempty(q) ? "(aucune entrée — n pour la page suivante)" : "(rien pour « $q »)"
        TK.set_string!(buf, inner.x + 1, inner.y + 1, msg, TK.tstyle(:text_dim))
    else
        _picker_render_list!(m.sccode, TK.Rect(inner.x, inner.y + 1, inner.width, body_h), buf)
    end
    # Page indicator (last row).
    pageinfo = "page $(m.sccode_page) · $(n) shown of $(length(m.sccode_entries))"
    isempty(m.sccode_tag) || (pageinfo *= " · tag=$(m.sccode_tag)")
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(rpad(pageinfo, inner.width), inner.width),
                   TK.tstyle(:text_dim))
end

# ── Registre de touches (déclaré en fin de fichier : les actions nommées
#    doivent exister au moment du bind!) ──
scope!(:modal_sccode, "sccode.org")
bind!(:modal_sccode, "Enter", "charger dans une pane synth"; short = "charger", group = :file, action = _load_sccode_filtered!)
bind!(:modal_sccode, "Space", "aperçu"; group = :view, action = _preview_sccode_filtered!)
bind!(:modal_sccode, ["n", "p"], "page suivante / précédente"; group = :nav,
      action = (m, evt) -> _sccode_paginate!(m, evt.char == 'n' ? +1 : -1))
bind!(:modal_sccode, "/", "rechercher"; group = :edit, action = m -> _picker_search!(m.sccode, true))
bind!(:modal_sccode, ["j", "↓"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (_sccode_sync!(m); _picker_nav!(m.sccode, :down)))
bind!(:modal_sccode, ["k", "↑"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (_sccode_sync!(m); _picker_nav!(m.sccode, :up)))
bind!(:modal_sccode, ["PgDn", "Ctrl-d"], "page d'écran suivante"; group = :nav, hint = false, repeat = true,
      action = m -> (_sccode_sync!(m); _picker_nav!(m.sccode, :pagedown)))
bind!(:modal_sccode, ["PgUp", "Ctrl-u"], "page d'écran précédente"; group = :nav, hint = false, repeat = true,
      action = m -> (_sccode_sync!(m); _picker_nav!(m.sccode, :pageup)))
_bind_modal_common!(:modal_sccode; nav = false)
