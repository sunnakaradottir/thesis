include("sparecores.jl")
using JuMP
using GLPK


# hardcoded current server (user input)
vendor_name = "aws"
server_id = "c6a.16xlarge"
benchmark_id = "openssl"
benchmark_config = Dict(
    "algo" => "sha256",
    "block_size" => 8192,
    "framework_version" => "3.3.0"
)

function better_servers_by_benchmark_score(vendor, benchmark_id, current_score, current_allocation; benchmark_config=nothing, higher_is_better=true)
    # call a function from sparecores.jl to get a list of servers
    servers = get_servers_by_benchmark(vendor, benchmark_id; benchmark_config=benchmark_config)
    println("DEBUG: Total servers returned from API: ", length(servers))

    # Check first few servers
    if length(servers) > 0
        println("DEBUG: First server selected_benchmark_score: ", servers[8].selected_benchmark_score)
        println("DEBUG: First server price: ", servers[8].min_price_ondemand)
    end
    # Count servers with valid scores
    valid_score_count = count(servers) do s
        !isnothing(s.selected_benchmark_score) && s.selected_benchmark_score != 0
    end
    println("DEBUG: Servers with valid benchmark scores: ", valid_score_count)

    # filter out servers with worse performing benchmark scores than current server
    better_servers = filter(servers) do server
        # valid benchmark score?
        score = server.selected_benchmark_score
        if isnothing(score) || score == 0
            return false
        end

        # filter out worse scores
        if higher_is_better # set in params for openssl for now - TODO: lookup benchmark metadata when user input is dynamic
            return score > current_score
        else
            return score < current_score
        end
    end

    println("DEBUG: Current score to beat: ", current_score)
    println("DEBUG: Higher is better: ", higher_is_better)
    println("DEBUG: Servers with better scores: ", length(better_servers))

    # filter servers to have the same CPU allocation as the current server
    better_servers = filter(better_servers) do server
        return server.cpu_allocation == current_allocation
    end

    println("DEBUG: Servers with better scores and same CPU allocation: ", length(better_servers))

    return [
        (
            server_id = s.server_id,
            display_name = s.display_name,
            score = s.selected_benchmark_score,
            price = s.min_price_ondemand,
            vcpus = s.vcpus,
            memory = s.memory_amount
        )
        for s in better_servers
    ]
end

function greedy_server_lookup(vendor_name, server_id, _benchmark_id; benchmark_config=nothing)
    # fetch current server benchmark score and price
    result = get_current_server_performance(vendor_name, server_id, benchmark_id; benchmark_config=benchmark_config)
    println(result)

    # look for servers with better benchmark scores
    better_servers = better_servers_by_benchmark_score(
        vendor_name, benchmark_id, result.score, result.cpu_allocation;
        benchmark_config=benchmark_config, higher_is_better=true
    )

    println("Found $(length(better_servers)) better servers")

    # only keep servers with better price per performance
    current_price_per_perf = result.price_per_performance

    println("\nCurrent price_per_perf: $current_price_per_perf")
    
    cost_effective = filter(better_servers) do s
        s.price / s.score < current_price_per_perf
    end

    println("Found $(length(cost_effective)) cost-effective servers")

    # pick the best recommendation
    sorted = sort(cost_effective, by = s -> s.price) # cheapest first
    
    if length(sorted) > 0
        println("\nTop $(min(5, length(sorted))) recommendations:")
        for (i, s) in enumerate(sorted[1:min(5, length(sorted))])
            println("\n$i. $(s.display_name)")
            println("   vCPUs: $(s.vcpus), Memory: $(s.memory / 1024) GB")
            println("   Score: $(s.score) (vs $(result.score))")
            println("   Price: \$$(s.price)/hr (vs \$$(result.price))")

            cost_reduction = (current_price_per_perf - s.price/s.score) / current_price_per_perf
            println("   Cost reduction: $(round(cost_reduction * 100, digits=2))%")
        end

        best = sorted[1]
    else
        println("No better cost-effective servers found")
    end

    # (maybe add later) TODO: repeat for cross-provider comparison
    return 0
end

greedy_server_lookup(vendor_name, server_id, benchmark_id; benchmark_config=benchmark_config)