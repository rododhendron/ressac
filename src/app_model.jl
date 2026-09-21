# src/app_model.jl
# Le modèle RessacApp (état de l'app Tachikoma), ses accesseurs
# (éditeur/pane/rôle focalisés, buffers synth) et l'amorçage du workspace
# par défaut. Tout ce qui suit dans app_*.jl prend un `m::RessacApp`.

using Dates
# `using Tachikoma` and `const TK = Tachikoma` now live at the top
# of Ressac.jl so pane impls (loaded before this file) can reference
# TK types directly.

# Synths are no longer a separate side-panel structure — each open
# synth is a workspace EditorPane with role=:synth and a synth_mode
# (:dsl | :sc) on its EditorBuffer. See _all_synth_buffers /
# _current_synth_tab in this file.

"""
    _STARTER_BUFFER

Buffer text shown on first `live()` if no session is loaded. Doubles
as the minimal-but-runnable demo: 4-on-the-floor kick + closed hat +
clap on beat 3 + sub bass. The leading comments orient a first-time
user — they cover the four keys needed to actually play this back
(Esc, then E, then `m` to mute, then `:q` to quit), and point to
`:tutorial` for the interactive guide.
"""
const _STARTER_BUFFER = """
# Bienvenue dans Ressac — Esc puis E pour jouer ces patterns.
# m sur une ligne @dN = mute · ? = aide · :tutorial = visite guidée · :q = quitter.

cps!(0.5)
@d1 p"bd bd bd bd"
@d2 p"~ ~ cp ~"
@d3 p"hh hh hh hh" |> gain(0.4)
"""

"""
    RessacApp

Top-level Tachikoma model. Holds the live scheduler, a patterns
CodeEditor, an optional stack of synth tabs (side panel when
non-empty), and the focus toggle for keystroke routing.
"""

@kwdef mutable struct RessacApp <: TK.Model
    scheduler::Scheduler
    # No m.editor / m.synth_tabs / m.focus fields — both the patterns
    # editor and every synth live inside the workspace tree as
    # EditorPanes (role :patterns / :synth). Resolve dynamically via
    # `_active_editor(m)` / `_focused_buffer(m)` / `_focused_role(m)`
    # / `_all_synth_buffers(m)`.
    # Modal overlay state — `:none`, `:guide`, `:synth_guide`, `:browse`,
    # `:synth_library`.
    modal::Symbol                = :none
    modal_scroll::Int            = 0
    # Aide `?` (modal :help) : sections affichées, modal à restaurer à la
    # fermeture (l'aide s'ouvre PAR-DESSUS un modal), et « tout montrer ».
    help_scopes::Vector{Symbol}  = Symbol[]
    help_return::Symbol          = :none
    help_expanded::Bool          = false
    # Which-key : préfixe en attente (:leader, :g, :pane_mode ou :none) et
    # depuis quand — le popup apparaît tout de suite (Space) ou après un
    # délai (g, Ctrl-w) pour ne pas gêner les habitués.
    prefix_kind::Symbol          = :none
    prefix_since::Float64        = 0.0
    # Lines shown by the generic :explain modal (`:explain <name>`).
    explain_lines::Vector{String} = String[]
    # Zoom : id du leaf rendu seul dans tout le workspace (0 = aucun).
    # Ctrl-w z / :zoom basculent ; un changement de focus dézoome.
    zoom_leaf::Int               = 0
    # Synth library picker state (only meaningful when modal === :synth_library).
    synthlib_cursor::Int         = 1
    # Snippet picker state (only meaningful when modal === :snippets).
    snip_cursor::Int             = 1
    snip_query::String           = ""
    snip_search_mode::Bool       = false
    # Active category tab — empty string = "all". Tab / Shift-Tab cycle.
    snip_category::String        = ""
    # Wiki state (only meaningful when modal === :wiki). Pages re-read
    # at every :wiki so editing a .md file in docs/wiki/ takes effect
    # without restarting.
    wiki_pages::Vector{_WikiPage} = _WikiPage[]
    wiki_idx::Int                = 1
    wiki_scroll::Int             = 0
    # Vim-style `.` repeat. We capture the text typed during the last
    # i/a/o-insert session and re-type it on `.` press.
    vim_in_insert::Bool          = false
    vim_insert_buf::String       = ""
    vim_last_insert::String      = ""
    # Normal-mode `.` repeat: track keystrokes whose combined effect
    # changed the buffer (dd, x, p, J, ...) so `.` can replay them.
    # `pending` accumulates keystrokes since the last buffer change;
    # whenever the buffer changes while in :normal, pending becomes
    # the new `last_normal`. `last_kind` picks which of last_insert /
    # last_normal `.` should replay.
    vim_pending_normal::Vector{TK.KeyEvent} = TK.KeyEvent[]
    vim_last_normal::Vector{TK.KeyEvent}    = TK.KeyEvent[]
    vim_last_kind::Symbol        = :none   # :insert, :normal, or :none
    # Visual-line mode. `V` enters; j/k/arrows extend selection;
    # d/y/c operate on the line range [min(anchor, cursor),
    # max(anchor, cursor)] then exit; Esc cancels without action.
    visual_active::Bool          = false
    visual_anchor_row::Int       = 1
    visual_anchor_col::Int       = 0
    # :line (capital V, whole-line yank/delete) or :char (lowercase v,
    # character-wise across rows). Default :line for backward compat.
    visual_kind::Symbol          = :line
    # Space-leader snippet expansion. `pending_leader` flips true after
    # Space in normal mode and waits for the trigger char; the trigger
    # expands a template that may contain $1, $2, … placeholders.
    # `placeholder_active` is then true while the user fills them, with
    # Tab navigating to the next position. All positions are tracked on
    # the same `placeholder_row` for now (every current template fits a
    # single line; multi-line would require a parallel `placeholder_rows`).
    pending_leader::Bool         = false
    placeholder_active::Bool     = false
    placeholder_row::Int         = 0
    placeholder_cols::Vector{Int} = Int[]
    placeholder_idx::Int         = 0
    # Post-eval flash — rows that were just evaluated (one per @dN
    # block). _render_eval_flash! paints them in :success for the
    # FLASH_DURATION_S window, fading toward the end.
    eval_flash_rows::Vector{Int} = Int[]
    eval_flash_ts::Float64       = 0.0
    # Mixer modal state — cursor for j/k navigation among active slots.
    mixer_cursor::Int            = 1
    # Playhead parse cache: per-row (line_hash, parsed-NamedTuple-or-nothing).
    # Skips the regex + body split when a line hasn't changed between
    # frames — at 120 fps with 40 visible lines that's ~5000 alloc/sec
    # of garbage we don't produce. Pruned each render to the visible
    # window so it stays bounded.
    playhead_cache::Dict{Int,Tuple{UInt64,Any}} = Dict{Int,Tuple{UInt64,Any}}()
    # sccode browser state (only meaningful when modal === :sccode).
    # `entries` is the list fetched from sccode.org; `page` is the page
    # number we're on; cursor is the highlighted row (1-based).
    sccode_entries::Vector{_SccodeEntry} = _SccodeEntry[]
    sccode_cursor::Int           = 1
    sccode_page::Int             = 1
    sccode_loading::Bool         = false
    # Live filter — substring match against title + id. Toggled with `/`;
    # chars append to query in search_mode, Esc exits search_mode but
    # keeps the filter, q closes the modal entirely.
    sccode_query::String         = ""
    sccode_search_mode::Bool     = false
    # Tag filter for `:sccode-tag <tag>` (URL ?tag=…). Empty = no tag.
    sccode_tag::String           = ""
    # Browser modal state (only meaningful when modal === :browse).
    browser_query::String        = ""
    browser_cursor::Int          = 1
    browser_filter::Symbol       = :all   # :all | :instruments | :samples | :synths
    browser_last_preview::Float64 = 0.0
    logs::Vector{String}         = ["[INFO] Ressac — ? aide · e évalue · :synth <nom> pour concevoir un son · :q quitte"]
    quit::Bool                   = false
    tick::Int                    = 0
    # Manual zoom for the wave scope. Two independent axes — Y for
    # amplitude (+ / - / =), X for time-window width (> / < / |). Both
    # default 1.0; >1 zooms in, <1 zooms out. Only meaningful while
    # scope is :wave and the user is in normal mode.
    scope_zoom::Float64          = 1.0       # Y / amplitude
    scope_zoom_x::Float64        = 1.0       # X / time
    # Tab-cycle autocomplete state. Shared between :insert Tab (word
    # under cursor) and :command Tab (ex-command verb / arg). On the
    # first Tab, the entry point gathers candidates + builds a
    # `completion_splice` closure that knows how to write the chosen
    # string back into the appropriate buffer. Subsequent Tabs just
    # cycle through `completion_candidates` and re-invoke the splice.
    # Any non-Tab key clears via `_reset_completion!` so the next
    # Tab starts fresh.
    completion_candidates::Vector{String} = String[]
    completion_idx::Int          = 0
    completion_splice::Union{Function,Nothing} = nothing
    completion_label::String     = ""           # picker title prefix
    # Multi-column grid layout published by `_render_completion_picker!`
    # at draw time so arrow-key navigation (up/down = ±cols, left/right
    # = ±1) can compute the next cell without re-deriving the picker
    # geometry. Stays 1 until the first render of a session.
    completion_cols::Int         = 1
    # Ex-command history cursor. 0 = inactive (next ↑ in :command yanks
    # the latest entry); 1..N indexes into `_EX_COMMAND_HISTORY` from
    # the END (1 = most recent). Reset to 0 on submit / Esc.
    ex_history_idx::Int          = 0
    # (reservoir scope span lives in the module-level
    # `_APP_SCOPE_RESERVOIR_SPAN[]` Ref alongside its singleton siblings,
    # so the workspace ScopePane can render without an app handle.)
    # :keydebug toggles a verbose-input mode that pushes every KeyEvent
    # received from the terminal to the log pane. Lets the user see the
    # exact symbol + char + action for any keystroke when diagnosing
    # layout or terminal issues.
    keydebug::Bool               = false
    # :pause freezes the render loop so the user can shift-drag-select
    # and copy text from the terminal without the next frame overwriting
    # the selection highlight. Any keypress (handled in update!) resumes.
    paused::Bool                 = false
    # Held-T acceleration state. last_t_fire = time() of the previous
    # `_test_current_synth!` call; t_hold_interval_ms = current wait
    # before the next fire (decays toward config.t_hold_min_ms).
    last_t_fire::Float64         = 0.0
    t_hold_interval_ms::Float64  = 0.0
    # WAV recording. Set when /ressac/recStart fires; cleared on stop.
    # Status bar reads this to show ● REC.
    recording::Bool              = false
    recording_path::String       = ""
    recording_start_ts::Float64  = 0.0
    workspaces::WorkspaceManager            = WorkspaceManager()
    # Layout rects published by view() each frame for the mouse
    # handler and overlay paths. These caches avoid re-deriving chrome
    # heights from area in dispatch code. They mirror what view()
    # would compute again; readers should treat them as best-effort.
    _last_log_rect::Union{Nothing,TK.Rect}  = nothing
    # Sub-project 10: Ctrl-Shift-F toggles every floating pane's
    # visibility globally (Zellij-style "hide UI" affordance).
    floats_hidden::Bool                     = false
    # Autonomous command + search bar — owns ':' / '/' input. Lives
    # at the app level so it's reachable regardless of which workspace
    # pane has focus. Activated by the global interceptor at the top
    # of update!(KeyEvent).
    command_line::CommandLine               = CommandLine()
    # Workspace area NamedTuple captured by view() each frame so the
    # mouse handler can re-run _compute_rects without re-deriving
    # chrome heights.
    _last_ws_area::Union{Nothing,NamedTuple} = nothing
    # Per-modal row → entry-index mapping built during render so the
    # mouse handler can resolve "click row N" → "select entry K".
    modal_rows::Vector{Tuple{Int,Int}}   = Tuple{Int,Int}[]  # (screen_y, entry_idx)
    # Log scroll offset (lines from the bottom). 0 = bottom, increases
    # backwards into history. Bumped by wheel events over the log pane.
    log_scroll::Int                      = 0
    # Journal en bas de l'écran : nombre de lignes (0 = replié). `:log`
    # bascule 3 → 10 → 0. Une pane :log dans l'arbre le replie aussi.
    log_tail_rows::Int                   = 3
    # Tap-to-record rhythm. `:tap [sample] [steps]` enters this mode;
    # Space records a hit at the current time, Enter commits the
    # quantized pattern into the buffer, Esc cancels. Any other key is
    # swallowed so the user can focus on tapping.
    tap_recording::Bool                  = false
    tap_events::Vector{Float64}          = Float64[]
    tap_sample::String                   = "bd"
    tap_steps::Int                       = 16
    tap_bars::Int                        = 1            # play the same pattern N bars → average
    tap_mode::Symbol                     = :pattern     # :pattern or :tempo (cps from taps)
    # Piano mode — letter keys map to semitones, hitting one fires the
    # current synth at that pitch. `piano_rec` toggles recording so
    # Enter commits the played notes as `@dN :synth |> n(p"...")`.
    piano_active::Bool                   = false
    piano_rec::Bool                      = false
    piano_synth::String                  = "fmbell"
    piano_octave::Int                    = 4               # MIDI octave (4 ≈ A4 = 440Hz region)
    piano_events::Vector{Tuple{Float64,Int}} = Tuple{Float64,Int}[]
    piano_steps::Int                     = 16
    # Ghost autocomplete — a faded suggestion that follows the cursor in
    # insert mode. Tab accepts it (and bumps its usage count in the
    # global ranking). Computed on every insert keystroke from the
    # surrounding context.
    ghost::String                        = ""
    ghost_row::Int                       = 0
    ghost_col::Int                       = 0   # 0-based; the col AT which the suggestion would be inserted
end

# Kitty CSI u reports numpad keys with their own :kp_<n> symbol instead
# of a :char event, so the CodeEditor (which only inserts on :char) drops
# them silently. Translate the numpad symbol set into the equivalent
# printable char + :char key so the editor handles them like regular
# digit / punctuation keystrokes.
const _NUMPAD_TO_CHAR = Dict{Symbol,Char}(
    :kp_0 => '0', :kp_1 => '1', :kp_2 => '2', :kp_3 => '3', :kp_4 => '4',
    :kp_5 => '5', :kp_6 => '6', :kp_7 => '7', :kp_8 => '8', :kp_9 => '9',
    :kp_decimal => '.', :kp_divide => '/', :kp_multiply => '*',
    :kp_subtract => '-', :kp_add => '+', :kp_equal => '=',
    :kp_separator => ',',
)

function _normalise_event(evt::TK.KeyEvent)
    c = get(_NUMPAD_TO_CHAR, evt.key, nothing)
    c === nothing && return evt
    return TK.KeyEvent(:char, c, evt.action)
end

"""
    _focused_buffer(m) -> Union{EditorBuffer, Nothing}

The `EditorBuffer` of the EditorPane currently focused in the active
workspace, or `nothing` if the focused leaf isn't an editor pane.
The single source of truth for "what is the user editing right now",
including its role (`:patterns` / `:synth`), name and synth_mode.
"""
function _focused_buffer(m::RessacApp)
    _ensure_default_workspace!(m)
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    (leaf isa PaneLeaf && 1 <= leaf.current_tab <= length(leaf.tabs)) || return nothing
    pane = leaf.tabs[leaf.current_tab]
    (pane isa EditorPane && 1 <= pane.current_tab <= length(pane.tabs)) || return nothing
    return pane.tabs[pane.current_tab]
end

"""
    _active_editor(m) -> CodeEditor

The `TK.CodeEditor` the user is currently editing — the focused
EditorPane's editor, or the first editor pane found anywhere if the
focused leaf isn't an editor. Throws if no editor pane exists at all.
Single source of truth for "where typed text goes".
"""
function _active_editor(m::RessacApp)
    buf = _focused_buffer(m)
    buf !== nothing && return buf.code_editor
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        for any_leaf in _all_leaves(ws.tree)
            for tab in any_leaf.tabs
                if tab isa EditorPane && !isempty(tab.tabs)
                    return tab.tabs[tab.current_tab].code_editor
                end
            end
        end
    end
    # No editor pane anywhere — patterns is a pane like any other and
    # may be closed. Callers that run every frame (view chrome) or on
    # every key (routing) must tolerate `nothing`; in-editor-context
    # callers never see it because they only run when an editor exists.
    return nothing
end

"""
    _focused_role(m) -> Symbol

`:patterns` / `:synth` for an editor pane, `:other` for a non-editor
pane (log / doc / scope / tuning) or no focus. Replaces the legacy
`m.focus` field — the workspace tree is now authoritative.
"""
function _focused_role(m::RessacApp)
    buf = _focused_buffer(m)
    buf === nothing ? :other : buf.role
end

"""
    _all_synth_buffers(m) -> Vector{Tuple{PaneLeaf, EditorBuffer}}

Every synth-role editor buffer in the active workspace, paired with
its containing leaf (for focus / close operations). Order follows
the tree's leaf iteration so `:tabnext` cycling is stable.
"""
function _all_synth_buffers(m::RessacApp)
    out = Tuple{PaneLeaf, EditorBuffer}[]
    ws = current_workspace(m.workspaces)
    ws === nothing && return out
    for leaf in _all_leaves(ws.tree)
        for tab in leaf.tabs
            if tab isa EditorPane
                for b in tab.tabs
                    b.role === :synth && push!(out, (leaf, b))
                end
            end
        end
    end
    return out
end

# A synth pane is open when at least one synth-role buffer exists.
_synth_pane_open(m::RessacApp) = !isempty(_all_synth_buffers(m))

# Le pane focalisé est-il un WaveformPane en mode sculpt ? (laisse passer Tab)
function _is_waveform_sculpt_focused(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return false
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    (leaf === nothing || isempty(leaf.tabs)) && return false
    pane = leaf.tabs[leaf.current_tab]
    return pane isa WaveformPane && pane.sculpt
end

"""
    _current_synth_tab(m) -> Union{EditorBuffer, Nothing}

The focused synth buffer if the focused pane is synth-role;
otherwise the first synth buffer found in the tree (so `:test` /
`:w` still target *a* synth when focus drifted). `nothing` when no
synth pane is open.
"""
function _current_synth_tab(m::RessacApp)
    buf = _focused_buffer(m)
    (buf !== nothing && buf.role === :synth) && return buf
    syn = _all_synth_buffers(m)
    isempty(syn) ? nothing : syn[1][2]
end

"""
    _focused_editor_rect(m) -> Union{Nothing,TK.Rect}

Inner rect of the workspace leaf currently holding the focused
EditorPane — i.e. the on-screen area where `_active_editor(m)` is
rendered. Computed on demand from `m._last_ws_area` +
`_compute_rects`; returns `nothing` if the workspace area hasn't
been published yet (pre-first-view) or if the focused leaf isn't
an editor pane.

Used by mouse hit-tests (click-into-editor) and overlay paths
(eval flash, playhead, visual selection, ghost autocomplete).
"""
function _focused_editor_rect(m::RessacApp)
    m._last_ws_area === nothing && return nothing
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    leaf isa PaneLeaf || return nothing
    (1 <= leaf.current_tab <= length(leaf.tabs)) || return nothing
    pane = leaf.tabs[leaf.current_tab]
    pane isa EditorPane || return nothing
    rects = _workspace_rects(m, ws, m._last_ws_area)
    r_nt = get(rects, leaf.id, nothing)
    r_nt === nothing && return nothing
    return _inner_rect_simple(_nt_to_rect(r_nt))
end

TK.should_quit(m::RessacApp) = m.quit

"""
    _ensure_default_workspace!(m::RessacApp)

Make sure the workspace manager has at least one workspace with a
:editor pane. Idempotent — safe to call multiple times.

In Task 8 of the sub-project 9 implementation, this is invoked by
start_live! (and on first access) so the workspace tree exists for
later tasks (split commands, persistence). The legacy view() path
still drives the visible UI; Task 15 swaps view to dispatch through
the workspace manager and removes the legacy m.layout_* fields.
"""
# Les trois façons de travailler. Créés au premier rendu ; chacun se
# remplit à la demande (première visite) : PLAY = patterns, DESIGN = une
# pane synth « sketch », EXPLORE = l'explorateur GA.
const _DEFAULT_WORKSPACES = ("PLAY", "DESIGN", "EXPLORE")

function _ensure_default_workspace!(m::RessacApp)
    if isempty(m.workspaces.workspaces)
        for n in _DEFAULT_WORKSPACES
            create_workspace!(m.workspaces, n)
        end
        m.workspaces.current_idx = 1
    end
    # Make sure the global log Ref points at the live app log so the
    # LogPane and the chrome log row share storage.
    _APP_LOG[] = m.logs
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    _fill_workspace!(ws)
    return
end

"""
    _fill_workspace!(ws)

Peuple un workspace dont la racine est un leaf vide, selon son nom :
PLAY (ou sans nom) → éditeur patterns avec le buffer de démarrage ;
DESIGN → pane synth « sketch » (starter DSL) ; EXPLORE → explorateur.
No-op si le workspace a déjà du contenu (chemin :layout load).
"""
function _fill_workspace!(ws::Workspace)
    leaf = ws.tree
    (leaf isa PaneLeaf && isempty(leaf.tabs)) || return
    if ws.name == "DESIGN"
        ep = _pane_new(:editor, Dict{String,Any}("buffer_role" => "synth", "name" => "sketch"))
        eb = ep.tabs[1]
        eb.synth_mode = :dsl
        TK.set_text!(eb.code_editor, _STARTER_DSL("sketch"))
        eb.code_editor.mode = :normal
        push!(leaf.tabs, ep)
    elseif ws.name == "EXPLORE"
        push!(leaf.tabs, _pane_new(:explorer, Dict{String,Any}()))
    else
        ep = _pane_new(:editor, Dict{String,Any}())
        TK.set_text!(ep.tabs[1].code_editor, _STARTER_BUFFER)
        push!(leaf.tabs, ep)
    end
    leaf.current_tab = 1
    ws.focused_pane = leaf.id
    return
end

"""
    _switch_workspace_named!(m, name) -> Bool

Bascule sur le workspace `name` (le crée s'il n'existe pas) et le
remplit s'il est vide. `:play` / `:design` / `:explore`, et les ponts
gs / U.
"""
function _switch_workspace_named!(m::RessacApp, name::AbstractString)
    wm = m.workspaces
    idx = findfirst(w -> w.name == name, wm.workspaces)
    if idx === nothing
        create_workspace!(wm, name)
    else
        cmd_workspace_switch!(wm, idx)
    end
    ws = current_workspace(wm)
    ws === nothing || _fill_workspace!(ws)
    return true
end

"""
    _place_pane!(m, kind, args) -> PaneImpl | Nothing

Met une pane dans le workspace courant : DANS le leaf racine s'il est
vide (workspace fraîchement créé), sinon en vsplit à droite du focus.
"""
function _place_pane!(m::RessacApp, kind::Symbol, args::AbstractDict)
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    leaf = ws.tree
    if leaf isa PaneLeaf && isempty(leaf.tabs)
        pane = _pane_new(kind, args)
        push!(leaf.tabs, pane)
        leaf.current_tab = 1
        ws.focused_pane = leaf.id
        return pane
    end
    cmd_vsplit!(m.workspaces, String(kind), args)
    return _focused_pane_impl(m)
end

"""
    _focused_pane_impl(m) -> Union{Nothing,PaneImpl}

La PaneImpl du leaf focalisé du workspace courant (onglet courant), ou
`nothing`. Sert au registre (scope de la pane) et à l'aide.
"""
function _focused_pane_impl(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return nothing
    leaf = _find_leaf_by_id(ws.tree, ws.focused_pane)
    (leaf === nothing || isempty(leaf.tabs)) && return nothing
    1 <= leaf.current_tab <= length(leaf.tabs) || return nothing
    return leaf.tabs[leaf.current_tab]
end

# ── Zoom de pane ────────────────────────────────────────────────────
"""
    _workspace_rects(m, ws, area) -> Dict{Int,NamedTuple}

Rects des leaves du workspace : tout l'arbre, ou seulement le leaf zoomé
(qui prend toute l'aire) quand `m.zoom_leaf` désigne le leaf focalisé.
"""
function _workspace_rects(m::RessacApp, ws::Workspace, area::NamedTuple)
    if m.zoom_leaf != 0 && m.zoom_leaf == ws.focused_pane &&
       _find_leaf_by_id(ws.tree, m.zoom_leaf) !== nothing
        return Dict{Int,NamedTuple}(m.zoom_leaf => area)
    end
    return _compute_rects(ws.tree, area)
end

"""
    _toggle_zoom!(m)

Zoome le leaf focalisé (seul à l'écran) ou dézoome s'il l'est déjà.
"""
function _toggle_zoom!(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    m.zoom_leaf = m.zoom_leaf == ws.focused_pane ? 0 : ws.focused_pane
    return
end

# La pane sculpt focalisée, ou nothing.
function _focused_sculpt_pane(m::RessacApp)
    p = _focused_pane_impl(m)
    return p isa WaveformPane && p.sculpt ? p : nothing
end
