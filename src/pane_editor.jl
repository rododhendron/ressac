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
    eval_target::Symbol     # :slot | :sc_eval
    completion_ctx::Symbol  # :patterns_dsl | :synth_dsl | :sc_ugens
end

function EditorBuffer(; role::Symbol = :patterns,
                       name::AbstractString = "main",
                       content::AbstractString = "")
    eval_target, completion_ctx = if role === :synth
        (:sc_eval, :synth_dsl)
    else
        (:slot, :patterns_dsl)
    end
    ed = TK.CodeEditor(; text = String(content),
                         focused = false,
                         tick = 0,
                         mode = :normal)
    return EditorBuffer(ed, role, String(name),
                        eval_target, completion_ctx)
end

mutable struct EditorPane <: PaneImpl
    tabs::Vector{EditorBuffer}
    current_tab::Int
end

EditorPane() = EditorPane([EditorBuffer()], 1)

function _editor_pane_ctor(args::AbstractDict)
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
    TK.render(tab.code_editor, inner, buf)
    return nothing
end

handle_key!(::EditorPane, evt) = false           # filled in Task 3c

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
            "cursor_row" => t.code_editor.cursor_row,
            "cursor_col" => t.code_editor.cursor_col,
            "scroll_offset" => t.code_editor.scroll_offset,
        ) for t in p.tabs],
        "current_tab" => p.current_tab,
    )
end

# ── Registration ───────────────────────────────────────────────────
register_pane_kind!(:editor, _editor_pane_ctor)
