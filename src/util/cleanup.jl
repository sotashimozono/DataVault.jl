# util/cleanup.jl — 残存した .running ファイルの掃除

"""
    cleanup_stale(vault) -> Int

Remove all `.running` sentinel files under the status directory.
Returns the number of files removed.
"""
function cleanup_stale(vault::Vault)::Int
    status_base = _run_status_dir(vault)
    isdir(status_base) || return 0

    count = 0
    for (root, _, files) in walkdir(status_base)
        for f in files
            if endswith(f, ".running")
                rm(joinpath(root, f); force=true)
                count += 1
            end
        end
    end
    count
end
