# sc-discoverer runner — registers _handle_sc_discover so the
# plugin loader auto-runs SC UGen discovery at start_live!.
#
# Companion file: discover.scd (the SC introspection script).
# Generated content target: ~/.cache/ressac/plugins/sc-autodiscover/.

using SHA
using TOML
using Dates

"""
    _sc_cache_dir() -> String

Absolute path to the generated cache plugin directory. Override
via the `RESSAC_CACHE_DIR` env var (e.g. for Docker / read-only
Nix store scenarios). Defaults to `~/.cache/ressac`.
"""
_sc_cache_dir() = joinpath(
    get(ENV, "RESSAC_CACHE_DIR", joinpath(homedir(), ".cache", "ressac")),
    "plugins", "sc-autodiscover",
)

"""
    _sc_script_sha256(scd_path) -> String

SHA-256 hex digest of the SC script content at `scd_path`. Used by
`_sc_cache_valid` to detect any change to `discover.scd` and auto-
invalidate the cache — frees us from maintaining a manual version
constant. Cosmetic edits (whitespace, comments) DO trigger
re-discovery; acceptable since discovery is only at `start_live!`
and takes ~10s.
"""
_sc_script_sha256(scd_path::AbstractString) =
    bytes2hex(SHA.sha256(read(scd_path, String)))
