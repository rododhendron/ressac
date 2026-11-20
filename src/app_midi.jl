# src/app_midi.jl
# L'entrée MIDI. SuperCollider ouvre les périphériques au démarrage
# (scripts/superdirt-startup.scd) et renvoie chaque note et chaque bouton
# à Ressac par OSC : `/ressac/midi <on|off|cc> <numéro> <valeur> <canal>`.
# Le fil d'écoute OSC les range dans une file ; l'app les sert à chaque
# image, sur le fil de l'interface — là où elle a le droit de toucher à
# son état. Rien à coller dans SuperCollider, aucune dépendance de plus.
#
# Une note va là où elle a un sens :
#   • le piano est ouvert (`:piano`, `:piano-rec`) → elle le joue, et
#     s'enregistre avec les autres ;
#   • sinon, un son est ouvert → on l'entend à cette hauteur (elle devient
#     la note de test, comme `:note`) ;
#   • sinon, rien : le journal dit une fois comment s'en servir.

struct MidiEvent
    kind::Symbol      # :on | :off | :cc
    num::Int          # numéro de note, ou de contrôleur
    val::Int          # vélocité, ou valeur du contrôleur (0–127)
    chan::Int
end

const _MIDI_QUEUE = MidiEvent[]
const _MIDI_LOCK = ReentrantLock()
const _MIDI_MAX_QUEUE = 512          # un contrôleur bavard ne remplit pas la mémoire

_midi_int(x) = x isa Real ? round(Int, x) : something(tryparse(Int, string(x)), 0)

"""
    _handle_midi!(args)

Un message `/ressac/midi` reçu (fil d'écoute OSC) : rangé dans la file.
Un message mal formé est ignoré.
"""
function _handle_midi!(args)
    length(args) >= 3 || return
    kind = Symbol(string(args[1]))
    kind in (:on, :off, :cc) || return
    ev = MidiEvent(kind, _midi_int(args[2]), _midi_int(args[3]), length(args) >= 4 ? _midi_int(args[4]) : 0)
    lock(_MIDI_LOCK) do
        length(_MIDI_QUEUE) >= _MIDI_MAX_QUEUE && popfirst!(_MIDI_QUEUE)
        push!(_MIDI_QUEUE, ev)
    end
    return
end

function _midi_drain!()
    lock(_MIDI_LOCK) do
        out = copy(_MIDI_QUEUE)
        empty!(_MIDI_QUEUE)
        return out
    end
end

const _MIDI_HINTED = Ref(false)

"""
    _midi_tick!(m)

Sert les notes MIDI arrivées depuis la dernière image. Un « note on » de
vélocité 0 est un relâchement (convention MIDI) : ignoré, comme les « off »
— les sons de Ressac ont leur propre durée.
"""
function _midi_tick!(m::RessacApp)
    evs = _midi_drain!()
    isempty(evs) && return
    for ev in evs
        (ev.kind === :on && ev.val > 0) || continue
        _midi_note!(m, ev.num)
    end
    return
end

function _midi_note!(m::RessacApp, num::Int)
    if m.piano_active
        # Le piano joue `octave × 12 + demi-ton` : on lui donne le demi-ton
        # qui tombe sur cette note, il l'enregistre comme les siennes.
        _piano_play!(m, num - m.piano_octave * 12)
    elseif _current_sound(m) !== nothing
        m.test_note = num
        _test_current_synth!(m)
    elseif !_MIDI_HINTED[]
        _MIDI_HINTED[] = true
        _push_app_log!(m, "[INFO] clavier MIDI reçu — :piano <son> pour jouer, :piano-rec <son> pour écrire ce que tu joues, ou ouvre un son (gs) pour l'entendre à la note")
    end
    return
end
