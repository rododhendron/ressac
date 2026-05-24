# Project-level config. Loaded from `./ressac.toml` at boot
# (and on `:reload-config`); falls back to defaults below if the file
# doesn't exist. Every field is editable live without re-launching.

using TOML

@kwdef mutable struct RessacConfig
    # ── UI ───────────────────────────────────────────────────────────
    theme::Symbol           = :kokaku   # any Tachikoma theme name OR a
                                        # Ressac custom (:cyberpunk, :solarpunk).
    fps::Int                = 120       # render rate ceiling — higher fps
                                        # → lower input latency → tighter
                                        # :tap acquisition (~8ms vs ~16ms).
    # ── T (test synth) held-key behaviour ────────────────────────────
    t_hold_initial_ms::Int  = 250       # first repeat fires after this
    t_hold_min_ms::Int      = 60        # interval can decay no lower than this
    t_hold_accel::Float64   = 0.85      # each fire multiplies the interval
                                        # by this ratio (0.85 = 15% faster)
    # ── Nudge ────────────────────────────────────────────────────────
    nudge_int_small::Int    = 1
    nudge_int_big::Int      = 10
    nudge_float_small::Float64 = 1.0
    nudge_float_big::Float64   = 0.1
    # ── Scope ────────────────────────────────────────────────────────
    scope_zoom_step::Float64 = 1.5
    scope_zoom_max::Float64  = 32.0
end

_RESSAC_CONFIG = Ref{RessacConfig}(RessacConfig())

"""
    _ressac_config_path() -> String

The default file we look at on boot / `:reload-config`. Project-root
relative — Ressac is meant to be launched from a project dir.
"""
_ressac_config_path() = joinpath(pwd(), "ressac.toml")

"""
    _load_ressac_config!() -> RessacConfig

Read `./ressac.toml` and overlay it on the defaults. Missing keys keep
their default value. Malformed entries log a warning and stay at the
default. Returns the resulting config and stores it in `_RESSAC_CONFIG`.
"""
function _load_ressac_config!()
    cfg = RessacConfig()
    path = _ressac_config_path()
    if isfile(path)
        try
            data = TOML.parsefile(path)
            _overlay_section!(cfg, data, "ui",   (:theme=>Symbol, :fps=>Int))
            _overlay_section!(cfg, data, "input",
                (:t_hold_initial_ms=>Int, :t_hold_min_ms=>Int,
                 :t_hold_accel=>Float64,
                 :nudge_int_small=>Int, :nudge_int_big=>Int,
                 :nudge_float_small=>Float64, :nudge_float_big=>Float64))
            _overlay_section!(cfg, data, "scope",
                (:scope_zoom_step=>Float64, :scope_zoom_max=>Float64))
        catch err
            @warn "Failed to parse $path: $(sprint(showerror, err)). Using defaults."
        end
    end
    _RESSAC_CONFIG[] = cfg
    return cfg
end

function _overlay_section!(cfg::RessacConfig, data::AbstractDict,
                            section::String, fields)
    haskey(data, section) || return
    sect = data[section]
    sect isa AbstractDict || return
    for (field, type) in fields
        key = String(field)
        haskey(sect, key) || continue
        raw = sect[key]
        try
            val = type === Symbol ? Symbol(raw) : convert(type, raw)
            setfield!(cfg, field, val)
        catch
            @warn "ressac.toml: [$section] $key = $raw — wrong type (want $type), ignored"
        end
    end
end

ressac_config() = _RESSAC_CONFIG[]
