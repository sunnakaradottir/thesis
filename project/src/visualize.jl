include("sparecores.jl")
include("data.jl")
include("cache.jl")
include("scoring.jl")
include("model.jl")

using Plots
using JSON


# run pipeline to get results for plotting
function solve_for_plot(data)
    isempty(data.candidates) && return nothing

    scores_matrix    = build_score_matrix(data.candidates, data.config_scores, data.benchmark_ids)
    normalized       = normalize_scores(scores_matrix)
    composite_scores = compute_composite_scores(normalized, data.weights)
    current_norm     = normalize_current_scores(data.current_scores, scores_matrix, data.benchmark_ids)
    current_score    = sum(current_norm .* data.weights)

    prices        = [c.min_price_ondemand for c in data.candidates]
    server_ids    = [c.server_id for c in data.candidates]
    vendor_ids    = [c.vendor_id for c in data.candidates]
    display_names = [c.display_name for c in data.candidates]

    m = build_model(prices, composite_scores)
    set_silent(m)
    optimize!(m)

    current   = (price = data.server_info.price, score = current_score)
    solutions = extract_solution(m, termination_status(m), prices, composite_scores, server_ids, display_names, vendor_ids, current)

    return (
        prices           = prices,
        scores           = composite_scores,
        server_ids       = server_ids,
        vendor_ids       = vendor_ids,
        display_names    = display_names,
        solutions        = solutions,
        current_price    = data.server_info.price,
        current_score    = current_score,
        current_server   = data.server_info,
    )
end


# plot a single profile/scale with the Pareto front highlighted
function plot_pareto(vendor, server_id, profile_name, scale_name; save_path=nothing, force_refresh=false)
    profile = load_profile(profile_name)
    data    = fetch_with_cache(vendor, server_id, profile_name, profile, scale_name; force_refresh)
    result  = solve_for_plot(data)

    isnothing(result) && error("No result for $vendor/$server_id $profile_name/$scale_name")
    isnothing(result.solutions) && error("No Pareto solutions found")

    pareto_indices = Set(s.selected_index for s in result.solutions)

    # separate candidates, Pareto and non-Pareto
    non_pareto_mask = [i ∉ pareto_indices for i in eachindex(result.prices)]
    pareto_mask     = [i ∈ pareto_indices for i in eachindex(result.prices)]

    p = scatter(
        result.prices[non_pareto_mask],
        result.scores[non_pareto_mask];
        label        = "Candidate instances ($(sum(non_pareto_mask)))",
        color        = :lightsteelblue,
        alpha        = 0.5,
        markersize   = 4,
        markerstroke = stroke(0),
        xlabel       = "Hourly cost (USD)",
        ylabel       = "Composite performance score",
        title        = "$(titlecase(replace(profile_name, "_" => " "))) · $(scale_name) scale\nCost vs. performance trade-off",
        legend       = :bottomright,
        size         = (800, 550),
        dpi          = 150,
        grid         = true,
        gridalpha    = 0.3,
        framestyle   = :box,
    )

    # connecting line for Pareto front — order from sort by price
    pareto_sorted = sort(result.solutions, by = s -> s.total_cost)
    pareto_prices = [s.total_cost  for s in pareto_sorted]
    pareto_scores = [s.total_score for s in pareto_sorted]

    plot!(p, pareto_prices, pareto_scores;
        label     = nothing,
        color     = :steelblue,
        linewidth = 1.5,
        alpha     = 0.6,
        linestyle = :dash,
    )

    scatter!(p, pareto_prices, pareto_scores;
        label      = "Pareto-optimal ($(length(result.solutions)))",
        color      = :steelblue,
        markersize = 7,
        markershape = :diamond,
        markerstroke = stroke(1, :white),
    )

    # label Pareto points with instance names
    for s in pareto_sorted
        label_text = s.display_name
        annotate!(p, s.total_cost, s.total_score,
            text(label_text, :steelblue, :left, 7, rotation=0))
    end

    # label current server as red star
    scatter!(p, [result.current_price], [result.current_score];
        label        = "Current: $(result.current_server.display_name)",
        color        = :crimson,
        markersize   = 10,
        markershape  = :star5,
        markerstroke = stroke(1, :white),
    )

    annotate!(p, result.current_price, result.current_score,
        text("  $(result.current_server.display_name)", :crimson, :left, 8))

    if !isnothing(save_path)
        savefig(p, save_path)
        println("Saved: $save_path")
    end

    return p
end


# plot all profiles and scales defined in test_cases.json, with error handling and retries
function plot_all_profiles(; output_dir=joinpath(@__DIR__, "..", "plots"), force_refresh=false)
    mkpath(output_dir)
    test_cases = JSON.parsefile(joinpath(@__DIR__, "..", "config", "test_cases.json"))["test_cases"]

    plots = []
    for (profile_name, tc) in test_cases
        for (scale_name, server_id) in tc["scales"]
            println("\nPlotting $profile_name / $scale_name ($server_id)")
            safe_name = replace(profile_name, "_" => "-")
            path = joinpath(output_dir, "$(safe_name)_$(scale_name).png")
            try
                p = plot_pareto(tc["vendor"], server_id, profile_name, scale_name, save_path=path, force_refresh)
                push!(plots, (profile_name=profile_name, scale_name=scale_name, plot=p))
            catch e
                @warn "Failed $profile_name/$scale_name: $e"
            end
        end
    end
    return plots
end



# create path to upload the plots to
output_dir = joinpath(@__DIR__, "..", "plots")
mkpath(output_dir)

# get test cases
test_cases = JSON.parsefile(joinpath(@__DIR__, "..", "config", "test_cases.json"))["test_cases"]

# plot each profile/medium combination test case and save to output directory
for (profile_name, tc) in test_cases
    scale_name = "medium"
    server_id  = tc["scales"][scale_name]
    println("\nPlotting $profile_name / $scale_name  ($server_id)")
    safe_name = replace(profile_name, "_" => "-")
    path = joinpath(output_dir, "$(safe_name)_$(scale_name).png")
    try
        plot_pareto(tc["vendor"], server_id, profile_name, scale_name; save_path=path)
    catch e
        @warn "Skipped $profile_name/$scale_name: $e"
    end
end

println("\nDone. Plots saved to: $output_dir")
# maybe add in more scales later
