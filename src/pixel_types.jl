# src/pixel_types.jl
# La scène de la grille en pixels (pixel_layer.jl) : définie avant le modèle
# de l'app, qui la porte d'une image à l'autre.

# Une note d'une piste : début et fin dans le cycle (0..1), hauteur ou rien.
const PixelNote = Tuple{Float64,Float64,Union{Nothing,Float64}}

struct PixelLane
    row::Int                 # la ligne d'écran (cellules)
    notes::Vector{PixelNote}
    state::Symbol            # :playing · :modified · :muted
    cursor::Bool
    held::Bool
end

mutable struct PixelScene
    x::Int; y::Int; w::Int; h::Int     # la zone, en cellules
    lanes::Vector{PixelLane}
    phase::Float64                     # où en est le cycle (0..1) ; < 0 : l'horloge n'a pas démarré
    cursor_row::Int                    # la ligne d'écran du curseur (0 : aucune)
    dim::Bool                          # quelque chose flotte par-dessus : l'image s'éteint avec le reste
end
