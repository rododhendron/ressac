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
# The model fields it touches (sccode_*) live on RessacApp
# (app_model.jl). Network calls run in the background (app_jobs.jl).

"""
    _open_sccode!(m; tag = "")

Ouvre le navigateur sccode et lance le chargement de la première page — en
fond : la modale s'affiche tout de suite (« chargement… »), l'app reste
jouable, la liste arrive quand sccode.org répond. `n` / `p` paginent.
"""
function _open_sccode!(m::RessacApp; tag::AbstractString = "")
    _open_modal!(m, :sccode)
    _picker_reset!(m.sccode); _picker_search!(m.sccode, false)
    m.sccode_tag = String(tag)
    m.sccode_entries = _SccodeEntry[]
    _sccode_load_page!(m, 1)
end

# Charge la page `page` de la liste. La réponse n'est appliquée que si elle
# est encore celle qu'on attend (le joueur a pu changer de page, de tag, ou
# fermer la modale entre-temps).
function _sccode_load_page!(m::RessacApp, page::Int)
    tag = m.sccode_tag
    m.sccode_loading = true
    m.sccode_wanted = (page, tag)
    _push_app_log!(m, "[INFO] sccode : chargement $(isempty(tag) ? "" : "tag=$(tag), ")page $(page)…")
    _background!(() -> _sccode_fetch_list(page; tag = tag)) do entries, err
        m.sccode_wanted == (page, tag) || return          # une demande plus récente est en route
        m.sccode_loading = false
        if err !== nothing
            _push_app_log!(m, "[ERROR] sccode page $page : $(sprint(showerror, err))")
            return
        end
        m.sccode_entries = entries
        m.sccode_page = page
        m.sccode.list.selected = 1; m.sccode.list.offset = 0
        _push_app_log!(m, "[INFO] sccode page $page — $(length(entries)) entrées")
    end
    return
end

"""
    _sccode_import!(m, id; title = "", then = nothing)

Single source of truth for "fetch sccode/<id>, convert its SynthDef to DSL,
write a unique .jl under `plugins/user-synths/`, register it, open it". Used
by `:sccode <id|url>`, by Enter on a row in the picker modal, and by
`_direct_load_sccode!` for URL-paste flows.

Le téléchargement se fait en fond ; quand la source est là, le fichier est
écrit (suffixé `-2`, `-3`… pour ne rien écraser), le synth enregistré et
ouvert, puis `then(nom)` est appelé s'il est donné. En cas d'échec le
journal le dit et `then` ne l'est pas.
"""
function _sccode_import!(m::RessacApp, id::AbstractString; title::AbstractString = "", then = nothing)
    id = String(id)
    _push_app_log!(m, "[INFO] sccode/$(id) : téléchargement…")
    _background!(() -> _sccode_fetch_source(id)) do src, err
        if err !== nothing
            _push_app_log!(m, "[ERROR] sccode fetch $(id): $(sprint(showerror, err))")
            return
        end
        # Tout son s'édite en DSL : le SynthDef est converti à l'arrivée, ou
        # refusé avec ce qui a manqué — jamais rangé à moitié lu.
        if !_is_raw_synthdef(src)
            _push_app_log!(m, "[ERROR] sccode/$(id) : pas de SynthDef dans ce code (un Pbind, un Ndef… ne s'importent pas)")
            return
        end
        # Un nom de synth est un identifiant : un SynthDef nommé autrement
        # prend un nom dérivé de l'id, avant la conversion.
        base = _sccode_extract_synthdef_name(src)
        if base === nothing || !SynthDSL.valid_synth_name(base)
            base = "sccode_" * replace(id, r"[^A-Za-z0-9_]" => "_")
            src = replace(src, r"SynthDef\s*\(\s*\\\w+" => SubstitutionString("SynthDef(\\\\" * base); count = 1)
        end
        (dsl, why) = as_dsl(src)
        if dsl === nothing
            _push_app_log!(m, "[ERROR] sccode/$(id) ne se convertit pas en DSL : $why")
            return
        end
        dir = joinpath(_project_dir(), "plugins", "user-synths")
        isdir(dir) || mkpath(dir)
        final_name = base
        target = joinpath(dir, "$(final_name).jl")
        n = 1
        while isfile(target)
            n += 1
            final_name = "$(base)_$n"                  # un nom de synth reste un identifiant
            target = joinpath(dir, "$(final_name).jl")
        end
        header = isempty(title) ?
            "# importé de sccode.org/$(id), converti en DSL\n\n" :
            "# importé de sccode.org/$(id) — « $(title) », converti en DSL\n\n"
        text = header * _align_dsl_synth_name(dsl, final_name)
        write(target, text)
        register_synth!(SynthEntry(Symbol(final_name), "user-synths",
                                   Dict{String,Any}("description" => "importé de sccode",
                                                    "tags" => ["sccode"],
                                                    "params" => _dsl_params_from_text(text))); update = true)
        _open_sound!(m, final_name)
        _push_app_log!(m, "[INFO] sccode/$(id) → plugins/user-synths/$(final_name).jl")
        then === nothing || then(final_name)
    end
    return
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
    _background!(() -> _sccode_fetch_source(entry.id)) do src, err
        if err !== nothing
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
    return
end

# Entrée sur une ligne : importe, et ferme la modale une fois le synth ouvert.
_load_sccode_by_entry!(m::RessacApp, entry::_SccodeEntry) =
    _sccode_import!(m, entry.id; title = entry.title, then = _ -> (m.modal === :sccode && (m.modal = :none)))

function _sccode_paginate!(m::RessacApp, delta::Int)
    new_page = max(1, m.sccode_page + delta)
    new_page == m.sccode_page && return
    _sccode_load_page!(m, new_page)
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
scope!(:modal_sccode, "sccode.org"; layer = :modal, modes = (:design,))
bind!(:modal_sccode, "Enter", "charger dans une pane synth"; short = "charger", group = :file, action = _load_sccode_filtered!)
bind!(:modal_sccode, "Space", "aperçu"; group = :view, action = _preview_sccode_filtered!)
bind!(:modal_sccode, ["n", "p"], "page suivante / précédente"; group = :nav,
      action = (m, evt) -> _sccode_paginate!(m, evt.char == 'n' ? +1 : -1))
bind!(:modal_sccode, "/", "rechercher"; group = :edit, action = m -> _picker_search!(m.sccode, true))
mixin_list_nav!(:modal_sccode, (m, key) -> _picker_nav!(m.sccode, key); before = _sccode_sync!)
_bind_modal_common!(:modal_sccode; nav = false)
