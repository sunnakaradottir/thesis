# cloud-optimizer

> Find cheaper cloud servers without sacrificing performance.

Given your current server and workload type, `cloud-optimizer` searches across AWS, Azure, GCP, OVH, Hetzner, and Alicloud to find every Pareto-optimal alternative — servers that are either cheaper, faster, or both. It uses real benchmark data from [Spare Cores](https://sparecores.com) and a bi-objective MIP solver to enumerate the full cost/performance trade-off frontier.

```
PARETO-OPTIMAL SOLUTIONS (4 solutions)
Current server: aws/c6i.2xlarge  $0.3332/hr  score: 0.5049

Rank  Provider    Server           Score (Δ%)       Cost/hr (Δ%)
-----------------------------------------------------------------
1     aws         m8azn.xlarge     0.9983 (+97.7%)  $0.4129 (+23.9%)
2     aws         c8a.xlarge       0.8864 (+75.6%)  $0.2155 (-35.3%)
3     azure       F4ams_v6         0.6488 (+28.5%)  $0.0449 (-86.5%)
4     azure       F2ams_v6         0.3733 (-26.1%)  $0.0225 (-93.2%)
```

## Features

- **Multi-provider** — searches 800+ servers across 6 cloud providers simultaneously
- **Workload-aware** — five built-in profiles weight benchmarks to match your actual workload
- **Pareto front** — surfaces every non-dominated cost/performance trade-off, not just the single cheapest option
- **Scale-aware filtering** — enforces minimum memory and vCPU floors based on your declared workload size
- **Real benchmark data** — all scores come from standardized runs on live cloud instances via the Spare Cores API

## Installation

```bash
julia -e 'import Pkg; Pkg.add(["HTTP", "JSON", "JSON3", "JuMP", "HiGHS", "MultiObjectiveAlgorithms"])'
```

## Usage

Edit the last line of `src/main.jl`:

```julia
result = solve_server_selection(
    "aws",          # your current provider
    "c6i.2xlarge",  # your current server
    "ml_inference", # workload profile (see below)
    "small"         # workload scale: small | medium | large | xlarge
)
```

Then run:

```bash
julia src/main.jl
```

## Workload profiles

Each profile defines which benchmarks matter and how much, based on what the workload actually stresses at runtime.

| Profile | Key benchmarks | Typical use case |
|---|---|---|
| `web_server` | HTTP throughput, Redis cache, TLS encryption, general compute | SaaS, APIs, web apps |
| `compute_heavy` | CPU throughput, compression, multi-core, single-thread | Data pipelines, batch jobs |
| `cache_intensive` | Redis ops, memory bandwidth, database ops | In-memory stores, session management |
| `ml_inference` | Floating point, SIMD/AVX, single-thread latency, multi-core | Model serving, NLP, computer vision |
| `ci_cd_build` | Compiler throughput, file compression, single-thread, multi-core | Build servers, CI/CD runners |

## Scale tiers

Scale tiers define the minimum hardware requirements (memory floor, vCPU floor) and the candidate search window. Candidates must meet the floor for the declared scale; the ceiling is derived from the next tier to keep results relevant.

| Scale | Min vCPUs | Min memory | Typical workload |
|---|---|---|---|
| `small` | 2 | 4 GB | ~10k users, hobby/early-stage |
| `medium` | 4 | 8 GB | ~50k users, growing product |
| `large` | 8 | 16 GB | ~200k users, established platform |
| `xlarge` | 16 | 32 GB | ~1M+ users, high-traffic service |

## How it works

1. Candidate servers with benchmark scores for all required benchmarks are fetched from the [Spare Cores API](https://sparecores.com) and filtered to those meeting the scale's hardware requirements
2. Each benchmark score is min-max normalized across the candidate pool, then combined into a single composite score using profile-defined weights
3. A bi-objective MIP (minimize cost, maximize score) is solved using the epsilon-constraint method to enumerate the full Pareto front
4. Results are ranked from highest-performing to cheapest, showing delta vs. your current server

## Project structure

```
config/
  profiles.json       # workload profiles: benchmark weights, configs, and scale definitions
src/
  main.jl             # entry point — edit this to set your server and profile
  data.jl             # API fetching, candidate filtering, score matrix construction
  scoring.jl          # min-max normalization and composite score computation
  model.jl            # bi-objective MIP formulation and Pareto front extraction
  output.jl           # result formatting and display
  sparecores.jl       # Spare Cores API client with retry/backoff
```

## Data source

Benchmark and pricing data sourced from the [Spare Cores API](https://sparecores.com). Benchmarks are run on real cloud instances under standardized, reproducible configurations.
