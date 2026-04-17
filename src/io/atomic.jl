# io/atomic.jl — NFS-safe な原子的書き込み

"""
    _atomic_jld2_write(path, data)

Write `data` (a `Dict`) to `path` atomically by writing to a per-pid
temporary file first and then `mv`ing it into place. Safe against
concurrent writers on NFS.
"""
function _atomic_jld2_write(path::String, data::Dict)
    tmp = path * ".tmp." * string(getpid())
    try
        jldopen(tmp, "w") do f
            for (k, v) in data
                f[string(k)] = v
            end
        end
        mv(tmp, path; force=true)
    catch e
        isfile(tmp) && rm(tmp; force=true)
        rethrow(e)
    end
end

"""
    _git_hash(ref_path) -> String

Return the short HEAD hash of the git repo containing `ref_path`,
or `"unknown"` if not in a repo.
"""
function _git_hash(ref_path::String)::String
    dir = isdir(ref_path) ? ref_path : dirname(ref_path)
    try
        strip(read(pipeline(`git -C $dir rev-parse --short HEAD`; stderr=devnull), String))
    catch
        "unknown"
    end
end
