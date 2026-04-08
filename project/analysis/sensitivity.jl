include("../src/sparecores.jl")
include("../src/data.jl")
include("../src/cache.jl")
include("../src/scoring.jl")
include("../src/model.jl")

using JSON
using Printf
using Distributions

"""
WEIGHT SENSITIVITY ANALYSIS (MONTE CARLO)

The benchmark weights in each profile are defined based on domain knowledge and
expert input. To validate these choices, we test how sensitive the model's output
is to weight perturbations using a Monte Carlo simulation.

The nominal recommendation is the cheapest Pareto-optimal instance that costs 
less than the current server while matching or exceeding its composite performance 
score, computed using the profile's defined weights.

  1. LOAD - fetch cached data for a profile/scale and compute the nominal
    recommendation using the profile's defined weights. → load_data()

  2. SAMPLE - generate N alternative weight sets from a Dirichlet distribution
    centered on the nominal weights. The Dirichlet guarantees weights sum to 1
    and stay positive. Concentration α controls the spread. → sample_weights()

  3. SOLVE - for each sampled weight set, recompute composite scores and re-solve
    the model. Record the cheapest Pareto solution that costs less than the current
    server and meets its performance. → top_recommendation()

  4. ANALYSE - count how often the nominal recommendation appears and report the
    cost range across all samples. → stability analysis
"""

function load_data(profile_name, scale_name)
    # loads cached data for a given profile/scale, including candidates, scores, and current server info
    test_cases = JSON.parsefile(joinpath(@__DIR__, "..", "config", "test_cases.json"))["test_cases"]
    tc         = test_cases[profile_name]
    profile    = load_profile(profile_name)
    return fetch_with_cache(tc["vendor"], tc["scales"][scale_name], profile_name, profile, scale_name)
end

function sample_weights(nominal, N; concentration=10.0)
    # creates a Dirichlet distribution with α = concentration × nominal_weights, then draws N samples from it
    d = Dirichlet(concentration .* nominal)
    return [rand(d) for _ in 1:N]
end

function top_recommendation(weights, normalized, prices, server_ids, vendor_ids, display_names, current_scores, scores_matrix, benchmark_ids, current_price)
    # for a given weight set, recompute composite scores, solve the model, and return the best recommendation that beats the current server
    composite = compute_composite_scores(normalized, weights)
    cur_score = sum(normalize_current_scores(current_scores, scores_matrix, benchmark_ids) .* weights)

    m = build_model(prices, composite)
    set_silent(m)
    optimize!(m)

    current   = (price=current_price, score=cur_score)
    solutions = extract_solution(m, termination_status(m), prices, composite, server_ids, display_names, vendor_ids, current)
    isnothing(solutions) && return nothing

    better = filter(s -> s.total_cost < current_price && s.total_score >= cur_score, solutions)
    isempty(better) && return nothing
    return argmin(s -> s.total_cost, better)
end


# ── analysis ──────────────────────────────────────────────────────────────────

const N           = 1000
const CONCENTRATE = 10.0
const PROFILE     = "web_server"
const SCALE       = "xlarge"

output_path = joinpath(@__DIR__, "..", "output/sensitivity/", "$(PROFILE)/$(SCALE).txt")
output      = open(output_path, "w")
log(s)      = (println(s); println(output, s))

data          = load_data(PROFILE, SCALE)
scores_matrix = build_score_matrix(data.candidates, data.config_scores, data.benchmark_ids)
normalized    = normalize_scores(scores_matrix)
current_norm  = normalize_current_scores(data.current_scores, scores_matrix, data.benchmark_ids)
current_score = sum(current_norm .* data.weights)
current       = (price=data.server_info.price, score=current_score)
prices        = [c.min_price_ondemand for c in data.candidates]
server_ids    = [c.server_id for c in data.candidates]
vendor_ids    = [c.vendor_id for c in data.candidates]
display_names = [c.display_name for c in data.candidates]

# nominal recommendation
composite_scores = compute_composite_scores(normalized, data.weights)
nominal_model    = build_model(prices, composite_scores)
set_silent(nominal_model)
optimize!(nominal_model)
nominal_solutions = extract_solution(nominal_model, termination_status(nominal_model), prices, composite_scores, server_ids, display_names, vendor_ids, current)
nominal_better  = filter(s -> s.total_cost < current.price && s.total_score >= current.score, nominal_solutions)
nominal_rec     = argmin(s -> s.total_cost, nominal_better)

log("Profile: $PROFILE / $SCALE")
log("Current server: $(data.server_info.display_name)  cost=\$$(round(current.price, digits=4))")
log("Nominal recommendation: $(nominal_rec.display_name)  cost=\$$(round(nominal_rec.total_cost, digits=4))  saving=$(round(nominal_rec.cost_reduction, digits=1))%")
log("")

# monte carlo
println("Running Monte Carlo ($N solves, concentration=$CONCENTRATE)...")
recommendations = []
for (i, w) in enumerate(sample_weights(data.weights, N; concentration=CONCENTRATE))
    rec = top_recommendation(w, normalized, prices, server_ids, vendor_ids, display_names, data.current_scores, scores_matrix, data.benchmark_ids, current.price)
    push!(recommendations, rec)
    i % 100 == 0 && println("  $i / $N")
end

# stability
valid  = filter(!isnothing, recommendations)
counts = Dict{String, Int}()
for r in valid; counts[r.display_name] = get(counts, r.display_name, 0) + 1; end

log("\nRecommendation frequency ($N samples, concentration=$CONCENTRATE):\n")
for (name, count) in sort(collect(counts), by=x -> -x[2])
    pct = 100 * count / N
    s = @sprintf("  %-30s  %4d / %d  (%5.1f%%)", name, count, N, pct)
    log(s)
end

rec_costs = [r.total_cost for r in valid]
log("")
log(@sprintf("Nominal stability:  %.1f%%", get(counts, nominal_rec.display_name, 0) / N * 100))
log(@sprintf("Min cost seen:      \$%.4f  (saving: %.1f%%)", minimum(rec_costs), maximum([r.cost_reduction for r in valid])))
log(@sprintf("Max cost seen:      \$%.4f  (saving: %.1f%%)", maximum(rec_costs), minimum([r.cost_reduction for r in valid])))
log(@sprintf("Guaranteed saving:  %.1f%% vs current (\$%.4f)", minimum([r.cost_reduction for r in valid]), current.price))

close(output)
println("\nResults saved to: $output_path")
