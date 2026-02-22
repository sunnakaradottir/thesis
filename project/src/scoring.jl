function normalize_scores(scores)
    """Min-max normalize each benchmark column to [0,1] range."""
    n_servers, n_benchmarks = size(scores)
    normalized = zeros(n_servers, n_benchmarks)

    for b in 1:n_benchmarks
        col = scores[:, b]
        min_val = minimum(col)
        max_val = maximum(col)

        if max_val > min_val
            normalized[:, b] = (col .- min_val) ./ (max_val - min_val)
        else
            # all same score, set to neutral
            normalized[:, b] .= 0.5
        end
    end

    return normalized
end

function compute_composite_scores(normalized, weights)
    """Weighted sum across benchmarks for each server."""
    return normalized * weights
end

function normalize_current_scores(current_scores, scores, benchmark_ids)
    """Normalize the current server's scores using the same min-max range as the candidates."""
    n_benchmarks = length(benchmark_ids)
    normalized = zeros(n_benchmarks)

    for (b, bid) in enumerate(benchmark_ids)
        col = scores[:, b]
        min_val = minimum(col)
        max_val = maximum(col)

        if max_val > min_val
            normalized[b] = (current_scores[bid] - min_val) / (max_val - min_val)
        else
            normalized[b] = 0.5
        end
    end

    return normalized
end
