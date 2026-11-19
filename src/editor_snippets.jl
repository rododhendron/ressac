# Space-leader snippet expansion + placeholder navigation.
#
# Workflow: in normal mode, Space → trigger char → template expands at
# cursor with the cursor on $1, editor auto-enters insert. Tab jumps
# to $2 / $3 / … (Shift-Tab goes back). Esc exits placeholder mode
# and falls back to standard insert→normal on the second press.
#
# Extracted from app.jl. The model fields driving this (pending_leader,
# placeholder_active, placeholder_row, placeholder_cols, placeholder_idx)
# stay on RessacApp.

"""
Une entrée du menu Espace : la touche, ce qu'elle écrit (`\$N` = arrêts de
Tab, sur une seule ligne), son nom et sa colonne dans le menu.
"""
struct LeaderSnippet
    key::Char
    template::String
    label::String
    column::String
end

# La table d'origine vit dans un fichier de données, pas dans le code.
const _LEADER_FILE = joinpath(dirname(@__DIR__), "plugins", "core", "leader.toml")
include_dependency(_LEADER_FILE)

"""
    _read_leader_file(path; column = "") -> Vector{LeaderSnippet}

Les `[[snippet]]` d'un `leader.toml`. Une entrée mal formée (touche de
plus d'un caractère, texte vide, sur plusieurs lignes) est laissée de côté
avec un avertissement : elle ne coûte qu'elle-même.
"""
function _read_leader_file(path::AbstractString; column::AbstractString = "")
    out = LeaderSnippet[]
    isfile(path) || return out
    data = try TOML.parsefile(path) catch err
        @warn "leader.toml illisible" path err
        return out
    end
    for e in get(data, "snippet", Any[])
        e isa AbstractDict || continue
        key = String(get(e, "key", "")); tpl = String(get(e, "template", ""))
        if length(key) != 1 || isspace(first(key)) || isempty(strip(tpl)) || occursin('\n', tpl)
            @warn "leader.toml : entrée ignorée (une touche d'un caractère, un texte d'une ligne)" path key
            continue
        end
        label = String(get(e, "label", "")); isempty(label) && (label = first(tpl, 28))
        col = String(get(e, "column", "")); isempty(col) && (col = String(column))
        push!(out, LeaderSnippet(first(key), tpl, label, col))
    end
    return out
end

const _LEADER_BASE = _read_leader_file(_LEADER_FILE)
# Ce que le joueur a ajouté ou changé (son `leader.toml`) : passe devant.
const _LEADER_USER = LeaderSnippet[]
const _LEADER_USER_COLUMN = "À TOI"

"""
    _LEADER_SNIPPETS

Touche → texte, la table en vigueur (celle d'origine, puis celle du
joueur par-dessus). Tenue à jour par `_leader_rebuild!`.
"""
const _LEADER_SNIPPETS = Dict{Char,String}(s.key => s.template for s in _LEADER_BASE)

"""
    _LEADER_ACTIONS

Triggers that fire a callback instead of expanding text — useful
for opening pickers / modals. `Space b` → browser, `Space ?` →
guide, etc. Resolved before `_LEADER_SNIPPETS` so they take
priority on the same char.
"""
const _LEADER_ACTIONS = Dict{Char,Function}(
    'b' => m -> _open_browser!(m),       # all sounds (samples + insts + synths)
    'L' => m -> _open_synth_library!(m), # synth library
    '?' => m -> _open_help!(m),
    'w' => m -> _open_wiki!(m),
    'I' => m -> _open_snippets!(m),      # I for "insert snippet" picker
    'P' => m -> _open_patterns_modal!(m),  # P comme patterns rangés
    'k' => m -> _keep_prompt!(m),          # k comme keep : ranger la ligne
    'o' => m -> _loop_open!(m),            # o comme une boucle : frapper un motif libre
    'V' => m -> _open_evolve_modal!(m),    # V comme variations
)

# Les entrées du menu qui ouvrent quelque chose au lieu d'écrire : la
# touche, son nom, sa colonne. (Leur action est dans `_LEADER_ACTIONS`.)
const _LEADER_ACTION_LABELS = [
    ('b', "▸ sons (samples, instruments, synths)", "OUVRIR"), ('L', "▸ sons rangés (réserve)", "OUVRIR"),
    ('P', "▸ motifs rangés (réserve)", "OUVRIR"), ('I', "▸ recettes (réserve)", "OUVRIR"),
    ('V', "▸ variations du bloc", "OUVRIR"), ('w', "▸ wiki", "OUVRIR"), ('?', "▸ aide", "OUVRIR"),
    ('k', "ranger la ligne @dN dans la réserve", "FAIRE"),
    ('o', "boucle : frapper un motif, de la longueur qu'on veut", "FAIRE"),
]

"""
    _LEADER_LABELS

Touche → nom, pour tout ce que le menu Espace connaît (textes et actions),
dans l'ordre d'affichage. Tenue à jour par `_leader_rebuild!`.
"""
const _LEADER_LABELS = Pair{Char,String}[]

_leader_user_path() = joinpath(_config_dir(), "leader.toml")

"""
    _parse_snippet_template(tpl) -> (text::String, placeholder_cols::Vector{Int})

Strip `\$N` markers and return the bare text plus the column
positions (0-based, relative to text start) where each placeholder
ends up. Markers must be `\$` followed by a single digit.
"""
function _parse_snippet_template(tpl::AbstractString)
    out = IOBuffer()
    cols = Tuple{Int,Int}[]  # (placeholder_idx, col_in_text)
    i = firstindex(tpl)
    col = 0
    while i <= ncodeunits(tpl)
        c = tpl[i]
        if c == '$' && i < ncodeunits(tpl) && isdigit(tpl[i+1])
            n = parse(Int, string(tpl[i+1]))
            push!(cols, (n, col))
            i = nextind(tpl, i, 2)
        else
            print(out, c)
            col += 1
            i = nextind(tpl, i)
        end
    end
    sort!(cols; by = first)
    return (String(take!(out)), [c for (_, c) in cols])
end

"""
    _expand_snippet!(m, ed, template)

Insert `template`'s text at the cursor, record placeholder positions,
move the cursor onto the first one, and switch to insert mode with
placeholder tracking armed. Templates without placeholders just get
inserted and we stay in normal mode (no nav needed).
"""
function _expand_snippet!(m::RessacApp, ed::TK.CodeEditor, template::AbstractString)
    text, ph_offsets = _parse_snippet_template(template)
    row = ed.cursor_row
    col = ed.cursor_col
    1 <= row <= length(ed.lines) || return
    lines = collect(String, split(TK.text(ed), '\n'; keepempty = true))
    kind = _snippet_kind(template)
    if kind === :chain && !isempty(strip(lines[row]))
        # Maillon `|> …` : en fin de ligne du bloc (après ses lignes `|>`).
        row = _block_end_row(lines, row)
        base = rstrip(lines[row])
        lines[row] = base * " " * text
        col = length(base) + 1
    elseif kind === :block && !isempty(strip(lines[row]))
        # Ligne complète `@dN …` : sur une nouvelle ligne sous le bloc.
        row = _block_end_row(lines, row) + 1
        insert!(lines, row, text)
        col = 0
    else
        line = lines[row]
        lines[row] = _take_chars(line, col) * text * _drop_chars(line, col)
    end
    _edit_text!(ed, join(lines, '\n'))
    ed.cursor_row = row
    if isempty(ph_offsets)
        ed.cursor_col = col + length(text)
        return
    end
    # Absolute placeholder columns = insert column + relative offset.
    m.placeholder_row    = row
    m.placeholder_cols   = [col + off for off in ph_offsets]
    m.placeholder_idx    = 1
    m.placeholder_active = true
    m.transient_ed       = ed
    ed.cursor_col = m.placeholder_cols[1]
    # On reste en mode NORMAL : Tab / Maj-Tab sautent entre les trous, `i`
    # remplit, `u` annule tout de suite si le snippet ne convient pas.
    ed.mode = :normal
end

# Nature d'un modèle : maillon de chaîne, ligne complète, ou fragment.
_snippet_kind(tpl::AbstractString) =
    startswith(tpl, "|>") ? :chain : startswith(tpl, "@d") ? :block : :inline

# Dernière ligne du bloc commencé en `row` : les lignes `|>` qui suivent.
function _block_end_row(lines::Vector{String}, row::Int)
    r = row
    while r < length(lines) && startswith(lstrip(lines[r + 1]), "|>")
        r += 1
    end
    return r
end


"""
    _next_free_slot(ed) -> Int

Premier numéro `@dN` absent du buffer (lignes commentées comprises).
"""
function _next_free_slot(ed::TK.CodeEditor)
    used = Set{Int}()
    for l in ed.lines
        mt = match(r"^\s*(?:#+\s*)?@d(\d+)\b", String(l))
        mt === nothing || push!(used, parse(Int, mt.captures[1]))
    end
    n = 1
    while n in used; n += 1; end
    return n
end

"""
    _prefill_slot(tpl, ed) -> String

`@d\$1 …` devient `@d3 …` avec le premier slot libre, les autres trous
sont renumérotés : le curseur tombe directement dans le pattern.
"""
function _prefill_slot(tpl::AbstractString, ed::TK.CodeEditor)
    occursin("@d\$1", tpl) || return String(tpl)
    out = replace(tpl, "@d\$1" => "@d$(_next_free_slot(ed))")
    return replace(out, r"\$(\d)" => x -> "\$" * string(parse(Int, x[2:end]) - 1))
end

"""
    _placeholder_jump!(m, ed, dir)

Move to the next (`dir = +1`) or previous (`dir = -1`) placeholder.
Going past the last placeholder exits placeholder mode (stays in
insert so the user can keep typing).
"""
function _placeholder_jump!(m::RessacApp, ed::TK.CodeEditor, dir::Int)
    m.placeholder_active || return false
    # La ligne des trous a pu disparaître (un `dd` entre deux Tab).
    if !(1 <= m.placeholder_row <= length(ed.lines))
        m.placeholder_active = false
        return true
    end
    new_idx = m.placeholder_idx + dir
    if new_idx < 1 || new_idx > length(m.placeholder_cols)
        m.placeholder_active = false
        return true
    end
    m.placeholder_idx = new_idx
    ed.cursor_row = m.placeholder_row
    ed.cursor_col = clamp(m.placeholder_cols[new_idx], 0, length(ed.lines[m.placeholder_row]))
    return true
end

"""
    _placeholder_track_change!(m, ed, pre_len)

Called after a buffer-modifying key in insert mode while
`placeholder_active`. Adjusts all placeholder columns after the
cursor by the delta `(post_len - pre_len)` so they stay aligned as
the user fills in text. Also deactivates if the user moved to a
different row.
"""
function _placeholder_track_change!(m::RessacApp, ed::TK.CodeEditor, pre_len::Int)
    m.placeholder_active || return
    if ed.cursor_row != m.placeholder_row
        m.placeholder_active = false; return
    end
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || (m.placeholder_active = false; return)
    post_len = length(ed.lines[row])
    delta = post_len - pre_len
    delta == 0 && return
    cur = ed.cursor_col
    # Shift placeholders that sit at or after the cursor by delta.
    # Don't move the placeholder the user is currently filling — only
    # the ones AHEAD so they don't slide under typed text.
    for i in eachindex(m.placeholder_cols)
        i == m.placeholder_idx && continue
        if m.placeholder_cols[i] >= cur
            m.placeholder_cols[i] += delta
        end
    end
end
