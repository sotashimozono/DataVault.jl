# util/snapshot.jl — config_snapshot.toml の保存と差分検知

"""
    _save_config_snapshot(vault)

On first call, copy the config TOML to `out/data/{project}/config_snapshot.toml`.
On subsequent calls, warn (without overwriting) if the live config differs.
"""
function _save_config_snapshot(vault::Vault)
    project_dir = joinpath(vault.outdir, "data", vault.spec.study.project_name)
    snapshot_path = joinpath(project_dir, "config_snapshot.toml")
    mkpath(project_dir)

    if !isfile(snapshot_path)
        cp(vault.config_path, snapshot_path)
    else
        existing = TOML.parsefile(snapshot_path)
        current = TOML.parsefile(vault.config_path)
        if existing != current
            @warn "Config has changed since the snapshot was taken — not overwriting" snapshot=snapshot_path
        end
    end
end
