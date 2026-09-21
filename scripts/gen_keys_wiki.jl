# scripts/gen_keys_wiki.jl — régénère docs/wiki/04-keys.md depuis le registre.
#
#     julia --project=. scripts/gen_keys_wiki.jl
#
# test/test_help.jl vérifie que la page est à jour : après tout changement
# de bindings, relancer ce script et commiter la page.
using Ressac
path = joinpath(@__DIR__, "..", "docs", "wiki", "04-keys.md")
write(path, Ressac.keys_wiki_markdown())
println("→ ", normpath(path))
