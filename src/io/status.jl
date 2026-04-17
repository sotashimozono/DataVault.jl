# io/status.jl — .done / .running ステータスファイル

"""
    is_done(vault, key) -> Bool
"""
is_done(vault::Vault, key::DataKey)::Bool = isfile(_done_file(vault, key))

"""
    mark_done!(vault, key; jobid=nothing, tag_value=nothing)

Write a `.done` file for `key`. Removes the corresponding `.running` file if present.

Fields written: `jobid`, `completed`, `git_hash`, and optionally `tag_value`.
`jobid` defaults to `SLURM_JOB_ID` env var, then current PID.
"""
function mark_done!(vault::Vault, key::DataKey; jobid=nothing, tag_value=nothing)
    done = _done_file(vault, key)
    mkpath(dirname(done))

    jobid_str = if jobid !== nothing
        string(jobid)
    elseif haskey(ENV, "SLURM_JOB_ID")
        ENV["SLURM_JOB_ID"]
    else
        string(getpid())
    end

    completed = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    git_hash = _git_hash(vault.config_path)

    lines = ["jobid=$jobid_str", "completed=$completed", "git_hash=$git_hash"]
    tag_value !== nothing && push!(lines, "tag_value=$tag_value")

    write(done, join(lines, "\n") * "\n")

    running = _running_file(vault, key)
    isfile(running) && rm(running; force=true)
    nothing
end

"""
    mark_running!(vault, key)

Write a `.running` sentinel with `pid`, `started`, and `heartbeat` fields.
The `heartbeat` field is periodically updated by [`touch_running!`](@ref)
to signal that the holder is still alive. [`cleanup_stale`](@ref) uses
the `heartbeat` timestamp to distinguish live jobs from crashed ones.
"""
function mark_running!(vault::Vault, key::DataKey)
    path = _running_file(vault, key)
    mkpath(dirname(path))
    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    write(path, "pid=$(getpid())\nstarted=$(now_str)\nheartbeat=$(now_str)\n")
    nothing
end

"""
    touch_running!(vault, key)

Update the `heartbeat=` line in the `.running` file to the current time.
Called periodically (e.g. every 60 s) while computation is in progress so
that [`cleanup_stale`](@ref) can distinguish live jobs from crashed ones.

No-op if the `.running` file does not exist (already cleared or never created).
"""
function touch_running!(vault::Vault, key::DataKey)
    path = _running_file(vault, key)
    isfile(path) || return nothing
    now_str = Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS")
    try
        lines = readlines(path)
        open(path, "w") do io
            for line in lines
                if startswith(line, "heartbeat=")
                    println(io, "heartbeat=$(now_str)")
                else
                    println(io, line)
                end
            end
        end
    catch
        # .running may have been removed by another master; swallow
    end
    nothing
end

"""
    running_heartbeat(vault, key) -> Union{DateTime, Nothing}

Read the `heartbeat=` timestamp from the `.running` file. Returns `nothing`
if the file does not exist or the timestamp cannot be parsed.
"""
function running_heartbeat(vault::Vault, key::DataKey)::Union{DateTime,Nothing}
    path = _running_file(vault, key)
    isfile(path) || return nothing
    try
        for line in eachline(path)
            if startswith(line, "heartbeat=")
                return Dates.DateTime(line[11:end], "yyyy-mm-ddTHH:MM:SS")
            end
        end
    catch
    end
    nothing
end

"""
    clear_running!(vault, key)

Remove the `.running` sentinel for `key`. Idempotent — safe to call when
the file has already been removed (e.g. by [`mark_done!`](@ref)).
"""
function clear_running!(vault::Vault, key::DataKey)
    path = _running_file(vault, key)
    isfile(path) && rm(path; force=true)
    nothing
end

"""
    is_running(vault, key) -> Bool
"""
is_running(vault::Vault, key::DataKey)::Bool = isfile(_running_file(vault, key))
