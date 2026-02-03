include("sparecores.jl")
using JuMP
using JSON
import HiGHS


function load_profile(profile_name)
    profiles = JSON.parsefile("config/profiles.json")
    if !haskey(profiles, profile_name)
        error("Profile '$profile_name' not found. Available: $(keys(profiles))")
    end
    return profiles[profile_name]
end

function get_multi_benchmark_data(vendor, server_id, profile)
    benchmarks = profile["benchmarks"]
    weights = [b["weight"] for b in benchmarks]
    benchmark_ids = [b["id"] for b in benchmarks]

    # get current server info (once)
    server_info = get_server_info(vendor, server_id)

    # for each benchmark: get current score/config, then get candidates
    current_scores = Dict{String, Float64}()
    current_configs = Dict{String, Any}()
    candidates_per_benchmark = Dict{String, Vector}()

    for bench in benchmarks
        bid = bench["id"]

        # current server's score and config for this benchmark
        result = get_benchmark_score(vendor, server_id, bid)
        if isnothing(result)
            error("Current server has no data for benchmark: $bid")
        end
        current_scores[bid] = result.score
        current_configs[bid] = result.config

        # candidates for this benchmark (using current server's config)
        candidates_per_benchmark[bid] = get_servers_by_benchmark(vendor, bid)
    end

    # find intersection: servers that have scores for ALL benchmarks
    all_server_ids = [Set(c.server_id for c in candidates_per_benchmark[bid]) for bid in benchmark_ids]
    common_ids = intersect(all_server_ids...)

    # filter to common servers with valid price and same CPU allocation
    first_benchmark_candidates = candidates_per_benchmark[benchmark_ids[1]]
    candidates = filter(first_benchmark_candidates) do server
        server.server_id in common_ids &&
        !isnothing(server.min_price_ondemand) && server.min_price_ondemand > 0 &&
        server.cpu_allocation == server_info.cpu_allocation
    end

    return (
        server_info = server_info,
        benchmark_ids = benchmark_ids,
        weights = weights,
        current_scores = current_scores,
        current_configs = current_configs,
        candidates = candidates,
        candidates_per_benchmark = candidates_per_benchmark
    )
end

function build_score_matrix(candidates, candidates_per_benchmark, benchmark_ids)
    """
        Build score matrix for candidates and benchmarks.

        # Arguments
        - `candidates`: Vector of candidate server objects
        - `candidates_per_benchmark`: Dict of benchmark_id => Vector of server objects
        - `benchmark_ids`: Vector of benchmark IDs

        # Returns
        - Matrix of size (n_servers × n_benchmarks)
    """
    n_servers = length(candidates)
    n_benchmarks = length(benchmark_ids)

    # map server_id to index for quick lookup
    server_id_to_idx = Dict(c.server_id => i for (i, c) in enumerate(candidates))

    # build matrix: rows = servers, cols = benchmarks
    scores = zeros(n_servers, n_benchmarks)

    for (b, bid) in enumerate(benchmark_ids)
        for server in candidates_per_benchmark[bid]
            if haskey(server_id_to_idx, server.server_id)
                i = server_id_to_idx[server.server_id]
                score = server.selected_benchmark_score
                if !isnothing(score)
                    scores[i, b] = score
                end
            end
        end
    end

    return scores
end


function normalize_scores(scores)
    """
        Min-max normalize each benchmark column to [0,1] range.

        # Arguments
        - `scores`: Matrix of size (n_servers × n_benchmarks)

        # Returns
        - Normalized matrix with same dimensions
    """
    n_servers, n_benchmarks = size(scores)
    normalized = zeros(n_servers, n_benchmarks)

    for b in 1:n_benchmarks
        col = scores[:, b]
        min_val = minimum(col)
        max_val = maximum(col)

        if max_val > min_val
            normalized[:, b] = (col .- min_val) ./ (max_val - min_val)
        else
            # all same score → set to 0.5 (neutral)
            normalized[:, b] .= 0.5
        end
    end

    return normalized
end


function compute_composite_scores(normalized, weights)
    # weighted sum across benchmarks for each server
    return normalized * weights
end

# TODO: ask Rasmus about preference here on percentile vs min-max
function normalize_current_scores(current_scores, scores, benchmark_ids)
    """
        Normalize current server's scores using min-max from candidates (not percentiles but rather distribution if that makes sense).

        Example:
        If current server has score 150 for benchmark A, and candidates have scores ranging from 100 to 200,
        then normalized score = (150 - 100) / (200 - 100) = 0.5
        
        Whereas percentile would consider how many candidates are below 150 so that if most candidates are above 150,
        the percentile would be lower.


        # Arguments
        - `current_scores`: Dict of benchmark_id => score for current server
        - `scores`: Matrix of candidate scores (n_servers × n_benchmarks)
        - `benchmark_ids`: Vector of benchmark IDs corresponding to columns in `scores`

        # Returns
        - Vector of normalized scores for current server
    """
    # init zeroed vector to store the percentile score for each benchmark
    n_benchmarks = length(benchmark_ids)
    normalized = zeros(n_benchmarks)
    
    for (b, bid) in enumerate(benchmark_ids)
        # candidate scores for this benchmark, min and max
        col = scores[:, b]
        min_val = minimum(col)
        max_val = maximum(col)

        if max_val > min_val
            # set normalized score where current score falls in min-max range
            normalized[b] = (current_scores[bid] - min_val) / (max_val - min_val)
        else
            # all same score among candidates - set to 0.5 (neutral)
            normalized[b] = 0.5
        end
    end

    return normalized
end


# current server (user input)
vendor_name = "aws"
server_id = "c6a.16xlarge"
profile_name = "web_server"

# params
M = 50  # max instances


function get_candidate_servers(vendor, benchmark_id, current_allocation; benchmark_config=nothing)
    """
        Get candidate servers for a given benchmark and CPU allocation.

        # Arguments
        - `vendor`: Vendor name (e.g., "aws")
        - `benchmark_id`: Benchmark identifier (e.g., "sysbench_cpu")
        - `current_allocation`: CPU allocation of current server (e.g., "dedicated")

        # Keyword Arguments
        - `benchmark_config`: Optional benchmark configuration to filter by

        # Returns
        - Vector of candidate server objects
    """
    servers = get_servers_by_benchmark(vendor, benchmark_id; benchmark_config=benchmark_config)

    # filter for valid benchmark scores and same CPU allocation
    candidates = filter(servers) do server
        score = server.selected_benchmark_score
        price = server.min_price_ondemand

        # must have valid score and price
        if isnothing(score) || score == 0 || isnothing(price) || price == 0
            return false
        end

        # must have same CPU allocation
        return server.cpu_allocation == current_allocation
    end

    return candidates
end


function build_model(prices, scores, current_score, current_price)
    n_servers = length(prices)
    model = Model(HiGHS.Optimizer)

    # decision variables
    @variable(model, y[1:n_servers], Bin) # select server type i
    @variable(model, x[1:n_servers] >= 0, Int) # number of instances

    # objective: minimize total cost
    @objective(model, Min, sum(prices[i] * x[i] for i in 1:n_servers))

    # select exactly one server type
    @constraint(model, sum(y[i] for i in 1:n_servers) == 1)
    # link x to y (can only use instances of selected type)
    @constraint(model, [i in 1:n_servers], x[i] <= M * y[i])
    # at least one instance if selected
    @constraint(model, [i in 1:n_servers], x[i] >= y[i])
    # performance requirement (meet or exceed current)
    @constraint(model, sum(scores[i] * x[i] for i in 1:n_servers) >= current_score)
    # must be cheaper than current
    @constraint(model, sum(prices[i] * x[i] for i in 1:n_servers) <= current_price)

    return model
end


function extract_solution(model, status, prices, scores, server_ids, display_names, current)
    if status == MOI.OPTIMAL
        println("\n" * "="^60)
        println("OPTIMAL SOLUTION FOUND")
        println("="^60)

        total_cost = objective_value(model)
        y = model[:y]
        x = model[:x]

        for i in eachindex(server_ids)
            if value(y[i]) > 0.5
                num_instances = round(Int, value(x[i]))
                selected_score = scores[i] * num_instances
                cost_reduction = (current.price - total_cost) / current.price * 100

                println("\nRecommendation:")
                println("  Server: $(display_names[i]) ($(server_ids[i]))")
                println("  Instances: $num_instances")
                println("  Total score: $selected_score (vs $(current.score) current)")
                println("  Total cost: \$$(round(total_cost, digits=4))/hr (vs \$$(current.price) current)")
                println("  Cost reduction: $(round(cost_reduction, digits=2))%")

                return (
                    server_id = server_ids[i],
                    display_name = display_names[i],
                    instances = num_instances,
                    total_score = selected_score,
                    total_cost = total_cost,
                    cost_reduction = cost_reduction
                )
            end
        end

    elseif status == MOI.INFEASIBLE
        println("\nNo feasible solution exists.")
        println("This means no server configuration can beat the current setup.")
        return nothing

    else
        println("\nSolver did not find optimal solution.")
        return nothing
    end
end


function solve_server_selection(vendor_name, server_id, profile_name)
    println("="^60)
    println("MIP SERVER SELECTION (Multi-Benchmark)")
    println("="^60)

    # load profile
    profile = load_profile(profile_name)
    println("\nProfile: $profile_name")
    println("  $(profile["description"])")
    println("  Benchmarks: $(join([b["id"] for b in profile["benchmarks"]], ", "))")

    # fetch multi-benchmark data
    println("\nFetching benchmark data...")
    data = get_multi_benchmark_data(vendor_name, server_id, profile)

    println("\nCurrent server: $(data.server_info.display_name)")
    println("  Price: \$$(data.server_info.price)/hr")
    println("  CPU allocation: $(data.server_info.cpu_allocation)")
    for bid in data.benchmark_ids
        println("  $bid score: $(data.current_scores[bid])")
    end

    println("\nFound $(length(data.candidates)) candidates with all benchmarks")
    if length(data.candidates) == 0
        return nothing
    end

    # build candidate score matrix and normalize
    scores_matrix = build_score_matrix(data.candidates, data.candidates_per_benchmark, data.benchmark_ids)
    normalized = normalize_scores(scores_matrix)
    composite_scores = compute_composite_scores(normalized, data.weights)

    # normalize current server scores
    current_normalized = normalize_current_scores(data.current_scores, scores_matrix, data.benchmark_ids)
    current_composite = sum(current_normalized .* data.weights)

    println("\nCurrent server composite score: $(round(current_composite, digits=4))")

    # extract parameters
    prices = [c.min_price_ondemand for c in data.candidates]
    server_ids = [c.server_id for c in data.candidates]
    display_names = [c.display_name for c in data.candidates]

    # build and solve
    println("\nBuilding MIP model...")
    model = build_model(prices, composite_scores, current_composite, data.server_info.price)

    println("Solving...")
    optimize!(model)

    status = termination_status(model)
    println("\nSolver status: $status")

    current = (price = data.server_info.price, score = current_composite)
    return extract_solution(model, status, prices, composite_scores, server_ids, display_names, current)
end


# run the optimization
result = solve_server_selection(vendor_name, server_id, profile_name)
