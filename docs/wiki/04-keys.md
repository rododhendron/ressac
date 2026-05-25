# Keys cheat sheet

## Modes

```
i / a / o / O      enter insert mode (vim-style)
Esc                back to normal
:                  ex-command mode
```

## Patterns pane (normal)

```
hjkl / arrows      move cursor
0 / $              line start / end
w / b / e          word forward / back / end
gg / G             buffer start / end
e                  eval current line (or block joined by |>)
E                  eval every @dN
:e                 same as E
m                  mute/unmute slot under cursor (frees voices too)
K                  preview sample/synth under cursor
?                  open the guide modal (one-keystroke help)
v                  visual char-wise selection (hjkl extends, dyc act)
V                  visual line-wise selection (j/k extends, dyc act)
.                  repeat last edit (insert OR normal-mode dd/x/p)
```

## Pattern editor — context-aware (cursor inside `"…"`)

```
>                  zoom pattern x2 (insert ~ between tokens)
<                  zoom pattern ÷2 (keep every other token)
H / L              shift token at cursor left / right
X                  silence the token at cursor (replace with ~)
1 / 2 / 3 / 4 / 6 / 8   subdivide token: 1=plain, 2=*2, 4=*4, etc.
```

## Space-leader (snippet expansion / picker)

```
Space d g l h p f s r n e m c S v   text snippet expansion
Space E R J                          Euclidean snippets
Space b L I w ?                      open browser / lib / snip / wiki / guide
Tab / S-Tab                          navigate placeholders in expanded snippet
Esc                                  exit placeholder mode (stay in insert)
```

## Synth pane (normal)

```
t / T / Space      fire the synth (hold = accelerated repeat)
:w                 save under current name
:w <name>          save-as (DSL → .jl, SC → .scd)
:close             drop the active tab
:back              hide the synth pane
```

## Nudge numbers (cursor on a numeric literal)

```
+ / -              ±1   (or ±1.0 for floats)
* / /              ±10  (or ±0.1 for floats)
hold for scrub
```

Mouse wheel anywhere over a number does the same — no need to move
the cursor.

## Scope

```
S                  cycle scope type (off → amp → wave → … → corr → off)
:scope <type>      pick directly. types:
                   off amp wave spectrum xy goni spectrogram
                   peak pitch onset hist corr
+/-/=              wave Y-zoom (when scope is :wave)
>/</=              wave X-zoom (when scope is :wave)
```

## Vim editing in any pane

```
dd / yy / cc       delete / yank / change line
cw / dw / yw       change / delete / yank word
c$ / d$ / y$       same to end of line
c0 / d0 / y0       same to start of line
x                  delete char under cursor
r<char>            replace char under cursor
.                  repeat last edit (vim)
```

## Lifecycle / safety

```
!                  PANIC (kill all sound + clear scheduler)
,                  hush (clear scheduler, let tails finish)
:safety on|off     master limiter + DC block + 10Hz HPF
.                  vim repeat
```

## Modals (j/k scroll, q close)

```
:guide             general guide (also: ?)
:tutorial          5-card interactive tour for new users
:dsl               synth-DSL cookbook
:wiki              this wiki
:synth-guide       synth-pane workflow
:lib               synth library picker (built-in + user-saved)
:snip              snippets picker (Tab cycles categories)
:browse            sample / instrument / synth browser (Tab cycles filter)
:mixer / :mix      per-slot meter + gain edit (+/-/*//) + mute/solo
:sccode  / :sc     sccode.org browser
```

## Live input modes

```
:tap [sample]      tap a rhythm with Space → quantized @dN "..."
                   (loop detection + cps auto-set + auto-eval)
:tap-strict        same but single-bar quantize, no loop detection
:bpm / :tap-tempo  tap-set cps from inter-tap intervals
:piano [synth]     letter keys → notes; [/] octave
:piano-rec         same + records into @dN :synth |> n("...")
```

## Files & sessions

```
:save <name>       save patterns buffer to sessions/<name>.txt
:load <name>       reload (then press E to eval all blocks)
:sessions          list saved sessions
:import path.wav   copy a .wav into plugins/user-samples/ and register
:import p.wav as N rename on import
```

## Recording

```
:rec start [name]  record SC master to ./recordings/<name>.wav
:rec stop          close the WAV
:rec               toggle
:export [seconds]  auto-export the current synth (default 4s)
```

## Display / utility

```
:theme <name>      switch theme (kokaku / cyberpunk / outrun / …)
:reload-config     reread ./ressac.toml
:pause             freeze render so you can shift-drag-select + copy
:copylogs          send log buffer to wl-copy / xclip
:keydebug          log every keypress to the pane
```
