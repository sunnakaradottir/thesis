using JuMP
import HiGHS
import MultiObjectiveAlgorithms as MOA

const OBJ_SCALE = 10_000

function build_model(prices, scores)
    """
        Bi-objective IP: maximize composite performance score, minimize hourly cost.
        Uses EpsilonConstraint (MOA) to enumerate the full Pareto front.
        EpsilonConstraint steps through objective values one integer unit at a time, so we
        scale continuous normalized floats to integers before building the model.
        Results are read back using the original values.
    """
    n = length(prices)
    int_scores = round.(Int, scores .* OBJ_SCALE)
    int_prices = round.(Int, prices .* OBJ_SCALE)

    model = Model(() -> MOA.Optimizer(HiGHS.Optimizer))
    set_attribute(model, MOA.Algorithm(), MOA.EpsilonConstraint())

    @variable(model, y[1:n], Bin)  # 1 if server i is selected

    @objective(model, Min, [
        -sum(int_scores[i] * y[i] for i in 1:n),  # maximize score (negated)
         sum(int_prices[i] * y[i] for i in 1:n)   # minimize cost
    ])

    @constraint(model, sum(y) == 1)  # select exactly one server

    return model
end

function extract_solution(model, status, prices, scores, server_ids, display_names, vendor_ids, current)
    """
        Extract all Pareto-optimal solutions from a solved model.
        Returns a vector of result named tuples, or nothing if infeasible.
    """
    if status != MOI.OPTIMAL
        return nothing
    end

    results = []
    y = model[:y]

    for r in 1:result_count(model)
        for i in eachindex(server_ids)
            if value(y[i]; result=r) > 0.5
                push!(results, (
                    vendor_id      = vendor_ids[i],
                    server_id      = server_ids[i],
                    display_name   = display_names[i],
                    total_score    = scores[i],
                    total_cost     = prices[i],
                    cost_reduction = (current.price - prices[i]) / current.price * 100,
                    selected_index = i,
                ))
                break
            end
        end
    end

    return isempty(results) ? nothing : results
end
