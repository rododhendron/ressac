# sccode.org integration. Fetches the public listing + individual code
# pages via HTTP, scrapes out the SuperCollider source for preview and
# save. There is no JSON API on sccode.org — we parse the HTML with
# narrow regexes that have to be revisited if the site's markup
# evolves. Failures are logged, not raised.

using HTTP

const _SCCODE_BASE = "https://sccode.org"

struct _SccodeEntry
    id::String         # e.g. "1-5iP"
    title::String
end

# Per-id source cache so previewing then loading the same entry doesn't
# refetch. Keyed by id, value is the raw SC source.
const _SCCODE_SOURCE_CACHE = Dict{String,String}()

"""
    _sccode_fetch_list(page=1; tag="") -> Vector{_SccodeEntry}

Hit `https://sccode.org/?p=N&tag=…` and extract every anchor pointing
to a snippet (URL pattern `/0-2U` / `/1-5iP` …). Returns the entries
in page order. Passing a `tag` narrows the result server-side.
"""
function _sccode_fetch_list(page::Int = 1; tag::AbstractString = "")
    # sccode.org's pagination param is `page`, not `p` (the latter looks
    # plausible from the URLs in cached docs but actually returns the
    # frontpage unchanged — the bug that made n/p look broken). Tags
    # use the path form `/tag/<scope>/<name>` rather than a query arg;
    # if the caller passes a `scope/name` pair (or just `name` defaulting
    # to a top-level tag) we route accordingly.
    base = if isempty(tag)
        _SCCODE_BASE * "/"
    else
        # Allow "class/SinOsc" or bare "synth" — sccode tags can be
        # auto-extracted classes (under /tag/class/) or user tags
        # (under /tag/). Default to class scope when no `/` present
        # since that's the more populated namespace.
        path = occursin('/', String(tag)) ? String(tag) : "class/" * String(tag)
        _SCCODE_BASE * "/tag/" * path
    end
    sep = occursin('?', base) ? "&" : "?"
    url = "$(base)$(sep)page=$(page)"
    r = HTTP.get(url; readtimeout = 15, status_exception = false)
    r.status == 200 || throw(error("sccode list HTTP $(r.status) for $url"))
    body = String(r.body)
    out = _SccodeEntry[]
    seen = Set{String}()
    # Sccode marks the code-page link with `class="object"`; user profile
    # links share the URL shape (`/0-2U` etc) but lack that class — keep
    # only `object`-tagged anchors so the listing isn't polluted by
    # author profile rows.
    for m in eachmatch(r"<a class=\"object\" href=\"/([0-9][\w-]*)\">([^<]+)</a>", body)
        id = String(m.captures[1])
        title = strip(_decode_html_entities(String(m.captures[2])))
        id in seen && continue
        push!(seen, id)
        push!(out, _SccodeEntry(id, isempty(title) ? "(untitled)" : title))
    end
    return out
end

"""
    _sccode_fetch_source(id) -> String

Fetch the page for a snippet and pull the syntax-highlighted source
out of the second `<pre>` block (the first is line numbers). Strips
HTML tags + decodes entities; result is the bare SuperCollider source.
Cached per-id.
"""
function _sccode_fetch_source(id::AbstractString)
    sid = String(id)
    haskey(_SCCODE_SOURCE_CACHE, sid) && return _SCCODE_SOURCE_CACHE[sid]
    url = "$(_SCCODE_BASE)/$(sid)"
    r = HTTP.get(url; readtimeout = 15, status_exception = false)
    r.status == 200 || throw(error("sccode source HTTP $(r.status) for $url"))
    body = String(r.body)
    # Collect every <pre>…</pre>; the code is in the one that doesn't look
    # like a column of line numbers.
    blocks = String[]
    for m in eachmatch(r"(?s)<pre[^>]*>(.*?)</pre>", body)
        push!(blocks, String(m.captures[1]))
    end
    isempty(blocks) && throw(error("sccode: no <pre> block on $url"))
    # Pick the first block whose stripped form contains a non-digit char.
    code_html = ""
    for b in blocks
        plain = replace(b, r"<[^>]+>" => "")
        if any(c -> !isdigit(c) && !isspace(c), plain)
            code_html = b
            break
        end
    end
    isempty(code_html) && (code_html = blocks[end])
    src = replace(code_html, r"<[^>]+>" => "")
    src = _decode_html_entities(src)
    _SCCODE_SOURCE_CACHE[sid] = src
    return src
end

const _HTML_ENTITY_MAP = Dict(
    "&lt;"   => "<",
    "&gt;"   => ">",
    "&amp;"  => "&",
    "&quot;" => "\"",
    "&apos;" => "'",
    "&#39;"  => "'",
    "&#039;" => "'",
    "&nbsp;" => " ",
)

function _decode_html_entities(s::AbstractString)
    out = String(s)
    for (e, v) in _HTML_ENTITY_MAP
        out = replace(out, e => v)
    end
    out
end

"""
    _sccode_extract_synthdef_name(src) -> Union{String,Nothing}

Pull `\\name` out of `SynthDef(\\name, …)`. Returns nothing if the
source isn't a SynthDef (some sccode snippets are full apps, others
are bare expressions). Used to name the file when saving.
"""
function _sccode_extract_synthdef_name(src::AbstractString)
    m = match(r"SynthDef\s*\(\s*\\(\w+)", src)
    m === nothing && return nothing
    return String(m.captures[1])
end
