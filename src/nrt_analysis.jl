# src/nrt_analysis.jl
# Analyse acoustique HORS-LIGNE (NRT). Rend un lot de génomes en silence
# via sclang headless (QT_QPA_PLATFORM=minimal) + Score.recordNRT, relit le
# wav multicanal, et en sort un vecteur descripteur par candidat. sclang
# compile les synthdefs → feature-complete (FFT/Env/n'importe quel UGen),
# aucun hardcoding. Aucune sortie audio, plus vite que le temps réel.

# Descripteurs scalaires dérivés des canaux d'analyse (cf. ANALYSIS_CHANNELS).
const DESCRIPTORS = (:centroid, :subratio, :flatness, :attack, :sustainness, :pitchconf)
const N_DESCRIPTORS = length(DESCRIPTORS)

const _NRT_SR = 44100
const _NRT_GAP = 0.05          # silence entre candidats (s)

_sclang_available() = Sys.which("sclang") !== nothing
_nrt_slot_dt() = 0.01 + _NRT_WINDOW + 0.02 + _NRT_GAP   # durée d'un slot candidat

# Script sclang : un Score qui charge tous les analysis-synthdefs (t=0) puis
# joue chaque candidat dans sa fenêtre temporelle ; recordNRT rend hors-ligne.
function _build_nrt_script(genomes, wavpath::String, oscpath::String)
    dt = _nrt_slot_dt()
    io = IOBuffer()
    println(io, "(")
    # SC : tous les `var` AVANT le 1er statement → on déclare defs/events en
    # tête, on construit le tableau de synthdefs d'un bloc, puis les events.
    println(io, "var defs, events;")
    print(io, "defs = [")
    for (i, g) in enumerate(genomes)
        i > 1 && print(io, ",")
        print(io, "\n", render_analysis_synthdef(g, Symbol("nrt", i)))
    end
    println(io, "\n];")
    println(io, "events = [];")
    println(io, "defs.do { |d| events = events.add([0.0, ['/d_recv', d.asBytes]]) };")
    for i in eachindex(genomes)
        t = (i - 1) * dt
        println(io, "events = events.add([", round(t; digits = 4),
                ", ['/s_new', \"nrt", i, "\", ", 1000 + i, ", 0, 0]]);")
    end
    total = length(genomes) * dt + 0.1
    println(io, "events = events.add([", round(total; digits = 4), ", ['/c_set', 0, 0]]);")
    println(io, "Score(events).recordNRT(")
    println(io, "  \"", oscpath, "\", \"", wavpath, "\", nil,")
    println(io, "  ", _NRT_SR, ", \"WAV\", \"float\",")
    println(io, "  ServerOptions.new.numOutputBusChannels_(", N_ANALYSIS_CHANNELS, "),")
    println(io, "  duration: ", round(total; digits = 4), ",")
    println(io, "  action: { 0.exit });")
    println(io, ")")
    return String(take!(io))
end

# Lecture d'un wav PCM float 32-bit (ce que recordNRT écrit) → matrice
# canaux × frames, en Float64.
function _read_wav_f32(path::String)
    raw = read(path)
    (length(raw) > 12 && raw[1:4] == b"RIFF" && raw[9:12] == b"WAVE") ||
        error("nrt: wav invalide ($path)")
    pos = 13; ch = 0; sr = 0; dpos = 0; dsz = 0
    while pos + 8 <= length(raw)
        cid = String(raw[pos:pos+3])
        sz  = Int(reinterpret(UInt32, raw[pos+4:pos+7])[1]); pos += 8
        if cid == "fmt "
            ch = Int(reinterpret(UInt16, raw[pos+2:pos+3])[1])
            sr = Int(reinterpret(UInt32, raw[pos+4:pos+7])[1])
        elseif cid == "data"
            dpos = pos; dsz = sz
        end
        pos += sz + (sz % 2)
    end
    (ch > 0 && dpos > 0) || error("nrt: wav sans fmt/data")
    samples = reinterpret(Float32, raw[dpos:dpos+dsz-1])
    nframes = length(samples) ÷ ch
    mat = Array{Float64}(undef, ch, nframes)
    @inbounds for f in 1:nframes, c in 1:ch
        mat[c, f] = Float64(samples[(f - 1) * ch + c])
    end
    return mat, sr
end

_safe_mean(v) = isempty(v) ? 0.0 : sum(v) / length(v)

# Descripteurs scalaires depuis la fenêtre [t0, t0+win] du canal-mat.
# Canaux : 1 centroïde · 2 subratio · 3 platitude · 4 amp · 5 pitchconf.
function _descriptors_from_window(mat, sr::Int, t0::Float64, win::Float64)
    nf = size(mat, 2)
    f0 = clamp(round(Int, t0 * sr) + 1, 1, nf)
    fend = clamp(round(Int, (t0 + win) * sr), 1, nf)
    fend <= f0 && return zeros(N_DESCRIPTORS)
    # régime établi (saute 20 ms d'attaque) pour les descripteurs spectraux
    fs = clamp(round(Int, (t0 + 0.03) * sr) + 1, f0, fend)
    centroid  = _safe_mean(@view mat[1, fs:fend])
    subratio  = _safe_mean(@view mat[2, fs:fend])
    flatness  = _safe_mean(@view mat[3, fs:fend])
    pitchconf = _safe_mean(@view mat[5, fs:fend])
    # canaux temporels : sur toute la fenêtre (attaque comprise)
    amp = mat[4, f0:fend]
    pk, pki = findmax(amp)
    attack = pk < 1e-4 ? 0.0 : clamp(1.0 - (pki - 1) / max(1, length(amp) - 1), 0.0, 1.0)
    tail = amp[max(1, length(amp) - length(amp) ÷ 4 + 1):end]
    sustainness = pk < 1e-4 ? 0.0 : clamp(_safe_mean(tail) / pk, 0.0, 1.0)
    return [centroid, subratio, flatness, attack, sustainness, pitchconf]
end

"""
    analyze_genomes(genomes) -> Vector{Vector{Float64}}

Rend `genomes` en NRT headless et renvoie un vecteur descripteur (longueur
`N_DESCRIPTORS`, normalisé ~[0,1]) par génome, dans l'ordre. Lève une erreur
si `sclang` est indisponible ou si le rendu échoue (l'appelant gère le repli).
"""
function analyze_genomes(genomes::Vector{Genome}; timeout::Int = 120)
    _sclang_available() || error("nrt: sclang introuvable")
    isempty(genomes) && return Vector{Float64}[]
    dir = mktempdir()
    try
        scd = joinpath(dir, "score.scd")
        wav = joinpath(dir, "out.wav")
        osc = joinpath(dir, "score.osc")
        write(scd, _build_nrt_script(genomes, wav, osc))
        cmd = addenv(`sclang $scd`, "QT_QPA_PLATFORM" => "minimal")
        Base.run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
        isfile(wav) || error("nrt: rendu échoué (pas de wav)")
        mat, sr = _read_wav_f32(wav)
        dt = _nrt_slot_dt()
        win = 0.01 + _NRT_WINDOW
        return [_descriptors_from_window(mat, sr, (i - 1) * dt, win)
                for i in eachindex(genomes)]
    finally
        rm(dir; recursive = true, force = true)
    end
end

# Script sclang minimal : rend UN génome en audio mono vers `wavpath`.
function _build_audio_script(g::Genome, wavpath::String, oscpath::String, dur::Float64)
    io = IOBuffer()
    println(io, "(")
    println(io, "var d;")
    println(io, "d = ", render_audio_synthdef(g, :nrtaudio), ";")
    println(io, "Score([")
    println(io, "  [0.0, ['/d_recv', d.asBytes]],")
    println(io, "  [0.0, ['/s_new', \"nrtaudio\", 1000, 0, 0]],")
    println(io, "  [", round(dur; digits = 4), ", ['/c_set', 0, 0]]")
    println(io, "]).recordNRT(")
    println(io, "  \"", oscpath, "\", \"", wavpath, "\", nil,")
    println(io, "  ", _NRT_SR, ", \"WAV\", \"float\",")
    println(io, "  ServerOptions.new.numOutputBusChannels_(1),")
    println(io, "  duration: ", round(dur; digits = 4), ",")
    println(io, "  action: { 0.exit });")
    println(io, ")")
    return String(take!(io))
end

"""
    render_genome_audio(g; pad=0.15) -> (samples::Vector{Float32}, sr::Int)

Rend l'onde sonore COMPLÈTE d'un génome en NRT headless (mono, avec son
enveloppe). Durée = attaque + sustain + release + `pad`, bornée à 6 s. Lève
une erreur si sclang est indisponible ou si le rendu échoue.
"""
function render_genome_audio(g::Genome; pad::Float64 = 0.15)
    _sclang_available() || error("nrt: sclang introuvable")
    dur = clamp(0.01 + control(g, :sustain) + control(g, :release) + pad, 0.2, 6.0)
    dir = mktempdir()
    try
        scd = joinpath(dir, "audio.scd")
        wav = joinpath(dir, "audio.wav")
        osc = joinpath(dir, "audio.osc")
        write(scd, _build_audio_script(g, wav, osc, dur))
        cmd = addenv(`sclang $scd`, "QT_QPA_PLATFORM" => "minimal")
        Base.run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
        isfile(wav) || error("nrt: rendu audio échoué (pas de wav)")
        mat, sr = _read_wav_f32(wav)
        return Float32.(vec(mat[1, :])), sr
    finally
        rm(dir; recursive = true, force = true)
    end
end
