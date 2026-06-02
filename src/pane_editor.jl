# src/pane_editor.jl
# :editor pane — unified patterns + synth editor with role-per-buffer.
#
# Each tab is an EditorBuffer with a role (:patterns | :synth) that
# determines:
#   * eval target (slot scheduler vs SC eval)
#   * completion context (patterns DSL vs UGens/SynthDSL)
#   * which key bindings dispatch (`e` vs `T`)

mutable struct EditorBuffer
    code_editor::TK.CodeEditor
    role::Symbol            # :patterns | :synth
    name::String
    synth_mode::Symbol      # :dsl | :sc  (only meaningful for :synth role)
end

function EditorBuffer(; role::Symbol = :patterns,
                       name::AbstractString = "main",
                       content::AbstractString = "",
                       synth_mode::Symbol = :dsl)
    ed = TK.CodeEditor(; text = String(content),
                         focused = false,
                         tick = 0,
                         mode = :normal)
    return EditorBuffer(ed, role, String(name), synth_mode)
end

mutable struct EditorPane <: PaneImpl
    tabs::Vector{EditorBuffer}
    current_tab::Int
end

EditorPane() = EditorPane([EditorBuffer()], 1)

function _editor_pane_ctor(args::AbstractDict)
    # Restore path: a serialized pane carries a "tabs" list with the
    # buffer content + cursor. Rebuild each EditorBuffer so layout
    # load doesn't drop what the user had open.
    tabs_raw = get(args, "tabs", nothing)
    if tabs_raw isa AbstractVector && !isempty(tabs_raw)
        buffers = EditorBuffer[]
        for t in tabs_raw
            t isa AbstractDict || continue
            role = String(get(t, "role", "patterns")) == "synth" ? :synth : :patterns
            name = String(get(t, "name", "main"))
            content = String(get(t, "content", ""))
            smode = Symbol(String(get(t, "synth_mode", "dsl")))
            buf = EditorBuffer(; role = role, name = name,
                                content = content, synth_mode = smode)
            buf.code_editor.cursor_row = Int(get(t, "cursor_row", 1))
            buf.code_editor.cursor_col = Int(get(t, "cursor_col", 0))
            buf.code_editor.scroll_offset = Int(get(t, "scroll_offset", 0))
            push!(buffers, buf)
        end
        if !isempty(buffers)
            cur = Int(get(args, "current_tab", 1))
            return EditorPane(buffers, clamp(cur, 1, length(buffers)))
        end
    end
    # Fresh path: a new pane from `:vsplit editor` / snippet panes.
    role_str = String(get(args, "buffer_role", "patterns"))
    name_str = String(get(args, "name", "main"))
    role = role_str == "synth" ? :synth : :patterns
    buf = EditorBuffer(; role = role, name = name_str)
    return EditorPane([buf], 1)
end

# ── PaneImpl contract ──────────────────────────────────────────────

function render!(p::EditorPane, area, buf)
    1 <= p.current_tab <= length(p.tabs) || return
    tab = p.tabs[p.current_tab]
    title_str = tab.role === :synth ?
        "SYNTH · $(tab.name)" :
        "PATTERNS"
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    _render_pane_block_simple!(rect, title_str, buf)
    inner = _inner_rect_simple(rect)
    if length(p.tabs) > 1 && inner.height >= 2
        tab_row = TK.Rect(inner.x, inner.y, inner.width, 1)
        body    = TK.Rect(inner.x, inner.y + 1, inner.width, inner.height - 1)
        _render_editor_tab_strip!(p, tab_row, buf)
        TK.render(tab.code_editor, body, buf)
    else
        TK.render(tab.code_editor, inner, buf)
    end
    return nothing
end

function _render_editor_tab_strip!(p::EditorPane, area::TK.Rect, buf::TK.Buffer)
    x = area.x
    for (i, t) in enumerate(p.tabs)
        is_current = i == p.current_tab
        label = " $(t.name) "
        style = is_current ?
            TK.tstyle(:accent, bold = true) :
            TK.tstyle(:text_dim)
        x + textwidth(label) > area.x + area.width && break
        TK.set_string!(buf, x, area.y, label, style)
        x += textwidth(label)
    end
end

function handle_key!(p::EditorPane, evt)
    1 <= p.current_tab <= length(p.tabs) || return false
    # Delegate straight to the underlying TK.CodeEditor. The eval
    # shortcuts (`e` for patterns slots, `T` for synth SC) are routed
    # at the app level in tui_app.jl — they need the RessacApp +
    # scheduler, which the PaneImpl contract doesn't carry — so there
    # are no per-pane eval stubs here.
    return TK.handle_key!(p.tabs[p.current_tab].code_editor, evt)
end

function title(p::EditorPane)
    1 <= p.current_tab <= length(p.tabs) || return "(empty editor)"
    return p.tabs[p.current_tab].name
end

# Defaulted overrides
default_mode(::EditorPane) = :tile

function serialize(p::EditorPane)
    return Dict{String,Any}(
        "tabs" => [Dict{String,Any}(
            "role" => String(t.role),
            "name" => t.name,
            "content" => TK.text(t.code_editor),
            "synth_mode" => String(t.synth_mode),
            "cursor_row" => t.code_editor.cursor_row,
            "cursor_col" => t.code_editor.cursor_col,
            "scroll_offset" => t.code_editor.scroll_offset,
        ) for t in p.tabs],
        "current_tab" => p.current_tab,
    )
end

# ── Registration ───────────────────────────────────────────────────
register_pane_kind!(:editor, _editor_pane_ctor)
