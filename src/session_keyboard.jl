# src/session_keyboard.jl
# La disposition du clavier. Quand le terminal parle le protocole clavier
# kitty avec « touches alternatives » (voir `_request_alternate_keys`), il
# envoie le caractère produit par Maj+touche et rien n'est à faire. Sinon
# Tachikoma reçoit la touche de base avec un modificateur Maj et applique
# une table QWERTY : sur un AZERTY, Maj+`,` donnait `<` au lieu de `?`,
# et `?` (l'aide) était injoignable.
#
# On détecte donc la disposition — `RESSAC_KEYBOARD`, la config,
# `XKB_DEFAULT_LAYOUT`, `localectl`, `setxkbmap`, `LANG` — et on installe
# la table Maj qui va avec. `:keyboard azerty|qwerty|auto` change en
# session.

# La table QWERTY d'origine de Tachikoma, capturée au premier appel
# (avant toute retouche) pour pouvoir y revenir.
const _US_SHIFT_MAP = Ref{Union{Nothing,Dict{Char,Char}}}(nothing)

# Touches qui n'existent pas en QWERTY : leur forme Maj ne gêne personne,
# on les ajoute toujours.
const _SHIFT_ACCENTS = Dict{Char,Char}(
    'ù' => '%', 'é' => '2', 'è' => '7', 'à' => '0', 'ç' => '9',
    '²' => '~', '°' => ')', 'µ' => '*', '§' => '!', '£' => '\$', '<' => '>')

# AZERTY (fr) : la touche de base → ce que Maj en fait.
const _SHIFT_AZERTY = Dict{Char,Char}(
    '&' => '1', 'é' => '2', '"' => '3', '\'' => '4', '(' => '5', '-' => '6',
    'è' => '7', '_' => '8', 'ç' => '9', 'à' => '0', ')' => '°', '=' => '+',
    '^' => '¨', '\$' => '£', 'ù' => '%', '*' => 'µ', '<' => '>',
    ',' => '?', ';' => '.', ':' => '/', '!' => '§')

const _KEYBOARD_LAYOUTS = (:qwerty, :azerty)
const _KEYBOARD = Ref{Symbol}(:qwerty)          # la disposition installée

"""
    apply_keyboard_layout!(layout) -> Symbol

Installe la table Maj de `layout` (`:qwerty` ou `:azerty`) dans
Tachikoma, à partir de sa table d'origine. Renvoie la disposition
installée.
"""
function apply_keyboard_layout!(layout::Symbol)
    layout in _KEYBOARD_LAYOUTS || throw(ArgumentError("disposition inconnue « $layout » — qwerty ou azerty"))
    map = TK._SHIFT_SYMBOL_MAP
    _US_SHIFT_MAP[] === nothing && (_US_SHIFT_MAP[] = copy(map))
    empty!(map)
    merge!(map, _US_SHIFT_MAP[])
    merge!(map, _SHIFT_ACCENTS)
    layout === :azerty && merge!(map, _SHIFT_AZERTY)
    _KEYBOARD[] = layout
    return layout
end

# Le nom XKB d'une disposition (« fr », « be », « fr-latin1 »…) → la nôtre.
function _layout_from_xkb(name::AbstractString)
    n = lowercase(strip(name))
    n = first(split(n, r"[,+(]"))              # « fr,us » → fr ; « fr(oss) » → fr
    n in ("fr", "be", "fr-latin1", "fr-latin9", "azerty") && return :azerty
    isempty(n) && return nothing
    return :qwerty
end

# « X11 Layout: fr » dans la sortie de `localectl status`.
function _parse_localectl(out::AbstractString)
    m = match(r"X11 Layout:\s*(\S+)", out)
    m === nothing && return nothing
    return _layout_from_xkb(m.captures[1])
end

# « layout:     us » dans la sortie de `setxkbmap -query`.
function _parse_setxkbmap(out::AbstractString)
    m = match(r"(?m)^layout:\s*(\S+)", out)
    m === nothing && return nothing
    return _layout_from_xkb(m.captures[1])
end

# Sortie d'une commande, ou "" si absente, en échec ou trop lente.
function _cmd_output(args::Vector{String}; timeout::Real = 1.5)
    Sys.which(args[1]) === nothing && return ""
    try
        p = open(pipeline(Cmd(args); stderr = devnull))
        t = Timer(timeout) do _
            process_running(p) && kill(p)
        end
        out = read(p, String)
        close(t)
        return success(p) ? out : ""
    catch
        return ""
    end
end

"""
    detect_keyboard_layout(; env = ENV, cfg = :auto) -> (layout, source)

La disposition, et d'où on la tient. Dans l'ordre : `RESSAC_KEYBOARD`,
la config, `XKB_DEFAULT_LAYOUT`, `localectl status` (la vraie source
sous systemd, y compris sous Wayland), `setxkbmap -query` (X11 ; sous
Wayland il ment souvent), puis `LANG` (fr, be). Sinon QWERTY.
"""
function detect_keyboard_layout(; env = ENV, cfg::Symbol = :auto)
    v = get(env, "RESSAC_KEYBOARD", "")
    isempty(v) || (l = _layout_from_xkb(v); l === nothing || return (l, "RESSAC_KEYBOARD"))
    cfg === :auto || return (cfg, "ressac.toml")
    v = get(env, "XKB_DEFAULT_LAYOUT", "")
    isempty(v) || (l = _layout_from_xkb(v); l === nothing || return (l, "XKB_DEFAULT_LAYOUT"))
    l = _parse_localectl(_cmd_output(["localectl", "status"]))
    l === nothing || return (l, "localectl")
    if !isempty(get(env, "DISPLAY", "")) && isempty(get(env, "WAYLAND_DISPLAY", ""))
        l = _parse_setxkbmap(_cmd_output(["setxkbmap", "-query"]))
        l === nothing || return (l, "setxkbmap")
    end
    lang = lowercase(get(env, "LC_ALL", get(env, "LANG", "")))
    (startswith(lang, "fr") || startswith(lang, "be")) && return (:azerty, "LANG")
    return (:qwerty, "défaut")
end

"""
    _setup_keyboard!(m_or_nothing, cfg_keyboard) -> (layout, source)

Au démarrage : détecte et installe. Le journal dit ce qui a été choisi et
comment changer.
"""
function _setup_keyboard!(cfg_keyboard::Symbol)
    (layout, source) = detect_keyboard_layout(; cfg = cfg_keyboard)
    apply_keyboard_layout!(layout)
    return (layout, source)
end
