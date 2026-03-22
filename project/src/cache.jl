using Serialization

const CACHE_DIR = joinpath(@__DIR__, "..", "cache")


function cache_path(vendor, server_id, profile_name, scale_name)
    mkpath(CACHE_DIR)
    return joinpath(CACHE_DIR, "$(vendor)_$(server_id)_$(profile_name)_$(scale_name).jls")
end


const CACHE_MAX_AGE_DAYS = 7

function fetch_with_cache(vendor, server_id, profile_name, profile, scale_name; force_refresh=false)
    path = cache_path(vendor, server_id, profile_name, scale_name)

    if !force_refresh && isfile(path)
        age_days = (time() - mtime(path)) / 86400 # seconds in a day
        if age_days <= CACHE_MAX_AGE_DAYS
            println("  [cache] $vendor/$server_id  $profile_name/$scale_name")
            return deserialize(path)
        end
        println("  [expired] $vendor/$server_id  $profile_name/$scale_name  ($(round(age_days, digits=1)) days old)")
    end

    println("  [fetch] $vendor/$server_id  $profile_name/$scale_name")
    data = get_multi_benchmark_data(vendor, server_id, profile, scale_name)
    serialize(path, data)
    return data
end
