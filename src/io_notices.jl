# Messages des threads de fond vers le journal de l'app.
#
# Le journal (`m.logs`) appartient à la tâche UI : c'est un Vector ordinaire,
# qu'elle lit en plein rendu. Le scheduler et l'écoute OSC tournent ailleurs ;
# ils ne le touchent jamais. Ils déposent ici, sous verrou, et la vue vide la
# file à chaque frame (`_drain_notices!` → `_push_app_log!`).
#
# La file est bornée : sans TUI pour la vider (tests, REPL nu), elle sature
# et jette, elle ne grossit pas.

const _NOTICE_LOCK  = ReentrantLock()
const _NOTICE_QUEUE = String[]
const _NOTICE_MAX   = 256

"""
    _notify!(line)

Dépose une ligne pour le journal de l'app. Sûr depuis n'importe quel thread,
ne bloque jamais plus que le temps d'un `push!`.
"""
function _notify!(line::AbstractString)
    lock(_NOTICE_LOCK) do
        length(_NOTICE_QUEUE) < _NOTICE_MAX && push!(_NOTICE_QUEUE, String(line))
    end
    return nothing
end

"""
    _drain_notices!() -> Vector{String}

Rend les lignes déposées depuis le dernier appel, dans l'ordre, et vide la file.
"""
function _drain_notices!()
    lock(_NOTICE_LOCK) do
        out = copy(_NOTICE_QUEUE)
        empty!(_NOTICE_QUEUE)
        return out
    end
end
