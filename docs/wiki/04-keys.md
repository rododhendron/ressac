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
:e                 eval every @dN
:e1e5e15           eval just d1 / d5 / d15
m                  mute/unmute slot under cursor
K                  preview sample/synth under cursor
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
:guide             general guide
:dsl               synth-DSL cookbook
:wiki              this wiki
:synth-guide       synth-pane workflow
:lib               synth library picker
:snip              snippets picker
:browse            sample / instrument / synth browser
:sccode  / :sc     sccode.org browser
```

## Live input modes

```
:tap [sample]      tap a rhythm with Space → quantized @dN p"..."
:piano [synth]     letter keys → notes; [/] octave
:piano-rec         same + records into @dN :synth |> n(p"...")
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
