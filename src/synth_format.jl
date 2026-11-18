# src/synth_format.jl
# La mise en forme d'un texte de son, sur le texte lui-même (pas de
# relecture du son : les commentaires et la façon d'écrire sont gardés).
#
#   • les `|>` passent en tête de ligne — un maillon par ligne, qu'on peut
#     alors commenter (`gcc`) pour le court-circuiter, déplacer, supprimer ;
#   • les nombres à queue de décimales sont raccourcis (`_fmt_short`).

_split_code_comment(line::AbstractString) = SynthDSL._split_code_comment(line)

const _LONG_NUMBER_RX = r"(?<![\w.])\d+\.\d{4,}(?:[eE][+-]?\d+)?(?![\w.])"

# Les nombres du code (pas des chaînes ni des commentaires) à plus de trois
# décimales, raccourcis.
function _shorten_numbers(code::AbstractString)
    out = IOBuffer()
    in_str = false
    seg = IOBuffer()
    flush!() = (print(out, replace(String(take!(seg)), _LONG_NUMBER_RX => s -> _fmt_short(parse(Float64, s)))))
    i = firstindex(code)
    while i <= lastindex(code)
        c = code[i]
        if in_str
            print(out, c)
            if c == '\\' && i < lastindex(code)
                i = nextind(code, i); print(out, code[i])
            elseif c == '"'
                in_str = false
            end
        elseif c == '"'
            flush!(); print(out, c); in_str = true
        else
            print(seg, c)
        end
        i = nextind(code, i)
    end
    flush!()
    return String(take!(out))
end

"""
    format_synth_text(text) -> String

Met en forme un texte de son sans le relire : `|>` en tête de ligne,
nombres raccourcis. Idempotent ; commentaires et chaînes intacts.
"""
function format_synth_text(text::AbstractString)
    lines = split(String(text), '\n'; keepempty = true)
    out = String[]
    carry = false                      # la ligne précédente finissait par `|>`
    for raw in lines
        (code, cmt) = _split_code_comment(raw)
        code = _shorten_numbers(code)
        body = rstrip(code)
        if isempty(strip(body))
            push!(out, isempty(cmt) ? String(rstrip(raw)) : rstrip(code * cmt))   # vide ou commentaire : tel quel
            continue
        end
        if carry
            indent = match(r"^\s*", body).match
            body = indent * "|> " * lstrip(body)
            carry = false
        end
        if endswith(body, "|>")
            body = rstrip(body[1:prevind(body, lastindex(body), 2)])
            carry = true
        end
        push!(out, isempty(cmt) ? String(body) : String(body) * (isempty(body) ? "" : "  ") * cmt)
    end
    return join(out, '\n')
end
