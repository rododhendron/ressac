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
    synth_mode::Symbol      # :dsl | :sc  (only meaningful for :synth role)
end

function EditorBuffer(; role::Symbol = :patterns,
                       name::AbstractString = "main",
                       content::AbstractString = "",
                       synth_mode::Symbol = :dsl)
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
                        eval_target, completion_ctx, synth_mode)
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
    tab = p.tabs[p.current_tab]
    # Eval shortcuts only fire from :normal — otherwise 'e' in
    # insert mode would never reach the buffer (the original bug).
    if evt isa TK.KeyEvent && evt.key === :char &&
       tab.code_editor.mode === :normal
        if evt.char == 'e' && tab.eval_target === :slot
            _eval_focused_buffer_to_slot!(tab)
            return true
        elseif evt.char == 'T' && tab.eval_target === :sc_eval
            _eval_focused_buffer_to_sc!(tab)
            return true
        end
    end
    return TK.handle_key!(tab.code_editor, evt)
end

# Eval bridges. T8b wires these to the existing slot push and SC
# eval flows in tui_app.jl; for now they're no-ops so dispatch is
# observable in tests without firing a real eval.
_eval_focused_buffer_to_slot!(::EditorBuffer) = nothing
_eval_focused_buffer_to_sc!(::EditorBuffer)   = nothing

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
