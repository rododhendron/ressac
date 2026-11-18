# src/modal_outputs.jl
# `:sorties` — choisir la sortie principale et le casque, et les brancher.
#
# Le casque entend la sortie principale, plus ce qu'on essaie : avec
# « l'atelier au casque » (`:casque`, ou `p` ici), les écoutes — `T`, les
# propositions de l'atelier, les candidats de l'explorateur — ne vont QUE
# dans le casque. La sortie principale, elle, ne change pas tant qu'on n'a
# rien gardé. L'enregistrement ne prend que la sortie principale.

# Le réglage, gardé d'une fois sur l'autre.
mutable struct AudioSettings
    main::String        # node.name de la sortie principale ("" : celle que SuperCollider a prise)
    casque::String      # node.name du casque ("" : pas de casque)
    preview::Bool       # les écoutes dans le casque seulement
end

_audio_settings_path() = joinpath(_config_dir(), "audio.toml")
const _AUDIO_SETTINGS = Ref{Union{Nothing,AudioSettings}}(nothing)

function _audio_settings()
    s = _AUDIO_SETTINGS[]
    s === nothing || return s
    s = AudioSettings("", "", false)
    path = _audio_settings_path()
    if isfile(path)
        try
            d = TOML.parsefile(path)
            s.main = String(get(d, "main", "")); s.casque = String(get(d, "casque", ""))
            s.preview = get(d, "preview", false) === true
        catch
        end
    end
    _AUDIO_SETTINGS[] = s
    return s
end

function _audio_settings_save!()
    s = _audio_settings()
    try
        mkpath(dirname(_audio_settings_path()))
        open(_audio_settings_path(), "w") do io
            TOML.print(io, Dict{String,Any}("main" => s.main, "casque" => s.casque, "preview" => s.preview))
        end
    catch
    end
    return
end

# Ce que SuperCollider doit savoir : le casque reçoit-il la sortie
# principale, et où vont les écoutes (bus 2 = le casque seul, 0 = partout).
function _audio_tell_sc!(m::RessacApp)
    s = _audio_settings()
    osc = m.scheduler.osc
    has = !isempty(s.casque)
    try
        send_osc(osc, encode(OSCMessage("/ressac/casque", Any[Int32(has ? 1 : 0)])))
        send_osc(osc, encode(OSCMessage("/ressac/previewOut", Any[Int32(has && s.preview ? 2 : 0)])))
    catch
    end
    return
end

"""
    _audio_apply!(m; quiet = false)

Relit le graphe PipeWire, branche SuperCollider selon le réglage et le lui
dit. En fond : `pw-dump` et `pw-link` sont des sous-processus.
"""
function _audio_apply!(m::RessacApp; quiet::Bool = false)
    s = _audio_settings()
    (main, casque) = (s.main, s.casque)
    _background!(() -> begin
        (g, note) = audio_graph()
        isempty(note) || return (g, 0, [note])
        (done, problems) = apply_routing!(g, main, casque)
        return (first(audio_graph()), done, problems)      # le graphe d'après, pour l'affichage
    end) do res, err
        if err !== nothing
            m.audio_note = first(sprint(showerror, err), 100)
            quiet || _push_app_log!(m, "[ERROR] sorties — $(m.audio_note)")
            return
        end
        (g, done, problems) = res
        m.audio_graph = g
        m.audio_note = join(problems, " · ")
        _audio_tell_sc!(m)
        if !isempty(problems)
            quiet || _push_app_log!(m, "[WARN] sorties — $(m.audio_note)")
        elseif done > 0 && !quiet
            _push_app_log!(m, "[INFO] sorties branchées ($done lien$(done > 1 ? "s" : ""))")
        end
    end
    return
end

"""
    _audio_tick!(m)

À chaque image : quand SuperCollider se met à répondre, le réglage gardé
est rebranché (ses ports n'existaient pas avant). Rien tant qu'aucune
sortie n'a été choisie.
"""
function _audio_tick!(m::RessacApp)
    alive = _sc_state() === :alive
    if alive && !m.audio_applied
        m.audio_applied = true
        s = _audio_settings()
        (isempty(s.main) && isempty(s.casque)) || _audio_apply!(m; quiet = true)
    elseif !alive
        m.audio_applied = false
    end
    return
end

# ── La modale ────────────────────────────────────────────────────────

function _open_outputs!(m::RessacApp)
    _open_modal!(m, :outputs)
    _picker_reset!(m.outs); _picker_search!(m.outs, false)
    _outputs_refresh!(m)
end

# Relit les sorties (une sortie branchée ou un casque allumé entre-temps).
function _outputs_refresh!(m::RessacApp)
    _background!(() -> audio_graph()) do res, err
        if err !== nothing
            m.audio_graph = AudioGraph(); m.audio_note = first(sprint(showerror, err), 100)
        else
            (m.audio_graph, m.audio_note) = res
        end
    end
    return
end

function _outputs_sync!(m::RessacApp, width::Int = 80)
    g = something(m.audio_graph, AudioGraph())
    s = _audio_settings()
    rows = TK.ListItem[]
    for sink in g.sinks
        role = sink.name == s.main ? "◉ sortie " : sink.name == s.casque ? "◎ casque " : "         "
        extra = (sink.default ? "  · par défaut du système" : "") *
                (sink.bluetooth ? "  · Bluetooth : le son arrive en retard" : "")
        style = sink.name == s.main ? TK.tstyle(:success, bold = true) :
                sink.name == s.casque ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
        push!(rows, TK.ListItem(first(role * sink.label * extra, width), style))
    end
    _picker_set!(m.outs, rows, g.sinks)
    return g.sinks
end

_outputs_cur(m::RessacApp) = (_outputs_sync!(m); _picker_selected(m.outs))

function _outputs_set_main!(m::RessacApp)
    sink = _outputs_cur(m)
    sink === nothing && return
    s = _audio_settings()
    s.main = sink.name
    s.casque == sink.name && (s.casque = "")
    _audio_settings_save!()
    _audio_apply!(m)
end

function _outputs_set_casque!(m::RessacApp)
    sink = _outputs_cur(m)
    sink === nothing && return
    s = _audio_settings()
    if s.casque == sink.name
        s.casque = ""                                   # de nouveau : plus de casque
    elseif s.main == sink.name
        _push_app_log!(m, "[INFO] « $(sink.label) » est déjà la sortie principale — choisis-en une autre pour le casque")
        return
    else
        s.casque = sink.name
    end
    _audio_settings_save!()
    _audio_apply!(m)
end

"""
    _casque_toggle!(m)

`:casque` — les écoutes (T, l'atelier, l'explorateur) dans le casque
seulement, ou de nouveau partout.
"""
function _casque_toggle!(m::RessacApp)
    s = _audio_settings()
    if isempty(s.casque)
        _push_app_log!(m, "[INFO] pas de casque choisi — :sorties, puis c sur ta sortie casque")
        return
    end
    s.preview = !s.preview
    _audio_settings_save!()
    _audio_tell_sc!(m)
    _push_app_log!(m, s.preview ?
        "[INFO] l'atelier au casque : ce que tu essaies (T, o / cim, l'explorateur) ne s'entend que dans le casque" :
        "[INFO] les écoutes s'entendent de nouveau partout")
    return
end

function _handle_outputs_key!(m::RessacApp, evt::TK.KeyEvent)
    (evt.key === :escape || evt.char == 'q') && (m.modal = :none; return)
    dispatch!(((:modal_outputs, m),), evt)
    return
end

function _render_outputs_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    sinks = something(m.audio_graph, AudioGraph()).sinks
    n = length(sinks)
    inner = _render_modal_block!(buf, area;
        title = "SORTIES",
        title_right = _modal_hint_text(m, :modal_outputs),
        w_max = 96,
        h_target = max(12, min(area.height - 4, n + 9)))
    inner.width < 24 && return
    s = _audio_settings()
    _outputs_sync!(m, inner.width - 3)
    list_h = max(1, inner.height - 5)
    if n == 0
        why = isempty(m.audio_note) ? "Aucune sortie audio trouvée — r pour relire." : m.audio_note
        TK.set_string!(buf, inner.x, inner.y, first(why, inner.width), TK.tstyle(:text_dim))
    else
        _picker_render_list!(m.outs, TK.Rect(inner.x, inner.y, inner.width, min(list_h, n)), buf)
    end
    y = inner.y + inner.height - 4
    lines = Tuple{String,Symbol}[]
    push!(lines, (isempty(s.casque) ? "Pas de casque : tout sort par la sortie principale." :
                  s.preview ? "Le casque entend la sortie, plus ce que tu essaies — que lui seul entend." :
                              "Le casque entend la même chose que la sortie. p : ce que tu essaies, pour lui seul.", :text))
    push!(lines, ("L'enregistrement (:rec) ne prend que la sortie principale.", :text_dim))
    isempty(m.audio_note) || n == 0 || push!(lines, (m.audio_note, :warning))
    for (i, (txt, color)) in enumerate(lines)
        y + i <= inner.y + inner.height - 1 || break
        TK.set_string!(buf, inner.x, y + i, first(txt, inner.width), TK.tstyle(color))
    end
    return
end

scope!(:modal_outputs, "Sorties audio (:sorties)"; layer = :modal)
bind!(:modal_outputs, "Enter", "sortie principale"; short = "sortie", group = :audio, action = _outputs_set_main!)
bind!(:modal_outputs, "c", "casque (de nouveau : plus de casque)"; short = "casque", group = :audio, action = _outputs_set_casque!)
bind!(:modal_outputs, "p", "ce que j'essaie : dans le casque seulement / partout"; short = "essais au casque", group = :audio,
      action = _casque_toggle!)
bind!(:modal_outputs, "r", "relire les sorties (un casque qu'on vient d'allumer)"; short = "relire", group = :nav,
      action = _outputs_refresh!)
mixin_list_nav!(:modal_outputs, (m, key) -> _picker_nav!(m.outs, key); before = _outputs_sync!)
_bind_modal_common!(:modal_outputs; nav = false)
