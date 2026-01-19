using HTTP
using JSON3



function get_servers_by_benchmark(vendor, benchmark_id; benchmark_config=nothing, higher_is_better=true)
    # Step 1: Call /servers with benchmark filters
    url = "https://keeper.sparecores.net/servers"
    params = [
        "vendor" => vendor,
        "benchmark_id" => benchmark_id,
        "limit" => "-1"  # Get all servers
    ]

    # TODO: check if we need to filter by the exact configuration
    # if !isnothing(benchmark_config)
    #     config_json = JSON3.write(benchmark_config)
    #     push!(params, "benchmark_config" => config_json)
    # end

    response = HTTP.get(url, query=params)
    data = JSON3.read(response.body)

    return data
end


function get_server_info(vendor, server_id)
    # server info and pricing
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
    params = ["benchmark_id" => benchmark_id]

    response = HTTP.get(url, query=params)
    data = JSON3.read(response.body)

    if length(data) == 0
        error("No benchmark data found for $vendor/$server_id with benchmark $benchmark_id")
    end

    # If config specified, find exact match
    if !isnothing(benchmark_config)
        matching = filter(data) do bench
            # Compare each field in the config
            config = bench.config
            all(key -> haskey(config, key) && config[key] == benchmark_config[key],
                keys(benchmark_config))
        end

        if length(matching) == 0
            println("Available configs for $benchmark_id:")
            for b in data[1:min(5, length(data))]  # Show first 5
                println("  ", b.config, " -> score: ", b.score)
            end
            error("No benchmark found with exact config match: $benchmark_config")
        end

        return matching[1].score
    end

    # No config specified, return first result
    return data[1].score
end


# server info, pricing and benchmark score
function get_current_server_performance(vendor, server_id, benchmark_id; benchmark_config=nothing)
    server_info = get_server_info(vendor, server_id)
    score = get_benchmark_score(vendor, server_id, benchmark_id; benchmark_config=benchmark_config)

    return (
        server_id = server_info.server_id,
        display_name = server_info.display_name,
        vcpus = server_info.vcpus,
        cpu_allocation = server_info.cpu_allocation,
        memory = server_info.memory,
        score = score,
        price = server_info.price,
        price_per_performance = score > 0 ? server_info.price / score : 0.0
    )
end