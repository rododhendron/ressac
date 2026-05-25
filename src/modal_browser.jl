# Browser modal — unified picker over registered samples,
# instruments and synths. Owns the open/handle/preview/insert/render
# path AND the shared types/helpers (`_BrowserEntry`, the three
# `_*_summary` rendering helpers, and the `_PREVIEW_CUT_GROUP`
# constant — moved here from the deleted tui_browser.jl).

"""
    _BrowserEntry(kind, name, plugin, summary)

Unified picker row. Carries enough metadata to render a one-line
summary and dispatch a preview without re-querying the registry.
"""
struct _BrowserEntry
    kind::Symbol      # :instrument | :sample | :synth
    name::Symbol
    plugin::String
    summary::String
end

# Preview-fire cut group: any sound previewed via `K` / Space uses
# this group so that consecutive previews truncate each other —
# you don't get a wash of overlapping samples when scanning the list
# quickly. SuperDirt voices sharing a positive `cut` int are
# mutually exclusive.
const _PREVIEW_CUT_GROUP = 9999

function _instrument_summary(e::InstrumentEntry)
    s_target = ""
    parts = String[]
    for (k, v) in e.params
        if k == "s"
            s_target = String(v)
        else
            push!(parts, "$k=$v")
        end
    end
    desc = get(e.metadata, "description", "")
    tail = isempty(desc) ? "" : "  — $desc"
    head = isempty(s_target) ? "" : "$(s_target)  "
    return head * join(parts, ", ") * tail
end

function _sample_summary(e::SampleEntry)
    nv = length(e.variants)
    tags = get(e.metadata, "tags", String[])
    tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
    bpm = get(e.metadata, "bpm", nothing)
    bpm_str = bpm === nothing ? "" : "  $(bpm) BPM"
    return "$(nv)v$tag_str$bpm_str"
end

function _synth_summary(e::SynthEntry)
    tags = get(e.metadata, "tags", String[])
    tag_str = isempty(tags) ? "" : "[" * join(tags, ", ") * "]"
    desc = get(e.metadata, "description", "")
    parts = String[]
    isempty(tag_str) || push!(parts, tag_str)
    isempty(desc) || push!(parts, desc)
    return join(parts, "  ")
end

function _open_browser!(m::RessacApp)
    m.modal = :browse
    m.browser_query = ""
    m.browser_cursor = 1
    m.browser_filter = :all
    m.modal_scroll = 0
end

function _browser_entries(m::RessacApp)
    out = _BrowserEntry[]
    if m.browser_filter === :all || m.browser_filter === :instruments
        for e in values(_INSTRUMENT_REGISTRY)
            push!(out, _BrowserEntry(:instrument, e.name, e.plugin, _instrument_summary(e)))
        end
    end
    if m.browser_filter === :all || m.browser_filter === :samples
        for e in values(_SAMPLE_REGISTRY)
            push!(out, _BrowserEntry(:sample, e.name, e.plugin, _sample_summary(e)))
        end
    end
    if m.browser_filter === :all || m.browser_filter === :synths
        for e in values(_SYNTH_REGISTRY)
            push!(out, _BrowserEntry(:synth, e.name, e.plugin, _synth_summary(e)))
        end
    end
    isempty(m.browser_query) || (out = filter(e -> _fuzzy_score(m.browser_query, String(e.name)) !== nothing, out))
    sort!(out; by = e -> (String(e.kind), String(e.name)))
    return out
end

function _handle_browser_key!(m::RessacApp, evt::TK.KeyEvent)
    entries = _browser_entries(m)
    n = length(entries)
    if evt.key === :escape || (evt.char == 'q' && isempty(m.browser_query))
        m.modal = :none
    elseif evt.key === :enter
        if 1 <= m.browser_cursor <= n
            _browser_insert!(m, entries[m.browser_cursor])
        end
        m.modal = :none
    elseif evt.char == 'j' || evt.key === :down
        m.browser_cursor = min(m.browser_cursor + 1, max(n, 1))
    elseif evt.char == 'k' || evt.key === :up
        m.browser_cursor = max(m.browser_cursor - 1, 1)
    elseif evt.char == 'K' || evt.char == ' '
        if 1 <= m.browser_cursor <= n
            _browser_preview!(m, entries[m.browser_cursor])
        end
    elseif evt.key === :tab
        filters = (:all, :instruments, :samples, :synths)
        i = findfirst(==(m.browser_filter), filters)
        m.browser_filter = filters[(i % length(filters)) + 1]
        m.browser_cursor = 1
    elseif evt.key === :backspace
        if !isempty(m.browser_query)
            m.browser_query = m.browser_query[1:prevind(m.browser_query, end)]
            m.browser_cursor = 1
        end
    elseif evt.char != '\0' && _is_typable_ascii(evt.char)
        m.browser_query *= string(evt.char)
        m.browser_cursor = 1
    end
end

function _browser_preview!(m::RessacApp, entry::_BrowserEntry)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    now = time()
    now - m.browser_last_preview < 0.05 && return
    m.browser_last_preview = now
    args = Any[]
    if entry.kind === :instrument
        instr = instrument_info(entry.name)
        instr === nothing && return
        for (k, v) in instr.params
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k); push!(args, converted)
        end
    elseif entry.kind === :sample
        push!(args, "s"); push!(args, String(entry.name))
    elseif entry.kind === :synth
        push!(args, "s"); push!(args, String(entry.name))
        push!(args, "release"); push!(args, Float32(0.4))
    end
    push!(args, "cut"); push!(args, Int32(_PREVIEW_CUT_GROUP))
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
end

function _browser_insert!(m::RessacApp, entry::_BrowserEntry)
    ed = _active_editor(m)
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ed.cursor_row
    1 <= row <= length(lines) || (push!(lines, ""); row = length(lines))
    line = lines[row]
    col = clamp(ed.cursor_col, 0, lastindex(line))
    name = String(entry.name)
    prefix = col > 0 ? line[1:col] : ""
    suffix = col >= lastindex(line) ? "" : line[col+1:end]
    lines[row] = prefix * name * suffix
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_col = lastindex(prefix) + lastindex(name)
    _push_app_log!(m, "[INFO] inserted $(entry.kind) $name")
end

function _render_browser_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    entries = _browser_entries(m)
    n = length(entries)
    inner = _render_modal_block!(buf, area;
        title = "BROWSE SOUNDS",
        title_right = "Tab category · / search · j/k · Space preview · Enter insert · q",
        w_max = 120,
        h_target = max(14, min(area.height - 4, n + 8)))
    inner.width < 20 && return
    # ── Row 1: category tab strip ─────────────────────────────────
    filters = (:all, :instruments, :samples, :synths)
    tab_x = inner.x
    for (i, f) in enumerate(filters)
        label = String(f)
        chip  = " " * label * " "
        is_active = f === m.browser_filter
        sty = is_active ? TK.tstyle(:accent, bold = true) :
                          TK.tstyle(:text_dim)
        tab_x + textwidth(chip) > inner.x + inner.width && break
        TK.set_string!(buf, tab_x, inner.y, chip, sty)
        tab_x += textwidth(chip)
        if i < length(filters) && tab_x + 2 < inner.x + inner.width
            TK.set_string!(buf, tab_x, inner.y, "·", TK.tstyle(:text_dim))
            tab_x += 1
        end
    end
    # ── Row 2: search bar ─────────────────────────────────────────
    sb_text = "⌕ " * m.browser_query * "▏"
    TK.set_string!(buf, inner.x, inner.y + 1,
                   first(rpad(sb_text, inner.width), inner.width),
                   TK.tstyle(:text_dim))
    # Body fills rows 3..end.
    body_y = inner.y + 2
    body_h = inner.height - 2
    # Auto-scroll so the cursor stays in view as the user j/k's past
    # the bottom of the viewport.
    m.modal_scroll = _scroll_to_show(m.browser_cursor, n, body_h, m.modal_scroll)
    visible = m.modal_scroll + 1 <= n ?
              entries[(m.modal_scroll + 1):min(end, m.modal_scroll + body_h)] :
              _BrowserEntry[]
    for i in 1:body_h
        line = ""
        if i <= length(visible)
            e = visible[i]
            abs_idx = m.modal_scroll + i
            marker = abs_idx == m.browser_cursor ? "▶ " : "  "
            kind_letter = e.kind === :instrument ? "I" :
                          e.kind === :sample     ? "S" : "Y"
            line = "$(marker)[$kind_letter] $(rpad(String(e.name), 18))  $(e.summary)"
        end
        style = if i <= length(visible) && (m.modal_scroll + i) == m.browser_cursor
            TK.tstyle(:accent, bold = true)
        else
            TK.tstyle(:text)
        end
        TK.set_string!(buf, inner.x, body_y + i - 1,
                       first(rpad(line, inner.width), inner.width), style)
    end
end
