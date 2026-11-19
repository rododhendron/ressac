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
bind!(:global, "/", "chercher dans le texte (n / N : occurrence suivante / précédente)"; short = "chercher", group = :misc, hint = false)
bind!(:global, "Ctrl-p", "palette : commandes, sons, fonctions, patterns"; short = "palette",
      group = :help, when = m -> m.modal === :none, action = _open_palette!)
bind!(:global, "Ctrl-w", "mode pane"; group = :layout, hint = false)
bind!(:global, "Ctrl-f", "montrer/cacher les floats"; group = :layout, hint = false)
bind!(:global, ":son · :wiki · :explorer · :back",
      "le volet à droite des patterns : un son, le wiki, l'explorateur — :back (ou :q) le referme"; group = :layout, hint = false)
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
    _patterns_pane_present(m)
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
bind!(:editor, "g c", "commenter / décommenter : gcc la ligne, gcj gck avec la voisine, gcap le paragraphe";
      short = "commenter", group = :edit, hint = false, when = _km_normal_ed,
      action = m -> (m.pending_gc = ""))
bind!(:editor, ["dd", "yy", "p"], "supprimer / copier / coller la ligne"; group = :edit, hint = false)
bind!(:editor, ["cw", "dw", "yw"], "opérateur + motion (aussi b, e, W, B, E, \$, 0)"; group = :edit, hint = false)
bind!(:editor, "x", "supprimer le caractère"; group = :edit, hint = false)
bind!(:editor, "u", "annuler"; group = :edit, hint = false)

# ── Les modes : ce qui concerne le son ou la session, quelle que soit ──
# la pane focalisée. Règle : une touche de mode n'est jamais aussi une
# touche d'une pane de ce mode (test_keymap.jl le vérifie).
scope!(:mode_play, "PATTERNS — d'où qu'on soit (fiche, wiki, journal)"; layer = :mode, modes = (:play,))
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

scope!(:mode_design, "SON — depuis le texte ou sa DOC"; layer = :mode, modes = (:design,))
bind!(:mode_design, ["T", "t"], "entendre le son (maintenir = rafale)"; short = "entendre", group = :audio,
      repeat = true, when = _km_normal,
      action = (m, evt) -> _fire_t_with_accel!(m; held = evt.action === TK.key_repeat))
bind!(:mode_design, "D", "drone : tenir le son / le relâcher"; short = "drone", group = :audio,
      when = _km_normal, action = _drone_toggle!)
bind!(:mode_design, "Space", "maillon DSL…"; group = :edit, when = _km_normal,
      action = m -> (m.pending_leader = true))
bind!(:mode_design, "U", "utiliser dans un pattern (sauve + @dN à gauche)"; short = "→ pattern",
      group = :file, when = _km_normal, action = _design_use_in_pattern!)
bind!(:mode_design, "P", "élagage : mesurer ce que chaque étape change (:prune retire le reste)"; short = "élagage", group = :structure,
      when = _km_normal, action = _design_measure_impacts!)
bind!(:mode_design, "K", "la fiche du mot sous le curseur (DOC)"; short = "fiche", group = :help,
      when = _km_normal, action = _design_doc_tab!)
bind!(:mode_design, "X", "l'explication du son (DOC)"; short = "explication", group = :help,
      when = _km_normal, action = m -> _design_doc_mode!(m, :explain))
bind!(:mode_design, "Y", "le graphe du son (DOC)"; short = "graphe", group = :help,
      when = _km_normal, action = m -> _design_doc_mode!(m, :graph))

scope!(:mode_explore, "EXPLORATEUR"; layer = :mode, modes = (:explore,))
bind!(:mode_explore, ["T", "t"], "entendre le candidat"; short = "entendre", group = :audio,
      when = _km_normal, action = _explore_play!)
bind!(:mode_explore, "D", "drone du candidat on/off"; short = "drone", group = :audio,
      when = _km_normal, action = _explore_drone!)

# ── :patterns ──────────────────────────────────────────────────────
scope!(:patterns, "Pane patterns"; layer = :pane, modes = (:play,))
bind!(:patterns, "Enter", "évaluer la ligne maintenant : elle part de la frappe, hors de la grille"; short = "maintenant",
      group = :eval, when = _km_patterns, action = _eval_current_line_now!)
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
bind!(:patterns, "g s", "ouvrir le son sous le curseur, à droite"; short = "son", group = :nav,
      when = _km_patterns, action = _goto_synth_under_cursor!)
bind!(:patterns, "g w", "ouvrir le wiki, à droite"; short = "wiki", group = :nav,
      when = _km_patterns, action = m -> _open_wiki!(m))
bind!(:patterns, "g x", "ouvrir l'explorateur de sons"; group = :nav, hint = false,
      when = _km_patterns, action = m -> _explore_slot_open!(m))
bind!(:mode_explore, "Enter", "adopter ce candidat : le slot le joue, il est rangé"; short = "adopter", group = :file,
      when = m -> m.explore_slot !== nothing, action = _explore_slot_adopt!)

# ── :synth ─────────────────────────────────────────────────────────
scope!(:synth, "Pane synth (texte)"; layer = :pane, modes = (:design,))
# L'atelier (atelier.jl) : sur un maillon, `o` / `O` proposent ce qui peut
# suivre ou précéder — et le font entendre. Ailleurs, ce sont ceux de vim.
_km_on_link(m::RessacApp) = _focused_role(m) === :synth && _km_normal_ed(m) &&
    (l = _link_at(_km_ed(m)); l !== nothing && l.linewise && _in_synth_chain(_km_ed(m)))
bind!(:synth, "o", "atelier : un maillon après (il s'entend avant d'être gardé)"; short = "maillon après",
      group = :structure, when = _km_on_link, action = m -> _atelier_open!(m, :after))
bind!(:synth, "O", "atelier : un maillon avant"; group = :structure, hint = false,
      when = m -> _km_on_link(m) && _link_at(_km_ed(m)).piped, action = m -> _atelier_open!(m, :before))
bind!(:synth, "&", "atelier : faire bouger un nombre, en faire un argument, écouter jusqu'ici, bifurquer…";
      short = "atelier…", group = :structure, when = _km_normal_ed, action = m -> (m.pending_atelier = true))
bind!(:synth, ["d a m", "y a m", "c i m"], "maillon : retirer · copier · remplacer (objet texte m)";
      group = :structure, hint = false)
bind!(:synth, "g t", "synth suivant"; group = :nav, hint = false,
      when = m -> _km_synth(m) && length(_all_synth_buffers(m)) > 1,
      action = m -> _cycle_synth_tab!(m; dir = +1))
bind!(:synth, "g T", "synth précédent"; group = :nav, hint = false,
      when = m -> _km_synth(m) && length(_all_synth_buffers(m)) > 1,
      action = m -> _cycle_synth_tab!(m; dir = -1))

# ── :leader — Space + touche (pane patterns) ───────────────────────
scope!(:leader, "Space + …"; layer = :transient, modes = (:play,))
# Les colonnes du menu Espace, dans l'ordre ; chaque touche dit la sienne
# (`_LEADER_COLUMN_OF`). Une touche sans colonne tombe dans « AUTRES ».
const _LEADER_COLUMN_ORDER = ["ÉCRIRE", "TRANSFORMER LA LIGNE", "OUVRIR", "FAIRE", _LEADER_USER_COLUMN]
const _LEADER_COLUMN_OF = Dict{String,String}()

"""
    _leader_rebuild!()

Rebâtit le menu Espace des patterns : la table d'origine
(`plugins/core/leader.toml`), les entrées qui ouvrent quelque chose, puis
celles du joueur (`_LEADER_USER`), qui passent devant sur la même touche.
"""
function _leader_rebuild!()
    clear_scope!(:leader)
    empty!(_LEADER_SNIPPETS); empty!(_LEADER_LABELS); empty!(_LEADER_COLUMN_OF)
    user = Dict(s.key => s for s in _LEADER_USER)
    seen = Set{Char}()
    put!(sn::LeaderSnippet) = begin
        sn.key in seen && return
        push!(seen, sn.key)
        _LEADER_SNIPPETS[sn.key] = sn.template
        push!(_LEADER_LABELS, sn.key => sn.label)
        _LEADER_COLUMN_OF[string(sn.key)] = sn.column
        tpl = sn.template
        bind!(:leader, "Space $(sn.key)", sn.label; group = :edit,
              action = m -> _expand_snippet!(m, _km_ed(m), _prefill_slot(tpl, _km_ed(m))))
    end
    for sn in _LEADER_BASE
        put!(get(user, sn.key, sn))
    end
    for (c, label, column) in _LEADER_ACTION_LABELS
        if haskey(user, c)
            put!(user[c])                       # le joueur a repris cette touche pour un texte
            continue
        end
        push!(seen, c)
        push!(_LEADER_LABELS, c => label)
        _LEADER_COLUMN_OF[string(c)] = column
        bind!(:leader, "Space $c", label; group = :help, action = _LEADER_ACTIONS[c],
              short = first(split(label, " (")))
    end
    foreach(put!, _LEADER_USER)                  # les touches nouvelles
    return
end

"""
    _leader_user_load!() -> Int

Lit le `leader.toml` du joueur (dossier de configuration) et rebâtit le
menu. Rend le nombre d'entrées lues ; sans fichier, le menu d'origine.
"""
function _leader_user_load!()
    empty!(_LEADER_USER)
    append!(_LEADER_USER, _read_leader_file(_leader_user_path(); column = _LEADER_USER_COLUMN))
    _leader_rebuild!()
    return length(_LEADER_USER)
end

function _leader_user_save!()
    path = _leader_user_path()
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "# Tes touches du menu Espace (même format que plugins/core/leader.toml).")
        for s in _LEADER_USER
            println(io, "\n[[snippet]]")
            TOML.print(io, Dict("key" => string(s.key), "template" => s.template, "label" => s.label, "column" => s.column))
        end
    end
    return path
end

# `:leader x <texte>` : la touche x du menu écrit <texte>.
function _leader_set_cmd!(m::RessacApp, key::AbstractString, tpl::AbstractString)
    (length(key) == 1 && !isempty(strip(tpl))) ||
        (_push_app_log!(m, "[WARN] :leader <touche> <texte> — une touche d'un caractère, puis ce qu'elle écrit (\$1 \$2 = arrêts de Tab)"); return)
    c = first(key)
    filter!(s -> s.key != c, _LEADER_USER)
    push!(_LEADER_USER, LeaderSnippet(c, String(strip(tpl)), first(String(strip(tpl)), 28), _LEADER_USER_COLUMN))
    _leader_rebuild!()
    path = try _leader_user_save!() catch err
        _push_app_log!(m, "[ERROR] :leader — pas pu écrire le fichier : $(first(sprint(showerror, err), 80))"); return
    end
    _push_app_log!(m, "[INFO] Espace $c écrit « $(strip(tpl)) » — gardé dans $path")
    return
end

# `:leader-rm x` : la touche x redevient ce qu'elle était (ou disparaît).
function _leader_rm_cmd!(m::RessacApp, key::AbstractString)
    c = isempty(key) ? ' ' : first(key)
    any(s -> s.key == c, _LEADER_USER) ||
        (_push_app_log!(m, "[WARN] :leader-rm — « $key » n'est pas une de tes touches (:leader les liste)"); return)
    filter!(s -> s.key != c, _LEADER_USER)
    _leader_rebuild!()
    try _leader_user_save!() catch; end
    _push_app_log!(m, "[INFO] Espace $c : " * (haskey(_LEADER_SNIPPETS, c) || haskey(_LEADER_ACTIONS, c) ? "revenu à l'origine" : "retiré"))
    return
end

# `:leader` : tout le menu, les tiennes marquées.
function _leader_listing()
    mine = Set(s.key for s in _LEADER_USER)
    rows = String[]
    for (c, label) in _LEADER_LABELS
        tpl = get(_LEADER_SNIPPETS, c, "")
        push!(rows, "$(c in mine ? "●" : " ") $c   $(rpad(first(label, 34), 34))  $tpl")
    end
    return vcat("Le menu Espace. ● = à toi · `:leader x <texte>` ajoute ou change · `:leader-rm x` retire",
                "Ton fichier : $(_leader_user_path())", "", rows)
end

_leader_rebuild!()

# Le leader d'un mode : les snippets de patterns dans PLAY, les maillons
# du DSL dans DESIGN (depuis n'importe quelle pane : ils vont dans le texte).
_leader_scope(m::RessacApp) = _workspace_mode(m) === :design ? :leader_synth : :leader

# Space dans DESIGN : des maillons du DSL, insérés en bout de chaîne.
scope!(:leader_synth, "Space + … (synth)"; layer = :transient, modes = (:design,))
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
# ── Les scopes transitoires ──────────────────────────────────────────
# Leurs touches sont de vraies actions du registre, comme partout : ce que
# l'aide, le which-key et le wiki affichent est ce qui s'exécute. (Elles
# étaient « documentaires », le comportement recopié à la main dans un
# moteur par scope — et les deux avaient divergé.) La couche de chacun est
# posée par `_active_layers` (app_layers.jl).

scope!(:pane_mode, "Mode pane (Ctrl-w, reste actif)"; layer = :transient)
const _PANE_MODE_FOCUS = Dict("h" => :left, "j" => :down, "k" => :up, "l" => :right,
                              "←" => :left, "↓" => :down, "↑" => :up, "→" => :right)
bind!(:pane_mode, "Ctrl-w s", "split horizontal"; group = :layout,
      action = m -> cmd_hsplit!(m.workspaces, "editor", Dict{String,Any}()))
bind!(:pane_mode, "Ctrl-w v", "split vertical"; group = :layout,
      action = m -> cmd_vsplit!(m.workspaces, "editor", Dict{String,Any}()))
bind!(:pane_mode, ["Ctrl-w h", "Ctrl-w j", "Ctrl-w k", "Ctrl-w l", "Ctrl-w ←", "Ctrl-w ↓", "Ctrl-w ↑", "Ctrl-w →"],
      "focus ← ↓ ↑ → (ou flèches)"; short = "focus", group = :nav, repeat = true,
      action = (m, evt) -> cmd_focus!(m.workspaces, _PANE_MODE_FOCUS[keyname(evt)]))
bind!(:pane_mode, "Ctrl-w c", "fermer la pane"; group = :layout, action = m -> _close_focused_pane!(m))
bind!(:pane_mode, "Ctrl-w z", "zoom / dézoom (la pane seule à l'écran)"; group = :layout, action = _toggle_zoom!)
bind!(:pane_mode, ["Ctrl-w <", "Ctrl-w >"], "moins / plus large (5 %) — ou glisser une bordure à la souris"; short = "largeur",
      group = :layout, repeat = true,
      action = (m, evt) -> cmd_resize!(m.workspaces, :h, evt.char == '<' ? -_RATIO_STEP : +_RATIO_STEP))
bind!(:pane_mode, ["Ctrl-w -", "Ctrl-w +"], "moins / plus haut (5 %)"; short = "hauteur", group = :layout, repeat = true,
      action = (m, evt) -> cmd_resize!(m.workspaces, :v, evt.char == '-' ? -_RATIO_STEP : +_RATIO_STEP))
bind!(:pane_mode, "Ctrl-w =", "des parts égales"; group = :layout, action = m -> cmd_equalize!(m.workspaces))
bind!(:pane_mode, "Ctrl-w r", "tourner la coupe (horizontal ⟷ vertical)"; group = :layout, action = m -> cmd_rotate!(m.workspaces))
bind!(:pane_mode, ["Ctrl-w Esc", "Ctrl-w Enter", "Ctrl-w Ctrl-w"], "quitter le mode pane"; group = :layout,
      action = m -> (_PANE_MODE.active = false))

scope!(:visual, "Sélection visuelle (v / V)"; layer = :transient)
_km_visual_char(m::RessacApp) = m.visual_kind === :char
bind!(:visual, ["j", "k", "↓", "↑"], "étendre la sélection (lignes)"; short = "étendre", group = :select, repeat = true,
      action = (m, evt) -> _visual_move!(m, keyname(evt) in ("j", "↓") ? :down : :up))
bind!(:visual, ["h", "l", "←", "→"], "étendre la sélection (caractères, en v)"; group = :select, hint = false, repeat = true,
      when = _km_visual_char, action = (m, evt) -> _visual_move!(m, keyname(evt) in ("h", "←") ? :left : :right))
bind!(:visual, ["0", "\$"], "jusqu'au début / à la fin de la ligne (en v)"; group = :select, hint = false,
      when = _km_visual_char, action = (m, evt) -> _visual_move!(m, evt.char == '0' ? :home : :end))
bind!(:visual, ["d", "y", "c"], "supprimer / copier / changer"; group = :edit,
      action = (m, evt) -> (_visual_apply!(m, _active_editor(m), evt.char)))
bind!(:visual, "m", "mute les slots sélectionnés"; group = :audio,
      action = m -> (_visual_blocks!(m, _active_editor(m), :mute); m.visual_active = false))
bind!(:visual, "e", "évaluer les blocs sélectionnés"; short = "évaluer", group = :eval,
      action = m -> (_visual_blocks!(m, _active_editor(m), :eval); m.visual_active = false))
bind!(:visual, "Esc", "annuler"; group = :select,
      action = m -> (m.visual_active = false; _push_app_log!(m, "[INFO] sélection annulée")))

scope!(:insert, "Mode insertion"; layer = :transient)
# (L'insertion est la frappe elle-même : pas des touches nommées, un moteur
# — `_editor_insert_engine!`. Ces trois lignes disent ce qu'il fait.)
bind!(:insert, "Esc", "retour au mode normal"; group = :edit)
bind!(:insert, "Tab", "compléter (ghost, identifiants) · placeholder suivant"; group = :edit)
bind!(:insert, "S-Tab", "placeholder précédent"; group = :edit)

scope!(:placeholder, "Snippet avec des trous (après Space + lettre)"; layer = :transient, modes = (:play, :design))
bind!(:placeholder, "Tab", "trou suivant"; group = :edit, action = m -> _placeholder_jump!(m, _active_editor(m), +1))
bind!(:placeholder, "S-Tab", "trou précédent"; group = :edit, action = m -> _placeholder_jump!(m, _active_editor(m), -1))
bind!(:placeholder, "Esc", "sortir des trous"; group = :edit, action = m -> (m.placeholder_active = false))
# `i` et `u` sont ceux de l'éditeur (insertion, annulation) : la couche les
# laisse passer, l'aide les rappelle.
bind!(:placeholder, "i", "remplir le trou (insertion)"; group = :edit)
bind!(:placeholder, "u", "annuler le snippet"; group = :edit)

scope!(:tap, "Tap (:tap / :bpm)"; layer = :transient, modes = (:play,))
bind!(:tap, "Space", "frapper"; group = :audio, action = _tap_hit!)
bind!(:tap, "Enter", "valider"; group = :audio, action = _tap_commit!)
bind!(:tap, "Esc", "annuler"; group = :audio, action = _tap_cancel!)

scope!(:piano, "Piano (:piano)"; layer = :transient, modes = (:play,))
# Les lettres du piano viennent de `_PIANO_KEYMAP` (rangée du bas =
# naturelles, celle du milieu = dièses ; z et w pour le do, qwerty/azerty).
let naturals = (0, 2, 4, 5, 7, 9, 11, 12)
    keys_of(pred) = sort!([string(c) for (c, n) in _PIANO_KEYMAP if pred(n)])
    play = (m, evt) -> _piano_play!(m, _PIANO_KEYMAP[evt.char])
    bind!(:piano, keys_of(n -> n in naturals), "notes (rangée du bas = naturelles)"; short = "notes", group = :audio, action = play)
    bind!(:piano, keys_of(n -> !(n in naturals)), "dièses"; group = :audio, action = play)
end
bind!(:piano, ["[", "]"], "octave − / +"; group = :audio,
      action = (m, evt) -> _piano_octave!(m, evt.char == '[' ? -1 : +1))
bind!(:piano, "Enter", "valider l'enregistrement"; group = :audio,
      action = m -> (m.piano_rec ? _piano_commit!(m) : _piano_stop!(m)))
bind!(:piano, "Esc", "quitter"; group = :audio, action = _piano_stop!)

# Entrée en mode visuel (v / V), partagée par les deux bindings.
function _visual_enter!(m::RessacApp, kind::Symbol)
    ed = _km_ed(m)
    m.visual_active = true
    m.transient_ed = ed
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
