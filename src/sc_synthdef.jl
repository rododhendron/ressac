# src/sc_synthdef.jl
# Un SynthDef SuperCollider écrit à la main → le DSL de Ressac. On lit
# les arguments (et leurs défauts), on remplace chaque variable `var`
# par son expression (dans l'ordre, une réaffectation reprend la
# précédente), on isole le signal envoyé à la sortie, et on le remonte
# en génome (sc_expr_parse.jl) pour l'écrire en pipes (render_dsl).

"""
    synthdef_to_dsl(src) -> (name, dsl) | nothing

`nothing` quand `src` ne se convertit pas. [`synthdef_to_dsl_reason`](@ref)
dit pourquoi.
"""
synthdef_to_dsl(src::AbstractString) = first(synthdef_to_dsl_reason(src))

"""
    synthdef_to_dsl_reason(src) -> ((name, dsl) | nothing, raison::String)

Convertit un `SynthDef(\\nom, { |args| … })` en DSL. Quand la sortie ne
s'isole pas, ou que son expression ne se lit pas entièrement, rien n'est
rendu et `raison` dit ce qui a manqué : un SynthDef à moitié compris
donnerait un DSL qui ne sonne pas pareil.
"""
function synthdef_to_dsl_reason(src::AbstractString)
    parsed = parse_synthdef(src)
    parsed === nothing &&
        return (nothing, "pas de SynthDef(\\nom, { |args| … Out.ar(out, …) }) reconnaissable")
    (name, args, expr) = parsed
    controls = Set{Symbol}(keys(args))
    (g, why) = parse_sc_expr(expr, controls)
    g === nothing && return (nothing, why)
    for (k, v) in args
        k in (:out, :pan) && continue
        g.controls[k] = v
    end
    haskey(g.controls, :freq) || (g.controls[:freq] = 220.0)
    haskey(g.controls, :sustain) || (g.controls[:sustain] = 0.5)
    SynthDSL.valid_synth_name(name) || return (nothing, "nom de SynthDef « $name » : pas un identifiant")
    return ((name, render_dsl(g, name)), "")
end

"""
    parse_synthdef(src) -> (name::Symbol, args::Dict{Symbol,Float64}, expr::String) | nothing

Le nom, les arguments numériques (avec leurs défauts, 0 quand absent)
et l'expression SC du signal de sortie, variables inlinées.
"""
function parse_synthdef(src::AbstractString)
    s = replace(String(src), r"//[^\n]*" => "")               # commentaires de ligne
    mt = match(r"SynthDef\s*\(\s*\\(\w+)\s*,\s*\{", s)
    mt === nothing && return nothing
    name = Symbol(mt.captures[1])
    body_start = mt.offset + ncodeunits(mt.match)
    body = _sc_block_body(s, body_start)
    body === nothing && return nothing
    # arguments : |a = 1, b, c = 2| ou arg a = 1, b;
    args = Dict{Symbol,Float64}()
    order = Symbol[]
    rest = body
    ma = match(r"^\s*\|([^|]*)\|", body)
    if ma !== nothing
        for part in split(ma.captures[1], ',')
            kv = split(part, '=')
            nm = strip(kv[1]); isempty(nm) && continue
            v = length(kv) > 1 ? something(tryparse(Float64, strip(kv[2])), 0.0) : 0.0
            args[Symbol(nm)] = v; push!(order, Symbol(nm))
        end
        rest = body[ma.offset + ncodeunits(ma.match):end]
    else
        ma = match(r"^\s*arg\s+([^;]*);", body)
        if ma !== nothing
            for part in split(ma.captures[1], ',')
                kv = split(part, '=')
                nm = strip(kv[1]); isempty(nm) && continue
                v = length(kv) > 1 ? something(tryparse(Float64, strip(kv[2])), 0.0) : 0.0
                args[Symbol(nm)] = v; push!(order, Symbol(nm))
            end
            rest = body[ma.offset + ncodeunits(ma.match):end]
        end
    end
    # instructions séparées par ; (hors parenthèses / accolades)
    stmts = _sc_split_statements(rest)
    vars = Dict{String,String}()
    out_expr = nothing
    for st in stmts
        t = strip(st)
        isempty(t) && continue
        if startswith(t, "var ")
            # `var a = expr, b, c = expr2;` : une déclaration peut porter sa
            # valeur. Chaque `nom = expr` est une affectation comme les autres.
            for decl in _sc_split_top(t[5:end], ',')
                md = match(r"^\s*([A-Za-z_]\w*)\s*=\s*(.*)$"s, decl)
                md === nothing && continue
                vars[String(md.captures[1])] = "(" * _sc_inline_vars(strip(String(md.captures[2])), vars) * ")"
            end
            continue
        end
        mo = match(r"^(?:OffsetOut|Out)\.ar\s*\(", t)
        if mo !== nothing
            inner = _sc_block_body(t, mo.offset + ncodeunits(mo.match); open = '(', close = ')')
            inner === nothing && continue
            parts = _sc_split_top(inner, ',')
            length(parts) >= 2 || continue
            sig = strip(parts[2])
            # DirtPan.ar(sig, n, pan) / Pan2.ar(sig, pan) : le signal est le 1er argument
            mp = match(r"^(?:DirtPan|Pan2|LinPan2|Balance2)\.ar\s*\(", sig)
            if mp !== nothing
                pin = _sc_block_body(sig, mp.offset + ncodeunits(mp.match); open = '(', close = ')')
                pin === nothing || (sig = strip(_sc_split_top(pin, ',')[1]))
            end
            out_expr = _sc_inline_vars(sig, vars)
            continue
        end
        me = match(r"^([A-Za-z_]\w*)\s*=\s*(.*)$"s, t)
        if me !== nothing
            v = String(me.captures[1]); e = strip(String(me.captures[2]))
            vars[v] = "(" * _sc_inline_vars(e, vars) * ")"
        end
    end
    out_expr === nothing && return nothing
    return (name, args, String(out_expr))
end

# Le texte entre l'ouverture (déjà consommée, position `from`) et sa fermeture.
function _sc_block_body(s::AbstractString, from::Int; open::Char = '{', close::Char = '}')
    depth = 1; i = from
    n = lastindex(s)
    while i <= n
        c = s[i]
        c == open && (depth += 1)
        if c == close
            depth -= 1
            depth == 0 && return s[from:prevind(s, i)]
        end
        i = nextind(s, i)
    end
    return nothing
end

# Coupe aux `;` de surface.
_sc_split_statements(s::AbstractString) = _sc_split_top(s, ';')

function _sc_split_top(s::AbstractString, sep::Char)
    out = String[]; depth = 0; start = firstindex(s); i = start
    n = lastindex(s)
    while i <= n
        c = s[i]
        (c == '(' || c == '{' || c == '[') && (depth += 1)
        (c == ')' || c == '}' || c == ']') && (depth -= 1)
        if c == sep && depth == 0
            push!(out, s[start:prevind(s, i)]); start = nextind(s, i)
        end
        i = nextind(s, i)
    end
    push!(out, s[start:end])
    return out
end

# Remplace chaque variable connue par son expression (mots entiers).
function _sc_inline_vars(e::AbstractString, vars::Dict{String,String})
    isempty(vars) && return String(e)
    return replace(String(e), r"(?<![\w.])([A-Za-z_]\w*)(?![\w(])" => (w -> get(vars, w, w)))
end

# ── Tout son s'édite en DSL ──────────────────────────────────────────

# Le texte est-il un SynthDef SuperCollider (et pas du DSL) ?
_is_raw_synthdef(src::AbstractString) = occursin(r"^(?:(?!//).)*SynthDef\s*\("m, src)

"""
    as_dsl(src) -> (texte | nothing, raison)

Le texte d'un son, en DSL. Un `@synth` passe tel quel ; un SynthDef
SuperCollider est converti. Quand il ne se convertit pas en entier, on ne
rend rien et `raison` dit ce qui a manqué — l'éditeur ne montre jamais un
son amputé.
"""
function as_dsl(src::AbstractString)
    _is_raw_synthdef(src) || return (String(src), "")
    (r, why) = synthdef_to_dsl_reason(src)
    r === nothing && return (nothing, why)
    return (r[2], "")
end
