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
    m.modal === :guide       ? _GUIDE_LINES :
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
    "── 5-minute tour: from zero to first beat ──",
    "(j/k or ↑/↓ to scroll · q to close · :wiki for the full docs)",
    "",
    "▓ CARD 1 — Two modes, like vim",
    "  NORMAL mode (you start here) — keys are commands",
    "  INSERT mode — keys type letters into the buffer",
    "",
    "    i      enter INSERT (start typing)",
    "    Esc    back to NORMAL (commands again)",
    "",
    "  The mode shows in the bottom-left corner: [NORMAL] / [INSERT].",
    "",
    "▓ CARD 2 — Make a sound",
    "  In NORMAL mode, press:",
    "",
    "    E      eval ALL @dN blocks in the buffer (you'll hear them)",
    "    e      eval just the line under the cursor",
    "",
    "  Lines you eval flash green for a moment. The playhead",
    "  (orange-ish bar) shows which note plays right now.",
    "",
    "▓ CARD 3 — Stop / mute / panic",
    "",
    "    m      mute the @dN slot under the cursor (toggles)",
    "    :hush  soft stop (sounds fade out naturally)",
    "    ,      same as :hush, one keystroke",
    "    !      PANIC: kill every running sound immediately",
    "",
    "▓ CARD 4 — Discover sounds & snippets",
    "",
    "    Space b   browse all available sounds (Tab cycles types)",
    "    :snip     browse multi-line snippet templates",
    "    Space d   templated pattern line: @d_ p\"_\" (Tab between fields)",
    "    Space g   templated gain pipe: |> gain(_)",
    "    :starter house|trap|lofi|ambient   load a genre starter",
    "",
    "▓ CARD 5 — Where to go next",
    "",
    "    :guide      the full keybinding cheat-sheet",
    "    :wiki       deeper docs (mini-notation, DSL, scope, themes)",
    "    :doc gain   description + usage examples for any param",
    "    :tap        tap a rhythm, Ressac writes the @dN line",
    "    :synth wob  open a synth-design tab on the right",
    "",
    "When you're ready to start fresh: select all (V then G), d to delete,",
    "i to insert, type your own patterns. Use Esc + e to hear them.",
    "",
    "Press q to close this tour. Run :tutorial any time to come back.",
]

const _DSL_GUIDE_LINES = String[
    "── Synth DSL — Julia → SuperCollider ── (j/k scroll, q close)",
    "",
    "Bring it in: `using Ressac.SynthDSL`",
    "",
    "▓ MINIMAL — three tokens, full SynthDef:",
    "",
    "    @synth :bare saw(:freq)",
    "",
    "Auto-fills freq=220, sustain=0.5, gain=0.5, an Env.linen envelope",
    "(doneAction:2 so it self-frees), multiply by :gain, and DirtPan",
    "routing to SuperDirt.",
    "",
    "▓ EXPLICIT PARAMS:",
    "",
    "    @synth :acid (freq=80, cutoff=2000, q=0.3) saw(:freq) |>",
    "        rlpf(:cutoff, :q) |> tanh_drive(1.5)",
    "",
    "    @synth :wob (freq=80) saw(:freq) |>",
    "        rlpf(lfo(6; low=300, high=2000), 0.25)",
    "",
    "▓ DRONE (no auto-free):",
    "",
    "    @synth :pad (freq=110, sustain=999) (auto_env=false,)",
    "        saw(:freq) |> low_pass(800) |> stereo_pan(0)",
    "",
    "▓ ENVELOPES — multiplied into the chain:",
    "",
    "    saw(:freq) |> env_perc(0.005, :sustain)        # snappy",
    "    saw(:freq) |> env_linen(0.01, :sustain, 0.2)   # held",
    "    saw(:freq) |> env_adsr(0.01, 0.1, 0.6, 0.3)    # gated (needs :gate)",
    "    sin_osc(:freq) |> env_sine(:sustain)           # bell curve",
    "    saw(:freq) |> env_pairs([0.1, 0.4, 0.5], [0, 1, 0.3, 0]; curve=:exp)",
    "",
    "▓ FILTERS:",
    "    low_pass(2000)               high_pass(200)",
    "    band_pass(1000, 0.4)         band_reject(800, 0.4)",
    "    rlpf(1500, 0.3)              rhpf(800, 0.3)        # resonant",
    "    moog_ff(1200, 2)             leak_dc()",
    "    b_low_pass(2000)             b_peak_eq(1000, 0.7, 6)",
    "",
    "▓ MODULATORS — return Sig, not curried:",
    "    lfo(6; low=300, high=2000)   # sin lfo mapped to range",
    "    lfo_saw / lfo_tri / lfo_pulse",
    "    line(start, stop, dur)       x_line(...)         # one-shot ramps",
    "    lag_kr(input, lag_time)      # smooths an input over time",
    "",
    "▓ DELAYS / REVERB:",
    "    delay_n(0.25) / delay_l / delay_c",
    "    comb_l(0.05, 1.5)            # delay + feedback",
    "    free_verb(0.6, 0.8, 0.5)     # mix, room, damp",
    "    g_verb(roomsize=30, revtime=4)",
    "",
    "▓ NOISE:",
    "    white() / pink() / brown() / gray()",
    "    dust(60)                     # random impulses",
    "    crackle(1.95)                # chaos generator",
    "",
    "▓ SHAPING:",
    "    tanh_drive(1.5)              # soft saturation",
    "    soft_clip() / cubic() / clip(-0.8, 0.8) / fold() / wrap()",
    "    decimator(11025, 8)          # bit-crush",
    "",
    "▓ ARITHMETIC — Sig supports + - * / and pipes:",
    "    sin_osc(:freq) + 0.3 * white()    # carrier + bit of hiss",
    "    saw(:freq) * lfo(2)               # ring-mod",
    "",
    "▓ STEREO:",
    "    stereo_pan(lfo(0.5))           # auto-pan",
    "    stereo_balance(other_sig, 0)   # crossfade",
    "    splay(0.8)                     # widen a multichannel input",
    "",
    "▓ PATTERNS — use the registered synth:",
    "",
    "    @d1 :acid |> n(p\"0 3 5 7 3 5 0 7\")",
    "",
    "▓ COOKBOOK — copy-paste-tweak:",
    "",
    "  # Kick:",
    "    @synth :kick (sustain=0.4) sin_osc(line(80, 40, 0.05)) |> env_perc(0.001, :sustain)",
    "",
    "  # FM bell:",
    "    @synth :fmbell (freq=440, sustain=1.5) sin_osc(:freq + sin_osc(:freq*1.41) *",
    "        line(800, 50, 0.5)) |> env_perc(0, :sustain)",
    "",
    "  # Acid bass with env on cutoff:",
    "    @synth :acid (freq=60, sustain=0.3) saw(:freq) |>",
    "        rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)",
    "",
    "  # Plucked string (Karplus-ish):",
    "    @synth :pluck (freq=220) comb_l(line(1/220, 1/220, 0.001), 0.7) *",
    "        white() |> env_perc(0.001, 0.001)",
    "",
    "  # Pad with chorus + reverb:",
    "    @synth :pad (freq=220, sustain=4) (auto_env=false,)",
    "        saw(:freq) + saw(:freq * 1.007) + saw(:freq * 0.993) |>",
    "        low_pass(2000) |> free_verb(0.5, 0.9, 0.5)",
    "",
    "▓ INSPECT WITHOUT PLAYING:",
    "    synth_source(:name, sig; params=...)   # returns the SC string",
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
    elseif m.modal === :wiki
        _handle_wiki_key!(m, evt)
        return
    elseif m.modal === :mixer
        _handle_mixer_key!(m, evt)
        return
    elseif m.modal === :sculpt
        _handle_sculpt_key!(m, evt)
        return
    end
    # Modaux texte (guide, tutoriel, explain…) : registre :modal_text.
    dispatch!(((:modal_text, m),), evt)
    return
end

# ── Scopes des modaux ─────────────────────────────────────────────
const _MODAL_SCOPES = Dict{Symbol,Symbol}(
    :browse => :modal_browse, :synth_library => :modal_lib, :sccode => :modal_sccode,
    :snippets => :modal_snippets, :wiki => :modal_wiki, :mixer => :modal_mixer,
    :sculpt => :modal_sculpt,
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
function _bind_modal_common!(scope::Symbol; nav::Bool = true)
    nav && bind!(scope, ["j", "k", "↓", "↑"], "naviguer"; group = :nav, hint = false)
    bind!(scope, ["Esc", "q"], "fermer"; group = :nav, hint = false)
end

scope!(:modal_text, "Texte (guide, tutoriel, explication)")
bind!(:modal_text, ["j", "↓"], "défiler"; group = :nav, hint = false,
      action = m -> (m.modal_scroll = min(m.modal_scroll + 1, max(0, length(_modal_lines(m)) - 1))))
bind!(:modal_text, ["k", "↑"], "remonter"; group = :nav, hint = false,
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
    title = m.modal === :guide       ? "GUIDE" :
            m.modal === :synth_guide ? "SYNTH GUIDE" :
            m.modal === :dsl_guide   ? "DSL GUIDE" :
            m.modal === :tutorial    ? "TUTORIAL · 5-minute tour" :
            m.modal === :explain     ? "EXPLAIN" : "INFO"
    inner = _render_modal_block!(buf, area;
        title = title,
        title_right = "j/k scroll · q close",
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

# Sculpt studio modal — _close_sculpt_modal! / _handle_sculpt_key! /
# _render_sculpt_modal! (+ knobs, explainer) → src/modal_sculpt.jl.

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
        title_style        = TK.tstyle(:accent, bold = true),
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
