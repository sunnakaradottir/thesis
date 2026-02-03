# Cloud Resource Optimization Model

## config/profiles.json
Has pre defined workload profiles defining which measurements (benchmarks) we want to compare the candidate server and current server with, along with importance weights.
- Importance weights can be 'overridden'
- Benchmark configuration is done to match current server, if available, otherwise no configuration and we look at the top result from the API


## Dependencies
import Pkg; Pkg.add("JSON")
import HiGHS; Pkg.add("HiGHS")
import JuMP; Pkg.add("JuMP")