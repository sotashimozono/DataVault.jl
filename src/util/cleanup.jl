# util/cleanup.jl — 残存した .running ファイルの掃除

"""
    cleanup_stale(vault; stale_after=600.0) -> Int

Remove `.running` sentinel files whose `heartbeat=` timestamp is older than
`stale_after` seconds. Returns the number of files removed.

The heartbeat is read from the file content (written by [`mark_running!`](@ref)
and updated by [`touch_running!`](@ref)). If the heartbeat cannot be parsed,
the file's mtime is used as a fallback.

Pass `stale_after=0.0` to remove all `.running` files unconditionally
(the pre-v0.4.1 behaviour).
"""
function cleanup_stale(vault::Vault; stale_after::Real=600.0)::Int
    status_base = _run_status_dir(vault)
    isdir(status_base) || return 0

    threshold = Float64(stale_after)
    now_dt = Dates.now()
    count = 0
    for (root, _, files) in walkdir(status_base)
        for f in files
            endswith(f, ".running") || continue
            fp = joinpath(root, f)
            _running_age_secs(fp, now_dt) > threshold || continue
            rm(fp; force=true)
            count += 1
        end
    end
    count
end

# Read the `heartbeat=` timestamp from a .running file and return age in
# seconds. Falls back to file mtime if the timestamp cannot be parsed.
function _running_age_secs(path::String, now_dt::DateTime)::Float64
    try
        for line in eachline(path)
            if startswith(line, "heartbeat=")
                hb = Dates.DateTime(line[11:end], "yyyy-mm-ddTHH:MM:SS")
                return Dates.value(now_dt - hb) / 1000.0  # ms → s
            end
        end
    catch
    end
    # Fallback: file mtime
    return time() - mtime(path)
end
