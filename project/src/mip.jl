profiles = JSON.parsefile("config/profiles.json")
include("sparecores.jl")
using JuMP
import HiGHS

# current server (user input)
vendor_name = "aws"
server_id = "c6a.16xlarge"
benchmark_id = "openssl"
benchmark_config = Dict(
    "algo" => "sha256",
    "block_size" => 8192,
    "framework_version" => "3.3.0"
)

# params
M = 50  # max instances


function get_candidate_servers(vendor, benchmark_id, current_allocation; benchmark_config=nothing)
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


function print_matrix_data(model)
    data = lp_matrix_data(model)

end

function solve_server_selection(vendor_name, server_id, benchmark_id; benchmark_config=nothing, higher_is_better=true)
    println("="^60)
    println("MIP SERVER SELECTION")
    println("="^60)

    # current server info
    current = get_current_server_performance(vendor_name, server_id, benchmark_id; benchmark_config=benchmark_config)

    println("\nCurrent server: $(current.display_name)")
    println("  Score: $(current.score)")
    println("  Price: \$$(current.price)/hr")
    println("  CPU allocation: $(current.cpu_allocation)")

    # candidate servers
    println("\nFetching candidate servers...")
    candidates = get_candidate_servers(vendor_name, benchmark_id, current.cpu_allocation; benchmark_config=benchmark_config)
    println("Found $(length(candidates)) candidates with same CPU allocation")

    if length(candidates) == 0
        println("No candidate servers found!")
        return nothing
    end

    # extract parameters
    prices = [c.min_price_ondemand for c in candidates]
    scores = [c.selected_benchmark_score for c in candidates]
    server_ids = [c.server_id for c in candidates]
    display_names = [c.display_name for c in candidates]

    # build and solve
    println("\nBuilding MIP model...")
    model = build_model(prices, scores, current.score, current.price)

    println("Solving...")
    optimize!(model)

    status = termination_status(model)
    println("\nSolver status: $status")

    return extract_solution(model, status, prices, scores, server_ids, display_names, current)
end


# run the optimization
result = solve_server_selection(vendor_name, server_id, benchmark_id; benchmark_config=benchmark_config)
