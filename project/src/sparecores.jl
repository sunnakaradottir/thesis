using HTTP
using JSON3


function config_match(api_val, profile_val)
    if api_val isa Number && profile_val isa Number
        return isapprox(api_val, profile_val)
    end
    return api_val == profile_val
end


function match_score(all_benchmarks, benchmark_id, config)
    matching = filter(b -> b.benchmark_id == benchmark_id, all_benchmarks)
    if !isnothing(config) && !isempty(config)
        matching = filter(matching) do bench
            all(key -> haskey(bench.config, key) && config_match(bench.config[key], config[key]),keys(config))
        end
    end
    return isempty(matching) ? nothing : matching[1].score
end


function with_retry(f; max_retries=3)
    for attempt in 1:max_retries
        try
            return f()
        catch e
            if attempt == max_retries
                rethrow()
            elseif e isa HTTP.Exceptions.StatusError && e.status == 429
                sleep(8.0^attempt)
            else
                sleep(1.0)
            end
        end
    end
end


function get_servers_by_benchmark(benchmark_id)
    response = with_retry(() -> HTTP.get("https://keeper.sparecores.net/servers", query=["benchmark_id" => benchmark_id, "limit" => "-1"]))
    return JSON3.read(response.body)
end


function get_server_info(vendor, server_id)
    response = with_retry(() -> HTTP.get("https://keeper.sparecores.net/servers", query=["vendor" => vendor, "partial_name_or_id" => server_id]))
    data = JSON3.read(response.body)

    isempty(data) && error("Server not found: $vendor/$server_id")

    s = data[1]
    return (
        server_id      = s.server_id,
        display_name   = s.display_name,
        vcpus          = s.vcpus,
        cpu_allocation = s.cpu_allocation,
        memory         = s.memory_amount / 1024,
        price          = s.min_price_ondemand
    )
end


function get_benchmark_score(vendor, server_id, benchmark_id; benchmark_config=nothing)
    all_benchmarks = with_retry(() -> JSON3.read(HTTP.get("https://keeper.sparecores.net/server/$vendor/$server_id/benchmarks").body))
    return match_score(all_benchmarks, benchmark_id, benchmark_config)
end


function fetch_server_benchmarks(candidates, benchmark_configs; max_concurrent=5, max_retries=3)
    results   = Dict{Tuple{String,String}, Dict{String, Union{Float64,Nothing}}}()
    total     = length(candidates)
    completed = Threads.Atomic{Int}(0)

    asyncmap(candidates; ntasks=max_concurrent) do server
        vid = server.vendor_id
        sid = server.server_id

        try
            all_benchmarks = with_retry(() -> JSON3.read(HTTP.get("https://keeper.sparecores.net/server/$vid/$sid/benchmarks").body); max_retries)
            results[(vid, sid)] = Dict(bid => match_score(all_benchmarks, bid, bconfig) for (bid, bconfig) in benchmark_configs)

            n = Threads.atomic_add!(completed, 1) + 1
            n % 50 == 0 && println("  Fetched $n / $total")

        catch e
            @warn "Failed to fetch benchmarks for $vid/$sid after $max_retries attempts: $e"
        end
    end

    return results
end
