using Tachikoma
const _WIKI_TK = Tachikoma

# Wiki — navigable in-app documentation, sourced from docs/wiki/*.md.
#
# Pages are markdown files; the pane renders a TOC + the selected
# page's content through the shared markdown renderer
# (content_markdown.jl). `:wiki` opens it, j/k scroll the content,
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
# docs/wiki du paquet (quel que soit le répertoire courant), sinon celui
# du répertoire courant, sinon rien.
function _wiki_dir()
    for base in (dirname(@__DIR__), pwd())
        d = joinpath(base, "docs", "wiki")
        isdir(d) && return d
    end
    return nothing
end

function _load_wiki_pages()
    out = _WikiPage[]
    dir = _wiki_dir()
    dir === nothing && return out
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
