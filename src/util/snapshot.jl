# util/snapshot.jl — config_snapshot.toml の保存と差分検知

"""
    _save_config_snapshot(vault)

On first call, copy the config TOML to
`{outdir}/data/{project}/{run}/config_snapshot.toml`.
On subsequent calls, warn (without overwriting) if the live config differs.

The snapshot lives next to the run's data so each run preserves the exact
config it was launched with.
"""
function _save_config_snapshot(vault::Vault)
    run_dir = _run_data_dir(vault)
    snapshot_path = joinpath(run_dir, "config_snapshot.toml")
    mkpath(run_dir)

    if !isfile(snapshot_path)
        cp(vault.config_path, snapshot_path)
    else
        existing = TOML.parsefile(snapshot_path)
        current = TOML.parsefile(vault.config_path)
        if existing != current
            @warn "Config has changed since the snapshot was taken — not overwriting" snapshot =
                snapshot_path
        end
    end
end
