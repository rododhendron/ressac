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
    _open_modal!(m, :sccode, :sccode_cursor)
    m.sccode_page = 1
    m.sccode_loading = true
    m.sccode_query = ""
    m.sccode_search_mode = false
    m.sccode_tag = String(tag)
    banner = isempty(tag) ? "page 1" : "tag=$(tag), page 1"
    _push_app_log!(m, "[INFO] sccode: fetching $(banner)…")
    try
        m.sccode_entries = _sccode_fetch_list(1; tag = m.sccode_tag)
        m.sccode_loading = false
        _push_app_log!(m, "[INFO] sccode: $(length(m.sccode_entries)) entries loaded")
    catch err
        m.sccode_loading = false
        m.sccode_entries = _SccodeEntry[]
        _push_app_log!(m, "[ERROR] sccode list: $(sprint(showerror, err))")
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
    isempty(m.sccode_query) && return m.sccode_entries
    q = lowercase(m.sccode_query)
    return [e for e in m.sccode_entries
            if occursin(q, lowercase(e.title)) || occursin(q, lowercase(e.id))]
end

function _handle_sccode_key!(m::RessacApp, evt::TK.KeyEvent)
    # Search mode: chars append, backspace pops, Esc/Enter exit (keep query).
    if m.sccode_search_mode
        if evt.key === :escape
            m.sccode_search_mode = false
        elseif evt.key === :enter
            m.sccode_search_mode = false
        elseif evt.key === :backspace
            isempty(m.sccode_query) || (m.sccode_query = m.sccode_query[1:end-1])
            m.sccode_cursor = 1
        elseif evt.key === :char && isprint(evt.char)
            m.sccode_query *= string(evt.char)
            m.sccode_cursor = 1
        end
        return
    end
    n = length(_sccode_filtered(m))
    # Query-aware Esc — see modal_snippets for the same pattern.
    if evt.key === :escape || evt.char == 'q'
        if !isempty(m.sccode_query)
            m.sccode_query = ""
            m.sccode_cursor = 1
        else
            m.modal = :none
        end
        return
    end
    _modal_cursor_nav!(m, evt, :sccode_cursor, n) && return
    if evt.char == '/'
        m.sccode_search_mode = true
    elseif evt.char == 'n'
        _sccode_paginate!(m, +1)
    elseif evt.char == 'p'
        _sccode_paginate!(m, -1)
    elseif evt.char == ' '
        _preview_sccode_filtered!(m)
    elseif evt.key === :enter || evt.char == '\r'
        _load_sccode_filtered!(m)
    end
end

# Wrappers that route through the filtered list so cursor indexing
# matches what the user sees in the modal.
_preview_sccode_filtered!(m::RessacApp) = _sccode_act!(m, _preview_sccode_by_entry!)
_load_sccode_filtered!(m::RessacApp)    = _sccode_act!(m, _load_sccode_by_entry!)

function _sccode_act!(m::RessacApp, f)
    filtered = _sccode_filtered(m)
    1 <= m.sccode_cursor <= length(filtered) || return
    f(m, filtered[m.sccode_cursor])
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
        _push_app_log!(m, "[WARN] sccode $(entry.id): no SynthDef, raw eval")
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[entry.id, src])))
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[name, src])))
    _push_app_log!(m, "[INFO] preview sccode/$(entry.id) → $(name)")
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
        m.sccode_cursor = 1
        _push_app_log!(m, "[INFO] sccode page $new_page — $(length(m.sccode_entries)) entries")
    catch err
        _push_app_log!(m, "[ERROR] sccode page $new_page: $(sprint(showerror, err))")
    finally
        m.sccode_loading = false
    end
end

"""
    _preview_sccode!(m)

Fetch the SC source for the cursor entry (cached after first hit) and
fire it via `/ressac/evalAndPlay`. If the snippet isn't a SynthDef
(no `\\name` decl), we still send it but log a warning — many sccode
snippets are full apps, not SynthDefs, and won't play meaningfully.
"""
function _preview_sccode!(m::RessacApp)
    1 <= m.sccode_cursor <= length(m.sccode_entries) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    entry = m.sccode_entries[m.sccode_cursor]
    src = try
        _sccode_fetch_source(entry.id)
    catch err
        _push_app_log!(m, "[ERROR] sccode fetch $(entry.id): $(sprint(showerror, err))")
        return
    end
    name = _sccode_extract_synthdef_name(src)
    if name === nothing
        _push_app_log!(m, "[WARN] sccode $(entry.id): no SynthDef found, sending raw eval anyway")
        send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[entry.id, src])))
        return
    end
    send_osc(sched.osc, encode(OSCMessage("/ressac/evalAndPlay", Any[name, src])))
    _push_app_log!(m, "[INFO] preview sccode/$(entry.id) → $(name)")
end

"""
    _load_sccode!(m)

Save the cursor entry into plugins/user-synths/<name>.scd (suffix
-2/-3/... to avoid clobber) and open it in a new tab. If no SynthDef
name can be extracted, falls back to the snippet id.
"""
function _load_sccode!(m::RessacApp)
    1 <= m.sccode_cursor <= length(m.sccode_entries) || return
    _load_sccode_by_entry!(m, m.sccode_entries[m.sccode_cursor])
end

function _render_sccode_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    inner = _render_modal_block!(buf, area;
        title = "SCCODE.ORG",
        title_right = "/ search · j/k · Space play · Enter import · n/p page · q close",
        w_max = 120,
        h_target = max(10, area.height - 4))
    inner.width < 20 && return
    if m.sccode_loading
        TK.set_string!(buf, inner.x + 1, inner.y, "fetching…", TK.tstyle(:warning))
        return
    end
    # Search bar (row 1).
    sb_prefix = m.sccode_search_mode ? "/" : "⌕ "
    sb_text = sb_prefix * m.sccode_query * (m.sccode_search_mode ? "▏" : "")
    sb_style = m.sccode_search_mode ?
        TK.tstyle(:accent, bold = true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, inner.x, inner.y,
                   first(rpad(sb_text, inner.width), inner.width), sb_style)
    # List rows 2..(end-1); footer on last row.
    filtered = _sccode_filtered(m)
    body_h = inner.height - 2
    n = length(filtered)
    if n == 0
        msg = isempty(m.sccode_query) ?
            "(no entries — try `n` for next page)" :
            "(no match for \"$(m.sccode_query)\")"
        TK.set_string!(buf, inner.x + 1, inner.y + 1, msg, TK.tstyle(:text_dim))
    else
        start_i = max(1, m.sccode_cursor - body_h ÷ 2)
        end_i = min(n, start_i + body_h - 1)
        start_i = max(1, end_i - body_h + 1)
        empty!(m.modal_rows)
        for (slot, i) in enumerate(start_i:end_i)
            e = filtered[i]
            is_cur = i == m.sccode_cursor
            marker = is_cur ? "▶ " : "  "
            label = "$(marker)#$(rpad(e.id, 8)) $(e.title)"
            style = is_cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
            screen_y = inner.y + slot
            TK.set_string!(buf, inner.x, screen_y,
                           first(rpad(label, inner.width), inner.width), style)
            push!(m.modal_rows, (screen_y, i))
        end
    end
    # Page indicator (last row).
    pageinfo = "page $(m.sccode_page) · $(n) shown of $(length(m.sccode_entries))"
    isempty(m.sccode_tag) || (pageinfo *= " · tag=$(m.sccode_tag)")
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(rpad(pageinfo, inner.width), inner.width),
                   TK.tstyle(:text_dim))
end
