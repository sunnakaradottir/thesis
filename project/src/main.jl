include("data.jl")
include("scoring.jl")
include("model.jl")
include("output.jl")


function solve_server_selection(vendor_name, server_id, profile_name; max_vcpu_multiplier=1, M=1)
    # 1. load profile
    profile = load_profile(profile_name)
    print_profile_info(profile_name, profile)

    # 2. fetch data
    println("\nFetching benchmark data...")
    data = get_multi_benchmark_data(vendor_name, server_id, profile, max_vcpu_multiplier)

    # 3. build scores + normalize
    scores_matrix = build_score_matrix(data.candidates, data.config_scores, data.benchmark_ids)
    normalized = normalize_scores(scores_matrix)
    composite_scores = compute_composite_scores(normalized, data.weights)
    current_normalized = normalize_current_scores(data.current_scores, scores_matrix, data.benchmark_ids)
    current_composite = sum(current_normalized .* data.weights)

    # 4. print current server info
    print_current_server(data, current_normalized, current_composite)
    print_candidates_summary(data.candidates)

    # 5. build + solve MIP
    prices = [c.min_price_ondemand for c in data.candidates]
    server_ids = [c.server_id for c in data.candidates]
    vendor_ids = [c.vendor_id for c in data.candidates]
    display_names = [c.display_name for c in data.candidates]

    println("\nBuilding MIP model...")
    model = build_model(prices, composite_scores, current_composite, data.server_info.price, M)

    println("Solving...")
    optimize!(model)

    status = termination_status(model)
    println("\nSolver status: $status")

    # 6. extract + print result
    current = (price = data.server_info.price, score = current_composite)
    result = extract_solution(model, status, prices, composite_scores, server_ids, display_names, vendor_ids, current)
    print_solution(result, current, scores_matrix, normalized, data.benchmark_ids, data.weights)

    return result
end

# run
result = solve_server_selection("aws", "m6i.xlarge", "web_server"; max_vcpu_multiplier=1, M=1)
