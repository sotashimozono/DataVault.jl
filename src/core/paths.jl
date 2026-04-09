# core/paths.jl — Vault のパス解決ヘルパ
# すべて vault.path_formatter を経由してパラメータ部分を生成する

function _param_path(vault::Vault, key::DataKey)::String
    vault.path_formatter(key, vault.spec.path_keys)
end

function _data_dir(vault::Vault, key::DataKey)::String
    joinpath(vault.outdir, "data", vault.spec.study.project_name, _param_path(vault, key))
end

function _data_file(vault::Vault, key::DataKey; prefix::AbstractString="data")::String
    joinpath(_data_dir(vault, key), @sprintf("%s_sample%03d.jld2", prefix, key.sample))
end

function _bin_dir(vault::Vault, key::DataKey)::String
    joinpath(vault.outdir, "bin", _param_path(vault, key))
end

function _bin_file(vault::Vault, key::DataKey; prefix::AbstractString="checkpoint")::String
    joinpath(_bin_dir(vault, key), @sprintf("%s_sample%03d.jld2", prefix, key.sample))
end

function _status_dir(vault::Vault, key::DataKey)::String
    joinpath(vault.outdir, "status", _param_path(vault, key))
end

function _done_file(vault::Vault, key::DataKey)::String
    joinpath(_status_dir(vault, key), @sprintf("sample_%03d.done", key.sample))
end

function _running_file(vault::Vault, key::DataKey)::String
    joinpath(_status_dir(vault, key), @sprintf("sample_%03d.running", key.sample))
end
