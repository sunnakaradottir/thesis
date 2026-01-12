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

# fetch current server benchmark score and price
result = get_current_server_performance(vendor_name, server_id, benchmark_id; benchmark_config=benchmark_config)
println(result)

# look for servers with better benchmark scores


# rank by price-per-performance and only keep better options - pick cheapest one of these


# calculate savings




# (maybe add later) repeat for cross-provider comparison