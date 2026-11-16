# Où Ressac lit et écrit sur le disque. Trois racines, une fonction chacune :
# rien d'autre dans src/ ne compose un chemin à partir de homedir() ou pwd().
#
#   _config_dir()   préférences du joueur (dispositions, usage de la complétion,
#                   plugins personnels) — RESSAC_CONFIG_DIR pour la déplacer
#   _cache_dir()    contenu régénérable (découverte SuperCollider)
#                   — RESSAC_CACHE_DIR pour le déplacer
#   _project_dir()  le projet en cours : plugins/, sessions/, recordings/,
#                   ressac.toml. C'est le répertoire courant.
#
# Lues à chaque appel, jamais figées dans une constante : la précompilation
# graverait sinon le home de la machine de build, et la suite de tests ne
# pourrait pas les rediriger vers un répertoire temporaire.

function _env_dir(var::AbstractString, default::AbstractString)
    v = get(ENV, var, "")
    return isempty(v) ? default : String(v)
end

_config_dir()  = _env_dir("RESSAC_CONFIG_DIR", joinpath(homedir(), ".config", "ressac"))
_cache_dir()   = _env_dir("RESSAC_CACHE_DIR",  joinpath(homedir(), ".cache",  "ressac"))
_project_dir() = pwd()
