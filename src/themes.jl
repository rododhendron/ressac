# Custom Ressac themes layered on top of Tachikoma's built-in set.
# Tachikoma already ships a generous palette (KOKAKU, OUTRUN, NEUROMANCER,
# MEADOW, …) — we add `cyberpunk` and `solarpunk` because the user asked
# for them by those exact names, and they each lean into a more saturated
# aesthetic than the closest built-in (OUTRUN is sunset-leaning; the
# CYBERPUNK below is the dense, glowing, neon-in-rain register).

using Tachikoma

const _RESSAC_CUSTOM_THEMES = Dict{Symbol, Tachikoma.Theme}()

function _init_custom_themes!()
    # Cyberpunk — dense city night, hot magenta on near-black, cyan
    # accents. Borders glow electric. Errors bleed bright red.
    _RESSAC_CUSTOM_THEMES[:cyberpunk] = Tachikoma.Theme(
        "cyberpunk",
        Tachikoma.Color256(232),  # bg: black
        Tachikoma.Color256(53),   # border: deep magenta
        Tachikoma.Color256(201),  # border_focus: hot pink
        Tachikoma.Color256(231),  # text: white
        Tachikoma.Color256(241),  # text_dim: dark gray
        Tachikoma.Color256(51),   # text_bright: electric cyan
        Tachikoma.Color256(201),  # primary: hot pink
        Tachikoma.Color256(93),   # secondary: violet
        Tachikoma.Color256(51),   # accent: electric cyan
        Tachikoma.Color256(46),   # success: neon green
        Tachikoma.Color256(220),  # warning: gold
        Tachikoma.Color256(196),  # error: pure red
        Tachikoma.Color256(213),  # title: pink
    )
    # Solarpunk — sunlit greens + warm earth + golden hour accent on
    # an off-white background. Bright but not eye-bleeding; the
    # idea is "well-tended garden lab", not "fluorescent office".
    _RESSAC_CUSTOM_THEMES[:solarpunk] = Tachikoma.Theme(
        "solarpunk",
        Tachikoma.Color256(230),  # bg: warm cream
        Tachikoma.Color256(108),  # border: sage
        Tachikoma.Color256(28),   # border_focus: forest green
        Tachikoma.Color256(235),  # text: very dark gray
        Tachikoma.Color256(243),  # text_dim: medium warm gray
        Tachikoma.Color256(232),  # text_bright: near-black
        Tachikoma.Color256(28),   # primary: forest green
        Tachikoma.Color256(94),   # secondary: tan
        Tachikoma.Color256(172),  # accent: gold / amber
        Tachikoma.Color256(34),   # success: emerald
        Tachikoma.Color256(166),  # warning: terracotta
        Tachikoma.Color256(124),  # error: dark red
        Tachikoma.Color256(22),   # title: deep green
    )
end

"""
    _apply_theme!(name::Symbol) -> Bool

Try a Ressac custom theme first; fall back to Tachikoma's built-in
table. Returns true on success.
"""
function _apply_theme!(name::Symbol)
    if haskey(_RESSAC_CUSTOM_THEMES, name)
        Tachikoma.set_theme!(_RESSAC_CUSTOM_THEMES[name])
        return true
    end
    try
        Tachikoma.set_theme!(name)
        return true
    catch
        return false
    end
end

"""
    _available_themes() -> Vector{Symbol}

All theme names that `:theme` will accept — our custom ones plus
every Tachikoma built-in.
"""
function _available_themes()
    names = Symbol[keys(_RESSAC_CUSTOM_THEMES)...]
    for t in Tachikoma.ALL_THEMES
        push!(names, Symbol(t.name))
    end
    unique!(names)
    sort!(names)
    return names
end
