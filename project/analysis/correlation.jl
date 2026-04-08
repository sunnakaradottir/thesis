include("../src/sparecores.jl")
include("../src/data.jl")
include("../src/cache.jl")
include("../src/scoring.jl")

using JSON
using Printf
using Statistics

"""
BENCHMARK CORRELATION ANALYSIS
────────────────────────────────────────────────────────────────────────────────
To justify the benchmark selection for each workload profile, we need to show
that each benchmark is contributing independently — i.e. no two benchmarks are
just measuring the same underlying hardware capability.

We do this with a Spearman rank correlation analysis:

1. LOAD     For each vCPU tier defined in the profile, fetch benchmark scores
            for all candidate instances with exactly that vCPU count. Grouping 
            by exact vCPU count to ensure that within a group score differences 
            reflect architecture rather than "more cores = higher score".
            → load_candidates_for_vcpu()

2. RANK     For each benchmark, rank all candidates from best to worst.
            This puts all benchmarks on the same 1-to-N scale, regardless of
            their original units (RPS, bytes/sec, score, etc.).
            → rank_scores()

3. CORR     Calculate pairwise Spearman correlation between benchmark columns.
            p ≈ 1  →  the two benchmarks rank instances the same way -> redundant
            p ≈ 0  →  the rankings are unrelated -> each captures something different
            → spearman_corr()

Low-to-moderate correlations across a profile's benchmarks is evidence that each
benchmark earns its place in the composite score by contributing information the
others do not.
────────────────────────────────────────────────────────────────────────────────
"""

function load_candidates_for_vcpu(profile_name, vcpus)
    test_cases = JSON.parsefile(joinpath(@__DIR__, "..", "config", "test_cases.json"))["test_cases"]
    tc         = test_cases[profile_name]

    profile           = load_profile(profile_name)
    benchmark_configs = [(b["id"], get(b, "config", nothing)) for b in profile["benchmarks"]]
    benchmark_ids     = [id for (id, _) in benchmark_configs]

    # use the medium scale server only to get cpu_allocation type (dedicated vs shared)
    server_info = get_server_info(tc["vendor"], tc["scales"]["medium"])
    bounds      = (min_memory_gb=0, min_vcpus=vcpus, max_vcpus=vcpus)
    candidates  = discover_candidates(benchmark_ids, server_info, bounds)

    println("  vCPU=$vcpus: fetching scores for $(length(candidates)) candidates...")
    config_scores = fetch_server_benchmarks(candidates, benchmark_configs)

    candidates = filter(candidates) do server
        key = (server.vendor_id, server.server_id)
        haskey(config_scores, key) &&
        all(bid -> !isnothing(get(config_scores[key], bid, nothing)), benchmark_ids)
    end
    println("  vCPU=$vcpus: $(length(candidates)) candidates with complete data")

    matrix = build_score_matrix(candidates, config_scores, benchmark_ids)
    return matrix, benchmark_ids, candidates
end

rank_scores(matrix)   = mapslices(col -> invperm(sortperm(-col)), matrix, dims=1)
spearman_corr(ranked) = cor(ranked)

function print_corr(corr, benchmark_ids, label, out=stdout)
    line(s) = (println(s); println(out, s))
    short = [split(b, ":")[end] for b in benchmark_ids]
    line("\n── $label ──\n")
    line(rpad("", 30) * join(rpad.(short, 16)))
    line("-" ^ (30 + 16 * length(short)))
    for (i, s) in enumerate(short)
        line(rpad(s, 30) * join(rpad(@sprintf("%.3f", corr[i,j]), 16) for j in eachindex(short)))
    end
end


# ── analysis ──────────────────────────────────────────────────────────────────

const MIN_GROUP_SIZE = 20
const PROFILE        = "ci_cd_build"

output_path = joinpath(@__DIR__, "..", "output/correlation/", "$(PROFILE).txt")
output      = open(output_path, "w")
log(s)      = (println(s); println(output, s))

profile    = load_profile(PROFILE)
vcpu_tiers = sort(unique([s["cpu_headroom"] for s in values(profile["scales"])]))

log("\nCorrelation analysis: $PROFILE")
log("vCPU tiers from profile: $vcpu_tiers\n")

for v in vcpu_tiers
    matrix, benchmark_ids, candidates = load_candidates_for_vcpu(PROFILE, v)
    length(candidates) < MIN_GROUP_SIZE && (log("  skipping vCPU=$v (n < $MIN_GROUP_SIZE)\n"); continue)
    print_corr(spearman_corr(rank_scores(matrix)), benchmark_ids, "vCPU = $v  (n=$(length(candidates)))", output)
end

close(output)
println("\nResults saved to: $output_path")
