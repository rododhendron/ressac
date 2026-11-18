# src/atelier_types.jl
# Les types du maillon (editor_links.jl) et de l'atelier (atelier.jl) :
# définis avant le modèle de l'app, qui en porte l'état.

"""
Un maillon d'une ligne, en colonnes de caractères (1 = premier caractère).
`inner` : son texte ; `around` : avec son `|>` ; `linewise` : il occupe la
ligne à lui seul ; `piped` : un `|>` le précède sur sa ligne ; `name` : la
fonction qu'il appelle.
"""
struct LinkSpan
    row::Int
    inner::UnitRange{Int}
    around::UnitRange{Int}
    linewise::Bool
    piped::Bool
    name::String
end

"""
Une proposition de l'atelier : le nom du maillon, ce qu'on écrit (sans le
`|>`), ce qu'il fait, et son rôle (pour ranger les cousins d'abord).
"""
struct AtelierItem
    name::String
    code::String
    desc::String
    role::Symbol
end

"""
Un essai en cours : le texte tel qu'il était, la ligne visée, ce qu'on y
fait (`:after`, `:before`, `:replace`), et le maillon visé s'il y en a un.
"""
mutable struct AtelierState
    tab::EditorBuffer
    base::Vector{String}
    row::Int
    action::Symbol
    link::Union{Nothing,LinkSpan}
    items::Vector{AtelierItem}
    heard::String                 # le dernier essai entendu (pour ne pas le rejouer à chaque image)
end

