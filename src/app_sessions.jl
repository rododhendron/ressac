# src/app_sessions.jl
# Les sessions : le texte des patterns, rangé sous un nom dans `sessions/`.
# Les verbes sont ceux de vim, parce que c'est le même geste :
#
#   :w            sauve la session courante
#   :w nom        la sauve sous ce nom (qui devient le sien)
#   :e nom        en ouvre une autre         (:e! pour jeter ce qui n'est pas sauvé)
#   :e #          revient à la précédente
#   :e!           relit la session courante depuis le disque
#   :enew         session vierge             (:enew! de même)
#
# Ouvrir une session ne coupe rien : ce qui joue continue jusqu'au premier
# `E`. Les lignes le disent d'elles-mêmes (elles sont « à l'arrêt » ou
# « modifiées », voir slot_state.jl).

_sessions_dir() = joinpath(_project_dir(), "sessions")
_session_path(name::AbstractString) = joinpath(_sessions_dir(), String(name) * ".txt")

# Un nom de session est un nom de fichier simple.
_valid_session_name(name::AbstractString) = occursin(r"^[\w][\w.-]*$", name)

"""
    list_sessions() -> Vector{String}

Les sessions rangées, par nom. `_last` (la copie de sûreté écrite à la
sortie) n'en est pas une.
"""
function list_sessions()
    dir = _sessions_dir()
    isdir(dir) || return String[]
    return sort!([splitext(f)[1] for f in readdir(dir) if endswith(f, ".txt") && f != "_last.txt"])
end

"""
    _session_dirty(m) -> Bool

Le texte des patterns a-t-il changé depuis la dernière sauvegarde ou
ouverture ?
"""
function _session_dirty(m::RessacApp)
    ed = _patterns_editor(m)
    ed === nothing && return false
    return hash(ed.lines) != m.session_saved
end

# Note le texte courant comme « sauvé ».
function _session_mark_saved!(m::RessacApp)
    ed = _patterns_editor(m)
    m.session_saved = ed === nothing ? UInt64(0) : hash(ed.lines)
    return
end

"""
    _session_write!(m, name = "") -> Bool

`:w` / `:w nom`. Sans nom et sans nom courant, on le demande plutôt que
d'écrire dans un fichier qu'on ne retrouvera pas.
"""
function _session_write!(m::RessacApp, name::AbstractString = "")
    ed = _patterns_editor(m)
    ed === nothing && (_push_app_log!(m, "[ERROR] :w — pas de texte de patterns à l'écran"); return false)
    name = isempty(name) ? m.session_name : String(name)
    if isempty(name)
        _push_app_log!(m, "[INFO] cette session n'a pas de nom — :w <nom> la range")
        return false
    end
    if !_valid_session_name(name)
        _push_app_log!(m, "[ERROR] :w — « $name » : un nom de session est fait de lettres, chiffres, - _ .")
        return false
    end
    try
        mkpath(_sessions_dir())
        write(_session_path(name), TK.text(ed))
    catch err
        _push_app_log!(m, "[ERROR] :w — $(sprint(showerror, err))")
        return false
    end
    m.session_name = name
    _session_mark_saved!(m)
    _push_app_log!(m, "[INFO] session « $name » sauvée")
    return true
end

# Remplace le texte des patterns par celui d'une autre session.
function _session_swap!(m::RessacApp, name::AbstractString, text::AbstractString)
    ed = _patterns_editor(m)
    ed === nothing && return false
    _load_text!(ed, text)
    ed.cursor_row = 1; ed.cursor_col = 0; ed.mode = :normal
    name == m.session_name || (m.session_prev = m.session_name)
    m.session_name = String(name)
    _session_mark_saved!(m)
    _focus_patterns!(m)
    return true
end

# Ce qui n'est pas sauvé serait perdu : on le dit, et `!` passe outre.
function _session_guard(m::RessacApp, verb::AbstractString, force::Bool)
    (force || !_session_dirty(m)) && return true
    _push_app_log!(m, "[WARN] la session a changé depuis sa sauvegarde — :w d'abord, ou :$(verb)! pour la laisser")
    return false
end

"""
    _session_open!(m, name; force = false) -> Bool

`:e nom`. `#` désigne la session précédente.
"""
function _session_open!(m::RessacApp, name::AbstractString; force::Bool = false)
    name = String(name)
    if name == "#"
        isempty(m.session_prev) && (_push_app_log!(m, "[INFO] :e # — pas de session précédente"); return false)
        name = m.session_prev
    end
    path = _session_path(name)
    if !_valid_session_name(name) || !isfile(path)
        _push_app_log!(m, "[ERROR] :e — pas de session « $name » (:sessions pour la liste)")
        return false
    end
    _session_guard(m, "e", force) || return false
    text = try
        read(path, String)
    catch err
        _push_app_log!(m, "[ERROR] :e — $(sprint(showerror, err))")
        return false
    end
    _session_swap!(m, name, text) || return false
    _push_app_log!(m, "[INFO] session « $name » — E la lance ; ce qui jouait continue d'ici là")
    return true
end

"""
    _session_reload!(m; force = false) -> Bool

`:e` / `:e!` sans nom : relit la session courante depuis le disque.
"""
function _session_reload!(m::RessacApp; force::Bool = false)
    isempty(m.session_name) && (_push_app_log!(m, "[WARN] :e — cette session n'a pas de nom, donc rien à relire du disque : :w <nom> l'écrit, :e <nom> en ouvre une (:sessions)"); return false)
    return _session_open!(m, m.session_name; force)
end

"""
    _session_new!(m; force = false) -> Bool

`:enew` : une session vierge, sans nom.
"""
function _session_new!(m::RessacApp; force::Bool = false)
    _session_guard(m, "enew", force) || return false
    _session_swap!(m, "", "") || return false
    _push_app_log!(m, "[INFO] session vierge — ce qui jouait continue ; , arrête tout")
    return true
end

function _session_delete!(m::RessacApp, name::AbstractString)
    path = _session_path(name)
    isfile(path) || return false
    rm(path; force = true)
    name == m.session_prev && (m.session_prev = "")
    _push_app_log!(m, "[INFO] session « $name » supprimée" *
                      (name == m.session_name ? " (son texte est toujours à l'écran)" : ""))
    return true
end

# ── D'un lancement à l'autre ─────────────────────────────────────────
# Le texte lui-même voyage avec la disposition (workspace_persistence.jl) :
# on retrouve son bricolage de la veille, en silence. Ici, seulement de
# quoi savoir quelle session c'était, et une copie de sûreté du texte.

_session_state_path() = joinpath(_config_dir(), "session.toml")

function _session_state_save!(m::RessacApp)
    try
        mkpath(_config_dir())
        open(_session_state_path(), "w") do io
            TOML.print(io, Dict{String,Any}("name" => m.session_name, "previous" => m.session_prev,
                                            "saved" => !_session_dirty(m)))
        end
        ed = _patterns_editor(m)
        if ed !== nothing
            mkpath(_sessions_dir())
            write(_session_path("_last"), TK.text(ed))
        end
    catch err
        _push_app_log!(m, "[WARN] état de session non écrit : $(sprint(showerror, err))")
    end
    return
end

function _session_state_restore!(m::RessacApp)
    path = _session_state_path()
    isfile(path) || return
    d = try
        TOML.parsefile(path)
    catch
        return
    end
    name = String(get(d, "name", ""))
    m.session_name = (_valid_session_name(name) && isfile(_session_path(name))) ? name : ""
    m.session_prev = String(get(d, "previous", ""))
    # Le texte restauré était-il sauvé ? Sinon le `+` de la status line le dit.
    get(d, "saved", false) == true && _session_mark_saved!(m)
    return
end

# Ce que la status line dit de la session : son nom, et `+` si elle a changé.
function _session_label(m::RessacApp)
    name = isempty(m.session_name) ? "sans nom" : m.session_name
    return _session_dirty(m) ? name * " +" : name
end
