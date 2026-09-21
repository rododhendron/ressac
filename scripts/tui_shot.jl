# scripts/tui_shot.jl — captures texte de la TUI, sans terminal.
#
#     julia --project=. scripts/tui_shot.jl <dossier_sortie>
#     SHOT_W=140 SHOT_H=40 julia --project=. scripts/tui_shot.jl /tmp/shots
#
# Construit une RessacApp headless (scheduler sur OSC mocké, comme
# test/test_visual_integration.jl), rejoue des scénarios de touches et
# dumpe chaque frame rendue (Tachikoma.TestBackend) en <nom>.txt.
# Sert à REGARDER l'UI (revue visuelle, diff entre deux commits) — les
# assertions, elles, vivent dans test/test_visual_integration.jl.
#
# Le buffer est remis à zéro avant chaque vue (`TK.reset!`), comme le
# fait le terminal réel entre deux frames : sans ça, on verrait des
# traînées de frames précédentes qui n'existent pas à l'écran.

using Ressac
import Tachikoma
const TK = Tachikoma

mutable struct _ShotOSC; sent::Vector{Vector{UInt8}}; end
_ShotOSC() = _ShotOSC(Vector{UInt8}[])
Ressac.send_osc(c::_ShotOSC, bytes::Vector{UInt8}) = push!(c.sent, bytes)

const W = parse(Int, get(ENV, "SHOT_W", "140"))
const H = parse(Int, get(ENV, "SHOT_H", "40"))
const OUT = isempty(ARGS) ? mktempdir() : ARGS[1]
isdir(OUT) || mkpath(OUT)

function newapp()
    sched = Ressac.Scheduler(_ShotOSC(); cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = TK.TestBackend(W, H)
    frame = TK.Frame(tb.buf, TK.Rect(1, 1, W, H), TK.GraphicsRegion[], TK.PixelSnapshot[])
    TK.view(app, frame)                    # amorce le workspace par défaut
    Ressac._PANE_MODE.active = false
    return app, tb, frame
end

key(app, c::Char)   = TK.update!(app, TK.KeyEvent(c))
key(app, s::Symbol) = TK.update!(app, TK.KeyEvent(s))
typ(app, s)         = foreach(c -> key(app, c), s)
ex(app, cmd)        = (key(app, ':'); typ(app, cmd); key(app, :enter))

function snap(app, tb, frame, name)
    TK.reset!(tb.buf)
    TK.view(app, frame)
    open(joinpath(OUT, name * ".txt"), "w") do io
        for y in 1:H; println(io, rstrip(TK.row_text(tb, y))); end
    end
    println("• $name  modal=$(app.modal) role=$(Ressac._focused_role(app))")
end

# ── Scénarios ──────────────────────────────────────────────────────
let (app, tb, frame) = newapp()
    snap(app, tb, frame, "01_initial")
    key(app, '?');      snap(app, tb, frame, "02_help_from_patterns")
    key(app, :escape)
    key(app, ':');      snap(app, tb, frame, "03_cmdline"); key(app, :escape)
    key(app, ' ');      snap(app, tb, frame, "04_space_leader"); key(app, :escape)
    ex(app, "lib");     snap(app, tb, frame, "05_lib_modal"); key(app, :escape)
    ex(app, "browse");  snap(app, tb, frame, "06_browse_modal"); key(app, :escape)
    ex(app, "wiki");    snap(app, tb, frame, "07_wiki_modal"); key(app, :escape)
    ex(app, "mixer");   snap(app, tb, frame, "08_mixer_modal"); key(app, :escape)
end
let (app, tb, frame) = newapp()
    ex(app, "synth kick"); snap(app, tb, frame, "10_synth_pane")
    key(app, '?');         snap(app, tb, frame, "11_help_from_synth")
    ex(app, "sculpt");     snap(app, tb, frame, "12_sculpt_from_synth")
end
let (app, tb, frame) = newapp()
    ex(app, "vsplit explorer"); snap(app, tb, frame, "20_explorer_pane")
    key(app, '?');              snap(app, tb, frame, "21_help_from_explorer")
    key(app, :escape)
    key(app, 'M');              snap(app, tb, frame, "22_sculpt_from_explorer")
    key(app, :escape)
end
let (app, tb, frame) = newapp()
    ex(app, "vsplit log");  snap(app, tb, frame, "30_vsplit_log")
    key(app, '?');          snap(app, tb, frame, "31_help_from_log")
end
println("→ $OUT")
