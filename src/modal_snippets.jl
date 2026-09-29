# Snippets picker — context-aware multi-line templates. The snippet
# table lives in the plugin-discoverable _SNIPPETS registry (see
# src/extension_registry.jl), populated from every plugin's
# snippets/*.toml + sidecar *.jl. This file owns the picker UI:
# context routing, filter, category tabs, preview, insert, render.
#
# Mapping from the previous _Snippet struct to SnippetEntry:
#   .trigger      → .name
#   .body         → .resolved_content
#   .description  → .description  (unchanged)
#   .category     → first(.tags)  (empty string if no tags)
#   .context      → .context      (unchanged)

"""
    _snip_context(m) -> Symbol

`:patterns` when the patterns pane is focused, `:synth_dsl` or
`:synth_sc` when a synth pane is open and focused — distinguished
so the picker only offers snippets that match the active tab's
authoring language (DSL Julia vs raw SuperCollider).
"""
function _snip_context(m::RessacApp)
    if _focused_role(m) === :synth
        tab = _current_synth_tab(m)
        tab !== nothing && return tab.synth_mode === :dsl ? :synth_dsl : :synth_sc
    end
    return :patterns
end

# Category for a SnippetEntry = first tag (legacy `.category` was a
# single string; SnippetEntry stores `tags::Vector{Symbol}`). Empty
# string when no tags are declared.
_snip_category_of(s::SnippetEntry) =
    isempty(s.tags) ? "" : String(first(s.tags))

function _snippets_visible(m::RessacApp)
    ctx = _snip_context(m)
    base = _snippets_for_context(ctx)
    if !isempty(m.snip_category)
        base = [s for s in base if _snip_category_of(s) == m.snip_category]
    end
    q = lowercase(_picker_query(m.snips))
    isempty(q) && return base
    return [s for s in base
            if occursin(q, lowercase(s.name)) ||
               occursin(q, lowercase(_snip_category_of(s))) ||
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
        cat = _snip_category_of(s)
        isempty(cat) && continue
        cat in seen && continue
        push!(seen, cat); push!(cats, cat)
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
    m.snips.list.selected = 1; m.snips.list.offset = 0
end

function _open_snippets!(m::RessacApp)
    _open_modal!(m, :snippets)
    _picker_reset!(m.snips); _picker_search!(m.snips, false)
    m.snip_category = ""
end

# Pose les snippets visibles dans le picker, formatés pour `width` colonnes.
function _snippets_sync!(m::RessacApp, width::Int = 80)
    snips = _snippets_visible(m)
    rows = [TK.ListItem(first("$(rpad(s.name, 18)) [$(rpad(_snip_category_of(s), 9))]  $(s.description)", width))
            for s in snips]
    _picker_set!(m.snips, rows, snips)
    return snips
end

_snip_cur(m::RessacApp) = (_snippets_sync!(m); _picker_selected(m.snips))

function _handle_snippets_key!(m::RessacApp, evt::TK.KeyEvent)
    pk = m.snips
    if pk.searching
        (evt.key === :escape || evt.key === :enter) && (_picker_search!(pk, false); return)
        _picker_type!(pk, evt) && return
        return
    end
    # Échap pèle : la recherche, puis la catégorie, puis la modale.
    if evt.key === :escape || evt.char == 'q'
        if !isempty(_picker_query(pk))
            _picker_clear!(pk)
        elseif !isempty(m.snip_category)
            m.snip_category = ""; pk.list.selected = 1; pk.list.offset = 0
        else
            m.modal = :none
        end
        return
    end
    dispatch!(((:modal_snippets, m),), evt)
    return
end

"""
    _preview_snippet!(m)

Dump the snippet body line-by-line into the log so the user can read
exactly what Enter would insert. Cheap and reversible.
"""
function _preview_snippet!(m::RessacApp)
    s = _snip_cur(m)
    s === nothing && return
    _push_app_log!(m, "[INFO] aperçu du snippet $(s.name) — $(s.description)")
    for line in split(strip(s.resolved_content), '\n')
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
    s = _snip_cur(m)
    s === nothing && return
    ed = _active_editor(m)
    ed === nothing && return
    body_lines = split(strip(s.resolved_content), '\n')
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
    _push_app_log!(m, "[INFO] snippet $(s.name) inséré ($(length(inserted)) lignes)")
end

function _render_snippets_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    snips = _snippets_visible(m)
    ctx = _snip_context(m)
    ctx_label = ctx === :synth_dsl ? "synth DSL (.jl)" :
                ctx === :synth_sc  ? "synth SC (.scd)" : "patterns"
    inner = _render_modal_block!(buf, area;
        title = "SNIPPETS · $ctx_label",
        title_right = _modal_hint_text(m, :modal_snippets),
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
    _picker_render_input!(m.snips, TK.Rect(inner.x, inner.y + 1, inner.width, 1), buf;
                          hint = "/ pour chercher · Tab change de catégorie · Entrée insère")
    # ── Body: rows 3..(end-1), footer on last row ────────────────
    body_y0 = inner.y + 2
    body_h  = inner.height - 3
    _snippets_sync!(m, inner.width - 3)
    n = length(snips)
    if n == 0
        q = _picker_query(m.snips)
        msg = isempty(q) ?
            "(aucun snippet dans la catégorie « $(m.snip_category) »)" :
            "(rien pour « $q »)"
        TK.set_string!(buf, inner.x + 1, body_y0, msg, TK.tstyle(:text_dim))
    else
        _picker_render_list!(m.snips, TK.Rect(inner.x, body_y0, inner.width, body_h), buf)
    end
    cat_label = isempty(m.snip_category) ? "all" : m.snip_category
    foot = "$(n) shown · ctx = $ctx_label · cat = $cat_label"
    TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                   first(rpad(foot, inner.width), inner.width),
                   TK.tstyle(:text_dim))
end

# ── Registre de touches (déclaré en fin de fichier : les actions nommées
#    doivent exister au moment du bind!) ──
scope!(:modal_snippets, "Snippets")
bind!(:modal_snippets, "Enter", "insérer"; group = :edit, action = _insert_snippet!)
bind!(:modal_snippets, "Space", "aperçu"; group = :view, action = _preview_snippet!)
bind!(:modal_snippets, ["Tab", "l", "→"], "catégorie suivante"; group = :nav,
      action = m -> _snip_cycle_category!(m, +1))
bind!(:modal_snippets, ["h", "←"], "catégorie précédente"; group = :nav, hint = false,
      action = m -> _snip_cycle_category!(m, -1))
bind!(:modal_snippets, "/", "rechercher"; group = :edit, action = m -> _picker_search!(m.snips, true))
bind!(:modal_snippets, ["j", "↓"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (_snippets_sync!(m); _picker_nav!(m.snips, :down)))
bind!(:modal_snippets, ["k", "↑"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (_snippets_sync!(m); _picker_nav!(m.snips, :up)))
bind!(:modal_snippets, ["PgDn", "Ctrl-d"], "page suivante"; group = :nav, hint = false, repeat = true,
      action = m -> (_snippets_sync!(m); _picker_nav!(m.snips, :pagedown)))
bind!(:modal_snippets, ["PgUp", "Ctrl-u"], "page précédente"; group = :nav, hint = false, repeat = true,
      action = m -> (_snippets_sync!(m); _picker_nav!(m.snips, :pageup)))
bind!(:modal_snippets, "Esc / q", "effacer la recherche → la catégorie → fermer"; group = :nav, hint = false)
_bind_modal_common!(:modal_snippets; nav = false)
