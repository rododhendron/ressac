# src/tk_scroll.jl
# Le défilement d'un contenu en lignes, partout dans Ressac, est porté par
# un `Tachikoma.ScrollPane` : offset borné, touches, molette, clic et
# glisser sur la barre, suivi automatique du bas (journal). Ce fichier
# réunit les quelques aides communes ; les touches restent déclarées
# dans le registre `bind!` de chaque scope et délèguent ici.

"""
    _scrollpane(; offset = 0, following = false) -> Tachikoma.ScrollPane

Un ScrollPane sans cadre (la pane ou la modale dessine le sien), avec sa
barre quand le contenu déborde. `following = true` colle au bas quand le
contenu grandit (journal) et se détache dès qu'on remonte.
"""
_scrollpane(; offset::Int = 0, following::Bool = false) =
    TK.ScrollPane(Vector{TK.Span}[]; offset = max(0, offset), following, show_scrollbar = true)

# Fait défiler comme la touche Tachikoma correspondante (:up, :down,
# :pageup, :pagedown, :home, :end_key), bornes comprises.
_scroll!(sp::TK.ScrollPane, key::Symbol) = (TK.handle_key!(sp, TK.KeyEvent(key)); nothing)

# La dernière position de défilement (le bas du contenu visible), telle
# que le ScrollPane la calcule après un rendu.
_scroll_last(sp::TK.ScrollPane) = TK._max_offset(sp, max(1, sp.last_area.height))

# Remet en haut.
_scroll_top!(sp::TK.ScrollPane) = (sp.offset = 0; nothing)

# Recolle au bas : le prochain rendu borne l'offset et le suivi reprend.
_scroll_end!(sp::TK.ScrollPane) = (sp.following = true; sp.offset = typemax(Int) ÷ 2; nothing)

# Une ligne de texte uniforme, comme contenu de ScrollPane.
_span_line(s::AbstractString, sty::TK.Style = TK.tstyle(:text)) = TK.Span[TK.Span(String(s), sty)]
