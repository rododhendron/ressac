# Overlay widget for help popups and modal :guide. Renders a centered
# bordered box on top of whatever's already in the buffer.
# Spec: docs/journal/20260522_visual_ux_design.md.

"""
    _overlay_rect(area_w, area_h, want_w, want_h)
        -> (left::Int, top::Int, width::Int, height::Int)

Compute the centered rectangle for an overlay of desired dimensions
`(want_w, want_h)` inside an area of size `(area_w, area_h)`. Both
dimensions are capped to 80% of their respective area.
"""
function _overlay_rect(area_w::Int, area_h::Int, want_w::Int, want_h::Int)
    max_w = max(1, floor(Int, area_w * 0.8))
    max_h = max(1, floor(Int, area_h * 0.8))
    w = min(want_w, max_w)
    h = min(want_h, max_h)
    left = max(0, (area_w - w) ÷ 2)
    top  = max(0, (area_h - h) ÷ 2)
    return (left, top, w, h)
end

"""
    _clip_lines(lines, width) -> Vector{String}

Truncate each line to at most `width` characters. Used to keep
overlay content from overflowing the rendered box.
"""
function _clip_lines(lines::AbstractVector{<:AbstractString}, width::Int)
    out = String[]
    for line in lines
        push!(out, String(first(line, width)))
    end
    return out
end

"""
    _Overlay(lines, title, style; scroll=0)

Custom widget: draws a bordered box centered in its render area,
containing `lines` (clipped + scrolled). The `title` appears in the
top border. `scroll` is the number of lines hidden above the
viewport.
"""
struct _Overlay
    lines::Vector{String}
    title::String
    style::TUI.Crayon
    scroll::Int
end

_Overlay(lines, title; style=TUI.Crayon(), scroll=0) =
    _Overlay(collect(lines), String(title), style, scroll)

function TUI.render(o::_Overlay, area::TUI.Rect, buf::TUI.Buffer)
    area_w = TUI.width(area)
    area_h = TUI.height(area)
    area_w >= 4 && area_h >= 3 || return
    want_h = length(o.lines) + 2
    want_w = 2 + (isempty(o.lines) ? 0 : maximum(length, o.lines))
    want_w = max(want_w, length(o.title) + 4)
    left, top, w, h = _overlay_rect(area_w, area_h, want_w, want_h)
    abs_left = TUI.left(area) + left
    abs_top  = TUI.top(area) + top
    inner_w = w - 2
    # Top border with title.
    title_str = " " * o.title * " "
    fill_w = max(0, w - 2 - length(title_str))
    top_border = "┌" * title_str * "─"^fill_w * "┐"
    TUI.set(buf, abs_left, abs_top, String(first(top_border, w)), o.style)
    # Body.
    inner_h = h - 2
    visible_end = min(length(o.lines), o.scroll + inner_h)
    visible = o.scroll + 1 <= length(o.lines) ?
              o.lines[(o.scroll + 1):visible_end] :
              String[]
    clipped = _clip_lines(visible, inner_w)
    for (i, line) in enumerate(clipped)
        padded = line * " "^max(0, inner_w - length(line))
        TUI.set(buf, abs_left, abs_top + i, "│" * padded * "│", o.style)
    end
    for i in (length(clipped) + 1):inner_h
        TUI.set(buf, abs_left, abs_top + i, "│" * " "^inner_w * "│", o.style)
    end
    bot = "└" * "─"^inner_w * "┘"
    TUI.set(buf, abs_left, abs_top + h - 1, bot, o.style)
end

"""
    _AppView(model)

Top-level composite widget: renders the normal layout, then overlays
the `?` help popup or `:guide` modal on top when their visibility
flags are set.
"""
struct _AppView
    model::LiveModel
end

function TUI.render(v::_AppView, area::TUI.Rect, buf::TUI.Buffer)
    layout = _build_main_layout(v.model)
    TUI.render(layout, area, buf)
    if v.model.show_help
        TUI.render(_help_overlay(v.model), area, buf)
    elseif v.model.mode === :guide
        TUI.render(_guide_overlay(v.model), area, buf)
    end
end

function _help_overlay(m::LiveModel)
    lines = get(_HELP_OVERLAY_LINES, m.mode, String["(no help for this mode)"])
    _Overlay(lines, "? help — press ? to close")
end

function _guide_overlay(m::LiveModel)
    _Overlay(_GUIDE_LINES, ":guide — j/k scroll, q close"; scroll = m.guide_scroll)
end
