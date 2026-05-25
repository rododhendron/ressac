# Adding your own samples

Ressac comes with the full TidalCycles sample collection (bd, sn, hh, cp,
amen, …) plus a starter set of instruments and synths. When you want to
use your OWN recordings — a vocal chop, a found-sound texture, a kick
you sampled from a record — there are two paths.

## The fast path: `:import`

```
:import /path/to/your-sample.wav
:import /path/to/your-sample.wav as kickheavy
```

This:
1. Copies the file into `plugins/user-samples/<name>/<name>_0.wav`
2. Registers it as a sample bank named `<name>` (or the basename of the
   file if you don't give `as ...`)
3. Tells the running SuperCollider to load it — no restart needed

Use it immediately:
```julia
@d1 p"kickheavy ~ kickheavy ~"
```

Re-running `:import` with the same name on a different file **adds a
variant** rather than overwriting. So:
```
:import kick1.wav as mykick     # mykick:0
:import kick2.wav as mykick     # mykick:1  (now you have 2)
:import kick3.wav as mykick     # mykick:2
```

In patterns you then pick variants with `n(...)`:
```julia
@d1 :mykick |> n(p"0 1 2 1")    # rotate through the three
@d1 p"mykick"                    # random variant
@d1 p"mykick:1"                  # variant #1 specifically
```

## The plugin path

For a curated bank of dozens of samples organised by category, write a
plugin descriptor instead of importing one file at a time.

Create `plugins/<plugin-name>/plugin.toml`:

```toml
name = "my-pack"
version = "0.1.0"
description = "my found-sound collection"

[samples]
# Either a list of root folders Ressac will scan, each subdir becoming
# a sample bank named after the folder:
roots = ["/absolute/path/to/your/sample/folders/"]

# OR explicit per-bank entries:
[[samples.banks]]
name = "vibegtr"
path = "/absolute/path/to/guitar-textures/"

[[samples.banks]]
name = "vinylhiss"
path = "/absolute/path/to/vinyl-hiss/"
```

Restart Ressac (or use `:reload-config` if it's already running and
you only changed the TOML — for new folders you need to relaunch SC).
The names `vibegtr` and `vinylhiss` are now in `:browse`, in
autocomplete, and in patterns.

## Where things live

```
plugins/
  dirt/                       # the vendored Dirt-Samples (bd, sn, hh, …)
  superdirt-synths/           # SC synthdefs (super808, supersaw, …)
  starter-instruments/        # preset chains like :kicklourd, :sub
  user-synths/                # your :w-saved synthdefs (.scd or .jl)
  user-samples/               # what :import populates
    mykick/
      mykick_0.wav
      mykick_1.wav
      mykick_2.wav
    voxchop/
      voxchop_0.wav
```

The directory layout matches what Dirt itself uses, so anything you put
in `plugins/user-samples/<name>/` works — `:import` is just sugar over
the same convention.

## File formats

Anything SuperCollider can read: WAV, AIFF, FLAC. Stereo or mono fine.
For best playback, normalise to ~-3 dBFS so SuperDirt's per-event gain
has headroom.

## Tips

- **Naming**: stick to lowercase, no spaces, ASCII. Bad chars are
  silently replaced with `_` by `:import` but the result might surprise
  you. `:import kick_heavy.wav as kickheavy` is cleaner than letting
  Ressac derive the name.
- **Folder vs file**: a bank is a folder; each `.wav` inside is a
  variant. Even a single sample lives in a folder.
- **Discovery**: after import, `:browse` shows it in the "samples"
  category. Tab-completion in `:s name` and `p"name"` finds it too.
- **Removal**: just delete the folder under `plugins/user-samples/`
  and restart. There's no `:unimport` yet.
