# src/app_modal.jl
# Infrastructure des modaux (cadre, ouverture, curseur, fermeture, clic)
# et les modaux génériques à défilement : guide, synth guide, DSL guide,
# tutoriel, explain. Les modaux spécialisés vivent dans modal_*.jl.

"""
    _modal_click!(m, x, y)

Click in a modal — map y to the row that was rendered there and set
the appropriate cursor. We track the (screen_y → entry_idx) mapping
during render via m.modal_rows.
"""
function _modal_click!(m::RessacApp, x::Int, y::Int)
    isempty(m.modal_rows) && return
    for (yy, idx) in m.modal_rows
        if y == yy
            if m.modal === :synth_library
                m.synthlib_cursor = idx
            elseif m.modal === :snippets
                m.snip_cursor = idx
            elseif m.modal === :sccode
                m.sccode_cursor = idx
            end
            return
        end
    end
end

_modal_lines(m::RessacApp) =
    m.modal === :synth_guide ? _SYNTH_GUIDE_LINES :
    m.modal === :dsl_guide   ? _DSL_GUIDE_LINES :
    m.modal === :tutorial    ? _TUTORIAL_LINES :
    m.modal === :explain     ? m.explain_lines :
    String[]

"""
    _TUTORIAL_LINES

The 5-minute onboarding tour for users coming from GUI DAWs. Each
"card" is a group of lines separated by a blank header; users scroll
with j/k. Designed to be readable end-to-end in under 5 minutes
without prior knowledge of vim or live-coding.
"""
const _TUTORIAL_LINES = String[
    "── Visite guidée en 5 minutes : de zéro au premier beat ──",
    "(j/k ou ↑/↓ pour défiler · q pour fermer · :wiki pour la doc complète)",
    "",
    "▓ CARTE 1 — Deux modes, comme vim",
    "  Mode NORMAL (tu démarres ici) — les touches sont des commandes",
    "  Mode INSERTION — les touches tapent du texte dans le buffer",
    "",
    "    i      passer en INSERTION (taper)",
    "    Esc    revenir en NORMAL (commandes)",
    "",
    "  Le mode est affiché dans la status line en haut : NORMAL / INSERTION.",
    "",
    "▓ CARTE 2 — Faire un son",
    "  En mode NORMAL, appuie sur :",
    "",
    "    E      évalue TOUS les blocs @dN du buffer (tu les entends)",
    "    e      évalue seulement la ligne sous le curseur",
    "",
    "  Les lignes évaluées clignotent en vert. La tête de lecture",
    "  (barre orangée) montre la note qui joue à l'instant.",
    "",
    "▓ CARTE 3 — Arrêter / mute / panic",
    "",
    "    m      mute le slot @dN sous le curseur (bascule)",
    "    :hush  arrêt doux (les sons finissent naturellement)",
    "    ,      pareil que :hush, en une touche",
    "    !      PANIC : coupe tout son immédiatement",
    "",
    "▓ CARTE 4 — Découvrir des sons et des snippets",
    "",
    "    Space b   parcourir tous les sons (Tab change de catégorie)",
    "    :snip     parcourir les snippets multi-lignes",
    "    Space d   ligne de pattern à trous : @d_ p\"_\" (Tab entre les champs)",
    "    Space g   pipe de gain à trous : |> gain(_)",
    "    :starter house|trap|lofi|ambient   charge un starter de genre",
    "",
    "▓ CARTE 5 — Concevoir un son, puis l'utiliser",
    "",
    "    :design     workspace DESIGN : une pane synth (Ctrl-2)",
    "    :lib        la librairie de synths (Enter ouvre une copie éditable)",
    "    T           teste le synth de la pane focalisée",
    "    U           l'utilise dans un pattern (@dN dans PLAY)",
    "    gs          depuis un pattern, ouvre le synth sous le curseur",
    "    :explore    workspace EXPLORE : l'explorateur génétique (Ctrl-3)",
    "",
    "▓ CARTE 6 — Où aller ensuite",
    "",
    "    ?           l'aide du contexte (touches de la pane focalisée)",
    "    :wiki       la doc en profondeur (mini-notation, DSL, scope, thèmes)",
    "    :doc gain   description + exemples pour un paramètre",
    "    :tap        tape un rythme, Ressac écrit la ligne @dN",
    "",
    "Pour repartir de zéro : tout sélectionner (V puis G), d pour supprimer,",
    "i pour insérer, tape tes patterns. Esc + e pour les entendre.",
    "",
    "q ferme cette visite. :tutorial pour y revenir.",
]

const _DSL_GUIDE_LINES = String[
    "── DSL de synthèse — Julia → SuperCollider ── (j/k défiler, q fermer)",
    "",
    "Pour l'importer : `using Ressac.SynthDSL`",
    "",
    "▓ MINIMAL — trois mots, un SynthDef complet :",
    "",
    "    @synth :bare saw(:freq)",
    "",
    "Remplit freq=220, sustain=0.5, gain=0.5, une enveloppe Env.linen",
    "(doneAction:2 : le synth se libère seul), multiplie par :gain, et",
    "route vers SuperDirt via DirtPan.",
    "",
    "▓ PARAMÈTRES EXPLICITES :",
    "",
    "    @synth :acid (freq=80, cutoff=2000, q=0.3) saw(:freq) |>",
    "        rlpf(:cutoff, :q) |> tanh_drive(1.5)",
    "",
    "    @synth :wob (freq=80) saw(:freq) |>",
    "        rlpf(lfo(6; low=300, high=2000), 0.25)",
    "",
    "▓ DRONE (sans auto-libération) :",
    "",
    "    @synth :pad (freq=110, sustain=999) (auto_env=false,)",
    "        saw(:freq) |> low_pass(800) |> stereo_pan(0)",
    "",
    "▓ ENVELOPPES — multipliées dans la chaîne :",
    "",
    "    saw(:freq) |> env_perc(0.005, :sustain)        # sèche",
    "    saw(:freq) |> env_linen(0.01, :sustain, 0.2)   # tenue",
    "    saw(:freq) |> env_adsr(0.01, 0.1, 0.6, 0.3)    # avec gate (:gate)",
    "    sin_osc(:freq) |> env_sine(:sustain)           # en cloche",
    "    saw(:freq) |> env_pairs([0.1, 0.4, 0.5], [0, 1, 0.3, 0]; curve=:exp)",
    "",
    "▓ FILTRES :",
    "    low_pass(2000)               high_pass(200)",
    "    band_pass(1000, 0.4)         band_reject(800, 0.4)",
    "    rlpf(1500, 0.3)              rhpf(800, 0.3)        # résonants",
    "    moog_ff(1200, 2)             leak_dc()",
    "    b_low_pass(2000)             b_peak_eq(1000, 0.7, 6)",
    "",
    "▓ MODULATEURS — renvoient un Sig, pas curryfiés :",
    "    lfo(6; low=300, high=2000)   # lfo sinus mappé sur une plage",
    "    lfo_saw / lfo_tri / lfo_pulse",
    "    line(start, stop, dur)       x_line(...)         # rampes uniques",
    "    lag_kr(input, lag_time)      # lisse une entrée dans le temps",
    "",
    "▓ DELAYS / RÉVERB :",
    "    delay_n(0.25) / delay_l / delay_c",
    "    comb_l(0.05, 1.5)            # delay + feedback",
    "    free_verb(0.6, 0.8, 0.5)     # mix, room, damp",
    "    g_verb(roomsize=30, revtime=4)",
    "",
    "▓ BRUITS :",
    "    white() / pink() / brown() / gray()",
    "    dust(60)                     # impulsions aléatoires",
    "    crackle(1.95)                # générateur chaotique",
    "",
    "▓ MISE EN FORME :",
    "    tanh_drive(1.5)              # saturation douce",
    "    soft_clip() / cubic() / clip(-0.8, 0.8) / fold() / wrap()",
    "    decimator(11025, 8)          # bit-crush",
    "",
    "▓ ARITHMÉTIQUE — Sig supporte + - * / et les pipes :",
    "    sin_osc(:freq) + 0.3 * white()    # porteuse + un peu de souffle",
    "    saw(:freq) * lfo(2)               # ring-mod",
    "",
    "▓ STÉRÉO :",
    "    stereo_pan(lfo(0.5))           # auto-pan",
    "    stereo_balance(other_sig, 0)   # fondu",
    "    splay(0.8)                     # élargit une entrée multicanale",
    "",
    "▓ PATTERNS — utiliser le synth enregistré :",
    "",
    "    @d1 :acid |> n(p\"0 3 5 7 3 5 0 7\")",
    "",
    "▓ RECETTES — à copier-coller-tordre :",
    "",
    "  # Kick :",
    "    @synth :kick (sustain=0.4) sin_osc(line(80, 40, 0.05)) |> env_perc(0.001, :sustain)",
    "",
    "  # Cloche FM :",
    "    @synth :fmbell (freq=440, sustain=1.5) sin_osc(:freq + sin_osc(:freq*1.41) *",
    "        line(800, 50, 0.5)) |> env_perc(0, :sustain)",
    "",
    "  # Basse acid avec enveloppe sur le cutoff :",
    "    @synth :acid (freq=60, sustain=0.3) saw(:freq) |>",
    "        rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)",
    "",
    "  # Corde pincée (façon Karplus) :",
    "    @synth :pluck (freq=220) comb_l(line(1/220, 1/220, 0.001), 0.7) *",
    "        white() |> env_perc(0.001, 0.001)",
    "",
    "  # Nappe avec chorus + réverb :",
    "    @synth :pad (freq=220, sustain=4) (auto_env=false,)",
    "        saw(:freq) + saw(:freq * 1.007) + saw(:freq * 0.993) |>",
    "        low_pass(2000) |> free_verb(0.5, 0.9, 0.5)",
    "",
    "▓ INSPECTER SANS JOUER :",
    "    synth_source(:name, sig; params=...)   # renvoie la source SC",
    "",
]

function _handle_modal_key!(m::RessacApp, evt::TK.KeyEvent)
    if m.modal === :browse
        _handle_browser_key!(m, evt)
        return
    elseif m.modal === :synth_library
        _handle_synthlib_key!(m, evt)
        return
    elseif m.modal === :sccode
        _handle_sccode_key!(m, evt)
        return
    elseif m.modal === :snippets
        _handle_snippets_key!(m, evt)
        return
    elseif m.modal === :mixer
        _handle_mixer_key!(m, evt)
        return
    elseif m.modal === :patterns
        _handle_patterns_key!(m, evt)
        return
    elseif m.modal === :evolve
        _handle_evolve_key!(m, evt)
        return
    end
    # Aide générée / modaux texte (tutoriel, explain…) : registre.
    dispatch!(((modal_scope(m), m),), evt)
    return
end

# ── Scopes des modaux ─────────────────────────────────────────────
const _MODAL_SCOPES = Dict{Symbol,Symbol}(
    :browse => :modal_browse, :synth_library => :modal_lib, :sccode => :modal_sccode,
    :snippets => :modal_snippets, :mixer => :modal_mixer, :patterns => :modal_patterns, :evolve => :modal_evolve,
    :help => :modal_help,
)
"""
    modal_scope(m) -> Symbol

Scope du registre pour le modal ouvert (`:modal_text` pour les modaux à
défilement : guide, tutoriel, explain…). `:none` si aucun modal.
"""
modal_scope(m::RessacApp) = m.modal === :none ? :none : get(_MODAL_SCOPES, m.modal, :modal_text)

# Entrées communes à tous les modaux (documentaires : la navigation j/k
# et la fermeture Esc/q sont gérées par _modal_cursor_nav! /
# _modal_close_key! ou leur variante « query-aware » dans chaque handler).
"""
    _modal_hint_text(m, scope; max_width=90) -> String

`title_right` d'un modal : ses bindings `hint` + « ? aide », générés.
"""
function _modal_hint_text(m::RessacApp, scope::Symbol; max_width::Int = 90)
    txt = hint_text(((scope, m),); max_width = max_width)
    lookup(scope, "?") === nothing || return txt          # le scope a déjà sa touche ?
    return isempty(txt) ? "? aide" : txt * " · ? aide"
end

function _bind_modal_common!(scope::Symbol; nav::Bool = true)
    nav && bind!(scope, ["j", "k", "↓", "↑"], "naviguer"; group = :nav, hint = false)
    bind!(scope, ["Esc", "q"], "fermer"; group = :nav, hint = false)
    bind!(scope, "?", "aide"; group = :help, action = _open_help!)
end

scope!(:modal_text, "Texte (guide, tutoriel, explication)")
bind!(:modal_text, ["j", "↓"], "défiler"; group = :nav, hint = false, repeat = true,
      action = m -> (m.modal_scroll = min(m.modal_scroll + 1, max(0, length(_modal_lines(m)) - 1))))
bind!(:modal_text, ["k", "↑"], "remonter"; group = :nav, hint = false, repeat = true,
      action = m -> (m.modal_scroll = max(0, m.modal_scroll - 1)))
bind!(:modal_text, "G", "fin"; group = :nav, hint = false,
      action = m -> (m.modal_scroll = max(0, length(_modal_lines(m)) - 1)))
bind!(:modal_text, "g", "début"; group = :nav, hint = false,
      action = m -> (m.modal_scroll = 0))
bind!(:modal_text, ["Esc", "q"], "fermer"; group = :nav,
      action = m -> (m.modal = :none; m.modal_scroll = 0))

"""
    _render_modal!(m, area, buf)

Draw a centered modal box over the rendered scene. Pulls the line
vector from `_modal_lines(m)`, applies `m.modal_scroll`, clips lines
to box width.
"""
function _render_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    lines = _modal_lines(m)
    isempty(lines) && return
    title = m.modal === :synth_guide ? "SYNTH GUIDE" :
            m.modal === :dsl_guide   ? "DSL GUIDE" :
            m.modal === :tutorial    ? "TUTORIAL · 5-minute tour" :
            m.modal === :explain     ? "EXPLAIN" : "INFO"
    inner = _render_modal_block!(buf, area;
        title = title,
        title_right = _modal_hint_text(m, :modal_text),
        w_max = 100,
        h_target = min(length(lines) + 2, area.height - 4))
    visible_end = min(length(lines), m.modal_scroll + inner.height)
    visible = m.modal_scroll + 1 <= length(lines) ?
              lines[(m.modal_scroll + 1):visible_end] :
              String[]
    for i in 1:inner.height
        line = i <= length(visible) ? visible[i] : ""
        TK.set_string!(buf, inner.x, inner.y + i - 1,
                       first(line, inner.width), TK.tstyle(:text))
    end
end

# Sculpt : une pane :waveform en mode sculpt (app_sculpt.jl), plus un modal.

"""
    _render_modal_block!(buf, area; title, title_right="", w_max=100, h_target=20) -> Rect

Center a bordered modal inside `area`. Clears the inner rect first so
the underlying editor / panes don't bleed through, then draws a
`TK.Block` with rounded corners + accent border. Returns the inner
`Rect` so the caller can pour content into it without computing
offsets.

The right-aligned title is the conventional spot for the help line
("j/k scroll · q close" etc.) — keep it short so it never collides
with the left title on narrow terminals.
"""
function _render_modal_block!(buf::TK.Buffer, area::TK.Rect;
                              title::AbstractString,
                              title_right::AbstractString = "",
                              w_min::Int = 40, w_max::Int = 100,
                              h_target::Int = 20)
    aw, ah = area.width, area.height
    box_w = clamp(w_max, w_min, max(w_min, aw - 4))
    box_h = clamp(h_target, 8, max(8, ah - 4))
    box_x = area.x + max(0, (aw - box_w) ÷ 2)
    box_y = area.y + max(0, (ah - box_h) ÷ 2)
    rect = TK.Rect(box_x, box_y, box_w, box_h)
    inner = _inner_rect(rect)
    # Clear inner first so any cells previously drawn by the editor /
    # panes underneath get overwritten with blank text style. Without
    # this the modal looks "transparent" on the body.
    blank = " " ^ inner.width
    bg_style = TK.tstyle(:text)
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, inner.x, y, blank, bg_style)
    end
    block = TK.Block(
        title              = " " * String(title) * " ",
        title_right        = isempty(title_right) ? "" :
                             " " * String(title_right) * " ",
        title_style        = _pill_style(:accent),
        title_right_style  = TK.tstyle(:text_dim),
        border_style       = TK.tstyle(:accent),
        box                = TK.BOX_ROUNDED,
        title_padding      = 0,
    )
    TK.render(block, rect, buf)
    return inner
end

"""
    _scroll_to_show(cursor, total, body_h, scroll) -> Int

Updated scroll offset so that `cursor` (1-based) is visible inside the
window `[scroll+1, scroll+body_h]`. "Scroll-as-needed" semantics — if
cursor is already in view, leaves `scroll` alone (no jumpy
re-centering on every keystroke). When forced to move, scrolls just
enough to bring the cursor to the nearest edge of the window.

Result is clamped to `[0, max(0, total - body_h)]` so the window
never reveals empty rows past the end of a short list.

Pure helper — used by every list-style modal (browse / lib) to keep
the cursor visible as the user j/k's past the bottom of the viewport.
"""
function _scroll_to_show(cursor::Int, total::Int, body_h::Int, scroll::Int)
    body_h <= 0 && return 0
    new_scroll = scroll
    if cursor < new_scroll + 1
        new_scroll = max(0, cursor - 1)
    elseif cursor > new_scroll + body_h
        new_scroll = cursor - body_h
    end
    return clamp(new_scroll, 0, max(0, total - body_h))
end

"""
    _open_modal!(m, kind, cursor_field=nothing)

Universal modal entry. Sets `m.modal = kind`, resets `modal_scroll`
to 0, and (when given) resets `cursor_field` to 1. Modals with
their own query / search / page state set those fields after calling
this. Pass `cursor_field = nothing` for scroll-only modals (e.g. wiki).
"""
function _open_modal!(m::RessacApp, kind::Symbol,
                     cursor_field::Union{Symbol,Nothing} = nothing)
    m.modal = kind
    m.modal_scroll = 0
    cursor_field === nothing || setfield!(m, cursor_field, 1)
    return nothing
end

"""
    _modal_cursor_nav!(m, evt, cursor_field, n) -> Bool

Standard list-modal cursor navigation: `j` / `:down` increments,
`k` / `:up` decrements. Reads + writes the cursor field via Symbol
lookup so each modal can keep its own (`browser_cursor`,
`mixer_cursor`, …). Cursor stays clamped to `[1, max(n, 1)]`.

Returns `true` iff the event was a nav key and was consumed — the
modal's handler should early-return in that case.
"""
function _modal_cursor_nav!(m::RessacApp, evt::TK.KeyEvent,
                            cursor_field::Symbol, n::Int)
    if evt.char == 'j' || evt.key === :down
        cur = getfield(m, cursor_field)
        setfield!(m, cursor_field, min(cur + 1, max(n, 1)))
        return true
    elseif evt.char == 'k' || evt.key === :up
        cur = getfield(m, cursor_field)
        setfield!(m, cursor_field, max(cur - 1, 1))
        return true
    end
    return false
end

"""
    _modal_close_key!(m, evt) -> Bool

Standard modal close: `Esc` or `q` closes the modal. Returns `true`
iff the modal was closed. Modals that need query-aware Esc (clear
the query first, close on the second Esc) should NOT call this and
handle Esc themselves.
"""
function _modal_close_key!(m::RessacApp, evt::TK.KeyEvent)
    if evt.key === :escape || evt.char == 'q'
        m.modal = :none
        return true
    end
    return false
end

# ── Aide `?` — générée depuis le registre ─────────────────────────
# `?` ouvre l'aide du CONTEXTE : la pane focalisée d'abord (ou le modal
# ouvert), puis le global, puis l'éditeur. Tab montre toutes les
# sections. L'aide s'ouvre par-dessus un modal et le restaure à la
# fermeture. `?` / Esc / q ferment.

# Ordre canonique des sections en mode « tout ».
const _HELP_ALL_SCOPES = Symbol[
    :global, :editor, :patterns, :leader, :placeholder, :synth, :visual, :insert, :pane_mode,
    :explorer, :waveform, :sculpt, :log, :doc, :wiki, :tuning, :tap, :piano,
    :modal_help, :modal_text, :modal_browse, :modal_lib, :modal_snippets, :modal_patterns,
    :modal_evolve,
    :modal_mixer, :modal_sccode,
]

"""
    _help_scopes(m) -> Vector{Symbol}

Sections de l'aide pour le contexte courant (ou toutes si `help_expanded`).
"""
function _help_scopes(m::RessacApp)
    m.help_expanded && return Symbol[s for s in _HELP_ALL_SCOPES if !isempty(bindings(s))]
    if m.help_return !== :none                       # aide ouverte depuis un modal
        return Symbol[get(_MODAL_SCOPES, m.help_return, :modal_text), :modal_help]
    end
    pane = _focused_pane_impl(m)
    ps = pane === nothing ? :none : pane_scope(pane)
    ps !== :none && return Symbol[ps, :global, :pane_mode, :modal_help]
    role = _focused_role(m)
    role === :synth && return Symbol[:synth, :editor, :global, :visual, :insert, :pane_mode, :modal_help]
    return Symbol[:patterns, :leader, :editor, :global, :visual, :insert, :pane_mode, :modal_help]
end

# Scopes dont la cible des prédicats est une PANE (pas l'app).
const _PANE_SCOPES = (:explorer, :waveform, :sculpt, :log, :doc, :wiki, :tuning)

# Cible des prédicats `when` d'un scope : la pane focalisée pour son
# propre scope, l'app pour les scopes app ; un scope de pane non
# focalisée n'a pas de cible (ses entrées ne sont pas grisées).
function _help_targets(m::RessacApp)
    t = Dict{Symbol,Any}()
    pane = _focused_pane_impl(m)
    if pane !== nothing && pane_scope(pane) !== :none
        t[pane_scope(pane)] = pane
    end
    for s in _HELP_ALL_SCOPES
        (haskey(t, s) || s in _PANE_SCOPES) || (t[s] = m)
    end
    return t
end

function _open_help!(m::RessacApp)
    m.modal === :help && return
    m.help_return = m.modal
    m.help_expanded = false
    m.help_scopes = _help_scopes(m)
    m.modal = :help
    m.modal_scroll = 0
    return
end

function _close_help!(m::RessacApp)
    m.modal = m.help_return
    m.help_return = :none
    m.modal_scroll = 0
    return
end

_toggle_help!(m::RessacApp) = m.modal === :help ? _close_help!(m) : _open_help!(m)

"""
    _help_lines(m) -> Vector{Tuple{String,Symbol}}

Lignes (texte, style) de l'aide : sections du registre puis la
référence statique (_GUIDE_REFERENCE_LINES). Styles : :title, :group,
:row, :dim, :note, :ref.
"""
function _help_lines(m::RessacApp)
    out = Tuple{String,Symbol}[]
    secs = help_sections(m.help_scopes; targets = _help_targets(m))
    for sec in secs
        push!(out, ("▸ " * sec.title, :title))
        kw = 0
        for g in sec.groups, r in g.rows
            kw = max(kw, textwidth(r.keys))
        end
        kw = min(kw, 22)
        for g in sec.groups
            push!(out, ("  " * g.title, :group))
            for r in g.rows
                push!(out, ("    " * rpad(r.keys, kw) * "  " * r.label, r.dim ? :dim : :row))
            end
        end
        for n in sec.notes
            push!(out, ("  " * n, :note))
        end
        push!(out, ("", :row))
    end
    push!(out, (m.help_expanded ? "▸ Référence" : "▸ Référence   (Tab : toutes les sections de touches)", :title))
    for l in _GUIDE_REFERENCE_LINES
        push!(out, (l, startswith(l, "▓") ? :group : :ref))
    end
    return out
end

function _render_help_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    lines = _help_lines(m)
    inner = _render_modal_block!(buf, area;
        title = "AIDE",
        title_right = _modal_hint_text(m, :modal_help),
        w_max = 100,
        h_target = min(length(lines) + 2, area.height - 4))
    start = clamp(m.modal_scroll + 1, 1, max(1, length(lines)))
    for i in 0:(inner.height - 1)
        idx = start + i
        idx > length(lines) && break
        txt, kind = lines[idx]
        sty = kind === :title ? TK.tstyle(:accent, bold = true) :
              kind === :group ? TK.tstyle(:title, bold = true) :
              kind === :dim   ? TK.tstyle(:text_dim) :
              kind === :note  ? TK.tstyle(:text_dim) :
                                TK.tstyle(:text)
        TK.set_string!(buf, inner.x, inner.y + i, first(txt, inner.width), sty)
    end
    return
end

_help_last(m::RessacApp) = max(0, length(_help_lines(m)) - 1)
scope!(:modal_help, "Aide")
bind!(:modal_help, ["j", "↓"], "défiler"; group = :nav, hint = false, repeat = true,
      action = m -> (m.modal_scroll = min(m.modal_scroll + 1, _help_last(m))))
bind!(:modal_help, ["k", "↑"], "remonter"; group = :nav, hint = false, repeat = true,
      action = m -> (m.modal_scroll = max(0, m.modal_scroll - 1)))
bind!(:modal_help, ["PgDn", "Ctrl-d"], "page suivante"; group = :nav, hint = false, repeat = true,
      action = m -> (m.modal_scroll = min(m.modal_scroll + 20, _help_last(m))))
bind!(:modal_help, ["PgUp", "Ctrl-u"], "page précédente"; group = :nav, hint = false, repeat = true,
      action = m -> (m.modal_scroll = max(0, m.modal_scroll - 20)))
bind!(:modal_help, ["g", "G"], "début / fin"; group = :nav, hint = false,
      action = (m, evt) -> (m.modal_scroll = evt.char == 'g' ? 0 : _help_last(m)))
bind!(:modal_help, "Tab", "toutes les sections ⟷ contexte"; short = "tout", group = :help,
      action = m -> (m.help_expanded = !m.help_expanded; m.help_scopes = _help_scopes(m); m.modal_scroll = 0))
bind!(:modal_help, ["?", "Esc", "q"], "fermer l'aide"; short = "fermer", group = :help, action = _close_help!)

# ── Wiki des touches (docs/wiki/04-keys.md), généré ──────────────
"""
    keys_wiki_markdown() -> String

La page « Touches » du wiki, générée depuis le registre : une section
par scope (ordre de `_HELP_ALL_SCOPES`), un tableau par groupe, puis les
notes du scope. `scripts/gen_keys_wiki.jl` l'écrit dans
docs/wiki/04-keys.md ; un test échoue si la page diverge.
"""
function keys_wiki_markdown()
    io = IOBuffer()
    println(io, "# Touches")
    println(io)
    println(io, "Page générée depuis le registre de bindings (`src/keymap.jl`, ",
                "`src/app_keymap.jl` et les scopes des panes/modaux) par ",
                "`scripts/gen_keys_wiki.jl` — ne pas éditer à la main. Dans l'app, ",
                "`?` ouvre la même chose pour le contexte courant.")
    println(io)
    println(io, "Notation : `Space d` = Space puis d · `Ctrl-w s` = Ctrl-w puis s · ",
                "`g t` = g puis t. Les touches séparées par ` / ` sont des synonymes.")
    for sec in help_sections(Symbol[s for s in _HELP_ALL_SCOPES if !isempty(bindings(s))])
        println(io)
        println(io, "## ", sec.title)
        for g in sec.groups
            println(io)
            println(io, "**", g.title, "**")
            println(io)
            println(io, "| Touche | Action |")
            println(io, "|---|---|")
            for r in g.rows
                println(io, "| `", replace(r.keys, "|" => "\\|"), "` | ", r.label, " |")
            end
        end
        if !isempty(sec.notes)
            println(io)
            println(io, "```")
            foreach(n -> println(io, n), sec.notes)
            println(io, "```")
        end
    end
    return String(take!(io))
end
