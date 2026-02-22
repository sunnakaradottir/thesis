using HTTP
using JSON3


function config_match(api_val, profile_val)
    """Compare config values, handling type mismatches (e.g. API returns 4.0, profile has 4)"""
    if api_val isa Number && profile_val isa Number
        return isapprox(api_val, profile_val)
    end
    return api_val == profile_val
end


function get_servers_by_benchmark(benchmark_id)
    """
        Fetch servers with benchmark scores for a given benchmark_id
    """
    url = "https://keeper.sparecores.net/servers"
    params = [
        "benchmark_id" => benchmark_id,
        "limit" => "-1"  # all servers
    ]

    response = HTTP.get(url, query=params)
    data = JSON3.read(response.body)

    return data
end


function get_server_info(vendor, server_id)
    """
        Fetch hardware specs and pricing for a given server
    """
    url = "https://keeper.sparecores.net/servers"
    params = [
        "vendor" => vendor,
        "partial_name_or_id" => server_id
    ]

    response = HTTP.get(url, query=params)
    data = JSON3.read(response.body)

    if length(data) == 0
        error("Server not found: $vendor/$server_id")
    end

    server = data[1]

    return (
        server_id = server.server_id,
        display_name = server.display_name,
        vcpus = server.vcpus,
        cpu_allocation = server.cpu_allocation,
        memory = server.memory_amount / 1024, # MB to GB
        price = server.min_price_ondemand
    )
end


function get_benchmark_score(vendor, server_id, benchmark_id; benchmark_config=nothing)
    url = "https://keeper.sparecores.net/server/$vendor/$server_id/benchmarks"

    response = HTTP.get(url)
    data = JSON3.read(response.body)

    # filter by benchmark_id (API doesn't filter properly)
    data = filter(b -> b.benchmark_id == benchmark_id, data)

    if length(data) == 0
        return nothing
    end

    # If config specified, find exact match
    if !isnothing(benchmark_config)
        matching = filter(data) do bench
            config = bench.config
            all(key -> haskey(config, key) && config_match(config[key], benchmark_config[key]),
                keys(benchmark_config))
        end

        if length(matching) == 0
            return nothing
        end

        return (score = matching[1].score, config = matching[1].config)
    end

    # No config specified, return first result
    return (score = data[1].score, config = data[1].config)
end


function fetch_server_benchmarks(candidates, benchmark_configs; max_concurrent=10, max_retries=3)
    """
        Fetch config-specific benchmark scores for all candidate servers in parallel.
        Respects API rate limit (300 req/min) with concurrency control and retry with backoff.

        # Arguments
        - `candidates`: Vector of server objects (from /servers endpoint)
        - `benchmark_configs`: Vector of (benchmark_id, config_dict_or_nothing) tuples
        - `max_concurrent`: Max parallel requests (default 10, conservative for rate limits)
        - `max_retries`: Max retries on 429/transient errors

        # Returns
        - Dict mapping (vendor_id, server_id) => Dict(benchmark_id => score or nothing)
    """
    results = Dict{Tuple{String,String}, Dict{String, Union{Float64,Nothing}}}()
    total = length(candidates)
    completed = Threads.Atomic{Int}(0)

    asyncmap(candidates; ntasks=max_concurrent) do server
        vid = server.vendor_id
        sid = server.server_id

        for attempt in 1:max_retries
            try
                url = "https://keeper.sparecores.net/server/$vid/$sid/benchmarks"
                response = HTTP.get(url)
                all_benchmarks = JSON3.read(response.body)

                server_scores = Dict{String, Union{Float64,Nothing}}()

                for (bid, bconfig) in benchmark_configs
                    matching = filter(b -> b.benchmark_id == bid, all_benchmarks)

                    if !isnothing(bconfig) && !isempty(bconfig)
                        matching = filter(matching) do bench
                            config = bench.config
                            all(key -> haskey(config, key) && config_match(config[key], bconfig[key]),
                                keys(bconfig))
                        end
                    end

                    server_scores[bid] = isempty(matching) ? nothing : matching[1].score
                end

                results[(vid, sid)] = server_scores

                n = Threads.atomic_add!(completed, 1) + 1
                if n % 50 == 0
                    println("  Fetched $n / $total")
                end
                break  # success, exit retry loop

            catch e
                if e isa HTTP.Exceptions.StatusError && e.status == 429
                    wait_time = 2.0^attempt  # exponential backoff: 2s, 4s, 8s
                    sleep(wait_time)
                elseif attempt == max_retries
                    @warn "Failed to fetch benchmarks for $vid/$sid after $max_retries attempts: $e"
                else
                    sleep(1.0)
                end
            end
        end
    end

    return results
end


function get_vendors()
    url = "https://keeper.sparecores.net/vendors"
    response = HTTP.get(url)
    data = JSON3.read(response.body)
    return [v.vendor_id for v in data]
end


# server info, pricing and benchmark score
function get_current_server_performance(vendor, server_id, benchmark_id; benchmark_config=nothing)
    server_info = get_server_info(vendor, server_id)
    benchmark = get_benchmark_score(vendor, server_id, benchmark_id; benchmark_config=benchmark_config)

    if isnothing(benchmark)
        error("No benchmark data found for $vendor/$server_id with benchmark $benchmark_id")
    end

    return (
        server_id = server_info.server_id,
        display_name = server_info.display_name,
        vcpus = server_info.vcpus,
        cpu_allocation = server_info.cpu_allocation,
        memory = server_info.memory,
        score = benchmark.score,
        config = benchmark.config,
        price = server_info.price,
        price_per_performance = benchmark.score > 0 ? server_info.price / benchmark.score : 0.0
    )
end