# Entry point for the multi-line TUI. The real work lives in
# `tui_model.jl`, `tui_buffer.jl`, `tui_eval.jl`, `tui_search.jl`,
# `tui_bindings.jl`, and `tui_view.jl`, which are all included by
# `Ressac.jl` before this file. This module just defines the public
# session-management API: `start_live!`, `stop_live!`, `restart_live!`,
# `live`, plus the implicit-scheduler helpers (`d!`, `unset!`,
# `hush_all!`, `cps!`).

const _LIVE_SCHEDULER = Ref{Union{Scheduler,Nothing}}(nothing)

function _check_live()
    s = _LIVE_SCHEDULER[]
    s === nothing && error("Pas de scheduler live — lance start_live!() ou live() d'abord.")
    return s
end

d!(slot::Symbol, p::Pattern) = set_pattern!(_check_live(), slot, p)
unset!(slot::Symbol)         = unset_pattern!(_check_live(), slot)
hush_all!()                  = hush!(_check_live())
cps!(x::Real)                = set_cps!(_check_live(), x)

function start_live!(; host::AbstractString = "127.0.0.1",
                       port::Integer = 57120,
                       cps::Real = 0.5,
                       lookahead::Real = 0.05,
                       plugins::Bool = true)
    if _LIVE_SCHEDULER[] !== nothing
        @warn "A live session is already running — returning the existing scheduler."
        return _LIVE_SCHEDULER[]
    end
    client = OSCClient(host, port)
    sched  = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    plugins && _load_plugins()
    return sched
end

function stop_live!()
    s = _LIVE_SCHEDULER[]
    s === nothing && return nothing
    stop!(s); hush!(s); _LIVE_SCHEDULER[] = nothing
    return nothing
end

restart_live!(; kwargs...) = (stop_live!(); start_live!(; kwargs...))

"""
    _request_alternate_keys()

Demande au terminal de signaler le caractère « tel qu'il sort avec Maj »
(bit 4 du protocole clavier kitty). Tachikoma n'active que les bits 1, 2
et 8 et retombe donc sur une table Maj **QWERTY** : sur un clavier
AZERTY, Maj+ù rendait `ù` au lieu de `%`. Avec ce drapeau, le terminal
envoie le caractère produit, quelle que soit la disposition.
`CSI = flags ; 1 u` change le niveau courant de la pile, sans empiler un
niveau qu'il faudrait dépiler à la sortie.

Sans terminal (tests, exécution non interactive) l'appel ne fait rien.
"""
function _request_alternate_keys()
    try
        isa(stdout, Base.TTY) || return nothing
        write(stdout, "\e[=15;1u")
        flush(stdout)
    catch
        # Un terminal qui ne connaît pas la séquence l'ignore.
    end
    return nothing
end

"""
    live(; host, port, cps, lookahead)

Boot the Tachikoma-based TUI on top of an active (or freshly-started)
scheduler. The legacy `_ressac_app!(::LiveModel)` loop was removed in
the phase-3 LiveModel cleanup — `Tachikoma.app(RessacApp(...))` is now
the single entry point.
"""
function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    _ = nothing
    existed = _LIVE_SCHEDULER[] !== nothing
    sched = existed ? _LIVE_SCHEDULER[] : start_live!(; host, port, cps, lookahead)
    cfg = _load_ressac_config!()
    _apply_theme!(cfg.theme)
    _install_syntax_theme!()   # punctuation/builtins legible on dark bg
    # La disposition du clavier : la table Maj de Tachikoma est QWERTY,
    # on installe celle qui correspond (voir session_keyboard.jl).
    (kb_layout, kb_source) = try _setup_keyboard!(cfg.keyboard) catch; (:qwerty, "défaut") end
    # Bring the Synth DSL into Main's namespace so pattern evals can
    # use saw/rlpf/lfo/@synth/... without an explicit `using`. Done
    # once per `live()` call; idempotent.
    try
        Core.eval(Main, :(using Ressac.SynthDSL))
    catch
    end
    app = RessacApp(; scheduler=sched)
    _push_app_log!(app, "[INFO] clavier : $kb_layout ($kb_source) — :keyboard azerty|qwerty|auto pour changer")
    # Le port d'écoute des réponses de SC (scope, mètres, découverte) :
    # s'il est pris, tout ce qui vient de SC se perd — on le dit au boot.
    _ensure_app_scope_listener!() ||
        _push_app_log!(app, "[ERROR] " * _SCOPE_LISTENER_ERROR[])
    # Sub-project 10: restore the last persisted workspace layout if
    # any. Wrapped so a corrupted file doesn't block boot — the
    # default workspace fallback handles the empty/error case.
    try
        load_layout!(app.workspaces, _default_layout_path())
    catch err
        @warn "Failed to load layout" exception=err
    end
    _ensure_default_workspace!(app)
    _request_alternate_keys()
    cfg.hover && _request_mouse_motion()
    try
        Tachikoma.app(app; fps=cfg.fps)
    finally
        cfg.hover && _release_mouse_motion()
        # Persist the workspace layout so the next launch restores the
        # panes the user had open (explorer, splits, …). Best-effort:
        # a failure here must not block a clean shutdown.
        try
            save_layout(app.workspaces, _default_layout_path())
        catch err
            @warn "Failed to save layout" exception=err
        end
        # Always free SC voices on exit — drones with auto_env=false
        # would otherwise keep playing after Ressac closes. Cheap nuke
        # via /ressac/panic.
        try
            send_osc(sched.osc, encode(OSCMessage("/ressac/panic", Any[])))
        catch
        end
        existed || stop_live!()
    end
    return nothing
end
