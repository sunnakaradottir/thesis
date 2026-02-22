using Printf


function print_profile_info(profile_name, profile)
    println("="^60)
    println("MIP SERVER SELECTION (Multi-Benchmark)")
    println("="^60)
    println("\nProfile: $profile_name")
    println("  $(profile["description"])")
    println("  Benchmarks: $(join([b["id"] for b in profile["benchmarks"]], ", "))")
end

function print_current_server(data, current_normalized, current_composite)
    println("\nCurrent server: $(data.server_info.display_name)")
    println("  Price: \$$(data.server_info.price)/hr")
    println("  CPU allocation: $(data.server_info.cpu_allocation)")

    # benchmark score breakdown
    println("\nCurrent server benchmark scores:")
    print_benchmark_table(data.current_scores, current_normalized, data.benchmark_ids, data.weights)
    println("  Weighted total: $(round(current_composite, digits=4))")
end

function print_candidates_summary(candidates)
    println("\nFound $(length(candidates)) candidates with all benchmarks")
    if length(candidates) == 0
        return
    end

    # count per provider
    vendor_counts = Dict{String, Int}()
    for c in candidates
        vendor_counts[c.vendor_id] = get(vendor_counts, c.vendor_id, 0) + 1
    end
    for (v, count) in sort(collect(vendor_counts), by=x->x[2], rev=true)
        println("  $v: $count")
    end
end

function print_benchmark_table(raw_scores, normalized, benchmark_ids, weights)
    """Print a formatted benchmark score table where raw_scores can be a Dict or Vector"""
    println("  " * "-"^68)
    println("  Benchmark                   Score  Weight%   Normalized   Weighted")
    println("  " * "-"^68)

    for (b, bid) in enumerate(benchmark_ids)
        raw = raw_scores isa Dict ? raw_scores[bid] : raw_scores[b]
        raw_str = raw >= 1e6 ? @sprintf("%.2e", raw) : @sprintf("%.2f", raw)
        weight_pct = round(weights[b] * 100, digits=1)
        norm = round(normalized[b], digits=4)
        weighted = round(normalized[b] * weights[b], digits=4)
        bid_display = length(bid) > 20 ? bid[1:17] * "..." : bid
        println("  $(rpad(bid_display, 20)) $(lpad(raw_str, 12))  $(lpad(string(weight_pct), 5))%   $(lpad(string(norm), 6))   $(lpad(string(weighted), 6))")
    end

    println("  " * "-"^68)
end

function print_solution(result, current, scores_matrix, normalized, benchmark_ids, weights)
    """Print the optimization result or infeasibility message"""
    if isnothing(result)
        println("\nNo feasible solution exists.")
        println("This means no server configuration can beat the current setup.")
        return
    end

    println("\n" * "="^60)
    println("OPTIMAL SOLUTION FOUND")
    println("="^60)

    println("\nRecommendation:")
    println("  Provider: $(result.vendor_id)")
    println("  Server: $(result.display_name) ($(result.server_id))")
    println("  Instances: $(result.instances)")
    println("  Total composite score: $(round(result.total_score, digits=4)) (vs $(round(current.score, digits=4)) current)")
    println("  Total cost: \$$(round(result.total_cost, digits=4))/hr (vs \$$(current.price) current)")
    println("  Cost reduction: $(round(result.cost_reduction, digits=2))%")

    # per-benchmark comparison for the selected server
    i = result.selected_index
    println("\n  Per-benchmark comparison (suggested server):")
    print_benchmark_table(scores_matrix[i, :], normalized[i, :], benchmark_ids, weights)
    println("  Weighted total: $(round(result.total_score / result.instances, digits=4))")
end
