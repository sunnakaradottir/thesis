function minmax_range(col)
    return minimum(col), maximum(col)
end

function normalize_scores(scores)
    n_servers, n_benchmarks = size(scores)
    normalized = zeros(n_servers, n_benchmarks)

    for b in 1:n_benchmarks
        col = scores[:, b]
        min_val, max_val = minmax_range(col)
        if max_val > min_val
            normalized[:, b] = (col .- min_val) ./ (max_val - min_val)
        else
            normalized[:, b] .= 0.5
        end
    end

    return normalized
end

function compute_composite_scores(normalized, weights)
    return normalized * weights
end

function normalize_current_scores(current_scores, scores, benchmark_ids)
    normalized = zeros(length(benchmark_ids))

    for (b, bid) in enumerate(benchmark_ids)
        min_val, max_val = minmax_range(scores[:, b])
        normalized[b] = max_val > min_val ? (current_scores[bid] - min_val) / (max_val - min_val) : 0.5
    end

    return normalized
end
