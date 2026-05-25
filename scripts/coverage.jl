# scripts/coverage.jl
#
# Run with `just coverage` (or `julia --project=. scripts/coverage.jl`)
# AFTER `julia --project=. -e 'using Pkg; Pkg.test(coverage=true)'`. Parses
# the .cov files Julia drops next to each src/*.jl and prints per-file +
# total coverage.
#
# .cov format: every src line gets a left-padded prefix:
#   `        N <line>`  → executed N times (covered)
#   `        - <line>`  → not executable (comment, blank, struct decl)
#   `        0 <line>`  → executable but never ran (uncovered)
# Lines with no recognised prefix are skipped — happens when an `include`d
# file isn't reinstrumented (a Julia 1.12 / PkgImages artifact rather than
# a real gap).

using Printf

results = Tuple{String,Int,Int,Float64}[]
for f in readdir("src"; join = true)
    endswith(f, ".cov") || continue
    src_name = replace(basename(f), r"\.\d+\.cov$" => "")
    covered = total = 0
    for line in eachline(f)
        m = match(r"^\s+(\d+)\s", line)
        m === nothing && continue
        total += 1
        parse(Int, m.captures[1]) > 0 && (covered += 1)
    end
    total > 0 && push!(results, (src_name, covered, total, 100.0 * covered / total))
end
sort!(results, by = r -> r[4])

println("PER-FILE COVERAGE (worst → best):")
println("-" ^ 70)
for (name, c, t, pct) in results
    marker = pct < 50 ? " ⚠️ " : pct < 80 ? " ·" : "   "
    @printf "%-32s %5d / %-5d  %5.1f%%%s\n" name c t pct marker
end
total_c = sum(r[2] for r in results)
total_t = sum(r[3] for r in results)
println("-" ^ 70)
@printf "%-32s %5d / %-5d  %5.1f%%\n" "TOTAL" total_c total_t (100.0 * total_c / total_t)
println()
@printf "  Files <50%%: %d   Files <80%%: %d   Files 100%%: %d\n" count(r -> r[4] < 50, results) count(r -> r[4] < 80, results) count(r -> r[4] >= 99.9, results)
