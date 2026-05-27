# Static docs + starter sketches USED TO live here as inline Dict
# literals (`_PARAM_DOCS`, `_PARAM_EXAMPLES`, `_STARTER_PACKS`).
# Sub-project 7 moved everything into `plugins/{core,reservoir,chaos}/docs/*.md`
# and `plugins/{...}/snippets/*.{toml,jl}` so plugins can contribute
# docs and starters via the same plugin.toml manifest as samples and
# synthdefs.
#
# See `src/extension_registry.jl` for the registry, lookup, and
# composition resolver. The TUI calls `Ressac.lookup_doc(name)`,
# `Ressac.lookup_snippet(name)`, `Ressac.list_docs()`, and
# `Ressac.list_starters()` exclusively.
nothing
