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

# Les mots qui ouvrent un bloc que `end` ferme.
const _BLOCK_OPENERS = Set(["begin", "do", "function", "macro", "let", "if", "for", "while",
                            "try", "quote", "struct", "module", "baremodule"])

"""
    _depth_scan(s, brackets = 0) -> (brackets, blocks)

Ce que la ligne `s` ouvre sans le fermer : `brackets` pour `(`, `[`, `{`,
`blocks` pour les mots qui attendent un `end` (`begin`, `do`, `function`…).
Les chaînes et les commentaires sont sautés. `brackets` en entrée est la
profondeur de crochets déjà ouverte par les lignes d'avant : dedans, les
mots ne comptent pas (`a[end]`, `[x for x in xs]` n'ouvrent rien). Un mot
ne compte que s'il est un mot entier : `blend`, `send` et `:end` ne ferment
rien.
"""
function _depth_scan(s::AbstractString, brackets::Int = 0)
    blocks = 0
    in_str = false
    i = firstindex(s)
    n = lastindex(s)
    prev = ' '
    while i <= n
        c = s[i]
        if in_str
            if c == '\\' && i < n
                i = nextind(s, i)  # skip escaped char
            elseif c == '"'
                in_str = false
            end
        elseif c == '#'
            break
        elseif c == '"'
            in_str = true
        elseif c == '(' || c == '[' || c == '{'
            brackets += 1
        elseif c == ')' || c == ']' || c == '}'
            brackets -= 1
        elseif (isletter(c) || c == '_') && !(isletter(prev) || isdigit(prev) || prev in ('_', '!', ':', '.', '@'))
            j = i
            while j < n && (k = nextind(s, j); isletter(s[k]) || isdigit(s[k]) || s[k] in ('_', '!'))
                j = k
            end
            if brackets <= 0
                word = SubString(s, i, j)
                word in _BLOCK_OPENERS ? (blocks += 1) : word == "end" ? (blocks -= 1) : nothing
            end
            prev = s[j]
            i = nextind(s, j)
            continue
        end
        prev = c
        i = nextind(s, i)
    end
    return (brackets, blocks)
end

"""
    _delim_depth(s) -> Int

Ce que `s` laisse ouvert en tout : crochets et blocs (`_depth_scan`).
"""
_delim_depth(s::AbstractString) = sum(_depth_scan(s))

# La ligne finit-elle sur un `|>` qui attend sa suite ?
_ends_with_pipe(s::AbstractString) = endswith(rstrip(SynthDSL._split_code_comment(String(s))[1]), "|>")

"""
    _logical_block_range(lines, row) -> (start_row, end_row)

Les lignes qui forment, avec `row`, une seule expression : on remonte tant
que la ligne commence par `|>`, que la précédente finit par `|>`, ou qu'un
crochet ou un bloc (`begin … end`, `do … end`) ouvert plus haut n'est pas
fermé ; on descend jusqu'à ce que tout soit fermé et que le texte se lise.
Les préfixes de commentaire (`# `) sont retirés d'abord : un bloc coupé a
la même étendue que son jumeau actif. C'est LA fonction qui dit où
commence et finit un bloc — `e`, `m`, `gc`, les slots, les variations.
"""
function _logical_block_range(lines::AbstractVector, row::Int)
    1 <= row <= length(lines) || return (row, row)
    _strip_cmt(s) = replace(String(s), r"^\s*#+\s*" => "")

    # depths[i] : ce qui est ouvert au DÉBUT de la ligne i. Une ligne `@dN`
    # en première colonne commence toujours un bloc : la profondeur y
    # repart de zéro, pour qu'une faute plus haut dans le texte (un `end`
    # en trop, une parenthèse oubliée) ne décale pas tout ce qui suit.
    stripped = _strip_cmt.(lines)
    depths = zeros(Int, length(lines) + 1)
    br = 0; bl = 0
    for i in 1:length(lines)
        if occursin(_SLOT_HEAD_RX, stripped[i]) && !isspace(first(String(lines[i])))
            br = 0; bl = 0
            depths[i] = 0
        end
        (br, dbl) = _depth_scan(stripped[i], br)
        bl += dbl
        (br < 0 || bl < 0) && (br = max(br, 0); bl = max(bl, 0))    # un fermant de trop n'ouvre rien
        depths[i + 1] = br + bl
    end

    start_row = row
    while start_row > 1
        cur = stripped[start_row]
        if startswith(lstrip(cur), "|>") || depths[start_row] > 0 || _ends_with_pipe(stripped[start_row - 1])
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
