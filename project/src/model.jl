using JuMP
import HiGHS


function build_model(prices, scores, current_score, current_price, M)
    """
        Build the MIP model: minimize cost while matching or exceeding current performance
        epsilon based constraint for performance scores
    """
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

function extract_solution(model, status, prices, scores, server_ids, display_names, vendor_ids, current)
    """
        Extract the selected server from a solved MIP model, or nothing if infeasible
    """
    if status != MOI.OPTIMAL
        return nothing
    end

    total_cost = objective_value(model)
    y = model[:y]
    x = model[:x]

    for i in eachindex(server_ids)
        if value(y[i]) > 0.5
            num_instances = round(Int, value(x[i]))
            return (
                vendor_id = vendor_ids[i],
                server_id = server_ids[i],
                display_name = display_names[i],
                instances = num_instances,
                total_score = scores[i] * num_instances,
                total_cost = total_cost,
                cost_reduction = (current.price - total_cost) / current.price * 100,
                selected_index = i
            )
        end
    end

    return nothing
end
