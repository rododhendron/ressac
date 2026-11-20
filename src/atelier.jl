# src/atelier.jl
# L'atelier : travailler la structure d'un son sans quitter son texte.
#
# Le texte EST le graphe du son : un maillon par ligne, de haut en bas. Les
# gestes sont ceux de vim, plus trois choses que vim n'a pas.
#
#   o / O     un maillon après / avant celui du curseur : une liste de ce
#             qui a un sens à cet endroit, chaque proposition S'ENTEND
#   cim       remplacer le maillon : la même liste, ses cousins d'abord
#   &         le reste — faire bouger un nombre, en faire un argument du
#             son, écouter le son jusqu'ici, bifurquer (une copie du son)
#
# Rien n'est écrit dans le texte tant qu'on n'a pas choisi : ce qu'on entend
# est un essai. `Entrée` garde (un seul `u` annule), `Échap` ne change rien.

# ── Ce qu'on peut proposer ───────────────────────────────────────────

# Un défaut du catalogue, écrit comme à la main : `1200`, `0.3`.
_atelier_num(v::Real) = isinteger(v) ? string(Int(v)) : _fmt_short(Float64(v))

# Les maillons du DSL qui n'ont pas d'UGen à eux dans le catalogue.
const _ATELIER_EXTRA = [
    ("env_perc",   "env_perc(0.01, :sustain)",            "enveloppe percussive : attaque sèche, puis ça retombe", :env),
    ("env_linen",  "env_linen(0.01, :sustain, 0.1)",      "enveloppe attaque · tenue · relâche",                   :env),
    ("env_adsr",   "env_adsr(0.01, 0.2, 0.6, :sustain)",  "enveloppe ADSR",                                         :env),
    ("tanh_drive", "tanh_drive(2)",                       "saturation douce : épaissit, arrondit les crêtes",       :math),
    ("amp",        "amp(0.5)",                            "amplitude : plus ou moins fort",                         :math),
    ("chorus",     "chorus()",                            "chorus : épaissit, fait flotter",                        :fx),
    ("phaser",     "phaser()",                            "phaser : des creux qui balaient le spectre",             :fx),
]

"""
    _atelier_catalog(position) -> Vector{AtelierItem}

Ce qui peut s'écrire à une place : `:stage` un maillon (un filtre, un effet,
une enveloppe…), `:source` une source. Chacun avec les réglages par défaut
du catalogue, pour qu'il sonne tout de suite.
"""
function _atelier_catalog(position::Symbol)
    out = AtelierItem[]
    table = position === :source ? _DSL_SOURCES : _DSL_STAGES
    for (u, (fn, idxs)) in table
        spec = ugen_spec(u)
        spec === nothing && continue
        isdefined(SynthDSL, Symbol(fn)) || continue
        u === :Tanh && continue                               # tanh_drive(k) : dans la liste à la main
        (position === :source && (u === :Line || u === :XLine || u === :SinOscKR)) && continue   # des modulateurs
        args = String[]
        for i in idxs
            i <= length(spec.slots) || continue
            sl = spec.slots[i]
            push!(args, sl.name === :freq && position === :source ? ":freq" : _atelier_num(sl.default))
        end
        push!(out, AtelierItem(fn, "$fn($(join(args, ", ")))", get(_UGEN_DESC, u, String(u)), spec.role))
    end
    if position === :stage
        for (name, code, desc, role) in _ATELIER_EXTRA
            isdefined(SynthDSL, Symbol(name)) && push!(out, AtelierItem(name, code, desc, role))
        end
    end
    return sort!(out; by = it -> it.name)
end

# Le rôle du maillon nommé `name` (pour proposer ses cousins d'abord).
function _atelier_role(name::AbstractString)
    for table in (_DSL_STAGES, _DSL_SOURCES), (u, (fn, _)) in table
        fn == name || continue
        spec = ugen_spec(u)
        spec === nothing || return spec.role
    end
    i = findfirst(x -> x[1] == name, _ATELIER_EXTRA)
    return i === nothing ? :none : _ATELIER_EXTRA[i][4]
end

# ── Ouvrir ───────────────────────────────────────────────────────────

"""
    _atelier_open!(m, action) -> Bool

Ouvre l'atelier sur le maillon du curseur du son courant. `action` :
`:after` (`o`), `:before` (`O`) ou `:replace` (`cim`).
"""
function _atelier_open!(m::RessacApp, action::Symbol)
    tab = _sound_under_cursor(m)
    if tab === nothing
        _push_app_log!(m, "[INFO] l'atelier travaille le texte d'un son — gs sur son nom l'amène dans le texte")
        return false
    end
    ed = tab.code_editor
    row = ed.cursor_row
    link = _link_at(ed)
    if link === nothing
        _push_app_log!(m, "[INFO] pose le curseur sur un maillon (une ligne `|> …`, ou la source)")
        return false
    end
    if action !== :replace && !link.linewise
        # Plusieurs maillons sur la ligne : elle est d'abord mise à un maillon
        # par ligne (ce que fait `:format`), et le curseur suit son maillon.
        k = something(findfirst(l -> l.inner == link.inner, _line_links(ed.lines[row], row)), 1)
        pieces = _split_links(String(ed.lines[row]))
        if length(pieces) < 2
            _push_app_log!(m, "[INFO] plusieurs maillons sur cette ligne — :format en met un par ligne, puis o / O")
            return false
        end
        lines = [String(l) for l in ed.lines]
        splice!(lines, row, pieces)
        row += clamp(k, 1, length(pieces)) - 1
        _edit_text!(ed, join(lines, '\n'); row = row, col = something(findfirst(!isspace, lines[row]), 1) - 1)
        link = _link_at(ed)
        link === nothing && return false
    end
    if action === :before && !link.piped
        _push_app_log!(m, "[INFO] rien ne vient avant la source — cim la remplace, o ajoute un maillon après")
        return false
    end
    position = (action === :replace && !link.piped) ? :source : :stage
    items = _atelier_catalog(position)
    if action === :replace
        role = _atelier_role(link.name)
        # Les cousins d'abord (même rôle), l'original en tête pour pouvoir y revenir à l'oreille.
        sort!(items; by = it -> (it.name == link.name ? 0 : it.role === role ? 1 : 2, it.name))
    end
    m.atelier = AtelierState(tab, [String(l) for l in ed.lines], row, action, link, items, "")
    _open_modal!(m, :atelier)
    _picker_reset!(m.at_pk); _picker_search!(m.at_pk, true)       # on tape pour filtrer, comme une complétion
    return true
end

function _atelier_entries(m::RessacApp)
    st = m.atelier
    st === nothing && return AtelierItem[]
    q = _picker_query(m.at_pk)
    isempty(q) && return st.items
    ql = lowercase(q)
    hits = filter(it -> _fuzzy_score(q, it.name) !== nothing || occursin(ql, lowercase(it.desc)), st.items)
    return sort!(hits; by = it -> (startswith(it.name, ql) ? 0 : 1))
end

function _atelier_sync!(m::RessacApp, width::Int = 60)
    items = _atelier_entries(m)
    rows = [TK.ListItem(first(rpad(it.name, 14) * " " * it.desc, width)) for it in items]
    _picker_set!(m.at_pk, rows, items)
    return items
end

_atelier_cur(m::RessacApp) = (_atelier_sync!(m); _picker_selected(m.at_pk))

# ── Le texte essayé ──────────────────────────────────────────────────

"""
    _atelier_text(st, item) -> (lines, row, col)

Le texte du son avec la proposition `item` à sa place, et où poser le
curseur ensuite (sur son premier réglage).
"""
function _atelier_text(st::AtelierState, item::AtelierItem)
    lines = copy(st.base)
    link = st.link
    row = st.row
    indent = String(match(r"^\s*", lines[row]).match)
    if st.action === :replace
        chars = collect(lines[row])
        lines[row] = String(vcat(chars[1:(first(link.inner) - 1)], collect(item.code), chars[(last(link.inner) + 1):end]))
        col = first(link.inner) - 1
    else
        new_row = st.action === :after ? row + 1 : row
        # Sous une ligne `@synth …`, le maillon se range un cran plus loin.
        occursin(r"^\s*@synth\b", lines[row]) && (indent *= "  ")
        insert!(lines, new_row, indent * "|> " * item.code)
        row = new_row
        col = length(indent) + 3
    end
    # Le curseur sur le premier réglage, s'il y en a un.
    open = findnext('(', lines[row], col + 1)
    inside = open !== nothing && open < lastindex(lines[row]) && lines[row][nextind(lines[row], open)] != ')'
    col = inside ? length(lines[row], 1, open) : col
    return (lines, row, col)
end

# Fait entendre la proposition du curseur — une fois par proposition.
function _atelier_hear!(m::RessacApp; force::Bool = false)
    st = m.atelier
    st === nothing && return
    item = _atelier_cur(m)
    item === nothing && return
    (!force && st.heard == item.code) && return
    st.heard = item.code
    (lines, row, _) = _atelier_text(st, item)
    _audition_synth_text!(m, st.tab, _sound_text_in(lines, row); what = "essai · $(item.name) dans")
    return
end

"""
    _atelier_accept!(m)

Garde la proposition : elle s'écrit dans le texte (un seul `u` l'annule) et
le curseur se pose sur son premier réglage.
"""
function _atelier_accept!(m::RessacApp)
    st = m.atelier
    item = st === nothing ? nothing : _atelier_cur(m)
    m.modal = :none
    m.atelier = nothing
    item === nothing && return
    (lines, row, col) = _atelier_text(st, item)
    ed = st.tab.code_editor
    _edit_text!(ed, join(lines, '\n'); row = row, col = col)
    ed.mode = :normal
    _push_app_log!(m, "[INFO] $(item.name) gardé — + - * / ou la molette règlent ses nombres, u annule")
    return
end

# Échap : rien n'a été écrit ; on refait entendre le son tel qu'il est.
function _atelier_cancel!(m::RessacApp)
    st = m.atelier
    m.modal = :none
    m.atelier = nothing
    (st === nothing || isempty(st.heard)) && return
    _audition_synth_text!(m, st.tab, _sound_text_in(st.base, st.row); what = "retour à")
    return
end

function _handle_atelier_key!(m::RessacApp, evt::TK.KeyEvent)
    pk = m.at_pk
    evt.action === TK.key_press || return
    if evt.key === :escape
        _atelier_cancel!(m)
    elseif evt.key === :enter
        _atelier_accept!(m)
    elseif evt.key === :down || evt.key === :tab || (evt.key === :ctrl && evt.char == 'n')
        _atelier_sync!(m); _picker_nav!(pk, :down); _atelier_hear!(m)
    elseif evt.key === :up || evt.key === :backtab || (evt.key === :ctrl && evt.char == 'p')
        _atelier_sync!(m); _picker_nav!(pk, :up); _atelier_hear!(m)
    elseif evt.key === :char && evt.char == ' ' && isempty(_picker_query(pk))
        _atelier_hear!(m; force = true)                     # réécouter
    else
        _picker_type!(pk, evt)
        _atelier_sync!(m)
    end
    return
end

function _render_atelier_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    st = m.atelier
    st === nothing && (m.modal = :none; return)
    where_ = st.action === :after ? "après $(st.link.name)" :
             st.action === :before ? "avant $(st.link.name)" : "à la place de $(st.link.name)"
    inner = _render_modal_block!(buf, area;
        title = "ATELIER · $(st.tab.name) — $where_",
        title_right = "↑ ↓ essayer · Entrée garder · Échap rien ne change",
        w_max = 96,
        h_target = max(12, min(area.height - 4, 18)))
    inner.width < 24 && return
    items = _atelier_sync!(m, inner.width - 3)
    _picker_render_input!(m.at_pk, TK.Rect(inner.x, inner.y, inner.width, 1), buf;
                          right_text = "$(length(items))", hint = "tape pour filtrer")
    if isempty(items)
        TK.set_string!(buf, inner.x, inner.y + 2, first("Rien de ce nom. Échap, puis écris-le à la main.", inner.width),
                       TK.tstyle(:text_dim))
        return
    end
    list_h = inner.height - 3
    _picker_render_list!(m.at_pk, TK.Rect(inner.x, inner.y + 1, inner.width, list_h), buf)
    # Ce qui s'écrira si on garde.
    item = _picker_selected(m.at_pk)
    if item !== nothing
        (lines, row, _) = _atelier_text(st, item)
        y = inner.y + inner.height - 1
        TK.set_string!(buf, inner.x, y - 1, repeat('─', inner.width), TK.tstyle(:border))
        _md_draw_line!(buf, inner.x, y, _md_code_line(strip(lines[row]), inner.width), inner.width)
    end
end

scope!(:modal_atelier, "Atelier (o · O · cim dans un son)"; layer = :modal, modes = (:design,))
bind!(:modal_atelier, ["↓", "↑"], "essayer la proposition suivante / précédente — elle s'entend"; group = :audio)
bind!(:modal_atelier, "Enter", "garder"; group = :edit)
bind!(:modal_atelier, "Esc", "fermer : rien n'a changé"; group = :nav)
bind!(:modal_atelier, "Space", "réécouter (quand la recherche est vide)"; group = :audio, hint = false)

# ── `&` : ce que vim n'a pas ─────────────────────────────────────────

# `&` déjà pressé : la touche suivante choisit (le registre, préfixe « & »).
function _atelier_prefix_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return true
    evt.key === :escape && (m.pending_atelier = false; return true)
    (evt.key !== :char || evt.char == '\0') && return true
    m.pending_atelier = false
    return false
end

# Le son qui contient `row` est-il un bloc `begin … end` (où une ligne nommée
# peut s'écrire) ? Rend ses lignes d'en-tête et de fin.
function _synth_block_rows(lines::AbstractVector, row::Int)
    b = _sound_block_at(lines, row)
    b === nothing && return nothing
    head = SynthDSL._split_code_comment(String(lines[b.row]))[1]
    (occursin(r"\b(begin|do\s+\w+)\s*$", head) && b.last_row > b.row &&
     occursin(r"^\s*end\b", String(lines[b.last_row]))) || return nothing
    return (b.row, b.last_row)
end

# Un nom libre dans le texte : `mod`, `mod2`, `mod3`…
function _free_name(text::AbstractString, base::AbstractString)
    taken(n) = occursin(Regex("(?<![\\w])" * n * "(?![\\w])"), text)
    taken(base) || return String(base)
    k = 2
    while taken("$base$k"); k += 1; end
    return "$base$k"
end

# Le nombre sous le curseur du son courant — (onglet, éditeur, (premier
# caractère, dernier caractère, texte)) — ou `nothing` (avec le message).
function _atelier_number(m::RessacApp, what::AbstractString)
    tab = _sound_under_cursor(m)
    tab === nothing &&
        (_push_app_log!(m, "[INFO] & $what — dans le texte d'un son, le curseur sur un nombre"); return nothing)
    ed = tab.code_editor
    hit = _number_at(ed, ed.cursor_row, ed.cursor_col)
    hit === nothing && (_push_app_log!(m, "[INFO] & $what — pose le curseur sur un nombre"); return nothing)
    # `_number_at` compte depuis 0, fin exclue ; ici : du premier au dernier caractère.
    return (tab, ed, (hit[1] + 1, hit[2], hit[3]))
end

"""
    _atelier_modulate!(m)

`& m` — le nombre sous le curseur se met à bouger : un LFO lent autour de sa
valeur, écrit sur une ligne NOMMÉE au-dessus de la chaîne, et le nombre
devient ce nom. (Imbriqué sur place, deux fois de suite, le texte ne se
lirait plus.)
"""
function _atelier_modulate!(m::RessacApp)
    r = _atelier_number(m, "m")
    r === nothing && return
    (tab, ed, (c1, c2, txt)) = r
    lines = [String(l) for l in ed.lines]
    block = _synth_block_rows(lines, ed.cursor_row)
    if block === nothing
        _push_app_log!(m, "[INFO] & m — le son doit s'écrire dans un `begin … end` pour y nommer une ligne")
        return
    end
    v = parse(Float64, txt)
    v == 0 && (_push_app_log!(m, "[INFO] & m — un nombre nul n'a pas d'« autour » : change-le d'abord"); return)
    name = _free_name(_sound_text(tab), "mod")
    (lo, hi) = minmax(v * 0.7, v * 1.3)
    row = ed.cursor_row
    chars = collect(lines[row])
    lines[row] = String(vcat(chars[1:(c1 - 1)], collect(name), chars[(c2 + 1):end]))
    indent = String(match(r"^\s*", lines[block[1] + 1]).match)
    insert!(lines, block[1] + 1, "$(indent)$name = lfo(1; low = $(_atelier_num(lo)), high = $(_atelier_num(hi)))")
    _edit_text!(ed, join(lines, '\n'); row = block[1] + 1, col = length(indent) + length(name) + 7)
    _push_app_log!(m, "[INFO] $txt bouge maintenant : $name, un LFO de $(_atelier_num(lo)) à $(_atelier_num(hi)) — règle sa vitesse, T écoute, u annule")
    return
end

# Le nom de la place du nombre dans l'appel qui l'entoure (« rq », « freq »), ou "".
_slot_name_at(chars::Vector{Char}, col1::Int) =
    (sl = _slot_at(chars, col1); sl === nothing ? "" : String(sl.name))

# La place du catalogue (nom, bornes) qu'occupe le caractère `col1` dans
# l'appel qui l'entoure, ou `nothing`.
function _slot_at(chars::Vector{Char}, col1::Int)
    fn = _enclosing_call(chars, col1 - 1)
    isempty(fn) && return nothing
    # La position du nombre parmi les arguments de l'appel.
    depth = 0; k = 1; i = col1 - 1
    while i >= 1
        c = chars[i]
        c == ')' && (depth += 1)
        if c == '('
            depth == 0 && break
            depth -= 1
        end
        (c == ',' && depth == 0) && (k += 1)
        i -= 1
    end
    for (table, piped) in ((_DSL_STAGES, true), (_DSL_SOURCES, false)), (u, (name, idxs)) in table
        name == fn || continue
        spec = ugen_spec(u)
        spec === nothing && continue
        # En pipe le signal n'est pas écrit : l'argument k est la place idxs[k].
        # En forme directe (`rlpf(sig, 800, 0.3)`) il est le premier.
        j = (piped && _piped_call(chars, i)) || !piped ? k : k - 1
        (1 <= j <= length(idxs) && idxs[j] <= length(spec.slots)) && return spec.slots[idxs[j]]
    end
    return nothing
end

# L'appel qui s'ouvre en `open_paren` est-il un maillon (précédé d'un `|>`) ?
function _piped_call(chars::Vector{Char}, open_paren::Int)
    i = open_paren - 1
    while i >= 1 && (isletter(chars[i]) || isdigit(chars[i]) || chars[i] == '_'); i -= 1; end
    while i >= 1 && isspace(chars[i]); i -= 1; end
    return i >= 2 && chars[i] == '>' && chars[i - 1] == '|'
end

"""
    _atelier_to_argument!(m)

`& k` — le nombre sous le curseur devient un argument du son : il sort dans
l'en-tête du `@synth` avec sa valeur, et un pattern peut alors le faire
bouger (`|> set(:nom, "<…>")`, ou un drone).
"""
function _atelier_to_argument!(m::RessacApp)
    r = _atelier_number(m, "k")
    r === nothing && return
    (tab, ed, (c1, c2, txt)) = r
    lines = [String(l) for l in ed.lines]
    here = _sound_block_at(lines, ed.cursor_row)
    head = (here !== nothing && occursin(r"^\s*@synth\s+:\w+\s*\(", lines[here.row])) ? here.row : nothing
    head === nothing && (_push_app_log!(m, "[INFO] & k — pas d'en-tête `@synth :nom (…)` où déclarer l'argument"); return)
    row = ed.cursor_row
    row == head && (_push_app_log!(m, "[INFO] & k — c'est déjà un argument du son"); return)
    chars = collect(lines[row])
    base = _slot_name_at(chars, c1)
    isempty(base) && (base = "k")
    name = _free_name(_sound_text(tab), base)
    lines[row] = String(vcat(chars[1:(c1 - 1)], collect(":" * name), chars[(c2 + 1):end]))
    # L'en-tête : `@synth :nom (a=1, b=2)` → `(a=1, b=2, nom=valeur)`.
    hl = lines[head]
    open = findfirst('(', hl)
    close = findnext(')', hl, open)
    close === nothing && (_push_app_log!(m, "[INFO] & k — l'en-tête du @synth tient sur plusieurs lignes : déclare `$name=$txt` à la main"); return)
    inside = strip(hl[nextind(hl, open):prevind(hl, close)])
    sep = isempty(inside) ? "" : (endswith(inside, ",") ? " " : ", ")
    lines[head] = hl[1:prevind(hl, close)] * sep * "$name=$txt" * hl[close:end]
    _edit_text!(ed, join(lines, '\n'); row = row, col = c1)
    _push_app_log!(m, "[INFO] $txt est maintenant l'argument :$name — un pattern peut le faire bouger, u annule")
    return
end

"""
    _atelier_solo!(m)

`& s` — fait entendre le son jusqu'au maillon du curseur, sans la suite :
pour savoir ce que chaque étape apporte.
"""
function _atelier_solo!(m::RessacApp)
    tab = _sound_under_cursor(m)
    tab === nothing && return
    ed = tab.code_editor
    lines = [String(l) for l in ed.lines]
    block = _synth_block_rows(lines, ed.cursor_row)
    link = _link_at(ed)
    if block === nothing || link === nothing || !link.linewise || !(block[1] < ed.cursor_row < block[2])
        _push_app_log!(m, "[INFO] & s — sur un maillon d'un son écrit un par ligne, dans un `begin … end`")
        return
    end
    # Les maillons qui suivent sont commentés, le temps de l'écoute.
    heard = copy(lines)
    cut = 0
    for r in (ed.cursor_row + 1):(block[2] - 1)
        code = SynthDSL._split_code_comment(heard[r])[1]
        startswith(lstrip(code), "|>") || continue
        heard[r] = "# " * heard[r]
        cut += 1
    end
    _audition_synth_text!(m, tab, _sound_text_in(heard, ed.cursor_row);
                          what = cut == 0 ? "tout" : "jusqu'à $(link.name) ($(cut) maillon$(cut == 1 ? "" : "s") en moins) :")
    return
end

"""
    _atelier_fork!(m)

`& b` — bifurquer : une copie du son sous un nouveau nom, écrite juste
dessous. Pour changer un son sans toucher aux slots qui jouent l'original.
"""
function _atelier_fork!(m::RessacApp)
    tab = _sound_under_cursor(m)
    tab === nothing && return
    ed = tab.code_editor
    base = replace(tab.name, r"\d+$" => "")
    k = 2
    name = "$base$k"
    while _sound_block_named(ed.lines, name) !== nothing || isfile(_app_synth_path(name; mode = :dsl))
        k += 1; name = "$base$k"
    end
    r = _sound_rows(tab)
    r === nothing && return
    ed.cursor_row = r[2]                        # la copie se pose sous l'original
    _insert_sound_block!(m, name, _align_dsl_synth_name(_sound_text(tab), name))
    _push_app_log!(m, "[INFO] « $name » : une copie de $(tab.name), juste dessous — :save la range, U l'envoie dans un pattern")
    return
end

scope!(:atelier, "& + … (atelier, dans un son)"; layer = :transient, modes = (:design,))
bind!(:atelier, "& o", "un maillon après celui du curseur"; short = "maillon après", group = :structure,
      action = m -> _atelier_open!(m, :after))
bind!(:atelier, "& O", "un maillon avant"; short = "maillon avant", group = :structure,
      action = m -> _atelier_open!(m, :before))
bind!(:atelier, "& r", "remplacer le maillon (cim)"; short = "remplacer", group = :structure,
      action = m -> _atelier_open!(m, :replace))
bind!(:atelier, "& d", "retirer le maillon (dam)"; short = "retirer", group = :structure,
      action = m -> (ed = _active_editor(m); ed === nothing || _link_op!(m, ed, 'd', 'a')))
bind!(:atelier, "& m", "faire bouger le nombre sous le curseur (un LFO, sur une ligne nommée)"; short = "faire bouger",
      group = :edit, action = _atelier_modulate!)
bind!(:atelier, "& k", "faire du nombre un argument du son"; short = "→ argument", group = :edit,
      action = _atelier_to_argument!)
bind!(:atelier, "& s", "écouter le son jusqu'à ce maillon"; short = "écouter jusqu'ici", group = :audio,
      action = _atelier_solo!)
bind!(:atelier, "& b", "bifurquer : une copie du son, à part"; short = "bifurquer", group = :file,
      action = _atelier_fork!)
bind!(:atelier, "& ?", "à quoi sert ce maillon"; short = "fiche", group = :help,
      action = m -> _design_doc_tab!(m))

# ── Ce qu'on tire s'entend ───────────────────────────────────────────
# Un nombre est un knob (`+ - * /`, la molette). Le tirer doit s'entendre
# sans autre geste :
#   • dans une ligne de pattern qui joue, le bloc est réévalué ;
#   • dans un son, il est REDÉFINI (sans rejouer de note) : les slots qui le
#     jouent prennent la nouvelle version à leur prochain coup, et un drone
#     tenu sur ce son est relancé avec ses réglages.
# La redéfinition attend un court instant que la main s'arrête : tenir `+`
# ne compile pas un son par répétition de touche.

const _REDEFINE_DELAY = 0.08

"""
    _slot_playing_at(m, ed, row) -> Union{Nothing,Symbol}

Le slot dont le bloc contient `row`, s'il joue exactement ce texte — c'est
la condition pour que tirer un de ses nombres le réévalue tout seul (un
bloc déjà « modifié » attend son `e`).
"""
function _slot_playing_at(m::RessacApp, ed::TK.CodeEditor, row::Int)
    ed === _patterns_editor(m) || return nothing
    for l in _slot_lines(m)
        (l.row <= row <= l.last_row && l.state === :playing) && return l.slot
    end
    return nothing
end

"""
    _after_nudge!(m, ed, row, slot_before)

À appeler après qu'un nombre a bougé à la ligne `row`. `slot_before` : ce
que `_slot_playing_at` disait AVANT le changement.
"""
function _after_nudge!(m::RessacApp, ed::TK.CodeEditor, row::Int, slot_before::Union{Nothing,Symbol})
    if slot_before !== nothing
        for b in _slot_blocks(m)
            (b.slot === slot_before && !b.commented && b.row <= row <= b.last_row) || continue
            _eval_slot_block!(m, b.slot, b.src)
            return
        end
        return
    end
    b = _sound_block_at(ed.lines, row)
    (b !== nothing && ed === _patterns_editor(m)) || return
    m.redefine = (Sound(b.name, ed), time() + _REDEFINE_DELAY)
    return
end

"""
    _define_synth_text!(m, tab, src) -> Bool

Redéfinit le son de `tab` avec le texte `src`, sans jouer de note.
"""
function _define_synth_text!(m::RessacApp, tab::Sound, src::AbstractString)
    (_LIVE_SCHEDULER[] === nothing || _is_raw_synthdef(src)) && return false
    was = _INSTALLING_SYNTH[]
    _INSTALLING_SYNTH[] = true
    try
        Core.eval(SynthDSL, SynthDSL._dsl_parse_all(_align_dsl_synth_name(src, tab.name)))
        return true
    catch
        return false                 # un texte en cours de frappe : le son d'avant reste
    finally
        _INSTALLING_SYNTH[] = was
    end
end

# Appelé à chaque image : la redéfinition en attente, quand la main s'est arrêtée.
function _redefine_tick!(m::RessacApp)
    m.redefine === nothing && return
    (tab, due) = m.redefine
    time() >= due || return
    m.redefine = nothing
    if drone_get(_drone_id(tab)) !== nothing
        _drone_launch!(m, tab)       # le drone tenu : nouveau nœud, mêmes réglages
    else
        _define_synth_text!(m, tab, _sound_text(tab))
    end
    return
end
