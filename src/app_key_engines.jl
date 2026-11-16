# src/app_key_engines.jl
# TK.update! clavier et les moteurs : ce qui n'est pas une touche nommée
# du registre — la ligne « : », le mode pane, la modale, la pane
# focalisée, le piano, le tap, la pause, le visuel, le leader, les trous
# d'un snippet, f/t, les opérateurs vim, l'insertion, le mode commande,
# le moteur de l'éditeur. La pile qui les ordonne est dans app_layers.jl.

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    # Pavé numérique → chiffres et opérateurs, AVANT tout routage.
    evt = _normalise_event(evt)
    if m.keydebug
        _push_app_log!(m, "[KEY] $(evt.key) char=$(repr(evt.char)) action=$(evt.action)")
    end
    # Dernier filet : une touche dont l'action lève se lit dans le log,
    # l'application ne tombe pas.
    try
        _resolve_key!(m, evt)
        _drain_requests!(m)
    catch err
        _push_app_log!(m, "[ERROR] touche $(keyname(evt)) — $(first(sprint(showerror, err), 160))")
    end
    return
end

# ── Barre de commande : priorité absolue quand elle est active ────
# Tant que la barre `:` / `/` est ouverte, TOUTE touche lui revient : ni
# les globaux du workspace, ni le mode pane, ni les panes ne la voient.
# Découplée de l'éditeur : marche quelle que soit la pane focalisée.
function _command_line_engine!(m::RessacApp, evt::TK.KeyEvent)
    is_active(m.command_line) || return false
    outcome = handle_key!(m.command_line, evt;
                          complete_fn = q -> _command_completion_candidates(m, q))
    if outcome === :dispatched
        cmd = m.command_line.last_dispatched
        if !isempty(cmd)
            if m.command_line.last_dispatched_mode === :search
                _ex_search!(m, cmd)
            else
                _handle_ex_command!(m, cmd)
            end
        end
    end
    return true
end

# ── Panic : coupe-son GLOBAL ──────────────────────────────────────
# `!` tue le son (patterns + tous les nœuds SC) depuis N'IMPORTE QUELLE
# pane ou modale. Seules exceptions : la SAISIE DE TEXTE — éditeur en
# insertion (où `!` est un caractère) — et l'attente d'un caractère
# littéral (`r!` remplace, `f!` saute au prochain `!`).
function _pre_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return false
    _text_entry_active(m) && return false       # la frappe va dans une saisie
    if evt.char == '!'
        ed = _active_editor(m)
        (ed === nothing || ed.mode === :normal) && !_awaiting_literal(m) || return false
        _panic!(m)
        return true
    end
    if evt.key === :ctrl && evt.char in '1':'9'
        _switch_workspace!(m, Int(evt.char - '0'))
        return true
    end
    # Ctrl-f — et Ctrl-Maj-F, que certains terminaux envoient en majuscule.
    if evt.key === :ctrl && (evt.char == 'f' || evt.char == 'F')
        m.floats_hidden = !m.floats_hidden
        return true
    end
    return false
end

# ── Ouvrir un transitoire : Ctrl-w (mode pane), « : » et « / » ───────
# Sans éditeur, on se comporte comme en mode normal : le mode pane et la
# commande `:` restent joignables (il faut pouvoir `:vsplit editor` pour
# rouvrir une pane de patterns quand il n'y en a plus). Ctrl-W en
# insertion efface toujours un mot ; `:` en insertion est un caractère ;
# `/` seulement si la modale ouverte n'a pas sa propre recherche.
function _open_transient_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return false
    _text_entry_active(m) && return false       # la frappe va dans une saisie
    ed = _active_editor(m)
    in_normal = ed === nothing || ed.mode === :normal
    in_normal || return false
    if evt.key === :ctrl && evt.char == 'w'
        _PANE_MODE.active = true
        return true
    end
    if evt.key === :char && !_awaiting_literal(m)
        if evt.char == ':'
            enter!(m.command_line, :command)
            return true
        elseif evt.char == '/' && !_modal_owns_key(m, "/")
            enter!(m.command_line, :search)
            return true
        end
    end
    return false
end

# ── Modale ouverte : elle possède toutes les touches ──────────────
# Avant le routage vers la pane focalisée, pour qu'une modale ouverte
# par une touche de pane (sculpt via `M` de l'explorer) reçoive bien la
# saisie au lieu que la pane encore focalisée l'avale. Les répétitions
# de touche ne passent que pour la navigation.
function _modal_engine!(m::RessacApp, evt::TK.KeyEvent)
    is_nav = evt.char in ('j', 'k', 'd', 'u', 'h', 'l', 'n', 'p', '<', '>') ||
             evt.key in (:up, :down, :left, :right, :pageup, :pagedown)
    if evt.action === TK.key_press || (evt.action === TK.key_repeat && is_nav)
        _handle_modal_key!(m, evt)
    end
    return true
end

# ── Pane focalisée ────────────────────────────────────────────────
# Une pane qui n'est pas l'éditeur actif (journal, doc, scope, sculpt…)
# reçoit la touche par son `handle_key!`. Si elle ne la consomme pas, ou
# s'il n'y a aucun éditeur ouvert, seul le scope :global s'applique
# (aide, hush, scope…). Sinon la touche continue vers l'éditeur, qu'on
# remet focalisé : `_render_tree_inner!` baisse ce drapeau dès que le
# focus est ailleurs, et `TK.handle_key!` l'ignore alors en silence.
function _pane_engine!(m::RessacApp, evt::TK.KeyEvent)
    r = _route_key_to_focused_pane!(m, evt)
    return r === :consumed
end

# (Piano, tap et mode pane n'ont pas de moteur : toutes leurs touches sont
# des actions du registre — app_keymap.jl — et leur couche, exclusive,
# avale le reste.)

# ── Pause : une touche reprend, et elle est avalée ────────────────
# (pour qu'elle ne s'insère pas aussi comme caractère).
function _paused_engine!(m::RessacApp, evt::TK.KeyEvent)
    if evt.action === TK.key_press
        m.paused = false
        _push_app_log!(m, "[INFO] reprise")
    end
    return true
end

# ── Sélection visuelle ───────────────────────────────────────────────
# Ses touches sont au registre (scope :visual). Toute autre touche pressée
# sort de la sélection et continue son chemin vers l'éditeur.
function _visual_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return false
    isempty(keyname(evt)) && return false          # un modificateur seul : on attend
    m.visual_active = false
    return false
end

# ── Mémoire de `.` : la session d'insertion est enregistrée ──────
# Un effet de bord, jamais une consommation.
function _vim_record_engine!(m::RessacApp, evt::TK.KeyEvent)
    _vim_record_keystroke!(m, _active_editor(m), evt, evt.action === TK.key_press)
    return false
end

# ── Mode normal : registre de bindings et accords ────────────────
# Toutes les ACTIONS passent par le registre (app_keymap.jl), en mode
# normal seulement : jamais une touche tapée en insertion ne déclenche
# une action. Couches : pane focalisée (:patterns | :synth) → :editor →
# :global. Un binding qui ne matche pas laisse la touche au moteur vim.
# ── Espace déjà pressé : la touche suivante choisit dans le leader ────
# (le registre de la couche, avec le préfixe « Space », passe après :
# ici on ne gère que l'attente et la sortie).
function _leader_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return true
    if evt.key === :escape
        m.pending_leader = false; return true
    end
    # Modificateur seul (Maj avant un E majuscule…) : on attend.
    (evt.key !== :char || evt.char == '\0') && return true
    m.pending_leader = false
    return false            # → le registre du leader, préfixe « Space »
end

# ── `f` / `t` en attente : le caractère suivant est la cible ──────────
function _pending_find_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return true
    motion = m.pending_find
    m.pending_find = nothing
    if evt.key === :char && evt.char != '\0'
        _find_char!(m, _active_editor(m), motion, evt.char)
    end
    return true
end

# ── Mode normal, après le registre : opérateurs et mouvements à nous ──
function _editor_normal_engine!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    is_press = evt.action === TK.key_press
    # Opérateur + mouvement (cw / dw / yw, variantes majuscules et e) :
    # Tachikoma ne connaît que les formes doublées (cc/dd/yy), celles-ci
    # sont à nous. Chacune garde `scroll_offset` pour que la vue ne saute
    # pas quand le texte change.
    if is_press && ed.pending_key in ('c', 'd', 'y') && evt.char in ('w', 'b', 'W', 'B', 'e', 'E', '$', '0')
        op = ed.pending_key
        ed.pending_key = nothing
        _op_with_motion!(m, ed, op, evt.char)
        return true
    end
    # Mouvements par mot — les nôtres plutôt que ceux de Tachikoma, pour
    # qu'ils avancent TOUJOURS et passent les lignes sans buter sur la
    # ponctuation. W / B sont les « gros mots » de vim (seule l'espace
    # sépare : foo.bar = un saut). Pas quand un opérateur attend.
    if is_press && evt.char in ('w', 'b', 'W', 'B') && ed.pending_key === nothing
        kind = (evt.char == 'W' || evt.char == 'B') ? :big : :small
        dir  = (evt.char == 'w' || evt.char == 'W') ? +1 : -1
        _word_motion!(ed, dir, kind)
        return true
    end
    return false
end

# ── Mode insertion : Tab complète, le reste s'écrit ──────────────
# Tab : accepter la suggestion fantôme si elle est visible, sinon le
# cycle de complétion de mot ; si rien ne s'applique, Tab continue vers
# l'éditeur. Toute autre touche remet le cycle à zéro, s'écrit, puis
# recalcule le fantôme. Les trous d'un snippet passent avant : Tab /
# Maj-Tab sautent de $1 en $2.
function _editor_insert_engine!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    evt.action === TK.key_press || return true
    if m.placeholder_active && evt.key === :tab
        _placeholder_jump!(m, ed, +1); return true
    end
    if m.placeholder_active && evt.key === :backtab
        _placeholder_jump!(m, ed, -1); return true
    end
    if evt.key === :tab
        if !isempty(m.ghost) && _accept_ghost!(m)
            _compute_ghost!(m)
            return true
        end
        if _try_autocomplete!(m, ed)
            m.ghost = ""
            return true
        end
        return false                                # Tab sans complétion : à l'éditeur
    end
    _reset_completion!(m)
    # Longueur de la ligne avant l'édition, pour que le suivi des trous
    # décale les $N restants du bon delta.
    pre_len = (m.placeholder_active && 1 <= ed.cursor_row <= length(ed.lines)) ?
              length(ed.lines[ed.cursor_row]) : 0
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    m.placeholder_active && _placeholder_track_change!(m, ed, pre_len)
    _compute_ghost!(m)
    return true
end


# ── L'éditeur lui-même : moteur vim de Tachikoma, puis `.` ───────
function _editor_engine!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    is_press = evt.action === TK.key_press
    pre_text = ed.mode === :normal ? TK.text(ed) : ""     # pour l'enregistrement de `.`
    pre_mode = ed.mode
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    if is_press && pre_mode === :normal
        _vim_post_normal!(m, ed, evt, pre_text)
    end
    return true
end


# Ce qu'une saisie de recherche accepte : tout caractère imprimable, accents
# compris (les libellés sont en français).
_is_typable(c::Char) = c != '\0' && isvalid(c) && isprint(c)

# ---------------------------------------------------------------------
# Live doc row
# ---------------------------------------------------------------------
