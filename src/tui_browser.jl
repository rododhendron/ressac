# Modal browser over the instrument/sample/synth registries.
# Triggered by `:browse` (alias `:b`). j/k navigates, typing filters
# (fuzzy), K (or hovering) previews, Enter inserts the name at the
# editor cursor, Tab cycles the type filter (all → instruments →
# samples → synths → all), Esc closes.

"""
    _BrowserEntry

Unified picker row. Carries enough metadata to render a one-line
summary and dispatch a preview without re-querying the registry.
"""
struct _BrowserEntry
    kind::Symbol      # :instrument | :sample | :synth
    name::Symbol
    plugin::String
    summary::String   # rendered detail (params or tags), one-liner
end

const _BROWSER_FILTERS = (:all, :instruments, :samples, :synths)

"""
    _browser_collect(filter) -> Vector{_BrowserEntry}

Snapshot the live registries into a flat list filtered by `filter`.
Sorted by `(kind, name)` so the unfiltered list is stable.
"""
function _browser_collect(filter::Symbol)
    out = _BrowserEntry[]
    if filter === :all || filter === :instruments
        for entry in values(_INSTRUMENT_REGISTRY)
            push!(out, _BrowserEntry(:instrument, entry.name, entry.plugin,
                                     _instrument_summary(entry)))
        end
    end
    if filter === :all || filter === :samples
        for entry in values(_SAMPLE_REGISTRY)
            push!(out, _BrowserEntry(:sample, entry.name, entry.plugin,
                                     _sample_summary(entry)))
        end
    end
    if filter === :all || filter === :synths
        for entry in values(_SYNTH_REGISTRY)
            push!(out, _BrowserEntry(:synth, entry.name, entry.plugin,
                                     _synth_summary(entry)))
        end
    end
    sort!(out, by = e -> (String(e.kind), String(e.name)))
    return out
end

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

"""
    _browser_filtered(m) -> Vector{_BrowserEntry}

Apply the live fuzzy query to the current filter's snapshot. Results
sorted by `(score, length, lexico)`; non-matches dropped (empty query
keeps everything in name order).
"""
function _browser_filtered(m::LiveModel)
    all_entries = _browser_collect(m.browser_filter)
    isempty(m.browser_query) && return all_entries
    scored = Tuple{Int,Int,_BrowserEntry}[]
    for entry in all_entries
        s = _fuzzy_score(m.browser_query, String(entry.name))
        s === nothing && continue
        push!(scored, (s, length(String(entry.name)), entry))
    end
    sort!(scored, by = t -> (t[1], t[2], String(t[3].name)))
    return [t[3] for t in scored]
end

# ---------------------------------------------------------------------
# Mode handler
# ---------------------------------------------------------------------

"""
    _handle_browser!(m, evt)

Keystroke router for `:browse` mode.

- j/k or arrows → move selection (no preview — explicit only).
- Backspace → drop the last query char.
- Printable ASCII → append to query.
- Tab → cycle the type filter.
- K or Space → fire a preview of the highlighted entry.
- Enter → insert the highlighted name at the editor cursor + close.
- q / Esc → close, restore mode.
"""
function _handle_browser!(m::LiveModel, evt)
    code = evt.code
    entries = _browser_filtered(m)
    n = length(entries)
    if code == "Esc" || code == "q" && isempty(m.browser_query)
        _browser_close!(m)
    elseif code == "Enter"
        if 1 <= m.browser_cursor <= n
            _browser_insert!(m, entries[m.browser_cursor])
        end
        _browser_close!(m)
    elseif code == "j" || code == "Down"
        m.browser_cursor = min(m.browser_cursor + 1, max(n, 1))
    elseif code == "k" || code == "Up"
        m.browser_cursor = max(m.browser_cursor - 1, 1)
    elseif code == "K" || code == " "
        # Explicit preview only — auto-preview on j/k was too spammy.
        # `K` (vim convention) or Space both fire.
        _browser_preview!(m, entries; min_gap = 0.0)
    elseif code == "Tab"
        idx = findfirst(==(m.browser_filter), _BROWSER_FILTERS)
        m.browser_filter = _BROWSER_FILTERS[(idx % length(_BROWSER_FILTERS)) + 1]
        m.browser_cursor = 1
        m.browser_scroll = 0
    elseif code == "Backspace"
        if !isempty(m.browser_query)
            m.browser_query = m.browser_query[1:prevind(m.browser_query, end)]
            m.browser_cursor = 1
            m.browser_scroll = 0
        end
    elseif length(code) == 1
        c = first(code)
        if _is_typable_ascii(c)
            m.browser_query *= code
            m.browser_cursor = 1
            m.browser_scroll = 0
        end
    end
end

function _browser_close!(m::LiveModel)
    m.mode = :normal
    m.browser_query = ""
    m.browser_cursor = 1
    m.browser_scroll = 0
end

function _browser_preview!(m::LiveModel, entries; min_gap::Float64 = 0.1)
    isempty(entries) && return
    1 <= m.browser_cursor <= length(entries) || return
    now = time()
    now - m.browser_last_preview < min_gap && return
    m.browser_last_preview = now
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    entry = entries[m.browser_cursor]
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
        # SuperDirt synths default to a near-zero envelope and are silent
        # without release; ours gets a sane preview envelope.
        push!(args, "release"); push!(args, Float32(0.4))
    end
    # Shared preview cut group: every preview shares cut=PREVIEW_CUT, so
    # firing a new one truncates the tail of the previous one. Avoids
    # the long-release pile-up the user noticed.
    push!(args, "cut"); push!(args, Int32(_PREVIEW_CUT_GROUP))
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
end

"""
    _PREVIEW_CUT_GROUP

The SuperDirt `cut` value used by every TUI preview (browser, K).
Voices sharing the same positive cut group truncate each other, so
each new preview silences the previous one. Chosen to be high enough
that user patterns are unlikely to collide with it.
"""
const _PREVIEW_CUT_GROUP = 9999

function _browser_insert!(m::LiveModel, entry::_BrowserEntry)
    name = String(entry.name)
    line = m.buffer[m.cursor_row]
    col = clamp(m.cursor_col, 1, lastindex(line) + 1)
    prefix = col > 1 ? line[1:prevind(line, col)] : ""
    suffix = col > lastindex(line) ? "" : line[col:end]
    m.buffer[m.cursor_row] = prefix * name * suffix
    m.cursor_col = lastindex(prefix) + lastindex(name) + 1
    _push_log!(m, "[INFO] inserted $(entry.kind) $name")
end

# ---------------------------------------------------------------------
# Overlay rendering
# ---------------------------------------------------------------------

"""
    _browser_lines(m, entries) -> Vector{String}

Render the picker's body lines. Format per row:
`> [I] name              summary`. Selected row gets a leading `>`,
others get spaces. Type letter is color-coded by virtue of being a
1-letter mnemonic readers can scan.
"""
function _browser_lines(m::LiveModel, entries::Vector{_BrowserEntry})
    lines = String[]
    push!(lines, "filter: $(m.browser_filter)     query: $(m.browser_query)█")
    push!(lines, "")
    if isempty(entries)
        push!(lines, "  (no matches — Backspace to broaden, Tab to switch filter)")
        return lines
    end
    name_w = max(8, maximum(length(String(e.name)) for e in entries; init=8))
    for (i, e) in enumerate(entries)
        marker = i == m.browser_cursor ? "▶ " : "  "
        kind_letter = e.kind === :instrument ? "I" :
                      e.kind === :sample     ? "S" : "Y"
        name_padded = rpad(String(e.name), name_w)
        push!(lines, "$(marker)[$kind_letter] $name_padded  $(e.summary)")
    end
    push!(lines, "")
    push!(lines, "$(length(entries)) match$(length(entries) == 1 ? "" : "es")")
    return lines
end

function _browser_overlay(m::LiveModel)
    entries = _browser_filtered(m)
    lines = _browser_lines(m, entries)
    # Clamp scroll so the cursor stays inside the viewport. Lines 1-2 are
    # the header (query); the first entry is index 3 in lines. Scroll only
    # the body region.
    header_lines = 2
    # Body cursor row inside `lines` for the selected entry.
    body_idx = isempty(entries) ? 0 : (header_lines + m.browser_cursor)
    if body_idx > 0
        # Hint: keep the cursor visible. Adjust scroll if needed using the
        # rendered height heuristic (we don't know it pre-render, so trust
        # the user to scroll naturally and let _Overlay clip).
        m.browser_scroll = max(0, body_idx - 18)
    end
    _Overlay(lines, "browse — j/k nav, K/Space preview, Tab filter, Enter insert, Esc close";
             scroll = m.browser_scroll)
end
