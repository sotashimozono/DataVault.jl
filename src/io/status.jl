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

Write a `.running` sentinel. Call at the start of computation to enable
`cleanup_stale()` to detect crashed jobs.
"""
function mark_running!(vault::Vault, key::DataKey)
    path = _running_file(vault, key)
    mkpath(dirname(path))
    write(
        path,
        "pid=$(getpid())\nstarted=$(Dates.format(Dates.now(), "yyyy-mm-ddTHH:MM:SS"))\n",
    )
    nothing
end
