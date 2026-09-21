# src/modal_sculpt.jl
# Sculpt studio — le modal plein écran (`:sculpt` / explorer `M`) : une
# WaveformPane en mode sculpt (onde + knobs) à gauche, l'explainer prose à
# droite. Toute la LOGIQUE sculpt vit dans pane_waveform.jl / wave_sculpt.jl ;
# ce fichier ne fait que l'orchestration modale (ouverture, routage clavier,
# rendu, commandes :sculpt / :w). Inclus depuis tui_app.jl après les autres
# modaux — s'appuie sur _render_modal_block!, _register_*!, _push_app_log!…
# (tous résolus au runtime ou définis avant le point d'inclusion).

"""
    _open_sculpt_modal!(m, gser, label) -> Bool

Open the fullscreen **sculpt studio** modal : a WaveformPane in sculpt
mode (`gser` = serialized genome) plus the explainer prose alongside.
"""
function _open_sculpt_modal!(m::RessacApp, gser, label::AbstractString)
    p = _pane_new(:waveform,
                  Dict{String,Any}("genome" => gser, "label" => label, "sculpt" => true))
    p isa WaveformPane || return false
    # Un studio pouvait déjà être ouvert : on signale à son worker de rendu
    # d'abandonner avant de le remplacer (sinon thread orphelin).
    m.sculpt_pane !== nothing && on_close!(m.sculpt_pane)
    m.sculpt_pane = p
    m.explain_lines = p.genome === nothing ? String["(génome indisponible)"] :
                      explain_genome(p.genome)
    m.modal = :sculpt
    m.modal_scroll = 0
    return true
end

"""
    _drain_explorer_sculpt!(m) -> Bool

Open the sculpt studio modal for a genome posted by the explorer (`M`).
"""
function _drain_explorer_sculpt!(m::RessacApp)
    req = _EXPLORER_SCULPT_REQUEST[]
    req === nothing && return false
    _EXPLORER_SCULPT_REQUEST[] = nothing
    gser, label = req
    _open_sculpt_modal!(m, gser, label)
    return true
end

# ── Sculpt : :sculpt [nom] ──────────────────────────────────────────
# Ouvre un synth en mode sculpt. `:sculpt <nom>` lit
# plugins/user-synths/<nom>.jl ; `:sculpt` seul prend le buffer focalisé.
function _sculpt_command!(m::RessacApp, name::AbstractString)
    nm = strip(String(name))
    g = if isempty(nm)
        ed = _active_editor(m)
        ed === nothing ? nothing : genome_from_dsl(TK.text(ed))
    else
        path = joinpath(pwd(), "plugins", "user-synths", "$nm.jl")
        if isfile(path)
            txt = read(path, String)
            gg = genome_from_text(txt)            # génome embarqué (exports récents)
            gg === nothing ? genome_from_dsl(txt) : gg   # sinon parse le DSL nu
        else
            nothing
        end
    end
    g === nothing &&
        (_push_app_log!(m, "[ERROR] :sculpt — pas un synth DSL reconnu"); return)
    _open_sculpt_modal!(m, serialize_genome(g), isempty(nm) ? "buffer" : nm)
    return
end
_register_literal!(m -> _sculpt_command!(m, ""), "sculpt")
_register_regex!(r"^sculpt\s+([\w.-]+)$",
    (m, mt) -> _sculpt_command!(m, mt.captures[1]))

# Sauve le génome sculpté du studio en synth DSL (.jl) avec génome embarqué
# → rejouable (:synth) et re-sculptable (:sculpt). `name` vide = label courant.
function _save_sculpt!(m::RessacApp, name::AbstractString)
    p = m.sculpt_pane
    (p === nothing || p.genome === nothing) &&
        (_push_app_log!(m, "[ERROR] :w — pas de sculpt actif"); return)
    nm = strip(String(name))
    isempty(nm) && (nm = replace(p.label, r"[^\w]" => "_"))
    sym = Symbol(nm)
    dsl = render_dsl(p.genome, sym) * "\n" * genome_comment(p.genome) * "\n"
    path = _app_synth_path(nm; mode = :dsl)
    isdir(dirname(path)) || mkpath(dirname(path))
    write(path, dsl)
    register_synth!(SynthEntry(sym, "user-synths",
        Dict{String,Any}("description" => "sculpted synth",
                         "tags" => ["user", "dsl", "sculpt"])))
    p.label = nm
    _push_app_log!(m, "[INFO] sculpt sauvé → $path")
    return
end

# ── Routage clavier du modal ───────────────────────────────────────
# Esc/q ferment — sauf pendant une saisie de valeur (Esc l'annule alors).
# `<`/`>` font défiler l'explainer ; tout le reste va à la WaveformPane.
"""
    _close_sculpt_modal!(m)

Ferme proprement le studio sculpt : signale au worker de rendu d'abandonner
(`on_close!` pose `closed`, le worker jette son résultat) puis relâche le pane
(pas de rétention du génome + samples pour toute la session). Idempotent.
"""
function _close_sculpt_modal!(m::RessacApp)
    m.sculpt_pane !== nothing && on_close!(m.sculpt_pane)
    m.sculpt_pane = nothing
    m.modal = :none
    m.modal_scroll = 0
    return
end

function _handle_sculpt_key!(m::RessacApp, evt::TK.KeyEvent)
    p = m.sculpt_pane
    p === nothing && (m.modal = :none; return)
    # Touches du studio (fermer, défiler l'explication) puis celles de
    # la pane sculpt elle-même (scope :sculpt).
    dispatch!(((:modal_sculpt, m),), evt) && return
    handle_key!(p, evt)
    # Édit structurel (swap/insert d'UGen…) → la structure a changé : on
    # rafraîchit la prose de l'explainer à droite (et on remonte le scroll).
    if p.structure_dirty
        p.genome === nothing || (m.explain_lines = explain_genome(p.genome))
        p.structure_dirty = false
        m.modal_scroll = 0
    end
    # `e` (export) posté par la pane → on draine ICI (le drain habituel ne
    # tourne pas en contexte modal) et on ferme le studio pour voir l'éditeur :
    # l'utilisateur sauve ensuite avec `:w <nom>` (→ plugins/user-synths/).
    if _EXPLORER_EXPORT_REQUEST[] !== nothing
        _close_sculpt_modal!(m)
        _drain_explorer_export!(m)
    end
    return
end

# ── Rendu du modal ─────────────────────────────────────────────────
"""
    _render_sculpt_modal!(m, area, buf)

Plein écran : onde en haut, puis knobs groupés par fonction (gauche) ⟷
explainer (droite). Réutilise toute la logique sculpt de la WaveformPane.
"""
function _render_sculpt_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    p = m.sculpt_pane
    p === nothing && (m.modal = :none; return)
    p.sculpt && _sculpt_pump!(p)             # consomme un re-render prêt
    busy = _sculpt_busy(p) ? " ↻" : ""
    inner = _render_modal_block!(buf, area;
        title = "SCULPT · $(p.label)$busy",
        title_right = "j/k·Tab nav · h/l tire · = val · édit n/o/d/i/r/x/m · ␣ joue · </> doc · e export · Esc",
        w_max = max(60, area.width - 4),
        h_target = max(12, area.height - 4))
    (inner.width < 8 || inner.height < 6) && return
    # 1. onde (tiers supérieur)
    waveh = clamp(inner.height ÷ 3, 3, inner.height - 5)
    warea = TK.Rect(inner.x, inner.y, inner.width, waveh)
    if !isempty(p.samples)
        p.last_rect = (warea.x, warea.y, warea.width, waveh)
        _render_wave_buffer!(p, warea, buf)
    else
        TK.set_string!(buf, inner.x, inner.y, "  (rendu en cours / indisponible)", TK.tstyle(:text_dim))
    end
    # séparateur + légende persistante des édits structurels (si ça tient)
    sepy = inner.y + waveh
    TK.set_string!(buf, inner.x, sepy, "─"^inner.width, TK.tstyle(:text_dim))
    legend = "─ édit: n new · o swap · d del · i input · r rate · x dup · m mod ─"
    textwidth(legend) + 2 < inner.width &&
        TK.set_string!(buf, inner.x + 2, sepy, legend, TK.tstyle(:text_dim))
    # 2. zone basse : knobs (gauche) | explainer (droite)
    bottomy = sepy + 1
    bottomh = inner.y + inner.height - bottomy
    bottomh < 2 && return
    kw = clamp(inner.width ÷ 2, 16, inner.width - 10)
    _render_sculpt_knobs!(p, TK.Rect(inner.x, bottomy, kw - 1, bottomh), buf)
    # cloison verticale
    for yy in bottomy:(bottomy + bottomh - 1)
        TK.set_string!(buf, inner.x + kw, yy, "│", TK.tstyle(:text_dim))
    end
    _render_sculpt_explain!(m, TK.Rect(inner.x + kw + 2, bottomy,
                                       inner.width - kw - 2, bottomh), buf)
    return
end

# Knobs groupés par fonction ; le focalisé surligné (+ saisie en cours). Pour
# un knob-nœud on montre l'UGen porteur (‹RLPF 2/5›) → feedback de o/O/n.
function _render_sculpt_knobs!(p::WaveformPane, area::TK.Rect, buf::TK.Buffer)
    p.genome === nothing && return
    groups = knob_groups(p.genome, p.knobs)
    y = area.y
    for (label, idxs) in groups
        y >= area.y + area.height && break
        # entête de groupe : nom + UGen du 1er knob-nœud du groupe
        gtag = isempty(idxs) ? "" : _sculpt_ugen_tag(p, p.knobs[idxs[1]])
        TK.set_string!(buf, area.x, y, first("▸ $label$gtag", area.width), TK.tstyle(:text_dim))
        y += 1
        for i in idxs
            y >= area.y + area.height && break
            kb = p.knobs[i]
            mark = i == p.focus ? "◉" : (get(p.strength, i, 1.0) > 0.5 ? "●" : "·")
            val = if i == p.focus && p.value_edit
                "= $(p.value_buf)▏"
            else
                string(round(knob_value(p.genome, kb); sigdigits = 5))
            end
            row = "  $mark $(rpad(String(kb.name), 8)) $val"
            sty = i == p.focus ? TK.tstyle(:primary) : TK.tstyle(:text)
            TK.set_string!(buf, area.x, y, first(row, area.width), sty)
            y += 1
        end
    end
end

# Prose de l'explainer (défilable via </>), depuis m.explain_lines.
function _render_sculpt_explain!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    lines = m.explain_lines
    isempty(lines) && return
    start = clamp(m.modal_scroll + 1, 1, max(1, length(lines)))
    for i in 0:(area.height - 1)
        idx = start + i
        idx > length(lines) && break
        TK.set_string!(buf, area.x, area.y + i, first(lines[idx], area.width), TK.tstyle(:text))
    end
end

# ── Registre : touches propres au studio (la pane a le scope :sculpt) ──
_sculpt_not_editing(m::RessacApp) = (p = m.sculpt_pane; p === nothing || !(p.sculpt && p.value_edit))
scope!(:modal_sculpt, "Studio sculpt")
bind!(:modal_sculpt, ["Esc", "q"], "fermer le studio"; group = :nav,
      when = _sculpt_not_editing, action = _close_sculpt_modal!)
bind!(:modal_sculpt, "?", "aide"; group = :help, when = _sculpt_not_editing, action = _open_help!)
bind!(:modal_sculpt, [">", "<"], "défiler l'explication"; group = :view,
      when = _sculpt_not_editing,
      action = (m, evt) -> (m.modal_scroll = evt.char == '>' ?
          min(m.modal_scroll + 1, max(0, length(m.explain_lines) - 1)) :
          max(0, m.modal_scroll - 1)))
