# core/paths.jl — Vault のパス解決ヘルパ
#
# レイアウト:
#   {outdir}/data/{project_name}/{run}/{params}/data_sample{NNN}.jld2
#   {outdir}/bin/{project_name}/{run}/{params}/checkpoint_sample{NNN}.jld2
#   {outdir}/status/{project_name}/{run}/{params}/sample_{NNN}.done
#   {outdir}/figure/{project_name}/{run}/...
#
# 1 つの study (= project_name) は複数の run を持てる。
# log.toml の [layout] セクションがこの規約を記録する。

# ── 「この run が住むディレクトリ」 ─────────────────────────────────────────────
# log.toml writer / snapshot / ledger / cleanup から再利用する。

_run_data_dir(vault::Vault)::String = joinpath(
    vault.outdir, "data", vault.spec.study.project_name, vault.run
)

_run_status_dir(vault::Vault)::String = joinpath(
    vault.outdir, "status", vault.spec.study.project_name, vault.run
)

_run_bin_dir(vault::Vault)::String = joinpath(
    vault.outdir, "bin", vault.spec.study.project_name, vault.run
)

_run_figure_dir(vault::Vault)::String = joinpath(
    vault.outdir, "figure", vault.spec.study.project_name, vault.run
)

# ── パラメータパス ────────────────────────────────────────────────────────────

function _param_path(vault::Vault, key::DataKey)::String
    vault.path_formatter(key, vault.spec.path_keys)
end

# ── データ ────────────────────────────────────────────────────────────────────

function _data_dir(vault::Vault, key::DataKey)::String
    joinpath(_run_data_dir(vault), _param_path(vault, key))
end

function _data_file(vault::Vault, key::DataKey; prefix::AbstractString="data")::String
    joinpath(_data_dir(vault, key), @sprintf("%s_sample%03d.jld2", prefix, key.sample))
end

# ── チェックポイント ──────────────────────────────────────────────────────────

function _bin_dir(vault::Vault, key::DataKey)::String
    joinpath(_run_bin_dir(vault), _param_path(vault, key))
end

function _bin_file(vault::Vault, key::DataKey; prefix::AbstractString="checkpoint")::String
    joinpath(_bin_dir(vault, key), @sprintf("%s_sample%03d.jld2", prefix, key.sample))
end

# ── ステータス ────────────────────────────────────────────────────────────────

function _status_dir(vault::Vault, key::DataKey)::String
    joinpath(_run_status_dir(vault), _param_path(vault, key))
end

function _done_file(vault::Vault, key::DataKey)::String
    joinpath(_status_dir(vault, key), @sprintf("sample_%03d.done", key.sample))
end

function _running_file(vault::Vault, key::DataKey)::String
    joinpath(_status_dir(vault, key), @sprintf("sample_%03d.running", key.sample))
end
