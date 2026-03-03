using JuMP
import HiGHS
import MultiObjectiveAlgorithms as MOA

const OBJ_SCALE = 10_000

function build_model(prices, scores, M)
    """
        Bi-objective IP: maximize composite performance score, minimize hourly cost.
        Uses EpsilonConstraint (MOA) to enumerate the full Pareto front.
        EpsilonConstraint steps through objective values one integer unit at a time, so we scale our continuous normalized floats to integers before building the model. 
        Results are read back using the original values.
    """
    n = length(prices)
    int_scores = round.(Int, scores .* OBJ_SCALE)
    int_prices = round.(Int, prices .* OBJ_SCALE)

    model = Model(() -> MOA.Optimizer(HiGHS.Optimizer))
    set_attribute(model, MOA.Algorithm(), MOA.EpsilonConstraint())

    @variable(model, y[1:n], Bin) # 1 if server type i is selected
    @variable(model, x[1:n] >= 0, Int) # number of instances of type i

    @objective(model, Min, [
        -sum(int_scores[i] * x[i] for i in 1:n), # maximize score (negated for minimization)
         sum(int_prices[i] * x[i] for i in 1:n)  # minimize cost
    ])

    @constraint(model, sum(y[i] for i in 1:n) == 1) # select exactly one type
    @constraint(model, [i in 1:n], x[i] <= M * y[i]) # link count to selection
    @constraint(model, [i in 1:n], x[i] >= y[i]) # at least one if selected

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
    x = model[:x]

    for r in 1:result_count(model)
        for i in eachindex(server_ids)
            if value(y[i]; result=r) > 0.5
                n_inst = round(Int, value(x[i]; result=r))
                push!(results, (
                    vendor_id      = vendor_ids[i],
                    server_id      = server_ids[i],
                    display_name   = display_names[i],
                    instances      = n_inst,
                    total_score    = scores[i] * n_inst,
                    total_cost     = prices[i] * n_inst,
                    cost_reduction = (current.price - prices[i] * n_inst) / current.price * 100,
                    selected_index = i,
                ))
                break
            end
        end
    end

    return isempty(results) ? nothing : results
end
