using Printf


function print_profile_info(profile_name, profile)
    println("="^60)
    println("SERVER SELECTION")
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

function print_solution(results, current)
    """Print the Pareto-optimal solutions or infeasibility message"""
    if isnothing(results)
        println("\nNo feasible solution exists.")
        return
    end

    # sort by score descending (highest performance first)
    sorted = sort(results, by=r -> r.total_score, rev=true)

    println("\n" * "="^90)
    @printf("PARETO-OPTIMAL SOLUTIONS (%d solutions)\n", length(sorted))
    println("="^90)
    @printf("Current server: \$%.4f/hr  score: %.4f\n\n", current.price, current.score)

    @printf("%-4s  %-10s  %-24s  %-16s  %-16s\n",
        "Rank", "Provider", "Server", "Score (Δ%)", "Cost/hr (Δ%)")
    println("-"^90)

    for (rank, r) in enumerate(sorted)
        score_delta = (r.total_score - current.score) / current.score * 100
        score_str   = @sprintf("%.4f (%+.1f%%)", r.total_score, score_delta)
        cost_str    = @sprintf("\$%.4f (%+.1f%%)", r.total_cost, -r.cost_reduction)
        @printf("%-4d  %-10s  %-24s  %-16s  %-16s\n", rank, r.vendor_id, r.display_name, score_str, cost_str)
    end

    println("-"^90)
end
