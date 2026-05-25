# Snippets picker — context-aware multi-line templates. The snippet
# table itself lives in src/snippets.jl as the const _SNIPPETS; this
# file owns the picker UI: context routing, filter, category tabs,
# preview, insert, render. Extracted from app.jl.

"""
    _snip_context(m) -> Symbol

`:patterns` when the patterns pane is focused, `:synth_dsl` or
`:synth_sc` when a synth pane is open and focused — distinguished
so the picker only offers snippets that match the active tab's
authoring language (DSL Julia vs raw SuperCollider).
"""
function _snip_context(m::RessacApp)
    if m.focus === :synth && _synth_pane_open(m)
        tab = _current_synth_tab(m)
        return tab.mode === :dsl ? :synth_dsl : :synth_sc
    end
    return :patterns
end

function _snippets_visible(m::RessacApp)
    ctx = _snip_context(m)
    base = _snippets_for_context(ctx)
    # Filter by active category tab (empty == "all").
    if !isempty(m.snip_category)
        base = [s for s in base if s.category == m.snip_category]
    end
    isempty(m.snip_query) && return base
    q = lowercase(m.snip_query)
    return [s for s in base
            if occursin(q, lowercase(s.trigger)) ||
               occursin(q, lowercase(s.category)) ||
               occursin(q, lowercase(s.description))]
end

"""
    _snip_categories(m) -> Vector{String}

Categories available for the current context, in declaration order so
the tabs follow the visual grouping in snippets.jl. The empty string
"" is prepended as the implicit "all" tab.
"""
function _snip_categories(m::RessacApp)
    ctx = _snip_context(m)
    base = _snippets_for_context(ctx)
    cats = String[""]
    seen = Set{String}()
    for s in base
        s.category in seen && continue
        push!(seen, s.category); push!(cats, s.category)
    end
    return cats
end

"""
    _snip_cycle_category!(m, dir)

Move the active category tab by `dir` (±1), wrapping around. Resets
the cursor to the top of the new filtered list so the user lands on
the first snippet of the category.
"""
function _snip_cycle_category!(m::RessacApp, dir::Int)
    cats = _snip_categories(m)
    isempty(cats) && return
    cur = findfirst(==(m.snip_category), cats)
    cur === nothing && (cur = 1)
    new = mod1(cur + dir, length(cats))
    m.snip_category = cats[new]
    m.snip_cursor = 1
end

function _open_snippets!(m::RessacApp)
    m.modal = :snippets
    m.snip_cursor = 1
    m.snip_query = ""
    m.snip_search_mode = false
    m.snip_category = ""
end

function _handle_snippets_key!(m::RessacApp, evt::TK.KeyEvent)
    if m.snip_search_mode
        if evt.key === :escape
            m.snip_search_mode = false
        elseif evt.key === :enter
            m.snip_search_mode = false
        elseif evt.key === :backspace
            isempty(m.snip_query) || (m.snip_query = m.snip_query[1:end-1])
            m.snip_cursor = 1
        elseif evt.key === :char && isprint(evt.char)
            m.snip_query *= string(evt.char)
            m.snip_cursor = 1
        end
        return
    end
    n = length(_snippets_visible(m))
    if evt.key === :escape || evt.char == 'q'
        if !isempty(m.snip_query)
            m.snip_query = ""; m.snip_cursor = 1
        elseif !isempty(m.snip_category)
            m.snip_category = ""; m.snip_cursor = 1
        else
            m.modal = :none
        end
    elseif evt.char == '/'
        m.snip_search_mode = true
    elseif evt.key === :tab || evt.char == 'l' || evt.key === :right
        _snip_cycle_category!(m, +1)
    elseif evt.char == 'h' || evt.key === :left
        _snip_cycle_category!(m, -1)
    elseif evt.char == 'j' || evt.key === :down
        m.snip_cursor = min(m.snip_cursor + 1, max(n, 1))
    elseif evt.char == 'k' || evt.key === :up
        m.snip_cursor = max(m.snip_cursor - 1, 1)
    elseif evt.char == ' '
        _preview_snippet!(m)
    elseif evt.key === :enter || evt.char == '\r'
        _insert_snippet!(m)
    end
end

"""
    _preview_snippet!(m)

Dump the snippet body line-by-line into the log so the user can read
exactly what Enter would insert. Cheap and reversible.
"""
function _preview_snippet!(m::RessacApp)
    snips = _snippets_visible(m)
    1 <= m.snip_cursor <= length(snips) || return
    s = snips[m.snip_cursor]
    _push_app_log!(m, "[INFO] snippet preview: $(s.trigger) — $(s.description)")
    for line in split(strip(s.body), '\n')
        _push_app_log!(m, "        $line")
    end
end

"""
    _insert_snippet!(m)

Splice the snippet body into the active editor at the cursor. The
snippet is dedented (we trim the leading indent that's in the
source-file string literal) and inserted as a NEW line below the
current one — so the user's existing line content is preserved.
After insertion the cursor lands at the START of the first new line.
"""
function _insert_snippet!(m::RessacApp)
    snips = _snippets_visible(m)
    1 <= m.snip_cursor <= length(snips) || return
    s = snips[m.snip_cursor]
    ed = _active_editor(m)
    body_lines = split(strip(s.body), '\n')
    min_indent = typemax(Int)
    for line in body_lines
        stripped = lstrip(line)
        isempty(stripped) && continue
        min_indent = min(min_indent, length(line) - length(stripped))
    end
    min_indent === typemax(Int) && (min_indent = 0)
    dedented = [length(line) >= min_indent ? line[min_indent + 1 : end] : line
                for line in body_lines]
    txt = TK.text(ed)
    src_lines = collect(split(txt, '\n'; keepempty=true))
    row = clamp(ed.cursor_row, 1, length(src_lines))
    inserted = String.(dedented)
    new_lines = vcat(src_lines[1:row], inserted, src_lines[row+1:end])
    TK.set_text!(ed, join(new_lines, '\n'))
    ed.cursor_row = row + 1
    ed.cursor_col = 0
    m.modal = :none
    _push_app_log!(m, "[INFO] inserted snippet $(s.trigger) ($(length(inserted)) lines)")
end

function _render_snippets_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    snips = _snippets_visible(m)
    ctx = _snip_context(m)
    ctx_label = ctx === :synth_dsl ? "synth DSL (.jl)" :
                ctx === :synth_sc  ? "synth SC (.scd)" : "patterns"
    inner = _render_modal_block!(buf, area;
        title = "SNIPPETS · $ctx_label",
        title_right = "Tab/h-l category · / search · j/k · Space preview · Enter insert · q",
        w_max = 110,
        h_target = max(14, area.height - 4))
    inner.width < 20 && return
    # ── Row 1: category tab strip ─────────────────────────────────
    cats = _snip_categories(m)
    tab_x = inner.x
    for cat in cats
        label = cat == "" ? "all" : cat
        chip  = " " * label * " "
        is_active = cat == m.snip_category
        sty = is_active ? TK.tstyle(:accent, bold = true) :
                          TK.tstyle(:text_dim)
        tab_x + textwidth(chip) > inner.x + inner.width && break
        TK.set_string!(buf, tab_x, inner.y, chip, sty)
        tab_x += textwidth(chip)
        if cat != cats[end] && tab_x + 2 < inner.x + inner.width
            TK.set_string!(buf, tab_x, inner.y, "·", TK.tstyle(:text_dim))
            tab_x += 1
        end
    end
    # ── Row 2: search bar ─────────────────────────────────────────
    sb_prefix = m.snip_search_mode ? "/" : "⌕ "
    sb_text = sb_prefix * m.snip_query * (m.snip_search_mode ? "▏" : "")
    sb_style = m.snip_search_mode ?
        TK.tstyle(:accent, bold = true) : TK.tstyle(:text_dim)
    TK.set_string!(buf, inner.x, inner.y + 1,
                   first(rpad(sb_text, inner.width), inner.width), sb_style)
    # ── Body: rows 3..(end-1), footer on last row ────────────────
    body_y0 = inner.y + 2
    body_h  = inner.height - 3
    n = length(snips)
    if n == 0
        msg = isempty(m.snip_query) ?
            "(no snippets in category '$(m.snip_category)')" :
            "(no match for \"$(m.snip_query)\")"
        TK.set_string!(buf, inner.x + 1, body_y0, msg, TK.tstyle(:text_dim))
    else
        start_i = max(1, m.snip_cursor - body_h ÷ 2)
        end_i = min(n, start_i + body_h - 1)
        start_i = max(1, end_i - body_h + 1)
        empty!(m.modal_rows)
        for (slot, i) in enumerate(start_i:end_i)
            s = snips[i]
            is_cur = i == m.snip_cursor
            marker = is_cur ? "▶ " : "  "
            label = "$(marker)$(rpad(s.trigger, 18)) [$(rpad(s.category, 9))]  $(s.description)"
            style = is_cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
            screen_y = body_y0 + slot - 1
            TK.set_string!(buf, inner.x, screen_y,
                           first(rpad(label, inner.width), inner.width), style)
            push!(m.modal_rows, (screen_y, i))
        end
    end
    cat_label = isempty(m.snip_category) ? "all" : m.snip_category
    foot = "$(n) shown · ctx = $ctx_label · cat = $cat_label"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(rpad(foot, inner.width), inner.width),
                   TK.tstyle(:text_dim))
end
