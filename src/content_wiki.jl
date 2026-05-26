using Tachikoma
const _WIKI_TK = Tachikoma

# Wiki — navigable in-app documentation, sourced from docs/wiki/*.md.
#
# Pages are markdown files; the modal renders a TOC + the selected
# page's content with basic markdown styling (headings, code blocks,
# lists, paragraphs). `:wiki` opens it, j/k scroll the content,
# n/p switch pages, q closes. Pages are re-read at every open so
# editing a .md file just needs another `:wiki`.

struct _WikiPage
    filename::String      # basename, e.g. "02-patterns.md"
    title::String         # first H1, or filename-stripped fallback
    lines::Vector{String} # body lines after the H1
end

"""
    _load_wiki_pages() -> Vector{_WikiPage}

Scan `docs/wiki/*.md` (project-relative), sort alphabetically by
filename (so `01-intro.md` comes first), and parse each into a page.
The title is the first `# H1` line; everything below it is body.
"""
function _load_wiki_pages()
    out = _WikiPage[]
    dir = joinpath(pwd(), "docs", "wiki")
    isdir(dir) || return out
    for f in sort!(readdir(dir))
        endswith(f, ".md") || continue
        path = joinpath(dir, f)
        body = try read(path, String) catch; "" end
        lines = collect(split(body, '\n'; keepempty=true))
        # Pull H1 as title; remove blank lines before it; rest is body.
        title = first(splitext(f)[1], 60)
        body_start = 1
        for (i, line) in enumerate(lines)
            stripped = strip(line)
            isempty(stripped) && continue
            if startswith(stripped, "# ")
                title = strip(stripped[3:end])
                body_start = i + 1
                break
            else
                break
            end
        end
        push!(out, _WikiPage(f, String(title), String.(lines[body_start:end])))
    end
    return out
end

"""
    _render_markdown_line(line, buf, x, y, max_w) -> next_y_offset

Render one markdown line with a style appropriate to its type.
Returns how many screen rows were consumed (usually 1; code blocks
and wrapped lines may take more — for now we wrap by truncation).
"""
function _render_markdown_line!(line::AbstractString, buf::_WIKI_TK.Buffer,
                                x::Int, y::Int, max_w::Int;
                                in_code::Bool = false)
    s = String(line)
    if in_code
        # Inside a fenced code block — primary colour, no markdown.
        _WIKI_TK.set_string!(buf, x, y, first(rpad(s, max_w), max_w),
                       _WIKI_TK.tstyle(:primary))
    elseif startswith(s, "## ")
        text = strip(s[4:end])
        _WIKI_TK.set_string!(buf, x, y, first(rpad("» " * text, max_w), max_w),
                       _WIKI_TK.tstyle(:primary, bold=true))
    elseif startswith(s, "# ")
        text = strip(s[3:end])
        _WIKI_TK.set_string!(buf, x, y, first(rpad("▓ " * text, max_w), max_w),
                       _WIKI_TK.tstyle(:accent, bold=true))
    elseif startswith(s, "### ")
        text = strip(s[5:end])
        _WIKI_TK.set_string!(buf, x, y, first(rpad("  " * text, max_w), max_w),
                       _WIKI_TK.tstyle(:title, bold=true))
    elseif startswith(s, "- ") || startswith(s, "* ")
        text = strip(s[3:end])
        _WIKI_TK.set_string!(buf, x, y, first(rpad("  • " * text, max_w), max_w),
                       _WIKI_TK.tstyle(:text))
    else
        # Plain paragraph; trim trailing whitespace and clip to width.
        _WIKI_TK.set_string!(buf, x, y, first(rpad(s, max_w), max_w),
                       _WIKI_TK.tstyle(:text))
    end
end
