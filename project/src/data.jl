include("sparecores.jl")
using JSON


function load_profile(profile_name)
    profiles = JSON.parsefile("config/profiles.json")
    if !haskey(profiles, profile_name)
        error("Profile '$profile_name' not found. Available: $(keys(profiles))")
    end
    return profiles[profile_name]
end

function get_multi_benchmark_data(vendor, server_id, profile, max_vcpu_multiplier)
    """
        Fetch benchmark data for all candidates and the current server.
        Discovers candidates via the /servers endpoint, filters them, then
        fetches config-specific scores for each via the per-server endpoint.
    """
    benchmarks = profile["benchmarks"]
    weights = [b["weight"] for b in benchmarks]
    benchmark_ids = [b["id"] for b in benchmarks]
    benchmark_configs = [(b["id"], get(b, "config", nothing)) for b in benchmarks]

    # get current server info (once)
    server_info = get_server_info(vendor, server_id)

    # candidate discovery: use /servers endpoint for each benchmark to find which servers have scores
    candidates_per_benchmark = Dict{String, Vector}()
    for bench in benchmarks
        bid = bench["id"]
        candidates_per_benchmark[bid] = get_servers_by_benchmark(bid)
    end

    # find intersection of servers that have scores for all benchmarks
    all_keys = [Set((c.vendor_id, c.server_id) for c in candidates_per_benchmark[bid]) for bid in benchmark_ids]
    common_keys = intersect(all_keys...)

    # filter to common servers with valid price, same CPU allocation, and within vCPU range
    max_vcpus = server_info.vcpus * max_vcpu_multiplier
    first_benchmark_candidates = candidates_per_benchmark[benchmark_ids[1]]
    candidates = filter(first_benchmark_candidates) do server
        (server.vendor_id, server.server_id) in common_keys &&
        !isnothing(server.min_price_ondemand) && server.min_price_ondemand > 0 &&
        server.cpu_allocation == server_info.cpu_allocation &&
        server.vcpus <= max_vcpus
    end

    # fetch config-specific scores for all candidates (parallel API calls)
    println("Fetching config-specific scores for $(length(candidates)) candidates...")
    config_scores = fetch_server_benchmarks(candidates, benchmark_configs)

    # filter out candidates that don't have scores for all benchmarks with the requested config
    candidates = filter(candidates) do server
        key = (server.vendor_id, server.server_id)
        haskey(config_scores, key) &&
        all(bid -> !isnothing(get(config_scores[key], bid, nothing)), benchmark_ids)
    end
    println("$(length(candidates)) candidates have scores for all requested configs")

    # get current server's config-specific scores (single API call via get_benchmark_score)
    current_scores = Dict{String, Float64}()
    for (bid, bconfig) in benchmark_configs
        result = get_benchmark_score(vendor, server_id, bid; benchmark_config=bconfig)
        if isnothing(result)
            error("Current server $vendor/$server_id has no data for benchmark $bid with requested config")
        end
        current_scores[bid] = result.score
    end

    return (
        server_info = server_info,
        benchmark_ids = benchmark_ids,
        weights = weights,
        current_scores = current_scores,
        candidates = candidates,
        config_scores = config_scores
    )
end

function build_score_matrix(candidates, config_scores, benchmark_ids)
    """
        Build a (n_servers x n_benchmarks) matrix from config-specific scores
    """
    n_servers = length(candidates)
    n_benchmarks = length(benchmark_ids)
    scores = zeros(n_servers, n_benchmarks)

    for (i, c) in enumerate(candidates)
        key = (c.vendor_id, c.server_id)
        server_scores = config_scores[key]
        for (b, bid) in enumerate(benchmark_ids)
            score = server_scores[bid]
            if !isnothing(score)
                scores[i, b] = score
            end
        end
    end

    return scores
end
