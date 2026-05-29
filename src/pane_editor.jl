# src/pane_editor.jl
# :editor pane — unified patterns + synth editor with role-per-buffer.
#
# Each tab is an EditorBuffer with a role (:patterns | :synth) that
# determines:
#   * eval target (slot scheduler vs SC eval)
#   * completion context (patterns DSL vs UGens/SynthDSL)
#   * which key bindings dispatch (`e` vs `T`)
#
# Sub-project 9 ships the pane skeleton + 4 contract fns + role
# routing. The actual editor cursor / autocomplete / vim modal logic
# reuses the existing code in tui_app.jl (Tachikoma text buffer).
# Step 7 of the migration plan (= Task 8) swaps the m.editor field
# out for an EditorPane wrapper.

struct EditorBuffer
    content::String
    cursor_row::Int
    cursor_col::Int
    scroll_offset::Int
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
    return EditorBuffer(String(content), 1, 0, 0, role, String(name),
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

# Mandatory: render!, handle_key!, title.
# Task 8 will wire render! to the existing Tachikoma text buffer
# rendering. For Task 4, we provide stubs that satisfy the contract.

render!(::EditorPane, area, buf) = nothing       # filled in Task 8
handle_key!(::EditorPane, evt) = false           # filled in Task 8

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
            "content" => t.content,
            "cursor_row" => t.cursor_row,
            "cursor_col" => t.cursor_col,
            "scroll_offset" => t.scroll_offset,
        ) for t in p.tabs],
        "current_tab" => p.current_tab,
    )
end

# ── Registration ───────────────────────────────────────────────────
register_pane_kind!(:editor, _editor_pane_ctor)
