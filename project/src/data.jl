include("sparecores.jl")
using JSON

const TIER_ORDER = ["small", "medium", "large", "xlarge"]


function load_profile(profile_name)
    profiles = JSON.parsefile("config/profiles.json")
    if !haskey(profiles, profile_name)
        error("Profile '$profile_name' not found. Available: $(keys(profiles))")
    end
    return profiles[profile_name]
end


function get_scale_bounds(profile, scale_name)
    tier_idx = findfirst(==(scale_name), TIER_ORDER)
    scale    = profile["scales"][scale_name]
    return (
        min_memory_gb = scale["required_memory_gb"],
        min_vcpus     = scale["cpu_headroom"],
        max_vcpus     = tier_idx < length(TIER_ORDER) ? profile["scales"][TIER_ORDER[tier_idx + 1]]["cpu_headroom"] : typemax(Int)
    )
end


function discover_candidates(benchmark_ids, server_info, bounds)
    candidates_per_benchmark = Dict(bid => get_servers_by_benchmark(bid) for bid in benchmark_ids)
    common_keys = intersect([Set((c.vendor_id, c.server_id) for c in candidates_per_benchmark[bid]) for bid in benchmark_ids]...)
    
    return filter(candidates_per_benchmark[benchmark_ids[1]]) do server
        (server.vendor_id, server.server_id) in common_keys &&
        !isnothing(server.min_price_ondemand) && server.min_price_ondemand > 0 &&
        server.cpu_allocation == server_info.cpu_allocation &&
        server.memory_amount / 1024 >= bounds.min_memory_gb &&
        server.vcpus >= bounds.min_vcpus &&
        server.vcpus <= bounds.max_vcpus
    end
end


function fetch_current_scores(vendor, server_id, benchmark_configs)
    scores = Dict{String, Float64}()
    for (bid, bconfig) in benchmark_configs
        score = get_benchmark_score(vendor, server_id, bid; benchmark_config=bconfig)
        isnothing(score) && error("Current server $vendor/$server_id has no data for benchmark $bid with requested config")
        scores[bid] = score
    end
    return scores
end


function get_multi_benchmark_data(vendor, server_id, profile, scale_name)
    benchmarks        = profile["benchmarks"]
    weights           = [b["weight"] for b in benchmarks]
    benchmark_configs = [(b["id"], get(b, "config", nothing)) for b in benchmarks]
    benchmark_ids     = [id for (id, _) in benchmark_configs]

    server_info = get_server_info(vendor, server_id)
    bounds      = get_scale_bounds(profile, scale_name)
    candidates  = discover_candidates(benchmark_ids, server_info, bounds)

    println("Fetching config-specific scores for $(length(candidates)) candidates...")
    config_scores = fetch_server_benchmarks(candidates, benchmark_configs)

    candidates = filter(candidates) do server
        key = (server.vendor_id, server.server_id)
        haskey(config_scores, key) &&
        all(bid -> !isnothing(get(config_scores[key], bid, nothing)), benchmark_ids)
    end
    println("$(length(candidates)) candidates have scores for all requested configs")

    return (
        server_info    = server_info,
        benchmark_ids  = benchmark_ids,
        weights        = weights,
        current_scores = fetch_current_scores(vendor, server_id, benchmark_configs),
        candidates     = candidates,
        config_scores  = config_scores
    )
end


function build_score_matrix(candidates, config_scores, benchmark_ids)
    n_servers    = length(candidates)
    n_benchmarks = length(benchmark_ids)
    scores       = zeros(n_servers, n_benchmarks)

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
