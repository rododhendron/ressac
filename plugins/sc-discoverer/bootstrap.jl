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

"""
    _sc_cache_valid(cache_dir, scd_path; sc_meta) -> Bool

Decide whether the cache at `cache_dir` is up to date.

`sc_meta` is a tuple `(sc_version::String, ugen_count::Int)` obtained
from an OSC roundtrip with SC, or `nothing` if the roundtrip failed.
A failed roundtrip is treated as "assume invalid" — we can't prove
freshness without SC, so re-discover.

Returns `false` (and triggers re-discovery) when ANY of:
  * the meta file is missing
  * the meta TOML is corrupted
  * `sc_meta === nothing` (SC unreachable)
  * `sc_version`, `ugen_count`, or `discover_script_sha256` mismatch
"""
function _sc_cache_valid(cache_dir::AbstractString, scd_path::AbstractString;
                        sc_meta::Union{Tuple{AbstractString,Integer}, Nothing})
    sc_meta === nothing && return false
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    isfile(meta_path) || return false
    meta = try
        TOML.parsefile(meta_path)
    catch
        @warn "sc-autodiscover: cache_meta.toml corrupted, will rediscover"
        return false
    end
    sha_now = _sc_script_sha256(scd_path)
    get(meta, "discover_script_sha256", "") == sha_now || return false
    sc_version, sc_ugen_count = sc_meta
    get(meta, "sc_version", "")  == sc_version  &&
    get(meta, "ugen_count", -1)  == sc_ugen_count
end
