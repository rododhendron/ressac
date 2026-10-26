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
scope!(:global, "Partout"; layer = :global)
bind!(:global, "?", "aide"; group = :help, action = _open_help!)
bind!(:global, "!", "panic (coupe tout)"; short = "panic", group = :audio, action = _panic!)
bind!(:global, "Esc", "quitter Ressac (Échap deux fois)"; group = :misc, hint = false,
      when = m -> _km_normal(m) && !m.visual_active && m.modal === :none && !_PANE_MODE.active &&
                  !m.pending_leader && !m.placeholder_active,
      action = _esc_quit_step!)
bind!(:global, ",", "hush (laisse finir les queues)"; short = "hush", group = :audio,
      when = _km_normal, action = _hush!)
bind!(:global, "S", "scope suivant"; group = :view, when = _km_normal,
      action = m -> _scope_cycle_key!(m))
bind!(:global, ":", "commande"; group = :misc)                 # app_input.jl (structurel)
bind!(:global, "/", "rechercher"; group = :misc, hint = false)
bind!(:global, "Ctrl-p", "palette : commandes, sons, fonctions, patterns"; short = "palette",
      group = :help, when = m -> m.modal === :none, action = _open_palette!)
bind!(:global, "Ctrl-w", "mode pane"; group = :layout, hint = false)
bind!(:global, ["Ctrl-1", "Ctrl-2", "Ctrl-3", "Ctrl-4", "Ctrl-5",
                "Ctrl-6", "Ctrl-7", "Ctrl-8", "Ctrl-9"],
      "workspace 1…9"; group = :layout, hint = false)
bind!(:global, "Ctrl-f", "montrer/cacher les floats"; group = :layout, hint = false)
bind!(:global, "Ctrl-1 / :play · Ctrl-2 / :design · Ctrl-3 / :explore",
      "workspaces PLAY (patterns) · DESIGN (synth) · EXPLORE (GA)"; group = :layout, hint = false)
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
                     _push_app_log!(m, "[INFO] zoom du scope remis à 1 (X et Y)")))
bind!(:global, "+", "réservoir : plus rapide"; group = :view, hint = false, when = _km_reservoir,
      action = m -> (_APP_SCOPE_RESERVOIR_SPAN[] = clamp(_APP_SCOPE_RESERVOIR_SPAN[] / 1.5, 0.1, 60.0);
                     _push_app_log!(m, "[INFO] fenêtre du scope réservoir = $(round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)) s (plus rapide)")))
bind!(:global, "-", "réservoir : plus lent"; group = :view, hint = false, when = _km_reservoir,
      action = m -> (_APP_SCOPE_RESERVOIR_SPAN[] = clamp(_APP_SCOPE_RESERVOIR_SPAN[] * 1.5, 0.1, 60.0);
                     _push_app_log!(m, "[INFO] fenêtre du scope réservoir = $(round(_APP_SCOPE_RESERVOIR_SPAN[]; digits=2)) s (plus lente)")))

# ── :editor — commun aux panes patterns et synth (mode normal) ─────
scope!(:editor, "Éditeur (patterns et synth)"; layer = :pane)
# Tab n'a de sens que si les DEUX panes existent dans le workspace courant
# (dans DESIGN, sans pane patterns, il ne ferait rien).
_km_can_swap(m::RessacApp) = _km_normal_ed(m) && _synth_pane_open(m) &&
    _patterns_pane_present(m) && !_is_waveform_sculpt_focused(m)
bind!(:editor, "Tab", "basculer patterns ⟷ synth"; short = "patterns⟷synth", group = :nav,
      when = _km_can_swap, action = _swap_focus!)
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
bind!(:editor, ["Ctrl-d", "PgDn"], "demi-page suivante"; group = :nav, hint = false, when = _km_normal_ed,
      action = m -> (ed = _km_ed(m); _page_scroll!(m, ed, +max(1, _viewport_h(m, ed) ÷ 2))))
bind!(:editor, ["Ctrl-u", "PgUp"], "demi-page précédente"; group = :nav, hint = false, when = _km_normal_ed,
      action = m -> (ed = _km_ed(m); _page_scroll!(m, ed, -max(1, _viewport_h(m, ed) ÷ 2))))
# Moteur vim de l'éditeur (documentaire).
bind!(:editor, ["i", "a", "o", "O"], "insérer (avant / après / ligne dessous / dessus)"; group = :edit, hint = false)
bind!(:editor, "Esc", "retour au mode normal"; group = :edit, hint = false)
bind!(:editor, ["h", "j", "k", "l"], "déplacer le curseur (ou flèches)"; group = :nav, hint = false)
bind!(:editor, ["w", "b", "e"], "mot suivant / précédent / fin de mot"; group = :nav, hint = false)
bind!(:editor, ["f", "F", "t", "T"], "aller au caractère (f dessus, t avant, majuscule = à gauche)";
      group = :nav, hint = false, when = _km_normal_ed,
      action = (m, evt) -> (m.pending_find = evt.char))
bind!(:editor, ";", "refaire la recherche de caractère"; group = :nav, hint = false,
      when = m -> _km_normal_ed(m) && m.last_find !== nothing, repeat = true,
      action = m -> _repeat_find!(m, _km_ed(m), +1))
bind!(:editor, ",", "refaire la recherche de caractère, à l'envers"; group = :nav, hint = false,
      when = m -> _km_normal_ed(m) && m.last_find !== nothing, repeat = true,
      action = m -> _repeat_find!(m, _km_ed(m), -1))
bind!(:patterns, "g K", "écouter le mot sous le curseur"; short = "écouter", group = :audio, hint = false,
      when = _km_patterns, action = _preview_word_under_cursor!)
bind!(:editor, ["W", "B", "E"], "MOT (séparé par des espaces)"; group = :nav, hint = false)
bind!(:editor, ["0", "\$"], "début / fin de ligne"; group = :nav, hint = false)
bind!(:editor, ["g g", "G"], "début / fin du buffer"; group = :nav, hint = false)
bind!(:editor, ["dd", "yy", "p"], "supprimer / copier / coller la ligne"; group = :edit, hint = false)
bind!(:editor, ["cw", "dw", "yw"], "opérateur + motion (aussi b, e, W, B, E, \$, 0)"; group = :edit, hint = false)
bind!(:editor, "x", "supprimer le caractère"; group = :edit, hint = false)
bind!(:editor, "u", "annuler"; group = :edit, hint = false)

# ── Les modes : ce qui concerne le son ou la session, quelle que soit ──
# la pane focalisée. Règle : une touche de mode n'est jamais aussi une
# touche d'une pane de ce mode (test_keymap.jl le vérifie).
scope!(:mode_play, "PLAY — quelle que soit la pane"; layer = :mode)
bind!(:mode_play, "e", "évaluer la ligne"; short = "évaluer", group = :eval, when = _km_normal,
      action = _eval_current_line!)
bind!(:mode_play, "E", "tout évaluer"; group = :eval, when = _km_normal,
      action = m -> _eval_pattern_blocks!(m, :all))
bind!(:mode_play, "m", "mute / unmute le slot"; short = "mute", group = :audio, when = _km_normal,
      action = _toggle_mute_current_line!)
bind!(:mode_play, "K", "la fiche du mot sous le curseur (DOC)"; short = "fiche", group = :help, when = _km_normal,
      action = _doc_under_cursor!)
bind!(:mode_play, "Space", "snippet…"; group = :edit, when = _km_normal,
      action = m -> (m.pending_leader = true))

scope!(:mode_design, "DESIGN — quelle que soit la pane"; layer = :mode)
bind!(:mode_design, ["T", "t"], "entendre le son (maintenir = rafale)"; short = "entendre", group = :audio,
      repeat = true, when = _km_normal,
      action = (m, evt) -> _fire_t_with_accel!(m; held = evt.action === TK.key_repeat))
bind!(:mode_design, "D", "drone : tenir le son / le relâcher"; short = "drone", group = :audio,
      when = _km_normal, action = _drone_toggle!)
bind!(:mode_design, "Space", "maillon DSL…"; group = :edit, when = _km_normal,
      action = m -> (m.pending_leader = true))
bind!(:mode_design, "U", "utiliser dans un pattern (sauve + @dN dans PLAY)"; short = "→ pattern",
      group = :file, when = _km_normal, action = _design_use_in_pattern!)
bind!(:mode_design, "P", "élagage : mesurer l'impact de chaque nœud"; short = "élagage", group = :structure,
      when = _km_normal, action = _design_measure_impacts!)
bind!(:mode_design, "K", "la fiche du mot sous le curseur (DOC)"; short = "fiche", group = :help,
      when = _km_normal, action = _design_doc_tab!)
bind!(:mode_design, "X", "l'explication du son (DOC)"; short = "explication", group = :help,
      when = _km_normal, action = m -> _design_doc_mode!(m, :explain))
bind!(:mode_design, "Y", "le graphe du son (DOC)"; short = "graphe", group = :help,
      when = _km_normal, action = m -> _design_doc_mode!(m, :graph))

scope!(:mode_explore, "EXPLORE — quelle que soit la pane"; layer = :mode)
bind!(:mode_explore, ["T", "t"], "entendre le candidat"; short = "entendre", group = :audio,
      when = _km_normal, action = _explore_play!)
bind!(:mode_explore, "D", "drone du candidat on/off"; short = "drone", group = :audio,
      when = _km_normal, action = _explore_drone!)

# ── :patterns ──────────────────────────────────────────────────────
scope!(:patterns, "Pane patterns"; layer = :pane)
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
bind!(:patterns, "g s", "ouvrir le synth sous le curseur (DESIGN)"; group = :nav, hint = false,
      when = _km_patterns, action = _goto_synth_under_cursor!)

# ── :synth ─────────────────────────────────────────────────────────
scope!(:synth, "Pane synth (texte)"; layer = :pane)
bind!(:synth, "g t", "synth suivant"; group = :nav, hint = false,
      when = m -> _km_synth(m) && length(_all_synth_buffers(m)) > 1,
      action = m -> _cycle_synth_tab!(m; dir = +1))
bind!(:synth, "g T", "synth précédent"; group = :nav, hint = false,
      when = m -> _km_synth(m) && length(_all_synth_buffers(m)) > 1,
      action = m -> _cycle_synth_tab!(m; dir = -1))

# ── :leader — Space + touche (pane patterns) ───────────────────────
scope!(:leader, "Space + …"; layer = :transient)
const _LEADER_FR = Dict{Char,String}(
    'd' => "slot @dN", 'g' => "gain", 'l' => "lpf", 'h' => "hpf", 'p' => "pan",
    'f' => "fast", 's' => "slow", 'r' => "room", 'n' => "n()", 'e' => "every",
    'm' => "mask", 'D' => "chaîne delay", 'c' => "cat", 'S' => "stack", 'v' => "rev",
    'E' => "euclidien", 'R' => "euclidien tourné", 'J' => "jersey (bd(3,8))",
    'a' => "chaîne d'effets (gain, lpf, room)",
    'b' => "▸ sons (samples, instruments, synths)", 'L' => "▸ librairie synths",
    'I' => "▸ snippets", 'P' => "▸ patterns rangés", 'V' => "▸ variations du bloc", 'w' => "▸ wiki", '?' => "▸ aide",
)
for (c, _) in _LEADER_LABELS
    label = get(_LEADER_FR, c, String([c]))
    if haskey(_LEADER_ACTIONS, c)
        bind!(:leader, "Space $c", label; group = :help, action = _LEADER_ACTIONS[c],
              short = first(split(label, " (")))
    else
        tpl = _LEADER_SNIPPETS[c]
        bind!(:leader, "Space $c", label; group = :edit,
              action = m -> _expand_snippet!(m, _km_ed(m), _prefill_slot(tpl, _km_ed(m))))
    end
end

# Le leader d'un mode : les snippets de patterns dans PLAY, les maillons
# du DSL dans DESIGN (depuis n'importe quelle pane : ils vont dans le texte).
_leader_scope(m::RessacApp) = _workspace_mode(m) === :design ? :leader_synth : :leader

# Space dans DESIGN : des maillons du DSL, insérés en bout de chaîne.
scope!(:leader_synth, "Space + … (synth)"; layer = :transient)
const _LEADER_SYNTH = [
    ('s', "saw(:freq)", "source saw"), ('o', "sin_osc(:freq)", "source sin_osc"),
    ('p', "pulse(:freq, \$1)", "source pulse"), ('w', "white()", "bruit blanc"),
    ('l', "|> rlpf(\$1, 0.3)", "passe-bas résonnant"), ('h', "|> high_pass(\$1)", "passe-haut"),
    ('b', "|> band_pass(\$1, 0.5)", "passe-bande"), ('m', "|> moog_ff(\$1, 2.0)", "filtre Moog"),
    ('e', "|> env_perc(0.01, \$1)", "enveloppe percussive"), ('a', "|> env_adsr(0.01, 0.2, 0.6, \$1)", "enveloppe ADSR"),
    ('t', "|> tanh_drive(\$1)", "saturation"), ('f', "|> fold2(\$1)", "repliement"), ('c', "|> clip2(\$1)", "écrêtage"),
    ('r', "|> free_verb(0.3, \$1)", "réverb"), ('d', "|> comb_c(\$1, 2.0)", "comb / delay"),
    ('L', "lfo(\$1; low = 400, high = 2000)", "LFO"), ('n', "|> lfo(\$1)", "LFO (brut)"),
    ('g', "|> amp(\$1)", "amplitude"), ('S', "|> safe()", "sécurité"),
    ('u', "|> ugen(:\$1)", "UGen sans wrapper"),
]
for (c, tpl, label) in _LEADER_SYNTH
    bind!(:leader_synth, "Space $c", label; group = :edit, short = label,
          action = m -> _expand_snippet!(m, _km_ed(m), tpl))
end
bind!(:leader_synth, "Space ?", "▸ aide"; group = :help, action = _open_help!)

# ── Scopes documentaires (dispatch explicite dans app_input.jl) ────
scope!(:pane_mode, "Mode pane (Ctrl-w, reste actif)"; layer = :transient)
bind!(:pane_mode, "Ctrl-w s", "split horizontal"; group = :layout)
bind!(:pane_mode, "Ctrl-w v", "split vertical"; group = :layout)
bind!(:pane_mode, ["Ctrl-w h", "Ctrl-w j", "Ctrl-w k", "Ctrl-w l"], "focus ← ↓ ↑ → (ou flèches)"; group = :nav)
bind!(:pane_mode, "Ctrl-w c", "fermer la pane"; group = :layout)
bind!(:pane_mode, "Ctrl-w z", "zoom / dézoom (la pane seule à l'écran)"; group = :layout)
bind!(:pane_mode, ["Ctrl-w <", "Ctrl-w >"], "moins / plus large (5 %) — ou glisser une bordure à la souris"; short = "largeur", group = :layout)
bind!(:pane_mode, ["Ctrl-w -", "Ctrl-w +"], "moins / plus haut (5 %)"; short = "hauteur", group = :layout)
bind!(:pane_mode, "Ctrl-w =", "des parts égales"; group = :layout)
bind!(:pane_mode, "Ctrl-w r", "tourner la coupe (horizontal ⟷ vertical)"; group = :layout)
bind!(:pane_mode, ["Ctrl-w Esc", "Ctrl-w Enter", "Ctrl-w Ctrl-w"], "quitter le mode pane"; group = :layout)

scope!(:visual, "Sélection visuelle (v / V)"; layer = :transient)
bind!(:visual, ["j", "k", "h", "l"], "étendre la sélection"; group = :select)
bind!(:visual, ["d", "y", "c"], "supprimer / copier / changer"; group = :edit)
bind!(:visual, "m", "mute les slots sélectionnés"; group = :audio)
bind!(:visual, "e", "évaluer le bloc"; group = :eval)
bind!(:visual, "Esc", "annuler"; group = :select)

scope!(:insert, "Mode insertion"; layer = :transient)
bind!(:insert, "Esc", "retour au mode normal"; group = :edit)
scope!(:placeholder, "Snippet avec des trous (après Space + lettre)"; layer = :transient)
bind!(:placeholder, "Tab", "trou suivant"; group = :edit)
bind!(:placeholder, "S-Tab", "trou précédent"; group = :edit)
bind!(:placeholder, "i", "remplir le trou (insertion)"; group = :edit)
bind!(:placeholder, "u", "annuler le snippet"; group = :edit)
bind!(:placeholder, "Esc", "sortir des trous"; group = :edit)
bind!(:insert, "Tab", "compléter (ghost, identifiants) · placeholder suivant"; group = :edit)
bind!(:insert, "S-Tab", "placeholder précédent"; group = :edit)

scope!(:tap, "Tap (:tap / :bpm)"; layer = :transient)
bind!(:tap, "Space", "frapper"; group = :audio)
bind!(:tap, "Enter", "valider"; group = :audio)
bind!(:tap, "Esc", "annuler"; group = :audio)

scope!(:piano, "Piano (:piano)"; layer = :transient)
bind!(:piano, "z x c v b n m ,", "notes (rangée du bas = naturelles)"; group = :audio)
bind!(:piano, "s d g h j", "dièses"; group = :audio)
bind!(:piano, ["[", "]"], "octave − / +"; group = :audio)
bind!(:piano, "Enter", "valider l'enregistrement"; group = :audio)
bind!(:piano, "Esc", "quitter"; group = :audio)

# Entrée en mode visuel (v / V), partagée par les deux bindings.
function _visual_enter!(m::RessacApp, kind::Symbol)
    ed = _km_ed(m)
    m.visual_active = true
    m.visual_kind = kind
    m.visual_anchor_row = ed.cursor_row
    m.visual_anchor_col = ed.cursor_col
    if kind === :line
        _push_app_log!(m, "[INFO] V — sélection de lignes · j/k étend · d/y/c agit · Esc annule")
    else
        _push_app_log!(m, "[INFO] v — sélection de caractères · hjkl étend · d/y/c agit · Esc annule")
    end
    return
end
