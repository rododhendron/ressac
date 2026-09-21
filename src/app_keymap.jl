# src/app_keymap.jl
# Déclaration des bindings côté app (scopes :global, :editor, :patterns,
# :synth, :leader, et les scopes documentaires :pane_mode, :visual,
# :insert, :tap, :piano). Les panes et les modaux déclarent les leurs
# dans leur fichier. L'ordre de déclaration = ordre dans la barre de
# touches. Les prédicats `when` reproduisent les gardes historiques du
# routage clavier (mode normal, pane ouverte, nombre sous le curseur…).
#
# Une entrée SANS action est documentaire : la touche est exécutée par
# le moteur vim de l'éditeur Tachikoma ou par le routage structurel de
# app_input.jl (barre de commande, panic, mode pane, workspaces).

# ── Prédicats ──────────────────────────────────────────────────────
_km_ed(m::RessacApp) = _active_editor(m)
# Mode normal, ou pas d'éditeur du tout (pane log/doc/explorer focalisée).
_km_normal(m::RessacApp) = ((ed = _km_ed(m)) === nothing || ed.mode === :normal)
_km_normal_ed(m::RessacApp) = ((ed = _km_ed(m)) !== nothing && ed.mode === :normal)
_km_patterns(m::RessacApp) = _km_normal_ed(m) && _focused_role(m) === :patterns
_km_synth(m::RessacApp)    = _km_normal_ed(m) && _focused_role(m) === :synth
_km_in_pattern(m::RessacApp) = _km_patterns(m) && _pat_at_cursor(_km_ed(m)) !== nothing
_km_number(m::RessacApp)   = _km_normal_ed(m) && _has_number_under_cursor(_km_ed(m))
_km_wave(m::RessacApp)     = _km_normal(m) && _APP_SCOPE_TYPE[] === :wave
_km_reservoir(m::RessacApp) = _km_normal(m) &&
    (_APP_SCOPE_TYPE[] === :reservoir || _APP_SCOPE_TYPE[] === Symbol("reservoir-graph"))

# ── :global — partout où l'on n'est pas en train de taper du texte ──
scope!(:global, "Partout")
bind!(:global, "?", "aide"; group = :help, action = _open_help!)
bind!(:global, "!", "panic (coupe tout)"; short = "panic", group = :audio, action = _panic!)
bind!(:global, ",", "hush (laisse finir les queues)"; short = "hush", group = :audio,
      when = _km_normal, action = _hush!)
bind!(:global, "S", "scope suivant"; group = :view, when = _km_normal,
      action = m -> _scope_cycle_key!(m))
bind!(:global, ":", "commande"; group = :misc)                 # app_input.jl (structurel)
bind!(:global, "/", "rechercher"; group = :misc, hint = false)
bind!(:global, "Ctrl-w", "mode pane"; group = :layout, hint = false)
bind!(:global, ["Ctrl-1", "Ctrl-2", "Ctrl-3", "Ctrl-4", "Ctrl-5",
                "Ctrl-6", "Ctrl-7", "Ctrl-8", "Ctrl-9"],
      "workspace 1…9"; group = :layout, hint = false)
bind!(:global, "Ctrl-f", "montrer/cacher les floats"; group = :layout, hint = false)
# Zoom du scope :wave / vitesse du scope réservoir. Après le nudge des
# nombres de :editor (même touches, garde « nombre sous le curseur »).
bind!(:global, "+", "scope : zoom Y +"; group = :view, hint = false, when = _km_wave,
      action = m -> (m.scope_zoom = clamp(m.scope_zoom * 1.5, 0.1, 32.0);
                     _push_app_log!(m, "[INFO] scope Y-zoom ×$(round(m.scope_zoom; digits=2))")))
bind!(:global, "-", "scope : zoom Y −"; group = :view, hint = false, when = _km_wave,
      action = m -> (m.scope_zoom = clamp(m.scope_zoom / 1.5, 0.1, 32.0);
                     _push_app_log!(m, "[INFO] scope Y-zoom ×$(round(m.scope_zoom; digits=2))")))
bind!(:global, ">", "scope : zoom X +"; group = :view, hint = false, when = _km_wave,
      action = m -> (m.scope_zoom_x = clamp(m.scope_zoom_x * 1.5, 0.1, 32.0);
                     _push_app_log!(m, "[INFO] scope X-zoom ×$(round(m.scope_zoom_x; digits=2))")))
bind!(:global, "<", "scope : zoom X −"; group = :view, hint = false, when = _km_wave,
      action = m -> (m.scope_zoom_x = clamp(m.scope_zoom_x / 1.5, 0.1, 32.0);
                     _push_app_log!(m, "[INFO] scope X-zoom ×$(round(m.scope_zoom_x; digits=2))")))
bind!(:global, "=", "scope : zoom reset"; group = :view, hint = false, when = _km_wave,
      action = m -> (m.scope_zoom = 1.0; m.scope_zoom_x = 1.0;
                     _push_app_log!(m, "[INFO] scope zoom reset (X & Y)")))
bind!(:global, "+", "réservoir : plus rapide"; group = :view, hint = false, when = _km_reservoir,
      action = m -> (_APP_SCOPE_RESERVOIR_SPAN[] = clamp(_APP_SCOPE_RESERVOIR_SPAN[] / 1.5, 0.1, 60.0);
                     _push_app_log!(m, "[INFO] reservoir scope span = $(round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)) s (faster)")))
bind!(:global, "-", "réservoir : plus lent"; group = :view, hint = false, when = _km_reservoir,
      action = m -> (_APP_SCOPE_RESERVOIR_SPAN[] = clamp(_APP_SCOPE_RESERVOIR_SPAN[] * 1.5, 0.1, 60.0);
                     _push_app_log!(m, "[INFO] reservoir scope span = $(round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)) s (slower)")))

# ── :editor — commun aux panes patterns et synth (mode normal) ─────
scope!(:editor, "Éditeur (patterns et synth)")
bind!(:editor, "Tab", "basculer patterns ⟷ synth"; short = "patterns⟷synth", group = :nav,
      when = m -> _km_normal_ed(m) && _synth_pane_open(m) && !_is_waveform_sculpt_focused(m),
      action = _swap_focus!)
bind!(:editor, ".", "répéter la dernière édition"; group = :edit, hint = false,
      when = _km_normal_ed, action = m -> _vim_replay!(m, _km_ed(m)))
bind!(:editor, "v", "sélection visuelle (caractères)"; group = :select, hint = false,
      when = m -> _km_normal_ed(m) && !m.visual_active,
      action = m -> _visual_enter!(m, :char))
bind!(:editor, "V", "sélection visuelle (lignes)"; group = :select, hint = false,
      when = m -> _km_normal_ed(m) && !m.visual_active,
      action = m -> _visual_enter!(m, :line))
# Nudge du nombre sous le curseur : maintenu = scrub.
bind!(:editor, "+", "nombre +1 (maintenir = scrub)"; group = :edit, hint = false, repeat = true,
      when = _km_number, action = m -> _nudge_number_under_cursor!(m, _km_ed(m), +1))
bind!(:editor, "-", "nombre −1"; group = :edit, hint = false, repeat = true,
      when = _km_number, action = m -> _nudge_number_under_cursor!(m, _km_ed(m), -1))
bind!(:editor, "*", "nombre +10"; group = :edit, hint = false, repeat = true,
      when = _km_number, action = m -> _nudge_number_under_cursor!(m, _km_ed(m), +10))
bind!(:editor, "/", "nombre −10"; group = :edit, hint = false, repeat = true,
      when = _km_number, action = m -> _nudge_number_under_cursor!(m, _km_ed(m), -10))
bind!(:editor, "PgDn", "page suivante"; group = :nav, hint = false, when = _km_normal_ed,
      action = m -> (ed = _km_ed(m); _page_scroll!(m, ed, +_viewport_h(m, ed))))
bind!(:editor, "PgUp", "page précédente"; group = :nav, hint = false, when = _km_normal_ed,
      action = m -> (ed = _km_ed(m); _page_scroll!(m, ed, -_viewport_h(m, ed))))
bind!(:editor, "Ctrl-d", "demi-page suivante"; group = :nav, hint = false, when = _km_normal_ed,
      action = m -> (ed = _km_ed(m); _page_scroll!(m, ed, +max(1, _viewport_h(m, ed) ÷ 2))))
bind!(:editor, "Ctrl-u", "demi-page précédente"; group = :nav, hint = false, when = _km_normal_ed,
      action = m -> (ed = _km_ed(m); _page_scroll!(m, ed, -max(1, _viewport_h(m, ed) ÷ 2))))
# Moteur vim de l'éditeur (documentaire).
bind!(:editor, ["i", "a", "o", "O"], "insérer (avant / après / ligne dessous / dessus)"; group = :edit, hint = false)
bind!(:editor, "Esc", "retour au mode normal"; group = :edit, hint = false)
bind!(:editor, ["h", "j", "k", "l"], "déplacer le curseur (ou flèches)"; group = :nav, hint = false)
bind!(:editor, ["w", "b", "e"], "mot suivant / précédent / fin de mot"; group = :nav, hint = false)
bind!(:editor, ["W", "B", "E"], "MOT (séparé par des espaces)"; group = :nav, hint = false)
bind!(:editor, ["0", "\$"], "début / fin de ligne"; group = :nav, hint = false)
bind!(:editor, ["g g", "G"], "début / fin du buffer"; group = :nav, hint = false)
bind!(:editor, ["dd", "yy", "p"], "supprimer / copier / coller la ligne"; group = :edit, hint = false)
bind!(:editor, ["cw", "dw", "yw"], "opérateur + motion (aussi b, e, W, B, E, \$, 0)"; group = :edit, hint = false)
bind!(:editor, "x", "supprimer le caractère"; group = :edit, hint = false)
bind!(:editor, "u", "annuler"; group = :edit, hint = false)

# ── :patterns ──────────────────────────────────────────────────────
scope!(:patterns, "Pane patterns")
bind!(:patterns, "e", "évaluer la ligne"; short = "évaluer", group = :eval, when = _km_patterns,
      action = _eval_current_line!)
bind!(:patterns, "E", "tout évaluer"; group = :eval, when = _km_patterns,
      action = m -> _eval_pattern_blocks!(m, :all))
bind!(:patterns, "m", "mute / unmute le slot"; short = "mute", group = :audio, when = _km_patterns,
      action = _toggle_mute_current_line!)
bind!(:patterns, "K", "écouter le mot sous le curseur"; short = "écouter", group = :audio, when = _km_patterns,
      action = _preview_word_under_cursor!)
bind!(:patterns, "Space", "snippet…"; group = :edit,
      when = m -> _km_patterns(m) && !m.tap_recording,
      action = m -> (m.pending_leader = true))
bind!(:patterns, ">", "pattern : zoom ×2"; group = :edit, hint = false, when = _km_in_pattern,
      action = m -> _pat_zoom!(m, _km_ed(m), +1))
bind!(:patterns, "<", "pattern : zoom ÷2"; group = :edit, hint = false, when = _km_in_pattern,
      action = m -> _pat_zoom!(m, _km_ed(m), -1))
bind!(:patterns, "L", "pattern : décaler le token →"; group = :edit, hint = false, when = _km_in_pattern,
      action = m -> _pat_shift!(m, _km_ed(m), +1))
bind!(:patterns, "H", "pattern : décaler le token ←"; group = :edit, hint = false, when = _km_in_pattern,
      action = m -> _pat_shift!(m, _km_ed(m), -1))
bind!(:patterns, "X", "pattern : silence le token (~)"; group = :edit, hint = false, when = _km_in_pattern,
      action = m -> _pat_silence!(m, _km_ed(m)))

# ── :synth ─────────────────────────────────────────────────────────
scope!(:synth, "Pane synth")
bind!(:synth, ["t", "T", "Space"], "tester le synth (maintenir = rafale)"; short = "tester", group = :audio,
      repeat = true, when = _km_synth,
      action = (m, evt) -> _fire_t_with_accel!(m; held = evt.action === TK.key_repeat))
bind!(:synth, "g t", "synth suivant"; group = :nav, hint = false,
      when = m -> _km_synth(m) && length(_all_synth_buffers(m)) > 1,
      action = m -> _cycle_synth_tab!(m; dir = +1))
bind!(:synth, "g T", "synth précédent"; group = :nav, hint = false,
      when = m -> _km_synth(m) && length(_all_synth_buffers(m)) > 1,
      action = m -> _cycle_synth_tab!(m; dir = -1))

# ── :leader — Space + touche (pane patterns) ───────────────────────
scope!(:leader, "Space + …")
const _LEADER_FR = Dict{Char,String}(
    'd' => "slot @dN", 'g' => "gain", 'l' => "lpf", 'h' => "hpf", 'p' => "pan",
    'f' => "fast", 's' => "slow", 'r' => "room", 'n' => "n()", 'e' => "every",
    'm' => "mask", 'D' => "chaîne delay", 'c' => "cat", 'S' => "stack", 'v' => "rev",
    'E' => "euclidien", 'R' => "euclidien tourné", 'J' => "jersey (bd(3,8))",
    'b' => "▸ sons (samples, instruments, synths)", 'L' => "▸ librairie synths",
    'I' => "▸ snippets", 'w' => "▸ wiki", '?' => "▸ aide",
)
for (c, _) in _LEADER_LABELS
    label = get(_LEADER_FR, c, String([c]))
    if haskey(_LEADER_ACTIONS, c)
        bind!(:leader, "Space $c", label; group = :help, action = _LEADER_ACTIONS[c],
              short = first(split(label, " (")))
    else
        tpl = _LEADER_SNIPPETS[c]
        bind!(:leader, "Space $c", label; group = :edit,
              action = m -> _expand_snippet!(m, _km_ed(m), tpl))
    end
end

# ── Scopes documentaires (dispatch explicite dans app_input.jl) ────
scope!(:pane_mode, "Mode pane (Ctrl-w, reste actif)")
bind!(:pane_mode, "Ctrl-w s", "split horizontal"; group = :layout)
bind!(:pane_mode, "Ctrl-w v", "split vertical"; group = :layout)
bind!(:pane_mode, ["Ctrl-w h", "Ctrl-w j", "Ctrl-w k", "Ctrl-w l"], "focus ← ↓ ↑ → (ou flèches)"; group = :nav)
bind!(:pane_mode, "Ctrl-w c", "fermer la pane"; group = :layout)
bind!(:pane_mode, ["Ctrl-w Esc", "Ctrl-w Enter", "Ctrl-w Ctrl-w"], "quitter le mode pane"; group = :layout)

scope!(:visual, "Sélection visuelle (v / V)")
bind!(:visual, ["j", "k", "h", "l"], "étendre la sélection"; group = :select)
bind!(:visual, ["d", "y", "c"], "supprimer / copier / changer"; group = :edit)
bind!(:visual, "m", "mute les slots sélectionnés"; group = :audio)
bind!(:visual, "e", "évaluer le bloc"; group = :eval)
bind!(:visual, "Esc", "annuler"; group = :select)

scope!(:insert, "Mode insertion")
bind!(:insert, "Esc", "retour au mode normal"; group = :edit)
bind!(:insert, "Tab", "compléter (ghost, identifiants) · placeholder suivant"; group = :edit)
bind!(:insert, "S-Tab", "placeholder précédent"; group = :edit)

scope!(:tap, "Tap (:tap / :bpm)")
bind!(:tap, "Space", "frapper"; group = :audio)
bind!(:tap, "Enter", "valider"; group = :audio)
bind!(:tap, "Esc", "annuler"; group = :audio)

scope!(:piano, "Piano (:piano)")
bind!(:piano, "z x c v b n m ,", "notes (rangée du bas = naturelles)"; group = :audio)
bind!(:piano, "s d g h j", "dièses"; group = :audio)
bind!(:piano, ["[", "]"], "octave − / +"; group = :audio)
bind!(:piano, "Enter", "valider l'enregistrement"; group = :audio)
bind!(:piano, "Esc", "quitter"; group = :audio)

# Ordre des couches dispatchées depuis le flux éditeur.
function _editor_layers(m::RessacApp)
    role = _focused_role(m)
    return ((role === :synth ? :synth : :patterns, m), (:editor, m), (:global, m))
end

# Entrée en mode visuel (v / V), partagée par les deux bindings.
function _visual_enter!(m::RessacApp, kind::Symbol)
    ed = _km_ed(m)
    m.visual_active = true
    m.visual_kind = kind
    m.visual_anchor_row = ed.cursor_row
    m.visual_anchor_col = ed.cursor_col
    if kind === :line
        _push_app_log!(m, "[INFO] V — visual line · j/k extend · d/y/c act · Esc cancel")
    else
        _push_app_log!(m, "[INFO] v — visual char · hjkl extend · d/y/c act · Esc cancel")
    end
    return
end
