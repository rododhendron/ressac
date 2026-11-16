# src/app_jobs.jl
# Le travail lent ne se fait pas sur la tâche UI.
#
# Une requête HTTP vers sccode.org (jusqu'à 15 s), un rendu sclang hors-ligne
# pour mesurer l'impact des nœuds : lancés tels quels depuis une commande,
# ils gelaient l'écran et les touches — pendant qu'on joue. `_background!`
# les envoie sur un autre thread ; leur résultat revient par une file, que la
# vue vide à chaque frame (`_drain_jobs!`), et c'est donc la tâche UI — elle
# seule — qui touche au modèle pour l'appliquer.
#
# Dans les tests, `_JOBS_INLINE[] = true` fait tout tourner sur place, dans
# l'ordre : même code, résultat immédiat.

const _JOB_LOCK   = ReentrantLock()
const _JOB_DONE   = Function[]
const _JOBS_INLINE = Ref{Bool}(false)
const _JOBS_PENDING = Threads.Atomic{Int}(0)

"""
    _background!(done, work)

Lance `work()` hors de la tâche UI, puis — sur la tâche UI, à la frame
suivante — appelle `done(result, err)` : `err` est `nothing` si `work` a
réussi, sinon l'exception (et `result` est `nothing`). `done` peut toucher
au modèle ; `work` ne le doit pas.
"""
function _background!(done::Function, work::Function)
    attempt() = try
        (work(), nothing)
    catch err
        (nothing, err)
    end
    if _JOBS_INLINE[]
        (result, err) = attempt()
        done(result, err)
        return nothing
    end
    Threads.atomic_add!(_JOBS_PENDING, 1)
    Threads.@spawn begin
        (result, err) = attempt()
        lock(() -> push!(_JOB_DONE, () -> done(result, err)), _JOB_LOCK)
        Threads.atomic_sub!(_JOBS_PENDING, 1)
    end
    return nothing
end

"""
    _drain_jobs!(m)

Applique, sur la tâche UI, les résultats arrivés depuis le dernier appel.
Une suite qui lève se lit dans le journal ; les autres passent quand même.
"""
function _drain_jobs!(m)
    ready = lock(_JOB_LOCK) do
        fs = copy(_JOB_DONE); empty!(_JOB_DONE); fs
    end
    for f in ready
        try
            f()
        catch err
            _push_app_log!(m, "[ERROR] tâche de fond — $(first(sprint(showerror, err), 160))")
        end
    end
    return nothing
end

"Des travaux de fond sont-ils encore en cours ou en attente d'être appliqués ?"
_jobs_busy() = _JOBS_PENDING[] > 0 || lock(() -> !isempty(_JOB_DONE), _JOB_LOCK)
