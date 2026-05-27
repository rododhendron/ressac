# ── Tempo & transport ──
# :cps 0.5            set tempo (cycles/sec). 0.5 = 120 BPM @ 4 beats/cycle
# :bpm  /  :tap-tempo tap-set tempo: 2+ Space hits then Enter
# :hush  /  :panic    soft / nuclear stop
# :pause              freeze render to mouse-select & copy

# ── Slots ──
# :mute d1            mute @d1 (toggle with `m` in normal mode)
# :unmute d1
# :solo d1            mute everything else
# E (normal mode)     eval every @dN block in the buffer

# ── Browse / library ──
# :browse             samples + synths + instruments picker
# :lib                synth library (built-in + your saved ones)
# :sccode             search sccode.org
# :sccode <id>        import one entry
# :doc <name>         description + usage examples
# :wiki  /  :guide    in-app docs

# ── Snippets / starters ──
# :snip               this picker
# :starter house      genre starter pack (house/dnb/techno/…)

# ── Sessions ──
# :save  <name>       save patterns buffer
# :load  <name>       reload it (then press E to eval)
# :sessions           list saved files

# ── Tap / piano ──
# :tap                tap a rhythm; Enter auto-detects period + cps
# :tap-strict         no loop detection (single-bar quantize)
# :piano <synth>      keyboard plays chromatic semitones
# :piano-rec          same + records into a @dN line

# ── Scope / visual ──
# :scope amp|wave|spectrum|xy|goni|spectrogram|peak|pitch|onset|hist|corr
# :theme <name>       switch theme  (:theme alone lists)
# :safety on|off      limiter + DC block + 10 Hz HPF
