include("data.jl")
include("scoring.jl")
include("model.jl")
include("output.jl")


function solve_server_selection(vendor_name, server_id, profile_name, scale_name; M=1)
    # 1. load profile
    profile = load_profile(profile_name)
    print_profile_info(profile_name, profile)

    # 2. fetch data
    println("\nFetching benchmark data...")
    data = get_multi_benchmark_data(vendor_name, server_id, profile, scale_name)

    # 3. build scores + normalize
    if isempty(data.candidates)
        error("No candidates found for profile '$profile_name' at scale '$scale_name'. " *
              "Try a larger max_vcpu_multiplier or a smaller scale.")
    end

    scores_matrix = build_score_matrix(data.candidates, data.config_scores, data.benchmark_ids)
    normalized = normalize_scores(scores_matrix)
    composite_scores = compute_composite_scores(normalized, data.weights)
    current_normalized = normalize_current_scores(data.current_scores, scores_matrix, data.benchmark_ids)
    current_composite = sum(current_normalized .* data.weights)

    # 4. print current server info
    print_current_server(data, current_normalized, current_composite)
    print_candidates_summary(data.candidates)

    # 5. build + solve bi-objective IP
    prices = [c.min_price_ondemand for c in data.candidates]
    server_ids = [c.server_id for c in data.candidates]
    vendor_ids = [c.vendor_id for c in data.candidates]
    display_names = [c.display_name for c in data.candidates]

    println("\nBuilding IP model...")
    model = build_model(prices, composite_scores, M)

    println("Solving...")
    optimize!(model)

    status = termination_status(model)
    println("\nSolver status: $status")
    println("Pareto solutions found: $(result_count(model))")

    # 6. extract + print result
    current = (price = data.server_info.price, score = current_composite)
    result = extract_solution(model, status, prices, composite_scores, server_ids, display_names, vendor_ids, current)
    print_solution(result, current, scores_matrix, normalized, data.benchmark_ids, data.weights)

    return result
end


result = solve_server_selection("aws", "c6i.2xlarge", "ml_inference", "small"; M=1)