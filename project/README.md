# Cloud Resource Optimization

An Integer Linear Programming (ILP) model that finds cheaper cloud server configurations across providers while maintaining equivalent performance. Uses real benchmark data from [Spare Cores](https://sparecores.com).

## How it works

1. You specify your current server and a workload profile
2. The model fetches benchmark scores for ~800+ candidate servers across AWS, Azure, GCP, Alicloud, OVH, and Hetzner
3. Scores are normalized and combined using profile-defined weights
4. An ILP solver finds the cheapest server that matches or exceeds your current performance

## Quick start

```bash
# install dependencies
julia -e 'import Pkg; Pkg.add(["HTTP", "JSON", "JSON3", "JuMP", "HiGHS", "Printf"])'

# run the optimizer
julia project/src/main.jl
```

Edit `src/main.jl` to change the input:

```julia
result = solve_server_selection(
    "aws",            # current provider
    "m6i.xlarge",     # current server
    "web_server";     # workload profile
    max_vcpu_multiplier=1,  # only consider servers with <= current vCPUs
    M=1                     # max instances of the recommended server
)
```

## Workload profiles

Defined in `config/profiles.json`. Each profile specifies which benchmarks matter for that workload and how much.

| Profile | Benchmarks | Use case |
|---------|-----------|----------|
| `web_server` | static_web, redis, openssl, geekbench | SaaS, APIs, web apps |
| `compute_heavy` | passmark CPU, compression, geekbench | Data pipelines, batch jobs |
| `cache_intensive` | redis, memory, database ops, geekbench | In-memory stores, analytics |
| `ml_inference` | floating point, SIMD, single-thread, geekbench | Model serving, NLP, CV |
| `ci_cd_build` | clang, compression, single-thread, file compression | Build pipelines, CI/CD |

Each benchmark includes a specific configuration (e.g., redis with pipeline=4 for web servers) to ensure realistic comparisons.

## Project structure

```
project/
  config/
    profiles.json     # workload profiles with benchmarks, weights, and configs
  src/
    main.jl           # entry point and orchestration
    data.jl           # data fetching, filtering, score matrix construction
    scoring.jl        # min-max normalization and composite scoring
    model.jl          # MIP formulation and solution extraction
    output.jl         # result formatting and display
    sparecores.jl     # Spare Cores API client
```

## Data source

All benchmark and pricing data comes from the [Spare Cores API](https://sparecores.com). Benchmarks are run on real cloud instances with standardized configurations.
