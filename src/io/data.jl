# io/data.jl — JLD2 データ・チェックポイントの読み書き

"""
    DataVault.load(vault, key; prefix="data") -> Dict

Load the JLD2 data file for `key`. Returns the stored dict.
Raises an error if the file does not exist.
"""
function load(vault::Vault, key::DataKey; prefix::AbstractString="data")::Dict
    path = _data_file(vault, key; prefix=prefix)
    isfile(path) || error("Data file not found: $path")
    JLD2.load(path)
end

"""
    DataVault.save!(vault, key, data; prefix="data")

Atomically write `data` (a Dict) to the JLD2 data file for `key`.
Uses a tmp file + rename pattern safe on NFS.
Does NOT automatically mark done — call `mark_done!` explicitly.
"""
function save!(vault::Vault, key::DataKey, data::Dict; prefix::AbstractString="data")
    path = _data_file(vault, key; prefix=prefix)
    mkpath(dirname(path))
    _atomic_jld2_write(path, data)
    nothing
end

"""
    DataVault.load_bin(vault, key; prefix="checkpoint") -> Dict

Load a binary checkpoint file. Raises an explicit error if not present
(checkpoints may exist only on HPC).
"""
function load_bin(vault::Vault, key::DataKey; prefix::AbstractString="checkpoint")::Dict
    path = _bin_file(vault, key; prefix=prefix)
    isfile(path) || error(
        "Checkpoint not found: $path\n" *
        "(Checkpoints may exist only on HPC. Check your outdir or sync first.)",
    )
    JLD2.load(path)
end

"""
    DataVault.save_bin!(vault, key, data; prefix="checkpoint")

Atomically write a binary checkpoint.
"""
function save_bin!(
    vault::Vault, key::DataKey, data::Dict; prefix::AbstractString="checkpoint"
)
    path = _bin_file(vault, key; prefix=prefix)
    mkpath(dirname(path))
    _atomic_jld2_write(path, data)
    nothing
end
