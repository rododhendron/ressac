# src/slot_state.jl
# Ce que fait chaque ligne `@dN` — le socle de l'affichage (marge, piste,
# erreur sous la ligne).
#
# Deux questions séparées :
#   • la STRUCTURE du texte : quels blocs `@dN` il contient, où ils
#     commencent et finissent (`_scan_slot_blocks`). Pure, ne dépend que du
#     texte ; c'est aussi ce que lit l'évaluation (`E`).
#   • l'ÉTAT de chaque bloc : joue, muet, modifié, en erreur, à l'arrêt
#     (`_slot_state`). Pure aussi : on lui passe ce que le scheduler joue et
#     ce qui a été évalué.
# La partie qui lit l'app (`_slot_lines(m)`) est dans app_slots.jl.

const _SLOT_HEAD_RX = r"^\s*(#+\s*)?@d(\d+)\b"

"""
Un bloc `@dN` du texte : son slot, ses lignes (`row`..`last_row`), son
source recollé en une expression, et s'il est commenté (= muet).
"""
struct SlotBlock
    slot::Symbol
    row::Int
    last_row::Int
    src::String
    commented::Bool
end

"""
Une évaluation qui a échoué, ou un pattern qui a levé en jouant. `src` est
le texte fautif : l'erreur reste affichée tant que le bloc est ce texte-là.
`kept` dit si un pattern plus ancien joue toujours sur le slot.
"""
struct SlotError
    src::String
    message::String
    kept::Bool
end

"""
L'état d'un bloc, pour l'affichage.

`state` :
  • `:playing`  — le slot joue ce texte ;
  • `:modified` — le slot joue, mais un texte plus ancien ;
  • `:muted`    — bloc commenté, ou slot coupé au mixer ;
  • `:error`    — le texte actuel a échoué (`error` dit pourquoi) ;
  • `:idle`     — rien ne joue pour ce bloc (jamais évalué, arrêté, ou
                  masqué par un bloc du même slot plus bas).
`held` (un drone tient la note) et `offgrid` (lancé hors de la grille)
s'ajoutent à `:playing` / `:modified`. `onsets` : coups du cycle courant.
"""
struct SlotLine
    slot::Symbol
    row::Int
    last_row::Int
    state::Symbol
    held::Bool
    offgrid::Bool
    onsets::Int
    error::Union{Nothing,SlotError}
end

"""
    _scan_slot_blocks(lines) -> (blocks::Vector{SlotBlock}, prelude::Vector{String})

Les blocs `@dN` du texte, dans l'ordre, et tout ce qui n'en est pas
(variables, `cps!`, fonctions…) recollé en expressions : le prélude, évalué
avant les slots pour qu'un `@d1 basse` voie la `basse = p"…"` écrite plus haut.

Un bloc va jusqu'où `_logical_block_range` le mène : les `|>` qui suivent,
une parenthèse ou un crochet resté ouvert.
"""
function _scan_slot_blocks(lines::AbstractVector)
    blocks = SlotBlock[]
    prelude = String[]
    i = 1
    while i <= length(lines)
        line = String(lines[i])
        mt = match(_SLOT_HEAD_RX, line)
        if mt === nothing
            if isempty(strip(line)) || startswith(lstrip(line), "#")
                i += 1
                continue
            end
            (a, b) = _logical_block_range(lines, i)
            b = max(b, i)
            push!(prelude, _join_logical_block(lines[a:b]))
            i = b + 1
            continue
        end
        (_, b) = _logical_block_range(lines, i)
        b = max(b, i)
        push!(blocks, SlotBlock(Symbol("d", mt.captures[2]), i, b,
                                _join_logical_block(lines[i:b]), mt.captures[1] !== nothing))
        i = b + 1
    end
    return (blocks, prelude)
end

"""
    _live_blocks(blocks) -> Dict{Symbol,SlotBlock}

Le bloc qui compte pour chaque slot : le DERNIER non commenté. Un slot écrit
deux fois joue sa définition la plus basse.
"""
function _live_blocks(blocks::AbstractVector{SlotBlock})
    live = Dict{Symbol,SlotBlock}()
    for b in blocks
        b.commented || (live[b.slot] = b)
    end
    return live
end

"""
    _slot_state(block, live; playing, cut, evaluated, error) -> Symbol

L'état d'un bloc. `live` : c'est le bloc qui compte pour son slot.
`playing` : le scheduler a un pattern sur ce slot. `cut` : coupé au mixer.
`evaluated` : le texte de la dernière évaluation réussie (ou `nothing`).
`error` : la dernière erreur du slot (ou `nothing`).
"""
function _slot_state(block::SlotBlock, live::Bool; playing::Bool, cut::Bool,
                     evaluated::Union{Nothing,AbstractString},
                     error::Union{Nothing,SlotError})
    block.commented && return :muted
    live || return :idle
    (error !== nothing && error.src == block.src) && return :error
    cut && return :muted
    playing || return :idle
    (evaluated !== nothing && evaluated != block.src) && return :modified
    return :playing
end

"""
    _note_value(onsets) -> Int

La valeur de note qui dit la vitesse d'un pattern : 1 ronde, 2 blanche,
3 noire, 4 croche, 5 double, 6 triple (0 : aucun coup). Un cycle vaut une
ronde ; entre deux puissances de deux, la plus proche (en rapport).
"""
function _note_value(onsets::Integer)
    onsets <= 0 && return 0
    return clamp(round(Int, log2(onsets)) + 1, 1, 6)
end

"""
    _join_logical_block(rows) -> String

Recolle les lignes d'un bloc en une expression Julia, commentaires retirés. Une ligne de
continuation qui commence par `|>` est accrochée à la précédente par
une espace : Julia lit `@d1 p"bd"` puis `|> gain(1)` comme deux
expressions et échoue, alors que `@d1 p"bd" |> gain(1)` est ce que l'on
veut. Les autres lignes (corps de fonction, tableau multi-ligne)
gardent leur saut de ligne.
"""
function _join_logical_block(rows)
    isempty(rows) && return ""
    out = IOBuffer()
    first_line = true
    for line in rows
        # Les commentaires ne font pas partie de l'expression : celui d'une
        # fin de ligne avalerait le `|>` raccroché derrière lui, et un
        # maillon commenté (`# |> lpf(800)`) est un maillon court-circuité.
        code = rstrip(SynthDSL._split_code_comment(String(line))[1])
        isempty(strip(code)) && continue
        if first_line
            print(out, code)
            first_line = false
        elseif startswith(lstrip(code), "|>")
            print(out, " ", strip(code))
        else
            print(out, "\n", code)
        end
    end
    return String(take!(out))
end

"""
    _delim_depth(s) -> Int

Net depth of unclosed `(`, `[`, `{` minus matching closers in `s`,
skipping string literals and `#` comments. Used by
`_logical_block_range` to detect multi-line expressions even when a
mid-block line on its own would parse as `:error` (which is what
happens for the tail of a multi-line array literal, e.g.
`     collect(37:48), collect(49:60)],`).
And begin/end ?
"""
function _delim_depth(s::AbstractString)
    depth = 0
    in_str = false
    str_char = ' '
    in_cmt = false
    i = firstindex(s)
    n = lastindex(s)
    while i <= n
        c = s[i]
        if in_cmt
            c == '\n' && (in_cmt = false)
        elseif in_str
            if c == '\\' && i < n
                i = nextind(s, i)  # skip escaped char
            elseif c == str_char
                in_str = false
            end
        else
            if c == '#'
                in_cmt = true
            elseif c == '"'
                in_str = true; str_char = '"'
            elseif c == '(' || c == '[' || c == '{'
                depth += 1
            elseif c == ')' || c == ']' || c == '}'
                depth -= 1
            end
        end
        i = nextind(s, i)
    end
    depth = occursin("begin", s) ? depth += 1 : depth
    depth = occursin("end", s) ? depth -= 1 : depth
    depth
end

"""
    _logical_block_range(lines, row) -> (start_row, end_row)

Find the range of lines that form a single logical Julia expression
containing `row`. Walks UP through `|>` continuations and any lines
that leave an open bracket / paren / brace; walks DOWN until those
brackets all close AND the gathered text parses (or we hit EOF).
Comment prefixes (`# ` / `#`) are stripped first so muted blocks have
the same range as their active twin.
"""
function _logical_block_range(lines::AbstractVector, row::Int)
    1 <= row <= length(lines) || return (row, row)
    _strip_cmt(s) = replace(String(s), r"^\s*#+\s*" => "")

    # depths[i] = net delim depth at the START of line i (1-based).
    # Walking up while depths[i] > 0 means "still inside an unclosed
    # bracket from a previous line" — i.e. line i is a continuation.
    stripped = _strip_cmt.(lines)
    depths = zeros(Int, length(lines) + 1)
    for i in 1:length(lines)
        depths[i + 1] = depths[i] + _delim_depth(stripped[i])
    end

    start_row = row
    while start_row > 1
        cur = stripped[start_row]
        if startswith(lstrip(cur), "|>") || depths[start_row] > 0
            start_row -= 1
        else
            break
        end
    end

    end_row = row
    # First close every still-open bracket from start_row's perspective.
    while end_row < length(lines) && depths[end_row + 1] > depths[start_row]
        end_row += 1
    end
    # Then keep extending while the joined block is still parse-incomplete
    # or the next line continues with `|>`.
    while end_row < length(lines)
        block = join(stripped[start_row:end_row], "\n")
        parsed = Meta.parse(block; raise = false)
        is_inc = parsed isa Expr && parsed.head === :incomplete
        next_cont = startswith(lstrip(stripped[end_row + 1]), "|>")
        if is_inc || next_cont
            end_row += 1
        else
            break
        end
    end
    return (start_row, end_row)
end
