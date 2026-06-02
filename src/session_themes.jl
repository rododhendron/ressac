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

# ── Syntax-highlight override ───────────────────────────────────────
# Tachikoma's default token style dims punctuation (`()[]{}.,;:`) and
# builtins to `:text_dim`, near-invisible on a black background (the
# kokaku default). Structural punctuation is load-bearing in Julia/SC
# code, so we override the style map at RUNTIME — defining it at
# module load is blocked by Julia's "no method overwriting during
# precompilation" rule, so `_install_syntax_theme!` is called once
# from `live()` after the theme is applied. Resolves through the
# active theme's named colours, so it adapts to any theme.
const _SYNTAX_THEME_INSTALLED = Ref(false)

function _install_syntax_theme!()
    _SYNTAX_THEME_INSTALLED[] && return
    _SYNTAX_THEME_INSTALLED[] = true
    @eval Tachikoma function _token_style(kind::TokenKind)
        if kind == tok_keyword
            tstyle(:primary, bold = true)
        elseif kind == tok_type
            tstyle(:warning)
        elseif kind == tok_number
            tstyle(:accent)
        elseif kind == tok_string
            tstyle(:success)
        elseif kind == tok_comment
            tstyle(:text_dim, italic = true)
        elseif kind == tok_macro
            tstyle(:secondary, bold = true)
        elseif kind == tok_symbol
            tstyle(:accent, italic = true)
        elseif kind == tok_bool
            tstyle(:accent, bold = true)
        elseif kind == tok_builtin
            tstyle(:secondary, italic = true)   # was :text_dim
        elseif kind == tok_operator
            tstyle(:text_bright, bold = true)
        elseif kind == tok_punctuation
            tstyle(:text, bold = true)           # was :text_dim
        else
            tstyle(:text)
        end
    end
    return nothing
end
