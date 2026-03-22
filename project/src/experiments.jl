
include("sparecores.jl")
include("data.jl")
include("cache.jl")
include("scoring.jl")
include("model.jl")

using Printf

const ALL_PROFILES = ["web_server", "compute_heavy", "cache_intensive", "ml_inference", "ci_cd_build"]
const ALL_SCALES   = ["small", "medium", "large", "xlarge"]

# runs existing solution multiple times and compares results
function run_single(vendor, server_id, profile_name, scale_name; force_refresh=false)
    profile = load_profile(profile_name)
    data = fetch_with_cache(vendor, server_id, profile_name, profile, scale_name; force_refresh)

    isempty(data.candidates) && return nothing

    scores_matrix    = build_score_matrix(data.candidates, data.config_scores, data.benchmark_ids)
    normalized       = normalize_scores(scores_matrix)
    composite_scores = compute_composite_scores(normalized, data.weights)
    current_norm     = normalize_current_scores(data.current_scores, scores_matrix, data.benchmark_ids)
    current_score    = sum(current_norm .* data.weights)

    prices        = [c.min_price_ondemand for c in data.candidates]
    server_ids    = [c.server_id for c in data.candidates]
    vendor_ids    = [c.vendor_id for c in data.candidates]
    display_names = [c.display_name for c in data.candidates]

    m = build_model(prices, composite_scores)
    set_silent(m)
    optimize!(m)

    current   = (price = data.server_info.price, score = current_score)
    solutions = extract_solution(m, termination_status(m), prices, composite_scores, server_ids, display_names, vendor_ids, current)

    return (
        profile_name  = profile_name,
        scale_name    = scale_name,
        n_candidates   = length(data.candidates),
        current_score   = current_score,
        current_price   = data.server_info.price,
        solutions       = solutions,
    )
end


# profile comparison - compare different profiles for the same server and scale
function run_profile_comparison(vendor, server_id, scale_name; force_refresh=false)
    println("\n" * "="^90)
    println("PROFILE COMPARISON for $vendor/$server_id  scale: $scale_name")
    println("="^90)

    results = []
    for profile_name in ALL_PROFILES
        print("  $profile_name... ")
        r = run_single(vendor, server_id, profile_name, scale_name; force_refresh)
        if isnothing(r)
            println("no candidates")
        else
            n = isnothing(r.solutions) ? 0 : length(r.solutions)
            println("$(r.n_candidates) candidates, $n Pareto solutions")
            push!(results, r)
        end
    end

    print_profile_comparison(results)
    return results
end

function print_profile_comparison(results)
    isempty(results) && return

    println()
    @printf("%-20s  %-11s  %-7s  %-30s  %-8s  %-30s  %-8s\n", "Profile", "Candidates", "Pareto", "Highest Score", "Score", "Cheapest", "Price")
    println("-"^118)

    for r in results
        if isnothing(r.solutions)
            @printf("%-20s  %-11d  %-7s\n", r.profile_name, r.n_candidates, "—")
            continue
        end

        best  = argmax(s -> s.total_score, r.solutions)
        cheap = argmin(s -> s.total_cost,  r.solutions)
        n     = length(r.solutions)

        @printf("%-20s  %-11d  %-7d  %-30s  %6.4f    %-30s  %6.4f\n", r.profile_name, r.n_candidates, n, "$(best.vendor_id)/$(best.display_name)",  best.total_score, "$(cheap.vendor_id)/$(cheap.display_name)", cheap.total_cost)
    end
    println("-"^118)
end


# scale comparison - compare different scales for the same server and profile
function run_scale_comparison(vendor, server_id, profile_name; force_refresh=false)
    println("\n" * "="^90)
    println("SCALE COMPARISON for $vendor/$server_id  profile: $profile_name")
    println("="^90)

    results = []
    for scale_name in ALL_SCALES
        print("  $scale_name... ")
        r = run_single(vendor, server_id, profile_name, scale_name; force_refresh)
        if isnothing(r)
            println("no candidates")
        else
            n = isnothing(r.solutions) ? 0 : length(r.solutions)
            println("$(r.n_candidates) candidates, $n Pareto solutions")
            push!(results, r)
        end
    end

    print_scale_comparison(results)
    return results
end

function print_scale_comparison(results)
    isempty(results) && return

    println()
    @printf("%-10s  %-11s  %-7s  %-30s  %-8s  %-30s  %-8s\n", "Scale", "Candidates", "Pareto", "Highest Score", "Score", "Cheapest", "Price")
    println("-"^112)

    for r in results
        if isnothing(r.solutions)
            @printf("%-10s  %-11d  %-7s\n", r.scale_name, r.n_candidates, "—")
            continue
        end

        best  = argmax(s -> s.total_score, r.solutions)
        cheap = argmin(s -> s.total_cost,  r.solutions)
        n     = length(r.solutions)

        @printf("%-10s  %-11d  %-7d  %-30s  %6.4f    %-30s  %6.4f\n", r.scale_name, r.n_candidates, n, "$(best.vendor_id)/$(best.display_name)",  best.total_score, "$(cheap.vendor_id)/$(cheap.display_name)", cheap.total_cost)
    end
    println("-"^112)
end

run_profile_comparison("aws", "c6i.2xlarge", "small")
run_scale_comparison("aws", "c6i.2xlarge", "ml_inference")