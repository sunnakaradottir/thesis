using HTTP
using JSON3

# hardcode user input
vendor = "aws"
server = "c6a.16xlarge"
benchmark_id = "openssl"
benchmark_config = Dict(
    "algo" => "sha256",
    "block_size" => 8192,
    "framework_version" => "3.4.0"
)
# make get req
url = "https://keeper.sparecores.net/server/$vendor/$server/benchmarks?benchmark_config=$benchmark_config"
response = HTTP.get(url)
# read res
data = JSON3.read(response.body)