# Rendu markdown partagé (content_markdown.jl) : wiki et fiches de doc.
using Test
using Ressac
using Tachikoma

_txt(line) = join(sp.content for sp in line)
_txts(lines) = [_txt(l) for l in lines]
_sty(line, i) = line[i].style

@testset "inline — code, gras, italique, lien" begin
    sp = Ressac._md_inline("un `code` et **gras** puis *ital* et [lien](http://x) fin")
    @test [x.content for x in sp] == ["un ", "code", " et ", "gras", " puis ", "ital", " et ", "lien", " fin"]
    @test sp[2].style == Ressac._md_style(:code)
    @test sp[4].style.bold && sp[6].style.italic && sp[8].style.underline
    # `*` dans un mot ou collé à une espace n'ouvre rien
    @test _txt(Ressac._md_inline("bd*3 et 2 * 3 = 6")) == "bd*3 et 2 * 3 = 6"
    @test length(Ressac._md_inline("bd*3 et 2 * 3 = 6")) == 1
    # un `*` à l'intérieur d'un code ne ferme pas un italique ouvert avant
    @test _txt(Ressac._md_inline("*a `b*c` d*")) == "a b*c d"
    # un code non fermé reste littéral
    @test _txt(Ressac._md_inline("un ` seul")) == "un ` seul"
    @test Ressac._md_inline("") == [Tachikoma.Span("", Tachikoma.tstyle(:text))]
end

@testset "repli — aux espaces, retrait suspendu, mot trop long" begin
    w = Ressac._md_wrap(Ressac._md_inline("un deux trois quatre"), 9)
    @test _txts(w) == ["un deux", "trois", "quatre"]
    w = Ressac._md_wrap(Ressac._md_inline("• alpha beta gamma delta"), 12; indent = 2)
    @test _txts(w) == ["• alpha beta", "  gamma", "  delta"]
    @test all(l -> textwidth(_txt(l)) <= 12, w)
    w = Ressac._md_wrap(Ressac._md_inline("abcdefghijklmnop xy"), 6)
    @test all(l -> textwidth(_txt(l)) <= 6, w)
    @test join(_txts(w)) == "abcdefghijklmnopxy"
    # le style survit au repli
    w = Ressac._md_wrap(Ressac._md_inline("aa **bb cc** dd"), 6)
    @test _txts(w) == ["aa bb", "cc dd"]
    @test _sty(w[2], 1).bold && !_sty(w[2], length(w[2])).bold
end

@testset "blocs — titres, listes, citations, filets, code coloré" begin
    src = ["# Titre", "## Sous", "- puce `x`", "  suite de la puce", "1. un", "2. deux", "> citation", "---",
           "```julia", "@d1 p\"bd sn\" |> gain(0.8)  # commentaire", "```", "texte"]
    r = Ressac._md_render(src, 40)
    ts = _txts(r)
    @test ts[1] == "▓ Titre" && ts[2] == "» Sous"
    @test r[3][3] == Tachikoma.Span("x", Ressac._md_style(:code))
    @test ts[3] == "  • puce x suite de la puce"        # la continuation rejoint la puce
    @test ts[4] == "  1. un" && ts[5] == "  2. deux"
    @test startswith(ts[6], "▎ ") && occursin("citation", ts[6]) && _sty(r[6], 2).italic
    @test ts[7] == "─" ^ 40
    @test startswith(ts[8], "┄") && startswith(ts[10], "┄")
    code = r[9]
    @test _txt(code) == "@d1 p\"bd sn\" |> gain(0.8)  # commentaire"
    @test code[1].style == Tachikoma.token_style(Tachikoma.tok_macro)
    @test code[end].style == Tachikoma.token_style(Tachikoma.tok_comment)
    @test ts[11] == "texte"
    # les lignes source d'un paragraphe sont rejointes avant le repli,
    # et un gras qui enjambe deux lignes tient
    r = Ressac._md_render(["au **plus", "petit** commun", "multiple.", "", "autre"], 60)
    @test _txts(r) == ["au plus petit commun multiple.", "", "autre"]
    @test _sty(r[1], 2).bold && r[1][2].content == "plus petit"
    # une puce sur deux lignes, puis une seconde puce
    r = Ressac._md_render(["- alpha", "  beta", "- gamma"], 60)
    @test _txts(r) == ["  • alpha beta", "  • gamma"]
    # une ligne de code plus large que la pane est rognée, pas repliée
    r = Ressac._md_render(["```", "x" ^ 60, "```"], 20)
    @test length(r) == 3 && textwidth(_txt(r[2])) == 20 && endswith(_txt(r[2]), "…")
    # un paragraphe long est replié
    r = Ressac._md_render(["mot " ^ 20], 20)
    @test length(r) >= 4 && all(l -> textwidth(_txt(l)) <= 20, r)
end

@testset "tableaux — en-tête en gras, colonnes ajustées à la largeur" begin
    rows = ["| Tidal | Ressac |", "|---|---|", "| `# gain 1` | `|> gain(1)` |", "| fast 2 | fast(2) |"]
    r = Ressac._md_render(rows, 40)
    ts = _txts(r)
    @test length(r) == 4                       # en-tête, filet, deux lignes
    @test startswith(ts[1], "Tidal") && _sty(r[1], 1).bold
    @test all(==('─'), collect(ts[2]))
    @test occursin("# gain 1", ts[3]) && occursin("|> gain(1)", ts[3])
    @test _sty(r[3], 1) == Ressac._md_style(:code)
    # trop large pour 24 colonnes : les cellules se replient, rien ne dépasse, rien ne se perd
    wide = ["| a | b |", "|---|---|", "| " * "x" ^ 30 * " | " * "y" ^ 30 * " |"]
    r = Ressac._md_render(wide, 24)
    @test all(l -> textwidth(_txt(l)) <= 24, r)
    @test length(r) > 3 && count(==('x'), join(_txts(r))) == 30
    # les colonnes gardent leur mot le plus long entier quand une autre a de la marge
    r = Ressac._md_render(["| Intervalle | Description longue avec plein de mots |", "|---|---|", "| octave | rapport 2 |"], 30)
    @test startswith(_txt(r[1]), "Intervalle")
    # `\|` est un vrai `|` dans la cellule
    r = Ressac._md_render(["| a | b |", "|---|---|", "| pipe \\|> | \\| |"], 30)
    @test length(r) == 3 && occursin("pipe |>", _txt(r[3])) && endswith(rstrip(_txt(r[3])), "|")
    # une table suivie d'un paragraphe : la table se ferme
    r = Ressac._md_render(["| a |", "|---|", "| 1 |", "", "texte"], 20)
    @test _txts(r)[end] == "texte"
end

@testset "pane wiki — ScrollPane : repli, défilement borné, barre, molette" begin
    page = Ressac._WikiPage("t.md", "Test", ["un mot " ^ 30, "", "```", "@d1 \"bd\"", "```", "fin"])
    p = Ressac.WikiPane([page], 1)
    tb = Tachikoma.TestBackend(50, 8)
    rect = Tachikoma.Rect(1, 1, 50, 8)
    Ressac.render!(p, rect, tb.buf)
    lines = p.pane.content
    @test length(lines) > 6                          # le paragraphe a été replié
    @test p.rendered == (1, 47)                       # largeur intérieure moins la barre
    @test all(l -> textwidth(_txt(l)) <= 47, lines)
    # aucune ligne ne déborde de la pane
    @test all(y -> textwidth(rstrip(Tachikoma.row_text(tb, y))) <= 50, 1:8)
    # j descend, G va au bout, k remonte, g revient : tout borné par le ScrollPane
    _k(c) = Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
    _k('j'); @test p.pane.offset == 1
    _k('G'); @test p.pane.offset == length(lines) - p.pane.last_area.height
    _k('j'); @test p.pane.offset == length(lines) - p.pane.last_area.height   # butée
    _k('k'); @test p.pane.offset == length(lines) - p.pane.last_area.height - 1
    _k('g'); @test p.pane.offset == 0
    # la molette au-dessus du contenu défile
    wheel = Tachikoma.MouseEvent(10, 4, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press, false, false, false)
    @test Ressac.handle_mouse!(p, wheel) === true && p.pane.offset > 0
    # changer de page remonte en haut et re-rend
    p.pages = [page, Ressac._WikiPage("u.md", "Deux", ["court"])]
    _k('n'); Ressac.render!(p, rect, tb.buf)
    @test p.idx == 2 && p.pane.offset == 0 && p.rendered == (2, 47)
    @test Tachikoma.find_text(tb, "court") !== nothing
    @test Ressac.serialize(p)["scroll"] == 0
end

@testset "pane doc — corps markdown, exemples colorés, ScrollPane" begin
    Ressac.lookup_doc("gain") === nothing &&                      # fiches du cœur, si la suite ne les a pas déjà chargées
        Ressac._handle_docs(joinpath(@__DIR__, "..", "plugins", "core"), Dict("dir" => "docs"), "core")
    lines = Ressac._doc_pane_lines("gain", 60)
    @test lines isa Vector{Ressac._MdLine}
    @test _txt(lines[1]) == "gain"
    ex = findfirst(l -> occursin("gain(0.8)", _txt(l)), lines)
    @test ex !== nothing
    @test any(sp -> sp.style == Tachikoma.token_style(Tachikoma.tok_string), lines[ex])   # p"bd*4" en couleur chaîne
    @test all(l -> textwidth(_txt(l)) <= 60, lines)
    # une carte de son reste une liste de lignes
    card = Ressac._doc_pane_lines("bd", 40)
    @test card isa Vector{Ressac._MdLine} && !isempty(card)
    # la pane : changer de fiche remonte en haut, le contenu suit le nom
    p = Ressac.DocPane("gain")
    tb = Tachikoma.TestBackend(40, 6)                            # plus court que la fiche : ça défile
    Ressac.render!(p, Tachikoma.Rect(1, 1, 40, 6), tb.buf)
    @test Tachikoma.find_text(tb, "gain") !== nothing && p.rendered == ("gain", 37)
    Ressac.handle_key!(p, Tachikoma.KeyEvent('j')); @test p.pane.offset == 1
    p.name = "fast"
    Ressac.render!(p, Tachikoma.Rect(1, 1, 40, 6), tb.buf)
    @test p.pane.offset == 0 && p.rendered == ("fast", 37)
    @test Tachikoma.find_text(tb, "fast") !== nothing
    @test Ressac.serialize(p)["scroll"] == 0
end
