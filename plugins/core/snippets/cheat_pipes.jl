# ── Pipe-chain anatomy ──
# Pattern  |>  control  |>  control  …
#   :bd                    a bare symbol = pure(:bd) (lifted)
#   "bd ~ sn ~"           mini-notation literal
#   gate(:bd, "1 0 1 1")  named pattern
#
# Then each |> wraps the pattern in a ControlMap layer:
#
#   @d1 "bd hh sn hh" |> gain(0.8) |> lpf(1500) |> pan(0.3)
#
# @dN macro is the final stage — installs the pattern at the slot.
# Composition rules (most useful):
#   gain * gain → ×          lpf min lpf → strictest
#   pan / n / room / delay → overwrite (last wins)
