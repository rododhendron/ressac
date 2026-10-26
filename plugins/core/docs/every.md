+++
examples = ["@d1 p\"bd hh sn hh\" |> every(4, rev)  # reverse every 4th cycle", "@d1 p\"bd hh sn hh\" |> every(3, fast(2))"]
name = "every"
short = "every(N, f, p) — applies the transformation f every N cycles. e.g. every(4, fast(2))."
tags = []
+++

# every

every(N, f, p) — applies the transformation f every N cycles. e.g. every(4, fast(2)).

Does something every Nth cycle: `every(4, rev)` reverses the fourth cycle, `every(3, fast(2))` doubles the third. The first cycle counts as cycle 0, so with `every(4, …)` it happens on cycles 0, 4, 8. For "the last of four" use `lastOf`.

See also: whenmod, sometimes, lastOf
