# src/modal_reserve.jl
# La réserve : tout ce qu'on a rangé et qu'on rappelle — les sons, les
# motifs (une ligne @dN entière : pattern, son, effets), les sessions, les
# recettes. Une seule bibliothèque à onglets ; `Tab` passe de l'un à l'autre.
#
# Chaque onglet est une modale qui existait séparément (librairie de synths,
# patterns rangés, snippets) ; les sessions sont nouvelles. Elles partagent
# ici leur titre et le geste pour changer d'onglet.

const _RESERVE_TABS = ((:synth_library, "sons"), (:patterns, "motifs"),
                       (:sessions, "sessions"), (:snippets, "recettes"))

_reserve_index(modal::Symbol) = findfirst(t -> t[1] === modal, _RESERVE_TABS)

"""
    _reserve_frame!(m, buf, inner) -> TK.Rect

Dessine la bande d'onglets de la réserve sur la première ligne de `inner`
et rend ce qui reste pour le contenu de l'onglet.
"""
function _reserve_frame!(m::RessacApp, buf::TK.Buffer, inner::TK.Rect)
    inner.height < 3 && return inner
    i = something(_reserve_index(m.modal), 1)
    _render_tabs!(buf, TK.Rect(inner.x, inner.y, inner.width, 1), String[t[2] for t in _RESERVE_TABS], i)
    return TK.Rect(inner.x, inner.y + 1, inner.width, inner.height - 1)
end

function _reserve_open_tab!(m::RessacApp, modal::Symbol)
    modal === :synth_library ? _open_synth_library!(m) :
    modal === :patterns      ? _open_patterns_modal!(m) :
    modal === :sessions      ? _open_sessions_modal!(m) :
                               _open_snippets!(m)
    return
end

"""
    _reserve_cycle!(m, dir)

`Tab` / `Maj-Tab` dans la réserve : l'onglet suivant, précédent.
"""
function _reserve_cycle!(m::RessacApp, dir::Int = +1)
    i = _reserve_index(m.modal)
    i === nothing && return
    _patterns_preview_stop!(m)
    _reserve_open_tab!(m, _RESERVE_TABS[mod1(i + dir, length(_RESERVE_TABS))][1])
    return
end

# `:réserve` rouvre l'onglet où on était.
function _open_reserve!(m::RessacApp)
    _reserve_open_tab!(m, _reserve_index(m.reserve_tab) === nothing ? :patterns : m.reserve_tab)
    return
end

_bind_reserve_tabs!(scope::Symbol) = begin
    bind!(scope, "Tab", "onglet suivant de la réserve"; short = "onglet", group = :nav,
          action = m -> _reserve_cycle!(m, +1))
    bind!(scope, "S-Tab", "onglet précédent"; group = :nav, hint = false,
          action = m -> _reserve_cycle!(m, -1))
end

# ── L'onglet des sessions ────────────────────────────────────────────

function _open_sessions_modal!(m::RessacApp)
    _open_modal!(m, :sessions)
    _picker_reset!(m.sess); _picker_search!(m.sess, false)
    return
end

function _session_entries(m::RessacApp)
    names = list_sessions()
    q = _picker_query(m.sess)
    isempty(q) && return names
    return filter(n -> _fuzzy_score(q, n) !== nothing, names)
end

function _sessions_sync!(m::RessacApp, width::Int = 30)
    names = _session_entries(m)
    rows = [TK.ListItem(first((n == m.session_name ? "● " : "  ") * n, width)) for n in names]
    _picker_set!(m.sess, rows, names)
    return names
end

_session_cur(m::RessacApp) = (_sessions_sync!(m); _picker_selected(m.sess))

function _sessions_open_selected!(m::RessacApp; force::Bool = false)
    name = _session_cur(m)
    name === nothing && return
    _session_open!(m, name; force) && (m.modal = :none)
    return
end

function _sessions_delete_selected!(m::RessacApp)
    name = _session_cur(m)
    name === nothing && return
    _session_delete!(m, name)
    _sessions_sync!(m)
    return
end

function _handle_sessions_key!(m::RessacApp, evt::TK.KeyEvent)
    pk = m.sess
    if pk.searching
        if evt.key === :escape
            _picker_search!(pk, false); _picker_clear!(pk)
            return
        elseif evt.key === :enter
            _picker_search!(pk, false)
            return
        end
        _picker_type!(pk, evt) && return
    end
    if evt.key === :escape || evt.char == 'q'
        isempty(_picker_query(pk)) ? (m.modal = :none) : _picker_clear!(pk)
        return
    end
    dispatch!(((:modal_sessions, m),), evt)
    return
end

# « il y a 3 jours », pour situer une session.
function _ago(t::Real, now::Real = time())
    s = max(0, now - t)
    s < 90 && return "à l'instant"
    s < 3600 && return "il y a $(round(Int, s / 60)) min"
    s < 86400 && return "il y a $(round(Int, s / 3600)) h"
    d = round(Int, s / 86400)
    return d == 1 ? "hier" : "il y a $d jours"
end

function _render_sessions_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    n = length(_session_entries(m))
    inner = _render_modal_block!(buf, area;
        title = "RÉSERVE",
        title_right = _modal_hint_text(m, :modal_sessions),
        w_max = 110,
        h_target = max(14, min(area.height - 4, n + 9)))
    inner.width < 24 && return
    inner = _reserve_frame!(m, buf, inner)
    list_w = max(18, min(30, inner.width ÷ 3))
    names = _sessions_sync!(m, list_w - 3)
    sel = m.sess.list.selected
    _picker_render_input!(m.sess, TK.Rect(inner.x, inner.y, inner.width, 1), buf;
                          right_text = "$(n) session$(n == 1 ? "" : "s")" * (n == 0 ? "" : "  ·  $sel/$n"),
                          hint = "/ pour chercher · Entrée ouvre · x supprime")
    if n == 0
        TK.set_string!(buf, inner.x, inner.y + 2,
                       first("Aucune session rangée. « :w <nom> » range le texte des patterns.", inner.width),
                       TK.tstyle(:text_dim))
        return
    end
    body_y = inner.y + 1
    body_h = inner.height - 1
    _picker_render_list!(m.sess, TK.Rect(inner.x, body_y, list_w, body_h), buf)
    sep_x = inner.x + list_w
    for y in body_y:(body_y + body_h - 1)
        TK.set_string!(buf, sep_x, y, "│", TK.tstyle(:border))
    end
    cur = names[clamp(sel, 1, n)]
    path = _session_path(cur)
    code_x = sep_x + 2
    code_w = inner.width - list_w - 2
    TK.set_string!(buf, code_x, body_y,
                   first((cur == m.session_name ? "la session ouverte · " : "") * _ago(mtime(path)), code_w),
                   TK.tstyle(:text_dim))
    text = try read(path, String) catch; "" end
    row = 2
    for line in split(text, '\n')
        row >= body_h && break
        _md_draw_line!(buf, code_x, body_y + row, _md_code_line(String(line), code_w), code_w)
        row += 1
    end
end

scope!(:modal_sessions, "Sessions"; layer = :modal)
bind!(:modal_sessions, "Enter", "ouvrir"; short = "ouvrir", group = :file,
      action = m -> _sessions_open_selected!(m))
bind!(:modal_sessions, "!", "ouvrir en laissant ce qui n'est pas sauvé"; group = :file, hint = false,
      action = m -> _sessions_open_selected!(m; force = true))
bind!(:modal_sessions, "/", "chercher"; short = "chercher", group = :nav,
      action = m -> _picker_search!(m.sess, true))
mixin_list_nav!(:modal_sessions, (m, key) -> _picker_nav!(m.sess, key); before = _sessions_sync!)
bind!(:modal_sessions, "x", "supprimer"; group = :edit,
      action = m -> _sessions_delete_selected!(m))
_bind_reserve_tabs!(:modal_sessions)
_bind_modal_common!(:modal_sessions)

# ── Écouter un motif avant de le poser ───────────────────────────────

# Le slot d'écoute : hors de portée des lignes qu'on écrit.
const _PREVIEW_SLOT = 64

"""
    _patterns_preview_toggle!(m)

`Espace` sur un motif rangé : il joue sur un slot à part, par-dessus ce qui
tourne ; `Espace` de nouveau, ou sortir de la réserve, l'arrête.
"""
function _patterns_preview_toggle!(m::RessacApp)
    if m.pat_preview
        _patterns_preview_stop!(m)
        return
    end
    e = _pattern_cur(m)
    e === nothing && return
    try
        Core.eval(Main, Meta.parse(retarget_pattern(e.code, _PREVIEW_SLOT)))
        m.pat_preview = true
        _push_app_log!(m, "[INFO] écoute de « $(e.name) » — Espace l'arrête")
    catch err
        _push_app_log!(m, "[ERROR] « $(e.name) » ne s'évalue pas : $(_humanize_eval_error(err, e.code))")
    end
    return
end

function _patterns_preview_stop!(m::RessacApp)
    m.pat_preview || return
    m.pat_preview = false
    unset_pattern!(m.scheduler, Symbol("d", _PREVIEW_SLOT))
    return
end
