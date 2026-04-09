"""
scripts/analysis/summarize.jl — 結果サマリー

使い方:
    julia --project=. scripts/analysis/summarize.jl [config_path]
"""

using DataVault, ParamIO, Printf

const EXAMPLES = joinpath(@__DIR__, "..", "..")
const CONFIG = get(ARGS, 1, joinpath(EXAMPLES, "configs", "vanderpol.toml"))
const OUTDIR = get(ENV, "DATAVAULT_OUTDIR", joinpath(EXAMPLES, "out"))

vault = Vault(CONFIG; outdir=OUTDIR)

done_keys = DataVault.keys(vault; status=:done)
println("=== Summary: $(vault.spec.study.project_name) ===")
println("Completed: $(length(done_keys)) / $(length(DataVault.keys(vault))) keys\n")

# μ ごとに amplitude と period の平均・標準偏差を集計
mu_groups = Dict{Float64,Vector{Dict}}()
for key in done_keys
    μ = Float64(key.params["system.mu"])
    data = DataVault.load(vault, key)
    push!(get!(mu_groups, μ, []), data)
end

println("mu       | amplitude (mean ± std) | period (mean ± std)")
println("---------|------------------------|--------------------")
for μ in sort(collect(keys(mu_groups)))
    rows = mu_groups[μ]
    amps = [r["amplitude"] for r in rows]
    periods = [r["period"] for r in rows]

    amp_mean = sum(amps) / length(amps)
    amp_std = sqrt(sum((a - amp_mean)^2 for a in amps) / max(1, length(amps) - 1))
    per_mean = sum(periods) / length(periods)
    per_std = sqrt(sum((p - per_mean)^2 for p in periods) / max(1, length(periods) - 1))

    @printf(
        "mu=%-5.2f | %6.4f ± %6.4f      | %6.4f ± %6.4f\n",
        μ,
        amp_mean,
        amp_std,
        per_mean,
        per_std
    )
end

println("\nLedger: $(build_ledger(vault))")
