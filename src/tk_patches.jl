# src/tk_patches.jl
# Correctifs appliqués à Tachikoma à l'exécution, quand la version du
# registre ne les a pas encore. Chacun est idempotent et documente le
# défaut qu'il couvre, pour qu'on sache le retirer le jour où l'amont
# est corrigé.

# ── Cache de tokens du CodeEditor ───────────────────────────────────
# Tachikoma 2.1.0 garde un `Vector{Vector{Token}}` indexé par numéro de
# ligne et ne re-tokenise que les lignes marquées sales. Or `dd`, `o`,
# `p`, `J`… insèrent ou suppriment des lignes et ne marquent que la
# ligne du curseur : toutes celles du dessous se décalent et gardent
# la coloration de leur ancienne voisine. Le symptôme qu'on voyait :
# supprimer une ligne commentée et voir la ligne suivante rester grise,
# ou un `@d1` devenir commentaire.
#
# Ici le cache se compare au CONTENU : un hachage par ligne, tenu à
# côté de l'éditeur (pas de champ libre dans la struct), et toute
# ligne dont le hachage a changé est re-tokenisée, quel que soit son
# numéro. Le coût est un `hash` par ligne et par rendu — négligeable.
# ── Pour quelle version ──────────────────────────────────────────────
# Chaque correctif REMPLACE une fonction entière de Tachikoma par une copie
# écrite contre une version précise. Posé sur une autre version, il
# écraserait à l'aveugle un code qui a peut-être changé (ou déjà corrigé le
# défaut). Deux garde-fous :
#   • `Project.toml` épingle `Tachikoma = "=2.1.0"` ;
#   • si l'environnement en charge une autre malgré tout, les correctifs ne
#     sont PAS appliqués, et on le dit — l'app tourne avec Tachikoma tel quel.
# Monter de version = relire chaque correctif contre l'amont, puis changer
# ces deux endroits ensemble.
const _TK_PATCHED_VERSION = v"2.1.0"

"Les correctifs Tachikoma valent-ils pour la version chargée ?"
function _tk_patches_apply()
    v = pkgversion(Tachikoma)
    v == _TK_PATCHED_VERSION && return true
    _TK_VERSION_WARNED[] || @warn "Tachikoma $(v) chargé, les correctifs de Ressac sont écrits pour $(_TK_PATCHED_VERSION) : ils ne sont pas appliqués (cache de tokens, saisie UTF-8, touches SS3)."
    _TK_VERSION_WARNED[] = true
    return false
end
const _TK_VERSION_WARNED = Ref(false)

const _TK_PATCHES_INSTALLED = Ref(false)
const _TOKEN_LINE_HASHES = WeakKeyDict{TK.CodeEditor,Vector{UInt64}}()

function _install_tk_patches!()
    _TK_PATCHES_INSTALLED[] && return
    _tk_patches_apply() || return
    _TK_PATCHES_INSTALLED[] = true
    @eval Tachikoma function _ensure_tokens!(ce::CodeEditor)
        hashes = get!(() -> UInt64[], $_TOKEN_LINE_HASHES, ce)
        n = length(ce.lines)
        known = length(hashes)
        while length(ce.token_cache) < n; push!(ce.token_cache, Token[]); end
        while length(ce.token_cache) > n; pop!(ce.token_cache); end
        length(hashes) > n && resize!(hashes, n)
        for row in 1:n
            h = hash(ce.lines[row])
            if row > known || hashes[row] != h || row in ce.dirty_lines
                ce.token_cache[row] = tokenize_line(ce.lines[row])
                row > length(hashes) ? push!(hashes, h) : (hashes[row] = h)
            end
        end
        empty!(ce.dirty_lines)
        return
    end
    return nothing
end
